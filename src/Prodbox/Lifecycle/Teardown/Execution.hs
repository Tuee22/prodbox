{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Total execution boundary for compiled lifecycle cleanup programs.  The
-- effect implementation receives only a closed operation plus its sealed
-- run\/graph\/scope context, and validates every proof binding before lowering
-- the result to the durable cleanup journal's small outcome algebra.
--
-- Sprint 4.94: a result of the wrong kind is no longer rejected, because it is
-- no longer constructible.  'TeardownOperation' and 'TeardownNodeResult' share
-- a result index, so an interpreter handed an operation can return only that
-- operation's answer or a refusal.  What the driver still checks — and what a
-- result index deliberately does not prove — is that the answer belongs to this
-- attempt and was produced under the expected observation scope.
module Prodbox.Lifecycle.Teardown.Execution
  ( TeardownMutationResult (..)
  , DurableReceiptKind (..)
  , DurableReceiptObservationResult (..)
  , DurableReceiptObservation (..)
  , LocalFoundationObservationResult (..)
  , LocalFoundationObservation (..)
  , LocalDataDispositionObservationResult (..)
  , LocalDataDispositionObservation (..)
  , TeardownNodeResult (..)
  , TeardownSucceededPredecessor
  , teardownSucceededPredecessorOperationId
  , teardownSucceededPredecessorAttemptId
  , teardownSucceededPredecessorOperation
  , TeardownAttemptedPredecessor
  , teardownAttemptedPredecessorOperationId
  , teardownAttemptedPredecessorAttemptId
  , teardownAttemptedPredecessorOutcome
  , teardownAttemptedPredecessorOperation
  , TeardownTerminalPredecessorResult (..)
  , TeardownTerminalPredecessor
  , teardownTerminalPredecessorOperationId
  , teardownTerminalPredecessorOperation
  , teardownTerminalPredecessorResult
  , TeardownExecutionContext
  , teardownExecutionOperationId
  , teardownExecutionAttemptId
  , teardownExecutionRunId
  , teardownExecutionDescriptorDigest
  , teardownExecutionGraphDigest
  , teardownExecutionNodeId
  , teardownExecutionIdentity
  , teardownExecutionObservationScope
  , teardownExecutionAttemptOperationIds
  , teardownExecutionOperationIdFor
  , teardownExecutionSuccessfulPredecessors
  , teardownExecutionAttemptedPredecessors
  , teardownExecutionTerminalPredecessors
  , LifecycleTeardownEffects (..)
  , runCompiledTeardownNode
  , runCompiledTeardownNodeWithAttempt
  , runCompiledTeardownNodeWithContext
  , runCompiledTeardownNodeWithDescriptorContext
  )
where

import Data.List (find)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDependency (..)
  , CleanupDependencyKind (..)
  , CleanupDigest
  , CleanupNodeId
  , CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupOperationId
  , CleanupRunId
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeDependencies
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupNodeOperationId
  , mkCleanupAttemptId
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , CleanupTerminalDependencyResult (..)
  , cleanupDependencyReceiptAttemptId
  , cleanupDependencyReceiptKind
  , cleanupDependencyReceiptNodeId
  , cleanupDependencyReceiptOperationId
  , cleanupDependencyReceiptOutcome
  , cleanupNodeExecutionAttemptId
  , cleanupNodeExecutionDependencyReceipts
  , cleanupNodeExecutionGraphDigest
  , cleanupNodeExecutionNodeId
  , cleanupNodeExecutionRunId
  , cleanupNodeExecutionTerminalDependencyReceipts
  , cleanupTerminalDependencyReceiptNodeId
  , cleanupTerminalDependencyReceiptOperationId
  , cleanupTerminalDependencyReceiptResult
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( CredentialRevocationRefusal
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( CredentialTarget (LifecycleProviderTarget)
  )
import Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence
import Prodbox.Lifecycle.Teardown.Checkpoint
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
  ( TeardownExecutionIdentity
  )
import Prodbox.Lifecycle.Teardown.ExecutionIdentity.Internal
  ( mkTeardownExecutionIdentity
  )
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneFinalDisposition (..)
  , RecoveryPlaneFinalEvidence
  , RecoveryPlaneIdentity
  , RecoveryPlaneInitialDisposition (..)
  , RecoveryPlaneInitialReadBack
  , recoveryPlaneFinalDisposition
  , recoveryPlaneFinalDispositionAttemptId
  , recoveryPlaneFinalEstablishAttemptId
  , recoveryPlaneFinalFailures
  , recoveryPlaneFinalIdentity
  , recoveryPlaneFinalInitialReadBackAttemptId
  , recoveryPlaneIdentityDescriptorDigest
  , recoveryPlaneIdentityDispositionOperationId
  , recoveryPlaneIdentityEstablishOperationId
  , recoveryPlaneIdentityGraphDigest
  , recoveryPlaneIdentityObservationScope
  , recoveryPlaneIdentityReadBackOperationId
  , recoveryPlaneIdentityRunId
  , recoveryPlaneIdentitySurface
  , recoveryPlaneInitialDisposition
  , recoveryPlaneInitialEstablishAttemptId
  , recoveryPlaneInitialFailures
  , recoveryPlaneInitialIdentity
  , recoveryPlaneInitialReadBackAttemptId
  , renderRecoveryPlaneComponentFailures
  )
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Lifecycle.Teardown.ScopeCodec (scopeForTerminalAudit)

data TeardownMutationResult
  = TeardownMutationApplied
  | TeardownMutationResponseLost !Text
  | TeardownMutationRefused !Text
  deriving (Eq, Show)

data DurableReceiptKind
  = CascadePreUninstallReportReceipt
  | CascadeCompletionReceipt
  | LocalOnlyCompletionReceipt
  | OrdinarySurfaceReportReceipt
  | ExternalDecommissionReadyReceipt
  | DecommissionTerminalReceipt
  deriving (Eq, Show)

data DurableReceiptObservationResult
  = DurableReceiptObserved
  | DurableReceiptMissing
  | DurableReceiptUnobservable !ObservationFailure
  deriving (Eq, Show)

data DurableReceiptObservation = DurableReceiptObservation
  { durableReceiptObservationKind :: !DurableReceiptKind
  , durableReceiptObservationScope :: !ObservationEvidenceScope
  , durableReceiptObservationGraphDigest :: !CleanupDigest
  , durableReceiptObservationResult :: !DurableReceiptObservationResult
  }
  deriving (Eq, Show)

data LocalFoundationObservationResult
  = LocalFoundationAbsent !AbsenceEvidence
  | LocalFoundationPresent
  | LocalFoundationUnobservable !ObservationFailure
  deriving (Eq, Show)

data LocalFoundationObservation = LocalFoundationObservation
  { localFoundationObservationScope :: !ObservationEvidenceScope
  , localFoundationObservationResult :: !LocalFoundationObservationResult
  }
  deriving (Eq, Show)

data LocalDataDispositionObservationResult
  = LocalDataDispositionConfirmed
  | LocalDataDispositionNotApplied
  | LocalDataDispositionUnobservable !ObservationFailure
  deriving (Eq, Show)

data LocalDataDispositionObservation = LocalDataDispositionObservation
  { localDataDispositionObservationScope :: !ObservationEvidenceScope
  , localDataDispositionObservationResult
      :: !LocalDataDispositionObservationResult
  }
  deriving (Eq, Show)

-- | Sprint 4.85: what re-observing the operational credential's revocation
-- found.
--
-- The refusal arm carries the canonical decision's own refusal rather than a
-- rendered string, so this surface and the Admin-worker boundary agree on why
-- a revocation was not read back.
data OperationalCredentialRevocationResult
  = OperationalCredentialRevocationConfirmed
  | OperationalCredentialRevocationRefused !CredentialRevocationRefusal
  | OperationalCredentialRevocationUnobservable !ObservationFailure
  deriving (Eq, Show)

data OperationalCredentialRevocationObservation
  = OperationalCredentialRevocationObservation
  { operationalCredentialRevocationObservationScope :: !ObservationEvidenceScope
  , operationalCredentialRevocationObservationTarget :: !CredentialTarget
  , operationalCredentialRevocationObservationResult
      :: !OperationalCredentialRevocationResult
  }
  deriving (Eq, Show)

-- | Sprint 4.94: the result of one lifecycle teardown operation, indexed by the
-- kind of answer the operation asks for.
--
-- 'TeardownNodeRefused' stays index-polymorphic, because every interpreter must
-- be able to decline any operation and a refusal carries its own typed cause.
-- Every other constructor is pinned, so an interpreter handed an operation can
-- return only that operation's result. The twenty catch-all arms the executor
-- used to carry — one per result constructor, all collapsing into
-- /\"lifecycle interpreter returned the wrong result kind\"/ — guard states that
-- are no longer representable, and are gone with the string.
data TeardownNodeResult (surface :: CleanupSurface) (result :: TeardownResultKind) where
  TeardownNodeRefused :: !Text -> TeardownNodeResult surface result
  TeardownMutationAttempt
    :: !TeardownMutationResult
    -> TeardownNodeResult surface 'MutationAttemptResult
  TeardownRegisteredTargetReconcile
    :: !RegisteredTargetReconcileResult
    -> TeardownNodeResult surface 'RegisteredTargetReconcileResult
  TeardownExactResourceObservation
    :: !ExactResourceObservation
    -> TeardownNodeResult surface 'ExactResourceObservationResult
  TeardownCheckpointPairObservation
    :: !CheckpointPairObservation
    -> TeardownNodeResult surface 'CheckpointPairObservationResult
  TeardownCheckpointRestore
    :: !CheckpointRestoreOutcome
    -> TeardownNodeResult surface 'CheckpointRestoreResult
  TeardownCheckpointRecoveryReadBack
    :: !CheckpointRecoveryReadBackEvidence
    -> TeardownNodeResult surface 'CheckpointRecoveryReadBackResult
  TeardownAwsStackReaderCommit
    :: !AwsStackReaderCommitOutcome
    -> TeardownNodeResult surface 'AwsStackReaderCommitResult
  TeardownAwsStackReaderReadBack
    :: !AwsStackReaderReadBackEvidence
    -> TeardownNodeResult surface 'AwsStackReaderReadBackResult
  TeardownCheckpointRetirement
    :: !CheckpointRetirementOutcome
    -> TeardownNodeResult surface 'CheckpointRetirementResult
  TeardownCheckpointRetirementReadBack
    :: !CheckpointRetirementEvidence
    -> TeardownNodeResult surface 'CheckpointRetirementReadBackResult
  TeardownEksDrainIntentReadBack
    :: !(Either EksDrainIntentError CommittedEksDrainIntent)
    -> TeardownNodeResult surface 'EksDrainIntentReadBackResult
  TeardownEksDrainAttempt
    :: !(Either EksDrainIntentError EksDrainAttemptEvidence)
    -> TeardownNodeResult surface 'EksDrainAttemptResult
  TeardownEksDrainTargetReadBack
    :: !(Either EksDrainIntentError EksDrainTargetsAbsentEvidence)
    -> TeardownNodeResult surface 'EksDrainTargetReadBackResult
  TeardownRecoveryPlaneInitialReadBack
    :: !(RecoveryPlaneInitialReadBack surface)
    -> TeardownNodeResult surface 'RecoveryPlaneInitialReadBackResult
  TeardownRecoveryPlaneFinalEvidence
    :: !(RecoveryPlaneFinalEvidence surface)
    -> TeardownNodeResult surface 'RecoveryPlaneFinalEvidenceResult
  TeardownTerminalAuditObservation
    :: !(TerminalAuditObservation surface)
    -> TeardownNodeResult surface 'TerminalAuditObservationResult
  TeardownDurableReceiptObservation
    :: !DurableReceiptObservation
    -> TeardownNodeResult surface 'DurableReceiptObservationResult
  TeardownLocalFoundationObservation
    :: !LocalFoundationObservation
    -> TeardownNodeResult surface 'LocalFoundationObservationResult
  TeardownLocalDataDispositionObservation
    :: !LocalDataDispositionObservation
    -> TeardownNodeResult surface 'LocalDataDispositionObservationResult
  TeardownOperationalCredentialRevocationObservation
    :: !OperationalCredentialRevocationObservation
    -> TeardownNodeResult surface 'OperationalCredentialRevocationObservationResult

data TeardownSucceededPredecessor surface = TeardownSucceededPredecessor
  { teardownSucceededPredecessorOperationId :: !CleanupOperationId
  , teardownSucceededPredecessorAttemptId :: !CleanupAttemptId
  , teardownSucceededPredecessorOperation :: !(SomeTeardownOperation surface)
  }
  deriving (Eq, Show)

-- | Direct 'RequiresAttempt' predecessor retained from the authoritative
-- CleanupRun snapshot.  Unlike the older operation-id projection, this
-- carries the exact fenced attempt and its terminal outcome so a response-
-- loss read-back can address the attempt that actually ran.
data TeardownAttemptedPredecessor surface = TeardownAttemptedPredecessor
  { teardownAttemptedPredecessorOperationId :: !CleanupOperationId
  , teardownAttemptedPredecessorAttemptId :: !CleanupAttemptId
  , teardownAttemptedPredecessorOutcome :: !CleanupNodeOutcome
  , teardownAttemptedPredecessorOperation :: !(SomeTeardownOperation surface)
  }
  deriving (Eq, Show)

-- | Exact terminal state retained for a direct
-- 'CleanupRequiresTerminal' predecessor.  A blocked predecessor is kept as
-- blocked and never receives a fabricated attempt identity.
data TeardownTerminalPredecessorResult
  = TeardownTerminalPredecessorCompleted !CleanupAttemptId !CleanupNodeOutcome
  | TeardownTerminalPredecessorBlocked ![CleanupNodeId]
  deriving (Eq, Show)

data TeardownTerminalPredecessor surface = TeardownTerminalPredecessor
  { teardownTerminalPredecessorOperationId :: !CleanupOperationId
  , teardownTerminalPredecessorOperation :: !(SomeTeardownOperation surface)
  , teardownTerminalPredecessorResult :: !TeardownTerminalPredecessorResult
  }
  deriving (Eq, Show)

data TeardownExecutionContext surface = TeardownExecutionContext
  { internalTeardownExecutionOperationId :: !CleanupOperationId
  , internalTeardownExecutionAttemptId :: !CleanupAttemptId
  , internalTeardownExecutionRunId :: !CleanupRunId
  , internalTeardownExecutionDescriptorDigest :: !(Maybe CleanupDigest)
  , internalTeardownExecutionGraphDigest :: !CleanupDigest
  , internalTeardownExecutionNodeId :: !CleanupNodeId
  , internalTeardownExecutionObservationScope :: !ObservationEvidenceScope
  , internalTeardownExecutionAttemptOperationIds :: ![CleanupOperationId]
  , internalTeardownExecutionOperationCatalog
      :: ![(SomeTeardownOperation surface, CleanupOperationId)]
  , internalTeardownExecutionSuccessfulPredecessors
      :: ![TeardownSucceededPredecessor surface]
  , internalTeardownExecutionAttemptedPredecessors
      :: ![TeardownAttemptedPredecessor surface]
  , internalTeardownExecutionTerminalPredecessors
      :: ![TeardownTerminalPredecessor surface]
  }

teardownExecutionOperationId
  :: TeardownExecutionContext surface -> CleanupOperationId
teardownExecutionOperationId = internalTeardownExecutionOperationId

teardownExecutionAttemptId
  :: TeardownExecutionContext surface -> CleanupAttemptId
teardownExecutionAttemptId = internalTeardownExecutionAttemptId

teardownExecutionRunId :: TeardownExecutionContext surface -> CleanupRunId
teardownExecutionRunId = internalTeardownExecutionRunId

-- | Descriptor identity is present only for execution admitted through the
-- opaque descriptor-bound runner. Compatibility/raw entrypoints deliberately
-- carry no value and therefore cannot validate recovery-plane evidence.
teardownExecutionDescriptorDigest
  :: TeardownExecutionContext surface -> Maybe CleanupDigest
teardownExecutionDescriptorDigest = internalTeardownExecutionDescriptorDigest

teardownExecutionGraphDigest
  :: TeardownExecutionContext surface -> CleanupDigest
teardownExecutionGraphDigest = internalTeardownExecutionGraphDigest

teardownExecutionNodeId :: TeardownExecutionContext surface -> CleanupNodeId
teardownExecutionNodeId = internalTeardownExecutionNodeId

teardownExecutionIdentity
  :: TeardownExecutionContext surface -> TeardownExecutionIdentity
teardownExecutionIdentity context =
  mkTeardownExecutionIdentity
    (teardownExecutionRunId context)
    (teardownExecutionGraphDigest context)
    (teardownExecutionNodeId context)
    (teardownExecutionOperationId context)
    (teardownExecutionAttemptId context)

teardownExecutionObservationScope
  :: TeardownExecutionContext surface -> ObservationEvidenceScope
teardownExecutionObservationScope = internalTeardownExecutionObservationScope

-- | Stable operation references of this node's 'RequiresAttempt'
-- predecessors.  Read-back interpreters consume these durable references;
-- they never need the predecessor call's return value.
teardownExecutionAttemptOperationIds
  :: TeardownExecutionContext surface -> [CleanupOperationId]
teardownExecutionAttemptOperationIds =
  internalTeardownExecutionAttemptOperationIds

-- | Look up another operation in this exact compiled run.  The context
-- constructor is private, so an interpreter cannot substitute a caller-made
-- operation identity or a catalog from another graph.  Multi-node protocols
-- (notably the EKS drain intent/effect/read-back chain) use this projection to
-- recover their stable binding after process loss without a side map.
teardownExecutionOperationIdFor
  :: TeardownExecutionContext surface
  -> TeardownOperation surface result
  -> Maybe CleanupOperationId
teardownExecutionOperationIdFor context wanted =
  snd
    <$> find
      ((== SomeTeardownOperation wanted) . fst)
      (internalTeardownExecutionOperationCatalog context)

-- | Direct 'RequiresSuccess' predecessors whose success outcome was read from
-- the durable CleanupRun aggregate before this attempt was admitted.
teardownExecutionSuccessfulPredecessors
  :: TeardownExecutionContext surface
  -> [TeardownSucceededPredecessor surface]
teardownExecutionSuccessfulPredecessors =
  internalTeardownExecutionSuccessfulPredecessors

teardownExecutionAttemptedPredecessors
  :: TeardownExecutionContext surface
  -> [TeardownAttemptedPredecessor surface]
teardownExecutionAttemptedPredecessors =
  internalTeardownExecutionAttemptedPredecessors

teardownExecutionTerminalPredecessors
  :: TeardownExecutionContext surface
  -> [TeardownTerminalPredecessor surface]
teardownExecutionTerminalPredecessors =
  internalTeardownExecutionTerminalPredecessors

class (Monad m) => LifecycleTeardownEffects m where
  executeLifecycleTeardownOperation
    :: TeardownExecutionContext surface
    -> TeardownOperation surface result
    -> m (TeardownNodeResult surface result)

runCompiledTeardownNode
  :: (LifecycleTeardownEffects m)
  => CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> m CleanupNodeOutcome
runCompiledTeardownNode compiled suppliedPlan =
  case mkCleanupAttemptId (cleanupNodeIdText (cleanupNodeId suppliedPlan) <> ":direct") of
    Left _ -> pure (CleanupNodeFailed "cleanup node cannot derive its direct attempt identity")
    Right attempt -> runCompiledTeardownNodeWithAttempt compiled attempt suppliedPlan

-- | Production entrypoint.  The durable runner supplies the exact fenced
-- attempt that it committed before invoking the effect.  Ephemeral external
-- projections and response-loss recovery must bind to this value rather than
-- wall-clock freshness or a process-local nonce.
runCompiledTeardownNodeWithAttempt
  :: (LifecycleTeardownEffects m)
  => CompiledDesiredAbsenceProgram surface
  -> CleanupAttemptId
  -> CleanupNodePlan
  -> m CleanupNodeOutcome
runCompiledTeardownNodeWithAttempt compiled attempt suppliedPlan =
  runCompiledTeardownNodeWithPredecessors
    compiled
    Nothing
    attempt
    []
    []
    []
    suppliedPlan

-- | Production admission from the durable runner.  Unlike the compatibility
-- entrypoints above, this preserves exact, authority-observed successful
-- predecessor receipts.  Proof-gated effects must consume only this path.
runCompiledTeardownNodeWithContext
  :: (LifecycleTeardownEffects m)
  => CompiledDesiredAbsenceProgram surface
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> m CleanupNodeOutcome
runCompiledTeardownNodeWithContext compiled durableContext suppliedPlan =
  runCompiledTeardownNodeWithMaybeDescriptorContext
    Nothing
    compiled
    durableContext
    suppliedPlan

-- | Descriptor-bound production admission. Recovery-plane proof results are
-- accepted only through this entrypoint: the opaque handle contributes the
-- committed descriptor digest after its run and graph are checked against
-- the exact recompiled program. All compatibility/raw entrypoints carry no
-- descriptor identity and fail closed for recovery proof arms.
runCompiledTeardownNodeWithDescriptorContext
  :: (LifecycleTeardownEffects m)
  => DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> m CleanupNodeOutcome
runCompiledTeardownNodeWithDescriptorContext bound compiled durableContext suppliedPlan
  | descriptorBoundCleanupRunId bound /= compiledDesiredAbsenceRunId compiled =
      pure (CleanupNodeFailed "descriptor-bound cleanup run identity does not match the compiled program")
  | descriptorBoundCleanupRunGraphDigest bound /= cleanupGraphDigest graph =
      pure (CleanupNodeFailed "descriptor-bound cleanup graph digest does not match the compiled program")
  | descriptorBoundCleanupRunGraph bound /= graph =
      pure (CleanupNodeFailed "descriptor-bound cleanup graph does not match the compiled program")
  | otherwise =
      runCompiledTeardownNodeWithMaybeDescriptorContext
        (Just (descriptorBoundCleanupRunDescriptorDigest bound))
        compiled
        durableContext
        suppliedPlan
 where
  graph = compiledDesiredAbsenceGraph compiled

runCompiledTeardownNodeWithMaybeDescriptorContext
  :: (LifecycleTeardownEffects m)
  => Maybe CleanupDigest
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> m CleanupNodeOutcome
runCompiledTeardownNodeWithMaybeDescriptorContext descriptorDigest compiled durableContext suppliedPlan =
  case durablePredecessors of
    Left detail -> pure (CleanupNodeFailed detail)
    Right (successfulPredecessors, attemptedPredecessors, terminalPredecessors) ->
      runCompiledTeardownNodeWithPredecessors
        compiled
        descriptorDigest
        (cleanupNodeExecutionAttemptId durableContext)
        successfulPredecessors
        attemptedPredecessors
        terminalPredecessors
        suppliedPlan
 where
  graph = compiledDesiredAbsenceGraph compiled
  durablePredecessors = do
    if cleanupNodeExecutionRunId durableContext == compiledDesiredAbsenceRunId compiled
      then Right ()
      else Left "cleanup execution context run does not match the compiled program"
    if cleanupNodeExecutionGraphDigest durableContext == cleanupGraphDigest graph
      then Right ()
      else Left "cleanup execution context graph does not match the compiled program"
    if cleanupNodeExecutionNodeId durableContext == cleanupNodeId suppliedPlan
      then Right ()
      else Left "cleanup execution context node does not match the supplied plan"
    if length receipts + length terminalReceipts
      == length (cleanupNodeDependencies suppliedPlan)
      then Right ()
      else Left "cleanup execution context does not contain every direct dependency receipt"
    mapM_ validateReceipt receipts
    mapM_ validateTerminalReceipt terminalReceipts
    let successfulPredecessors =
          [ TeardownSucceededPredecessor
              { teardownSucceededPredecessorOperationId =
                  cleanupDependencyReceiptOperationId receipt
              , teardownSucceededPredecessorAttemptId =
                  cleanupDependencyReceiptAttemptId receipt
              , teardownSucceededPredecessorOperation = operation
              }
          | receipt <- receipts
          , cleanupDependencyReceiptKind receipt == CleanupRequiresSuccess
          , cleanupDependencyReceiptOutcome receipt == CleanupNodeSucceeded
          , Just operation <-
              [ compiledOperationForNode
                  (cleanupDependencyReceiptNodeId receipt)
                  compiled
              ]
          ]
        attemptedPredecessors =
          [ TeardownAttemptedPredecessor
              { teardownAttemptedPredecessorOperationId =
                  cleanupDependencyReceiptOperationId receipt
              , teardownAttemptedPredecessorAttemptId =
                  cleanupDependencyReceiptAttemptId receipt
              , teardownAttemptedPredecessorOutcome =
                  cleanupDependencyReceiptOutcome receipt
              , teardownAttemptedPredecessorOperation = operation
              }
          | receipt <- receipts
          , cleanupDependencyReceiptKind receipt == CleanupRequiresAttempt
          , Just operation <-
              [ compiledOperationForNode
                  (cleanupDependencyReceiptNodeId receipt)
                  compiled
              ]
          ]
        terminalPredecessors =
          [ TeardownTerminalPredecessor
              { teardownTerminalPredecessorOperationId =
                  cleanupTerminalDependencyReceiptOperationId receipt
              , teardownTerminalPredecessorOperation = operation
              , teardownTerminalPredecessorResult =
                  projectTerminalResult
                    (cleanupTerminalDependencyReceiptResult receipt)
              }
          | receipt <- terminalReceipts
          , Just operation <-
              [ compiledOperationForNode
                  (cleanupTerminalDependencyReceiptNodeId receipt)
                  compiled
              ]
          ]
    pure (successfulPredecessors, attemptedPredecessors, terminalPredecessors)
  receipts = cleanupNodeExecutionDependencyReceipts durableContext
  terminalReceipts =
    cleanupNodeExecutionTerminalDependencyReceipts durableContext
  projectTerminalResult result = case result of
    CleanupTerminalDependencyCompleted attempt outcome ->
      TeardownTerminalPredecessorCompleted attempt outcome
    CleanupTerminalDependencyBlocked blockers ->
      TeardownTerminalPredecessorBlocked blockers
  validateReceipt receipt = do
    dependency <-
      maybe
        (Left "cleanup execution receipt is not a direct dependency of the supplied plan")
        Right
        ( find
            ( (== cleanupDependencyReceiptNodeId receipt)
                . cleanupDependencyNode
            )
            (cleanupNodeDependencies suppliedPlan)
        )
    if cleanupDependencyKind dependency == cleanupDependencyReceiptKind receipt
      then Right ()
      else Left "cleanup execution receipt has the wrong dependency kind"
    if cleanupDependencyReceiptKind receipt == CleanupRequiresTerminal
      then Left "cleanup terminal dependency used an attempted receipt"
      else Right ()
    dependencyPlan <-
      maybe
        (Left "cleanup execution receipt node is missing from the compiled graph")
        Right
        ( find
            ((== cleanupDependencyReceiptNodeId receipt) . cleanupNodeId)
            (cleanupGraphNodes graph)
        )
    if cleanupNodeOperationId dependencyPlan
      == cleanupDependencyReceiptOperationId receipt
      then Right ()
      else Left "cleanup execution receipt has the wrong operation identity"
    case cleanupDependencyReceiptOutcome receipt of
      CleanupNodeSucceeded -> Right ()
      CleanupNodeFailed _
        | cleanupDependencyReceiptKind receipt == CleanupRequiresAttempt -> Right ()
      CleanupNodeEffectUnconfirmed _
        | cleanupDependencyReceiptKind receipt == CleanupRequiresAttempt -> Right ()
      _ -> Left "cleanup execution receipt outcome does not satisfy its dependency"
    case compiledOperationForNode (cleanupDependencyReceiptNodeId receipt) compiled of
      Nothing -> Left "cleanup execution receipt has no closed lifecycle operation"
      Just _ -> Right ()

  validateTerminalReceipt receipt = do
    dependency <-
      maybe
        (Left "cleanup terminal receipt is not a direct dependency of the supplied plan")
        Right
        ( find
            ( (== cleanupTerminalDependencyReceiptNodeId receipt)
                . cleanupDependencyNode
            )
            (cleanupNodeDependencies suppliedPlan)
        )
    if cleanupDependencyKind dependency == CleanupRequiresTerminal
      then Right ()
      else Left "cleanup terminal receipt has the wrong dependency kind"
    dependencyPlan <-
      maybe
        (Left "cleanup terminal receipt node is missing from the compiled graph")
        Right
        ( find
            ( (== cleanupTerminalDependencyReceiptNodeId receipt)
                . cleanupNodeId
            )
            (cleanupGraphNodes graph)
        )
    if cleanupNodeOperationId dependencyPlan
      == cleanupTerminalDependencyReceiptOperationId receipt
      then Right ()
      else Left "cleanup terminal receipt has the wrong operation identity"
    case cleanupTerminalDependencyReceiptResult receipt of
      CleanupTerminalDependencyCompleted _ _ -> Right ()
      CleanupTerminalDependencyBlocked [] ->
        Left "cleanup terminal receipt has an empty blocked set"
      CleanupTerminalDependencyBlocked blockers
        | all (`elem` map cleanupNodeId (cleanupGraphNodes graph)) blockers -> Right ()
        | otherwise -> Left "cleanup terminal receipt names an unknown blocker"
    case compiledOperationForNode
      (cleanupTerminalDependencyReceiptNodeId receipt)
      compiled of
      Nothing -> Left "cleanup terminal receipt has no closed lifecycle operation"
      Just _ -> Right ()

runCompiledTeardownNodeWithPredecessors
  :: (LifecycleTeardownEffects m)
  => CompiledDesiredAbsenceProgram surface
  -> Maybe CleanupDigest
  -> CleanupAttemptId
  -> [TeardownSucceededPredecessor surface]
  -> [TeardownAttemptedPredecessor surface]
  -> [TeardownTerminalPredecessor surface]
  -> CleanupNodePlan
  -> m CleanupNodeOutcome
runCompiledTeardownNodeWithPredecessors compiled descriptorDigest attempt succeededPredecessors attemptedPredecessors terminalPredecessors suppliedPlan =
  case matchingPlan of
    Nothing -> pure (CleanupNodeFailed "cleanup node is not in the compiled lifecycle graph")
    Just expectedPlan
      | expectedPlan /= suppliedPlan ->
          pure (CleanupNodeFailed "cleanup node differs from its compiled lifecycle descriptor")
      | otherwise -> case compiledOperationForNode (cleanupNodeId suppliedPlan) compiled of
          Nothing ->
            pure (CleanupNodeFailed "cleanup node has no closed lifecycle operation")
          -- Sprint 4.94: unpacking the existential here is what gives the
          -- operation and its result one shared result index, so the executor
          -- can no longer hand a checker the wrong kind of answer.
          Just (SomeTeardownOperation operation) -> do
            result <- executeLifecycleTeardownOperation context operation
            pure
              ( validateNodeResult
                  compiled
                  context
                  operation
                  result
              )
 where
  graph = compiledDesiredAbsenceGraph compiled
  matchingPlan =
    find ((== cleanupNodeId suppliedPlan) . cleanupNodeId) (cleanupGraphNodes graph)
  context =
    TeardownExecutionContext
      { internalTeardownExecutionOperationId = cleanupNodeOperationId suppliedPlan
      , internalTeardownExecutionAttemptId = attempt
      , internalTeardownExecutionRunId = compiledDesiredAbsenceRunId compiled
      , internalTeardownExecutionDescriptorDigest = descriptorDigest
      , internalTeardownExecutionGraphDigest = cleanupGraphDigest graph
      , internalTeardownExecutionNodeId = cleanupNodeId suppliedPlan
      , internalTeardownExecutionObservationScope =
          compiledDesiredAbsenceObservationScope compiled
      , internalTeardownExecutionAttemptOperationIds =
          attemptOperationIds suppliedPlan
      , internalTeardownExecutionOperationCatalog =
          [ (operation, cleanupNodeOperationId plan)
          | plan <- cleanupGraphNodes graph
          , Just operation <- [compiledOperationForNode (cleanupNodeId plan) compiled]
          ]
      , internalTeardownExecutionSuccessfulPredecessors =
          succeededPredecessors
      , internalTeardownExecutionAttemptedPredecessors =
          attemptedPredecessors
      , internalTeardownExecutionTerminalPredecessors =
          terminalPredecessors
      }
  attemptOperationIds plan =
    mapMaybe
      dependencyOperationId
      [ dependency
      | dependency <- cleanupNodeDependencies plan
      , cleanupDependencyKind dependency == CleanupRequiresAttempt
      ]
  dependencyOperationId dependency =
    cleanupNodeOperationId
      <$> find
        ((== cleanupDependencyNode dependency) . cleanupNodeId)
        (cleanupGraphNodes graph)

-- | Sprint 4.94: dispatch one operation's result to the check that operation
-- asks for.
--
-- The dispatch is unchanged in shape and entirely changed in what it can be
-- handed. Matching an operation now refines the result index, so each helper
-- receives a result that can only be a refusal or that operation's own answer,
-- and the twenty catch-all arms that used to collapse into
-- /\"lifecycle interpreter returned the wrong result kind\"/ guard states the type
-- no longer admits.
--
-- The refusal is handled by each helper rather than once here, and that is the
-- point rather than duplication: with a single leading refusal arm the rest of
-- the match would still be a catch-all over the result universe, which is the
-- shape this sprint removes. Two exhaustive arms per helper is the exhaustive
-- match [Pure FP Standards § 2.2](../../../documents/engineering/pure_fp_standards.md#22-pattern-match-exhaustively)
-- asks for.
validateNodeResult
  :: forall surface result
   . CompiledDesiredAbsenceProgram surface
  -> TeardownExecutionContext surface
  -> TeardownOperation surface result
  -> TeardownNodeResult surface result
  -> CleanupNodeOutcome
validateNodeResult
  compiled
  context
  operation
  nodeResult = case operation of
    EstablishRecoveryPlane _ -> expectRecoveryMutation nodeResult
    ReadBackRecoveryPlane witness -> expectRecoveryInitial witness nodeResult
    ObserveRecoveryPlaneDisposition witness ->
      expectRecoveryFinal witness nodeResult
    ObserveRegisteredTarget target -> expectExactObservation False target nodeResult
    ObserveStackCheckpointPair target -> expectCheckpointPair target nodeResult
    ReconcileStackCheckpointRestore target -> expectCheckpointRestore target nodeResult
    ReadBackStackCheckpointRecovery target ->
      expectCheckpointRecoveryReadBack target nodeResult
    CommitAwsStackReaderBundle target ->
      expectAwsStackReaderCommit target nodeResult
    ReadBackAwsStackReaderBundle target ->
      expectAwsStackReaderReadBack target nodeResult
    CommitEksDrainIntent _ -> expectMutation nodeResult
    ReadBackEksDrainIntent target -> expectEksDrainIntent target nodeResult
    DrainEksKubernetesResources target -> expectEksDrainAttempt target nodeResult
    ReadBackEksKubernetesDrain target -> expectEksDrainReadBack target nodeResult
    ReconcileRegisteredTargetAbsent target ->
      expectRegisteredTargetReconcile target nodeResult
    ReadBackRegisteredTargetAbsent target -> expectExactObservation True target nodeResult
    RetireStackCheckpointPair target -> expectCheckpointRetirement target nodeResult
    ReadBackStackCheckpointRetirement target ->
      expectCheckpointRetirementReadBack target nodeResult
    AuditCascadeEscapes -> expectTerminalAudit nodeResult
    CommitCascadePreUninstallReport -> expectMutation nodeResult
    ReadBackCascadePreUninstallReport ->
      expectReceipt CascadePreUninstallReportReceipt nodeResult
    UninstallCascadeLocalFoundation -> expectMutation nodeResult
    ReadBackCascadeLocalAbsence -> expectLocalAbsence nodeResult
    CommitCascadeCompletion -> expectMutation nodeResult
    ReadBackCascadeCompletion -> expectReceipt CascadeCompletionReceipt nodeResult
    UninstallLocalOnlyFoundation -> expectMutation nodeResult
    ReadBackLocalOnlyAbsence -> expectLocalAbsence nodeResult
    CommitLocalOnlyCompletion -> expectMutation nodeResult
    ReadBackLocalOnlyCompletion -> expectReceipt LocalOnlyCompletionReceipt nodeResult
    RevokeOperationalCredential _ -> expectMutation nodeResult
    ReadBackOperationalCredentialRevocation _ ->
      expectOperationalCredentialRevocation nodeResult
    CommitOrdinarySurfaceReport -> expectMutation nodeResult
    ReadBackOrdinarySurfaceReport ->
      expectReceipt OrdinarySurfaceReportReceipt nodeResult
    AuditTotalDecommissionEscapes -> expectTerminalAudit nodeResult
    ObserveExternalDecommissionReceipt ->
      expectReceipt ExternalDecommissionReadyReceipt nodeResult
    UninstallDecommissionLocalFoundation -> expectMutation nodeResult
    ReadBackDecommissionLocalAbsence -> expectLocalAbsence nodeResult
    ApplyDecommissionLocalDataDisposition -> expectMutation nodeResult
    ReadBackDecommissionLocalDataDisposition -> expectLocalDataDisposition nodeResult
    CommitDecommissionTerminalReceipt -> expectMutation nodeResult
    ReadBackDecommissionTerminalReceipt ->
      expectReceipt DecommissionTerminalReceipt nodeResult
   where
    expectedOperationId = teardownExecutionOperationId context
    expectedAttemptId = teardownExecutionAttemptId context
    expectedAttemptOperationIds = teardownExecutionAttemptOperationIds context
    succeededPredecessors = teardownExecutionSuccessfulPredecessors context
    attemptedPredecessors = teardownExecutionAttemptedPredecessors context
    terminalPredecessors = teardownExecutionTerminalPredecessors context
    expectedScope = compiledDesiredAbsenceObservationScope compiled
    expectedGraphDigest = cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)

    expectEksDrainIntent
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'EksDrainIntentReadBackResult
      -> CleanupNodeOutcome
    expectEksDrainIntent target result = case result of
      TeardownEksDrainIntentReadBack (Left err) ->
        CleanupNodeFailed ("EKS drain intent read-back refused: " <> renderShow err)
      TeardownEksDrainIntentReadBack (Right committed)
        | validateEksIntentBinding target (committedEksDrainIntent committed)
            && attemptedOperationMatches (CommitEksDrainIntent target) ->
            CleanupNodeSucceeded
        | otherwise -> bindingMismatch
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectEksDrainAttempt
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'EksDrainAttemptResult
      -> CleanupNodeOutcome
    expectEksDrainAttempt target result = case result of
      TeardownEksDrainAttempt (Left err) ->
        CleanupNodeFailed ("EKS drain attempt refused: " <> renderShow err)
      TeardownEksDrainAttempt (Right attempt)
        | not (validateEksIntentBinding target (eksDrainAttemptIntent attempt)) ->
            bindingMismatch
        | not (attemptedOperationMatches (ReadBackEksDrainIntent target)) ->
            bindingMismatch
        | eksDrainBindingEffectOperationId
            (eksDrainIntentBinding (eksDrainAttemptIntent attempt))
            /= expectedOperationId ->
            bindingMismatch
        | eksDrainAttemptEvidenceAttemptId attempt /= expectedAttemptId ->
            bindingMismatch
        | otherwise -> case eksDrainAttemptOutcome attempt of
            EksDrainMutationApplied -> CleanupNodeSucceeded
            EksDrainSkippedNoKubernetesTarget -> CleanupNodeSucceeded
            EksDrainMutationFailed failure ->
              CleanupNodeFailed (observationFailureText failure)
            EksDrainMutationUnobservable failure ->
              CleanupNodeEffectUnconfirmed (observationFailureText failure)
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectEksDrainReadBack
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'EksDrainTargetReadBackResult
      -> CleanupNodeOutcome
    expectEksDrainReadBack target result = case result of
      TeardownEksDrainTargetReadBack (Left err) ->
        CleanupNodeFailed ("EKS drain target read-back refused: " <> renderShow err)
      TeardownEksDrainTargetReadBack (Right evidence)
        | not
            ( validateEksIntentBinding
                target
                (eksDrainTargetsAbsentIntent evidence)
            ) ->
            bindingMismatch
        | eksDrainTargetsAbsentScope evidence /= expectedScope -> bindingMismatch
        | eksDrainTargetsAbsentRunId evidence /= compiledDesiredAbsenceRunId compiled ->
            bindingMismatch
        | eksDrainTargetsAbsentGraphDigest evidence /= expectedGraphDigest ->
            bindingMismatch
        | Just (eksDrainTargetsAbsentIntentCommitOperationId evidence)
            /= expectedEksOperationId (CommitEksDrainIntent target) ->
            bindingMismatch
        | Just (eksDrainTargetsAbsentIntentReadBackOperationId evidence)
            /= expectedEksOperationId (ReadBackEksDrainIntent target) ->
            bindingMismatch
        | Just (eksDrainTargetsAbsentEffectOperationId evidence)
            /= expectedEksOperationId (DrainEksKubernetesResources target) ->
            bindingMismatch
        | eksDrainTargetsAbsentDrainReadBackOperationId evidence /= expectedOperationId ->
            bindingMismatch
        | not (attemptReceiptMatches target evidence) -> bindingMismatch
        | otherwise -> CleanupNodeSucceeded
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    validateEksIntentBinding
      :: RegisteredTargetBinding -> EksDrainIntent -> Bool
    validateEksIntentBinding target intent =
      eksDrainIntentResourceKey intent == registeredTargetKey target
        && eksDrainIntentCoordinateDigest intent == registeredTargetCoordinateDigest target
        && eksDrainBindingScope binding == expectedScope
        && eksDrainBindingRunId binding == compiledDesiredAbsenceRunId compiled
        && eksDrainBindingGraphDigest binding == expectedGraphDigest
        && Just (eksDrainBindingIntentCommitOperationId binding)
          == expectedEksOperationId (CommitEksDrainIntent target)
        && Just (eksDrainBindingIntentReadBackOperationId binding)
          == expectedEksOperationId (ReadBackEksDrainIntent target)
        && Just (eksDrainBindingEffectOperationId binding)
          == expectedEksOperationId (DrainEksKubernetesResources target)
        && Just (eksDrainBindingDrainReadBackOperationId binding)
          == expectedEksOperationId (ReadBackEksKubernetesDrain target)
     where
      binding = eksDrainIntentBinding intent

    expectedEksOperationId
      :: TeardownOperation surface wantedResult -> Maybe CleanupOperationId
    expectedEksOperationId wanted =
      case [ operationId
           | (nodeId, candidate) <- compiledDesiredAbsenceOperations compiled
           , candidate == SomeTeardownOperation wanted
           , node <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
           , cleanupNodeId node == nodeId
           , let operationId = cleanupNodeOperationId node
           ] of
        [operationId] -> Just operationId
        _ -> Nothing

    attemptedOperationMatches :: TeardownOperation surface wantedResult -> Bool
    attemptedOperationMatches wanted =
      any
        ( \predecessor ->
            teardownAttemptedPredecessorOperation predecessor
              == SomeTeardownOperation wanted
              && Just (teardownAttemptedPredecessorOperationId predecessor)
                == expectedEksOperationId wanted
        )
        attemptedPredecessors

    attemptReceiptMatches target evidence =
      any
        ( \predecessor ->
            teardownAttemptedPredecessorOperation predecessor
              == SomeTeardownOperation (DrainEksKubernetesResources target)
              && teardownAttemptedPredecessorOperationId predecessor
                == eksDrainTargetsAbsentEffectOperationId evidence
              && teardownAttemptedPredecessorAttemptId predecessor
                == eksDrainTargetsAbsentEffectAttemptId evidence
        )
        attemptedPredecessors

    observationFailureText (ObservationFailure detail) = detail
    renderShow = Text.pack . show

    expectMutation :: TeardownNodeResult surface 'MutationAttemptResult -> CleanupNodeOutcome
    expectMutation result = case result of
      TeardownMutationAttempt mutation -> case mutation of
        TeardownMutationApplied -> CleanupNodeSucceeded
        TeardownMutationResponseLost detail -> CleanupNodeEffectUnconfirmed detail
        TeardownMutationRefused detail -> CleanupNodeFailed detail
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectRecoveryMutation :: TeardownNodeResult surface 'MutationAttemptResult -> CleanupNodeOutcome
    expectRecoveryMutation result = case teardownExecutionDescriptorDigest context of
      Nothing -> descriptorContextRequired
      Just _ -> expectMutation result

    expectRecoveryInitial
      :: RecoverySurfaceWitness surface
      -> TeardownNodeResult surface 'RecoveryPlaneInitialReadBackResult
      -> CleanupNodeOutcome
    expectRecoveryInitial witness result = case result of
      TeardownRecoveryPlaneInitialReadBack evidence
        | not (recoveryIdentityMatches witness identity) -> bindingMismatch
        | recoveryPlaneIdentityReadBackOperationId identity /= expectedOperationId ->
            bindingMismatch
        | recoveryPlaneInitialReadBackAttemptId evidence /= expectedAttemptId ->
            bindingMismatch
        | not (initialPredecessorMatches witness evidence) -> bindingMismatch
        | not
            ( threeDistinctAttempts
                (recoveryPlaneInitialEstablishAttemptId evidence)
                (recoveryPlaneInitialReadBackAttemptId evidence)
                Nothing
            ) ->
            bindingMismatch
        | otherwise -> case recoveryPlaneInitialDisposition evidence of
            RecoveryPlaneInitiallyReady -> CleanupNodeSucceeded
            RecoveryPlaneInitiallyNotReady ->
              CleanupNodeFailed
                ( recoveryFailure
                    "cleanup recovery plane is not initially ready"
                    (recoveryPlaneInitialFailures evidence)
                )
       where
        identity = recoveryPlaneInitialIdentity evidence
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectRecoveryFinal
      :: RecoverySurfaceWitness surface
      -> TeardownNodeResult surface 'RecoveryPlaneFinalEvidenceResult
      -> CleanupNodeOutcome
    expectRecoveryFinal witness result = case result of
      TeardownRecoveryPlaneFinalEvidence evidence
        | not (recoveryIdentityMatches witness identity) -> bindingMismatch
        | recoveryPlaneIdentityDispositionOperationId identity /= expectedOperationId ->
            bindingMismatch
        | recoveryPlaneFinalDispositionAttemptId evidence /= expectedAttemptId ->
            bindingMismatch
        | not (finalReadBackPredecessorMatches witness evidence) -> bindingMismatch
        | not
            ( threeDistinctAttempts
                (recoveryPlaneFinalEstablishAttemptId evidence)
                (recoveryPlaneFinalInitialReadBackAttemptId evidence)
                (Just (recoveryPlaneFinalDispositionAttemptId evidence))
            ) ->
            bindingMismatch
        | otherwise -> case recoveryPlaneFinalDisposition evidence of
            RecoveryPlaneEstablished -> CleanupNodeSucceeded
            RecoveryPlaneNotEstablished ->
              CleanupNodeFailed
                ( recoveryFailure
                    "cleanup recovery plane was not established"
                    (recoveryPlaneFinalFailures evidence)
                )
            RecoveryPlaneLost ->
              CleanupNodeFailed
                ( recoveryFailure
                    "cleanup recovery plane was lost"
                    (recoveryPlaneFinalFailures evidence)
                )
       where
        identity = recoveryPlaneFinalIdentity evidence
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    recoveryFailure prefix =
      maybe
        prefix
        (\failures -> prefix <> ": " <> renderRecoveryPlaneComponentFailures failures)

    recoveryIdentityMatches
      :: RecoverySurfaceWitness surface
      -> RecoveryPlaneIdentity surface
      -> Bool
    recoveryIdentityMatches witness identity =
      recoveryPlaneIdentitySurface identity == recoverySurface witness
        && recoveryPlaneIdentityRunId identity == compiledDesiredAbsenceRunId compiled
        && Just (recoveryPlaneIdentityDescriptorDigest identity)
          == teardownExecutionDescriptorDigest context
        && recoveryPlaneIdentityGraphDigest identity == expectedGraphDigest
        && recoveryPlaneIdentityObservationScope identity == expectedScope
        && Just (recoveryPlaneIdentityEstablishOperationId identity)
          == teardownExecutionOperationIdFor
            context
            (EstablishRecoveryPlane witness)
        && Just (recoveryPlaneIdentityReadBackOperationId identity)
          == teardownExecutionOperationIdFor
            context
            (ReadBackRecoveryPlane witness)
        && Just (recoveryPlaneIdentityDispositionOperationId identity)
          == teardownExecutionOperationIdFor
            context
            (ObserveRecoveryPlaneDisposition witness)
        && threeDistinctOperations identity

    threeDistinctOperations :: RecoveryPlaneIdentity surface -> Bool
    threeDistinctOperations identity =
      establishOperation /= readBackOperation
        && establishOperation /= dispositionOperation
        && readBackOperation /= dispositionOperation
     where
      establishOperation = recoveryPlaneIdentityEstablishOperationId identity
      readBackOperation = recoveryPlaneIdentityReadBackOperationId identity
      dispositionOperation = recoveryPlaneIdentityDispositionOperationId identity

    initialPredecessorMatches
      :: RecoverySurfaceWitness surface
      -> RecoveryPlaneInitialReadBack surface
      -> Bool
    initialPredecessorMatches witness evidence =
      expectedAttemptOperationIds == [expectedEstablishOperation]
        && case attemptedPredecessors of
          [predecessor] ->
            teardownAttemptedPredecessorOperationId predecessor
              == expectedEstablishOperation
              && teardownAttemptedPredecessorAttemptId predecessor
                == recoveryPlaneInitialEstablishAttemptId evidence
              && teardownAttemptedPredecessorOperation predecessor
                == SomeTeardownOperation (EstablishRecoveryPlane witness)
          _ -> False
     where
      expectedEstablishOperation =
        recoveryPlaneIdentityEstablishOperationId
          (recoveryPlaneInitialIdentity evidence)

    finalReadBackPredecessorMatches
      :: RecoverySurfaceWitness surface
      -> RecoveryPlaneFinalEvidence surface
      -> Bool
    finalReadBackPredecessorMatches witness evidence =
      case filter matchingOperation terminalPredecessors of
        [predecessor] -> case teardownTerminalPredecessorResult predecessor of
          TeardownTerminalPredecessorCompleted attempt _ ->
            teardownTerminalPredecessorOperation predecessor
              == SomeTeardownOperation (ReadBackRecoveryPlane witness)
              && attempt == recoveryPlaneFinalInitialReadBackAttemptId evidence
          TeardownTerminalPredecessorBlocked _ -> False
        _ -> False
     where
      matchingOperation predecessor =
        teardownTerminalPredecessorOperationId predecessor
          == recoveryPlaneIdentityReadBackOperationId
            (recoveryPlaneFinalIdentity evidence)

    recoverySurface :: RecoverySurfaceWitness surface -> CleanupSurface
    recoverySurface witness = case witness of
      CascadeRecoverySurface -> Cascade
      ExplicitPerRunRecoverySurface -> ExplicitPerRun
      OperationalRecoverySurface -> OperationalTeardown
      ExplicitLongLivedRecoverySurface -> ExplicitLongLived

    threeDistinctAttempts
      :: CleanupAttemptId
      -> CleanupAttemptId
      -> Maybe CleanupAttemptId
      -> Bool
    threeDistinctAttempts establishAttempt readBackAttempt dispositionAttempt =
      establishAttempt /= readBackAttempt
        && case dispositionAttempt of
          Nothing -> True
          Just finalAttempt ->
            establishAttempt /= finalAttempt
              && readBackAttempt /= finalAttempt

    descriptorContextRequired =
      CleanupNodeFailed "cleanup recovery-plane evidence requires descriptor-bound execution"

    expectExactObservation
      :: Bool
      -> RegisteredTargetBinding
      -> TeardownNodeResult surface 'ExactResourceObservationResult
      -> CleanupNodeOutcome
    expectExactObservation requireAbsent target result = case result of
      TeardownExactResourceObservation observation
        | exactObservationResourceKey observation /= registeredTargetKey target -> bindingMismatch
        | exactObservationCoordinateDigest observation
            /= registeredTargetCoordinateDigest target ->
            bindingMismatch
        | exactObservationEvidenceScope observation /= expectedScope -> bindingMismatch
        | exactObservationAuthority observation /= expectedObservationAuthority target -> bindingMismatch
        | otherwise -> case exactObservationResult observation of
            ExactResourceAbsent _ -> CleanupNodeSucceeded
            ExactResourcePresent _
              | requireAbsent -> CleanupNodeFailed "registered resource is still present"
              | otherwise -> CleanupNodeSucceeded
            ExactResourcePartial _ _ ->
              CleanupNodeFailed "registered resource observation is partial"
            ExactResourceUnobservable _ ->
              CleanupNodeFailed "registered resource is unobservable"
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectRegisteredTargetReconcile
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'RegisteredTargetReconcileResult
      -> CleanupNodeOutcome
    expectRegisteredTargetReconcile target result = case result of
      TeardownRegisteredTargetReconcile reconciled
        | registeredTargetReconcileKey reconciled /= registeredTargetKey target ->
            bindingMismatch
        | registeredTargetReconcileCoordinateDigest reconciled
            /= registeredTargetCoordinateDigest target ->
            bindingMismatch
        | registeredTargetReconcileScope reconciled /= expectedScope ->
            bindingMismatch
        | registeredTargetReconcileOperationId reconciled /= expectedOperationId ->
            bindingMismatch
        | otherwise ->
            reconcileDispositionOutcome
              (registeredTargetReconcileDisposition reconciled)
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectCheckpointPair
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'CheckpointPairObservationResult
      -> CleanupNodeOutcome
    expectCheckpointPair target result = case result of
      TeardownCheckpointPairObservation pair
        | not (registeredStackBindingMatches target) -> bindingMismatch
        | otherwise -> case validateCheckpointPair target pair of
            Left _ -> bindingMismatch
            Right _ -> CleanupNodeSucceeded
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectCheckpointRestore
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'CheckpointRestoreResult
      -> CleanupNodeOutcome
    expectCheckpointRestore target result = case result of
      TeardownCheckpointRestore outcome
        | not (registeredStackBindingMatches target) -> bindingMismatch
        | checkpointRestoreOutcomeOperationId outcome /= expectedOperationId ->
            bindingMismatch
        | checkpointRestoreOutcomeStackKey outcome /= registeredTargetKey target ->
            bindingMismatch
        | checkpointRestoreOutcomeCoordinateDigest outcome
            /= registeredTargetCoordinateDigest target ->
            bindingMismatch
        | checkpointRestoreOutcomeScope outcome /= expectedScope -> bindingMismatch
        | otherwise -> case checkpointRestoreOutcomeDisposition outcome of
            CheckpointRestorePrimaryAlreadyAvailable -> CleanupNodeSucceeded
            CheckpointRestoreResourceAlreadyAbsent _ -> CleanupNodeSucceeded
            CheckpointRestoreNoUsableBackup -> CleanupNodeSucceeded
            CheckpointRestoreMutationAttempted attempt -> case attempt of
              CheckpointRestoreApplied -> CleanupNodeSucceeded
              CheckpointRestoreResponseLost ->
                CleanupNodeEffectUnconfirmed "checkpoint restore response lost"
              CheckpointRestoreRefused _ ->
                CleanupNodeFailed "checkpoint restore was refused"
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectCheckpointRecoveryReadBack
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'CheckpointRecoveryReadBackResult
      -> CleanupNodeOutcome
    expectCheckpointRecoveryReadBack target result = case result of
      TeardownCheckpointRecoveryReadBack evidence
        | not (registeredStackBindingMatches target) -> bindingMismatch
        | checkpointRecoveryStackKey evidence /= registeredTargetKey target ->
            bindingMismatch
        | checkpointRecoveryCoordinateDigest evidence
            /= registeredTargetCoordinateDigest target ->
            bindingMismatch
        | checkpointRecoveryScope evidence /= expectedScope -> bindingMismatch
        | not (matchesOnlyAttemptOperation (checkpointRecoveryOperationId evidence)) ->
            bindingMismatch
        | otherwise -> CleanupNodeSucceeded
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectAwsStackReaderCommit
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'AwsStackReaderCommitResult
      -> CleanupNodeOutcome
    expectAwsStackReaderCommit target result = case result of
      TeardownAwsStackReaderCommit outcome
        | not (registeredStackBindingMatches target) -> bindingMismatch
        | awsStackReaderCommitRunId outcome
            /= compiledDesiredAbsenceRunId compiled ->
            bindingMismatch
        | awsStackReaderCommitGraphDigest outcome /= expectedGraphDigest ->
            bindingMismatch
        | awsStackReaderCommitOperationId outcome /= expectedOperationId ->
            bindingMismatch
        | awsStackReaderCommitAttemptId outcome /= expectedAttemptId ->
            bindingMismatch
        | awsStackReaderCommitKey outcome /= registeredTargetKey target ->
            bindingMismatch
        | awsStackReaderCommitCoordinateDigest outcome
            /= registeredTargetCoordinateDigest target ->
            bindingMismatch
        | awsStackReaderCommitScope outcome /= expectedScope -> bindingMismatch
        | Just (awsStackReaderCommitReconcileOperationId outcome)
            /= expectedEksOperationId (ReconcileRegisteredTargetAbsent target) ->
            bindingMismatch
        | not (successfulCheckpointRecoveryMatches target) -> bindingMismatch
        | otherwise -> case awsStackReaderCommitDisposition outcome of
            AwsStackReaderCommitCreated -> CleanupNodeSucceeded
            AwsStackReaderCommitExactReplay -> CleanupNodeSucceeded
            AwsStackReaderCommitConflict ->
              CleanupNodeFailed "AWS stack-reader bundle conflicts with the durable value"
            AwsStackReaderCommitResponseLost (ObservationFailure detail) ->
              CleanupNodeEffectUnconfirmed detail
            AwsStackReaderCommitUnavailable (ObservationFailure detail) ->
              CleanupNodeFailed detail
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectAwsStackReaderReadBack
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'AwsStackReaderReadBackResult
      -> CleanupNodeOutcome
    expectAwsStackReaderReadBack target result = case result of
      TeardownAwsStackReaderReadBack evidence
        | not (registeredStackBindingMatches target) -> bindingMismatch
        | awsStackReaderReadBackRunId evidence
            /= compiledDesiredAbsenceRunId compiled ->
            bindingMismatch
        | awsStackReaderReadBackGraphDigest evidence /= expectedGraphDigest ->
            bindingMismatch
        | awsStackReaderReadBackOperationId evidence /= expectedOperationId ->
            bindingMismatch
        | awsStackReaderReadBackAttemptId evidence /= expectedAttemptId ->
            bindingMismatch
        | awsStackReaderReadBackKey evidence /= registeredTargetKey target ->
            bindingMismatch
        | awsStackReaderReadBackCoordinateDigest evidence
            /= registeredTargetCoordinateDigest target ->
            bindingMismatch
        | awsStackReaderReadBackScope evidence /= expectedScope -> bindingMismatch
        | Just (awsStackReaderReadBackReconcileOperationId evidence)
            /= expectedEksOperationId (ReconcileRegisteredTargetAbsent target) ->
            bindingMismatch
        | not (stackReaderCommitAttemptMatches target evidence) ->
            bindingMismatch
        | otherwise -> CleanupNodeSucceeded
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    successfulCheckpointRecoveryMatches :: RegisteredTargetBinding -> Bool
    successfulCheckpointRecoveryMatches target =
      case succeededPredecessors of
        [predecessor] ->
          teardownSucceededPredecessorOperation predecessor
            == SomeTeardownOperation (ReadBackStackCheckpointRecovery target)
            && Just (teardownSucceededPredecessorOperationId predecessor)
              == expectedEksOperationId (ReadBackStackCheckpointRecovery target)
        _ -> False

    stackReaderCommitAttemptMatches
      :: RegisteredTargetBinding
      -> AwsStackReaderReadBackEvidence
      -> Bool
    stackReaderCommitAttemptMatches target evidence =
      expectedAttemptOperationIds
        == [awsStackReaderReadBackCommitOperationId evidence]
        && case attemptedPredecessors of
          [predecessor] ->
            teardownAttemptedPredecessorOperation predecessor
              == SomeTeardownOperation (CommitAwsStackReaderBundle target)
              && teardownAttemptedPredecessorOperationId predecessor
                == awsStackReaderReadBackCommitOperationId evidence
              && teardownAttemptedPredecessorAttemptId predecessor
                == awsStackReaderReadBackCommitAttemptId evidence
          _ -> False

    expectCheckpointRetirement
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'CheckpointRetirementResult
      -> CleanupNodeOutcome
    expectCheckpointRetirement target result = case result of
      TeardownCheckpointRetirement outcome
        | not (registeredStackBindingMatches target) -> bindingMismatch
        | checkpointRetirementOutcomeOperationId outcome /= expectedOperationId ->
            bindingMismatch
        | checkpointRetirementOutcomeStackKey outcome /= registeredTargetKey target ->
            bindingMismatch
        | checkpointRetirementOutcomeCoordinateDigest outcome
            /= registeredTargetCoordinateDigest target ->
            bindingMismatch
        | checkpointRetirementOutcomeScope outcome /= expectedScope -> bindingMismatch
        | otherwise -> case checkpointRetirementOutcomeAttempt outcome of
            CheckpointRetirementApplied -> CleanupNodeSucceeded
            CheckpointRetirementResponseLost ->
              CleanupNodeEffectUnconfirmed "checkpoint retirement response lost"
            CheckpointRetirementRefused _ ->
              CleanupNodeFailed "checkpoint retirement was refused"
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectCheckpointRetirementReadBack
      :: RegisteredTargetBinding
      -> TeardownNodeResult surface 'CheckpointRetirementReadBackResult
      -> CleanupNodeOutcome
    expectCheckpointRetirementReadBack target result = case result of
      TeardownCheckpointRetirementReadBack evidence
        | not (registeredStackBindingMatches target) -> bindingMismatch
        | checkpointRetirementEvidenceStackKey evidence
            /= registeredTargetKey target ->
            bindingMismatch
        | checkpointRetirementEvidenceCoordinateDigest evidence
            /= registeredTargetCoordinateDigest target ->
            bindingMismatch
        | checkpointRetirementEvidenceScope evidence /= expectedScope -> bindingMismatch
        | not
            ( matchesOnlyAttemptOperation
                (checkpointRetirementEvidenceOperationId evidence)
            ) ->
            bindingMismatch
        | otherwise -> CleanupNodeSucceeded
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    registeredStackBindingMatches :: RegisteredTargetBinding -> Bool
    registeredStackBindingMatches target =
      registeredTargetKind target == Stack
        && case lookupRegisteredIdentity (registeredTargetKey target) of
          Nothing -> False
          Just identity ->
            registeredIdentityKind identity == Stack
              && registeredIdentityCoordinateDigest identity
                == registeredTargetCoordinateDigest target

    validateCheckpointPair
      :: RegisteredTargetBinding
      -> CheckpointPairObservation
      -> Either CheckpointPairError CheckpointPairObservation
    validateCheckpointPair target pair =
      mkCheckpointPairObservation
        (registeredTargetKey target)
        expectedScope
        (primaryCheckpointObservation pair)
        (backupCheckpointObservation pair)

    matchesOnlyAttemptOperation :: CleanupOperationId -> Bool
    matchesOnlyAttemptOperation operationId =
      expectedAttemptOperationIds == [operationId]

    reconcileDispositionOutcome
      :: RegisteredTargetReconcileDisposition -> CleanupNodeOutcome
    reconcileDispositionOutcome disposition = case disposition of
      RegisteredTargetConfirmedAlreadyAbsent _ -> CleanupNodeSucceeded
      RegisteredTargetAwsStackMutation attempt -> mutationAttemptOutcome attempt
      RegisteredTargetAwsEksMutation attempt -> mutationAttemptOutcome attempt
      RegisteredTargetAwsEbsMutation attempt -> mutationAttemptOutcome attempt
      RegisteredTargetAwsValidationZoneMutation attempt ->
        mutationAttemptOutcome attempt
      RegisteredTargetAwsRetainedEbsMutation attempt ->
        mutationAttemptOutcome attempt
      RegisteredTargetAwsIamRoleFamilyMutation attempt ->
        mutationAttemptOutcome attempt
      RegisteredTargetAwsLoadBalancerControllerFamilyMutation attempt ->
        mutationAttemptOutcome attempt
      RegisteredTargetDns01ChallengeOwnerDelete attempt ->
        mutationAttemptOutcome attempt
      RegisteredTargetReconcileRefused detail -> CleanupNodeFailed detail

    mutationAttemptOutcome
      :: RegisteredTargetMutationAttempt -> CleanupNodeOutcome
    mutationAttemptOutcome attempt = case attempt of
      RegisteredTargetMutationApplied -> CleanupNodeSucceeded
      RegisteredTargetMutationResponseLost detail ->
        CleanupNodeEffectUnconfirmed detail
      RegisteredTargetMutationRefused detail -> CleanupNodeFailed detail

    expectTerminalAudit
      :: TeardownNodeResult surface 'TerminalAuditObservationResult -> CleanupNodeOutcome
    expectTerminalAudit result = case result of
      TeardownTerminalAuditObservation observation
        | terminalAuditEvidenceScope (terminalAuditScope observation)
            /= auditEvidenceScope expectedScope ->
            bindingMismatch
        | otherwise -> case terminalAuditResult observation of
            TerminalAuditConfirmedClean _ -> CleanupNodeSucceeded
            TerminalAuditFoundEscapes _ _ ->
              CleanupNodeFailed "terminal lifecycle audit found unexpected resources"
            TerminalAuditUnobservable _ _ ->
              CleanupNodeFailed "terminal lifecycle audit is unobservable"
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectReceipt
      :: DurableReceiptKind
      -> TeardownNodeResult surface 'DurableReceiptObservationResult
      -> CleanupNodeOutcome
    expectReceipt expectedKind result = case result of
      TeardownDurableReceiptObservation observation
        | durableReceiptObservationKind observation /= expectedKind -> bindingMismatch
        | durableReceiptObservationScope observation /= expectedScope -> bindingMismatch
        | durableReceiptObservationGraphDigest observation /= expectedGraphDigest -> bindingMismatch
        | otherwise -> case durableReceiptObservationResult observation of
            DurableReceiptObserved -> CleanupNodeSucceeded
            DurableReceiptMissing -> CleanupNodeFailed "durable cleanup receipt is missing"
            DurableReceiptUnobservable _ ->
              CleanupNodeFailed "durable cleanup receipt is unobservable"
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectLocalAbsence
      :: TeardownNodeResult surface 'LocalFoundationObservationResult -> CleanupNodeOutcome
    expectLocalAbsence result = case result of
      TeardownLocalFoundationObservation observation
        | localFoundationObservationScope observation /= expectedScope -> bindingMismatch
        | otherwise -> case localFoundationObservationResult observation of
            LocalFoundationAbsent _ -> CleanupNodeSucceeded
            LocalFoundationPresent -> CleanupNodeFailed "local RKE2 foundation is still present"
            LocalFoundationUnobservable _ ->
              CleanupNodeFailed "local RKE2 foundation is unobservable"
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    -- Sprint 4.85: the revocation read-back succeeds only on the canonical
    -- confirmed decision. A refusal is a failure rather than an unobservable
    -- result -- the boundary answered, and the answer was that the credential
    -- is not gone -- and an unobservable read-back stays distinct from both.
    expectOperationalCredentialRevocation
      :: TeardownNodeResult surface 'OperationalCredentialRevocationObservationResult
      -> CleanupNodeOutcome
    expectOperationalCredentialRevocation result = case result of
      TeardownOperationalCredentialRevocationObservation observation
        | operationalCredentialRevocationObservationScope observation
            /= expectedScope ->
            bindingMismatch
        | operationalCredentialRevocationObservationTarget observation
            /= LifecycleProviderTarget ->
            bindingMismatch
        | otherwise ->
            case operationalCredentialRevocationObservationResult observation of
              OperationalCredentialRevocationConfirmed -> CleanupNodeSucceeded
              OperationalCredentialRevocationRefused refusal ->
                CleanupNodeFailed
                  ( "operational credential revocation was not read back: "
                      <> Text.pack (show refusal)
                  )
              OperationalCredentialRevocationUnobservable _ ->
                CleanupNodeFailed
                  "operational credential revocation is unobservable"
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    expectLocalDataDisposition
      :: TeardownNodeResult surface 'LocalDataDispositionObservationResult
      -> CleanupNodeOutcome
    expectLocalDataDisposition result = case result of
      TeardownLocalDataDispositionObservation observation
        | localDataDispositionObservationScope observation /= expectedScope -> bindingMismatch
        | otherwise -> case localDataDispositionObservationResult observation of
            LocalDataDispositionConfirmed -> CleanupNodeSucceeded
            LocalDataDispositionNotApplied ->
              CleanupNodeFailed "local data disposition was not applied"
            LocalDataDispositionUnobservable _ ->
              CleanupNodeFailed "local data disposition is unobservable"
      TeardownNodeRefused detail -> CleanupNodeFailed detail

    bindingMismatch = CleanupNodeFailed "lifecycle observation binding mismatch"

expectedObservationAuthority :: RegisteredTargetBinding -> ObservationAuthority
expectedObservationAuthority target =
  case lookupRegisteredIdentity (registeredTargetKey target) of
    Just identity -> registeredIdentityObservationAuthority identity
    Nothing -> AwsResourceApiAuthority

-- | The scope a run's terminal escape audit is taken in.
--
-- Sprint 4.92: this was a field-by-field re-mint through
-- 'mkObservationEvidenceScope', which copied six of the scope's seven fields
-- and dropped the seventh, because that constructor's documented contract
-- hardcodes the run's retained DNS hosted zone to absent.  The audit therefore
-- ran under a scope that was not the run's, and @expectTerminalAudit@ above
-- compares the receipt's scope against this value with derived 'Eq': a zoned
-- run's audit receipt could only ever be read as a binding mismatch, and the
-- audit that did run swept for DNS01 challenge records without the zone they
-- live in.  The canonical re-scoper is a record update, so a field added to the
-- scope later cannot be dropped here again.
auditEvidenceScope :: ObservationEvidenceScope -> ObservationEvidenceScope
auditEvidenceScope = scopeForTerminalAudit
