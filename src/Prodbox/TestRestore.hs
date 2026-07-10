{-# LANGUAGE OverloadedStrings #-}

-- | Pure canonical-suite restore planning plus the typed daemon precondition
-- used by the SMTP restore step. Execution remains at the TestRunner boundary;
-- the plan is substrate-aware so the AWS harness can project from the same
-- sequence without importing TestRunner internals.
module Prodbox.TestRestore
  ( RestoreChart (..)
  , RestoreCyclePlan (..)
  , RestoreCycleStep (..)
  , RestoreKeycloakSmtp (..)
  , buildRestoreCyclePlan
  , gatewayDaemonLivenessPrecondition
  , restoreChartId
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.ComponentGraph
  ( ComponentId (..)
  , ReadinessProbe (..)
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

data RestoreKeycloakSmtp
  = RestoreWithoutKeycloakSmtp
  | RestoreWithKeycloakSmtp
  deriving (Eq, Show)

data RestoreCycleStep
  = RestoreDeleteChart !RestoreChart
  | RestoreEnsureGatewayMinioBootstrap
  | RestoreReconcileChart !RestoreChart
  | RestoreSyncKeycloakSmtp
  | RestoreWaitForPublicEdge
  deriving (Eq, Show)

data RestoreCyclePlan = RestoreCyclePlan
  { restoreCycleSubstrate :: !Substrate
  , restoreCycleSteps :: ![RestoreCycleStep]
  }
  deriving (Eq, Show)

-- | The one canonical destructive restore core. The optional SMTP action is
-- the sole permitted projection difference and is deliberately anchored after
-- gateway reconciliation and before every dependent chart.
buildRestoreCyclePlan :: Substrate -> RestoreKeycloakSmtp -> RestoreCyclePlan
buildRestoreCyclePlan substrate restoreSmtp =
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
    case restoreSmtp of
      RestoreWithoutKeycloakSmtp -> []
      RestoreWithKeycloakSmtp -> [RestoreSyncKeycloakSmtp]

-- | Adapt one gateway object-store observation into a composable, bounded,
-- fail-closed prerequisite. The caller supplies the real one-shot action and
-- loopback NodePort label; this module owns neither transport coordinates nor
-- a second polling loop.
gatewayDaemonLivenessPrecondition
  :: RetryPolicy
  -> String
  -> IO (Either Text ReadinessProbeResult)
  -> Precondition
gatewayDaemonLivenessPrecondition policy endpointLabel observeOnce =
  Precondition
    { preconditionLabel = gatewayDaemonLivenessLabel
    , preconditionCheck = do
        result <-
          waitForComponentReadiness
            policy
            ( BackendRoundTripTarget
                ComponentGatewayDaemonFull
                ComponentMinio
                observeOnce
            )
            (ProbeBackendRoundTrip ComponentMinio)
        pure (either (Left . readinessError) Right result)
    }
 where
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
