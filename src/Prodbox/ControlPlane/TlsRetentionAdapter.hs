{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production immutable ciphertext-envelope binding for the TLS Retention
-- Adapter.  The repository owns no promotion or restore decision state: it
-- writes one canonical envelope at the exact retention version and confirms the
-- bytes through an authoritative read-back before returning a receipt.
module Prodbox.ControlPlane.TlsRetentionAdapter
  ( tlsRetentionMaximumEncodedEnvelopeBytes
  , tlsRetentionRepository
  , tlsRetentionRepositoryWithTransport
  , tlsRetentionAdapterReady
  )
where

import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneResponse
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.DedicatedAdapterStore
  ( AdapterObjectName
  , AdapterObjectObservation (..)
  , AdapterObjectVersion
  , AdapterPutResult (..)
  , DedicatedAdapterBinding
  , DedicatedAdapterKind (TlsRetentionAdapter)
  , DedicatedAdapterTransport (..)
  , adapterBindingTransport
  , adapterObjectVersionText
  , tlsRetentionEnvelopeObjectName
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsEnvelopeObservation (..)
  , TlsRetentionReceipt (..)
  , TlsRetentionRepository (..)
  , TlsSealedEnvelope
  , tlsSealedEnvelopeDigest
  , validateTlsSealedEnvelope
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( RetainedTlsRef (..)
  , RetentionVersion (..)
  )

-- | The canonical encoded envelope must fit below the native S3 client's
-- one-MiB response bound.  The endpoint's component bounds leave framing room.
tlsRetentionMaximumEncodedEnvelopeBytes :: Int
tlsRetentionMaximumEncodedEnvelopeBytes = 896 * 1024

tlsRetentionRepository
  :: DedicatedAdapterBinding 'TlsRetentionAdapter
  -> TlsRetentionRepository IO
tlsRetentionRepository binding =
  tlsRetentionRepositoryWithTransport (adapterBindingTransport binding)

tlsRetentionRepositoryWithTransport
  :: DedicatedAdapterTransport 'TlsRetentionAdapter IO
  -> TlsRetentionRepository IO
tlsRetentionRepositoryWithTransport transport =
  TlsRetentionRepository
    { storeTlsEnvelope = storeEnvelope transport
    , restoreTlsEnvelope = restoreEnvelope transport
    }

storeEnvelope
  :: DedicatedAdapterTransport 'TlsRetentionAdapter IO
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> IO (Either Text TlsRetentionReceipt)
storeEnvelope transport reference envelope =
  case validateTlsSealedEnvelope envelope of
    Left detail -> pure (Left detail)
    Right ()
      | tlsSealedEnvelopeDigest envelope /= retainedCiphertextDigest reference ->
          pure (Left "TLS retention envelope digest does not match its reference")
      | otherwise ->
          case retentionObjectName reference of
            Left detail -> pure (Left detail)
            Right objectName -> do
              let encoded = encodeEnvelope envelope
              if ByteString.length encoded > tlsRetentionMaximumEncodedEnvelopeBytes
                then pure (Left "TLS retention encoded envelope exceeds the compiled bound")
                else do
                  attempted <- putAdapterObjectIfAbsent transport objectName encoded
                  case attempted of
                    Left detail -> confirmAfterAttempt detail objectName encoded
                    Right AdapterPutApplied ->
                      confirmAfterAttempt "TLS retention PUT was not confirmed" objectName encoded
                    Right AdapterPutConflict ->
                      confirmAfterAttempt
                        "TLS retention version already existed but did not match"
                        objectName
                        encoded
 where
  confirmAfterAttempt failure objectName expectedBytes = do
    observed <- observeAdapterObject transport objectName
    pure $ case observed of
      Left detail -> Left (failure <> ": " <> detail)
      Right AdapterObjectMissing -> Left failure
      Right (AdapterObjectObserved version bytes)
        | bytes /= expectedBytes -> Left "TLS retention read-back bytes did not match"
        | otherwise -> case decodeEnvelope bytes of
            Left detail -> Left detail
            Right readBack
              | readBack /= envelope -> Left "TLS retention read-back envelope did not match"
              | tlsSealedEnvelopeDigest readBack /= retainedCiphertextDigest reference ->
                  Left "TLS retention read-back digest did not match"
              | otherwise -> Right (receiptFor reference readBack version)

restoreEnvelope
  :: DedicatedAdapterTransport 'TlsRetentionAdapter IO
  -> RetainedTlsRef
  -> IO (Either Text TlsEnvelopeObservation)
restoreEnvelope transport reference =
  case retentionObjectName reference of
    Left detail -> pure (Left detail)
    Right objectName -> do
      observed <- observeAdapterObject transport objectName
      pure $ case observed of
        Left detail -> Left detail
        Right AdapterObjectMissing -> Right TlsEnvelopeMissing
        Right (AdapterObjectObserved version bytes) ->
          case decodeEnvelope bytes of
            Left detail -> Right (TlsEnvelopeCorrupt detail)
            Right envelope
              | tlsSealedEnvelopeDigest envelope /= retainedCiphertextDigest reference ->
                  Right (TlsEnvelopeCorrupt "TLS retention envelope digest mismatch")
              | otherwise -> Right (TlsEnvelopePresent envelope (receiptFor reference envelope version))

retentionObjectName
  :: RetainedTlsRef
  -> Either Text (AdapterObjectName 'TlsRetentionAdapter)
retentionObjectName reference =
  let RetentionVersion version = retainedVersion reference
   in tlsRetentionEnvelopeObjectName version

encodeEnvelope :: TlsSealedEnvelope -> ByteString.ByteString
encodeEnvelope = LazyByteString.toStrict . encodeControlPlaneResponse

decodeEnvelope :: ByteString.ByteString -> Either Text TlsSealedEnvelope
decodeEnvelope bytes
  | ByteString.length bytes > tlsRetentionMaximumEncodedEnvelopeBytes =
      Left "TLS retention encoded envelope exceeds the compiled bound"
  | otherwise =
      case decodeControlPlaneResponse tlsRetentionMaximumEncodedEnvelopeBytes (LazyByteString.fromStrict bytes) of
        Left err -> Left ("TLS retention encoded envelope is invalid: " <> Text.pack (show err))
        Right envelope -> case validateTlsSealedEnvelope envelope of
          Left detail -> Left detail
          Right () -> Right envelope

receiptFor
  :: RetainedTlsRef
  -> TlsSealedEnvelope
  -> AdapterObjectVersion
  -> TlsRetentionReceipt
receiptFor reference envelope version =
  TlsRetentionReceipt
    { tlsRetentionReceiptReference = reference
    , tlsRetentionReceiptEnvelopeDigest = tlsSealedEnvelopeDigest envelope
    , tlsRetentionReceiptObjectVersion = adapterObjectVersionText version
    }

tlsRetentionAdapterReady
  :: DedicatedAdapterBinding 'TlsRetentionAdapter
  -> IO Bool
tlsRetentionAdapterReady =
  adapterObjectStoreReady . adapterBindingTransport
