{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production-independent oracle for the frozen @TEARDOWN-2026-08-15@
-- counterexample.  The module deliberately has no lifecycle-runtime imports:
-- repository artifacts and typed qualification fakes are its only inputs.
module Prodbox.Test.Qualification.TeardownCounterexample
  ( TeardownFixtureId
  , teardownFixtureIdText
  , TeardownEvidenceScope (..)
  , AwsAuditArn
  , awsAuditArnText
  , AuditTagRow (..)
  , NormalizedAuditResource (..)
  , ExactStackKey (..)
  , exactStackKeyText
  , OracleFailure (..)
  , ExactStackObservation (..)
  , LocalCallerObservation (..)
  , TeardownImplementation (..)
  , FrozenSourceIdentity (..)
  , FrozenCompositionIdentity (..)
  , CheckpointObservation (..)
  , AuthorityObservation (..)
  , BackupObservation (..)
  , ReportObservation (..)
  , DurableTransition (..)
  , ExternalStateCase (..)
  , externalStateCaseText
  , RecoveryReferenceDisposition (..)
  , ExternalStateDispositionRow (..)
  , InterruptionKind (..)
  , interruptionKindText
  , InterruptionSide (..)
  , interruptionSideText
  , InterruptionScheduleRow (..)
  , TeardownProfileEnvelope (..)
  , TeardownBackgroundLoad (..)
  , TeardownEnvelopeMapping (..)
  , TeardownResourceProfile (..)
  , ResourceTotals (..)
  , profileTotals
  , TeardownArtifactDigest
  , teardownArtifactDigestText
  , FrozenTeardownCounterexample
  , frozenTeardownFixtureId
  , frozenTeardownEvidenceScope
  , frozenTeardownSupersededIdentity
  , frozenTeardownReplacementIdentity
  , frozenTeardownAuditTagRows
  , frozenTeardownAuditResources
  , frozenTeardownRequests
  , frozenTeardownExactObservations
  , frozenTeardownCheckpointObservations
  , frozenTeardownCallerObservation
  , frozenTeardownAuthorityObservation
  , frozenTeardownBackupObservation
  , frozenTeardownReportObservation
  , frozenTeardownDurableTransitions
  , frozenTeardownExternalStateRows
  , frozenTeardownInterruptionSchedule
  , frozenTeardownCausalProfile
  , frozenTeardownProductionProfile
  , frozenTeardownArtifactDigest
  , ArtifactKind (..)
  , TeardownCounterexampleError (..)
  , canonicalTeardownFixtureId
  , canonicalTeardownEvidenceScope
  , canonicalRetainedBucketArn
  , TeardownTraceFixture (..)
  , teardownTraceFixturePath
  , teardownDispositionsFixturePath
  , teardownCausalProfileFixturePath
  , teardownProductionProfileFixturePath
  , parseTeardownCounterexampleArtifacts
  , loadTeardownCounterexampleFixture
  , loadTeardownCounterexample
  , SupersededGlobalCopyResult (..)
  , supersededGlobalCopyOracle
  , DrainTarget (..)
  , DrainSelection (..)
  , DestroySelection (..)
  , CallerFailure (..)
  , CleanupFailure (..)
  , CascadeOracleResult (..)
  , ReplacementTeardownResult (..)
  , replacementTeardownOracle
  , TeardownRecoveryRequestIdentity (..)
  , TeardownRecoveryFakeFailure (..)
  , TeardownRecoveryInterpreter
  , mkTeardownRecoveryInterpreter
  , canonicalTeardownRecoveryInterpreter
  , TeardownRecoveryOracleError (..)
  , runTeardownRecoveryOracle
  )
where

import Control.Exception (IOException, SomeException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (find, group, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Dhall qualified
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Aws.Region (canonicalRegressionAwsRegion)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import Text.Read (readMaybe)

newtype TeardownFixtureId = TeardownFixtureId Text
  deriving stock (Eq, Ord, Show)

teardownFixtureIdText :: TeardownFixtureId -> Text
teardownFixtureIdText (TeardownFixtureId value) = value

data TeardownEvidenceScope = TeardownEvidenceScope
  { teardownScopeRun :: !Text
  , teardownScopeRegistryRevision :: !Text
  , teardownScopeSurface :: !Text
  , teardownScopeOperation :: !Text
  , teardownScopeFoundation :: !Text
  , teardownScopeAwsAccount :: !Text
  , teardownScopeAwsRegion :: !Text
  }
  deriving stock (Eq, Ord, Show)

newtype AwsAuditArn = AwsAuditArn Text
  deriving stock (Eq, Ord, Show)

awsAuditArnText :: AwsAuditArn -> Text
awsAuditArnText (AwsAuditArn value) = value

data AuditTagRow = AuditTagRow
  { auditTagRowArn :: !AwsAuditArn
  , auditTagRowKey :: !Text
  , auditTagRowValue :: !Text
  }
  deriving stock (Eq, Ord, Show)

data NormalizedAuditResource = NormalizedAuditResource
  { normalizedAuditArn :: !AwsAuditArn
  , normalizedAuditTags :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

data ExactStackKey
  = ExactAwsEks
  | ExactAwsEksSubzone
  | ExactAwsTest
  deriving stock (Bounded, Enum, Eq, Ord, Show)

exactStackKeyText :: ExactStackKey -> Text
exactStackKeyText stackKey = case stackKey of
  ExactAwsEks -> "aws-eks"
  ExactAwsEksSubzone -> "aws-eks-subzone"
  ExactAwsTest -> "aws-test"

newtype OracleFailure = OracleFailure
  { oracleFailureText :: Text
  }
  deriving stock (Eq, Ord, Show)

data ExactStackObservation = ExactStackObservation
  { exactObservationKey :: !ExactStackKey
  , exactObservationFailure :: !OracleFailure
  }
  deriving stock (Eq, Ord, Show)

data LocalCallerObservation = LocalCallerObservation
  { localCallerIdentity :: !Text
  , localCallerFailure :: !OracleFailure
  }
  deriving stock (Eq, Ord, Show)

data TeardownImplementation
  = SupersededImplementation
  | ReplacementImplementation
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data FrozenSourceIdentity = FrozenSourceIdentity
  { frozenSourceHead :: !Text
  , frozenSourceDirty :: !Bool
  , frozenSourcePolicyId :: !Text
  , frozenSourcePolicyVersion :: !Natural
  , frozenSourcePolicyDigest :: !Text
  , frozenSourceManifestDigest :: !Text
  }
  deriving stock (Eq, Ord, Show)

data FrozenCompositionIdentity = FrozenCompositionIdentity
  { frozenCompositionSource :: !FrozenSourceIdentity
  , frozenCompositionGeneratedConfigDigest :: !Text
  , frozenCompositionTopologyDigest :: !Text
  , frozenCompositionWiringDigest :: !Text
  , frozenCompositionImages :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

data CheckpointObservation = CheckpointObservation
  { checkpointObservationKey :: !ExactStackKey
  , checkpointObservationFailure :: !OracleFailure
  }
  deriving stock (Eq, Ord, Show)

data AuthorityObservation = AuthorityObservation
  { authorityObservationIdentity :: !Text
  , authorityObservationFailure :: !OracleFailure
  }
  deriving stock (Eq, Ord, Show)

data BackupObservation = BackupObservation
  { backupObservationIdentity :: !Text
  , backupObservationDetail :: !Text
  }
  deriving stock (Eq, Ord, Show)

data ReportObservation = ReportObservation
  { reportObservationIdentity :: !Text
  , reportObservationOriginalFailures :: !Natural
  , reportObservationCleanupFailures :: !Natural
  }
  deriving stock (Eq, Ord, Show)

data DurableTransition = DurableTransition
  { durableTransitionId :: !Text
  , durableTransitionOperationId :: !Text
  }
  deriving stock (Eq, Ord, Show)

data ExternalStateCase
  = ExternalLocalApiStopped
  | ExternalLocalApiAbsent
  | ExternalCallerServiceAccountMissing
  | ExternalCallerRbacRefused
  | ExternalStaleKubernetesContext
  | ExternalVaultSealed
  | ExternalMinioUnavailable
  | ExternalAuthorityLoss
  | ExternalBackupLoss
  | ExternalProviderLoss
  | ExternalPrimaryAbsentBackupValid
  | ExternalPrimaryAbsentBackupInvalid
  | ExternalPrimaryCorruptBackupValid
  | ExternalPrimaryCorruptBackupInvalid
  | ExternalPrimaryPresentBackupValid
  | ExternalPrimaryPresentBackupInvalid
  | ExternalOwnershipManifestComplete
  | ExternalOwnershipManifestIncomplete
  | ExternalAwsAbsent
  | ExternalAwsPresent
  | ExternalAwsPartial
  | ExternalAwsUnobservable
  | ExternalEksDrainUnavailable
  | ExternalResponseLost
  | ExternalExactReadBackDelayed
  deriving stock (Bounded, Enum, Eq, Ord, Show)

externalStateCaseText :: ExternalStateCase -> Text
externalStateCaseText externalState = case externalState of
  ExternalLocalApiStopped -> "local-api-stopped"
  ExternalLocalApiAbsent -> "local-api-absent"
  ExternalCallerServiceAccountMissing -> "caller-service-account-missing"
  ExternalCallerRbacRefused -> "caller-rbac-refused"
  ExternalStaleKubernetesContext -> "stale-kubernetes-context"
  ExternalVaultSealed -> "vault-sealed"
  ExternalMinioUnavailable -> "minio-unavailable"
  ExternalAuthorityLoss -> "authority-loss"
  ExternalBackupLoss -> "backup-loss"
  ExternalProviderLoss -> "provider-loss"
  ExternalPrimaryAbsentBackupValid -> "primary-absent-backup-valid"
  ExternalPrimaryAbsentBackupInvalid -> "primary-absent-backup-invalid"
  ExternalPrimaryCorruptBackupValid -> "primary-corrupt-backup-valid"
  ExternalPrimaryCorruptBackupInvalid -> "primary-corrupt-backup-invalid"
  ExternalPrimaryPresentBackupValid -> "primary-present-backup-valid"
  ExternalPrimaryPresentBackupInvalid -> "primary-present-backup-invalid"
  ExternalOwnershipManifestComplete -> "ownership-manifest-complete"
  ExternalOwnershipManifestIncomplete -> "ownership-manifest-incomplete"
  ExternalAwsAbsent -> "aws-absent"
  ExternalAwsPresent -> "aws-present"
  ExternalAwsPartial -> "aws-partial"
  ExternalAwsUnobservable -> "aws-unobservable"
  ExternalEksDrainUnavailable -> "eks-drain-unavailable"
  ExternalResponseLost -> "response-lost"
  ExternalExactReadBackDelayed -> "exact-readback-delayed"

data RecoveryReferenceDisposition
  = RecoveryResumeCommittedIntent
  | RecoveryAlreadyAppliedReadBack
  | RecoveryFailClosedRefusal
  | RecoverySuccessorBlockedAmbiguous
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data ExternalStateDispositionRow = ExternalStateDispositionRow
  { externalStateRowCase :: !ExternalStateCase
  , externalStateRowDisposition :: !RecoveryReferenceDisposition
  }
  deriving stock (Eq, Ord, Show)

data InterruptionKind
  = InterruptCtrlC
  | InterruptSigkill
  | InterruptClientDisconnect
  | InterruptOwnerLeaseExpiry
  | InterruptRestart
  deriving stock (Bounded, Enum, Eq, Ord, Show)

interruptionKindText :: InterruptionKind -> Text
interruptionKindText interruptionKind = case interruptionKind of
  InterruptCtrlC -> "ctrl-c"
  InterruptSigkill -> "sigkill"
  InterruptClientDisconnect -> "client-disconnect"
  InterruptOwnerLeaseExpiry -> "owner-lease-expiry"
  InterruptRestart -> "restart"

data InterruptionSide
  = InterruptBefore
  | InterruptAfter
  deriving stock (Bounded, Enum, Eq, Ord, Show)

interruptionSideText :: InterruptionSide -> Text
interruptionSideText interruptionSide = case interruptionSide of
  InterruptBefore -> "before"
  InterruptAfter -> "after"

data InterruptionScheduleRow = InterruptionScheduleRow
  { interruptionScheduleKind :: !InterruptionKind
  , interruptionScheduleSide :: !InterruptionSide
  , interruptionScheduleTransition :: !DurableTransition
  , interruptionScheduleRunScope :: !Text
  , interruptionScheduleDisposition :: !RecoveryReferenceDisposition
  }
  deriving stock (Eq, Ord, Show)

data TeardownProfileEnvelope = TeardownProfileEnvelope
  { component :: !Text
  , cpu_millis :: !Natural
  , memory_mib :: !Natural
  , ephemeral_mib :: !Natural
  , persistence_mib :: !Natural
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data TeardownBackgroundLoad = TeardownBackgroundLoad
  { request_rate_per_second :: !Natural
  , concurrent_clients :: !Natural
  , payload_bytes :: !Natural
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data TeardownEnvelopeMapping = TeardownEnvelopeMapping
  { superseded_component :: !Text
  , replacement_components :: ![Text]
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data TeardownResourceProfile = TeardownResourceProfile
  { format_version :: !Natural
  , fixture_id :: !Text
  , profile_id :: !Text
  , profile_kind :: !Text
  , background_load :: !TeardownBackgroundLoad
  , fault_schedule :: ![Text]
  , fault_schedule_digest :: !Text
  , independently_justified :: !Bool
  , superseded_envelopes :: ![TeardownProfileEnvelope]
  , replacement_envelopes :: ![TeardownProfileEnvelope]
  , envelope_mapping :: ![TeardownEnvelopeMapping]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data ResourceTotals = ResourceTotals
  { totalCpuMillis :: !Natural
  , totalMemoryMib :: !Natural
  , totalEphemeralMib :: !Natural
  , totalPersistenceMib :: !Natural
  }
  deriving stock (Eq, Ord, Show)

profileTotals :: [TeardownProfileEnvelope] -> ResourceTotals
profileTotals = foldr addEnvelope (ResourceTotals 0 0 0 0)
 where
  addEnvelope profileEnvelope accumulatedTotals =
    ResourceTotals
      { totalCpuMillis = cpu_millis profileEnvelope + totalCpuMillis accumulatedTotals
      , totalMemoryMib = memory_mib profileEnvelope + totalMemoryMib accumulatedTotals
      , totalEphemeralMib = ephemeral_mib profileEnvelope + totalEphemeralMib accumulatedTotals
      , totalPersistenceMib =
          persistence_mib profileEnvelope + totalPersistenceMib accumulatedTotals
      }

newtype TeardownArtifactDigest = TeardownArtifactDigest Text
  deriving stock (Eq, Ord, Show)

teardownArtifactDigestText :: TeardownArtifactDigest -> Text
teardownArtifactDigestText (TeardownArtifactDigest value) = value

data FrozenTeardownCounterexample = FrozenTeardownCounterexample
  { internalFrozenTeardownFixtureId :: !TeardownFixtureId
  , internalFrozenTeardownEvidenceScope :: !TeardownEvidenceScope
  , internalFrozenTeardownSupersededIdentity :: !FrozenCompositionIdentity
  , internalFrozenTeardownReplacementIdentity :: !FrozenCompositionIdentity
  , internalFrozenTeardownAuditTagRows :: ![AuditTagRow]
  , internalFrozenTeardownAuditResources :: ![NormalizedAuditResource]
  , internalFrozenTeardownRequests :: ![ExactStackKey]
  , internalFrozenTeardownExactObservations :: ![ExactStackObservation]
  , internalFrozenTeardownCheckpointObservations :: ![CheckpointObservation]
  , internalFrozenTeardownCallerObservation :: !LocalCallerObservation
  , internalFrozenTeardownAuthorityObservation :: !AuthorityObservation
  , internalFrozenTeardownBackupObservation :: !BackupObservation
  , internalFrozenTeardownReportObservation :: !ReportObservation
  , internalFrozenTeardownDurableTransitions :: ![DurableTransition]
  , internalFrozenTeardownExternalStateRows :: ![ExternalStateDispositionRow]
  , internalFrozenTeardownInterruptionSchedule :: ![InterruptionScheduleRow]
  , internalFrozenTeardownCausalProfile :: !TeardownResourceProfile
  , internalFrozenTeardownProductionProfile :: !TeardownResourceProfile
  , internalFrozenTeardownArtifactDigest :: !TeardownArtifactDigest
  }
  deriving stock (Eq, Show)

frozenTeardownFixtureId :: FrozenTeardownCounterexample -> TeardownFixtureId
frozenTeardownFixtureId = internalFrozenTeardownFixtureId

frozenTeardownEvidenceScope :: FrozenTeardownCounterexample -> TeardownEvidenceScope
frozenTeardownEvidenceScope = internalFrozenTeardownEvidenceScope

frozenTeardownSupersededIdentity :: FrozenTeardownCounterexample -> FrozenCompositionIdentity
frozenTeardownSupersededIdentity = internalFrozenTeardownSupersededIdentity

frozenTeardownReplacementIdentity :: FrozenTeardownCounterexample -> FrozenCompositionIdentity
frozenTeardownReplacementIdentity = internalFrozenTeardownReplacementIdentity

frozenTeardownAuditTagRows :: FrozenTeardownCounterexample -> [AuditTagRow]
frozenTeardownAuditTagRows = internalFrozenTeardownAuditTagRows

frozenTeardownAuditResources :: FrozenTeardownCounterexample -> [NormalizedAuditResource]
frozenTeardownAuditResources = internalFrozenTeardownAuditResources

frozenTeardownRequests :: FrozenTeardownCounterexample -> [ExactStackKey]
frozenTeardownRequests = internalFrozenTeardownRequests

frozenTeardownExactObservations :: FrozenTeardownCounterexample -> [ExactStackObservation]
frozenTeardownExactObservations = internalFrozenTeardownExactObservations

frozenTeardownCheckpointObservations :: FrozenTeardownCounterexample -> [CheckpointObservation]
frozenTeardownCheckpointObservations = internalFrozenTeardownCheckpointObservations

frozenTeardownCallerObservation :: FrozenTeardownCounterexample -> LocalCallerObservation
frozenTeardownCallerObservation = internalFrozenTeardownCallerObservation

frozenTeardownAuthorityObservation :: FrozenTeardownCounterexample -> AuthorityObservation
frozenTeardownAuthorityObservation = internalFrozenTeardownAuthorityObservation

frozenTeardownBackupObservation :: FrozenTeardownCounterexample -> BackupObservation
frozenTeardownBackupObservation = internalFrozenTeardownBackupObservation

frozenTeardownReportObservation :: FrozenTeardownCounterexample -> ReportObservation
frozenTeardownReportObservation = internalFrozenTeardownReportObservation

frozenTeardownDurableTransitions :: FrozenTeardownCounterexample -> [DurableTransition]
frozenTeardownDurableTransitions = internalFrozenTeardownDurableTransitions

frozenTeardownExternalStateRows :: FrozenTeardownCounterexample -> [ExternalStateDispositionRow]
frozenTeardownExternalStateRows = internalFrozenTeardownExternalStateRows

frozenTeardownInterruptionSchedule :: FrozenTeardownCounterexample -> [InterruptionScheduleRow]
frozenTeardownInterruptionSchedule = internalFrozenTeardownInterruptionSchedule

frozenTeardownCausalProfile :: FrozenTeardownCounterexample -> TeardownResourceProfile
frozenTeardownCausalProfile = internalFrozenTeardownCausalProfile

frozenTeardownProductionProfile :: FrozenTeardownCounterexample -> TeardownResourceProfile
frozenTeardownProductionProfile = internalFrozenTeardownProductionProfile

frozenTeardownArtifactDigest :: FrozenTeardownCounterexample -> TeardownArtifactDigest
frozenTeardownArtifactDigest = internalFrozenTeardownArtifactDigest

data ArtifactKind
  = TraceArtifact
  | DispositionsArtifact
  | CausalProfileArtifact
  | ProductionProfileArtifact
  deriving stock (Eq, Ord, Show)

data TeardownCounterexampleError
  = TeardownArtifactUnreadable !FilePath !Text
  | TeardownArtifactUnbounded !ArtifactKind !Int !Int
  | TeardownArtifactInvalidUtf8 !ArtifactKind !Text
  | TeardownArtifactMalformed !ArtifactKind !Text
  | TeardownArtifactSemanticMismatch !ArtifactKind !Text
  | TeardownExternalStateDuplicate !ExternalStateCase
  | TeardownExternalStateInventoryIncomplete ![ExternalStateCase]
  | TeardownExternalStateDispositionMismatch
      !ExternalStateCase
      !RecoveryReferenceDisposition
      !RecoveryReferenceDisposition
  | TeardownInterruptionDuplicate !InterruptionKind !InterruptionSide !Text
  | TeardownInterruptionInventoryIncomplete !Int !Int
  | TeardownInterruptionDispositionMismatch
      !InterruptionKind
      !InterruptionSide
      !Text
      !RecoveryReferenceDisposition
      !RecoveryReferenceDisposition
  | TeardownProfileDigestMismatch
      !ArtifactKind
      !TeardownArtifactDigest
      !TeardownArtifactDigest
  | TeardownProfileDecodeFailure !ArtifactKind !Text
  | TeardownProfileMismatch !ArtifactKind
  | TeardownArtifactDigestMismatch
      !TeardownArtifactDigest
      !TeardownArtifactDigest
  deriving stock (Eq, Show)

canonicalTeardownFixtureId :: TeardownFixtureId
canonicalTeardownFixtureId = TeardownFixtureId "TEARDOWN-2026-08-15"

canonicalTeardownEvidenceScope :: TeardownEvidenceScope
canonicalTeardownEvidenceScope =
  TeardownEvidenceScope
    { teardownScopeRun = "teardown-2026-08-15-run-0001"
    , teardownScopeRegistryRevision = "lifecycle-registry/v1"
    , teardownScopeSurface = "cascade"
    , teardownScopeOperation = "reconcile-desired-absent"
    , teardownScopeFoundation = "home-linux-rke2"
    , teardownScopeAwsAccount = "111122223333"
    , teardownScopeAwsRegion = canonicalRegressionAwsRegion
    }

canonicalRetainedBucketArn :: AwsAuditArn
canonicalRetainedBucketArn = AwsAuditArn "arn:aws:s3:::prodbox-retained-state-fixture"

canonicalRetainedTags :: Map Text Text
canonicalRetainedTags =
  Map.fromList
    [ ("prodbox.io/managed-by", "prodbox")
    , ("prodbox.io/role", "long-lived-pulumi-state")
    ]

canonicalAuditTagRows :: [AuditTagRow]
canonicalAuditTagRows =
  [ AuditTagRow canonicalRetainedBucketArn tagKey tagValue
  | (tagKey, tagValue) <- Map.toAscList canonicalRetainedTags
  ]

canonicalSupersededIdentity :: FrozenCompositionIdentity
canonicalSupersededIdentity =
  FrozenCompositionIdentity
    { frozenCompositionSource =
        FrozenSourceIdentity
          { frozenSourceHead = "5a40e9a5f4076e3348032377fb18464ab67afca6aa731299995965b9428fb212"
          , frozenSourceDirty = True
          , frozenSourcePolicyId = "teardown-source-allowlist"
          , frozenSourcePolicyVersion = 1
          , frozenSourcePolicyDigest = "8ae04a75a02d61534994ce5c8ca3cb38f58624df7c1a3e2c54bbd4e03610d2a8"
          , frozenSourceManifestDigest = "68da178dd2cf58d58c75b99fe818fe7958632cf114bb426888ac832549d7fc59"
          }
    , frozenCompositionGeneratedConfigDigest =
        "cee6278a8d91762214caeccd204a43625a6e69f8ea930e10e1c0a4b7bdb8618b"
    , frozenCompositionTopologyDigest = "3eebb0073ad365573adf8381de939adef713f4b033ff3f7ca9b751e7897f015a"
    , frozenCompositionWiringDigest = "c0de2982e8830143dc6e184065dac47021bf784b35d51137ae49005a245e4caf"
    , frozenCompositionImages =
        Map.singleton
          "legacy-cleanup-runner"
          "68c789bb9add7beca16d3205052fdb3faf03fa9e32f3664c0c95a27849df7b16"
    }

canonicalReplacementIdentity :: FrozenCompositionIdentity
canonicalReplacementIdentity =
  FrozenCompositionIdentity
    { frozenCompositionSource =
        FrozenSourceIdentity
          { frozenSourceHead = "bb244d82680138d967f2af892dcd0fcd4743b550376ef5b1d58268c9e9de2a81"
          , frozenSourceDirty = True
          , frozenSourcePolicyId = "teardown-source-allowlist"
          , frozenSourcePolicyVersion = 1
          , frozenSourcePolicyDigest = "f948ff9500d299be71dcbb97be1f56d9412bb93c1eaf3af232101758bba2659b"
          , frozenSourceManifestDigest = "63f8e9bcc4bd652a725141b4ff9a73a49ca9c891d81daebf28269fe9dde545f3"
          }
    , frozenCompositionGeneratedConfigDigest =
        "ca5db4f29378e82a1bbe7ae8b9e55fbda68649194362286e1b5086f426e007ed"
    , frozenCompositionTopologyDigest = "da7233bb89dd3ce1d94e2753b89639c32c56eebc8c79c2081a0450e37546626d"
    , frozenCompositionWiringDigest = "b1c5de2b7bed796000a4602249fd1df45b992b3438d7c7747345fd7e5c65930b"
    , frozenCompositionImages =
        Map.fromList
          [ ("backup-adapter", "b2386d4d0c3fad80822460ede78c8c9674658a46bcd7ece2a8fa4c61631cc874")
          , ("lifecycle-authority", "f777a77b386107301d407e8235e05935d735f8e96927577b9c1a5d0fbd30af51")
          , ("provider-worker", "f1419b3a068c2844f0713ef674f1f194dc09a8a2df0f623c5c63b935460be528")
          , ("recovery-runner", "28ff7bd17bea154684cc2e6724b03d8cb57d0eec08661d42d0fd2337f2394adf")
          ]
    }

canonicalExactObservations :: [ExactStackObservation]
canonicalExactObservations =
  [ ExactStackObservation stackKey (OracleFailure "exact-stack-authority-not-serving")
  | stackKey <- [minBound .. maxBound]
  ]

canonicalCheckpointObservations :: [CheckpointObservation]
canonicalCheckpointObservations =
  [ CheckpointObservation stackKey (OracleFailure "primary-checkpoint-unobservable")
  | stackKey <- [minBound .. maxBound]
  ]

canonicalCallerObservation :: LocalCallerObservation
canonicalCallerObservation =
  LocalCallerObservation
    "local-cascade-caller"
    (OracleFailure "lifecycle-authority-caller-unobservable")

canonicalAuthorityObservation :: AuthorityObservation
canonicalAuthorityObservation =
  AuthorityObservation
    "lifecycle-authority"
    (OracleFailure "lifecycle-authority-unobservable")

canonicalBackupObservation :: BackupObservation
canonicalBackupObservation =
  BackupObservation "retained-report-backup" "retained-report-backup-readable"

canonicalReportObservation :: ReportObservation
canonicalReportObservation = ReportObservation "teardown-final-report" 1 1

canonicalDurableTransitions :: [DurableTransition]
canonicalDurableTransitions =
  [ DurableTransition "register-run" "teardown-op-register-run"
  , DurableTransition "commit-observation-intent" "teardown-op-observation-intent"
  , DurableTransition "commit-mutation-intent" "teardown-op-mutation-intent"
  , DurableTransition "commit-mutation-outcome" "teardown-op-mutation-outcome"
  , DurableTransition "commit-independent-readback" "teardown-op-independent-readback"
  , DurableTransition "commit-pre-uninstall-report" "teardown-op-pre-uninstall-report"
  , DurableTransition "commit-report-backup" "teardown-op-report-backup"
  , DurableTransition "commit-terminal-report" "teardown-op-terminal-report"
  ]

referenceDispositionFor :: ExternalStateCase -> RecoveryReferenceDisposition
referenceDispositionFor externalState = case externalState of
  ExternalLocalApiStopped -> RecoveryFailClosedRefusal
  ExternalLocalApiAbsent -> RecoveryFailClosedRefusal
  ExternalCallerServiceAccountMissing -> RecoveryFailClosedRefusal
  ExternalCallerRbacRefused -> RecoveryFailClosedRefusal
  ExternalStaleKubernetesContext -> RecoveryFailClosedRefusal
  ExternalVaultSealed -> RecoveryFailClosedRefusal
  ExternalMinioUnavailable -> RecoveryFailClosedRefusal
  ExternalAuthorityLoss -> RecoveryFailClosedRefusal
  ExternalBackupLoss -> RecoveryFailClosedRefusal
  ExternalProviderLoss -> RecoveryFailClosedRefusal
  ExternalPrimaryAbsentBackupValid -> RecoveryResumeCommittedIntent
  ExternalPrimaryAbsentBackupInvalid -> RecoverySuccessorBlockedAmbiguous
  ExternalPrimaryCorruptBackupValid -> RecoveryResumeCommittedIntent
  ExternalPrimaryCorruptBackupInvalid -> RecoverySuccessorBlockedAmbiguous
  ExternalPrimaryPresentBackupValid -> RecoveryAlreadyAppliedReadBack
  ExternalPrimaryPresentBackupInvalid -> RecoveryAlreadyAppliedReadBack
  ExternalOwnershipManifestComplete -> RecoveryAlreadyAppliedReadBack
  ExternalOwnershipManifestIncomplete -> RecoverySuccessorBlockedAmbiguous
  ExternalAwsAbsent -> RecoveryAlreadyAppliedReadBack
  ExternalAwsPresent -> RecoveryResumeCommittedIntent
  ExternalAwsPartial -> RecoverySuccessorBlockedAmbiguous
  ExternalAwsUnobservable -> RecoverySuccessorBlockedAmbiguous
  ExternalEksDrainUnavailable -> RecoverySuccessorBlockedAmbiguous
  ExternalResponseLost -> RecoveryAlreadyAppliedReadBack
  ExternalExactReadBackDelayed -> RecoverySuccessorBlockedAmbiguous

canonicalExternalStateRows :: [ExternalStateDispositionRow]
canonicalExternalStateRows =
  [ ExternalStateDispositionRow externalState (referenceDispositionFor externalState)
  | externalState <- [minBound .. maxBound]
  ]

canonicalInterruptionSchedule :: [InterruptionScheduleRow]
canonicalInterruptionSchedule =
  [ InterruptionScheduleRow
      interruptionKind
      interruptionSide
      durableTransition
      (teardownScopeRun canonicalTeardownEvidenceScope)
      ( case interruptionSide of
          InterruptBefore -> RecoveryResumeCommittedIntent
          InterruptAfter -> RecoveryAlreadyAppliedReadBack
      )
  | durableTransition <- canonicalDurableTransitions
  , interruptionKind <- [minBound .. maxBound]
  , interruptionSide <- [minBound .. maxBound]
  ]

canonicalCausalProfile :: TeardownResourceProfile
canonicalCausalProfile =
  canonicalProfile
    "teardown-causal-v1"
    "causal"
    (TeardownBackgroundLoad 4 2 1024)
    False
    (TeardownProfileEnvelope "legacy-cleanup-runner" 1000 1024 1024 1024)
    [ TeardownProfileEnvelope "lifecycle-authority" 300 300 256 512
    , TeardownProfileEnvelope "provider-worker" 250 256 256 128
    , TeardownProfileEnvelope "backup-adapter" 200 212 256 256
    , TeardownProfileEnvelope "recovery-runner" 250 256 256 128
    ]

canonicalProductionProfile :: TeardownResourceProfile
canonicalProductionProfile =
  canonicalProfile
    "teardown-production-v1"
    "production"
    (TeardownBackgroundLoad 20 4 2048)
    True
    (TeardownProfileEnvelope "legacy-cleanup-runner" 1600 2048 2048 2048)
    [ TeardownProfileEnvelope "lifecycle-authority" 500 640 512 1024
    , TeardownProfileEnvelope "provider-worker" 400 512 512 256
    , TeardownProfileEnvelope "backup-adapter" 300 384 512 512
    , TeardownProfileEnvelope "recovery-runner" 400 512 512 256
    ]

canonicalProfile
  :: Text
  -> Text
  -> TeardownBackgroundLoad
  -> Bool
  -> TeardownProfileEnvelope
  -> [TeardownProfileEnvelope]
  -> TeardownResourceProfile
canonicalProfile profileId profileKind backgroundLoad justified supersededEnvelope replacementEnvelopes =
  TeardownResourceProfile
    { format_version = 1
    , fixture_id = "TEARDOWN-2026-08-15"
    , profile_id = profileId
    , profile_kind = profileKind
    , background_load = backgroundLoad
    , fault_schedule = map durableTransitionId canonicalDurableTransitions
    , fault_schedule_digest = canonicalFaultScheduleDigest
    , independently_justified = justified
    , superseded_envelopes = [supersededEnvelope]
    , replacement_envelopes = replacementEnvelopes
    , envelope_mapping =
        [ TeardownEnvelopeMapping
            "legacy-cleanup-runner"
            [ "lifecycle-authority"
            , "provider-worker"
            , "backup-adapter"
            , "recovery-runner"
            ]
        ]
    }

canonicalFaultScheduleDigest :: Text
canonicalFaultScheduleDigest =
  teardownArtifactDigestText
    ( artifactDigest
        [ Text.unlines
            [ Text.intercalate
                "|"
                [ interruptionKindText (interruptionScheduleKind scheduleRow)
                , interruptionSideText (interruptionScheduleSide scheduleRow)
                , durableTransitionId (interruptionScheduleTransition scheduleRow)
                , interruptionScheduleRunScope scheduleRow
                , durableTransitionOperationId (interruptionScheduleTransition scheduleRow)
                , recoveryReferenceDispositionText
                    (interruptionScheduleDisposition scheduleRow)
                ]
            | scheduleRow <- canonicalInterruptionSchedule
            ]
        ]
    )

recoveryReferenceDispositionText :: RecoveryReferenceDisposition -> Text
recoveryReferenceDispositionText disposition = case disposition of
  RecoveryResumeCommittedIntent -> "resume-committed-intent"
  RecoveryAlreadyAppliedReadBack -> "already-applied-readback"
  RecoveryFailClosedRefusal -> "fail-closed-refusal"
  RecoverySuccessorBlockedAmbiguous -> "successor-blocked-ambiguous"

-- Filled from the exact four committed artifact byte streams.  Semantic
-- validation runs first so a matrix mutation reports the offending row rather
-- than being reduced to a generic checksum failure.
canonicalArtifactDigest :: TeardownArtifactDigest
canonicalArtifactDigest =
  TeardownArtifactDigest "7338a7228fb7c79929d23f64af285d5daa0b180918c7bea694897972a255b76d"

canonicalCausalProfileDigest :: TeardownArtifactDigest
canonicalCausalProfileDigest =
  TeardownArtifactDigest "cb02747196b5a09217ce110ca2feb52bfee81a1742c9ae8364997be7816a39c1"

canonicalProductionProfileDigest :: TeardownArtifactDigest
canonicalProductionProfileDigest =
  TeardownArtifactDigest "4cc526fff00e39b42fcd93102efa6b25122bf427d049db214d4cce7d82e1e5c7"

data TeardownTraceFixture
  = CanonicalTeardownTrace
  | MutatedTeardownTrace
  deriving stock (Eq, Ord, Show)

qualificationDirectory :: FilePath -> FilePath
qualificationDirectory repoRoot = repoRoot </> "test" </> "qualification"

teardownTraceFixturePath :: FilePath -> FilePath
teardownTraceFixturePath repoRoot =
  qualificationDirectory repoRoot </> "TEARDOWN-2026-08-15.trace"

teardownDispositionsFixturePath :: FilePath -> TeardownTraceFixture -> FilePath
teardownDispositionsFixturePath repoRoot traceFixture =
  qualificationDirectory repoRoot </> case traceFixture of
    CanonicalTeardownTrace -> "TEARDOWN-2026-08-15.dispositions"
    MutatedTeardownTrace -> "TEARDOWN-2026-08-15.mutated.dispositions"

teardownCausalProfileFixturePath :: FilePath -> FilePath
teardownCausalProfileFixturePath repoRoot =
  qualificationDirectory repoRoot </> "TEARDOWN-2026-08-15.causal-profile.dhall"

teardownProductionProfileFixturePath :: FilePath -> FilePath
teardownProductionProfileFixturePath repoRoot =
  qualificationDirectory repoRoot </> "TEARDOWN-2026-08-15.production-profile.dhall"

maximumTraceBytes, maximumDispositionsBytes, maximumProfileBytes :: Int
maximumTraceBytes = 64 * 1024
maximumDispositionsBytes = 128 * 1024
maximumProfileBytes = 32 * 1024

loadTeardownCounterexampleFixture
  :: FilePath
  -> TeardownTraceFixture
  -> IO (Either TeardownCounterexampleError FrozenTeardownCounterexample)
loadTeardownCounterexampleFixture repoRoot traceFixture = do
  traceResult <-
    readArtifactBounded TraceArtifact maximumTraceBytes (teardownTraceFixturePath repoRoot)
  dispositionsResult <-
    readArtifactBounded
      DispositionsArtifact
      maximumDispositionsBytes
      (teardownDispositionsFixturePath repoRoot traceFixture)
  causalProfileResult <-
    readArtifactBounded
      CausalProfileArtifact
      maximumProfileBytes
      (teardownCausalProfileFixturePath repoRoot)
  productionProfileResult <-
    readArtifactBounded
      ProductionProfileArtifact
      maximumProfileBytes
      (teardownProductionProfileFixturePath repoRoot)
  case (traceResult, dispositionsResult, causalProfileResult, productionProfileResult) of
    (Right traceContents, Right dispositionContents, Right causalContents, Right productionContents) ->
      parseTeardownCounterexampleArtifacts
        traceContents
        dispositionContents
        causalContents
        productionContents
    (Left err, _, _, _) -> pure (Left err)
    (_, Left err, _, _) -> pure (Left err)
    (_, _, Left err, _) -> pure (Left err)
    (_, _, _, Left err) -> pure (Left err)

loadTeardownCounterexample
  :: FilePath
  -> IO (Either TeardownCounterexampleError FrozenTeardownCounterexample)
loadTeardownCounterexample repoRoot =
  loadTeardownCounterexampleFixture repoRoot CanonicalTeardownTrace

readArtifactBounded
  :: ArtifactKind
  -> Int
  -> FilePath
  -> IO (Either TeardownCounterexampleError Text)
readArtifactBounded artifactKind maximumBytes path = do
  readResult <-
    try (withBinaryFile path ReadMode (\handle -> ByteString.hGet handle (maximumBytes + 1)))
      :: IO (Either IOException ByteString)
  pure $ case readResult of
    Left err -> Left (TeardownArtifactUnreadable path (Text.pack (show err)))
    Right bytes
      | ByteString.length bytes > maximumBytes ->
          Left
            ( TeardownArtifactUnbounded
                artifactKind
                maximumBytes
                (ByteString.length bytes)
            )
      | otherwise -> case TextEncoding.decodeUtf8' bytes of
          Left err -> Left (TeardownArtifactInvalidUtf8 artifactKind (Text.pack (show err)))
          Right contents -> Right contents

-- | Decode and validate all four bounded artifact schemas.  This is IO only
-- because the two exact, digest-approved profile texts are decoded by Dhall.
parseTeardownCounterexampleArtifacts
  :: Text
  -> Text
  -> Text
  -> Text
  -> IO (Either TeardownCounterexampleError FrozenTeardownCounterexample)
parseTeardownCounterexampleArtifacts traceContents dispositionContents causalContents productionContents =
  case validateTrace traceContents of
    Left err -> pure (Left err)
    Right () -> case validateDispositions dispositionContents of
      Left err -> pure (Left err)
      Right () -> case validateProfileDigest CausalProfileArtifact canonicalCausalProfileDigest causalContents of
        Left err -> pure (Left err)
        Right () -> case validateProfileDigest ProductionProfileArtifact canonicalProductionProfileDigest productionContents of
          Left err -> pure (Left err)
          Right () -> do
            causalResult <- decodeProfile CausalProfileArtifact causalContents
            productionResult <- decodeProfile ProductionProfileArtifact productionContents
            pure $ do
              causalProfile <- causalResult
              productionProfile <- productionResult
              requireProfile CausalProfileArtifact canonicalCausalProfile causalProfile
              requireProfile ProductionProfileArtifact canonicalProductionProfile productionProfile
              let observedDigest = artifactDigest [traceContents, dispositionContents, causalContents, productionContents]
              if observedDigest == canonicalArtifactDigest
                then
                  Right
                    FrozenTeardownCounterexample
                      { internalFrozenTeardownFixtureId = canonicalTeardownFixtureId
                      , internalFrozenTeardownEvidenceScope = canonicalTeardownEvidenceScope
                      , internalFrozenTeardownSupersededIdentity = canonicalSupersededIdentity
                      , internalFrozenTeardownReplacementIdentity = canonicalReplacementIdentity
                      , internalFrozenTeardownAuditTagRows = canonicalAuditTagRows
                      , internalFrozenTeardownAuditResources =
                          [NormalizedAuditResource canonicalRetainedBucketArn canonicalRetainedTags]
                      , internalFrozenTeardownRequests = [minBound .. maxBound]
                      , internalFrozenTeardownExactObservations = canonicalExactObservations
                      , internalFrozenTeardownCheckpointObservations = canonicalCheckpointObservations
                      , internalFrozenTeardownCallerObservation = canonicalCallerObservation
                      , internalFrozenTeardownAuthorityObservation = canonicalAuthorityObservation
                      , internalFrozenTeardownBackupObservation = canonicalBackupObservation
                      , internalFrozenTeardownReportObservation = canonicalReportObservation
                      , internalFrozenTeardownDurableTransitions = canonicalDurableTransitions
                      , internalFrozenTeardownExternalStateRows = canonicalExternalStateRows
                      , internalFrozenTeardownInterruptionSchedule = canonicalInterruptionSchedule
                      , internalFrozenTeardownCausalProfile = causalProfile
                      , internalFrozenTeardownProductionProfile = productionProfile
                      , internalFrozenTeardownArtifactDigest = observedDigest
                      }
                else Left (TeardownArtifactDigestMismatch canonicalArtifactDigest observedDigest)

validateProfileDigest
  :: ArtifactKind
  -> TeardownArtifactDigest
  -> Text
  -> Either TeardownCounterexampleError ()
validateProfileDigest artifactKind expected contents =
  let observed = artifactDigest [contents]
   in if observed == expected
        then Right ()
        else Left (TeardownProfileDigestMismatch artifactKind expected observed)

decodeProfile
  :: ArtifactKind
  -> Text
  -> IO (Either TeardownCounterexampleError TeardownResourceProfile)
decodeProfile artifactKind contents = do
  decoded <-
    try (Dhall.input Dhall.auto contents)
      :: IO (Either SomeException TeardownResourceProfile)
  pure $ case decoded of
    Left err -> Left (TeardownProfileDecodeFailure artifactKind (Text.pack (show err)))
    Right profile -> Right profile

requireProfile
  :: ArtifactKind
  -> TeardownResourceProfile
  -> TeardownResourceProfile
  -> Either TeardownCounterexampleError ()
requireProfile artifactKind expected observed =
  if observed == expected
    then Right ()
    else Left (TeardownProfileMismatch artifactKind)

data TraceFact
  = TraceFormatVersion !Natural
  | TraceFixtureId !Text
  | TraceRunScope !Text
  | TraceRegistryRevision !Text
  | TraceSurface !Text
  | TraceOperation !Text
  | TraceFoundation !Text
  | TraceAwsAccount !Text
  | TraceAwsRegion !Text
  | TraceSourceHead !TeardownImplementation !Text
  | TraceSourceDirty !TeardownImplementation !Bool
  | TraceSourcePolicyId !TeardownImplementation !Text
  | TraceSourcePolicyVersion !TeardownImplementation !Natural
  | TraceSourcePolicyDigest !TeardownImplementation !Text
  | TraceSourceManifestDigest !TeardownImplementation !Text
  | TraceGeneratedConfigDigest !TeardownImplementation !Text
  | TraceTopologyDigest !TeardownImplementation !Text
  | TraceWiringDigest !TeardownImplementation !Text
  | TraceComponentImage !TeardownImplementation !Text !Text
  | TraceTagRow !AuditTagRow
  | TraceRequest !ExactStackKey
  | TraceProvider !ExactStackObservation
  | TraceCheckpoint !CheckpointObservation
  | TraceKubernetes !LocalCallerObservation
  | TraceAuthority !AuthorityObservation
  | TraceBackup !BackupObservation
  | TraceReport !ReportObservation
  | TraceTransition !DurableTransition
  deriving stock (Eq, Ord, Show)

validateTrace :: Text -> Either TeardownCounterexampleError ()
validateTrace contents = do
  observed <- traverse parseTraceFact (significantLines contents)
  if sort observed == sort canonicalTraceFacts
    then Right ()
    else
      Left
        ( TeardownArtifactSemanticMismatch
            TraceArtifact
            "the exact trace fact inventory or one of its identity/key/scope/cardinality fields differs"
        )

parseTraceFact :: Text -> Either TeardownCounterexampleError TraceFact
parseTraceFact line = case Text.words line of
  ["format-version", value] -> TraceFormatVersion <$> parseNatural TraceArtifact line value
  ["fixture-id", value] -> Right (TraceFixtureId value)
  ["run-scope", value] -> Right (TraceRunScope value)
  ["registry-revision", value] -> Right (TraceRegistryRevision value)
  ["surface", value] -> Right (TraceSurface value)
  ["operation", value] -> Right (TraceOperation value)
  ["foundation", value] -> Right (TraceFoundation value)
  ["aws-account", value] -> Right (TraceAwsAccount value)
  ["aws-region", value] -> Right (TraceAwsRegion value)
  ["source-head", implementation, value] ->
    TraceSourceHead <$> parseImplementation line implementation <*> pure value
  ["source-dirty", implementation, value] ->
    TraceSourceDirty
      <$> parseImplementation line implementation
      <*> parseBoolean TraceArtifact line value
  ["source-policy-id", implementation, value] ->
    TraceSourcePolicyId <$> parseImplementation line implementation <*> pure value
  ["source-policy-version", implementation, value] ->
    TraceSourcePolicyVersion
      <$> parseImplementation line implementation
      <*> parseNatural TraceArtifact line value
  ["source-policy-digest", implementation, value] ->
    TraceSourcePolicyDigest <$> parseImplementation line implementation <*> pure value
  ["source-manifest-digest", implementation, value] ->
    TraceSourceManifestDigest <$> parseImplementation line implementation <*> pure value
  ["generated-config-digest", implementation, value] ->
    TraceGeneratedConfigDigest <$> parseImplementation line implementation <*> pure value
  ["topology-digest", implementation, value] ->
    TraceTopologyDigest <$> parseImplementation line implementation <*> pure value
  ["wiring-digest", implementation, value] ->
    TraceWiringDigest <$> parseImplementation line implementation <*> pure value
  ["component-image", implementation, imageComponent, value] ->
    TraceComponentImage
      <$> parseImplementation line implementation
      <*> pure imageComponent
      <*> pure value
  ["tag-row", arn, tagKey, tagValue] ->
    Right (TraceTagRow (AuditTagRow (AwsAuditArn arn) tagKey tagValue))
  ["request", stackKey] -> TraceRequest <$> parseExactStackKey TraceArtifact line stackKey
  ["provider", stackKey, "unobservable", detail] ->
    TraceProvider
      . (`ExactStackObservation` OracleFailure detail)
      <$> parseExactStackKey TraceArtifact line stackKey
  ["checkpoint", stackKey, "unobservable", detail] ->
    TraceCheckpoint
      . (`CheckpointObservation` OracleFailure detail)
      <$> parseExactStackKey TraceArtifact line stackKey
  ["kubernetes", identity, "unobservable", detail] ->
    Right (TraceKubernetes (LocalCallerObservation identity (OracleFailure detail)))
  ["authority", identity, "unobservable", detail] ->
    Right (TraceAuthority (AuthorityObservation identity (OracleFailure detail)))
  ["backup", identity, "present", detail] ->
    Right (TraceBackup (BackupObservation identity detail))
  ["report", identity, "committed", originalFailures, cleanupFailures] ->
    TraceReport
      <$> ( ReportObservation identity
              <$> parseNatural TraceArtifact line originalFailures
              <*> parseNatural TraceArtifact line cleanupFailures
          )
  ["transition", transitionId, operationId] ->
    Right (TraceTransition (DurableTransition transitionId operationId))
  _ -> Left (TeardownArtifactMalformed TraceArtifact line)

parseImplementation
  :: Text
  -> Text
  -> Either TeardownCounterexampleError TeardownImplementation
parseImplementation line value = case value of
  "superseded" -> Right SupersededImplementation
  "replacement" -> Right ReplacementImplementation
  _ -> Left (TeardownArtifactMalformed TraceArtifact line)

canonicalTraceFacts :: [TraceFact]
canonicalTraceFacts =
  [ TraceFormatVersion 1
  , TraceFixtureId (teardownFixtureIdText canonicalTeardownFixtureId)
  , TraceRunScope (teardownScopeRun canonicalTeardownEvidenceScope)
  , TraceRegistryRevision (teardownScopeRegistryRevision canonicalTeardownEvidenceScope)
  , TraceSurface (teardownScopeSurface canonicalTeardownEvidenceScope)
  , TraceOperation (teardownScopeOperation canonicalTeardownEvidenceScope)
  , TraceFoundation (teardownScopeFoundation canonicalTeardownEvidenceScope)
  , TraceAwsAccount (teardownScopeAwsAccount canonicalTeardownEvidenceScope)
  , TraceAwsRegion (teardownScopeAwsRegion canonicalTeardownEvidenceScope)
  ]
    ++ compositionFacts SupersededImplementation canonicalSupersededIdentity
    ++ compositionFacts ReplacementImplementation canonicalReplacementIdentity
    ++ map TraceTagRow canonicalAuditTagRows
    ++ [TraceRequest stackKey | stackKey <- [minBound .. maxBound]]
    ++ map TraceProvider canonicalExactObservations
    ++ map TraceCheckpoint canonicalCheckpointObservations
    ++ [ TraceKubernetes canonicalCallerObservation
       , TraceAuthority canonicalAuthorityObservation
       , TraceBackup canonicalBackupObservation
       , TraceReport canonicalReportObservation
       ]
    ++ map TraceTransition canonicalDurableTransitions

compositionFacts :: TeardownImplementation -> FrozenCompositionIdentity -> [TraceFact]
compositionFacts implementation identity =
  let sourceIdentity = frozenCompositionSource identity
   in [ TraceSourceHead implementation (frozenSourceHead sourceIdentity)
      , TraceSourceDirty implementation (frozenSourceDirty sourceIdentity)
      , TraceSourcePolicyId implementation (frozenSourcePolicyId sourceIdentity)
      , TraceSourcePolicyVersion implementation (frozenSourcePolicyVersion sourceIdentity)
      , TraceSourcePolicyDigest implementation (frozenSourcePolicyDigest sourceIdentity)
      , TraceSourceManifestDigest implementation (frozenSourceManifestDigest sourceIdentity)
      , TraceGeneratedConfigDigest implementation (frozenCompositionGeneratedConfigDigest identity)
      , TraceTopologyDigest implementation (frozenCompositionTopologyDigest identity)
      , TraceWiringDigest implementation (frozenCompositionWiringDigest identity)
      ]
        ++ [ TraceComponentImage implementation imageComponent imageDigest
           | (imageComponent, imageDigest) <- Map.toAscList (frozenCompositionImages identity)
           ]

data DispositionFact
  = DispositionFormatVersion !Natural
  | DispositionFixtureId !Text
  | DispositionSupersededResult !Text !Text
  | DispositionReplacementResult !Text !Text
  | DispositionExternal !ExternalStateDispositionRow
  | DispositionInterruption
      !InterruptionKind
      !InterruptionSide
      !Text
      !RecoveryReferenceDisposition
  deriving stock (Eq, Ord, Show)

validateDispositions :: Text -> Either TeardownCounterexampleError ()
validateDispositions contents = do
  facts <- traverse parseDispositionFact (significantLines contents)
  let externalRows = [row | DispositionExternal row <- facts]
      interruptionRows =
        [ (kind, side, transitionId, disposition)
        | DispositionInterruption kind side transitionId disposition <- facts
        ]
  validateExternalRows externalRows
  validateInterruptionRows interruptionRows
  if sort facts == sort canonicalDispositionFacts
    then Right ()
    else
      Left
        ( TeardownArtifactSemanticMismatch
            DispositionsArtifact
            "the exact result, matrix, or interruption fact inventory differs"
        )

parseDispositionFact :: Text -> Either TeardownCounterexampleError DispositionFact
parseDispositionFact line = case Text.words line of
  ["format-version", value] ->
    DispositionFormatVersion <$> parseNatural DispositionsArtifact line value
  ["fixture-id", value] -> Right (DispositionFixtureId value)
  ["superseded-result", result, expectation] ->
    Right (DispositionSupersededResult result expectation)
  ["replacement-result", result, expectation] ->
    Right (DispositionReplacementResult result expectation)
  ["external", externalState, disposition] -> do
    parsedState <- parseExternalState line externalState
    parsedDisposition <- parseDisposition line disposition
    Right (DispositionExternal (ExternalStateDispositionRow parsedState parsedDisposition))
  ["interrupt", kind, side, transitionId, "same-run", "same-operation", disposition] ->
    DispositionInterruption
      <$> parseInterruptionKind line kind
      <*> parseInterruptionSide line side
      <*> pure transitionId
      <*> parseDisposition line disposition
  _ -> Left (TeardownArtifactMalformed DispositionsArtifact line)

validateExternalRows
  :: [ExternalStateDispositionRow]
  -> Either TeardownCounterexampleError ()
validateExternalRows rows = do
  case duplicateValues (map externalStateRowCase rows) of
    duplicate : _ -> Left (TeardownExternalStateDuplicate duplicate)
    [] -> Right ()
  let required = [minBound .. maxBound]
      missing =
        [externalState | externalState <- required, externalState `notElem` map externalStateRowCase rows]
  if null missing && length rows == length required
    then Right ()
    else Left (TeardownExternalStateInventoryIncomplete missing)
  mapM_ validateRow rows
 where
  validateRow row =
    let expected = referenceDispositionFor (externalStateRowCase row)
        observed = externalStateRowDisposition row
     in if observed == expected
          then Right ()
          else
            Left
              ( TeardownExternalStateDispositionMismatch
                  (externalStateRowCase row)
                  expected
                  observed
              )

validateInterruptionRows
  :: [(InterruptionKind, InterruptionSide, Text, RecoveryReferenceDisposition)]
  -> Either TeardownCounterexampleError ()
validateInterruptionRows rows = do
  let keys = [(kind, side, transitionId) | (kind, side, transitionId, _) <- rows]
  case duplicateValues keys of
    (kind, side, transitionId) : _ ->
      Left (TeardownInterruptionDuplicate kind side transitionId)
    [] -> Right ()
  let requiredKeys =
        [ (kind, side, durableTransitionId transition)
        | transition <- canonicalDurableTransitions
        , kind <- [minBound .. maxBound]
        , side <- [minBound .. maxBound]
        ]
  if sort keys == sort requiredKeys
    then Right ()
    else Left (TeardownInterruptionInventoryIncomplete (length requiredKeys) (length rows))
  mapM_ validateRow rows
 where
  validateRow (kind, side, transitionId, observed) =
    let expected = case side of
          InterruptBefore -> RecoveryResumeCommittedIntent
          InterruptAfter -> RecoveryAlreadyAppliedReadBack
     in if observed == expected
          then Right ()
          else
            Left
              ( TeardownInterruptionDispositionMismatch
                  kind
                  side
                  transitionId
                  expected
                  observed
              )

canonicalDispositionFacts :: [DispositionFact]
canonicalDispositionFacts =
  [ DispositionFormatVersion 1
  , DispositionFixtureId (teardownFixtureIdText canonicalTeardownFixtureId)
  , DispositionSupersededResult "false-three-stack-classification" "expected-failure"
  , DispositionReplacementResult "cascade-incomplete" "expected-pass"
  ]
    ++ map DispositionExternal canonicalExternalStateRows
    ++ [ DispositionInterruption
           (interruptionScheduleKind scheduleRow)
           (interruptionScheduleSide scheduleRow)
           (durableTransitionId (interruptionScheduleTransition scheduleRow))
           (interruptionScheduleDisposition scheduleRow)
       | scheduleRow <- canonicalInterruptionSchedule
       ]

parseExactStackKey
  :: ArtifactKind
  -> Text
  -> Text
  -> Either TeardownCounterexampleError ExactStackKey
parseExactStackKey artifactKind line value = case value of
  "aws-eks" -> Right ExactAwsEks
  "aws-eks-subzone" -> Right ExactAwsEksSubzone
  "aws-test" -> Right ExactAwsTest
  _ -> Left (TeardownArtifactMalformed artifactKind line)

parseExternalState
  :: Text -> Text -> Either TeardownCounterexampleError ExternalStateCase
parseExternalState line value =
  case find ((== value) . externalStateCaseText) [minBound .. maxBound] of
    Just externalState -> Right externalState
    Nothing -> Left (TeardownArtifactMalformed DispositionsArtifact line)

parseInterruptionKind
  :: Text -> Text -> Either TeardownCounterexampleError InterruptionKind
parseInterruptionKind line value =
  case find ((== value) . interruptionKindText) [minBound .. maxBound] of
    Just interruptionKind -> Right interruptionKind
    Nothing -> Left (TeardownArtifactMalformed DispositionsArtifact line)

parseInterruptionSide
  :: Text -> Text -> Either TeardownCounterexampleError InterruptionSide
parseInterruptionSide line value =
  case find ((== value) . interruptionSideText) [minBound .. maxBound] of
    Just interruptionSide -> Right interruptionSide
    Nothing -> Left (TeardownArtifactMalformed DispositionsArtifact line)

parseDisposition
  :: Text
  -> Text
  -> Either TeardownCounterexampleError RecoveryReferenceDisposition
parseDisposition line value =
  case find
    ((== value) . recoveryReferenceDispositionText)
    [minBound .. maxBound] of
    Just disposition -> Right disposition
    Nothing -> Left (TeardownArtifactMalformed DispositionsArtifact line)

parseNatural
  :: ArtifactKind
  -> Text
  -> Text
  -> Either TeardownCounterexampleError Natural
parseNatural artifactKind line value = case readMaybe (Text.unpack value) of
  Just naturalValue -> Right naturalValue
  Nothing -> Left (TeardownArtifactMalformed artifactKind line)

parseBoolean
  :: ArtifactKind
  -> Text
  -> Text
  -> Either TeardownCounterexampleError Bool
parseBoolean artifactKind line value = case value of
  "true" -> Right True
  "false" -> Right False
  _ -> Left (TeardownArtifactMalformed artifactKind line)

significantLines :: Text -> [Text]
significantLines contents =
  [ stripped
  | rawLine <- Text.lines contents
  , let stripped = Text.strip rawLine
  , not (Text.null stripped)
  , not ("#" `Text.isPrefixOf` stripped)
  ]

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues = foldr collectDuplicate [] . group . sort
 where
  collectDuplicate groupedValues duplicates = case groupedValues of
    value : _ : _ -> value : duplicates
    _ -> duplicates

artifactDigest :: [Text] -> TeardownArtifactDigest
artifactDigest contents =
  TeardownArtifactDigest
    ( Text.pack
        ( concatMap
            renderHexByte
            ( ByteString.unpack
                (SHA256.hash (ByteString.intercalate (ByteString.singleton 0) (map TextEncoding.encodeUtf8 contents)))
            )
        )
    )
 where
  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

data SupersededGlobalCopyResult = SupersededGlobalCopyResult
  { supersededDecodedAuditRows :: ![AuditTagRow]
  , supersededAuditArns :: ![AwsAuditArn]
  , supersededCopiedExactPresence :: !(Map ExactStackKey [AwsAuditArn])
  , supersededDrainSelection :: !DrainSelection
  }
  deriving stock (Eq, Show)

supersededGlobalCopyOracle
  :: FrozenTeardownCounterexample -> SupersededGlobalCopyResult
supersededGlobalCopyOracle fixture =
  let decodedRows = frozenTeardownAuditTagRows fixture
      arns = map auditTagRowArn decodedRows
      copied =
        Map.fromList
          [(stackKey, arns) | stackKey <- frozenTeardownRequests fixture]
   in SupersededGlobalCopyResult
        { supersededDecodedAuditRows = decodedRows
        , supersededAuditArns = arns
        , supersededCopiedExactPresence = copied
        , supersededDrainSelection = DrainSelected DrainAwsEks
        }

data DrainTarget
  = DrainLocalFoundation
  | DrainAwsEks
  deriving stock (Eq, Ord, Show)

data DrainSelection
  = NoDrainSelected
  | DrainSelected !DrainTarget
  deriving stock (Eq, Ord, Show)

data DestroySelection
  = NoDestroySelected
  | DestroySelected ![ExactStackKey]
  deriving stock (Eq, Ord, Show)

data CallerFailure = CallerFailure
  { failedCallerIdentity :: !Text
  , failedCallerReason :: !OracleFailure
  }
  deriving stock (Eq, Ord, Show)

data CleanupFailure = CleanupFailure
  { failedCleanupBoundary :: !Text
  , failedCleanupReason :: !OracleFailure
  }
  deriving stock (Eq, Ord, Show)

data CascadeOracleResult
  = CascadeComplete
  | CascadeIncomplete !CallerFailure ![CleanupFailure]
  deriving stock (Eq, Ord, Show)

data ReplacementTeardownResult = ReplacementTeardownResult
  { replacementRetainedAuditArns :: ![AwsAuditArn]
  , replacementExactUnobservables :: !(Map ExactStackKey OracleFailure)
  , replacementCheckpointUnobservables :: !(Map ExactStackKey OracleFailure)
  , replacementBackupObservation :: !BackupObservation
  , replacementReportObservation :: !ReportObservation
  , replacementDrainSelection :: !DrainSelection
  , replacementDestroySelection :: !DestroySelection
  , replacementCascadeResult :: !CascadeOracleResult
  }
  deriving stock (Eq, Show)

replacementTeardownOracle
  :: FrozenTeardownCounterexample -> ReplacementTeardownResult
replacementTeardownOracle fixture =
  let caller = frozenTeardownCallerObservation fixture
      authority = frozenTeardownAuthorityObservation fixture
   in ReplacementTeardownResult
        { replacementRetainedAuditArns =
            map normalizedAuditArn (frozenTeardownAuditResources fixture)
        , replacementExactUnobservables =
            Map.fromList
              [ (exactObservationKey observation, exactObservationFailure observation)
              | observation <- frozenTeardownExactObservations fixture
              ]
        , replacementCheckpointUnobservables =
            Map.fromList
              [ (checkpointObservationKey observation, checkpointObservationFailure observation)
              | observation <- frozenTeardownCheckpointObservations fixture
              ]
        , replacementBackupObservation = frozenTeardownBackupObservation fixture
        , replacementReportObservation = frozenTeardownReportObservation fixture
        , replacementDrainSelection = NoDrainSelected
        , replacementDestroySelection = NoDestroySelected
        , replacementCascadeResult =
            CascadeIncomplete
              CallerFailure
                { failedCallerIdentity = localCallerIdentity caller
                , failedCallerReason = localCallerFailure caller
                }
              [ CleanupFailure
                  { failedCleanupBoundary = authorityObservationIdentity authority
                  , failedCleanupReason = authorityObservationFailure authority
                  }
              ]
        }

-- | Every fake request is exact-keyed.  There is intentionally no generic
-- residue/absence constructor and no Boolean evidence channel.
data TeardownRecoveryRequestIdentity
  = TeardownRecoveryProviderRequest
      !TeardownFixtureId
      !TeardownEvidenceScope
      !ExactStackKey
  | TeardownRecoveryCheckpointRequest
      !TeardownFixtureId
      !TeardownEvidenceScope
      !ExactStackKey
  | TeardownRecoveryAuditRequest
      !TeardownFixtureId
      !TeardownEvidenceScope
  | TeardownRecoveryKubernetesRequest
      !TeardownFixtureId
      !TeardownEvidenceScope
      !Text
  | TeardownRecoveryAuthorityRequest
      !TeardownFixtureId
      !TeardownEvidenceScope
      !Text
  | TeardownRecoveryBackupRequest
      !TeardownFixtureId
      !TeardownEvidenceScope
      !Text
  | TeardownRecoveryReportRequest
      !TeardownFixtureId
      !TeardownEvidenceScope
      !Text
  deriving stock (Eq, Ord, Show)

data TeardownRecoveryFakeFailure
  = TeardownRecoveryFakeRequestMissing !TeardownRecoveryRequestIdentity
  | TeardownRecoveryFakeRequestUnavailable
      !TeardownRecoveryRequestIdentity
      !OracleFailure
  deriving stock (Eq, Ord, Show)

data TeardownRecoveryInterpreter m = TeardownRecoveryInterpreter
  { observeTeardownProvider
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> ExactStackKey
      -> m (Either TeardownRecoveryFakeFailure ExactStackObservation)
  , observeTeardownCheckpoint
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> ExactStackKey
      -> m (Either TeardownRecoveryFakeFailure CheckpointObservation)
  , observeTeardownAudit
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> m (Either TeardownRecoveryFakeFailure [NormalizedAuditResource])
  , observeTeardownKubernetes
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> Text
      -> m (Either TeardownRecoveryFakeFailure LocalCallerObservation)
  , observeTeardownAuthority
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> Text
      -> m (Either TeardownRecoveryFakeFailure AuthorityObservation)
  , observeTeardownBackup
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> Text
      -> m (Either TeardownRecoveryFakeFailure BackupObservation)
  , observeTeardownReport
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> Text
      -> m (Either TeardownRecoveryFakeFailure ReportObservation)
  }

mkTeardownRecoveryInterpreter
  :: ( TeardownFixtureId
       -> TeardownEvidenceScope
       -> ExactStackKey
       -> m (Either TeardownRecoveryFakeFailure ExactStackObservation)
     )
  -> ( TeardownFixtureId
       -> TeardownEvidenceScope
       -> ExactStackKey
       -> m (Either TeardownRecoveryFakeFailure CheckpointObservation)
     )
  -> ( TeardownFixtureId
       -> TeardownEvidenceScope
       -> m (Either TeardownRecoveryFakeFailure [NormalizedAuditResource])
     )
  -> ( TeardownFixtureId
       -> TeardownEvidenceScope
       -> Text
       -> m (Either TeardownRecoveryFakeFailure LocalCallerObservation)
     )
  -> ( TeardownFixtureId
       -> TeardownEvidenceScope
       -> Text
       -> m (Either TeardownRecoveryFakeFailure AuthorityObservation)
     )
  -> ( TeardownFixtureId
       -> TeardownEvidenceScope
       -> Text
       -> m (Either TeardownRecoveryFakeFailure BackupObservation)
     )
  -> ( TeardownFixtureId
       -> TeardownEvidenceScope
       -> Text
       -> m (Either TeardownRecoveryFakeFailure ReportObservation)
     )
  -> TeardownRecoveryInterpreter m
mkTeardownRecoveryInterpreter = TeardownRecoveryInterpreter

canonicalTeardownRecoveryInterpreter
  :: (Applicative m)
  => FrozenTeardownCounterexample
  -> TeardownRecoveryInterpreter m
canonicalTeardownRecoveryInterpreter fixture =
  mkTeardownRecoveryInterpreter
    observeProvider
    observeCheckpoint
    observeAudit
    observeKubernetes
    observeAuthority
    observeBackup
    observeReport
 where
  expectedFixture = frozenTeardownFixtureId fixture
  expectedScope = frozenTeardownEvidenceScope fixture
  identityMatches observedFixture observedScope =
    observedFixture == expectedFixture && observedScope == expectedScope

  observeProvider observedFixture observedScope stackKey =
    pure $
      lookupExact
        (TeardownRecoveryProviderRequest observedFixture observedScope stackKey)
        exactObservationKey
        (frozenTeardownExactObservations fixture)
        observedFixture
        observedScope
        stackKey

  observeCheckpoint observedFixture observedScope stackKey =
    pure $
      lookupExact
        (TeardownRecoveryCheckpointRequest observedFixture observedScope stackKey)
        checkpointObservationKey
        (frozenTeardownCheckpointObservations fixture)
        observedFixture
        observedScope
        stackKey

  lookupExact request keyOf rows observedFixture observedScope stackKey
    | not (identityMatches observedFixture observedScope) =
        Left (TeardownRecoveryFakeRequestMissing request)
    | otherwise = case find ((== stackKey) . keyOf) rows of
        Just observation -> Right observation
        Nothing -> Left (TeardownRecoveryFakeRequestMissing request)

  observeAudit observedFixture observedScope =
    pure $
      exactSingleton
        (TeardownRecoveryAuditRequest observedFixture observedScope)
        observedFixture
        observedScope
        (frozenTeardownAuditResources fixture)

  observeKubernetes observedFixture observedScope identity =
    let expected = frozenTeardownCallerObservation fixture
     in pure $
          exactNamed
            (TeardownRecoveryKubernetesRequest observedFixture observedScope identity)
            observedFixture
            observedScope
            identity
            (localCallerIdentity expected)
            expected

  observeAuthority observedFixture observedScope identity =
    let expected = frozenTeardownAuthorityObservation fixture
     in pure $
          exactNamed
            (TeardownRecoveryAuthorityRequest observedFixture observedScope identity)
            observedFixture
            observedScope
            identity
            (authorityObservationIdentity expected)
            expected

  observeBackup observedFixture observedScope identity =
    let expected = frozenTeardownBackupObservation fixture
     in pure $
          exactNamed
            (TeardownRecoveryBackupRequest observedFixture observedScope identity)
            observedFixture
            observedScope
            identity
            (backupObservationIdentity expected)
            expected

  observeReport observedFixture observedScope identity =
    let expected = frozenTeardownReportObservation fixture
     in pure $
          exactNamed
            (TeardownRecoveryReportRequest observedFixture observedScope identity)
            observedFixture
            observedScope
            identity
            (reportObservationIdentity expected)
            expected

  exactSingleton request observedFixture observedScope value =
    if identityMatches observedFixture observedScope
      then Right value
      else Left (TeardownRecoveryFakeRequestMissing request)

  exactNamed request observedFixture observedScope identity expectedIdentity value =
    if identityMatches observedFixture observedScope && identity == expectedIdentity
      then Right value
      else Left (TeardownRecoveryFakeRequestMissing request)

data TeardownRecoveryOracleError
  = TeardownRecoveryFakeRefused !TeardownRecoveryFakeFailure
  | TeardownRecoveryProviderKeyMismatch !ExactStackKey !ExactStackKey
  | TeardownRecoveryProviderMismatch
      !ExactStackKey
      !ExactStackObservation
      !ExactStackObservation
  | TeardownRecoveryCheckpointKeyMismatch !ExactStackKey !ExactStackKey
  | TeardownRecoveryCheckpointMismatch
      !ExactStackKey
      !CheckpointObservation
      !CheckpointObservation
  | TeardownRecoveryAuditMismatch
      ![NormalizedAuditResource]
      ![NormalizedAuditResource]
  | TeardownRecoveryKubernetesMismatch
      !LocalCallerObservation
      !LocalCallerObservation
  | TeardownRecoveryAuthorityMismatch !AuthorityObservation !AuthorityObservation
  | TeardownRecoveryBackupMismatch !BackupObservation !BackupObservation
  | TeardownRecoveryReportMismatch !ReportObservation !ReportObservation
  | TeardownRecoveryReplacementMismatch
      !ReplacementTeardownResult
      !ReplacementTeardownResult
  deriving stock (Eq, Show)

runTeardownRecoveryOracle
  :: (Monad m)
  => FrozenTeardownCounterexample
  -> TeardownRecoveryInterpreter m
  -> m (Either TeardownRecoveryOracleError ReplacementTeardownResult)
runTeardownRecoveryOracle fixture interpreter = do
  let fixtureId = frozenTeardownFixtureId fixture
      scope = frozenTeardownEvidenceScope fixture
  providerResult <- observeProviderRows fixtureId scope (frozenTeardownRequests fixture)
  case providerResult of
    Left err -> pure (Left err)
    Right providerRows -> do
      checkpointResult <- observeCheckpointRows fixtureId scope (frozenTeardownRequests fixture)
      case checkpointResult of
        Left err -> pure (Left err)
        Right checkpointRows -> do
          auditResult <- observeTeardownAudit interpreter fixtureId scope
          case checkExact
            TeardownRecoveryAuditMismatch
            (frozenTeardownAuditResources fixture)
            auditResult of
            Left err -> pure (Left err)
            Right auditRows -> do
              let expectedKubernetes = frozenTeardownCallerObservation fixture
              kubernetesResult <-
                observeTeardownKubernetes
                  interpreter
                  fixtureId
                  scope
                  (localCallerIdentity expectedKubernetes)
              case checkExact TeardownRecoveryKubernetesMismatch expectedKubernetes kubernetesResult of
                Left err -> pure (Left err)
                Right kubernetesObservation -> do
                  let expectedAuthority = frozenTeardownAuthorityObservation fixture
                  authorityResult <-
                    observeTeardownAuthority
                      interpreter
                      fixtureId
                      scope
                      (authorityObservationIdentity expectedAuthority)
                  case checkExact TeardownRecoveryAuthorityMismatch expectedAuthority authorityResult of
                    Left err -> pure (Left err)
                    Right authorityObservation -> do
                      let expectedBackup = frozenTeardownBackupObservation fixture
                      backupResult <-
                        observeTeardownBackup
                          interpreter
                          fixtureId
                          scope
                          (backupObservationIdentity expectedBackup)
                      case checkExact TeardownRecoveryBackupMismatch expectedBackup backupResult of
                        Left err -> pure (Left err)
                        Right backupObservation -> do
                          let expectedReport = frozenTeardownReportObservation fixture
                          reportResult <-
                            observeTeardownReport
                              interpreter
                              fixtureId
                              scope
                              (reportObservationIdentity expectedReport)
                          pure $ do
                            reportObservation <-
                              checkExact TeardownRecoveryReportMismatch expectedReport reportResult
                            finish
                              auditRows
                              providerRows
                              checkpointRows
                              kubernetesObservation
                              authorityObservation
                              backupObservation
                              reportObservation
 where
  observeProviderRows _ _ [] = pure (Right [])
  observeProviderRows fixtureId scope (stackKey : remaining) = do
    observedResult <- observeTeardownProvider interpreter fixtureId scope stackKey
    case validateProvider stackKey observedResult of
      Left err -> pure (Left err)
      Right observed -> do
        rest <- observeProviderRows fixtureId scope remaining
        pure ((observed :) <$> rest)

  observeCheckpointRows _ _ [] = pure (Right [])
  observeCheckpointRows fixtureId scope (stackKey : remaining) = do
    observedResult <- observeTeardownCheckpoint interpreter fixtureId scope stackKey
    case validateCheckpoint stackKey observedResult of
      Left err -> pure (Left err)
      Right observed -> do
        rest <- observeCheckpointRows fixtureId scope remaining
        pure ((observed :) <$> rest)

  validateProvider stackKey observedResult = do
    observed <- either (Left . TeardownRecoveryFakeRefused) Right observedResult
    if exactObservationKey observed /= stackKey
      then Left (TeardownRecoveryProviderKeyMismatch stackKey (exactObservationKey observed))
      else case find ((== stackKey) . exactObservationKey) (frozenTeardownExactObservations fixture) of
        Nothing ->
          Left
            ( TeardownRecoveryFakeRefused
                ( TeardownRecoveryFakeRequestMissing
                    ( TeardownRecoveryProviderRequest
                        (frozenTeardownFixtureId fixture)
                        (frozenTeardownEvidenceScope fixture)
                        stackKey
                    )
                )
            )
        Just expected
          | observed == expected -> Right observed
          | otherwise -> Left (TeardownRecoveryProviderMismatch stackKey expected observed)

  validateCheckpoint stackKey observedResult = do
    observed <- either (Left . TeardownRecoveryFakeRefused) Right observedResult
    if checkpointObservationKey observed /= stackKey
      then Left (TeardownRecoveryCheckpointKeyMismatch stackKey (checkpointObservationKey observed))
      else case find ((== stackKey) . checkpointObservationKey) (frozenTeardownCheckpointObservations fixture) of
        Nothing ->
          Left
            ( TeardownRecoveryFakeRefused
                ( TeardownRecoveryFakeRequestMissing
                    ( TeardownRecoveryCheckpointRequest
                        (frozenTeardownFixtureId fixture)
                        (frozenTeardownEvidenceScope fixture)
                        stackKey
                    )
                )
            )
        Just expected
          | observed == expected -> Right observed
          | otherwise -> Left (TeardownRecoveryCheckpointMismatch stackKey expected observed)

  checkExact mismatch expected observedResult = do
    observed <- either (Left . TeardownRecoveryFakeRefused) Right observedResult
    if observed == expected
      then Right observed
      else Left (mismatch expected observed)

  finish auditRows providerRows checkpointRows kubernetesObservation authorityObservation backupObservation reportObservation =
    let actual =
          ReplacementTeardownResult
            { replacementRetainedAuditArns = map normalizedAuditArn auditRows
            , replacementExactUnobservables =
                Map.fromList
                  [ (exactObservationKey observation, exactObservationFailure observation)
                  | observation <- providerRows
                  ]
            , replacementCheckpointUnobservables =
                Map.fromList
                  [ (checkpointObservationKey observation, checkpointObservationFailure observation)
                  | observation <- checkpointRows
                  ]
            , replacementBackupObservation = backupObservation
            , replacementReportObservation = reportObservation
            , replacementDrainSelection = NoDrainSelected
            , replacementDestroySelection = NoDestroySelected
            , replacementCascadeResult =
                CascadeIncomplete
                  CallerFailure
                    { failedCallerIdentity = localCallerIdentity kubernetesObservation
                    , failedCallerReason = localCallerFailure kubernetesObservation
                    }
                  [ CleanupFailure
                      { failedCleanupBoundary = authorityObservationIdentity authorityObservation
                      , failedCleanupReason = authorityObservationFailure authorityObservation
                      }
                  ]
            }
        expected = replacementTeardownOracle fixture
     in if actual == expected
          then Right actual
          else Left (TeardownRecoveryReplacementMismatch expected actual)
