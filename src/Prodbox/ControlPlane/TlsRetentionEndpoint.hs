{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed ciphertext-envelope protocol served by the TLS Retention Adapter.
-- Certificate/key plaintext never crosses this boundary.  The Adapter stores
-- only the selected Agent's certificate ciphertext plus the retained-home
-- Transit-wrapped DEK, under the exact configured scope prefix and immutable
-- retention version, then reads the bytes back before returning a receipt.
module Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsSealedEnvelope
  , TlsStorePayload (..)
  , TlsRestorePayload (..)
  , TlsRetentionReceipt (..)
  , TlsEnvelopeObservation (..)
  , TlsRetentionRepository (..)
  , TlsStoreResult (..)
  , TlsRestoreResult (..)
  , tlsMaximumCertificateCiphertextBytes
  , tlsMaximumWrappedDekBytes
  , mkTlsSealedEnvelope
  , tlsCertificateCiphertextBytes
  , tlsWrappedDekBytes
  , tlsSealedEnvelopeDigest
  , validateTlsSealedEnvelope
  , serveTlsStoreRequest
  , serveTlsRestoreRequest
  , tlsStoreHttpStatus
  , tlsStoreSummary
  , tlsRestoreHttpStatus
  , tlsRestoreSummary
  , tlsStoreResponseBody
  , tlsRestoreResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Lifecycle.Authority.TlsRetention (RetainedTlsRef (..))

data TlsSealedEnvelope = TlsSealedEnvelope
  { internalTlsCertificateCiphertext :: !ByteString
  , internalTlsWrappedDek :: !ByteString
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TlsSealedEnvelope where
  show envelope =
    "<tls-sealed-envelope:ciphertext="
      <> show (ByteString.length (tlsCertificateCiphertextBytes envelope))
      <> " bytes,wrapped-dek="
      <> show (ByteString.length (tlsWrappedDekBytes envelope))
      <> " bytes>"

data TlsStorePayload = TlsStorePayload
  { tlsStoreCandidate :: !RetainedTlsRef
  , tlsStoreEnvelope :: !TlsSealedEnvelope
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype TlsRestorePayload = TlsRestorePayload
  { tlsRestoreReference :: RetainedTlsRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsRetentionReceipt = TlsRetentionReceipt
  { tlsRetentionReceiptReference :: !RetainedTlsRef
  , tlsRetentionReceiptEnvelopeDigest :: !Text
  , tlsRetentionReceiptObjectVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsEnvelopeObservation
  = TlsEnvelopeMissing
  | TlsEnvelopePresent !TlsSealedEnvelope !TlsRetentionReceipt
  | TlsEnvelopeCorrupt !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsRetentionRepository m = TlsRetentionRepository
  { storeTlsEnvelope
      :: RetainedTlsRef
      -> TlsSealedEnvelope
      -> m (Either Text TlsRetentionReceipt)
  , restoreTlsEnvelope
      :: RetainedTlsRef
      -> m (Either Text TlsEnvelopeObservation)
  }

data TlsStoreResult
  = TlsStoreSucceeded !TlsRetentionReceipt
  | TlsStoreFailed !Text
  | TlsStoreBadRequest !ControlPlaneRequestCodecError
  | TlsStoreInvalidEnvelope
  | TlsStoreDigestMismatch
  deriving stock (Eq, Show)

data TlsRestoreResult
  = TlsRestoreObserved !TlsEnvelopeObservation
  | TlsRestoreReadFailed !Text
  | TlsRestoreBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

tlsMaximumCertificateCiphertextBytes :: Int
tlsMaximumCertificateCiphertextBytes = 768 * 1024

tlsMaximumWrappedDekBytes :: Int
tlsMaximumWrappedDekBytes = 64 * 1024

mkTlsSealedEnvelope :: ByteString -> ByteString -> Either Text TlsSealedEnvelope
mkTlsSealedEnvelope certificateCiphertext wrappedDek = do
  let envelope = TlsSealedEnvelope certificateCiphertext wrappedDek
  validateTlsSealedEnvelope envelope
  Right envelope

tlsCertificateCiphertextBytes :: TlsSealedEnvelope -> ByteString
tlsCertificateCiphertextBytes = internalTlsCertificateCiphertext

tlsWrappedDekBytes :: TlsSealedEnvelope -> ByteString
tlsWrappedDekBytes = internalTlsWrappedDek

tlsSealedEnvelopeDigest :: TlsSealedEnvelope -> Text
tlsSealedEnvelopeDigest envelope =
  TextEncoding.decodeUtf8
    ( hexSha256
        ( ByteString.intercalate
            "\NUL"
            [ "prodbox-tls-sealed-envelope-v1"
            , lengthBytes (tlsCertificateCiphertextBytes envelope)
            , tlsCertificateCiphertextBytes envelope
            , lengthBytes (tlsWrappedDekBytes envelope)
            , tlsWrappedDekBytes envelope
            ]
        )
    )
 where
  lengthBytes = ByteString8.pack . show . ByteString.length

validateTlsSealedEnvelope :: TlsSealedEnvelope -> Either Text ()
validateTlsSealedEnvelope envelope
  | ByteString.null (tlsCertificateCiphertextBytes envelope) =
      Left "TLS certificate ciphertext must not be empty"
  | ByteString.length (tlsCertificateCiphertextBytes envelope)
      > tlsMaximumCertificateCiphertextBytes =
      Left "TLS certificate ciphertext exceeds the compiled bound"
  | ByteString.null (tlsWrappedDekBytes envelope) =
      Left "TLS wrapped DEK must not be empty"
  | ByteString.length (tlsWrappedDekBytes envelope) > tlsMaximumWrappedDekBytes =
      Left "TLS wrapped DEK exceeds the compiled bound"
  | otherwise = Right ()

serveTlsStoreRequest
  :: (Monad m)
  => Int
  -> TlsRetentionRepository m
  -> LazyByteString.ByteString
  -> m TlsStoreResult
serveTlsStoreRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsStoreBadRequest err)
    Right payload ->
      case validateTlsSealedEnvelope (tlsStoreEnvelope payload) of
        Left _ -> pure TlsStoreInvalidEnvelope
        Right ()
          | retainedCiphertextDigest (tlsStoreCandidate payload)
              /= tlsSealedEnvelopeDigest (tlsStoreEnvelope payload) ->
              pure TlsStoreDigestMismatch
          | otherwise -> do
              stored <-
                storeTlsEnvelope
                  repository
                  (tlsStoreCandidate payload)
                  (tlsStoreEnvelope payload)
              pure $ case stored of
                Left detail -> TlsStoreFailed detail
                Right receipt -> TlsStoreSucceeded receipt

serveTlsRestoreRequest
  :: (Monad m)
  => Int
  -> TlsRetentionRepository m
  -> LazyByteString.ByteString
  -> m TlsRestoreResult
serveTlsRestoreRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsRestoreBadRequest err)
    Right payload -> do
      observed <- restoreTlsEnvelope repository (tlsRestoreReference payload)
      pure $ case observed of
        Left detail -> TlsRestoreReadFailed detail
        Right observation -> TlsRestoreObserved observation

tlsStoreHttpStatus :: TlsStoreResult -> Int
tlsStoreHttpStatus result = case result of
  TlsStoreSucceeded _ -> 200
  TlsStoreFailed _ -> 503
  TlsStoreBadRequest _ -> 400
  TlsStoreInvalidEnvelope -> 400
  TlsStoreDigestMismatch -> 409

tlsStoreSummary :: TlsStoreResult -> Text
tlsStoreSummary result = case result of
  TlsStoreSucceeded _ -> "tls-store:read-back-confirmed"
  TlsStoreFailed _ -> "tls-store:failed"
  TlsStoreBadRequest err -> "tls-store:bad-request:" <> controlPlaneRequestCodecToken err
  TlsStoreInvalidEnvelope -> "tls-store:invalid-envelope"
  TlsStoreDigestMismatch -> "tls-store:digest-mismatch"

tlsRestoreHttpStatus :: TlsRestoreResult -> Int
tlsRestoreHttpStatus result = case result of
  TlsRestoreObserved TlsEnvelopeMissing -> 404
  TlsRestoreObserved (TlsEnvelopePresent _ _) -> 200
  TlsRestoreObserved (TlsEnvelopeCorrupt _) -> 500
  TlsRestoreReadFailed _ -> 503
  TlsRestoreBadRequest _ -> 400

tlsRestoreSummary :: TlsRestoreResult -> Text
tlsRestoreSummary result = case result of
  TlsRestoreObserved TlsEnvelopeMissing -> "tls-restore:missing"
  TlsRestoreObserved (TlsEnvelopePresent _ _) -> "tls-restore:present"
  TlsRestoreObserved (TlsEnvelopeCorrupt _) -> "tls-restore:corrupt"
  TlsRestoreReadFailed _ -> "tls-restore:read-failed"
  TlsRestoreBadRequest err -> "tls-restore:bad-request:" <> controlPlaneRequestCodecToken err

tlsStoreResponseBody :: TlsStoreResult -> ByteString
tlsStoreResponseBody result = case result of
  TlsStoreSucceeded receipt ->
    LazyByteString.toStrict (encodeControlPlaneResponse receipt)
  _ -> TextEncoding.encodeUtf8 (tlsStoreSummary result)

tlsRestoreResponseBody :: TlsRestoreResult -> ByteString
tlsRestoreResponseBody result = case result of
  TlsRestoreObserved observation ->
    LazyByteString.toStrict (encodeControlPlaneResponse observation)
  _ -> TextEncoding.encodeUtf8 (tlsRestoreSummary result)
