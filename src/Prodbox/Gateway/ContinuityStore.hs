{-# LANGUAGE OverloadedStrings #-}

-- | Model-B retained-store interpreter for gateway continuity.
--
-- Logical names are HMAC-opaque and bodies use Vault-Transit envelopes.  The
-- logical Word64 revision is encoded inside the authenticated body; the S3
-- ETag is used only as the compare-and-swap token and is never treated as the
-- protocol revision.
module Prodbox.Gateway.ContinuityStore
  ( ContinuityStoreMaterial (..)
  , ContinuityStoreBackend (..)
  , modelBContinuityAuthority
  , modelBContinuityAuthorityWithBackend
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Crypto.Envelope (DekCipher)
import Prodbox.Gateway.Continuity
  ( AuthorityCasResult (..)
  , AuthorityObservation (..)
  , ContinuityScope
  , GatewayContinuityAuthority
  , VersionedAuthorityRecord
  , authorityVersionValue
  , continuityScopeEmitter
  , decodeVersionedAuthorityRecord
  , encodeVersionedAuthorityRecord
  , gatewayContinuityAuthorityWithInitialize
  , versionAuthorityRecord
  , versionedAuthorityVersion
  )
import Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError (..)
  , LogicalConditionalPutResult (..)
  , LogicalObject (LogicalGatewayState)
  , VersionedLogicalObject (..)
  , getLogicalVersioned
  , putLogicalIfAbsent
  , putLogicalIfVersion
  , renderEncryptedObjectError
  )
import Prodbox.Minio.ObjectStore (ObjectStoreConfig, ObjectVersion)

data ContinuityStoreMaterial = ContinuityStoreMaterial
  { continuityStoreObjectStore :: ObjectStoreConfig
  , continuityStoreCipher :: DekCipher
  , continuityStoreHmacKey :: ByteString
  , continuityStoreClusterId :: Text
  }

-- | Injected logical Model-B boundary.  Production closes these callbacks
-- over the encrypted object layer; tests can exercise version/ETag and error
-- classification without a subprocess or object store.
data ContinuityStoreBackend m = ContinuityStoreBackend
  { continuityBackendGet
      :: LogicalObject
      -> m (Either EncryptedObjectError (Maybe VersionedLogicalObject))
  , continuityBackendPutIfAbsent
      :: LogicalObject
      -> ByteString
      -> m (Either EncryptedObjectError LogicalConditionalPutResult)
  , continuityBackendPutIfVersion
      :: LogicalObject
      -> ObjectVersion
      -> ByteString
      -> m (Either EncryptedObjectError LogicalConditionalPutResult)
  }

modelBContinuityAuthority
  :: ContinuityStoreMaterial
  -> ContinuityScope
  -> GatewayContinuityAuthority IO
modelBContinuityAuthority material scope =
  modelBContinuityAuthorityWithBackend (productionBackend material) scope

productionBackend :: ContinuityStoreMaterial -> ContinuityStoreBackend IO
productionBackend material =
  ContinuityStoreBackend
    { continuityBackendGet =
        getLogicalVersioned
          (continuityStoreObjectStore material)
          (continuityStoreCipher material)
          (continuityStoreHmacKey material)
          (continuityStoreClusterId material)
    , continuityBackendPutIfAbsent =
        putLogicalIfAbsent
          (continuityStoreObjectStore material)
          (continuityStoreCipher material)
          (continuityStoreHmacKey material)
          (continuityStoreClusterId material)
    , continuityBackendPutIfVersion =
        putLogicalIfVersion
          (continuityStoreObjectStore material)
          (continuityStoreCipher material)
          (continuityStoreHmacKey material)
          (continuityStoreClusterId material)
    }

modelBContinuityAuthorityWithBackend
  :: (Monad m)
  => ContinuityStoreBackend m
  -> ContinuityScope
  -> GatewayContinuityAuthority m
modelBContinuityAuthorityWithBackend backend scope =
  gatewayContinuityAuthorityWithInitialize
    scope
    observe
    initialize
    compareAndSwap
 where
  observe = do
    stored <- observeStored backend scope
    pure $ case stored of
      StoreMissing -> AuthorityMissing
      StoreCorrupt detail -> AuthorityCorrupt detail
      StoreUnobservable detail -> AuthorityUnobservable detail
      StoreObserved versioned _ -> AuthorityObserved versioned

  initialize record = do
    let versioned = versionAuthorityRecord 0 record
    result <-
      continuityBackendPutIfAbsent
        backend
        (continuityLogicalObject scope)
        (encodeVersionedAuthorityRecord versioned)
    pure $ case result of
      Left err -> mapWriteError err
      Right LogicalConditionalPutApplied -> AuthorityCasApplied versioned
      Right LogicalConditionalPutConflict -> AuthorityCasConflict Nothing

  compareAndSwap expected desired = do
    observed <- observeStored backend scope
    case observed of
      StoreMissing -> pure AuthorityCasMissing
      StoreCorrupt detail -> pure (AuthorityCasCorrupt detail)
      StoreUnobservable detail -> pure (AuthorityCasUnobservable detail)
      StoreObserved current storeVersion
        | versionedAuthorityVersion current /= expected ->
            pure (AuthorityCasConflict (Just (versionedAuthorityVersion current)))
        | authorityVersionValue expected == maxBound ->
            pure (AuthorityCasConflict (Just expected))
        | otherwise -> do
            let next =
                  versionAuthorityRecord
                    (authorityVersionValue expected + 1)
                    desired
            result <-
              continuityBackendPutIfVersion
                backend
                (continuityLogicalObject scope)
                storeVersion
                (encodeVersionedAuthorityRecord next)
            pure $ case result of
              Left err -> mapWriteError err
              Right LogicalConditionalPutApplied -> AuthorityCasApplied next
              Right LogicalConditionalPutConflict ->
                AuthorityCasConflict (Just (versionedAuthorityVersion current))

data StoreObservation
  = StoreMissing
  | StoreCorrupt Text
  | StoreUnobservable Text
  | StoreObserved VersionedAuthorityRecord ObjectVersion

observeStored
  :: (Monad m)
  => ContinuityStoreBackend m
  -> ContinuityScope
  -> m StoreObservation
observeStored backend scope = do
  fetched <-
    continuityBackendGet
      backend
      (continuityLogicalObject scope)
  pure $ case fetched of
    Left err -> mapReadError err
    Right Nothing -> StoreMissing
    Right (Just versionedLogical) ->
      case decodeVersionedAuthorityRecord
        scope
        (versionedLogicalBytes versionedLogical) of
        Left err -> StoreCorrupt (Text.pack (show err))
        Right versioned ->
          StoreObserved versioned (versionedLogicalStoreVersion versionedLogical)

continuityLogicalObject :: ContinuityScope -> LogicalObject
continuityLogicalObject scope =
  LogicalGatewayState ("continuity/" <> continuityScopeEmitter scope)

mapReadError :: EncryptedObjectError -> StoreObservation
mapReadError err =
  case err of
    EncryptedObjectOpenFailed _ -> StoreCorrupt (Text.pack (renderEncryptedObjectError err))
    EncryptedObjectIndexMalformed _ -> StoreCorrupt (Text.pack (renderEncryptedObjectError err))
    EncryptedObjectMissing _ -> StoreMissing
    _ -> StoreUnobservable (Text.pack (renderEncryptedObjectError err))

mapWriteError :: EncryptedObjectError -> AuthorityCasResult
mapWriteError err =
  case err of
    EncryptedObjectOpenFailed _ -> AuthorityCasCorrupt (Text.pack (renderEncryptedObjectError err))
    EncryptedObjectIndexMalformed _ -> AuthorityCasCorrupt (Text.pack (renderEncryptedObjectError err))
    EncryptedObjectMissing _ -> AuthorityCasMissing
    _ -> AuthorityCasUnobservable (Text.pack (renderEncryptedObjectError err))
