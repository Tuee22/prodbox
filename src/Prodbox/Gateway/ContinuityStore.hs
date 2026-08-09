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
import GHC.Clock (getMonotonicTimeNSec)
import Numeric.Natural (Natural)
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
  , continuityStoreObserveDurationMillis :: Natural -> IO ()
  , continuityStoreObserveRoundTrip :: ObjectVersion -> IO ()
  -- ^ Sprint 1.76: invoked with the version the store returned, at the moment
  -- a conditional write of the continuity object is accepted. This is the one
  -- place in the daemon that knows a round trip to the shared object store
  -- actually landed, so it is the only place permitted to record the receipt
  -- the deep readiness probe later reads
  -- (bootstrap_readiness_doctrine.md § 2.3).
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
        timed $
          getLogicalVersioned
            (continuityStoreObjectStore material)
            (continuityStoreCipher material)
            (continuityStoreHmacKey material)
            (continuityStoreClusterId material)
    , continuityBackendPutIfAbsent =
        witnessed . timed2 $
          putLogicalIfAbsent
            (continuityStoreObjectStore material)
            (continuityStoreCipher material)
            (continuityStoreHmacKey material)
            (continuityStoreClusterId material)
    , continuityBackendPutIfVersion =
        witnessed3 . timed3 $
          putLogicalIfVersion
            (continuityStoreObjectStore material)
            (continuityStoreCipher material)
            (continuityStoreHmacKey material)
            (continuityStoreClusterId material)
    }
 where
  observeDuration started = do
    finished <- getMonotonicTimeNSec
    continuityStoreObserveDurationMillis material (fromIntegral ((finished - started) `div` 1000000))

  -- Record the receipt on exactly the applied arm, and only after the
  -- interpreter has it in hand. A conflict or an error records nothing, so a
  -- refused write can never refresh the round-trip evidence.
  recordApplied result = do
    case result of
      Right (LogicalConditionalPutApplied version) ->
        continuityStoreObserveRoundTrip material version
      _ -> pure ()
    pure result
  witnessed operation first second = operation first second >>= recordApplied
  witnessed3 operation first second third = operation first second third >>= recordApplied
  timed operation first = do
    started <- getMonotonicTimeNSec
    result <- operation first
    observeDuration started
    pure result
  timed2 operation first second = do
    started <- getMonotonicTimeNSec
    result <- operation first second
    observeDuration started
    pure result
  timed3 operation first second third = do
    started <- getMonotonicTimeNSec
    result <- operation first second third
    observeDuration started
    pure result

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
      Right (LogicalConditionalPutApplied _) -> AuthorityCasApplied versioned
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
              Right (LogicalConditionalPutApplied _) -> AuthorityCasApplied next
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
