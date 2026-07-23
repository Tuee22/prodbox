{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.26 (increment H+): one compiled source of truth for the always-on
-- Authority Backup Adapter workload's static identities — the Pod
-- ServiceAccount, the least-privilege Vault Kubernetes-auth role, and the
-- constant-time liveness/readiness probe paths.
--
-- The Authority Backup Adapter (home-only) reads ONLY
-- @secret/aws/authority-backup-store@ and backs up authority envelope/blob state
-- to its S3 prefix. It is a physically separate Deployment with its own identity
-- and failure domain, distinct from the Lifecycle Authority and from the Gateway
-- Runtime.
--
-- The ServiceAccount name and the Vault role are the SAME identity
-- ('VaultRoleAuthorityBackup'): the Pod authenticates to Vault Kubernetes auth
-- as this ServiceAccount, which is bound to the least-privilege role of the same
-- name. Unlike the Bootstrap Broker (whose probe paths project a closed route
-- registry), the standing-role probe paths are constant-time string constants
-- here — the agreed Sprint 3.26 simplification, since the @authority-backup@
-- runtime interpreter is deferred to Sprint 4.48.
module Prodbox.Lifecycle.AuthorityBackup.ChartStatics
  ( AuthorityBackupChartStatics (..)
  , authorityBackupChartStatics
  , authorityBackupChartStaticsServiceAccountValue
  , renderAuthorityBackupChartStaticsYaml
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Vault.RoleId (VaultRoleId (..), vaultRoleIdText)

-- | The Authority Backup Adapter chart's compiled static identities.
data AuthorityBackupChartStatics = AuthorityBackupChartStatics
  { authorityBackupStaticServiceAccount :: Text
  , authorityBackupStaticVaultRole :: Text
  , authorityBackupStaticLivenessPath :: Text
  , authorityBackupStaticReadinessPath :: Text
  }
  deriving (Eq, Show)

-- | The one compiled instance. The ServiceAccount name and the Vault role are
-- the same least-privilege identity; the probe paths are constant-time string
-- constants (Sprint 3.26 standing-role simplification).
authorityBackupChartStatics :: AuthorityBackupChartStatics
authorityBackupChartStatics =
  AuthorityBackupChartStatics
    { authorityBackupStaticServiceAccount = vaultRoleIdText VaultRoleAuthorityBackup
    , authorityBackupStaticVaultRole = vaultRoleIdText VaultRoleAuthorityBackup
    , authorityBackupStaticLivenessPath = "/healthz"
    , authorityBackupStaticReadinessPath = "/readyz"
    }

-- | @serviceAccount@ block for the deployed values JSON.
authorityBackupChartStaticsServiceAccountValue :: Value
authorityBackupChartStaticsServiceAccountValue =
  object
    [ "name" .= authorityBackupStaticServiceAccount authorityBackupChartStatics
    ]

-- | The @authority-backup-chart-statics.values@ generated section body. The
-- same typed statics feed the supported Haskell chart plan, so the committed
-- @values.yaml@ defaults cannot drift from the deployed values.
renderAuthorityBackupChartStaticsYaml :: String
renderAuthorityBackupChartStaticsYaml =
  unlines
    [ "serviceAccount:"
    , "  name: " ++ Text.unpack (authorityBackupStaticServiceAccount authorityBackupChartStatics)
    , "vault:"
    , "  role: " ++ Text.unpack (authorityBackupStaticVaultRole authorityBackupChartStatics)
    , "probes:"
    , "  liveness: " ++ Text.unpack (authorityBackupStaticLivenessPath authorityBackupChartStatics)
    , "  readiness: " ++ Text.unpack (authorityBackupStaticReadinessPath authorityBackupChartStatics)
    ]
