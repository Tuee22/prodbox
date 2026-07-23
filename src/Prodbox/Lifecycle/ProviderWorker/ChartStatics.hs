{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.26: one compiled source of truth for the fenced home-only Provider
-- Worker control-plane workload's static identities — the Pod ServiceAccount,
-- the least-privilege Vault Kubernetes-auth role, and the constant-time
-- liveness/readiness probe paths.
--
-- The worker's listen port is deployment configuration (@listener.port@ in the
-- mounted worker Dhall), NOT a compiled static, so it is deliberately absent
-- here. What IS compiled is the worker's identity and its probe contract, which
-- must never drift from the other control-plane workloads (they are physically
-- separate with distinct identities and failure domains).
--
-- The ServiceAccount name and the Vault role are the SAME identity
-- ('VaultRoleProviderWorker'): the Pod authenticates to Vault Kubernetes auth as
-- this ServiceAccount, which is bound to the fenced least-privilege role of the
-- same name (reading only @secret\/aws\/lifecycle-provider@). The liveness and
-- readiness paths are constant-time string constants (the agreed Sprint 3.26
-- simplification — probe paths are compiled literals here, not projections of a
-- route registry).
module Prodbox.Lifecycle.ProviderWorker.ChartStatics
  ( ProviderWorkerChartStatics (..)
  , providerWorkerChartStatics
  , providerWorkerChartStaticsServiceAccountValue
  , renderProviderWorkerChartStaticsYaml
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Vault.RoleId (VaultRoleId (..), vaultRoleIdText)

-- | The Provider Worker chart's compiled static identities.
data ProviderWorkerChartStatics = ProviderWorkerChartStatics
  { providerWorkerStaticServiceAccount :: Text
  , providerWorkerStaticVaultRole :: Text
  , providerWorkerStaticLivenessPath :: Text
  , providerWorkerStaticReadinessPath :: Text
  }
  deriving (Eq, Show)

-- | The one compiled instance. The ServiceAccount name and the Vault role are
-- the same fenced least-privilege identity; the probe paths are constant-time
-- string constants so they cannot drift from the served routes.
providerWorkerChartStatics :: ProviderWorkerChartStatics
providerWorkerChartStatics =
  ProviderWorkerChartStatics
    { providerWorkerStaticServiceAccount = vaultRoleIdText VaultRoleProviderWorker
    , providerWorkerStaticVaultRole = vaultRoleIdText VaultRoleProviderWorker
    , providerWorkerStaticLivenessPath = "/healthz"
    , providerWorkerStaticReadinessPath = "/readyz"
    }

-- | @serviceAccount@ block for the deployed values JSON.
providerWorkerChartStaticsServiceAccountValue :: Value
providerWorkerChartStaticsServiceAccountValue =
  object
    [ "name" .= providerWorkerStaticServiceAccount providerWorkerChartStatics
    ]

-- | The @provider-worker-chart-statics.values@ generated section body. The same
-- typed statics feed the supported Haskell chart plan, so the committed
-- @values.yaml@ defaults cannot drift from the deployed values or the served
-- routes.
renderProviderWorkerChartStaticsYaml :: String
renderProviderWorkerChartStaticsYaml =
  unlines
    [ "serviceAccount:"
    , "  name: " ++ Text.unpack (providerWorkerStaticServiceAccount providerWorkerChartStatics)
    , "vault:"
    , "  role: " ++ Text.unpack (providerWorkerStaticVaultRole providerWorkerChartStatics)
    , "probes:"
    , "  liveness: " ++ Text.unpack (providerWorkerStaticLivenessPath providerWorkerChartStatics)
    , "  readiness: " ++ Text.unpack (providerWorkerStaticReadinessPath providerWorkerChartStatics)
    ]
