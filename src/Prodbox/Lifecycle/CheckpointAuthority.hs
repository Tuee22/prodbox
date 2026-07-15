{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Typed coordinates and compare-and-swap boundary for retained Model-B
-- state.  The retained checkpoint authority and a selected workload-cluster
-- secret sink deliberately have unrelated constructors: a target endpoint can
-- never be substituted for the authority that owns the lease/checkpoint.
--
-- Sprint 4.51: every Model-B coordinate, request, lease guard, and CAS adapter
-- carries a fully-erased 'StoreLifetime' PHANTOM index. A coordinate for
-- retained control-plane authority state is @'ClusterRetained'@; a per-run /
-- chart-scoped object is @'ChartLifetime'@. Because the index is a pure phantom
-- it would default to a phantom role and 'Data.Coerce.coerce' could relabel the
-- tag, so 'ModelBObjectCoordinate' carries a load-bearing @type role … nominal@
-- (the other three infer @nominal@ through the coordinate they embed). Storing
-- retained state through a chart-lifetime transport is then a compile-time type
-- error, with zero runtime cost and byte-identical sealed envelopes.
module Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError (..)
  , StoreLifetime (..)
  , LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBLeaseGuard (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , TargetClusterSecretSink
  , checkpointAuthorityClusterId
  , checkpointAuthorityGatewayEndpoint
  , checkpointAuthorityObjectBucket
  , checkpointAuthorityObjectNamespace
  , checkpointAuthorityVaultKeyspace
  , mkChartLifetimeCoordinate
  , mkClusterRetainedCoordinate
  , mkCrossClusterDurableCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , mkTargetClusterSecretSink
  , modelBObjectAuthority
  , modelBObjectLogicalName
  , modelBObjectVersionText
  , targetSecretSinkGatewayEndpoint
  , targetSecretSinkIdentity
  , targetSecretSinkKvPath
  , targetSecretSinkVaultMount
  )
where

import Data.ByteString (ByteString)
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.StoreLifetime (StoreLifetime (..))

-- | A validation failure in decoded authority coordinates.  Empty, control,
-- and over-bound fields are rejected before an external adapter is selected.
data AuthorityCoordinateError
  = AuthorityCoordinateEmpty !Text
  | AuthorityCoordinateContainsWhitespace !Text
  | AuthorityCoordinateContainsControl !Text
  | AuthorityCoordinateTooLong !Text !Int !Int
  deriving (Eq, Show)

-- | The retained home/control-plane authority for the shared checkpoint and
-- lease.  Its object-store and Vault coordinates are explicit decoded input;
-- there is no ambient gateway or kube-context fallback.
data LongLivedCheckpointAuthority = LongLivedCheckpointAuthority
  { internalCheckpointAuthorityClusterId :: !Text
  , internalCheckpointAuthorityGatewayEndpoint :: !Text
  , internalCheckpointAuthorityObjectBucket :: !Text
  , internalCheckpointAuthorityObjectNamespace :: !Text
  , internalCheckpointAuthorityVaultKeyspace :: !Text
  }
  deriving (Eq, Show)

-- | The independently selected destination for workload-cluster secret
-- material.  This type intentionally carries no object-store coordinate and
-- has no conversion to 'LongLivedCheckpointAuthority'.
data TargetClusterSecretSink = TargetClusterSecretSink
  { internalTargetSecretSinkIdentity :: !Text
  , internalTargetSecretSinkGatewayEndpoint :: !Text
  , internalTargetSecretSinkVaultMount :: !Text
  , internalTargetSecretSinkKvPath :: !Text
  }
  deriving (Eq, Show)

mkLongLivedCheckpointAuthority
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Either AuthorityCoordinateError LongLivedCheckpointAuthority
mkLongLivedCheckpointAuthority clusterId endpoint bucket objectNamespace vaultKeyspace =
  LongLivedCheckpointAuthority
    <$> validateCoordinate "cluster_id" 128 clusterId
    <*> validateCoordinate "gateway_endpoint" 2048 endpoint
    <*> validateCoordinate "object_bucket" 255 bucket
    <*> validateCoordinate "object_namespace" 512 objectNamespace
    <*> validateCoordinate "vault_keyspace" 512 vaultKeyspace

mkTargetClusterSecretSink
  :: Text
  -> Text
  -> Text
  -> Text
  -> Either AuthorityCoordinateError TargetClusterSecretSink
mkTargetClusterSecretSink identity endpoint vaultMount kvPath =
  TargetClusterSecretSink
    <$> validateCoordinate "target_identity" 128 identity
    <*> validateCoordinate "target_gateway_endpoint" 2048 endpoint
    <*> validateCoordinate "target_vault_mount" 128 vaultMount
    <*> validateCoordinate "target_kv_path" 512 kvPath

checkpointAuthorityClusterId :: LongLivedCheckpointAuthority -> Text
checkpointAuthorityClusterId = internalCheckpointAuthorityClusterId

checkpointAuthorityGatewayEndpoint :: LongLivedCheckpointAuthority -> Text
checkpointAuthorityGatewayEndpoint = internalCheckpointAuthorityGatewayEndpoint

checkpointAuthorityObjectBucket :: LongLivedCheckpointAuthority -> Text
checkpointAuthorityObjectBucket = internalCheckpointAuthorityObjectBucket

checkpointAuthorityObjectNamespace :: LongLivedCheckpointAuthority -> Text
checkpointAuthorityObjectNamespace = internalCheckpointAuthorityObjectNamespace

checkpointAuthorityVaultKeyspace :: LongLivedCheckpointAuthority -> Text
checkpointAuthorityVaultKeyspace = internalCheckpointAuthorityVaultKeyspace

targetSecretSinkIdentity :: TargetClusterSecretSink -> Text
targetSecretSinkIdentity = internalTargetSecretSinkIdentity

targetSecretSinkGatewayEndpoint :: TargetClusterSecretSink -> Text
targetSecretSinkGatewayEndpoint = internalTargetSecretSinkGatewayEndpoint

targetSecretSinkVaultMount :: TargetClusterSecretSink -> Text
targetSecretSinkVaultMount = internalTargetSecretSinkVaultMount

targetSecretSinkKvPath :: TargetClusterSecretSink -> Text
targetSecretSinkKvPath = internalTargetSecretSinkKvPath

-- | A logical Model-B object rooted at the retained authority, tagged with its
-- storage lifetime @l@.  The logical name is still fed through the
-- encrypted-object/HMAC layer by the production adapter; it is not a raw MinIO
-- key.  The @l@ index is a fully-erased phantom, so it would default to a
-- phantom role and 'Data.Coerce.coerce' could relabel the lifetime; the explicit
-- @nominal@ role below forbids that (the sibling request/guard/adapter types
-- infer @nominal@ through the coordinate they embed).
type role ModelBObjectCoordinate nominal

data ModelBObjectCoordinate (l :: StoreLifetime) = ModelBObjectCoordinate
  { internalModelBObjectAuthority :: !LongLivedCheckpointAuthority
  , internalModelBObjectLogicalName :: !Text
  }
  deriving (Eq, Show)

-- | Un-exported polymorphic builder.  The exported lifetime-tagging
-- constructors below each fix @l@, so no code path can construct a
-- lifetime-ambiguous or mis-tagged coordinate, and every constructor passes the
-- byte-identical full logical name (no prefix-splitting) so the sealed-envelope
-- bytes never drift.
unsafeCoordinate
  :: LongLivedCheckpointAuthority
  -> Text
  -> Either AuthorityCoordinateError (ModelBObjectCoordinate l)
unsafeCoordinate authority logicalName =
  ModelBObjectCoordinate authority
    <$> validateCoordinate "model_b_logical_name" 512 logicalName

-- | Build a coordinate for retained control-plane authority state — the lease,
-- target-commit intent, SMTP projection, and retained checkpoint that outlive a
-- run.
mkClusterRetainedCoordinate
  :: LongLivedCheckpointAuthority
  -> Text
  -> Either AuthorityCoordinateError (ModelBObjectCoordinate 'ClusterRetained)
mkClusterRetainedCoordinate = unsafeCoordinate

-- | Build a coordinate for chart-scoped / per-run Pulumi stack state.
mkChartLifetimeCoordinate
  :: LongLivedCheckpointAuthority
  -> Text
  -> Either AuthorityCoordinateError (ModelBObjectCoordinate 'ChartLifetime)
mkChartLifetimeCoordinate = unsafeCoordinate

-- | Build a coordinate for cross-cluster durable backup state.
mkCrossClusterDurableCoordinate
  :: LongLivedCheckpointAuthority
  -> Text
  -> Either AuthorityCoordinateError (ModelBObjectCoordinate 'CrossClusterDurable)
mkCrossClusterDurableCoordinate = unsafeCoordinate

modelBObjectAuthority :: ModelBObjectCoordinate l -> LongLivedCheckpointAuthority
modelBObjectAuthority = internalModelBObjectAuthority

modelBObjectLogicalName :: ModelBObjectCoordinate l -> Text
modelBObjectLogicalName = internalModelBObjectLogicalName

-- | Opaque version supplied by the object store (for example its ETag).  It is
-- never derived from the decoded logical payload or used as the fencing token.
newtype ModelBObjectVersion = ModelBObjectVersion
  { internalModelBObjectVersionText :: Text
  }
  deriving (Eq, Ord, Show)

mkModelBObjectVersion
  :: Text -> Either AuthorityCoordinateError ModelBObjectVersion
mkModelBObjectVersion value =
  ModelBObjectVersion <$> validateCoordinate "model_b_object_version" 512 value

modelBObjectVersionText :: ModelBObjectVersion -> Text
modelBObjectVersionText = internalModelBObjectVersionText

-- | Flat external observation.  Missing, corrupt, and unobservable are
-- intentionally distinct and only 'ModelBObserved' carries a CAS version.
data ModelBObservation value
  = ModelBMissing
  | ModelBObserved !ModelBObjectVersion !value
  | ModelBCorrupt !Text
  | ModelBUnobservable !Text
  deriving (Eq, Functor, Show)

-- | A conditional Model-B write, indexed by the storage lifetime @l@ of the
-- object it targets.  The phantom @l@ precedes @value@ so the derived 'Functor'
-- still maps over the payload.  The guarded constructors carry a
-- 'ModelBLeaseGuard', which is monomorphically @'ClusterRetained'@ (a lease is
-- always retained authority state), so a @'ChartLifetime'@ object may be guarded
-- by a retained lease without a second lifetime parameter.
data ModelBCasRequest (l :: StoreLifetime) value
  = ModelBInitialize !(ModelBObjectCoordinate l) !value
  | ModelBReplace
      !(ModelBObjectCoordinate l)
      !ModelBObjectVersion
      !value
  | ModelBInitializeGuarded
      !(ModelBObjectCoordinate l)
      !ModelBLeaseGuard
      !value
  | ModelBReplaceGuarded
      !(ModelBObjectCoordinate l)
      !ModelBObjectVersion
      !ModelBLeaseGuard
      !value
  deriving (Eq, Functor, Show)

-- | Lease evidence carried to the physical authority CAS endpoint.  The
-- daemon re-observes this exact lease object/version and validates the decoded
-- owner/fence/expiry immediately before accepting the target-object write.
-- It remains a cross-object guard, not a claim of multi-object atomicity.
--
-- A lease is always retained control-plane authority state, so the guarded lease
-- coordinate is fixed to @'ClusterRetained'@; 'ModelBLeaseGuard' therefore
-- carries no lifetime index of its own.
data ModelBLeaseGuard = ModelBLeaseGuard
  { modelBLeaseGuardCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , modelBLeaseGuardExpectedVersion :: !ModelBObjectVersion
  , modelBLeaseGuardOwnerNonceText :: !Text
  , modelBLeaseGuardFencingTokenValue :: !Natural
  }
  deriving (Eq, Show)

data ModelBCasResult value
  = ModelBCasApplied !ModelBObjectVersion !value
  | ModelBCasConflict !(ModelBObservation value)
  | ModelBCasRefusedCorrupt !Text
  | ModelBCasUnobservable !Text
  deriving (Eq, Functor, Show)

-- | Injected production boundary, indexed by the storage lifetime @l@ it is
-- authorised to reach.  Model-B payload encoding/encryption and object-store
-- conditional writes live behind these two operations; pure lease/intent
-- planners consume only the observations and requests above.  A
-- @'ChartLifetime'@ adapter cannot observe or write a @'ClusterRetained'@
-- coordinate, and vice-versa.
data ModelBCasAdapter (l :: StoreLifetime) m value = ModelBCasAdapter
  { modelBObserve
      :: ModelBObjectCoordinate l
      -> m (ModelBObservation value)
  , modelBCompareAndSwap
      :: ModelBCasRequest l value
      -> m (ModelBCasResult value)
  }

-- | Payload codec supplied by the state-machine owner.  Decode failures are
-- corruption evidence; transport/CAS failures remain unobservable.  Lifted from
-- 'Prodbox.Lifecycle.CheckpointAuthorityStore' in Sprint 4.51 so the
-- gateway-backed and (future) host-direct adapters share it without a module
-- cycle.  It is payload-only and carries no storage-lifetime index.
data ModelBCodec value = ModelBCodec
  { encodeModelBValue :: value -> Either String ByteString
  , decodeModelBValue :: ByteString -> Either String value
  }

validateCoordinate :: Text -> Int -> Text -> Either AuthorityCoordinateError Text
validateCoordinate label maximumLength raw
  | Text.null value = Left (AuthorityCoordinateEmpty label)
  | Text.any isControl value = Left (AuthorityCoordinateContainsControl label)
  | Text.any isSpace value = Left (AuthorityCoordinateContainsWhitespace label)
  | Text.length value > maximumLength =
      Left (AuthorityCoordinateTooLong label (Text.length value) maximumLength)
  | otherwise = Right value
 where
  value = Text.strip raw
