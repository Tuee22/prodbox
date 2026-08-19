{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production immutable ciphertext binding for the Authority Backup Adapter.
module Prodbox.ControlPlane.AuthorityBackupAdapter
  ( authorityBackupRepository
  , authorityBackupRepositoryWithTransport
  , authorityBackupAdapterReady
  , authorityBackupBlobObjectNameForClass
  )
where

import Data.Text (Text)
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (..)
  , AuthorityBackupBlobObservation (..)
  , AuthorityBackupCiphertext
  , AuthorityBackupDigest
  , AuthorityBackupReceipt (..)
  , AuthorityBackupRepository (..)
  , authorityBackupCiphertextBytes
  , authorityBackupCiphertextDigest
  , authorityBackupDigestText
  , mkAuthorityBackupCiphertext
  , validateAuthorityBackupCiphertextForClass
  )
import Prodbox.ControlPlane.DedicatedAdapterStore
  ( AdapterObjectName
  , AdapterObjectObservation (..)
  , AdapterPutResult (..)
  , DedicatedAdapterBinding
  , DedicatedAdapterKind (AuthorityBackupAdapter)
  , DedicatedAdapterTransport (..)
  , adapterBindingTransport
  , adapterObjectVersionText
  , authorityBackupBlobObjectName
  )

authorityBackupRepository
  :: DedicatedAdapterBinding 'AuthorityBackupAdapter
  -> AuthorityBackupRepository IO
authorityBackupRepository binding =
  authorityBackupRepositoryWithTransport (adapterBindingTransport binding)

authorityBackupRepositoryWithTransport
  :: DedicatedAdapterTransport 'AuthorityBackupAdapter IO
  -> AuthorityBackupRepository IO
authorityBackupRepositoryWithTransport transport =
  AuthorityBackupRepository
    { copyAuthorityBackupBlob = copyBlob transport
    , observeAuthorityBackupBlob = observeBlob transport
    }

copyBlob
  :: DedicatedAdapterTransport 'AuthorityBackupAdapter IO
  -> AuthorityBackupBlobClass
  -> AuthorityBackupCiphertext
  -> IO (Either Text AuthorityBackupReceipt)
copyBlob transport blobClass ciphertext =
  case validateAuthorityBackupCiphertextForClass blobClass ciphertext of
    Left detail -> pure (Left detail)
    Right () -> case backupObjectName blobClass (authorityBackupCiphertextDigest ciphertext) of
      Left detail -> pure (Left detail)
      Right objectName -> do
        attempted <-
          putAdapterObjectIfAbsent
            transport
            objectName
            (authorityBackupCiphertextBytes ciphertext)
        case attempted of
          Left detail -> confirmAfterAttempt detail objectName
          Right AdapterPutApplied -> confirmAfterAttempt "backup PUT was not confirmed" objectName
          Right AdapterPutConflict -> confirmAfterAttempt "backup object already existed but did not match" objectName
 where
  confirmAfterAttempt failure objectName = do
    observed <- observeAdapterObject transport objectName
    pure $ case observed of
      Left detail -> Left (failure <> ": " <> detail)
      Right AdapterObjectMissing -> Left failure
      Right (AdapterObjectObserved version bytes) ->
        case mkAuthorityBackupCiphertext bytes of
          Left _ -> Left "Authority backup read-back exceeded the ciphertext bound"
          Right readBack -> case validateAuthorityBackupCiphertextForClass blobClass readBack of
            Left detail -> Left detail
            Right ()
              | authorityBackupCiphertextBytes readBack
                  /= authorityBackupCiphertextBytes ciphertext ->
                  Left "Authority backup read-back bytes did not match"
              | otherwise ->
                  Right
                    AuthorityBackupReceipt
                      { authorityBackupReceiptClass = blobClass
                      , authorityBackupReceiptDigest = authorityBackupCiphertextDigest readBack
                      , authorityBackupReceiptObjectVersion = adapterObjectVersionText version
                      }

observeBlob
  :: DedicatedAdapterTransport 'AuthorityBackupAdapter IO
  -> AuthorityBackupBlobClass
  -> AuthorityBackupDigest
  -> IO (Either Text AuthorityBackupBlobObservation)
observeBlob transport blobClass digest =
  case backupObjectName blobClass digest of
    Left detail -> pure (Left detail)
    Right objectName -> do
      observed <- observeAdapterObject transport objectName
      pure $ case observed of
        Left detail -> Left detail
        Right AdapterObjectMissing -> Right AuthorityBackupBlobMissing
        Right (AdapterObjectObserved version bytes) ->
          case mkAuthorityBackupCiphertext bytes of
            Left detail -> Right (AuthorityBackupBlobCorrupt detail)
            Right ciphertext ->
              case validateAuthorityBackupCiphertextForClass blobClass ciphertext of
                Left detail -> Right (AuthorityBackupBlobCorrupt detail)
                Right ()
                  | authorityBackupCiphertextDigest ciphertext /= digest ->
                      Right (AuthorityBackupBlobCorrupt "Authority backup digest mismatch")
                  | otherwise ->
                      Right
                        ( AuthorityBackupBlobPresent
                            ciphertext
                            AuthorityBackupReceipt
                              { authorityBackupReceiptClass = blobClass
                              , authorityBackupReceiptDigest = digest
                              , authorityBackupReceiptObjectVersion = adapterObjectVersionText version
                              }
                        )

-- | The one place a typed backup blob class becomes an adapter object name.
--
-- Sprint 4.87: exported so every class can be enumerated against it.  The
-- segment crosses a stringly-typed seam into the dedicated adapter store, and
-- a class whose segment that store does not admit refuses every copy and every
-- observation of that class at run time rather than failing to compile.
authorityBackupBlobObjectNameForClass
  :: AuthorityBackupBlobClass
  -> AuthorityBackupDigest
  -> Either Text (AdapterObjectName 'AuthorityBackupAdapter)
authorityBackupBlobObjectNameForClass blobClass digest =
  authorityBackupBlobObjectName
    ( case blobClass of
        AuthorityAggregateEnvelope -> "authority-aggregate"
        AuthorityCheckpointBlob -> "checkpoint"
        AuthorityConfigBlob -> "config"
    )
    (authorityBackupDigestText digest)

backupObjectName
  :: AuthorityBackupBlobClass
  -> AuthorityBackupDigest
  -> Either Text (AdapterObjectName 'AuthorityBackupAdapter)
backupObjectName = authorityBackupBlobObjectNameForClass

authorityBackupAdapterReady
  :: DedicatedAdapterBinding 'AuthorityBackupAdapter
  -> IO Bool
authorityBackupAdapterReady =
  adapterObjectStoreReady . adapterBindingTransport
