{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.18: typed chart-secret inventory for Vault Kubernetes auth.
-- This is the Vault-native successor to the master-seed inventory retired by
-- Sprint 3.19; it names least-privilege read grants before chart consumers are
-- switched from derived or chart-generated secrets to direct Vault reads.
module Prodbox.Secret.VaultInventory
  ( VaultSecretPath (..)
  , VaultSecretFieldSource (..)
  , VaultSecretFieldSpec (..)
  , VaultSecretObjectSpec (..)
  , VaultSecretConsumer (..)
  , VaultSecretBootstrapAction (..)
  , VaultSecretBootstrapStep (..)
  , VaultSecretBootstrapError (..)
  , VaultSecretBootstrapOps (..)
  , VaultSecretObservation (..)
  , vaultSecretConsumerKvApiPaths
  , vaultSecretConsumerPolicyDocument
  , vaultSecretPathName
  , vaultSecretObjectFieldNames
  , chartVaultManagedSecretObjects
  , chartVaultSecretObjects
  , chartVaultSecretConsumers
  , vaultSecretConsumerByName
  , vaultIdentityRegistryViolations
  , generateVaultSecretFieldValue
  , runVaultSecretBootstrapWith
  )
where

import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString.Base64.URL qualified as B64Url
import Data.Char
  ( isAsciiLower
  , isAsciiUpper
  , isDigit
  )
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Minio.RootCredential (minioRootPassword, minioRootUser)
import Prodbox.Vault.Client (VaultCasOutcome)
import Prodbox.Vault.RoleId (allVaultRoleIds, vaultRoleIdText)

data VaultSecretPath = VaultSecretPath
  { vaultSecretPathMount :: Text
  , vaultSecretPathLogical :: Text
  }
  deriving (Eq, Ord, Show)

data VaultSecretFieldSource
  = VaultSecretGenerated Text
  | VaultSecretStatic Text
  | VaultSecretExternal
  deriving (Eq, Show)

data VaultSecretFieldSpec = VaultSecretFieldSpec
  { vaultSecretFieldName :: Text
  , vaultSecretFieldSource :: VaultSecretFieldSource
  }
  deriving (Eq, Show)

data VaultSecretObjectSpec = VaultSecretObjectSpec
  { vaultSecretObjectPath :: VaultSecretPath
  , vaultSecretObjectFields :: [VaultSecretFieldSpec]
  }
  deriving (Eq, Show)

data VaultSecretConsumer = VaultSecretConsumer
  { vaultSecretConsumerName :: Text
  , vaultSecretConsumerPolicyName :: Text
  , vaultSecretConsumerRoleName :: Text
  , vaultSecretConsumerNamespaces :: [Text]
  , vaultSecretConsumerServiceAccounts :: [Text]
  , vaultSecretConsumerKvPaths :: [VaultSecretPath]
  , vaultSecretConsumerTtl :: Text
  }
  deriving (Eq, Show)

data VaultSecretBootstrapAction
  = VaultSecretBootstrapPresent
  | VaultSecretBootstrapCreated
  | VaultSecretBootstrapUpdatedMissingFields
  deriving (Eq, Show)

data VaultSecretBootstrapStep = VaultSecretBootstrapStep
  { vaultSecretBootstrapStepPath :: VaultSecretPath
  , vaultSecretBootstrapStepAction :: VaultSecretBootstrapAction
  , vaultSecretBootstrapStepFields :: [Text]
  }
  deriving (Eq, Show)

data VaultSecretBootstrapError
  = VaultSecretBootstrapReadFailed VaultSecretPath HttpError
  | -- | Sprint 4.74: a bootstrap write's failure is a CAS outcome, not a bare
    -- transport error. The fold unions generated fields onto what it read, so
    -- "another writer changed this object" and "Vault did not answer" call for
    -- different responses and used to arrive as the same value.
    VaultSecretBootstrapWriteFailed VaultSecretPath VaultCasOutcome
  | VaultSecretBootstrapExternalFieldMissing VaultSecretPath Text
  deriving (Eq, Show)

-- | What a bootstrap read found, carrying the version a conditional write must
-- be conditioned on.
--
-- Sprint 4.71: the read used to answer a bare field map, which is why the write
-- that followed it could only be unconditional. The bootstrap fold is a
-- read-modify-write — it unions generated fields onto what it observed — so an
-- unconditional write silently loses a concurrent writer's generated field.
data VaultSecretObservation
  = VaultSecretObjectAbsent
  | VaultSecretObjectPresent !Natural !(Map Text Text)
  deriving (Eq, Show)

data VaultSecretBootstrapOps = VaultSecretBootstrapOps
  { vaultSecretBootstrapObserve
      :: VaultSecretPath -> IO (Either HttpError VaultSecretObservation)
  , vaultSecretBootstrapWrite
      :: VaultSecretPath
      -> Natural
      -- \^ The version the write is conditioned on. @0@ is Vault's own
      -- create-if-absent, so an absent observation and a present one are the
      -- same call with different evidence rather than two code paths.
      -> Map Text Text
      -> IO (Either VaultCasOutcome ())
  , vaultSecretBootstrapGenerate :: VaultSecretFieldSpec -> IO Text
  }

vaultSecretConsumerKvApiPaths :: VaultSecretConsumer -> [Text]
vaultSecretConsumerKvApiPaths =
  map vaultSecretPathApiPath . vaultSecretConsumerKvPaths

vaultSecretObjectFieldNames :: VaultSecretObjectSpec -> [Text]
vaultSecretObjectFieldNames =
  map vaultSecretFieldName . vaultSecretObjectFields

vaultSecretPathName :: VaultSecretPath -> Text
vaultSecretPathName path =
  vaultSecretPathMount path <> "/" <> vaultSecretPathLogical path

vaultSecretConsumerPolicyDocument :: VaultSecretConsumer -> Text
vaultSecretConsumerPolicyDocument consumer =
  Text.intercalate "\n" (map readRule (vaultSecretConsumerKvPaths consumer))
 where
  readRule path =
    Text.unlines
      [ "path \"" <> vaultSecretPathApiPath path <> "\" {"
      , "  capabilities = [\"read\"]"
      , "}"
      ]

vaultSecretConsumerByName :: Text -> Maybe VaultSecretConsumer
vaultSecretConsumerByName name =
  find ((== name) . vaultSecretConsumerName) chartVaultSecretConsumers

-- | Sprint 3.26: the compiled Vault identity registry must be collision-free.
-- Every Vault Kubernetes-auth role name and every chart-secret policy name is
-- bound by at most one identity across BOTH the cross-module 'VaultRoleId'
-- inventory (the workloads whose role identity is a compiled constant, e.g. the
-- Gateway Runtime and the Bootstrap Broker) AND the data-driven chart-secret
-- consumers. If two identities shared a role name, materializing them would
-- silently widen one workload's authority to the other's ServiceAccounts; if two
-- shared a policy name, one policy document would overwrite the other. This is
-- the "identities exist exactly once as a compiled closed registry value"
-- invariant (lifecycle_control_plane_architecture.md § 10.2), previously
-- unenforced between the two role-name sources. Returns a violation per
-- colliding name; empty means the registry is collision-free.
vaultIdentityRegistryViolations :: [String]
vaultIdentityRegistryViolations =
  concat
    [ [ "chart-secret consumer role name `"
          <> Text.unpack name
          <> "` is defined by more than one consumer in the closed Vault identity registry"
      | name <- duplicateNames consumerRoleNames
      ]
    , [ "chart-secret consumer policy name `"
          <> Text.unpack name
          <> "` is defined by more than one consumer in the closed Vault identity registry"
      | name <- duplicateNames consumerPolicyNames
      ]
    , [ "Vault Kubernetes-auth role name `"
          <> Text.unpack name
          <> "` collides between the cross-module VaultRoleId registry and a chart-secret consumer"
      | name <- roleIdNames
      , name `elem` consumerRoleNames
      ]
    ]
 where
  roleIdNames = map vaultRoleIdText allVaultRoleIds
  consumerRoleNames = map vaultSecretConsumerRoleName chartVaultSecretConsumers
  consumerPolicyNames = map vaultSecretConsumerPolicyName chartVaultSecretConsumers
  duplicateNames names =
    [ name
    | (name, count) <- Map.toList (Map.fromListWith (+) [(n, 1 :: Int) | n <- names])
    , count > (1 :: Int)
    ]

chartVaultSecretConsumers :: [VaultSecretConsumer]
chartVaultSecretConsumers =
  [ keycloakPostgresConsumer "keycloak" "keycloak-postgres"
  , keycloakPostgresConsumer "vscode" "keycloak-postgres"
  , keycloakRuntimeConsumer "keycloak-runtime" "keycloak" "keycloak"
  , keycloakRuntimeConsumer "vscode-keycloak-runtime" "vscode-keycloak" "vscode"
  , VaultSecretConsumer
      { vaultSecretConsumerName = "oidc-session-validation"
      , vaultSecretConsumerPolicyName = "oidc-session-validation"
      , vaultSecretConsumerRoleName = "oidc-session-validation"
      , vaultSecretConsumerNamespaces = ["vscode"]
      , vaultSecretConsumerServiceAccounts = ["oidc-session-validation-agent"]
      , vaultSecretConsumerKvPaths =
          [VaultSecretPath "secret" "vscode/oidc/demo-user"]
      , vaultSecretConsumerTtl = "15m"
      }
  , VaultSecretConsumer
      { vaultSecretConsumerName = "vscode-oidc"
      , vaultSecretConsumerPolicyName = "vscode-oidc"
      , vaultSecretConsumerRoleName = "vscode-oidc"
      , vaultSecretConsumerNamespaces = ["vscode"]
      , vaultSecretConsumerServiceAccounts = ["vscode-oidc-secret-materializer"]
      , vaultSecretConsumerKvPaths =
          [VaultSecretPath "secret" "vscode/oidc/vscode"]
      , vaultSecretConsumerTtl = "1h"
      }
  , VaultSecretConsumer
      { vaultSecretConsumerName = "minio-admin-oidc"
      , vaultSecretConsumerPolicyName = "minio-admin-oidc"
      , vaultSecretConsumerRoleName = "minio-admin-oidc"
      , vaultSecretConsumerNamespaces = ["prodbox"]
      , vaultSecretConsumerServiceAccounts = ["minio-admin-oidc-materializer"]
      , vaultSecretConsumerKvPaths =
          [VaultSecretPath "secret" "vscode/oidc/vscode"]
      , vaultSecretConsumerTtl = "15m"
      }
  , VaultSecretConsumer
      { vaultSecretConsumerName = "api-oidc"
      , vaultSecretConsumerPolicyName = "api-oidc"
      , vaultSecretConsumerRoleName = "api-oidc"
      , vaultSecretConsumerNamespaces = ["api"]
      , vaultSecretConsumerServiceAccounts = ["api"]
      , vaultSecretConsumerKvPaths =
          [VaultSecretPath "secret" "vscode/oidc/prodbox-api"]
      , vaultSecretConsumerTtl = "1h"
      }
  , VaultSecretConsumer
      { vaultSecretConsumerName = "websocket-oidc"
      , vaultSecretConsumerPolicyName = "websocket-oidc"
      , vaultSecretConsumerRoleName = "websocket-oidc"
      , vaultSecretConsumerNamespaces = ["websocket"]
      , vaultSecretConsumerServiceAccounts = ["websocket"]
      , vaultSecretConsumerKvPaths =
          [VaultSecretPath "secret" "vscode/oidc/prodbox-websocket"]
      , vaultSecretConsumerTtl = "1h"
      }
  , VaultSecretConsumer
      { vaultSecretConsumerName = "keycloak-smtp"
      , vaultSecretConsumerPolicyName = "keycloak-smtp"
      , vaultSecretConsumerRoleName = "keycloak-smtp"
      , vaultSecretConsumerNamespaces = ["keycloak", "vscode"]
      , vaultSecretConsumerServiceAccounts = ["keycloak"]
      , vaultSecretConsumerKvPaths = [VaultSecretPath "secret" "keycloak/smtp"]
      , vaultSecretConsumerTtl = "1h"
      }
  , VaultSecretConsumer
      { vaultSecretConsumerName = "gateway-event-keys"
      , vaultSecretConsumerPolicyName = "gateway-gateway"
      , vaultSecretConsumerRoleName = "gateway-gateway"
      , vaultSecretConsumerNamespaces = ["gateway"]
      , vaultSecretConsumerServiceAccounts = ["prodbox-gateway-daemon"]
      , vaultSecretConsumerKvPaths =
          [ VaultSecretPath "secret" "gateway/gateway/node-a/event-key"
          , VaultSecretPath "secret" "gateway/gateway/node-b/event-key"
          , VaultSecretPath "secret" "gateway/gateway/node-c/event-key"
          , VaultSecretPath "secret" "aws/gateway-dns"
          , VaultSecretPath "secret" "gateway/gateway/minio"
          ]
      , vaultSecretConsumerTtl = "1h"
      }
  , VaultSecretConsumer
      { vaultSecretConsumerName = "gateway-minio-bootstrap"
      , vaultSecretConsumerPolicyName = "gateway-minio-bootstrap"
      , vaultSecretConsumerRoleName = "gateway-minio-bootstrap"
      , vaultSecretConsumerNamespaces = ["prodbox"]
      , vaultSecretConsumerServiceAccounts = ["minio"]
      , vaultSecretConsumerKvPaths =
          [ VaultSecretPath "secret" "minio/root"
          , VaultSecretPath "secret" "gateway/gateway/minio"
          , VaultSecretPath "secret" "minio/lifecycle-authority"
          ]
      , vaultSecretConsumerTtl = "1h"
      }
  , VaultSecretConsumer
      { vaultSecretConsumerName = "minio-root"
      , vaultSecretConsumerPolicyName = "minio"
      , vaultSecretConsumerRoleName = "minio"
      , vaultSecretConsumerNamespaces = ["prodbox"]
      , vaultSecretConsumerServiceAccounts = ["minio"]
      , vaultSecretConsumerKvPaths = [VaultSecretPath "secret" "minio/root"]
      , vaultSecretConsumerTtl = "1h"
      }
  , -- Sprint 7.15: the ACME EAB material (ZeroSSL external-account-binding
    -- key ID + HMAC key) lives at secret/acme/eab. The in-cluster EAB
    -- secret materializer (SA acme-eab-secret-materializer in cert-manager,
    -- rendered by Prodbox.CLI.Rke2.acmeEabMaterializerManifests) reads it via
    -- Vault Kubernetes auth (policy/role "acme") and materializes the
    -- acme-eab-credentials Secret that the ZeroSSL ClusterIssuer references.
    VaultSecretConsumer
      { vaultSecretConsumerName = "acme"
      , vaultSecretConsumerPolicyName = "acme"
      , vaultSecretConsumerRoleName = "acme"
      , vaultSecretConsumerNamespaces = ["cert-manager"]
      , vaultSecretConsumerServiceAccounts = ["acme-eab-secret-materializer"]
      , vaultSecretConsumerKvPaths = [VaultSecretPath "secret" "acme/eab"]
      , vaultSecretConsumerTtl = "1h"
      }
  , -- Home cert-manager has a distinct LongLived Route 53 identity. The AWS
    -- run-scoped counterpart below is bound to a different target ServiceAccount.
    VaultSecretConsumer
      { vaultSecretConsumerName = "cert-manager-home-dns01"
      , vaultSecretConsumerPolicyName = "aws-cert-manager-home"
      , vaultSecretConsumerRoleName = "aws-cert-manager-home"
      , vaultSecretConsumerNamespaces = ["cert-manager"]
      , vaultSecretConsumerServiceAccounts = ["home-dns01-secret-materializer"]
      , vaultSecretConsumerKvPaths =
          [VaultSecretPath "secret" "aws/cert-manager/home/dns01"]
      , vaultSecretConsumerTtl = "1h"
      }
  , -- EKS-only target projection. The role cannot read the home DNS identity.
    VaultSecretConsumer
      { vaultSecretConsumerName = "cert-manager-aws-dns01"
      , vaultSecretConsumerPolicyName = "aws-cert-manager-run"
      , vaultSecretConsumerRoleName = "aws-cert-manager-run"
      , vaultSecretConsumerNamespaces = ["cert-manager"]
      , vaultSecretConsumerServiceAccounts = ["aws-dns01-target-materializer"]
      , vaultSecretConsumerKvPaths =
          [VaultSecretPath "secret" "aws/cert-manager/aws/dns01"]
      , vaultSecretConsumerTtl = "1h"
      }
  ]

chartVaultSecretObjects :: [VaultSecretObjectSpec]
chartVaultSecretObjects =
  concat
    [ keycloakPostgresObjects "keycloak" "keycloak-postgres"
    , keycloakPostgresObjects "vscode" "keycloak-postgres"
    , keycloakRuntimeObjects "keycloak"
    , keycloakRuntimeObjects "vscode"
    , oidcObjects "keycloak"
    , oidcObjects "vscode"
    ,
      [ kvObject
          "secret"
          "keycloak/smtp"
          [ externalField "host"
          , externalField "port"
          , externalField "from"
          , externalField "from_display_name"
          , externalField "reply_to"
          , externalField "username"
          , externalField "password"
          ]
      , kvObject
          "secret"
          "gateway/gateway/node-a/event-key"
          [generatedField "key" "gateway-event-key"]
      , kvObject
          "secret"
          "gateway/gateway/node-b/event-key"
          [generatedField "key" "gateway-event-key"]
      , kvObject
          "secret"
          "gateway/gateway/node-c/event-key"
          [generatedField "key" "gateway-event-key"]
      , -- The Credential Provisioner and Target Secret Agent own these
        -- external fields.  Bootstrap declares their closed schemas but never
        -- generates or substitutes credential bytes.
        kvObject
          "secret"
          "aws/lifecycle-provider"
          awsCredentialFields
      , kvObject
          "secret"
          "aws/gateway-dns"
          awsCredentialFields
      , kvObject
          "secret"
          "aws/cert-manager/home/dns01"
          awsCredentialFields
      , -- Registered for the AWS-target projection. It is absent from the
        -- home first-reconcile plan and from every home DNS01 read grant.
        kvObject
          "secret"
          "aws/cert-manager/aws/dns01"
          awsCredentialFields
      , -- Sprint 4.50: long-lived IAM credentials scoped only to the
        -- Authority Backup Adapter's compiled S3 prefixes. The AWS harness
        -- authors these fields; bootstrap never synthesizes them.
        kvObject
          "secret"
          "aws/authority-backup-store"
          awsCredentialFields
      , -- Sprint 4.50: a distinct long-lived IAM credential for the exact
        -- canonical public-edge TLS retention prefixes. It is intentionally
        -- not substitutable for the Authority Backup credential above.
        kvObject
          "secret"
          "aws/tls-retention-store"
          awsCredentialFields
      , kvObject
          "secret"
          "gateway/gateway/minio"
          [ staticField "minio_access_key" "prodbox-gateway"
          , generatedField "minio_secret_key" "gateway-minio-secret-key"
          ]
      , kvObject
          "secret"
          "minio/lifecycle-authority"
          [ staticField "minio_access_key" "prodbox-lifecycle-authority"
          , generatedField "minio_secret_key" "lifecycle-authority-minio-secret-key"
          ]
      , kvObject
          "secret"
          "minio/root"
          [ staticField "rootUser" (Text.pack minioRootUser)
          , staticField "rootPassword" (Text.pack minioRootPassword)
          ]
      , kvObject
          "secret"
          "object-store/hmac"
          [generatedField "key" "object-store-hmac-key"]
      , kvObject
          "secret"
          "federation/hmac"
          [generatedField "key" "federation-hmac-key"]
      , -- Sprint 7.15: ZeroSSL EAB material. Both fields are external —
        -- the key ID and HMAC key are issued by ZeroSSL and supplied by
        -- the operator/harness (`prodbox config setup` or `vault kv put`),
        -- never randomly generated, so they are not auto-seeded.
        kvObject
          "secret"
          "acme/eab"
          [externalField "key_id", externalField "hmac_key"]
      ]
    ]
 where
  awsCredentialFields =
    [ externalField "access_key_id"
    , externalField "secret_access_key"
    , externalField "session_token"
    , externalField "region"
    ]

chartVaultManagedSecretObjects :: [VaultSecretObjectSpec]
chartVaultManagedSecretObjects =
  filter (all isManagedField . vaultSecretObjectFields) chartVaultSecretObjects
 where
  isManagedField field =
    case vaultSecretFieldSource field of
      VaultSecretExternal -> False
      VaultSecretGenerated _ -> True
      VaultSecretStatic _ -> True

keycloakPostgresConsumer :: Text -> Text -> VaultSecretConsumer
keycloakPostgresConsumer namespace release =
  VaultSecretConsumer
    { vaultSecretConsumerName = namespace <> "-keycloak-postgres"
    , vaultSecretConsumerPolicyName = namespace <> "-" <> release <> "-pg"
    , vaultSecretConsumerRoleName = namespace <> "-" <> release <> "-pg"
    , vaultSecretConsumerNamespaces = [namespace]
    , vaultSecretConsumerServiceAccounts = ["prodbox-" <> namespace <> "-pg"]
    , vaultSecretConsumerKvPaths =
        [ VaultSecretPath "secret" (namespace <> "/" <> release <> "/patroni/app")
        , VaultSecretPath "secret" (namespace <> "/" <> release <> "/patroni/superuser")
        , VaultSecretPath "secret" (namespace <> "/" <> release <> "/patroni/standby")
        ]
    , vaultSecretConsumerTtl = "1h"
    }

keycloakRuntimeConsumer :: Text -> Text -> Text -> VaultSecretConsumer
keycloakRuntimeConsumer name policyName namespace =
  VaultSecretConsumer
    { vaultSecretConsumerName = name
    , vaultSecretConsumerPolicyName = policyName
    , vaultSecretConsumerRoleName = policyName
    , vaultSecretConsumerNamespaces = [namespace]
    , vaultSecretConsumerServiceAccounts = ["keycloak"]
    , vaultSecretConsumerKvPaths =
        [ VaultSecretPath "secret" (keycloakAdminPath namespace)
        , VaultSecretPath
            "secret"
            (keycloakPostgresAppPath namespace "keycloak-postgres")
        , VaultSecretPath "secret" (namespace <> "/oidc/vscode")
        , VaultSecretPath "secret" (namespace <> "/oidc/prodbox-api")
        , VaultSecretPath "secret" (namespace <> "/oidc/prodbox-websocket")
        , VaultSecretPath "secret" (namespace <> "/oidc/demo-user")
        , VaultSecretPath "secret" "keycloak/smtp"
        ]
    , vaultSecretConsumerTtl = "1h"
    }

keycloakPostgresObjects :: Text -> Text -> [VaultSecretObjectSpec]
keycloakPostgresObjects namespace release =
  [ kvObject
      "secret"
      (keycloakPostgresAppPath namespace release)
      [staticField "username" "keycloak", generatedField "password" "patroni-password"]
  , kvObject
      "secret"
      (namespace <> "/" <> release <> "/patroni/superuser")
      [staticField "username" "postgres", generatedField "password" "patroni-password"]
  , kvObject
      "secret"
      (namespace <> "/" <> release <> "/patroni/standby")
      [staticField "username" "primaryuser", generatedField "password" "patroni-password"]
  ]

keycloakRuntimeObjects :: Text -> [VaultSecretObjectSpec]
keycloakRuntimeObjects namespace =
  [ kvObject
      "secret"
      (keycloakAdminPath namespace)
      [generatedField "password" "keycloak-admin-password"]
  ]

keycloakAdminPath :: Text -> Text
keycloakAdminPath namespace
  | namespace == "keycloak" = "keycloak/admin"
  | otherwise = namespace <> "/keycloak/admin"

keycloakPostgresAppPath :: Text -> Text -> Text
keycloakPostgresAppPath namespace release =
  namespace <> "/" <> release <> "/patroni/app"

oidcObjects :: Text -> [VaultSecretObjectSpec]
oidcObjects namespace =
  [ kvObject
      "secret"
      (namespace <> "/oidc/vscode")
      [generatedField "client_secret" "oidc-client-secret"]
  , kvObject
      "secret"
      (namespace <> "/oidc/prodbox-api")
      [generatedField "client_secret" "oidc-client-secret"]
  , kvObject
      "secret"
      (namespace <> "/oidc/prodbox-websocket")
      [generatedField "client_secret" "oidc-client-secret"]
  , kvObject
      "secret"
      (namespace <> "/oidc/demo-user")
      [generatedField "password" "demo-user-password"]
  ]

kvObject :: Text -> Text -> [VaultSecretFieldSpec] -> VaultSecretObjectSpec
kvObject mount path fields =
  VaultSecretObjectSpec (VaultSecretPath mount path) fields

generatedField :: Text -> Text -> VaultSecretFieldSpec
generatedField name label =
  VaultSecretFieldSpec name (VaultSecretGenerated label)

staticField :: Text -> Text -> VaultSecretFieldSpec
staticField name value =
  VaultSecretFieldSpec name (VaultSecretStatic value)

externalField :: Text -> VaultSecretFieldSpec
externalField name =
  VaultSecretFieldSpec name VaultSecretExternal

vaultSecretPathApiPath :: VaultSecretPath -> Text
vaultSecretPathApiPath path =
  vaultSecretPathMount path <> "/data/" <> vaultSecretPathLogical path

generateVaultSecretFieldValue :: VaultSecretFieldSpec -> IO Text
generateVaultSecretFieldValue field = do
  bytes <- getRandomBytes 32
  pure $
    if vaultSecretFieldName field `elem` minioCommandSecretFields
      then minioCommandSecretValue bytes
      else TextEncoding.decodeUtf8 (B64Url.encodeUnpadded bytes)

minioCommandSecretFields :: [Text]
minioCommandSecretFields =
  [ "minio_secret_key"
  , "rootPassword"
  ]

minioCommandSecretValue :: ByteString -> Text
minioCommandSecretValue bytes =
  Text.take 43 (filtered <> Text.replicate 43 "A")
 where
  raw = TextEncoding.decodeUtf8 (B64Url.encodeUnpadded bytes)
  filtered = Text.filter isAsciiAlphaNumeric raw
  isAsciiAlphaNumeric c = isAsciiUpper c || isAsciiLower c || isDigit c

minioCommandSecretTextSafe :: Text -> Bool
minioCommandSecretTextSafe value =
  Text.strip value /= "" && Text.all isAsciiAlphaNumeric (Text.strip value)
 where
  isAsciiAlphaNumeric c = isAsciiUpper c || isAsciiLower c || isDigit c

runVaultSecretBootstrapWith
  :: VaultSecretBootstrapOps
  -> [VaultSecretObjectSpec]
  -> IO (Either VaultSecretBootstrapError [VaultSecretBootstrapStep])
runVaultSecretBootstrapWith ops =
  go []
 where
  go steps [] = pure (Right (reverse steps))
  go steps (spec : rest) = do
    readResult <- vaultSecretBootstrapObserve ops (vaultSecretObjectPath spec)
    case readResult of
      Right (VaultSecretObjectPresent version existing) ->
        ensureFields ops False version existing spec >>= continue steps rest
      Right VaultSecretObjectAbsent ->
        ensureFields ops True 0 Map.empty spec >>= continue steps rest
      Left (HttpStatus 404 _) ->
        ensureFields ops True 0 Map.empty spec >>= continue steps rest
      Left err ->
        pure (Left (VaultSecretBootstrapReadFailed (vaultSecretObjectPath spec) err))

  continue _ _ (Left err) = pure (Left err)
  continue steps rest (Right step') = go (step' : steps) rest

ensureFields
  :: VaultSecretBootstrapOps
  -> Bool
  -> Natural
  -> Map Text Text
  -> VaultSecretObjectSpec
  -> IO (Either VaultSecretBootstrapError VaultSecretBootstrapStep)
ensureFields ops wasAbsent expectedVersion existing spec = do
  materialized <-
    materializeMissingFields
      ops
      (vaultSecretObjectPath spec)
      existing
      (vaultSecretObjectFields spec)
  case materialized of
    Left err -> pure (Left err)
    Right missingValues
      | null missingValues ->
          pure
            ( Right
                VaultSecretBootstrapStep
                  { vaultSecretBootstrapStepPath = vaultSecretObjectPath spec
                  , vaultSecretBootstrapStepAction = VaultSecretBootstrapPresent
                  , vaultSecretBootstrapStepFields = []
                  }
            )
      | otherwise -> do
          let fields = Map.union (Map.fromList missingValues) existing
          writeResult <-
            vaultSecretBootstrapWrite ops (vaultSecretObjectPath spec) expectedVersion fields
          pure $ case writeResult of
            Left err -> Left (VaultSecretBootstrapWriteFailed (vaultSecretObjectPath spec) err)
            Right () ->
              Right
                VaultSecretBootstrapStep
                  { vaultSecretBootstrapStepPath = vaultSecretObjectPath spec
                  , vaultSecretBootstrapStepAction =
                      if wasAbsent then VaultSecretBootstrapCreated else VaultSecretBootstrapUpdatedMissingFields
                  , vaultSecretBootstrapStepFields = map fst missingValues
                  }

materializeMissingFields
  :: VaultSecretBootstrapOps
  -> VaultSecretPath
  -> Map Text Text
  -> [VaultSecretFieldSpec]
  -> IO (Either VaultSecretBootstrapError [(Text, Text)])
materializeMissingFields ops path existing =
  go []
 where
  go values [] = pure (Right (reverse values))
  go values (field : rest)
    | fieldSatisfied field existing = go values rest
    | otherwise =
        case vaultSecretFieldSource field of
          VaultSecretStatic value ->
            go ((vaultSecretFieldName field, value) : values) rest
          VaultSecretGenerated _ -> do
            value <- vaultSecretBootstrapGenerate ops field
            go ((vaultSecretFieldName field, value) : values) rest
          VaultSecretExternal ->
            pure
              ( Left
                  (VaultSecretBootstrapExternalFieldMissing path (vaultSecretFieldName field))
              )

fieldSatisfied :: VaultSecretFieldSpec -> Map Text Text -> Bool
fieldSatisfied field existing =
  case Map.lookup (vaultSecretFieldName field) existing of
    Nothing -> False
    Just value ->
      vaultSecretFieldName field `notElem` minioCommandSecretFields
        || minioCommandSecretTextSafe value
