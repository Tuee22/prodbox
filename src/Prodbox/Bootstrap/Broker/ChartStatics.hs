{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.26 (increment A): one compiled source of truth for the physically
-- separate Bootstrap Broker workload's static identities — the Pod
-- ServiceAccount, the bootstrap-only Vault Kubernetes-auth role, and the
-- constant-time liveness/readiness probe paths.
--
-- The broker's listen port is deployment configuration (@listener.listen_port@
-- in the mounted broker Dhall), NOT a compiled static, so it is deliberately
-- absent here: unlike the gateway, the broker binds a loopback-restricted
-- Service whose port the operator chooses per cluster. What IS compiled is the
-- broker's identity and its probe contract, which must never drift from the
-- Gateway Runtime's (they are physically separate workloads with distinct
-- identities and failure domains) nor from the closed 'BrokerRoute' registry.
--
-- The ServiceAccount name and the Vault role are the SAME identity
-- ('VaultRoleBootstrapBroker'): the Pod authenticates to Vault Kubernetes auth
-- as this ServiceAccount, which is bound to the bootstrap-only role of the same
-- name. The liveness and readiness paths are projections of the
-- 'Routes.BrokerHealth' and 'Routes.BrokerReadiness' routes, so a probe can
-- never point at a path the broker does not actually serve.
module Prodbox.Bootstrap.Broker.ChartStatics
  ( BrokerChartStatics (..)
  , brokerChartStatics
  , brokerChartStaticsServiceAccountValue
  , renderBrokerChartStaticsYaml
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Bootstrap.Broker.Routes qualified as Routes
import Prodbox.Vault.RoleId (VaultRoleId (VaultRoleBootstrapBroker), vaultRoleIdText)

-- | The Bootstrap Broker chart's compiled static identities.
data BrokerChartStatics = BrokerChartStatics
  { brokerStaticServiceAccount :: Text
  , brokerStaticVaultRole :: Text
  , brokerStaticLivenessPath :: Text
  , brokerStaticReadinessPath :: Text
  }
  deriving (Eq, Show)

-- | The one compiled instance. The ServiceAccount name and the Vault role are
-- the same bootstrap-only identity; the probe paths come from the closed route
-- registry so they cannot drift from the served routes.
brokerChartStatics :: BrokerChartStatics
brokerChartStatics =
  BrokerChartStatics
    { brokerStaticServiceAccount = vaultRoleIdText VaultRoleBootstrapBroker
    , brokerStaticVaultRole = vaultRoleIdText VaultRoleBootstrapBroker
    , brokerStaticLivenessPath = Text.pack (Routes.brokerRoutePath Routes.BrokerHealth)
    , brokerStaticReadinessPath = Text.pack (Routes.brokerRoutePath Routes.BrokerReadiness)
    }

-- | @serviceAccount@ block for the deployed values JSON.
brokerChartStaticsServiceAccountValue :: Value
brokerChartStaticsServiceAccountValue =
  object
    [ "name" .= brokerStaticServiceAccount brokerChartStatics
    ]

-- | The @bootstrap-broker-chart-statics.values@ generated section body. The
-- same typed statics feed the supported Haskell chart plan, so the committed
-- @values.yaml@ defaults cannot drift from the deployed values or the served
-- routes.
renderBrokerChartStaticsYaml :: String
renderBrokerChartStaticsYaml =
  unlines
    [ "serviceAccount:"
    , "  name: " ++ Text.unpack (brokerStaticServiceAccount brokerChartStatics)
    , "vault:"
    , "  role: " ++ Text.unpack (brokerStaticVaultRole brokerChartStatics)
    , "probes:"
    , "  liveness: " ++ Text.unpack (brokerStaticLivenessPath brokerChartStatics)
    , "  readiness: " ++ Text.unpack (brokerStaticReadinessPath brokerChartStatics)
    ]
