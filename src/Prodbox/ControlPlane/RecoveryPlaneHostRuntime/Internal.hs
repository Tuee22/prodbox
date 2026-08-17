{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private host dispatcher for the three closed recovery-plane
-- operations. It accepts no fallback callback: every non-recovery operation
-- is refused, leaving eventual total lifecycle composition to dispatch this
-- closed action beside the other concrete runtimes.
module Prodbox.ControlPlane.RecoveryPlaneHostRuntime.Internal
  ( RecoveryPlaneHostRuntimeError (..)
  , recoveryPlaneHostDescriptorBoundNodeActionInternal
  , RecoveryPlaneHostRuntimeRegression
  , fixedRecoveryPlaneHostRuntimeRegression
  , recoveryPlaneHostRuntimeClosedOperationsExact
  , recoveryPlaneHostRuntimeRemoteAmbiguityUnconfirmed
  , recoveryPlaneHostRuntimeDefiniteRefusalFailed
  , recoveryPlaneHostRuntimeOpacityClosed
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  )
import Prodbox.ControlPlane.LocalRke2HostObservationTransport.Internal
  ( localRke2HostObservationEstablishBoundaryInternal
  )
import Prodbox.ControlPlane.RecoveryPlaneEndpoint
  ( RecoveryPlaneEndpointResponseError (..)
  , RecoveryPlaneWireRefusal (..)
  , RecoveryPlaneWireUnavailable (..)
  )
import Prodbox.ControlPlane.RecoveryPlaneTransportClient
  ( RecoveryPlaneAuthorityClientError (..)
  , executeRecoveryPlaneFinalDispositionRemote
  , executeRecoveryPlaneInitialReadBackRemote
  , lifecycleAuthorityRecoveryPlaneAuthenticatedClient
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome (..)
  , CleanupNodePlan
  , cleanupNodeId
  , cleanupNodeOperationId
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , DescriptorBoundCleanupNodeExecutionAction
  , cleanupNodeExecutionAttemptId
  , cleanupNodeExecutionGraphDigest
  , cleanupNodeExecutionNodeId
  , cleanupNodeExecutionRunId
  , descriptorBoundCleanupNodeAction
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceOperations
  )
import Prodbox.Lifecycle.Teardown.Model (CleanupSurfaceWitness)
import Prodbox.Lifecycle.Teardown.Program
  ( RecoverySurfaceWitness (CascadeRecoverySurface)
  , TeardownOperation (..)
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter
  ( recoveryPlaneDescriptorBoundNodeAction
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter.Internal
  ( recoveryPlaneHostEstablishInterpreterInternal
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime)
  )

data RecoveryPlaneHostRuntimeError
  = RecoveryPlaneHostRuntimeContextMismatch !Text
  | RecoveryPlaneHostRuntimeOperationMissing
  | RecoveryPlaneHostRuntimeOperationDuplicated
  | RecoveryPlaneHostRuntimeOperationRefused !Text
  | RecoveryPlaneHostRuntimeAuthorityRefused !RecoveryPlaneAuthorityClientError
  deriving stock (Eq, Show)

data RecoveryPlaneHostPhase
  = RecoveryPlaneHostEstablish
  | RecoveryPlaneHostInitialReadBack
  | RecoveryPlaneHostFinalDisposition
  deriving stock (Eq, Show)

-- | Closed host action. Establish runs locally through the normal
-- descriptor-bound Execution validator and only then submits route 57's
-- Healthy candidate. The two evidence phases carry only the current durable
-- run/operation/attempt to route 56, where Authority reloads and re-observes
-- all facts. No raw component row or proof crosses this boundary.
recoveryPlaneHostDescriptorBoundNodeActionInternal
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> DescriptorBoundCleanupNodeExecutionAction
recoveryPlaneHostDescriptorBoundNodeActionInternal transport =
  descriptorBoundCleanupNodeAction (dispatchRecoveryPlaneHostNode transport)

dispatchRecoveryPlaneHostNode
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> DescriptorBoundCleanupRun
  -> CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
dispatchRecoveryPlaneHostNode transport running _ compiled context plan =
  case validateContext running context plan of
    Left err -> pure (refusalOutcome err)
    Right () -> case operationForPlan compiled plan of
      Left err -> pure (refusalOutcome err)
      Right operation -> case classifyOperation operation of
        Left err -> pure (refusalOutcome err)
        Right RecoveryPlaneHostEstablish ->
          recoveryPlaneDescriptorBoundNodeAction
            establishInterpreter
            running
            context
            plan
        Right RecoveryPlaneHostInitialReadBack -> do
          result <-
            executeRecoveryPlaneInitialReadBackRemote
              authorityClient
              (cleanupNodeExecutionRunId context)
              (cleanupNodeOperationId plan)
              (cleanupNodeExecutionAttemptId context)
          pure (remoteOutcome result)
        Right RecoveryPlaneHostFinalDisposition -> do
          result <-
            executeRecoveryPlaneFinalDispositionRemote
              authorityClient
              (cleanupNodeExecutionRunId context)
              (cleanupNodeOperationId plan)
              (cleanupNodeExecutionAttemptId context)
          pure (remoteOutcome result)
 where
  authorityClient = lifecycleAuthorityRecoveryPlaneAuthenticatedClient transport
  establishInterpreter =
    recoveryPlaneHostEstablishInterpreterInternal
      (localRke2HostObservationEstablishBoundaryInternal transport)

validateContext
  :: DescriptorBoundCleanupRun
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> Either RecoveryPlaneHostRuntimeError ()
validateContext running context plan
  | cleanupNodeExecutionRunId context /= descriptorBoundCleanupRunId running =
      Left (RecoveryPlaneHostRuntimeContextMismatch "cleanup run id differs")
  | cleanupNodeExecutionGraphDigest context
      /= descriptorBoundCleanupRunGraphDigest running =
      Left (RecoveryPlaneHostRuntimeContextMismatch "cleanup graph digest differs")
  | cleanupNodeExecutionNodeId context /= cleanupNodeId plan =
      Left (RecoveryPlaneHostRuntimeContextMismatch "cleanup node id differs")
  | otherwise = Right ()

operationForPlan
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> Either RecoveryPlaneHostRuntimeError (TeardownOperation surface)
operationForPlan compiled plan =
  case [ operation
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , nodeId == cleanupNodeId plan
       ] of
    [operation] -> Right operation
    [] -> Left RecoveryPlaneHostRuntimeOperationMissing
    _ -> Left RecoveryPlaneHostRuntimeOperationDuplicated

classifyOperation
  :: TeardownOperation surface
  -> Either RecoveryPlaneHostRuntimeError RecoveryPlaneHostPhase
classifyOperation operation = case operation of
  EstablishRecoveryPlane _ -> Right RecoveryPlaneHostEstablish
  ReadBackRecoveryPlane _ -> Right RecoveryPlaneHostInitialReadBack
  ObserveRecoveryPlaneDisposition _ -> Right RecoveryPlaneHostFinalDisposition
  _ ->
    Left
      ( RecoveryPlaneHostRuntimeOperationRefused
          (teardownOperationTag operation)
      )

remoteOutcome
  :: Either RecoveryPlaneAuthorityClientError CleanupNodeOutcome
  -> CleanupNodeOutcome
remoteOutcome result = case result of
  Right outcome -> outcome
  Left err
    | ambiguousRemoteFailure err ->
        CleanupNodeEffectUnconfirmed (bounded (Text.pack (show err)))
    | otherwise -> refusalOutcome (RecoveryPlaneHostRuntimeAuthorityRefused err)

ambiguousRemoteFailure :: RecoveryPlaneAuthorityClientError -> Bool
ambiguousRemoteFailure err = case err of
  RecoveryPlaneAuthorityClientTransportFailed _ -> True
  RecoveryPlaneAuthorityClientResponseInvalid _ -> True
  RecoveryPlaneAuthorityClientHttpStatusMismatch _ _ -> True
  RecoveryPlaneAuthorityClientResponseRefused responseError ->
    case responseError of
      RecoveryPlaneEndpointResponseVersionMismatch {} -> True
      RecoveryPlaneEndpointResponseRequestMismatch {} -> True
      RecoveryPlaneEndpointResponseRefused refusal -> case refusal of
        RecoveryPlaneWirePhaseMismatch _ -> True
        _ -> False
      RecoveryPlaneEndpointResponseUnavailable unavailable -> case unavailable of
        RecoveryPlaneWireExecutionUnavailable _ -> True
        _ -> False

refusalOutcome :: RecoveryPlaneHostRuntimeError -> CleanupNodeOutcome
refusalOutcome = CleanupNodeFailed . bounded . Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024

-- | Fixed, non-authorizing diagnostics. No transport, descriptor handle,
-- operation, or action escapes the public facade.
data RecoveryPlaneHostRuntimeRegression
  = RecoveryPlaneHostRuntimeRegression
      !Bool
      !Bool
      !Bool
      !Bool

fixedRecoveryPlaneHostRuntimeRegression :: RecoveryPlaneHostRuntimeRegression
fixedRecoveryPlaneHostRuntimeRegression =
  RecoveryPlaneHostRuntimeRegression
    ( and
        [ classifyOperation (EstablishRecoveryPlane CascadeRecoverySurface)
            == Right RecoveryPlaneHostEstablish
        , classifyOperation (ReadBackRecoveryPlane CascadeRecoverySurface)
            == Right RecoveryPlaneHostInitialReadBack
        , classifyOperation
            (ObserveRecoveryPlaneDisposition CascadeRecoverySurface)
            == Right RecoveryPlaneHostFinalDisposition
        , case classifyOperation AuditCascadeEscapes of
            Left RecoveryPlaneHostRuntimeOperationRefused {} -> True
            _ -> False
        ]
    )
    ( case remoteOutcome (Left (RecoveryPlaneAuthorityClientTransportFailed "lost")) of
        CleanupNodeEffectUnconfirmed _ -> True
        _ -> False
    )
    ( case remoteOutcome
        ( Left
            ( RecoveryPlaneAuthorityClientResponseRefused
                ( RecoveryPlaneEndpointResponseRefused
                    RecoveryPlaneWireRunMissing
                )
            )
        ) of
        CleanupNodeFailed _ -> True
        _ -> False
    )
    True

recoveryPlaneHostRuntimeClosedOperationsExact
  :: RecoveryPlaneHostRuntimeRegression -> Bool
recoveryPlaneHostRuntimeClosedOperationsExact
  (RecoveryPlaneHostRuntimeRegression exact _ _ _) = exact

recoveryPlaneHostRuntimeRemoteAmbiguityUnconfirmed
  :: RecoveryPlaneHostRuntimeRegression -> Bool
recoveryPlaneHostRuntimeRemoteAmbiguityUnconfirmed
  (RecoveryPlaneHostRuntimeRegression _ exact _ _) = exact

recoveryPlaneHostRuntimeDefiniteRefusalFailed
  :: RecoveryPlaneHostRuntimeRegression -> Bool
recoveryPlaneHostRuntimeDefiniteRefusalFailed
  (RecoveryPlaneHostRuntimeRegression _ _ exact _) = exact

recoveryPlaneHostRuntimeOpacityClosed
  :: RecoveryPlaneHostRuntimeRegression -> Bool
recoveryPlaneHostRuntimeOpacityClosed
  (RecoveryPlaneHostRuntimeRegression _ _ _ exact) = exact
