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
  , adapterObjectStoreReady
  , adapterObjectVersionText
  , tlsLegacyRetentionEnvelopeObjectName
  , tlsRetentionEnvelopeObjectName
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsEnvelopeObservation (..)
  , TlsRestoreRepositoryFailure (..)
  , TlsRetentionReceipt (..)
  , TlsRetentionRepository (..)
  , TlsSealedEnvelope
  , TlsStoreConfirmationFailure (..)
  , TlsStorePutDisposition (..)
  , TlsStoreRepositoryFailure (..)
  , TlsVersionEnvelopeObservation (..)
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
    , observeTlsEnvelopeVersion = observeEnvelopeVersion transport
    , observeTlsAuthorityEnvelopeVersion = observeAuthorityEnvelopeVersion transport
    }

storeEnvelope
  :: DedicatedAdapterTransport 'TlsRetentionAdapter IO
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> IO (Either TlsStoreRepositoryFailure TlsRetentionReceipt)
storeEnvelope transport reference envelope =
  case validateTlsSealedEnvelope envelope of
    Left _ -> pure (Left TlsStoreRepositoryEnvelopeInvalid)
    Right ()
      | tlsSealedEnvelopeDigest envelope /= retainedCiphertextDigest reference ->
          pure (Left TlsStoreRepositoryDigestMismatch)
      | otherwise ->
          case retentionObjectName reference of
            Left _ -> pure (Left TlsStoreRepositoryObjectNameInvalid)
            Right objectName -> do
              let encoded = encodeEnvelope envelope
              if ByteString.length encoded > tlsRetentionMaximumEncodedEnvelopeBytes
                then pure (Left TlsStoreRepositoryEncodedEnvelopeTooLarge)
                else do
                  attempted <- putAdapterObjectIfAbsent transport objectName encoded
                  confirmAfterAttempt
                    (putDisposition attempted)
                    objectName
                    encoded
 where
  putDisposition attempted = case attempted of
    Left _ -> TlsStorePutUnobservable
    Right AdapterPutApplied -> TlsStorePutApplied
    Right AdapterPutConflict -> TlsStorePutConflict

  confirmAfterAttempt disposition objectName expectedBytes = do
    observed <- observeAdapterObject transport objectName
    pure $ case observed of
      Left _ -> confirmationFailed TlsStoreConfirmationUnobservable
      Right AdapterObjectMissing -> confirmationFailed TlsStoreConfirmationMissing
      Right (AdapterObjectObserved version bytes)
        | bytes /= expectedBytes -> confirmationFailed TlsStoreConfirmationBytesMismatch
        | otherwise -> case decodeEnvelope bytes of
            Left _ -> confirmationFailed TlsStoreConfirmationEnvelopeInvalid
            Right readBack
              | readBack /= envelope -> confirmationFailed TlsStoreConfirmationEnvelopeMismatch
              | tlsSealedEnvelopeDigest readBack /= retainedCiphertextDigest reference ->
                  confirmationFailed TlsStoreConfirmationDigestMismatch
              | otherwise -> Right (receiptFor reference readBack version)
   where
    confirmationFailed =
      Left . TlsStoreRepositoryConfirmationFailed disposition

restoreEnvelope
  :: DedicatedAdapterTransport 'TlsRetentionAdapter IO
  -> RetainedTlsRef
  -> IO (Either TlsRestoreRepositoryFailure TlsEnvelopeObservation)
restoreEnvelope transport reference =
  case retentionObjectName reference of
    Left _ -> pure (Left TlsRestoreRepositoryObjectNameInvalid)
    Right objectName -> do
      observed <- observeAdapterObject transport objectName
      pure $ case observed of
        Left _ -> Left TlsRestoreRepositoryObservationUnobservable
        Right AdapterObjectMissing -> Right TlsEnvelopeMissing
        Right (AdapterObjectObserved version bytes) ->
          case decodeEnvelope bytes of
            Left detail -> Right (TlsEnvelopeCorrupt detail)
            Right envelope
              | tlsSealedEnvelopeDigest envelope /= retainedCiphertextDigest reference ->
                  Right (TlsEnvelopeCorrupt "TLS retention envelope digest mismatch")
              | otherwise -> Right (TlsEnvelopePresent envelope (receiptFor reference envelope version))

observeEnvelopeVersion
  :: DedicatedAdapterTransport 'TlsRetentionAdapter IO
  -> RetentionVersion
  -> IO (Either TlsRestoreRepositoryFailure TlsVersionEnvelopeObservation)
observeEnvelopeVersion transport version =
  case retentionVersionObjectName version of
    Left _ -> pure (Left TlsRestoreRepositoryObjectNameInvalid)
    Right objectName -> observeEnvelopeAtName transport objectName

observeAuthorityEnvelopeVersion
  :: DedicatedAdapterTransport 'TlsRetentionAdapter IO
  -> RetentionVersion
  -> IO (Either TlsRestoreRepositoryFailure TlsVersionEnvelopeObservation)
observeAuthorityEnvelopeVersion transport version =
  case authorityRetentionVersionObjectName version of
    Left _ -> pure (Left TlsRestoreRepositoryObjectNameInvalid)
    Right objectName -> observeEnvelopeAtName transport objectName

observeEnvelopeAtName
  :: DedicatedAdapterTransport 'TlsRetentionAdapter IO
  -> AdapterObjectName 'TlsRetentionAdapter
  -> IO (Either TlsRestoreRepositoryFailure TlsVersionEnvelopeObservation)
observeEnvelopeAtName transport objectName = do
  observed <- observeAdapterObject transport objectName
  pure $ case observed of
    Left _ -> Left TlsRestoreRepositoryObservationUnobservable
    Right AdapterObjectMissing -> Right TlsVersionEnvelopeMissing
    Right (AdapterObjectObserved objectVersion bytes) ->
      case decodeEnvelope bytes of
        Left _ -> Right TlsVersionEnvelopeCorrupt
        Right envelope ->
          Right
            ( TlsVersionEnvelopePresent
                envelope
                (adapterObjectVersionText objectVersion)
            )

retentionObjectName
  :: RetainedTlsRef
  -> Either Text (AdapterObjectName 'TlsRetentionAdapter)
retentionObjectName reference =
  authorityRetentionVersionObjectName (retainedVersion reference)

authorityRetentionVersionObjectName
  :: RetentionVersion
  -> Either Text (AdapterObjectName 'TlsRetentionAdapter)
authorityRetentionVersionObjectName (RetentionVersion version) =
  tlsRetentionEnvelopeObjectName version

retentionVersionObjectName
  :: RetentionVersion
  -> Either Text (AdapterObjectName 'TlsRetentionAdapter)
retentionVersionObjectName (RetentionVersion version) =
  tlsLegacyRetentionEnvelopeObjectName version

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
