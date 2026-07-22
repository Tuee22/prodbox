-- | Closed runtime-role and mounted-configuration identities.
--
-- A process selects one role before it decodes configuration.  The mapping is
-- deliberately total and carries exactly one canonical mount per role; there is
-- no shared daemon config and no fallback path from one role to the other.
module Prodbox.Runtime.Role
  ( RuntimeRole (..)
  , RuntimeConfigIdentity (..)
  , allRuntimeRoles
  , runtimeRoleName
  , runtimeRoleConfigIdentity
  , runtimeConfigIdentityRole
  , runtimeConfigIdentityName
  , runtimeConfigMountDirectory
  , runtimeConfigFileName
  , runtimeConfigMountPath
  )
where

import System.FilePath ((</>))

-- | The closed set of long-running roles in the gateway/bootstrap split.
data RuntimeRole
  = BootstrapBroker
  | GatewayRuntime
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A role-indexed configuration identity.  Keeping this as a closed ADT makes
-- it impossible to request an unclassified, generic daemon configuration.
data RuntimeConfigIdentity
  = BootstrapBrokerConfig
  | GatewayRuntimeConfig
  deriving (Eq, Ord, Show, Enum, Bounded)

allRuntimeRoles :: [RuntimeRole]
allRuntimeRoles = [minBound .. maxBound]

runtimeRoleName :: RuntimeRole -> String
runtimeRoleName role = case role of
  BootstrapBroker -> "bootstrap-broker"
  GatewayRuntime -> "gateway-runtime"

runtimeRoleConfigIdentity :: RuntimeRole -> RuntimeConfigIdentity
runtimeRoleConfigIdentity role = case role of
  BootstrapBroker -> BootstrapBrokerConfig
  GatewayRuntime -> GatewayRuntimeConfig

runtimeConfigIdentityRole :: RuntimeConfigIdentity -> RuntimeRole
runtimeConfigIdentityRole identity = case identity of
  BootstrapBrokerConfig -> BootstrapBroker
  GatewayRuntimeConfig -> GatewayRuntime

runtimeConfigIdentityName :: RuntimeConfigIdentity -> String
runtimeConfigIdentityName identity = case identity of
  BootstrapBrokerConfig -> "bootstrap-broker-config-v1"
  GatewayRuntimeConfig -> "gateway-runtime-config-v1"

runtimeConfigMountDirectory :: RuntimeConfigIdentity -> FilePath
runtimeConfigMountDirectory identity = case identity of
  BootstrapBrokerConfig -> "/etc/bootstrap-broker/config"
  GatewayRuntimeConfig -> "/etc/gateway/config"

runtimeConfigFileName :: RuntimeConfigIdentity -> FilePath
runtimeConfigFileName identity = case identity of
  BootstrapBrokerConfig -> "config.dhall"
  GatewayRuntimeConfig -> "config.dhall"

runtimeConfigMountPath :: RuntimeConfigIdentity -> FilePath
runtimeConfigMountPath identity =
  runtimeConfigMountDirectory identity </> runtimeConfigFileName identity
