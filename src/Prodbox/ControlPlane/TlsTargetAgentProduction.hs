{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production selected-Agent binding for the exact public-edge TLS Secret
-- and the cluster-local side of the TLS DEK exchange. Kubernetes access uses
-- the Pod ServiceAccount and the in-cluster API CA; DEK/private-token wrapping
-- uses only the compiled Target Agent Transit key.
module Prodbox.ControlPlane.TlsTargetAgentProduction
  ( publicEdgeTlsSecretNamespace
  , publicEdgeTlsSecretName
  , tlsRetentionDekTransitKey
  , tlsTargetAgentProductionBoundaries
  , tlsPublicEdgeSecretBoundary
  , TlsSecretApplyDecision (..)
  , decideTlsSecretApply
  , tlsDekVaultBoundary
  , parseTlsPublicEdgeSecret
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson
  ( Value
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.Hourglass (Elapsed (Elapsed), timeGetElapsed)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.PEM (PEM (pemContent, pemName), pemParseBS)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.X509 (Certificate)
import Data.X509 qualified as X509
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekTransitBoundary (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsPublicEdgeSecret
  , TlsSecretBoundary (..)
  , TlsSecretObservation (..)
  , mkTlsPublicEdgeSecret
  , tlsPublicEdgeSecretAnnotations
  , tlsPublicEdgeSecretCertificate
  , tlsPublicEdgeSecretData
  , tlsPublicEdgeSecretType
  )
import Prodbox.Http.Client (HttpError)
import Prodbox.K8s.InCluster
  ( K8sSecretOps (..)
  , inClusterK8sSecretOps
  , loadInClusterCredentials
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (..)
  , SourceSecretRef (..)
  )
import Prodbox.Vault.Client
  ( VaultToken
  , vaultTransitDecrypt
  , vaultTransitEncrypt
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

publicEdgeTlsSecretNamespace :: Text
publicEdgeTlsSecretNamespace = "vscode"

publicEdgeTlsSecretName :: Text
publicEdgeTlsSecretName = "public-edge-tls"

tlsRetentionDekTransitKey :: Text
tlsRetentionDekTransitKey = "prodbox-tls-retention-dek"

tlsTargetAgentProductionBoundaries
  :: VaultSession
  -> IO (Either Text (TlsSecretBoundary IO, TlsDekTransitBoundary IO))
tlsTargetAgentProductionBoundaries session = do
  credentials <- loadInClusterCredentials
  case credentials of
    Left detail -> pure (Left (Text.pack detail))
    Right inCluster -> do
      operations <- inClusterK8sSecretOps inCluster
      pure $ do
        secretOps <- mapLeft Text.pack operations
        Right
          ( tlsPublicEdgeSecretBoundary secretOps
          , tlsDekVaultBoundary session
          )

tlsPublicEdgeSecretBoundary :: K8sSecretOps -> TlsSecretBoundary IO
tlsPublicEdgeSecretBoundary operations =
  TlsSecretBoundary
    { readExactPublicEdgeTlsSecret = readExact
    , applyExactPublicEdgeTlsSecret = applyExact
    }
 where
  readExact = do
    result <- secretOpsGet operations publicEdgeTlsSecretNamespace publicEdgeTlsSecretName
    pure $ case result of
      Left detail -> Left (Text.pack detail)
      Right Nothing -> Right TlsSecretMissing
      Right (Just value) -> case parseTlsPublicEdgeSecret value of
        Left detail -> Right (TlsSecretCorrupt detail)
        Right secret -> Right (TlsSecretPresent secret)

  applyExact secret = do
    existing <- readExact
    case decideTlsSecretApply secret existing of
      TlsSecretApplyFailed detail -> pure (Left detail)
      TlsSecretApplyIdempotent observed -> pure (Right observed)
      TlsSecretApplyCreate -> do
        applied <-
          secretOpsPut
            operations
            publicEdgeTlsSecretNamespace
            publicEdgeTlsSecretName
            (tlsPublicEdgeSecretManifest secret)
        case applied of
          Left detail -> pure (Left (Text.pack detail))
          Right () -> do
            readBack <- readExact
            pure $ case readBack of
              Left detail -> Left detail
              Right (TlsSecretPresent observed)
                | tlsSecretContent observed == tlsSecretContent secret -> Right observed
                | otherwise -> Left "restored public-edge TLS Secret differs on read-back"
              Right TlsSecretMissing -> Left "restored public-edge TLS Secret is absent on read-back"
              Right (TlsSecretCorrupt detail) ->
                Left ("restored public-edge TLS Secret is corrupt: " <> detail)

data TlsSecretApplyDecision
  = TlsSecretApplyCreate
  | TlsSecretApplyIdempotent !TlsPublicEdgeSecret
  | TlsSecretApplyFailed !Text
  deriving stock (Eq, Show)

decideTlsSecretApply
  :: TlsPublicEdgeSecret
  -> Either Text TlsSecretObservation
  -> TlsSecretApplyDecision
decideTlsSecretApply desired observed = case observed of
  Left detail -> TlsSecretApplyFailed detail
  Right TlsSecretMissing -> TlsSecretApplyCreate
  Right (TlsSecretCorrupt detail) ->
    TlsSecretApplyFailed ("public-edge TLS Secret already exists but is corrupt: " <> detail)
  Right (TlsSecretPresent existing)
    | tlsSecretContent existing == tlsSecretContent desired ->
        TlsSecretApplyIdempotent existing
    | otherwise ->
        TlsSecretApplyFailed "public-edge TLS Secret already exists with different retained content"

tlsSecretContent
  :: TlsPublicEdgeSecret
  -> (CertIdentity, Text, Map Text Text, Map Text Text)
tlsSecretContent secret =
  ( tlsPublicEdgeSecretCertificate secret
  , tlsPublicEdgeSecretType secret
  , tlsPublicEdgeSecretData secret
  , tlsPublicEdgeSecretAnnotations secret
  )

tlsDekVaultBoundary :: VaultSession -> TlsDekTransitBoundary IO
tlsDekVaultBoundary session =
  TlsDekTransitBoundary
    { tlsDekTransitEncrypt = \plaintext ->
        vaultSessionCall
          session
          (\token -> vaultTransitEncrypt (sessionAddress session) token tlsRetentionDekTransitKey plaintext)
    , tlsDekTransitDecrypt = \ciphertext ->
        vaultSessionCall
          session
          (\token -> vaultTransitDecrypt (sessionAddress session) token tlsRetentionDekTransitKey ciphertext)
    }

parseTlsPublicEdgeSecret :: Value -> Either Text TlsPublicEdgeSecret
parseTlsPublicEdgeSecret value = do
  wire <- mapLeft Text.pack (parseEither parseWire value)
  certificateBytes <-
    mapLeft
      (const "public-edge tls.crt is not valid base64")
      (Base64.decode (TextEncoding.encodeUtf8 (wireTlsCertificate wire)))
  certificate <- parseCertificateIdentity certificateBytes
  mkTlsPublicEdgeSecret
    (SourceSecretRef (wireTlsUid wire) (wireTlsResourceVersion wire))
    certificate
    (wireTlsType wire)
    (wireTlsData wire)
    (wireTlsAnnotations wire)

data WireTlsSecret = WireTlsSecret
  { wireTlsUid :: !Text
  , wireTlsResourceVersion :: !Text
  , wireTlsType :: !Text
  , wireTlsData :: !(Map Text Text)
  , wireTlsAnnotations :: !(Map Text Text)
  , wireTlsCertificate :: !Text
  }

parseWire :: Value -> Parser WireTlsSecret
parseWire = withObject "public-edge TLS Secret" $ \secret -> do
  secretType <- secret .: "type"
  secretData <- secret .: "data"
  metadata <- secret .: "metadata"
  withObject
    "public-edge TLS Secret metadata"
    ( \meta -> do
        uid <- meta .: "uid"
        resourceVersion <- meta .: "resourceVersion"
        annotations <- fromMaybe Map.empty <$> meta .:? "annotations"
        certificate <- case Map.lookup "tls.crt" secretData of
          Nothing -> fail "public-edge TLS Secret is missing data.tls.crt"
          Just encoded -> pure encoded
        pure
          WireTlsSecret
            { wireTlsUid = uid
            , wireTlsResourceVersion = resourceVersion
            , wireTlsType = secretType
            , wireTlsData = secretData
            , wireTlsAnnotations = Map.filterWithKey isCertManagerAnnotation annotations
            , wireTlsCertificate = certificate
            }
    )
    metadata

tlsPublicEdgeSecretManifest :: TlsPublicEdgeSecret -> Value
tlsPublicEdgeSecretManifest secret =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Secret" :: Text)
    , "metadata"
        .= object
          [ "name" .= publicEdgeTlsSecretName
          , "namespace" .= publicEdgeTlsSecretNamespace
          , "labels"
              .= object
                [ "prodbox.io/retained-secret" .= publicEdgeTlsSecretName
                ]
          , "annotations" .= textMapObject (tlsPublicEdgeSecretAnnotations secret)
          ]
    , "type" .= tlsPublicEdgeSecretType secret
    , "data" .= textMapObject (tlsPublicEdgeSecretData secret)
    ]

textMapObject :: Map Text Text -> Value
textMapObject values =
  object [Key.fromText name .= value | (name, value) <- Map.toAscList values]

parseCertificateIdentity :: ByteString -> Either Text CertIdentity
parseCertificateIdentity certificateBytes = do
  pems <- mapLeft Text.pack (pemParseBS certificateBytes)
  pem <- case filter ((== "CERTIFICATE") . pemName) pems of
    [] -> Left "public-edge tls.crt contains no CERTIFICATE PEM block"
    firstCertificate : _ -> Right firstCertificate
  signed <- mapLeft Text.pack (X509.decodeSignedCertificate (pemContent pem))
  let certificate = X509.getCertificate signed
      Elapsed notAfterSeconds = timeGetElapsed (snd (X509.certValidity certificate))
      notAfterInteger = toInteger notAfterSeconds
  if notAfterInteger <= 0
    then Left "public-edge certificate has an invalid notAfter"
    else
      Right
        ( CertIdentity
            (Text.pack (show (X509.certSerial certificate)))
            (certificatePublicKeyDigest certificate)
            (fromInteger notAfterInteger)
        )

certificatePublicKeyDigest :: Certificate -> Text
certificatePublicKeyDigest certificate =
  TextEncoding.decodeUtf8
    (hexSha256 (TextEncoding.encodeUtf8 (Text.pack (show (X509.certPubKey certificate)))))

isCertManagerAnnotation :: Text -> Text -> Bool
isCertManagerAnnotation name _ = "cert-manager.io/" `Text.isPrefixOf` name

vaultSessionCall
  :: VaultSession
  -> (VaultToken -> IO (Either HttpError value))
  -> IO (Either Text value)
vaultSessionCall session action = do
  attempted <- catchVaultSession (withSessionToken session action)
  pure $ case attempted of
    Left _ -> Left "TLS DEK Vault session is unavailable"
    Right (Left _) -> Left "TLS DEK Transit operation failed"
    Right (Right value) -> Right value

catchVaultSession
  :: IO (Either HttpError value)
  -> IO (Either SomeException (Either HttpError value))
catchVaultSession = try

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f = either (Left . f) Right
