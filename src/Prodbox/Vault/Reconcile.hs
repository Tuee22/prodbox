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
  , VaultKubernetesTokenType (..)
  , VaultKubernetesRoleSpec (..)
  , VaultReconcilePlan (..)
  , VaultReconcileOps (..)
  , VaultReconcileTarget (..)
  , VaultReconcileAction (..)
  , VaultReconcileStep (..)
  , VaultReconcileHttpOperation (..)
  , VaultReconcileError (..)
  , defaultVaultReconcilePlan
  , bootstrapBrokerRotatableTransitKeys
  , bootstrapProvisionerRole
  , bootstrapPkiOperatorRole
  , bootstrapControlPlaneClientRole
  , bootstrapSealRole
  , tokenAccessorAuditorRole
  , VaultPkiBaselineStatus (..)
  , VaultPkiReconcileOperation (..)
  , VaultPkiObserveOperation (..)
  , VaultPkiReconcileError (..)
  , VaultPkiObserveError (..)
  , VaultPkiRootDecision (..)
  , decideVaultPkiRoot
  , reconcileVaultPkiBaseline
  , observeVaultPkiBaseline
  , runVaultReconcile
  , runVaultReconcileWith
  , renderVaultReconcileStep
  , renderVaultReconcileError
  )
where

import Data.Char (isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry
  ( adminActionRunnerAuditorVaultRole
  , adminActionRunnerCompletionVaultRole
  , adminActionRunnerVaultRole
  , controlPlaneSigningKeyInventory
  , controlPlaneSigningKeyName
  , controlPlaneSigningKeyRefFor
  , credentialProvisionerAuditorVaultRole
  , credentialProvisionerCompletionVaultRole
  , credentialProvisionerVaultRole
  , externalMaterialIngressAuditorVaultRole
  , externalMaterialIngressVaultRole
  , harnessControlPlaneVaultRole
  , operatorControlPlaneVaultRole
  , targetSecretControllerAuditorVaultRole
  , targetSecretWorkerAuditorVaultRole
  , targetSecretWorkerVaultRole
  , trustedCallersForRole
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (..))
import Prodbox.ControlPlane.RetainedAuthentication
  ( controlPlaneAuthorityEpochPath
  , controlPlaneRequestReplayPath
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (..)
  , TargetSecretId (..)
  , allTargetMaterialIds
  , targetSecretIdToken
  , targetSecretIdVaultLogicalPath
  )
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.Runtime.Role (RuntimeRole (..))
import Prodbox.Secret.VaultInventory
  ( VaultSecretBootstrapAction (..)
  , VaultSecretBootstrapError (..)
  , VaultSecretBootstrapOps (..)
  , VaultSecretBootstrapStep (..)
  , VaultSecretConsumer (..)
  , VaultSecretFieldSource (..)
  , VaultSecretFieldSpec (..)
  , VaultSecretObjectSpec (..)
  , VaultSecretObservation (..)
  , VaultSecretPath (..)
  , chartVaultManagedSecretObjects
  , chartVaultSecretConsumers
  , generateVaultSecretFieldValue
  , runVaultSecretBootstrapWith
  , vaultSecretConsumerPolicyDocument
  , vaultSecretPathName
  )
import Prodbox.Vault.Client
  ( KubernetesRoleReadback (..)
  , KvV2Cas (KvV2Cas)
  , PkiIssuerListing (..)
  , PkiRoleInfo (..)
  , TransitKeyInfo (..)
  , VaultAddress
  , VaultAuthInfo (..)
  , VaultCasOutcome (..)
  , VaultMountInfo (..)
  , VaultToken
  , classifyVaultCasOutcome
  , kvV2VersionedSecretData
  , kvV2VersionedSecretVersion
  , renderVaultCasOutcome
  , vaultCreateTransitKey
  , vaultEnableAuthMethod
  , vaultEnableMount
  , vaultGeneratePkiInternalRoot
  , vaultKvCasWriteV2
  , vaultKvReadVersionedV2
  , vaultListAuthMethods
  , vaultListMounts
  , vaultListPkiIssuers
  , vaultReadKubernetesRole
  , vaultReadPkiRole
  , vaultReadTransitKey
  , vaultWriteKubernetesAuthConfig
  , vaultWriteKubernetesBatchRole
  , vaultWriteKubernetesRole
  , vaultWritePkiRole
  , vaultWritePolicy
  )
import Prodbox.Vault.RoleId
  ( VaultRoleId
      ( VaultRoleAuthorityBackup
      , VaultRoleBootstrapBroker
      , VaultRoleGatewayDaemon
      , VaultRoleLifecycleAuthority
      , VaultRoleProviderWorker
      , VaultRoleTargetSecretAgent
      , VaultRoleTlsRetention
      )
  , vaultRoleIdText
  )
import Text.Read (readMaybe)

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
  , vaultKubernetesRoleSpecAudience :: Maybe Text
  , vaultKubernetesRoleSpecTtl :: Text
  , vaultKubernetesRoleSpecTokenType :: VaultKubernetesTokenType
  }
  deriving (Eq, Show)

data VaultKubernetesTokenType
  = VaultKubernetesServiceToken
  | VaultKubernetesBatchToken
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
  , vaultOpsReadKubernetesRole
      :: VaultKubernetesRoleSpec
      -> IO (Either HttpError KubernetesRoleReadback)
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

-- | Closed operation identity for transport failures in the baseline fold.
-- The accompanying context in 'VaultReconcileHttpError' remains available to
-- the operator renderer, but callers that need a payload-free decision must
-- classify this constructor instead of parsing that text.
data VaultReconcileHttpOperation
  = VaultReconcileListMounts
  | VaultReconcileEnableMount
  | VaultReconcileListAuthMethods
  | VaultReconcileEnableAuthMethod
  | VaultReconcileWriteKubernetesAuthConfig
  | VaultReconcileReadTransitKey
  | VaultReconcileCreateTransitKey
  | VaultReconcileWritePolicy
  | VaultReconcileWriteKubernetesRole
  | VaultReconcileReadBackKubernetesRole
  deriving (Eq, Ord, Show, Enum, Bounded)

data VaultReconcileError
  = VaultReconcileHttpError VaultReconcileHttpOperation Text HttpError
  | VaultReconcileMountTypeMismatch Text Text Text
  | VaultReconcileMountOptionMismatch Text Text Text (Maybe Text)
  | VaultReconcileAuthTypeMismatch Text Text Text
  | VaultReconcileTransitKeyTypeMismatch Text Text Text
  | VaultReconcileKubernetesRoleReadbackMismatch Text
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
          , "prodbox-retained-material"
          , "prodbox-tls-retention-dek"
          ]
          ++ [VaultTransitKeySpec "prodbox-authority-genesis-signing" "ed25519"]
          ++ [VaultTransitKeySpec "prodbox-target-secret-commitment" "hmac"]
          ++ [VaultTransitKeySpec "prodbox-retained-material-commitment" "hmac"]
          ++ [ VaultTransitKeySpec (controlPlaneSigningKeyName ref) "ed25519"
             | ref <- controlPlaneSigningKeyInventory
             ]
    , vaultReconcilePolicies =
        [ VaultPolicySpec
            "prodbox-gateway"
            (gatewayPolicy <> serviceControlPlaneClientPolicy GatewayRuntime)
        , VaultPolicySpec
            (vaultRoleIdText VaultRoleBootstrapBroker)
            bootstrapBrokerPolicy
        , VaultPolicySpec bootstrapProvisionerRole bootstrapProvisionerPolicy
        , VaultPolicySpec bootstrapPkiOperatorRole bootstrapPkiOperatorPolicy
        , VaultPolicySpec bootstrapSealRole bootstrapSealPolicy
        , VaultPolicySpec
            bootstrapControlPlaneClientRole
            (serviceControlPlaneClientPolicy BootstrapBroker)
        , VaultPolicySpec tokenAccessorAuditorRole tokenAccessorAuditorPolicy
        , VaultPolicySpec "prodbox-pulumi" pulumiPolicy
        , VaultPolicySpec "prodbox-federation-custody" federationPolicy
        , VaultPolicySpec
            "prodbox-lifecycle-authority"
            ( lifecycleAuthorityPolicy
                <> standingControlPlaneAuthenticationPolicy LifecycleAuthorityRuntime
            )
        , VaultPolicySpec
            "prodbox-provider-worker"
            ( providerWorkerPolicy
                <> standingControlPlaneAuthenticationPolicy ProviderWorkerRuntime
            )
        , VaultPolicySpec
            "prodbox-authority-backup"
            ( authorityBackupPolicy
                <> standingControlPlaneAuthenticationPolicy AuthorityBackupRuntime
            )
        , VaultPolicySpec
            "prodbox-tls-retention"
            ( tlsRetentionPolicy
                <> standingControlPlaneAuthenticationPolicy TlsRetentionRuntime
            )
        , VaultPolicySpec
            "prodbox-target-secret-agent"
            ( targetSecretAgentPolicy
                <> standingControlPlaneAuthenticationPolicy TargetSecretAgentRuntime
            )
        , VaultPolicySpec
            operatorControlPlaneVaultRole
            (externalControlPlaneAuthenticationPolicy CallerOperatorCli)
        , VaultPolicySpec
            harnessControlPlaneVaultRole
            (externalControlPlaneAuthenticationPolicy CallerTestHarness)
        , VaultPolicySpec
            externalMaterialIngressVaultRole
            externalMaterialIngressPolicy
        , VaultPolicySpec
            externalMaterialIngressAuditorVaultRole
            ( narrowTokenAccessorAuditorPolicy
                <> serviceSessionJournalPolicy externalMaterialIngressVaultRole
                <> serviceSessionJournalPolicy targetSecretWorkerVaultRole
            )
        , VaultPolicySpec
            credentialProvisionerAuditorVaultRole
            ( narrowTokenAccessorAuditorPolicy
                <> serviceSessionJournalPolicy credentialProvisionerVaultRole
                <> serviceSessionJournalPolicy targetSecretWorkerVaultRole
            )
        , VaultPolicySpec
            credentialProvisionerVaultRole
            credentialProvisionerPolicy
        , VaultPolicySpec
            credentialProvisionerCompletionVaultRole
            (externalControlPlaneAuthenticationPolicy CallerCredentialProvisioner)
        , VaultPolicySpec
            adminActionRunnerVaultRole
            ( adminActionRunnerPolicy
                <> externalControlPlaneAuthenticationPolicy CallerAdminActionRunner
            )
        , VaultPolicySpec
            adminActionRunnerAuditorVaultRole
            adminActionRunnerAuditorPolicy
        , VaultPolicySpec
            adminActionRunnerCompletionVaultRole
            (externalControlPlaneAuthenticationPolicy CallerAdminActionRunner)
        , VaultPolicySpec
            targetSecretWorkerVaultRole
            targetSecretWorkerPolicy
        , VaultPolicySpec
            targetSecretWorkerAuditorVaultRole
            targetSecretWorkerAuditorPolicy
        , VaultPolicySpec
            targetSecretControllerAuditorVaultRole
            ( targetSecretWorkerAuditorPolicy
                <> serviceSessionJournalPolicy targetSecretWorkerVaultRole
            )
        ]
          ++ map chartSecretPolicy chartVaultSecretConsumers
    , vaultReconcileKubernetesRoles =
        [ VaultKubernetesRoleSpec
            (vaultRoleIdText VaultRoleGatewayDaemon)
            ["prodbox-gateway-daemon"]
            ["gateway"]
            -- The gateway daemon logs in under this role (charts/gateway/values.yaml
            -- `vault.role`). It needs BOTH policies: `prodbox-gateway` for the
            -- object-store HMAC read + prodbox-pulumi-state Transit encrypt/decrypt,
            -- and `gateway-gateway` (the gateway-event-keys consumer policy) for the
            -- per-node event-key / Gateway DNS / gateway minio KV reads.
            ["prodbox-gateway", "gateway-gateway"]
            Nothing
            "1h"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            (vaultRoleIdText VaultRoleBootstrapBroker)
            ["prodbox-bootstrap-secret-worker"]
            ["bootstrap-broker"]
            [vaultRoleIdText VaultRoleBootstrapBroker]
            Nothing
            "5m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            bootstrapProvisionerRole
            ["prodbox-bootstrap-broker"]
            ["bootstrap-broker"]
            [bootstrapProvisionerRole]
            Nothing
            "5m"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            bootstrapPkiOperatorRole
            ["prodbox-bootstrap-broker"]
            ["bootstrap-broker"]
            [bootstrapPkiOperatorRole]
            Nothing
            "5m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            bootstrapSealRole
            ["prodbox-bootstrap-broker"]
            ["bootstrap-broker"]
            [bootstrapSealRole]
            Nothing
            "1m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            bootstrapControlPlaneClientRole
            ["prodbox-bootstrap-broker"]
            ["bootstrap-broker"]
            [bootstrapControlPlaneClientRole]
            Nothing
            "15m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            tokenAccessorAuditorRole
            ["prodbox-bootstrap-broker"]
            ["bootstrap-broker"]
            [tokenAccessorAuditorRole]
            Nothing
            "5m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            "prodbox-pulumi-runner"
            ["prodbox-pulumi-runner"]
            ["prodbox-system"]
            ["prodbox-pulumi"]
            Nothing
            "1h"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            "prodbox-federation-controller"
            ["prodbox-federation-controller"]
            ["gateway"]
            ["prodbox-federation-custody"]
            Nothing
            "1h"
            VaultKubernetesServiceToken
        , standingRole
            VaultRoleLifecycleAuthority
            "prodbox-lifecycle-authority"
        , standingRole
            VaultRoleProviderWorker
            "prodbox-provider-worker"
        , standingRole
            VaultRoleAuthorityBackup
            "prodbox-authority-backup"
        , standingRole
            VaultRoleTlsRetention
            "prodbox-tls-retention"
        , standingRole
            VaultRoleTargetSecretAgent
            "prodbox-target-secret-agent"
        , VaultKubernetesRoleSpec
            operatorControlPlaneVaultRole
            [operatorControlPlaneVaultRole]
            ["bootstrap-broker"]
            [operatorControlPlaneVaultRole]
            Nothing
            "5m"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            harnessControlPlaneVaultRole
            [harnessControlPlaneVaultRole]
            ["gateway"]
            [harnessControlPlaneVaultRole]
            Nothing
            "15m"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            externalMaterialIngressVaultRole
            [externalMaterialIngressVaultRole]
            ["credential-provisioner"]
            [externalMaterialIngressVaultRole]
            (Just "prodbox-control-plane")
            "10m"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            externalMaterialIngressAuditorVaultRole
            [externalMaterialIngressVaultRole]
            ["credential-provisioner"]
            [externalMaterialIngressAuditorVaultRole]
            (Just "prodbox-control-plane")
            "2m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            credentialProvisionerAuditorVaultRole
            [credentialProvisionerVaultRole]
            ["credential-provisioner"]
            [credentialProvisionerAuditorVaultRole]
            (Just "prodbox-control-plane")
            "2m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            credentialProvisionerVaultRole
            [credentialProvisionerVaultRole]
            ["credential-provisioner"]
            [credentialProvisionerVaultRole]
            (Just "prodbox-control-plane")
            "10m"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            credentialProvisionerCompletionVaultRole
            [credentialProvisionerVaultRole]
            ["credential-provisioner"]
            [credentialProvisionerCompletionVaultRole]
            (Just "prodbox-control-plane")
            "2m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            adminActionRunnerVaultRole
            [adminActionRunnerVaultRole]
            ["admin-action-runner"]
            [adminActionRunnerVaultRole]
            (Just "vault")
            "10m"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            adminActionRunnerAuditorVaultRole
            [adminActionRunnerVaultRole]
            ["admin-action-runner"]
            [adminActionRunnerAuditorVaultRole]
            (Just "vault")
            "5m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            adminActionRunnerCompletionVaultRole
            [adminActionRunnerVaultRole]
            ["admin-action-runner"]
            [adminActionRunnerCompletionVaultRole]
            (Just "vault")
            "2m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            targetSecretWorkerVaultRole
            [targetSecretWorkerVaultRole]
            ["target-secret-agent"]
            [targetSecretWorkerVaultRole]
            (Just "prodbox-control-plane")
            "10m"
            VaultKubernetesServiceToken
        , VaultKubernetesRoleSpec
            targetSecretWorkerAuditorVaultRole
            [targetSecretWorkerVaultRole]
            ["target-secret-agent"]
            [targetSecretWorkerAuditorVaultRole]
            (Just "prodbox-control-plane")
            "5m"
            VaultKubernetesBatchToken
        , VaultKubernetesRoleSpec
            targetSecretControllerAuditorVaultRole
            ["prodbox-target-secret-agent", "prodbox-lifecycle-authority"]
            ["target-secret-agent", "lifecycle-authority"]
            [targetSecretControllerAuditorVaultRole]
            (Just "prodbox-control-plane")
            "5m"
            VaultKubernetesBatchToken
        ]
          ++ map chartSecretRole chartVaultSecretConsumers
    , vaultReconcileSecretObjects =
        controlPlaneAuthorityEpochSeed : chartVaultManagedSecretObjects
    }

standingRole :: VaultRoleId -> Text -> VaultKubernetesRoleSpec
standingRole role policy =
  VaultKubernetesRoleSpec
    (vaultRoleIdText role)
    [vaultRoleIdText role]
    ["gateway"]
    [policy]
    Nothing
    "1h"
    VaultKubernetesServiceToken

controlPlaneAuthorityEpochSeed :: VaultSecretObjectSpec
controlPlaneAuthorityEpochSeed =
  VaultSecretObjectSpec
    { vaultSecretObjectPath = VaultSecretPath "secret" controlPlaneAuthorityEpochPath
    , vaultSecretObjectFields =
        [ VaultSecretFieldSpec
            { vaultSecretFieldName = "epoch"
            , vaultSecretFieldSource = VaultSecretStatic "1"
            }
        ]
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
    Nothing
    (vaultSecretConsumerTtl consumer)
    VaultKubernetesServiceToken

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
          \spec -> do
            let writeRole = case vaultKubernetesRoleSpecTokenType spec of
                  VaultKubernetesServiceToken -> vaultWriteKubernetesRole
                  VaultKubernetesBatchToken -> vaultWriteKubernetesBatchRole
            writeRole
              address
              token
              (vaultKubernetesRoleSpecName spec)
              (vaultKubernetesRoleSpecServiceAccounts spec)
              (vaultKubernetesRoleSpecNamespaces spec)
              (vaultKubernetesRoleSpecPolicies spec)
              (vaultKubernetesRoleSpecAudience spec)
              (vaultKubernetesRoleSpecTtl spec)
      , vaultOpsReadKubernetesRole =
          \spec ->
            vaultReadKubernetesRole
              address
              token
              (vaultKubernetesRoleSpecName spec)
      , vaultOpsSecretBootstrap =
          VaultSecretBootstrapOps
            { vaultSecretBootstrapObserve =
                \path -> do
                  observed <-
                    vaultKvReadVersionedV2
                      address
                      token
                      (vaultSecretPathMount path)
                      (vaultSecretPathLogical path)
                  pure $ case observed of
                    Left (HttpStatus 404 _) -> Right VaultSecretObjectAbsent
                    Left err -> Left err
                    Right versioned ->
                      Right
                        ( VaultSecretObjectPresent
                            (kvV2VersionedSecretVersion versioned)
                            (kvV2VersionedSecretData versioned)
                        )
            , -- Sprint 4.71: conditioned on the version the observation
              -- carried. The bootstrap fold unions generated fields onto what
              -- it read, so an unconditional write here silently discarded a
              -- concurrent writer's generated field.
              vaultSecretBootstrapWrite =
                \path expectedVersion fields -> do
                  written <-
                    vaultKvCasWriteV2
                      address
                      token
                      (vaultSecretPathMount path)
                      (vaultSecretPathLogical path)
                      (KvV2Cas expectedVersion)
                      fields
                  -- Sprint 4.74: the fold's caller receives which of the three
                  -- CAS facts occurred rather than one transport error.
                  pure $ case classifyVaultCasOutcome written of
                    VaultCasApplied _ -> Right ()
                    failed -> Left failed
            , vaultSecretBootstrapGenerate = generateVaultSecretFieldValue
            }
      }

runVaultReconcileWith
  :: VaultReconcileOps -> VaultReconcilePlan -> IO (Either VaultReconcileError [VaultReconcileStep])
runVaultReconcileWith ops plan = do
  mountResult <- vaultOpsListMounts ops
  case mountResult of
    Left err ->
      pure
        (Left (VaultReconcileHttpError VaultReconcileListMounts "list mounts" err))
    Right existingMounts -> do
      mountStepsResult <- reconcileMounts ops existingMounts (vaultReconcileMounts plan)
      case mountStepsResult of
        Left err -> pure (Left err)
        Right mountSteps -> do
          authResult <- vaultOpsListAuthMethods ops
          case authResult of
            Left err ->
              pure
                ( Left
                    ( VaultReconcileHttpError
                        VaultReconcileListAuthMethods
                        "list auth methods"
                        err
                    )
                )
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
            pure
              ( Left
                  ( VaultReconcileHttpError
                      VaultReconcileEnableMount
                      ("enable mount " <> vaultMountSpecPath spec)
                      err
                  )
              )
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
            pure
              ( Left
                  ( VaultReconcileHttpError
                      VaultReconcileEnableAuthMethod
                      ("enable auth " <> vaultAuthSpecPath spec)
                      err
                  )
              )
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
                  VaultReconcileWriteKubernetesAuthConfig
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
            pure
              ( Left
                  ( VaultReconcileHttpError
                      VaultReconcileCreateTransitKey
                      ("create transit key " <> vaultTransitKeySpecName spec)
                      err
                  )
              )
          Right () ->
            go (step VaultReconcileTransitKey (vaultTransitKeySpecName spec) VaultReconcileCreated : steps) rest
      Left err ->
        pure
          ( Left
              ( VaultReconcileHttpError
                  VaultReconcileReadTransitKey
                  ("read transit key " <> vaultTransitKeySpecName spec)
                  err
              )
          )

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
        pure
          ( Left
              ( VaultReconcileHttpError
                  VaultReconcileWritePolicy
                  ("write policy " <> vaultPolicySpecName spec)
                  err
              )
          )
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
    written <- vaultOpsWriteKubernetesRole ops spec
    case written of
      Left err ->
        pure
          ( Left
              ( VaultReconcileHttpError
                  VaultReconcileWriteKubernetesRole
                  ("write Kubernetes role " <> vaultKubernetesRoleSpecName spec)
                  err
              )
          )
      Right () -> do
        observed <- vaultOpsReadKubernetesRole ops spec
        case observed of
          Left err ->
            pure
              ( Left
                  ( VaultReconcileHttpError
                      VaultReconcileReadBackKubernetesRole
                      ("read back Kubernetes role " <> vaultKubernetesRoleSpecName spec)
                      err
                  )
              )
          Right readback
            | kubernetesRoleReadbackMatches spec readback ->
                go
                  (step VaultReconcileKubernetesRole (vaultKubernetesRoleSpecName spec) VaultReconcileWritten : steps)
                  rest
            | otherwise ->
                pure
                  ( Left
                      ( VaultReconcileKubernetesRoleReadbackMismatch
                          (vaultKubernetesRoleSpecName spec)
                      )
                  )

kubernetesRoleReadbackMatches
  :: VaultKubernetesRoleSpec -> KubernetesRoleReadback -> Bool
kubernetesRoleReadbackMatches spec readback =
  case vaultDurationSeconds (vaultKubernetesRoleSpecTtl spec) of
    Nothing -> False
    Just ttlSeconds ->
      kubernetesRoleReadbackServiceAccounts readback
        == vaultKubernetesRoleSpecServiceAccounts spec
        && kubernetesRoleReadbackNamespaces readback
          == vaultKubernetesRoleSpecNamespaces spec
        && kubernetesRoleReadbackPolicies readback
          == vaultKubernetesRoleSpecPolicies spec
        && normalizeAudience (kubernetesRoleReadbackAudience readback)
          == normalizeAudience (vaultKubernetesRoleSpecAudience spec)
        && kubernetesRoleReadbackTtlSeconds readback == ttlSeconds
        && kubernetesRoleReadbackMaximumTtlSeconds readback == ttlSeconds
        && kubernetesRoleReadbackExplicitMaximumTtlSeconds readback == ttlSeconds
        && kubernetesRoleReadbackTokenType readback == expectedTokenType
 where
  expectedTokenType = case vaultKubernetesRoleSpecTokenType spec of
    VaultKubernetesServiceToken -> "service"
    VaultKubernetesBatchToken -> "batch"

normalizeAudience :: Maybe Text -> Maybe Text
normalizeAudience candidate = case Text.strip <$> candidate of
  Just value | not (Text.null value) -> Just value
  _ -> Nothing

vaultDurationSeconds :: Text -> Maybe Natural
vaultDurationSeconds raw = do
  (digits, suffix) <- Text.unsnoc (Text.strip raw)
  if Text.null digits || not (Text.all isDigit digits)
    then Nothing
    else do
      value <- readMaybe (Text.unpack digits)
      multiplier <- case suffix of
        's' -> Just 1
        'm' -> Just 60
        'h' -> Just 3600
        _ -> Nothing
      let seconds = value * multiplier
      if seconds > 0 then Just seconds else Nothing

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
  VaultReconcileHttpError _ context httpErr ->
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
  VaultReconcileKubernetesRoleReadbackMismatch role ->
    "Vault Kubernetes role "
      ++ Text.unpack role
      ++ " did not read back with its exact ServiceAccount, namespace, policy, audience, token type, and TTL caps"
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
  VaultSecretBootstrapWriteFailed path casOutcome ->
    "Vault secret "
      ++ Text.unpack (vaultSecretPathName path)
      ++ " write failed: "
      ++ Text.unpack (renderVaultCasOutcome casOutcome)
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
    , "path \"secret/data/prodbox/gateway/continuity-admission/*\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
    , "}"
    , ""
    , "path \"secret/data/keycloak/smtp\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
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

-- | The only keys the isolated Broker worker may rotate.  The same closed
-- inventory drives both its Vault ACL and its runtime input validation.
bootstrapBrokerRotatableTransitKeys :: [Text]
bootstrapBrokerRotatableTransitKeys =
  [ "prodbox-active-config"
  , "prodbox-gateway-state"
  , "prodbox-pulumi-state"
  , "prodbox-minio-envelope"
  , "prodbox-downstream-cluster-config"
  ]

bootstrapBrokerPolicy :: Text
bootstrapBrokerPolicy =
  Text.concat (fmap keyRules bootstrapBrokerRotatableTransitKeys)
 where
  keyRules keyName =
    Text.unlines
      [ "path \"transit/keys/" <> keyName <> "\" {"
      , "  capabilities = [\"read\"]"
      , "}"
      , "path \"transit/keys/" <> keyName <> "/rotate\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      ]

bootstrapProvisionerRole :: Text
bootstrapProvisionerRole = "prodbox-bootstrap-provisioner"

-- | Accessor-free batch role for post-bootstrap PKI observation and the exact
-- compiled test-certificate issuance.  It cannot reconcile mounts, policies,
-- auth roles, secrets, or seal Vault.
bootstrapPkiOperatorRole :: Text
bootstrapPkiOperatorRole = "prodbox-bootstrap-pki-operator"

-- | Standing controller-only role used solely to sign the Broker's closed
-- service-to-service requests.  Secret workers cannot select this role, and
-- it carries none of the provisioner's Vault baseline capability.
bootstrapControlPlaneClientRole :: Text
bootstrapControlPlaneClientRole = "prodbox-bootstrap-control-plane-client"

bootstrapSealRole :: Text
bootstrapSealRole = "prodbox-bootstrap-seal"

tokenAccessorAuditorRole :: Text
tokenAccessorAuditorRole = "prodbox-token-accessor-auditor"

data VaultPkiBaselineStatus
  = VaultPkiBaselineAbsent
  | VaultPkiBaselineDrifted
  | VaultPkiBaselineReady
  deriving (Eq, Show)

-- | Closed mutation-side PKI operation vocabulary. Operator context, Vault
-- paths, role names, and response bodies stay in the HTTP client rather than
-- becoming part of the bootstrap diagnostic contract.
data VaultPkiReconcileOperation
  = VaultPkiReconcileListIssuers
  | VaultPkiReconcileGenerateInternalRoot
  | VaultPkiReconcileWriteRole
  deriving (Eq, Show, Enum, Bounded)

-- | Closed read-back-side PKI operation vocabulary.
data VaultPkiObserveOperation
  = VaultPkiObserveListIssuers
  | VaultPkiObserveReadRole
  deriving (Eq, Show, Enum, Bounded)

data VaultPkiObserveError
  = VaultPkiObserveHttpError !VaultPkiObserveOperation !HttpError
  deriving (Eq, Show)

data VaultPkiReconcileError
  = VaultPkiReconcileHttpError !VaultPkiReconcileOperation !HttpError
  | VaultPkiReconcileObserveFailed !VaultPkiObserveError
  | VaultPkiReconcileReadBackNotExact !VaultPkiBaselineStatus
  deriving (Eq, Show)

data VaultPkiRootDecision
  = VaultPkiGenerateRoot
  | VaultPkiKeepExistingRoot
  deriving (Eq, Show)

-- | Decide the first PKI reconciliation step from issuer-list evidence.
-- Vault represents a newly mounted PKI engine with HTTP 404 until an issuer
-- exists; that state is semantically identical to a successful empty list.
decideVaultPkiRoot
  :: Either HttpError [Text]
  -> Either VaultPkiReconcileError VaultPkiRootDecision
decideVaultPkiRoot issuers = case issuers of
  Right [] -> Right VaultPkiGenerateRoot
  Right _ -> Right VaultPkiKeepExistingRoot
  Left (HttpStatus 404 _) -> Right VaultPkiGenerateRoot
  Left failure ->
    Left (VaultPkiReconcileHttpError VaultPkiReconcileListIssuers failure)

reconcileVaultPkiBaseline
  :: VaultAddress
  -> VaultToken
  -> IO (Either VaultPkiReconcileError VaultPkiBaselineStatus)
reconcileVaultPkiBaseline address token = do
  issuers <- vaultListPkiIssuers address token
  generated <- case decideVaultPkiRoot (pkiIssuerKeys <$> issuers) of
    Right VaultPkiGenerateRoot ->
      fmap
        ( either
            (Left . VaultPkiReconcileHttpError VaultPkiReconcileGenerateInternalRoot)
            Right
        )
        (vaultGeneratePkiInternalRoot address token)
    Right VaultPkiKeepExistingRoot -> pure (Right ())
    Left failure -> pure (Left failure)
  case generated of
    Left failure -> pure (Left failure)
    Right () -> do
      written <- vaultWritePkiRole address token "prodbox-bootstrap-test"
      case written of
        Left failure ->
          pure
            ( Left
                (VaultPkiReconcileHttpError VaultPkiReconcileWriteRole failure)
            )
        Right () -> do
          observed <- observeVaultPkiBaseline address token
          pure $ case observed of
            Right VaultPkiBaselineReady -> Right VaultPkiBaselineReady
            Right status -> Left (VaultPkiReconcileReadBackNotExact status)
            Left failure -> Left (VaultPkiReconcileObserveFailed failure)

observeVaultPkiBaseline
  :: VaultAddress
  -> VaultToken
  -> IO (Either VaultPkiObserveError VaultPkiBaselineStatus)
observeVaultPkiBaseline address token = do
  issuers <- vaultListPkiIssuers address token
  role <- vaultReadPkiRole address token "prodbox-bootstrap-test"
  pure $ case (issuers, role) of
    (Right listing, Right info)
      | null (pkiIssuerKeys listing) -> Right VaultPkiBaselineAbsent
      | pkiRoleAllowsAnyName info
          && pkiRoleMaxTtlSeconds info == 3600
          && pkiRoleKeyType info == "ec" ->
          Right VaultPkiBaselineReady
      | otherwise -> Right VaultPkiBaselineDrifted
    (Left (HttpStatus 404 _), _) -> Right VaultPkiBaselineAbsent
    (_, Left (HttpStatus 404 _)) -> Right VaultPkiBaselineAbsent
    (Left failure, _) ->
      Left (VaultPkiObserveHttpError VaultPkiObserveListIssuers failure)
    (_, Left failure) ->
      Left (VaultPkiObserveHttpError VaultPkiObserveReadRole failure)

-- The post-bootstrap provisioner can reconcile only the compiled Vault
-- baseline families plus the Broker's exact test-PKI operations. It
-- has no token administration, generated-root, or generic raw sys capability.
bootstrapProvisionerPolicy :: Text
bootstrapProvisionerPolicy =
  Text.unlines
    [ "path \"sys/mounts\" { capabilities = [\"read\"] }"
    , "path \"sys/mounts/secret\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"sys/mounts/transit\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"sys/mounts/pki\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"sys/auth\" { capabilities = [\"read\"] }"
    , "path \"sys/auth/kubernetes\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"auth/kubernetes/config\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"transit/keys/prodbox-*\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"sys/policies/acl/prodbox-*\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"auth/kubernetes/role/prodbox-*\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"secret/data/*\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"secret/metadata/*\" { capabilities = [\"read\"] }"
    , "path \"pki/issuers\" { capabilities = [\"list\"] }"
    , "path \"pki/root/generate/internal\" { capabilities = [\"update\"] }"
    , "path \"pki/roles/prodbox-bootstrap-test\" { capabilities = [\"create\", \"read\", \"update\"] }"
    , "path \"pki/issue/prodbox-bootstrap-test\" { capabilities = [\"update\"] }"
    ]

bootstrapPkiOperatorPolicy :: Text
bootstrapPkiOperatorPolicy =
  Text.unlines
    [ "path \"pki/issuers\" { capabilities = [\"list\"] }"
    , "path \"pki/roles/prodbox-bootstrap-test\" { capabilities = [\"read\"] }"
    , "path \"pki/issue/prodbox-bootstrap-test\" { capabilities = [\"update\"] }"
    ]

-- The seal operation uses a one-minute batch token.  It has no server-side
-- accessor to defer across the transition to sealed state and cannot perform
-- any baseline, token-administration, or data operation.
bootstrapSealPolicy :: Text
bootstrapSealPolicy =
  Text.unlines
    [ "path \"sys/seal\" { capabilities = [\"update\", \"sudo\"] }"
    ]

tokenAccessorAuditorPolicy :: Text
tokenAccessorAuditorPolicy =
  Text.unlines
    [ "path \"auth/token/accessors\" { capabilities = [\"list\", \"sudo\"] }"
    , "path \"auth/token/lookup-accessor\" { capabilities = [\"update\", \"sudo\"] }"
    , "path \"auth/token/revoke-accessor\" { capabilities = [\"update\", \"sudo\"] }"
    ]

narrowTokenAccessorAuditorPolicy :: Text
narrowTokenAccessorAuditorPolicy =
  Text.unlines
    [ "path \"auth/token/accessors\" { capabilities = [\"list\", \"sudo\"] }"
    , "path \"auth/token/lookup-accessor\" { capabilities = [\"update\", \"sudo\"] }"
    , "path \"auth/token/revoke-accessor\" { capabilities = [\"update\", \"sudo\"] }"
    ]

serviceSessionJournalPolicy :: Text -> Text
serviceSessionJournalPolicy workerRole =
  Text.unlines
    [ "path \"secret/data/control-plane/service-sessions/" <> workerRole <> "\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
    , "}"
    ]

lifecycleAuthorityPolicy :: Text
lifecycleAuthorityPolicy =
  Text.unlines
    [ "path \"secret/data/minio/lifecycle-authority\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , "path \"secret/data/object-store/hmac\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , "path \"transit/encrypt/prodbox-pulumi-state\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"transit/decrypt/prodbox-pulumi-state\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"transit/encrypt/prodbox-active-config\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"transit/decrypt/prodbox-active-config\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"transit/keys/prodbox-authority-genesis-signing\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , "path \"transit/sign/prodbox-authority-genesis-signing\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"secret/data/control-plane/bootstrap-handoff\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
    , "}"
    ]

providerWorkerPolicy :: Text
providerWorkerPolicy =
  readOnlyKvPolicy "secret/data/aws/lifecycle-provider"
    <> readOnlyKvPolicy "secret/metadata/aws/lifecycle-provider"

authorityBackupPolicy :: Text
authorityBackupPolicy =
  readOnlyKvPolicy "secret/data/aws/authority-backup-store"

tlsRetentionPolicy :: Text
tlsRetentionPolicy =
  readOnlyKvPolicy "secret/data/aws/tls-retention-store"

targetSecretAgentPolicy :: Text
targetSecretAgentPolicy =
  Text.concat (fmap targetRule allTargetMaterialIds)
    <> Text.concat (fmap trustRule targetWorkerAuthorizationIds)
    <> Text.unlines
      [ "path \"secret/data/target-agent/retained-home/ses-smtp-source\" {"
      , "  capabilities = [\"create\", \"read\", \"update\"]"
      , "}"
      , "path \"secret/metadata/target-agent/retained-home/ses-smtp-source\" {"
      , "  capabilities = [\"create\", \"read\", \"update\", \"delete\"]"
      , "}"
      , "path \"secret/data/target-agent/retained-home/acme-eab-source\" {"
      , "  capabilities = [\"create\", \"read\", \"update\"]"
      , "}"
      , "path \"secret/metadata/target-agent/retained-home/acme-eab-source\" {"
      , "  capabilities = [\"create\", \"read\", \"update\", \"delete\"]"
      , "}"
      , "path \"transit/encrypt/prodbox-retained-material\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"transit/decrypt/prodbox-retained-material\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"transit/hmac/prodbox-retained-material-commitment\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"transit/encrypt/prodbox-tls-retention-dek\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"transit/decrypt/prodbox-tls-retention-dek\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"transit/keys/prodbox-authority-genesis-signing\" {"
      , "  capabilities = [\"read\"]"
      , "}"
      , "path \"secret/data/target-agent/child-custody/*\" {"
      , "  capabilities = [\"create\", \"read\", \"update\"]"
      , "}"
      ]
 where
  targetRule target =
    let logical = targetSecretIdVaultLogicalPath target
     in Text.unlines
          [ "path \"secret/metadata/" <> logical <> "\" {"
          , "  capabilities = [\"read\", \"delete\"]"
          , "}"
          ]
  trustRule target =
    Text.unlines
      [ "path \"secret/data/target-agent/trust/" <> targetSecretIdToken target <> "\" {"
      , "  capabilities = [\"create\", \"read\", \"update\"]"
      , "}"
      ]

standingControlPlaneAuthenticationPolicy :: RuntimeRole -> Text
standingControlPlaneAuthenticationPolicy role =
  Text.unlines
    ( [ ""
      , "path \"transit/keys/" <> ownKey <> "\" {"
      , "  capabilities = [\"read\"]"
      , "}"
      , "path \"transit/sign/" <> ownKey <> "\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      ]
        <> concatMap publicReadRule inboundKeyNames
        <> epochRules
        <> [ "path \"secret/data/" <> controlPlaneRequestReplayPath role <> "\" {"
           , "  capabilities = [\"create\", \"read\", \"update\"]"
           , "}"
           ]
    )
 where
  ownKey = controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor (CallerService role))
  inboundKeyNames =
    filter
      (/= ownKey)
      [ controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor caller)
      | caller <- trustedCallersForRole role
      ]
  publicReadRule keyName =
    [ "path \"transit/keys/" <> keyName <> "\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    ]
  epochRules
    | role == LifecycleAuthorityRuntime =
        [ "path \"secret/data/" <> controlPlaneAuthorityEpochPath <> "\" {"
        , "  capabilities = [\"create\", \"read\", \"update\"]"
        , "}"
        ]
    | otherwise =
        [ "path \"secret/data/" <> controlPlaneAuthorityEpochPath <> "\" {"
        , "  capabilities = [\"read\"]"
        , "}"
        ]

externalControlPlaneAuthenticationPolicy :: CallerPrincipal -> Text
externalControlPlaneAuthenticationPolicy caller =
  Text.unlines
    [ "path \"transit/keys/" <> keyName <> "\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , "path \"transit/sign/" <> keyName <> "\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"secret/data/" <> controlPlaneAuthorityEpochPath <> "\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , "path \"transit/keys/prodbox-authority-genesis-signing\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    ]
 where
  keyName = controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor caller)

-- | Exact one-shot EAB ingress/custody capability.  The schema-bound worker can
-- verify the Authority permit and seal only the retained ACME EAB source.  It
-- has no retained decrypt, final-target KV, generic Target Agent, or
-- control-plane signing capability.
externalMaterialIngressPolicy :: Text
externalMaterialIngressPolicy =
  Text.unlines
    [ "path \"transit/keys/prodbox-authority-genesis-signing\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , "path \"secret/data/target-agent/retained-home/acme-eab-source\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
    , "}"
    , "path \"secret/metadata/target-agent/retained-home/acme-eab-source\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
    , "}"
    , "path \"transit/encrypt/prodbox-retained-material\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"transit/hmac/prodbox-retained-material-commitment\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"auth/token/revoke-self\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    ]

-- | Exact one-shot AWS-admin worker capability. Administrator credentials
-- arrive only over the bounded stdin frame, and newly minted credentials leave
-- only through the authenticated Target materialization protocol. The worker
-- can verify the Authority permit, maintain its own two secret-free journals,
-- and revoke itself. A disjoint accessor-free completion role authenticates
-- the terminal handoff only after the worker session is proven absent; this
-- role has no generic secret read/write, AWS credential KV, or retained
-- decrypt grant.
credentialProvisionerPolicy :: Text
credentialProvisionerPolicy =
  Text.unlines
    [ "path \"transit/keys/prodbox-authority-genesis-signing\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , "path \"secret/data/control-plane/aws-admin-executions/*\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
    , "}"
    , "path \"secret/data/target-agent/retained-home/ses-smtp-source\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
    , "}"
    , "path \"secret/metadata/target-agent/retained-home/ses-smtp-source\" {"
    , "  capabilities = [\"create\", \"read\", \"update\"]"
    , "}"
    , "path \"transit/encrypt/prodbox-retained-material\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"transit/hmac/prodbox-retained-material-commitment\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , "path \"auth/token/revoke-self\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    ]
    <> serviceSessionJournalPolicy credentialProvisionerVaultRole

-- | The one-shot Admin Runner can verify only the Authority-signed permit and
-- revoke its own short lease. AWS authorization arrives separately over the
-- attested stdin frame; no standing AWS KV, generic control-plane signing, or
-- Target Secret Agent data capability is granted here.
adminActionRunnerPolicy :: Text
adminActionRunnerPolicy =
  Text.unlines
    [ "path \"transit/keys/prodbox-authority-genesis-signing\" {"
    , "  capabilities = [\"read\"]"
    , "}"
    , "path \"auth/token/revoke-self\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    ]

-- | A second, independently short batch session may revoke and answer exactly
-- one journaled accessor lookup. It has no accessor of its own, cannot list,
-- sign, or read any application/Vault data, and expires after five minutes.
adminActionRunnerAuditorPolicy :: Text
adminActionRunnerAuditorPolicy =
  narrowTokenAccessorAuditorPolicy
    <> serviceSessionJournalPolicy adminActionRunnerVaultRole

-- | Ephemeral Target materializer authority.  Every KV coordinate comes from
-- the closed target registry and this policy is bound only to the one-shot
-- worker ServiceAccount.  There is no control-plane signing/replay capability,
-- generic KV wildcard, list, delete, or Transit decrypt authority.
targetSecretWorkerPolicy :: Text
targetSecretWorkerPolicy =
  Text.concat (fmap targetRules targetWorkerTargetIds)
    <> Text.concat (fmap trustRule targetWorkerAuthorizationIds)
    <> Text.unlines
      [ "path \"transit/hmac/prodbox-target-secret-commitment\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"transit/hmac/prodbox-retained-material-commitment\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"transit/encrypt/prodbox-tls-retention-dek\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"transit/decrypt/prodbox-tls-retention-dek\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      , "path \"secret/data/target-agent/child-custody/*\" {"
      , "  capabilities = [\"create\", \"read\", \"update\"]"
      , "}"
      , "path \"auth/token/revoke-self\" {"
      , "  capabilities = [\"update\"]"
      , "}"
      ]
 where
  targetRules target =
    let logical = targetSecretIdVaultLogicalPath target
     in Text.unlines
          [ "path \"secret/data/" <> logical <> "\" {"
          , "  capabilities = [\"create\", \"read\", \"update\"]"
          , "}"
          , "path \"secret/metadata/" <> logical <> "\" {"
          , "  capabilities = [\"create\", \"read\", \"update\"]"
          , "}"
          ]
  trustRule target =
    Text.unlines
      [ "path \"secret/data/target-agent/trust/" <> targetSecretIdToken target <> "\" {"
      , "  capabilities = [\"read\"]"
      , "}"
      ]

targetSecretWorkerAuditorPolicy :: Text
targetSecretWorkerAuditorPolicy =
  tokenAccessorAuditorPolicy
    <> serviceSessionJournalPolicy targetSecretWorkerVaultRole

targetWorkerTargetIds :: [TargetSecretId]
targetWorkerTargetIds =
  [ TargetSesSmtp
  , TargetAcmeEab
  ]
    <> [ TargetAwsCredential identity
       | identity <- [minBound .. maxBound]
       , identity /= AwsRunCertManagerDns01
       ]

-- | Every signed intent coordinate the one-shot worker may authenticate.
-- Operation coordinates receive trust-record access and their own exact
-- capabilities above, but no synthetic KV target authority.
targetWorkerAuthorizationIds :: [TargetSecretId]
targetWorkerAuthorizationIds =
  targetWorkerTargetIds
    <> [TargetPublicEdgeTls, TargetFederationCustody]

-- Gateway is a client of Lifecycle Authority observation/submission routes but
-- owns no authenticated server route, so it receives no replay-object access
-- and no inbound-caller public-key reads.
serviceControlPlaneClientPolicy :: RuntimeRole -> Text
serviceControlPlaneClientPolicy role =
  externalControlPlaneAuthenticationPolicy (CallerService role)

readOnlyKvPolicy :: Text -> Text
readOnlyKvPolicy path =
  Text.unlines
    [ "path \"" <> path <> "\" {"
    , "  capabilities = [\"read\"]"
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
