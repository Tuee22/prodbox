{-# LANGUAGE OverloadedStrings #-}

-- | Pure, callback-free evidence carried between the durable stack-reader
-- commit/read-back nodes and the execution validator.  Constructors are
-- hidden so the graph interpreter has one place to bind repository outcomes
-- to the exact compiled operations.
module Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence
  ( AwsStackReaderCommitDisposition (..)
  , AwsStackReaderCommitOutcome
  , awsStackReaderCommitRunId
  , awsStackReaderCommitGraphDigest
  , awsStackReaderCommitOperationId
  , awsStackReaderCommitAttemptId
  , awsStackReaderCommitReconcileOperationId
  , awsStackReaderCommitKey
  , awsStackReaderCommitCoordinateDigest
  , awsStackReaderCommitScope
  , awsStackReaderCommitDisposition
  , mkAwsStackReaderCommitOutcome
  , AwsStackReaderReadBackEvidence
  , awsStackReaderReadBackRunId
  , awsStackReaderReadBackGraphDigest
  , awsStackReaderReadBackOperationId
  , awsStackReaderReadBackAttemptId
  , awsStackReaderReadBackCommitOperationId
  , awsStackReaderReadBackCommitAttemptId
  , awsStackReaderReadBackReconcileOperationId
  , awsStackReaderReadBackKey
  , awsStackReaderReadBackCoordinateDigest
  , awsStackReaderReadBackScope
  , mkAwsStackReaderReadBackEvidence
  , AwsStackReaderEvidenceError (..)
  )
where

import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  , cleanupRunIdText
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry

data AwsStackReaderCommitDisposition
  = AwsStackReaderCommitCreated
  | AwsStackReaderCommitExactReplay
  | AwsStackReaderCommitConflict
  | AwsStackReaderCommitResponseLost !ObservationFailure
  | AwsStackReaderCommitUnavailable !ObservationFailure
  deriving (Eq, Show)

data AwsStackReaderCommitOutcome = AwsStackReaderCommitOutcome
  { internalAwsStackReaderCommitRunId :: !CleanupRunId
  , internalAwsStackReaderCommitGraphDigest :: !CleanupDigest
  , internalAwsStackReaderCommitOperationId :: !CleanupOperationId
  , internalAwsStackReaderCommitAttemptId :: !CleanupAttemptId
  , internalAwsStackReaderCommitReconcileOperationId :: !CleanupOperationId
  , internalAwsStackReaderCommitKey :: !RegisteredResourceKey
  , internalAwsStackReaderCommitCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalAwsStackReaderCommitScope :: !ObservationEvidenceScope
  , internalAwsStackReaderCommitDisposition
      :: !AwsStackReaderCommitDisposition
  }
  deriving (Eq, Show)

awsStackReaderCommitRunId :: AwsStackReaderCommitOutcome -> CleanupRunId
awsStackReaderCommitRunId = internalAwsStackReaderCommitRunId

awsStackReaderCommitGraphDigest :: AwsStackReaderCommitOutcome -> CleanupDigest
awsStackReaderCommitGraphDigest = internalAwsStackReaderCommitGraphDigest

awsStackReaderCommitOperationId
  :: AwsStackReaderCommitOutcome -> CleanupOperationId
awsStackReaderCommitOperationId = internalAwsStackReaderCommitOperationId

awsStackReaderCommitAttemptId :: AwsStackReaderCommitOutcome -> CleanupAttemptId
awsStackReaderCommitAttemptId = internalAwsStackReaderCommitAttemptId

awsStackReaderCommitReconcileOperationId
  :: AwsStackReaderCommitOutcome -> CleanupOperationId
awsStackReaderCommitReconcileOperationId =
  internalAwsStackReaderCommitReconcileOperationId

awsStackReaderCommitKey
  :: AwsStackReaderCommitOutcome -> RegisteredResourceKey
awsStackReaderCommitKey = internalAwsStackReaderCommitKey

awsStackReaderCommitCoordinateDigest
  :: AwsStackReaderCommitOutcome -> ManagedResourceCoordinateDigest
awsStackReaderCommitCoordinateDigest =
  internalAwsStackReaderCommitCoordinateDigest

awsStackReaderCommitScope
  :: AwsStackReaderCommitOutcome -> ObservationEvidenceScope
awsStackReaderCommitScope = internalAwsStackReaderCommitScope

awsStackReaderCommitDisposition
  :: AwsStackReaderCommitOutcome -> AwsStackReaderCommitDisposition
awsStackReaderCommitDisposition = internalAwsStackReaderCommitDisposition

mkAwsStackReaderCommitOutcome
  :: CleanupRunId
  -> CleanupDigest
  -> CleanupOperationId
  -> CleanupAttemptId
  -> CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> AwsStackReaderCommitDisposition
  -> Either AwsStackReaderEvidenceError AwsStackReaderCommitOutcome
mkAwsStackReaderCommitOutcome runId graphDigest commitOperation commitAttempt reconcileOperation target scope disposition = do
  validateTarget runId target scope
  validateDistinctOperations commitOperation reconcileOperation
  Right
    AwsStackReaderCommitOutcome
      { internalAwsStackReaderCommitRunId = runId
      , internalAwsStackReaderCommitGraphDigest = graphDigest
      , internalAwsStackReaderCommitOperationId = commitOperation
      , internalAwsStackReaderCommitAttemptId = commitAttempt
      , internalAwsStackReaderCommitReconcileOperationId = reconcileOperation
      , internalAwsStackReaderCommitKey = registeredTargetKey target
      , internalAwsStackReaderCommitCoordinateDigest =
          registeredTargetCoordinateDigest target
      , internalAwsStackReaderCommitScope = scope
      , internalAwsStackReaderCommitDisposition = disposition
      }

data AwsStackReaderReadBackEvidence = AwsStackReaderReadBackEvidence
  { internalAwsStackReaderReadBackRunId :: !CleanupRunId
  , internalAwsStackReaderReadBackGraphDigest :: !CleanupDigest
  , internalAwsStackReaderReadBackOperationId :: !CleanupOperationId
  , internalAwsStackReaderReadBackAttemptId :: !CleanupAttemptId
  , internalAwsStackReaderReadBackCommitOperationId :: !CleanupOperationId
  , internalAwsStackReaderReadBackCommitAttemptId :: !CleanupAttemptId
  , internalAwsStackReaderReadBackReconcileOperationId :: !CleanupOperationId
  , internalAwsStackReaderReadBackKey :: !RegisteredResourceKey
  , internalAwsStackReaderReadBackCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalAwsStackReaderReadBackScope :: !ObservationEvidenceScope
  }
  deriving (Eq, Show)

awsStackReaderReadBackRunId
  :: AwsStackReaderReadBackEvidence -> CleanupRunId
awsStackReaderReadBackRunId = internalAwsStackReaderReadBackRunId

awsStackReaderReadBackGraphDigest
  :: AwsStackReaderReadBackEvidence -> CleanupDigest
awsStackReaderReadBackGraphDigest = internalAwsStackReaderReadBackGraphDigest

awsStackReaderReadBackOperationId
  :: AwsStackReaderReadBackEvidence -> CleanupOperationId
awsStackReaderReadBackOperationId = internalAwsStackReaderReadBackOperationId

awsStackReaderReadBackAttemptId
  :: AwsStackReaderReadBackEvidence -> CleanupAttemptId
awsStackReaderReadBackAttemptId = internalAwsStackReaderReadBackAttemptId

awsStackReaderReadBackCommitOperationId
  :: AwsStackReaderReadBackEvidence -> CleanupOperationId
awsStackReaderReadBackCommitOperationId =
  internalAwsStackReaderReadBackCommitOperationId

awsStackReaderReadBackCommitAttemptId
  :: AwsStackReaderReadBackEvidence -> CleanupAttemptId
awsStackReaderReadBackCommitAttemptId =
  internalAwsStackReaderReadBackCommitAttemptId

awsStackReaderReadBackReconcileOperationId
  :: AwsStackReaderReadBackEvidence -> CleanupOperationId
awsStackReaderReadBackReconcileOperationId =
  internalAwsStackReaderReadBackReconcileOperationId

awsStackReaderReadBackKey
  :: AwsStackReaderReadBackEvidence -> RegisteredResourceKey
awsStackReaderReadBackKey = internalAwsStackReaderReadBackKey

awsStackReaderReadBackCoordinateDigest
  :: AwsStackReaderReadBackEvidence -> ManagedResourceCoordinateDigest
awsStackReaderReadBackCoordinateDigest =
  internalAwsStackReaderReadBackCoordinateDigest

awsStackReaderReadBackScope
  :: AwsStackReaderReadBackEvidence -> ObservationEvidenceScope
awsStackReaderReadBackScope = internalAwsStackReaderReadBackScope

mkAwsStackReaderReadBackEvidence
  :: CleanupRunId
  -> CleanupDigest
  -> CleanupOperationId
  -> CleanupAttemptId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> Either AwsStackReaderEvidenceError AwsStackReaderReadBackEvidence
mkAwsStackReaderReadBackEvidence runId graphDigest readBackOperation readBackAttempt commitOperation commitAttempt reconcileOperation target scope = do
  validateTarget runId target scope
  validateDistinctOperations commitOperation reconcileOperation
  validateDistinctOperations readBackOperation commitOperation
  validateDistinctOperations readBackOperation reconcileOperation
  Right
    AwsStackReaderReadBackEvidence
      { internalAwsStackReaderReadBackRunId = runId
      , internalAwsStackReaderReadBackGraphDigest = graphDigest
      , internalAwsStackReaderReadBackOperationId = readBackOperation
      , internalAwsStackReaderReadBackAttemptId = readBackAttempt
      , internalAwsStackReaderReadBackCommitOperationId = commitOperation
      , internalAwsStackReaderReadBackCommitAttemptId = commitAttempt
      , internalAwsStackReaderReadBackReconcileOperationId = reconcileOperation
      , internalAwsStackReaderReadBackKey = registeredTargetKey target
      , internalAwsStackReaderReadBackCoordinateDigest =
          registeredTargetCoordinateDigest target
      , internalAwsStackReaderReadBackScope = scope
      }

data AwsStackReaderEvidenceError
  = AwsStackReaderEvidenceTargetUnregistered !RegisteredResourceKey
  | AwsStackReaderEvidenceTargetNotStack !RegisteredResourceKey !ResourceKind
  | AwsStackReaderEvidenceTargetKindMismatch
      !RegisteredResourceKey
      !ResourceKind
      !ResourceKind
  | AwsStackReaderEvidenceCoordinateMismatch
      !RegisteredResourceKey
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | AwsStackReaderEvidenceRunScopeMismatch
      !CleanupRunId
      !DurableObservationRunScope
  | AwsStackReaderEvidenceScopeOperationMismatch !LifecycleOperation
  | AwsStackReaderEvidenceOperationCollision !CleanupOperationId
  deriving (Eq, Show)

validateTarget
  :: CleanupRunId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> Either AwsStackReaderEvidenceError ()
validateTarget runId target scope = do
  identity <-
    maybe
      (Left (AwsStackReaderEvidenceTargetUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  if registeredTargetKind target == registeredIdentityKind identity
    then Right ()
    else
      Left
        ( AwsStackReaderEvidenceTargetKindMismatch
            key
            (registeredIdentityKind identity)
            (registeredTargetKind target)
        )
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        ( AwsStackReaderEvidenceTargetNotStack
            key
            (registeredIdentityKind identity)
        )
  if registeredTargetCoordinateDigest target
    == registeredIdentityCoordinateDigest identity
    then Right ()
    else
      Left
        ( AwsStackReaderEvidenceCoordinateMismatch
            key
            (registeredIdentityCoordinateDigest identity)
            (registeredTargetCoordinateDigest target)
        )
  if evidenceDurableRunScope scope
    == DurableObservationRunScope (cleanupRunIdText runId)
    then Right ()
    else
      Left
        ( AwsStackReaderEvidenceRunScopeMismatch
            runId
            (evidenceDurableRunScope scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else
      Left
        ( AwsStackReaderEvidenceScopeOperationMismatch
            (evidenceLifecycleOperation scope)
        )
 where
  key = registeredTargetKey target

validateDistinctOperations
  :: CleanupOperationId
  -> CleanupOperationId
  -> Either AwsStackReaderEvidenceError ()
validateDistinctOperations left right
  | left /= right = Right ()
  | otherwise = Left (AwsStackReaderEvidenceOperationCollision left)
