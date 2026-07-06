{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.36: idempotent Vault bootstrap reconciler. The low-level HTTP
-- wire format lives in "Prodbox.Vault.Client"; this module owns ordering,
-- drift checks, and the default prodbox Vault policy surface.
module Prodbox.Vault.Reconcile
  ( VaultMountSpec (..)
  , VaultAuthSpec (..)
  , VaultKubernetesAuthConfigSpec (..)
  , VaultTransitKeySpec (..)
  , VaultPolicySpec (..)
  , VaultKubernetesRoleSpec (..)
  , VaultReconcilePlan (..)
  , VaultReconcileOps (..)
  , VaultReconcileTarget (..)
  , VaultReconcileAction (..)
  , VaultReconcileStep (..)
  , VaultReconcileError (..)
  , defaultVaultReconcilePlan
  , operatorWritePolicy
  , runVaultReconcile
  , runVaultReconcileWith
  , renderVaultReconcileStep
  , renderVaultReconcileError
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.Secret.VaultInventory
  ( VaultSecretBootstrapAction (..)
  , VaultSecretBootstrapError (..)
  , VaultSecretBootstrapOps (..)
  , VaultSecretBootstrapStep (..)
  , VaultSecretConsumer (..)
  , VaultSecretObjectSpec (..)
  , VaultSecretPath (..)
  , chartVaultManagedSecretObjects
  , chartVaultSecretConsumers
  , generateVaultSecretFieldValue
  , runVaultSecretBootstrapWith
  , vaultSecretConsumerPolicyDocument
  , vaultSecretPathName
  )
import Prodbox.Vault.Client
  ( TransitKeyInfo (..)
  , VaultAddress
  , VaultAuthInfo (..)
  , VaultMountInfo (..)
  , VaultToken
  , vaultCreateTransitKey
  , vaultEnableAuthMethod
  , vaultEnableMount
  , vaultKvReadV2
  , vaultKvWriteV2
  , vaultListAuthMethods
  , vaultListMounts
  , vaultReadTransitKey
  , vaultWriteKubernetesAuthConfig
  , vaultWriteKubernetesRole
  , vaultWritePolicy
  )

data VaultMountSpec = VaultMountSpec
  { vaultMountSpecPath :: Text
  , vaultMountSpecType :: Text
  , vaultMountSpecOptions :: Map Text Text
  }
  deriving (Eq, Show)

data VaultAuthSpec = VaultAuthSpec
  { vaultAuthSpecPath :: Text
  , vaultAuthSpecType :: Text
  }
  deriving (Eq, Show)

data VaultKubernetesAuthConfigSpec = VaultKubernetesAuthConfigSpec
  { vaultKubernetesAuthConfigSpecPath :: Text
  , vaultKubernetesAuthConfigSpecHost :: Text
  }
  deriving (Eq, Show)

data VaultTransitKeySpec = VaultTransitKeySpec
  { vaultTransitKeySpecName :: Text
  , vaultTransitKeySpecType :: Text
  }
  deriving (Eq, Show)

data VaultPolicySpec = VaultPolicySpec
  { vaultPolicySpecName :: Text
  , vaultPolicySpecDocument :: Text
  }
  deriving (Eq, Show)

data VaultKubernetesRoleSpec = VaultKubernetesRoleSpec
  { vaultKubernetesRoleSpecName :: Text
  , vaultKubernetesRoleSpecServiceAccounts :: [Text]
  , vaultKubernetesRoleSpecNamespaces :: [Text]
  , vaultKubernetesRoleSpecPolicies :: [Text]
  , vaultKubernetesRoleSpecTtl :: Text
  }
  deriving (Eq, Show)

data VaultReconcilePlan = VaultReconcilePlan
  { vaultReconcileMounts :: [VaultMountSpec]
  , vaultReconcileAuthMethods :: [VaultAuthSpec]
  , vaultReconcileKubernetesAuthConfigs :: [VaultKubernetesAuthConfigSpec]
  , vaultReconcileTransitKeys :: [VaultTransitKeySpec]
  , vaultReconcilePolicies :: [VaultPolicySpec]
  , vaultReconcileKubernetesRoles :: [VaultKubernetesRoleSpec]
  , vaultReconcileSecretObjects :: [VaultSecretObjectSpec]
  }
  deriving (Eq, Show)

data VaultReconcileOps = VaultReconcileOps
  { vaultOpsListMounts :: IO (Either HttpError (Map Text VaultMountInfo))
  , vaultOpsEnableMount :: VaultMountSpec -> IO (Either HttpError ())
  , vaultOpsListAuthMethods :: IO (Either HttpError (Map Text VaultAuthInfo))
  , vaultOpsEnableAuthMethod :: VaultAuthSpec -> IO (Either HttpError ())
  , vaultOpsWriteKubernetesAuthConfig :: VaultKubernetesAuthConfigSpec -> IO (Either HttpError ())
  , vaultOpsReadTransitKey :: VaultTransitKeySpec -> IO (Either HttpError TransitKeyInfo)
  , vaultOpsCreateTransitKey :: VaultTransitKeySpec -> IO (Either HttpError ())
  , vaultOpsWritePolicy :: VaultPolicySpec -> IO (Either HttpError ())
  , vaultOpsWriteKubernetesRole :: VaultKubernetesRoleSpec -> IO (Either HttpError ())
  , vaultOpsSecretBootstrap :: VaultSecretBootstrapOps
  }

data VaultReconcileTarget
  = VaultReconcileMount
  | VaultReconcileAuthMethod
  | VaultReconcileKubernetesAuthConfig
  | VaultReconcileTransitKey
  | VaultReconcilePolicy
  | VaultReconcileKubernetesRole
  | VaultReconcileSecretObject
  deriving (Eq, Show)

data VaultReconcileAction
  = VaultReconcileCreated
  | VaultReconcilePresent
  | VaultReconcileWritten
  deriving (Eq, Show)

data VaultReconcileStep = VaultReconcileStep
  { vaultReconcileStepTarget :: VaultReconcileTarget
  , vaultReconcileStepName :: Text
  , vaultReconcileStepAction :: VaultReconcileAction
  }
  deriving (Eq, Show)

data VaultReconcileError
  = VaultReconcileHttpError Text HttpError
  | VaultReconcileMountTypeMismatch Text Text Text
  | VaultReconcileMountOptionMismatch Text Text Text (Maybe Text)
  | VaultReconcileAuthTypeMismatch Text Text Text
  | VaultReconcileTransitKeyTypeMismatch Text Text Text
  | VaultReconcileSecretBootstrapFailed VaultSecretBootstrapError
  deriving (Eq, Show)

defaultVaultReconcilePlan :: VaultReconcilePlan
defaultVaultReconcilePlan =
  VaultReconcilePlan
    { vaultReconcileMounts =
        [ VaultMountSpec "secret" "kv" (Map.singleton "version" "2")
        , VaultMountSpec "transit" "transit" Map.empty
        , VaultMountSpec "pki" "pki" Map.empty
        ]
    , vaultReconcileAuthMethods =
        [VaultAuthSpec "kubernetes" "kubernetes"]
    , vaultReconcileKubernetesAuthConfigs =
        [ VaultKubernetesAuthConfigSpec
            "kubernetes"
            "https://kubernetes.default.svc:443"
        ]
    , vaultReconcileTransitKeys =
        map
          (`VaultTransitKeySpec` "aes256-gcm96")
          [ "prodbox-active-config"
          , "prodbox-gateway-state"
          , "prodbox-pulumi-state"
          , "prodbox-minio-envelope"
          , "prodbox-downstream-cluster-config"
          ]
    , vaultReconcilePolicies =
        [ VaultPolicySpec "prodbox-gateway" gatewayPolicy
        , VaultPolicySpec "prodbox-pulumi" pulumiPolicy
        , VaultPolicySpec "prodbox-federation-custody" federationPolicy
        , VaultPolicySpec "prodbox-operator-write" operatorWritePolicy
        ]
          ++ map chartSecretPolicy chartVaultSecretConsumers
    , vaultReconcileKubernetesRoles =
        [ VaultKubernetesRoleSpec
            "prodbox-gateway-daemon"
            ["prodbox-gateway-daemon"]
            ["gateway"]
            ["prodbox-gateway"]
            "1h"
        , VaultKubernetesRoleSpec
            "prodbox-pulumi-runner"
            ["prodbox-pulumi-runner"]
            ["prodbox-system"]
            ["prodbox-pulumi"]
            "1h"
        , VaultKubernetesRoleSpec
            "prodbox-federation-controller"
            ["prodbox-federation-controller"]
            ["gateway"]
            ["prodbox-federation-custody"]
            "1h"
        , -- Sprint 1.44: the operator-write role the gateway daemon's
          -- @POST /v1/secret/<logical>@ endpoint logs into Vault under, using
          -- the operator-injected Kubernetes JWT presented on the request (NOT
          -- the daemon's own read-only @prodbox-gateway-daemon@ identity). It is
          -- scoped to exactly the two host-minted operator secrets routed
          -- through the daemon: @secret/acme/eab@ and @secret/gateway/gateway/aws@.
          VaultKubernetesRoleSpec
            "prodbox-operator-write"
            ["prodbox-operator-write"]
            ["gateway"]
            ["prodbox-operator-write"]
            "5m"
        ]
          ++ map chartSecretRole chartVaultSecretConsumers
    , vaultReconcileSecretObjects = chartVaultManagedSecretObjects
    }

chartSecretPolicy :: VaultSecretConsumer -> VaultPolicySpec
chartSecretPolicy consumer =
  VaultPolicySpec
    (vaultSecretConsumerPolicyName consumer)
    (vaultSecretConsumerPolicyDocument consumer)

chartSecretRole :: VaultSecretConsumer -> VaultKubernetesRoleSpec
chartSecretRole consumer =
  VaultKubernetesRoleSpec
    (vaultSecretConsumerRoleName consumer)
    (vaultSecretConsumerServiceAccounts consumer)
    (vaultSecretConsumerNamespaces consumer)
    [vaultSecretConsumerPolicyName consumer]
    (vaultSecretConsumerTtl consumer)

runVaultReconcile
  :: VaultAddress
  -> VaultToken
  -> VaultReconcilePlan
  -> IO (Either VaultReconcileError [VaultReconcileStep])
runVaultReconcile address token =
  runVaultReconcileWith
    VaultReconcileOps
      { vaultOpsListMounts = vaultListMounts address token
      , vaultOpsEnableMount =
          \spec ->
            vaultEnableMount
              address
              token
              (vaultMountSpecPath spec)
              (vaultMountSpecType spec)
              (vaultMountSpecOptions spec)
      , vaultOpsListAuthMethods = vaultListAuthMethods address token
      , vaultOpsEnableAuthMethod =
          \spec ->
            vaultEnableAuthMethod address token (vaultAuthSpecPath spec) (vaultAuthSpecType spec)
      , vaultOpsWriteKubernetesAuthConfig =
          \spec ->
            vaultWriteKubernetesAuthConfig
              address
              token
              (vaultKubernetesAuthConfigSpecPath spec)
              (vaultKubernetesAuthConfigSpecHost spec)
      , vaultOpsReadTransitKey =
          \spec -> vaultReadTransitKey address token (vaultTransitKeySpecName spec)
      , vaultOpsCreateTransitKey =
          \spec ->
            vaultCreateTransitKey address token (vaultTransitKeySpecName spec) (vaultTransitKeySpecType spec)
      , vaultOpsWritePolicy =
          \spec -> vaultWritePolicy address token (vaultPolicySpecName spec) (vaultPolicySpecDocument spec)
      , vaultOpsWriteKubernetesRole =
          \spec ->
            vaultWriteKubernetesRole
              address
              token
              (vaultKubernetesRoleSpecName spec)
              (vaultKubernetesRoleSpecServiceAccounts spec)
              (vaultKubernetesRoleSpecNamespaces spec)
              (vaultKubernetesRoleSpecPolicies spec)
              (vaultKubernetesRoleSpecTtl spec)
      , vaultOpsSecretBootstrap =
          VaultSecretBootstrapOps
            { vaultSecretBootstrapRead =
                \path ->
                  vaultKvReadV2
                    address
                    token
                    (vaultSecretPathMount path)
                    (vaultSecretPathLogical path)
            , vaultSecretBootstrapWrite =
                \path fields ->
                  vaultKvWriteV2
                    address
                    token
                    (vaultSecretPathMount path)
                    (vaultSecretPathLogical path)
                    fields
            , vaultSecretBootstrapGenerate = generateVaultSecretFieldValue
            }
      }

runVaultReconcileWith
  :: VaultReconcileOps -> VaultReconcilePlan -> IO (Either VaultReconcileError [VaultReconcileStep])
runVaultReconcileWith ops plan = do
  mountResult <- vaultOpsListMounts ops
  case mountResult of
    Left err -> pure (Left (VaultReconcileHttpError "list mounts" err))
    Right existingMounts -> do
      mountStepsResult <- reconcileMounts ops existingMounts (vaultReconcileMounts plan)
      case mountStepsResult of
        Left err -> pure (Left err)
        Right mountSteps -> do
          authResult <- vaultOpsListAuthMethods ops
          case authResult of
            Left err -> pure (Left (VaultReconcileHttpError "list auth methods" err))
            Right existingAuth -> do
              authStepsResult <- reconcileAuthMethods ops existingAuth (vaultReconcileAuthMethods plan)
              case authStepsResult of
                Left err -> pure (Left err)
                Right authSteps -> do
                  authConfigResult <-
                    reconcileKubernetesAuthConfigs ops (vaultReconcileKubernetesAuthConfigs plan)
                  case authConfigResult of
                    Left err -> pure (Left err)
                    Right authConfigSteps -> do
                      transitResult <- reconcileTransitKeys ops (vaultReconcileTransitKeys plan)
                      case transitResult of
                        Left err -> pure (Left err)
                        Right transitSteps -> do
                          policyResult <- reconcilePolicies ops (vaultReconcilePolicies plan)
                          case policyResult of
                            Left err -> pure (Left err)
                            Right policySteps -> do
                              roleResult <- reconcileKubernetesRoles ops (vaultReconcileKubernetesRoles plan)
                              case roleResult of
                                Left err -> pure (Left err)
                                Right roleSteps -> do
                                  secretResult <-
                                    reconcileSecretObjects
                                      ops
                                      (vaultReconcileSecretObjects plan)
                                  pure $ case secretResult of
                                    Left err -> Left err
                                    Right secretSteps ->
                                      Right
                                        ( mountSteps
                                            ++ authSteps
                                            ++ authConfigSteps
                                            ++ transitSteps
                                            ++ policySteps
                                            ++ roleSteps
                                            ++ secretSteps
                                        )

reconcileMounts
  :: VaultReconcileOps
  -> Map Text VaultMountInfo
  -> [VaultMountSpec]
  -> IO (Either VaultReconcileError [VaultReconcileStep])
reconcileMounts ops existing =
  go []
 where
  go steps [] = pure (Right (reverse steps))
  go steps (spec : rest) =
    case Map.lookup (vaultMountSpecPath spec) existing of
      Nothing -> do
        result <- vaultOpsEnableMount ops spec
        case result of
          Left err ->
            pure (Left (VaultReconcileHttpError ("enable mount " <> vaultMountSpecPath spec) err))
          Right () ->
            go (step VaultReconcileMount (vaultMountSpecPath spec) VaultReconcileCreated : steps) rest
      Just info
        | vaultMountType info /= vaultMountSpecType spec ->
            pure
              ( Left
                  ( VaultReconcileMountTypeMismatch
                      (vaultMountSpecPath spec)
                      (vaultMountSpecType spec)
                      (vaultMountType info)
                  )
              )
        | otherwise ->
            case firstMismatchedOption spec info of
              Just (key, expected, actual) ->
                pure
                  ( Left
                      ( VaultReconcileMountOptionMismatch
                          (vaultMountSpecPath spec)
                          key
                          expected
                          actual
                      )
                  )
              Nothing ->
                go (step VaultReconcileMount (vaultMountSpecPath spec) VaultReconcilePresent : steps) rest

reconcileAuthMethods
  :: VaultReconcileOps
  -> Map Text VaultAuthInfo
  -> [VaultAuthSpec]
  -> IO (Either VaultReconcileError [VaultReconcileStep])
reconcileAuthMethods ops existing =
  go []
 where
  go steps [] = pure (Right (reverse steps))
  go steps (spec : rest) =
    case Map.lookup (vaultAuthSpecPath spec) existing of
      Nothing -> do
        result <- vaultOpsEnableAuthMethod ops spec
        case result of
          Left err ->
            pure (Left (VaultReconcileHttpError ("enable auth " <> vaultAuthSpecPath spec) err))
          Right () ->
            go (step VaultReconcileAuthMethod (vaultAuthSpecPath spec) VaultReconcileCreated : steps) rest
      Just info
        | vaultAuthType info /= vaultAuthSpecType spec ->
            pure
              ( Left
                  ( VaultReconcileAuthTypeMismatch
                      (vaultAuthSpecPath spec)
                      (vaultAuthSpecType spec)
                      (vaultAuthType info)
                  )
              )
        | otherwise ->
            go (step VaultReconcileAuthMethod (vaultAuthSpecPath spec) VaultReconcilePresent : steps) rest

reconcileKubernetesAuthConfigs
  :: VaultReconcileOps
  -> [VaultKubernetesAuthConfigSpec]
  -> IO (Either VaultReconcileError [VaultReconcileStep])
reconcileKubernetesAuthConfigs ops =
  go []
 where
  go steps [] = pure (Right (reverse steps))
  go steps (spec : rest) = do
    result <- vaultOpsWriteKubernetesAuthConfig ops spec
    case result of
      Left err ->
        pure
          ( Left
              ( VaultReconcileHttpError
                  ("write Kubernetes auth config " <> vaultKubernetesAuthConfigSpecPath spec)
                  err
              )
          )
      Right () ->
        go
          ( step
              VaultReconcileKubernetesAuthConfig
              (vaultKubernetesAuthConfigSpecPath spec)
              VaultReconcileWritten
              : steps
          )
          rest

reconcileTransitKeys
  :: VaultReconcileOps
  -> [VaultTransitKeySpec]
  -> IO (Either VaultReconcileError [VaultReconcileStep])
reconcileTransitKeys ops =
  go []
 where
  go steps [] = pure (Right (reverse steps))
  go steps (spec : rest) = do
    readResult <- vaultOpsReadTransitKey ops spec
    case readResult of
      Right info
        | transitKeyType info /= vaultTransitKeySpecType spec ->
            pure
              ( Left
                  ( VaultReconcileTransitKeyTypeMismatch
                      (vaultTransitKeySpecName spec)
                      (vaultTransitKeySpecType spec)
                      (transitKeyType info)
                  )
              )
        | otherwise ->
            go (step VaultReconcileTransitKey (vaultTransitKeySpecName spec) VaultReconcilePresent : steps) rest
      Left (HttpStatus 404 _) -> do
        createResult <- vaultOpsCreateTransitKey ops spec
        case createResult of
          Left err ->
            pure (Left (VaultReconcileHttpError ("create transit key " <> vaultTransitKeySpecName spec) err))
          Right () ->
            go (step VaultReconcileTransitKey (vaultTransitKeySpecName spec) VaultReconcileCreated : steps) rest
      Left err ->
        pure (Left (VaultReconcileHttpError ("read transit key " <> vaultTransitKeySpecName spec) err))

reconcilePolicies
  :: VaultReconcileOps -> [VaultPolicySpec] -> IO (Either VaultReconcileError [VaultReconcileStep])
reconcilePolicies ops =
  go []
 where
  go steps [] = pure (Right (reverse steps))
  go steps (spec : rest) = do
    result <- vaultOpsWritePolicy ops spec
    case result of
      Left err ->
        pure (Left (VaultReconcileHttpError ("write policy " <> vaultPolicySpecName spec) err))
      Right () ->
        go (step VaultReconcilePolicy (vaultPolicySpecName spec) VaultReconcileWritten : steps) rest

reconcileKubernetesRoles
  :: VaultReconcileOps
  -> [VaultKubernetesRoleSpec]
  -> IO (Either VaultReconcileError [VaultReconcileStep])
reconcileKubernetesRoles ops =
  go []
 where
  go steps [] = pure (Right (reverse steps))
  go steps (spec : rest) = do
    result <- vaultOpsWriteKubernetesRole ops spec
    case result of
      Left err ->
        pure
          ( Left
              (VaultReconcileHttpError ("write Kubernetes role " <> vaultKubernetesRoleSpecName spec) err)
          )
      Right () ->
        go
          (step VaultReconcileKubernetesRole (vaultKubernetesRoleSpecName spec) VaultReconcileWritten : steps)
          rest

reconcileSecretObjects
  :: VaultReconcileOps
  -> [VaultSecretObjectSpec]
  -> IO (Either VaultReconcileError [VaultReconcileStep])
reconcileSecretObjects ops specs = do
  result <- runVaultSecretBootstrapWith (vaultOpsSecretBootstrap ops) specs
  pure $ case result of
    Left err -> Left (VaultReconcileSecretBootstrapFailed err)
    Right steps -> Right (map secretBootstrapStep steps)

secretBootstrapStep :: VaultSecretBootstrapStep -> VaultReconcileStep
secretBootstrapStep bootstrapStep =
  step
    VaultReconcileSecretObject
    (vaultSecretPathName (vaultSecretBootstrapStepPath bootstrapStep))
    (secretBootstrapAction (vaultSecretBootstrapStepAction bootstrapStep))

secretBootstrapAction :: VaultSecretBootstrapAction -> VaultReconcileAction
secretBootstrapAction action = case action of
  VaultSecretBootstrapPresent -> VaultReconcilePresent
  VaultSecretBootstrapCreated -> VaultReconcileCreated
  VaultSecretBootstrapUpdatedMissingFields -> VaultReconcileWritten

firstMismatchedOption :: VaultMountSpec -> VaultMountInfo -> Maybe (Text, Text, Maybe Text)
firstMismatchedOption spec info =
  case filter mismatched (Map.toList (vaultMountSpecOptions spec)) of
    [] -> Nothing
    (key, expected) : _ -> Just (key, expected, Map.lookup key (vaultMountOptions info))
 where
  mismatched (key, expected) =
    Map.lookup key (vaultMountOptions info) /= Just expected

step :: VaultReconcileTarget -> Text -> VaultReconcileAction -> VaultReconcileStep
step target name action =
  VaultReconcileStep
    { vaultReconcileStepTarget = target
    , vaultReconcileStepName = name
    , vaultReconcileStepAction = action
    }

renderVaultReconcileStep :: VaultReconcileStep -> String
renderVaultReconcileStep reconcileStep =
  Text.unpack
    ( targetText (vaultReconcileStepTarget reconcileStep)
        <> " "
        <> vaultReconcileStepName reconcileStep
        <> ": "
        <> actionText (vaultReconcileStepAction reconcileStep)
    )

renderVaultReconcileError :: VaultReconcileError -> String
renderVaultReconcileError err = case err of
  VaultReconcileHttpError context httpErr ->
    Text.unpack context ++ " failed: " ++ renderHttpError httpErr
  VaultReconcileMountTypeMismatch mount expected actual ->
    "Vault mount "
      ++ Text.unpack mount
      ++ " has type "
      ++ Text.unpack actual
      ++ "; expected "
      ++ Text.unpack expected
  VaultReconcileMountOptionMismatch mount key expected actual ->
    "Vault mount "
      ++ Text.unpack mount
      ++ " has option "
      ++ Text.unpack key
      ++ "="
      ++ maybe "<missing>" Text.unpack actual
      ++ "; expected "
      ++ Text.unpack expected
  VaultReconcileAuthTypeMismatch path expected actual ->
    "Vault auth method "
      ++ Text.unpack path
      ++ " has type "
      ++ Text.unpack actual
      ++ "; expected "
      ++ Text.unpack expected
  VaultReconcileTransitKeyTypeMismatch key expected actual ->
    "Vault Transit key "
      ++ Text.unpack key
      ++ " has type "
      ++ Text.unpack actual
      ++ "; expected "
      ++ Text.unpack expected
  VaultReconcileSecretBootstrapFailed bootstrapErr ->
    renderVaultSecretBootstrapError bootstrapErr

targetText :: VaultReconcileTarget -> Text
targetText target = case target of
  VaultReconcileMount -> "mount"
  VaultReconcileAuthMethod -> "auth"
  VaultReconcileKubernetesAuthConfig -> "kubernetes-auth-config"
  VaultReconcileTransitKey -> "transit-key"
  VaultReconcilePolicy -> "policy"
  VaultReconcileKubernetesRole -> "kubernetes-role"
  VaultReconcileSecretObject -> "secret-object"

actionText :: VaultReconcileAction -> Text
actionText action = case action of
  VaultReconcileCreated -> "created"
  VaultReconcilePresent -> "present"
  VaultReconcileWritten -> "written"

renderVaultSecretBootstrapError :: VaultSecretBootstrapError -> String
renderVaultSecretBootstrapError err = case err of
  VaultSecretBootstrapReadFailed path httpErr ->
    "Vault secret "
      ++ Text.unpack (vaultSecretPathName path)
      ++ " read failed: "
      ++ renderHttpError httpErr
  VaultSecretBootstrapWriteFailed path httpErr ->
    "Vault secret "
      ++ Text.unpack (vaultSecretPathName path)
      ++ " write failed: "
      ++ renderHttpError httpErr
  VaultSecretBootstrapExternalFieldMissing path fieldName ->
    "Vault secret "
      ++ Text.unpack (vaultSecretPathName path)
      ++ " field "
      ++ Text.unpack fieldName
      ++ " is externally owned and cannot be generated"

gatewayPolicy :: Text
gatewayPolicy =
  Text.unlines
    [ "path \"secret/data/prodbox/gateway/*\" {"
    , "  capabilities = [\"read\", \"list\"]"
    , "}"
    , ""
    , "path \"secret/metadata/prodbox/gateway/*\" {"
    , "  capabilities = [\"list\"]"
    , "}"
    , ""
    , "path \"secret/data/object-store/hmac\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , ""
    , "path \"transit/decrypt/prodbox-active-config\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/encrypt/prodbox-gateway-state\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/decrypt/prodbox-gateway-state\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/encrypt/prodbox-pulumi-state\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/decrypt/prodbox-pulumi-state\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    ]

-- | Sprint 1.44: the operator-write policy. The gateway daemon's
-- @POST /v1/secret/<logical>@ endpoint logs into Vault under this policy (via
-- the operator-injected Kubernetes JWT) to persist exactly the two host-minted
-- operator secrets that route through the daemon instead of a host root-token
-- direct write:
--
--   * @secret/acme/eab@ — the ZeroSSL external-account-binding material.
--   * @secret/gateway/gateway/aws@ — the minted operational @aws.*@ credential.
--
-- It is deliberately narrow (create/update on those two KV paths only) so a
-- compromised operator JWT cannot reach the rest of the KV store, the transit
-- keys, or the federation custody tree.
operatorWritePolicy :: Text
operatorWritePolicy =
  Text.unlines
    [ "path \"secret/data/acme/eab\" {"
    , "  capabilities = [\"create\", \"update\"]"
    , "}"
    , ""
    , "path \"secret/data/gateway/gateway/aws\" {"
    , "  capabilities = [\"create\", \"update\"]"
    , "}"
    ]

pulumiPolicy :: Text
pulumiPolicy =
  Text.unlines
    [ "path \"transit/encrypt/prodbox-pulumi-state\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/decrypt/prodbox-pulumi-state\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    ]

federationPolicy :: Text
federationPolicy =
  Text.unlines
    [ "path \"secret/data/clusters/*\" {"
    , "  capabilities = [\"create\", \"read\", \"update\", \"patch\", \"delete\", \"list\"]"
    , "}"
    , ""
    , "path \"secret/metadata/clusters/*\" {"
    , "  capabilities = [\"list\", \"delete\"]"
    , "}"
    , ""
    , "path \"transit/encrypt/prodbox-downstream-cluster-config\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/decrypt/prodbox-downstream-cluster-config\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/encrypt/prodbox-child-*\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/decrypt/prodbox-child-*\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    ]
