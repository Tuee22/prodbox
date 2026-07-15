{-# LANGUAGE OverloadedStrings #-}

-- | Pure canonical-suite restore planning plus the typed daemon precondition
-- used by the SMTP restore step. Execution remains at the TestRunner boundary;
-- the plan is substrate-aware so the AWS harness can project from the same
-- sequence without importing TestRunner internals.
module Prodbox.TestRestore
  ( RestoreChart (..)
  , RestoreCyclePlan (..)
  , RestoreCycleStep (..)
  , RetainedSesPreparationInterpreter (..)
  , RetainedSesPreparationInputs (..)
  , RetainedSesPreparationPlan
  , RetainedSesPreparationPrecondition (..)
  , RetainedSesPreparationStep (..)
  , RetainedSesRequirement (..)
  , buildRestoreCyclePlan
  , gatewayDaemonLivenessPrecondition
  , retainedSesPreparationPrecondition
  , retainedSesPreparationTrace
  , restoreChartId
  , restoreStepResetsGatewayHealthyWindow
  , runRetainedSesPreparationWith
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.ComponentGraph
  ( ComponentId (..)
  , ReadinessProbe (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , TargetClusterSecretSink
  )
import Prodbox.Lifecycle.Preconditions
  ( Precondition (..)
  , StructuredError (..)
  )
import Prodbox.Lifecycle.ReadinessObservation
  ( ComponentReadinessTarget (..)
  , ReadinessProbeResult
  , waitForComponentReadiness
  )
import Prodbox.Retry (RetryPolicy)
import Prodbox.Substrate (Substrate)

data RestoreChart
  = RestoreChartGateway
  | RestoreChartVscode
  | RestoreChartApi
  | RestoreChartWebsocket
  deriving (Bounded, Enum, Eq, Show)

restoreChartId :: RestoreChart -> String
restoreChartId chart =
  case chart of
    RestoreChartGateway -> "gateway"
    RestoreChartVscode -> "vscode"
    RestoreChartApi -> "api"
    RestoreChartWebsocket -> "websocket"

-- | A capability projected solely from the selected validation set.  It is
-- deliberately independent of bootstrap flags and substrate selection.
data RetainedSesRequirement
  = SesNotRequired
  | SesRequired
  deriving (Eq, Show)

-- | The observable semantic stages of the one retained SES preparation
-- transaction.  Acquire and release are part of the transaction contract;
-- an interpreter must not flatten them into independently skippable restore
-- actions.
data RetainedSesPreparationStep
  = RetainedSesAcquire
  | RetainedSesReconcile
  | RetainedSesAwaitReady
  | RetainedSesSyncTarget
  | RetainedSesRelease
  deriving (Bounded, Enum, Eq, Show)

-- | The target gateway must prove a real object-store round trip before the
-- retained transaction may acquire its lease.  This is plan data rather than
-- an ambient bootstrap convention, so every interpreter must account for it.
data RetainedSesPreparationPrecondition
  = RetainedSesGatewayObjectStoreReady
  deriving (Eq, Show)

-- | Opaque nested plan for the one registered retained-SES effect.  The
-- semantic trace documents the Phase 4.47 bracket owned by the registered
-- ensure operation; interpreters observe and validate it but never flatten
-- those stages into independently skippable actions.
data RetainedSesPreparationPlan = RetainedSesPreparationPlan
  { retainedSesPreparationPrecondition :: !RetainedSesPreparationPrecondition
  , retainedSesPreparationTrace :: ![RetainedSesPreparationStep]
  }
  deriving (Eq, Show)

canonicalRetainedSesPreparationPlan :: RetainedSesPreparationPlan
canonicalRetainedSesPreparationPlan =
  RetainedSesPreparationPlan
    { retainedSesPreparationPrecondition = RetainedSesGatewayObjectStoreReady
    , retainedSesPreparationTrace = [minBound .. maxBound]
    }

-- | Explicit coordinates for retained control-plane authority and the
-- independently selected workload-cluster secret sink.  The unrelated field
-- types make ambient target inference and authority/target substitution
-- unrepresentable at this planning boundary.
data RetainedSesPreparationInputs = RetainedSesPreparationInputs
  { retainedSesCheckpointAuthority :: !LongLivedCheckpointAuthority
  , retainedSesTargetSecretSink :: !TargetClusterSecretSink
  }
  deriving (Eq, Show)

-- | A small injected interpreter for the two plan-level effects: the typed
-- target-readiness precondition and one registered atomic ensure.  The ensure
-- implementation remains responsible for its own acquire/release bracket and
-- internal transaction stages.
data RetainedSesPreparationInterpreter action failure
  = RetainedSesPreparationInterpreter
  { checkRetainedSesPreparationPrecondition
      :: RetainedSesPreparationPrecondition
      -> RetainedSesPreparationInputs
      -> action (Either failure ())
  , runRegisteredRetainedSesEnsure
      :: RetainedSesPreparationPlan
      -> RetainedSesPreparationInputs
      -> action (Either failure ())
  }

runRetainedSesPreparationWith
  :: (Monad action)
  => RetainedSesPreparationInterpreter action failure
  -> RetainedSesPreparationPlan
  -> RetainedSesPreparationInputs
  -> action (Either failure ())
runRetainedSesPreparationWith interpreter preparationPlan inputs = do
  readinessResult <-
    checkRetainedSesPreparationPrecondition
      interpreter
      (retainedSesPreparationPrecondition preparationPlan)
      inputs
  case readinessResult of
    Left failure -> pure (Left failure)
    Right () ->
      runRegisteredRetainedSesEnsure interpreter preparationPlan inputs

data RestoreCycleStep
  = RestoreDeleteChart !RestoreChart
  | RestoreEnsureGatewayMinioBootstrap
  | RestoreReconcileChart !RestoreChart
  | RestorePrepareRetainedSes !RetainedSesPreparationPlan
  | RestoreWaitForPublicEdge
  deriving (Eq, Show)

data RestoreCyclePlan = RestoreCyclePlan
  { restoreCycleSubstrate :: !Substrate
  , restoreCycleSteps :: ![RestoreCycleStep]
  }
  deriving (Eq, Show)

-- | Only a gateway rollout explicitly present in the compiled restore plan
-- may restart the runtime-stability success window.  The caller must preserve
-- the run-wide absorbing unhealthy evidence when applying this decision.
restoreStepResetsGatewayHealthyWindow :: RestoreCycleStep -> Bool
restoreStepResetsGatewayHealthyWindow restoreStep =
  case restoreStep of
    RestoreDeleteChart RestoreChartGateway -> True
    RestoreReconcileChart RestoreChartGateway -> True
    RestoreDeleteChart _ -> False
    RestoreReconcileChart _ -> False
    RestoreEnsureGatewayMinioBootstrap -> False
    RestorePrepareRetainedSes _ -> False
    RestoreWaitForPublicEdge -> False

-- | The one canonical destructive restore core.  The optional retained SES
-- transaction is represented by one atomic marker: its bracketed five-stage
-- interpretation is anchored after gateway reconciliation and before every
-- dependent chart.
buildRestoreCyclePlan :: Substrate -> RetainedSesRequirement -> RestoreCyclePlan
buildRestoreCyclePlan substrate retainedSesRequirement =
  RestoreCyclePlan
    { restoreCycleSubstrate = substrate
    , restoreCycleSteps =
        [ RestoreDeleteChart RestoreChartWebsocket
        , RestoreDeleteChart RestoreChartApi
        , RestoreDeleteChart RestoreChartVscode
        , RestoreDeleteChart RestoreChartGateway
        , RestoreEnsureGatewayMinioBootstrap
        , RestoreReconcileChart RestoreChartGateway
        ]
          ++ smtpSteps
          ++ [ RestoreReconcileChart RestoreChartVscode
             , RestoreReconcileChart RestoreChartApi
             , RestoreReconcileChart RestoreChartWebsocket
             , RestoreWaitForPublicEdge
             ]
    }
 where
  smtpSteps =
    case retainedSesRequirement of
      SesNotRequired -> []
      SesRequired -> [RestorePrepareRetainedSes canonicalRetainedSesPreparationPlan]

-- | Adapt one gateway object-store observation into a composable, bounded,
-- fail-closed prerequisite. The caller supplies the real one-shot actions and
-- loopback NodePort label; this module owns neither transport coordinates nor
-- a second polling loop.
--
-- Sprint 2.34: the gate gains a kubelet @/readyz@ PRECHECK ('observeReadyzOnce')
-- ordered before the object-store round trip. The daemon's @/readyz@ now
-- latches only on the first proven object-store round trip since boot, so
-- requiring @/readyz@ ready before this lifecycle round trip makes
-- lifecycle-ready imply kubelet-ready by construction: the lifecycle gate can
-- never admit dependent work through a daemon the kubelet would still pull from
-- its Service endpoints.
gatewayDaemonLivenessPrecondition
  :: RetryPolicy
  -> String
  -> IO (Either Text ReadinessProbeResult)
  -> IO (Either Text ReadinessProbeResult)
  -> Precondition
gatewayDaemonLivenessPrecondition policy endpointLabel observeReadyzOnce observeRoundTripOnce =
  Precondition
    { preconditionLabel = gatewayDaemonLivenessLabel
    , preconditionCheck = do
        readyzResult <-
          waitForComponentReadiness
            policy
            (FrontDoorHttpTarget ComponentGatewayDaemonFull observeReadyzOnce)
            ProbeFrontDoorHttp
        case readyzResult of
          Left reason -> pure (Left (readyzError reason))
          Right () -> do
            result <-
              waitForComponentReadiness
                policy
                ( BackendRoundTripTarget
                    ComponentGatewayDaemonFull
                    ComponentMinio
                    observeRoundTripOnce
                )
                (ProbeBackendRoundTrip ComponentMinio)
            pure (either (Left . readinessError) Right result)
    }
 where
  readyzError reason =
    StructuredError
      { errorPreconditionLabel = gatewayDaemonLivenessLabel
      , errorSummaryLine =
          "Gateway daemon kubelet readiness (/readyz) was not observed at "
            ++ endpointLabel
            ++ "."
      , errorOffendingItems =
          [(endpointLabel, "prodbox charts reconcile gateway")]
      , errorNarrative =
          unlines
            [ "Refused: gateway daemon /readyz did not report ready at "
                ++ endpointLabel
                ++ "."
            , "Observation: " ++ Text.unpack reason
            , "No object-store round trip was attempted."
            , "No Keycloak SMTP sync was started."
            , "Run `prodbox charts reconcile gateway`, confirm the daemon NodePort reports /readyz ready, then retry."
            ]
      }
  readinessError reason =
    StructuredError
      { errorPreconditionLabel = gatewayDaemonLivenessLabel
      , errorSummaryLine =
          "Gateway daemon object-store readiness was not observed at "
            ++ endpointLabel
            ++ "."
      , errorOffendingItems =
          [(endpointLabel, "prodbox charts reconcile gateway")]
      , errorNarrative =
          unlines
            [ "Refused: gateway daemon object-store readiness was not observed at "
                ++ endpointLabel
                ++ "."
            , "Observation: " ++ Text.unpack reason
            , "No Keycloak SMTP sync was started."
            , "Run `prodbox charts reconcile gateway`, confirm the daemon NodePort is ready, then retry."
            ]
      }

gatewayDaemonLivenessLabel :: String
gatewayDaemonLivenessLabel = "gatewayDaemonObjectStoreReady"
