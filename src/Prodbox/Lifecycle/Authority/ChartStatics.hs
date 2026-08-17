{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.26: one compiled source of truth for the retained home Lifecycle
-- Authority workload's static identities — the Pod ServiceAccount, the
-- least-privilege Vault Kubernetes-auth role, and the constant-time
-- liveness/readiness probe paths.
--
-- The authority's listen port is deployment configuration (@listener.port@ in
-- the mounted role Dhall), NOT a compiled static, so it is deliberately absent
-- here. What IS compiled is the authority's identity and its probe contract,
-- which must never drift from any other control-plane workload's (they are
-- physically separate workloads with distinct identities and failure domains).
--
-- The ServiceAccount name and the Vault role are the SAME identity
-- ('VaultRoleLifecycleAuthority'): the Pod authenticates to Vault Kubernetes
-- auth as this ServiceAccount, which is bound to the least-privilege role of the
-- same name. Unlike the broker (whose probe paths project the closed
-- 'Prodbox.Bootstrap.Broker.Routes' registry), the liveness and readiness paths
-- here are constant-time string constants — the agreed Sprint 3.26
-- simplification for the standing control-plane roles, whose runtime
-- interpreters (and therefore any route registry) land in Sprint 4.48.
module Prodbox.Lifecycle.Authority.ChartStatics
  ( LifecycleAuthorityChartStatics (..)
  , lifecycleAuthorityChartStatics
  , lifecycleAuthorityChartStaticsServiceAccountValue
  , lifecycleAuthorityRecoveryObserverValue
  , renderLifecycleAuthorityChartStaticsYaml
  , renderLifecycleAuthorityRecoveryObserverYaml
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Vault.RoleId (VaultRoleId (VaultRoleLifecycleAuthority), vaultRoleIdText)

-- | The Lifecycle Authority chart's compiled static identities.
data LifecycleAuthorityChartStatics = LifecycleAuthorityChartStatics
  { lifecycleAuthorityStaticNamespace :: Text
  , lifecycleAuthorityStaticServiceAccount :: Text
  , lifecycleAuthorityStaticVaultRole :: Text
  , lifecycleAuthorityStaticLivenessPath :: Text
  , lifecycleAuthorityStaticReadinessPath :: Text
  }
  deriving (Eq, Show)

-- | The one compiled instance. The ServiceAccount name and the Vault role are
-- the same least-privilege identity; the probe paths are constant-time string
-- constants (Sprint 3.26 simplification, not a route-registry projection).
lifecycleAuthorityChartStatics :: LifecycleAuthorityChartStatics
lifecycleAuthorityChartStatics =
  LifecycleAuthorityChartStatics
    { lifecycleAuthorityStaticNamespace = "lifecycle-authority"
    , lifecycleAuthorityStaticServiceAccount = vaultRoleIdText VaultRoleLifecycleAuthority
    , lifecycleAuthorityStaticVaultRole = vaultRoleIdText VaultRoleLifecycleAuthority
    , lifecycleAuthorityStaticLivenessPath = "/healthz"
    , lifecycleAuthorityStaticReadinessPath = "/readyz"
    }

-- | @serviceAccount@ block for the deployed values JSON.
lifecycleAuthorityChartStaticsServiceAccountValue :: Value
lifecycleAuthorityChartStaticsServiceAccountValue =
  object
    [ "name" .= lifecycleAuthorityStaticServiceAccount lifecycleAuthorityChartStatics
    ]

-- | Subject projected into the exact-name, GET-only recovery observer
-- RoleBindings owned by each recovery-profile chart namespace.
lifecycleAuthorityRecoveryObserverValue :: Value
lifecycleAuthorityRecoveryObserverValue =
  object
    [ "serviceAccountName"
        .= lifecycleAuthorityStaticServiceAccount lifecycleAuthorityChartStatics
    , "serviceAccountNamespace"
        .= lifecycleAuthorityStaticNamespace lifecycleAuthorityChartStatics
    ]

-- | The @lifecycle-authority-chart-statics.values@ generated section body. The
-- same typed statics feed the supported Haskell chart plan, so the committed
-- @values.yaml@ defaults cannot drift from the deployed values or the compiled
-- identity.
renderLifecycleAuthorityChartStaticsYaml :: String
renderLifecycleAuthorityChartStaticsYaml =
  unlines
    ( [ "serviceAccount:"
      , "  name: " ++ Text.unpack (lifecycleAuthorityStaticServiceAccount lifecycleAuthorityChartStatics)
      , "vault:"
      , "  role: " ++ Text.unpack (lifecycleAuthorityStaticVaultRole lifecycleAuthorityChartStatics)
      , "probes:"
      , "  liveness: " ++ Text.unpack (lifecycleAuthorityStaticLivenessPath lifecycleAuthorityChartStatics)
      , "  readiness: "
          ++ Text.unpack (lifecycleAuthorityStaticReadinessPath lifecycleAuthorityChartStatics)
      ]
        ++ recoveryObserverYamlLines
    )

-- | Generated values block shared by every chart that owns an exact recovery
-- observer Role/Binding.  The observing subject therefore cannot drift from
-- the Authority workload identity.
renderLifecycleAuthorityRecoveryObserverYaml :: String
renderLifecycleAuthorityRecoveryObserverYaml =
  unlines recoveryObserverYamlLines

recoveryObserverYamlLines :: [String]
recoveryObserverYamlLines =
  [ "recoveryObserver:"
  , "  serviceAccountName: "
      ++ Text.unpack
        (lifecycleAuthorityStaticServiceAccount lifecycleAuthorityChartStatics)
  , "  serviceAccountNamespace: "
      ++ Text.unpack
        (lifecycleAuthorityStaticNamespace lifecycleAuthorityChartStatics)
  ]
