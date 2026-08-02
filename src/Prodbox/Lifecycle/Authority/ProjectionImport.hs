{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Production-safe import of the four legacy lifecycle projections.
--
-- A caller selects one member of the closed 'MigrationProjection' inventory;
-- it cannot submit projection bytes or a digest.  This interpreter observes the
-- legacy object, decodes it with the projection's real bounded/versioned codec,
-- initializes the replacement object, and authoritatively re-observes both
-- sides.  Only that verified read-back can be lowered to
-- 'RecordProjectionImport'.  A changed source revision or a different target
-- is a conflict: this boundary never overwrites either writer's state.
module Prodbox.Lifecycle.Authority.ProjectionImport
  ( ProjectionImportCodecConfig
  , ProjectionImportCodecConfigError (..)
  , ProjectionCodecError (..)
  , CanonicalProjection
  , canonicalProjectionBytes
  , canonicalProjectionEvidence
  , mkProjectionImportCodecConfig
  , productionCheckpointProjectionMaximumBytes
  , decodeCanonicalProjection
  , LegacyProjectionObservation (..)
  , LegacyProjectionSource (..)
  , ProjectionTargetObservation (..)
  , ProjectionTargetWriteResult (..)
  , ProjectionImportTarget (..)
  , ProjectionImportFailure (..)
  , ProjectionImportResult (..)
  , MigrationImportApplicationError (..)
  , MigrationImportCommandApplicator
  , mkMigrationImportCommandApplicator
  , runMigrationImportCommandApplicator
  , migrationRepositoryImportApplicator
  , MigrationProjectionCoordinates
  , MigrationProjectionCoordinateError (..)
  , mkMigrationProjectionCoordinates
  , migrationProjectionCoordinate
  , LegacyMigrationProjectionCoordinates
  , legacyMigrationLeaseCoordinate
  , legacyMigrationCheckpointCoordinate
  , legacyMigrationTargetIntentCoordinate
  , legacyMigrationSmtpCoordinate
  , mkLegacyMigrationProjectionCoordinates
  , ProductionProjectionImport
  , ProductionProjectionImportError (..)
  , mkProductionProjectionImport
  , productionProjectionImportCodecConfig
  , productionLegacyProjectionCoordinates
  , productionReplacementProjectionCoordinates
  , productionLegacyProjectionSource
  , productionProjectionImportTarget
  , LegacyProjectionAdapters (..)
  , legacyProjectionSourceFromAdapters
  , legacyProjectionSourceOverTransport
  , projectionImportTargetOverTransport
  , ProjectionShadowProof
  , projectionShadowDigest
  , projectionShadowEvidence
  , shadowCompareLegacyProjections
  , modelBLegacyProjectionSource
  , modelBProjectionImportTarget
  , importLegacyProjectionWithApplicator
  , importLegacyProjection
  , completeVerifiedProjectionImportsWithApplicator
  , completeVerifiedProjectionImports
  )
where

import Codec.Serialise (Serialise, serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isAsciiLower, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionCommandRefusal
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationDigest
  , MigrationImportCommand (..)
  , MigrationImportDecision
  , MigrationProjection
  , MigrationProjectionImport (..)
  , mkMigrationDigest
  )
import Prodbox.Lifecycle.Authority.Migration qualified as Migration
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationApplyError
  , MigrationImportApplyResult
  , MigrationRepository
  , applyMigrationImportCommand
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ChartLifetime, ClusterRetained)
  , checkpointAuthorityClusterId
  , mkChartLifetimeCoordinate
  , mkClusterRetainedCoordinate
  , modelBObjectAuthority
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.Lease
  ( LeaseKey
  , LeasePolicy
  , LeaseProjection
  , authorityTimeMicros
  , decodeLeaseProjection
  , encodeLeaseProjection
  , fencingTokenValue
  , leaseKeyAccount
  , leaseKeyRegion
  , leaseKeyResource
  , leaseObjectCoordinate
  , leaseProjectionReleasedPredecessor
  , ownerNonceText
  )
import Prodbox.Lifecycle.ModelBCasTransport
  ( ModelBTransport
  , modelBCasAdapterOverTransport
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( PulumiCheckpointCodecError (..)
  , PulumiCheckpointPayloadKind (..)
  , canonicalPulumiCheckpointBytes
  , decodeCanonicalPulumiCheckpoint
  , pulumiCheckpointMaximumBytes
  )
import Prodbox.Lifecycle.SmtpKeyRepair
  ( SmtpCommittedProjection
  , decodeSmtpCommittedProjection
  , encodeSmtpCommittedProjection
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CommittedTargetValue
  , RegisteredTargetSet
  , TargetCommitDisposition (..)
  , TargetCommitIntent
  , TargetIntentProjection
  , committedTargetDigest
  , committedTargetGeneration
  , credentialGenerationValue
  , decodeTargetIntentProjection
  , encodeTargetIntentProjection
  , mkTargetIntentCoordinate
  , targetCommitDeadline
  , targetCommitDigest
  , targetCommitDisposition
  , targetCommitFencingToken
  , targetCommitGeneration
  , targetCommitOwnerNonce
  , targetIntentCoordinateObject
  , targetProjectionEntries
  , targetProjectionEntryCommitted
  , targetProjectionEntryIntent
  , targetProjectionEntryTargetIdentity
  , targetValueDigestText
  )

-- | Pulumi checkpoints are the only projection whose native codec does not
-- publish a fixed maximum.  The limit remains explicit and is capped so a
-- mounted config cannot turn migration into an unbounded allocation.
newtype ProjectionImportCodecConfigError
  = CheckpointProjectionMaximumInvalid Int
  deriving stock (Eq, Show)

data ProjectionImportCodecConfig = ProjectionImportCodecConfig
  { projectionLeasePolicy :: !LeasePolicy
  , projectionRegisteredTargets :: !RegisteredTargetSet
  , projectionCheckpointMaximumBytes :: !Int
  }

mkProjectionImportCodecConfig
  :: LeasePolicy
  -> RegisteredTargetSet
  -> Int
  -> Either ProjectionImportCodecConfigError ProjectionImportCodecConfig
mkProjectionImportCodecConfig leasePolicy registeredTargets checkpointMaximum
  | checkpointMaximum <= 0 = Left (CheckpointProjectionMaximumInvalid checkpointMaximum)
  | checkpointMaximum > pulumiCheckpointMaximumBytes =
      Left (CheckpointProjectionMaximumInvalid checkpointMaximum)
  | otherwise =
      Right
        ProjectionImportCodecConfig
          { projectionLeasePolicy = leasePolicy
          , projectionRegisteredTargets = registeredTargets
          , projectionCheckpointMaximumBytes = checkpointMaximum
          }

-- | The compiled production ceiling for the legacy Pulumi checkpoint.  It is
-- deliberately not a request or mounted-config field.
productionCheckpointProjectionMaximumBytes :: Int
productionCheckpointProjectionMaximumBytes = pulumiCheckpointMaximumBytes

data ProjectionCodecError
  = ProjectionLeaseCodecInvalid !Text
  | ProjectionCheckpointTooLarge !Int !Int
  | ProjectionCheckpointInvalid !Text
  | ProjectionCheckpointUnsupportedVersion !Word
  | ProjectionTargetIntentCodecInvalid !Text
  | ProjectionSmtpCodecInvalid !Text
  deriving stock (Eq, Show)

data CanonicalProjection = CanonicalProjection
  { internalCanonicalProjectionBytes :: !ByteString
  , internalCanonicalProjectionEvidence :: !MigrationProjectionImport
  }
  deriving stock (Eq)

instance Show CanonicalProjection where
  show projection =
    "CanonicalProjection {canonicalProjectionByteLength = "
      ++ show (ByteString.length (internalCanonicalProjectionBytes projection))
      ++ ", canonicalProjectionEvidence = "
      ++ show (internalCanonicalProjectionEvidence projection)
      ++ "}"

canonicalProjectionBytes :: CanonicalProjection -> ByteString
canonicalProjectionBytes = internalCanonicalProjectionBytes

canonicalProjectionEvidence :: CanonicalProjection -> MigrationProjectionImport
canonicalProjectionEvidence = internalCanonicalProjectionEvidence

-- | Decode one projection with its production codec and return canonical bytes
-- plus semantic evidence.  Lease v1 is deliberately promoted to canonical v2;
-- target and SMTP codecs already reject non-canonical framing.  Pulumi JSON is
-- parsed, version-checked, and re-encoded to a deterministic Aeson value.
decodeCanonicalProjection
  :: ProjectionImportCodecConfig
  -> MigrationProjection
  -> ByteString
  -> Either ProjectionCodecError CanonicalProjection
decodeCanonicalProjection config projection bytes = case projection of
  Migration.LeaseProjection -> do
    lease <-
      mapLeft
        (ProjectionLeaseCodecInvalid . Text.pack . show)
        (decodeLeaseProjection (projectionLeasePolicy config) bytes)
    let canonical = encodeLeaseProjection lease
        evidence
          | Just _ <- leaseProjectionReleasedPredecessor lease =
              ProjectionReleasedPredecessor (projectionDigest projection canonical)
          | otherwise = ProjectionLegacy (projectionDigest projection canonical)
    pure (CanonicalProjection canonical evidence)
  Migration.CheckpointProjection -> do
    canonical <- decodeCheckpointProjection config bytes
    pure
      ( CanonicalProjection
          canonical
          (ProjectionLegacy (projectionDigest projection canonical))
      )
  Migration.TargetIntentProjection -> do
    target <-
      mapLeft
        (ProjectionTargetIntentCodecInvalid . Text.pack . show)
        (decodeTargetIntentProjection (projectionRegisteredTargets config) bytes)
    let canonical = encodeTargetIntentProjection target
        entries = targetProjectionEntries target
        staged =
          [ (targetProjectionEntryTargetIdentity entry, intent)
          | entry <- entries
          , intent <- maybeToList (targetProjectionEntryIntent entry)
          ]
        committed =
          [ (targetProjectionEntryTargetIdentity entry, value)
          | entry <- entries
          , value <- maybeToList (targetProjectionEntryCommitted entry)
          ]
        evidence =
          if null staged
            then ProjectionLegacy (projectionDigest projection canonical)
            else
              ProjectionStaged
                (projectionDigestWith "target-committed" (canonicalCommittedEvidence committed))
                (projectionDigestWith "target-staged" (canonicalStagedEvidence staged))
    pure (CanonicalProjection canonical evidence)
  Migration.SmtpProjection -> do
    smtp <-
      mapLeft
        (ProjectionSmtpCodecInvalid . Text.pack . show)
        (decodeSmtpCommittedProjection bytes)
    canonical <-
      mapLeft
        (ProjectionSmtpCodecInvalid . Text.pack . show)
        (encodeSmtpCommittedProjection smtp)
    pure
      ( CanonicalProjection
          canonical
          (ProjectionLegacy (projectionDigest projection canonical))
      )

decodeCheckpointProjection
  :: ProjectionImportCodecConfig
  -> ByteString
  -> Either ProjectionCodecError ByteString
decodeCheckpointProjection config bytes =
  canonicalPulumiCheckpointBytes
    <$> mapLeft
      projectionCheckpointError
      ( decodeCanonicalPulumiCheckpoint
          (Set.fromList [PulumiFileBackendCheckpoint, PulumiLegacyExportCheckpoint])
          (projectionCheckpointMaximumBytes config)
          bytes
      )
 where
  projectionCheckpointError err = case err of
    PulumiCheckpointTooLarge actual maximumBytes ->
      ProjectionCheckpointTooLarge actual maximumBytes
    PulumiCheckpointInvalid detail -> ProjectionCheckpointInvalid detail
    PulumiCheckpointUnsupportedVersion version ->
      ProjectionCheckpointUnsupportedVersion version
    PulumiCheckpointPayloadKindRefused kind ->
      ProjectionCheckpointInvalid
        ("checkpoint payload kind unexpectedly refused: " <> Text.pack (show kind))

data TargetCommittedEvidence = TargetCommittedEvidence !Text !Natural !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetStagedEvidence
  = TargetStagedEvidence
      !Text
      !Text
      !Natural
      !Natural
      !Text
      !Natural
      !Word8
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

canonicalCommittedEvidence
  :: [(Text, CommittedTargetValue)]
  -> ByteString
canonicalCommittedEvidence values =
  LazyByteString.toStrict
    ( serialise
        [ TargetCommittedEvidence
            identity
            (credentialGenerationValue (committedTargetGeneration committed))
            (targetValueDigestText (committedTargetDigest committed))
        | (identity, committed) <- values
        ]
    )

canonicalStagedEvidence
  :: [(Text, TargetCommitIntent)]
  -> ByteString
canonicalStagedEvidence values =
  LazyByteString.toStrict
    ( serialise
        [ TargetStagedEvidence
            identity
            (ownerNonceText (targetCommitOwnerNonce intent))
            (fencingTokenValue (targetCommitFencingToken intent))
            (credentialGenerationValue (targetCommitGeneration intent))
            (targetValueDigestText (targetCommitDigest intent))
            (authorityTimeMicros (targetCommitDeadline intent))
            (targetDispositionCode (targetCommitDisposition intent))
        | (identity, intent) <- values
        ]
    )

data LegacyProjectionObservation revision
  = LegacyProjectionMissing
  | LegacyProjectionObserved !revision !ByteString
  | LegacyProjectionCorrupt !Text
  | LegacyProjectionEndpointUnready !Text
  | LegacyProjectionUnobservable !Text
  deriving stock (Eq)

instance Show (LegacyProjectionObservation revision) where
  show observation = case observation of
    LegacyProjectionMissing -> "LegacyProjectionMissing"
    LegacyProjectionObserved _ bytes ->
      "LegacyProjectionObserved <revision> <" ++ show (ByteString.length bytes) ++ " bytes>"
    LegacyProjectionCorrupt detail -> "LegacyProjectionCorrupt " ++ show detail
    LegacyProjectionEndpointUnready detail ->
      "LegacyProjectionEndpointUnready " ++ show detail
    LegacyProjectionUnobservable detail -> "LegacyProjectionUnobservable " ++ show detail

newtype LegacyProjectionSource m revision = LegacyProjectionSource
  { observeLegacyProjection
      :: MigrationProjection
      -> m (LegacyProjectionObservation revision)
  }

data ProjectionTargetObservation revision
  = ProjectionTargetMissing
  | ProjectionTargetObserved !revision !ByteString
  | ProjectionTargetCorrupt !Text
  | ProjectionTargetEndpointUnready !Text
  | ProjectionTargetUnobservable !Text
  deriving stock (Eq)

instance Show (ProjectionTargetObservation revision) where
  show observation = case observation of
    ProjectionTargetMissing -> "ProjectionTargetMissing"
    ProjectionTargetObserved _ bytes ->
      "ProjectionTargetObserved <revision> <" ++ show (ByteString.length bytes) ++ " bytes>"
    ProjectionTargetCorrupt detail -> "ProjectionTargetCorrupt " ++ show detail
    ProjectionTargetEndpointUnready detail ->
      "ProjectionTargetEndpointUnready " ++ show detail
    ProjectionTargetUnobservable detail -> "ProjectionTargetUnobservable " ++ show detail

data ProjectionTargetWriteResult revision
  = ProjectionTargetWriteApplied !revision
  | ProjectionTargetWriteConflict !(ProjectionTargetObservation revision)
  | ProjectionTargetWriteRefusedCorrupt !Text
  | ProjectionTargetWriteEndpointUnready !Text
  | ProjectionTargetWriteUnobservable !Text
  deriving stock (Eq)

instance Show (ProjectionTargetWriteResult revision) where
  show result = case result of
    ProjectionTargetWriteApplied _ -> "ProjectionTargetWriteApplied <revision>"
    ProjectionTargetWriteConflict observed ->
      "ProjectionTargetWriteConflict (" ++ show observed ++ ")"
    ProjectionTargetWriteRefusedCorrupt detail ->
      "ProjectionTargetWriteRefusedCorrupt " ++ show detail
    ProjectionTargetWriteEndpointUnready detail ->
      "ProjectionTargetWriteEndpointUnready " ++ show detail
    ProjectionTargetWriteUnobservable detail ->
      "ProjectionTargetWriteUnobservable " ++ show detail

data ProjectionImportTarget m revision = ProjectionImportTarget
  { observeImportedProjection
      :: MigrationProjection
      -> m (ProjectionTargetObservation revision)
  , initializeImportedProjection
      :: MigrationProjection
      -> ByteString
      -> m (ProjectionTargetWriteResult revision)
  }

data ProjectionImportFailure
  = ProjectionImportSourceCorrupt !MigrationProjection !Text
  | ProjectionImportSourceCodecCorrupt !MigrationProjection !ProjectionCodecError
  | ProjectionImportSourceEndpointUnready !MigrationProjection !Text
  | ProjectionImportSourceUnobservable !MigrationProjection !Text
  | ProjectionImportSourceChanged !MigrationProjection
  | ProjectionImportShadowChanged !MigrationProjection
  | ProjectionImportTargetCorrupt !MigrationProjection !Text
  | ProjectionImportTargetCodecCorrupt !MigrationProjection !ProjectionCodecError
  | ProjectionImportTargetEndpointUnready !MigrationProjection !Text
  | ProjectionImportTargetUnobservable !MigrationProjection !Text
  | ProjectionImportTargetConflict
      !MigrationProjection
      !MigrationDigest
      !MigrationDigest
  | ProjectionImportTargetUnexpectedPresent !MigrationProjection
  | ProjectionImportTargetReadbackMissing !MigrationProjection
  | ProjectionImportTargetWriteRefused !MigrationProjection !Text
  | ProjectionImportMigrationStateFailed !MigrationImportApplicationError
  deriving stock (Eq, Show)

data ProjectionImportResult = ProjectionImportResult
  { projectionImportEvidence :: !MigrationProjectionImport
  , projectionImportStateResult :: !MigrationImportApplyResult
  }
  deriving stock (Eq, Show)

-- | Failure vocabulary for the closed import-command capability.  Aggregate
-- admission refusal is retained as its typed cause instead of being relabelled
-- as an I/O failure.  The compatibility constructor wraps errors from the
-- historical standalone migration repository explicitly.
data MigrationImportApplicationError
  = MigrationImportCompatibilityRepositoryFailed !MigrationApplyError
  | MigrationImportAuthorityReadFailed !Text
  | MigrationImportAuthorityWriteFailed !Text
  | MigrationImportAuthorityReadbackFailed !Text
  | MigrationImportAuthorityRefused !AuthorityAdmissionCommandRefusal
  | MigrationImportAuthorityProtocolViolation !Text
  | MigrationImportAuthorityReadbackDiverged
      !MigrationImportDecision
      !MigrationImportDecision
  deriving stock (Eq, Show)

-- | The only authority mutation capability needed by projection import.  The
-- importer cannot choose a retained object or perform a generic CAS; after it
-- has verified source and target read-back it can submit only the closed
-- 'MigrationImportCommand'.  Production binds this to the single retained
-- Authority admission aggregate, while the compatibility constructor below
-- keeps the pre-aggregate repository available to byte-compatibility tests.
newtype MigrationImportCommandApplicator m = MigrationImportCommandApplicator
  { runMigrationImportCommandApplicator
      :: MigrationImportCommand
      -> m (Either MigrationImportApplicationError MigrationImportApplyResult)
  }

mkMigrationImportCommandApplicator
  :: ( MigrationImportCommand
       -> m (Either MigrationImportApplicationError MigrationImportApplyResult)
     )
  -> MigrationImportCommandApplicator m
mkMigrationImportCommandApplicator = MigrationImportCommandApplicator

migrationRepositoryImportApplicator
  :: (Monad m)
  => Int
  -> MigrationRepository m revision
  -> MigrationImportCommandApplicator m
migrationRepositoryImportApplicator maximumBytes repository =
  MigrationImportCommandApplicator
    ( fmap (mapLeft MigrationImportCompatibilityRepositoryFailed)
        . applyMigrationImportCommand maximumBytes repository
    )

data MigrationProjectionCoordinates = MigrationProjectionCoordinates
  { migrationLeaseCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , migrationCheckpointCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , migrationTargetIntentCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , migrationSmtpCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  }
  deriving stock (Eq, Show)

data MigrationProjectionCoordinateError
  = MigrationProjectionCoordinateAuthorityMismatch !MigrationProjection
  | MigrationProjectionCoordinateWrongNamespace !MigrationProjection !Text
  deriving stock (Eq, Show)

mkMigrationProjectionCoordinates
  :: ModelBObjectCoordinate 'ClusterRetained
  -> ModelBObjectCoordinate 'ClusterRetained
  -> ModelBObjectCoordinate 'ClusterRetained
  -> ModelBObjectCoordinate 'ClusterRetained
  -> Either MigrationProjectionCoordinateError MigrationProjectionCoordinates
mkMigrationProjectionCoordinates lease checkpoint target smtp = do
  let pairs =
        [ (Migration.LeaseProjection, lease)
        , (Migration.CheckpointProjection, checkpoint)
        , (Migration.TargetIntentProjection, target)
        , (Migration.SmtpProjection, smtp)
        ]
      expectedAuthority = modelBObjectAuthority lease
  mapM_ (validateAuthority expectedAuthority) pairs
  mapM_ validateNamespace pairs
  Right
    MigrationProjectionCoordinates
      { migrationLeaseCoordinate = lease
      , migrationCheckpointCoordinate = checkpoint
      , migrationTargetIntentCoordinate = target
      , migrationSmtpCoordinate = smtp
      }
 where
  validateAuthority expected (projection, coordinate)
    | modelBObjectAuthority coordinate == expected = Right ()
    | otherwise = Left (MigrationProjectionCoordinateAuthorityMismatch projection)
  validateNamespace (projection, coordinate)
    | namespaceFor projection `Text.isPrefixOf` modelBObjectLogicalName coordinate = Right ()
    | otherwise =
        Left
          ( MigrationProjectionCoordinateWrongNamespace
              projection
              (modelBObjectLogicalName coordinate)
          )

migrationProjectionCoordinate
  :: MigrationProjectionCoordinates
  -> MigrationProjection
  -> ModelBObjectCoordinate 'ClusterRetained
migrationProjectionCoordinate coordinates projection = case projection of
  Migration.LeaseProjection -> migrationLeaseCoordinate coordinates
  Migration.CheckpointProjection -> migrationCheckpointCoordinate coordinates
  Migration.TargetIntentProjection -> migrationTargetIntentCoordinate coordinates
  Migration.SmtpProjection -> migrationSmtpCoordinate coordinates

namespaceFor :: MigrationProjection -> Text
namespaceFor projection = case projection of
  Migration.LeaseProjection -> "leases/"
  Migration.CheckpointProjection -> "pulumi-stack/"
  Migration.TargetIntentProjection -> "target-commit-intents/"
  Migration.SmtpProjection -> "smtp-commit/"

-- | Exact coordinates of the pre-cutover projection inventory.  The Pulumi
-- checkpoint is deliberately chart-lifetime on the legacy side; lease,
-- target-intent, and SMTP state are retained.  Keeping this record distinct
-- from 'MigrationProjectionCoordinates' prevents a production importer from
-- relabelling the old checkpoint as retained merely to fit one homogeneous
-- adapter.
data LegacyMigrationProjectionCoordinates = LegacyMigrationProjectionCoordinates
  { legacyMigrationLeaseCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , legacyMigrationCheckpointCoordinate :: !(ModelBObjectCoordinate 'ChartLifetime)
  , legacyMigrationTargetIntentCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , legacyMigrationSmtpCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  }
  deriving stock (Eq, Show)

mkLegacyMigrationProjectionCoordinates
  :: ModelBObjectCoordinate 'ClusterRetained
  -> ModelBObjectCoordinate 'ChartLifetime
  -> ModelBObjectCoordinate 'ClusterRetained
  -> ModelBObjectCoordinate 'ClusterRetained
  -> Either MigrationProjectionCoordinateError LegacyMigrationProjectionCoordinates
mkLegacyMigrationProjectionCoordinates lease checkpoint target smtp = do
  let expectedAuthority = modelBObjectAuthority lease
  validateCoordinate expectedAuthority Migration.LeaseProjection lease
  validateCoordinate expectedAuthority Migration.CheckpointProjection checkpoint
  validateCoordinate expectedAuthority Migration.TargetIntentProjection target
  validateCoordinate expectedAuthority Migration.SmtpProjection smtp
  Right
    LegacyMigrationProjectionCoordinates
      { legacyMigrationLeaseCoordinate = lease
      , legacyMigrationCheckpointCoordinate = checkpoint
      , legacyMigrationTargetIntentCoordinate = target
      , legacyMigrationSmtpCoordinate = smtp
      }
 where
  validateCoordinate expected projection coordinate
    | modelBObjectAuthority coordinate /= expected =
        Left (MigrationProjectionCoordinateAuthorityMismatch projection)
    | namespaceFor projection `Text.isPrefixOf` modelBObjectLogicalName coordinate = Right ()
    | otherwise =
        Left
          ( MigrationProjectionCoordinateWrongNamespace
              projection
              (modelBObjectLogicalName coordinate)
          )

-- | Complete, validated construction inputs for the one production legacy
-- projection family.  The old and replacement stores may have different
-- physical endpoints, buckets, namespaces, and Vault keyspaces, but they must
-- describe the same authority scope.  The object inventory itself is closed:
-- the lease key must name @aws-ses@ and the checkpoint logical name cannot be
-- supplied by an HTTP caller or mounted free-form object list.
data ProductionProjectionImport = ProductionProjectionImport
  { internalProductionProjectionImportCodecConfig :: !ProjectionImportCodecConfig
  , internalProductionLegacyProjectionCoordinates :: !LegacyMigrationProjectionCoordinates
  , internalProductionReplacementProjectionCoordinates :: !MigrationProjectionCoordinates
  }

data ProductionProjectionImportError
  = ProductionProjectionImportScopeMismatch !Text !Text
  | ProductionProjectionImportAccountInvalid
  | ProductionProjectionImportRegionInvalid
  | ProductionProjectionImportResourceUnsupported !Text
  | ProductionProjectionImportCodecInvalid !ProjectionImportCodecConfigError
  | ProductionProjectionImportCoordinateInvalid !AuthorityCoordinateError
  | ProductionProjectionImportCoordinateSetInvalid !MigrationProjectionCoordinateError
  deriving stock (Eq, Show)

mkProductionProjectionImport
  :: LongLivedCheckpointAuthority
  -> LongLivedCheckpointAuthority
  -> LeaseKey
  -> LeasePolicy
  -> RegisteredTargetSet
  -> Int
  -> Either ProductionProjectionImportError ProductionProjectionImport
mkProductionProjectionImport
  legacyAuthority
  replacementAuthority
  leaseKey
  leasePolicy
  registeredTargets
  checkpointMaximum
    | leaseKeyResource leaseKey /= productionProjectionResource =
        Left
          ( ProductionProjectionImportResourceUnsupported
              (leaseKeyResource leaseKey)
          )
    | not (validAwsAccountId (leaseKeyAccount leaseKey)) =
        Left ProductionProjectionImportAccountInvalid
    | not (validAwsRegion (leaseKeyRegion leaseKey)) =
        Left ProductionProjectionImportRegionInvalid
    | legacyScope /= replacementScope =
        Left
          ( ProductionProjectionImportScopeMismatch
              legacyScope
              replacementScope
          )
    | otherwise = do
        config <-
          mapLeft
            ProductionProjectionImportCodecInvalid
            ( mkProjectionImportCodecConfig
                leasePolicy
                registeredTargets
                checkpointMaximum
            )
        legacyCoordinates <-
          buildLegacyCoordinates legacyAuthority leaseKey
        replacementCoordinates <-
          buildReplacementCoordinates replacementAuthority leaseKey
        Right
          ProductionProjectionImport
            { internalProductionProjectionImportCodecConfig = config
            , internalProductionLegacyProjectionCoordinates = legacyCoordinates
            , internalProductionReplacementProjectionCoordinates = replacementCoordinates
            }
   where
    legacyScope = checkpointAuthorityClusterId legacyAuthority
    replacementScope = checkpointAuthorityClusterId replacementAuthority

validAwsAccountId :: Text -> Bool
validAwsAccountId value =
  Text.length value == 12
    && Text.all (\character -> isAscii character && isDigit character) value

validAwsRegion :: Text -> Bool
validAwsRegion value =
  case (Text.uncons value, Text.unsnoc value) of
    (Just (first, _), Just (_, lastCharacter)) ->
      Text.length value <= 63
        && Text.all validCharacter value
        && first /= '-'
        && lastCharacter /= '-'
    _ -> False
 where
  validCharacter character =
    isAscii character
      && (isAsciiLower character || isDigit character || character == '-')

productionProjectionResource :: Text
productionProjectionResource = "aws-ses"

productionCheckpointLogicalName :: Text
productionCheckpointLogicalName = "pulumi-stack/aws-ses"

productionProjectionImportCodecConfig
  :: ProductionProjectionImport
  -> ProjectionImportCodecConfig
productionProjectionImportCodecConfig =
  internalProductionProjectionImportCodecConfig

productionLegacyProjectionCoordinates
  :: ProductionProjectionImport
  -> LegacyMigrationProjectionCoordinates
productionLegacyProjectionCoordinates =
  internalProductionLegacyProjectionCoordinates

productionReplacementProjectionCoordinates
  :: ProductionProjectionImport
  -> MigrationProjectionCoordinates
productionReplacementProjectionCoordinates =
  internalProductionReplacementProjectionCoordinates

-- | Instantiate the typed legacy source against the physical pre-cutover
-- transport selected by startup configuration.
productionLegacyProjectionSource
  :: ModelBTransport
  -> ProductionProjectionImport
  -> LegacyProjectionSource IO ModelBObjectVersion
productionLegacyProjectionSource transport production =
  legacyProjectionSourceOverTransport
    (productionProjectionImportCodecConfig production)
    transport
    (productionLegacyProjectionCoordinates production)

-- | Instantiate the initialize-only replacement target against the dedicated
-- Lifecycle Authority store selected by startup configuration.
productionProjectionImportTarget
  :: ModelBTransport
  -> ProductionProjectionImport
  -> ProjectionImportTarget IO ModelBObjectVersion
productionProjectionImportTarget transport production =
  projectionImportTargetOverTransport
    transport
    (productionReplacementProjectionCoordinates production)

buildLegacyCoordinates
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> Either ProductionProjectionImportError LegacyMigrationProjectionCoordinates
buildLegacyCoordinates authority leaseKey = do
  lease <- coordinate (leaseObjectCoordinate authority leaseKey)
  checkpoint <-
    coordinate
      (mkChartLifetimeCoordinate authority productionCheckpointLogicalName)
  target <- coordinate (targetProjectionCoordinate authority leaseKey)
  smtp <- coordinate (smtpProjectionCoordinate authority leaseKey)
  mapLeft
    ProductionProjectionImportCoordinateSetInvalid
    (mkLegacyMigrationProjectionCoordinates lease checkpoint target smtp)
 where
  coordinate = mapLeft ProductionProjectionImportCoordinateInvalid

buildReplacementCoordinates
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> Either ProductionProjectionImportError MigrationProjectionCoordinates
buildReplacementCoordinates authority leaseKey = do
  lease <- coordinate (leaseObjectCoordinate authority leaseKey)
  checkpoint <-
    coordinate
      (mkClusterRetainedCoordinate authority productionCheckpointLogicalName)
  target <- coordinate (targetProjectionCoordinate authority leaseKey)
  smtp <- coordinate (smtpProjectionCoordinate authority leaseKey)
  mapLeft
    ProductionProjectionImportCoordinateSetInvalid
    (mkMigrationProjectionCoordinates lease checkpoint target smtp)
 where
  coordinate = mapLeft ProductionProjectionImportCoordinateInvalid

targetProjectionCoordinate
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> Either AuthorityCoordinateError (ModelBObjectCoordinate 'ClusterRetained)
targetProjectionCoordinate authority leaseKey =
  targetIntentCoordinateObject <$> mkTargetIntentCoordinate authority leaseKey

smtpProjectionCoordinate
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> Either AuthorityCoordinateError (ModelBObjectCoordinate 'ClusterRetained)
smtpProjectionCoordinate authority leaseKey =
  mkClusterRetainedCoordinate
    authority
    ( Text.intercalate
        "/"
        [ "smtp-commit"
        , leaseKeyAccount leaseKey
        , leaseKeyRegion leaseKey
        , leaseKeyResource leaseKey
        ]
    )

-- | The four typed pre-cutover readers.  The adapter payloads are the real
-- domain projections rather than unvalidated bytes, so the source can emit
-- canonical bytes only after each production codec has accepted the object.
data LegacyProjectionAdapters m = LegacyProjectionAdapters
  { legacyLeaseProjectionAdapter
      :: !(ModelBCasAdapter 'ClusterRetained m LeaseProjection)
  , legacyCheckpointProjectionAdapter
      :: !(ModelBCasAdapter 'ChartLifetime m ByteString)
  , legacyTargetIntentProjectionAdapter
      :: !(ModelBCasAdapter 'ClusterRetained m TargetIntentProjection)
  , legacySmtpProjectionAdapter
      :: !(ModelBCasAdapter 'ClusterRetained m SmtpCommittedProjection)
  }

legacyProjectionSourceFromAdapters
  :: (Monad m)
  => LegacyProjectionAdapters m
  -> LegacyMigrationProjectionCoordinates
  -> LegacyProjectionSource m ModelBObjectVersion
legacyProjectionSourceFromAdapters adapters coordinates =
  LegacyProjectionSource (observeProjectionFromAdapters adapters coordinates)

observeProjectionFromAdapters
  :: (Monad m)
  => LegacyProjectionAdapters m
  -> LegacyMigrationProjectionCoordinates
  -> MigrationProjection
  -> m (LegacyProjectionObservation ModelBObjectVersion)
observeProjectionFromAdapters adapters coordinates projection = case projection of
  Migration.LeaseProjection -> do
    observed <-
      modelBObserve
        (legacyLeaseProjectionAdapter adapters)
        (legacyMigrationLeaseCoordinate coordinates)
    pure (encodeLegacyObservation (Right . encodeLeaseProjection) observed)
  Migration.CheckpointProjection -> do
    observed <-
      modelBObserve
        (legacyCheckpointProjectionAdapter adapters)
        (legacyMigrationCheckpointCoordinate coordinates)
    pure (encodeLegacyObservation Right observed)
  Migration.TargetIntentProjection -> do
    observed <-
      modelBObserve
        (legacyTargetIntentProjectionAdapter adapters)
        (legacyMigrationTargetIntentCoordinate coordinates)
    pure (encodeLegacyObservation (Right . encodeTargetIntentProjection) observed)
  Migration.SmtpProjection -> do
    observed <-
      modelBObserve
        (legacySmtpProjectionAdapter adapters)
        (legacyMigrationSmtpCoordinate coordinates)
    pure
      ( encodeLegacyObservation
          (mapLeft (Text.pack . show) . encodeSmtpCommittedProjection)
          observed
      )

encodeLegacyObservation
  :: (value -> Either Text ByteString)
  -> ModelBObservation value
  -> LegacyProjectionObservation ModelBObjectVersion
encodeLegacyObservation encodeValue observed = case observed of
  ModelBMissing -> LegacyProjectionMissing
  ModelBObserved revision value ->
    case encodeValue value of
      Left detail -> LegacyProjectionCorrupt detail
      Right bytes -> LegacyProjectionObserved revision bytes
  ModelBCorrupt detail -> LegacyProjectionCorrupt detail
  ModelBEndpointUnready detail -> LegacyProjectionEndpointUnready detail
  ModelBUnobservable detail -> LegacyProjectionUnobservable detail

-- | Production constructor over a physical legacy transport.  It instantiates
-- each typed adapter with the exact codec and lifetime dictated by the closed
-- projection inventory.
legacyProjectionSourceOverTransport
  :: ProjectionImportCodecConfig
  -> ModelBTransport
  -> LegacyMigrationProjectionCoordinates
  -> LegacyProjectionSource IO ModelBObjectVersion
legacyProjectionSourceOverTransport config transport coordinates =
  legacyProjectionSourceFromAdapters adapters coordinates
 where
  authority = modelBObjectAuthority (legacyMigrationLeaseCoordinate coordinates)
  adapters =
    LegacyProjectionAdapters
      { legacyLeaseProjectionAdapter =
          modelBCasAdapterOverTransport authority transport leaseCodec
      , legacyCheckpointProjectionAdapter =
          modelBCasAdapterOverTransport authority transport byteStringProjectionCodec
      , legacyTargetIntentProjectionAdapter =
          modelBCasAdapterOverTransport authority transport targetIntentCodec
      , legacySmtpProjectionAdapter =
          modelBCasAdapterOverTransport authority transport smtpCodec
      }
  leaseCodec =
    ModelBCodec
      { encodeModelBValue = Right . encodeLeaseProjection
      , decodeModelBValue =
          mapLeft show . decodeLeaseProjection (projectionLeasePolicy config)
      }
  targetIntentCodec =
    ModelBCodec
      { encodeModelBValue = Right . encodeTargetIntentProjection
      , decodeModelBValue =
          mapLeft show
            . decodeTargetIntentProjection (projectionRegisteredTargets config)
      }
  smtpCodec =
    ModelBCodec
      { encodeModelBValue = mapLeft show . encodeSmtpCommittedProjection
      , decodeModelBValue = mapLeft show . decodeSmtpCommittedProjection
      }

-- | Production replacement target over its own physical transport.  Every
-- write is still initialize-only and every successful response is followed by
-- the exact read-back performed by 'importLegacyProjection'.
projectionImportTargetOverTransport
  :: ModelBTransport
  -> MigrationProjectionCoordinates
  -> ProjectionImportTarget IO ModelBObjectVersion
projectionImportTargetOverTransport transport coordinates =
  modelBProjectionImportTarget
    ( modelBCasAdapterOverTransport
        authority
        transport
        byteStringProjectionCodec
    )
    coordinates
 where
  authority = modelBObjectAuthority (migrationLeaseCoordinate coordinates)

byteStringProjectionCodec :: ModelBCodec ByteString
byteStringProjectionCodec =
  ModelBCodec
    { encodeModelBValue = Right
    , decodeModelBValue = Right
    }

modelBLegacyProjectionSource
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m ByteString
  -> MigrationProjectionCoordinates
  -> LegacyProjectionSource m ModelBObjectVersion
modelBLegacyProjectionSource adapter coordinates =
  LegacyProjectionSource $ \projection -> do
    observed <- modelBObserve adapter (migrationProjectionCoordinate coordinates projection)
    pure $ case observed of
      ModelBMissing -> LegacyProjectionMissing
      ModelBObserved revision bytes -> LegacyProjectionObserved revision bytes
      ModelBCorrupt detail -> LegacyProjectionCorrupt detail
      ModelBEndpointUnready detail -> LegacyProjectionEndpointUnready detail
      ModelBUnobservable detail -> LegacyProjectionUnobservable detail

modelBProjectionImportTarget
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m ByteString
  -> MigrationProjectionCoordinates
  -> ProjectionImportTarget m ModelBObjectVersion
modelBProjectionImportTarget adapter coordinates =
  ProjectionImportTarget
    { observeImportedProjection = \projection -> do
        observed <- modelBObserve adapter (migrationProjectionCoordinate coordinates projection)
        pure (targetObservationFromModelB observed)
    , initializeImportedProjection = \projection bytes -> do
        written <-
          modelBCompareAndSwap
            adapter
            ( ModelBInitialize
                (migrationProjectionCoordinate coordinates projection)
                bytes
            )
        pure $ case written of
          ModelBCasApplied revision _ -> ProjectionTargetWriteApplied revision
          ModelBCasConflict observed ->
            ProjectionTargetWriteConflict (targetObservationFromModelB observed)
          ModelBCasRefusedCorrupt detail -> ProjectionTargetWriteRefusedCorrupt detail
          ModelBCasEndpointUnready detail -> ProjectionTargetWriteEndpointUnready detail
          ModelBCasUnobservable detail -> ProjectionTargetWriteUnobservable detail
    }

targetObservationFromModelB
  :: ModelBObservation ByteString
  -> ProjectionTargetObservation ModelBObjectVersion
targetObservationFromModelB observed = case observed of
  ModelBMissing -> ProjectionTargetMissing
  ModelBObserved revision bytes -> ProjectionTargetObserved revision bytes
  ModelBCorrupt detail -> ProjectionTargetCorrupt detail
  ModelBEndpointUnready detail -> ProjectionTargetEndpointUnready detail
  ModelBUnobservable detail -> ProjectionTargetUnobservable detail

data ProjectionShadowSnapshot sourceRevision targetRevision
  = ProjectionShadowMissing
  | ProjectionShadowObserved
      !sourceRevision
      !targetRevision
      !CanonicalProjection
  deriving stock (Eq)

-- | Opaque evidence from two equal, complete passes over all four source and
-- replacement projections.  Revisions participate in equality while the
-- exported proof retains only semantic evidence and its deterministic digest.
data ProjectionShadowProof = ProjectionShadowProof
  { internalProjectionShadowDigest :: !MigrationDigest
  , internalProjectionShadowEvidence
      :: !(Map MigrationProjection MigrationProjectionImport)
  }
  deriving stock (Eq, Show)

projectionShadowDigest :: ProjectionShadowProof -> MigrationDigest
projectionShadowDigest = internalProjectionShadowDigest

projectionShadowEvidence
  :: ProjectionShadowProof
  -> Map MigrationProjection MigrationProjectionImport
projectionShadowEvidence = internalProjectionShadowEvidence

-- | Read the complete source/target inventory twice.  Each pass compares the
-- canonical bytes, and the passes must retain identical source and target
-- revisions.  A caller performs this once before writer suspension and again
-- after quiescence; the cutover orchestrator requires the digest to remain
-- unchanged before it can freeze or activate the replacement.
shadowCompareLegacyProjections
  :: (Monad m, Eq sourceRevision, Eq targetRevision)
  => ProjectionImportCodecConfig
  -> LegacyProjectionSource m sourceRevision
  -> ProjectionImportTarget m targetRevision
  -> m (Either ProjectionImportFailure ProjectionShadowProof)
shadowCompareLegacyProjections config source target = do
  first <- shadowPass
  case first of
    Left failure -> pure (Left failure)
    Right firstSnapshots -> do
      second <- shadowPass
      pure $ do
        secondSnapshots <- second
        case firstChangedProjection firstSnapshots secondSnapshots of
          Just projection -> Left (ProjectionImportShadowChanged projection)
          Nothing ->
            let evidence =
                  Map.fromAscList
                    [ (projection, shadowSnapshotEvidence snapshot)
                    | (projection, snapshot) <- firstSnapshots
                    ]
                digestBytes =
                  LazyByteString.toStrict
                    (serialise (Map.toAscList evidence))
             in Right
                  ProjectionShadowProof
                    { internalProjectionShadowDigest =
                        projectionDigestWith
                          "projection-shadow"
                          digestBytes
                    , internalProjectionShadowEvidence = evidence
                    }
 where
  shadowPass =
    fmap sequence $
      traverse
        ( \projection ->
            fmap (projection,)
              <$> observeProjectionShadow projection
        )
        [minBound .. maxBound]

  observeProjectionShadow projection = do
    sourceObservation <- observeLegacyProjection source projection
    targetObservation <- observeImportedProjection target projection
    pure $ case sourceObservation of
      LegacyProjectionMissing -> case targetObservation of
        ProjectionTargetMissing -> Right ProjectionShadowMissing
        ProjectionTargetObserved {} ->
          Left (ProjectionImportTargetUnexpectedPresent projection)
        other -> Left (targetObservationFailure projection other)
      LegacyProjectionObserved sourceRevision sourceBytes ->
        case decodeCanonicalProjection config projection sourceBytes of
          Left codecError ->
            Left (ProjectionImportSourceCodecCorrupt projection codecError)
          Right canonical -> case targetObservation of
            ProjectionTargetObserved targetRevision targetBytes ->
              case targetBytesMatch config projection canonical targetBytes of
                Just failure -> Left failure
                Nothing ->
                  Right
                    ( ProjectionShadowObserved
                        sourceRevision
                        targetRevision
                        canonical
                    )
            ProjectionTargetMissing ->
              Left (ProjectionImportTargetReadbackMissing projection)
            other -> Left (targetObservationFailure projection other)
      LegacyProjectionCorrupt detail ->
        Left (ProjectionImportSourceCorrupt projection detail)
      LegacyProjectionEndpointUnready detail ->
        Left (ProjectionImportSourceEndpointUnready projection detail)
      LegacyProjectionUnobservable detail ->
        Left (ProjectionImportSourceUnobservable projection detail)

firstChangedProjection
  :: (Eq sourceRevision, Eq targetRevision)
  => [(MigrationProjection, ProjectionShadowSnapshot sourceRevision targetRevision)]
  -> [(MigrationProjection, ProjectionShadowSnapshot sourceRevision targetRevision)]
  -> Maybe MigrationProjection
firstChangedProjection first second =
  case [ projection
       | ((projection, left), (otherProjection, right)) <- zip first second
       , projection /= otherProjection || left /= right
       ] of
    projection : _ -> Just projection
    []
      | length first == length second -> Nothing
      | otherwise -> Just Migration.LeaseProjection

shadowSnapshotEvidence
  :: ProjectionShadowSnapshot sourceRevision targetRevision
  -> MigrationProjectionImport
shadowSnapshotEvidence snapshot = case snapshot of
  ProjectionShadowMissing -> ProjectionMissing
  ProjectionShadowObserved _ _ canonical -> canonicalProjectionEvidence canonical

-- | Import one member of the closed projection inventory.  The migration state
-- CAS is the last effect and is unreachable until the two source observations
-- agree and the target has returned matching canonical bytes.
importLegacyProjectionWithApplicator
  :: (Monad m, Eq sourceRevision)
  => ProjectionImportCodecConfig
  -> MigrationImportCommandApplicator m
  -> LegacyProjectionSource m sourceRevision
  -> ProjectionImportTarget m targetRevision
  -> MigrationProjection
  -> m (Either ProjectionImportFailure ProjectionImportResult)
importLegacyProjectionWithApplicator config applicator source target projection = do
  firstSource <- observeLegacyProjection source projection
  case firstSource of
    LegacyProjectionMissing -> importMissingProjection
    LegacyProjectionObserved sourceRevision sourceBytes ->
      case decodeCanonicalProjection config projection sourceBytes of
        Left codecError ->
          pure (Left (ProjectionImportSourceCodecCorrupt projection codecError))
        Right canonical -> importObservedProjection sourceRevision canonical
    LegacyProjectionCorrupt detail ->
      pure (Left (ProjectionImportSourceCorrupt projection detail))
    LegacyProjectionEndpointUnready detail ->
      pure (Left (ProjectionImportSourceEndpointUnready projection detail))
    LegacyProjectionUnobservable detail ->
      pure (Left (ProjectionImportSourceUnobservable projection detail))
 where
  importMissingProjection = do
    firstTarget <- observeImportedProjection target projection
    case firstTarget of
      ProjectionTargetMissing -> do
        stableSource <- observeLegacyProjection source projection
        case stableSource of
          LegacyProjectionMissing -> do
            stableTarget <- observeImportedProjection target projection
            case stableTarget of
              ProjectionTargetMissing -> recordEvidence ProjectionMissing
              ProjectionTargetObserved {} ->
                pure (Left (ProjectionImportTargetUnexpectedPresent projection))
              other -> pure (Left (targetObservationFailure projection other))
          _ -> pure (Left (sourceChangedFailure projection stableSource))
      ProjectionTargetObserved {} ->
        pure (Left (ProjectionImportTargetUnexpectedPresent projection))
      other -> pure (Left (targetObservationFailure projection other))

  importObservedProjection sourceRevision canonical = do
    firstTarget <- observeImportedProjection target projection
    targetPreparation <- case firstTarget of
      ProjectionTargetMissing -> do
        writeResult <-
          initializeImportedProjection
            target
            projection
            (canonicalProjectionBytes canonical)
        pure (Right (targetWriteFailure projection writeResult))
      ProjectionTargetObserved _ targetBytes ->
        pure $ case targetBytesMatch config projection canonical targetBytes of
          Nothing -> Right Nothing
          Just failure -> Left failure
      other -> pure (Left (targetObservationFailure projection other))
    case targetPreparation of
      Left failure -> pure (Left failure)
      Right writeFailure -> do
        stableSource <- observeLegacyProjection source projection
        case validateStableSource config projection sourceRevision canonical stableSource of
          Left failure -> pure (Left failure)
          Right () -> do
            readback <- observeImportedProjection target projection
            case validateTargetReadback config projection canonical readback of
              Right () -> recordEvidence (canonicalProjectionEvidence canonical)
              Left readbackFailure ->
                pure
                  ( Left
                      ( case writeFailure of
                          Just original
                            | readbackFailure == ProjectionImportTargetReadbackMissing projection ->
                                original
                          _ -> readbackFailure
                      )
                  )

  recordEvidence evidence = do
    applied <-
      runMigrationImportCommandApplicator
        applicator
        (RecordProjectionImport projection evidence)
    pure $ case applied of
      Left err -> Left (ProjectionImportMigrationStateFailed err)
      Right result ->
        Right
          ProjectionImportResult
            { projectionImportEvidence = evidence
            , projectionImportStateResult = result
            }

-- | Compatibility entrypoint for fixtures that still model the migration
-- projection as its historical standalone retained object.  Production uses
-- 'importLegacyProjectionWithApplicator' with the aggregate-backed applicator.
importLegacyProjection
  :: (Monad m, Eq sourceRevision)
  => ProjectionImportCodecConfig
  -> Int
  -> MigrationRepository m migrationRevision
  -> LegacyProjectionSource m sourceRevision
  -> ProjectionImportTarget m targetRevision
  -> MigrationProjection
  -> m (Either ProjectionImportFailure ProjectionImportResult)
importLegacyProjection config maximumBytes repository =
  importLegacyProjectionWithApplicator
    config
    (migrationRepositoryImportApplicator maximumBytes repository)

completeVerifiedProjectionImportsWithApplicator
  :: MigrationImportCommandApplicator m
  -> m (Either MigrationImportApplicationError MigrationImportApplyResult)
completeVerifiedProjectionImportsWithApplicator applicator =
  runMigrationImportCommandApplicator applicator CompleteProjectionImports

-- | Compatibility completion entrypoint over the historical standalone
-- migration repository.
completeVerifiedProjectionImports
  :: (Monad m)
  => Int
  -> MigrationRepository m revision
  -> m (Either MigrationApplyError MigrationImportApplyResult)
completeVerifiedProjectionImports maximumBytes repository =
  applyMigrationImportCommand maximumBytes repository CompleteProjectionImports

validateStableSource
  :: (Eq revision)
  => ProjectionImportCodecConfig
  -> MigrationProjection
  -> revision
  -> CanonicalProjection
  -> LegacyProjectionObservation revision
  -> Either ProjectionImportFailure ()
validateStableSource config projection expectedRevision expected observed = case observed of
  LegacyProjectionObserved revision bytes
    | revision /= expectedRevision -> Left (ProjectionImportSourceChanged projection)
    | otherwise ->
        case decodeCanonicalProjection config projection bytes of
          Left err -> Left (ProjectionImportSourceCodecCorrupt projection err)
          Right actual
            | canonicalProjectionBytes actual == canonicalProjectionBytes expected -> Right ()
            | otherwise -> Left (ProjectionImportSourceChanged projection)
  LegacyProjectionCorrupt detail -> Left (ProjectionImportSourceCorrupt projection detail)
  LegacyProjectionEndpointUnready detail ->
    Left (ProjectionImportSourceEndpointUnready projection detail)
  LegacyProjectionUnobservable detail ->
    Left (ProjectionImportSourceUnobservable projection detail)
  LegacyProjectionMissing -> Left (ProjectionImportSourceChanged projection)

validateTargetReadback
  :: ProjectionImportCodecConfig
  -> MigrationProjection
  -> CanonicalProjection
  -> ProjectionTargetObservation revision
  -> Either ProjectionImportFailure ()
validateTargetReadback config projection expected observed = case observed of
  ProjectionTargetMissing -> Left (ProjectionImportTargetReadbackMissing projection)
  ProjectionTargetObserved _ bytes ->
    maybeToEither () (targetBytesMatch config projection expected bytes)
  ProjectionTargetCorrupt detail -> Left (ProjectionImportTargetCorrupt projection detail)
  ProjectionTargetEndpointUnready detail ->
    Left (ProjectionImportTargetEndpointUnready projection detail)
  ProjectionTargetUnobservable detail ->
    Left (ProjectionImportTargetUnobservable projection detail)

targetBytesMatch
  :: ProjectionImportCodecConfig
  -> MigrationProjection
  -> CanonicalProjection
  -> ByteString
  -> Maybe ProjectionImportFailure
targetBytesMatch config projection expected bytes =
  case decodeCanonicalProjection config projection bytes of
    Left err -> Just (ProjectionImportTargetCodecCorrupt projection err)
    Right actual
      | canonicalProjectionBytes actual == canonicalProjectionBytes expected -> Nothing
      | otherwise ->
          Just
            ( ProjectionImportTargetConflict
                projection
                (projectionDigest projection (canonicalProjectionBytes expected))
                (projectionDigest projection (canonicalProjectionBytes actual))
            )

targetObservationFailure
  :: MigrationProjection
  -> ProjectionTargetObservation revision
  -> ProjectionImportFailure
targetObservationFailure projection observed = case observed of
  ProjectionTargetCorrupt detail -> ProjectionImportTargetCorrupt projection detail
  ProjectionTargetEndpointUnready detail ->
    ProjectionImportTargetEndpointUnready projection detail
  ProjectionTargetUnobservable detail -> ProjectionImportTargetUnobservable projection detail
  ProjectionTargetMissing -> ProjectionImportTargetReadbackMissing projection
  ProjectionTargetObserved {} -> ProjectionImportTargetUnexpectedPresent projection

sourceChangedFailure
  :: MigrationProjection
  -> LegacyProjectionObservation revision
  -> ProjectionImportFailure
sourceChangedFailure projection observed = case observed of
  LegacyProjectionCorrupt detail -> ProjectionImportSourceCorrupt projection detail
  LegacyProjectionEndpointUnready detail ->
    ProjectionImportSourceEndpointUnready projection detail
  LegacyProjectionUnobservable detail -> ProjectionImportSourceUnobservable projection detail
  LegacyProjectionMissing -> ProjectionImportSourceChanged projection
  LegacyProjectionObserved {} -> ProjectionImportSourceChanged projection

targetWriteFailure
  :: MigrationProjection
  -> ProjectionTargetWriteResult revision
  -> Maybe ProjectionImportFailure
targetWriteFailure projection result = case result of
  ProjectionTargetWriteApplied _ -> Nothing
  ProjectionTargetWriteConflict observed -> Just (targetObservationFailure projection observed)
  ProjectionTargetWriteRefusedCorrupt detail ->
    Just (ProjectionImportTargetWriteRefused projection detail)
  ProjectionTargetWriteEndpointUnready detail ->
    Just (ProjectionImportTargetEndpointUnready projection detail)
  ProjectionTargetWriteUnobservable detail ->
    Just (ProjectionImportTargetUnobservable projection detail)

projectionDigest :: MigrationProjection -> ByteString -> MigrationDigest
projectionDigest projection =
  projectionDigestWith (projectionDigestDomain projection)

projectionDigestWith :: ByteString -> ByteString -> MigrationDigest
projectionDigestWith domain bytes =
  case mkMigrationDigest (sha256Hex ("prodbox-migration-projection-v1:" <> domain <> ":" <> bytes)) of
    Just digest -> digest
    Nothing -> error "internal projection SHA-256 digest did not satisfy MigrationDigest"

projectionDigestDomain :: MigrationProjection -> ByteString
projectionDigestDomain projection = case projection of
  Migration.LeaseProjection -> "lease"
  Migration.CheckpointProjection -> "checkpoint"
  Migration.TargetIntentProjection -> "target-intent"
  Migration.SmtpProjection -> "smtp"

sha256Hex :: ByteString -> Text
sha256Hex = Text.pack . concatMap renderByte . ByteString.unpack . SHA256.hash
 where
  renderByte byte
    | byte < 16 = '0' : showHex byte ""
    | otherwise = showHex byte ""

targetDispositionCode :: TargetCommitDisposition -> Word8
targetDispositionCode disposition = case disposition of
  TargetCommitPrepared -> 0
  TargetCommitCommitted -> 1
  TargetCommitAborted -> 2

mapLeft :: (left -> mapped) -> Either left right -> Either mapped right
mapLeft function result = case result of
  Left err -> Left (function err)
  Right value -> Right value

maybeToEither :: right -> Maybe left -> Either left right
maybeToEither value maybeFailure = case maybeFailure of
  Nothing -> Right value
  Just failure -> Left failure
