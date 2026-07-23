{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.26: one compiled source of truth for the home-only TLS Retention
-- Adapter workload's static identities — the Pod ServiceAccount, the
-- least-privilege Vault Kubernetes-auth role, and the constant-time
-- liveness/readiness probe paths.
--
-- The adapter's listen port is deployment configuration (@listener.port@ in the
-- mounted role Dhall / chart values), NOT a compiled static, so it is
-- deliberately absent here. What IS compiled is the adapter's identity and its
-- probe contract, which must never drift from the Gateway Runtime's (they are
-- physically separate workloads with distinct identities and failure domains).
--
-- The ServiceAccount name and the Vault role are the SAME identity
-- ('VaultRoleTlsRetention'): the Pod authenticates to Vault Kubernetes auth as
-- this ServiceAccount, which is bound to the least-privilege role of the same
-- name (reading only @secret/aws/tls-retention-store@). The liveness and
-- readiness paths are constant-time string constants (the agreed Sprint 3.26
-- simplification — a probe can never point at a path the adapter does not
-- serve, and no route registry is consulted here).
module Prodbox.Lifecycle.TlsRetention.ChartStatics
  ( TlsRetentionChartStatics (..)
  , tlsRetentionChartStatics
  , tlsRetentionChartStaticsServiceAccountValue
  , renderTlsRetentionChartStaticsYaml
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Vault.RoleId (VaultRoleId (..), vaultRoleIdText)

-- | The TLS Retention Adapter chart's compiled static identities.
data TlsRetentionChartStatics = TlsRetentionChartStatics
  { tlsRetentionStaticServiceAccount :: Text
  , tlsRetentionStaticVaultRole :: Text
  , tlsRetentionStaticLivenessPath :: Text
  , tlsRetentionStaticReadinessPath :: Text
  }
  deriving (Eq, Show)

-- | The one compiled instance. The ServiceAccount name and the Vault role are
-- the same least-privilege identity; the probe paths are constant-time string
-- constants so they cannot drift from the served routes.
tlsRetentionChartStatics :: TlsRetentionChartStatics
tlsRetentionChartStatics =
  TlsRetentionChartStatics
    { tlsRetentionStaticServiceAccount = vaultRoleIdText VaultRoleTlsRetention
    , tlsRetentionStaticVaultRole = vaultRoleIdText VaultRoleTlsRetention
    , tlsRetentionStaticLivenessPath = "/healthz"
    , tlsRetentionStaticReadinessPath = "/readyz"
    }

-- | @serviceAccount@ block for the deployed values JSON.
tlsRetentionChartStaticsServiceAccountValue :: Value
tlsRetentionChartStaticsServiceAccountValue =
  object
    [ "name" .= tlsRetentionStaticServiceAccount tlsRetentionChartStatics
    ]

-- | The @tls-retention-chart-statics.values@ generated section body. The same
-- typed statics feed the supported Haskell chart plan, so the committed
-- @values.yaml@ defaults cannot drift from the deployed values or the served
-- routes.
renderTlsRetentionChartStaticsYaml :: String
renderTlsRetentionChartStaticsYaml =
  unlines
    [ "serviceAccount:"
    , "  name: " ++ Text.unpack (tlsRetentionStaticServiceAccount tlsRetentionChartStatics)
    , "vault:"
    , "  role: " ++ Text.unpack (tlsRetentionStaticVaultRole tlsRetentionChartStatics)
    , "probes:"
    , "  liveness: " ++ Text.unpack (tlsRetentionStaticLivenessPath tlsRetentionChartStatics)
    , "  readiness: " ++ Text.unpack (tlsRetentionStaticReadinessPath tlsRetentionChartStatics)
    ]
