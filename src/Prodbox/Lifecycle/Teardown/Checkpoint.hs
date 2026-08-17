{-# LANGUAGE OverloadedStrings #-}

-- | Crash-safe checkpoint recovery and retirement proofs for stack teardown.
-- A restore effect never produces a verified primary checkpoint: only an
-- exact read-back bound to the preallocated operation reference can do that.
-- Likewise, checkpoint material can be retired only after provider absence
-- has already been observed for the same stack and cleanup scope.
module Prodbox.Lifecycle.Teardown.Checkpoint
  ( CheckpointRestoreRequest
  , checkpointRestoreOperationId
  , checkpointRestoreStackKey
  , checkpointRestoreCoordinateDigest
  , checkpointRestoreScope
  , checkpointRestoreBackupProvenance
  , checkpointRestoreBackupVersion
  , CheckpointRestoreAttempt (..)
  , CheckpointRestoreDisposition (..)
  , CheckpointRestoreOutcome
  , checkpointRestoreOutcomeOperationId
  , checkpointRestoreOutcomeStackKey
  , checkpointRestoreOutcomeCoordinateDigest
  , checkpointRestoreOutcomeScope
  , checkpointRestoreOutcomeDisposition
  , CheckpointRecoveryDisposition (..)
  , CheckpointRecoveryReadBackEvidence
  , checkpointRecoveryOperationId
  , checkpointRecoveryStackKey
  , checkpointRecoveryCoordinateDigest
  , checkpointRecoveryScope
  , checkpointRecoveryDisposition
  , CheckpointRestoreReadBack (..)
  , VerifiedRestoredPrimaryCheckpoint
  , verifiedRestoredPrimaryOperationId
  , verifiedRestoredPrimaryStackKey
  , verifiedRestoredPrimaryProvenance
  , verifiedRestoredPrimaryVersion
  , CheckpointRestoreError (..)
  , mkCheckpointRestoreRequest
  , mkCheckpointRestoreNotRequiredOutcome
  , mkCheckpointRestoreNoMutationOutcome
  , recordCheckpointRestoreAttempt
  , confirmCheckpointNoRestoreReadBack
  , confirmCheckpointRecoveryReadBack
  , confirmRestoredCheckpoint
  , CheckpointRetirementPolicy (..)
  , CheckpointRetirementAttempt (..)
  , CheckpointRetirementOutcome
  , checkpointRetirementOutcomeOperationId
  , checkpointRetirementOutcomeStackKey
  , checkpointRetirementOutcomeCoordinateDigest
  , checkpointRetirementOutcomeScope
  , checkpointRetirementOutcomeAttempt
  , CheckpointReferenceDisposition (..)
  , CheckpointRetirementObservation (..)
  , CheckpointRetirementAuthorization
  , checkpointRetirementOperationId
  , checkpointRetirementStackKey
  , checkpointRetirementCoordinateDigest
  , checkpointRetirementScope
  , checkpointRetirementPolicy
  , CheckpointRetirementEvidence
  , checkpointRetirementEvidenceOperationId
  , checkpointRetirementEvidenceStackKey
  , checkpointRetirementEvidenceCoordinateDigest
  , checkpointRetirementEvidenceScope
  , checkpointRetirementEvidencePolicy
  , CheckpointRetirementError (..)
  , authorizeCheckpointRetirement
  , recordCheckpointRetirementAttempt
  , confirmCheckpointRetirement
  )
where

import Prodbox.Lifecycle.CleanupRun (CleanupOperationId)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

-- | A restore request sealed before the external copy operation begins.
-- Only a positively read-back backup copy can enter this value.
data CheckpointRestoreRequest = CheckpointRestoreRequest
  { internalCheckpointRestoreOperationId :: !CleanupOperationId
  , internalCheckpointRestoreStackKey :: !RegisteredResourceKey
  , internalCheckpointRestoreCoordinateDigest :: !ManagedResourceCoordinateDigest
  , internalCheckpointRestoreScope :: !ObservationEvidenceScope
  , internalCheckpointRestoreBackupProvenance :: !CheckpointProvenance
  , internalCheckpointRestoreBackupVersion :: !CheckpointVersion
  }
  deriving (Eq, Show)

checkpointRestoreOperationId :: CheckpointRestoreRequest -> CleanupOperationId
checkpointRestoreOperationId = internalCheckpointRestoreOperationId

checkpointRestoreStackKey :: CheckpointRestoreRequest -> RegisteredResourceKey
checkpointRestoreStackKey = internalCheckpointRestoreStackKey

checkpointRestoreCoordinateDigest
  :: CheckpointRestoreRequest -> ManagedResourceCoordinateDigest
checkpointRestoreCoordinateDigest = internalCheckpointRestoreCoordinateDigest

checkpointRestoreScope :: CheckpointRestoreRequest -> ObservationEvidenceScope
checkpointRestoreScope = internalCheckpointRestoreScope

checkpointRestoreBackupProvenance
  :: CheckpointRestoreRequest -> CheckpointProvenance
checkpointRestoreBackupProvenance = internalCheckpointRestoreBackupProvenance

checkpointRestoreBackupVersion :: CheckpointRestoreRequest -> CheckpointVersion
checkpointRestoreBackupVersion = internalCheckpointRestoreBackupVersion

-- | Diagnostic result of the copy attempt.  Response loss deliberately stays
-- distinct from refusal; neither constructor is destruction authority.
data CheckpointRestoreAttempt
  = CheckpointRestoreApplied
  | CheckpointRestoreResponseLost
  | CheckpointRestoreRefused !ObservationFailure
  deriving (Eq, Show)

-- | Diagnostic disposition of the restore effect.  The opaque wrapper below
-- binds this value to the stable operation reference and exact stack scope.
data CheckpointRestoreDisposition
  = CheckpointRestorePrimaryAlreadyAvailable
  | CheckpointRestoreResourceAlreadyAbsent !AbsenceEvidence
  | CheckpointRestoreNoUsableBackup
  | CheckpointRestoreMutationAttempted !CheckpointRestoreAttempt
  deriving (Eq, Show)

-- | Bound result of the restore effect.  A no-mutation result can be minted
-- only from exact stack absence or an exact checkpoint-pair observation for
-- which copying the backup is not required or not possible.  A mutation
-- result requires the opaque request produced from a positively observed
-- backup.
data CheckpointRestoreOutcome = CheckpointRestoreOutcome
  { internalCheckpointRestoreOutcomeOperationId :: !CleanupOperationId
  , internalCheckpointRestoreOutcomeStackKey :: !RegisteredResourceKey
  , internalCheckpointRestoreOutcomeCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalCheckpointRestoreOutcomeScope :: !ObservationEvidenceScope
  , internalCheckpointRestoreOutcomeDisposition :: !CheckpointRestoreDisposition
  }
  deriving (Eq, Show)

checkpointRestoreOutcomeOperationId
  :: CheckpointRestoreOutcome -> CleanupOperationId
checkpointRestoreOutcomeOperationId =
  internalCheckpointRestoreOutcomeOperationId

checkpointRestoreOutcomeStackKey
  :: CheckpointRestoreOutcome -> RegisteredResourceKey
checkpointRestoreOutcomeStackKey = internalCheckpointRestoreOutcomeStackKey

checkpointRestoreOutcomeCoordinateDigest
  :: CheckpointRestoreOutcome -> ManagedResourceCoordinateDigest
checkpointRestoreOutcomeCoordinateDigest =
  internalCheckpointRestoreOutcomeCoordinateDigest

checkpointRestoreOutcomeScope
  :: CheckpointRestoreOutcome -> ObservationEvidenceScope
checkpointRestoreOutcomeScope = internalCheckpointRestoreOutcomeScope

checkpointRestoreOutcomeDisposition
  :: CheckpointRestoreOutcome -> CheckpointRestoreDisposition
checkpointRestoreOutcomeDisposition = internalCheckpointRestoreOutcomeDisposition

-- | What the independent recovery read-back established.  No case is
-- constructible from the restore effect result: the primary case is a fresh
-- positive checkpoint observation, the no-restore case is fresh exact stack
-- absence, and the unavailable case is exact absence of both checkpoint
-- copies.
data CheckpointRecoveryDisposition
  = CheckpointRecoveryPrimaryAvailable
      !CheckpointProvenance
      !CheckpointVersion
  | CheckpointRecoveryRestoreNotRequired !AbsenceEvidence
  | CheckpointRecoveryNoUsableCheckpoint
      !CheckpointResult
      !CheckpointResult
  deriving (Eq, Show)

data CheckpointRecoveryReadBackEvidence = CheckpointRecoveryReadBackEvidence
  { internalCheckpointRecoveryOperationId :: !CleanupOperationId
  , internalCheckpointRecoveryStackKey :: !RegisteredResourceKey
  , internalCheckpointRecoveryCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalCheckpointRecoveryScope :: !ObservationEvidenceScope
  , internalCheckpointRecoveryDisposition :: !CheckpointRecoveryDisposition
  }
  deriving (Eq, Show)

checkpointRecoveryOperationId
  :: CheckpointRecoveryReadBackEvidence -> CleanupOperationId
checkpointRecoveryOperationId = internalCheckpointRecoveryOperationId

checkpointRecoveryStackKey
  :: CheckpointRecoveryReadBackEvidence -> RegisteredResourceKey
checkpointRecoveryStackKey = internalCheckpointRecoveryStackKey

checkpointRecoveryCoordinateDigest
  :: CheckpointRecoveryReadBackEvidence -> ManagedResourceCoordinateDigest
checkpointRecoveryCoordinateDigest = internalCheckpointRecoveryCoordinateDigest

checkpointRecoveryScope
  :: CheckpointRecoveryReadBackEvidence -> ObservationEvidenceScope
checkpointRecoveryScope = internalCheckpointRecoveryScope

checkpointRecoveryDisposition
  :: CheckpointRecoveryReadBackEvidence -> CheckpointRecoveryDisposition
checkpointRecoveryDisposition = internalCheckpointRecoveryDisposition

-- | Flat adapter value returned by the mandatory primary-copy read-back.
data CheckpointRestoreReadBack = CheckpointRestoreReadBack
  { checkpointRestoreReadBackOperationId :: !CleanupOperationId
  , checkpointRestoreReadBackObservation :: !CheckpointObservation
  }
  deriving (Eq, Show)

-- | Private evidence that the primary now contains the exact independently
-- observed backup version under the original stable operation reference.
data VerifiedRestoredPrimaryCheckpoint = VerifiedRestoredPrimaryCheckpoint
  { internalVerifiedRestoredPrimaryOperationId :: !CleanupOperationId
  , internalVerifiedRestoredPrimaryStackKey :: !RegisteredResourceKey
  , internalVerifiedRestoredPrimaryProvenance :: !CheckpointProvenance
  , internalVerifiedRestoredPrimaryVersion :: !CheckpointVersion
  }
  deriving (Eq, Show)

verifiedRestoredPrimaryOperationId
  :: VerifiedRestoredPrimaryCheckpoint -> CleanupOperationId
verifiedRestoredPrimaryOperationId = internalVerifiedRestoredPrimaryOperationId

verifiedRestoredPrimaryStackKey
  :: VerifiedRestoredPrimaryCheckpoint -> RegisteredResourceKey
verifiedRestoredPrimaryStackKey = internalVerifiedRestoredPrimaryStackKey

verifiedRestoredPrimaryProvenance
  :: VerifiedRestoredPrimaryCheckpoint -> CheckpointProvenance
verifiedRestoredPrimaryProvenance = internalVerifiedRestoredPrimaryProvenance

verifiedRestoredPrimaryVersion
  :: VerifiedRestoredPrimaryCheckpoint -> CheckpointVersion
verifiedRestoredPrimaryVersion = internalVerifiedRestoredPrimaryVersion

data CheckpointRestoreError
  = CheckpointRestoreStackUnregistered !RegisteredResourceKey
  | CheckpointRestoreTargetIsNotStack !RegisteredResourceKey !ResourceKind
  | CheckpointRestoreTargetNotAllowed !RegisteredResourceKey !CleanupSurface
  | CheckpointRestoreScopeOperationInvalid !LifecycleOperation
  | CheckpointRestoreScopeRevisionMismatch !RegistryRevision !RegistryRevision
  | CheckpointRestoreBackupKeyMismatch !RegisteredResourceKey !RegisteredResourceKey
  | CheckpointRestoreBackupCopyInvalid !CheckpointCopy
  | CheckpointRestoreBackupScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CheckpointRestoreBackupUnavailable !CheckpointResult
  | CheckpointRestoreAbsenceBindingInvalid !CompleteObservationSetError
  | CheckpointRestoreResourceNotAbsent !ExactObservationResult
  | CheckpointRestorePairInvalid !CheckpointPairError
  | CheckpointRestoreMutationRequired !CheckpointVersion
  | CheckpointRestoreRecoveryIncomplete !CheckpointCopy !CheckpointResult
  | CheckpointRestorePrimaryNotRecovered
      !CheckpointVersion
      !CheckpointResult
  | CheckpointRestoreReadBackOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | CheckpointRestorePrimaryKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | CheckpointRestorePrimaryCopyInvalid !CheckpointCopy
  | CheckpointRestorePrimaryScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CheckpointRestorePrimaryVersionMismatch !CheckpointVersion !CheckpointVersion
  | CheckpointRestorePrimaryUnavailable !CheckpointResult
  deriving (Eq, Show)

-- | Seal the no-restore branch only when an independent exact observation
-- already proves the registered stack absent.  This is deliberately
-- separate from checkpoint state: stale backup material is retired later,
-- after the registered absence read-back, and is never restored merely to
-- make teardown possible.
mkCheckpointRestoreNotRequiredOutcome
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ExactResourceObservation
  -> Either CheckpointRestoreError CheckpointRestoreOutcome
mkCheckpointRestoreNotRequiredOutcome operationId stackKey scope observation = do
  identity <- validateStackTarget stackKey scope
  absence <- validateExactStackAbsence stackKey scope observation
  Right
    CheckpointRestoreOutcome
      { internalCheckpointRestoreOutcomeOperationId = operationId
      , internalCheckpointRestoreOutcomeStackKey = stackKey
      , internalCheckpointRestoreOutcomeCoordinateDigest =
          registeredIdentityCoordinateDigest identity
      , internalCheckpointRestoreOutcomeScope = scope
      , internalCheckpointRestoreOutcomeDisposition =
          CheckpointRestoreResourceAlreadyAbsent absence
      }

-- | Seal a no-mutation restore result from the exact current pair.  A usable
-- primary needs no copy.  If the primary is unusable, a usable backup makes a
-- mutation mandatory and this constructor refuses.
mkCheckpointRestoreNoMutationOutcome
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointPairObservation
  -> Either CheckpointRestoreError CheckpointRestoreOutcome
mkCheckpointRestoreNoMutationOutcome operationId stackKey scope pair = do
  identity <- validateStackTarget stackKey scope
  validatedPair <- validatePair stackKey scope pair
  let primaryResult =
        checkpointObservationResult
          (primaryCheckpointObservation validatedPair)
      backupResult =
        checkpointObservationResult
          (backupCheckpointObservation validatedPair)
      disposition = case primaryResult of
        CheckpointPresent _ -> Right CheckpointRestorePrimaryAlreadyAvailable
        _ -> case backupResult of
          CheckpointPresent version -> Left (CheckpointRestoreMutationRequired version)
          _ -> exactNoCheckpointDisposition primaryResult backupResult
  resolvedDisposition <- disposition
  Right
    CheckpointRestoreOutcome
      { internalCheckpointRestoreOutcomeOperationId = operationId
      , internalCheckpointRestoreOutcomeStackKey = stackKey
      , internalCheckpointRestoreOutcomeCoordinateDigest =
          registeredIdentityCoordinateDigest identity
      , internalCheckpointRestoreOutcomeScope = scope
      , internalCheckpointRestoreOutcomeDisposition = resolvedDisposition
      }

-- | Bind the diagnostic mutation outcome to the opaque request which had to
-- be constructed before the copy effect was attempted.
recordCheckpointRestoreAttempt
  :: CheckpointRestoreRequest
  -> CheckpointRestoreAttempt
  -> CheckpointRestoreOutcome
recordCheckpointRestoreAttempt request attempt =
  CheckpointRestoreOutcome
    { internalCheckpointRestoreOutcomeOperationId =
        checkpointRestoreOperationId request
    , internalCheckpointRestoreOutcomeStackKey = checkpointRestoreStackKey request
    , internalCheckpointRestoreOutcomeCoordinateDigest =
        checkpointRestoreCoordinateDigest request
    , internalCheckpointRestoreOutcomeScope = checkpointRestoreScope request
    , internalCheckpointRestoreOutcomeDisposition =
        CheckpointRestoreMutationAttempted attempt
    }

-- | Re-observe the exact registered resource through the stable restore
-- operation reference.  This is the only recovery read-back which may skip
-- primary restoration while a backup remains: the stack itself is already
-- authoritatively absent, so checkpoint material can proceed to retirement.
confirmCheckpointNoRestoreReadBack
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ExactResourceObservation
  -> Either CheckpointRestoreError CheckpointRecoveryReadBackEvidence
confirmCheckpointNoRestoreReadBack operationId stackKey scope observation = do
  identity <- validateStackTarget stackKey scope
  absence <- validateExactStackAbsence stackKey scope observation
  Right
    CheckpointRecoveryReadBackEvidence
      { internalCheckpointRecoveryOperationId = operationId
      , internalCheckpointRecoveryStackKey = stackKey
      , internalCheckpointRecoveryCoordinateDigest =
          registeredIdentityCoordinateDigest identity
      , internalCheckpointRecoveryScope = scope
      , internalCheckpointRecoveryDisposition =
          CheckpointRecoveryRestoreNotRequired absence
      }

-- | Independently read back the checkpoint pair through the stable restore
-- operation reference.  A still-usable backup with no primary proves that a
-- required restore has not converged; it cannot be reclassified as the
-- no-checkpoint fallback.
confirmCheckpointRecoveryReadBack
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointPairObservation
  -> Either CheckpointRestoreError CheckpointRecoveryReadBackEvidence
confirmCheckpointRecoveryReadBack operationId stackKey scope pair = do
  identity <- validateStackTarget stackKey scope
  validatedPair <- validatePair stackKey scope pair
  let primary = primaryCheckpointObservation validatedPair
      backup = backupCheckpointObservation validatedPair
      primaryResult = checkpointObservationResult primary
      backupResult = checkpointObservationResult backup
  disposition <- case primaryResult of
    CheckpointPresent version ->
      Right
        ( CheckpointRecoveryPrimaryAvailable
            (checkpointObservationProvenance primary)
            version
        )
    _ -> case backupResult of
      CheckpointPresent expectedVersion ->
        Left
          ( CheckpointRestorePrimaryNotRecovered
              expectedVersion
              primaryResult
          )
      _ -> exactNoCheckpointRecovery primaryResult backupResult
  Right
    CheckpointRecoveryReadBackEvidence
      { internalCheckpointRecoveryOperationId = operationId
      , internalCheckpointRecoveryStackKey = stackKey
      , internalCheckpointRecoveryCoordinateDigest =
          registeredIdentityCoordinateDigest identity
      , internalCheckpointRecoveryScope = scope
      , internalCheckpointRecoveryDisposition = disposition
      }

exactNoCheckpointDisposition
  :: CheckpointResult
  -> CheckpointResult
  -> Either CheckpointRestoreError CheckpointRestoreDisposition
exactNoCheckpointDisposition primaryResult backupResult =
  case (primaryResult, backupResult) of
    (CheckpointAbsent, CheckpointAbsent) ->
      Right CheckpointRestoreNoUsableBackup
    (CheckpointPartial _, _) ->
      Left
        ( CheckpointRestoreRecoveryIncomplete
            PrimaryCheckpointCopy
            primaryResult
        )
    (CheckpointUnobservable _, _) ->
      Left
        ( CheckpointRestoreRecoveryIncomplete
            PrimaryCheckpointCopy
            primaryResult
        )
    (_, CheckpointPartial _) ->
      Left
        ( CheckpointRestoreRecoveryIncomplete
            BackupCheckpointCopy
            backupResult
        )
    (_, CheckpointUnobservable _) ->
      Left
        ( CheckpointRestoreRecoveryIncomplete
            BackupCheckpointCopy
            backupResult
        )
    _ ->
      Left
        ( CheckpointRestoreRecoveryIncomplete
            PrimaryCheckpointCopy
            primaryResult
        )

exactNoCheckpointRecovery
  :: CheckpointResult
  -> CheckpointResult
  -> Either CheckpointRestoreError CheckpointRecoveryDisposition
exactNoCheckpointRecovery primaryResult backupResult = do
  disposition <- exactNoCheckpointDisposition primaryResult backupResult
  case disposition of
    CheckpointRestoreNoUsableBackup ->
      Right
        ( CheckpointRecoveryNoUsableCheckpoint
            primaryResult
            backupResult
        )
    _ ->
      Left
        ( CheckpointRestoreRecoveryIncomplete
            PrimaryCheckpointCopy
            primaryResult
        )

validateExactStackAbsence
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ExactResourceObservation
  -> Either CheckpointRestoreError AbsenceEvidence
validateExactStackAbsence stackKey scope observation = do
  _ <-
    either
      (Left . CheckpointRestoreAbsenceBindingInvalid)
      Right
      (mkCompleteObservationSet scope [stackKey] [observation])
  case exactObservationResult observation of
    ExactResourceAbsent absence -> Right absence
    other -> Left (CheckpointRestoreResourceNotAbsent other)

mkCheckpointRestoreRequest
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointObservation
  -> Either CheckpointRestoreError CheckpointRestoreRequest
mkCheckpointRestoreRequest operationId stackKey scope backup = do
  identity <- validateStackTarget stackKey scope
  if checkpointObservationStackKey backup == stackKey
    then Right ()
    else
      Left
        ( CheckpointRestoreBackupKeyMismatch
            stackKey
            (checkpointObservationStackKey backup)
        )
  if checkpointObservationCopy backup == BackupCheckpointCopy
    then Right ()
    else Left (CheckpointRestoreBackupCopyInvalid (checkpointObservationCopy backup))
  if checkpointObservationEvidenceScope backup == scope
    then Right ()
    else
      Left
        ( CheckpointRestoreBackupScopeMismatch
            scope
            (checkpointObservationEvidenceScope backup)
        )
  version <- case checkpointObservationResult backup of
    CheckpointPresent observedVersion -> Right observedVersion
    unavailable -> Left (CheckpointRestoreBackupUnavailable unavailable)
  Right
    CheckpointRestoreRequest
      { internalCheckpointRestoreOperationId = operationId
      , internalCheckpointRestoreStackKey = stackKey
      , internalCheckpointRestoreCoordinateDigest =
          registeredIdentityCoordinateDigest identity
      , internalCheckpointRestoreScope = scope
      , internalCheckpointRestoreBackupProvenance =
          checkpointObservationProvenance backup
      , internalCheckpointRestoreBackupVersion = version
      }

confirmRestoredCheckpoint
  :: CheckpointRestoreRequest
  -> CheckpointRestoreReadBack
  -> Either CheckpointRestoreError VerifiedRestoredPrimaryCheckpoint
confirmRestoredCheckpoint request readBack = do
  let expectedOperation = checkpointRestoreOperationId request
      observedOperation = checkpointRestoreReadBackOperationId readBack
      observation = checkpointRestoreReadBackObservation readBack
      expectedKey = checkpointRestoreStackKey request
      expectedScope = checkpointRestoreScope request
      expectedVersion = checkpointRestoreBackupVersion request
  if observedOperation == expectedOperation
    then Right ()
    else
      Left
        ( CheckpointRestoreReadBackOperationMismatch
            expectedOperation
            observedOperation
        )
  if checkpointObservationStackKey observation == expectedKey
    then Right ()
    else
      Left
        ( CheckpointRestorePrimaryKeyMismatch
            expectedKey
            (checkpointObservationStackKey observation)
        )
  if checkpointObservationCopy observation == PrimaryCheckpointCopy
    then Right ()
    else Left (CheckpointRestorePrimaryCopyInvalid (checkpointObservationCopy observation))
  if checkpointObservationEvidenceScope observation == expectedScope
    then Right ()
    else
      Left
        ( CheckpointRestorePrimaryScopeMismatch
            expectedScope
            (checkpointObservationEvidenceScope observation)
        )
  observedVersion <- case checkpointObservationResult observation of
    CheckpointPresent version -> Right version
    unavailable -> Left (CheckpointRestorePrimaryUnavailable unavailable)
  if observedVersion == expectedVersion
    then
      Right
        VerifiedRestoredPrimaryCheckpoint
          { internalVerifiedRestoredPrimaryOperationId = expectedOperation
          , internalVerifiedRestoredPrimaryStackKey = expectedKey
          , internalVerifiedRestoredPrimaryProvenance =
              checkpointObservationProvenance observation
          , internalVerifiedRestoredPrimaryVersion = observedVersion
          }
    else Left (CheckpointRestorePrimaryVersionMismatch expectedVersion observedVersion)

data CheckpointRetirementPolicy
  = RetireActiveCheckpointReference
  deriving (Eq, Show)

data CheckpointRetirementAttempt
  = CheckpointRetirementApplied
  | CheckpointRetirementResponseLost
  | CheckpointRetirementRefused !ObservationFailure
  deriving (Eq, Show)

-- | A retirement effect result can be recorded only alongside the opaque
-- authorization which already contains exact provider absence.
data CheckpointRetirementOutcome = CheckpointRetirementOutcome
  { internalCheckpointRetirementOutcomeOperationId :: !CleanupOperationId
  , internalCheckpointRetirementOutcomeStackKey :: !RegisteredResourceKey
  , internalCheckpointRetirementOutcomeCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalCheckpointRetirementOutcomeScope :: !ObservationEvidenceScope
  , internalCheckpointRetirementOutcomeAttempt :: !CheckpointRetirementAttempt
  }
  deriving (Eq, Show)

checkpointRetirementOutcomeOperationId
  :: CheckpointRetirementOutcome -> CleanupOperationId
checkpointRetirementOutcomeOperationId =
  internalCheckpointRetirementOutcomeOperationId

checkpointRetirementOutcomeStackKey
  :: CheckpointRetirementOutcome -> RegisteredResourceKey
checkpointRetirementOutcomeStackKey = internalCheckpointRetirementOutcomeStackKey

checkpointRetirementOutcomeCoordinateDigest
  :: CheckpointRetirementOutcome -> ManagedResourceCoordinateDigest
checkpointRetirementOutcomeCoordinateDigest =
  internalCheckpointRetirementOutcomeCoordinateDigest

checkpointRetirementOutcomeScope
  :: CheckpointRetirementOutcome -> ObservationEvidenceScope
checkpointRetirementOutcomeScope = internalCheckpointRetirementOutcomeScope

checkpointRetirementOutcomeAttempt
  :: CheckpointRetirementOutcome -> CheckpointRetirementAttempt
checkpointRetirementOutcomeAttempt = internalCheckpointRetirementOutcomeAttempt

-- | Independent aggregate read-back after the logical-retirement attempt.
-- The immutable primary and backup blobs deliberately remain present for the
-- separately fenced GC protocol; this value speaks only about whether the
-- exact aggregate reference is still current.
data CheckpointReferenceDisposition
  = CheckpointReferenceRetired !CheckpointVersion
  | CheckpointReferenceAlreadyRetired
  | CheckpointReferenceStillCurrent !CheckpointVersion
  | CheckpointReferenceDispositionUnobservable !ObservationFailure
  deriving (Eq, Show)

data CheckpointRetirementObservation = CheckpointRetirementObservation
  { checkpointRetirementObservationOperationId :: !CleanupOperationId
  , checkpointRetirementObservationStackKey :: !RegisteredResourceKey
  , checkpointRetirementObservationScope :: !ObservationEvidenceScope
  , checkpointRetirementObservationPrimaryProvenance :: !CheckpointProvenance
  , checkpointRetirementObservationBackupProvenance :: !CheckpointProvenance
  , checkpointRetirementObservationReferenceDisposition
      :: !CheckpointReferenceDisposition
  }
  deriving (Eq, Show)

data CheckpointReferenceExpectation
  = CheckpointReferenceWasAlreadyRetired
  | CheckpointReferenceWasCurrent !CheckpointVersion
  deriving (Eq, Show)

data CheckpointRetirementAuthorization = CheckpointRetirementAuthorization
  { internalCheckpointRetirementOperationId :: !CleanupOperationId
  , internalCheckpointRetirementStackKey :: !RegisteredResourceKey
  , internalCheckpointRetirementCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalCheckpointRetirementScope :: !ObservationEvidenceScope
  , internalCheckpointRetirementPolicy :: !CheckpointRetirementPolicy
  , internalCheckpointRetirementPrimaryProvenance :: !CheckpointProvenance
  , internalCheckpointRetirementBackupProvenance :: !CheckpointProvenance
  , internalCheckpointRetirementReferenceExpectation
      :: !CheckpointReferenceExpectation
  }
  deriving (Eq, Show)

checkpointRetirementOperationId
  :: CheckpointRetirementAuthorization -> CleanupOperationId
checkpointRetirementOperationId = internalCheckpointRetirementOperationId

checkpointRetirementStackKey
  :: CheckpointRetirementAuthorization -> RegisteredResourceKey
checkpointRetirementStackKey = internalCheckpointRetirementStackKey

checkpointRetirementCoordinateDigest
  :: CheckpointRetirementAuthorization -> ManagedResourceCoordinateDigest
checkpointRetirementCoordinateDigest = internalCheckpointRetirementCoordinateDigest

checkpointRetirementScope
  :: CheckpointRetirementAuthorization -> ObservationEvidenceScope
checkpointRetirementScope = internalCheckpointRetirementScope

checkpointRetirementPolicy
  :: CheckpointRetirementAuthorization -> CheckpointRetirementPolicy
checkpointRetirementPolicy = internalCheckpointRetirementPolicy

data CheckpointRetirementEvidence = CheckpointRetirementEvidence
  { internalCheckpointRetirementEvidenceOperationId :: !CleanupOperationId
  , internalCheckpointRetirementEvidenceStackKey :: !RegisteredResourceKey
  , internalCheckpointRetirementEvidenceCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalCheckpointRetirementEvidenceScope :: !ObservationEvidenceScope
  , internalCheckpointRetirementEvidencePolicy :: !CheckpointRetirementPolicy
  }
  deriving (Eq, Show)

checkpointRetirementEvidenceOperationId
  :: CheckpointRetirementEvidence -> CleanupOperationId
checkpointRetirementEvidenceOperationId =
  internalCheckpointRetirementEvidenceOperationId

checkpointRetirementEvidenceStackKey
  :: CheckpointRetirementEvidence -> RegisteredResourceKey
checkpointRetirementEvidenceStackKey =
  internalCheckpointRetirementEvidenceStackKey

checkpointRetirementEvidenceCoordinateDigest
  :: CheckpointRetirementEvidence -> ManagedResourceCoordinateDigest
checkpointRetirementEvidenceCoordinateDigest =
  internalCheckpointRetirementEvidenceCoordinateDigest

checkpointRetirementEvidenceScope
  :: CheckpointRetirementEvidence -> ObservationEvidenceScope
checkpointRetirementEvidenceScope = internalCheckpointRetirementEvidenceScope

checkpointRetirementEvidencePolicy
  :: CheckpointRetirementEvidence -> CheckpointRetirementPolicy
checkpointRetirementEvidencePolicy = internalCheckpointRetirementEvidencePolicy

data CheckpointRetirementError
  = CheckpointRetirementStackUnregistered !RegisteredResourceKey
  | CheckpointRetirementTargetIsNotStack !RegisteredResourceKey !ResourceKind
  | CheckpointRetirementTargetNotAllowed !RegisteredResourceKey !CleanupSurface
  | CheckpointRetirementScopeOperationInvalid !LifecycleOperation
  | CheckpointRetirementScopeRevisionMismatch !RegistryRevision !RegistryRevision
  | CheckpointRetirementAbsenceKeyMismatch !RegisteredResourceKey !RegisteredResourceKey
  | CheckpointRetirementAbsenceCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | CheckpointRetirementAbsenceAuthorityMismatch !ObservationAuthority
  | CheckpointRetirementAbsenceScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CheckpointRetirementResourceNotAbsent !ExactObservationResult
  | CheckpointRetirementPairInvalid !CheckpointPairError
  | CheckpointRetirementCheckpointInventoryIncomplete
      !CheckpointCopy
      !CheckpointResult
  | CheckpointRetirementReadBackOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | CheckpointRetirementReadBackKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | CheckpointRetirementReadBackScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CheckpointRetirementProvenanceMismatch
      !CheckpointCopy
      !CheckpointProvenance
      !CheckpointProvenance
  | CheckpointRetirementVersionMismatch !CheckpointVersion !CheckpointVersion
  | CheckpointRetirementDispositionMismatch
      !CheckpointReferenceDisposition
      !CheckpointReferenceDisposition
  deriving (Eq, Show)

authorizeCheckpointRetirement
  :: CleanupOperationId
  -> CheckpointRetirementPolicy
  -> ObservationEvidenceScope
  -> ExactResourceObservation
  -> CheckpointPairObservation
  -> Either CheckpointRetirementError CheckpointRetirementAuthorization
authorizeCheckpointRetirement operationId policy scope absence pair = do
  let stackKey = exactObservationResourceKey absence
  identity <- firstRestoreError (validateStackTarget stackKey scope)
  if exactObservationCoordinateDigest absence == registeredIdentityCoordinateDigest identity
    then Right ()
    else
      Left
        ( CheckpointRetirementAbsenceCoordinateMismatch
            (registeredIdentityCoordinateDigest identity)
            (exactObservationCoordinateDigest absence)
        )
  if exactObservationAuthority absence == registeredIdentityObservationAuthority identity
    then Right ()
    else
      Left
        ( CheckpointRetirementAbsenceAuthorityMismatch
            (exactObservationAuthority absence)
        )
  if exactObservationEvidenceScope absence == scope
    then Right ()
    else
      Left
        ( CheckpointRetirementAbsenceScopeMismatch
            scope
            (exactObservationEvidenceScope absence)
        )
  case exactObservationResult absence of
    ExactResourceAbsent _ -> Right ()
    other -> Left (CheckpointRetirementResourceNotAbsent other)
  validatedPair <-
    either
      (Left . CheckpointRetirementPairInvalid)
      Right
      ( mkCheckpointPairObservation
          stackKey
          scope
          (primaryCheckpointObservation pair)
          (backupCheckpointObservation pair)
      )
  referenceExpectation <-
    expectedReference
      (checkpointObservationResult (primaryCheckpointObservation validatedPair))
      (checkpointObservationResult (backupCheckpointObservation validatedPair))
  Right
    CheckpointRetirementAuthorization
      { internalCheckpointRetirementOperationId = operationId
      , internalCheckpointRetirementStackKey = stackKey
      , internalCheckpointRetirementCoordinateDigest =
          registeredIdentityCoordinateDigest identity
      , internalCheckpointRetirementScope = scope
      , internalCheckpointRetirementPolicy = policy
      , internalCheckpointRetirementPrimaryProvenance =
          checkpointObservationProvenance (primaryCheckpointObservation validatedPair)
      , internalCheckpointRetirementBackupProvenance =
          checkpointObservationProvenance (backupCheckpointObservation validatedPair)
      , internalCheckpointRetirementReferenceExpectation = referenceExpectation
      }
 where
  firstRestoreError result = case result of
    Right identity -> Right identity
    Left err -> case err of
      CheckpointRestoreStackUnregistered key ->
        Left (CheckpointRetirementStackUnregistered key)
      CheckpointRestoreTargetIsNotStack key kind ->
        Left (CheckpointRetirementTargetIsNotStack key kind)
      CheckpointRestoreTargetNotAllowed key surface ->
        Left (CheckpointRetirementTargetNotAllowed key surface)
      CheckpointRestoreScopeOperationInvalid operation ->
        Left (CheckpointRetirementScopeOperationInvalid operation)
      CheckpointRestoreScopeRevisionMismatch expected actual ->
        Left (CheckpointRetirementScopeRevisionMismatch expected actual)
      _ -> Left (CheckpointRetirementStackUnregistered (exactObservationResourceKey absence))

  expectedReference primaryResult backupResult =
    case (primaryResult, backupResult) of
      (CheckpointAbsent, CheckpointAbsent) ->
        Right CheckpointReferenceWasAlreadyRetired
      (CheckpointPresent version, CheckpointAbsent) ->
        Right (CheckpointReferenceWasCurrent version)
      (CheckpointAbsent, CheckpointPresent version) ->
        Right (CheckpointReferenceWasCurrent version)
      (CheckpointPresent primaryVersion, CheckpointPresent backupVersion)
        | primaryVersion == backupVersion ->
            Right (CheckpointReferenceWasCurrent primaryVersion)
        | otherwise ->
            Left
              ( CheckpointRetirementVersionMismatch
                  primaryVersion
                  backupVersion
              )
      (unavailable@CheckpointPartial {}, _) ->
        Left
          ( CheckpointRetirementCheckpointInventoryIncomplete
              PrimaryCheckpointCopy
              unavailable
          )
      (unavailable@CheckpointUnobservable {}, _) ->
        Left
          ( CheckpointRetirementCheckpointInventoryIncomplete
              PrimaryCheckpointCopy
              unavailable
          )
      (_, unavailable@CheckpointPartial {}) ->
        Left
          ( CheckpointRetirementCheckpointInventoryIncomplete
              BackupCheckpointCopy
              unavailable
          )
      (_, unavailable@CheckpointUnobservable {}) ->
        Left
          ( CheckpointRetirementCheckpointInventoryIncomplete
              BackupCheckpointCopy
              unavailable
          )

recordCheckpointRetirementAttempt
  :: CheckpointRetirementAuthorization
  -> CheckpointRetirementAttempt
  -> CheckpointRetirementOutcome
recordCheckpointRetirementAttempt authorization attempt =
  CheckpointRetirementOutcome
    { internalCheckpointRetirementOutcomeOperationId =
        checkpointRetirementOperationId authorization
    , internalCheckpointRetirementOutcomeStackKey =
        checkpointRetirementStackKey authorization
    , internalCheckpointRetirementOutcomeCoordinateDigest =
        checkpointRetirementCoordinateDigest authorization
    , internalCheckpointRetirementOutcomeScope =
        checkpointRetirementScope authorization
    , internalCheckpointRetirementOutcomeAttempt = attempt
    }

confirmCheckpointRetirement
  :: CheckpointRetirementAuthorization
  -> CheckpointRetirementObservation
  -> Either CheckpointRetirementError CheckpointRetirementEvidence
confirmCheckpointRetirement authorization observation = do
  let expectedOperation = checkpointRetirementOperationId authorization
      observedOperation = checkpointRetirementObservationOperationId observation
      expectedKey = checkpointRetirementStackKey authorization
      observedKey = checkpointRetirementObservationStackKey observation
      expectedScope = checkpointRetirementScope authorization
      observedScope = checkpointRetirementObservationScope observation
      primaryProvenance =
        checkpointRetirementObservationPrimaryProvenance observation
      backupProvenance =
        checkpointRetirementObservationBackupProvenance observation
      actualDisposition =
        checkpointRetirementObservationReferenceDisposition observation
  if observedOperation == expectedOperation
    then Right ()
    else
      Left
        ( CheckpointRetirementReadBackOperationMismatch
            expectedOperation
            observedOperation
        )
  if observedKey == expectedKey
    then Right ()
    else Left (CheckpointRetirementReadBackKeyMismatch expectedKey observedKey)
  if observedScope == expectedScope
    then Right ()
    else Left (CheckpointRetirementReadBackScopeMismatch expectedScope observedScope)
  requireProvenance
    PrimaryCheckpointCopy
    (internalCheckpointRetirementPrimaryProvenance authorization)
    primaryProvenance
  requireProvenance
    BackupCheckpointCopy
    (internalCheckpointRetirementBackupProvenance authorization)
    backupProvenance
  let expectedDisposition =
        case internalCheckpointRetirementReferenceExpectation authorization of
          CheckpointReferenceWasAlreadyRetired ->
            CheckpointReferenceAlreadyRetired
          CheckpointReferenceWasCurrent version ->
            CheckpointReferenceRetired version
  requireDisposition expectedDisposition actualDisposition
  Right
    CheckpointRetirementEvidence
      { internalCheckpointRetirementEvidenceOperationId = expectedOperation
      , internalCheckpointRetirementEvidenceStackKey = expectedKey
      , internalCheckpointRetirementEvidenceCoordinateDigest =
          checkpointRetirementCoordinateDigest authorization
      , internalCheckpointRetirementEvidenceScope = expectedScope
      , internalCheckpointRetirementEvidencePolicy = checkpointRetirementPolicy authorization
      }
 where
  requireDisposition expected actual
    | actual == expected = Right ()
    | otherwise = Left (CheckpointRetirementDispositionMismatch expected actual)

  requireProvenance copy expected actual
    | actual == expected = Right ()
    | otherwise = Left (CheckpointRetirementProvenanceMismatch copy expected actual)

validateStackTarget
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either CheckpointRestoreError RegisteredIdentity
validateStackTarget stackKey scope = do
  identity <- case lookupRegisteredIdentity stackKey of
    Nothing -> Left (CheckpointRestoreStackUnregistered stackKey)
    Just registered -> Right registered
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        ( CheckpointRestoreTargetIsNotStack
            stackKey
            (registeredIdentityKind identity)
        )
  if cleanupSurfaceAllows (evidenceCleanupSurface scope) identity
    then Right ()
    else
      Left
        ( CheckpointRestoreTargetNotAllowed
            stackKey
            (evidenceCleanupSurface scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else
      Left
        ( CheckpointRestoreScopeOperationInvalid
            (evidenceLifecycleOperation scope)
        )
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right identity
    else
      Left
        ( CheckpointRestoreScopeRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )

validatePair
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointPairObservation
  -> Either CheckpointRestoreError CheckpointPairObservation
validatePair stackKey scope pair =
  case mkCheckpointPairObservation
    stackKey
    scope
    (primaryCheckpointObservation pair)
    (backupCheckpointObservation pair) of
    Left err -> Left (CheckpointRestorePairInvalid err)
    Right validated -> Right validated
