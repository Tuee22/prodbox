{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Probe
  ( GatewayProbeEndpoint (..)
  , GatewayProbeSpec (..)
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

-- | The closed set of constant-time lifecycle projections exposed by the
-- gateway daemon. Operational diagnostics such as @/v1/state@ deliberately
-- have no constructor here.
data GatewayProbeEndpoint
  = GatewayHealthz
  | GatewayReadyz
  deriving (Eq, Show)

data GatewayProbeSpec = GatewayProbeSpec
  { gatewayProbeEndpoint :: GatewayProbeEndpoint
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
    { gatewayProbeEndpoint = GatewayHealthz
    , gatewayProbeInitialDelaySeconds = 10
    , gatewayProbePeriodSeconds = 15
    , gatewayProbeTimeoutSeconds = 1
    , gatewayProbeFailureThreshold = 3
    , gatewayProbeSuccessThreshold = 1
    }

gatewayReadinessProbe :: GatewayProbeSpec
gatewayReadinessProbe =
  GatewayProbeSpec
    { gatewayProbeEndpoint = GatewayReadyz
    , gatewayProbeInitialDelaySeconds = 5
    , gatewayProbePeriodSeconds = 10
    , gatewayProbeTimeoutSeconds = 1
    , gatewayProbeFailureThreshold = 3
    , gatewayProbeSuccessThreshold = 1
    }

gatewayProbeEndpointPath :: GatewayProbeEndpoint -> String
gatewayProbeEndpointPath endpoint =
  case endpoint of
    GatewayHealthz -> "/healthz"
    GatewayReadyz -> "/readyz"

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
