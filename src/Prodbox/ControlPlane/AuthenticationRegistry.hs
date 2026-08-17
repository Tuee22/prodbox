{-# LANGUAGE OverloadedStrings #-}

-- | Closed production inventory for control-plane signing keys and route
-- callers.  Charts, Vault policy reconciliation, listener trust resolution,
-- and client construction all project from this table; none carries a raw
-- public/private key or an independently maintained caller list.
module Prodbox.ControlPlane.AuthenticationRegistry
  ( ControlPlaneSigningKeyRef
  , controlPlaneSigningKeyRefFor
  , controlPlaneSigningKeyName
  , controlPlaneSigningKeyPrincipal
  , controlPlaneSigningKeyInventory
  , controlPlaneSigningKeyRefFromName
  , controlPlaneRouteCallerTopology
  , trustedCallersForRoute
  , trustedCallersForRole
  , callerMayCallRoute
  , localServiceCaller
  , operatorControlPlaneVaultRole
  , harnessControlPlaneVaultRole
  , externalMaterialIngressVaultRole
  , externalMaterialIngressAuditorVaultRole
  , credentialProvisionerVaultRole
  , credentialProvisionerAuditorVaultRole
  , credentialProvisionerCompletionVaultRole
  , adminActionRunnerVaultRole
  , adminActionRunnerAuditorVaultRole
  , adminActionRunnerCompletionVaultRole
  , targetSecretWorkerVaultRole
  , targetSecretWorkerAuditorVaultRole
  , targetSecretControllerAuditorVaultRole
  , bootstrapCoreExternalControlPlaneCallerServiceAccount
  , gatewayExternalControlPlaneCallerServiceAccounts
  , externalControlPlaneCallerServiceAccounts
  )
where

import Data.List (find)
import Data.Text (Text)
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (..)
  , allCallerPrincipals
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (..)
  , allControlPlaneRoutes
  , controlPlaneRouteRole
  )
import Prodbox.Runtime.Role (RuntimeRole (..))

data ControlPlaneSigningKeyRef = ControlPlaneSigningKeyRef
  { controlPlaneSigningKeyPrincipal :: !CallerPrincipal
  , controlPlaneSigningKeyName :: !Text
  }
  deriving (Eq, Ord, Show)

controlPlaneSigningKeyRefFor :: CallerPrincipal -> ControlPlaneSigningKeyRef
controlPlaneSigningKeyRefFor principal =
  ControlPlaneSigningKeyRef
    { controlPlaneSigningKeyPrincipal = principal
    , controlPlaneSigningKeyName =
        "prodbox-control-plane-" <> keySuffix principal
    }
 where
  keySuffix value = case value of
    CallerService role -> case role of
      BootstrapBroker -> "service-bootstrap-broker"
      GatewayRuntime -> "service-gateway-runtime"
      LifecycleAuthorityRuntime -> "service-lifecycle-authority"
      ProviderWorkerRuntime -> "service-provider-worker"
      AuthorityBackupRuntime -> "service-authority-backup"
      TlsRetentionRuntime -> "service-tls-retention"
      TargetSecretAgentRuntime -> "service-target-secret-agent"
    CallerOperatorCli -> "operator-cli"
    CallerTestHarness -> "test-harness"
    CallerAdminActionRunner -> "admin-action-runner"
    CallerCredentialProvisioner -> "credential-provisioner"

controlPlaneSigningKeyInventory :: [ControlPlaneSigningKeyRef]
controlPlaneSigningKeyInventory = fmap controlPlaneSigningKeyRefFor allCallerPrincipals

controlPlaneSigningKeyRefFromName :: Text -> Maybe ControlPlaneSigningKeyRef
controlPlaneSigningKeyRefFromName name =
  find ((== name) . controlPlaneSigningKeyName) controlPlaneSigningKeyInventory

localServiceCaller :: RuntimeRole -> CallerPrincipal
localServiceCaller = CallerService

operatorControlPlaneVaultRole :: Text
operatorControlPlaneVaultRole = "prodbox-control-plane-operator"

harnessControlPlaneVaultRole :: Text
harnessControlPlaneVaultRole = "prodbox-control-plane-test-harness"

externalMaterialIngressVaultRole :: Text
externalMaterialIngressVaultRole = "prodbox-external-material-ingress"

externalMaterialIngressAuditorVaultRole :: Text
externalMaterialIngressAuditorVaultRole =
  "prodbox-external-material-ingress-auditor"

credentialProvisionerVaultRole :: Text
credentialProvisionerVaultRole = "prodbox-credential-provisioner"

credentialProvisionerAuditorVaultRole :: Text
credentialProvisionerAuditorVaultRole =
  "prodbox-credential-provisioner-auditor"

-- | Accessor-free batch identity used only after the AWS-admin worker service
-- session has been proven absent. It signs the terminal Authority receipt and
-- has no IAM, execution-journal, Target, or token-administration capability.
credentialProvisionerCompletionVaultRole :: Text
credentialProvisionerCompletionVaultRole =
  "prodbox-credential-provisioner-completion-reporter"

adminActionRunnerVaultRole :: Text
adminActionRunnerVaultRole = "prodbox-admin-action-runner"

adminActionRunnerAuditorVaultRole :: Text
adminActionRunnerAuditorVaultRole = "prodbox-admin-action-session-auditor"

-- | Accessor-free batch identity acquired only after the Runner has proved its
-- service session absent.  It can authenticate the terminal receipt handoff
-- but has no worker, token-administration, or retained-journal capability.
adminActionRunnerCompletionVaultRole :: Text
adminActionRunnerCompletionVaultRole = "prodbox-admin-action-completion-reporter"

-- | Ephemeral Kubernetes-auth role used only by attested Target materializer
-- Jobs.  It is intentionally absent from 'VaultRoleId': no standing runtime
-- may acquire this data-CAS/HMAC capability.
targetSecretWorkerVaultRole :: Text
targetSecretWorkerVaultRole = "prodbox-target-secret-worker"

-- | Narrow post-worker accessor observer.  It can inspect one server-issued
-- accessor and revoke only itself; it has no Target data or Transit authority.
targetSecretWorkerAuditorVaultRole :: Text
targetSecretWorkerAuditorVaultRole = "prodbox-target-secret-worker-auditor"

-- | Accessor-free batch identity used by the standing Target Agent only while
-- coordinating an attested worker. It owns the worker session journal and
-- accessor-audit surface, but no Target data or Transit capability.
targetSecretControllerAuditorVaultRole :: Text
targetSecretControllerAuditorVaultRole =
  "prodbox-target-secret-controller-auditor"

-- | The operator cleanup caller is part of bootstrap core.  Its
-- ServiceAccount and exact self-TokenRequest RBAC therefore survive deletion
-- of Gateway and every application namespace.
bootstrapCoreExternalControlPlaneCallerServiceAccount :: Text
bootstrapCoreExternalControlPlaneCallerServiceAccount =
  operatorControlPlaneVaultRole

-- | The test harness remains a Gateway-lifetime test fixture.  It is not a
-- cleanup authority and is deliberately absent from the ordinary teardown
-- recovery profile.
gatewayExternalControlPlaneCallerServiceAccounts :: [Text]
gatewayExternalControlPlaneCallerServiceAccounts =
  [harnessControlPlaneVaultRole]

-- | Complete host-facing caller inventory.  Each identity is both a concrete
-- Kubernetes ServiceAccount and a Vault Kubernetes-auth role; the owning
-- charts project the lifetime-specific subsets above.
externalControlPlaneCallerServiceAccounts :: [Text]
externalControlPlaneCallerServiceAccounts =
  bootstrapCoreExternalControlPlaneCallerServiceAccount
    : gatewayExternalControlPlaneCallerServiceAccounts

-- | Exact inbound caller topology.  Operator and automation identities can
-- exercise every closed route; service-to-service grants are the minimal
-- production edges.  Keeping the operator/harness entries explicit in every
-- row means a new route cannot silently inherit either authority.
controlPlaneRouteCallerTopology :: [(ControlPlaneRoute, [CallerPrincipal])]
controlPlaneRouteCallerTopology =
  [ row LifecycleAuthorityControl []
  , row LifecycleMigrationApply []
  , row LifecycleProjectionImport []
  , row LifecycleAuthorityObserve standingConsumers
  , row LifecycleAuthorityBackupExport []
  , row LifecycleAuthorityDecommissionExport []
  , row LifecycleAuthorityDecommissionStop []
  , row LifecycleRetainedSesLease []
  , row LifecycleOperationSubmit standingConsumers
  , row LifecycleOperationObserve standingConsumers
  , row LifecycleConfigObserve configConsumers
  , row LifecycleConfigProposeCas []
  , row LifecycleExternalMaterialIngress []
  , row LifecycleFederationRegister [bootstrapBroker]
  , row LifecycleAdminAction []
  ,
    ( LifecycleAwsAdminProvisioner
    , [CallerOperatorCli, CallerTestHarness, CallerCredentialProvisioner]
    )
  , (LifecycleAdminActionExecution, [CallerAdminActionRunner])
  , row LifecycleProviderDispatch []
  , (ProviderWorkApply, [authority])
  , (ProviderWorkObserve, [authority])
  , row AuthorityBackupCopy [authority]
  , row AuthorityBackupObserve [authority]
  , row TlsRetentionStore [authority, targetAgent]
  , row TlsRetentionRestore [authority, targetAgent]
  , row TargetMaterialObserve [authority, CallerCredentialProvisioner]
  , row TargetSecretDecommissionInventory [authority]
  , row TargetSecretDecommissionTombstone [authority]
  , row TargetSecretDecommissionCustodyTombstone [authority]
  , (TargetSecretAdminActionGenerationTombstone, [CallerAdminActionRunner])
  , (TargetSecretAdminActionCustodyTombstone, [CallerAdminActionRunner])
  , (TargetChildCustodyCommit, [authority])
  , (TargetChildRecoveryPrepare, [bootstrapBroker])
  , (TargetChildRecoveryObserve, [bootstrapBroker])
  , (TargetTlsPrepareExchange, [authority])
  , (TargetTlsRetain, [authority])
  , (TargetTlsHomeWrap, [authority])
  , (TargetTlsHomeRewrap, [authority])
  , (TargetTlsRestore, [authority])
  , (TargetTlsVerifySource, [authority])
  , row LifecycleTlsRetentionObserve []
  , row LifecycleTlsRetentionPromote []
  , row LifecyclePulumiCheckpoint [providerWorker]
  , (LifecycleBootstrapHandoffAccept, [bootstrapBroker])
  , (LifecycleBootstrapHandoffObserve, [bootstrapBroker])
  , row
      LifecycleTargetIntentIssue
      [authority, targetAgent, CallerCredentialProvisioner]
  , (TargetSecretTrustInstall, [authority])
  , row LifecycleRetainedMaterialDelivery [CallerCredentialProvisioner]
  , (TargetRetainedMaterialRewrap, [authority])
  , row LifecycleCleanupRun [authority]
  , row LifecycleEksDrainIntent [authority]
  , row LifecycleEksDrainReadBackReceipt [authority]
  , row LifecycleAwsStackReader [authority]
  , row LifecycleAwsStackCreationBinding [authority]
  , row LifecycleOwnershipManifest [authority]
  , row LifecycleRecoveryPlane [authority]
  , (LifecycleLocalRke2HostObservation, [CallerOperatorCli])
  ]
 where
  row route services = (route, [CallerOperatorCli, CallerTestHarness] <> services)
  authority = CallerService LifecycleAuthorityRuntime
  providerWorker = CallerService ProviderWorkerRuntime
  targetAgent = CallerService TargetSecretAgentRuntime
  bootstrapBroker = CallerService BootstrapBroker
  standingConsumers =
    [ CallerService GatewayRuntime
    , providerWorker
    , CallerService AuthorityBackupRuntime
    , CallerService TlsRetentionRuntime
    , targetAgent
    ]
  configConsumers =
    [ CallerService BootstrapBroker
    , CallerService GatewayRuntime
    , authority
    , providerWorker
    , CallerService AuthorityBackupRuntime
    , CallerService TlsRetentionRuntime
    , targetAgent
    ]

trustedCallersForRoute :: ControlPlaneRoute -> [CallerPrincipal]
trustedCallersForRoute route =
  case lookup route controlPlaneRouteCallerTopology of
    Just callers -> callers
    Nothing -> error ("missing closed control-plane route topology for " <> show route)

trustedCallersForRole :: RuntimeRole -> [CallerPrincipal]
trustedCallersForRole role =
  distinct
    [ caller
    | route <- allControlPlaneRoutes
    , controlPlaneRouteRole route == role
    , caller <- trustedCallersForRoute route
    ]
 where
  distinct = foldl appendIfMissing []
  appendIfMissing accumulated caller
    | caller `elem` accumulated = accumulated
    | otherwise = accumulated <> [caller]

callerMayCallRoute :: CallerPrincipal -> ControlPlaneRoute -> Bool
callerMayCallRoute caller = elem caller . trustedCallersForRoute
