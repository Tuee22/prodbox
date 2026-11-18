{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded, unambiguous decoding for a candidate kind kubeconfig. This does
-- not authenticate the source file, validate certificates or contact a cluster.
module Prodbox.Control.KindKubeconfigYaml
  ( KindKubeconfigDecodeError (..)
  , decodeKindKubeconfig
  , decodeBoundedYamlValue
  , decodeBoundedYamlDocuments
  , matchesKindKubeadmScope
  , matchesPinnedKindKubeadmConfig
  )
where

import Control.Exception (try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.ByteString qualified as ByteString
import Data.Conduit (ConduitT, await, runConduit, (.|))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Yaml.Internal qualified as Yaml
import Prodbox.Config.DeploymentScope (DeploymentScope, scopeKindName)
import Prodbox.Control.KindKubeconfig (KindKubeconfig, KindKubeconfigError, validateKindKubeconfig)
import Prodbox.Settings.Coordinate (ipLiteralText, mkIpLiteral)
import Text.Libyaml qualified as Libyaml

data KindKubeconfigDecodeError
  = KindKubeconfigDocumentTooLarge
  | KindKubeconfigDocumentInvalidUtf8
  | KindKubeconfigDocumentUnsupported
  | KindKubeconfigDocumentInvalid
  | KindKubeconfigProjectionError !KindKubeconfigError
  deriving (Eq, Show)

-- | Reject aliases, anchors, explicit tags, merge keys, deep or large event
-- streams and duplicate mapping keys before accepting the semantic projection.
-- Neither parser errors nor document bytes are returned in diagnostics.
decodeKindKubeconfig
  :: DeploymentScope -> ByteString.ByteString -> IO (Either KindKubeconfigDecodeError KindKubeconfig)
decodeKindKubeconfig scope input =
  do
    decoded <- decodeBoundedYamlValue input
    pure $ do
      value <- decoded
      either (Left . KindKubeconfigProjectionError) Right (validateKindKubeconfig scope value)

-- | Decode one bounded, duplicate-free document without expanding aliases.
-- It supplies no authentication or semantic interpretation of the value.
decodeBoundedYamlValue :: ByteString.ByteString -> IO (Either KindKubeconfigDecodeError Value)
decodeBoundedYamlValue input
  | ByteString.length input > 524288 = pure (Left KindKubeconfigDocumentTooLarge)
  | otherwise = case TextEncoding.decodeUtf8' input of
      Left _ -> pure (Left KindKubeconfigDocumentInvalidUtf8)
      Right _ -> do
        scanned <- try (runResourceT (runConduit (Libyaml.decode input .| scanEvents 0 0)))
        case scanned of
          Left (_ :: Libyaml.YamlException) -> pure (Left KindKubeconfigDocumentInvalid)
          Right False -> pure (Left KindKubeconfigDocumentUnsupported)
          Right True -> do
            decoded <-
              Yaml.decodeHelper_ (Libyaml.decode input) :: IO (Either Yaml.ParseException ([Yaml.Warning], Value))
            pure $ case decoded of
              Left _ -> Left KindKubeconfigDocumentInvalid
              Right (warnings, value)
                | not (null warnings) -> Left KindKubeconfigDocumentUnsupported
                | otherwise -> Right value

-- | Decode a bounded stream of up to sixteen unambiguous documents. The
-- errors never include document contents, which may contain bootstrap tokens.
-- This only establishes syntax; callers must validate every semantic field.
decodeBoundedYamlDocuments :: ByteString.ByteString -> IO (Either KindKubeconfigDecodeError [Value])
decodeBoundedYamlDocuments input
  | ByteString.length input > 65536 = pure (Left KindKubeconfigDocumentTooLarge)
  | otherwise = case TextEncoding.decodeUtf8' input of
      Left _ -> pure (Left KindKubeconfigDocumentInvalidUtf8)
      Right _ -> do
        scanned <- try (runResourceT (runConduit (Libyaml.decode input .| scanEvents 0 0)))
        case scanned of
          Left (_ :: Libyaml.YamlException) -> pure (Left KindKubeconfigDocumentInvalid)
          Right False -> pure (Left KindKubeconfigDocumentUnsupported)
          Right True -> do
            decoded <-
              Yaml.decodeAllHelper_ (Libyaml.decode input)
                :: IO (Either Yaml.ParseException ([Yaml.Warning], [Value]))
            pure $ case decoded of
              Left _ -> Left KindKubeconfigDocumentInvalid
              Right (warnings, values)
                | not (null warnings) || null values || length values > 16 -> Left KindKubeconfigDocumentUnsupported
                | otherwise -> Right values

-- | Compare the pinned kind provider's document identities and selected
-- cluster coordinates. This is a partial projection, not validation of the
-- remaining fields, authenticity, permission to execute, or readiness.
matchesKindKubeadmScope :: DeploymentScope -> Text.Text -> Text.Text -> [Value] -> Bool
matchesKindKubeadmScope scope nodeAddress version documents = case documents of
  [cluster, initial, join, kubelet, proxy] ->
    either (const False) ((== nodeAddress) . ipLiteralText) (mkIpLiteral nodeAddress)
      && not (Text.null version)
      && Text.length version <= 128
      && parseEither clusterProjection cluster == Right True
      && parseEither initProjection initial == Right True
      && parseEither (identity "kubeadm.k8s.io/v1beta3" "JoinConfiguration") join == Right True
      && parseEither (identity "kubelet.config.k8s.io/v1beta1" "KubeletConfiguration") kubelet == Right True
      && parseEither (identity "kubeproxy.config.k8s.io/v1alpha1" "KubeProxyConfiguration") proxy
        == Right True
  _ -> False
 where
  clusterName = Text.pack (scopeKindName scope)
  identity api kind = Aeson.withObject "document" $ \object -> do
    actualApi <- object .: "apiVersion" :: Parser Text.Text
    actualKind <- object .: "kind" :: Parser Text.Text
    pure (actualApi == api && actualKind == kind)
  clusterProjection value = do
    selected <- identity "kubeadm.k8s.io/v1beta3" "ClusterConfiguration" value
    Aeson.withObject
      "cluster"
      ( \object -> do
          name <- object .: "clusterName"
          observedVersion <- object .: "kubernetesVersion"
          endpoint <- object .: "controlPlaneEndpoint"
          network <- object .: "networking"
          podSubnet <- network .: "podSubnet"
          serviceSubnet <- network .: "serviceSubnet"
          pure $
            selected
              && name == clusterName
              && observedVersion == version
              && endpoint == clusterName <> "-control-plane:6443"
              && podSubnet == ("10.244.0.0/16" :: Text.Text)
              && serviceSubnet == ("10.96.0.0/16" :: Text.Text)
      )
      value
  initProjection value = do
    selected <- identity "kubeadm.k8s.io/v1beta3" "InitConfiguration" value
    Aeson.withObject
      "init"
      ( \object -> do
          endpoint <- object .: "localAPIEndpoint"
          address <- endpoint .: "advertiseAddress"
          port <- endpoint .: "bindPort" :: Parser Int
          pure (selected && address == nodeAddress && port == 6443)
      )
      value

-- | Match the observed default five-document configuration produced by the
-- pinned kind provider. Tokens are checked and compared in memory only.
-- This does not authenticate kind, the node, the daemon, or the observations
-- supplied by the caller, and it does not authorize a write or kubeadm run.
matchesPinnedKindKubeadmConfig
  :: DeploymentScope -> Text.Text -> Text.Text -> Text.Text -> [Value] -> Bool
matchesPinnedKindKubeadmConfig scope nodeAddress version cgroupDriver documents =
  matchesKindKubeadmScope scope nodeAddress version documents
    && cgroupDriver `elem` ["systemd", "cgroupfs"]
    && case documents of
      [_, initial, join, _, _] -> case (parseEither initToken initial, parseEither joinToken join) of
        (Right first, Right second) -> validToken first && first == second && documents == expected first
        _ -> False
      _ -> False
 where
  cluster = Text.pack (scopeKindName scope)
  node = cluster <> "-control-plane"
  endpoint = node <> ":6443"
  local = Aeson.object ["advertiseAddress" Aeson..= nodeAddress, "bindPort" Aeson..= (6443 :: Int)]
  registration =
    Aeson.object
      [ "criSocket" Aeson..= ("unix:///run/containerd/containerd.sock" :: Text.Text)
      , "kubeletExtraArgs"
          Aeson..= Aeson.object
            [ "node-ip" Aeson..= nodeAddress
            , "node-labels" Aeson..= ("" :: Text.Text)
            , "provider-id" Aeson..= ("kind://docker/" <> cluster <> "/" <> node)
            ]
      ]
  initToken = Aeson.withObject "init" $ \object -> do
    tokens <- object .: "bootstrapTokens" :: Parser [Value]
    case tokens of
      [token] -> Aeson.withObject "token" (.: "token") token
      _ -> fail "unexpected token count"
  joinToken = Aeson.withObject "join" $ \object -> do
    discovery <- object .: "discovery"
    bootstrap <- discovery .: "bootstrapToken"
    bootstrap .: "token"
  validToken value = case Text.splitOn "." value of
    [prefix, secret] ->
      Text.length prefix == 6
        && Text.length secret == 16
        && Text.all tokenChar prefix
        && Text.all tokenChar secret
    _ -> False
  tokenChar character = (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')
  expected token =
    [ Aeson.object
        [ "apiVersion" Aeson..= ("kubeadm.k8s.io/v1beta3" :: Text.Text)
        , "kind" Aeson..= ("ClusterConfiguration" :: Text.Text)
        , "clusterName" Aeson..= cluster
        , "kubernetesVersion" Aeson..= version
        , "controlPlaneEndpoint" Aeson..= endpoint
        , "networking"
            Aeson..= Aeson.object
              [ "podSubnet" Aeson..= ("10.244.0.0/16" :: Text.Text)
              , "serviceSubnet" Aeson..= ("10.96.0.0/16" :: Text.Text)
              ]
        , "apiServer"
            Aeson..= Aeson.object
              [ "certSANs" Aeson..= (["localhost", "127.0.0.1"] :: [Text.Text])
              , "extraArgs" Aeson..= Aeson.object ["runtime-config" Aeson..= ("" :: Text.Text)]
              ]
        , "controllerManager"
            Aeson..= Aeson.object
              ["extraArgs" Aeson..= Aeson.object ["enable-hostpath-provisioner" Aeson..= ("true" :: Text.Text)]]
        , "scheduler" Aeson..= Aeson.object ["extraArgs" Aeson..= Aeson.Null]
        ]
    , Aeson.object
        [ "apiVersion" Aeson..= ("kubeadm.k8s.io/v1beta3" :: Text.Text)
        , "kind" Aeson..= ("InitConfiguration" :: Text.Text)
        , "bootstrapTokens" Aeson..= [Aeson.object ["token" Aeson..= token]]
        , "localAPIEndpoint" Aeson..= local
        , "nodeRegistration" Aeson..= registration
        , "skipPhases" Aeson..= (["preflight"] :: [Text.Text])
        ]
    , Aeson.object
        [ "apiVersion" Aeson..= ("kubeadm.k8s.io/v1beta3" :: Text.Text)
        , "kind" Aeson..= ("JoinConfiguration" :: Text.Text)
        , "controlPlane" Aeson..= Aeson.object ["localAPIEndpoint" Aeson..= local]
        , "discovery"
            Aeson..= Aeson.object
              [ "bootstrapToken"
                  Aeson..= Aeson.object
                    [ "apiServerEndpoint" Aeson..= endpoint
                    , "token" Aeson..= token
                    , "unsafeSkipCAVerification" Aeson..= True
                    ]
              ]
        , "nodeRegistration" Aeson..= registration
        , "skipPhases" Aeson..= (["preflight"] :: [Text.Text])
        ]
    , Aeson.object
        [ "apiVersion" Aeson..= ("kubelet.config.k8s.io/v1beta1" :: Text.Text)
        , "kind" Aeson..= ("KubeletConfiguration" :: Text.Text)
        , "cgroupDriver" Aeson..= cgroupDriver
        , "cgroupRoot" Aeson..= ("/kubelet" :: Text.Text)
        , "evictionHard"
            Aeson..= Aeson.object
              [ "imagefs.available" Aeson..= ("0%" :: Text.Text)
              , "nodefs.available" Aeson..= ("0%" :: Text.Text)
              , "nodefs.inodesFree" Aeson..= ("0%" :: Text.Text)
              ]
        , "failSwapOn" Aeson..= False
        , "imageGCHighThresholdPercent" Aeson..= (100 :: Int)
        ]
    , Aeson.object
        [ "apiVersion" Aeson..= ("kubeproxy.config.k8s.io/v1alpha1" :: Text.Text)
        , "kind" Aeson..= ("KubeProxyConfiguration" :: Text.Text)
        , "conntrack" Aeson..= Aeson.object ["maxPerCore" Aeson..= (0 :: Int)]
        , "iptables" Aeson..= Aeson.object ["minSyncPeriod" Aeson..= ("1s" :: Text.Text)]
        , "mode" Aeson..= ("iptables" :: Text.Text)
        ]
    ]

scanEvents :: (Monad m) => Int -> Int -> ConduitT Libyaml.Event output m Bool
scanEvents count depth = do
  next <- await
  case next of
    Nothing -> pure (depth == 0)
    Just event
      | count >= 1024 -> pure False
      | otherwise -> case event of
          Libyaml.EventAlias _ -> pure False
          Libyaml.EventScalar bytes tag _ anchor
            | tag /= Libyaml.NoTag || anchor /= Nothing || bytes == "<<" -> pure False
            | otherwise -> scanEvents (count + 1) depth
          Libyaml.EventSequenceStart tag _ anchor -> start tag anchor
          Libyaml.EventMappingStart tag _ anchor -> start tag anchor
          Libyaml.EventSequenceEnd -> finish
          Libyaml.EventMappingEnd -> finish
          _ -> scanEvents (count + 1) depth
 where
  start tag anchor
    | tag /= Libyaml.NoTag || anchor /= Nothing || depth >= 16 = pure False
    | otherwise = scanEvents (count + 1) (depth + 1)
  finish
    | depth <= 0 = pure False
    | otherwise = scanEvents (count + 1) (depth - 1)
