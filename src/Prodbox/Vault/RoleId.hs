{-# LANGUAGE OverloadedStrings #-}

-- | Typed identities for Vault Kubernetes-auth roles that are shared across
-- otherwise independent render and reconciliation layers.
module Prodbox.Vault.RoleId
  ( VaultRoleId (..)
  , vaultRoleIdText
  )
where

import Data.Text (Text)

-- | The closed inventory of shared Vault role identities. Role names owned by
-- chart-secret consumers remain data-driven in @VaultInventory@; this type
-- covers identities whose consumers span multiple production modules.
data VaultRoleId
  = VaultRoleGatewayDaemon
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Stable Vault Kubernetes-auth role name.
vaultRoleIdText :: VaultRoleId -> Text
vaultRoleIdText roleId =
  case roleId of
    VaultRoleGatewayDaemon -> "prodbox-gateway-daemon"
