{-# LANGUAGE OverloadedStrings #-}

-- | A non-authorizing kind configuration plan. The caller must verify the
-- retained image, root generation, port availability, and cluster identity
-- before applying it, then independently read back the resulting resources.
module Prodbox.Config.KindPlan
  ( KindPlan
  , KindPlanError (..)
  , PublicationMapping (..)
  , kindPlan
  , kindPlanScope
  , kindPlanNodeImage
  , kindPlanMappings
  , matchesObservedKindNodeRun
  , kindNodeRunArguments
  , KindNodeCreateInput (..)
  , kindNodeVarVolumeName
  , kindNodeVarVolumeNameForScope
  , kindNodeVarVolumeLabels
  , kindNodeVarVolumeCreateBody
  , kindNodeCreateBody
  , requireDisjointKindPlans
  , kindPlanHostPorts
  , renderKindConfig
  , renderKindConfigWithLocalImageId
  )
where

import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy (ByteString)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.Config.DeploymentScope
  ( DeploymentScope
  , DeploymentScopeError
  , requireDisjointScopes
  , scopeApiPort
  , scopeKindName
  , scopeRoot
  , validRootGeneration
  )
import Prodbox.Config.RetainedArtifacts (isCanonicalSha256Digest)
import Prodbox.ContainerImage (ImageRef (..), parseImageRef)
import Prodbox.Settings.Coordinate (IpLiteral, ipLiteralText, mkIpLiteral)

data PublicationMapping = PublicationMapping
  { publicationHostPort :: !Int
  , publicationNodePort :: !Int
  , publicationListenAddress :: !IpLiteral
  }
  deriving (Eq, Show)

data KindPlanError
  = InvalidNodeImage
  | InvalidPublicationPort
  | InvalidPublicationNodePort
  | DuplicatePublicationPort
  | OverlappingKindScope !DeploymentScopeError
  | OverlappingKindHostPort
  deriving (Eq, Show)

data KindPlan = KindPlan
  { kindPlanScope :: !DeploymentScope
  , nodeImage :: !String
  , httpMapping :: !PublicationMapping
  , httpsMapping :: !PublicationMapping
  }
  deriving (Eq, Show)

kindPlanNodeImage :: KindPlan -> String
kindPlanNodeImage = nodeImage

kindPlanMappings :: KindPlan -> (PublicationMapping, PublicationMapping)
kindPlanMappings plan = (httpMapping plan, httpsMapping plan)

-- | Match the observed v0.32.0 provider's exact Docker argv against this
-- plan. The caller must independently verify the kind tool and image bytes,
-- bind the supplied digests to the operation, admit the effect, and settle
-- and read back the resulting container. Matching argv is not authority.
matchesObservedKindNodeRun :: KindPlan -> String -> String -> [String] -> Bool
matchesObservedKindNodeRun plan kindDigest localImage arguments =
  kindDigest == "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
    && isCanonicalSha256Digest localImage
    && ':' `notElem` scopeRoot (kindPlanScope plan)
    && arguments == kindNodeRunArguments plan localImage

-- | The exact Docker argv the observed v0.32.0 provider uses for the node. It
-- names no resource and grants no authority; the node proposal records it.
kindNodeRunArguments :: KindPlan -> String -> [String]
kindNodeRunArguments plan localImage = expected
 where
  scope = kindPlanScope plan
  cluster = scopeKindName scope
  node = cluster ++ "-control-plane"
  expected =
    [ "run"
    , "--name"
    , node
    , "--hostname"
    , node
    , "--label"
    , "io.x-k8s.kind.role=control-plane"
    , "--privileged"
    , "--security-opt"
    , "seccomp=unconfined"
    , "--security-opt"
    , "apparmor=unconfined"
    , "--tmpfs"
    , "/tmp"
    , "--tmpfs"
    , "/run"
    , "--volume"
    , "/var"
    , "--volume"
    , "/lib/modules:/lib/modules:ro"
    , "-e"
    , "KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER"
    , "--detach"
    , "--tty"
    , "--label"
    , "io.x-k8s.kind.cluster=" ++ cluster
    , "--net"
    , cluster
    , "--restart=on-failure:1"
    , "--init=false"
    , "--cgroupns=private"
    , "--volume=" ++ scopeRoot scope ++ ":/var/lib/prodbox"
    , publish (httpMapping plan)
    , publish (httpsMapping plan)
    , "--publish=127.0.0.1:" ++ show (scopeApiPort scope) ++ ":6443/TCP"
    , "-e"
    , "KUBECONFIG=/etc/kubernetes/admin.conf"
    , localImage
    ]
  publish mapping =
    "--publish="
      ++ host (Text.unpack (ipLiteralText (publicationListenAddress mapping)))
      ++ ":"
      ++ show (publicationHostPort mapping)
      ++ ":"
      ++ show (publicationNodePort mapping)
      ++ "/TCP"
  host value = if ':' `elem` value then "[" ++ value ++ "]" else value

-- | Inputs must be established by the operation owner. In particular, a
-- syntactically valid network ID or image ID is not evidence of ownership.
data KindNodeCreateInput = KindNodeCreateInput
  { nodeCreateToolDigest :: !String
  , nodeCreateImageId :: !String
  , nodeCreateNetworkId :: !String
  , nodeCreateGeneration :: !String
  , nodeCreateOperation :: !String
  , nodeCreateArguments :: ![String]
  }
  deriving (Eq, Show)

-- | Derive the node's Docker volume name from the selected identity and its
-- exact generation and operation. This does not create or claim the volume.
kindNodeVarVolumeName :: KindPlan -> String -> String -> Maybe String
kindNodeVarVolumeName plan = kindNodeVarVolumeNameForScope (kindPlanScope plan)

kindNodeVarVolumeNameForScope :: DeploymentScope -> String -> String -> Maybe String
kindNodeVarVolumeNameForScope scope generation operation
  | validRootGeneration generation && validRootGeneration operation =
      Just (scopeKindName scope ++ "-var-" ++ generation ++ "-" ++ operation)
  | otherwise = Nothing

-- | Expected labels for an independently verified node volume. Matching labels
-- alone do not prove provenance or grant authority over the volume.
kindNodeVarVolumeLabels :: KindPlan -> String -> String -> Maybe (Map.Map String String)
kindNodeVarVolumeLabels plan generation operation = do
  _ <- kindNodeVarVolumeName plan generation operation
  pure $
    Map.fromList
      [ ("io.prodbox.deployment", scopeKindName (kindPlanScope plan))
      , ("io.prodbox.generation", generation)
      , ("io.prodbox.operation", operation)
      , ("io.prodbox.resource", "kind-node-var")
      ]

-- | Construct only the deterministic, local-driver volume proposal. This is
-- not an admission, durable intent, ownership proof or provider operation.
kindNodeVarVolumeCreateBody :: KindPlan -> String -> String -> Maybe Value
kindNodeVarVolumeCreateBody plan generation operation = do
  name <- kindNodeVarVolumeName plan generation operation
  labels <- kindNodeVarVolumeLabels plan generation operation
  pure $
    object
      [ "Name" .= name
      , "Driver" .= ("local" :: String)
      , "DriverOpts" .= object []
      , "Labels" .= labels
      ]

-- | Project an exactly matched provider request to a Docker create body. The
-- network is selected by the caller's full ID, and labels retain operation
-- identity. Docker can create a missing named volume implicitly. Admission,
-- volume provenance, durable intent, transport, start, settlement and cleanup
-- remain caller obligations; this projection is not an effect permit.
kindNodeCreateBody :: KindPlan -> KindNodeCreateInput -> Maybe Value
kindNodeCreateBody plan input
  | not
      ( matchesObservedKindNodeRun
          plan
          (nodeCreateToolDigest input)
          (nodeCreateImageId input)
          (nodeCreateArguments input)
      ) =
      Nothing
  | not (isCanonicalSha256Digest ("sha256:" ++ nodeCreateNetworkId input)) = Nothing
  | otherwise =
      body <$> kindNodeVarVolumeName plan (nodeCreateGeneration input) (nodeCreateOperation input)
 where
  scope = kindPlanScope plan
  cluster = scopeKindName scope
  node = cluster ++ "-control-plane"
  mappings = [httpMapping plan, httpsMapping plan]
  exposed mapping = Key.fromString (show (publicationNodePort mapping) ++ "/tcp") .= object []
  binding mapping =
    Key.fromString (show (publicationNodePort mapping) ++ "/tcp")
      .= [ object
             [ "HostIp" .= ipLiteralText (publicationListenAddress mapping)
             , "HostPort" .= show (publicationHostPort mapping)
             ]
         ]
  apiBinding = [object ["HostIp" .= ("127.0.0.1" :: String), "HostPort" .= show (scopeApiPort scope)]]
  body volumeName =
    object
      [ "Hostname" .= node
      , "Image" .= nodeCreateImageId input
      , "Tty" .= True
      , "Env"
          .= (["KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER", "KUBECONFIG=/etc/kubernetes/admin.conf"] :: [String])
      , "Labels"
          .= object
            [ "io.x-k8s.kind.cluster" .= cluster
            , "io.x-k8s.kind.role" .= ("control-plane" :: String)
            , "io.prodbox.generation" .= nodeCreateGeneration input
            , "io.prodbox.operation" .= nodeCreateOperation input
            ]
      , "Volumes" .= object []
      , "ExposedPorts" .= object (map exposed mappings ++ ["6443/tcp" .= object []])
      , "HostConfig"
          .= object
            [ "Binds"
                .= ( [volumeName ++ ":/var", "/lib/modules:/lib/modules:ro", scopeRoot scope ++ ":/var/lib/prodbox"]
                       :: [String]
                   )
            , "NetworkMode" .= nodeCreateNetworkId input
            , "PortBindings" .= object (map binding mappings ++ ["6443/tcp" .= apiBinding])
            , "RestartPolicy" .= object ["Name" .= ("on-failure" :: String), "MaximumRetryCount" .= (1 :: Int)]
            , "Privileged" .= True
            , "SecurityOpt" .= (["seccomp=unconfined", "apparmor=unconfined"] :: [String])
            , "Tmpfs" .= object ["/tmp" .= ("" :: String), "/run" .= ("" :: String)]
            , "CgroupnsMode" .= ("private" :: String)
            , "Init" .= False
            ]
      ]

kindPlan
  :: DeploymentScope
  -> String
  -> PublicationMapping
  -> PublicationMapping
  -> Either KindPlanError KindPlan
kindPlan scope image http https
  | not (validPinnedImage image) = Left InvalidNodeImage
  | not (all validPort ports) = Left InvalidPublicationPort
  | not (all validNodePort [publicationNodePort http, publicationNodePort https]) =
      Left InvalidPublicationNodePort
  | publicationHostPort http == publicationHostPort https
      || publicationHostPort http == scopeApiPort scope
      || publicationHostPort https == scopeApiPort scope
      || publicationNodePort http == publicationNodePort https =
      Left DuplicatePublicationPort
  | otherwise = Right (KindPlan scope image http https)
 where
  ports =
    [ publicationHostPort http
    , publicationNodePort http
    , publicationHostPort https
    , publicationNodePort https
    ]

validPort :: Int -> Bool
validPort value = value > 0 && value <= 65535

-- The rendered kind configuration leaves Kubernetes' service-node-port-range
-- at its default. A Docker mapping outside it cannot serve a NodePort Service.
validNodePort :: Int -> Bool
validNodePort value = value >= 30000 && value <= 32767

-- | The public image reference must contain a canonical immutable digest. It
-- remains only a declared identity until retained bytes and architecture are
-- independently observed.
validPinnedImage :: String -> Bool
validPinnedImage raw =
  case break (== '@') raw of
    (reference, '@' : digest)
      | length raw <= 512 && isCanonicalSha256Digest digest ->
          case parseImageRef reference of
            Left _ -> False
            Right parsed ->
              validRegistry (imageRegistry parsed)
                && length (imageRegistry parsed) + length (imageRepository parsed) + 1 <= 255
                && all validRepositoryComponent (Text.splitOn "/" (Text.pack (imageRepository parsed)))
                && validTag (imageTag parsed)
                && not (null reference)
                && not (any (`elem` (" \t\r\n" :: String)) reference)
    _ -> False

validRegistry :: String -> Bool
validRegistry registry
  | "[" `isPrefixOf` registry =
      case break (== ']') (drop 1 registry) of
        (address, ']' : suffix) -> ':' `elem` address && isRightIp address && validPortSuffix suffix
        _ -> False
  | otherwise =
      case break (== ':') registry of
        (host, suffix) -> validHost host && validPortSuffix suffix
 where
  isRightIp value = case mkIpLiteral (Text.pack value) of
    Right _ -> True
    Left _ -> False
  validHost host =
    not (null host)
      && length host <= 253
      && all validHostLabel (Text.splitOn "." (Text.pack host))
      && validNumericHost host
  validNumericHost host = case Text.splitOn "." (Text.pack host) of
    [a, b, c, d]
      | all (Text.all asciiDigit) [a, b, c, d] -> isRightIp host
    _ -> True
  validHostLabel label = case (Text.uncons label, Text.unsnoc label) of
    (Just (first, _), Just (_, final)) ->
      Text.length label <= 63
        && asciiHostAlphaNum first
        && asciiHostAlphaNum final
        && Text.all (\character -> asciiHostAlphaNum character || character == '-') label
    _ -> False
  validPortSuffix "" = True
  validPortSuffix (':' : digits) =
    not (null digits)
      && length digits <= 5
      && all asciiDigit digits
      && case reads digits of
        [(port, "")] -> validPort port
        _ -> False
  validPortSuffix _ = False

validRepositoryComponent :: Text.Text -> Bool
validRepositoryComponent component =
  not (Text.null component)
    && validParts (Text.unpack component)
 where
  validParts value = case span asciiAlphaNum value of
    ([], _) -> False
    (_, []) -> True
    (_, rest) -> case separator rest of
      Nothing -> False
      Just remaining -> validParts remaining
  separator ('.' : remaining) = Just remaining
  separator ('_' : '_' : remaining) = Just remaining
  separator ('_' : remaining) = Just remaining
  separator ('-' : remaining) = Just (dropWhile (== '-') remaining)
  separator _ = Nothing

validTag :: String -> Bool
validTag [] = False
validTag (first : rest) =
  length rest < 128
    && (asciiAlphaNum first || isAsciiUpper first || first == '_')
    && all
      ( \character -> asciiAlphaNum character || isAsciiUpper character || character `elem` ("_.-" :: String)
      )
      rest

asciiAlphaNum :: Char -> Bool
asciiAlphaNum character = isAsciiLower character || asciiDigit character

asciiHostAlphaNum :: Char -> Bool
asciiHostAlphaNum character = asciiAlphaNum character || isAsciiUpper character

asciiDigit :: Char -> Bool
asciiDigit character = isDigit character && character >= '0' && character <= '9'

requireDisjointKindPlans :: KindPlan -> KindPlan -> Either KindPlanError ()
requireDisjointKindPlans left right = do
  either
    (Left . OverlappingKindScope)
    Right
    (requireDisjointScopes (kindPlanScope left) (kindPlanScope right))
  if any (`elem` hostPorts right) (hostPorts left)
    then Left OverlappingKindHostPort
    else Right ()

kindPlanHostPorts :: KindPlan -> [Int]
kindPlanHostPorts = hostPorts

hostPorts :: KindPlan -> [Int]
hostPorts plan =
  [ scopeApiPort (kindPlanScope plan)
  , publicationHostPort (httpMapping plan)
  , publicationHostPort (httpsMapping plan)
  ]

-- | kind accepts JSON as YAML. A structured encoder keeps host paths and
-- addresses as values rather than embedding them in YAML or command syntax.
renderKindConfig :: KindPlan -> ByteString
renderKindConfig plan = renderKindConfigWithImage plan (nodeImage plan)

-- | Render the same mounts, ports and scope for an observed local image ID.
-- This validates syntax only: the caller must bind this ID to the verified
-- retained archive and independently establish admission and recovery.
renderKindConfigWithLocalImageId :: KindPlan -> String -> Maybe ByteString
renderKindConfigWithLocalImageId plan imageId
  | isCanonicalSha256Digest imageId = Just (renderKindConfigWithImage plan imageId)
  | otherwise = Nothing

renderKindConfigWithImage :: KindPlan -> String -> ByteString
renderKindConfigWithImage plan image =
  encode $
    object
      [ "kind" .= ("Cluster" :: Text.Text)
      , "apiVersion" .= ("kind.x-k8s.io/v1alpha4" :: Text.Text)
      , "name" .= scopeKindName scope
      , "networking"
          .= object
            [ "apiServerAddress" .= ("127.0.0.1" :: Text.Text)
            , "apiServerPort" .= scopeApiPort scope
            -- The default CNI is kindnet from the pinned node image: it needs no
            -- external pull and was observed to enforce NetworkPolicy with real
            -- sockets. disableDefaultCNI is therefore deliberately absent.
            ]
      , "nodes"
          .= [ object
                 [ "role" .= ("control-plane" :: Text.Text)
                 , "image" .= image
                 , "extraMounts"
                     .= [object ["hostPath" .= scopeRoot scope, "containerPath" .= ("/var/lib/prodbox" :: Text.Text)]]
                 , "extraPortMappings" .= map renderMapping [httpMapping plan, httpsMapping plan]
                 ]
             ]
      ]
 where
  scope = kindPlanScope plan
  renderMapping mapping =
    object
      [ "hostPort" .= publicationHostPort mapping
      , "containerPort" .= publicationNodePort mapping
      , "listenAddress" .= ipLiteralText (publicationListenAddress mapping)
      , "protocol" .= ("TCP" :: Text.Text)
      ]
