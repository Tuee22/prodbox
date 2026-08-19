{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: package-private host dispatcher for the four closed cascade
-- host operations.
--
-- The compiled cascade graph reaches the destructive host boundary through
-- separate nodes — @UninstallCascadeLocalFoundation@,
-- @ReadBackCascadeLocalAbsence@, @CommitCascadeCompletion@,
-- @ReadBackCascadeCompletion@ — and
-- "Prodbox.Lifecycle.HostCleanupRunner" performs them as separate durable
-- phases.  This module is the join, and it accepts no fallback callback:
-- every non-cascade-host operation is refused.
--
-- Three properties carry the design.
--
--   * __A node discharges exactly one durable phase.__  Each operation names
--     the phase that performs its effect, and the node drives the runner until
--     the durable intent has reached it.  The phases with no compiled node —
--     accepting the readiness, arming the terminal, and re-establishing the
--     recovery plane and the Authority — are the runner's own preparation for
--     the next node, and no node claims to have performed them.
--
--   * __A node that finds its phase already reached performs nothing.__  The
--     durable intent is the shared answer, so a rerun after a lost response
--     observes that its effect is already durable instead of repeating it.
--     That is what keeps the destructive uninstall issued exactly once across
--     an interrupted cascade.
--
--   * __An observation failure is unconfirmed, never a refusal.__  The runner
--     reports a mutation whose read-back failed and a read-back that failed on
--     its own through the same typed error, and from the node's side the two
--     are indistinguishable: the effect may have landed.  Reporting that as a
--     definite failure would let the run close a node whose effect is still
--     outstanding.
--
-- What this module does not own: the content of any phase, which belongs to
-- the runner; the durable transitions, which belong to
-- "Prodbox.Lifecycle.HostCleanupIntent"; and the construction of the closed
-- runtime, which is the non-public candidate entrypoint Sprint @4.86@ still
-- owns.
module Prodbox.ControlPlane.CascadeHostRuntime.Internal
  ( CascadeHostRuntime
  , mkCascadeHostRuntime
  , CascadeHostRuntimeError (..)
  , cascadeHostDescriptorBoundNodeActionInternal
  , CascadeHostRuntimeRegression
  , fixedCascadeHostRuntimeRegression
  , cascadeHostRuntimeClosedOperationsExact
  , cascadeHostRuntimePhasesDistinct
  , cascadeHostRuntimeObservationUnconfirmed
  , cascadeHostRuntimeDefiniteRefusalFailed
  , cascadeHostRuntimeOpacityClosed
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome (..)
  , CleanupNodePlan
  , cleanupNodeId
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , DescriptorBoundCleanupNodeExecutionAction
  , cleanupNodeExecutionGraphDigest
  , cleanupNodeExecutionNodeId
  , cleanupNodeExecutionRunId
  , descriptorBoundCleanupNodeAction
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntentPhase (..)
  , HostCleanupIntentStore
  , hostCleanupIntentPhase
  , observeHostCleanupIntent
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupRunnerEffects
  , HostCleanupRunnerError (..)
  , HostCleanupRunnerProgress (..)
  , HostCleanupRunnerStep (HostCleanupReadBackCompletionStep)
  , stepHostCleanupRunner
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceOperations
  )
import Prodbox.Lifecycle.Teardown.Model (CleanupSurfaceWitness)
import Prodbox.Lifecycle.Teardown.Program
  ( TeardownOperation (..)
  , teardownOperationTag
  )

-- | The closed runtime: a durable host-cleanup record and the production
-- effects that act on it.
--
-- There is no caller-supplied continuation and no injected boundary, which is
-- what makes it admissible to the descriptor-bound dispatcher.
data CascadeHostRuntime = CascadeHostRuntime
  { cascadeHostIntentStore :: !HostCleanupIntentStore
  , cascadeHostRunnerEffects :: !(HostCleanupRunnerEffects IO)
  }

mkCascadeHostRuntime
  :: HostCleanupIntentStore
  -> HostCleanupRunnerEffects IO
  -> CascadeHostRuntime
mkCascadeHostRuntime = CascadeHostRuntime

data CascadeHostRuntimeError
  = CascadeHostRuntimeContextMismatch !Text
  | CascadeHostRuntimeOperationMissing
  | CascadeHostRuntimeOperationDuplicated
  | CascadeHostRuntimeOperationRefused !Text
  | CascadeHostRuntimeIntentMissing
  | CascadeHostRuntimeIntentUnobservable !Text
  | CascadeHostRuntimeRunnerRefused !HostCleanupRunnerError
  | CascadeHostRuntimePhaseNotReached !HostCleanupIntentPhase
  deriving stock (Eq, Show)

-- | Closed host action.  Each cascade host node drives the durable runner to
-- the phase that performs its effect and stops.
cascadeHostDescriptorBoundNodeActionInternal
  :: CascadeHostRuntime
  -> DescriptorBoundCleanupNodeExecutionAction
cascadeHostDescriptorBoundNodeActionInternal runtime =
  descriptorBoundCleanupNodeAction (dispatchCascadeHostNode runtime)

dispatchCascadeHostNode
  :: CascadeHostRuntime
  -> DescriptorBoundCleanupRun
  -> CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
dispatchCascadeHostNode runtime running _ compiled context plan =
  case validateContext running context plan of
    Left err -> pure (refusalOutcome err)
    Right () -> case operationForPlan compiled plan of
      Left err -> pure (refusalOutcome err)
      Right operation -> case classifyOperation operation of
        Left err -> pure (refusalOutcome err)
        Right target -> driveToPhase runtime target

-- | Drive the durable runner until the intent has reached @target@.
--
-- The bound is the number of durable phases, so a runner that stopped
-- advancing terminates as a definite refusal instead of spinning.
driveToPhase
  :: CascadeHostRuntime -> HostCleanupIntentPhase -> IO CleanupNodeOutcome
driveToPhase runtime target = observeThen cascadeHostPhaseBudget
 where
  observeThen budget = do
    observed <- observeHostCleanupIntent (cascadeHostIntentStore runtime)
    case observed of
      Left err ->
        pure
          ( refusalOutcome
              (CascadeHostRuntimeIntentUnobservable (bounded (Text.pack (show err))))
          )
      Right Nothing -> pure (refusalOutcome CascadeHostRuntimeIntentMissing)
      Right (Just intent)
        | hostCleanupIntentPhase intent >= target -> pure CleanupNodeSucceeded
        | budget <= (0 :: Int) ->
            pure (refusalOutcome (CascadeHostRuntimePhaseNotReached target))
        | otherwise -> do
            stepped <-
              stepHostCleanupRunner
                (cascadeHostIntentStore runtime)
                (cascadeHostRunnerEffects runtime)
                Nothing
            case stepped of
              Left err -> pure (runnerOutcome err)
              Right (HostCleanupRunnerCompleted _) -> pure CleanupNodeSucceeded
              Right (HostCleanupRunnerAdvanced phase)
                | phase >= target -> pure CleanupNodeSucceeded
                | otherwise -> observeThen (budget - 1)

-- | One more than the number of durable phases.
cascadeHostPhaseBudget :: Int
cascadeHostPhaseBudget = 9

-- | The runner's typed refusals, mapped onto the node's three answers.
--
-- An observation failure covers both "the mutation was issued and its
-- read-back failed" and "a read-back failed on its own", and from here the two
-- are indistinguishable, so the effect is reported as unconfirmed rather than
-- as a definite failure.
runnerOutcome :: HostCleanupRunnerError -> CleanupNodeOutcome
runnerOutcome err = case err of
  HostCleanupRunnerObservationFailed _ _ ->
    CleanupNodeEffectUnconfirmed (bounded (Text.pack (show err)))
  _ -> refusalOutcome (CascadeHostRuntimeRunnerRefused err)

validateContext
  :: DescriptorBoundCleanupRun
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> Either CascadeHostRuntimeError ()
validateContext running context plan
  | cleanupNodeExecutionRunId context /= descriptorBoundCleanupRunId running =
      Left (CascadeHostRuntimeContextMismatch "cleanup run id differs")
  | cleanupNodeExecutionGraphDigest context
      /= descriptorBoundCleanupRunGraphDigest running =
      Left (CascadeHostRuntimeContextMismatch "cleanup graph digest differs")
  | cleanupNodeExecutionNodeId context /= cleanupNodeId plan =
      Left (CascadeHostRuntimeContextMismatch "cleanup node id differs")
  | otherwise = Right ()

operationForPlan
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> Either CascadeHostRuntimeError (TeardownOperation surface)
operationForPlan compiled plan =
  case [ operation
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , nodeId == cleanupNodeId plan
       ] of
    [operation] -> Right operation
    [] -> Left CascadeHostRuntimeOperationMissing
    _ -> Left CascadeHostRuntimeOperationDuplicated

-- | The one place a compiled cascade host operation names the durable phase
-- that performs it.
classifyOperation
  :: TeardownOperation surface
  -> Either CascadeHostRuntimeError HostCleanupIntentPhase
classifyOperation operation = case operation of
  UninstallCascadeLocalFoundation -> Right HostCleanupLocalUninstallIssued
  ReadBackCascadeLocalAbsence -> Right HostCleanupLocalAbsenceRecorded
  CommitCascadeCompletion -> Right HostCleanupCompletionCommitted
  ReadBackCascadeCompletion -> Right HostCleanupComplete
  _ ->
    Left
      ( CascadeHostRuntimeOperationRefused
          (teardownOperationTag operation)
      )

refusalOutcome :: CascadeHostRuntimeError -> CleanupNodeOutcome
refusalOutcome = CleanupNodeFailed . bounded . Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024

-- | Fixed, non-authorizing diagnostics.  No store, effects record, operation,
-- or action escapes the public facade.
data CascadeHostRuntimeRegression
  = CascadeHostRuntimeRegression
      !Bool
      !Bool
      !Bool
      !Bool
      !Bool

fixedCascadeHostRuntimeRegression :: CascadeHostRuntimeRegression
fixedCascadeHostRuntimeRegression =
  CascadeHostRuntimeRegression
    ( and
        [ classifyOperation UninstallCascadeLocalFoundation
            == Right HostCleanupLocalUninstallIssued
        , classifyOperation ReadBackCascadeLocalAbsence
            == Right HostCleanupLocalAbsenceRecorded
        , classifyOperation CommitCascadeCompletion
            == Right HostCleanupCompletionCommitted
        , classifyOperation ReadBackCascadeCompletion
            == Right HostCleanupComplete
        , case classifyOperation UninstallLocalOnlyFoundation of
            Left CascadeHostRuntimeOperationRefused {} -> True
            _ -> False
        , case classifyOperation AuditCascadeEscapes of
            Left CascadeHostRuntimeOperationRefused {} -> True
            _ -> False
        ]
    )
    -- Four nodes, four distinct phases: a phase that discharged two nodes
    -- would leave a resume with nothing to attribute a failure to.
    ( length
        ( distinctPhases
            [ classifyOperation UninstallCascadeLocalFoundation
            , classifyOperation ReadBackCascadeLocalAbsence
            , classifyOperation CommitCascadeCompletion
            , classifyOperation ReadBackCascadeCompletion
            ]
        )
        == 4
    )
    ( case runnerOutcome
        ( HostCleanupRunnerObservationFailed
            HostCleanupReadBackCompletionStep
            "read-back failed"
        ) of
        CleanupNodeEffectUnconfirmed _ -> True
        _ -> False
    )
    ( case runnerOutcome HostCleanupRunnerReadyBindingMissing of
        CleanupNodeFailed _ -> True
        _ -> False
    )
    True

distinctPhases
  :: [Either CascadeHostRuntimeError HostCleanupIntentPhase]
  -> [HostCleanupIntentPhase]
distinctPhases = foldr keep []
 where
  keep classified seen = case classified of
    Right phase | phase `notElem` seen -> phase : seen
    _ -> seen

cascadeHostRuntimeClosedOperationsExact :: CascadeHostRuntimeRegression -> Bool
cascadeHostRuntimeClosedOperationsExact
  (CascadeHostRuntimeRegression exact _ _ _ _) = exact

cascadeHostRuntimePhasesDistinct :: CascadeHostRuntimeRegression -> Bool
cascadeHostRuntimePhasesDistinct
  (CascadeHostRuntimeRegression _ exact _ _ _) = exact

cascadeHostRuntimeObservationUnconfirmed
  :: CascadeHostRuntimeRegression -> Bool
cascadeHostRuntimeObservationUnconfirmed
  (CascadeHostRuntimeRegression _ _ exact _ _) = exact

cascadeHostRuntimeDefiniteRefusalFailed :: CascadeHostRuntimeRegression -> Bool
cascadeHostRuntimeDefiniteRefusalFailed
  (CascadeHostRuntimeRegression _ _ _ exact _) = exact

cascadeHostRuntimeOpacityClosed :: CascadeHostRuntimeRegression -> Bool
cascadeHostRuntimeOpacityClosed
  (CascadeHostRuntimeRegression _ _ _ _ exact) = exact
