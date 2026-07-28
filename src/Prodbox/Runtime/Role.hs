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
  | LifecycleAuthorityRuntime
  | ProviderWorkerRuntime
  | AuthorityBackupRuntime
  | TlsRetentionRuntime
  | TargetSecretAgentRuntime
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A role-indexed configuration identity.  Keeping this as a closed ADT makes
-- it impossible to request an unclassified, generic daemon configuration.
data RuntimeConfigIdentity
  = BootstrapBrokerConfig
  | GatewayRuntimeConfig
  | LifecycleAuthorityConfig
  | ProviderWorkerConfig
  | AuthorityBackupConfig
  | TlsRetentionConfig
  | TargetSecretAgentConfig
  deriving (Eq, Ord, Show, Enum, Bounded)

allRuntimeRoles :: [RuntimeRole]
allRuntimeRoles = [minBound .. maxBound]

runtimeRoleName :: RuntimeRole -> String
runtimeRoleName role = case role of
  BootstrapBroker -> "bootstrap-broker"
  GatewayRuntime -> "gateway-runtime"
  LifecycleAuthorityRuntime -> "lifecycle-authority"
  ProviderWorkerRuntime -> "provider-worker"
  AuthorityBackupRuntime -> "authority-backup"
  TlsRetentionRuntime -> "tls-retention"
  TargetSecretAgentRuntime -> "target-secret-agent"

runtimeRoleConfigIdentity :: RuntimeRole -> RuntimeConfigIdentity
runtimeRoleConfigIdentity role = case role of
  BootstrapBroker -> BootstrapBrokerConfig
  GatewayRuntime -> GatewayRuntimeConfig
  LifecycleAuthorityRuntime -> LifecycleAuthorityConfig
  ProviderWorkerRuntime -> ProviderWorkerConfig
  AuthorityBackupRuntime -> AuthorityBackupConfig
  TlsRetentionRuntime -> TlsRetentionConfig
  TargetSecretAgentRuntime -> TargetSecretAgentConfig

runtimeConfigIdentityRole :: RuntimeConfigIdentity -> RuntimeRole
runtimeConfigIdentityRole identity = case identity of
  BootstrapBrokerConfig -> BootstrapBroker
  GatewayRuntimeConfig -> GatewayRuntime
  LifecycleAuthorityConfig -> LifecycleAuthorityRuntime
  ProviderWorkerConfig -> ProviderWorkerRuntime
  AuthorityBackupConfig -> AuthorityBackupRuntime
  TlsRetentionConfig -> TlsRetentionRuntime
  TargetSecretAgentConfig -> TargetSecretAgentRuntime

runtimeConfigIdentityName :: RuntimeConfigIdentity -> String
runtimeConfigIdentityName identity = case identity of
  BootstrapBrokerConfig -> "bootstrap-broker-config-v1"
  GatewayRuntimeConfig -> "gateway-runtime-config-v1"
  LifecycleAuthorityConfig -> "lifecycle-authority-config-v1"
  ProviderWorkerConfig -> "provider-worker-config-v1"
  AuthorityBackupConfig -> "authority-backup-config-v1"
  TlsRetentionConfig -> "tls-retention-config-v1"
  TargetSecretAgentConfig -> "target-secret-agent-config-v1"

runtimeConfigMountDirectory :: RuntimeConfigIdentity -> FilePath
runtimeConfigMountDirectory identity = case identity of
  BootstrapBrokerConfig -> "/etc/bootstrap-broker/config"
  GatewayRuntimeConfig -> "/etc/gateway/config"
  LifecycleAuthorityConfig -> "/etc/lifecycle-authority/config"
  ProviderWorkerConfig -> "/etc/provider-worker/config"
  AuthorityBackupConfig -> "/etc/authority-backup/config"
  TlsRetentionConfig -> "/etc/tls-retention/config"
  TargetSecretAgentConfig -> "/etc/target-secret-agent/config"

runtimeConfigFileName :: RuntimeConfigIdentity -> FilePath
runtimeConfigFileName identity = case identity of
  BootstrapBrokerConfig -> "config.dhall"
  GatewayRuntimeConfig -> "config.dhall"
  LifecycleAuthorityConfig -> "config.dhall"
  ProviderWorkerConfig -> "config.dhall"
  AuthorityBackupConfig -> "config.dhall"
  TlsRetentionConfig -> "config.dhall"
  TargetSecretAgentConfig -> "config.dhall"

runtimeConfigMountPath :: RuntimeConfigIdentity -> FilePath
runtimeConfigMountPath identity =
  runtimeConfigMountDirectory identity </> runtimeConfigFileName identity
