{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.26: one compiled source of truth for the substrate-local Target
-- Secret Agent workload's static identities — the Pod ServiceAccount, the Vault
-- Kubernetes-auth role, and the constant-time liveness/readiness probe paths.
--
-- The agent delivers and reads allowlisted target-secret KV through Vault
-- Kubernetes auth. Its listen port is deployment configuration
-- (@listener.port@ in the mounted role Dhall), NOT a compiled static, so it is
-- deliberately absent here. What IS compiled is the agent's identity and its
-- probe contract, which must never drift from any other control-plane
-- workload's (they are physically separate workloads with distinct identities
-- and failure domains).
--
-- The ServiceAccount name and the Vault role are the SAME identity
-- ('VaultRoleTargetSecretAgent'): the Pod authenticates to Vault Kubernetes
-- auth as this ServiceAccount, which is bound to the least-privilege role of
-- the same name. The liveness and readiness paths are constant-time string
-- constants — the agreed Sprint 3.26 simplification, since the standing
-- control-plane roles do not carry a closed route registry — so a kubelet probe
-- stays a fixed, capability-free path.
module Prodbox.Lifecycle.TargetSecretAgent.ChartStatics
  ( TargetSecretAgentChartStatics (..)
  , targetSecretAgentChartStatics
  , targetSecretAgentChartStaticsServiceAccountValue
  , renderTargetSecretAgentChartStaticsYaml
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Vault.RoleId (VaultRoleId (..), vaultRoleIdText)

-- | The Target Secret Agent chart's compiled static identities.
data TargetSecretAgentChartStatics = TargetSecretAgentChartStatics
  { targetSecretAgentStaticServiceAccount :: Text
  , targetSecretAgentStaticVaultRole :: Text
  , targetSecretAgentStaticLivenessPath :: Text
  , targetSecretAgentStaticReadinessPath :: Text
  }
  deriving (Eq, Show)

-- | The one compiled instance. The ServiceAccount name and the Vault role are
-- the same least-privilege identity; the probe paths are constant-time string
-- constants (Sprint 3.26 simplification), so a kubelet probe can never point at
-- a capability-bearing path.
targetSecretAgentChartStatics :: TargetSecretAgentChartStatics
targetSecretAgentChartStatics =
  TargetSecretAgentChartStatics
    { targetSecretAgentStaticServiceAccount = vaultRoleIdText VaultRoleTargetSecretAgent
    , targetSecretAgentStaticVaultRole = vaultRoleIdText VaultRoleTargetSecretAgent
    , targetSecretAgentStaticLivenessPath = "/healthz"
    , targetSecretAgentStaticReadinessPath = "/readyz"
    }

-- | @serviceAccount@ block for the deployed values JSON.
targetSecretAgentChartStaticsServiceAccountValue :: Value
targetSecretAgentChartStaticsServiceAccountValue =
  object
    [ "name" .= targetSecretAgentStaticServiceAccount targetSecretAgentChartStatics
    ]

-- | The @target-secret-agent-chart-statics.values@ generated section body. The
-- same typed statics feed the supported Haskell chart plan, so the committed
-- @values.yaml@ defaults cannot drift from the deployed values or the compiled
-- identity.
renderTargetSecretAgentChartStaticsYaml :: String
renderTargetSecretAgentChartStaticsYaml =
  unlines
    [ "serviceAccount:"
    , "  name: " ++ Text.unpack (targetSecretAgentStaticServiceAccount targetSecretAgentChartStatics)
    , "vault:"
    , "  role: " ++ Text.unpack (targetSecretAgentStaticVaultRole targetSecretAgentChartStatics)
    , "probes:"
    , "  liveness: " ++ Text.unpack (targetSecretAgentStaticLivenessPath targetSecretAgentChartStatics)
    , "  readiness: " ++ Text.unpack (targetSecretAgentStaticReadinessPath targetSecretAgentChartStatics)
    ]
