{-# LANGUAGE OverloadedStrings #-}

-- | Typed identities for Vault Kubernetes-auth roles that are shared across
-- otherwise independent render and reconciliation layers.
module Prodbox.Vault.RoleId
  ( VaultRoleId (..)
  , allVaultRoleIds
  , vaultRoleIdText
  )
where

import Data.Text (Text)

-- | The closed inventory of shared Vault role identities. Role names owned by
-- chart-secret consumers remain data-driven in @VaultInventory@; this type
-- covers identities whose consumers span multiple production modules.
--
-- Sprint 3.26 adds 'VaultRoleBootstrapBroker': the physically separate
-- pre-Vault Bootstrap Broker workload authenticates to Vault Kubernetes auth as
-- its own ServiceAccount bound to a bootstrap-only role, distinct from the
-- Gateway Runtime's mesh/DNS role. No two roles may share a name (the anti-
-- shared-identity invariant proved by 'test/unit/BrokerChartStatics.hs').
--
-- Sprint 3.26 also adds the five standing control-plane role identities — the
-- retained home Lifecycle Authority, the fenced Provider Worker, the Authority
-- Backup and TLS Retention Adapters, and the substrate-local Target Secret
-- Agent. Each is a physically separate workload with its own ServiceAccount
-- bound to a least-privilege Vault role of the same name (see
-- @Prodbox.Vault.Reconcile.defaultVaultReconcilePlan@ for the policy sets and
-- @documents/engineering/secret_derivation_doctrine.md@ for the inventory). The
-- production interpreters behind these workloads land in Phase 4.
data VaultRoleId
  = VaultRoleGatewayDaemon
  | VaultRoleBootstrapBroker
  | VaultRoleLifecycleAuthority
  | VaultRoleProviderWorker
  | VaultRoleAuthorityBackup
  | VaultRoleTlsRetention
  | VaultRoleTargetSecretAgent
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every role identity in the closed inventory.
allVaultRoleIds :: [VaultRoleId]
allVaultRoleIds = [minBound .. maxBound]

-- | Stable Vault Kubernetes-auth role name.
vaultRoleIdText :: VaultRoleId -> Text
vaultRoleIdText roleId =
  case roleId of
    VaultRoleGatewayDaemon -> "prodbox-gateway-daemon"
    VaultRoleBootstrapBroker -> "prodbox-bootstrap-broker"
    VaultRoleLifecycleAuthority -> "prodbox-lifecycle-authority"
    VaultRoleProviderWorker -> "prodbox-provider-worker"
    VaultRoleAuthorityBackup -> "prodbox-authority-backup"
    VaultRoleTlsRetention -> "prodbox-tls-retention"
    VaultRoleTargetSecretAgent -> "prodbox-target-secret-agent"
