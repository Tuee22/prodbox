{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Typed coordinates and compare-and-swap boundary for retained Model-B
-- state.  The retained checkpoint authority and a selected workload-cluster
-- secret sink deliberately have unrelated constructors: a target endpoint can
-- never be substituted for the authority that owns the lease/checkpoint.
module Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError (..)
  , LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
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
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectCoordinate
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

import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

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

-- | A logical Model-B object rooted at the retained authority.  The logical
-- name is still fed through the encrypted-object/HMAC layer by the production
-- adapter; it is not a raw MinIO key.
data ModelBObjectCoordinate = ModelBObjectCoordinate
  { internalModelBObjectAuthority :: !LongLivedCheckpointAuthority
  , internalModelBObjectLogicalName :: !Text
  }
  deriving (Eq, Show)

mkModelBObjectCoordinate
  :: LongLivedCheckpointAuthority
  -> Text
  -> Either AuthorityCoordinateError ModelBObjectCoordinate
mkModelBObjectCoordinate authority logicalName =
  ModelBObjectCoordinate authority
    <$> validateCoordinate "model_b_logical_name" 512 logicalName

modelBObjectAuthority :: ModelBObjectCoordinate -> LongLivedCheckpointAuthority
modelBObjectAuthority = internalModelBObjectAuthority

modelBObjectLogicalName :: ModelBObjectCoordinate -> Text
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

data ModelBCasRequest value
  = ModelBInitialize !ModelBObjectCoordinate !value
  | ModelBReplace
      !ModelBObjectCoordinate
      !ModelBObjectVersion
      !value
  | ModelBInitializeGuarded
      !ModelBObjectCoordinate
      !ModelBLeaseGuard
      !value
  | ModelBReplaceGuarded
      !ModelBObjectCoordinate
      !ModelBObjectVersion
      !ModelBLeaseGuard
      !value
  deriving (Eq, Functor, Show)

-- | Lease evidence carried to the physical authority CAS endpoint.  The
-- daemon re-observes this exact lease object/version and validates the decoded
-- owner/fence/expiry immediately before accepting the target-object write.
-- It remains a cross-object guard, not a claim of multi-object atomicity.
data ModelBLeaseGuard = ModelBLeaseGuard
  { modelBLeaseGuardCoordinate :: !ModelBObjectCoordinate
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

-- | Injected production boundary.  Model-B payload encoding/encryption and
-- object-store conditional writes live behind these two operations; pure
-- lease/intent planners consume only the observations and requests above.
data ModelBCasAdapter m value = ModelBCasAdapter
  { modelBObserve
      :: ModelBObjectCoordinate
      -> m (ModelBObservation value)
  , modelBCompareAndSwap
      :: ModelBCasRequest value
      -> m (ModelBCasResult value)
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
