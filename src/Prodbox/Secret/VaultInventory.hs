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
  , vaultSecretConsumerKvApiPaths
  , vaultSecretConsumerPolicyDocument
  , vaultSecretPathName
  , vaultSecretObjectFieldNames
  , chartVaultManagedSecretObjects
  , chartVaultSecretObjects
  , chartVaultSecretConsumers
  , vaultSecretConsumerByName
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
import Prodbox.Http.Client (HttpError (..))

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
  | VaultSecretBootstrapWriteFailed VaultSecretPath HttpError
  | VaultSecretBootstrapExternalFieldMissing VaultSecretPath Text
  deriving (Eq, Show)

data VaultSecretBootstrapOps = VaultSecretBootstrapOps
  { vaultSecretBootstrapRead :: VaultSecretPath -> IO (Either HttpError (Map Text Text))
  , vaultSecretBootstrapWrite :: VaultSecretPath -> Map Text Text -> IO (Either HttpError ())
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

chartVaultSecretConsumers :: [VaultSecretConsumer]
chartVaultSecretConsumers =
  [ keycloakPostgresConsumer "keycloak" "keycloak-postgres"
  , keycloakPostgresConsumer "vscode" "keycloak-postgres"
  , keycloakRuntimeConsumer "keycloak-runtime" "keycloak" "keycloak"
  , keycloakRuntimeConsumer "vscode-keycloak-runtime" "vscode-keycloak" "vscode"
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
          , VaultSecretPath "secret" "gateway/gateway/aws"
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
      , kvObject
          "secret"
          "gateway/gateway/aws"
          [ externalField "access_key_id"
          , externalField "secret_access_key"
          , externalField "session_token"
          , externalField "region"
          ]
      , kvObject
          "secret"
          "gateway/gateway/minio"
          [ staticField "minio_access_key" "prodbox-gateway"
          , generatedField "minio_secret_key" "gateway-minio-secret-key"
          ]
      , kvObject
          "secret"
          "minio/root"
          [ staticField "rootUser" "prodbox-minio-root"
          , generatedField "rootPassword" "minio-root-password"
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
        , VaultSecretPath "secret" (keycloakPostgresAppPath namespace "keycloak-postgres")
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
    readResult <- vaultSecretBootstrapRead ops (vaultSecretObjectPath spec)
    case readResult of
      Right existing ->
        ensureFields ops False existing spec >>= continue steps rest
      Left (HttpStatus 404 _) ->
        ensureFields ops True Map.empty spec >>= continue steps rest
      Left err ->
        pure (Left (VaultSecretBootstrapReadFailed (vaultSecretObjectPath spec) err))

  continue _ _ (Left err) = pure (Left err)
  continue steps rest (Right step') = go (step' : steps) rest

ensureFields
  :: VaultSecretBootstrapOps
  -> Bool
  -> Map Text Text
  -> VaultSecretObjectSpec
  -> IO (Either VaultSecretBootstrapError VaultSecretBootstrapStep)
ensureFields ops wasAbsent existing spec = do
  materialized <-
    materializeMissingFields ops (vaultSecretObjectPath spec) existing (vaultSecretObjectFields spec)
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
          writeResult <- vaultSecretBootstrapWrite ops (vaultSecretObjectPath spec) fields
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
