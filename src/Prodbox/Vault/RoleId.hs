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
data VaultRoleId
  = VaultRoleGatewayDaemon
  | VaultRoleBootstrapBroker
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
