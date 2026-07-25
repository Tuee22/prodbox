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
    { -- The kubelet readiness probe is @/healthz@ (process reachable), NOT
      -- @/readyz@. The gateway daemon boots in a DEGRADED pre-Vault mode whose
      -- @/readyz@ is fail-closed 503 by design (it cannot prove an object-store
      -- round trip until Vault is unsealed), yet the pod MUST stay in its Service
      -- endpoints in that mode: the lifecycle reaches the daemon over the NodePort
      -- to drive Vault unseal, and only then does the Pod restart into full mode.
      -- Binding kubelet readiness to @/readyz@ (Sprint 2.34) pulled the degraded
      -- Pod out of its Service and deadlocked the pre-Vault bootstrap (the daemon
      -- could never be reached to unseal Vault). Fail-closed SERVING is enforced
      -- where it belongs — clients receive an explicit 503 from @/readyz@ and the
      -- real routes, the single-writer emitter Lease fences writes, and the
      -- lifecycle's @ComponentGatewayDaemonFull@ object-store round-trip gate is
      -- the authoritative full-readiness barrier — not at the kubelet/Service seam
      -- that the bootstrap depends on.
      gatewayProbeEndpoint = healthzProbeRoute
    , gatewayProbeInitialDelaySeconds = 5
    , gatewayProbePeriodSeconds = 10
    , gatewayProbeTimeoutSeconds = 1
    , gatewayProbeFailureThreshold = 3
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
