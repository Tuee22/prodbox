{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact public-edge TLS Secret lane owned by a selected Target Secret
-- Agent. Requests carry no namespace, Secret name, Kubernetes path, Vault
-- path, or plaintext. Retention seals a validated exact Secret under a fresh
-- DEK and encrypts that DEK only to the retained-home Agent. Restore accepts
-- only the Authority-committed reference and applies/read-backs the exact
-- decoded Secret.
module Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsPublicEdgeSecret
  , TlsSecretObservation (..)
  , TlsSecretBoundary (..)
  , TlsTargetPrepareResult (..)
  , TlsTargetRetainRequest (..)
  , TlsTargetRetainReceipt (..)
  , TlsTargetRetainResult (..)
  , TlsHomeWrapRequest (..)
  , TlsHomeWrapResult (..)
  , TlsHomeRewrapRequest (..)
  , TlsHomeRewrapResult (..)
  , TlsTargetRestoreRequest (..)
  , TlsTargetRestoreReceipt (..)
  , TlsTargetRestoreResult (..)
  , TlsTargetVerifyRequest (..)
  , TlsTargetVerifyReceipt (..)
  , TlsTargetVerifyResult (..)
  , TlsTargetAgentError (..)
  , tlsTargetMaximumRequestBytes
  , mkTlsPublicEdgeSecret
  , tlsPublicEdgeSecretSource
  , tlsPublicEdgeSecretCertificate
  , tlsPublicEdgeSecretType
  , tlsPublicEdgeSecretData
  , tlsPublicEdgeSecretAnnotations
  , prepareTlsTargetExchange
  , retainTlsAtSelectedAgent
  , wrapTlsDekAtHomeAgent
  , rewrapTlsDekAtHomeAgent
  , restoreTlsAtSelectedAgent
  , verifyTlsSourceAtSelectedAgent
  , serveTlsTargetPrepareRequest
  , serveTlsTargetRetainRequest
  , serveTlsHomeWrapRequest
  , serveTlsHomeRewrapRequest
  , serveTlsTargetRestoreRequest
  , serveTlsTargetVerifyRequest
  , tlsTargetPrepareHttpStatus
  , tlsTargetPrepareResponseBody
  , tlsTargetRetainHttpStatus
  , tlsTargetRetainResponseBody
  , tlsHomeWrapHttpStatus
  , tlsHomeWrapResponseBody
  , tlsHomeRewrapHttpStatus
  , tlsHomeRewrapResponseBody
  , tlsTargetRestoreHttpStatus
  , tlsTargetRestoreResponseBody
  , tlsTargetVerifyHttpStatus
  , tlsTargetVerifyResponseBody
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekEnvelope
  , TlsDekExchangeError
  , TlsDekPrepared
  , TlsDekPublicKey
  , TlsDekTransitBoundary
  , TlsWrappedDek
  , openTlsDekAtDestination
  , prepareTlsDekExchange
  , rewrapTlsDekFromRetainedHome
  , sealTlsDekForDestination
  , wrapTlsDekAtRetainedHome
  )
import Prodbox.Crypto.Aead
  ( AeadError
  , aeadNonceBytes
  , openAead
  , sealAead
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (..)
  , RetainedTlsRef (..)
  , RetentionVersion
  , SourceSecretRef (..)
  )

data TlsPublicEdgeSecret = TlsPublicEdgeSecret
  { internalTlsPublicEdgeSecretSource :: !SourceSecretRef
  , internalTlsPublicEdgeSecretCertificate :: !CertIdentity
  , internalTlsPublicEdgeSecretType :: !Text
  , internalTlsPublicEdgeSecretData :: !(Map Text Text)
  , internalTlsPublicEdgeSecretAnnotations :: !(Map Text Text)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TlsPublicEdgeSecret where
  show secret =
    "<tls-public-edge-secret:fields="
      <> show (Map.size (tlsPublicEdgeSecretData secret))
      <> ",annotations="
      <> show (Map.size (tlsPublicEdgeSecretAnnotations secret))
      <> ">"

data TlsSecretObservation
  = TlsSecretMissing
  | TlsSecretPresent !TlsPublicEdgeSecret
  | TlsSecretCorrupt !Text
  deriving stock (Eq, Show)

data TlsSecretBoundary m = TlsSecretBoundary
  { readExactPublicEdgeTlsSecret :: m (Either Text TlsSecretObservation)
  , applyExactPublicEdgeTlsSecret
      :: TlsPublicEdgeSecret
      -> m (Either Text TlsPublicEdgeSecret)
  }

data TlsTargetPrepareResult
  = TlsTargetPrepared !TlsDekPrepared
  | TlsTargetPrepareFailed !TlsTargetAgentError
  | TlsTargetPrepareBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

data TlsTargetRetainRequest = TlsTargetRetainRequest
  { tlsTargetRetainVersion :: !RetentionVersion
  , tlsTargetRetainHomePublicKey :: !TlsDekPublicKey
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsTargetRetainReceipt = TlsTargetRetainReceipt
  { tlsTargetRetainedVersion :: !RetentionVersion
  , tlsTargetRetainedCertificate :: !CertIdentity
  , tlsTargetRetainedSource :: !SourceSecretRef
  , tlsTargetRetainedCertificateCiphertext :: !ByteString
  , tlsTargetRetainedDekEnvelope :: !TlsDekEnvelope
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TlsTargetRetainReceipt where
  show receipt =
    "<tls-target-retain-receipt:ciphertext="
      <> show (ByteString.length (tlsTargetRetainedCertificateCiphertext receipt))
      <> " bytes>"

data TlsTargetRetainResult
  = TlsTargetRetained !TlsTargetRetainReceipt
  | TlsTargetRetainMissing
  | TlsTargetRetainFailed !TlsTargetAgentError
  | TlsTargetRetainBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

data TlsHomeWrapRequest = TlsHomeWrapRequest
  { tlsHomeWrapPrepared :: !TlsDekPrepared
  , tlsHomeWrapEnvelope :: !TlsDekEnvelope
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsHomeWrapResult
  = TlsHomeWrapped !TlsWrappedDek
  | TlsHomeWrapFailed !TlsTargetAgentError
  | TlsHomeWrapBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

data TlsHomeRewrapRequest = TlsHomeRewrapRequest
  { tlsHomeRewrapWrappedDek :: !TlsWrappedDek
  , tlsHomeRewrapTargetPublicKey :: !TlsDekPublicKey
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsHomeRewrapResult
  = TlsHomeRewrapped !TlsDekEnvelope
  | TlsHomeRewrapFailed !TlsTargetAgentError
  | TlsHomeRewrapBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

data TlsTargetRestoreRequest = TlsTargetRestoreRequest
  { tlsTargetRestoreReference :: !RetainedTlsRef
  , tlsTargetRestorePrepared :: !TlsDekPrepared
  , tlsTargetRestoreDekEnvelope :: !TlsDekEnvelope
  , tlsTargetRestoreCertificateCiphertext :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsTargetRestoreReceipt = TlsTargetRestoreReceipt
  { tlsTargetRestoredReference :: !RetainedTlsRef
  , tlsTargetRestoredReadBackSource :: !SourceSecretRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsTargetRestoreResult
  = TlsTargetRestored !TlsTargetRestoreReceipt
  | TlsTargetRestoreFailed !TlsTargetAgentError
  | TlsTargetRestoreBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

newtype TlsTargetVerifyRequest = TlsTargetVerifyRequest
  { tlsTargetVerifyReference :: RetainedTlsRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsTargetVerifyReceipt = TlsTargetVerifyReceipt
  { tlsTargetVerifiedCertificate :: !CertIdentity
  , tlsTargetVerifiedSource :: !SourceSecretRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsTargetVerifyResult
  = TlsTargetSourceVerified !TlsTargetVerifyReceipt
  | TlsTargetVerifyMissing
  | TlsTargetVerifyMismatch
  | TlsTargetVerifyFailed !TlsTargetAgentError
  | TlsTargetVerifyBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

data TlsTargetAgentError
  = TlsTargetSecretUnavailable
  | TlsTargetSecretInvalid
  | TlsTargetSecretReadBackMismatch
  | TlsTargetSecretApplyFailed
  | TlsTargetDekExchangeFailed !TlsDekExchangeError
  | TlsTargetCipherFailed !AeadError
  | TlsTargetCertificateCiphertextInvalid
  | TlsTargetCertificateCiphertextTooLarge !Int !Int
  | TlsTargetReferenceMismatch
  deriving stock (Eq, Show)

data WireTlsCertificateCiphertext = WireTlsCertificateCiphertext
  { wireTlsCertificateVersion :: !Word16
  , wireTlsCertificateNonce :: !ByteString
  , wireTlsCertificateCiphertext :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

tlsTargetMaximumRequestBytes :: Int
tlsTargetMaximumRequestBytes = 2 * 1024 * 1024

tlsCertificateCiphertextMaximumBytes :: Int
tlsCertificateCiphertextMaximumBytes = 768 * 1024

tlsSecretMaximumEncodedBytes :: Int
tlsSecretMaximumEncodedBytes = 700 * 1024

tlsCertificateCiphertextVersion :: Word16
tlsCertificateCiphertextVersion = 1

mkTlsPublicEdgeSecret
  :: SourceSecretRef
  -> CertIdentity
  -> Text
  -> Map Text Text
  -> Map Text Text
  -> Either Text TlsPublicEdgeSecret
mkTlsPublicEdgeSecret source certificate secretType secretData annotations = do
  validateSource source
  validateCertificate certificate
  if secretType /= "kubernetes.io/tls"
    then Left "public-edge Secret type must be kubernetes.io/tls"
    else pure ()
  validateSecretData secretData
  validateAnnotations annotations
  let secret =
        TlsPublicEdgeSecret
          { internalTlsPublicEdgeSecretSource = source
          , internalTlsPublicEdgeSecretCertificate = certificate
          , internalTlsPublicEdgeSecretType = secretType
          , internalTlsPublicEdgeSecretData = secretData
          , internalTlsPublicEdgeSecretAnnotations = annotations
          }
      encoded = LazyByteString.toStrict (serialise secret)
  if ByteString.length encoded > tlsSecretMaximumEncodedBytes
    then Left "public-edge TLS Secret exceeds the compiled bound"
    else Right secret

tlsPublicEdgeSecretSource :: TlsPublicEdgeSecret -> SourceSecretRef
tlsPublicEdgeSecretSource = internalTlsPublicEdgeSecretSource

tlsPublicEdgeSecretCertificate :: TlsPublicEdgeSecret -> CertIdentity
tlsPublicEdgeSecretCertificate = internalTlsPublicEdgeSecretCertificate

tlsPublicEdgeSecretType :: TlsPublicEdgeSecret -> Text
tlsPublicEdgeSecretType = internalTlsPublicEdgeSecretType

tlsPublicEdgeSecretData :: TlsPublicEdgeSecret -> Map Text Text
tlsPublicEdgeSecretData = internalTlsPublicEdgeSecretData

tlsPublicEdgeSecretAnnotations :: TlsPublicEdgeSecret -> Map Text Text
tlsPublicEdgeSecretAnnotations = internalTlsPublicEdgeSecretAnnotations

prepareTlsTargetExchange
  :: TlsDekTransitBoundary IO
  -> IO TlsTargetPrepareResult
prepareTlsTargetExchange transit =
  either TlsTargetPrepareFailed TlsTargetPrepared
    . first TlsTargetDekExchangeFailed
    <$> prepareTlsDekExchange transit

retainTlsAtSelectedAgent
  :: TlsSecretBoundary IO
  -> RetentionVersion
  -> TlsDekPublicKey
  -> IO TlsTargetRetainResult
retainTlsAtSelectedAgent secretBoundary version homePublicKey = do
  observed <- readExactPublicEdgeTlsSecret secretBoundary
  case observed of
    Left _ -> pure (TlsTargetRetainFailed TlsTargetSecretUnavailable)
    Right TlsSecretMissing -> pure TlsTargetRetainMissing
    Right (TlsSecretCorrupt _) -> pure (TlsTargetRetainFailed TlsTargetSecretInvalid)
    Right (TlsSecretPresent secret) -> do
      dek <- getRandomBytes 32
      nonce <- getRandomBytes aeadNonceBytes
      let plaintext = LazyByteString.toStrict (serialise secret)
          aad = tlsSecretAad version (tlsPublicEdgeSecretCertificate secret) (tlsPublicEdgeSecretSource secret)
      case sealAead dek nonce aad plaintext of
        Left err -> pure (TlsTargetRetainFailed (TlsTargetCipherFailed err))
        Right sealed -> do
          let encodedCiphertext =
                LazyByteString.toStrict
                  ( serialise
                      WireTlsCertificateCiphertext
                        { wireTlsCertificateVersion = tlsCertificateCiphertextVersion
                        , wireTlsCertificateNonce = nonce
                        , wireTlsCertificateCiphertext = sealed
                        }
                  )
          if ByteString.length encodedCiphertext > tlsCertificateCiphertextMaximumBytes
            then
              pure
                ( TlsTargetRetainFailed
                    ( TlsTargetCertificateCiphertextTooLarge
                        (ByteString.length encodedCiphertext)
                        tlsCertificateCiphertextMaximumBytes
                    )
                )
            else do
              exchanged <- sealTlsDekForDestination homePublicKey dek
              pure $ case exchanged of
                Left err -> TlsTargetRetainFailed (TlsTargetDekExchangeFailed err)
                Right envelope ->
                  TlsTargetRetained
                    TlsTargetRetainReceipt
                      { tlsTargetRetainedVersion = version
                      , tlsTargetRetainedCertificate = tlsPublicEdgeSecretCertificate secret
                      , tlsTargetRetainedSource = tlsPublicEdgeSecretSource secret
                      , tlsTargetRetainedCertificateCiphertext = encodedCiphertext
                      , tlsTargetRetainedDekEnvelope = envelope
                      }

wrapTlsDekAtHomeAgent
  :: TlsDekTransitBoundary IO
  -> TlsDekPrepared
  -> TlsDekEnvelope
  -> IO TlsHomeWrapResult
wrapTlsDekAtHomeAgent transit prepared envelope =
  either (TlsHomeWrapFailed . TlsTargetDekExchangeFailed) TlsHomeWrapped
    <$> wrapTlsDekAtRetainedHome transit prepared envelope

rewrapTlsDekAtHomeAgent
  :: TlsDekTransitBoundary IO
  -> TlsWrappedDek
  -> TlsDekPublicKey
  -> IO TlsHomeRewrapResult
rewrapTlsDekAtHomeAgent transit wrapped targetPublicKey =
  either (TlsHomeRewrapFailed . TlsTargetDekExchangeFailed) TlsHomeRewrapped
    <$> rewrapTlsDekFromRetainedHome transit wrapped targetPublicKey

restoreTlsAtSelectedAgent
  :: TlsSecretBoundary IO
  -> TlsDekTransitBoundary IO
  -> RetainedTlsRef
  -> TlsDekPrepared
  -> TlsDekEnvelope
  -> ByteString
  -> IO TlsTargetRestoreResult
restoreTlsAtSelectedAgent secretBoundary transit reference prepared dekEnvelope certificateCiphertext = do
  openedDek <- openTlsDekAtDestination transit prepared dekEnvelope
  case openedDek of
    Left err -> pure (TlsTargetRestoreFailed (TlsTargetDekExchangeFailed err))
    Right dek -> case decodeCertificateCiphertext certificateCiphertext of
      Left err -> pure (TlsTargetRestoreFailed err)
      Right wire ->
        case openAead
          dek
          (wireTlsCertificateNonce wire)
          (tlsSecretAad (retainedVersion reference) (retainedCert reference) (retainedSourceSecret reference))
          (wireTlsCertificateCiphertext wire) of
          Left err -> pure (TlsTargetRestoreFailed (TlsTargetCipherFailed err))
          Right plaintext -> case decodeTlsPublicEdgeSecret plaintext of
            Left err -> pure (TlsTargetRestoreFailed err)
            Right secret
              | tlsPublicEdgeSecretCertificate secret /= retainedCert reference
                  || tlsPublicEdgeSecretSource secret /= retainedSourceSecret reference ->
                  pure (TlsTargetRestoreFailed TlsTargetReferenceMismatch)
              | otherwise -> do
                  applied <- applyExactPublicEdgeTlsSecret secretBoundary secret
                  pure $ case applied of
                    Left _ -> TlsTargetRestoreFailed TlsTargetSecretApplyFailed
                    Right readBack
                      | secretContent readBack /= secretContent secret ->
                          TlsTargetRestoreFailed TlsTargetSecretReadBackMismatch
                      | otherwise ->
                          TlsTargetRestored
                            TlsTargetRestoreReceipt
                              { tlsTargetRestoredReference = reference
                              , tlsTargetRestoredReadBackSource = tlsPublicEdgeSecretSource readBack
                              }

-- | Re-read the exact selected-cluster Secret after the Adapter has confirmed
-- its immutable envelope.  Promotion evidence is therefore about the same
-- Kubernetes UID/resourceVersion and certificate identity that was sealed,
-- rather than merely trusting the first read performed during sealing.
verifyTlsSourceAtSelectedAgent
  :: TlsSecretBoundary IO
  -> RetainedTlsRef
  -> IO TlsTargetVerifyResult
verifyTlsSourceAtSelectedAgent secretBoundary reference = do
  observed <- readExactPublicEdgeTlsSecret secretBoundary
  pure $ case observed of
    Left _ -> TlsTargetVerifyFailed TlsTargetSecretUnavailable
    Right TlsSecretMissing -> TlsTargetVerifyMissing
    Right (TlsSecretCorrupt _) -> TlsTargetVerifyFailed TlsTargetSecretInvalid
    Right (TlsSecretPresent secret)
      | tlsPublicEdgeSecretSource secret /= retainedSourceSecret reference
          || tlsPublicEdgeSecretCertificate secret /= retainedCert reference ->
          TlsTargetVerifyMismatch
      | otherwise ->
          TlsTargetSourceVerified
            TlsTargetVerifyReceipt
              { tlsTargetVerifiedCertificate = tlsPublicEdgeSecretCertificate secret
              , tlsTargetVerifiedSource = tlsPublicEdgeSecretSource secret
              }

serveTlsTargetPrepareRequest
  :: Int
  -> TlsDekTransitBoundary IO
  -> LazyByteString.ByteString
  -> IO TlsTargetPrepareResult
serveTlsTargetPrepareRequest maximumBytes transit body =
  case decodeControlPlaneRequest maximumBytes body :: Either ControlPlaneRequestCodecError () of
    Left err -> pure (TlsTargetPrepareBadRequest err)
    Right () -> prepareTlsTargetExchange transit

serveTlsTargetRetainRequest
  :: Int
  -> TlsSecretBoundary IO
  -> LazyByteString.ByteString
  -> IO TlsTargetRetainResult
serveTlsTargetRetainRequest maximumBytes boundary body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsTargetRetainBadRequest err)
    Right request ->
      retainTlsAtSelectedAgent
        boundary
        (tlsTargetRetainVersion request)
        (tlsTargetRetainHomePublicKey request)

serveTlsHomeWrapRequest
  :: Int
  -> TlsDekTransitBoundary IO
  -> LazyByteString.ByteString
  -> IO TlsHomeWrapResult
serveTlsHomeWrapRequest maximumBytes transit body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsHomeWrapBadRequest err)
    Right request ->
      wrapTlsDekAtHomeAgent transit (tlsHomeWrapPrepared request) (tlsHomeWrapEnvelope request)

serveTlsHomeRewrapRequest
  :: Int
  -> TlsDekTransitBoundary IO
  -> LazyByteString.ByteString
  -> IO TlsHomeRewrapResult
serveTlsHomeRewrapRequest maximumBytes transit body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsHomeRewrapBadRequest err)
    Right request ->
      rewrapTlsDekAtHomeAgent
        transit
        (tlsHomeRewrapWrappedDek request)
        (tlsHomeRewrapTargetPublicKey request)

serveTlsTargetRestoreRequest
  :: Int
  -> TlsSecretBoundary IO
  -> TlsDekTransitBoundary IO
  -> LazyByteString.ByteString
  -> IO TlsTargetRestoreResult
serveTlsTargetRestoreRequest maximumBytes secretBoundary transit body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsTargetRestoreBadRequest err)
    Right request ->
      restoreTlsAtSelectedAgent
        secretBoundary
        transit
        (tlsTargetRestoreReference request)
        (tlsTargetRestorePrepared request)
        (tlsTargetRestoreDekEnvelope request)
        (tlsTargetRestoreCertificateCiphertext request)

serveTlsTargetVerifyRequest
  :: Int
  -> TlsSecretBoundary IO
  -> LazyByteString.ByteString
  -> IO TlsTargetVerifyResult
serveTlsTargetVerifyRequest maximumBytes secretBoundary body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsTargetVerifyBadRequest err)
    Right request ->
      verifyTlsSourceAtSelectedAgent
        secretBoundary
        (tlsTargetVerifyReference request)

tlsTargetPrepareHttpStatus :: TlsTargetPrepareResult -> ReplyStatus
tlsTargetPrepareHttpStatus result = case result of
  TlsTargetPrepared _ -> ReplyOk
  TlsTargetPrepareFailed _ -> ReplyServiceUnavailable
  TlsTargetPrepareBadRequest _ -> ReplyBadRequest

tlsTargetPrepareResponseBody :: TlsTargetPrepareResult -> ByteString
tlsTargetPrepareResponseBody result = case result of
  TlsTargetPrepared prepared -> strictResponse prepared
  TlsTargetPrepareFailed _ -> "tls-target-prepare:failed"
  TlsTargetPrepareBadRequest err ->
    TextEncoding.encodeUtf8 ("tls-target-prepare:bad-request:" <> controlPlaneRequestCodecToken err)

tlsTargetRetainHttpStatus :: TlsTargetRetainResult -> ReplyStatus
tlsTargetRetainHttpStatus result = case result of
  TlsTargetRetained _ -> ReplyOk
  TlsTargetRetainMissing -> ReplyNotFound
  TlsTargetRetainFailed TlsTargetSecretUnavailable -> ReplyServiceUnavailable
  TlsTargetRetainFailed _ -> ReplyConflict
  TlsTargetRetainBadRequest _ -> ReplyBadRequest

tlsTargetRetainResponseBody :: TlsTargetRetainResult -> ByteString
tlsTargetRetainResponseBody result = case result of
  TlsTargetRetained receipt -> strictResponse receipt
  TlsTargetRetainMissing -> "tls-target-retain:missing"
  TlsTargetRetainFailed _ -> "tls-target-retain:failed"
  TlsTargetRetainBadRequest err ->
    TextEncoding.encodeUtf8 ("tls-target-retain:bad-request:" <> controlPlaneRequestCodecToken err)

tlsHomeWrapHttpStatus :: TlsHomeWrapResult -> ReplyStatus
tlsHomeWrapHttpStatus result = case result of
  TlsHomeWrapped _ -> ReplyOk
  TlsHomeWrapFailed _ -> ReplyConflict
  TlsHomeWrapBadRequest _ -> ReplyBadRequest

tlsHomeWrapResponseBody :: TlsHomeWrapResult -> ByteString
tlsHomeWrapResponseBody result = case result of
  TlsHomeWrapped wrapped -> strictResponse wrapped
  TlsHomeWrapFailed _ -> "tls-home-wrap:failed"
  TlsHomeWrapBadRequest err ->
    TextEncoding.encodeUtf8 ("tls-home-wrap:bad-request:" <> controlPlaneRequestCodecToken err)

tlsHomeRewrapHttpStatus :: TlsHomeRewrapResult -> ReplyStatus
tlsHomeRewrapHttpStatus result = case result of
  TlsHomeRewrapped _ -> ReplyOk
  TlsHomeRewrapFailed _ -> ReplyConflict
  TlsHomeRewrapBadRequest _ -> ReplyBadRequest

tlsHomeRewrapResponseBody :: TlsHomeRewrapResult -> ByteString
tlsHomeRewrapResponseBody result = case result of
  TlsHomeRewrapped envelope -> strictResponse envelope
  TlsHomeRewrapFailed _ -> "tls-home-rewrap:failed"
  TlsHomeRewrapBadRequest err ->
    TextEncoding.encodeUtf8 ("tls-home-rewrap:bad-request:" <> controlPlaneRequestCodecToken err)

tlsTargetRestoreHttpStatus :: TlsTargetRestoreResult -> ReplyStatus
tlsTargetRestoreHttpStatus result = case result of
  TlsTargetRestored _ -> ReplyOk
  TlsTargetRestoreFailed TlsTargetSecretApplyFailed -> ReplyServiceUnavailable
  TlsTargetRestoreFailed TlsTargetSecretUnavailable -> ReplyServiceUnavailable
  TlsTargetRestoreFailed _ -> ReplyConflict
  TlsTargetRestoreBadRequest _ -> ReplyBadRequest

tlsTargetRestoreResponseBody :: TlsTargetRestoreResult -> ByteString
tlsTargetRestoreResponseBody result = case result of
  TlsTargetRestored receipt -> strictResponse receipt
  TlsTargetRestoreFailed _ -> "tls-target-restore:failed"
  TlsTargetRestoreBadRequest err ->
    TextEncoding.encodeUtf8 ("tls-target-restore:bad-request:" <> controlPlaneRequestCodecToken err)

tlsTargetVerifyHttpStatus :: TlsTargetVerifyResult -> ReplyStatus
tlsTargetVerifyHttpStatus result = case result of
  TlsTargetSourceVerified _ -> ReplyOk
  TlsTargetVerifyMissing -> ReplyNotFound
  TlsTargetVerifyMismatch -> ReplyConflict
  TlsTargetVerifyFailed TlsTargetSecretUnavailable -> ReplyServiceUnavailable
  TlsTargetVerifyFailed _ -> ReplyConflict
  TlsTargetVerifyBadRequest _ -> ReplyBadRequest

tlsTargetVerifyResponseBody :: TlsTargetVerifyResult -> ByteString
tlsTargetVerifyResponseBody result = case result of
  TlsTargetSourceVerified receipt -> strictResponse receipt
  TlsTargetVerifyMissing -> "tls-target-verify:missing"
  TlsTargetVerifyMismatch -> "tls-target-verify:mismatch"
  TlsTargetVerifyFailed _ -> "tls-target-verify:failed"
  TlsTargetVerifyBadRequest err ->
    TextEncoding.encodeUtf8 ("tls-target-verify:bad-request:" <> controlPlaneRequestCodecToken err)

strictResponse :: (Serialise value) => value -> ByteString
strictResponse = LazyByteString.toStrict . encodeControlPlaneResponse

decodeCertificateCiphertext
  :: ByteString -> Either TlsTargetAgentError WireTlsCertificateCiphertext
decodeCertificateCiphertext bytes
  | ByteString.length bytes > tlsCertificateCiphertextMaximumBytes =
      Left
        ( TlsTargetCertificateCiphertextTooLarge
            (ByteString.length bytes)
            tlsCertificateCiphertextMaximumBytes
        )
  | otherwise = do
      wire <-
        first
          (const TlsTargetCertificateCiphertextInvalid)
          (deserialiseOrFail (LazyByteString.fromStrict bytes))
      if wireTlsCertificateVersion wire /= tlsCertificateCiphertextVersion
        || LazyByteString.toStrict (serialise wire) /= bytes
        || ByteString.length (wireTlsCertificateNonce wire) /= aeadNonceBytes
        then Left TlsTargetCertificateCiphertextInvalid
        else Right wire

decodeTlsPublicEdgeSecret
  :: ByteString -> Either TlsTargetAgentError TlsPublicEdgeSecret
decodeTlsPublicEdgeSecret bytes
  | ByteString.length bytes > tlsSecretMaximumEncodedBytes =
      Left TlsTargetSecretInvalid
  | otherwise = do
      secret <-
        first
          (const TlsTargetSecretInvalid)
          (deserialiseOrFail (LazyByteString.fromStrict bytes))
      if LazyByteString.toStrict (serialise secret) /= bytes
        then Left TlsTargetSecretInvalid
        else
          first
            (const TlsTargetSecretInvalid)
            ( mkTlsPublicEdgeSecret
                (tlsPublicEdgeSecretSource secret)
                (tlsPublicEdgeSecretCertificate secret)
                (tlsPublicEdgeSecretType secret)
                (tlsPublicEdgeSecretData secret)
                (tlsPublicEdgeSecretAnnotations secret)
            )

tlsSecretAad
  :: RetentionVersion -> CertIdentity -> SourceSecretRef -> ByteString
tlsSecretAad version certificate source =
  LazyByteString.toStrict
    (serialise ("prodbox-public-edge-tls-secret-v1" :: Text, version, certificate, source))

secretContent
  :: TlsPublicEdgeSecret -> (CertIdentity, Text, Map Text Text, Map Text Text)
secretContent secret =
  ( tlsPublicEdgeSecretCertificate secret
  , tlsPublicEdgeSecretType secret
  , tlsPublicEdgeSecretData secret
  , tlsPublicEdgeSecretAnnotations secret
  )

validateSource :: SourceSecretRef -> Either Text ()
validateSource source = do
  validateBoundedText "Secret UID" 512 (sourceSecretUid source)
  validateBoundedText "Secret resourceVersion" 512 (sourceSecretResourceVersion source)

validateCertificate :: CertIdentity -> Either Text ()
validateCertificate certificate = do
  validateBoundedText "certificate serial" 256 (certSerial certificate)
  validateBoundedText "certificate SPKI digest" 128 (certSpkiDigest certificate)
  if certNotAfter certificate == 0
    then Left "certificate notAfter must be positive"
    else Right ()

validateSecretData :: Map Text Text -> Either Text ()
validateSecretData fields = do
  let keys = Map.keysSet fields
      required = Set.fromList ["tls.crt", "tls.key"]
      allowed = Set.insert "ca.crt" required
  if required `Set.isSubsetOf` keys && keys `Set.isSubsetOf` allowed
    then pure ()
    else Left "public-edge TLS Secret has an invalid data field set"
  mapM_ validateField (Map.toList fields)
 where
  validateField (name, encoded) = do
    validateBoundedText ("Secret data field " <> name) (700 * 1024) encoded
    decoded <-
      first
        (const ("Secret data field " <> name <> " is not base64"))
        (Base64.decode (TextEncoding.encodeUtf8 encoded))
    if ByteString.null decoded
      then Left ("Secret data field " <> name <> " is empty")
      else Right ()

validateAnnotations :: Map Text Text -> Either Text ()
validateAnnotations annotations = do
  if Map.size annotations > 16
    then Left "public-edge TLS Secret has too many adoption annotations"
    else pure ()
  mapM_ validateOne (Map.toList annotations)
 where
  validateOne (name, value)
    | not ("cert-manager.io/" `Text.isPrefixOf` name) =
        Left "public-edge TLS Secret contains a non-cert-manager adoption annotation"
    | otherwise = do
        validateBoundedText "certificate adoption annotation name" 256 name
        validateBoundedTextAllowEmpty "certificate adoption annotation value" 4096 value

validateBoundedText :: Text -> Int -> Text -> Either Text ()
validateBoundedText label maximumLength value
  | Text.null value = Left (label <> " must not be empty")
  | Text.any isControl value = Left (label <> " contains a control character")
  | Text.length value > maximumLength = Left (label <> " exceeds the compiled bound")
  | otherwise = Right ()

-- cert-manager renders absent optional SAN and issuer-group lists as exact
-- empty annotation values. They remain bounded and control-character-free.
validateBoundedTextAllowEmpty :: Text -> Int -> Text -> Either Text ()
validateBoundedTextAllowEmpty label maximumLength value
  | Text.any isControl value = Left (label <> " contains a control character")
  | Text.length value > maximumLength = Left (label <> " exceeds the compiled bound")
  | otherwise = Right ()
