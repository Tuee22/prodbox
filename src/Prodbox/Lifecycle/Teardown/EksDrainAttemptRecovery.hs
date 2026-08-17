{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Crash-safe reconstruction of the exact EKS drain attempt consumed by the
-- independent Kubernetes read-back.
--
-- The authoritative cleanup aggregate deliberately retains only the fenced
-- predecessor attempt and its small terminal outcome.  This adapter combines
-- that opaque receipt with the independently recovered committed intent.  A
-- collapsed failure is conservatively reconstructed as unobservable; it can
-- never be upgraded into a definite mutation failure or success.
module Prodbox.Lifecycle.Teardown.EksDrainAttemptRecovery
  ( recoverEksDrainAttemptEvidence
  , EksDrainAttemptRecoveryError (..)
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupNodeOutcome (..)
  , CleanupOperationId
  , CleanupRunId
  )
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.Execution
  ( TeardownAttemptedPredecessor
  , TeardownExecutionContext
  , teardownAttemptedPredecessorAttemptId
  , teardownAttemptedPredecessorOperation
  , teardownAttemptedPredecessorOperationId
  , teardownAttemptedPredecessorOutcome
  , teardownExecutionAttemptedPredecessors
  , teardownExecutionGraphDigest
  , teardownExecutionObservationScope
  , teardownExecutionOperationId
  , teardownExecutionRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( ManagedResourceCoordinateDigest
  , ObservationEvidenceScope
  , ObservationFailure (..)
  , RegisteredResourceKey
  )
import Prodbox.Lifecycle.Teardown.Program
  ( RegisteredTargetBinding
  , TeardownOperation (DrainEksKubernetesResources)
  , registeredTargetCoordinateDigest
  , registeredTargetKey
  )

data EksDrainAttemptRecoveryError
  = EksDrainAttemptRecoveryPredecessorMissing
  | EksDrainAttemptRecoveryPredecessorAmbiguous !Int
  | EksDrainAttemptRecoveryPredecessorOperationInvalid
  | EksDrainAttemptRecoveryPredecessorTargetMismatch
      !RegisteredTargetBinding
      !RegisteredTargetBinding
  | EksDrainAttemptRecoveryPredecessorOperationIdMismatch
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainAttemptRecoveryReadBackOperationIdMismatch
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainAttemptRecoveryTargetKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | EksDrainAttemptRecoveryTargetCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | EksDrainAttemptRecoveryScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | EksDrainAttemptRecoveryRunMismatch !CleanupRunId !CleanupRunId
  | EksDrainAttemptRecoveryGraphMismatch !CleanupDigest !CleanupDigest
  | EksDrainAttemptRecoveryEffectOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainAttemptRecoveryIntentInvalid !EksDrainIntentError
  deriving (Eq, Show)

-- | Reconstruct the opaque attempt proof from an Authority-observed direct
-- predecessor.  The current read-back context supplies the expected
-- run/graph/scope, while @expectedEffectOperation@ comes from the compiled
-- operation bundle.  No caller-supplied attempt identity or outcome enters
-- this boundary.
recoverEksDrainAttemptEvidence
  :: RegisteredTargetBinding
  -> CleanupOperationId
  -> TeardownExecutionContext surface
  -> CommittedEksDrainIntent
  -> Either EksDrainAttemptRecoveryError EksDrainAttemptEvidence
recoverEksDrainAttemptEvidence expectedTarget expectedEffectOperation context committed = do
  predecessor <- onlyAttemptedPredecessor context
  observedTarget <- exactDrainPredecessorTarget predecessor
  requireEqual
    EksDrainAttemptRecoveryPredecessorTargetMismatch
    expectedTarget
    observedTarget
  requireEqual
    EksDrainAttemptRecoveryPredecessorOperationIdMismatch
    expectedEffectOperation
    (teardownAttemptedPredecessorOperationId predecessor)

  let intent = committedEksDrainIntent committed
      binding = eksDrainIntentBinding intent
  requireEqual
    EksDrainAttemptRecoveryReadBackOperationIdMismatch
    (eksDrainBindingDrainReadBackOperationId binding)
    (teardownExecutionOperationId context)
  requireEqual
    EksDrainAttemptRecoveryTargetKeyMismatch
    (registeredTargetKey expectedTarget)
    (eksDrainIntentResourceKey intent)
  requireEqual
    EksDrainAttemptRecoveryTargetCoordinateMismatch
    (registeredTargetCoordinateDigest expectedTarget)
    (eksDrainIntentCoordinateDigest intent)
  requireEqual
    EksDrainAttemptRecoveryRunMismatch
    (teardownExecutionRunId context)
    (eksDrainBindingRunId binding)
  requireEqual
    EksDrainAttemptRecoveryScopeMismatch
    (teardownExecutionObservationScope context)
    (eksDrainBindingScope binding)
  requireEqual
    EksDrainAttemptRecoveryGraphMismatch
    (teardownExecutionGraphDigest context)
    (eksDrainBindingGraphDigest binding)
  requireEqual
    EksDrainAttemptRecoveryEffectOperationMismatch
    expectedEffectOperation
    (eksDrainBindingEffectOperationId binding)

  let attempt =
        beginEksDrainAttempt
          committed
          (teardownAttemptedPredecessorAttemptId predecessor)
      recoveredOutcome =
        conservativeOutcome
          (eksDrainIntentTarget intent)
          (teardownAttemptedPredecessorOutcome predecessor)
  either
    (Left . EksDrainAttemptRecoveryIntentInvalid)
    Right
    ( recordEksDrainAttempt
        attempt
        (eksDrainAttemptObservationFor attempt recoveredOutcome)
    )

onlyAttemptedPredecessor
  :: TeardownExecutionContext surface
  -> Either
       EksDrainAttemptRecoveryError
       (TeardownAttemptedPredecessor surface)
onlyAttemptedPredecessor context =
  case teardownExecutionAttemptedPredecessors context of
    [] -> Left EksDrainAttemptRecoveryPredecessorMissing
    [predecessor] -> Right predecessor
    predecessors ->
      Left
        (EksDrainAttemptRecoveryPredecessorAmbiguous (length predecessors))

exactDrainPredecessorTarget
  :: TeardownAttemptedPredecessor surface
  -> Either EksDrainAttemptRecoveryError RegisteredTargetBinding
exactDrainPredecessorTarget predecessor =
  case teardownAttemptedPredecessorOperation predecessor of
    DrainEksKubernetesResources target -> Right target
    _ -> Left EksDrainAttemptRecoveryPredecessorOperationInvalid

conservativeOutcome
  :: EksDrainIntentTarget -> CleanupNodeOutcome -> EksDrainAttemptOutcome
conservativeOutcome target durableOutcome = case target of
  EksDrainNoKubernetesTarget {} -> EksDrainSkippedNoKubernetesTarget
  EksDrainExactKubernetesTarget {} -> case durableOutcome of
    CleanupNodeSucceeded -> EksDrainMutationApplied
    CleanupNodeEffectUnconfirmed _ ->
      EksDrainMutationUnobservable
        (ObservationFailure effectUnconfirmedDetail)
    CleanupNodeFailed _ ->
      EksDrainMutationUnobservable
        (ObservationFailure failedAttemptDetail)

effectUnconfirmedDetail :: Text
effectUnconfirmedDetail =
  "durable EKS drain attempt completed with an unconfirmed effect"

failedAttemptDetail :: Text
failedAttemptDetail =
  "durable EKS drain attempt failed without an exact retained mutation result"

requireEqual
  :: (Eq value)
  => (value -> value -> EksDrainAttemptRecoveryError)
  -> value
  -> value
  -> Either EksDrainAttemptRecoveryError ()
requireEqual mismatch expected actual =
  if expected == actual
    then Right ()
    else Left (mismatch expected actual)
