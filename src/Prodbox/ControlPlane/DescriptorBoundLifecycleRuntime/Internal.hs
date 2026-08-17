{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE RankNTypes #-}

-- | Package-private total dispatcher for descriptor-bound lifecycle work.
-- The constructor accepts only the two closed production runtimes. It has no
-- caller-supplied continuation for operations those runtimes do not own.
module Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal
  ( DescriptorBoundLifecycleRuntimeError (..)
  , DescriptorBoundLifecycleUnsupported (..)
  , descriptorBoundLifecycleNodeActionInternal
  , DescriptorBoundLifecycleRuntimeRegression
  , fixedDescriptorBoundLifecycleRuntimeRegression
  , descriptorBoundLifecycleRuntimeCloudOperationsExact
  , descriptorBoundLifecycleRuntimeRecoveryOperationsExact
  , descriptorBoundLifecycleRuntimeUnsupportedOperationsExact
  , descriptorBoundLifecycleRuntimeUnsupportedIsRefusal
  , descriptorBoundLifecycleRuntimeNoCallerContinuation
  , descriptorBoundLifecycleRuntimeDescriptorBoundOnly
  , descriptorBoundLifecycleRuntimeOpacityClosed
  )
where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedClientTransport
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthorityOperationClient
import Prodbox.ControlPlane.AwsStackReaderRepository
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient (..)
  , descriptorBoundCleanupRunClient
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunDescriptorResponse (..)
  , CleanupRunEndpointResult (CleanupRunEndpointDescriptorBound)
  , cleanupRunEndpointBody
  , cleanupRunEndpointStatus
  , cleanupRunMaximumBytes
  )
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.EksDrainIntentClient
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
import Prodbox.ControlPlane.RecoveryPlaneHostRuntime.Internal
  ( fixedRecoveryPlaneHostRuntimeRegression
  , recoveryPlaneHostDescriptorBoundNodeActionInternal
  , recoveryPlaneHostRuntimeClosedOperationsExact
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupOwnerId
  , CleanupPrimaryOutcome (CleanupPrimarySucceeded)
  , CleanupRun
  , CleanupRunId
  , beginCleanupNode
  , cleanupDigestText
  , cleanupGraphNodes
  , cleanupLeaseFence
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupRunIdText
  , cleanupRunLease
  , completeCleanupNode
  , encodeCleanupRun
  , mkCleanupAttemptId
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  , recordPrimaryOutcome
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , DescriptorBoundCleanupNodeExecutionAction
  , descriptorBoundCleanupNodeAction
  , descriptorBoundCleanupNodeExecutionContext
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.PulumiCheckpoint
import Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.AwsStackReaderInterpreter
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( CleanupProgramDescriptor
  , captureCleanupProgramDescriptor
  , cleanupProgramDescriptorBytes
  , cleanupProgramDescriptorDigest
  , cleanupProgramDescriptorRunId
  )
import Prodbox.Lifecycle.Teardown.CloudRuntime
  ( CloudRuntime
  , executeCloudOperation
  , mkCloudRuntime
  )
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter
import Prodbox.Lifecycle.Teardown.EksTeardownExecutor
import Prodbox.Lifecycle.Teardown.Execution
  ( LifecycleTeardownEffects (..)
  , TeardownNodeResult (TeardownNodeRefused)
  , runCompiledTeardownNodeWithDescriptorContext
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceOperations
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurfaceWitness (..)
  , LinuxRke2FoundationId (..)
  , ObservationFailure (..)
  )
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
  ( TeardownOperation (..)
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime)
  )

-- | Every operation not owned by either released runtime has a distinct
-- refusal classification. Appending a lifecycle operation requires extending
-- the exhaustive classifier below before this module compiles warning-free.
data DescriptorBoundLifecycleUnsupported
  = DescriptorBoundLifecycleCascadeAudit
  | DescriptorBoundLifecycleCascadePreUninstallReportCommit
  | DescriptorBoundLifecycleCascadePreUninstallReportReadBack
  | DescriptorBoundLifecycleCascadeLocalFoundationUninstall
  | DescriptorBoundLifecycleCascadeLocalAbsenceReadBack
  | DescriptorBoundLifecycleCascadeCompletionCommit
  | DescriptorBoundLifecycleCascadeCompletionReadBack
  | DescriptorBoundLifecycleLocalOnlyFoundationUninstall
  | DescriptorBoundLifecycleLocalOnlyAbsenceReadBack
  | DescriptorBoundLifecycleLocalOnlyCompletionCommit
  | DescriptorBoundLifecycleLocalOnlyCompletionReadBack
  | DescriptorBoundLifecycleOrdinarySurfaceReportCommit
  | DescriptorBoundLifecycleOrdinarySurfaceReportReadBack
  | DescriptorBoundLifecycleTotalDecommissionAudit
  | DescriptorBoundLifecycleExternalDecommissionReceiptObserve
  | DescriptorBoundLifecycleDecommissionLocalFoundationUninstall
  | DescriptorBoundLifecycleDecommissionLocalAbsenceReadBack
  | DescriptorBoundLifecycleDecommissionLocalDataDispositionApply
  | DescriptorBoundLifecycleDecommissionLocalDataDispositionReadBack
  | DescriptorBoundLifecycleDecommissionTerminalReceiptCommit
  | DescriptorBoundLifecycleDecommissionTerminalReceiptReadBack
  deriving stock (Eq, Show)

data DescriptorBoundLifecycleRuntimeError
  = DescriptorBoundLifecycleOperationMissing
  | DescriptorBoundLifecycleOperationDuplicated
  | DescriptorBoundLifecycleCloudOperationDeclined !Text
  | DescriptorBoundLifecycleRecoveryEnteredCloudRuntime !Text
  | DescriptorBoundLifecycleOperationUnsupported
      !DescriptorBoundLifecycleUnsupported
  deriving stock (Eq, Show)

data DescriptorBoundLifecycleRoute
  = DescriptorBoundLifecycleRecoveryRoute
  | DescriptorBoundLifecycleCloudRoute
  | DescriptorBoundLifecycleUnsupportedRoute
      !DescriptorBoundLifecycleUnsupported
  deriving stock (Eq, Show)

data DescriptorBoundLifecycleOperationShape
  = DescriptorBoundLifecycleEstablishRecoveryPlane
  | DescriptorBoundLifecycleReadBackRecoveryPlane
  | DescriptorBoundLifecycleObserveRecoveryPlaneDisposition
  | DescriptorBoundLifecycleObserveRegisteredTarget
  | DescriptorBoundLifecycleObserveStackCheckpointPair
  | DescriptorBoundLifecycleReconcileStackCheckpointRestore
  | DescriptorBoundLifecycleReadBackStackCheckpointRecovery
  | DescriptorBoundLifecycleCommitAwsStackReaderBundle
  | DescriptorBoundLifecycleReadBackAwsStackReaderBundle
  | DescriptorBoundLifecycleCommitEksDrainIntent
  | DescriptorBoundLifecycleReadBackEksDrainIntent
  | DescriptorBoundLifecycleDrainEksKubernetesResources
  | DescriptorBoundLifecycleReadBackEksKubernetesDrain
  | DescriptorBoundLifecycleReconcileRegisteredTargetAbsent
  | DescriptorBoundLifecycleReadBackRegisteredTargetAbsent
  | DescriptorBoundLifecycleRetireStackCheckpointPair
  | DescriptorBoundLifecycleReadBackStackCheckpointRetirement
  | DescriptorBoundLifecycleAuditCascadeEscapes
  | DescriptorBoundLifecycleCommitCascadePreUninstallReport
  | DescriptorBoundLifecycleReadBackCascadePreUninstallReport
  | DescriptorBoundLifecycleUninstallCascadeLocalFoundation
  | DescriptorBoundLifecycleReadBackCascadeLocalAbsence
  | DescriptorBoundLifecycleCommitCascadeCompletion
  | DescriptorBoundLifecycleReadBackCascadeCompletion
  | DescriptorBoundLifecycleUninstallLocalOnlyFoundation
  | DescriptorBoundLifecycleReadBackLocalOnlyAbsence
  | DescriptorBoundLifecycleCommitLocalOnlyCompletion
  | DescriptorBoundLifecycleReadBackLocalOnlyCompletion
  | DescriptorBoundLifecycleCommitOrdinarySurfaceReport
  | DescriptorBoundLifecycleReadBackOrdinarySurfaceReport
  | DescriptorBoundLifecycleAuditTotalDecommissionEscapes
  | DescriptorBoundLifecycleObserveExternalDecommissionReceipt
  | DescriptorBoundLifecycleUninstallDecommissionLocalFoundation
  | DescriptorBoundLifecycleReadBackDecommissionLocalAbsence
  | DescriptorBoundLifecycleApplyDecommissionLocalDataDisposition
  | DescriptorBoundLifecycleReadBackDecommissionLocalDataDisposition
  | DescriptorBoundLifecycleCommitDecommissionTerminalReceipt
  | DescriptorBoundLifecycleReadBackDecommissionTerminalReceipt
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Total descriptor-bound lifecycle action. Recovery-plane operations use
-- the released closed host action; cloud operations use the released cloud
-- runtime behind the descriptor-aware Execution validator. Every other
-- operation enters the same validator and is then refused by its exact typed
-- unsupported classification.
descriptorBoundLifecycleNodeActionInternal
  :: CloudRuntime IO
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> DescriptorBoundCleanupNodeExecutionAction
descriptorBoundLifecycleNodeActionInternal cloudRuntime transport =
  descriptorBoundCleanupNodeAction $ \running _ compiled context plan ->
    case operationForPlan compiled plan of
      Left err -> pure (refusalOutcome err)
      Right operation -> case routeOperation operation of
        DescriptorBoundLifecycleRecoveryRoute ->
          recoveryAction running context plan
        DescriptorBoundLifecycleCloudRoute ->
          runClosedLifecycleEffects
            ( runCompiledTeardownNodeWithDescriptorContext
                running
                compiled
                context
                plan
            )
            cloudRuntime
        DescriptorBoundLifecycleUnsupportedRoute _ ->
          runClosedLifecycleEffects
            ( runCompiledTeardownNodeWithDescriptorContext
                running
                compiled
                context
                plan
            )
            cloudRuntime
 where
  recoveryAction =
    recoveryPlaneHostDescriptorBoundNodeActionInternal transport

operationForPlan
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> Either DescriptorBoundLifecycleRuntimeError (TeardownOperation surface)
operationForPlan compiled plan =
  case [ operation
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , nodeId == cleanupNodeId plan
       ] of
    [operation] -> Right operation
    [] -> Left DescriptorBoundLifecycleOperationMissing
    _ -> Left DescriptorBoundLifecycleOperationDuplicated

routeOperation
  :: TeardownOperation surface
  -> DescriptorBoundLifecycleRoute
routeOperation = routeOperationShape . operationShape

operationShape
  :: TeardownOperation surface
  -> DescriptorBoundLifecycleOperationShape
operationShape operation = case operation of
  EstablishRecoveryPlane _ -> DescriptorBoundLifecycleEstablishRecoveryPlane
  ReadBackRecoveryPlane _ -> DescriptorBoundLifecycleReadBackRecoveryPlane
  ObserveRecoveryPlaneDisposition _ ->
    DescriptorBoundLifecycleObserveRecoveryPlaneDisposition
  ObserveRegisteredTarget _ -> DescriptorBoundLifecycleObserveRegisteredTarget
  ObserveStackCheckpointPair _ ->
    DescriptorBoundLifecycleObserveStackCheckpointPair
  ReconcileStackCheckpointRestore _ ->
    DescriptorBoundLifecycleReconcileStackCheckpointRestore
  ReadBackStackCheckpointRecovery _ ->
    DescriptorBoundLifecycleReadBackStackCheckpointRecovery
  CommitAwsStackReaderBundle _ ->
    DescriptorBoundLifecycleCommitAwsStackReaderBundle
  ReadBackAwsStackReaderBundle _ ->
    DescriptorBoundLifecycleReadBackAwsStackReaderBundle
  CommitEksDrainIntent _ -> DescriptorBoundLifecycleCommitEksDrainIntent
  ReadBackEksDrainIntent _ -> DescriptorBoundLifecycleReadBackEksDrainIntent
  DrainEksKubernetesResources _ ->
    DescriptorBoundLifecycleDrainEksKubernetesResources
  ReadBackEksKubernetesDrain _ ->
    DescriptorBoundLifecycleReadBackEksKubernetesDrain
  ReconcileRegisteredTargetAbsent _ ->
    DescriptorBoundLifecycleReconcileRegisteredTargetAbsent
  ReadBackRegisteredTargetAbsent _ ->
    DescriptorBoundLifecycleReadBackRegisteredTargetAbsent
  RetireStackCheckpointPair _ ->
    DescriptorBoundLifecycleRetireStackCheckpointPair
  ReadBackStackCheckpointRetirement _ ->
    DescriptorBoundLifecycleReadBackStackCheckpointRetirement
  AuditCascadeEscapes -> DescriptorBoundLifecycleAuditCascadeEscapes
  CommitCascadePreUninstallReport ->
    DescriptorBoundLifecycleCommitCascadePreUninstallReport
  ReadBackCascadePreUninstallReport ->
    DescriptorBoundLifecycleReadBackCascadePreUninstallReport
  UninstallCascadeLocalFoundation ->
    DescriptorBoundLifecycleUninstallCascadeLocalFoundation
  ReadBackCascadeLocalAbsence ->
    DescriptorBoundLifecycleReadBackCascadeLocalAbsence
  CommitCascadeCompletion -> DescriptorBoundLifecycleCommitCascadeCompletion
  ReadBackCascadeCompletion ->
    DescriptorBoundLifecycleReadBackCascadeCompletion
  UninstallLocalOnlyFoundation ->
    DescriptorBoundLifecycleUninstallLocalOnlyFoundation
  ReadBackLocalOnlyAbsence ->
    DescriptorBoundLifecycleReadBackLocalOnlyAbsence
  CommitLocalOnlyCompletion -> DescriptorBoundLifecycleCommitLocalOnlyCompletion
  ReadBackLocalOnlyCompletion ->
    DescriptorBoundLifecycleReadBackLocalOnlyCompletion
  CommitOrdinarySurfaceReport ->
    DescriptorBoundLifecycleCommitOrdinarySurfaceReport
  ReadBackOrdinarySurfaceReport ->
    DescriptorBoundLifecycleReadBackOrdinarySurfaceReport
  AuditTotalDecommissionEscapes ->
    DescriptorBoundLifecycleAuditTotalDecommissionEscapes
  ObserveExternalDecommissionReceipt ->
    DescriptorBoundLifecycleObserveExternalDecommissionReceipt
  UninstallDecommissionLocalFoundation ->
    DescriptorBoundLifecycleUninstallDecommissionLocalFoundation
  ReadBackDecommissionLocalAbsence ->
    DescriptorBoundLifecycleReadBackDecommissionLocalAbsence
  ApplyDecommissionLocalDataDisposition ->
    DescriptorBoundLifecycleApplyDecommissionLocalDataDisposition
  ReadBackDecommissionLocalDataDisposition ->
    DescriptorBoundLifecycleReadBackDecommissionLocalDataDisposition
  CommitDecommissionTerminalReceipt ->
    DescriptorBoundLifecycleCommitDecommissionTerminalReceipt
  ReadBackDecommissionTerminalReceipt ->
    DescriptorBoundLifecycleReadBackDecommissionTerminalReceipt

routeOperationShape
  :: DescriptorBoundLifecycleOperationShape
  -> DescriptorBoundLifecycleRoute
routeOperationShape shape = case shape of
  DescriptorBoundLifecycleEstablishRecoveryPlane ->
    DescriptorBoundLifecycleRecoveryRoute
  DescriptorBoundLifecycleReadBackRecoveryPlane ->
    DescriptorBoundLifecycleRecoveryRoute
  DescriptorBoundLifecycleObserveRecoveryPlaneDisposition ->
    DescriptorBoundLifecycleRecoveryRoute
  DescriptorBoundLifecycleObserveRegisteredTarget ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleObserveStackCheckpointPair ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleReconcileStackCheckpointRestore ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleReadBackStackCheckpointRecovery ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleCommitAwsStackReaderBundle ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleReadBackAwsStackReaderBundle ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleCommitEksDrainIntent ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleReadBackEksDrainIntent ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleDrainEksKubernetesResources ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleReadBackEksKubernetesDrain ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleReconcileRegisteredTargetAbsent ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleReadBackRegisteredTargetAbsent ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleRetireStackCheckpointPair ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleReadBackStackCheckpointRetirement ->
    DescriptorBoundLifecycleCloudRoute
  DescriptorBoundLifecycleAuditCascadeEscapes ->
    unsupported DescriptorBoundLifecycleCascadeAudit
  DescriptorBoundLifecycleCommitCascadePreUninstallReport ->
    unsupported DescriptorBoundLifecycleCascadePreUninstallReportCommit
  DescriptorBoundLifecycleReadBackCascadePreUninstallReport ->
    unsupported DescriptorBoundLifecycleCascadePreUninstallReportReadBack
  DescriptorBoundLifecycleUninstallCascadeLocalFoundation ->
    unsupported DescriptorBoundLifecycleCascadeLocalFoundationUninstall
  DescriptorBoundLifecycleReadBackCascadeLocalAbsence ->
    unsupported DescriptorBoundLifecycleCascadeLocalAbsenceReadBack
  DescriptorBoundLifecycleCommitCascadeCompletion ->
    unsupported DescriptorBoundLifecycleCascadeCompletionCommit
  DescriptorBoundLifecycleReadBackCascadeCompletion ->
    unsupported DescriptorBoundLifecycleCascadeCompletionReadBack
  DescriptorBoundLifecycleUninstallLocalOnlyFoundation ->
    unsupported DescriptorBoundLifecycleLocalOnlyFoundationUninstall
  DescriptorBoundLifecycleReadBackLocalOnlyAbsence ->
    unsupported DescriptorBoundLifecycleLocalOnlyAbsenceReadBack
  DescriptorBoundLifecycleCommitLocalOnlyCompletion ->
    unsupported DescriptorBoundLifecycleLocalOnlyCompletionCommit
  DescriptorBoundLifecycleReadBackLocalOnlyCompletion ->
    unsupported DescriptorBoundLifecycleLocalOnlyCompletionReadBack
  DescriptorBoundLifecycleCommitOrdinarySurfaceReport ->
    unsupported DescriptorBoundLifecycleOrdinarySurfaceReportCommit
  DescriptorBoundLifecycleReadBackOrdinarySurfaceReport ->
    unsupported DescriptorBoundLifecycleOrdinarySurfaceReportReadBack
  DescriptorBoundLifecycleAuditTotalDecommissionEscapes ->
    unsupported DescriptorBoundLifecycleTotalDecommissionAudit
  DescriptorBoundLifecycleObserveExternalDecommissionReceipt ->
    unsupported DescriptorBoundLifecycleExternalDecommissionReceiptObserve
  DescriptorBoundLifecycleUninstallDecommissionLocalFoundation ->
    unsupported DescriptorBoundLifecycleDecommissionLocalFoundationUninstall
  DescriptorBoundLifecycleReadBackDecommissionLocalAbsence ->
    unsupported DescriptorBoundLifecycleDecommissionLocalAbsenceReadBack
  DescriptorBoundLifecycleApplyDecommissionLocalDataDisposition ->
    unsupported DescriptorBoundLifecycleDecommissionLocalDataDispositionApply
  DescriptorBoundLifecycleReadBackDecommissionLocalDataDisposition ->
    unsupported DescriptorBoundLifecycleDecommissionLocalDataDispositionReadBack
  DescriptorBoundLifecycleCommitDecommissionTerminalReceipt ->
    unsupported DescriptorBoundLifecycleDecommissionTerminalReceiptCommit
  DescriptorBoundLifecycleReadBackDecommissionTerminalReceipt ->
    unsupported DescriptorBoundLifecycleDecommissionTerminalReceiptReadBack
 where
  unsupported = DescriptorBoundLifecycleUnsupportedRoute

-- | Minimal Reader-like effect carrier. Its environment is exactly the
-- opaque CloudRuntime; there is no injected operation callback.
newtype ClosedLifecycleEffects value = ClosedLifecycleEffects
  { runClosedLifecycleEffects :: CloudRuntime IO -> IO value
  }

instance Functor ClosedLifecycleEffects where
  fmap transform action =
    ClosedLifecycleEffects $ \runtime ->
      fmap transform (runClosedLifecycleEffects action runtime)

instance Applicative ClosedLifecycleEffects where
  pure value = ClosedLifecycleEffects $ \_ -> pure value
  function <*> value =
    ClosedLifecycleEffects $ \runtime -> do
      transform <- runClosedLifecycleEffects function runtime
      input <- runClosedLifecycleEffects value runtime
      pure (transform input)

instance Monad ClosedLifecycleEffects where
  action >>= next =
    ClosedLifecycleEffects $ \runtime -> do
      value <- runClosedLifecycleEffects action runtime
      runClosedLifecycleEffects (next value) runtime

instance LifecycleTeardownEffects ClosedLifecycleEffects where
  executeLifecycleTeardownOperation context operation =
    ClosedLifecycleEffects $ \runtime -> case routeOperation operation of
      DescriptorBoundLifecycleCloudRoute -> do
        result <- executeCloudOperation runtime context operation
        pure
          ( maybe
              ( TeardownNodeRefused
                  ( renderRuntimeError
                      ( DescriptorBoundLifecycleCloudOperationDeclined
                          (teardownOperationTag operation)
                      )
                  )
              )
              id
              result
          )
      DescriptorBoundLifecycleRecoveryRoute ->
        pure
          ( TeardownNodeRefused
              ( renderRuntimeError
                  ( DescriptorBoundLifecycleRecoveryEnteredCloudRuntime
                      (teardownOperationTag operation)
                  )
              )
          )
      DescriptorBoundLifecycleUnsupportedRoute unsupported ->
        pure
          ( TeardownNodeRefused
              ( renderRuntimeError
                  (DescriptorBoundLifecycleOperationUnsupported unsupported)
              )
          )

refusalOutcome
  :: DescriptorBoundLifecycleRuntimeError
  -> CleanupNodeOutcome
refusalOutcome = CleanupNodeFailed . renderRuntimeError

renderRuntimeError :: DescriptorBoundLifecycleRuntimeError -> Text
renderRuntimeError = Text.take 1024 . Text.pack . show

-- | Fixed, non-authorizing diagnostics. No runtime, transport, descriptor
-- handle, operation value, or executable action escapes the public facade.
data DescriptorBoundLifecycleRuntimeRegression
  = DescriptorBoundLifecycleRuntimeRegression
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool

fixedDescriptorBoundLifecycleRuntimeRegression
  :: IO DescriptorBoundLifecycleRuntimeRegression
fixedDescriptorBoundLifecycleRuntimeRegression = do
  exercised <- exerciseRegressionDispatcher
  let inventory = regressionOperationShapeInventory
      allShapes = Set.fromList [minBound .. maxBound]
      cloudExact =
        either
          (const False)
          (\shapes -> shapes == allShapes && routeCount isCloudRoute shapes == 14)
          inventory
      recoveryExact =
        either
          (const False)
          (\shapes -> shapes == allShapes && routeCount isRecoveryRoute shapes == 3)
          inventory
          && recoveryPlaneHostRuntimeClosedOperationsExact
            fixedRecoveryPlaneHostRuntimeRegression
      unsupportedExact =
        either
          (const False)
          (\shapes -> shapes == allShapes && routeCount isUnsupportedRoute shapes == 21)
          inventory
      cloudExecuted = either (const False) fst exercised
      unsupportedExecuted = either (const False) snd exercised
      closed = cloudExecuted && unsupportedExecuted
      descriptorBound = closed && cloudExact && unsupportedExact
      opaque = descriptorBound && recoveryExact
  pure
    ( DescriptorBoundLifecycleRuntimeRegression
        cloudExact
        recoveryExact
        unsupportedExact
        unsupportedExecuted
        closed
        descriptorBound
        opaque
    )

descriptorBoundLifecycleRuntimeCloudOperationsExact
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeCloudOperationsExact
  (DescriptorBoundLifecycleRuntimeRegression exact _ _ _ _ _ _) = exact

descriptorBoundLifecycleRuntimeRecoveryOperationsExact
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeRecoveryOperationsExact
  (DescriptorBoundLifecycleRuntimeRegression _ exact _ _ _ _ _) = exact

descriptorBoundLifecycleRuntimeUnsupportedOperationsExact
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeUnsupportedOperationsExact
  (DescriptorBoundLifecycleRuntimeRegression _ _ exact _ _ _ _) = exact

descriptorBoundLifecycleRuntimeUnsupportedIsRefusal
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeUnsupportedIsRefusal
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ exact _ _ _) = exact

descriptorBoundLifecycleRuntimeNoCallerContinuation
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeNoCallerContinuation
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ _ exact _ _) = exact

descriptorBoundLifecycleRuntimeDescriptorBoundOnly
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeDescriptorBoundOnly
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ _ _ exact _) = exact

descriptorBoundLifecycleRuntimeOpacityClosed
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeOpacityClosed
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ _ _ _ exact) = exact

routeCount
  :: (DescriptorBoundLifecycleRoute -> Bool)
  -> Set.Set DescriptorBoundLifecycleOperationShape
  -> Int
routeCount belongs =
  length . filter (belongs . routeOperationShape) . Set.toList

isCloudRoute :: DescriptorBoundLifecycleRoute -> Bool
isCloudRoute route = case route of
  DescriptorBoundLifecycleCloudRoute -> True
  _ -> False

isRecoveryRoute :: DescriptorBoundLifecycleRoute -> Bool
isRecoveryRoute route = case route of
  DescriptorBoundLifecycleRecoveryRoute -> True
  _ -> False

isUnsupportedRoute :: DescriptorBoundLifecycleRoute -> Bool
isUnsupportedRoute route = case route of
  DescriptorBoundLifecycleUnsupportedRoute _ -> True
  _ -> False

regressionOperationShapeInventory
  :: Either Text (Set.Set DescriptorBoundLifecycleOperationShape)
regressionOperationShapeInventory = do
  localOnly <- shapesFor "dispatcher-local-only" LocalOnlySurface Nothing
  cascade <- shapesFor "dispatcher-cascade" CascadeSurface (Just regressionAwsScope)
  explicitPerRun <-
    shapesFor
      "dispatcher-explicit-per-run"
      ExplicitPerRunSurface
      (Just regressionAwsScope)
  operational <-
    shapesFor
      "dispatcher-operational"
      OperationalTeardownSurface
      (Just regressionAwsScope)
  explicitLongLived <-
    shapesFor
      "dispatcher-explicit-long-lived"
      ExplicitLongLivedSurface
      (Just regressionAwsScope)
  totalDecommission <-
    shapesFor
      "dispatcher-total-decommission"
      TotalDecommissionSurface
      (Just regressionAwsScope)
  pure
    ( Set.unions
        [ localOnly
        , cascade
        , explicitPerRun
        , operational
        , explicitLongLived
        , totalDecommission
        ]
    )

shapesFor
  :: Text
  -> CleanupSurfaceWitness surface
  -> Maybe AwsScope
  -> Either Text (Set.Set DescriptorBoundLifecycleOperationShape)
shapesFor rawRunId witness maybeAwsScope = do
  runId <- firstShow (mkCleanupRunId rawRunId)
  compiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          runId
          regressionFoundation
          maybeAwsScope
          witness
      )
  pure
    ( Set.fromList
        [ operationShape operation
        | (_, operation) <- compiledDesiredAbsenceOperations compiled
        ]
    )

exerciseRegressionDispatcher :: IO (Either Text (Bool, Bool))
exerciseRegressionDispatcher =
  case regressionDescriptorFixture of
    Left err -> pure (Left err)
    Right (compiled, initialRun, descriptor) -> do
      providerCalls <- newIORef (0 :: Int)
      case regressionCloudRuntime providerCalls of
        Left err -> pure (Left err)
        Right cloudRuntime -> do
          cloud <-
            executeRegressionOperation
              cloudRuntime
              providerCalls
              compiled
              initialRun
              descriptor
              "observe/aws-test"
          unsupported <-
            executeRegressionOperation
              cloudRuntime
              providerCalls
              compiled
              initialRun
              descriptor
              "audit-cascade-escapes"
          pure $ do
            (cloudOutcome, cloudCalls) <- cloud
            (unsupportedOutcome, unsupportedCalls) <- unsupported
            let cloudExact =
                  cloudCalls == 1
                    && isFailedOutcome cloudOutcome
                unsupportedExact =
                  unsupportedCalls == 0
                    && case unsupportedOutcome of
                      CleanupNodeFailed detail ->
                        "DescriptorBoundLifecycleCascadeAudit"
                          `Text.isInfixOf` detail
                      _ -> False
            pure (cloudExact, unsupportedExact)

executeRegressionOperation
  :: CloudRuntime IO
  -> IORef Int
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> CleanupRun
  -> CleanupProgramDescriptor
  -> Text
  -> IO (Either Text (CleanupNodeOutcome, Int))
executeRegressionOperation cloudRuntime providerCalls compiled initialRun descriptor operationTag =
  case runningAtRegressionOperation operationTag compiled initialRun of
    Left err -> pure (Left err)
    Right (plan, running) -> do
      observed <- observeRegressionHandle descriptor running
      case observed of
        Left err -> pure (Left err)
        Right (bound, transport) ->
          case descriptorBoundCleanupNodeExecutionContext bound plan of
            Left err -> pure (Left err)
            Right context -> do
              atomicModifyIORef' providerCalls (const (0, ()))
              outcome <-
                descriptorBoundLifecycleNodeActionInternal
                  cloudRuntime
                  transport
                  bound
                  context
                  plan
              calls <- readIORef providerCalls
              pure (Right (outcome, calls))

isFailedOutcome :: CleanupNodeOutcome -> Bool
isFailedOutcome outcome = case outcome of
  CleanupNodeFailed _ -> True
  _ -> False

regressionDescriptorFixture
  :: Either
       Text
       ( CompiledDesiredAbsenceProgram 'Cascade
       , CleanupRun
       , CleanupProgramDescriptor
       )
regressionDescriptorFixture = do
  runId <- firstShow (mkCleanupRunId "descriptor-bound-dispatcher")
  owner <- regressionOwnerValue
  compiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          runId
          regressionFoundation
          (Just regressionAwsScope)
          CascadeSurface
      )
  initialRun <-
    firstShow
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          owner
          1
          1000
      )
  descriptor <- firstShow (captureCleanupProgramDescriptor compiled initialRun)
  pure (compiled, initialRun, descriptor)

runningAtRegressionOperation
  :: Text
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> Either Text (CleanupNodePlan, CleanupRun)
runningAtRegressionOperation expectedOperation compiled initialRun = do
  owner <- regressionOwnerValue
  withPrimary <-
    firstShow
      ( recordPrimaryOutcome
          owner
          (cleanupLeaseFence (cleanupRunLease initialRun))
          CleanupPrimarySucceeded
          initialRun
      )
  drive withPrimary (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled))
 where
  drive _ [] = Left ("compiled program lacks operation " <> expectedOperation)
  drive run (plan : remaining) = do
    operation <- operationTagForPlan compiled plan
    attempt <-
      firstShow
        ( mkCleanupAttemptId
            ("dispatcher/" <> cleanupNodeIdText (cleanupNodeId plan))
        )
    running <-
      firstShow
        ( beginCleanupNode
            owner
            (cleanupLeaseFence (cleanupRunLease run))
            (cleanupNodeId plan)
            attempt
            run
        )
    if operation == expectedOperation
      then pure (plan, running)
      else do
        completed <-
          firstShow
            ( completeCleanupNode
                owner
                (cleanupLeaseFence (cleanupRunLease running))
                (cleanupNodeId plan)
                attempt
                CleanupNodeSucceeded
                running
            )
        drive completed remaining

operationTagForPlan
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> Either Text Text
operationTagForPlan compiled plan =
  case [ teardownOperationTag operation
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , nodeId == cleanupNodeId plan
       ] of
    [operation] -> Right operation
    [] -> Left "compiled program has no semantic operation for cleanup node"
    _ -> Left "compiled program has duplicate semantic operations for cleanup node"

observeRegressionHandle
  :: CleanupProgramDescriptor
  -> CleanupRun
  -> IO
       ( Either
           Text
           ( DescriptorBoundCleanupRun
           , AuthenticatedClientTransport 'LifecycleAuthorityRuntime
           )
       )
observeRegressionHandle descriptor running =
  case encodeCleanupRun cleanupRunMaximumBytes running of
    Left err -> pure (Left (Text.pack (show err)))
    Right runBytes -> do
      let runId = cleanupRunIdText (cleanupProgramDescriptorRunId descriptor)
          descriptorDigest = cleanupProgramDescriptorDigest descriptor
          responses =
            [ CleanupRunDescriptorPresent
                runId
                (cleanupDigestText descriptorDigest)
                runBytes
            , CleanupRunDescriptorProgramPresent
                runId
                (cleanupDigestText descriptorDigest)
                (cleanupProgramDescriptorBytes descriptor)
            ]
      queuedResponses <- newIORef responses
      case regressionDescriptorClient queuedResponses of
        Left err -> pure (Left err)
        Right (client, transport) -> do
          observed <-
            observeDescriptorBoundCleanupRun
              client
              (cleanupProgramDescriptorRunId descriptor)
          remaining <- readIORef queuedResponses
          pure $ do
            unless (null remaining) (Left "descriptor client left unread responses")
            bound <- firstShow observed
            pure (bound, transport)

regressionDescriptorClient
  :: IORef [CleanupRunDescriptorResponse]
  -> Either
       Text
       ( DescriptorBoundCleanupRunClient IO
       , AuthenticatedClientTransport 'LifecycleAuthorityRuntime
       )
regressionDescriptorClient queuedResponses = do
  endpoint <- firstShow (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    firstShow
      ( controlPlaneClientWithTransport
          cleanupRunMaximumBytes
          endpoint
          ( \_ _ _ _ -> do
              next <-
                atomicModifyIORef' queuedResponses $ \queued -> case queued of
                  [] -> ([], Nothing)
                  response : remaining -> (remaining, Just response)
              pure $ case next of
                Nothing -> Right (500, ByteString.empty)
                Just response ->
                  let result = CleanupRunEndpointDescriptorBound response
                   in Right
                        ( replyStatusCode (cleanupRunEndpointStatus result)
                        , cleanupRunEndpointBody result
                        )
          )
      )
  bounds <-
    firstShow
      ( mkAuthenticatedTransportBounds
          cleanupRunMaximumBytes
          256
          (cleanupRunMaximumBytes - 1024)
      )
  providers <- regressionClientProviders
  let transport = mkAuthenticatedClientTransport bounds providers rawClient
  pure (descriptorBoundCleanupRunClient transport, transport)

regressionClientProviders
  :: Either Text (AuthenticatedClientProviders IO)
regressionClientProviders = do
  generation <- firstShow (mkSigningKeyGeneration 1)
  signer <-
    firstShow
      ( mkRequestSigner
          CallerOperatorCli
          generation
          (ByteString.pack [0 .. 31])
      )
  nonce <- firstShow (mkRequestNonce (ByteString.pack [32 .. 47]))
  scope <- firstShow (mkAuthorityScope "cluster-a")
  pure
    AuthenticatedClientProviders
      { provideAuthenticatedClientSigner =
          pure (Right (localRequestSigningCapability signer))
      , provideAuthenticatedClientScope = pure (Right scope)
      , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
      , provideAuthenticatedClientDeadline =
          pure (Right (authorityTimeFromMicros 2000))
      , provideAuthenticatedClientNonce = pure (Right nonce)
      }

regressionCloudRuntime :: IORef Int -> Either Text (CloudRuntime IO)
regressionCloudRuntime providerCalls = do
  authorities <- regressionCheckpointAuthorities
  let registered = regressionRegisteredInterpreter providerCalls
      checkpoint =
        AwsCheckpointInterpreter
          { awsCheckpointOperationAuthority = regressionAuthorityOperationClient
          , awsCheckpointAuthorities = authorities
          , awsCheckpointRegisteredTargetInterpreter = registered
          }
      stackReader =
        AwsStackReaderInterpreter
          { awsStackReaderClient =
              nonAuthorizingAwsStackReaderDiagnosticClient
                (AwsStackReaderClientRemoteRefused "fixed dispatcher refusal")
          , awsStackReaderInputReaders =
              mkAwsStackReaderInputReaders
                (\_ _ -> pure (Left "fixed checkpoint reader refusal"))
                (\_ _ -> pure (Left "fixed manifest reader refusal"))
                (\_ _ _ -> pure (Left "fixed Provider reader refusal"))
          }
      eksExecutor = regressionEksExecutor registered
  pure (mkCloudRuntime registered checkpoint stackReader eksExecutor)

regressionRegisteredInterpreter
  :: IORef Int
  -> AwsRegisteredTargetInterpreter IO
regressionRegisteredInterpreter providerCalls =
  AwsRegisteredTargetInterpreter
    { awsRegisteredTargetProviderBoundary =
        TeardownProviderBoundary $ \_ _ -> do
          modifyIORef' providerCalls (+ 1)
          pure (TeardownProviderRefused "fixed dispatcher Provider refusal")
    , awsRegisteredTargetReadStackDecisionInputs =
        \_ _ _ -> pure (Left "fixed decision reader refusal")
    , awsRegisteredTargetReadStackProviderBinding =
        \_ _ _ -> pure (Left "fixed Provider-binding reader refusal")
    , awsRegisteredTargetPresentEksDestroyBoundary =
        mkAwsEksPresentDestroyBoundary $ \_ _ _ ->
          pure (Left AwsRegisteredTargetEksDrainProofRequired)
    }

regressionAuthorityOperationClient :: AuthorityOperationClient IO
regressionAuthorityOperationClient =
  AuthorityOperationClient
    { submitAuthorityOperation = \_ _ ->
        pure (Left (AuthorityOperationRemoteRefused 409 "fixed refusal"))
    , observeAuthorityOperation = \_ ->
        pure (Left (AuthorityOperationRemoteRefused 409 "fixed refusal"))
    }

regressionCheckpointAuthorities
  :: Either Text (AwsCheckpointAuthorities IO)
regressionCheckpointAuthorities = do
  eks <- refusedCheckpointAuthority "aws-eks"
  subzone <- refusedCheckpointAuthority "aws-eks-subzone"
  testStack <- refusedCheckpointAuthority "aws-test"
  firstShow (mkAwsCheckpointAuthorities eks subzone testStack)

refusedCheckpointAuthority
  :: Text
  -> Either Text (PulumiCheckpointAuthority IO)
refusedCheckpointAuthority name = do
  registration <- firstShow (registeredPulumiCheckpointByName name)
  pure
    PulumiCheckpointAuthority
      { pulumiCheckpointAuthorityRegistration = registration
      , observePulumiCheckpoint = checkpointRefusal
      , observePulumiCheckpointPair = checkpointRefusal
      , publishPulumiCheckpoint = \_ _ _ -> checkpointRefusal
      , retirePulumiCheckpoint = \_ _ -> checkpointRefusal
      , restorePulumiCheckpointPrimary = \_ _ _ -> checkpointRefusal
      , readBackPulumiCheckpointRestore = \_ -> checkpointRefusal
      , attemptPulumiCheckpointRetirement = \_ _ _ -> checkpointRefusal
      , readBackPulumiCheckpointRetirement = \_ -> checkpointRefusal
      }

checkpointRefusal
  :: IO (Either PulumiCheckpointClientError value)
checkpointRefusal = pure (Left (PulumiCheckpointRemoteRefused "fixed refusal"))

regressionEksExecutor
  :: AwsRegisteredTargetInterpreter IO
  -> EksTeardownExecutor IO
regressionEksExecutor registered =
  EksTeardownExecutor
    { eksTeardownRegisteredTargetInterpreter = registered
    , eksTeardownDrainInterpreter =
        mkEksDrainInterpreter
          (pure 1000)
          ( \_ ->
              pure
                ( EksDrainSessionAcquisitionUnobservable
                    (ObservationFailure "fixed session refusal")
                )
          )
          ( mkEksDrainClientBoundary $ \_ consume ->
              consume
                ( Left
                    ( EksDrainClientAccessUnobservable
                        (ObservationFailure "fixed Kubernetes refusal")
                    )
                )
          )
    , eksTeardownCommitSelectionBoundary =
        mkEksDrainCommitSelectionBoundary $ \_ _ consume ->
          consume
            ( Left
                ( EksDrainClientAccessRefused
                    (ObservationFailure "fixed commit selection refusal")
                )
            )
    , eksTeardownAttemptBoundary =
        mkEksDrainAttemptBoundary $ \_ _ consume ->
          consume
            ( Left
                ( EksDrainClientAccessRefused
                    (ObservationFailure "fixed attempt refusal")
                )
            )
    , eksTeardownIntentClient = regressionEksIntentClient
    , eksTeardownReceiptClient = regressionEksReceiptClient
    , eksTeardownSelectionParameters =
        \_ -> pure (Left "fixed selection parameters refusal")
    }

regressionEksIntentClient :: EksDrainIntentClient IO
regressionEksIntentClient =
  EksDrainIntentClient
    { commitAndReadBackEksDrainIntent = refused
    , readBackCommittedEksDrainIntent = refused
    , recoverCommittedEksDrainIntent = refused
    }
 where
  refused _ = pure (Left (EksDrainIntentClientRemoteRefused "fixed refusal"))

regressionEksReceiptClient :: EksDrainReadBackReceiptClient IO
regressionEksReceiptClient =
  EksDrainReadBackReceiptClient
    { commitAndReadBackEksDrainReceipt = \_ _ _ -> refused
    , readBackEksDrainReceipt = \_ -> refused
    , commitCanonicalEksDrainReceiptFromIntentIdentity = \_ _ -> refused
    , recoverEksDrainReceiptFromIntentIdentity = \_ -> refused
    }
 where
  refused =
    pure (Left (EksDrainReadBackReceiptClientRemoteRefused "fixed refusal"))

regressionOwnerValue :: Either Text CleanupOwnerId
regressionOwnerValue =
  firstShow (mkCleanupOwnerId "descriptor-bound-dispatcher-authority")

regressionFoundation :: LinuxRke2FoundationId
regressionFoundation = LinuxRke2FoundationId "foundation/home"

regressionAwsScope :: AwsScope
regressionAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)
