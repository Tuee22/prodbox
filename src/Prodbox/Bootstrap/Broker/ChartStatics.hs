{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.26 (increment A): one compiled source of truth for the physically
-- separate Bootstrap Broker workload's static identities — the Pod
-- ServiceAccount, the bootstrap-only Vault Kubernetes-auth role, and the
-- constant-time liveness/readiness probe paths.
--
-- __Standard-C correction (Sprint 3.35, 2026-08-13).__ This module used to say
-- that the broker's listen port is deployment configuration
-- (@listener.listen_port@ in the mounted broker Dhall), "NOT a compiled static",
-- chosen by the operator per cluster, and that it is therefore deliberately
-- absent here. Measured against source, that was false in the load-bearing
-- direction: 'Prodbox.ControlPlane.Runtime.runControlPlaneServer' — the one
-- server every control-plane role including this one is served by — bound a
-- port literal without consulting the role it was handed, and every rendering
-- path emitted the same literal independently. So the declared operator choice
-- did not exist, and the value had no owner for its restatements to drift from.
--
-- (The value is deliberately not spelled in this comment. Sprint 3.35's
-- @checkControlPlaneListenPortOwner@ named this file on its first run for
-- exactly that — a comment restating a value is still a restatement, per
-- [pure_fp_standards.md § 1.4](../../../../documents/engineering/pure_fp_standards.md).)
--
-- The port now has a compiled owner,
-- 'Prodbox.ControlPlane.ListenPort.controlPlaneListenPort', which the binder,
-- the rendered chart values, and the emitted broker Dhall all read. It stays
-- absent from this module for a different and true reason: it is a
-- control-plane-wide coordinate shared by six roles, not a Bootstrap-Broker
-- identity, so it belongs to the module that owns it rather than to this one.
--
-- What IS compiled here is the broker's identity and its probe contract, which
-- must never drift from the Gateway Runtime's (they are physically separate
-- workloads with distinct identities and failure domains) nor from the closed
-- 'BrokerRoute' registry.
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
  , brokerChartStaticsClientValue
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
  , brokerStaticClientServiceAccount :: Text
  , brokerStaticWorkerServiceAccount :: Text
  , brokerStaticWorkerImageRepository :: Text
  , brokerStaticTokenAudience :: Text
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
    , brokerStaticClientServiceAccount = "prodbox-bootstrap-broker-client"
    , brokerStaticWorkerServiceAccount = "prodbox-bootstrap-secret-worker"
    , brokerStaticWorkerImageRepository =
        "127.0.0.1:30080/prodbox/prodbox-runtime"
    , brokerStaticTokenAudience = "prodbox-bootstrap-broker"
    , brokerStaticVaultRole = vaultRoleIdText VaultRoleBootstrapBroker
    , brokerStaticLivenessPath = Text.pack (Routes.brokerRoutePath Routes.BrokerHealth)
    , brokerStaticReadinessPath = Text.pack (Routes.brokerRoutePath Routes.BrokerReadiness)
    }

-- | @serviceAccount@ block for the deployed values JSON.
brokerChartStaticsServiceAccountValue :: Value
brokerChartStaticsServiceAccountValue =
  object
    [ "name" .= brokerStaticServiceAccount brokerChartStatics
    , "workerName" .= brokerStaticWorkerServiceAccount brokerChartStatics
    ]

-- | Secret-free caller identity and custom TokenRequest audience. The client
-- account has no Vault role and cannot borrow the controller identity.
brokerChartStaticsClientValue :: Value
brokerChartStaticsClientValue =
  object
    [ "serviceAccountName" .= brokerStaticClientServiceAccount brokerChartStatics
    , "tokenAudience" .= brokerStaticTokenAudience brokerChartStatics
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
    , "  workerName: " ++ Text.unpack (brokerStaticWorkerServiceAccount brokerChartStatics)
    , "client:"
    , "  serviceAccountName: " ++ Text.unpack (brokerStaticClientServiceAccount brokerChartStatics)
    , "  tokenAudience: " ++ Text.unpack (brokerStaticTokenAudience brokerChartStatics)
    , "worker:"
    , "  imageRepository: " ++ Text.unpack (brokerStaticWorkerImageRepository brokerChartStatics)
    , "vault:"
    , "  role: " ++ Text.unpack (brokerStaticVaultRole brokerChartStatics)
    , "probes:"
    , "  liveness: " ++ Text.unpack (brokerStaticLivenessPath brokerChartStatics)
    , "  readiness: " ++ Text.unpack (brokerStaticReadinessPath brokerChartStatics)
    ]
