{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Package-private total dispatcher for descriptor-bound lifecycle work.
-- The constructor accepts only the two closed production runtimes. It has no
-- caller-supplied continuation for operations those runtimes do not own.
module Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal
  ( DescriptorBoundLifecycleRuntimeError (..)
  , DescriptorBoundLifecycleUnsupported (..)
  , descriptorBoundLifecycleNodeActionInternal
  , descriptorBoundOrdinaryLifecycleNodeActionInternal
  , DescriptorBoundLifecycleRuntimeRegression
  , fixedDescriptorBoundLifecycleRuntimeRegression
  , descriptorBoundLifecycleRuntimeCloudOperationsExact
  , descriptorBoundLifecycleRuntimeRecoveryOperationsExact
  , descriptorBoundLifecycleRuntimeCascadePreUninstallOperationsExact
  , descriptorBoundLifecycleRuntimeCascadeHostOperationsExact
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
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws.Region (canonicalRegressionAwsRegion)
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
import Prodbox.ControlPlane.CascadeHostRuntime.Internal
  ( CascadeHostRuntime
  , cascadeHostDescriptorBoundNodeActionInternal
  , cascadeHostRuntimeClosedOperationsExact
  , cascadeHostRuntimePhasesDistinct
  , fixedCascadeHostRuntimeRegression
  , mkCascadeHostRuntime
  )
import Prodbox.ControlPlane.CascadePreUninstallRuntime.Internal
  ( CascadePreUninstallRuntime
  , cascadePreUninstallDescriptorBoundNodeActionInternal
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient (..)
  , descriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunNodeStates
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
  ( mkAuthorityScope
  )
import Prodbox.ControlPlane.EksDrainIntentClient
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import Prodbox.ControlPlane.PulumiCheckpointClient
  ( PulumiCheckpointAuthority (..)
  , PulumiCheckpointClientError (..)
  )
import Prodbox.ControlPlane.RecoveryPlaneHostRuntime.Internal
  ( fixedRecoveryPlaneHostRuntimeRegression
  , recoveryPlaneHostDescriptorBoundNodeActionInternal
  , recoveryPlaneHostRuntimeClosedOperationsExact
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.Http.ReplyStatus
  ( ReplyStatus (ReplyInternalError)
  , replyStatusCode
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupNodeState (..)
  , CleanupOwnerId
  , CleanupPrimaryOutcome (CleanupPrimarySucceeded)
  , CleanupRun
  , beginCleanupNode
  , cleanupDigestText
  , cleanupGraphDigest
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
import Prodbox.Lifecycle.HostCleanupIntent (mkHostCleanupIntentStore)
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupEffectOutcome (HostCleanupEffectRefused)
  , HostCleanupRunnerEffects (..)
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderRevision
  , ProviderStackConfig
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  )
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
  ( DurableReceiptKind (OrdinarySurfaceReportReceipt)
  , DurableReceiptObservation (..)
  , DurableReceiptObservationResult (..)
  , LifecycleTeardownEffects (..)
  , TeardownMutationResult (TeardownMutationApplied)
  , TeardownNodeResult (..)
  , runCompiledTeardownNodeWithDescriptorContext
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceOperations
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (Cascade)
  , CleanupSurfaceWitness (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , ObservationFailure (..)
  , RegisteredResourceKey (..)
  )
import Prodbox.Lifecycle.Teardown.Program
  ( TeardownOperation (..)
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime)
  )
import System.IO.Temp (withSystemTempDirectory)

-- | Every operation not owned by either released runtime has a distinct
-- refusal classification. Appending a lifecycle operation requires extending
-- the exhaustive classifier below before this module compiles warning-free.
data DescriptorBoundLifecycleUnsupported
  = DescriptorBoundLifecycleLocalOnlyFoundationUninstall
  | DescriptorBoundLifecycleLocalOnlyAbsenceReadBack
  | DescriptorBoundLifecycleLocalOnlyCompletionCommit
  | DescriptorBoundLifecycleLocalOnlyCompletionReadBack
  | DescriptorBoundLifecycleOrdinarySurfaceReportCommit
  | DescriptorBoundLifecycleOrdinarySurfaceReportReadBack
  | DescriptorBoundLifecycleOperationalCredentialRevoke
  | DescriptorBoundLifecycleOperationalCredentialRevocationReadBack
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
  | DescriptorBoundLifecycleCascadeHostEnteredCloudRuntime !Text
  | DescriptorBoundLifecycleCascadeHostRuntimeUnavailable !Text
  | DescriptorBoundLifecycleCascadePreUninstallEnteredCloudRuntime !Text
  | DescriptorBoundLifecycleCascadePreUninstallRuntimeUnavailable !Text
  | DescriptorBoundLifecycleOrdinaryReportEnteredCloudRuntime !Text
  | DescriptorBoundLifecycleOperationUnsupported
      !DescriptorBoundLifecycleUnsupported
  deriving stock (Eq, Show)

data DescriptorBoundLifecycleRoute
  = DescriptorBoundLifecycleRecoveryRoute
  | DescriptorBoundLifecycleCascadePreUninstallRoute
  | DescriptorBoundLifecycleCascadeHostRoute
  | DescriptorBoundLifecycleOrdinaryReportRoute
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
  | DescriptorBoundLifecycleRevokeOperationalCredential
  | DescriptorBoundLifecycleReadBackOperationalCredentialRevocation
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
-- the released closed host action; cascade Stage-C operations use the closed
-- pre-uninstall runtime; cloud operations use the released cloud runtime
-- behind the descriptor-aware Execution validator. Every other operation
-- enters the same validator and is then refused by its exact typed unsupported
-- classification.
descriptorBoundLifecycleNodeActionInternal
  :: CloudRuntime IO
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> CascadePreUninstallRuntime
  -> CascadeHostRuntime
  -> DescriptorBoundCleanupNodeExecutionAction
descriptorBoundLifecycleNodeActionInternal cloudRuntime transport cascadePreUninstall cascadeHost =
  descriptorBoundCleanupNodeAction
    ( dispatchDescriptorBoundLifecycleNode
        cloudRuntime
        transport
        (Just cascadePreUninstall)
        (Just cascadeHost)
    )

-- | The same total dispatcher for an ordinary cleanup surface.  No cascade
-- host runtime can be supplied: an explicit per-run program has no operation
-- capable of uninstalling the retained local foundation.
descriptorBoundOrdinaryLifecycleNodeActionInternal
  :: CloudRuntime IO
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> DescriptorBoundCleanupNodeExecutionAction
descriptorBoundOrdinaryLifecycleNodeActionInternal cloudRuntime transport =
  descriptorBoundCleanupNodeAction
    (dispatchDescriptorBoundLifecycleNode cloudRuntime transport Nothing Nothing)

dispatchDescriptorBoundLifecycleNode
  :: CloudRuntime IO
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> Maybe CascadePreUninstallRuntime
  -> Maybe CascadeHostRuntime
  -> DescriptorBoundCleanupRun
  -> CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
dispatchDescriptorBoundLifecycleNode
  cloudRuntime
  transport
  cascadePreUninstall
  cascadeHost
  running
  _
  compiled
  context
  plan =
    case operationForPlan compiled plan of
      Left err -> pure (refusalOutcome err)
      Right operation -> case routeOperation operation of
        DescriptorBoundLifecycleRecoveryRoute ->
          recoveryPlaneHostDescriptorBoundNodeActionInternal
            transport
            running
            context
            plan
        DescriptorBoundLifecycleCascadePreUninstallRoute ->
          case cascadePreUninstall of
            Nothing ->
              pure
                ( refusalOutcome
                    ( DescriptorBoundLifecycleCascadePreUninstallRuntimeUnavailable
                        (teardownOperationTag operation)
                    )
                )
            Just runtime ->
              cascadePreUninstallDescriptorBoundNodeActionInternal
                runtime
                running
                context
                plan
        DescriptorBoundLifecycleCascadeHostRoute ->
          case cascadeHost of
            Nothing ->
              pure
                ( refusalOutcome
                    ( DescriptorBoundLifecycleCascadeHostRuntimeUnavailable
                        (teardownOperationTag operation)
                    )
                )
            Just runtime ->
              cascadeHostDescriptorBoundNodeActionInternal
                runtime
                running
                context
                plan
        DescriptorBoundLifecycleOrdinaryReportRoute ->
          runOrdinaryReportAction running compiled context plan
        DescriptorBoundLifecycleCloudRoute -> runCloudAction
        DescriptorBoundLifecycleUnsupportedRoute _ -> runCloudAction
   where
    runCloudAction =
      runClosedLifecycleEffects
        ( runCompiledTeardownNodeWithDescriptorContext
            running
            compiled
            context
            plan
        )
        cloudRuntime

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
  RevokeOperationalCredential _ ->
    DescriptorBoundLifecycleRevokeOperationalCredential
  ReadBackOperationalCredentialRevocation _ ->
    DescriptorBoundLifecycleReadBackOperationalCredentialRevocation
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
    DescriptorBoundLifecycleCascadePreUninstallRoute
  DescriptorBoundLifecycleCommitCascadePreUninstallReport ->
    DescriptorBoundLifecycleCascadePreUninstallRoute
  DescriptorBoundLifecycleReadBackCascadePreUninstallReport ->
    DescriptorBoundLifecycleCascadePreUninstallRoute
  DescriptorBoundLifecycleUninstallCascadeLocalFoundation ->
    DescriptorBoundLifecycleCascadeHostRoute
  DescriptorBoundLifecycleReadBackCascadeLocalAbsence ->
    DescriptorBoundLifecycleCascadeHostRoute
  DescriptorBoundLifecycleCommitCascadeCompletion ->
    DescriptorBoundLifecycleCascadeHostRoute
  DescriptorBoundLifecycleReadBackCascadeCompletion ->
    DescriptorBoundLifecycleCascadeHostRoute
  DescriptorBoundLifecycleUninstallLocalOnlyFoundation ->
    unsupported DescriptorBoundLifecycleLocalOnlyFoundationUninstall
  DescriptorBoundLifecycleReadBackLocalOnlyAbsence ->
    unsupported DescriptorBoundLifecycleLocalOnlyAbsenceReadBack
  DescriptorBoundLifecycleCommitLocalOnlyCompletion ->
    unsupported DescriptorBoundLifecycleLocalOnlyCompletionCommit
  DescriptorBoundLifecycleReadBackLocalOnlyCompletion ->
    unsupported DescriptorBoundLifecycleLocalOnlyCompletionReadBack
  DescriptorBoundLifecycleCommitOrdinarySurfaceReport ->
    DescriptorBoundLifecycleOrdinaryReportRoute
  DescriptorBoundLifecycleReadBackOrdinarySurfaceReport ->
    DescriptorBoundLifecycleOrdinaryReportRoute
  DescriptorBoundLifecycleRevokeOperationalCredential ->
    unsupported DescriptorBoundLifecycleOperationalCredentialRevoke
  DescriptorBoundLifecycleReadBackOperationalCredentialRevocation ->
    unsupported DescriptorBoundLifecycleOperationalCredentialRevocationReadBack
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
    ClosedLifecycleEffects executeOperation
   where
    executeOperation runtime = case routeOperation operation of
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
      DescriptorBoundLifecycleCascadeHostRoute ->
        pure
          ( TeardownNodeRefused
              ( renderRuntimeError
                  ( DescriptorBoundLifecycleCascadeHostEnteredCloudRuntime
                      (teardownOperationTag operation)
                  )
              )
          )
      DescriptorBoundLifecycleCascadePreUninstallRoute ->
        pure
          ( TeardownNodeRefused
              ( renderRuntimeError
                  ( DescriptorBoundLifecycleCascadePreUninstallEnteredCloudRuntime
                      (teardownOperationTag operation)
                  )
              )
          )
      DescriptorBoundLifecycleOrdinaryReportRoute ->
        pure
          ( TeardownNodeRefused
              ( renderRuntimeError
                  ( DescriptorBoundLifecycleOrdinaryReportEnteredCloudRuntime
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

data OrdinaryReportRuntime = OrdinaryReportRuntime
  { ordinaryReportScope :: !ObservationEvidenceScope
  , ordinaryReportGraphDigest :: !CleanupDigest
  , ordinaryReportReadBackResult :: !DurableReceiptObservationResult
  }

newtype OrdinaryReportEffects value = OrdinaryReportEffects
  { runOrdinaryReportEffects :: OrdinaryReportRuntime -> IO value
  }

instance Functor OrdinaryReportEffects where
  fmap transform action =
    OrdinaryReportEffects $ \runtime ->
      fmap transform (runOrdinaryReportEffects action runtime)

instance Applicative OrdinaryReportEffects where
  pure value = OrdinaryReportEffects $ \_ -> pure value
  function <*> value =
    OrdinaryReportEffects $ \runtime -> do
      transform <- runOrdinaryReportEffects function runtime
      input <- runOrdinaryReportEffects value runtime
      pure (transform input)

instance Monad OrdinaryReportEffects where
  action >>= next =
    OrdinaryReportEffects $ \runtime -> do
      value <- runOrdinaryReportEffects action runtime
      runOrdinaryReportEffects (next value) runtime

instance LifecycleTeardownEffects OrdinaryReportEffects where
  executeLifecycleTeardownOperation _ operation =
    OrdinaryReportEffects (runOrdinaryReportOperation operation)

runOrdinaryReportOperation
  :: TeardownOperation surface
  -> OrdinaryReportRuntime
  -> IO (TeardownNodeResult surface)
runOrdinaryReportOperation operation runtime = case operation of
  CommitOrdinarySurfaceReport ->
    pure (TeardownMutationAttempt TeardownMutationApplied)
  ReadBackOrdinarySurfaceReport ->
    pure
      ( TeardownDurableReceiptObservation
          DurableReceiptObservation
            { durableReceiptObservationKind = OrdinarySurfaceReportReceipt
            , durableReceiptObservationScope = ordinaryReportScope runtime
            , durableReceiptObservationGraphDigest = ordinaryReportGraphDigest runtime
            , durableReceiptObservationResult = ordinaryReportReadBackResult runtime
            }
      )
  _ ->
    pure
      ( TeardownNodeRefused
          ( renderRuntimeError
              ( DescriptorBoundLifecycleOrdinaryReportEnteredCloudRuntime
                  (teardownOperationTag operation)
              )
          )
      )

runOrdinaryReportAction
  :: DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
runOrdinaryReportAction running compiled context plan =
  runOrdinaryReportEffects
    ( runCompiledTeardownNodeWithDescriptorContext
        running
        compiled
        context
        plan
    )
    OrdinaryReportRuntime
      { ordinaryReportScope = compiledDesiredAbsenceObservationScope compiled
      , ordinaryReportGraphDigest =
          cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
      , ordinaryReportReadBackResult = ordinaryReportReceiptResult running compiled
      }

ordinaryReportReceiptResult
  :: DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram surface
  -> DurableReceiptObservationResult
ordinaryReportReceiptResult running compiled =
  case [ nodeId
       | (nodeId, CommitOrdinarySurfaceReport) <- compiledDesiredAbsenceOperations compiled
       ] of
    [commitNode] -> case Map.lookup commitNode (descriptorBoundCleanupRunNodeStates running) of
      Just (CleanupNodeCompleted _ CleanupNodeSucceeded) -> DurableReceiptObserved
      _ -> DurableReceiptMissing
    _ -> DurableReceiptMissing

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
      cascadePreUninstallExact =
        either
          (const False)
          ( \shapes ->
              shapes == allShapes
                && routeCount isCascadePreUninstallRoute shapes == 3
          )
          inventory
      cascadeHostExact =
        either
          (const False)
          -- Sprint 4.86 (2026-08-19): the four compiled cascade host nodes
          -- route to the closed cascade host runtime, one node per durable
          -- phase.
          (\shapes -> shapes == allShapes && routeCount isCascadeHostRoute shapes == 4)
          inventory
          && cascadeHostRuntimeClosedOperationsExact
            fixedCascadeHostRuntimeRegression
          && cascadeHostRuntimePhasesDistinct fixedCascadeHostRuntimeRegression
      unsupportedExact =
        either
          (const False)
          -- Sprint 4.85 (2026-08-18): 23 rather than 21 — the operational
          -- surface's credential revocation and that revocation's read-back
          -- are compiled nodes with no released adapter, so they classify as
          -- typed refusals like every other unreleased operation.
          -- Sprint 4.86 (2026-08-19): 19 rather than 23 — the four cascade
          -- host nodes now have a released runtime.
          -- Sprint 6.5 (2026-08-23): 14 rather than 17 — the cascade audit,
          -- report commit, and report read-back now have a closed runtime.
          (\shapes -> shapes == allShapes && routeCount isUnsupportedRoute shapes == 14)
          inventory
      cloudExecuted = either (const False) (\(exact, _, _) -> exact) exercised
      cascadePreUninstallExecuted =
        either (const False) (\(_, exact, _) -> exact) exercised
      cascadeHostExecuted = either (const False) (\(_, _, exact) -> exact) exercised
      unsupportedIsRefusal =
        not
          ( Text.null
              ( renderRuntimeError
                  ( DescriptorBoundLifecycleOperationUnsupported
                      DescriptorBoundLifecycleLocalOnlyFoundationUninstall
                  )
              )
          )
      closed =
        cloudExecuted
          && cascadePreUninstallExecuted
          && cascadeHostExecuted
          && unsupportedIsRefusal
      descriptorBound = closed && cloudExact && unsupportedExact
      opaque =
        descriptorBound
          && recoveryExact
          && cascadePreUninstallExact
          && cascadeHostExact
  pure
    ( DescriptorBoundLifecycleRuntimeRegression
        cloudExact
        recoveryExact
        cascadePreUninstallExact
        cascadeHostExact
        unsupportedExact
        unsupportedIsRefusal
        closed
        descriptorBound
        opaque
    )

descriptorBoundLifecycleRuntimeCloudOperationsExact
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeCloudOperationsExact
  (DescriptorBoundLifecycleRuntimeRegression exact _ _ _ _ _ _ _ _) = exact

descriptorBoundLifecycleRuntimeRecoveryOperationsExact
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeRecoveryOperationsExact
  (DescriptorBoundLifecycleRuntimeRegression _ exact _ _ _ _ _ _ _) = exact

descriptorBoundLifecycleRuntimeCascadePreUninstallOperationsExact
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeCascadePreUninstallOperationsExact
  (DescriptorBoundLifecycleRuntimeRegression _ _ exact _ _ _ _ _ _) = exact

descriptorBoundLifecycleRuntimeCascadeHostOperationsExact
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeCascadeHostOperationsExact
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ exact _ _ _ _ _) = exact

descriptorBoundLifecycleRuntimeUnsupportedOperationsExact
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeUnsupportedOperationsExact
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ _ exact _ _ _ _) = exact

descriptorBoundLifecycleRuntimeUnsupportedIsRefusal
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeUnsupportedIsRefusal
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ _ _ exact _ _ _) = exact

descriptorBoundLifecycleRuntimeNoCallerContinuation
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeNoCallerContinuation
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ _ _ _ exact _ _) = exact

descriptorBoundLifecycleRuntimeDescriptorBoundOnly
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeDescriptorBoundOnly
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ _ _ _ _ exact _) = exact

descriptorBoundLifecycleRuntimeOpacityClosed
  :: DescriptorBoundLifecycleRuntimeRegression -> Bool
descriptorBoundLifecycleRuntimeOpacityClosed
  (DescriptorBoundLifecycleRuntimeRegression _ _ _ _ _ _ _ _ exact) = exact

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

isCascadePreUninstallRoute :: DescriptorBoundLifecycleRoute -> Bool
isCascadePreUninstallRoute route = case route of
  DescriptorBoundLifecycleCascadePreUninstallRoute -> True
  _ -> False

isCascadeHostRoute :: DescriptorBoundLifecycleRoute -> Bool
isCascadeHostRoute route = case route of
  DescriptorBoundLifecycleCascadeHostRoute -> True
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
          Nothing
          witness
      )
  pure
    ( Set.fromList
        [ operationShape operation
        | (_, operation) <- compiledDesiredAbsenceOperations compiled
        ]
    )

exerciseRegressionDispatcher :: IO (Either Text (Bool, Bool, Bool))
exerciseRegressionDispatcher =
  case regressionDescriptorFixture of
    Left err -> pure (Left err)
    Right (compiled, initialRun, descriptor) -> do
      providerCalls <- newIORef (0 :: Int)
      case regressionCloudRuntime providerCalls of
        Left err -> pure (Left err)
        Right cloudRuntime ->
          withRegressionCascadeHost
            ( exerciseRegressionRoutes
                cloudRuntime
                providerCalls
                compiled
                initialRun
                descriptor
            )

withRegressionCascadeHost
  :: (CascadeHostRuntime -> IO (Either Text result))
  -> IO (Either Text result)
withRegressionCascadeHost use =
  withSystemTempDirectory "prodbox-descriptor-bound-cascade-host" openStore
 where
  openStore temporaryRoot = case mkHostCleanupIntentStore temporaryRoot of
    Left err -> pure (Left (Text.pack (show err)))
    Right store -> use (mkCascadeHostRuntime store regressionHostRunnerEffects)

exerciseRegressionRoutes
  :: CloudRuntime IO
  -> IORef Int
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> CleanupRun
  -> CleanupProgramDescriptor
  -> CascadeHostRuntime
  -> IO (Either Text (Bool, Bool, Bool))
exerciseRegressionRoutes
  cloudRuntime
  providerCalls
  compiled
  initialRun
  descriptor
  cascadeHost = do
    cloud <- execute "observe/aws-test"
    cascadePreUninstall <- execute "audit-cascade-escapes"
    cascade <- execute "uninstall-cascade-local-foundation"
    pure $ do
      (cloudOutcome, cloudCalls) <- cloud
      (cascadePreUninstallOutcome, cascadePreUninstallCalls) <- cascadePreUninstall
      (cascadeOutcome, cascadeCalls) <- cascade
      pure
        ( cloudCalls == 1 && isFailedOutcome cloudOutcome
        , cascadePreUninstallCalls == 0
            && failedWith
              "DescriptorBoundLifecycleCascadePreUninstallRuntimeUnavailable"
              cascadePreUninstallOutcome
        , -- The destructive host node reaches the closed cascade host runtime
          -- and never the cloud runtime: an empty durable record refuses
          -- before any effect is taken.
          cascadeCalls == 0
            && failedWith "CascadeHostRuntimeIntentMissing" cascadeOutcome
        )
   where
    execute =
      executeRegressionOperation
        cloudRuntime
        cascadeHost
        providerCalls
        compiled
        initialRun
        descriptor

failedWith :: Text -> CleanupNodeOutcome -> Bool
failedWith expected outcome = case outcome of
  CleanupNodeFailed detail -> expected `Text.isInfixOf` detail
  _ -> False

-- | Arms that refuse everything.  The fixed dispatcher exercise runs against an
-- empty durable record, so the runtime refuses before any arm is reached; the
-- record exists to keep the runtime closed rather than to be called.
regressionHostRunnerEffects :: HostCleanupRunnerEffects IO
regressionHostRunnerEffects =
  HostCleanupRunnerEffects
    { hostRunnerAcceptAuthority = \_ _ -> pure refusedEffect
    , hostRunnerReadBackAuthorityAcceptance = \_ -> pure (Left unreachable)
    , hostRunnerRunLocalUninstall = \_ -> pure refusedEffect
    , hostRunnerReadBackLocalAbsence = \_ _ -> pure (Left unreachable)
    , hostRunnerReestablishBootstrapRecovery = \_ -> pure refusedEffect
    , hostRunnerReadBackBootstrapRecovery = \_ -> pure (Left unreachable)
    , hostRunnerReestablishLifecycleAuthority = \_ -> pure refusedEffect
    , hostRunnerReadBackLifecycleAuthority = \_ -> pure (Left unreachable)
    , hostRunnerReconcileCleanupRun = \_ _ -> pure refusedEffect
    , hostRunnerReadBackCleanupRun = \_ -> pure (Left unreachable)
    , hostRunnerCommitCompletionReceipt = \_ _ -> pure refusedEffect
    , hostRunnerReadBackCompletionReceipt = \_ -> pure (Left unreachable)
    }
 where
  refusedEffect = HostCleanupEffectRefused unreachable
  unreachable = "the fixed dispatcher exercise takes no host effect"

executeRegressionOperation
  :: CloudRuntime IO
  -> CascadeHostRuntime
  -> IORef Int
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> CleanupRun
  -> CleanupProgramDescriptor
  -> Text
  -> IO (Either Text (CleanupNodeOutcome, Int))
executeRegressionOperation
  cloudRuntime
  cascadeHost
  providerCalls
  compiled
  initialRun
  descriptor
  operationTag =
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
                  descriptorBoundCleanupNodeAction
                    ( dispatchDescriptorBoundLifecycleNode
                        cloudRuntime
                        transport
                        Nothing
                        (Just cascadeHost)
                    )
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
          Nothing
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
  drive owner withPrimary (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled))
 where
  drive _ _ [] = Left ("compiled program lacks operation " <> expectedOperation)
  drive owner run (plan : remaining) = do
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
        drive owner completed remaining

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
  endpoint <- firstShow (mkLifecycleAuthorityEndpoint regressionAuthorityEndpoint)
  rawClient <-
    firstShow
      ( controlPlaneClientWithTransport
          cleanupRunMaximumBytes
          endpoint
          ( \_ _ _ _ -> do
              next <-
                atomicModifyIORef' queuedResponses dequeueQueuedResponse
              pure $ case next of
                Nothing ->
                  Right
                    ( replyStatusCode ReplyInternalError
                    , ByteString.empty
                    )
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

regressionAuthorityEndpoint :: Text
regressionAuthorityEndpoint =
  "http://lifecycle-authority:" <> Text.pack (show controlPlaneListenPort)

dequeueQueuedResponse :: [value] -> ([value], Maybe value)
dequeueQueuedResponse queued = case queued of
  [] -> ([], Nothing)
  response : remaining -> (remaining, Just response)

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
        \operationId key scope ->
          pure
            ( firstShow
                ( mkAwsStackProviderBinding
                    operationId
                    key
                    scope
                    regressionProviderRevision
                    (regressionProviderConfig key)
                )
            )
    , awsRegisteredTargetPresentEksDestroyBoundary =
        mkAwsEksPresentDestroyBoundary $ \_ _ _ ->
          pure (Left AwsRegisteredTargetEksDrainProofRequired)
    , awsRegisteredTargetDns01ChallengeOwnerDeleteBoundary =
        refusingDns01ChallengeOwnerDeleteBoundary
          "fixed dispatcher DNS01 owner-delete refusal"
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
      , retirePulumiCheckpoint = \_ _ _ -> checkpointRefusal
      , restorePulumiCheckpointPrimary = \_ _ _ -> checkpointRefusal
      , readBackPulumiCheckpointRestore = \_ -> checkpointRefusal
      , attemptPulumiCheckpointRetirement = \_ _ _ _ -> checkpointRefusal
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
    , eksTeardownDrainInterpreter = mkEksDrainInterpreter (pure 1000)
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
    (AwsRegion canonicalRegressionAwsRegion)

regressionProviderRevision :: ProviderRevision
regressionProviderRevision =
  either (error . show) id (mkProviderRevision 1)

regressionProviderConfig :: RegisteredResourceKey -> ProviderStackConfig
regressionProviderConfig key = case key of
  AwsEksKey -> mustConfig (mkAwsEksProviderStackConfig "127.0.0.1/32")
  AwsEksSubzoneKey ->
    mustConfig
      (mkAwsEksSubzoneProviderStackConfig "ZREGRESSION" "aws.example.test")
  AwsTestKey -> mustConfig (mkAwsTestProviderStackConfig "127.0.0.1/32")
  _ -> error ("fixed dispatcher requested Provider config for " <> show key)
 where
  mustConfig = either (error . show) id

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)
