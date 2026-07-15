{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Probe
  ( GatewayProbeSpec (..)
  , gatewayLifecycleProbeValues
  , gatewayLivenessProbe
  , gatewayProbeEndpointPath
  , gatewayReadinessProbe
  , renderGatewayProbeDefaultsYaml
  )
where

import Data.Aeson
  ( Value
  , object
  , (.=)
  )
import Prodbox.Gateway.Routes
  ( KubeletProbeRoute
  , healthzProbeRoute
  , kubeletProbeRoutePattern
  , readyzProbeRoute
  )

-- | Sprint 2.34: a kubelet probe's endpoint is a 'KubeletProbeRoute' — a
-- liveness or readiness route drawn from the compiled route registry
-- ("Prodbox.Gateway.Routes"). The old @GatewayProbeEndpoint@ enum (which held
-- the @/healthz@ / @/readyz@ literals independently) is deleted; a probe bound to
-- a diagnostic or RPC route is unbuildable by the registry smart constructor.
data GatewayProbeSpec = GatewayProbeSpec
  { gatewayProbeEndpoint :: KubeletProbeRoute
  , gatewayProbeInitialDelaySeconds :: Int
  , gatewayProbePeriodSeconds :: Int
  , gatewayProbeTimeoutSeconds :: Int
  , gatewayProbeFailureThreshold :: Int
  , gatewayProbeSuccessThreshold :: Int
  }
  deriving (Eq, Show)

gatewayLivenessProbe :: GatewayProbeSpec
gatewayLivenessProbe =
  GatewayProbeSpec
    { gatewayProbeEndpoint = healthzProbeRoute
    , gatewayProbeInitialDelaySeconds = 10
    , gatewayProbePeriodSeconds = 15
    , gatewayProbeTimeoutSeconds = 1
    , gatewayProbeFailureThreshold = 3
    , gatewayProbeSuccessThreshold = 1
    }

gatewayReadinessProbe :: GatewayProbeSpec
gatewayReadinessProbe =
  GatewayProbeSpec
    { gatewayProbeEndpoint = readyzProbeRoute
    , gatewayProbeInitialDelaySeconds = 5
    , gatewayProbePeriodSeconds = 10
    , gatewayProbeTimeoutSeconds = 1
    , -- Sprint 2.34: readiness now latches on the first proven object-store
      -- round trip since boot, so first-ready may lag process start by several
      -- reconnect intervals. The threshold rises 3 -> 6 to give that
      -- durable-authority proof grace before the kubelet pulls the Pod from its
      -- Service endpoints. Liveness stays at 3 (process health is immediate).
      gatewayProbeFailureThreshold = 6
    , gatewayProbeSuccessThreshold = 1
    }

gatewayProbeEndpointPath :: KubeletProbeRoute -> String
gatewayProbeEndpointPath = kubeletProbeRoutePattern

gatewayLifecycleProbeValues :: Value
gatewayLifecycleProbeValues =
  object
    [ "liveness" .= gatewayProbeValue gatewayLivenessProbe
    , "readiness" .= gatewayProbeValue gatewayReadinessProbe
    ]

gatewayProbeValue :: GatewayProbeSpec -> Value
gatewayProbeValue spec =
  object
    [ "path" .= gatewayProbeEndpointPath (gatewayProbeEndpoint spec)
    , "initialDelaySeconds" .= gatewayProbeInitialDelaySeconds spec
    , "periodSeconds" .= gatewayProbePeriodSeconds spec
    , "timeoutSeconds" .= gatewayProbeTimeoutSeconds spec
    , "failureThreshold" .= gatewayProbeFailureThreshold spec
    , "successThreshold" .= gatewayProbeSuccessThreshold spec
    ]

-- | Canonical static chart defaults. The same typed values are emitted into
-- the supported Haskell chart plan through 'gatewayLifecycleProbeValues'.
renderGatewayProbeDefaultsYaml :: String
renderGatewayProbeDefaultsYaml =
  unlines
    ( ["probes:"]
        ++ renderProbe "liveness" gatewayLivenessProbe
        ++ renderProbe "readiness" gatewayReadinessProbe
    )
 where
  renderProbe name spec =
    [ "  " ++ name ++ ":"
    , "    path: " ++ gatewayProbeEndpointPath (gatewayProbeEndpoint spec)
    , "    initialDelaySeconds: " ++ show (gatewayProbeInitialDelaySeconds spec)
    , "    periodSeconds: " ++ show (gatewayProbePeriodSeconds spec)
    , "    timeoutSeconds: " ++ show (gatewayProbeTimeoutSeconds spec)
    , "    failureThreshold: " ++ show (gatewayProbeFailureThreshold spec)
    , "    successThreshold: " ++ show (gatewayProbeSuccessThreshold spec)
    ]
