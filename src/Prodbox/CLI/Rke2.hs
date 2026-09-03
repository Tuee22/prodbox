{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Rke2
  ( acmeRuntimeManifestWith
  , ensureAcmeRuntimeForSubstrate
  , acmeClusterIssuerSpec
  , awaitAcmeMaterialization
  , ensureRuntimeImageForSubstrate
  , ensureGatewayMinioBootstrap
  , ensureInternalControlPlaneChartReady
  , ensureAdminPublicEdgeRoutes
  , ensureGatewayChartReady
  , ensureGatewayChartReadyPostVaultAt
  , adminPublicEdgeManifestItems
  , ensureHarborRegistryRuntime
  , ensureHarborRegistryStorageBackend
  , harborStorageBackendManifestItems
  , harborRegistryStorageWaitArguments
  , harborRegistryStorageDeleteArguments
  , ensureMinioRuntime
  , ensurePostgresOperatorRuntime
  , ensureVaultRuntime
  , ensureRootVaultLifecycle
  , bindVaultLifecycleContext
  , externalMaterialRequestForObservation
  , reconcileAcmeEabFixture
  , MinioImageSource (..)
  , RetainedStorageInventoryEntry (..)
  , CascadePhaseOutcome (..)
  , independentPhase
  , derivedPhase
  , renderFailedCascadePhases
  , DeleteMode (..)
  , CascadeSubstrateDecision (..)
  , aggregateCascadeExit
  , cascadeOrderNarration
  , inferCascadeSubstrate
  , cascadeSweepCredentialAbsentExit
  , retainedStateNoticePerRunLine
  , isMinioSecretKeyArgumentSafe
  , OperationalAwsCredentialGate (..)
  , buildNativeDeletePlan
  , buildNativeInstallExecutionPlan
  , NativeInstallPayload (..)
  , nativeHarnessBootstrapFloorStepOrder
  , ReconcileStepAnchor (..)
  , ReconcileStepId (..)
  , nativeInstallStepOrder
  , nativeComponentReadinessTarget
  , authorityBackupReadinessChecks
  , componentReadinessRetryPolicyFor
  , renderNativeDeletePlan
  , renderNativeInstallPlan
  , nativeInstallStepOrderRespectsGraph
  , stepsForComponent
  , isRetryableHelmFailure
  , isRetryableHarborPublicationFailure
  , RedirectPolicy (..)
  , RegistryStorageBackend (..)
  , RegistryStorageEdgeReadiness (..)
  , classifyRegistryStorageEdgeProbe
  , GatewayFullModeProbe (..)
  , KubernetesReadinessCheck (..)
  , classifyKubernetesReadiness
  , classifyGatewayFullModeProbe
  , gatewayDaemonWorkloadRefs
  , gatewayNamespace
  , minioNamespace
  , minioReleaseName
  , vaultNamespace
  , ensureRegistryStorageBackendEdgeReady
  , observeGatewayBackendRoundTripOnce
  , observeGatewayBackendRoundTripOnceAt
  , observeGatewayReadyzOnceAt
  , observeKubernetesReadinessOnce
  , observeRegistryBackendRoundTripOnce
  , RegistryStorageEdgeObservation (..)
  , parseRegistryStorageEdgeResponse
  , observeVaultUnsealedOnce
  , classifyBrokerVaultUnsealedStatus
  , renderInotifySysctlDropIn
  , renderResourceVectorRuntime
  , renderRke2ResourceGuardrailConfig
  , renderRke2SystemdResourceDropIn
  , Rke2ImageImportDecision (..)
  , decideRke2ImageImport
  , RuntimeImageRetentionObservationError (..)
  , managedRuntimeImageRetentionInventoryArguments
  , selectManagedDanglingRuntimeImageIds
  , renderMinioChartArgs
  , retainedStorageInventoryEntries
  , harborRegistryStorageBackend
  , registryConfigYaml
  , rke2InstallPresent
  , Rke2InstallPresence (..)
  , DeleteTerminalArm (..)
  , selectDeleteEntryArm
  , deleteArmIsNoInstallSuccess
  , RetainedStateNarration (..)
  , retainedStateNarrationFor
  , operationalAwsCredentialGateFromResult
  , runAnchoredReconcileSteps
  , runEdgeCommand
  , runNativeHarnessBootstrapFloor
  , reconcileHarnessLifecycleProviderCredential
  , runNativeDeleteCascade
  , runCascadeDrainResult
  , runRke2Command
  , homeSubstratePlatformComponents
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , displayException
  , onException
  , try
  )
import Control.Monad (foldM)
import Data.Aeson
  ( Value
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char
  ( isAsciiLower
  , isAsciiUpper
  , isDigit
  , isHexDigit
  , isSpace
  , toLower
  )
import Data.Either (fromLeft)
import Data.List
  ( intercalate
  , isInfixOf
  , isPrefixOf
  , nub
  )
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Data.Word (Word8)
import Numeric.Natural (Natural)
import Prodbox.Aws (adminAwsEnvironment)
import Prodbox.Aws.CredentialHandle (baseCredentialHandleFromSettings)
import Prodbox.Aws.Native.Sts qualified as NativeSts
import Prodbox.Aws.Native.Wire (httpSend)
import Prodbox.CLI.Command
  ( EdgeCommand (..)
  , FederationRegisterOptions (..)
  , Plan (..)
  , PlanOptions (..)
  , Rke2Command (..)
  , Rke2DeleteFlags (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Output
  ( writeDiagnostic
  , writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.CLI.Vault
  ( BrokerVaultSealStatus (..)
  , gatewayEndpointFromEnv
  , observeBrokerVaultSealStatus
  , runPostUnsealHandoffViaBroker
  , runVaultBootstrapViaBroker
  )
import Prodbox.Capacity.Allocation qualified as CapacityAllocation
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.HostProbe (observeHostCapacity)
import Prodbox.Capacity.ObservedHost qualified as ObservedHost
import Prodbox.Capacity.Placement qualified as Placement
import Prodbox.Capacity.Render qualified as CapacityRender
import Prodbox.Cluster.Federation
  ( ChildBootstrapCredential (..)
  , ChildIndex (..)
  , ChildMetadata (..)
  , ChildRegistrationPlan (..)
  , childBootstrapKvLogicalPath
  , childBootstrapVaultFields
  , childIndexVaultFields
  , childMetadataKvLogicalPath
  , childMetadataVaultFields
  , childRegistrationPlan
  , childRegistrationTransitKey
  , childRegistrationVaultNamespace
  , childTransitSealPolicyDocument
  , decodeChildIndex
  , decodePayloadJsonField
  , federationChildrenIndexKvLogicalPath
  , renderChildRegistrationPlan
  , upsertChildIndex
  )
import Prodbox.Config.Basics
  ( ParentRef (..)
  , UnencryptedBasics (basicsClusterId)
  )
import Prodbox.Config.ComponentGraph
  ( ComponentDag
  , ComponentId (..)
  , ComponentNode (..)
  , chartNameForComponent
  , componentCapabilityRequirement
  , componentIdText
  , componentReconcileOrder
  , lookupComponentNode
  )
import Prodbox.Config.LocalRetainedRoot
  ( reconcileAuthorityBoundRetainedRootMarker
  , renderLocalRetainedRootError
  , renderRetainedRootMarkerReconcileOutcome
  )
import Prodbox.Config.Tier0
  ( ensureBasicsFloor
  )
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.ControlPlane.AuthorityBackupClient
  ( authorityAggregateBackupClientWithTransport
  )
import Prodbox.ControlPlane.AuthorityBackupExportClient
  ( authorityBackupExportClient
  )
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( GenesisAwsAdminIntentParameters (..)
  , compileNormalAwsAdminIntentForScope
  , normalAwsAdminOperationIdForScope
  , productionAuthorityBackupReconcileBoundary
  , reconcileRemainingFirstReconcileCredentials
  )
import Prodbox.ControlPlane.AuthorityControlClient
  ( authorityControlClientWithTransport
  )
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminProvisionerClient
  , AwsAdminProvisionerClientError (AwsAdminProvisionerClientRefused)
  , awsAdminProvisionerClient
  , observeAwsAdminProvisioning
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminProvisionerChallenge (awsAdminChallengeCanonicalIntent)
  , AwsAdminProvisionerObservation (awsAdminObservedChallenge)
  )
import Prodbox.ControlPlane.CapabilityRequirement (requirementCoordinate')
import Prodbox.ControlPlane.Coordinate (coordGeneration)
import Prodbox.ControlPlane.ExternalMaterialIngressClient
  ( externalMaterialIngressClient
  , observeCurrentExternalMaterialIngress
  )
import Prodbox.ControlPlane.ExternalMaterialIngressEndpoint
  ( ExternalMaterialIngressAction (ExternalMaterialInstall, ExternalMaterialRotate)
  , ExternalMaterialIngressChallenge (..)
  , ExternalMaterialIngressObservation (..)
  )
import Prodbox.ControlPlane.ExternalMaterialIngressWorkflow
  ( ExternalMaterialIngressWorkflowRequest (..)
  , kubernetesExternalMaterialJobBoundary
  , runExternalMaterialIngressWorkflowWithDelivery
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator, LifecycleAuthorityTestHarness)
  , externalCallerKubernetesSubject
  , renderLifecycleAuthorityAuthenticationError
  , withAuthorityBackupAuthenticatedTransport
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  , withLifecycleAuthorityRetainedDeliveryAuthenticatedTransport
  , withTargetSecretAgentAuthenticatedTransport
  )
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchHostProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryClient
  ( retainedMaterialDeliveryClient
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( observeRegisteredTargetMaterial
  , targetMaterialClient
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( TargetMaterialObservation (targetMaterialObservedGeneration)
  )
import Prodbox.ControlPlane.TargetMaterialFixture
  ( seedAcmeEabFromTestSecrets
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.DockerConfig (withEphemeralDockerConfig)
import Prodbox.Error (fatalError)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.Types (PeerEndpoint)
import Prodbox.Host
  ( LanAddressing (..)
  , defaultGatewayNodePort
  , detectLanAddressing
  , runHostFirewallGatewayRestrictOptional
  , runHostFirewallGatewayUnrestrict
  )
import Prodbox.Http.Client
  ( HttpError (..)
  , renderHttpError
  )
import Prodbox.Infra.AwsEksTestStack (awsEksCanonicalClusterName, withEksKubeconfig)
import Prodbox.Infra.LongLivedPulumiBackend (loadAdminAwsCredentials)
import Prodbox.Lib.ChartPlatform
  ( ChartDeploymentPlan (..)
  , ChartReleasePlan (..)
  , ResolvedCustomImage (..)
  , buildChartDeploymentPlanForSubstrate
  , deployChartPlan
  , gatewayNodeIdsForSubstrate
  , keycloakRealmName
  , keycloakVscodeClientId
  , operatorAvailableTarget
  , readKubernetesApiEgressCoordinate
  , resolveChartSecrets
  , resolveRuntimeChartImageForSubstrate
  , resolvedCustomImageTargetAgentIdentity
  )
import Prodbox.Lib.EksCustomImagePush
  ( EksCustomImagePushConfig (..)
  , defaultEksCustomImagePushConfig
  , eksCustomImagePushPodManifest
  , rewriteChartRefForInClusterPush
  )
import Prodbox.Lib.Storage
  ( retainedStatefulSetPersistentVolumeClaimName
  , retainedStatefulSetPersistentVolumeName
  , workloadStorageSize
  )
import Prodbox.Lifecycle.AnchoredReconcile
  ( AnchoredOrderSpec (..)
  , ReconcilePhase (..)
  , ReconcileStepAnchor (..)
  , anchoredOrderRespectsGraph
  , compileAnchoredOrder
  , runAnchoredStepOrder
  , runFirstAnchoredStepOrder
  )
import Prodbox.Lifecycle.Authority.BootstrapReconcile
  ( AuthorityBackupReconcileOutcome (..)
  , reconcileAuthorityBackupAdmission
  )
import Prodbox.Lifecycle.CapabilityReadinessBarrier
  ( newReadinessObservationClient
  , observeReadinessThroughCapability
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminCoordinator
  ( AwsAdminKubernetesBoundary
  , coordinateAwsAdminProvisioning
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminKubernetes
  ( oneShotAwsAdminJobResources
  , productionAwsAdminKubernetesBoundary
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitIntent
  , CredentialIamParameters
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentGeneration
  , decodeAwsAdminPermitIntent
  , mkAuthorityBackupIamParameters
  , mkGatewayDnsIamParameters
  , mkHomeDns01IamParameters
  , mkLifecycleProviderIamParameters
  , mkTlsRetentionIamParameters
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialIngressPhase
      ( ExternalMaterialIngressIntentCommitted
      , ExternalMaterialIngressPermitCommitted
      , ExternalMaterialIngressReceiptCommitted
      )
  )
import Prodbox.Lifecycle.CredentialProvisioner.KubernetesJob
  ( CredentialProvisionerJobConnection (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , OperatorMaterialAction (InstallOperatorMaterial, RevokeOperatorMaterial, RotateOperatorMaterial)
  )
import Prodbox.Lifecycle.CredentialProvisioner.Substrate
  ( productionCredentialProvisionerSubstrateBoundary
  , reconcileCredentialProvisionerSubstrate
  )
import Prodbox.Lifecycle.DependencyAdmission
  ( AdmissionRefusal
  , AdmissionSet
  , DependencyAdmission
  , mutationAdmittedComponent
  , recordAdmission
  , renderAdmissionRefusal
  )
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.FederatedVault
  ( FederatedVaultLifecycle (..)
  , ParentVaultReadiness (..)
  , parentReadinessDecision
  , renderParentReadinessBlock
  , vaultLifecycleFromBasics
  , vaultLifecycleHelmSealArgs
  )
import Prodbox.Lifecycle.K8sDrain qualified as K8sDrain
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros)
import Prodbox.Lifecycle.LiveResidue
  ( PerRunResidueStatuses (..)
  , queryPerRunResidueStatuses
  )
import Prodbox.Lifecycle.Preconditions
  ( StructuredError (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderReadiness)
  , ProviderReadinessProbe (ProviderReadinessStsIdentity)
  )
import Prodbox.Lifecycle.ReadinessObservation
  ( BackendRoundTripResult (..)
  , ComponentReadinessTarget (..)
  , ReadinessProbeResult (..)
  , componentReadinessRetryPolicy
  )
import Prodbox.Lifecycle.RegistryBackendWitness (registryBackendWitness)
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.ResourceRegistry qualified as ResourceRegistry
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Lifecycle.TargetCommitIntent (credentialGenerationValue)
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneFinalDisposition (RecoveryPlaneNotEstablished)
  )
import Prodbox.Minio.ObjectStoreTypes
  ( defaultObjectStoreBucket
  , minioClusterServiceEndpoint
  , minioClusterServiceNamespace
  , minioSigningRegion
  )
import Prodbox.Minio.RootCredential (minioRootPassword, minioRootUser)
import Prodbox.PostgresPlatform
  ( patroniOperatorDeploymentName
  , patroniOperatorNamespace
  , patroniOperatorReleaseName
  , patroniPostgresqlCrdName
  )
import Prodbox.PublicEdge
  ( PublicEdgeRoute (..)
  , authPathPrefix
  , minioPathPrefix
  , publicEdgeClusterIssuerName
  , publicEdgeTlsRetentionKey
  , requireSubstrateCertScopeSet
  , requireSubstrateServedHost
  , resolveSubstrateHostedZoneId
  , servedHostString
  , substrateIdentityIssuerUrl
  , substratePublicRouteUrl
  )
import Prodbox.Result (Result (..))
import Prodbox.Retry
  ( RetryPolicy
  , customImagePushRetryPolicy
  , deploymentRevisionObservationRetryPolicy
  , drawRetryDelayMicros
  , helmTransientRetryPolicy
  , retryPolicyMaxAttempts
  )
import Prodbox.Service (isRetryableTransientFailure)
import Prodbox.Settings
  ( AcmeAccount (..)
  , AcmeSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , MetallbBgpPeer (..)
  , PublicEdgeAdvertisementMode (..)
  , PulumiStateBackendSection (..)
  , ValidatedCoordinates (..)
  , ValidatedDeploymentContext
  , ValidatedServedHost (..)
  , ValidatedSettings (..)
  , acme
  , defaultConfigFile
  , deploymentClusterId
  , deploymentVaultAddress
  , eab_hmac_key
  , eab_key_id
  , loadConfigFile
  , loadUnencryptedBasics
  , manual_pv_host_root
  , pulumi_state_backend
  , reconcileInForceConfigFromFile
  , region
  , renderPublicEdgeAdvertisementMode
  , renderSeedInForceOutcome
  , requireAcmeAccount
  , requireOperationalAwsRegion
  , storage
  , validateAndLoadBootstrapSettings
  , validateAndLoadSettings
  , validateOperationalAwsCredentials
  , validatedConfig
  , validatedCoordinates
  , validatedDeploymentContext
  , validatedResourcePlan
  )
import Prodbox.Settings.Coordinate
  ( AwsRegion
  , acmeDirectoryUrlText
  , awsRegionText
  , emailAddressText
  , route53ZoneIdText
  , s3BucketNameText
  )
import Prodbox.Settings.SecretRef
  ( SecretRef (..)
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import Prodbox.Substrate (Substrate (..), replicasForSubstrate, substrateId)
import Prodbox.Vault.Client
  ( KvV2Cas (KvV2Cas)
  , VaultAddress (..)
  , VaultCasOutcome (..)
  , VaultToken (..)
  , classifyVaultCasOutcome
  , kvV2VersionedSecretData
  , kvV2VersionedSecretVersion
  , renderVaultCasOutcome
  , vaultCreateToken
  , vaultCreateTransitKey
  , vaultKvCasWriteV2
  , vaultKvReadV2
  , vaultKvReadVersionedV2
  , vaultReadTransitKey
  , vaultSealStatus
  , vaultWritePolicy
  )
import Prodbox.Vault.Host (vaultAddressForDeploymentContext)
import Prodbox.Vault.Status (probeVaultStatusLine)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getHomeDirectory
  , getTemporaryDirectory
  , listDirectory
  , makeAbsolute
  , removeFile
  )
import System.Environment (getEnvironment, lookupEnv)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )
import System.FilePath
  ( takeDirectory
  , (</>)
  )
import System.IO
  ( IOMode (ReadMode)
  , hClose
  , openBinaryFile
  , openTempFile
  )
import System.Info (os)
import System.Info qualified as SystemInfo
import Text.Printf (printf)
import Text.Read (readMaybe)

rke2BinaryPath :: FilePath
rke2BinaryPath = "/usr/local/bin/rke2"

rke2ConfigPath :: FilePath
rke2ConfigPath = "/etc/rancher/rke2/config.yaml"

rke2ResourceGuardrailConfigPath :: FilePath
rke2ResourceGuardrailConfigPath = "/etc/rancher/rke2/config.yaml.d/90-prodbox-resource-guardrails.yaml"

rke2KubeconfigPath :: FilePath
rke2KubeconfigPath = "/etc/rancher/rke2/rke2.yaml"

rke2RegistriesPath :: FilePath
rke2RegistriesPath = "/etc/rancher/rke2/registries.yaml"

-- | Persisted sysctl drop-in that raises the inotify limits so the systemd
-- manager (PID 1), containerd, and kubelet do not exhaust the per-user
-- inotify-instance cap during RKE2 lifecycle operations. Written by
-- 'ensureHostInotifyLimits' as the first reconcile/delete host-prep step.
--
-- The @99-@ prefix is load-bearing: @sysctl --system@ (and systemd-sysctl at
-- boot) applies drop-ins in lexicographic filename order with last-wins
-- precedence, and @/usr/lib/sysctl.d/30-tracker.conf@ pins
-- @fs.inotify.max_user_watches = 65536@. A @30-@ prefix would sort before
-- @30-tracker.conf@ and lose; @99-@ sorts after it and wins.
inotifyDropInPath :: FilePath
inotifyDropInPath = "/etc/sysctl.d/99-prodbox-inotify.conf"

rke2UninstallPath :: FilePath
rke2UninstallPath = "/usr/local/bin/rke2-uninstall.sh"

rke2ServiceName :: String
rke2ServiceName = "rke2-server.service"

rke2SystemdResourceDropInPath :: FilePath
rke2SystemdResourceDropInPath = "/etc/systemd/system/rke2-server.service.d/90-prodbox-resource-guardrails.conf"

-- | On-disk markers that indicate an RKE2 install is present on this host.
-- @rke2 delete@ short-circuits to a no-op success only when ALL of these are
-- absent. Deliberately keyed off install state, not service state: an
-- installed-but-stopped RKE2 still has a cluster and per-run state on disk to
-- delete, so it must still flow through the per-run residue gate rather than be
-- treated as "nothing to delete".
rke2InstallMarkers :: [FilePath]
rke2InstallMarkers =
  [ rke2BinaryPath
  , rke2UninstallPath
  , "/var/lib/rancher/rke2"
  , takeDirectory rke2ConfigPath
  ]

-- | Operator-facing line emitted when @rke2 delete@ finds no RKE2 install.
noRke2ClusterMessage :: String
noRke2ClusterMessage = "No RKE2 cluster to delete."

-- | True when an RKE2 install is present on this host. Honors the
-- @PRODBOX_TEST_RKE2_PRESENT@ test seam (mirroring the @PRODBOX_TEST_RESIDUE_*@
-- hooks used by "Prodbox.Lifecycle.LiveResidue") so the suite stays
-- host-independent: @"1"@ forces present, @"0"@ forces absent, unset probes the
-- real filesystem markers.
rke2InstallPresent :: IO Bool
rke2InstallPresent = do
  override <- lookupEnv "PRODBOX_TEST_RKE2_PRESENT"
  case override of
    Just "1" -> pure True
    Just "0" -> pure False
    _ -> or <$> mapM markerExists rke2InstallMarkers
 where
  markerExists path = (||) <$> doesFileExist path <*> doesDirectoryExist path

prodboxNamespace :: String
prodboxNamespace = "prodbox"

vaultNamespace :: String
vaultNamespace = "vault"

vaultTransitSealTokenSecretName :: String
vaultTransitSealTokenSecretName = "vault-transit-seal-token"

prodboxIdentityConfigMap :: String
prodboxIdentityConfigMap = "prodbox-identity"

prodboxAnnotationKey :: String
prodboxAnnotationKey = "prodbox.io/id"

prodboxLabelKey :: String
prodboxLabelKey = "prodbox.io/id"

manualStorageClass :: String
manualStorageClass = "manual"

harborNamespace :: String
harborNamespace = "harbor"

-- | The in-cluster OCI registry image: the single-binary, natively multi-arch
-- CNCF @distribution@ registry. It ships one multi-arch manifest, so the same
-- image runs on every substrate (amd64 + arm64) with no per-component override.
-- The pod pulls this from Docker Hub itself on first schedule (a pre-registry
-- bootstrap public pull, alongside MinIO).
registryImage :: String
registryImage = "registry:2"

-- | Kubernetes resource names for the single-binary registry (Deployment +
-- ConfigMap; the front-door Service keeps 'harborServiceName' so the EKS-side
-- in-cluster DNS @harbor.harbor.svc.cluster.local@ is unchanged).
registryDeploymentName :: String
registryDeploymentName = "registry"

registryConfigMapName :: String
registryConfigMapName = "registry-config"

-- | The container port @registry:2@ listens on.
registryContainerPort :: Int
registryContainerPort = 5000

harborRegistryEndpoint :: String
harborRegistryEndpoint = ContainerImage.harborRegistryEndpoint

vaultApiReadinessAttempts :: Int
vaultApiReadinessAttempts = 60

vaultApiReadinessDelayMicroseconds :: Int
vaultApiReadinessDelayMicroseconds = 2000000

publicEdgeListenerName :: String
publicEdgeListenerName = "https"

harborServiceName :: String
harborServiceName = "harbor"

harborServicePort :: Int
harborServicePort = 80

minioNamespace :: String
minioNamespace = minioClusterServiceNamespace

minioReleaseName :: String
minioReleaseName = "minio"

minioAdminRouteName :: String
minioAdminRouteName = "minio-console"

minioAdminSecurityPolicyName :: String
minioAdminSecurityPolicyName = "minio-oidc"

minioAdminClientSecretName :: String
minioAdminClientSecretName = "minio-oidc-client"

-- | The short-lived, namespace-scoped consumer that projects the exact
-- @vscode/oidc/vscode#client_secret@ reference into the Envoy Gateway
-- SecurityPolicy Secret.  The host never observes the Secret payload.
minioAdminOidcMaterializerName :: String
minioAdminOidcMaterializerName = "minio-admin-oidc-materializer"

minioAdminOidcVaultRole :: String
minioAdminOidcVaultRole = "minio-admin-oidc"

minioConsoleServiceName :: String
minioConsoleServiceName = "minio-console"

minioConsoleServicePort :: Int
minioConsoleServicePort = 9001

harborRegistryStorageSecretName :: String
harborRegistryStorageSecretName = "harbor-registry-s3"

harborRegistryStorageBucket :: String
harborRegistryStorageBucket = "prodbox-harbor-registry"

harborStorageUserPrefix :: String
harborStorageUserPrefix = "prodbox-harbor-"

harborStoragePolicyName :: String
harborStoragePolicyName = "prodbox-harbor-registry-policy"

harborRegistryStorageBootstrapJobName :: String
harborRegistryStorageBootstrapJobName = "harbor-registry-bucket-init"

-- | Sprint 3.44: the host waiter and explicit delete are the single cleanup
-- owner for this Job.  Keeping their exact argument vectors as values makes
-- the observed name, namespace, and completion bound independently testable.
harborRegistryStorageWaitArguments :: [String]
harborRegistryStorageWaitArguments =
  [ "wait"
  , "--for=condition=complete"
  , "job/" ++ harborRegistryStorageBootstrapJobName
  , "-n"
  , minioNamespace
  , "--timeout=300s"
  ]

harborRegistryStorageDeleteArguments :: [String]
harborRegistryStorageDeleteArguments =
  [ "delete"
  , "job"
  , harborRegistryStorageBootstrapJobName
  , "-n"
  , minioNamespace
  , "--ignore-not-found=true"
  , "--wait=true"
  ]

-- | Job name plus canonical IAM principal and policy name for the
-- gateway daemon's MinIO object-store surface, provisioned in one unified pass
-- by 'ensureGatewayMinioBootstrap'.
gatewayMinioBootstrapJobName :: String
gatewayMinioBootstrapJobName = "gateway-minio-bootstrap"

-- | Namespace where the gateway chart deploys. Reconcile pre-creates it
-- before @prodbox charts reconcile gateway@ runs.
gatewayNamespace :: String
gatewayNamespace = "gateway"

gatewayBootstrapNamespaces :: [String]
gatewayBootstrapNamespaces =
  ["keycloak", "vscode"]

-- | Canonical IAM policy name granting the gateway user
-- @s3:GetObject@/@s3:PutObject@/@s3:ListBucket@ on @prodbox-state/*@.
gatewayMinioPolicyName :: String
gatewayMinioPolicyName = "prodbox-gateway-policy"

-- | Dedicated least-privilege MinIO principal used only by the retained
-- Lifecycle Authority process.  It shares the ciphertext bucket with the
-- compatibility Gateway principal but not credentials or Vault identity.
lifecycleAuthorityMinioPolicyName :: String
lifecycleAuthorityMinioPolicyName = "prodbox-lifecycle-authority-policy"

minioClusterEndpoint :: String
minioClusterEndpoint = minioClusterServiceEndpoint

metallbNamespace :: String
metallbNamespace = "metallb-system"

metallbReleaseName :: String
metallbReleaseName = "metallb"

metallbRepositoryName :: String
metallbRepositoryName = "metallb"

metallbRepositoryUrl :: String
metallbRepositoryUrl = "https://metallb.github.io/metallb"

metallbChartRef :: String
metallbChartRef = "metallb/metallb"

metallbChartVersion :: String
metallbChartVersion = "0.14.9"

envoyGatewayNamespace :: String
envoyGatewayNamespace = "envoy-gateway-system"

envoyGatewayReleaseName :: String
envoyGatewayReleaseName = "envoy-gateway"

envoyGatewayChartRef :: String
envoyGatewayChartRef = "oci://docker.io/envoyproxy/gateway-helm"

-- Sprint 7.12: the Envoy Gateway chart version is sourced from the single
-- 'ContainerImage.envoyGatewayRelease' SSoT (shared with the control-plane
-- and data-plane image pins and with the AWS-substrate installer). There is
-- no second place to set an Envoy Gateway version, so the EG-chart /
-- Envoy-data-plane skew cannot reappear.
envoyGatewayChartVersion :: String
envoyGatewayChartVersion = ContainerImage.envoyGatewayChartVersion

publicEdgeGatewayClassName :: String
publicEdgeGatewayClassName = "prodbox-public-edge"

publicEdgeEnvoyProxyName :: String
publicEdgeEnvoyProxyName = "prodbox-public-edge"

certManagerNamespace :: String
certManagerNamespace = "cert-manager"

certManagerReleaseName :: String
certManagerReleaseName = "cert-manager"

certManagerRepositoryName :: String
certManagerRepositoryName = "jetstack"

certManagerRepositoryUrl :: String
certManagerRepositoryUrl = "https://charts.jetstack.io"

certManagerChartRef :: String
certManagerChartRef = "jetstack/cert-manager"

-- Sprint 7.12: the cert-manager chart version is sourced from the single
-- 'ContainerImage.certManagerChartVersion' SSoT (shared with the
-- cert-manager image pins and with the AWS-substrate installer). cert-manager
-- is a shared platform component, so there is no per-substrate re-pin.
certManagerChartVersion :: String
certManagerChartVersion = ContainerImage.certManagerChartVersion

postgresOperatorRepositoryName :: String
postgresOperatorRepositoryName = "percona"

postgresOperatorRepositoryUrl :: String
postgresOperatorRepositoryUrl = "https://percona.github.io/percona-helm-charts/"

postgresOperatorChartRef :: String
postgresOperatorChartRef = "percona/pg-operator"

-- Sprint 7.12: the Percona PostgreSQL operator is a shared platform
-- component, so its chart version comes from the single
-- 'ContainerImage.postgresOperatorChartVersion' SSoT.
postgresOperatorChartVersion :: String
postgresOperatorChartVersion = ContainerImage.postgresOperatorChartVersion

-- | The cert-manager ACME account-key Secret name. cert-manager stores
-- the ZeroSSL ACME account registration under this @privateKeySecretRef@.
zerosslAccountKeySecretName :: String
zerosslAccountKeySecretName = "zerossl-account-key"

route53CredentialsSecretName :: String
route53CredentialsSecretName = "route53-credentials"

-- | One-shot home-only consumer that projects the exact registered
-- cert-manager DNS01 generation into the fixed Kubernetes Secret consumed by
-- the Route 53 solver.  Its memory volume is destroyed with the Job and the
-- host observes only Kubernetes object metadata.
homeDns01MaterializerName :: String
homeDns01MaterializerName = "home-dns01-secret-materializer"

awsDns01MaterializerName :: String
awsDns01MaterializerName = "aws-dns01-target-materializer"

homeDns01VaultRole :: String
homeDns01VaultRole = "aws-cert-manager-home"

homeDns01VaultPath :: String
homeDns01VaultPath = "aws/cert-manager/home/dns01"

awsDns01VaultPath :: String
awsDns01VaultPath = "aws/cert-manager/aws/dns01"

acmeEabSecretName :: String
acmeEabSecretName = "acme-eab-credentials"

acmeEabSecretKey :: String
acmeEabSecretKey = "secret"

-- | Sprint 7.15: the EAB HMAC key is materialized into the
-- 'acmeEabSecretName' Secret from Vault @secret/acme/eab@ (field
-- @hmac_key@) by a Vault-login Job in the @cert-manager@ namespace,
-- reusing the Sprint 3.18 chart-side materialization pattern (init
-- container logs into Vault via Kubernetes auth, main container creates
-- the k8s Secret and patches the issuer). Neither EAB field transits the
-- operator host.
acmeEabMaterializerName :: String
acmeEabMaterializerName = "acme-eab-secret-materializer"

-- | The Vault Kubernetes-auth role bound to 'acmeEabMaterializerName'.
-- Declared in 'Prodbox.Secret.VaultInventory.chartVaultSecretConsumers'
-- (policy @acme@, role @acme@, namespace @cert-manager@).
acmeEabVaultRole :: String
acmeEabVaultRole = "acme"

-- | The Vault KV logical path (under mount @secret@) that holds the EAB
-- material, matching the secret inventory and the config 'SecretRef.Vault'
-- defaults.
acmeEabVaultPath :: String
acmeEabVaultPath = "acme/eab"

acmeEabVaultHmacField :: String
acmeEabVaultHmacField = "hmac_key"

acmeEabVaultKeyIdField :: String
acmeEabVaultKeyIdField = "key_id"

data MinioImageSource
  = MinioBootstrapPublic
  | MinioSteadyStateHarbor
  deriving (Eq, Show)

data HostArchitecture
  = HostArchitectureAmd64
  | HostArchitectureArm64
  deriving (Eq, Show)

data CustomImageBuildPlan = CustomImageBuildPlan
  { customImageDockerfile :: FilePath
  }
  deriving (Eq, Show)

minioStorageSize :: String
minioStorageSize = "20Gi"

-- Sprint 4.31: the in-cluster Vault durable PV joins the unified
-- retained-storage reconciler at `.data/vault/vault/0`, replacing the
-- hand-applied PV from the 3.17 live bring-up. The Vault StatefulSet's `data`
-- volumeClaimTemplate adopts the prebound `data-vault-0` PVC.
vaultStorageNamespace :: String
vaultStorageNamespace = "vault"

vaultStorageSize :: String
vaultStorageSize = "1Gi"

managedNamespaces :: [String]
managedNamespaces =
  [ prodboxNamespace
  , harborNamespace
  , metallbNamespace
  , envoyGatewayNamespace
  , certManagerNamespace
  , patroniOperatorNamespace
  , "gateway"
  , "vscode"
  ]

managedHelmInstances :: [String]
managedHelmInstances =
  [ "harbor"
  , "minio"
  , "metallb"
  , envoyGatewayReleaseName
  , "cert-manager"
  , patroniOperatorReleaseName
  ]

ephemeralResourceKinds :: [String]
ephemeralResourceKinds =
  [ "events"
  , "events.events.k8s.io"
  ]

doctrineCrdSuffixes :: [String]
doctrineCrdSuffixes =
  [ ".metallb.io"
  , ".cert-manager.io"
  , ".acme.cert-manager.io"
  , ".gateway.networking.k8s.io"
  , ".gateway.envoyproxy.io"
  , ".pgv2.percona.com"
  , ".postgres-operator.crunchydata.com"
  ]

runRke2Command :: FilePath -> Rke2Command -> IO ExitCode
runRke2Command repoRoot command =
  case command of
    Rke2Status ->
      requireLinux (runClusterStatus repoRoot)
    Rke2Start ->
      requireLinux $
        runCommand
          Subprocess
            { subprocessPath = "sudo"
            , subprocessArguments = ["systemctl", "start", rke2ServiceName]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    Rke2Stop ->
      requireLinux $
        runCommand
          Subprocess
            { subprocessPath = "sudo"
            , subprocessArguments = ["systemctl", "stop", rke2ServiceName]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    Rke2Restart ->
      requireLinux $
        runCommand
          Subprocess
            { subprocessPath = "sudo"
            , subprocessArguments = ["systemctl", "restart", rke2ServiceName]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    Rke2Reconcile planOptions withEdge ->
      requireLinux (runNativeInstall repoRoot planOptions withEdge)
    Rke2Delete flags planOptions ->
      requireLinux $
        if not (rke2DeleteYes flags)
          then failWith "rke2 delete requires --yes confirmation"
          else
            -- Sprint 4.26: route the destructive teardown through the
            -- Plan / Apply entrypoint so `--dry-run` renders the full
            -- destructive plan and exits 0 WITHOUT mutating, and
            -- `--plan-file` writes the rendered plan (pure_fp_standards.md
            -- § Plan / Apply). The no-RKE2-install short-circuit, the
            -- per-run refuse-gate, and the cascade orchestration all live
            -- inside the apply closure so dry-run performs none of them.
            runPlanWithOptions
              planOptions
              (buildNativeDeletePlan repoRoot flags)
              (applyNativeDelete repoRoot)
    Rke2FederationRegister childClusterId options ->
      runClusterFederationRegister repoRoot childClusterId options
    Rke2Logs maybeLines ->
      requireLinux $
        case normalizeLogLines maybeLines of
          Left err -> failWith err
          Right linesToShow ->
            runCommand
              Subprocess
                { subprocessPath = "journalctl"
                , subprocessArguments =
                    [ "-u"
                    , rke2ServiceName
                    , "-n"
                    , show linesToShow
                    , "--no-pager"
                    ]
                , subprocessEnvironment = Nothing
                , subprocessWorkingDirectory = Just repoRoot
                }

runClusterStatus :: FilePath -> IO ExitCode
runClusterStatus repoRoot = do
  serviceResult <- captureToolOutput repoRoot "systemctl" ["is-active", rke2ServiceName]
  case serviceResult of
    Left err -> failWith err
    Right serviceOutput -> do
      writeOutputLine ("RKE2_SERVICE=" ++ serviceStatusLine serviceOutput)
      statusLines <-
        either
          (\err -> pure ["RESOURCE_PLAN=unavailable:" ++ err])
          (resourceStatusLines repoRoot defaultResourceStatusRoot)
          defaultResourceStatusPlan
      mapM_ writeOutputLine statusLines
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left err -> failWith err
        Right settings -> do
          (vaultLine, _vaultExit) <-
            probeVaultStatusLine
              (vaultAddressForDeploymentContext (validatedDeploymentContext settings))
          writeOutputLine vaultLine
          pure (processExitCode serviceOutput)
 where
  serviceStatusLine output =
    case trimWhitespace (processStdout output) of
      "" -> trimWhitespace (outputDetail output)
      status -> status
  -- Sprint 1.88: this used to fabricate a whole `ValidatedSettings` — the only
  -- production site that constructed one without running `validateConfig` — so
  -- that it could pass it to a function reading two of its four fields. Two
  -- `error` calls on a `prodbox cluster status` path went with it. The status
  -- reader now takes exactly what it reads, so there is nothing left to
  -- fabricate and the compile failure is a value this arm renders.
  defaultResourceStatusRoot = ".data"
  defaultResourceStatusPlan =
    mapLeftToString
      CapacityAllocation.renderCompileError
      (CapacityAllocation.compileResourcePlanUncertified Capacity.defaultResourcePlan)

mapLeftToString :: (err -> String) -> Either err right -> Either String right
mapLeftToString render value = case value of
  Left err -> Left (render err)
  Right result -> Right result

-- | Sprint 1.88: takes the allocated plan and the manual PV root it actually
-- reads, rather than a whole 'ValidatedSettings' of which it read two fields.
--
-- The narrowing is what lets `ValidatedSettings` have exactly one production
-- constructor: the wide signature was the entire reason
-- `prodbox cluster status` fabricated a record no validation had produced.
resourceStatusLines
  :: FilePath -> FilePath -> CapacityAllocation.SomeAllocatedPlan -> IO [String]
resourceStatusLines repoRoot manualPvHostRoot allocatedPlan = do
  observedResult <- observeHostCapacity repoRoot manualPvHostRoot
  let plan = case allocatedPlan of
        CapacityAllocation.SomeAllocatedPlan _ allocated ->
          CapacityAllocation.allocatedPlanSource allocated
      authored = Capacity.host_capacity plan
      allocatable = CapacityAllocation.planAllocatable allocatedPlan
      baseLines =
        [ "RESOURCE_HOST_AUTHORED=" ++ renderResourceVectorRuntime authored
        , "RESOURCE_RKE2_RESERVED=" ++ renderResourceVectorRuntime (Capacity.rke2_reserved plan)
        , "RESOURCE_EVICTION_FLOOR=" ++ renderResourceVectorRuntime (Capacity.eviction_floor plan)
        , "RESOURCE_CLUSTER_ALLOCATABLE=" ++ renderResourceVectorRuntime allocatable
        ]
  pure $
    case observedResult of
      Left err -> baseLines ++ ["RESOURCE_HOST_OBSERVED=unavailable:" ++ err]
      Right observed ->
        baseLines
          ++ [ "RESOURCE_HOST_OBSERVED="
                 ++ renderResourceVectorRuntime (ObservedHost.observedHostVector observed)
             , "RESOURCE_HOST_CAPACITY="
                 ++ case CapacityAllocation.compileResourcePlanAgainstObserved
                   observed
                   allocatedPlan of
                   Right _ -> "sufficient"
                   Left _ -> "insufficient"
             ]

data FederationRegisterPayload = FederationRegisterPayload
  { federationRegisterPayloadPlan :: ChildRegistrationPlan
  , federationRegisterPayloadChildVaultAddress :: Maybe String
  , federationRegisterPayloadChildKubeconfig :: Maybe FilePath
  , federationRegisterPayloadChildEndpoints :: [(String, String)]
  , federationRegisterPayloadChildKubeconfigReference :: Maybe String
  , federationRegisterPayloadChildAccountId :: Maybe String
  , federationRegisterPayloadChildPulumiStacks :: [(String, String)]
  }
  deriving (Eq, Show)

runClusterFederationRegister :: FilePath -> String -> FederationRegisterOptions -> IO ExitCode
runClusterFederationRegister repoRoot childClusterId options = do
  planResult <- buildFederationRegisterPayload repoRoot childClusterId options
  case planResult of
    Left err -> failWith err
    Right payload ->
      runPlanWithOptions
        (federationRegisterPlanOptions options)
        (buildPlan (renderChildRegistrationPlan . federationRegisterPayloadPlan) payload)
        (applyClusterFederationRegister repoRoot)

buildFederationRegisterPayload
  :: FilePath -> String -> FederationRegisterOptions -> IO (Either String FederationRegisterPayload)
buildFederationRegisterPayload repoRoot childClusterId options = do
  hmacKeyResult <-
    if dryRun (federationRegisterPlanOptions options)
      then pure (Right "prodbox-federation-preview-only")
      else loadFederationHmacKeyForRegister repoRoot
  pure $ do
    hmacKey <- hmacKeyResult
    let plan = childRegistrationPlan (TextEncoding.encodeUtf8 hmacKey) (Text.pack childClusterId)
    Right
      FederationRegisterPayload
        { federationRegisterPayloadPlan = plan
        , federationRegisterPayloadChildVaultAddress = federationRegisterChildVaultAddress options
        , federationRegisterPayloadChildKubeconfig = federationRegisterChildKubeconfig options
        , federationRegisterPayloadChildEndpoints = federationRegisterChildEndpoints options
        , federationRegisterPayloadChildKubeconfigReference =
            federationRegisterChildKubeconfigReference options
        , federationRegisterPayloadChildAccountId = federationRegisterChildAccountId options
        , federationRegisterPayloadChildPulumiStacks = federationRegisterChildPulumiStacks options
        }

applyClusterFederationRegister :: FilePath -> FederationRegisterPayload -> IO ExitCode
applyClusterFederationRegister repoRoot payload =
  case ( federationRegisterPayloadChildVaultAddress payload
       , federationRegisterPayloadChildKubeconfig payload
       ) of
    (Nothing, _) ->
      failWith "cluster federation register apply requires --child-vault-address URL"
    (_, Nothing) ->
      failWith "cluster federation register apply requires --child-kubeconfig PATH"
    (Just childVaultAddress, Just childKubeconfig) -> do
      parentResult <- loadParentFederationAuthority repoRoot
      case parentResult of
        Left err -> failWith err
        Right (parentClusterId, parentAddress, parentToken) -> do
          let plan = federationRegisterPayloadPlan payload
              childId = childRegistrationChildId plan
              transitKey = childRegistrationTransitKey plan
              policyName = childTransitSealPolicyName plan
          keyResult <- ensureParentTransitKey parentAddress parentToken transitKey
          case keyResult of
            Left err -> failWith err
            Right () -> do
              policyResult <-
                vaultWritePolicy
                  parentAddress
                  parentToken
                  policyName
                  (childTransitSealPolicyDocument transitKey)
              case policyResult of
                Left err -> failWith ("write child transit-seal Vault policy: " ++ renderHttpError err)
                Right () -> do
                  tokenResult <- vaultCreateToken parentAddress parentToken [policyName] "24h"
                  case tokenResult of
                    Left err -> failWith ("create child transit-seal Vault token: " ++ renderHttpError err)
                    Right childToken -> do
                      let metadata =
                            childMetadataFromRegisterPayload
                              parentClusterId
                              childVaultAddress
                              payload
                              plan
                          bootstrapCredential =
                            ChildBootstrapCredential
                              { childBootstrapClusterId = childId
                              , childBootstrapParentVaultAddress = unVaultAddress parentAddress
                              , childBootstrapTransitKey = transitKey
                              , childBootstrapVaultNamespace = childRegistrationVaultNamespace plan
                              , childBootstrapToken = unVaultToken childToken
                              }
                      metadataResult <-
                        writeParentChildObject
                          parentAddress
                          parentToken
                          (childMetadataKvLogicalPath childId)
                          (childMetadataVaultFields metadata)
                      case metadataResult of
                        Left err -> failWith ("write child metadata Vault KV: " ++ Text.unpack err)
                        Right () -> do
                          bootstrapResult <-
                            writeParentChildObject
                              parentAddress
                              parentToken
                              (childBootstrapKvLogicalPath childId)
                              (childBootstrapVaultFields bootstrapCredential)
                          case bootstrapResult of
                            Left err -> failWith ("write child bootstrap Vault KV: " ++ Text.unpack err)
                            Right () -> do
                              indexResult <- updateParentChildIndex parentAddress parentToken childId
                              case indexResult of
                                Left err -> failWith err
                                Right () -> do
                                  secretExit <- applyChildTransitSealSecret repoRoot childKubeconfig childToken
                                  case secretExit of
                                    ExitFailure _ -> pure secretExit
                                    ExitSuccess -> do
                                      writeOutput
                                        ( unlines
                                            [ "Cluster federation registration complete:"
                                            , "  child_cluster_id=" ++ Text.unpack childId
                                            , "  metadata_kv_path=secret/" ++ Text.unpack (childMetadataKvLogicalPath childId)
                                            , "  bootstrap_kv_path=secret/" ++ Text.unpack (childBootstrapKvLogicalPath childId)
                                            , "  children_index_kv_path=secret/" ++ Text.unpack federationChildrenIndexKvLogicalPath
                                            , "  transit_key=" ++ Text.unpack transitKey
                                            , "  child_bootstrap_secret=vault/vault-transit-seal-token"
                                            ]
                                        )
                                      pure ExitSuccess

childMetadataFromRegisterPayload
  :: Text.Text
  -> String
  -> FederationRegisterPayload
  -> ChildRegistrationPlan
  -> ChildMetadata
childMetadataFromRegisterPayload parentClusterId childVaultAddress payload plan =
  ChildMetadata
    { childMetadataClusterId = childRegistrationChildId plan
    , childMetadataVaultAddress = Text.pack childVaultAddress
    , childMetadataTransitKey = childRegistrationTransitKey plan
    , childMetadataVaultNamespace = childRegistrationVaultNamespace plan
    , childMetadataParentClusterId = parentClusterId
    , childMetadataEndpoints =
        Map.fromList
          ( map
              textPair
              (("vault", childVaultAddress) : federationRegisterPayloadChildEndpoints payload)
          )
    , childMetadataKubeconfigReference =
        Text.pack <$> federationRegisterPayloadChildKubeconfigReference payload
    , childMetadataAccountId =
        Text.pack <$> federationRegisterPayloadChildAccountId payload
    , childMetadataPulumiStacks =
        Map.fromList (map textPair (federationRegisterPayloadChildPulumiStacks payload))
    }
 where
  textPair (key, value) = (Text.pack key, Text.pack value)

-- | Sprint 4.71: the child index is a read-modify-write, and the write is now
-- conditioned on the version the read observed.
--
-- The superseded shape read the index, upserted one child, and wrote
-- unconditionally: two concurrent registrations both read the same index and
-- the second silently erased the first child. That is a lost update, not a
-- hygiene issue, and no read-back downstream would have noticed — the index
-- looks perfectly well-formed with a child missing from it.
updateParentChildIndex :: VaultAddress -> VaultToken -> Text.Text -> IO (Either String ())
updateParentChildIndex parentAddress parentToken childId = do
  readResult <-
    vaultKvReadVersionedV2
      parentAddress
      parentToken
      "secret"
      federationChildrenIndexKvLogicalPath
  case readResult of
    Left (HttpStatus 404 _) ->
      writeIndex 0 (ChildIndex [])
    Left err ->
      pure (Left ("read child federation index Vault KV: " ++ renderHttpError err))
    Right versioned ->
      case decodePayloadJsonField decodeChildIndex (kvV2VersionedSecretData versioned) of
        Left err -> pure (Left ("decode child federation index Vault KV: " ++ err))
        Right index -> writeIndex (kvV2VersionedSecretVersion versioned) index
 where
  writeIndex expectedVersion index = do
    let updatedIndex = upsertChildIndex childId index
    writeResult <-
      vaultKvCasWriteV2
        parentAddress
        parentToken
        "secret"
        federationChildrenIndexKvLogicalPath
        (KvV2Cas expectedVersion)
        (childIndexVaultFields updatedIndex)
    -- Sprint 4.74: a lost race on the child index is a different operator
    -- fact from an unreachable Vault — the first means another registration
    -- won and this one must re-read, the second means nothing is known.
    pure $ case classifyVaultCasOutcome writeResult of
      VaultCasApplied _ -> Right ()
      failed ->
        Left
          ( "write child federation index Vault KV: "
              ++ Text.unpack (renderVaultCasOutcome failed)
          )

-- | Write one parent-held child object, conditioned on the version the parent
-- observed.
--
-- Registration may legitimately re-run, so this is not create-only: what it
-- refuses is a blind overwrite of a value that changed since it was read. The
-- objects it guards are the child's metadata and its bootstrap credential, and
-- silently replacing the latter would strand the parent's custody of the
-- previous one.
writeParentChildObject
  :: VaultAddress
  -> VaultToken
  -> Text.Text
  -> Map.Map Text.Text Text.Text
  -> IO (Either Text.Text ())
writeParentChildObject parentAddress parentToken logicalPath fields = do
  observed <- vaultKvReadVersionedV2 parentAddress parentToken "secret" logicalPath
  case observed of
    Left (HttpStatus 404 _) -> write 0
    Left err -> pure (Left (Text.pack (renderHttpError err)))
    Right versioned -> write (kvV2VersionedSecretVersion versioned)
 where
  -- Sprint 4.74: this object guards the child's metadata and bootstrap
  -- credential, so "another registration won" and "Vault did not answer" must
  -- not reach the operator as one sentence.
  write expectedVersion = do
    written <-
      vaultKvCasWriteV2
        parentAddress
        parentToken
        "secret"
        logicalPath
        (KvV2Cas expectedVersion)
        fields
    pure $ case classifyVaultCasOutcome written of
      VaultCasApplied _ -> Right ()
      failed -> Left (renderVaultCasOutcome failed)

loadParentFederationAuthority
  :: FilePath -> IO (Either String (Text.Text, VaultAddress, VaultToken))
loadParentFederationAuthority _repoRoot =
  pure
    ( Left
        ( "cluster federation registration requires the Bootstrap Broker's "
            ++ "receipt-bound child-custody workflow; the reusable parent root-token "
            ++ "and direct Vault write transport has been removed"
        )
    )

loadFederationHmacKeyForRegister :: FilePath -> IO (Either String Text.Text)
loadFederationHmacKeyForRegister repoRoot = do
  parentResult <- loadParentFederationAuthority repoRoot
  case parentResult of
    Left err -> pure (Left err)
    Right (_, parentAddress, parentToken) -> do
      readResult <- vaultKvReadV2 parentAddress parentToken "secret" "federation/hmac"
      pure $ case readResult of
        Left err -> Left ("read secret/federation/hmac: " ++ renderHttpError err)
        Right fields ->
          case Map.lookup "key" fields of
            Nothing -> Left "Vault KV object secret/federation/hmac missing field `key`"
            Just value
              | Text.null (Text.strip value) -> Left "Vault KV object secret/federation/hmac field `key` is empty"
              | otherwise -> Right value

ensureParentTransitKey :: VaultAddress -> VaultToken -> Text.Text -> IO (Either String ())
ensureParentTransitKey address token keyName = do
  readResult <- vaultReadTransitKey address token keyName
  case readResult of
    Right _ -> pure (Right ())
    Left (HttpStatus 404 _) -> do
      createResult <- vaultCreateTransitKey address token keyName "aes256-gcm96"
      pure $ case createResult of
        Left err -> Left ("create child Transit key " ++ Text.unpack keyName ++ ": " ++ renderHttpError err)
        Right () -> Right ()
    Left err -> pure (Left ("read child Transit key " ++ Text.unpack keyName ++ ": " ++ renderHttpError err))

applyChildTransitSealSecret :: FilePath -> FilePath -> VaultToken -> IO ExitCode
applyChildTransitSealSecret repoRoot childKubeconfig childToken =
  withTemporaryJsonManifest "child-transit-seal-token" (childTransitSealSecretManifest childToken) $ \manifestPath -> do
    outputResult <-
      captureToolOutput
        repoRoot
        "kubectl"
        ["--kubeconfig", childKubeconfig, "apply", "-f", manifestPath]
    case outputResult of
      Left err -> failWith err
      Right output ->
        case processExitCode output of
          ExitSuccess -> pure ExitSuccess
          ExitFailure _ ->
            failWith ("failed to apply child transit-seal token Secret: " ++ outputDetail output)

childTransitSealSecretManifest :: VaultToken -> [Value]
childTransitSealSecretManifest token =
  [ object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("Namespace" :: String)
      , "metadata" .= object ["name" .= vaultNamespace]
      ]
  , object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("Secret" :: String)
      , "metadata"
          .= object
            [ "name" .= vaultTransitSealTokenSecretName
            , "namespace" .= vaultNamespace
            ]
      , "type" .= ("Opaque" :: String)
      , "stringData" .= object ["token" .= Text.unpack (unVaultToken token)]
      ]
  ]

childTransitSealPolicyName :: ChildRegistrationPlan -> Text.Text
childTransitSealPolicyName plan =
  "prodbox-child-seal-" <> childRegistrationVaultNamespace plan

runNativeInstall :: FilePath -> PlanOptions -> Bool -> IO ExitCode
runNativeInstall repoRoot planOptions withEdge = do
  settingsResult <- validateAndLoadBootstrapSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right bootstrapSettings -> do
      identityResult <- resolveMachineIdentity
      case identityResult of
        Left err -> failWith err
        Right (machineId, prodboxId) -> do
          let labelValue = prodboxIdToLabelValue prodboxId
          case buildNativeInstallExecutionPlan
            repoRoot
            bootstrapSettings
            machineId
            prodboxId
            labelValue
            withEdge of
            Left structuredError -> failWith (errorNarrative structuredError)
            Right plan ->
              runPlanWithOptions
                planOptions
                plan
                (applyNativeInstallPlan repoRoot bootstrapSettings)

-- | Internal automation bootstrap used before the test harness can refresh
-- its Lifecycle-provider credential. It executes the ordinary graph through
-- the retained Authority/config transition and stops before every steady
-- component, especially Provider Worker deep readiness. The public
-- @cluster reconcile@ path always uses the full mode below.
runNativeHarnessBootstrapFloor :: FilePath -> IO ExitCode
runNativeHarnessBootstrapFloor repoRoot = do
  settingsResult <- validateAndLoadBootstrapSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right bootstrapSettings -> do
      identityResult <- resolveMachineIdentity
      case identityResult of
        Left err -> failWith err
        Right (machineId, prodboxId) -> do
          let labelValue = prodboxIdToLabelValue prodboxId
          case buildNativeInstallExecutionPlan
            repoRoot
            bootstrapSettings
            machineId
            prodboxId
            labelValue
            False of
            Left structuredError -> failWith (errorNarrative structuredError)
            Right plan ->
              applyNativeInstallPlanWithMode
                NativeInstallHarnessBootstrapFloor
                repoRoot
                bootstrapSettings
                (planPayload plan)

-- | @prodbox edge ...@ dispatch. @edge reconcile@ is the AWS-gated,
-- edge-only reconcile (the same plan @cluster reconcile --with-edge@
-- appends, but standalone). @edge status@ is routed to the existing
-- public-edge readiness check ('HostPublicEdge') at the parser layer.
runEdgeCommand :: FilePath -> EdgeCommand -> IO ExitCode
runEdgeCommand repoRoot command =
  case command of
    EdgeReconcile planOptions ->
      requireLinux (runEdgeReconcile repoRoot planOptions)

runEdgeReconcile :: FilePath -> PlanOptions -> IO ExitCode
runEdgeReconcile repoRoot planOptions = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      identityResult <- resolveMachineIdentity
      case identityResult of
        Left err -> failWith err
        Right (_machineId, prodboxId) ->
          let labelValue = prodboxIdToLabelValue prodboxId
              plan = buildPlan (renderEdgeReconcilePlan repoRoot) (prodboxId, labelValue)
           in runPlanWithOptions
                planOptions
                plan
                ( \(resolvedProdboxId, resolvedLabelValue) -> applyPublicEdgeReconcile repoRoot settings resolvedProdboxId resolvedLabelValue
                )

renderEdgeReconcilePlan :: FilePath -> (String, String) -> String
renderEdgeReconcilePlan repoRoot (_prodboxId, _labelValue) =
  unlines
    [ "EDGE_RECONCILE_PLAN"
    , "REPO_ROOT=" ++ repoRoot
    , "STEP=require_operational_aws_credentials"
    , "STEP=ensure_public_edge_acme_runtime"
    , "STEP=reconcile_dns_bootstrap_record"
    ]

-- | Every reconcile bring-up step, in a single typed table. This is the SSoT the
-- narration and the executor both read (M1).
data ReconcileStepId
  = StepRke2ResourceGuardrails
  | StepHostInotifyLimits
  | StepManagedRuntimeImageRetention
  | StepRke2ServerInstalled
  | StepRke2IngressController
  | StepEnableRke2Service
  | StepRestartRke2Service
  | StepSyncUserKubeconfig
  | StepVerifyClusterInfo
  | StepWaitForClusterNodesReady
  | StepDeleteNonManualStorageClasses
  | StepEnsureProdboxIdentityConfigMap
  | StepEnsureHostControlDataDirectory
  | StepEnsureRetainedLocalStorage
  | StepMinioRuntimeBootstrap
  | StepVaultRuntime
  | StepHarborRegistryStorageBackend
  | StepHarborRegistryRuntime
  | StepVerifyRegistryMinioEdge
  | StepMirrorClusterImagesOnce
  | StepEnsureRuntimeImage
  | StepRke2RegistriesConfig
  | StepCertManagerRuntime
  | StepBootstrapBrokerChartReady
  | StepFederatedVaultLifecycle
  | StepTargetSecretAgentChartReady
  | StepCredentialProvisionerSubstrateReady
  | StepLifecycleAuthorityChartReady
  | StepPostUnsealHandoff
  | StepAuthorityBackupChartReady
  | StepAuthorityBackupRolloutReady
  | StepEstablishAuthorityBackup
  | StepReconcileInForceConfig
  | StepLoadInForceSettings
  | StepProviderWorkerChartReady
  | StepTlsRetentionChartReady
  | StepMetalLbRuntime
  | StepEnvoyGatewayRuntime
  | StepPostgresOperatorRuntime
  | StepGatewayMinioBootstrap
  | StepGatewayChartReady
  | StepRootChartNamespaceGuardrails
  | StepAdminPublicEdgeRoutes
  | StepReconcileManagedAnnotations
  | StepRequireOperationalAwsCredentials
  | StepPublicEdgeAcmeRuntime
  | StepReconcileDnsBootstrapRecord
  deriving (Eq, Show, Enum, Bounded)

-- | The stable @STEP=@ narration token for a step.
reconcileStepToken :: ReconcileStepId -> String
reconcileStepToken step = case step of
  StepRke2ResourceGuardrails -> "ensure_rke2_resource_guardrails"
  StepHostInotifyLimits -> "ensure_host_inotify_limits"
  StepManagedRuntimeImageRetention -> "reconcile_managed_runtime_image_retention"
  StepRke2ServerInstalled -> "ensure_rke2_server_installed"
  StepRke2IngressController -> "ensure_rke2_ingress_controller"
  StepEnableRke2Service -> "enable_rke2_service"
  StepRestartRke2Service -> "restart_rke2_service"
  StepSyncUserKubeconfig -> "sync_user_kubeconfig"
  StepVerifyClusterInfo -> "verify_cluster_info"
  StepWaitForClusterNodesReady -> "wait_for_cluster_nodes_ready"
  StepDeleteNonManualStorageClasses -> "delete_non_manual_storage_classes"
  StepEnsureProdboxIdentityConfigMap -> "ensure_prodbox_identity_config_map"
  StepEnsureHostControlDataDirectory -> "ensure_host_control_data_directory"
  StepEnsureRetainedLocalStorage -> "ensure_retained_local_storage"
  StepMinioRuntimeBootstrap -> "ensure_minio_runtime_bootstrap"
  StepVaultRuntime -> "ensure_vault_runtime"
  StepHarborRegistryStorageBackend -> "ensure_harbor_registry_storage_backend"
  StepHarborRegistryRuntime -> "ensure_harbor_registry_runtime"
  StepVerifyRegistryMinioEdge -> "verify_registry_minio_edge"
  StepMirrorClusterImagesOnce -> "mirror_cluster_images_once"
  StepEnsureRuntimeImage -> "ensure_gateway_images"
  StepRke2RegistriesConfig -> "ensure_rke2_registries_config"
  StepCertManagerRuntime -> "ensure_cert_manager_runtime"
  StepBootstrapBrokerChartReady -> "ensure_bootstrap_broker_chart_ready"
  StepFederatedVaultLifecycle -> "ensure_federated_vault_lifecycle"
  StepTargetSecretAgentChartReady -> "ensure_target_secret_agent_chart_ready"
  StepCredentialProvisionerSubstrateReady -> "ensure_credential_provisioner_substrate_ready"
  StepLifecycleAuthorityChartReady -> "ensure_lifecycle_authority_chart_ready"
  StepPostUnsealHandoff -> "reconcile_post_unseal_handoff"
  StepAuthorityBackupChartReady -> "ensure_authority_backup_chart_ready"
  StepAuthorityBackupRolloutReady -> "observe_authority_backup_rollout_ready"
  StepEstablishAuthorityBackup -> "establish_authority_backup_admission"
  StepReconcileInForceConfig -> "reconcile_authority_in_force_config"
  StepLoadInForceSettings -> "load_authority_in_force_settings"
  StepProviderWorkerChartReady -> "ensure_provider_worker_chart_ready"
  StepTlsRetentionChartReady -> "ensure_tls_retention_chart_ready"
  StepMetalLbRuntime -> "ensure_metallb_runtime"
  StepEnvoyGatewayRuntime -> "ensure_envoy_gateway_runtime"
  StepPostgresOperatorRuntime -> "ensure_postgres_operator_runtime"
  StepGatewayMinioBootstrap -> "ensure_gateway_minio_bootstrap"
  StepGatewayChartReady -> "ensure_gateway_chart_ready"
  StepRootChartNamespaceGuardrails -> "ensure_root_chart_namespace_guardrails"
  StepAdminPublicEdgeRoutes -> "ensure_admin_public_edge_routes"
  StepReconcileManagedAnnotations -> "reconcile_managed_annotations"
  StepRequireOperationalAwsCredentials -> "require_operational_aws_credentials"
  StepPublicEdgeAcmeRuntime -> "ensure_public_edge_acme_runtime"
  StepReconcileDnsBootstrapRecord -> "reconcile_dns_bootstrap_record"

reconcileStepPhase :: ReconcileStepId -> ReconcilePhase
reconcileStepPhase step = case step of
  StepRke2ResourceGuardrails -> PhaseBootstrap
  StepHostInotifyLimits -> PhaseBootstrap
  StepManagedRuntimeImageRetention -> PhaseBootstrap
  StepRke2ServerInstalled -> PhaseBootstrap
  StepRke2IngressController -> PhaseBootstrap
  StepEnableRke2Service -> PhaseBootstrap
  StepRestartRke2Service -> PhaseBootstrap
  StepSyncUserKubeconfig -> PhaseBootstrap
  StepVerifyClusterInfo -> PhaseBootstrap
  StepWaitForClusterNodesReady -> PhaseBootstrap
  StepDeleteNonManualStorageClasses -> PhaseBootstrap
  StepEnsureProdboxIdentityConfigMap -> PhaseBootstrap
  StepEnsureHostControlDataDirectory -> PhaseBootstrap
  StepEnsureRetainedLocalStorage -> PhaseBootstrap
  StepMinioRuntimeBootstrap -> PhaseBootstrap
  StepVaultRuntime -> PhaseBootstrap
  StepHarborRegistryStorageBackend -> PhaseBootstrap
  StepHarborRegistryRuntime -> PhaseBootstrap
  StepVerifyRegistryMinioEdge -> PhaseBootstrap
  StepMirrorClusterImagesOnce -> PhaseBootstrap
  StepEnsureRuntimeImage -> PhaseBootstrap
  StepRke2RegistriesConfig -> PhaseBootstrap
  StepCertManagerRuntime -> PhaseSteady
  StepBootstrapBrokerChartReady -> PhaseBootstrap
  StepFederatedVaultLifecycle -> PhaseTransition
  StepTargetSecretAgentChartReady -> PhaseTransition
  StepCredentialProvisionerSubstrateReady -> PhaseTransition
  StepLifecycleAuthorityChartReady -> PhaseTransition
  StepPostUnsealHandoff -> PhaseTransition
  StepAuthorityBackupChartReady -> PhaseTransition
  StepAuthorityBackupRolloutReady -> PhaseTransition
  StepEstablishAuthorityBackup -> PhaseTransition
  StepReconcileInForceConfig -> PhaseTransition
  StepLoadInForceSettings -> PhaseTransition
  StepProviderWorkerChartReady -> PhaseSteady
  StepTlsRetentionChartReady -> PhaseSteady
  StepMetalLbRuntime -> PhaseSteady
  StepEnvoyGatewayRuntime -> PhaseSteady
  StepPostgresOperatorRuntime -> PhaseSteady
  StepGatewayMinioBootstrap -> PhaseTransition
  StepGatewayChartReady -> PhaseSteady
  StepRootChartNamespaceGuardrails -> PhaseSteady
  StepAdminPublicEdgeRoutes -> PhaseSteady
  StepReconcileManagedAnnotations -> PhaseSteady
  StepRequireOperationalAwsCredentials -> PhaseEdge
  StepPublicEdgeAcmeRuntime -> PhaseEdge
  StepReconcileDnsBootstrapRecord -> PhaseEdge

-- | The exact anchor for every step. This match is intentionally exhaustive:
-- adding a 'ReconcileStepId' without an ordering decision fails the
-- warning-clean build.
reconcileStepAnchor :: ReconcileStepId -> ReconcileStepAnchor
reconcileStepAnchor step = case step of
  StepRke2ResourceGuardrails -> HostPrepBefore ComponentClusterBase
  StepHostInotifyLimits -> HostPrepBefore ComponentClusterBase
  StepManagedRuntimeImageRetention -> HostPrepBefore ComponentClusterBase
  StepRke2ServerInstalled -> ComponentMutation ComponentClusterBase
  StepRke2IngressController -> ComponentMutation ComponentClusterBase
  StepEnableRke2Service -> ComponentMutation ComponentClusterBase
  StepRestartRke2Service -> ComponentMutation ComponentClusterBase
  StepSyncUserKubeconfig -> ComponentMutation ComponentClusterBase
  StepVerifyClusterInfo -> ComponentMutation ComponentClusterBase
  StepWaitForClusterNodesReady -> ComponentReadiness ComponentClusterBase
  StepDeleteNonManualStorageClasses -> HostPostAfter ComponentClusterBase
  StepEnsureProdboxIdentityConfigMap -> ComponentReadiness ComponentClusterBase
  StepEnsureHostControlDataDirectory -> HostPrepBefore ComponentMinio
  StepEnsureRetainedLocalStorage -> HostPrepBefore ComponentMinio
  StepMinioRuntimeBootstrap -> ComponentReadiness ComponentMinio
  StepVaultRuntime -> ComponentReadiness ComponentVaultWorkload
  StepHarborRegistryStorageBackend -> ComponentMutation ComponentRegistry
  StepHarborRegistryRuntime -> ComponentMutation ComponentRegistry
  StepVerifyRegistryMinioEdge -> ComponentReadiness ComponentRegistry
  StepMirrorClusterImagesOnce -> HostPostAfter ComponentRegistry
  StepEnsureRuntimeImage -> HostPostAfter ComponentRegistry
  StepRke2RegistriesConfig -> ComponentReadiness ComponentRegistry
  StepCertManagerRuntime -> ComponentReadiness ComponentCertManager
  StepBootstrapBrokerChartReady -> ComponentReadiness ComponentChartBootstrapBroker
  -- The home lifecycle interpreter both performs the custody transition and
  -- proves the resulting unsealed state.  Unlike AWS (which has a separate
  -- `StepAwsVaultUnsealedReady`), this is therefore the component's terminal
  -- production-readiness barrier.
  StepFederatedVaultLifecycle -> ComponentReadiness ComponentVaultUnsealed
  StepTargetSecretAgentChartReady -> ComponentReadiness ComponentChartTargetSecretAgent
  StepCredentialProvisionerSubstrateReady -> HostPrepBefore ComponentChartAuthorityBackup
  StepLifecycleAuthorityChartReady -> ComponentReadiness ComponentChartLifecycleAuthority
  StepPostUnsealHandoff -> ComponentReadiness ComponentChartLifecycleAuthority
  StepAuthorityBackupChartReady -> ComponentMutation ComponentChartAuthorityBackup
  StepAuthorityBackupRolloutReady -> ComponentReadiness ComponentChartAuthorityBackup
  StepEstablishAuthorityBackup -> TransitionFor ComponentChartAuthorityBackup
  StepReconcileInForceConfig -> TransitionFor ComponentChartAuthorityBackup
  StepLoadInForceSettings -> ComponentReadiness ComponentChartAuthorityBackup
  StepProviderWorkerChartReady -> ComponentReadiness ComponentChartProviderWorker
  StepTlsRetentionChartReady -> ComponentReadiness ComponentChartTlsRetention
  StepMetalLbRuntime -> ComponentReadiness ComponentMetalLB
  StepEnvoyGatewayRuntime -> ComponentReadiness ComponentEnvoyGateway
  StepPostgresOperatorRuntime -> ComponentReadiness ComponentPerconaPostgresOperator
  -- The unified Gateway/Authority IAM reconcile reads Vault, so it belongs
  -- after unseal; the Authority consumes its dedicated principal during
  -- initial admission, so the reconcile must precede that chart.
  StepGatewayMinioBootstrap -> HostPrepBefore ComponentChartLifecycleAuthority
  StepGatewayChartReady -> ComponentReadiness ComponentGatewayDaemonFull
  StepRootChartNamespaceGuardrails -> HostPostAfter ComponentGatewayDaemonFull
  StepAdminPublicEdgeRoutes -> HostPostAfter ComponentGatewayDaemonFull
  StepReconcileManagedAnnotations -> ComponentReadiness ComponentGatewayDaemonFull
  StepRequireOperationalAwsCredentials -> EdgeOnly
  StepPublicEdgeAcmeRuntime -> EdgeOnly
  StepReconcileDnsBootstrapRecord -> EdgeOnly

-- | Stable within-component step order. The component order itself comes only
-- from 'componentReconcileOrder'; chart-only nodes deliberately contribute no
-- native home-platform steps.
stepsForComponent :: ComponentId -> [ReconcileStepId]
stepsForComponent component = case component of
  ComponentClusterBase ->
    [ StepRke2ResourceGuardrails
    , StepHostInotifyLimits
    , StepManagedRuntimeImageRetention
    , StepRke2ServerInstalled
    , StepRke2IngressController
    , StepEnableRke2Service
    , StepRestartRke2Service
    , StepSyncUserKubeconfig
    , StepVerifyClusterInfo
    , StepWaitForClusterNodesReady
    , StepDeleteNonManualStorageClasses
    , StepEnsureProdboxIdentityConfigMap
    ]
  ComponentMinio ->
    [ StepEnsureHostControlDataDirectory
    , StepEnsureRetainedLocalStorage
    , StepMinioRuntimeBootstrap
    ]
  ComponentVaultWorkload -> [StepVaultRuntime]
  ComponentVaultUnsealed -> [StepFederatedVaultLifecycle]
  ComponentRegistry ->
    [ StepHarborRegistryStorageBackend
    , StepHarborRegistryRuntime
    , StepVerifyRegistryMinioEdge
    , StepMirrorClusterImagesOnce
    , StepEnsureRuntimeImage
    , StepRke2RegistriesConfig
    ]
  ComponentMetalLB -> [StepMetalLbRuntime]
  ComponentEnvoyGateway -> [StepEnvoyGatewayRuntime]
  ComponentCertManager -> [StepCertManagerRuntime]
  ComponentPerconaPostgresOperator -> [StepPostgresOperatorRuntime]
  ComponentGatewayDaemonPreVault -> []
  ComponentGatewayDaemonFull ->
    [ StepGatewayChartReady
    , StepRootChartNamespaceGuardrails
    , StepAdminPublicEdgeRoutes
    , StepReconcileManagedAnnotations
    ]
  ComponentChartPulsar -> []
  ComponentChartRedis -> []
  ComponentChartKeycloakPostgres -> []
  ComponentChartKeycloak -> []
  ComponentChartVscode -> []
  ComponentChartApi -> []
  ComponentChartWebsocket -> []
  ComponentChartGateway -> []
  -- Sprint 4.50: internal charts remain off the public `charts` surface, but
  -- native reconcile deploys each release and ends its component group at the
  -- chart's own rollout/readiness barrier.
  ComponentChartBootstrapBroker -> [StepBootstrapBrokerChartReady]
  ComponentChartLifecycleAuthority ->
    [ StepGatewayMinioBootstrap
    , StepLifecycleAuthorityChartReady
    , StepPostUnsealHandoff
    ]
  ComponentChartProviderWorker -> [StepProviderWorkerChartReady]
  ComponentChartAuthorityBackup ->
    [ StepCredentialProvisionerSubstrateReady
    , StepAuthorityBackupChartReady
    , StepAuthorityBackupRolloutReady
    , StepEstablishAuthorityBackup
    , StepReconcileInForceConfig
    , StepLoadInForceSettings
    ]
  ComponentChartTlsRetention -> [StepTlsRetentionChartReady]
  ComponentChartTargetSecretAgent -> [StepTargetSecretAgentChartReady]

edgeReconcileSteps :: [ReconcileStepId]
edgeReconcileSteps =
  [ StepRequireOperationalAwsCredentials
  , StepPublicEdgeAcmeRuntime
  , StepReconcileDnsBootstrapRecord
  ]

-- | The native component order is only a pure projection of the validated
-- component DAG. The optional public-edge tail is deliberately outside the
-- component graph and is appended by the plan compiler.
nativeInstallStepOrder :: ComponentDag -> [ReconcileStepId]
nativeInstallStepOrder dag =
  concatMap stepsForComponent (componentReconcileOrder dag)

-- | The steps to narrate/execute for a run, honouring @--with-edge@.
nativeInstallStepsForRun :: [ReconcileStepId] -> Bool -> [ReconcileStepId]
nativeInstallStepsForRun order withEdge =
  [step | step <- order, withEdge || reconcileStepPhase step /= PhaseEdge]

-- | The exact graph prefix the automation harness may establish before it
-- refreshes the Provider credential. This is a projection of the same ordered
-- step table as full reconcile, not a second authored bootstrap plan.
nativeHarnessBootstrapFloorStepOrder :: [ReconcileStepId] -> [ReconcileStepId]
nativeHarnessBootstrapFloorStepOrder =
  filter
    ( \step ->
        reconcileStepPhase step == PhaseBootstrap
          || reconcileStepPhase step == PhaseTransition
    )

deriveNativeInstallStepOrder
  :: [ComponentNode] -> Either String (ComponentDag, [ReconcileStepId])
deriveNativeInstallStepOrder = compileAnchoredOrder nativeAnchoredOrderSpec

nativeAnchoredOrderSpec :: AnchoredOrderSpec ReconcileStepId
nativeAnchoredOrderSpec =
  AnchoredOrderSpec
    { anchoredSurfaceName = "Native reconcile"
    , anchoredAllSteps = [minBound .. maxBound]
    , anchoredRequiredComponents = []
    , anchoredStepsForComponent = stepsForComponent
    , anchoredTailSteps = edgeReconcileSteps
    , anchoredStepAnchor = reconcileStepAnchor
    , anchoredStepPhase = reconcileStepPhase
    , anchoredStepToken = reconcileStepToken
    }

-- | Prove every dependency's complete anchored step group precedes the first
-- step of its consumer. Empty chart-only groups are intentionally skipped.
nativeInstallStepOrderRespectsGraph
  :: ComponentDag -> [ReconcileStepId] -> Either String ()
nativeInstallStepOrderRespectsGraph = anchoredOrderRespectsGraph nativeAnchoredOrderSpec

renderNativeInstallPlan
  :: FilePath -> ValidatedSettings -> String -> String -> String -> Bool -> String
renderNativeInstallPlan repoRoot settings machineId prodboxId labelValue withEdge =
  case deriveNativeInstallStepOrder (components (validatedConfig settings)) of
    Left detail ->
      unlines
        [ "RKE2_RECONCILE_PLAN_INVALID"
        , "ERROR=" ++ detail
        ]
    Right (_dag, order) ->
      renderNativeInstallPlanWithOrder
        order
        repoRoot
        settings
        machineId
        prodboxId
        labelValue
        withEdge

renderNativeInstallPlanWithOrder
  :: [ReconcileStepId]
  -> FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> String
  -> Bool
  -> String
renderNativeInstallPlanWithOrder order repoRoot settings machineId prodboxId labelValue withEdge =
  unlines
    ( [ "RKE2_RECONCILE_PLAN"
      , "REPO_ROOT=" ++ repoRoot
      , "MACHINE_ID=" ++ machineId
      , "PRODBOX_ID=" ++ prodboxId
      , "LABEL_VALUE=" ++ labelValue
      , "MANUAL_PV_ROOT=" ++ resolvedManualPvHostRoot settings
      , "WITH_EDGE=" ++ (if withEdge then "true" else "false")
      , "HOST_CAPACITY=" ++ renderResourceVectorRuntime (Capacity.host_capacity resourcePlan)
      , "RKE2_RESERVED=" ++ renderResourceVectorRuntime (Capacity.rke2_reserved resourcePlan)
      , "EVICTION_FLOOR=" ++ renderResourceVectorRuntime (Capacity.eviction_floor resourcePlan)
      , "CLUSTER_ALLOCATABLE="
          ++ renderResourceVectorRuntime
            (CapacityAllocation.planAllocatable (validatedAllocatedPlan settings))
      ]
        -- Narration is projected from the single ordered step table (M1), so it
        -- can never drift from the executor, which reads the same table.
        ++ ["STEP=" ++ reconcileStepToken step | step <- nativeInstallStepsForRun order withEdge]
    )
 where
  resourcePlan = validatedResourcePlan settings

data NativeInstallPayload = NativeInstallPayload
  { nativeInstallPayloadMachineId :: String
  , nativeInstallPayloadProdboxId :: String
  , nativeInstallPayloadLabelValue :: String
  , nativeInstallPayloadWithEdge :: Bool
  , nativeInstallPayloadDag :: ComponentDag
  , nativeInstallPayloadStepOrder :: [ReconcileStepId]
  }
  deriving (Eq, Show)

buildNativeInstallExecutionPlan
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> String
  -> Bool
  -> Either StructuredError (Plan NativeInstallPayload)
buildNativeInstallExecutionPlan repoRoot settings machineId prodboxId labelValue withEdge = do
  (dag, order) <-
    case deriveNativeInstallStepOrder (components (validatedConfig settings)) of
      Left detail -> Left (nativeInstallPlanStructuredError detail)
      Right derived -> Right derived
  let payload =
        NativeInstallPayload
          { nativeInstallPayloadMachineId = machineId
          , nativeInstallPayloadProdboxId = prodboxId
          , nativeInstallPayloadLabelValue = labelValue
          , nativeInstallPayloadWithEdge = withEdge
          , nativeInstallPayloadDag = dag
          , nativeInstallPayloadStepOrder = order
          }
  pure
    ( buildPlan
        ( \resolved ->
            renderNativeInstallPlanWithOrder
              (nativeInstallPayloadStepOrder resolved)
              repoRoot
              settings
              (nativeInstallPayloadMachineId resolved)
              (nativeInstallPayloadProdboxId resolved)
              (nativeInstallPayloadLabelValue resolved)
              (nativeInstallPayloadWithEdge resolved)
        )
        payload
    )

nativeInstallPlanStructuredError :: String -> StructuredError
nativeInstallPlanStructuredError detail =
  StructuredError
    { errorPreconditionLabel = "nativeInstallGraphOrder"
    , errorSummaryLine = "Native reconcile graph could not produce a safe execution plan."
    , errorOffendingItems = []
    , errorNarrative =
        unlines
          [ "Native reconcile graph could not produce a safe execution plan."
          , detail
          , "No reconcile mutation was started."
          ]
    }

applyNativeInstallPlan
  :: FilePath
  -> ValidatedSettings
  -> NativeInstallPayload
  -> IO ExitCode
applyNativeInstallPlan = applyNativeInstallPlanWithMode NativeInstallFull

data NativeInstallMode
  = NativeInstallFull
  | NativeInstallHarnessBootstrapFloor
  deriving (Eq)

applyNativeInstallPlanWithMode
  :: NativeInstallMode
  -> FilePath
  -> ValidatedSettings
  -> NativeInstallPayload
  -> IO ExitCode
applyNativeInstallPlanWithMode mode repoRoot bootstrapSettings payload = do
  -- Sprint 4.43: execution is projected from the SAME ordered step table
  -- (`nativeInstallStepOrder`) the plan narration reads, so the two cannot drift
  -- (bootstrap_readiness_doctrine.md M1). The pre-Vault bootstrap runs the
  -- `PhaseBootstrap` steps, the Vault-init transition runs its dedicated control
  -- flow, and the post-Vault steady phase runs the `PhaseSteady` steps.
  -- Sprint 4.61: admissions are threaded across the phase boundaries rather
  -- than reset at each one. The phases are separate calls only because their
  -- step actions differ; they are one run, and a readiness observation made in
  -- an earlier phase is evidence in a later one until its age bound expires it.
  -- Sprint 4.64: the run begins here and only here. The empty admission set is
  -- no longer nameable at a phase boundary, so a later phase cannot be handed
  -- one by accident.
  bootstrapOutcome <-
    runFirstAnchoredReconcileSteps
      repoRoot
      bootstrapSettings
      dag
      bootstrapStepAction
      [step | step <- order, reconcileStepPhase step == PhaseBootstrap]
  case bootstrapOutcome of
    Left bootstrapExit -> pure bootstrapExit
    Right bootstrapAdmissions -> do
      vaultLifecycleResult <-
        ensureFederatedVaultLifecycleDetailed
          repoRoot
          (validatedDeploymentContext bootstrapSettings)
      case vaultLifecycleExitCode vaultLifecycleResult of
        ExitFailure _ -> pure (vaultLifecycleExitCode vaultLifecycleResult)
        ExitSuccess -> do
          vaultReadyObserved <-
            requireNativeComponentReadiness
              repoRoot
              bootstrapSettings
              dag
              ComponentVaultUnsealed
          let vaultReadyExit = fromLeft ExitSuccess vaultReadyObserved
              vaultAdmissions =
                either
                  (const bootstrapAdmissions)
                  (`recordAdmission` bootstrapAdmissions)
                  vaultReadyObserved
          case vaultReadyExit of
            ExitFailure _ -> pure vaultReadyExit
            ExitSuccess -> do
              -- MinIO, Vault, and Broker are ready.  The remaining transition
              -- deliberately still uses Tier-0 settings: home Agent -> frozen
              -- Authority -> Backup Adapter -> backup admission -> config CAS.
              (transitionExit, transitionAdmissions) <-
                runAnchoredReconcileSteps
                  repoRoot
                  bootstrapSettings
                  dag
                  transitionStepAction
                  vaultAdmissions
                  [ step
                  | step <- order
                  , reconcileStepPhase step == PhaseTransition
                  , step /= StepFederatedVaultLifecycle
                  , step /= StepLoadInForceSettings
                  ]
              case transitionExit of
                ExitFailure _ -> pure transitionExit
                ExitSuccess -> do
                  settingsResult <- loadPostMinioLifecycleSettings repoRoot
                  case settingsResult of
                    Left err -> failWith err
                    Right settings -> do
                      -- Loading the observed projection is the final readiness
                      -- barrier of the Authority-backup component group.
                      authorityObserved <-
                        requireNativeComponentReadiness
                          repoRoot
                          settings
                          dag
                          ComponentChartAuthorityBackup
                      let inForceAuthorityReady = fromLeft ExitSuccess authorityObserved
                          authorityAdmissions =
                            either
                              (const transitionAdmissions)
                              (`recordAdmission` transitionAdmissions)
                              authorityObserved
                      case inForceAuthorityReady of
                        ExitFailure _ -> pure inForceAuthorityReady
                        ExitSuccess
                          | mode == NativeInstallHarnessBootstrapFloor ->
                              pure ExitSuccess
                          | otherwise -> do
                              lanDefaultsResult <- resolveClusterPlatformLanDefaults
                              case lanDefaultsResult of
                                Left err -> failWith err
                                Right lanDefaults -> do
                                  (steadyExit, _steadyAdmissions) <-
                                    runAnchoredReconcileSteps
                                      repoRoot
                                      settings
                                      dag
                                      (steadyStepAction settings lanDefaults)
                                      authorityAdmissions
                                      [step | step <- order, reconcileStepPhase step == PhaseSteady]
                                  case steadyExit of
                                    ExitFailure _ -> pure steadyExit
                                    ExitSuccess
                                      -- The public edge (Route 53 DNS + ZeroSSL DNS-01 TLS) is the only
                                      -- part of reconcile that needs operational AWS credentials.
                                      | withEdge ->
                                          applyPublicEdgeReconcile repoRoot settings prodboxId labelValue
                                      | otherwise -> pure ExitSuccess
 where
  machineId = nativeInstallPayloadMachineId payload
  prodboxId = nativeInstallPayloadProdboxId payload
  labelValue = nativeInstallPayloadLabelValue payload
  withEdge = nativeInstallPayloadWithEdge payload
  dag = nativeInstallPayloadDag payload
  order = case mode of
    NativeInstallFull -> nativeInstallPayloadStepOrder payload
    NativeInstallHarnessBootstrapFloor ->
      nativeHarnessBootstrapFloorStepOrder (nativeInstallPayloadStepOrder payload)

  -- The @PhaseBootstrap@ executor is total. A wrong-phase call fails loudly;
  -- no newly-added step can silently no-op through a wildcard.
  bootstrapStepAction :: ReconcileStepId -> IO ExitCode
  bootstrapStepAction step = case step of
    StepRke2ResourceGuardrails -> ensureRke2ResourceGuardrails repoRoot bootstrapSettings
    StepHostInotifyLimits -> ensureHostInotifyLimits repoRoot
    StepManagedRuntimeImageRetention -> reconcileManagedRuntimeImageRetention repoRoot
    StepRke2ServerInstalled -> ensureRke2ServerInstalled repoRoot
    StepRke2IngressController -> ensureRke2IngressController repoRoot
    StepEnableRke2Service ->
      runCommand
        Subprocess
          { subprocessPath = "sudo"
          , subprocessArguments = ["systemctl", "enable", rke2ServiceName]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    StepRestartRke2Service ->
      runCommand
        Subprocess
          { subprocessPath = "sudo"
          , subprocessArguments = ["systemctl", "restart", rke2ServiceName]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    StepSyncUserKubeconfig -> syncUserKubeconfig repoRoot
    StepVerifyClusterInfo -> verifyClusterInfo repoRoot
    StepWaitForClusterNodesReady -> waitForClusterNodesReady repoRoot
    StepDeleteNonManualStorageClasses -> deleteNonManualStorageClasses repoRoot
    StepEnsureProdboxIdentityConfigMap ->
      ensureProdboxIdentityConfigMap repoRoot machineId prodboxId labelValue
    StepEnsureHostControlDataDirectory -> ensureHostControlDataDirectory repoRoot bootstrapSettings
    StepEnsureRetainedLocalStorage ->
      ensureRetainedLocalStorage repoRoot bootstrapSettings prodboxId labelValue
    -- Sprint 7.25: MinIO comes up BEFORE Vault (it depends only on the cluster +
    -- its retained PV — static root cred, no Vault init container), so Vault init
    -- writes the unlock bundle to a live MinIO and unseal reads it FROM MinIO.
    StepMinioRuntimeBootstrap ->
      ensureMinioRuntime repoRoot bootstrapSettings SubstrateHomeLocal MinioBootstrapPublic
    StepVaultRuntime -> ensureVaultRuntime repoRoot bootstrapSettings
    StepHarborRegistryStorageBackend -> ensureHarborRegistryStorageBackend repoRoot
    StepHarborRegistryRuntime -> ensureHarborRegistryRuntime repoRoot SubstrateHomeLocal
    -- Sprint 4.43: the deep registry->MinIO S3 edge gate (M3) runs before the
    -- mirror push and every downstream registry write, replacing reliance on the
    -- shallow `GET /v2/` front-door gate.
    StepVerifyRegistryMinioEdge -> ensureRegistryStorageBackendEdgeReady repoRoot
    StepMirrorClusterImagesOnce -> mirrorClusterImagesOnce repoRoot
    StepEnsureRuntimeImage -> ensureRuntimeImage repoRoot prodboxId
    StepRke2RegistriesConfig -> ensureRke2RegistriesConfig repoRoot
    StepCertManagerRuntime -> wrongPhaseStep PhaseBootstrap step
    StepBootstrapBrokerChartReady ->
      ensureInternalControlPlaneChartReady
        repoRoot
        bootstrapSettings
        SubstrateHomeLocal
        ComponentChartBootstrapBroker
    StepFederatedVaultLifecycle -> wrongPhaseStep PhaseBootstrap step
    StepLoadInForceSettings -> wrongPhaseStep PhaseBootstrap step
    StepTargetSecretAgentChartReady -> wrongPhaseStep PhaseBootstrap step
    StepCredentialProvisionerSubstrateReady -> wrongPhaseStep PhaseBootstrap step
    StepLifecycleAuthorityChartReady -> wrongPhaseStep PhaseBootstrap step
    StepPostUnsealHandoff -> wrongPhaseStep PhaseBootstrap step
    StepAuthorityBackupChartReady -> wrongPhaseStep PhaseBootstrap step
    StepAuthorityBackupRolloutReady -> wrongPhaseStep PhaseBootstrap step
    StepEstablishAuthorityBackup -> wrongPhaseStep PhaseBootstrap step
    StepReconcileInForceConfig -> wrongPhaseStep PhaseBootstrap step
    StepProviderWorkerChartReady -> wrongPhaseStep PhaseBootstrap step
    StepTlsRetentionChartReady -> wrongPhaseStep PhaseBootstrap step
    StepMetalLbRuntime -> wrongPhaseStep PhaseBootstrap step
    StepEnvoyGatewayRuntime -> wrongPhaseStep PhaseBootstrap step
    StepPostgresOperatorRuntime -> wrongPhaseStep PhaseBootstrap step
    StepGatewayMinioBootstrap -> wrongPhaseStep PhaseBootstrap step
    StepGatewayChartReady -> wrongPhaseStep PhaseBootstrap step
    StepRootChartNamespaceGuardrails -> wrongPhaseStep PhaseBootstrap step
    StepAdminPublicEdgeRoutes -> wrongPhaseStep PhaseBootstrap step
    StepReconcileManagedAnnotations -> wrongPhaseStep PhaseBootstrap step
    StepRequireOperationalAwsCredentials -> wrongPhaseStep PhaseBootstrap step
    StepPublicEdgeAcmeRuntime -> wrongPhaseStep PhaseBootstrap step
    StepReconcileDnsBootstrapRecord -> wrongPhaseStep PhaseBootstrap step

  transitionStepAction :: ReconcileStepId -> IO ExitCode
  transitionStepAction step = case step of
    StepTargetSecretAgentChartReady ->
      ensureInternalControlPlaneChartReady
        repoRoot
        bootstrapSettings
        SubstrateHomeLocal
        ComponentChartTargetSecretAgent
    StepCredentialProvisionerSubstrateReady ->
      ensureCredentialProvisionerSubstrateReady repoRoot
    StepLifecycleAuthorityChartReady ->
      ensureInternalControlPlaneChartReady
        repoRoot
        bootstrapSettings
        SubstrateHomeLocal
        ComponentChartLifecycleAuthority
    StepPostUnsealHandoff -> runPostUnsealHandoffViaBroker repoRoot
    StepAuthorityBackupChartReady ->
      ensureInternalControlPlaneChartReady
        repoRoot
        bootstrapSettings
        SubstrateHomeLocal
        ComponentChartAuthorityBackup
    -- Authority Backup is deliberately applied without Helm waiting because
    -- its capability-backed readiness is graph-owned. This requested-revision
    -- barrier separates that mutation from the first backup-admission request;
    -- otherwise the old Available condition can race the Recreate rollout.
    StepAuthorityBackupRolloutReady -> pure ExitSuccess
    StepEstablishAuthorityBackup ->
      requireEstablishedAuthorityBackupAdmission repoRoot bootstrapSettings
    StepReconcileInForceConfig -> do
      reconciled <-
        reconcileInForceConfigFromFile LifecycleAuthorityOperator repoRoot
      case reconciled of
        Left detail -> failWith detail
        Right outcome -> do
          writeOutputLine (renderSeedInForceOutcome outcome)
          markerResult <- reconcileAuthorityBoundRetainedRootMarker repoRoot
          case markerResult of
            Left err -> failWith (Text.unpack (renderLocalRetainedRootError err))
            Right markerOutcome -> do
              writeOutputLine
                (Text.unpack (renderRetainedRootMarkerReconcileOutcome markerOutcome))
              pure ExitSuccess
    StepFederatedVaultLifecycle -> wrongPhaseStep PhaseTransition step
    StepLoadInForceSettings -> wrongPhaseStep PhaseTransition step
    StepRke2ResourceGuardrails -> wrongPhaseStep PhaseTransition step
    StepHostInotifyLimits -> wrongPhaseStep PhaseTransition step
    StepManagedRuntimeImageRetention -> wrongPhaseStep PhaseTransition step
    StepRke2ServerInstalled -> wrongPhaseStep PhaseTransition step
    StepRke2IngressController -> wrongPhaseStep PhaseTransition step
    StepEnableRke2Service -> wrongPhaseStep PhaseTransition step
    StepRestartRke2Service -> wrongPhaseStep PhaseTransition step
    StepSyncUserKubeconfig -> wrongPhaseStep PhaseTransition step
    StepVerifyClusterInfo -> wrongPhaseStep PhaseTransition step
    StepWaitForClusterNodesReady -> wrongPhaseStep PhaseTransition step
    StepDeleteNonManualStorageClasses -> wrongPhaseStep PhaseTransition step
    StepEnsureProdboxIdentityConfigMap -> wrongPhaseStep PhaseTransition step
    StepEnsureHostControlDataDirectory -> wrongPhaseStep PhaseTransition step
    StepEnsureRetainedLocalStorage -> wrongPhaseStep PhaseTransition step
    StepMinioRuntimeBootstrap -> wrongPhaseStep PhaseTransition step
    StepVaultRuntime -> wrongPhaseStep PhaseTransition step
    StepHarborRegistryStorageBackend -> wrongPhaseStep PhaseTransition step
    StepHarborRegistryRuntime -> wrongPhaseStep PhaseTransition step
    StepVerifyRegistryMinioEdge -> wrongPhaseStep PhaseTransition step
    StepMirrorClusterImagesOnce -> wrongPhaseStep PhaseTransition step
    StepEnsureRuntimeImage -> wrongPhaseStep PhaseTransition step
    StepRke2RegistriesConfig -> wrongPhaseStep PhaseTransition step
    StepBootstrapBrokerChartReady -> wrongPhaseStep PhaseTransition step
    StepCertManagerRuntime -> wrongPhaseStep PhaseTransition step
    StepProviderWorkerChartReady -> wrongPhaseStep PhaseTransition step
    StepTlsRetentionChartReady -> wrongPhaseStep PhaseTransition step
    StepMetalLbRuntime -> wrongPhaseStep PhaseTransition step
    StepEnvoyGatewayRuntime -> wrongPhaseStep PhaseTransition step
    StepPostgresOperatorRuntime -> wrongPhaseStep PhaseTransition step
    StepGatewayMinioBootstrap -> ensureGatewayMinioBootstrap repoRoot
    StepGatewayChartReady -> wrongPhaseStep PhaseTransition step
    StepRootChartNamespaceGuardrails -> wrongPhaseStep PhaseTransition step
    StepAdminPublicEdgeRoutes -> wrongPhaseStep PhaseTransition step
    StepReconcileManagedAnnotations -> wrongPhaseStep PhaseTransition step
    StepRequireOperationalAwsCredentials -> wrongPhaseStep PhaseTransition step
    StepPublicEdgeAcmeRuntime -> wrongPhaseStep PhaseTransition step
    StepReconcileDnsBootstrapRecord -> wrongPhaseStep PhaseTransition step

  -- The @PhaseSteady@ executor is likewise total.
  steadyStepAction :: ValidatedSettings -> (String, String) -> ReconcileStepId -> IO ExitCode
  steadyStepAction settings (metallbPool, edgeLbIp) step = case step of
    StepProviderWorkerChartReady ->
      ensureInternalControlPlaneChartReady
        repoRoot
        settings
        SubstrateHomeLocal
        ComponentChartProviderWorker
    StepTlsRetentionChartReady ->
      ensureInternalControlPlaneChartReady
        repoRoot
        settings
        SubstrateHomeLocal
        ComponentChartTlsRetention
    StepCertManagerRuntime -> ensureCertManagerRuntime repoRoot prodboxId labelValue
    StepMetalLbRuntime -> ensureMetalLbRuntime repoRoot settings prodboxId labelValue metallbPool
    StepEnvoyGatewayRuntime ->
      ensureEnvoyGatewayRuntime repoRoot settings prodboxId labelValue edgeLbIp
    StepPostgresOperatorRuntime -> ensurePostgresOperatorRuntime repoRoot prodboxId labelValue
    StepGatewayMinioBootstrap -> wrongPhaseStep PhaseSteady step
    StepGatewayChartReady -> ensureGatewayChartReadyPostVault repoRoot settings SubstrateHomeLocal
    StepRootChartNamespaceGuardrails -> ensureRootChartNamespaceGuardrails repoRoot settings
    StepAdminPublicEdgeRoutes ->
      ensureAdminPublicEdgeRoutes repoRoot settings SubstrateHomeLocal prodboxId labelValue
    StepReconcileManagedAnnotations -> reconcileManagedAnnotations repoRoot prodboxId labelValue
    StepRke2ResourceGuardrails -> wrongPhaseStep PhaseSteady step
    StepHostInotifyLimits -> wrongPhaseStep PhaseSteady step
    StepManagedRuntimeImageRetention -> wrongPhaseStep PhaseSteady step
    StepRke2ServerInstalled -> wrongPhaseStep PhaseSteady step
    StepRke2IngressController -> wrongPhaseStep PhaseSteady step
    StepEnableRke2Service -> wrongPhaseStep PhaseSteady step
    StepRestartRke2Service -> wrongPhaseStep PhaseSteady step
    StepSyncUserKubeconfig -> wrongPhaseStep PhaseSteady step
    StepVerifyClusterInfo -> wrongPhaseStep PhaseSteady step
    StepWaitForClusterNodesReady -> wrongPhaseStep PhaseSteady step
    StepDeleteNonManualStorageClasses -> wrongPhaseStep PhaseSteady step
    StepEnsureProdboxIdentityConfigMap -> wrongPhaseStep PhaseSteady step
    StepEnsureHostControlDataDirectory -> wrongPhaseStep PhaseSteady step
    StepEnsureRetainedLocalStorage -> wrongPhaseStep PhaseSteady step
    StepMinioRuntimeBootstrap -> wrongPhaseStep PhaseSteady step
    StepVaultRuntime -> wrongPhaseStep PhaseSteady step
    StepHarborRegistryStorageBackend -> wrongPhaseStep PhaseSteady step
    StepHarborRegistryRuntime -> wrongPhaseStep PhaseSteady step
    StepVerifyRegistryMinioEdge -> wrongPhaseStep PhaseSteady step
    StepMirrorClusterImagesOnce -> wrongPhaseStep PhaseSteady step
    StepEnsureRuntimeImage -> wrongPhaseStep PhaseSteady step
    StepRke2RegistriesConfig -> wrongPhaseStep PhaseSteady step
    StepBootstrapBrokerChartReady -> wrongPhaseStep PhaseSteady step
    StepFederatedVaultLifecycle -> wrongPhaseStep PhaseSteady step
    StepLoadInForceSettings -> wrongPhaseStep PhaseSteady step
    StepTargetSecretAgentChartReady -> wrongPhaseStep PhaseSteady step
    StepCredentialProvisionerSubstrateReady -> wrongPhaseStep PhaseSteady step
    StepLifecycleAuthorityChartReady -> wrongPhaseStep PhaseSteady step
    StepPostUnsealHandoff -> wrongPhaseStep PhaseSteady step
    StepAuthorityBackupChartReady -> wrongPhaseStep PhaseSteady step
    StepAuthorityBackupRolloutReady -> wrongPhaseStep PhaseSteady step
    StepEstablishAuthorityBackup -> wrongPhaseStep PhaseSteady step
    StepReconcileInForceConfig -> wrongPhaseStep PhaseSteady step
    StepRequireOperationalAwsCredentials -> wrongPhaseStep PhaseSteady step
    StepPublicEdgeAcmeRuntime -> wrongPhaseStep PhaseSteady step
    StepReconcileDnsBootstrapRecord -> wrongPhaseStep PhaseSteady step

  wrongPhaseStep :: ReconcilePhase -> ReconcileStepId -> IO ExitCode
  wrongPhaseStep expected step =
    failWith
      ( "Internal reconcile-plan error: step `"
          ++ reconcileStepToken step
          ++ "` was dispatched to "
          ++ show expected
          ++ " but belongs to "
          ++ show (reconcileStepPhase step)
          ++ "."
      )

-- | Run an already-derived phase slice. A step marked as the component's
-- readiness barrier performs one final authoritative observation through the
-- Sprint-1.59 seam after its existing bounded convergence action succeeds.
runAnchoredReconcileSteps
  :: FilePath
  -> ValidatedSettings
  -> ComponentDag
  -> (ReconcileStepId -> IO ExitCode)
  -> AdmissionSet
  -> [ReconcileStepId]
  -> IO (ExitCode, AdmissionSet)
runAnchoredReconcileSteps repoRoot settings dag runStep carried steps =
  renderRefusalAsExit carried (runOrder carried steps)
 where
  runOrder =
    runAnchoredStepOrder
      dag
      reconcileClockMicros
      reconcileStepAnchor
      -- Sprint 4.56: the mutating arm cannot be reached without the admission the
      -- executor re-validated; it is bound here rather than ignored so the proof
      -- stays a required argument all the way to the act.
      (\admission step -> mutationAdmittedComponent admission `seq` runStep step)
      runStep
      (requireNativeComponentReadiness repoRoot settings dag)

-- | Sprint 4.64: the run's first phase. The empty admission set is supplied by
-- the executor, so this surface names it nowhere and a later phase cannot be
-- handed one.
--
-- The return type is @'Either' 'ExitCode' 'AdmissionSet'@ rather than the pair
-- the later phases use, and that is the point rather than an inconsistency: on
-- any failure there is no admission set worth carrying, and the pair shape
-- would have forced this function to name an empty one — reintroducing exactly
-- the value the sprint removed.
runFirstAnchoredReconcileSteps
  :: FilePath
  -> ValidatedSettings
  -> ComponentDag
  -> (ReconcileStepId -> IO ExitCode)
  -> [ReconcileStepId]
  -> IO (Either ExitCode AdmissionSet)
runFirstAnchoredReconcileSteps repoRoot settings dag runStep steps = do
  outcome <-
    runFirstAnchoredStepOrder
      dag
      reconcileClockMicros
      reconcileStepAnchor
      (\admission step -> mutationAdmittedComponent admission `seq` runStep step)
      runStep
      (requireNativeComponentReadiness repoRoot settings dag)
      steps
  case outcome of
    Left refusal -> Left <$> failWith (Text.unpack (renderAdmissionRefusal refusal))
    Right (ExitFailure code, _) -> pure (Left (ExitFailure code))
    Right (ExitSuccess, admissions) -> pure (Right admissions)

-- | Sprint 5.31: the refusal arrives as itself and is rendered here. Lowering
-- it to an exit code inside the runner discarded the reason on a path that
-- printed nothing, so a refused reconcile exited 1 in silence.
renderRefusalAsExit
  :: AdmissionSet
  -> IO (Either AdmissionRefusal (ExitCode, AdmissionSet))
  -> IO (ExitCode, AdmissionSet)
renderRefusalAsExit carried run = do
  outcome <- run
  case outcome of
    Left refusal -> do
      refused <- failWith (Text.unpack (renderAdmissionRefusal refusal))
      pure (refused, carried)
    Right result -> pure result

-- | The reconcile clock an admission's age is measured against.
reconcileClockMicros :: IO Natural
reconcileClockMicros = do
  posix <- getPOSIXTime
  pure (fromInteger (max 0 (floor (toRational posix * 1000000) :: Integer)))

requireNativeComponentReadiness
  :: FilePath
  -> ValidatedSettings
  -> ComponentDag
  -> ComponentId
  -> IO (Either ExitCode DependencyAdmission)
requireNativeComponentReadiness repoRoot settings dag component =
  case (lookupComponentNode component dag, componentCapabilityRequirement component dag) of
    (Nothing, _) ->
      refuseWith
        ( "Native reconcile readiness has no graph node for component `"
            ++ componentIdText component
            ++ "`."
        )
    (_, Nothing) ->
      refuseWith
        ( "Native reconcile readiness has no capability requirement for component `"
            ++ componentIdText component
            ++ "`."
        )
    (Just node, Just requirement) ->
      case nativeComponentReadinessTarget repoRoot settings component of
        Left reason -> refuseWith (Text.unpack reason)
        Right target -> do
          -- Sprint 1.61: drive the barrier through the single capability handle
          -- and the shared runCapability boundary. The actual probe I/O
          -- ('nativeComponentReadinessTarget' + its observe*Once actions) is
          -- unchanged; only the routing (ref -> runCapability -> classifyObservation)
          -- is new, and it is behaviour-preserving for every reachable reading.
          let client =
                newReadinessObservationClient
                  (coordGeneration (requirementCoordinate' requirement))
                  (readiness node)
                  target
          readinessResult <-
            observeReadinessThroughCapability
              (componentReadinessRetryPolicyFor component)
              client
              component
              requirement
          case readinessResult of
            Right admission -> pure (Right admission)
            Left detail ->
              refuseWith
                ( "Component `"
                    ++ componentIdText component
                    ++ "` did not satisfy "
                    ++ show (readiness node)
                    ++ " within the bounded readiness budget: "
                    ++ Text.unpack detail
                )

-- | The Broker and Authority Backup Helm applies deliberately do not wait for
-- their capability-backed readiness. Their exact requested-revision
-- observations therefore own a longer finite controller-convergence window;
-- all other component barriers retain the small shared jitter budget.
componentReadinessRetryPolicyFor :: ComponentId -> RetryPolicy
componentReadinessRetryPolicyFor component =
  case component of
    ComponentChartBootstrapBroker -> deploymentRevisionObservationRetryPolicy
    ComponentChartAuthorityBackup -> deploymentRevisionObservationRetryPolicy
    _ -> componentReadinessRetryPolicy

-- | Production one-shot target registry for every component the native home
-- reconcile mutates. Chart-only nodes are owned by ChartPlatform and fail
-- closed if accidentally routed through this driver.
nativeComponentReadinessTarget
  :: FilePath
  -> ValidatedSettings
  -> ComponentId
  -> Either Text.Text ComponentReadinessTarget
nativeComponentReadinessTarget repoRoot settings component =
  case component of
    ComponentClusterBase ->
      Right (ServiceActiveTarget component (observeRke2ServiceActiveOnce repoRoot))
    ComponentMinio ->
      Right
        ( RolloutCompleteTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                [StatefulSetReady minioNamespace minioReleaseName]
            )
        )
    ComponentVaultWorkload ->
      Right
        ( RolloutCompleteTarget
            component
            (observeKubernetesReadinessOnce repoRoot [StatefulSetReady vaultNamespace "vault"])
        )
    ComponentVaultUnsealed ->
      Right (VaultUnsealedTarget component (observeVaultUnsealedOnce repoRoot))
    ComponentRegistry ->
      Right
        ( BackendRoundTripTarget
            component
            ComponentMinio
            (observeRegistryBackendRoundTripOnce repoRoot)
        )
    ComponentMetalLB ->
      Right
        ( RolloutCompleteTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                ( [ DeploymentAvailable metallbNamespace "metallb-controller"
                  , DaemonSetReady metallbNamespace "metallb-speaker"
                  , CrdEstablished "ipaddresspools.metallb.io"
                  ]
                    ++ case configuredPublicEdgeAdvertisementMode settings of
                      "bgp" ->
                        [ CrdEstablished "bgppeers.metallb.io"
                        , CrdEstablished "bgpadvertisements.metallb.io"
                        ]
                      _ -> [CrdEstablished "l2advertisements.metallb.io"]
                )
            )
        )
    ComponentEnvoyGateway ->
      Right
        ( RolloutCompleteTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                [ DeploymentAvailable envoyGatewayNamespace envoyGatewayReleaseName
                , CrdEstablished "gatewayclasses.gateway.networking.k8s.io"
                , CrdEstablished "gateways.gateway.networking.k8s.io"
                , CrdEstablished "httproutes.gateway.networking.k8s.io"
                , CrdEstablished "envoyproxies.gateway.envoyproxy.io"
                , CrdEstablished "securitypolicies.gateway.envoyproxy.io"
                ]
            )
        )
    ComponentCertManager ->
      Right
        ( RolloutCompleteTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                [ DeploymentAvailable certManagerNamespace certManagerReleaseName
                , DeploymentAvailable certManagerNamespace (certManagerReleaseName ++ "-webhook")
                , DeploymentAvailable certManagerNamespace (certManagerReleaseName ++ "-cainjector")
                , CrdEstablished "clusterissuers.cert-manager.io"
                ]
            )
        )
    ComponentPerconaPostgresOperator -> operatorAvailableTarget component
    ComponentGatewayDaemonPreVault -> unsupportedNativeReadiness component
    ComponentGatewayDaemonFull ->
      Right (BackendRoundTripTarget component ComponentMinio observeGatewayBackendRoundTripOnce)
    ComponentChartPulsar -> unsupportedNativeReadiness component
    ComponentChartRedis -> unsupportedNativeReadiness component
    ComponentChartKeycloakPostgres -> unsupportedNativeReadiness component
    ComponentChartKeycloak -> unsupportedNativeReadiness component
    ComponentChartVscode -> unsupportedNativeReadiness component
    ComponentChartApi -> unsupportedNativeReadiness component
    ComponentChartWebsocket -> unsupportedNativeReadiness component
    ComponentChartGateway -> unsupportedNativeReadiness component
    ComponentChartBootstrapBroker ->
      Right
        ( ResourceExistsTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                [DeploymentRevisionObserved "bootstrap-broker" "bootstrap-broker"]
            )
        )
    ComponentChartLifecycleAuthority ->
      Right
        ( RolloutCompleteTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                [StatefulSetReady "lifecycle-authority" "lifecycle-authority"]
            )
        )
    ComponentChartProviderWorker ->
      deploymentRolloutTarget component "provider-worker" "provider-worker"
    ComponentChartAuthorityBackup ->
      Right
        ( RolloutCompleteTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                authorityBackupReadinessChecks
            )
        )
    ComponentChartTlsRetention ->
      deploymentRolloutTarget component "tls-retention" "tls-retention"
    ComponentChartTargetSecretAgent ->
      deploymentRolloutTarget component "target-secret-agent" "target-secret-agent"
 where
  deploymentRolloutTarget targetComponent namespace deployment =
    Right
      ( RolloutCompleteTarget
          targetComponent
          ( observeKubernetesReadinessOnce
              repoRoot
              [DeploymentAvailable namespace deployment]
          )
      )

-- | Exact requested-revision barrier between the no-wait Authority Backup
-- Helm mutation and the first authenticated backup request.
authorityBackupReadinessChecks :: [KubernetesReadinessCheck]
authorityBackupReadinessChecks =
  [ DeploymentRevisionObserved "authority-backup" "authority-backup"
  , DeploymentAvailable "authority-backup" "authority-backup"
  ]

unsupportedNativeReadiness :: ComponentId -> Either Text.Text value
unsupportedNativeReadiness component =
  Left
    ( Text.pack
        ( "Native reconcile has no readiness target for chart-owned component `"
            ++ componentIdText component
            ++ "`."
        )
    )

observeRke2ServiceActiveOnce :: FilePath -> IO (Either Text.Text ReadinessProbeResult)
observeRke2ServiceActiveOnce repoRoot = do
  result <- captureToolOutput repoRoot "systemctl" ["is-active", rke2ServiceName]
  pure $
    case result of
      Left err -> Left (Text.pack err)
      Right output ->
        let status = map toLower (trimWhitespace (processStdout output))
         in if status == "active"
              then Right ReadinessProbeReady
              else
                if status `elem` ["inactive", "activating", "deactivating", "failed"]
                  then Right (ReadinessProbePending (Text.pack ("systemd state is " ++ status)))
                  else case processExitCode output of
                    ExitSuccess ->
                      Right (ReadinessProbePending (Text.pack ("systemd state is " ++ status)))
                    ExitFailure _ -> Left (Text.pack (outputDetail output))

data KubernetesReadinessCheck
  = DeploymentAvailable String String
  | DeploymentRevisionObserved String String
  | StatefulSetReady String String
  | DaemonSetReady String String
  | CrdEstablished String
  deriving (Eq, Show)

observeKubernetesReadinessOnce
  :: FilePath
  -> [KubernetesReadinessCheck]
  -> IO (Either Text.Text ReadinessProbeResult)
observeKubernetesReadinessOnce repoRoot = go
 where
  go checks = case checks of
    [] -> pure (Right ReadinessProbeReady)
    check : remaining -> do
      result <- observeKubernetesCheckOnce repoRoot check
      case result of
        Right ReadinessProbeReady -> go remaining
        Right pending@(ReadinessProbePending _) -> pure (Right pending)
        Left reason -> pure (Left reason)

observeKubernetesCheckOnce
  :: FilePath
  -> KubernetesReadinessCheck
  -> IO (Either Text.Text ReadinessProbeResult)
observeKubernetesCheckOnce repoRoot check = do
  outputResult <- captureToolOutput repoRoot "kubectl" (kubernetesReadinessArguments check)
  pure $
    case outputResult of
      Left err -> Left (Text.pack err)
      Right output ->
        case processExitCode output of
          ExitFailure _ -> Left (Text.pack (outputDetail output))
          ExitSuccess -> classifyKubernetesReadiness check (trimWhitespace (processStdout output))

kubernetesReadinessArguments :: KubernetesReadinessCheck -> [String]
kubernetesReadinessArguments check =
  case check of
    DeploymentAvailable namespace name ->
      namespacedGetArguments
        "deployment"
        namespace
        name
        "jsonpath={.status.conditions[?(@.type==\"Available\")].status}"
    DeploymentRevisionObserved namespace name ->
      namespacedGetArguments
        "deployment"
        namespace
        name
        "jsonpath={.metadata.generation}:{.status.observedGeneration}:{.spec.replicas}:{.status.updatedReplicas}"
    StatefulSetReady namespace name ->
      namespacedGetArguments
        "statefulset"
        namespace
        name
        "jsonpath={.spec.replicas}:{.status.readyReplicas}:{.status.updatedReplicas}"
    DaemonSetReady namespace name ->
      namespacedGetArguments
        "daemonset"
        namespace
        name
        "jsonpath={.status.desiredNumberScheduled}:{.status.numberReady}:{.status.updatedNumberScheduled}"
    CrdEstablished name ->
      [ "get"
      , "crd"
      , name
      , "--ignore-not-found"
      , "-o"
      , "jsonpath={.status.conditions[?(@.type==\"Established\")].status}"
      ]

namespacedGetArguments :: String -> String -> String -> String -> [String]
namespacedGetArguments kind namespace name outputFormat =
  [ "get"
  , kind
  , name
  , "--namespace"
  , namespace
  , "--ignore-not-found"
  , "-o"
  , outputFormat
  ]

classifyKubernetesReadiness
  :: KubernetesReadinessCheck -> String -> Either Text.Text ReadinessProbeResult
classifyKubernetesReadiness check raw =
  case check of
    DeploymentAvailable _ _ -> conditionResult
    DeploymentRevisionObserved _ _ -> deploymentRevisionResult
    CrdEstablished _ -> conditionResult
    StatefulSetReady _ _ -> replicaResult
    DaemonSetReady _ _ -> replicaResult
 where
  conditionResult
    | map toLower raw == "true" = Right ReadinessProbeReady
    | otherwise = Right (pendingResult raw)
  replicaResult =
    case mapM readMaybe (splitOnColon raw) :: Maybe [Int] of
      Just [desired, ready, updated]
        | desired > 0 && ready >= desired && updated >= desired -> Right ReadinessProbeReady
      _ -> Right (pendingResult raw)
  deploymentRevisionResult =
    case mapM readMaybe (splitOnColon raw) :: Maybe [Int] of
      Just [generation, observedGeneration, desired, updated]
        | generation > 0
            && observedGeneration == generation
            && desired > 0
            && updated >= desired ->
            Right ReadinessProbeReady
      _ -> Right (pendingResult raw)
  pendingResult detail =
    ReadinessProbePending
      ( Text.pack
          ( show check
              ++ " is not ready"
              ++ if null detail then "" else ": " ++ detail
          )
      )

splitOnColon :: String -> [String]
splitOnColon value =
  case break (== ':') value of
    (prefix, []) -> [prefix]
    (prefix, _ : remaining) -> prefix : splitOnColon remaining

observeVaultUnsealedOnce :: FilePath -> IO (Either Text.Text ReadinessProbeResult)
observeVaultUnsealedOnce repoRoot =
  classifyBrokerVaultUnsealedStatus <$> observeBrokerVaultSealStatus repoRoot

classifyBrokerVaultUnsealedStatus
  :: Either String BrokerVaultSealStatus
  -> Either Text.Text ReadinessProbeResult
classifyBrokerVaultUnsealedStatus observed = case observed of
  Left detail -> Left (Text.pack detail)
  Right status
    | brokerVaultStatusInitializationAmbiguous status ->
        Left "Bootstrap Broker reports ambiguous Vault initialization"
    | not (brokerVaultStatusInitialized status) ->
        Right (ReadinessProbePending "Bootstrap Broker reports Vault uninitialized")
    | brokerVaultStatusSealed status ->
        Right (ReadinessProbePending "Bootstrap Broker reports Vault sealed")
    | otherwise -> Right ReadinessProbeReady

-- | Sprint 1.76: the registry deep probe now mints a real witness. The probe
-- POSTs a blob-upload session, which the registry can only create by writing
-- through to its MinIO storage backend; the session identifier the registry
-- returns is the receipt of that write. A 2xx that names no session is NOT a
-- round trip and fails closed, where before any 201/202 was accepted and the
-- receipt discarded.
observeRegistryBackendRoundTripOnce
  :: FilePath -> IO (Either Text.Text BackendRoundTripResult)
observeRegistryBackendRoundTripOnce repoRoot = do
  probed <- probeRegistryStorageBackendEdge repoRoot
  landedAt <- readinessWallClockNow
  pure $
    case classifyRegistryStorageEdgeProbe (fmap registryProbeStatus probed) of
      RegistryEdgeNotReady detail -> Right (BackendRoundTripPending (Text.pack detail))
      RegistryEdgeUnreachable detail -> Left (Text.pack detail)
      RegistryEdgeReady ->
        case probed of
          Left detail -> Left (Text.pack detail)
          Right observation ->
            case registryBackendWitness
              (Text.pack (registryProbeUploadSession observation))
              landedAt of
              Nothing ->
                Right
                  ( BackendRoundTripPending
                      "registry accepted the upload but named no storage-backend session"
                  )
              Just witness -> Right (BackendRoundTripConfirmed witness)

observeGatewayBackendRoundTripOnce :: IO (Either Text.Text BackendRoundTripResult)
observeGatewayBackendRoundTripOnce = do
  endpoint <- gatewayEndpointFromEnv
  observeGatewayBackendRoundTripOnceAt endpoint

-- | Sprint 1.76: the gateway deep probe stops treating a constant-time
-- @\/readyz@ GET as proof of a backend write.
--
-- @\/readyz@ is kept as the liveness precondition it genuinely is — a daemon
-- that is draining or still starting has nothing to say about the backend edge —
-- and the EVIDENCE now comes from the receipt the daemon recorded when its own
-- conditional continuity write was accepted by the shared object store. The
-- daemon performs that write on every heartbeat publication, so a healthy daemon
-- refreshes the receipt continuously and a wedged one stops, which is exactly
-- the distinction the freshness window is there to make.
observeGatewayBackendRoundTripOnceAt
  :: PeerEndpoint -> IO (Either Text.Text BackendRoundTripResult)
observeGatewayBackendRoundTripOnceAt endpoint = do
  result <- probeGatewayFullModeOnceAt endpoint
  case result of
    GatewayFullModeNotReady detail ->
      pure
        ( Right
            ( BackendRoundTripPending
                (Text.pack ("gateway continuity is not ready: " ++ detail))
            )
        )
    GatewayFullModeTransient detail -> pure (Left (Text.pack detail))
    GatewayFullModeHealthy -> do
      observed <- GatewayClient.queryBackendRoundTrip endpoint
      pure $
        case observed of
          Left err -> Left (Text.pack (GatewayClient.renderGatewayError err))
          Right GatewayClient.GatewayBackendRoundTripAbsent ->
            Right
              ( BackendRoundTripPending
                  "gateway has not yet landed an object-store round trip"
              )
          Right (GatewayClient.GatewayBackendRoundTripWitnessed witness) ->
            Right (BackendRoundTripConfirmed witness)

-- | Sprint 2.34: observe the daemon's kubelet @/readyz@ once, as the lifecycle
-- gate's precheck. A 200 is ready; a 503 (@draining@/@starting@) is
-- not-ready-yet with the body; a transport failure is unreachable (fail
-- closed). Pairs with 'observeGatewayBackendRoundTripOnceAt' so lifecycle-ready
-- implies kubelet-ready by construction.
observeGatewayReadyzOnceAt
  :: PeerEndpoint -> IO (Either Text.Text ReadinessProbeResult)
observeGatewayReadyzOnceAt endpoint = do
  probe <- GatewayClient.queryReadyz endpoint
  pure $
    case probe of
      GatewayClient.GatewayReadyzReady -> Right ReadinessProbeReady
      GatewayClient.GatewayReadyzNotReady code body ->
        Right
          ( ReadinessProbePending
              (Text.pack ("gateway /readyz reported HTTP " ++ show code ++ ": " ++ takeWhile (/= '\n') body))
          )
      GatewayClient.GatewayReadyzUnreachable detail -> Left (Text.pack detail)

-- | Drive genesis or backup repair through the retained Authority fold, the
-- attested AWS-admin Credential Provisioner Job, and the physically separate
-- Authority Backup Adapter before config/provider/DNS effects may run.
requireEstablishedAuthorityBackupAdmission :: FilePath -> ValidatedSettings -> IO ExitCode
requireEstablishedAuthorityBackupAdmission repoRoot settings = do
  basicsResult <- loadUnencryptedBasics repoRoot
  imageResult <- resolveRuntimeChartImageForSubstrate SubstrateHomeLocal
  now <- round . (* 1000000) <$> getPOSIXTime
  case (basicsResult, imageResult) of
    (Left detail, _) -> failWith detail
    (_, Left detail) -> failWith detail
    (Right basics, Right (Just image)) ->
      case authorityBackupRuntimeInputs repoRoot basics settings image now of
        Left detail -> failWith detail
        Right (coordinate, intentParameters, kubernetes) -> do
          reconciled <-
            withHostLifecycleAuthorityAuthentication
              LifecycleAuthorityOperator
              repoRoot
              ( \authentication ->
                  withLifecycleAuthorityAuthenticatedTransport authentication $ \authorityTransport ->
                    withAuthorityBackupAuthenticatedTransport authentication $ \backupTransport -> do
                      let provisionerClient = awsAdminProvisionerClient authorityTransport
                          loadCredentials =
                            either (Left . Text.pack) Right
                              <$> loadAdminAwsCredentials repoRoot
                          boundary =
                            productionAuthorityBackupReconcileBoundary
                              (basicsClusterId basics)
                              coordinate
                              authorityTransport
                              (authorityControlClientWithTransport authorityTransport)
                              (authorityBackupExportClient authorityTransport)
                              (authorityAggregateBackupClientWithTransport backupTransport)
                              provisionerClient
                              kubernetes
                              loadCredentials
                              intentParameters
                      admission <- reconcileAuthorityBackupAdmission boundary
                      case admission of
                        Left err ->
                          pure (Left ("Authority backup admission reconciliation failed: " ++ show err))
                        Right ready@(AuthorityBackupAdmissionReady _) -> do
                          continuation <-
                            reconcileRemainingFirstReconcileCredentials
                              provisionerClient
                              kubernetes
                              loadCredentials
                              intentParameters
                              (firstReconcileIamParameters basics settings)
                          pure $ case continuation of
                            Left detail ->
                              Left ("First-reconcile credential continuation failed: " ++ Text.unpack detail)
                            Right () -> Right ready
                        Right frozen -> pure (Right frozen)
              )
          case reconciled of
            Left err -> failWith (renderLifecycleAuthorityAuthenticationError err)
            Right (Left err) -> failWith (renderLifecycleAuthorityAuthenticationError err)
            Right (Right (Left err)) -> failWith (renderLifecycleAuthorityAuthenticationError err)
            Right (Right (Right (Left detail))) -> failWith detail
            Right (Right (Right (Right (AuthorityBackupAdmissionReady _)))) -> pure ExitSuccess
            Right (Right (Right (Right (AuthorityBackupAdmissionFrozen _ health)))) ->
              failWith
                ( "Authority backup admission remains safely frozen after "
                    ++ show health
                    ++ "; no config or normal lifecycle work was started."
                )
    (_, Right Nothing) ->
      failWith "The pinned runtime image is unavailable for the Credential Provisioner Job."

authorityBackupRuntimeInputs
  :: FilePath
  -> UnencryptedBasics
  -> ValidatedSettings
  -> ResolvedCustomImage
  -> Natural
  -> Either
       String
       ( Text.Text
       , GenesisAwsAdminIntentParameters
       , AwsAdminKubernetesBoundary IO
       )
authorityBackupRuntimeInputs repoRoot basics settings image heartbeat = do
  manifestDigest <-
    maybe
      (Left "The runtime image has no immutable repository manifest digest.")
      Right
      (resolvedCustomImageManifestDigest image)
  selectedAgent <-
    resolvedCustomImageTargetAgentIdentity (basicsClusterId basics) image
  let resources = oneShotAwsAdminJobResources
  let backend = pulumi_state_backend (validatedConfig settings)
      coordinate = "authority-backup-store/" <> basicsClusterId basics
  iamParameters <-
    either
      (Left . show)
      Right
      ( mkAuthorityBackupIamParameters
          (psbRegion backend)
          (psbBucketName backend)
          [coordinate]
      )
  let connection =
        CredentialProvisionerJobConnection
          { credentialProvisionerJobEnvironment = Nothing
          , credentialProvisionerJobWorkingDirectory = repoRoot
          , credentialProvisionerJobControllerSubject =
              Just (externalCallerKubernetesSubject LifecycleAuthorityOperator)
          }
      deadline = authorityTimeFromMicros (heartbeat + 30 * 60 * 1000000)
      parameters =
        GenesisAwsAdminIntentParameters
          { genesisIntentIamParameters = iamParameters
          , genesisIntentImageDigest = Text.pack manifestDigest
          , genesisIntentAuthorityScope = basicsClusterId basics
          , genesisIntentAuthorityEndpoint =
              -- Sprint 3.35: the port is the compiled owner. The host form is
              -- deliberately the short `.svc` one this call site has always
              -- used, not `controlPlaneClusterServiceUrl`'s FQDN — binding the
              -- port is the drift this sprint closes; changing a resolvable
              -- host form is a behaviour change it does not make.
              Text.pack
                ( "http://lifecycle-authority.lifecycle-authority.svc:"
                    ++ show controlPlaneListenPort
                )
          , genesisIntentSelectedAgent = selectedAgent
          , genesisIntentDeadline = deadline
          }
      kubernetes =
        productionAwsAdminKubernetesBoundary
          connection
          ( Text.pack
              (resolvedCustomImageRepository image ++ ":" ++ resolvedCustomImageTag image)
          )
          resources
          currentAwsAdminJobHeartbeat
  Right (coordinate, parameters, kubernetes)

currentAwsAdminJobHeartbeat :: IO (Either Text.Text Natural)
currentAwsAdminJobHeartbeat = do
  attempted <- try getPOSIXTime :: IO (Either IOException POSIXTime)
  pure $ case attempted of
    Left _ -> Left "AWS-admin Job heartbeat clock is unavailable"
    Right posix ->
      Right
        ( fromInteger
            (max 0 (floor (toRational posix * 1000000) :: Integer))
        )

-- | Refresh the harness's operational Lifecycle-provider credential through
-- the authenticated, attested Credential Provisioner. The operation scope is
-- stable for a qualification cycle. If a response is lost after Target
-- material advances, the matching retained Authority operation is recovered
-- byte-for-byte instead of allocating another generation.
reconcileHarnessLifecycleProviderCredential
  :: FilePath
  -> Text.Text
  -> IO ExitCode
reconcileHarnessLifecycleProviderCredential repoRoot operationScope = do
  settingsResult <- validateAndLoadSettings repoRoot
  basicsResult <- loadUnencryptedBasics repoRoot
  imageResult <- resolveRuntimeChartImageForSubstrate SubstrateHomeLocal
  adminResult <- loadAdminAwsCredentials repoRoot
  now <- round . (* 1000000) <$> getPOSIXTime
  case (settingsResult, basicsResult, imageResult, adminResult) of
    (Left detail, _, _, _) -> failWith detail
    (_, Left detail, _, _) -> failWith detail
    (_, _, Left detail, _) -> failWith detail
    (_, _, Right Nothing, _) ->
      failWith "The pinned runtime image is unavailable for the Credential Provisioner Job."
    (_, _, _, Left detail) -> failWith detail
    (Right settings, Right basics, Right (Just image), Right adminCredentials) ->
      case authorityBackupRuntimeInputs repoRoot basics settings image now of
        Left detail -> failWith detail
        Right (_, parameters, kubernetes) -> do
          iamResult <-
            firstReconcileIamParameters
              basics
              settings
              adminCredentials
              LifecycleProviderCredential
          case iamResult of
            Left detail -> failWith (Text.unpack detail)
            Right iamParameters -> do
              reconciled <-
                withHostLifecycleAuthorityAuthentication
                  LifecycleAuthorityTestHarness
                  repoRoot
                  ( \authentication -> do
                      targetResult <-
                        withTargetSecretAgentAuthenticatedTransport authentication $ \transport ->
                          observeRegisteredTargetMaterial
                            (targetMaterialClient transport)
                            (TargetAwsCredential AwsLifecycleProvider)
                      case targetResult of
                        Left err ->
                          pure (Left (renderLifecycleAuthorityAuthenticationError err))
                        Right (Left err) ->
                          pure (Left ("observe Lifecycle-provider Target generation: " ++ show err))
                        Right (Right observedTarget) -> do
                          authorityResult <-
                            withLifecycleAuthorityAuthenticatedTransport authentication $ \transport -> do
                              let client = awsAdminProvisionerClient transport
                              intentResult <-
                                resolveHarnessLifecycleProviderIntent
                                  client
                                  parameters
                                  operationScope
                                  iamParameters
                                  observedTarget
                              case intentResult of
                                Left detail -> pure (Left detail)
                                Right intent -> do
                                  coordinated <-
                                    coordinateAwsAdminProvisioning
                                      client
                                      kubernetes
                                      adminCredentials
                                      intent
                                  pure $ case coordinated of
                                    Left err -> Left ("coordinate Lifecycle-provider credential: " ++ show err)
                                    Right _ ->
                                      Right
                                        ( credentialGenerationValue
                                            (awsAdminPermitIntentGeneration intent)
                                        )
                          pure $ case authorityResult of
                            Left err -> Left (renderLifecycleAuthorityAuthenticationError err)
                            Right outcome -> outcome
                  )
              case reconciled of
                Left err -> failWith (renderLifecycleAuthorityAuthenticationError err)
                Right (Left detail) -> failWith detail
                Right (Right generation) -> do
                  writeOutputLine
                    ( "Lifecycle-provider credential is current through the authenticated Credential Provisioner at generation "
                        ++ show generation
                        ++ "."
                    )
                  pure ExitSuccess

resolveHarnessLifecycleProviderIntent
  :: AwsAdminProvisionerClient IO
  -> GenesisAwsAdminIntentParameters
  -> Text.Text
  -> CredentialIamParameters
  -> Maybe TargetMaterialObservation
  -> IO (Either String AwsAdminPermitIntent)
resolveHarnessLifecycleProviderIntent client parameters operationScope iamParameters observedTarget = do
  let observedGeneration = maybe 1 targetMaterialObservedGeneration observedTarget
  case normalAwsAdminOperationIdForScope
    operationScope
    LifecycleProviderCredential
    observedGeneration of
    Left detail -> pure (Left (Text.unpack detail))
    Right operationId -> do
      existing <- observeAwsAdminProvisioning client operationId
      case existing of
        Right observation ->
          pure
            ( decodeAndValidateHarnessLifecycleProviderIntent
                observedGeneration
                observation
            )
        Left (AwsAdminProvisionerClientRefused "operation-not-found") ->
          pure $ do
            let (action, generation) = case observedTarget of
                  Nothing -> (InstallOperatorMaterial, 1)
                  Just target ->
                    ( RotateOperatorMaterial
                    , targetMaterialObservedGeneration target + 1
                    )
            firstText
              ( compileNormalAwsAdminIntentForScope
                  parameters
                  operationScope
                  LifecycleProviderCredential
                  action
                  generation
                  iamParameters
              )
        Left err ->
          pure (Left ("observe retained Lifecycle-provider credential operation: " ++ show err))
 where
  firstText = Bifunctor.first Text.unpack

decodeAndValidateHarnessLifecycleProviderIntent
  :: Natural
  -> AwsAdminProvisionerObservation
  -> Either String AwsAdminPermitIntent
decodeAndValidateHarnessLifecycleProviderIntent expectedGeneration observation = do
  intent <-
    Bifunctor.first
      show
      ( decodeAwsAdminPermitIntent
          (awsAdminChallengeCanonicalIntent (awsAdminObservedChallenge observation))
      )
  if awsAdminPermitIntentCredentialClass intent == LifecycleProviderCredential
    then Right ()
    else Left "retained harness credential operation names a different credential class"
  if credentialGenerationValue (awsAdminPermitIntentGeneration intent) == expectedGeneration
    then Right ()
    else Left "retained harness credential operation names a different Target generation"
  case awsAdminPermitIntentAction intent of
    InstallOperatorMaterial -> Right intent
    RotateOperatorMaterial -> Right intent
    RevokeOperatorMaterial ->
      Left "retained harness credential operation is a revocation, not an install or rotation"

firstReconcileIamParameters
  :: UnencryptedBasics
  -> ValidatedSettings
  -> Credentials
  -> AwsCredentialClass
  -> IO (Either Text.Text CredentialIamParameters)
firstReconcileIamParameters _basics settings credentials credentialClass =
  case credentialClass of
    LifecycleProviderCredential -> do
      accountResult <- adminCredentialAccountId credentials
      pure $ do
        accountId <- accountResult
        firstText
          ( mkLifecycleProviderIamParameters
              backendRegion
              accountId
              "prodbox-lifecycle-provider"
          )
    AuthorityBackupStoreCredential ->
      pure (Left "authority-backup install is valid only as first-reconcile member zero")
    TlsRetentionStoreCredential ->
      pure $ do
        -- Sprint 1.83: the carried parse, not a third derivation of it.
        scopeSet <- firstText (requireSubstrateCertScopeSet settings SubstrateHomeLocal)
        firstText
          ( mkTlsRetentionIamParameters
              backendRegion
              backendBucket
              [Text.pack (publicEdgeTlsRetentionKey SubstrateHomeLocal scopeSet)]
          )
    GatewayDnsCredential ->
      pure
        ( firstText
            (mkGatewayDnsIamParameters backendRegion homeZoneId)
        )
    HomeCertManagerDns01Credential ->
      pure
        ( firstText
            (mkHomeDns01IamParameters backendRegion homeZoneId)
        )
    AwsRunCertManagerDns01Credential ->
      pure (Left "AWS-run DNS01 identity is not a home first-reconcile member")
    SesSmtpRetainedCustodyCredential ->
      pure (Left "SES SMTP custody is not a home first-reconcile member")
 where
  coordinates = validatedCoordinates settings
  -- Sprint 1.89: both coordinates come from the parsed projection. Neither had
  -- a shape rule before: `pulumi_state_backend.region` had no validation at all
  -- and `route53.zone_id` had only an emptiness check on the AWS tier, so this
  -- IAM parameter pair was assembled from two entirely undecided strings.
  backendRegion = maybe Text.empty awsRegionText (coordinatePulumiBackendRegion coordinates)
  backendBucket = maybe Text.empty s3BucketNameText (coordinatePulumiBackendBucket coordinates)
  homeZoneId = maybe Text.empty route53ZoneIdText (coordinateHomeZoneId coordinates)
  firstText :: (Show err) => Either err value -> Either Text.Text value
  firstText = either (Left . Text.pack . show) Right

adminCredentialAccountId :: Credentials -> IO (Either Text.Text Text.Text)
adminCredentialAccountId credentials =
  case baseCredentialHandleFromSettings credentials of
    Left err -> pure (Left (Text.pack (show err)))
    Right handle -> do
      observed <- NativeSts.getCallerIdentity (NativeSts.newStsClient handle httpSend)
      pure $ case observed of
        Left err -> Left (Text.pack (show err))
        Right identity -> Right (NativeSts.callerIdentityAccount identity)

loadPostMinioLifecycleSettings :: FilePath -> IO (Either String ValidatedSettings)
loadPostMinioLifecycleSettings = validateAndLoadSettings

-- | The AWS-gated public-edge reconcile, factored out of the local cluster
-- plan (Phase 2). Fails fast naming @prodbox aws setup@ when operational
-- @aws.*@ is empty, then applies the ZeroSSL DNS-01 ClusterIssuer. Gateway
-- DNS is owned exclusively by the Lifecycle Authority-backed exact-record
-- reconciler; this cluster bootstrap path must not write Route 53 records.
applyPublicEdgeReconcile :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
applyPublicEdgeReconcile repoRoot settings prodboxId labelValue =
  case validateOperationalAwsCredentials (validatedConfig settings) of
    Left err ->
      failWith
        ( err
            ++ " The public edge needs operational AWS credentials for Route 53"
            ++ " DNS + ZeroSSL TLS. Run `prodbox aws setup`, then re-run with"
            ++ " `--with-edge`."
        )
    Right () -> ensureAcmeRuntime repoRoot settings prodboxId labelValue

-- | Sprint 4.26: the Plan for @prodbox cluster delete@ (default and
-- @--cascade@). The payload is the 'Rke2DeleteFlags' so the apply closure
-- branches on @--cascade@ / @--allow-pulumi-residue@ exactly as the dispatch
-- arm used to; the rendered plan is the operator-visible destructive
-- sequence so @--dry-run@ shows the full teardown without mutating.
buildNativeDeletePlan :: FilePath -> Rke2DeleteFlags -> Plan Rke2DeleteFlags
buildNativeDeletePlan repoRoot =
  buildPlan (renderNativeDeletePlan repoRoot)

-- | Sprint 4.26: render the destructive @cluster delete@ plan. The cascade
-- variant renders the canonical phase order (confirm-MinIO → drain →
-- per-run destroys → test-EBS reaper → uninstall → sweep); the default variant
-- renders the refuse-gate + per-run sweep + cluster-substrate removal. Both list the
-- per-run stacks from the managed-resource registry SSoT
-- ('ResourceRegistry.perRunManagedResources'), so the rendered plan can
-- never omit a per-run stack (closing the historical @aws-eks-subzone@
-- gap on the default-delete path).
renderNativeDeletePlan :: FilePath -> Rke2DeleteFlags -> String
renderNativeDeletePlan repoRoot flags
  | rke2DeleteCascade flags =
      unlines
        ( [ "RKE2_DELETE_CASCADE_PLAN"
          , "REPO_ROOT=" ++ repoRoot
          , "MODE=cascade"
          , "NARRATION=" ++ cascadeOrderNarration
          , "STEP=ensure_host_inotify_limits"
          , "STEP=confirm_minio_per_run_residue"
          , "STEP=k8s_drain"
          ]
            ++ [ "STEP=per_run_destroy " ++ ResourceRegistry.resourceName resource
               | resource <- ResourceRegistry.perRunManagedResources
               ]
            ++ [ "STEP=test_ebs_reaper"
               , "STEP=delete_rke2_cluster_substrate"
               , "STEP=remove_calico_endpoint_status_residue"
               , "STEP=remove_managed_kubeconfig"
               , "STEP=host_firewall_gateway_unrestrict"
               , "STEP=render_retained_state_notice"
               , "STEP=postflight_tag_sweep"
               ]
        )
  | otherwise =
      -- Default `cluster delete` is a PURE LOCAL UNINSTALL: it never
      -- queries, gates on, or destroys the per-run AWS Pulumi backend.
      -- Deleting the cluster preserves `.data/`, so per-run state + any
      -- AWS resources stay fully reasoned-about afterward. All per-run AWS
      -- destruction lives in `--cascade` (or `prodbox aws stack <name>
      -- destroy`).
      unlines
        [ "RKE2_DELETE_PLAN"
        , "REPO_ROOT=" ++ repoRoot
        , "MODE=default"
        , "STEP=ensure_host_inotify_limits"
        , "STEP=delete_rke2_cluster_substrate"
        , "STEP=remove_calico_endpoint_status_residue"
        , "STEP=remove_managed_kubeconfig"
        , "STEP=host_firewall_gateway_unrestrict"
        , "STEP=render_retained_state_notice"
        ]

-- | Sprint 4.26: the apply closure for @prodbox cluster delete@. Performs the
-- effects @--dry-run@ deliberately skips: the no-RKE2-install
-- short-circuit, the inotify-limit host prep, and either the cascade
-- reconciler (@--cascade@) or the refuse-gate default path.
-- | Sprint 4.88: whether an RKE2 install is present, as a value rather than a
-- bare 'Bool', so the entry table below is a total function over a named
-- product instead of a nested @if@.
data Rke2InstallPresence
  = Rke2Installed
  | Rke2NotInstalled
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | Sprint 4.88: the terminal arm a @cluster delete@ invocation selects before
-- any phase runs.
--
-- The no-install short-circuit used to be selected by install presence alone,
-- so a @--cascade@ that observed nothing at all returned @ExitSuccess@ — and an
-- operator reading exit @0@ from a cascade has been told the cascade ran. Local
-- RKE2 absence is not per-run AWS absence, and doctrine § 5a gives the
-- no-install success arm to the local-only mode alone.
data DeleteTerminalArm
  = -- | Local-only mode, nothing installed: there is genuinely nothing to
    -- uninstall and no claim is made about anything else.
    DeleteArmLocalOnlyNoInstall
  | -- | Local-only mode, an install was present and was uninstalled.
    DeleteArmLocalOnlyUninstalled
  | -- | Cascade mode, nothing installed. The cascade could not reach the
    -- durable cleanup namespace, so it reports what it did not establish
    -- rather than returning success.
    DeleteArmCascadeNoInstall
  | -- | Cascade mode, an install was present and the phases ran.
    DeleteArmCascadeReachedPhases
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | Pure: the entry table over delete mode and install presence.
--
-- Exactly one arm is a no-install success, and it is selected by the local-only
-- mode, so the cascade mode cannot reach it and cannot be given it by a later
-- caller.
selectDeleteEntryArm :: DeleteMode -> Rke2InstallPresence -> DeleteTerminalArm
selectDeleteEntryArm mode presence = case (mode, presence) of
  (DeleteModeLocalUninstall, Rke2NotInstalled) -> DeleteArmLocalOnlyNoInstall
  (DeleteModeLocalUninstall, Rke2Installed) -> DeleteArmLocalOnlyUninstalled
  (DeleteModeCascade, Rke2NotInstalled) -> DeleteArmCascadeNoInstall
  (DeleteModeCascade, Rke2Installed) -> DeleteArmCascadeReachedPhases

-- | Pure: whether an arm's exit status may be zero on the no-install path.
deleteArmIsNoInstallSuccess :: DeleteTerminalArm -> Bool
deleteArmIsNoInstallSuccess arm = case arm of
  DeleteArmLocalOnlyNoInstall -> True
  DeleteArmLocalOnlyUninstalled -> False
  DeleteArmCascadeNoInstall -> False
  DeleteArmCascadeReachedPhases -> False

-- | Sprint 4.88: what a terminal arm may say about the retained root.
--
-- The retained-state notice is the only place the supported surface mentions
-- the store an operator might then delete, so its licence sentence is a claim
-- and not a convenience.
data RetainedStateNarration
  = -- | The run reached no delete path and observed nothing, so it says
    -- nothing about the store either.
    RetainedStateSilent
  | -- | An explicit local-only uninstall, or a path carrying a completion
    -- receipt. Only these may say the store is preserved.
    RetainedStatePreserved
  | -- | A path that reached a delete route without a completion receipt. It
    -- names the store and names what this run did not observe.
    RetainedStateUnproven
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | Pure and total over the arm universe: a new arm with no narration fails to
-- compile rather than silently rendering nothing.
retainedStateNarrationFor :: DeleteTerminalArm -> RetainedStateNarration
retainedStateNarrationFor arm = case arm of
  DeleteArmLocalOnlyNoInstall -> RetainedStateSilent
  DeleteArmLocalOnlyUninstalled -> RetainedStatePreserved
  DeleteArmCascadeNoInstall -> RetainedStateSilent
  -- The legacy cascade carries no completion receipt, so it may not license
  -- retiring the store. Sprint `6.5` activates the replacement that does.
  DeleteArmCascadeReachedPhases -> RetainedStateUnproven

applyNativeDelete :: FilePath -> Rke2DeleteFlags -> IO ExitCode
applyNativeDelete repoRoot flags = do
  -- The residue gate's fail-closed case (an unreachable in-cluster MinIO
  -- backend) is indistinguishable from "cluster already gone", which is why
  -- install presence is read before it. What changed in Sprint 4.88 is that
  -- presence alone no longer decides the arm: the mode does.
  present <- rke2InstallPresent
  let presence = if present then Rke2Installed else Rke2NotInstalled
      mode =
        if rke2DeleteCascade flags
          then DeleteModeCascade
          else DeleteModeLocalUninstall
  case selectDeleteEntryArm mode presence of
    DeleteArmLocalOnlyNoInstall -> do
      writeOutputLine noRke2ClusterMessage
      pure ExitSuccess
    DeleteArmCascadeNoInstall -> runCascadeNoInstallRefusal
    arm ->
      -- Raise the host inotify limits BEFORE systemd unwinds the
      -- RKE2 units during teardown, so PID 1 does not log
      -- `Failed to allocate directory watch: Too many open files`
      -- to the console (see streaming_doctrine.md § 6). Idempotent
      -- and shared with reconcile; covers both delete paths.
      runSequentially
        [ ensureHostInotifyLimits repoRoot
        , case arm of
            DeleteArmCascadeReachedPhases -> runNativeDeleteCascade repoRoot
            _ -> runNativeLocalUninstall repoRoot
        ]

-- | Sprint 4.88: the cascade's no-install terminal arm.
--
-- It names the durable cleanup namespace it could not reach and the
-- recovery-plane disposition it reports, and deliberately makes no statement
-- about AWS: this run observed no stack, so it has no absence to report and no
-- presence either.
runCascadeNoInstallRefusal :: IO ExitCode
runCascadeNoInstallRefusal = do
  writeDiagnosticLine
    ( "cluster delete --cascade reached no phase: no local RKE2 install is "
        ++ "present, so the retained local Lifecycle Authority that owns the "
        ++ "durable cleanup run namespace could not be reached. Recovery-plane "
        ++ "disposition: "
        ++ show RecoveryPlaneNotEstablished
        ++ "."
    )
  writeDiagnosticLine
    ( "This exit makes no claim about per-run AWS stacks: nothing was "
        ++ "observed. Restore the retained local control plane and retry, or "
        ++ "destroy a named stack directly with `prodbox aws stack <name> "
        ++ "destroy --yes`."
    )
  pure (ExitFailure 1)

-- | Default @prodbox cluster delete@: a PURE LOCAL UNINSTALL. It does NOT
-- query, gate on, or destroy the per-run AWS Pulumi backend — deleting the
-- cluster preserves @.data/@, so the per-run state and any AWS resources
-- remain fully reasoned-about and destroyable afterward. All per-run AWS
-- destruction lives in 'runNativeDeleteCascade' (or @prodbox aws stack
-- <name> destroy@).
runNativeLocalUninstall :: FilePath -> IO ExitCode
runNativeLocalUninstall repoRoot = do
  retainedManualPvRoot <- resolveRetainedManualPvRoot repoRoot
  writeOutputLine "Uninstalling the local cluster..."
  runSequentially
    [ deleteRke2ClusterSubstrate repoRoot
    , removeCalicoEndpointStatusResidue
    , removeManagedKubeconfig
    , runHostFirewallGatewayUnrestrict defaultGatewayNodePort
    , renderRetainedStateNotice DeleteArmLocalOnlyUninstalled retainedManualPvRoot
    ]

-- | Sprint 4.76: which form of @prodbox cluster delete@ is running.
-- Narration that differs between the two forms takes this rather than
-- re-deriving it from 'Rke2DeleteFlags' at each site.
data DeleteMode
  = DeleteModeLocalUninstall
  | DeleteModeCascade
  deriving (Eq, Show)

-- | Sprint 4.17.a + 4.40 canonical cascade order:
-- confirm-MinIO → drain → per-run destroys → test-EBS reaper → uninstall → sweep.
-- Per @documents/engineering/lifecycle_reconciliation_doctrine.md §5b@
-- the K8s drain runs **before** any per-run Pulumi destroy so the
-- in-cluster controllers (AWS Load Balancer Controller, EBS CSI driver,
-- cert-manager) unwind their AWS-side ENIs / ALBs / EBS volumes while
-- still alive. Per-run destroys then delete the underlying network
-- substrate (VPC, subnets, EKS cluster) without tripping on orphan
-- controller-owned dependencies. On the home substrate the order is
-- equivalent either way because no in-cluster controllers create AWS
-- resources; on the AWS substrate the pre-Sprint-4.17.a inverted order
-- (destroys → drain) produced @DependencyViolation@ on subnet deletion
-- because controller-owned ENIs blocked the destroy.
--
-- Skip-is-success invariants:
--
-- * Per-run destroys (Sprint 4.16): when a stack reports
--   'ResidueAbsent' (today via the file-existence adapter, tomorrow via
--   @pulumi stack ls --json@ against MinIO), its destroy is skipped.
--   When MinIO is unreachable a future swap of the adapter will return
--   'ResidueUnreachable' which 'isResiduePresent' treats as absent —
--   the per-run state died with the cluster.
-- * K8s drain (Sprint 4.15): on the home substrate, when the local
--   Kubernetes cluster is absent, the drain phase emits 'DrainSkipped'
--   and the cascade continues — there are no in-cluster controllers
--   creating AWS resources, so nothing to drain. Sprint 4.17.b adds the
--   substrate-aware drain that targets the EKS cluster's kubeconfig on
--   @SubstrateAws@; on AWS, 'DrainSkipped' becomes a hard failure
--   because the source of the AWS resources the per-run destroys would
--   need to delete is exactly the cluster the drain failed to reach.
-- * Postflight tag sweep: failure to query the AWS Resource Tagging
--   API is reported as a diagnostic but does not fail the cascade —
--   the operator-named cascade phrase only promises that the cascade
--   *ran* the sweep; resolving residue is operator work.
-- | Sprint 4.17.a + 4.40: the operator-facing narration string for the canonical
-- cascade phase order. Exposed as a top-level constant so unit tests can pin
-- the drain-before-destroys and test-EBS-reaper order without re-implementing
-- it. The order text must match the doctrine table at
-- @documents/engineering/lifecycle_reconciliation_doctrine.md §5b@.
cascadeOrderNarration :: String
cascadeOrderNarration =
  "rke2 delete --cascade: confirm-MinIO → drain → per-run destroys → test-EBS reaper → uninstall → sweep"

-- | Sprint 4.76: one cascade phase's name and verdict. The cascade folds
-- these rather than short-circuiting, because
-- @lifecycle_reconciliation_doctrine.md § 5b@ / § 5c require that a
-- failed or skipped earlier phase neither suppress a later independent
-- phase's attempt nor be erased by that attempt's success — "both
-- outcomes remain in the aggregate report".
data CascadePhaseOutcome = CascadePhaseOutcome
  { cascadePhaseName :: String
  , cascadePhaseExit :: ExitCode
  , cascadePhaseDerivedFrom :: Maybe String
  -- ^ Sprint 4.82: the phase whose failure caused this one, when it did.
  --
  -- One unobservable authority used to produce two failed phases that read as
  -- peers: @Unresolved phase(s): confirm-MinIO, drain@ presents a single cause
  -- as two independent problems, and an operator cannot tell from that line
  -- whether they have one fault or two. Class-D distinguishability,
  -- @chaos_hardening_doctrine.md § 21@ — the outcome type could not express
  -- @failed because an earlier phase could not be observed@, so it did not.
  }
  deriving (Eq, Show)

-- | A phase that failed on its own merits.
independentPhase :: String -> ExitCode -> CascadePhaseOutcome
independentPhase name exit =
  CascadePhaseOutcome
    { cascadePhaseName = name
    , cascadePhaseExit = exit
    , cascadePhaseDerivedFrom = Nothing
    }

-- | A phase whose failure is downstream of another phase's. The edge is only
-- recorded when this phase actually failed AND the named phase failed; a
-- succeeding phase is never attributed to anything.
derivedPhase :: String -> ExitCode -> String -> [CascadePhaseOutcome] -> CascadePhaseOutcome
derivedPhase name exit cause earlier =
  CascadePhaseOutcome
    { cascadePhaseName = name
    , cascadePhaseExit = exit
    , cascadePhaseDerivedFrom =
        if exit /= ExitSuccess && any causeFailed earlier then Just cause else Nothing
    }
 where
  causeFailed outcome =
    cascadePhaseName outcome == cause && cascadePhaseExit outcome /= ExitSuccess

-- | Sprint 4.82: render the failed-phase list so a derived failure is not
-- narrated as an independent one.
renderFailedCascadePhases :: [CascadePhaseOutcome] -> String
renderFailedCascadePhases outcomes =
  intercalate
    ", "
    [ case cascadePhaseDerivedFrom outcome of
        Nothing -> cascadePhaseName outcome
        Just cause -> cascadePhaseName outcome ++ " (downstream of " ++ cause ++ ")"
    | outcome <- outcomes
    , cascadePhaseExit outcome /= ExitSuccess
    ]

-- | Pure: the cascade's aggregate verdict over its recorded phases.
-- Exposed so a unit case can pin "one failed phase fails the run" without
-- driving the IO orchestration.
aggregateCascadeExit :: [CascadePhaseOutcome] -> ExitCode
aggregateCascadeExit outcomes
  | null (failedCascadePhases outcomes) = ExitSuccess
  | otherwise = ExitFailure 1

failedCascadePhases :: [CascadePhaseOutcome] -> [String]
failedCascadePhases outcomes =
  [cascadePhaseName outcome | outcome <- outcomes, cascadePhaseExit outcome /= ExitSuccess]

-- | LEGACY-ESCAPE[bespoke-cascade-executor]: the cascade is orchestrated here
-- rather than by a lifecycle-owned desired-absence program.  Registered in
-- "Prodbox.Legacy.EscapeRegistry"; deleted by Sprint @6.5@'s qualified
-- single-writer cutover to the descriptor-bound cleanup runner.
runNativeDeleteCascade :: FilePath -> IO ExitCode
runNativeDeleteCascade repoRoot = do
  writeOutputLine cascadeOrderNarration
  -- Step 1: confirm-MinIO — live source-of-truth query of the per-run stacks'
  -- encrypted checkpoints through the sole in-cluster Lifecycle Authority
  -- repository. No alternate Gateway or host object-store transport exists.
  perRun <- queryPerRunResidueStatuses repoRoot
  -- Sprint 4.81: the observation carries the authority that answered; the
  -- status is projected only where a status-shaped consumer needs it, so the
  -- layer survives to the narration instead of being erased at the first use.
  let eksObservation = perRunAwsEksTest perRun
      subzoneObservation = perRunAwsEksSubzone perRun
      testObservation = perRunAwsTest perRun
  -- When the retained checkpoint store cannot answer, the cluster-wide AWS
  -- tag sweep is still useful terminal audit evidence. It is not keyed by
  -- stack, however, so it must never refine any of these exact observations.
  awsAnswer <-
    if perRunNeedsAwsLayer [eksObservation, subzoneObservation, testObservation]
      then queryAwsLayerForPerRun repoRoot
      else
        pure
          ( ResidueStatus.AwsLayerNotConsulted
              "the retained checkpoint store answered for every per-run stack"
          )
  let eksResolution = ResidueStatus.resolveResidueAcrossLayers eksObservation awsAnswer
      subzoneResolution = ResidueStatus.resolveResidueAcrossLayers subzoneObservation awsAnswer
      testResolution = ResidueStatus.resolveResidueAcrossLayers testObservation awsAnswer
      resolutions = [eksResolution, subzoneResolution, testResolution]
      exactEks = ResidueStatus.residueObservationStatus eksObservation
      exactSubzone = ResidueStatus.residueObservationStatus subzoneObservation
      exactTest = ResidueStatus.residueObservationStatus testObservation
      exactAnswers =
        ResourceRegistry.PerRunResidueAnswers
          { ResourceRegistry.perRunAnswerAwsEks = exactEks
          , ResourceRegistry.perRunAnswerAwsEksSubzone = exactSubzone
          , ResourceRegistry.perRunAnswerAwsTest = exactTest
          }
      -- Sprint 4.84: the narration names each stack from the registry entry the
      -- identity selects, rather than from a separately written label list
      -- zipped against the resolutions by position.
      liveSummary =
        intercalate
          ", "
          ( zipWith
              ( \identity resolution ->
                  ResourceRegistry.resourceName
                    (ResourceRegistry.perRunManagedResourceFor identity)
                    ++ "="
                    ++ ResidueStatus.renderResidueResolution resolution
              )
              ResourceRegistry.perRunStackIdentities
              resolutions
          )
  writeOutputLine ("Per-run residue status: " ++ liveSummary)
  case inferCascadeSubstrate exactEks exactSubzone exactTest of
    CascadeSubstrateUnobservable stackNames -> do
      writeDiagnosticLine
        ( "cluster delete --cascade refused before drain, destroy, reaper, or uninstall: "
            ++ "the exact Lifecycle Authority observation is unobservable for "
            ++ intercalate ", " stackNames
            ++ ". The cluster-wide AWS result above is audit-only; it cannot "
            ++ "identify a Pulumi stack, select the EKS drain target, or authorize "
            ++ "a destructive action. Restore the retained local RKE2 Lifecycle "
            ++ "Authority and retry."
        )
      pure (ExitFailure 1)
    CascadeSubstrateKnown cascadeSubstrate ->
      runAuthorizedDeleteCascade repoRoot cascadeSubstrate exactAnswers

-- | Run mutating cascade phases only after every exact per-stack observation
-- is known. Keeping this boundary separate prevents global audit evidence from
-- being accidentally threaded into drain selection or destroy authorization.
runAuthorizedDeleteCascade
  :: FilePath
  -> Substrate
  -> ResourceRegistry.PerRunResidueAnswers
  -> IO ExitCode
runAuthorizedDeleteCascade repoRoot cascadeSubstrate exactAnswers = do
  let perRunPairs = ResourceRegistry.pairPerRunResidue exactAnswers
  -- Step 2: drain before per-run destroys so in-cluster controllers can
  -- release AWS-side resources while they are still serving.
  drainExit <- runCascadeDrainPhase repoRoot cascadeSubstrate
  -- Step 3: per-run Pulumi destroys. Runs even when the drain failed:
  -- doctrine § 5c makes drain→destroy an *attempt* edge, so last-resort
  -- provider cleanup still makes progress and the drain failure is not
  -- erased by the destroy's success.
  destroyOutcome <- ResourceRegistry.reconcileAbsent repoRoot perRunPairs
  -- Step 4: Sprint 4.40 test-scoped EBS reaper. Retained-production EBS
  -- survives by tag policy and by the reaper's test-scoped filter.
  reaperExit <- runCascadeTestEbsReaper repoRoot
  -- Step 5: RKE2 uninstall + cluster-substrate cleanup.
  retainedManualPvRoot <- resolveRetainedManualPvRoot repoRoot
  uninstallExit <-
    runSequentially
      [ deleteRke2ClusterSubstrate repoRoot
      , removeCalicoEndpointStatusResidue
      , removeManagedKubeconfig
      , runHostFirewallGatewayUnrestrict defaultGatewayNodePort
      , renderRetainedStateNotice DeleteArmCascadeReachedPhases retainedManualPvRoot
      ]
  -- Step 6: postflight cluster-tag sweep. Fail-closed since Sprint 4.76
  -- (doctrine § 6): a non-empty escapee list or an unreachable Tagging
  -- API is a hard failure, not a diagnostic. Sprint 4.80 closed the last
  -- skip arm the same way, using the substrate already inferred above:
  -- a missing admin credential is a cannot-confirm only when this cluster
  -- lifecycle actually had AWS state in scope.
  sweepExit <- runCascadePostflightTagSweep repoRoot cascadeSubstrate
  let phases =
        confirmPhase
          : derivedPhase "drain" drainExit "confirm-MinIO" [confirmPhase]
          : [ independentPhase
                "per-run destroys"
                (ResourceRegistry.absentReconcileDestroyExit destroyOutcome)
            , independentPhase "test-EBS reaper" reaperExit
            , independentPhase "uninstall" uninstallExit
            , independentPhase "sweep" sweepExit
            ]
      confirmPhase =
        independentPhase "confirm-MinIO" (perRunResidueObservationExit destroyOutcome)
      aggregate = aggregateCascadeExit phases
  case failedCascadePhases phases of
    [] -> writeOutputLine "cluster delete --cascade: every phase reported success."
    _ ->
      writeDiagnosticLine
        ( "cluster delete --cascade did NOT complete cleanly. Unresolved phase(s): "
            ++ renderFailedCascadePhases phases
            ++ ". Every phase above still ran; the aggregate reports failure because "
            ++ "at least one of them could not confirm the outcome it is responsible for."
        )
  pure aggregate

-- | Sprint 4.76: the confirm-MinIO phase's own verdict, distinct from the
-- destroy fold's. An unobserved per-run stack leaves authority state
-- unresolved (@lifecycle_reconciliation_doctrine.md § 5b@ phase 1), which
-- fails this phase even when nothing needed destroying.
perRunResidueObservationExit :: ResourceRegistry.AbsentReconcileOutcome -> ExitCode
perRunResidueObservationExit outcome
  | null (ResourceRegistry.absentReconcileUnobserved outcome) = ExitSuccess
  | otherwise = ExitFailure 1

-- Sprint 4.21: the per-run cascade inventory (which present stacks to
-- destroy, in canonical order) moved into the managed-resource registry
-- as 'Prodbox.Lifecycle.ResourceRegistry.pairPerRunResidue' +
-- 'resourcesToDestroy', and the destroy dispatch into
-- 'Prodbox.Lifecycle.ResourceRegistry.reconcileAbsent'.

-- | A drain target can be selected only from exact per-stack observations.
-- Unknown does not mean local and it does not mean AWS: either choice could
-- drain the wrong control plane, so it is a refusal before mutation.
data CascadeSubstrateDecision
  = CascadeSubstrateKnown !Substrate
  | CascadeSubstrateUnobservable ![String]
  deriving (Eq, Show)

inferCascadeSubstrate
  :: ResidueStatus.ResidueStatus
  -> ResidueStatus.ResidueStatus
  -> ResidueStatus.ResidueStatus
  -> CascadeSubstrateDecision
inferCascadeSubstrate eksStatus subzoneStatus testStatus =
  case [ name
       | (name, status) <- namedStatuses
       , ResidueStatus.isResidueUnreachable status
       ] of
    [] ->
      CascadeSubstrateKnown
        ( if all (ResidueStatus.isResidueAbsent . snd) namedStatuses
            then SubstrateHomeLocal
            else SubstrateAws
        )
    unobservable -> CascadeSubstrateUnobservable unobservable
 where
  namedStatuses =
    [ ("aws-eks", eksStatus)
    , ("aws-eks-subzone", subzoneStatus)
    , ("aws-test", testStatus)
    ]

-- | Sprint 4.17.a/4.17.b helper: the K8s drain phase extracted from the
-- prior single-block cascade so step 2 of the canonical order is
-- callable in isolation, with substrate-aware kubeconfig
-- handling.
--
-- For @SubstrateHomeLocal@: keeps the Sprint 4.15 skip-is-success
-- semantics — when the local Kubernetes cluster is absent, the drain
-- phase emits @DrainSkipped@ and the cascade continues (no in-cluster
-- controllers means nothing to drain).
--
-- For @SubstrateAws@: binds kubectl explicitly to the scoped Provider-issued
-- endpoint/CA configuration whose bearer is served through a FIFO. Treats
-- @DrainSkipped@ as a hard failure because the EKS cluster is the
-- source of the AWS resources the per-run destroys will try to delete
-- — skipping the drain guarantees the next phase fails with
-- @DependencyViolation@ per
-- @documents\/engineering\/lifecycle_reconciliation_doctrine.md §5b@.
runCascadeDrainPhase :: FilePath -> Substrate -> IO ExitCode
runCascadeDrainPhase repoRoot substrate = do
  writeOutputLine
    ( "K8s drain phase (substrate="
        ++ substrateId substrate
        ++ "): deleting LoadBalancer Services, ALB Ingresses, and Delete-reclaim PVCs..."
    )
  drainResult <- runCascadeDrainResult repoRoot substrate
  case K8sDrain.cascadeDecisionFromDrainResult drainResult of
    K8sDrain.CascadeContinue Nothing -> do
      writeOutputLine
        "K8s drain phase complete. Proceeding with per-run destroys + uninstall + postflight sweep."
      pure ExitSuccess
    K8sDrain.CascadeContinue (Just reason) -> case substrate of
      SubstrateHomeLocal -> do
        writeOutputLine
          ( "K8s drain skipped: "
              ++ reason
              ++ " Proceeding with per-run destroys + uninstall + postflight sweep."
          )
        pure ExitSuccess
      SubstrateAws -> do
        writeOutputLine
          ( "K8s drain phase failed on the AWS substrate: "
              ++ reason
              ++ " Cascade aborts because the EKS cluster's in-cluster controllers (AWS LBC, EBS CSI) could not be drained; per-run Pulumi destroys would fail with DependencyViolation on subnet deletion."
          )
        pure (ExitFailure 1)
    K8sDrain.CascadeAbort reason -> do
      case drainResult of
        K8sDrain.DrainTimedOut survivors ->
          writeOutputLine (K8sDrain.renderDrainTimeoutRefusal survivors)
        _ -> writeOutputLine reason
      pure (ExitFailure 1)

-- | Preserve the typed drain result for the durable cleanup DAG. The CLI
-- projection above remains the sole place that lowers substrate policy to an
-- exit code.
runCascadeDrainResult :: FilePath -> Substrate -> IO K8sDrain.DrainResult
runCascadeDrainResult repoRoot substrate = do
  let drainWith preparedEnvironment = case preparedEnvironment of
        Left detail -> pure (K8sDrain.DrainUnobservable detail)
        Right drainEnv ->
          K8sDrain.drainAwsAffectingK8sResources drainEnv K8sDrain.defaultDrainTimeout
  case substrate of
    SubstrateHomeLocal -> do
      drainEnvVars <- buildDrainEnvironment repoRoot SubstrateHomeLocal Nothing
      drainWith drainEnvVars
    SubstrateAws -> do
      -- Sprint 4.18 fifth chunk: re-derive the EKS kubeconfig via
      -- 'withEksKubeconfig' so the drain's kubectl subprocesses don't
      -- rely on the legacy `.prodbox-state/` persisted path. A bracket
      -- setup failure (live MinIO backend unreachable, snapshot missing,
      -- aws eks update-kubeconfig fails) is a hard cascade failure on
      -- AWS — same severity as a skipped drain — because the destroy
      -- phase would otherwise hit DependencyViolation on subnet
      -- deletion.
      bracketResult <-
        try
          ( withEksKubeconfig repoRoot $ \kubeconfigPath -> do
              drainEnvVars <- buildDrainEnvironment repoRoot SubstrateAws (Just kubeconfigPath)
              drainWith drainEnvVars
          )
          :: IO (Either SomeException K8sDrain.DrainResult)
      case bracketResult of
        Left exc ->
          pure
            ( K8sDrain.DrainUnobservable
                ( "AWS kubeconfig materialization failed: "
                    ++ show exc
                )
            )
        Right result -> pure result

-- | Prepare an exact drain target. Both substrates fail closed when their
-- kubeconfig is unavailable. 'K8sDrain.prepareK8sDrainEnv' removes ambient
-- @KUBECONFIG@ entries and binds the selected path exactly once via kubectl's
-- explicit @--kubeconfig@ option.
buildDrainEnvironment
  :: FilePath
  -> Substrate
  -> Maybe FilePath
  -> IO (Either String K8sDrain.K8sDrainEnv)
buildDrainEnvironment repoRoot substrate maybeAwsKubeconfig = do
  parentEnv <- getEnvironment
  case (substrate, maybeAwsKubeconfig) of
    (SubstrateHomeLocal, _) ->
      K8sDrain.prepareK8sDrainEnv rke2KubeconfigPath parentEnv (Just repoRoot)
    (SubstrateAws, Nothing) ->
      pure
        ( Left
            "AWS drain kubeconfig was not materialized. Refusing to use ambient KUBECONFIG or kubectl's default context."
        )
    (SubstrateAws, Just kubeconfigPath) ->
      K8sDrain.prepareK8sDrainEnv kubeconfigPath parentEnv (Just repoRoot)

-- | Sprint 4.76: the reaper reports an exit code instead of unit, so a
-- failed query or delete reaches the cascade's phase fold. A missing
-- ephemeral admin credential remains a skip (there is no AWS session to
-- query with, and the reaper is not a sweep-owning surface under § 6).
runCascadeTestEbsReaper :: FilePath -> IO ExitCode
runCascadeTestEbsReaper repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left _ -> do
      writeOutputLine
        "Test-scoped EBS reaper: skipped (no ephemeral admin AWS credential available)."
      pure ExitSuccess
    Right adminCredentials -> do
      environment <- adminAwsEnvironment adminCredentials
      result <-
        EbsVolume.runTestScopedEbsReaper
          EbsVolume.TestEbsReaperInput
            { EbsVolume.testEbsReaperEnvironment = environment
            , EbsVolume.testEbsReaperWorkingDirectory = Just repoRoot
            , EbsVolume.testEbsReaperClusterName = awsEksCanonicalClusterName
            }
      case result of
        Left err -> do
          writeDiagnosticLine
            ("Test-scoped EBS reaper: query/delete failed: " ++ err)
          pure (ExitFailure 1)
        Right report -> do
          writeOutputLine (EbsVolume.renderTestScopedEbsReaperReport report)
          pure ExitSuccess

-- | Sprint 4.17 helper, made fail-closed by Sprint 4.76: the postflight
-- cluster-tag sweep of the canonical cascade. Per
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 6@ the
-- sweep is the backstop for K8s-operator-created AWS resources that
-- escape the drain, and **a required tag sweep is fail-closed**: a
-- non-empty escapee list or a Tagging API that cannot be read is a hard
-- failure, never a silent pass. Before Sprint 4.76 this function
-- returned @IO ()@, so neither outcome could reach the exit code, and
-- its own Haddock cited § 6 as licensing that.
--
-- The one remaining skip is a missing ephemeral admin credential: there
-- is no AWS session to query with, so no query is attempted. That arm is
-- narrated as a skip — it does **not** claim the sweep was clean — and
-- whether it should refuse outright is registered in
-- @DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md@ rather than decided
-- here, because refusing would make @--cascade@ fail on every host that
-- has never provisioned an AWS substrate.
-- | Sprint 4.80: the credential-absent arm's verdict, decided rather than
-- fixed.
--
-- Sprint 4.76 left this arm a skip and registered the reason as a __policy__
-- question rather than an honesty one: the arm no longer claimed absence, but
-- refusing outright would have failed @prodbox cluster delete --cascade@ on
-- every host that has never provisioned an AWS substrate — the recommended
-- wipe-and-rebuild path in @CLAUDE.md@.
--
-- The cascade already computes the fact that decides it.
-- 'inferCascadeSubstrate' refuses before reaching this function when an exact
-- stack observation is unobservable; for fully-observed inputs it yields
-- 'SubstrateAws' when a stack is present and 'SubstrateHomeLocal' when all are
-- absent. So:
--
--   * 'SubstrateHomeLocal' — every per-run AWS stack was observed absent, so
--     this cluster lifecycle created no AWS resources for the sweep to
--     backstop. A skip confirms nothing and needs to confirm nothing.
--   * 'SubstrateAws' — AWS state was observed present, the sweep is exactly
--     the § 6 backstop for it, and "I have no credential to query with" is a
--     case of cannot-confirm. That is a hard failure.
--
-- The AWS-free host keeps exiting 0, and the host that actually had AWS state
-- can no longer pass a cascade whose backstop never ran.
cascadeSweepCredentialAbsentExit :: Substrate -> ExitCode
cascadeSweepCredentialAbsentExit substrate = case substrate of
  SubstrateHomeLocal -> ExitSuccess
  SubstrateAws -> ExitFailure 1

-- | Run the cluster-wide AWS tag query as terminal audit evidence when an
-- exact checkpoint observation is unavailable. This answer is never threaded
-- into stack status, target selection, or mutation authorization: tags do not
-- attribute a resource to one exact Pulumi stack. A missing credential is
-- 'AwsLayerNotConsulted', never an absence.
queryAwsLayerForPerRun :: FilePath -> IO ResidueStatus.AwsLayerAnswer
queryAwsLayerForPerRun repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left detail ->
      pure
        ( ResidueStatus.AwsLayerNotConsulted
            ("no ephemeral admin AWS credential available: " ++ detail)
        )
    Right adminCredentials -> do
      environment <- adminAwsEnvironment adminCredentials
      let input =
            TagSweep.TagSweepInput
              { TagSweep.tagSweepEnvironment = environment
              , TagSweep.tagSweepClusterName = Just awsEksCanonicalClusterName
              , TagSweep.tagSweepWorkingDirectory = Just repoRoot
              }
      discovered <- TagSweep.discoverClusterTaggedAwsResources input
      pure $ case discovered of
        Left detail -> ResidueStatus.AwsLayerUnobservable detail
        Right [] -> ResidueStatus.AwsLayerNoResources
        Right resources ->
          ResidueStatus.AwsLayerResourcesPresent
            (map TagSweep.taggedResourceArn resources)

-- | The global audit is consulted exactly when the exact authority failed to
-- answer for at least one stack, and not otherwise.
--
-- Stated as its own pure predicate so the "we did not need to ask" case is a
-- decision with a reason rather than an absent branch.
perRunNeedsAwsLayer :: [ResidueStatus.ResidueObservation] -> Bool
perRunNeedsAwsLayer =
  any (ResidueStatus.isResidueUnreachable . ResidueStatus.residueObservationStatus)

runCascadePostflightTagSweep :: FilePath -> Substrate -> IO ExitCode
runCascadePostflightTagSweep repoRoot cascadeSubstrate = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left _ -> do
      let exit = cascadeSweepCredentialAbsentExit cascadeSubstrate
          narration =
            "Postflight tag sweep: NOT RUN (no ephemeral admin AWS credential available \
            \— no test-secrets.dhall and no TTY — so no Tagging API query was attempted). \
            \This is not a confirmation that no AWS residue exists."
      case exit of
        ExitSuccess ->
          writeOutputLine
            ( narration
                ++ " Every per-run AWS stack was observed absent, so this cluster \
                   \lifecycle created no AWS resources for the sweep to backstop."
            )
        ExitFailure _ ->
          writeDiagnosticLine
            ( narration
                ++ " Per-run AWS state was present or could not be observed, so the \
                   \sweep is the backstop for it and its absence is unconfirmed. \
                   \Re-run with an admin AWS credential available."
            )
      pure exit
    Right adminCredentials -> do
      environment <- adminAwsEnvironment adminCredentials
      let input =
            TagSweep.TagSweepInput
              { TagSweep.tagSweepEnvironment = environment
              , TagSweep.tagSweepClusterName = Just awsEksCanonicalClusterName
              , TagSweep.tagSweepWorkingDirectory = Just repoRoot
              }
      -- Sprint 7.26: `TagSweepCascade` carves out intentionally-RETAINED
      -- long-lived shared infrastructure (the `pulumi_state_backend`
      -- bucket + `aws-ses`) — `cluster delete --cascade` keeps these by
      -- design, so they are NOT escaped residue.
      verdict <-
        TagSweep.decideTagSweep TagSweep.TagSweepCascade
          <$> TagSweep.discoverClusterTaggedAwsResources input
      let exit = TagSweep.tagSweepVerdictExit verdict
      case exit of
        ExitSuccess -> writeOutputLine (TagSweep.renderTagSweepVerdict TagSweep.TagSweepCascade verdict)
        ExitFailure _ -> writeDiagnosticLine (TagSweep.renderTagSweepVerdict TagSweep.TagSweepCascade verdict)
      pure exit

-- Sprint 1.89: the binding is named for its provenance. This reads a config
-- 'validateConfig' has not seen and cannot see — the retained manual-PV root
-- must be resolvable while validation itself is unavailable — so raw is the only
-- thing there is to read here and no decision is being discarded. The name
-- `config` would have made this indistinguishable from the validated binding
-- elsewhere in this module, which is what @checkTier0CoordinateReads@ discovered.
resolveRetainedManualPvRoot :: FilePath -> IO FilePath
resolveRetainedManualPvRoot repoRoot = do
  configResult <- loadConfigFile repoRoot
  let configuredRoot =
        case configResult of
          Right unvalidatedConfig ->
            Text.unpack (manual_pv_host_root (storage unvalidatedConfig))
          Left _ -> Text.unpack (manual_pv_host_root (storage defaultConfigFile))
  makeAbsolute (repoRoot </> configuredRoot)

ensureRke2ServerInstalled :: FilePath -> IO ExitCode
ensureRke2ServerInstalled repoRoot = do
  existsResult <- captureToolOutput repoRoot "test" ["-x", rke2BinaryPath]
  case existsResult of
    Left err -> failWith err
    Right output ->
      case processExitCode output of
        ExitSuccess -> pure ExitSuccess
        ExitFailure _ ->
          withTemporaryTextFile "prodbox-rke2-installer" "" $ \installerPath -> do
            downloadResult <-
              captureToolOutput
                repoRoot
                "curl"
                ["-sfL", "https://get.rke2.io", "-o", installerPath]
            case downloadResult of
              Left err -> failWith err
              Right downloadOutput ->
                case processExitCode downloadOutput of
                  ExitFailure _ ->
                    failWith
                      ("failed to download RKE2 installer: " ++ outputDetail downloadOutput)
                  ExitSuccess ->
                    runCommand
                      Subprocess
                        { subprocessPath = "sudo"
                        , subprocessArguments = ["env", "INSTALL_RKE2_TYPE=server", "sh", installerPath]
                        , subprocessEnvironment = Nothing
                        , subprocessWorkingDirectory = Just repoRoot
                        }

ensureRke2IngressController :: FilePath -> IO ExitCode
ensureRke2IngressController repoRoot = do
  contentResult <- readRootFile repoRoot rke2ConfigPath
  case contentResult of
    Left err -> failWith err
    Right existingContent ->
      let updatedContent = renderIngressControllerConfig existingContent "none"
       in if updatedContent == existingContent
            then pure ExitSuccess
            else writeRootFile repoRoot rke2ConfigPath updatedContent

syncUserKubeconfig :: FilePath -> IO ExitCode
syncUserKubeconfig repoRoot = do
  homeDirectory <- getHomeDirectory
  ownerResult <- currentOwnerSpec repoRoot
  case ownerResult of
    Left err -> failWith err
    Right ownerSpec ->
      let targetPath = homeDirectory </> ".kube" </> "config"
       in runSequentially
            [ runCommand
                Subprocess
                  { subprocessPath = "sudo"
                  , subprocessArguments = ["mkdir", "-p", takeDirectory targetPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            , runCommand
                Subprocess
                  { subprocessPath = "sudo"
                  , subprocessArguments = ["cp", rke2KubeconfigPath, targetPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            , runCommand
                Subprocess
                  { subprocessPath = "sudo"
                  , subprocessArguments = ["chown", ownerSpec, targetPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            , runCommand
                Subprocess
                  { subprocessPath = "chmod"
                  , subprocessArguments = ["600", targetPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            ]

verifyClusterInfo :: FilePath -> IO ExitCode
verifyClusterInfo repoRoot =
  runCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments = ["cluster-info"]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

waitForClusterNodesReady :: FilePath -> IO ExitCode
waitForClusterNodesReady repoRoot = go rke2NodeDiscoveryAttempts "cluster API not yet reachable"
 where
  go :: Int -> String -> IO ExitCode
  go attemptsRemaining lastDetail
    | attemptsRemaining <= 0 =
        failWith
          ( "Failed to observe registered cluster nodes before readiness wait: "
              ++ lastDetail
          )
    | otherwise = do
        outputResult <- captureKubectl repoRoot ["get", "nodes", "-o", "name"]
        case outputResult of
          Left err -> do
            threadDelay rke2NodeDiscoveryDelayMicroseconds
            go (attemptsRemaining - 1) err
          Right output ->
            case processExitCode output of
              ExitSuccess ->
                case parseObjectNames (processStdout output) of
                  [] -> do
                    threadDelay rke2NodeDiscoveryDelayMicroseconds
                    go
                      (attemptsRemaining - 1)
                      "cluster API reachable but no node objects registered yet"
                  _ ->
                    runCommand
                      Subprocess
                        { subprocessPath = "kubectl"
                        , subprocessArguments =
                            [ "wait"
                            , "--for=condition=Ready"
                            , "node"
                            , "--all"
                            , "--timeout=300s"
                            ]
                        , subprocessEnvironment = Nothing
                        , subprocessWorkingDirectory = Just repoRoot
                        }
              ExitFailure _ -> do
                threadDelay rke2NodeDiscoveryDelayMicroseconds
                go (attemptsRemaining - 1) (outputDetail output)

deleteNonManualStorageClasses :: FilePath -> IO ExitCode
deleteNonManualStorageClasses repoRoot = do
  outputResult <- captureKubectl repoRoot ["get", "storageclass", "-o", "name"]
  case outputResult of
    Left err -> failWith err
    Right output ->
      case processExitCode output of
        ExitFailure _ -> failWith ("Failed to list StorageClasses: " ++ outputDetail output)
        ExitSuccess ->
          let refs =
                [ ref
                | ref <- parseObjectNames (processStdout output)
                , dropResourcePrefix ref /= manualStorageClass
                ]
           in runSequentially
                [ runCommand
                    Subprocess
                      { subprocessPath = "kubectl"
                      , subprocessArguments = ["delete", "storageclass", ref, "--ignore-not-found=true"]
                      , subprocessEnvironment = Nothing
                      , subprocessWorkingDirectory = Just repoRoot
                      }
                | ref <- refs
                ]

-- | Sprint 4.31: reconcile every always-on retained PV under the unified
-- `.data/<namespace>/<StatefulSet>/<ordinal>` scheme — MinIO (`.data/prodbox/minio/0`,
-- chowned to its `1000:1000` runtime user) and Vault (`.data/vault/vault/0`,
-- chowned to its `100:100` runtime user) — with no per-host machine-id prefix.
-- Each host directory is created and chowned, any Released/Failed PV is reset so
-- it can rebind, and the deterministic StorageClass + PV + prebound PVC for both
-- workloads are applied in one manifest. The MinIO and Vault StatefulSets adopt
-- their prebound PVCs. Per-chart retained PVs (the Patroni cluster, `vscode`) are
-- created at chart-deploy time through the same `storageBinding` scheme in
-- 'Prodbox.Lib.ChartPlatform'.
ensureRetainedLocalStorage :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureRetainedLocalStorage repoRoot settings prodboxId labelValue = do
  nodeNameResult <- resolveSingleNodeHostname repoRoot
  case nodeNameResult of
    Left err -> failWith err
    Right nodeName -> do
      let bindings =
            map
              (retainedLocalStorageBinding (resolvedManualPvHostRoot settings))
              (retainedLocalStorageEntriesForSubstrate SubstrateHomeLocal)
      runSequentially
        ( map
            ( \binding ->
                ensureHostStoragePath
                  repoRoot
                  (retainedLocalStorageBindingHostPath binding)
                  (retainedLocalStorageBindingOwner binding)
            )
            bindings
            ++ map
              (resetReleasedPersistentVolume repoRoot . retainedLocalStorageBindingPersistentVolume)
              bindings
            ++ [ applyRetainedStorageManifest
                   repoRoot
                   (storageManifestItems bindings nodeName prodboxId labelValue)
               ]
        )

-- | Create the host-side control directory for operator-owned artifacts
-- such as the encrypted Vault unlock bundle. Workload PV leaf directories
-- keep their runtime uid/gid ownerships in 'ensureRetainedLocalStorage'.
ensureHostControlDataDirectory :: FilePath -> ValidatedSettings -> IO ExitCode
ensureHostControlDataDirectory repoRoot settings = do
  ownerResult <- currentOwnerSpec repoRoot
  case ownerResult of
    Left err -> failWith err
    Right ownerSpec ->
      let hostControlPath = resolvedManualPvHostRoot settings </> "prodbox"
       in runSequentially
            [ runCommand
                Subprocess
                  { subprocessPath = "sudo"
                  , subprocessArguments = ["mkdir", "-p", hostControlPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            , runCommand
                Subprocess
                  { subprocessPath = "sudo"
                  , subprocessArguments = ["chown", ownerSpec, hostControlPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            , runCommand
                Subprocess
                  { subprocessPath = "sudo"
                  , subprocessArguments = ["chmod", "0750", hostControlPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            ]

data RetainedLocalStorageEntry = RetainedLocalStorageEntry
  { retainedLocalStorageEntryNamespace :: String
  , retainedLocalStorageEntryStatefulSet :: String
  , retainedLocalStorageEntryOrdinal :: Int
  , retainedLocalStorageEntryStorageSize :: String
  , retainedLocalStorageEntryOwner :: String
  }

data RetainedLocalStorageBinding = RetainedLocalStorageBinding
  { retainedLocalStorageBindingNamespace :: String
  , retainedLocalStorageBindingPersistentVolume :: String
  , retainedLocalStorageBindingPersistentClaim :: String
  , retainedLocalStorageBindingStorageSize :: String
  , retainedLocalStorageBindingHostPath :: FilePath
  , retainedLocalStorageBindingOwner :: String
  }

data RetainedStorageInventoryEntry = RetainedStorageInventoryEntry
  { retainedStorageInventoryNamespace :: String
  , retainedStorageInventoryStatefulSet :: String
  , retainedStorageInventoryOrdinal :: Int
  , retainedStorageInventoryPersistentVolume :: String
  , retainedStorageInventoryPersistentClaim :: String
  , retainedStorageInventoryStorageSize :: String
  }
  deriving (Eq, Show)

retainedLocalStorageEntries :: [RetainedLocalStorageEntry]
retainedLocalStorageEntries =
  [ RetainedLocalStorageEntry
      { retainedLocalStorageEntryNamespace = minioNamespace
      , retainedLocalStorageEntryStatefulSet = "minio"
      , retainedLocalStorageEntryOrdinal = 0
      , retainedLocalStorageEntryStorageSize = minioStorageSize
      , retainedLocalStorageEntryOwner = "1000:1000"
      }
  , RetainedLocalStorageEntry
      { retainedLocalStorageEntryNamespace = vaultStorageNamespace
      , retainedLocalStorageEntryStatefulSet = "vault"
      , retainedLocalStorageEntryOrdinal = 0
      , retainedLocalStorageEntryStorageSize = vaultStorageSize
      , retainedLocalStorageEntryOwner = "100:100"
      }
  ]

retainedLocalStorageEntriesForSubstrate :: Substrate -> [RetainedLocalStorageEntry]
retainedLocalStorageEntriesForSubstrate substrate =
  case substrate of
    SubstrateHomeLocal -> retainedLocalStorageEntries
    SubstrateAws -> retainedAwsLocalStorageEntries

retainedAwsLocalStorageEntries :: [RetainedLocalStorageEntry]
retainedAwsLocalStorageEntries =
  [ entry
      { retainedLocalStorageEntryStorageSize =
          if retainedLocalStorageEntryNamespace entry == minioNamespace
            && retainedLocalStorageEntryStatefulSet entry == "minio"
            then "20Gi"
            else retainedLocalStorageEntryStorageSize entry
      }
  | entry <- retainedLocalStorageEntries
  ]

-- | Sprint 4.39: substrate-aware retained-storage inventory. Home and AWS use
-- the same deterministic namespace/PV/PVC identities; the volume source differs
-- later at materialization time (hostPath on home, pre-created EBS
-- @volumeHandle@ on AWS).
retainedStorageInventoryEntries :: Substrate -> [RetainedStorageInventoryEntry]
retainedStorageInventoryEntries substrate =
  map inventoryEntry (retainedLocalStorageEntriesForSubstrate substrate)
 where
  inventoryEntry entry =
    RetainedStorageInventoryEntry
      { retainedStorageInventoryNamespace = retainedLocalStorageEntryNamespace entry
      , retainedStorageInventoryStatefulSet = retainedLocalStorageEntryStatefulSet entry
      , retainedStorageInventoryOrdinal = retainedLocalStorageEntryOrdinal entry
      , retainedStorageInventoryPersistentVolume =
          retainedStatefulSetPersistentVolumeName
            (retainedLocalStorageEntryNamespace entry)
            (retainedLocalStorageEntryStatefulSet entry)
            (retainedLocalStorageEntryOrdinal entry)
      , retainedStorageInventoryPersistentClaim =
          retainedStatefulSetPersistentVolumeClaimName
            (retainedLocalStorageEntryStatefulSet entry)
            (retainedLocalStorageEntryOrdinal entry)
      , retainedStorageInventoryStorageSize = retainedLocalStorageEntryStorageSize entry
      }

retainedLocalStorageBinding :: FilePath -> RetainedLocalStorageEntry -> RetainedLocalStorageBinding
retainedLocalStorageBinding root entry =
  RetainedLocalStorageBinding
    { retainedLocalStorageBindingNamespace = retainedLocalStorageEntryNamespace entry
    , retainedLocalStorageBindingPersistentVolume =
        retainedStatefulSetPersistentVolumeName
          (retainedLocalStorageEntryNamespace entry)
          (retainedLocalStorageEntryStatefulSet entry)
          (retainedLocalStorageEntryOrdinal entry)
    , retainedLocalStorageBindingPersistentClaim =
        retainedStatefulSetPersistentVolumeClaimName
          (retainedLocalStorageEntryStatefulSet entry)
          (retainedLocalStorageEntryOrdinal entry)
    , retainedLocalStorageBindingStorageSize = retainedLocalStorageEntryStorageSize entry
    , retainedLocalStorageBindingHostPath =
        root
          </> retainedLocalStorageEntryNamespace entry
          </> retainedLocalStorageEntryStatefulSet entry
          </> show (retainedLocalStorageEntryOrdinal entry)
    , retainedLocalStorageBindingOwner = retainedLocalStorageEntryOwner entry
    }

-- | Delete a retained PV only when it is stuck @Released@/@Failed@ (e.g. after a
-- PVC delete left the @Retain@ PV behind) so the next apply can recreate it and
-- rebind. A @Bound@ or absent PV is left untouched.
resetReleasedPersistentVolume :: FilePath -> String -> IO ExitCode
resetReleasedPersistentVolume repoRoot pvName = do
  pvPhaseResult <-
    captureKubectl
      repoRoot
      ["get", "pv", pvName, "-o", "jsonpath={.status.phase}", "--ignore-not-found=true"]
  case pvPhaseResult of
    Left err -> failWith err
    Right pvPhaseOutput ->
      if trimWhitespace (processStdout pvPhaseOutput) `elem` ["Released", "Failed"]
        then
          runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments =
                  ["delete", "pv", pvName, "--ignore-not-found=true", "--wait=true"]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        else pure ExitSuccess

-- | Apply the retained StorageClass + PV/PVC manifest set. @kubectl apply@ is
-- idempotent: re-applying an already-bound PVC with an identical spec is a no-op.
applyRetainedStorageManifest :: FilePath -> [Value] -> IO ExitCode
applyRetainedStorageManifest repoRoot manifestItems =
  withTemporaryJsonManifest "prodbox-storage" manifestItems $ \manifestPath -> do
    applyResult <- captureKubectl repoRoot ["apply", "-f", manifestPath]
    case applyResult of
      Left err -> failWith err
      Right applyOutput ->
        case processExitCode applyOutput of
          ExitFailure _ ->
            failWith
              ( "Failed to ensure retained local storage resources: "
                  ++ outputDetail applyOutput
              )
          ExitSuccess -> pure ExitSuccess

-- | Sprint 3.17: deploy the in-cluster Vault platform component from the local
-- @charts/vault@ chart — a single-replica StatefulSet on a durable PV. Vault
-- comes up sealed; the operator runs @prodbox vault unseal@ next. Vault is a
-- shared platform component declared in 'homeSubstratePlatformComponents' and
-- 'awsSubstratePlatformComponents'. The home and AWS platform reconcilers both
-- install this same chart so the Vault StatefulSet/Service/PVC shape remains
-- substrate-equivalent.
ensureVaultRuntime :: FilePath -> ValidatedSettings -> IO ExitCode
ensureVaultRuntime repoRoot settings =
  case workloadStorageSize (validatedResourcePlan settings) "vault" of
    Left err -> failWith err
    Right storageSize -> do
      lifecycleResult <-
        resolveVaultLifecycle repoRoot (validatedDeploymentContext settings)
      case lifecycleResult of
        Left err -> failWith err
        Right lifecycle ->
          case lifecycle of
            RootVaultLifecycle _ _ ->
              applyVaultRuntime repoRoot storageSize lifecycle
            ChildVaultLifecycle _ _ parent -> do
              parentReadiness <- probeParentVaultReadiness parent
              case renderParentReadinessBlock parent parentReadiness of
                Just block -> failWith block
                Nothing -> do
                  tokenResult <- childTransitSealTokenPresent repoRoot
                  case tokenResult of
                    Left err -> failWith err
                    Right () -> applyVaultRuntime repoRoot storageSize lifecycle

applyVaultRuntime :: FilePath -> String -> FederatedVaultLifecycle -> IO ExitCode
applyVaultRuntime repoRoot storageSize lifecycle =
  runSequentially
    [ runHelmCommandWithRetries
        repoRoot
        ( [ "upgrade"
          , "--install"
          , "vault"
          , repoRoot ++ "/charts/vault"
          , "--namespace"
          , vaultNamespace
          , "--create-namespace"
          ]
            ++ vaultLifecycleHelmSealArgs lifecycle
            ++ [ "--set"
               , "storage.size=" ++ storageSize
               ]
        )
    , runCommand
        Subprocess
          { subprocessPath = "kubectl"
          , subprocessArguments =
              [ "rollout"
              , "status"
              , "statefulset/vault"
              , "-n"
              , vaultNamespace
              , "--timeout=300s"
              ]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    ]

probeParentVaultReadiness :: ParentRef -> IO ParentVaultReadiness
probeParentVaultReadiness parent = do
  statusResult <- vaultSealStatus (VaultAddress (parentRefVaultAddress parent))
  pure (parentReadinessDecision (mapLeftEither renderHttpError statusResult))

childTransitSealTokenPresent :: FilePath -> IO (Either String ())
childTransitSealTokenPresent repoRoot = do
  tokenResult <- readChildTransitSealToken repoRoot
  pure $ case tokenResult of
    Left err ->
      Left
        ( "missing child transit-seal token Secret "
            ++ vaultNamespace
            ++ "/"
            ++ vaultTransitSealTokenSecretName
            ++ ": "
            ++ err
            ++ ". Run `prodbox cluster federation register <child> --child-vault-address URL --child-kubeconfig PATH` on the parent first."
        )
    Right _ -> Right ()

data VaultLifecycleResult = VaultLifecycleResult
  { vaultLifecycleExitCode :: ExitCode
  }
  deriving (Eq, Show)

data OperationalAwsCredentialGate
  = OperationalAwsCredentialsReady
  | OperationalAwsCredentialsAbsent String
  | OperationalAwsCredentialsInvalid String
  deriving (Eq, Show)

-- | Sprint 4.29: after the Vault StatefulSet is deployed/rebound, reconcile
-- the root Vault lifecycle before any secret-dependent platform step starts.
-- @vault init@ is guarded by Vault's initialized flag and refuses to re-init;
-- @vault unseal@ is a no-op for an already-unsealed Vault; @vault reconcile@
-- applies the baseline mounts, policies, auth, roles, and generated KV seed
-- objects only after Vault is initialized and unsealed.
ensureRootVaultLifecycle :: FilePath -> ValidatedDeploymentContext -> IO ExitCode
ensureRootVaultLifecycle repoRoot context = do
  lifecycleResult <- resolveVaultLifecycle repoRoot context
  case lifecycleResult of
    Left err -> failWith err
    Right RootVaultLifecycle {} ->
      vaultLifecycleExitCode <$> ensureRootVaultLifecycleDetailed repoRoot context
    Right ChildVaultLifecycle {} ->
      failWith "root Vault lifecycle refused: the validated deployment context names a child lifecycle"

ensureRootVaultLifecycleDetailed
  :: FilePath -> ValidatedDeploymentContext -> IO VaultLifecycleResult
ensureRootVaultLifecycleDetailed repoRoot context = do
  testLifecycle <- lookupEnv "PRODBOX_TEST_ROOT_VAULT_LIFECYCLE"
  case testLifecycle of
    Just "ready" -> do
      writeOutputLine "Vault lifecycle: test-ready"
      pure (VaultLifecycleResult ExitSuccess)
    Just other ->
      lifecycleFailure <$> failWith ("invalid PRODBOX_TEST_ROOT_VAULT_LIFECYCLE=" ++ other)
    Nothing -> continue
 where
  continue = do
    bootstrapExit <- runVaultBootstrapViaBroker repoRoot
    case bootstrapExit of
      ExitFailure _ -> pure (lifecycleFailure bootstrapExit)
      ExitSuccess -> do
        -- Sprint 1.39 (self-heal): the daemon-mediated bootstrap initializes,
        -- unseals, and reconciles Vault inside the cluster. The host still owns
        -- the non-secret Tier-0 floor beside the binary, so guarantee it after
        -- the daemon reports Vault ready.
        floorResult <- ensureBasicsFloor repoRoot context
        case floorResult of
          Left err -> lifecycleFailure <$> failWith err
          Right () -> pure (VaultLifecycleResult ExitSuccess)

ensureFederatedVaultLifecycleDetailed
  :: FilePath
  -> ValidatedDeploymentContext
  -> IO VaultLifecycleResult
ensureFederatedVaultLifecycleDetailed repoRoot context = do
  lifecycleResult <- resolveVaultLifecycle repoRoot context
  case lifecycleResult of
    Left err -> lifecycleFailure <$> failWith err
    Right (RootVaultLifecycle _ _) -> ensureRootVaultLifecycleDetailed repoRoot context
    Right (ChildVaultLifecycle childId _ parent) ->
      ensureChildVaultLifecycleDetailed repoRoot childId parent

ensureChildVaultLifecycleDetailed :: FilePath -> Text.Text -> ParentRef -> IO VaultLifecycleResult
ensureChildVaultLifecycleDetailed _repoRoot childId _parent =
  lifecycleFailure
    <$> failWith
      ( "child Vault lifecycle requires the Bootstrap Broker's typed "
          ++ "ChildCustodyBinding -> ChildEncryptedReceipt -> "
          ++ "ParentCustodyAcknowledgement protocol; the removed direct "
          ++ "Vault-init/root-token custody path cannot be used (child="
          ++ Text.unpack childId
          ++ ")"
      )

lifecycleFailure :: ExitCode -> VaultLifecycleResult
lifecycleFailure exitCode =
  VaultLifecycleResult
    { vaultLifecycleExitCode = exitCode
    }

resolveVaultLifecycle
  :: FilePath
  -> ValidatedDeploymentContext
  -> IO (Either String FederatedVaultLifecycle)
resolveVaultLifecycle repoRoot context = do
  basicsResult <- loadUnencryptedBasics repoRoot
  pure $ case basicsResult of
    Left err -> Left err
    Right basics -> vaultLifecycleFromBasics basics >>= bindVaultLifecycleContext context

-- | Bind observation and execution to one cluster/Vault identity. A lifecycle
-- decoded from stale or foreign Tier-0 data cannot authorize effects for the
-- validated command context.
bindVaultLifecycleContext
  :: ValidatedDeploymentContext
  -> FederatedVaultLifecycle
  -> Either String FederatedVaultLifecycle
bindVaultLifecycleContext context lifecycle =
  let (lifecycleClusterId, lifecycleVaultAddress) = case lifecycle of
        RootVaultLifecycle clusterId address -> (clusterId, address)
        ChildVaultLifecycle clusterId address _ -> (clusterId, address)
      expectedClusterId = deploymentClusterId context
      expectedVaultAddress = deploymentVaultAddress context
   in if lifecycleClusterId /= expectedClusterId
        then
          Left
            ( "lifecycle context mismatch: sealed cluster id `"
                ++ Text.unpack lifecycleClusterId
                ++ "` does not match validated context.cluster_id `"
                ++ Text.unpack expectedClusterId
                ++ "`"
            )
        else
          if lifecycleVaultAddress /= expectedVaultAddress
            then
              Left
                ( "lifecycle context mismatch: sealed Vault address `"
                    ++ Text.unpack lifecycleVaultAddress
                    ++ "` does not match validated context.vault_address `"
                    ++ Text.unpack expectedVaultAddress
                    ++ "`"
                )
            else Right lifecycle

readChildTransitSealToken :: FilePath -> IO (Either String VaultToken)
readChildTransitSealToken repoRoot = do
  outputResult <-
    runTextCommand
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "secret"
            , vaultTransitSealTokenSecretName
            , "-n"
            , vaultNamespace
            , "-o"
            , "go-template={{index .data \"token\" | base64decode}}"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case outputResult of
    Left err -> Left err
    Right token
      | null (trimWhitespace token) -> Left "Secret field token is empty"
      | otherwise -> Right (VaultToken (Text.pack (trimWhitespace token)))

mapLeftEither :: (left -> left') -> Either left right -> Either left' right
mapLeftEither f value = case value of
  Left err -> Left (f err)
  Right result -> Right result

-- | Sprint 4.31: deploy MinIO from the prodbox-owned @charts/minio@ chart — a
-- single-replica StatefulSet on the unified retained-storage scheme — replacing
-- the bitnami standalone Deployment. The reconcile installs it twice (public
-- bootstrap image, then the Harbor-mirrored steady-state image), each a
-- @helm upgrade --install@ that only flips the image values; the StatefulSet
-- rolls the pod and adopts the prebound @data-minio-0@ PVC either way.
ensureMinioRuntime :: FilePath -> ValidatedSettings -> Substrate -> MinioImageSource -> IO ExitCode
ensureMinioRuntime repoRoot settings substrate imageSource =
  case workloadStorageSize (validatedResourcePlan settings) "minio" of
    Left err -> failWith err
    Right storageSize ->
      runSequentially
        [ runHelmCommandWithRetries
            repoRoot
            ( [ "upgrade"
              , "--install"
              , minioReleaseName
              , repoRoot ++ "/charts/minio"
              , "--namespace"
              , minioNamespace
              , "--create-namespace"
              ]
                ++ renderMinioChartArgs substrate imageSource storageSize
            )
        , runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments =
                  [ "rollout"
                  , "status"
                  , "statefulset/minio"
                  , "-n"
                  , minioNamespace
                  , "--timeout=300s"
                  ]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        ]

-- | Pure render of @--set@ flag pairs for the prodbox-owned @charts/minio@
-- install. MinIO always uses the PUBLIC (bootstrap-exception) image regardless of
-- the requested image source, so @_imageSource@ is ignored: MinIO is Harbor's own
-- S3 storage backend, so it cannot source its image from Harbor (a circular
-- dependency). The bitnami Deployment masked this because a Deployment surges a
-- new pod before terminating the old one (keeping Harbor's backend alive across an
-- image switch); a single-replica StatefulSet does not surge, so a Harbor-sourced
-- MinIO image deadlocks (MinIO down → Harbor 500 → MinIO @ImagePullBackOff@). Only
-- the substrate-specific storage class + size vary; everything else is fixed in the
-- chart's @values.yaml@. The @[String]@ output is a flat alternating
-- @["--set", "k=v", …]@ list ready to splice into a @helm upgrade --install@.
renderMinioChartArgs :: Substrate -> MinioImageSource -> String -> [String]
renderMinioChartArgs substrate _imageSource storageSize =
  let (minioImage, _minioMcImage) = minioChartImages MinioBootstrapPublic
   in [ "--set"
      , "image.repository=" ++ renderImageRefWithoutTag minioImage
      , "--set"
      , "image.tag=" ++ ContainerImage.imageTag minioImage
      , -- Sprint 7.25: inject the STATIC MinIO root credential directly, so the
        -- chart no longer reads it from Vault and MinIO depends only on the
        -- cluster (can come up before Vault to serve the unlock bundle).
        "--set"
      , "rootUser=" ++ minioRootUser
      , "--set"
      , "rootPassword=" ++ minioRootPassword
      ]
        ++ minioSubstratePersistenceArgs substrate storageSize

-- | Substrate-specific MinIO storage args for the @data@ volumeClaimTemplate:
-- both substrates use the retained @manual@ StorageClass. Home binds to the
-- hostPath PV at @.data/prodbox/minio/0@; AWS binds to the pre-created EBS
-- volume lifted in as a static CSI PV. Both are bounded at 20 GiB so the
-- default full-workflow resource plan fits a small single-node host.
minioSubstratePersistenceArgs :: Substrate -> String -> [String]
minioSubstratePersistenceArgs substrate storageSize =
  case substrate of
    SubstrateHomeLocal ->
      ["--set", "storage.className=manual", "--set", "storage.size=" ++ storageSize]
    SubstrateAws ->
      ["--set", "storage.className=manual", "--set", "storage.size=" ++ storageSize]

minioChartImages :: MinioImageSource -> (ContainerImage.ImageRef, ContainerImage.ImageRef)
minioChartImages imageSource =
  case imageSource of
    MinioBootstrapPublic ->
      (ContainerImage.publicMinioImage, ContainerImage.publicMinioMcImage)
    MinioSteadyStateHarbor ->
      (ContainerImage.harborMinioImage, ContainerImage.harborMinioMcImage)

ensureHarborRegistryStorageBackend :: FilePath -> IO ExitCode
ensureHarborRegistryStorageBackend repoRoot = do
  credentialsResult <- resolveHarborStorageCredentials repoRoot
  case credentialsResult of
    Left err -> failWith err
    Right (accessKey, secretKey) ->
      runSequentially
        [ runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments = harborRegistryStorageDeleteArguments
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        , withTemporaryJsonManifest
            "harbor-storage-backend"
            (harborStorageBackendManifestItems accessKey secretKey)
            ( \manifestPath ->
                runCommand
                  Subprocess
                    { subprocessPath = "kubectl"
                    , subprocessArguments = ["apply", "-f", manifestPath]
                    , subprocessEnvironment = Nothing
                    , subprocessWorkingDirectory = Just repoRoot
                    }
            )
        , runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments = harborRegistryStorageWaitArguments
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        , runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments = harborRegistryStorageDeleteArguments
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        ]

-- | Sprint 3.18: idempotently bootstrap the gateway daemon's MinIO surface
-- in one unified, Vault-backed pass:
--
--   1. Create the @gateway@ namespace if absent.
--   2. Apply a Job in the @minio@ namespace that authenticates to Vault with
--      the @minio@ ServiceAccount, materializes both the MinIO root
--      credentials and gateway MinIO user credentials on tmpfs, creates the
--      @prodbox-state@ bucket (idempotent), creates or updates the @prodbox-gateway@
--      user with the Vault-managed password, creates or updates the
--      @prodbox-gateway-policy@ IAM policy granting @s3:GetObject@ /
--      @s3:PutObject@ on @prodbox-state/*@ and @s3:ListBucket@ on @prodbox-state@, and
--      attaches the policy to the user.
--
-- Idempotent across reconciles: @mc admin user add@ silently overwrites the
-- password if it differs (ensuring MinIO state matches Vault); the named policy
-- is detached, removed, recreated, and reattached so permission drift is
-- repaired when the chart-side storage contract changes.
ensureGatewayMinioBootstrap :: FilePath -> IO ExitCode
ensureGatewayMinioBootstrap repoRoot = do
  -- Step 1: ensure gateway namespace exists.
  nsExit <-
    runCommand
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "create"
            , "namespace"
            , gatewayNamespace
            , "--dry-run=client"
            , "-o"
            , "yaml"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  case nsExit of
    ExitFailure _ -> pure nsExit
    ExitSuccess -> do
      _ <-
        runCommand
          Subprocess
            { subprocessPath = "sh"
            , subprocessArguments =
                [ "-c"
                , "kubectl create namespace "
                    ++ gatewayNamespace
                    ++ " --dry-run=client -o yaml | kubectl apply -f -"
                ]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
      -- Step 2: apply the Vault-backed MinIO bootstrap Job.
      runSequentially
        [ runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments =
                  [ "delete"
                  , "job"
                  , gatewayMinioBootstrapJobName
                  , "-n"
                  , minioNamespace
                  , "--ignore-not-found=true"
                  , "--wait=true"
                  ]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        , withTemporaryJsonManifest
            "gateway-minio-bootstrap"
            gatewayMinioBootstrapManifestItems
            ( \manifestPath ->
                runCommand
                  Subprocess
                    { subprocessPath = "kubectl"
                    , subprocessArguments = ["apply", "-f", manifestPath]
                    , subprocessEnvironment = Nothing
                    , subprocessWorkingDirectory = Just repoRoot
                    }
            )
        , runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments =
                  [ "wait"
                  , "--for=condition=complete"
                  , "job/" ++ gatewayMinioBootstrapJobName
                  , "-n"
                  , minioNamespace
                  , "--timeout=300s"
                  ]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        , runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments =
                  [ "delete"
                  , "job"
                  , gatewayMinioBootstrapJobName
                  , "-n"
                  , minioNamespace
                  , "--ignore-not-found=true"
                  , "--wait=true"
                  ]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        ]

generateMinioCredentials :: String -> String -> IO (Either String (String, String))
generateMinioCredentials label userPrefix = do
  freshUserSuffixResult <-
    try
      ( do
          handle <- openBinaryFile "/dev/urandom" ReadMode
          bytes <- BS.hGet handle 34
          hClose handle
          pure bytes
      )
      :: IO (Either SomeException BS.ByteString)
  case freshUserSuffixResult of
    Left e ->
      pure
        ( Left
            ( "failed to read /dev/urandom for "
                ++ label
                ++ " credentials: "
                ++ displayException e
            )
        )
    Right entropyBytes -> do
      let suffixHex =
            take 8 . concatMap (printf "%02x" :: Word8 -> String) . BS.unpack $
              BS.take 4 entropyBytes
          passwordBytes = BS.take 30 (BS.drop 4 entropyBytes)
          passwordBase64 =
            take 40 . filter isAsciiAlphaNumeric . BS8.unpack $
              Base64.encode passwordBytes
          password =
            passwordBase64
              ++ replicate (40 - length passwordBase64) 'A'
      pure (Right (userPrefix ++ suffixHex, password))
 where
  isAsciiAlphaNumeric c = isAsciiUpper c || isAsciiLower c || isDigit c

resolveHarborStorageCredentials :: FilePath -> IO (Either String (String, String))
resolveHarborStorageCredentials repoRoot = do
  existingResult <- readHarborStorageCredentialsSecret repoRoot
  case existingResult of
    Right creds -> pure (Right creds)
    Left _ -> generateMinioCredentials "harbor-storage" harborStorageUserPrefix

readHarborStorageCredentialsSecret :: FilePath -> IO (Either String (String, String))
readHarborStorageCredentialsSecret repoRoot = do
  accessKeyResult <- readHarborStorageSecretField "REGISTRY_STORAGE_S3_ACCESSKEY"
  secretKeyResult <- readHarborStorageSecretField "REGISTRY_STORAGE_S3_SECRETKEY"
  pure $ do
    accessKey <- accessKeyResult
    secretKey <- secretKeyResult
    let trimmedAccessKey = trimWhitespace accessKey
        trimmedSecretKey = trimWhitespace secretKey
    if not (isMinioAccessKeyArgumentSafe trimmedAccessKey)
      then Left "Harbor storage access key secret field is empty"
      else
        if not (isMinioSecretKeyArgumentSafe trimmedSecretKey)
          then Left "Harbor storage secret key field is empty or not argument-safe for mc"
          else Right (trimmedAccessKey, trimmedSecretKey)
 where
  readHarborStorageSecretField fieldName =
    runTextCommand
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "secret"
            , harborRegistryStorageSecretName
            , "-n"
            , harborNamespace
            , "-o"
            , "go-template={{index .data \"" ++ fieldName ++ "\" | base64decode}}"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }

isMinioAccessKeyArgumentSafe :: String -> Bool
isMinioAccessKeyArgumentSafe value =
  let trimmed = trimWhitespace value
   in trimmed /= "" && not ("-" `isPrefixOf` trimmed) && not (any isSpace trimmed)

isMinioSecretKeyArgumentSafe :: String -> Bool
isMinioSecretKeyArgumentSafe value =
  let trimmed = trimWhitespace value
   in trimmed /= "" && all isAsciiAlphaNumeric trimmed
 where
  isAsciiAlphaNumeric c = isAsciiUpper c || isAsciiLower c || isDigit c

-- | Bootstrap the retained ciphertext bucket and its two deliberately disjoint
-- MinIO principals in one idempotent pass.  The Gateway principal remains only
-- for the pre-cutover compatibility path; the Lifecycle Authority principal is
-- the production in-cluster owner and reads its credential from its own Vault
-- object.
gatewayMinioBootstrapManifestItems :: [Value]
gatewayMinioBootstrapManifestItems =
  [ object
      [ "apiVersion" .= ("batch/v1" :: String)
      , "kind" .= ("Job" :: String)
      , "metadata"
          .= object
            [ "name" .= gatewayMinioBootstrapJobName
            , "namespace" .= minioNamespace
            ]
      , "spec"
          .= object
            [ "backoffLimit" .= (3 :: Int)
            , "ttlSecondsAfterFinished" .= (60 :: Int)
            , "template"
                .= object
                  [ "spec"
                      .= object
                        [ "restartPolicy" .= ("OnFailure" :: String)
                        , "serviceAccountName" .= minioReleaseName
                        , "initContainers" .= [gatewayMinioVaultInitContainer]
                        , "volumes" .= [minioRootVaultMaterializedVolume]
                        , "containers"
                            .= [ object
                                   [ "name" .= ("gateway-minio-bootstrap" :: String)
                                   , "image" .= ContainerImage.renderImageRef ContainerImage.publicMinioMcImage
                                   , "command" .= ["sh" :: String, "-c"]
                                   , "args"
                                       .= [ unlines
                                              [ "set -eu"
                                              , "MINIO_ROOT_USER=\"$(cat \"$MINIO_ROOT_USER_FILE\")\""
                                              , "MINIO_ROOT_PASSWORD=\"$(cat \"$MINIO_ROOT_PASSWORD_FILE\")\""
                                              , "GW_USER=\"$(cat \"$GW_USER_FILE\")\""
                                              , "GW_PASS=\"$(cat \"$GW_PASS_FILE\")\""
                                              , "LA_USER=\"$(cat \"$LA_USER_FILE\")\""
                                              , "LA_PASS=\"$(cat \"$LA_PASS_FILE\")\""
                                              , "mc alias set local "
                                                  ++ minioClusterEndpoint
                                                  ++ " \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\""
                                              , "mc mb --ignore-existing local/" ++ defaultObjectStoreBucket
                                              , "mc admin user add local \"$GW_USER\" \"$GW_PASS\""
                                              , "cat > /tmp/policy.json <<'POLICY_EOF'"
                                              , gatewayMinioPolicyJson
                                              , "POLICY_EOF"
                                              , "mc admin policy detach local "
                                                  ++ gatewayMinioPolicyName
                                                  ++ " --user \"$GW_USER\" || true"
                                              , "mc admin policy rm local "
                                                  ++ gatewayMinioPolicyName
                                                  ++ " || true"
                                              , "mc admin policy create local "
                                                  ++ gatewayMinioPolicyName
                                                  ++ " /tmp/policy.json"
                                              , "mc admin policy attach local "
                                                  ++ gatewayMinioPolicyName
                                                  ++ " --user \"$GW_USER\""
                                              , "mc admin user add local \"$LA_USER\" \"$LA_PASS\""
                                              , "cat > /tmp/lifecycle-authority-policy.json <<'POLICY_EOF'"
                                              , lifecycleAuthorityMinioPolicyJson
                                              , "POLICY_EOF"
                                              , "mc admin policy detach local "
                                                  ++ lifecycleAuthorityMinioPolicyName
                                                  ++ " --user \"$LA_USER\" || true"
                                              , "mc admin policy rm local "
                                                  ++ lifecycleAuthorityMinioPolicyName
                                                  ++ " || true"
                                              , "mc admin policy create local "
                                                  ++ lifecycleAuthorityMinioPolicyName
                                                  ++ " /tmp/lifecycle-authority-policy.json"
                                              , "mc admin policy attach local "
                                                  ++ lifecycleAuthorityMinioPolicyName
                                                  ++ " --user \"$LA_USER\""
                                              ]
                                          ]
                                   , "env"
                                       .= ( minioRootFileEnv
                                              ++ gatewayMinioFileEnv
                                              ++ lifecycleAuthorityMinioFileEnv
                                          )
                                   , "volumeMounts" .= [minioRootVaultMaterializedVolumeMount]
                                   ]
                               ]
                        ]
                  ]
            ]
      ]
  ]

-- | Canonical IAM policy granting the @prodbox-gateway@ principal the
-- minimum permissions needed for gateway-owned object-store reads/writes:
-- @s3:GetObject@/@s3:PutObject@ on @prodbox-state/*@ plus @s3:ListBucket@ on
-- @prodbox-state@.
gatewayMinioPolicyJson :: String
gatewayMinioPolicyJson =
  unlines
    [ "{"
    , "  \"Version\": \"2012-10-17\","
    , "  \"Statement\": ["
    , "    {"
    , "      \"Effect\": \"Allow\","
    , "      \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:DeleteObject\"],"
    , "      \"Resource\": [\"arn:aws:s3:::" ++ defaultObjectStoreBucket ++ "/*\"]"
    , "    },"
    , "    {"
    , "      \"Effect\": \"Allow\","
    , "      \"Action\": [\"s3:ListBucket\"],"
    , "      \"Resource\": [\"arn:aws:s3:::" ++ defaultObjectStoreBucket ++ "\"]"
    , "    }"
    , "  ]"
    , "}"
    ]

-- | The Authority owns the same opaque retained-object namespace during
-- cutover, including deletion during its typed lifecycle programs.  It has no
-- permission to any other bucket.
lifecycleAuthorityMinioPolicyJson :: String
lifecycleAuthorityMinioPolicyJson = gatewayMinioPolicyJson

harborStoragePolicyJson :: String
harborStoragePolicyJson =
  unlines
    [ "{"
    , "  \"Version\": \"2012-10-17\","
    , "  \"Statement\": ["
    , "    {"
    , "      \"Effect\": \"Allow\","
    , "      \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:DeleteObject\", \"s3:AbortMultipartUpload\", \"s3:ListMultipartUploadParts\"],"
    , "      \"Resource\": [\"arn:aws:s3:::" ++ harborRegistryStorageBucket ++ "/*\"]"
    , "    },"
    , "    {"
    , "      \"Effect\": \"Allow\","
    , "      \"Action\": [\"s3:ListBucket\", \"s3:GetBucketLocation\", \"s3:ListBucketMultipartUploads\"],"
    , "      \"Resource\": [\"arn:aws:s3:::" ++ harborRegistryStorageBucket ++ "\"]"
    , "    }"
    , "  ]"
    , "}"
    ]

minioRootVaultMaterializedVolumeName :: String
minioRootVaultMaterializedVolumeName = "minio-root-vault"

minioRootVaultMaterializedPath :: String
minioRootVaultMaterializedPath = "/vault-materialized"

gatewayMinioVaultInitContainer :: Value
gatewayMinioVaultInitContainer =
  object
    [ "name" .= ("vault-gateway-minio" :: String)
    , "image" .= ("hashicorp/vault:1.18.3" :: String)
    , "imagePullPolicy" .= ("IfNotPresent" :: String)
    , "env"
        .= [ object
               [ "name" .= ("VAULT_ADDR" :: String)
               , "value" .= ("http://vault.vault.svc.cluster.local:8200" :: String)
               ]
           , object
               [ "name" .= ("VAULT_AUTH_PATH" :: String)
               , "value" .= ("kubernetes" :: String)
               ]
           , object
               [ "name" .= ("VAULT_ROLE" :: String)
               , "value" .= ("gateway-minio-bootstrap" :: String)
               ]
           , object
               [ "name" .= ("VAULT_SA_TOKEN_FILE" :: String)
               , "value" .= ("/var/run/secrets/kubernetes.io/serviceaccount/token" :: String)
               ]
           ]
    , "command" .= ["sh" :: String, "-ec"]
    , "args"
        .= [ unlines
               [ "set -eu"
               , "jwt=\"$(cat \"${VAULT_SA_TOKEN_FILE}\")\""
               , "export VAULT_TOKEN=\"$(vault write -field=token \"auth/${VAULT_AUTH_PATH}/login\" role=\"${VAULT_ROLE}\" jwt=\"${jwt}\")\""
               , "umask 077"
               , "vault kv get -field=rootUser secret/minio/root > "
                   ++ minioRootVaultMaterializedPath
                   ++ "/rootUser"
               , "vault kv get -field=rootPassword secret/minio/root > "
                   ++ minioRootVaultMaterializedPath
                   ++ "/rootPassword"
               , "vault kv get -field=minio_access_key secret/gateway/gateway/minio > "
                   ++ minioRootVaultMaterializedPath
                   ++ "/gatewayMinioAccessKey"
               , "vault kv get -field=minio_secret_key secret/gateway/gateway/minio > "
                   ++ minioRootVaultMaterializedPath
                   ++ "/gatewayMinioSecretKey"
               , "vault kv get -field=minio_access_key secret/minio/lifecycle-authority > "
                   ++ minioRootVaultMaterializedPath
                   ++ "/lifecycleAuthorityMinioAccessKey"
               , "vault kv get -field=minio_secret_key secret/minio/lifecycle-authority > "
                   ++ minioRootVaultMaterializedPath
                   ++ "/lifecycleAuthorityMinioSecretKey"
               ]
           ]
    , "volumeMounts" .= [minioRootVaultMaterializedInitVolumeMount]
    ]

minioRootFileEnv :: [Value]
minioRootFileEnv =
  [ object
      [ "name" .= ("MINIO_ROOT_USER_FILE" :: String)
      , "value" .= (minioRootVaultMaterializedPath ++ "/rootUser")
      ]
  , object
      [ "name" .= ("MINIO_ROOT_PASSWORD_FILE" :: String)
      , "value" .= (minioRootVaultMaterializedPath ++ "/rootPassword")
      ]
  ]

gatewayMinioFileEnv :: [Value]
gatewayMinioFileEnv =
  [ object
      [ "name" .= ("GW_USER_FILE" :: String)
      , "value" .= (minioRootVaultMaterializedPath ++ "/gatewayMinioAccessKey")
      ]
  , object
      [ "name" .= ("GW_PASS_FILE" :: String)
      , "value" .= (minioRootVaultMaterializedPath ++ "/gatewayMinioSecretKey")
      ]
  ]

lifecycleAuthorityMinioFileEnv :: [Value]
lifecycleAuthorityMinioFileEnv =
  [ object
      [ "name" .= ("LA_USER_FILE" :: String)
      , "value" .= (minioRootVaultMaterializedPath ++ "/lifecycleAuthorityMinioAccessKey")
      ]
  , object
      [ "name" .= ("LA_PASS_FILE" :: String)
      , "value" .= (minioRootVaultMaterializedPath ++ "/lifecycleAuthorityMinioSecretKey")
      ]
  ]

minioRootVaultMaterializedVolumeMount :: Value
minioRootVaultMaterializedVolumeMount =
  object
    [ "name" .= minioRootVaultMaterializedVolumeName
    , "mountPath" .= minioRootVaultMaterializedPath
    , "readOnly" .= True
    ]

minioRootVaultMaterializedInitVolumeMount :: Value
minioRootVaultMaterializedInitVolumeMount =
  object
    [ "name" .= minioRootVaultMaterializedVolumeName
    , "mountPath" .= minioRootVaultMaterializedPath
    ]

minioRootVaultMaterializedVolume :: Value
minioRootVaultMaterializedVolume =
  object
    [ "name" .= minioRootVaultMaterializedVolumeName
    , "emptyDir"
        .= object
          [ "medium" .= ("Memory" :: String)
          , "sizeLimit" .= ("1Mi" :: String)
          ]
    ]

harborStorageBackendManifestItems :: String -> String -> [Value]
harborStorageBackendManifestItems accessKey secretKey =
  [ object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("Namespace" :: String)
      , "metadata"
          .= object
            [ "name" .= harborNamespace
            ]
      ]
  , object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("Secret" :: String)
      , "metadata"
          .= object
            [ "name" .= harborRegistryStorageSecretName
            , "namespace" .= harborNamespace
            ]
      , "type" .= ("Opaque" :: String)
      , "stringData"
          .= object
            [ "REGISTRY_STORAGE_S3_ACCESSKEY" .= accessKey
            , "REGISTRY_STORAGE_S3_SECRETKEY" .= secretKey
            ]
      ]
  , object
      [ "apiVersion" .= ("batch/v1" :: String)
      , "kind" .= ("Job" :: String)
      , "metadata"
          .= object
            [ "name" .= harborRegistryStorageBootstrapJobName
            , "namespace" .= minioNamespace
            ]
      , "spec"
          .= object
            [ "backoffLimit" .= (3 :: Int)
            , -- The creating reconcile waits for this exact Job and explicitly
              -- deletes it afterwards. A TTL controller could remove terminal
              -- evidence before that bounded waiter observes it.
              "template"
                .= object
                  [ "spec"
                      .= object
                        [ "restartPolicy" .= ("OnFailure" :: String)
                        , -- Sprint 7.25 follow-up: the MinIO root credential is a fixed static
                          -- constant (Prodbox.Minio.RootCredential) — the registered
                          -- bootstrap-floor credential of vault_doctrine.md §6.1, identical
                          -- to the @secret/minio/root@ Vault value and injected directly into the
                          -- MinIO chart. This bootstrap Job runs BEFORE the daemon-mediated Vault
                          -- init/unseal (which itself depends on Harbor via the gateway image), so
                          -- it must NOT read from Vault. It uses the static constant directly,
                          -- mirroring 'ensureMinioRuntime'. (The gateway MinIO bootstrap Job runs
                          -- AFTER Vault is up and still materializes creds from Vault.)
                          "serviceAccountName" .= minioReleaseName
                        , "containers"
                            .= [ object
                                   [ "name" .= ("bucket-bootstrap" :: String)
                                   , "image" .= ContainerImage.renderImageRef ContainerImage.publicMinioMcImage
                                   , "command" .= ["sh" :: String, "-c"]
                                   , "args"
                                       .= [ unlines
                                              [ "set -eu"
                                              , "mc alias set local " ++ minioClusterEndpoint ++ " \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\""
                                              , "mc mb --ignore-existing local/" ++ harborRegistryStorageBucket
                                              , "mc admin user add local \"$HARBOR_STORAGE_ACCESS_KEY\" \"$HARBOR_STORAGE_SECRET_KEY\""
                                              , "cat > /tmp/policy.json <<'POLICY_EOF'"
                                              , harborStoragePolicyJson
                                              , "POLICY_EOF"
                                              , "mc admin policy detach local "
                                                  ++ harborStoragePolicyName
                                                  ++ " --user \"$HARBOR_STORAGE_ACCESS_KEY\" || true"
                                              , "mc admin policy rm local "
                                                  ++ harborStoragePolicyName
                                                  ++ " || true"
                                              , "mc admin policy create local "
                                                  ++ harborStoragePolicyName
                                                  ++ " /tmp/policy.json"
                                              , "mc admin policy attach local "
                                                  ++ harborStoragePolicyName
                                                  ++ " --user \"$HARBOR_STORAGE_ACCESS_KEY\""
                                              ]
                                          ]
                                   , "env"
                                       .= [ object
                                              [ "name" .= ("MINIO_ROOT_USER" :: String)
                                              , "value" .= minioRootUser
                                              ]
                                          , object
                                              [ "name" .= ("MINIO_ROOT_PASSWORD" :: String)
                                              , "value" .= minioRootPassword
                                              ]
                                          , object
                                              [ "name" .= ("HARBOR_STORAGE_ACCESS_KEY" :: String)
                                              , "value" .= accessKey
                                              ]
                                          , object
                                              [ "name" .= ("HARBOR_STORAGE_SECRET_KEY" :: String)
                                              , "value" .= secretKey
                                              ]
                                          ]
                                   ]
                               ]
                        ]
                  ]
            ]
      ]
  ]

-- | Stand up the in-cluster OCI registry: a single-binary CNCF @distribution@
-- (@registry:2@) Deployment + NodePort Service applied with @kubectl@ (no Helm,
-- no multi-pod chart), backed by the MinIO/S3 storage bootstrapped by
-- 'ensureHarborRegistryStorageBackend'. @registry:2@ is anonymous over HTTP —
-- a @localhost@ NodePort is insecure-by-default in Docker, so pushes need no
-- @docker login@ and no TLS — and auto-creates the @prodbox/<repo>@ path on
-- first push, so there is no projects API to reconcile. The same Deployment
-- serves both substrates; @registry:2@ ships one multi-arch manifest, so the
-- node pulls the native platform with no per-component override.
ensureHarborRegistryRuntime :: FilePath -> Substrate -> IO ExitCode
ensureHarborRegistryRuntime repoRoot _substrate = do
  -- Remove any prior Harbor helm release so its multi-pod stack (core, nginx,
  -- portal, jobservice, bundled db/redis) does not linger beside the
  -- single-binary registry:2 Deployment on a rebuilt-in-place cluster. The
  -- registry:2 Deployment/Service/ConfigMap and the storage Secret are applied
  -- separately (kubectl), so uninstalling the release does not touch them.
  cleanupExit <- reconcileLegacyHarborReleaseAbsent repoRoot
  case cleanupExit of
    ExitFailure _ -> pure cleanupExit
    ExitSuccess -> do
      installExit <-
        withTemporaryJsonManifest
          "prodbox-registry-runtime"
          registryRuntimeManifestItems
          ( \manifestPath ->
              runCommand
                Subprocess
                  { subprocessPath = "kubectl"
                  , subprocessArguments = ["apply", "-f", manifestPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
          )
      case installExit of
        ExitFailure _ -> pure installExit
        ExitSuccess ->
          -- Wait for the Deployment to become Available (the pod's first,
          -- unauthenticated registry:2 pull can be slow), then confirm the NodePort
          -- serves GET /v2/ and holds stable before the mirror loop pushes.
          runSequentially
            [ waitForDeployment repoRoot harborNamespace registryDeploymentName
            , waitForHarborRegistryEndpoint repoRoot
            , waitForHarborStableEndpoints repoRoot
            ]

-- | The superseded Harbor release is a registered desired-absence resource.
-- A registry:2 apply is illegal until Helm authoritatively reports that exact
-- release absent; cluster/API failures are not treated as absence.
reconcileLegacyHarborReleaseAbsent :: FilePath -> IO ExitCode
reconcileLegacyHarborReleaseAbsent repoRoot =
  ResourceRegistry.resourceDestroy ResourceRegistry.legacyHarborHelmResource repoRoot

-- | The registry:2 runtime manifest: a ConfigMap holding the @registry:2@
-- @config.yml@ (S3 storage driver pointed at the MinIO-backed
-- @prodbox-harbor-registry@ bucket), a single-replica Deployment, and a
-- NodePort Service on 30080. The S3 access/secret keys are injected from the
-- 'harborRegistryStorageSecretName' Secret via @envFrom@ (its keys are already
-- registry:2's native @REGISTRY_STORAGE_S3_ACCESSKEY@/@SECRETKEY@ overrides),
-- so no credential is written into the ConfigMap. The Service keeps the
-- @harbor@ name/port 80 so the EKS-side in-cluster DNS
-- @harbor.harbor.svc.cluster.local@ is unchanged.
registryRuntimeManifestItems :: [Value]
registryRuntimeManifestItems =
  [ object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("Namespace" :: String)
      , "metadata" .= object ["name" .= harborNamespace]
      ]
  , object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("ConfigMap" :: String)
      , "metadata"
          .= object
            [ "name" .= registryConfigMapName
            , "namespace" .= harborNamespace
            ]
      , "data" .= object ["config.yml" .= registryConfigYaml harborRegistryStorageBackend]
      ]
  , object
      [ "apiVersion" .= ("apps/v1" :: String)
      , "kind" .= ("Deployment" :: String)
      , "metadata"
          .= object
            [ "name" .= registryDeploymentName
            , "namespace" .= harborNamespace
            , "labels" .= object ["app" .= registryDeploymentName]
            ]
      , "spec"
          .= object
            [ "replicas" .= (1 :: Int)
            , "selector" .= object ["matchLabels" .= object ["app" .= registryDeploymentName]]
            , "template"
                .= object
                  [ "metadata" .= object ["labels" .= object ["app" .= registryDeploymentName]]
                  , "spec"
                      .= object
                        [ "containers"
                            .= ( [ object
                                     [ "name" .= registryDeploymentName
                                     , "image" .= registryImage
                                     , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                     , "ports" .= ([object ["containerPort" .= registryContainerPort]] :: [Value])
                                     , "envFrom"
                                         .= ( [ object
                                                  [ "secretRef"
                                                      .= object ["name" .= harborRegistryStorageSecretName]
                                                  ]
                                              ]
                                                :: [Value]
                                            )
                                     , "volumeMounts"
                                         .= ( [ object
                                                  [ "name" .= registryConfigMapName
                                                  , "mountPath" .= ("/etc/docker/registry/config.yml" :: String)
                                                  , "subPath" .= ("config.yml" :: String)
                                                  ]
                                              ]
                                                :: [Value]
                                            )
                                     , -- Gate the Service endpoints on the registry actually serving
                                       -- GET /v2/, so the mirror push cannot race a scheduled-but-not-
                                       -- yet-listening registry. A generous failureThreshold tolerates
                                       -- a slow first (unauthenticated) registry:2 pull.
                                       "readinessProbe"
                                         .= object
                                           [ "httpGet" .= object ["path" .= ("/v2/" :: String), "port" .= registryContainerPort]
                                           , "periodSeconds" .= (5 :: Int)
                                           , "failureThreshold" .= (60 :: Int)
                                           ]
                                     ]
                                 ]
                                   :: [Value]
                               )
                        , "volumes"
                            .= ( [ object
                                     [ "name" .= registryConfigMapName
                                     , "configMap" .= object ["name" .= registryConfigMapName]
                                     ]
                                 ]
                                   :: [Value]
                               )
                        ]
                  ]
            ]
      ]
  , object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("Service" :: String)
      , "metadata"
          .= object
            [ "name" .= harborServiceName
            , "namespace" .= harborNamespace
            ]
      , "spec"
          .= object
            [ "type" .= ("NodePort" :: String)
            , "selector" .= object ["app" .= registryDeploymentName]
            , "ports"
                .= ( [ object
                         [ "port" .= harborServicePort
                         , "targetPort" .= registryContainerPort
                         , "nodePort" .= (30080 :: Int)
                         ]
                     ]
                       :: [Value]
                   )
            ]
      ]
  ]

-- | Blob redirect behavior for the registry storage driver. This is a required
-- field of 'RegistryStorageBackend': callers cannot silently inherit the
-- registry driver's redirect default.
data RedirectPolicy
  = RedirectDisabled
  | RedirectEnabled
  deriving (Eq, Show)

-- | Typed S3-compatible storage backend for @registry:2@. Credentials remain
-- runtime environment overrides and therefore never enter this record.
data RegistryStorageBackend = RegistryStorageBackend
  { registryStorageBackendRegion :: String
  , registryStorageBackendEndpoint :: String
  , registryStorageBackendBucket :: String
  , registryStorageBackendSecure :: Bool
  , registryStorageBackendV4Auth :: Bool
  , registryStorageBackendRootDirectory :: String
  , registryStorageBackendRedirect :: RedirectPolicy
  , registryStorageBackendDeleteEnabled :: Bool
  }
  deriving (Eq, Show)

-- | The canonical MinIO-backed storage record for the in-cluster registry.
-- The load-bearing redirect choice is explicit: the host-side localhost
-- NodePort cannot follow presigned redirects to cluster-only DNS.
harborRegistryStorageBackend :: RegistryStorageBackend
harborRegistryStorageBackend =
  RegistryStorageBackend
    { registryStorageBackendRegion = minioSigningRegion
    , registryStorageBackendEndpoint = minioClusterEndpoint
    , registryStorageBackendBucket = harborRegistryStorageBucket
    , registryStorageBackendSecure = False
    , registryStorageBackendV4Auth = True
    , registryStorageBackendRootDirectory = "/"
    , registryStorageBackendRedirect = RedirectDisabled
    , registryStorageBackendDeleteEnabled = True
    }

-- | Render the @registry:2@ @config.yml@ from its typed storage record. The
-- @accesskey@/@secretkey@ are supplied at runtime via
-- @REGISTRY_STORAGE_S3_ACCESSKEY@/@SECRETKEY@, so no credential appears here.
registryConfigYaml :: RegistryStorageBackend -> String
registryConfigYaml backend =
  unlines
    [ "version: 0.1"
    , "log:"
    , "  fields:"
    , "    service: registry"
    , "storage:"
    , "  cache:"
    , "    blobdescriptor: inmemory"
    , "  redirect:"
    , "    disable: " ++ renderRedirectDisabled (registryStorageBackendRedirect backend)
    , "  s3:"
    , "    region: " ++ registryStorageBackendRegion backend
    , "    regionendpoint: " ++ registryStorageBackendEndpoint backend
    , "    bucket: " ++ registryStorageBackendBucket backend
    , "    secure: " ++ renderYamlBool (registryStorageBackendSecure backend)
    , "    v4auth: " ++ renderYamlBool (registryStorageBackendV4Auth backend)
    , "    rootdirectory: " ++ registryStorageBackendRootDirectory backend
    , "  delete:"
    , "    enabled: " ++ renderYamlBool (registryStorageBackendDeleteEnabled backend)
    , "http:"
    , "  addr: :" ++ show registryContainerPort
    , "health:"
    , "  storagedriver:"
    , "    enabled: true"
    , "    interval: 10s"
    , "    threshold: 3"
    ]

renderRedirectDisabled :: RedirectPolicy -> String
renderRedirectDisabled policy =
  case policy of
    RedirectDisabled -> "true"
    RedirectEnabled -> "false"

renderYamlBool :: Bool -> String
renderYamlBool value =
  case value of
    True -> "true"
    False -> "false"

waitForDeployment :: FilePath -> String -> String -> IO ExitCode
waitForDeployment repoRoot namespace deploymentName =
  runCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "wait"
          , "--for=condition=Available"
          , "deployment/" ++ deploymentName
          , "-n"
          , namespace
          , "--timeout=300s"
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

waitForHarborRegistryEndpoint :: FilePath -> IO ExitCode
waitForHarborRegistryEndpoint repoRoot =
  waitForHarborHttpStatus repoRoot "/v2/" ["200", "401"] "registry endpoint"

-- | Require several consecutive successful @GET /v2/@ rounds on the registry
-- NodePort before any image write continues on a fresh cluster, so the mirror
-- loop never races a scheduled-but-not-yet-serving registry.
waitForHarborStableEndpoints :: FilePath -> IO ExitCode
waitForHarborStableEndpoints repoRoot =
  go harborEndpointStabilityAttempts 0 "registry endpoint not yet checked"
 where
  go :: Int -> Int -> String -> IO ExitCode
  go attemptsRemaining consecutiveSuccesses lastDetail
    | consecutiveSuccesses >= harborEndpointStabilitySuccesses = pure ExitSuccess
    | attemptsRemaining <= 0 =
        failWith
          ( "Failed to observe a stable registry endpoint before continuing: "
              ++ lastDetail
          )
    | otherwise = do
        registryStatusResult <- probeHarborHttpStatus repoRoot "/v2/"
        case registryStatusResult of
          Right registryStatus
            | registryStatus `elem` ["200", "401"] ->
                let nextSuccesses = consecutiveSuccesses + 1
                 in if nextSuccesses >= harborEndpointStabilitySuccesses
                      then pure ExitSuccess
                      else retry attemptsRemaining nextSuccesses "registry endpoint is stable"
          Left err -> retry attemptsRemaining 0 err
          Right registryStatus ->
            retry
              attemptsRemaining
              0
              ("unexpected registry status: /v2/=" ++ registryStatus)

  retry :: Int -> Int -> String -> IO ExitCode
  retry attemptsRemaining consecutiveSuccesses detail = do
    threadDelay harborEndpointStabilityDelayMicroseconds
    go (attemptsRemaining - 1) consecutiveSuccesses detail

waitForHarborHttpStatus :: FilePath -> String -> [String] -> String -> IO ExitCode
waitForHarborHttpStatus repoRoot path expectedStatuses description =
  go harborEndpointReadinessAttempts "HTTP endpoint not yet checked"
 where
  go :: Int -> String -> IO ExitCode
  go attemptsRemaining lastDetail
    | attemptsRemaining <= 0 =
        failWith ("Failed to observe " ++ description ++ " before continuing: " ++ lastDetail)
    | otherwise = do
        statusResult <- probeHarborHttpStatus repoRoot path
        case statusResult of
          Left err -> retry attemptsRemaining err
          Right statusCode ->
            if statusCode `elem` expectedStatuses
              then pure ExitSuccess
              else retry attemptsRemaining ("HTTP " ++ statusCode)

  retry :: Int -> String -> IO ExitCode
  retry attemptsRemaining detail = do
    threadDelay harborEndpointReadinessDelayMicroseconds
    go (attemptsRemaining - 1) detail

probeHarborHttpStatus :: FilePath -> String -> IO (Either String String)
probeHarborHttpStatus repoRoot path = do
  outputResult <-
    captureToolOutput
      repoRoot
      "curl"
      [ "-sS"
      , "--max-time"
      , "5"
      , "-o"
      , "/dev/null"
      , "-w"
      , "%{http_code}"
      , "http://" ++ harborRegistryEndpoint ++ path
      ]
  pure $
    case outputResult of
      Left err -> Left err
      Right output ->
        case processExitCode output of
          ExitSuccess -> Right (trimWhitespace (processStdout output))
          ExitFailure _ -> Left (outputDetail output)

-- | Sprint 4.43: the deep registry→MinIO S3 storage-backend readiness gate
-- (bootstrap_readiness_doctrine.md M3). A @GET /v2/@ front-door probe is served
-- by @registry:2@ __without touching S3__, so it never proves the registry can
-- reach its MinIO storage backend — the exact shallow gate that left the
-- @dial tcp: lookup minio.prodbox.svc.cluster.local: no such host@ race open at
-- the image-mirror push. This gate exercises the __same edge the mirror push
-- uses__: it opens a blob-upload session against the registry
-- (@POST /v2/<name>/blobs/uploads/@), which the S3 storage driver services by
-- writing an upload record to MinIO. A @202 Accepted@ therefore proves the
-- registry reached MinIO S3; a curl-level failure is 'RegistryEdgeUnreachable'
-- (gates closed, doctrine Statement 4); any non-2xx status is
-- 'RegistryEdgeNotReady' (retryable — MinIO may be transiently unreachable from
-- the registry pod). It runs before 'mirrorClusterImagesOnce' and before any
-- runtime/custom-image push.
data RegistryStorageEdgeReadiness
  = RegistryEdgeReady
  | RegistryEdgeNotReady String
  | RegistryEdgeUnreachable String
  deriving (Eq, Show)

-- | The anonymous repository name the deep-gate blob-upload probe targets. It is
-- never committed — an incomplete upload session the registry garbage-collects.
registryStorageEdgeProbeRepository :: String
registryStorageEdgeProbeRepository = "prodbox-readiness-probe"

-- | Pure classification of the deep-gate probe result (M3). A curl-level failure
-- (the registry NodePort unreachable) is 'RegistryEdgeUnreachable' and gates
-- closed; a @201@/@202@ upload session proves the S3 write edge; any other status
-- (including a registry @5xx@ when it cannot reach MinIO) is retryable
-- 'RegistryEdgeNotReady'.
classifyRegistryStorageEdgeProbe :: Either String String -> RegistryStorageEdgeReadiness
classifyRegistryStorageEdgeProbe result =
  case result of
    Left err -> RegistryEdgeUnreachable err
    Right status
      | status `elem` ["201", "202"] -> RegistryEdgeReady
      | otherwise ->
          RegistryEdgeNotReady ("registry storage-backend probe returned HTTP " ++ status)

-- | Open a blob-upload session against the registry NodePort — the real
-- registry→MinIO S3 write round-trip the deep gate needs (see
-- 'RegistryStorageEdgeReadiness').
-- | Sprint 1.76: what one registry storage-backend probe observed — the HTTP
-- status the registry answered with, and the upload session it named. The
-- session is the receipt of the write-through to MinIO; before this sprint the
-- probe requested only the status and discarded the receipt, which is why the
-- deep gate had nothing to carry as evidence.
data RegistryStorageEdgeObservation = RegistryStorageEdgeObservation
  { registryProbeStatus :: String
  , registryProbeUploadSession :: String
  }
  deriving (Eq, Show)

-- | Sprint 1.76: the instant a deep probe observed its round trip land. Read
-- immediately after the probe returns, so the witness carries the write's
-- instant rather than the instant somebody later folded the evidence.
readinessWallClockNow :: IO AuthorityTime
readinessWallClockNow = do
  posix <- getPOSIXTime
  pure (authorityTimeFromMicros (fromInteger (max 0 (floor (toRational posix * 1000000) :: Integer))))

probeRegistryStorageBackendEdge
  :: FilePath -> IO (Either String RegistryStorageEdgeObservation)
probeRegistryStorageBackendEdge repoRoot = do
  outputResult <-
    captureToolOutput
      repoRoot
      "curl"
      [ "-sS"
      , "--max-time"
      , "10"
      , "-X"
      , "POST"
      , "-o"
      , "/dev/null"
      , "-D"
      , "-"
      , "-w"
      , "\n%{http_code}"
      , "http://"
          ++ harborRegistryEndpoint
          ++ "/v2/"
          ++ registryStorageEdgeProbeRepository
          ++ "/blobs/uploads/"
      ]
  pure $
    case outputResult of
      Left err -> Left err
      Right output ->
        case processExitCode output of
          ExitSuccess -> Right (parseRegistryStorageEdgeResponse (processStdout output))
          ExitFailure _ -> Left (outputDetail output)

-- | Split a @curl -D - -w "\n%{http_code}"@ response into the status the probe
-- asked for and the upload session the registry named. Pure, so the parse is
-- exercised without a live registry.
parseRegistryStorageEdgeResponse :: String -> RegistryStorageEdgeObservation
parseRegistryStorageEdgeResponse raw =
  RegistryStorageEdgeObservation
    { registryProbeStatus = status
    , registryProbeUploadSession = session
    }
 where
  responseLines = map trimWhitespace (lines raw)
  nonEmpty = [entry | entry <- responseLines, not (null entry)]
  status = case reverse nonEmpty of
    (final : _) -> final
    [] -> ""
  session =
    case headerValues "docker-upload-uuid" ++ headerValues "location" of
      (value : _) -> value
      [] -> ""

  -- The registry names the session it created in `Docker-Upload-UUID`, and
  -- names where to continue it in `Location`. Either identifies the write the
  -- registry performed; the UUID is preferred deterministically because it is
  -- the identifier the registry itself allocated rather than a URL it composed.
  headerValues wanted =
    [ value
    | entry <- responseLines
    , (name, ':' : rest) <- [break (== ':') entry]
    , map toLower (trimWhitespace name) == wanted
    , let value = trimWhitespace rest
    , not (null value)
    ]

-- | Sprint 4.43: poll the deep registry→MinIO edge gate until it proves the S3
-- write path, refusing (gating closed) on exhaustion. This is the registry
-- component's real readiness barrier (graph @ProbeBackendRoundTrip minio@),
-- gating the mirror push and every downstream registry write.
ensureRegistryStorageBackendEdgeReady :: FilePath -> IO ExitCode
ensureRegistryStorageBackendEdgeReady repoRoot =
  go harborEndpointReadinessAttempts "registry storage-backend edge not yet checked"
 where
  go :: Int -> String -> IO ExitCode
  go attemptsRemaining lastDetail
    | attemptsRemaining <= 0 =
        failWith
          ( "Failed to prove the registry->MinIO S3 storage-backend edge before continuing. "
              ++ "A GET /v2/ front-door probe does not exercise this edge "
              ++ "(bootstrap_readiness_doctrine.md M3); last observation: "
              ++ lastDetail
          )
    | otherwise = do
        probeResult <- probeRegistryStorageBackendEdge repoRoot
        case classifyRegistryStorageEdgeProbe (fmap registryProbeStatus probeResult) of
          RegistryEdgeReady -> pure ExitSuccess
          RegistryEdgeNotReady detail -> retry attemptsRemaining detail
          RegistryEdgeUnreachable detail -> retry attemptsRemaining ("unreachable: " ++ detail)

  retry :: Int -> String -> IO ExitCode
  retry attemptsRemaining detail = do
    threadDelay harborEndpointReadinessDelayMicroseconds
    go (attemptsRemaining - 1) detail

-- | Sprint 7.12: the shared platform components the HOME-substrate install
-- path stands up. The lower-layer pieces ('ensureMetalLbRuntime' — MetalLB,
-- and the in-cluster Harbor NodePort) are intentionally substrate-specific
-- and are NOT part of the shared inventory. This list is asserted equal (as
-- a set) to 'ContainerImage.sharedPlatformComponents' by the
-- 'test/unit/Main.hs' coverage test, so the home install can never silently
-- omit a shared component.
--
-- The seven canonical workload charts (@gateway@, @keycloak@,
-- @keycloak-postgres@, @vscode@, @api@, @redis@, @websocket@) are deployed
-- through the substrate-independent 'Prodbox.Lib.ChartPlatform'
-- ('supportedChartNames' plus the @keycloak-postgres@ / @redis@
-- dependencies) on BOTH substrates; the platform pieces (Envoy Gateway,
-- cert-manager, ZeroSSL DNS01, the Percona operator, MinIO, Harbor) are
-- stood up by 'applyNativeInstallPlan' / 'ensureClusterPlatformRuntime'
-- here.
homeSubstratePlatformComponents :: [ContainerImage.PlatformComponent]
homeSubstratePlatformComponents =
  [ ContainerImage.ComponentGateway
  , ContainerImage.ComponentKeycloak
  , ContainerImage.ComponentKeycloakPostgres
  , ContainerImage.ComponentVscode
  , ContainerImage.ComponentApi
  , ContainerImage.ComponentRedis
  , ContainerImage.ComponentWebsocket
  , ContainerImage.ComponentMinio
  , ContainerImage.ComponentHarbor
  , ContainerImage.ComponentPerconaPostgresOperator
  , ContainerImage.ComponentEnvoyGateway
  , ContainerImage.ComponentCertManager
  , ContainerImage.ComponentZeroSslDns01
  , ContainerImage.ComponentVault
  ]

-- | Reconcile the non-secret, retained-local substrate for permit-created
-- Credential Provisioner Jobs and accept it only after an independent exact
-- observation.  No Job or credential material is part of this step.
ensureCredentialProvisionerSubstrateReady :: FilePath -> IO ExitCode
ensureCredentialProvisionerSubstrateReady repoRoot = do
  apiCoordinateResult <- readKubernetesApiEgressCoordinate
  case apiCoordinateResult of
    Left err ->
      failWith
        ( "Credential Provisioner Kubernetes API egress observation failed: "
            ++ err
        )
    Right apiCoordinate -> do
      reconciled <-
        reconcileCredentialProvisionerSubstrate
          apiCoordinate
          (productionCredentialProvisionerSubstrateBoundary repoRoot)
      case reconciled of
        Left err ->
          failWith
            ( "Credential Provisioner execution substrate reconciliation failed: "
                ++ show err
            )
        Right () -> pure ExitSuccess

-- | Reconcile one internal control-plane chart in its own namespace. The
-- component graph still carries role-to-role edges so the native plan derives
-- the production order, while this projection deliberately selects only the
-- root release from ChartPlatform's dependency-expanded plan: standing roles
-- have distinct namespaces, ServiceAccounts, NetworkPolicies, and Vault roles
-- and must never be co-installed into a consumer's namespace.
ensureInternalControlPlaneChartReady
  :: FilePath -> ValidatedSettings -> Substrate -> ComponentId -> IO ExitCode
ensureInternalControlPlaneChartReady repoRoot settings substrate component =
  case internalControlPlaneChartName component of
    Left err -> failWith err
    Right chartName -> do
      planResult <-
        buildChartDeploymentPlanForSubstrate
          substrate
          repoRoot
          settings
          chartName
          Map.empty
          Map.empty
      case planResult >>= isolateRootRelease chartName of
        Left err -> failWith err
        Right plan -> do
          deployResult <- deployChartPlan plan
          case deployResult of
            Left err -> failWith err
            Right report -> writeOutputLine report >> pure ExitSuccess

internalControlPlaneChartName :: ComponentId -> Either String String
internalControlPlaneChartName component =
  case component of
    ComponentChartBootstrapBroker -> chartName
    ComponentChartLifecycleAuthority -> chartName
    ComponentChartProviderWorker -> chartName
    ComponentChartAuthorityBackup -> chartName
    ComponentChartTlsRetention -> chartName
    ComponentChartTargetSecretAgent -> chartName
    _ -> Left ("Component `" ++ componentIdText component ++ "` is not an internal control-plane chart.")
 where
  chartName =
    maybe
      (Left ("Internal control-plane component `" ++ componentIdText component ++ "` has no chart name."))
      Right
      (chartNameForComponent component)

isolateRootRelease :: String -> ChartDeploymentPlan -> Either String ChartDeploymentPlan
isolateRootRelease chartName plan =
  case [ release
       | release <- chartDeploymentPlanReleases plan
       , chartReleasePlanReleaseName release == chartName
       ] of
    [rootRelease] -> Right plan {chartDeploymentPlanReleases = [rootRelease]}
    [] -> Left ("Internal chart plan for `" ++ chartName ++ "` has no root release.")
    _ -> Left ("Internal chart plan for `" ++ chartName ++ "` has duplicate root releases.")

-- | Deploy the gateway chart as a reconcile-time platform component and
-- install the loopback-only NodePort iptables restriction on home (mirrors
-- the @charts reconcile gateway@ post-hook).
--
-- Idempotent: 'deployChartPlan' no-ops when the gateway release is already
-- installed, and the firewall step is safe to repeat.
ensureGatewayChartReady
  :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
ensureGatewayChartReady repoRoot settings substrate =
  ensureGatewayChartReadyForSubstrate repoRoot settings substrate

-- | Post-Vault gateway convergence: deploy the gateway chart, then ensure the
-- daemon is actually running in FULL mode (see 'ensureGatewayDaemonFullModeAt').
-- The physical bootstrap cut runs through the Bootstrap Broker, so reconcile
-- does not install a degraded pre-Vault Gateway release.
ensureGatewayChartReadyPostVault :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
ensureGatewayChartReadyPostVault repoRoot settings substrate = do
  endpoint <- gatewayEndpointFromEnv
  ensureGatewayChartReadyPostVaultAt repoRoot settings substrate endpoint

ensureGatewayChartReadyPostVaultAt
  :: FilePath -> ValidatedSettings -> Substrate -> PeerEndpoint -> IO ExitCode
ensureGatewayChartReadyPostVaultAt repoRoot settings substrate endpoint = do
  deployExit <- ensureGatewayChartReady repoRoot settings substrate
  case deployExit of
    ExitFailure _ -> pure deployExit
    ExitSuccess -> ensureGatewayDaemonFullModeAt repoRoot endpoint

-- | The Gateway readiness projection is the deep proof for its retained
-- continuity store: it cannot report ready before the continuity worker has
-- completed a validated object-store recovery round trip. A release left behind
-- by an older reconcile may still be running in its pre-Vault state, so an
-- initial definite not-ready result triggers one deterministic rollout restart;
-- the post-restart proof then polls the same compiled readiness route. No generic
-- Pulumi/object-store RPC is used as a health probe.
ensureGatewayDaemonFullModeAt :: FilePath -> PeerEndpoint -> IO ExitCode
ensureGatewayDaemonFullModeAt repoRoot endpoint = do
  initialProbe <- pollGatewayFullModeAt endpoint False gatewayFullModeInitialProbeAttempts
  case initialProbe of
    GatewayFullModeHealthy -> do
      writeOutputLine "GATEWAY_DAEMON_MODE=full (no restart needed)"
      pure ExitSuccess
    GatewayFullModeTransient detail ->
      failWith
        ("gateway daemon readiness was unreachable while verifying full mode: " ++ detail)
    GatewayFullModeNotReady body -> do
      writeOutputLine
        ( "GATEWAY_DAEMON_MODE=degraded-pre-vault; restarting gateway daemons to resolve "
            ++ "their retained continuity authority ("
            ++ trimProbeBody body
            ++ ")"
        )
      restartExit <-
        runSequentially
          ( [rolloutRestart repoRoot gatewayNamespace ref | ref <- gatewayDaemonWorkloadRefs]
              ++ [rolloutStatus repoRoot gatewayNamespace ref | ref <- gatewayDaemonWorkloadRefs]
          )
      case restartExit of
        ExitFailure _ -> pure restartExit
        ExitSuccess -> do
          verifyProbe <- pollGatewayFullModeAt endpoint True gatewayFullModeVerifyAttempts
          case verifyProbe of
            GatewayFullModeHealthy -> do
              writeOutputLine "GATEWAY_DAEMON_MODE=full (restarted into full mode)"
              pure ExitSuccess
            GatewayFullModeNotReady verifyBody ->
              failWith
                ( "gateway daemon remained not-ready after its continuity restart: "
                    ++ trimProbeBody verifyBody
                )
            GatewayFullModeTransient detail ->
              failWith
                ("gateway daemon readiness was unreachable after restart: " ++ detail)

-- | The gateway daemon workloads to restart, derived from the canonical
-- 'gatewayNodeIds' SSoT (one @gateway-\<nodeId>@ StatefulSet per node). Sprint
-- 3.26 renders the gateway emitters as stable per-node StatefulSet identities
-- (each with a registered retained journal), so rollout restart/status target
-- @statefulset/@ refs.
gatewayDaemonWorkloadRefs :: [String]
gatewayDaemonWorkloadRefs =
  ["statefulset/gateway-" ++ nodeId | nodeId <- gatewayNodeIdsForSubstrate SubstrateHomeLocal]

gatewayFullModeInitialProbeAttempts :: Int
gatewayFullModeInitialProbeAttempts = 10

gatewayFullModeVerifyAttempts :: Int
gatewayFullModeVerifyAttempts = vaultApiReadinessAttempts

-- | Classification of the Gateway's deep readiness proof. See
-- 'ensureGatewayDaemonFullModeAt'.
data GatewayFullModeProbe
  = GatewayFullModeHealthy
  | GatewayFullModeNotReady String
  | GatewayFullModeTransient String
  deriving (Eq, Show)

classifyGatewayFullModeProbe :: GatewayClient.GatewayReadyzProbe -> GatewayFullModeProbe
classifyGatewayFullModeProbe probe = case probe of
  GatewayClient.GatewayReadyzReady -> GatewayFullModeHealthy
  GatewayClient.GatewayReadyzNotReady code body ->
    GatewayFullModeNotReady ("HTTP " ++ show code ++ ": " ++ body)
  GatewayClient.GatewayReadyzUnreachable detail -> GatewayFullModeTransient detail

probeGatewayFullModeOnceAt :: PeerEndpoint -> IO GatewayFullModeProbe
probeGatewayFullModeOnceAt endpoint =
  classifyGatewayFullModeProbe <$> GatewayClient.queryReadyz endpoint

-- | Poll the deep readiness projection up to @attempts@. The initial path
-- returns a definite not-ready observation so the old pre-Vault Pod can be
-- restarted; the verification path retries it while the new continuity worker
-- establishes its round-trip latch. Transport failures are always retried.
pollGatewayFullModeAt :: PeerEndpoint -> Bool -> Int -> IO GatewayFullModeProbe
pollGatewayFullModeAt endpoint retryNotReady attempts =
  go attempts (GatewayFullModeTransient "gateway daemon not yet probed")
 where
  go remaining lastProbe
    | remaining <= 0 = pure lastProbe
    | otherwise = do
        probe <- probeGatewayFullModeOnceAt endpoint
        case probe of
          GatewayFullModeHealthy -> pure GatewayFullModeHealthy
          GatewayFullModeNotReady _ | not retryNotReady -> pure probe
          _ -> do
            threadDelay vaultApiReadinessDelayMicroseconds
            go (remaining - 1) probe

trimProbeBody :: String -> String
trimProbeBody = Text.unpack . Text.strip . Text.pack

resolveOperationalAwsCredentialGate
  :: FilePath -> ValidatedSettings -> IO OperationalAwsCredentialGate
resolveOperationalAwsCredentialGate repoRoot settings =
  case validateOperationalAwsCredentials config of
    Left err -> pure (operationalAwsCredentialGateFromResult (Left err))
    Right () -> do
      readiness <-
        dispatchHostProviderIntentFresh
          LifecycleAuthorityOperator
          repoRoot
          "rke2-operational-aws-readiness"
          (ObserveProviderReadiness ProviderReadinessStsIdentity)
      pure $ case readiness of
        Left err -> OperationalAwsCredentialsInvalid (renderProviderCallerError err)
        Right _ -> OperationalAwsCredentialsReady
 where
  config = validatedConfig settings

operationalAwsCredentialGateFromResult
  :: Either String Credentials -> OperationalAwsCredentialGate
operationalAwsCredentialGateFromResult result =
  case result of
    Left err
      | operationalAwsCredentialAbsentError err -> OperationalAwsCredentialsAbsent err
      | otherwise -> OperationalAwsCredentialsInvalid err
    Right credentials
      | operationalAwsCredentialsConfigured credentials -> OperationalAwsCredentialsReady
      | otherwise ->
          OperationalAwsCredentialsAbsent "operational aws.* resolved with an empty field"

operationalAwsCredentialsConfigured :: Credentials -> Bool
operationalAwsCredentialsConfigured credentials =
  not (Text.null (Text.strip (access_key_id credentials)))
    && not (Text.null (Text.strip (secret_access_key credentials)))
    && not (Text.null (Text.strip (region credentials)))

operationalAwsCredentialAbsentError :: String -> Bool
operationalAwsCredentialAbsentError err =
  any (`Text.isInfixOf` rendered) ["missing", "empty"]
 where
  rendered = Text.toLower (Text.pack err)

ensureGatewayChartReadyForSubstrate
  :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
ensureGatewayChartReadyForSubstrate repoRoot settings substrate =
  ensureGatewayChartReadyCredentialed repoRoot settings substrate

ensureGatewayChartReadyCredentialed
  :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
ensureGatewayChartReadyCredentialed repoRoot settings substrate = do
  namespaceExit <- ensureGatewayBootstrapNamespaceOwnership repoRoot
  case namespaceExit of
    ExitFailure _ -> pure namespaceExit
    ExitSuccess -> do
      secretsResult <- resolveChartSecrets repoRoot gatewayNamespace
      case secretsResult of
        Left err -> failWith err
        Right chartSecrets -> do
          planResult <-
            buildChartDeploymentPlanForSubstrate
              substrate
              repoRoot
              settings
              gatewayNamespace
              chartSecrets
              Map.empty
          case planResult of
            Left err -> failWith err
            Right plan -> do
              deployResult <- deployChartPlan plan
              case deployResult of
                Left err -> failWith err
                Right report -> do
                  writeOutputLine report
                  firewallExit <- case substrate of
                    SubstrateHomeLocal ->
                      runHostFirewallGatewayRestrictOptional defaultGatewayNodePort
                    _ -> pure ExitSuccess
                  case firewallExit of
                    ExitFailure _ -> pure firewallExit
                    ExitSuccess -> pure ExitSuccess

ensureGatewayBootstrapNamespaceOwnership :: FilePath -> IO ExitCode
ensureGatewayBootstrapNamespaceOwnership repoRoot =
  kubectlApplyJsonManifest
    repoRoot
    "gateway-bootstrap-namespaces"
    (map gatewayBootstrapNamespaceManifest gatewayBootstrapNamespaces)

gatewayBootstrapNamespaceManifest :: String -> Value
gatewayBootstrapNamespaceManifest namespace =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Namespace" :: String)
    , "metadata"
        .= object
          [ "name" .= namespace
          , "labels"
              .= object
                [ "app.kubernetes.io/managed-by" .= ("Helm" :: String)
                , "prodbox.io/created-by" .= ("gateway-chart-rbac-bootstrap" :: String)
                ]
          , "annotations"
              .= object
                [ "meta.helm.sh/release-name" .= gatewayNamespace
                , "meta.helm.sh/release-namespace" .= gatewayNamespace
                , "helm.sh/resource-policy" .= ("keep" :: String)
                ]
          ]
    ]

ensureAdminPublicEdgeRoutes
  :: FilePath -> ValidatedSettings -> Substrate -> String -> String -> IO ExitCode
ensureAdminPublicEdgeRoutes repoRoot settings substrate prodboxId labelValue =
  -- Sprint 1.84: resolve the served host here, where there is an error channel,
  -- rather than letting the pure manifest renderer answer `""`.
  -- Sprint 1.87: carry the resolved 'ValidatedServedHost' rather than only its
  -- string projection, so the SecurityPolicy renderer downstream consumes this
  -- resolution instead of performing its own.
  case requireSubstrateServedHost settings substrate of
    Left err -> failWith err
    Right servedHost ->
      ensureAdminPublicEdgeRoutesAt repoRoot servedHost prodboxId labelValue

ensureAdminPublicEdgeRoutesAt
  :: FilePath
  -> ValidatedServedHost
  -> String
  -> String
  -> IO ExitCode
ensureAdminPublicEdgeRoutesAt repoRoot servedHost prodboxId labelValue = do
  staleCleanup <-
    deleteMaterializerAndObservePodAbsence
      repoRoot
      minioNamespace
      minioAdminOidcMaterializerName
  case staleCleanup of
    ExitFailure _ -> pure staleCleanup
    ExitSuccess ->
      withTemporaryJsonManifest
        "prodbox-admin-public-edge"
        (adminPublicEdgeManifestItems servedHost prodboxId labelValue)
        ( \manifestPath -> do
            outputResult <- captureKubectl repoRoot ["apply", "-f", manifestPath]
            case outputResult of
              Left err -> failWith err
              Right output ->
                case processExitCode output of
                  ExitFailure _ -> failWith ("kubectl apply failed: " ++ outputDetail output)
                  ExitSuccess -> awaitAdminOidcMaterialization repoRoot
        )

-- | Wait for the exact in-cluster projection and read back only the target
-- Secret's non-secret Kubernetes metadata.  Neither command requests @data@,
-- so the operator host cannot obtain the OIDC client secret.
awaitAdminOidcMaterialization :: FilePath -> IO ExitCode
awaitAdminOidcMaterialization repoRoot = do
  waited <-
    captureKubectl
      repoRoot
      [ "wait"
      , "--namespace"
      , minioNamespace
      , "--for=condition=complete"
      , "--timeout=300s"
      , "job/" ++ minioAdminOidcMaterializerName
      ]
  outcome <- case waited of
    Left err -> failWith err
    Right waitOutput ->
      case processExitCode waitOutput of
        ExitFailure _ ->
          failWith "MinIO admin OIDC materializer did not complete."
        ExitSuccess -> do
          observed <-
            captureKubectl
              repoRoot
              [ "get"
              , "secret/" ++ minioAdminClientSecretName
              , "--namespace"
              , minioNamespace
              , "--output=jsonpath={.metadata.resourceVersion}"
              ]
          case observed of
            Left err -> failWith err
            Right output
              | processExitCode output /= ExitSuccess ->
                  failWith "MinIO admin OIDC Secret metadata read-back failed."
              | null (trimWhitespace (processStdout output)) ->
                  failWith "MinIO admin OIDC Secret metadata read-back returned no resourceVersion."
              | otherwise -> pure ExitSuccess
  cleanup <-
    deleteMaterializerAndObservePodAbsence
      repoRoot
      minioNamespace
      minioAdminOidcMaterializerName
  pure (preferFirstFailure outcome cleanup)

deleteMaterializerAndObservePodAbsence
  :: FilePath -> String -> String -> IO ExitCode
deleteMaterializerAndObservePodAbsence repoRoot namespace jobName = do
  deleted <-
    captureKubectl
      repoRoot
      [ "delete"
      , "job/" ++ jobName
      , "--namespace"
      , namespace
      , "--cascade=foreground"
      , "--wait=true"
      , "--ignore-not-found=true"
      ]
  case deleted of
    Left err -> failWith err
    Right deleteOutput
      | processExitCode deleteOutput /= ExitSuccess ->
          failWith ("materializer Job cleanup failed: " ++ outputDetail deleteOutput)
      | otherwise -> do
          observed <-
            captureKubectl
              repoRoot
              [ "get"
              , "pods"
              , "--namespace"
              , namespace
              , "--selector=job-name=" ++ jobName
              , "--output=name"
              ]
          case observed of
            Left err -> failWith err
            Right output
              | processExitCode output /= ExitSuccess ->
                  failWith ("materializer Pod absence read-back failed: " ++ outputDetail output)
              | not (null (trimWhitespace (processStdout output))) ->
                  failWith "materializer Job was deleted but a materializer Pod remains"
              | otherwise -> pure ExitSuccess

preferFirstFailure :: ExitCode -> ExitCode -> ExitCode
preferFirstFailure first second = case first of
  ExitFailure _ -> first
  ExitSuccess -> second

-- | Sprint 1.87: the @ValidatedSettings@ and 'Substrate' parameters are gone.
-- They existed only so the SecurityPolicy renderer could re-derive the served
-- host its caller had already resolved; it now consumes the resolved
-- 'ValidatedServedHost' directly, and nothing in this manifest set reads the
-- config again.
adminPublicEdgeManifestItems
  :: ValidatedServedHost
  -> String
  -> String
  -> [Value]
adminPublicEdgeManifestItems servedHost prodboxId labelValue =
  -- The single-binary registry:2 has no web UI, so there is no admin edge route
  -- for it (the former OIDC-gated /harbor surface is gone). Only the MinIO
  -- console admin route remains.  Its Secret is projected inside the target
  -- namespace by the exact Vault-authenticated materializer resources.
  adminOidcClientSecretMaterializerManifests prodboxId labelValue
    ++ [ adminHttpRouteManifest
           minioNamespace
           minioAdminRouteName
           minioPathPrefix
           minioConsoleServiceName
           minioConsoleServicePort
           prodboxId
           labelValue
           (servedHostString servedHost)
       , adminSecurityPolicyManifest
           minioNamespace
           minioAdminSecurityPolicyName
           minioAdminRouteName
           minioAdminClientSecretName
           (substratePublicRouteUrl servedHost PublicRouteMinio)
           prodboxId
           labelValue
           servedHost
       ]

-- | Exact consumer-side projection for the MinIO Envoy SecurityPolicy.  The
-- init container reads only the registered VS Code OIDC client field through
-- the namespace-bound Vault role; the sibling container may create or patch
-- only the one named Kubernetes Secret.
adminOidcClientSecretMaterializerManifests :: String -> String -> [Value]
adminOidcClientSecretMaterializerManifests prodboxId labelValue =
  [ serviceAccount
  , role
  , roleBinding
  , job
  ]
 where
  metadata =
    object
      [ "name" .= minioAdminOidcMaterializerName
      , "namespace" .= minioNamespace
      , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
      , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
      ]
  serviceAccount =
    object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("ServiceAccount" :: String)
      , "metadata" .= metadata
      ]
  role =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("Role" :: String)
      , "metadata" .= metadata
      , "rules"
          .= [ object
                 [ "apiGroups" .= ([""] :: [String])
                 , "resources" .= (["secrets"] :: [String])
                 , "verbs" .= (["create"] :: [String])
                 ]
             , object
                 [ "apiGroups" .= ([""] :: [String])
                 , "resources" .= (["secrets"] :: [String])
                 , "resourceNames" .= ([minioAdminClientSecretName] :: [String])
                 , "verbs" .= (["get", "update", "patch"] :: [String])
                 ]
             ]
      ]
  roleBinding =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("RoleBinding" :: String)
      , "metadata" .= metadata
      , "subjects"
          .= [ object
                 [ "kind" .= ("ServiceAccount" :: String)
                 , "name" .= minioAdminOidcMaterializerName
                 , "namespace" .= minioNamespace
                 ]
             ]
      , "roleRef"
          .= object
            [ "apiGroup" .= ("rbac.authorization.k8s.io" :: String)
            , "kind" .= ("Role" :: String)
            , "name" .= minioAdminOidcMaterializerName
            ]
      ]
  initScript =
    unlines
      [ "set -eu"
      , "jwt=\"$(cat \"${VAULT_SA_TOKEN_FILE}\")\""
      , "export VAULT_TOKEN=\"$(vault write -field=token \"auth/${VAULT_AUTH_PATH}/login\" role=\"${VAULT_ROLE}\" jwt=\"${jwt}\")\""
      , "umask 077"
      , "vault kv get -field=client_secret secret/vscode/oidc/vscode > /vault-materialized/client-secret"
      , "test -s /vault-materialized/client-secret"
      , "chmod 0644 /vault-materialized/client-secret"
      ]
  materializeScript =
    unlines
      [ "set -eu"
      , "api_server=\"https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}\""
      , "token=\"$(cat \"${SERVICEACCOUNT_TOKEN_FILE}\")\""
      , "client_secret_b64=\"$(base64 < /vault-materialized/client-secret | tr -d '\\n')\""
      , "test -n \"${client_secret_b64}\""
      , "cat > /vault-materialized/create.json <<EOF"
      , "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${SECRET_NAME}\",\"labels\":{\"app.kubernetes.io/managed-by\":\"prodbox\"}},\"type\":\"Opaque\",\"data\":{\"client-secret\":\"${client_secret_b64}\"}}"
      , "EOF"
      , "cat > /vault-materialized/patch.json <<EOF"
      , "{\"type\":\"Opaque\",\"data\":{\"client-secret\":\"${client_secret_b64}\"}}"
      , "EOF"
      , "create_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/json\" -o /vault-materialized/create-response.json -w '%{http_code}' --data-binary @/vault-materialized/create.json \"${api_server}/api/v1/namespaces/${POD_NAMESPACE}/secrets\" || true)\""
      , "case \"${create_code}\" in"
      , "  201) exit 0 ;;"
      , "  409)"
      , "    patch_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/merge-patch+json\" -o /vault-materialized/patch-response.json -w '%{http_code}' --request PATCH --data-binary @/vault-materialized/patch.json \"${api_server}/api/v1/namespaces/${POD_NAMESPACE}/secrets/${SECRET_NAME}\" || true)\""
      , "    case \"${patch_code}\" in 200|201) exit 0 ;; *) echo 'OIDC Secret patch was refused' >&2; exit 1 ;; esac ;;"
      , "  *) echo 'OIDC Secret create was refused' >&2; exit 1 ;;"
      , "esac"
      ]
  job =
    object
      [ "apiVersion" .= ("batch/v1" :: String)
      , "kind" .= ("Job" :: String)
      , "metadata" .= metadata
      , "spec"
          .= object
            [ "backoffLimit" .= (0 :: Int)
            , "ttlSecondsAfterFinished" .= (60 :: Int)
            , "template"
                .= object
                  [ "metadata"
                      .= object
                        [ "labels"
                            .= object
                              [ Key.fromString prodboxLabelKey .= labelValue
                              , "app.kubernetes.io/name" .= minioAdminOidcMaterializerName
                              ]
                        ]
                  , "spec"
                      .= object
                        [ "serviceAccountName" .= minioAdminOidcMaterializerName
                        , "restartPolicy" .= ("Never" :: String)
                        , "initContainers"
                            .= [ object
                                   [ "name" .= ("vault-secrets" :: String)
                                   , "image" .= ContainerImage.renderImageRef ContainerImage.publicVaultImage
                                   , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                   , "env"
                                       .= [ envVar "VAULT_ADDR" "http://vault.vault.svc.cluster.local:8200"
                                          , envVar "VAULT_AUTH_PATH" "kubernetes"
                                          , envVar "VAULT_ROLE" minioAdminOidcVaultRole
                                          , envVar "VAULT_SA_TOKEN_FILE" "/var/run/secrets/kubernetes.io/serviceaccount/token"
                                          ]
                                   , "command" .= (["/bin/sh", "-ec", initScript] :: [String])
                                   , "volumeMounts" .= [materializedVolumeMount False]
                                   ]
                               ]
                        , "containers"
                            .= [ object
                                   [ "name" .= ("materialize-client-secret" :: String)
                                   , "image" .= ContainerImage.renderImageRef ContainerImage.harborCurlImage
                                   , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                   , "env"
                                       .= [ object
                                              [ "name" .= ("POD_NAMESPACE" :: String)
                                              , "valueFrom"
                                                  .= object
                                                    [ "fieldRef"
                                                        .= object ["fieldPath" .= ("metadata.namespace" :: String)]
                                                    ]
                                              ]
                                          , envVar "SECRET_NAME" minioAdminClientSecretName
                                          , envVar "SERVICEACCOUNT_TOKEN_FILE" "/var/run/secrets/kubernetes.io/serviceaccount/token"
                                          , envVar "SERVICEACCOUNT_CA_FILE" "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
                                          ]
                                   , "command" .= (["/bin/sh", "-ec", materializeScript] :: [String])
                                   , "volumeMounts" .= [materializedVolumeMount False]
                                   ]
                               ]
                        , "volumes"
                            .= [ object
                                   [ "name" .= ("vault-materialized" :: String)
                                   , "emptyDir"
                                       .= object
                                         [ "medium" .= ("Memory" :: String)
                                         , "sizeLimit" .= ("1Mi" :: String)
                                         ]
                                   ]
                               ]
                        ]
                  ]
            ]
      ]
  envVar :: String -> String -> Value
  envVar name value = object ["name" .= name, "value" .= value]
  materializedVolumeMount readOnly =
    object
      [ "name" .= ("vault-materialized" :: String)
      , "mountPath" .= ("/vault-materialized" :: String)
      , "readOnly" .= readOnly
      ]

adminHttpRouteManifest
  :: String -> String -> String -> String -> Int -> String -> String -> String -> Value
adminHttpRouteManifest namespace routeName pathPrefix serviceName servicePort prodboxId labelValue hostFqdn =
  object
    [ "apiVersion" .= ("gateway.networking.k8s.io/v1" :: String)
    , "kind" .= ("HTTPRoute" :: String)
    , "metadata"
        .= object
          [ "name" .= routeName
          , "namespace" .= namespace
          , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
          , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
          ]
    , "spec"
        .= object
          [ "parentRefs"
              .= ( [ object
                       [ "name" .= ("public-edge" :: String)
                       , "namespace" .= ("vscode" :: String)
                       , "sectionName" .= publicEdgeListenerName
                       ]
                   ]
                     :: [Value]
                 )
          , "hostnames" .= ([hostFqdn] :: [String])
          , "rules"
              .= ( [ object
                       [ "matches"
                           .= ( [ object
                                    [ "path"
                                        .= object
                                          [ "type" .= ("PathPrefix" :: String)
                                          , "value" .= pathPrefix
                                          ]
                                    ]
                                ]
                                  :: [Value]
                              )
                       , "backendRefs"
                           .= ( [ object
                                    [ "name" .= serviceName
                                    , "port" .= servicePort
                                    ]
                                ]
                                  :: [Value]
                              )
                       ]
                   ]
                     :: [Value]
                 )
          ]
    ]

adminSecurityPolicyManifest
  :: String
  -> String
  -> String
  -> String
  -> String
  -> String
  -> String
  -> ValidatedServedHost
  -> Value
adminSecurityPolicyManifest namespace policyName routeName secretName baseUrl prodboxId labelValue servedHost =
  object
    [ "apiVersion" .= ("gateway.envoyproxy.io/v1alpha1" :: String)
    , "kind" .= ("SecurityPolicy" :: String)
    , "metadata"
        .= object
          [ "name" .= policyName
          , "namespace" .= namespace
          , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
          , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
          ]
    , "spec"
        .= object
          [ "targetRefs"
              .= ( [ object
                       [ "group" .= ("gateway.networking.k8s.io" :: String)
                       , "kind" .= ("HTTPRoute" :: String)
                       , "name" .= routeName
                       ]
                   ]
                     :: [Value]
                 )
          , "oidc"
              .= object
                [ "provider" .= adminOidcProviderManifest servedHost
                , "clientID" .= keycloakVscodeClientId
                , "clientSecret" .= object ["name" .= secretName]
                , "redirectURL" .= (baseUrl ++ "/oauth2/callback")
                , "logoutPath" .= ("/logout" :: String)
                ]
          ]
    ]

adminOidcProviderManifest :: ValidatedServedHost -> Value
adminOidcProviderManifest servedHost =
  object
    [ "issuer" .= issuer
    , "authorizationEndpoint" .= (issuer ++ "/protocol/openid-connect/auth")
    , "tokenEndpoint" .= sharedKeycloakInternalTokenEndpoint
    ]
 where
  issuer = substrateIdentityIssuerUrl servedHost

sharedKeycloakInternalTokenEndpoint :: String
sharedKeycloakInternalTokenEndpoint =
  "http://keycloak.vscode.svc.cluster.local:8080"
    ++ authPathPrefix
    ++ "/realms/"
    ++ keycloakRealmName
    ++ "/protocol/openid-connect/token"

resolveClusterPlatformLanDefaults :: IO (Either String (String, String))
resolveClusterPlatformLanDefaults = do
  maybeMetallbPool <- lookupNonEmptyEnv "PRODBOX_PULUMI_METALLB_POOL"
  maybeEdgeLbIp <- firstNonEmptyEnv ["PRODBOX_PULUMI_EDGE_LB_IP", "PRODBOX_PULUMI_INGRESS_LB_IP"]
  case (maybeMetallbPool, maybeEdgeLbIp) of
    (Just metallbPool, Just edgeLbIp) -> pure (Right (metallbPool, edgeLbIp))
    (Just _, Nothing) ->
      pure
        (Left "set both PRODBOX_PULUMI_METALLB_POOL and PRODBOX_PULUMI_EDGE_LB_IP, or set neither")
    (Nothing, Just _) ->
      pure
        (Left "set both PRODBOX_PULUMI_METALLB_POOL and PRODBOX_PULUMI_EDGE_LB_IP, or set neither")
    (Nothing, Nothing) ->
      fmap renderLanAddressingDefaults detectLanAddressing

renderLanAddressingDefaults :: Either String LanAddressing -> Either String (String, String)
renderLanAddressingDefaults lanResult =
  case lanResult of
    Left err ->
      Left ("failed to derive MetalLB defaults from host networking: " ++ err)
    Right lan -> Right (lanMetallbPool lan, lanIngressLbIp lan)

ensureMetalLbRuntime :: FilePath -> ValidatedSettings -> String -> String -> String -> IO ExitCode
ensureMetalLbRuntime repoRoot settings prodboxId labelValue metallbPool = do
  repoExit <- ensureHelmRepoAdded repoRoot metallbRepositoryName metallbRepositoryUrl
  case repoExit of
    ExitFailure _ -> pure repoExit
    ExitSuccess -> do
      installExit <-
        helmUpgradeInstallWithJsonValuesAndArgs
          repoRoot
          metallbReleaseName
          metallbChartRef
          ["--force-conflicts"]
          metallbChartVersion
          metallbNamespace
          (metallbHelmValues prodboxId labelValue)
      case installExit of
        ExitFailure _ -> pure installExit
        ExitSuccess -> do
          let advertisementMode = configuredPublicEdgeAdvertisementMode settings
          waitExit <-
            runSequentially
              ( [ rolloutStatus repoRoot metallbNamespace "deployment/metallb-controller"
                , rolloutStatus repoRoot metallbNamespace "daemonset/metallb-speaker"
                , waitForCrdEstablished repoRoot "ipaddresspools.metallb.io"
                ]
                  ++ case advertisementMode of
                    "bgp" ->
                      [ waitForCrdEstablished repoRoot "bgppeers.metallb.io"
                      , waitForCrdEstablished repoRoot "bgpadvertisements.metallb.io"
                      ]
                    _ ->
                      [waitForCrdEstablished repoRoot "l2advertisements.metallb.io"]
              )
          case waitExit of
            ExitFailure _ -> pure waitExit
            ExitSuccess ->
              kubectlApplyJsonManifest
                repoRoot
                "prodbox-metallb-resources"
                (metallbRuntimeManifest settings prodboxId labelValue metallbPool)

firstNonEmptyEnv :: [String] -> IO (Maybe String)
firstNonEmptyEnv variableNames = go variableNames
 where
  go [] = pure Nothing
  go (variableName : remaining) = do
    maybeValue <- lookupNonEmptyEnv variableName
    case maybeValue of
      Just value -> pure (Just value)
      Nothing -> go remaining

metallbHelmValues :: String -> String -> Value
metallbHelmValues prodboxId labelValue =
  object
    [ "controller"
        .= object
          [ "image"
              .= object
                [ "repository" .= renderImageRefWithoutTag ContainerImage.harborMetallbControllerImage
                , "tag" .= ContainerImage.imageTag ContainerImage.harborMetallbControllerImage
                ]
          ]
    , "speaker"
        .= object
          [ "image"
              .= object
                [ "repository" .= renderImageRefWithoutTag ContainerImage.harborMetallbSpeakerImage
                , "tag" .= ContainerImage.imageTag ContainerImage.harborMetallbSpeakerImage
                ]
          , "frr"
              .= object
                [ "image"
                    .= object
                      [ "repository" .= renderImageRefWithoutTag ContainerImage.harborFrrImage
                      , "tag" .= ContainerImage.imageTag ContainerImage.harborFrrImage
                      ]
                ]
          ]
    , "commonLabels" .= object [Key.fromString prodboxLabelKey .= labelValue]
    , "commonAnnotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
    ]

metallbRuntimeManifest :: ValidatedSettings -> String -> String -> String -> [Value]
metallbRuntimeManifest settings prodboxId labelValue metallbPool =
  object
    [ "apiVersion" .= ("metallb.io/v1beta1" :: String)
    , "kind" .= ("IPAddressPool" :: String)
    , "metadata"
        .= object
          [ "name" .= ("default-pool" :: String)
          , "namespace" .= metallbNamespace
          , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
          , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
          ]
    , "spec" .= object ["addresses" .= [metallbPool]]
    ]
    : case configuredPublicEdgeAdvertisementMode settings of
      "bgp" ->
        map (metallbBgpPeerManifest prodboxId labelValue) (configuredPublicEdgeBgpPeers settings)
          ++ [metallbBgpAdvertisementManifest prodboxId labelValue]
      _ -> [metallbL2AdvertisementManifest prodboxId labelValue]

metallbL2AdvertisementManifest :: String -> String -> Value
metallbL2AdvertisementManifest prodboxId labelValue =
  object
    [ "apiVersion" .= ("metallb.io/v1beta1" :: String)
    , "kind" .= ("L2Advertisement" :: String)
    , "metadata"
        .= object
          [ "name" .= ("default-advertisement" :: String)
          , "namespace" .= metallbNamespace
          , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
          , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
          ]
    , "spec" .= object ["ipAddressPools" .= ["default-pool" :: String]]
    ]

metallbBgpPeerManifest :: String -> String -> MetallbBgpPeer -> Value
metallbBgpPeerManifest prodboxId labelValue peer =
  object
    [ "apiVersion" .= ("metallb.io/v1beta2" :: String)
    , "kind" .= ("BGPPeer" :: String)
    , "metadata"
        .= object
          [ "name" .= Text.unpack (peer_name peer)
          , "namespace" .= metallbNamespace
          , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
          , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
          ]
    , "spec"
        .= object
          ( [ "peerAddress" .= Text.unpack (peer_address peer)
            , "peerASN" .= (fromIntegral (peer_asn peer) :: Int)
            , "myASN" .= (fromIntegral (my_asn peer) :: Int)
            ]
              ++ case ebgp_multi_hop peer of
                Just enabled -> ["ebgpMultiHop" .= enabled]
                Nothing -> []
          )
    ]

metallbBgpAdvertisementManifest :: String -> String -> Value
metallbBgpAdvertisementManifest prodboxId labelValue =
  object
    [ "apiVersion" .= ("metallb.io/v1beta1" :: String)
    , "kind" .= ("BGPAdvertisement" :: String)
    , "metadata"
        .= object
          [ "name" .= ("default-advertisement" :: String)
          , "namespace" .= metallbNamespace
          , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
          , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
          ]
    , "spec" .= object ["ipAddressPools" .= ["default-pool" :: String]]
    ]

ensureEnvoyGatewayRuntime
  :: FilePath -> ValidatedSettings -> String -> String -> String -> IO ExitCode
ensureEnvoyGatewayRuntime repoRoot settings prodboxId labelValue edgeLbIp = do
  installExit <-
    helmUpgradeInstallWithJsonValues
      repoRoot
      envoyGatewayReleaseName
      envoyGatewayChartRef
      envoyGatewayChartVersion
      envoyGatewayNamespace
      (envoyGatewayHelmValues settings labelValue)
  case installExit of
    ExitFailure _ -> pure installExit
    ExitSuccess -> do
      waitExit <-
        runSequentially
          [ waitForDeployment repoRoot envoyGatewayNamespace envoyGatewayReleaseName
          , waitForCrdEstablished repoRoot "gatewayclasses.gateway.networking.k8s.io"
          , waitForCrdEstablished repoRoot "gateways.gateway.networking.k8s.io"
          , waitForCrdEstablished repoRoot "httproutes.gateway.networking.k8s.io"
          , waitForCrdEstablished repoRoot "envoyproxies.gateway.envoyproxy.io"
          , waitForCrdEstablished repoRoot "securitypolicies.gateway.envoyproxy.io"
          ]
      case waitExit of
        ExitFailure _ -> pure waitExit
        ExitSuccess ->
          kubectlApplyJsonManifest
            repoRoot
            "prodbox-envoy-gateway-runtime"
            (envoyGatewayRuntimeManifest settings prodboxId labelValue edgeLbIp)

envoyGatewayHelmValues :: ValidatedSettings -> String -> Value
envoyGatewayHelmValues settings labelValue =
  object
    [ "deployment"
        .= object
          [ "replicas" .= configuredEnvoyGatewayControllerReplicas settings
          , "pod"
              .= object
                [ "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
                ]
          , "envoyGateway"
              .= object
                [ "image"
                    .= object
                      [ "repository" .= renderImageRefWithoutTag ContainerImage.harborEnvoyGatewayImage
                      , "tag" .= ContainerImage.imageTag ContainerImage.harborEnvoyGatewayImage
                      ]
                ]
          ]
    , "config"
        .= object
          [ "envoyGateway"
              .= object
                [ "gateway"
                    .= object
                      [ "controllerName" .= ("gateway.envoyproxy.io/gatewayclass-controller" :: String)
                      ]
                ]
          ]
    ]

envoyGatewayRuntimeManifest :: ValidatedSettings -> String -> String -> String -> [Value]
envoyGatewayRuntimeManifest settings prodboxId labelValue edgeLbIp =
  [ object
      [ "apiVersion" .= ("gateway.envoyproxy.io/v1alpha1" :: String)
      , "kind" .= ("EnvoyProxy" :: String)
      , "metadata"
          .= object
            [ "name" .= publicEdgeEnvoyProxyName
            , "namespace" .= envoyGatewayNamespace
            , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "spec"
          .= object
            [ "provider"
                .= object
                  [ "type" .= ("Kubernetes" :: String)
                  , "kubernetes"
                      .= object
                        [ "envoyDeployment"
                            .= object
                              [ "replicas" .= configuredEnvoyGatewayDataPlaneReplicas settings
                              , "container"
                                  .= object
                                    [ "image"
                                        .= ContainerImage.renderImageRef ContainerImage.harborEnvoyProxyImage
                                    ]
                              ]
                        , "envoyService"
                            .= object
                              [ "name" .= ("public-edge" :: String)
                              , "type" .= ("LoadBalancer" :: String)
                              , "loadBalancerIP" .= edgeLbIp
                              , "externalTrafficPolicy" .= ("Local" :: String)
                              , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
                              ]
                        ]
                  ]
            ]
      ]
  , object
      [ "apiVersion" .= ("gateway.networking.k8s.io/v1" :: String)
      , "kind" .= ("GatewayClass" :: String)
      , "metadata"
          .= object
            [ "name" .= publicEdgeGatewayClassName
            , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "spec"
          .= object
            [ "controllerName" .= ("gateway.envoyproxy.io/gatewayclass-controller" :: String)
            , "parametersRef"
                .= object
                  [ "group" .= ("gateway.envoyproxy.io" :: String)
                  , "kind" .= ("EnvoyProxy" :: String)
                  , "name" .= publicEdgeEnvoyProxyName
                  , "namespace" .= envoyGatewayNamespace
                  ]
            ]
      ]
  ]

-- | Sprint 1.80: a total projection of the union onto the MetalLB spelling. No
-- string comparison decides it any more; an unset mode is Layer 2, which is the
-- behaviour the superseded string fallback had and is now stated rather than
-- reached by falling off the end of a comparison.
configuredPublicEdgeAdvertisementMode :: ValidatedSettings -> String
configuredPublicEdgeAdvertisementMode settings =
  Text.unpack
    ( renderPublicEdgeAdvertisementMode
        (fromMaybe AdvertiseLayer2 (public_edge_advertisement_mode deploymentSection))
    )
 where
  deploymentSection = deployment (validatedConfig settings)

configuredPublicEdgeBgpPeers :: ValidatedSettings -> [MetallbBgpPeer]
configuredPublicEdgeBgpPeers settings =
  fromMaybe [] (public_edge_bgp_peers (deployment (validatedConfig settings)))

configuredEnvoyGatewayControllerReplicas :: ValidatedSettings -> Int
configuredEnvoyGatewayControllerReplicas settings =
  fromIntegral
    ( replicasForSubstrate
        SubstrateHomeLocal
        (envoy_gateway_controller_scaling (deployment (validatedConfig settings)))
    )

configuredEnvoyGatewayDataPlaneReplicas :: ValidatedSettings -> Int
configuredEnvoyGatewayDataPlaneReplicas settings =
  fromIntegral
    ( replicasForSubstrate
        SubstrateHomeLocal
        (envoy_gateway_data_plane_scaling (deployment (validatedConfig settings)))
    )

ensureCertManagerRuntime :: FilePath -> String -> String -> IO ExitCode
ensureCertManagerRuntime repoRoot prodboxId labelValue = do
  repoExit <- ensureHelmRepoAdded repoRoot certManagerRepositoryName certManagerRepositoryUrl
  case repoExit of
    ExitFailure _ -> pure repoExit
    ExitSuccess -> do
      installExit <-
        helmUpgradeInstallWithJsonValues
          repoRoot
          certManagerReleaseName
          certManagerChartRef
          certManagerChartVersion
          certManagerNamespace
          (certManagerHelmValues prodboxId labelValue)
      case installExit of
        ExitFailure _ -> pure installExit
        ExitSuccess ->
          runSequentially
            [ waitForDeployment repoRoot certManagerNamespace certManagerReleaseName
            , waitForDeployment repoRoot certManagerNamespace (certManagerReleaseName ++ "-webhook")
            , waitForDeployment repoRoot certManagerNamespace (certManagerReleaseName ++ "-cainjector")
            , waitForCrdEstablished repoRoot "clusterissuers.cert-manager.io"
            ]

certManagerHelmValues :: String -> String -> Value
certManagerHelmValues _prodboxId labelValue =
  object
    [ "crds" .= object ["enabled" .= True]
    , "image"
        .= object
          [ "repository" .= renderImageRefWithoutTag ContainerImage.harborCertManagerControllerImage
          , "tag" .= ContainerImage.imageTag ContainerImage.harborCertManagerControllerImage
          ]
    , "webhook"
        .= object
          [ "image"
              .= object
                [ "repository" .= renderImageRefWithoutTag ContainerImage.harborCertManagerWebhookImage
                , "tag" .= ContainerImage.imageTag ContainerImage.harborCertManagerWebhookImage
                ]
          ]
    , "cainjector"
        .= object
          [ "image"
              .= object
                [ "repository" .= renderImageRefWithoutTag ContainerImage.harborCertManagerCainjectorImage
                , "tag" .= ContainerImage.imageTag ContainerImage.harborCertManagerCainjectorImage
                ]
          ]
    , "acmesolver"
        .= object
          [ "image"
              .= object
                [ "repository" .= renderImageRefWithoutTag ContainerImage.harborCertManagerAcmesolverImage
                , "tag" .= ContainerImage.imageTag ContainerImage.harborCertManagerAcmesolverImage
                ]
          ]
    , "startupapicheck"
        .= object
          [ "image"
              .= object
                [ "repository" .= renderImageRefWithoutTag ContainerImage.harborCertManagerStartupApiCheckImage
                , "tag" .= ContainerImage.imageTag ContainerImage.harborCertManagerStartupApiCheckImage
                ]
          ]
    , "global"
        .= object
          [ "leaderElection" .= object ["namespace" .= certManagerNamespace]
          ]
    , "podLabels" .= object [Key.fromString prodboxLabelKey .= labelValue]
    , "resources"
        .= object
          [ "requests"
              .= object
                [ "cpu" .= ("50m" :: String)
                , "memory" .= ("64Mi" :: String)
                ]
          ]
    ]

ensureAcmeRuntime :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureAcmeRuntime = ensureAcmeRuntimeForSubstrate SubstrateHomeLocal

-- | Reconcile ACME against the currently selected kubeconfig. The AWS arm
-- consumes only its target-local run-scoped Vault generation; it never seeds
-- or resolves credential bytes on the host.
ensureAcmeRuntimeForSubstrate
  :: Substrate -> FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureAcmeRuntimeForSubstrate substrate repoRoot settings prodboxId labelValue = do
  staleDnsCleanup <-
    deleteMaterializerAndObservePodAbsence
      repoRoot
      certManagerNamespace
      dnsMaterializerName
  staleEabCleanup <-
    deleteMaterializerAndObservePodAbsence
      repoRoot
      certManagerNamespace
      acmeEabMaterializerName
  case preferFirstFailure staleDnsCleanup staleEabCleanup of
    ExitFailure code -> pure (ExitFailure code)
    ExitSuccess -> do
      -- Test fixture material enters the same committed Authority ingress as
      -- interactive material.  This call never writes Vault or the Target
      -- Agent directly and never returns either EAB field to this process.
      case substrate of
        SubstrateHomeLocal -> reconcileAcmeEabFixture LifecycleAuthorityOperator repoRoot
        SubstrateAws -> pure ()
      -- Sprint 1.81: resolve the hosted zone through the IO resolver rather than
      -- the pure reader. This is an IO context, and the IO resolver is the one
      -- that can consult the live aws-eks-subzone stack snapshot when
      -- `aws_substrate.hosted_zone_id` is empty — which the pure reader answered
      -- with a crash.
      hostedZoneResult <- resolveSubstrateHostedZoneId repoRoot settings substrate
      -- Sprint 1.89: the manifest render is now a decision too, so the two
      -- refusals resolve at the same point rather than one of them being a
      -- blank field inside an applied ClusterIssuer.
      case hostedZoneResult >>= \hostedZoneId ->
        acmeRuntimeManifestWith substrate settings hostedZoneId prodboxId labelValue of
        Left detail -> failWith detail
        Right acmeManifests ->
          withTemporaryJsonManifest
            "prodbox-acme-runtime"
            acmeManifests
            ( \manifestPath -> do
                applyExit <-
                  runCommand
                    Subprocess
                      { subprocessPath = "kubectl"
                      , subprocessArguments = ["apply", "-f", manifestPath]
                      , subprocessEnvironment = Nothing
                      , subprocessWorkingDirectory = Just repoRoot
                      }
                case applyExit of
                  ExitFailure _ -> pure applyExit
                  ExitSuccess -> do
                    dnsMaterialized <- awaitDns01Materialization repoRoot dnsMaterializerName
                    case dnsMaterialized of
                      ExitFailure _ -> pure dnsMaterialized
                      ExitSuccess -> do
                        eabMaterialized <- awaitAcmeMaterialization repoRoot settings
                        case eabMaterialized of
                          ExitFailure _ -> pure eabMaterialized
                          ExitSuccess ->
                            runCommand
                              Subprocess
                                { subprocessPath = "kubectl"
                                , subprocessArguments =
                                    [ "wait"
                                    , "--for=condition=Ready"
                                    , "clusterissuer/" ++ publicEdgeClusterIssuerName
                                    , "--timeout=300s"
                                    ]
                                , subprocessEnvironment = Nothing
                                , subprocessWorkingDirectory = Just repoRoot
                                }
            )
 where
  dnsMaterializerName = case substrate of
    SubstrateHomeLocal -> homeDns01MaterializerName
    SubstrateAws -> awsDns01MaterializerName

reconcileAcmeEabFixture :: ExternalLifecycleAuthorityCaller -> FilePath -> IO ()
reconcileAcmeEabFixture caller repoRoot =
  seedAcmeEabFromTestSecrets (submitAcmeEabFixture caller repoRoot) repoRoot

submitAcmeEabFixture
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> BS.ByteString
  -> IO (Either String ())
submitAcmeEabFixture caller repoRoot ingressFrame = do
  basicsResult <- loadUnencryptedBasics repoRoot
  imageResult <- resolveRuntimeChartImageForSubstrate SubstrateHomeLocal
  heartbeat <- round . (* 1000000) <$> getPOSIXTime
  case (basicsResult, imageResult) of
    (Left detail, _) -> pure (Left detail)
    (_, Left detail) -> pure (Left detail)
    (_, Right Nothing) -> pure (Left "The runtime image is unavailable for ACME EAB ingress.")
    (Right basics, Right (Just image)) ->
      case resolvedCustomImageManifestDigest image of
        Nothing ->
          pure (Left "The runtime image has no immutable repository manifest digest for ACME EAB ingress.")
        Just digest -> do
          let operationId = "acme-eab-fixture-" <> basicsClusterId basics
              repository =
                Text.pack
                  (resolvedCustomImageRepository image ++ ":" ++ resolvedCustomImageTag image)
              currentImageDigest = Text.pack digest
              jobs =
                kubernetesExternalMaterialJobBoundary
                  CredentialProvisionerJobConnection
                    { credentialProvisionerJobEnvironment = Nothing
                    , credentialProvisionerJobWorkingDirectory = repoRoot
                    , credentialProvisionerJobControllerSubject =
                        Just (externalCallerKubernetesSubject caller)
                    }
          submitted <-
            withHostLifecycleAuthorityAuthentication
              caller
              repoRoot
              ( \authentication ->
                  withLifecycleAuthorityAuthenticatedTransport authentication $ \transport -> do
                    withLifecycleAuthorityRetainedDeliveryAuthenticatedTransport
                      authentication
                      ( \deliveryTransport -> do
                          let client = externalMaterialIngressClient transport
                          observed <- observeCurrentExternalMaterialIngress client
                          case externalMaterialRequestForObservation
                            operationId
                            repository
                            currentImageDigest
                            heartbeat
                            observed of
                            Left detail -> pure (Left detail)
                            Right request ->
                              Bifunctor.first show
                                <$> runExternalMaterialIngressWorkflowWithDelivery
                                  client
                                  (retainedMaterialDeliveryClient deliveryTransport)
                                  (basicsClusterId basics)
                                  jobs
                                  request
                                  ingressFrame
                      )
              )
          pure $ case submitted of
            Left err -> Left (renderLifecycleAuthorityAuthenticationError err)
            Right (Left err) -> Left (renderLifecycleAuthorityAuthenticationError err)
            Right (Right (Left err)) -> Left (renderLifecycleAuthorityAuthenticationError err)
            Right (Right (Right (Left err))) -> Left err
            Right (Right (Right (Right _))) -> Right ()

externalMaterialRequestForObservation
  :: Text.Text
  -> Text.Text
  -> Text.Text
  -> Natural
  -> Either externalError (Maybe ExternalMaterialIngressObservation)
  -> Either String ExternalMaterialIngressWorkflowRequest
externalMaterialRequestForObservation operationId repository imageDigest heartbeat observed =
  case observed of
    Left _ -> Left "Lifecycle Authority current external-material observation is unavailable."
    Right Nothing -> Right (freshRequest ExternalMaterialInstall 1 imageDigest heartbeat)
    Right (Just current)
      | externalMaterialObservedOperationId current == operationId ->
          let challenge = externalMaterialObservedChallenge current
              deadline = externalMaterialChallengeDeadlineMicros challenge
              retainedHeartbeat = deadline - min deadline externalMaterialLeaseMicros
              action =
                if externalMaterialChallengeGeneration challenge == 1
                  then ExternalMaterialInstall
                  else ExternalMaterialRotate
              retainedReplay =
                ( freshRequest
                    action
                    (externalMaterialChallengeGeneration challenge)
                    (externalMaterialChallengeImageDigest challenge)
                    retainedHeartbeat
                )
                  { externalMaterialWorkflowDeadline = authorityTimeFromMicros deadline
                  }
           in Right
                ( if externalMaterialObservedPhase current
                    `elem` [ ExternalMaterialIngressIntentCommitted
                           , ExternalMaterialIngressPermitCommitted
                           ]
                    && deadline <= heartbeat
                    then
                      freshRequest
                        action
                        (externalMaterialChallengeGeneration challenge)
                        imageDigest
                        heartbeat
                    else retainedReplay
                )
      | externalMaterialObservedPhase current == ExternalMaterialIngressReceiptCommitted ->
          Right
            ( freshRequest
                ExternalMaterialRotate
                (externalMaterialChallengeGeneration (externalMaterialObservedChallenge current) + 1)
                imageDigest
                heartbeat
            )
      | otherwise ->
          Left "A different external-material ingress operation is still in progress."
 where
  freshRequest action generation selectedImage selectedHeartbeat =
    ExternalMaterialIngressWorkflowRequest
      { externalMaterialWorkflowAction = action
      , externalMaterialWorkflowOperationId = operationId
      , externalMaterialWorkflowGeneration = generation
      , externalMaterialWorkflowImageRepository = repository
      , externalMaterialWorkflowImageDigest = selectedImage
      , externalMaterialWorkflowDeadline =
          authorityTimeFromMicros (selectedHeartbeat + externalMaterialLeaseMicros)
      , externalMaterialWorkflowHeartbeatMicros = selectedHeartbeat
      }

externalMaterialLeaseMicros :: Natural
externalMaterialLeaseMicros = 30 * 60 * 1000000

awaitDns01Materialization :: FilePath -> String -> IO ExitCode
awaitDns01Materialization repoRoot materializerName = do
  waited <-
    captureKubectl
      repoRoot
      [ "wait"
      , "--namespace"
      , certManagerNamespace
      , "--for=condition=complete"
      , "--timeout=300s"
      , "job/" ++ materializerName
      ]
  outcome <- case waited of
    Left err -> failWith err
    Right output
      | processExitCode output /= ExitSuccess ->
          failWith "Home DNS01 credential materializer did not complete."
      | otherwise ->
          observeMaterializedSecretMetadata
            repoRoot
            certManagerNamespace
            route53CredentialsSecretName
            "home DNS01 credential"
  cleanup <-
    deleteMaterializerAndObservePodAbsence
      repoRoot
      certManagerNamespace
      materializerName
  pure (preferFirstFailure outcome cleanup)

awaitAcmeMaterialization :: FilePath -> ValidatedSettings -> IO ExitCode
awaitAcmeMaterialization repoRoot settings =
  case (eab_key_id acmeConfig, eab_hmac_key acmeConfig) of
    (Nothing, Nothing) -> pure ExitSuccess
    (Just (SecretRefVault _), Just (SecretRefVault _)) -> do
      waited <-
        captureKubectl
          repoRoot
          [ "wait"
          , "--namespace"
          , certManagerNamespace
          , "--for=condition=complete"
          , "--timeout=300s"
          , "job/" ++ acmeEabMaterializerName
          ]
      outcome <- case waited of
        Left err -> failWith err
        Right output
          | processExitCode output /= ExitSuccess ->
              failWith "ACME EAB materializer did not complete."
          | otherwise ->
              observeMaterializedSecretMetadata
                repoRoot
                certManagerNamespace
                acmeEabSecretName
                "ACME EAB"
      cleanup <-
        deleteMaterializerAndObservePodAbsence
          repoRoot
          certManagerNamespace
          acmeEabMaterializerName
      pure (preferFirstFailure outcome cleanup)
    _ -> failWith "ACME EAB requires both exact SecretRef.Vault references or neither."
 where
  acmeConfig = acme (validatedConfig settings)

observeMaterializedSecretMetadata
  :: FilePath -> String -> String -> String -> IO ExitCode
observeMaterializedSecretMetadata repoRoot namespace secretName label = do
  observed <-
    captureKubectl
      repoRoot
      [ "get"
      , "secret/" ++ secretName
      , "--namespace"
      , namespace
      , "--output=jsonpath={.metadata.uid}:{.metadata.resourceVersion}"
      ]
  case observed of
    Left err -> failWith err
    Right output
      | processExitCode output /= ExitSuccess ->
          failWith (label ++ " Secret metadata read-back failed: " ++ outputDetail output)
      | notElem ':' (trimWhitespace (processStdout output)) ->
          failWith (label ++ " Secret metadata read-back was incomplete.")
      | otherwise -> pure ExitSuccess

-- | Sprint 7.5.c.v follow-up: variant of 'acmeRuntimeManifest' that takes
-- an externally-resolved hosted-zone ID so the IO caller can fall back to
-- the live aws-eks-subzone Pulumi stack snapshot when
-- @aws_substrate.hosted_zone_id@ is empty in @prodbox.dhall@. See
-- 'Prodbox.PublicEdge.resolveSubstrateHostedZoneId' for the doctrine-
-- compliant resolution algorithm.
--
-- EAB material is not an argument: the exact in-cluster materializer reads
-- both fields and patches the one registered ClusterIssuer.
-- Sprint 1.89: refuses instead of rendering when the ACME account or the
-- operational region is unconfigured. Both were previously rendered as whatever
-- the raw field held, which on a home-only config is the empty string — a
-- ClusterIssuer whose contact and region are blank applies cleanly and fails at
-- ACME registration.
acmeRuntimeManifestWith
  :: Substrate -> ValidatedSettings -> Text.Text -> String -> String -> Either String [Value]
acmeRuntimeManifestWith substrate settings hostedZoneId prodboxId labelValue =
  (credentialResources ++)
    <$> acmeCommonRuntimeResources settings hostedZoneId prodboxId labelValue
 where
  credentialResources = case substrate of
    SubstrateHomeLocal -> homeDns01MaterializerManifests prodboxId labelValue
    SubstrateAws -> awsDns01TargetMaterializerManifests prodboxId labelValue

acmeCommonRuntimeResources
  :: ValidatedSettings -> Text.Text -> String -> String -> Either String [Value]
acmeCommonRuntimeResources settings hostedZoneId prodboxId labelValue = do
  acmeAccount <- requireAcmeAccount settings
  awsRegion <- requireOperationalAwsRegion settings
  Right (clusterIssuer acmeAccount awsRegion : eabMaterializerResources)
 where
  acmeConfig = acme (validatedConfig settings)
  -- Sprint 7.15: when EAB is configured, render the Vault-login materializer
  -- (ServiceAccount + Role + RoleBinding + Job) that creates the
  -- 'acmeEabSecretName' Secret from Vault @secret/acme/eab#hmac_key@ rather
  -- than rendering the plaintext HMAC key inline. The materializer reuses
  -- the Sprint 3.18 chart-side pattern (see
  -- charts/vscode/templates/securitypolicy-client-secret-job.yaml).
  eabMaterializerResources =
    case (eab_key_id acmeConfig, eab_hmac_key acmeConfig) of
      (Just _, Just _) -> acmeEabMaterializerManifests prodboxId labelValue
      _ -> []
  clusterIssuer acmeAccount awsRegion =
    clusterIssuerResource
      publicEdgeClusterIssuerName
      (acmeClusterIssuerSpec acmeAccount awsRegion hostedZoneId)
  clusterIssuerResource issuerName issuerSpec =
    object
      [ "apiVersion" .= ("cert-manager.io/v1" :: String)
      , "kind" .= ("ClusterIssuer" :: String)
      , "metadata"
          .= object
            [ "name" .= issuerName
            , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "spec" .= object ["acme" .= issuerSpec]
      ]

-- | Project the exact LongLived home DNS01 generation into cert-manager's
-- fixed solver Secret.  Vault payload bytes remain in a pod-scoped memory
-- volume; the sibling writer is authorized to create Secrets in the target
-- namespace and to read/update/patch only the fixed Secret after creation.
homeDns01MaterializerManifests :: String -> String -> [Value]
homeDns01MaterializerManifests prodboxId labelValue =
  dns01TargetMaterializerManifests
    homeDns01MaterializerName
    homeDns01VaultRole
    homeDns01VaultPath
    prodboxId
    labelValue

-- | AWS uses a distinct run-scoped Vault object and ServiceAccount.  This is
-- the target-local one-shot projection: credential bytes move only from the
-- EKS Vault session through a memory volume into the fixed cert-manager
-- Secret, never through the host or the Gateway.
awsDns01TargetMaterializerManifests :: String -> String -> [Value]
awsDns01TargetMaterializerManifests prodboxId labelValue =
  dns01TargetMaterializerManifests
    awsDns01MaterializerName
    "aws-cert-manager-run"
    awsDns01VaultPath
    prodboxId
    labelValue

dns01TargetMaterializerManifests
  :: String -> String -> String -> String -> String -> [Value]
dns01TargetMaterializerManifests materializerName vaultRole vaultPath prodboxId labelValue =
  [ serviceAccount
  , role
  , roleBinding
  , job
  ]
 where
  metadata =
    object
      [ "name" .= materializerName
      , "namespace" .= certManagerNamespace
      , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
      , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
      ]
  serviceAccount =
    object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("ServiceAccount" :: String)
      , "metadata" .= metadata
      ]
  role =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("Role" :: String)
      , "metadata" .= metadata
      , "rules"
          .= [ object
                 [ "apiGroups" .= ([""] :: [String])
                 , "resources" .= (["secrets"] :: [String])
                 , "verbs" .= (["create"] :: [String])
                 ]
             , object
                 [ "apiGroups" .= ([""] :: [String])
                 , "resources" .= (["secrets"] :: [String])
                 , "resourceNames" .= ([route53CredentialsSecretName] :: [String])
                 , "verbs" .= (["get", "update", "patch"] :: [String])
                 ]
             ]
      ]
  roleBinding =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("RoleBinding" :: String)
      , "metadata" .= metadata
      , "subjects"
          .= [ object
                 [ "kind" .= ("ServiceAccount" :: String)
                 , "name" .= materializerName
                 , "namespace" .= certManagerNamespace
                 ]
             ]
      , "roleRef"
          .= object
            [ "apiGroup" .= ("rbac.authorization.k8s.io" :: String)
            , "kind" .= ("Role" :: String)
            , "name" .= materializerName
            ]
      ]
  initScript =
    unlines
      [ "set -eu"
      , "jwt=\"$(cat \"${VAULT_SA_TOKEN_FILE}\")\""
      , "export VAULT_TOKEN=\"$(vault write -field=token \"auth/${VAULT_AUTH_PATH}/login\" role=\"${VAULT_ROLE}\" jwt=\"${jwt}\")\""
      , "umask 077"
      , "vault kv get -field=access_key_id secret/"
          ++ vaultPath
          ++ " > /vault-materialized/access-key-id"
      , "vault kv get -field=secret_access_key secret/"
          ++ vaultPath
          ++ " > /vault-materialized/secret-access-key"
      , "test -s /vault-materialized/access-key-id"
      , "test -s /vault-materialized/secret-access-key"
      , "chmod 0644 /vault-materialized/access-key-id /vault-materialized/secret-access-key"
      ]
  materializeScript =
    unlines
      [ "set -eu"
      , "api_server=\"https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}\""
      , "token=\"$(cat \"${SERVICEACCOUNT_TOKEN_FILE}\")\""
      , "access_key_b64=\"$(base64 < /vault-materialized/access-key-id | tr -d '\\n')\""
      , "secret_key_b64=\"$(base64 < /vault-materialized/secret-access-key | tr -d '\\n')\""
      , "test -n \"${access_key_b64}\""
      , "test -n \"${secret_key_b64}\""
      , "cat > /vault-materialized/create.json <<EOF"
      , "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${SECRET_NAME}\",\"labels\":{\"app.kubernetes.io/managed-by\":\"prodbox\"}},\"type\":\"Opaque\",\"data\":{\"access-key-id\":\"${access_key_b64}\",\"secret-access-key\":\"${secret_key_b64}\"}}"
      , "EOF"
      , "cat > /vault-materialized/patch.json <<EOF"
      , "{\"type\":\"Opaque\",\"data\":{\"access-key-id\":\"${access_key_b64}\",\"secret-access-key\":\"${secret_key_b64}\"}}"
      , "EOF"
      , "create_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/json\" -o /vault-materialized/create-response.json -w '%{http_code}' --data-binary @/vault-materialized/create.json \"${api_server}/api/v1/namespaces/${POD_NAMESPACE}/secrets\" || true)\""
      , "case \"${create_code}\" in"
      , "  201) exit 0 ;;"
      , "  409)"
      , "    patch_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/merge-patch+json\" -o /vault-materialized/patch-response.json -w '%{http_code}' --request PATCH --data-binary @/vault-materialized/patch.json \"${api_server}/api/v1/namespaces/${POD_NAMESPACE}/secrets/${SECRET_NAME}\" || true)\""
      , "    case \"${patch_code}\" in 200|201) exit 0 ;; *) echo 'home DNS01 Secret patch was refused' >&2; exit 1 ;; esac ;;"
      , "  *) echo 'home DNS01 Secret create was refused' >&2; exit 1 ;;"
      , "esac"
      ]
  job =
    object
      [ "apiVersion" .= ("batch/v1" :: String)
      , "kind" .= ("Job" :: String)
      , "metadata" .= metadata
      , "spec"
          .= object
            [ "backoffLimit" .= (0 :: Int)
            , "ttlSecondsAfterFinished" .= (60 :: Int)
            , "template"
                .= object
                  [ "metadata"
                      .= object
                        [ "labels"
                            .= object
                              [ Key.fromString prodboxLabelKey .= labelValue
                              , "app.kubernetes.io/name" .= materializerName
                              ]
                        ]
                  , "spec"
                      .= object
                        [ "serviceAccountName" .= materializerName
                        , "restartPolicy" .= ("Never" :: String)
                        , "initContainers"
                            .= [ object
                                   [ "name" .= ("vault-secrets" :: String)
                                   , "image" .= ContainerImage.renderImageRef ContainerImage.publicVaultImage
                                   , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                   , "env"
                                       .= [ envVar "VAULT_ADDR" "http://vault.vault.svc.cluster.local:8200"
                                          , envVar "VAULT_AUTH_PATH" "kubernetes"
                                          , envVar "VAULT_ROLE" vaultRole
                                          , envVar "VAULT_SA_TOKEN_FILE" "/var/run/secrets/kubernetes.io/serviceaccount/token"
                                          ]
                                   , "command" .= (["/bin/sh", "-ec", initScript] :: [String])
                                   , "volumeMounts" .= [materializedVolumeMount]
                                   ]
                               ]
                        , "containers"
                            .= [ object
                                   [ "name" .= ("materialize-route53-secret" :: String)
                                   , "image" .= ContainerImage.renderImageRef ContainerImage.harborCurlImage
                                   , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                   , "env"
                                       .= [ object
                                              [ "name" .= ("POD_NAMESPACE" :: String)
                                              , "valueFrom"
                                                  .= object
                                                    [ "fieldRef"
                                                        .= object ["fieldPath" .= ("metadata.namespace" :: String)]
                                                    ]
                                              ]
                                          , envVar "SECRET_NAME" route53CredentialsSecretName
                                          , envVar "SERVICEACCOUNT_TOKEN_FILE" "/var/run/secrets/kubernetes.io/serviceaccount/token"
                                          , envVar "SERVICEACCOUNT_CA_FILE" "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
                                          ]
                                   , "command" .= (["/bin/sh", "-ec", materializeScript] :: [String])
                                   , "volumeMounts" .= [materializedVolumeMount]
                                   ]
                               ]
                        , "volumes"
                            .= [ object
                                   [ "name" .= ("vault-materialized" :: String)
                                   , "emptyDir"
                                       .= object
                                         [ "medium" .= ("Memory" :: String)
                                         , "sizeLimit" .= ("1Mi" :: String)
                                         ]
                                   ]
                               ]
                        ]
                  ]
            ]
      ]
  envVar :: String -> String -> Value
  envVar name value = object ["name" .= name, "value" .= value]
  materializedVolumeMount =
    object
      [ "name" .= ("vault-materialized" :: String)
      , "mountPath" .= ("/vault-materialized" :: String)
      ]

-- | Sprint 7.15: the EAB HMAC secret materializer — a ServiceAccount, a
-- least-privilege Role (create the @acme-eab-credentials@ Secret;
-- get/update/patch only it), a RoleBinding, and a Job that logs into Vault
-- via Kubernetes auth (role @acme@), reads @secret/acme/eab#hmac_key@, and
-- creates the @acme-eab-credentials@ Secret in @cert-manager@. This mirrors
-- @charts/vscode/templates/securitypolicy-client-secret-job.yaml@ exactly;
-- the HMAC key never transits the operator host.
acmeEabMaterializerManifests :: String -> String -> [Value]
acmeEabMaterializerManifests prodboxId labelValue =
  [ serviceAccount
  , role
  , roleBinding
  , clusterRole
  , clusterRoleBinding
  , job
  ]
 where
  managedMetadata extra =
    object
      ( [ "name" .= acmeEabMaterializerName
        , "namespace" .= certManagerNamespace
        , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
        , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
        ]
          ++ extra
      )
  serviceAccount =
    object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("ServiceAccount" :: String)
      , "metadata" .= managedMetadata []
      ]
  role =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("Role" :: String)
      , "metadata" .= managedMetadata []
      , "rules"
          .= [ object
                 [ "apiGroups" .= ([""] :: [String])
                 , "resources" .= (["secrets"] :: [String])
                 , "verbs" .= (["create"] :: [String])
                 ]
             , object
                 [ "apiGroups" .= ([""] :: [String])
                 , "resources" .= (["secrets"] :: [String])
                 , "resourceNames" .= ([acmeEabSecretName] :: [String])
                 , "verbs" .= (["get", "update", "patch"] :: [String])
                 ]
             ]
      ]
  roleBinding =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("RoleBinding" :: String)
      , "metadata" .= managedMetadata []
      , "subjects"
          .= [ object
                 [ "kind" .= ("ServiceAccount" :: String)
                 , "name" .= acmeEabMaterializerName
                 , "namespace" .= certManagerNamespace
                 ]
             ]
      , "roleRef"
          .= object
            [ "apiGroup" .= ("rbac.authorization.k8s.io" :: String)
            , "kind" .= ("Role" :: String)
            , "name" .= acmeEabMaterializerName
            ]
      ]
  clusterRole =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("ClusterRole" :: String)
      , "metadata"
          .= object
            [ "name" .= acmeEabMaterializerName
            , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "rules"
          .= [ object
                 [ "apiGroups" .= (["cert-manager.io"] :: [String])
                 , "resources" .= (["clusterissuers"] :: [String])
                 , "resourceNames" .= ([publicEdgeClusterIssuerName] :: [String])
                 , "verbs" .= (["get", "patch"] :: [String])
                 ]
             ]
      ]
  clusterRoleBinding =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("ClusterRoleBinding" :: String)
      , "metadata"
          .= object
            [ "name" .= acmeEabMaterializerName
            , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "subjects"
          .= [ object
                 [ "kind" .= ("ServiceAccount" :: String)
                 , "name" .= acmeEabMaterializerName
                 , "namespace" .= certManagerNamespace
                 ]
             ]
      , "roleRef"
          .= object
            [ "apiGroup" .= ("rbac.authorization.k8s.io" :: String)
            , "kind" .= ("ClusterRole" :: String)
            , "name" .= acmeEabMaterializerName
            ]
      ]
  vaultImage = ContainerImage.renderImageRef ContainerImage.publicVaultImage
  curlImage = ContainerImage.renderImageRef ContainerImage.harborCurlImage
  initScript =
    unlines
      [ "set -eu"
      , "jwt=\"$(cat \"${VAULT_SA_TOKEN_FILE}\")\""
      , "export VAULT_TOKEN=\"$(vault write -field=token \"auth/${VAULT_AUTH_PATH}/login\" role=\"${VAULT_ROLE}\" jwt=\"${jwt}\")\""
      , "umask 077"
      , "vault kv get -field="
          ++ acmeEabVaultHmacField
          ++ " secret/"
          ++ acmeEabVaultPath
          ++ " > /vault-materialized/hmac-key"
      , "vault kv get -field="
          ++ acmeEabVaultKeyIdField
          ++ " secret/"
          ++ acmeEabVaultPath
          ++ " > /vault-materialized/key-id"
      , "test -s /vault-materialized/hmac-key"
      , "test -s /vault-materialized/key-id"
      , -- The sibling 'materialize-eab-secret' container runs the curl image
        -- as a different (non-root) UID than this vault-image init container,
        -- so the @umask 077@ file (0600, owned by the init UID) is otherwise
        -- unreadable to it — base64 reads nothing and the materialized Secret
        -- comes out empty (ZeroSSL then fails with "empty MAC key"). The
        -- volume is a pod-scoped in-memory emptyDir, so widening this handoff
        -- file to 0644 for the sibling read keeps the secret inside the pod
        -- trust boundary.
        "chmod 0644 /vault-materialized/hmac-key /vault-materialized/key-id"
      ]
  materializeScript =
    unlines
      [ "set -eu"
      , "api_server=\"https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}\""
      , "token=\"$(cat \"${SERVICEACCOUNT_TOKEN_FILE}\")\""
      , "hmac_b64=\"$(base64 < /vault-materialized/hmac-key | tr -d '\\n')\""
      , "key_id=\"$(cat /vault-materialized/key-id)\""
      , "[ -n \"${key_id}\" ] && [ \"${#key_id}\" -le 512 ] && printf '%s' \"${key_id}\" | grep -Eq '^[A-Za-z0-9._~-]+$' || { echo 'materialized EAB key ID has an unsupported shape' >&2; exit 1; }"
      , -- Fail loud rather than materialize an empty Secret: an empty HMAC
        -- here surfaces only later as the opaque ZeroSSL "cannot sign JWS
        -- with an empty MAC key" error. If the handoff file is empty or
        -- unreadable, fail the one-shot Job without retrying it.
        "[ -n \"${hmac_b64}\" ] || { echo 'materialized EAB HMAC is empty: secret/acme/eab#hmac_key is missing/empty in Vault or the handoff file was unreadable' >&2 ; exit 1 ; }"
      , "cat > /vault-materialized/secret-create.json <<EOF"
      , "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${SECRET_NAME}\",\"labels\":{\"app.kubernetes.io/managed-by\":\"prodbox\"}},\"type\":\"Opaque\",\"data\":{\""
          ++ acmeEabSecretKey
          ++ "\":\"${hmac_b64}\"}}"
      , "EOF"
      , "cat > /vault-materialized/secret-patch.json <<EOF"
      , "{\"type\":\"Opaque\",\"data\":{\"" ++ acmeEabSecretKey ++ "\":\"${hmac_b64}\"}}"
      , "EOF"
      , "create_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/json\" -o /vault-materialized/secret-create-response.json -w '%{http_code}' --data-binary @/vault-materialized/secret-create.json \"${api_server}/api/v1/namespaces/${POD_NAMESPACE}/secrets\" || true)\""
      , "case \"${create_code}\" in"
      , "  201) ;;"
      , "  409)"
      , "    patch_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/merge-patch+json\" -o /vault-materialized/secret-patch-response.json -w '%{http_code}' --request PATCH --data-binary @/vault-materialized/secret-patch.json \"${api_server}/api/v1/namespaces/${POD_NAMESPACE}/secrets/${SECRET_NAME}\" || true)\""
      , "    case \"${patch_code}\" in 200|201) ;; *) echo 'EAB Secret patch was refused' >&2 ; exit 1 ;; esac ;;"
      , "  *) echo 'EAB Secret create was refused' >&2 ; exit 1 ;;"
      , "esac"
      , "cat > /vault-materialized/issuer-patch.json <<EOF"
      , "{\"spec\":{\"acme\":{\"externalAccountBinding\":{\"keyID\":\"${key_id}\",\"keySecretRef\":{\"name\":\""
          ++ acmeEabSecretName
          ++ "\",\"key\":\""
          ++ acmeEabSecretKey
          ++ "\"}}}}}"
      , "EOF"
      , "issuer_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/merge-patch+json\" -o /vault-materialized/issuer-patch-response.json -w '%{http_code}' --request PATCH --data-binary @/vault-materialized/issuer-patch.json \"${api_server}/apis/cert-manager.io/v1/clusterissuers/${ISSUER_NAME}\" || true)\""
      , "case \"${issuer_code}\" in 200) exit 0 ;; *) echo 'ClusterIssuer EAB patch was refused' >&2; exit 1 ;; esac"
      ]
  job =
    object
      [ "apiVersion" .= ("batch/v1" :: String)
      , "kind" .= ("Job" :: String)
      , "metadata" .= managedMetadata []
      , "spec"
          .= object
            [ "backoffLimit" .= (0 :: Int)
            , "ttlSecondsAfterFinished" .= (60 :: Int)
            , "template"
                .= object
                  [ "metadata"
                      .= object
                        [ "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
                        ]
                  , "spec"
                      .= object
                        [ "serviceAccountName" .= acmeEabMaterializerName
                        , "restartPolicy" .= ("Never" :: String)
                        , "initContainers"
                            .= [ object
                                   [ "name" .= ("vault-secrets" :: String)
                                   , "image" .= vaultImage
                                   , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                   , "env"
                                       .= [ envVar "VAULT_ADDR" "http://vault.vault.svc.cluster.local:8200"
                                          , envVar "VAULT_AUTH_PATH" "kubernetes"
                                          , envVar "VAULT_ROLE" acmeEabVaultRole
                                          , envVar
                                              "VAULT_SA_TOKEN_FILE"
                                              "/var/run/secrets/kubernetes.io/serviceaccount/token"
                                          ]
                                   , "command" .= (["/bin/sh", "-ec", initScript] :: [String])
                                   , "volumeMounts"
                                       .= [ object
                                              [ "name" .= ("vault-materialized" :: String)
                                              , "mountPath" .= ("/vault-materialized" :: String)
                                              ]
                                          ]
                                   ]
                               ]
                        , "containers"
                            .= [ object
                                   [ "name" .= ("materialize-eab-secret" :: String)
                                   , "image" .= curlImage
                                   , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                   , "env"
                                       .= [ object
                                              [ "name" .= ("POD_NAMESPACE" :: String)
                                              , "valueFrom"
                                                  .= object
                                                    [ "fieldRef"
                                                        .= object
                                                          ["fieldPath" .= ("metadata.namespace" :: String)]
                                                    ]
                                              ]
                                          , envVar "SECRET_NAME" acmeEabSecretName
                                          , envVar "ISSUER_NAME" publicEdgeClusterIssuerName
                                          , envVar
                                              "SERVICEACCOUNT_TOKEN_FILE"
                                              "/var/run/secrets/kubernetes.io/serviceaccount/token"
                                          , envVar
                                              "SERVICEACCOUNT_CA_FILE"
                                              "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
                                          ]
                                   , "command" .= (["sh", "-c", materializeScript] :: [String])
                                   , "volumeMounts"
                                       .= [ object
                                              [ "name" .= ("vault-materialized" :: String)
                                              , "mountPath" .= ("/vault-materialized" :: String)
                                              , "readOnly" .= False
                                              ]
                                          ]
                                   ]
                               ]
                        , "volumes"
                            .= [ object
                                   [ "name" .= ("vault-materialized" :: String)
                                   , "emptyDir"
                                       .= object
                                         [ "medium" .= ("Memory" :: String)
                                         , "sizeLimit" .= ("1Mi" :: String)
                                         ]
                                   ]
                               ]
                        ]
                  ]
            ]
      ]
  envVar :: String -> String -> Value
  envVar name value =
    object ["name" .= name, "value" .= value]

-- | The DNS-01 Route 53 ACME solver block referenced by the ZeroSSL
-- 'ClusterIssuer'. Keyed off 'route53CredentialsSecretName' and the
-- substrate hosted zone.
acmeRoute53Solver :: Text.Text -> Text.Text -> Value
acmeRoute53Solver awsRegion hostedZoneId =
  object
    [ "dns01"
        .= object
          [ "route53"
              .= object
                [ "region" .= Text.unpack awsRegion
                , "hostedZoneID" .= Text.unpack hostedZoneId
                , "accessKeyIDSecretRef"
                    .= object
                      [ "name" .= route53CredentialsSecretName
                      , "key" .= ("access-key-id" :: String)
                      ]
                , "secretAccessKeySecretRef"
                    .= object
                      [ "name" .= route53CredentialsSecretName
                      , "key" .= ("secret-access-key" :: String)
                      ]
                ]
          ]
    ]

-- | Secret-free base for the ZeroSSL ACME @ClusterIssuer@.  When EAB is
-- configured, the namespace-scoped one-shot materializer patches the exact
-- @externalAccountBinding@ from its in-memory Vault projection.  Neither EAB
-- field is representable at this host rendering boundary.
-- Sprint 1.89: the renderer takes the parsed account and region rather than a
-- 'ValidatedSettings' it re-reads them from.
--
-- This is the shape Sprint 1.87 established and the reason it gave: handing a
-- pure renderer the raw @Text@ leaves @\"\"@ a well-typed inhabitant of every
-- argument, so the refusal lives in caller discipline. An 'AcmeAccount' and an
-- 'AwsRegion' have no empty inhabitant, so a ClusterIssuer with a blank contact
-- or a blank region is unconstructible here rather than merely unlikely.
acmeClusterIssuerSpec :: AcmeAccount -> AwsRegion -> Text.Text -> Value
acmeClusterIssuerSpec acmeAccount awsRegion hostedZoneId =
  object
    [ "server" .= Text.unpack (acmeDirectoryUrlText (acmeAccountDirectoryUrl acmeAccount))
    , "email" .= Text.unpack (emailAddressText (acmeAccountEmail acmeAccount))
    , "privateKeySecretRef" .= object ["name" .= zerosslAccountKeySecretName]
    , "solvers" .= [acmeRoute53Solver (awsRegionText awsRegion) hostedZoneId]
    ]

ensurePostgresOperatorRuntime :: FilePath -> String -> String -> IO ExitCode
ensurePostgresOperatorRuntime repoRoot prodboxId labelValue = do
  repoExit <-
    ensureHelmRepoAdded repoRoot postgresOperatorRepositoryName postgresOperatorRepositoryUrl
  case repoExit of
    ExitFailure _ -> pure repoExit
    ExitSuccess -> do
      installExit <-
        helmUpgradeInstallWithJsonValues
          repoRoot
          patroniOperatorReleaseName
          postgresOperatorChartRef
          postgresOperatorChartVersion
          patroniOperatorNamespace
          (postgresOperatorHelmValues prodboxId labelValue)
      case installExit of
        ExitFailure _ -> pure installExit
        ExitSuccess ->
          runSequentially
            [ waitForCrdEstablished repoRoot patroniPostgresqlCrdName
            , waitForDeployment repoRoot patroniOperatorNamespace patroniOperatorDeploymentName
            ]

postgresOperatorHelmValues :: String -> String -> Value
postgresOperatorHelmValues prodboxId _labelValue =
  object
    [ "operatorImageRepository"
        .= renderImageRefWithoutTag ContainerImage.harborPostgresOperatorImage
    , "imagePullPolicy" .= ("IfNotPresent" :: String)
    , "watchAllNamespaces" .= True
    , "disableTelemetry" .= True
    , "fullnameOverride" .= patroniOperatorDeploymentName
    , "podAnnotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
    ]

ensureHelmRepoAdded :: FilePath -> String -> String -> IO ExitCode
ensureHelmRepoAdded repoRoot repoName repoUrl = do
  repoAddResult <- captureToolOutput repoRoot "helm" ["repo", "add", repoName, repoUrl]
  case repoAddResult of
    Left err -> failWith err
    Right repoAddOutput ->
      case processExitCode repoAddOutput of
        ExitFailure _
          | "already exists" `isInfixOf` map toLower (outputDetail repoAddOutput) -> updateRepo
          | otherwise ->
              failWith ("Failed to add Helm repo " ++ repoName ++ ": " ++ outputDetail repoAddOutput)
        ExitSuccess -> updateRepo
 where
  updateRepo =
    runHelmCommandWithRetries repoRoot ["repo", "update", repoName]

helmUpgradeInstallWithJsonValues
  :: FilePath -> String -> String -> String -> String -> Value -> IO ExitCode
helmUpgradeInstallWithJsonValues repoRoot releaseName chartRef chartVersion namespace values =
  helmUpgradeInstallWithJsonValuesAndArgs
    repoRoot
    releaseName
    chartRef
    []
    chartVersion
    namespace
    values

helmUpgradeInstallWithJsonValuesAndArgs
  :: FilePath -> String -> String -> [String] -> String -> String -> Value -> IO ExitCode
helmUpgradeInstallWithJsonValuesAndArgs repoRoot releaseName chartRef extraArgs chartVersion namespace values =
  withTemporaryJsonBytes ("prodbox-helm-values-" ++ releaseName) (encode values) $ \valuesPath ->
    runHelmCommandWithRetries
      repoRoot
      ( [ "upgrade"
        , "--install"
        , releaseName
        , chartRef
        ]
          ++ extraArgs
          ++ [ "--version"
             , chartVersion
             , "--namespace"
             , namespace
             , "--create-namespace"
             , "-f"
             , valuesPath
             ]
      )

runHelmCommandWithRetries :: FilePath -> [String] -> IO ExitCode
runHelmCommandWithRetries repoRoot arguments = go (retryPolicyMaxAttempts helmTransientRetryPolicy)
 where
  go attemptsRemaining = do
    outputResult <- captureToolOutput repoRoot "helm" arguments
    case outputResult of
      Left err -> failWith err
      Right output ->
        case processExitCode output of
          ExitSuccess -> do
            emitCapturedProcessOutput output
            pure ExitSuccess
          failure@(ExitFailure _)
            | attemptsRemaining > 1 && isRetryableHelmFailure output -> do
                writeDiagnosticLine
                  ( "Retrying helm "
                      ++ unwords arguments
                      ++ " after transient upstream failure ("
                      ++ show (retryPolicyMaxAttempts helmTransientRetryPolicy - attemptsRemaining + 1)
                      ++ "/"
                      ++ show (retryPolicyMaxAttempts helmTransientRetryPolicy)
                      ++ "): "
                      ++ outputDetail output
                  )
                threadDelay
                  =<< drawRetryDelayMicros
                    helmTransientRetryPolicy
                    (retryPolicyMaxAttempts helmTransientRetryPolicy - attemptsRemaining)
                go (attemptsRemaining - 1)
            | otherwise -> do
                emitCapturedProcessOutput output
                pure failure

isRetryableHelmFailure :: ProcessOutput -> Bool
isRetryableHelmFailure output =
  isRetryableTransientFailure
    [ "failed to fetch"
    , "failed to download"
    ]
    (outputDetail output)

waitForCrdEstablished :: FilePath -> String -> IO ExitCode
waitForCrdEstablished repoRoot crdName =
  runCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "wait"
          , "--for=condition=Established"
          , "--timeout=300s"
          , "crd/" ++ crdName
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

rolloutStatus :: FilePath -> String -> String -> IO ExitCode
rolloutStatus repoRoot namespace resourceRef =
  runCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "rollout"
          , "status"
          , resourceRef
          , "--namespace"
          , namespace
          , "--timeout=300s"
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

-- | Roll-restart a Deployment (new pods, same manifest). Used by the post-Vault
-- gateway step to re-boot the daemon into full mode when its byte-identical
-- ConfigMap would otherwise never trigger a rollout.
rolloutRestart :: FilePath -> String -> String -> IO ExitCode
rolloutRestart repoRoot namespace resourceRef =
  runCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "rollout"
          , "restart"
          , resourceRef
          , "--namespace"
          , namespace
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

kubectlApplyJsonManifest :: FilePath -> String -> [Value] -> IO ExitCode
kubectlApplyJsonManifest repoRoot prefix items =
  withTemporaryJsonManifest prefix items $ \manifestPath -> do
    outputResult <- captureKubectl repoRoot ["apply", "-f", manifestPath]
    case outputResult of
      Left err -> failWith err
      Right output ->
        case processExitCode output of
          ExitSuccess -> pure ExitSuccess
          ExitFailure _ -> failWith ("kubectl apply failed: " ++ outputDetail output)

ensureRootChartNamespaceGuardrails :: FilePath -> ValidatedSettings -> IO ExitCode
ensureRootChartNamespaceGuardrails repoRoot settings = do
  credentialGate <- resolveOperationalAwsCredentialGate repoRoot settings
  case credentialGate of
    OperationalAwsCredentialsAbsent _ -> do
      writeOutputLine
        ( "Skipping root chart namespace guardrails: operational aws.* is empty or"
            ++ " missing in Vault, so the gateway chart namespace bootstrap was skipped."
        )
      pure ExitSuccess
    OperationalAwsCredentialsInvalid err ->
      failWith ("load operational AWS credentials from Vault: " ++ err)
    OperationalAwsCredentialsReady ->
      case rootChartNamespaceGuardrailItems plan of
        Left err -> failWith err
        Right items -> kubectlApplyJsonManifest repoRoot "root-chart-namespace-guardrails" items
 where
  plan = validatedResourcePlan settings

rootChartNamespaceGuardrailItems :: Capacity.ResourcePlan -> Either String [Value]
rootChartNamespaceGuardrailItems plan =
  fmap concat (traverse (rootChartNamespaceGuardrailItemsFor plan) dormantRootChartNamespaces)

dormantRootChartNamespaces :: [String]
dormantRootChartNamespaces =
  -- `vscode`, `api`, `websocket`, and `gateway` render their guardrails from
  -- active Helm releases. `keycloak` is also a supported root chart, but the
  -- canonical workflow normally consumes it as the `vscode` dependency; keep
  -- the standalone namespace capped without deploying a duplicate workload.
  ["keycloak"]

rootChartNamespaceGuardrailItemsFor :: Capacity.ResourcePlan -> String -> Either String [Value]
rootChartNamespaceGuardrailItemsFor plan namespace = do
  namespaceAdmission <- Placement.planNamespaceAdmission SubstrateAws (Text.pack namespace) plan
  limitEnvelope <- Placement.planNamespaceLimits SubstrateAws (Text.pack namespace) plan
  pure
    [ rootChartResourceQuotaManifest namespace namespaceAdmission
    , rootChartLimitRangeManifest namespace limitEnvelope
    ]

rootChartResourceQuotaManifest :: String -> Capacity.ResourceEnvelope -> Value
rootChartResourceQuotaManifest namespace namespaceAdmission =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("ResourceQuota" :: String)
    , "metadata" .= rootChartGuardrailMetadata namespace (namespace ++ "-resource-quota")
    , "spec" .= CapacityRender.resourceQuotaEnvelopeSpec namespaceAdmission
    ]

rootChartLimitRangeManifest :: String -> Capacity.ResourceEnvelope -> Value
rootChartLimitRangeManifest namespace envelope =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("LimitRange" :: String)
    , "metadata" .= rootChartGuardrailMetadata namespace (namespace ++ "-limit-range")
    , "spec"
        .= object
          [ "limits"
              .= [ object
                     [ "type" .= ("Container" :: String)
                     , "default" .= CapacityRender.resourceVectorRuntimeValue (Capacity.limit envelope)
                     , "defaultRequest" .= CapacityRender.resourceVectorRuntimeValue (Capacity.request envelope)
                     ]
                 ]
          ]
    ]

rootChartGuardrailMetadata :: String -> String -> Value
rootChartGuardrailMetadata namespace name =
  object
    [ "name" .= name
    , "namespace" .= namespace
    , "annotations"
        .= object
          [ "meta.helm.sh/release-name" .= namespace
          , "meta.helm.sh/release-namespace" .= namespace
          ]
    , "labels"
        .= object
          [ "app.kubernetes.io/name" .= namespace
          , "app.kubernetes.io/instance" .= namespace
          , "app.kubernetes.io/managed-by" .= ("Helm" :: String)
          , "prodbox.io/chart-root" .= namespace
          ]
    ]

lookupNonEmptyEnv :: String -> IO (Maybe String)
lookupNonEmptyEnv name = do
  maybeValue <- lookupEnv name
  pure $
    case maybeValue of
      Just value ->
        let trimmed = trimWhitespace value
         in if trimmed == ""
              then Nothing
              else Just trimmed
      Nothing -> Nothing

mirrorClusterImagesOnce :: FilePath -> IO ExitCode
mirrorClusterImagesOnce repoRoot =
  -- Run the mirror pulls + registry pushes inside an ephemeral DOCKER_CONFIG
  -- (host docker.io auth read-only for public pulls), scrubbed on exit — no
  -- docker login, nothing persisted. The in-cluster registry:2 NodePort is
  -- anonymous over HTTP, so pushes carry no credential.
  withEphemeralDockerConfig $ do
    imagesResult <- collectClusterImages repoRoot
    case imagesResult of
      Left err -> failWith err
      Right images ->
        let requiredPairs = ContainerImage.requiredPublicImageCandidatePairs
            discoveredPairs =
              [ (sources, target)
              | image <- images
              , Just source <- [ContainerImage.normalizeImageRefText image]
              , not (isHarborHostedImage source)
              , Just target <- [ContainerImage.harborMirrorTargetForSource source]
              , Just sources <- [ContainerImage.harborMirrorSourceCandidates source]
              ]
            imagePairs = mergeMirrorCandidatePairs (discoveredPairs ++ requiredPairs)
         in runSequentially
              [ ensureMirroredClusterImage repoRoot sources target
              | (sources, target) <- imagePairs
              ]

collectClusterImages :: FilePath -> IO (Either String [String])
collectClusterImages repoRoot = do
  outputResult <-
    captureKubectl
      repoRoot
      [ "get"
      , "pods"
      , "-A"
      , "-o"
      , "jsonpath={range .items[*]}{range .spec.initContainers[*]}{.image}{\"\\n\"}{end}{range .spec.containers[*]}{.image}{\"\\n\"}{end}{end}"
      ]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitFailure _ -> Left ("Failed to list cluster container images: " ++ outputDetail output)
      ExitSuccess -> Right (nub (filter (/= "") (lines (processStdout output))))

ensureMirroredClusterImage :: FilePath -> [String] -> String -> IO ExitCode
ensureMirroredClusterImage repoRoot sourceCandidates target = do
  targetAvailableResult <- harborTargetAvailableForHostArchitecture repoRoot target
  case targetAvailableResult of
    Left err -> failWith err
    Right True -> pure ExitSuccess
    Right False -> do
      mirrorResult <- mirrorHostArchitectureTargetFromCandidates repoRoot sourceCandidates target
      case mirrorResult of
        Left err -> failWith err
        Right () -> pure ExitSuccess

ensureRuntimeImage :: FilePath -> String -> IO ExitCode
ensureRuntimeImage = ensureRuntimeImageForSubstrate SubstrateHomeLocal

-- | Substrate-aware publication of the single union runtime image
-- (@docker/prodbox.Dockerfile@). One image serves every in-cluster role
-- (gateway daemon + api / websocket workloads); the role is selected by each
-- chart's container @args:@, not by separate images.
ensureRuntimeImageForSubstrate :: Substrate -> FilePath -> String -> IO ExitCode
ensureRuntimeImageForSubstrate substrate repoRoot prodboxId = do
  let runtimeTag = prodboxIdToLabelValue prodboxId
      runtimeImage = ContainerImage.harborRuntimeImageRepository ++ ":" ++ runtimeTag
      latestImage = ContainerImage.harborRuntimeImageRepository ++ ":latest"
  withManagedRuntimeImageRetention repoRoot $
    ensureCustomImageVariantsForSubstrate
      substrate
      repoRoot
      CustomImageBuildPlan
        { customImageDockerfile = "docker/prodbox.Dockerfile"
        }
      [runtimeImage, latestImage]
      runtimeImage

-- | Bound Docker's retained host-side generations for the one managed union
-- runtime repository. The pre-pass creates headroom before a changed build;
-- the post-pass removes the predecessor that becomes dangling when the moving
-- tags advance. Both passes use exact IDs from a machine-formatted observation,
-- never a broad Docker prune.
withManagedRuntimeImageRetention :: FilePath -> IO ExitCode -> IO ExitCode
withManagedRuntimeImageRetention repoRoot action = do
  preRetentionExit <- reconcileManagedRuntimeImageRetention repoRoot
  case preRetentionExit of
    ExitFailure _ -> pure preRetentionExit
    ExitSuccess -> do
      actionExit <-
        action `onException` do
          _ <- reconcileManagedRuntimeImageRetention repoRoot
          pure ()
      postRetentionExit <- reconcileManagedRuntimeImageRetention repoRoot
      pure (firstNonSuccess [actionExit, postRetentionExit])

-- | Sprint 7.5.c.v.b — substrate-aware custom-image publication.
--
--   * 'SubstrateHomeLocal': @docker login@ to @127.0.0.1:30080@,
--     @docker build@ + @docker push@, then @docker pull@ +
--     @sudo ctr image import@ to land the image in RKE2 containerd.
--   * 'SubstrateAws': @docker build@ on the operator host (Docker
--     is available), then publish via an in-cluster crane pod that
--     receives the docker-saved tarball via @kubectl cp@ and runs
--     @crane push --insecure@ against
--     @harbor.harbor.svc.cluster.local@. The operator-host
--     @docker push@ + @ctr@ paths do not apply on EKS (no network
--     path from the operator host into EKS Harbor; no @ctr@ socket
--     access into EKS node containerd sockets). EKS chart pods pick
--     up the pushed image via the Sprint @7.5.c.ii@ containerd
--     registry-mirror DaemonSet on each node.
ensureCustomImageVariantsForSubstrate
  :: Substrate -> FilePath -> CustomImageBuildPlan -> [String] -> String -> IO ExitCode
ensureCustomImageVariantsForSubstrate substrate repoRoot imageBuildPlan taggedRefs importRef =
  case substrate of
    SubstrateHomeLocal -> ensureCustomImageVariantsHomeLocal repoRoot imageBuildPlan taggedRefs importRef
    SubstrateAws -> ensureCustomImageVariantsAws repoRoot imageBuildPlan taggedRefs

ensureCustomImageVariantsHomeLocal
  :: FilePath -> CustomImageBuildPlan -> [String] -> String -> IO ExitCode
ensureCustomImageVariantsHomeLocal repoRoot imageBuildPlan taggedRefs importRef =
  -- Build + push + registry pull + ctr import inside an ephemeral DOCKER_CONFIG
  -- (no docker login; the anonymous registry:2 NodePort needs no push
  -- credential, the base-image build pull uses the host docker.io login),
  -- scrubbed on exit.
  withEphemeralDockerConfig $ do
    buildExit <- buildAndPushCustomImageVariants repoRoot imageBuildPlan taggedRefs
    case buildExit of
      ExitFailure _ -> pure buildExit
      ExitSuccess -> do
        pullExit <- runCommand =<< dockerSubprocessFor repoRoot ["pull", importRef]
        case pullExit of
          ExitFailure _ -> pure pullExit
          ExitSuccess -> importImageIntoRke2Containerd repoRoot importRef

-- | AWS-substrate custom-image publication path. Builds the image on
-- the operator host via @docker build@ (which is available locally),
-- @docker save@'s the image to a tarball, then publishes via an
-- in-cluster crane pod (anonymous — the registry renders no @auth@
-- stanza). The @ctr@ import step is intentionally
-- omitted — EKS nodes pull from in-cluster Harbor via the
-- containerd registry-mirror DaemonSet.
ensureCustomImageVariantsAws
  :: FilePath -> CustomImageBuildPlan -> [String] -> IO ExitCode
ensureCustomImageVariantsAws repoRoot imageBuildPlan taggedRefs =
  case taggedRefs of
    [] -> pure ExitSuccess
    (primaryRef : _) ->
      -- The host `docker build` base-image pull authenticates to Docker Hub via
      -- an ephemeral DOCKER_CONFIG; the registry push runs in-cluster (crane
      -- pod, anonymous) and the `docker save` is local.
      withEphemeralDockerConfig $ do
        buildExit <- buildCustomImageHostArchitecture repoRoot imageBuildPlan taggedRefs
        case buildExit of
          ExitFailure _ -> pure buildExit
          ExitSuccess -> pushCustomImageVariantsViaInClusterCrane repoRoot primaryRef taggedRefs

buildCustomImageHostArchitecture
  :: FilePath -> CustomImageBuildPlan -> [String] -> IO ExitCode
buildCustomImageHostArchitecture repoRoot imageBuildPlan taggedRefs =
  case supportedHostArchitecture of
    Left err -> failWith err
    Right hostArchitecture -> buildCustomImageOnce repoRoot hostArchitecture imageBuildPlan taggedRefs

-- | Render + apply the in-cluster crane pod from
-- 'Prodbox.Lib.EksCustomImagePush.eksCustomImagePushPodManifest',
-- @docker save@ the locally-built image to a tarball under the
-- chart-platform tmp dir, @kubectl cp@ the tarball into the pod, then
-- @kubectl exec@ @crane push --insecure@ once per requested tag and
-- delete the pod. There is no login step: the in-cluster registry
-- renders no @auth@ stanza and accepts anonymous push.
pushCustomImageVariantsViaInClusterCrane
  :: FilePath -> String -> [String] -> IO ExitCode
pushCustomImageVariantsViaInClusterCrane repoRoot primaryRef taggedRefs = do
  let cfg = defaultEksCustomImagePushConfig
      podNs = customPushPodNamespace cfg
      podNm = customPushPodName cfg
      podPath = "/data/image.tar"
  -- Sprint 4.18: stage the docker-save tarball in the system temp
  -- directory rather than under @.prodbox-state\/tmp\/@ so the repo
  -- root is no longer polluted with scratch state.
  tarDir <- getTemporaryDirectory
  let tarPath = tarDir </> "prodbox-custom-image.tar"
  writeOutputLine
    ( "Publishing custom image via in-cluster crane pod ("
        ++ podNs
        ++ "/"
        ++ podNm
        ++ "): "
        ++ primaryRef
    )
  saveExit <- runCommand =<< dockerSubprocessFor repoRoot ["save", "-o", tarPath, primaryRef]
  case saveExit of
    ExitFailure _ -> pure saveExit
    ExitSuccess -> do
      -- Apply the push-pod manifest fresh every call so previous
      -- runs don't leave a Completed pod blocking apply.
      _ <-
        runCommand
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments = ["delete", "pod", "-n", podNs, podNm, "--ignore-not-found"]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
      withTemporaryJsonManifest "eks-custom-image-push-pod" [eksCustomImagePushPodManifest cfg] $ \manifestPath -> do
        applyExit <-
          runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments = ["apply", "-f", manifestPath]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        case applyExit of
          ExitFailure _ -> pure applyExit
          ExitSuccess -> do
            readyExit <-
              runCommand
                Subprocess
                  { subprocessPath = "kubectl"
                  , subprocessArguments =
                      [ "wait"
                      , "--for=condition=Ready"
                      , "pod/" ++ podNm
                      , "-n"
                      , podNs
                      , "--timeout=120s"
                      ]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            case readyExit of
              ExitFailure _ -> pure readyExit
              ExitSuccess -> do
                cpExit <-
                  runCommand
                    Subprocess
                      { subprocessPath = "kubectl"
                      , subprocessArguments =
                          [ "cp"
                          , tarPath
                          , podNs ++ "/" ++ podNm ++ ":" ++ podPath
                          ]
                      , subprocessEnvironment = Nothing
                      , subprocessWorkingDirectory = Just repoRoot
                      }
                case cpExit of
                  ExitFailure _ -> pure cpExit
                  -- No registry login: the in-cluster @registry:2@ renders no
                  -- @auth@ stanza and accepts anonymous push, exactly as the
                  -- home substrate does (vault_doctrine.md §20.3).
                  ExitSuccess -> do
                    pushExits <-
                      mapM
                        (pushOneRefViaCranePod cfg podNs podNm podPath repoRoot)
                        taggedRefs
                    _ <- deleteCranePushPod podNs podNm repoRoot
                    pure $ firstNonSuccess pushExits

deleteCranePushPod :: String -> String -> FilePath -> IO ExitCode
deleteCranePushPod podNs podNm repoRoot =
  runCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          ["delete", "pod", "-n", podNs, podNm, "--ignore-not-found"]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

pushOneRefViaCranePod
  :: EksCustomImagePushConfig
  -> String
  -> String
  -> String
  -> FilePath
  -> String
  -> IO ExitCode
pushOneRefViaCranePod cfg podNs podNm podPath repoRoot chartRef = do
  let inClusterRef = rewriteChartRefForInClusterPush cfg chartRef
  writeOutputLine
    ( "  crane push "
        ++ podPath
        ++ " "
        ++ inClusterRef
        ++ " --insecure"
    )
  runCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "exec"
          , "-n"
          , podNs
          , podNm
          , "--"
          , "/ko-app/crane"
          , "push"
          , podPath
          , inClusterRef
          , "--insecure"
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

firstNonSuccess :: [ExitCode] -> ExitCode
firstNonSuccess = go
 where
  go [] = ExitSuccess
  go (ExitSuccess : rest) = go rest
  go (failure : _) = failure

buildAndPushCustomImageVariants :: FilePath -> CustomImageBuildPlan -> [String] -> IO ExitCode
buildAndPushCustomImageVariants repoRoot imageBuildPlan taggedRefs =
  case supportedHostArchitecture of
    Left err -> failWith err
    Right hostArchitecture -> do
      buildExit <- buildCustomImageOnce repoRoot hostArchitecture imageBuildPlan taggedRefs
      case buildExit of
        ExitFailure _ -> pure buildExit
        ExitSuccess ->
          runSequentially
            [ pushDockerImageWithRetry
                repoRoot
                (renderHostArchitecture hostArchitecture)
                tagRef
                ("custom image " ++ tagRef)
            | tagRef <- taggedRefs
            ]

buildCustomImageOnce
  :: FilePath -> HostArchitecture -> CustomImageBuildPlan -> [String] -> IO ExitCode
buildCustomImageOnce repoRoot hostArchitecture imageBuildPlan taggedRefs = do
  -- Sprint 1.49: the prodbox/gateway image no longer COPYs a baked
  -- `docker/default-prodbox.dhall`. The image RUNs the binary
  -- (`prodbox config generate`) to write its binary-sibling Tier-0 config at
  -- build time, so there is nothing to regenerate into the build context before
  -- `docker build` (config_doctrine.md §0, §3).
  let arguments =
        [ "build"
        , "-f"
        , customImageDockerfile imageBuildPlan
        ]
          ++ concat [["-t", tagRef] | tagRef <- taggedRefs]
          ++ ["."]
  outputResult <- captureDockerToolOutput repoRoot arguments
  case outputResult of
    Left err -> failWith err
    Right output ->
      case processExitCode output of
        ExitSuccess -> do
          emitCapturedProcessOutput output
          pure ExitSuccess
        ExitFailure _ ->
          failWith
            ( "Failed to build "
                ++ customImageDockerfile imageBuildPlan
                ++ " for "
                ++ renderHostArchitecture hostArchitecture
                ++ ": "
                ++ outputDetail output
            )

-- | Sprint 3.36: publish exactly the host architecture, which is what this
-- lifecycle supports and what the caller above is named for.
--
-- The @--platform@ flag is not a refinement of the previous behaviour, it is the
-- behaviour the surrounding code already claimed. @docker push \<tag\>@ under the
-- containerd image store pushes the whole manifest __index__ the pull produced;
-- for a multi-architecture upstream that index names platforms whose blobs were
-- never fetched, and the push fails naming none of them. Pushing a
-- platform-specific manifest as a single-platform image is the operation Exit
-- Definition items 27 and 28 describe: an amd64 host publishes amd64, cross-arch
-- emulation and mixed-arch closure are out of scope.
pushDockerImageWithRetry :: FilePath -> String -> String -> String -> IO ExitCode
pushDockerImageWithRetry repoRoot platform imageRef description =
  go (retryPolicyMaxAttempts customImagePushRetryPolicy)
 where
  go attemptsRemaining = do
    outputResult <- captureDockerToolOutput repoRoot ["push", "--platform", platform, imageRef]
    case outputResult of
      Left err -> failWith err
      Right output ->
        case processExitCode output of
          ExitSuccess -> do
            emitCapturedProcessOutput output
            pure ExitSuccess
          ExitFailure _
            | attemptsRemaining > 1 && isRetryableHarborPublicationFailure (outputDetail output) -> do
                writeDiagnosticLine
                  ( "Retrying Harbor publication for "
                      ++ description
                      ++ " ("
                      ++ show (retryPolicyMaxAttempts customImagePushRetryPolicy - attemptsRemaining + 1)
                      ++ "/"
                      ++ show (retryPolicyMaxAttempts customImagePushRetryPolicy)
                      ++ "): "
                      ++ outputDetail output
                  )
                threadDelay
                  =<< drawRetryDelayMicros
                    customImagePushRetryPolicy
                    (retryPolicyMaxAttempts customImagePushRetryPolicy - attemptsRemaining)
                go (attemptsRemaining - 1)
            | otherwise -> do
                emitCapturedProcessOutput output
                pure (ExitFailure 1)

-- | Sprint 4.43: a retry classifier that misclassifies a dependency's
-- characteristic transient failure is a shallow gate wearing a retry's clothes
-- (bootstrap_readiness_doctrine.md §4). The registry→MinIO push edge fails
-- transiently with __name-resolution__ errors (@no such host@ / @dial tcp@ /
-- @lookup@ / @name resolution@) while endpoint programming settles; these are
-- now classified retryable so residual jitter is bounded by
-- 'pushDockerImageWithRetry' rather than failing the bootstrap outright. The
-- deep gate ('ensureRegistryStorageBackendEdgeReady') is what removes the race;
-- this classifier only bounds the residual.
isRetryableHarborPublicationFailure :: String -> Bool
isRetryableHarborPublicationFailure =
  isRetryableTransientFailure
    [ "unexpected status from put request"
    ]

harborTargetAvailableForHostArchitecture :: FilePath -> String -> IO (Either String Bool)
harborTargetAvailableForHostArchitecture repoRoot imageRef = do
  pullResult <- captureDockerToolOutput repoRoot ["pull", imageRef]
  pure $
    case pullResult of
      Left err -> Left err
      Right output ->
        case processExitCode output of
          ExitSuccess -> Right True
          ExitFailure _ -> Right False

-- | No-op reset of a mirror target before re-tagging a fresh candidate onto it.
-- @registry:2@ overwrites a tag on push (a push re-uploads only the missing
-- blobs and re-points the tag), so — unlike Harbor's REST project-repository
-- delete — no explicit purge is required before mirroring the next candidate
-- source. Retained as a seam so the candidate-retry flow reads unchanged.
purgeHarborMirrorTarget :: FilePath -> String -> IO ExitCode
purgeHarborMirrorTarget _ _ = pure ExitSuccess

mirrorHostArchitectureTargetFromCandidates
  :: FilePath -> [String] -> String -> IO (Either String ())
mirrorHostArchitectureTargetFromCandidates repoRoot sourceCandidates target = go [] sourceCandidates
 where
  go diagnostics [] =
    let detail =
          if null diagnostics
            then "Tried: " ++ intercalate ", " sourceCandidates
            else intercalate " | " (reverse diagnostics)
     in pure
          ( Left
              ( "Unable to mirror a canonical upstream source for "
                  ++ target
                  ++ ". "
                  ++ detail
              )
          )
  go diagnostics (source : remainingSources) = do
    publicationResult <- mirrorHostArchitectureTarget repoRoot source target
    case publicationResult of
      Right () -> pure (Right ())
      Left err ->
        go
          ( ( "Failed to publish Harbor mirror target "
                ++ target
                ++ " from "
                ++ source
                ++ ": "
                ++ err
            )
              : diagnostics
          )
          remainingSources

mirrorHostArchitectureTarget :: FilePath -> String -> String -> IO (Either String ())
mirrorHostArchitectureTarget repoRoot source target =
  case supportedHostArchitecture of
    Left err -> pure (Left err)
    Right hostArchitecture ->
      mirrorHostArchitectureTargetFor
        repoRoot
        (renderHostArchitecture hostArchitecture)
        source
        target

mirrorHostArchitectureTargetFor
  :: FilePath -> String -> String -> String -> IO (Either String ())
mirrorHostArchitectureTargetFor repoRoot platform source target = do
  pullResult <- captureDockerToolOutput repoRoot ["pull", "--platform", platform, source]
  case pullResult of
    Left err -> pure (Left err)
    Right pullOutput ->
      case processExitCode pullOutput of
        ExitFailure _ -> pure (Left (outputDetail pullOutput))
        ExitSuccess -> do
          purgeExit <- purgeHarborMirrorTarget repoRoot target
          case purgeExit of
            ExitFailure _ ->
              pure
                ( Left
                    ( "Failed to reset Harbor mirror target '"
                        ++ target
                        ++ "' before mirroring from "
                        ++ source
                    )
                )
            ExitSuccess -> do
              tagResult <- captureDockerToolOutput repoRoot ["tag", source, target]
              case tagResult of
                Left err -> pure (Left err)
                Right tagOutput ->
                  case processExitCode tagOutput of
                    ExitFailure _ -> pure (Left (outputDetail tagOutput))
                    ExitSuccess ->
                      do
                        pushExit <-
                          pushDockerImageWithRetry
                            repoRoot
                            platform
                            target
                            ("mirror target " ++ target)
                        case pushExit of
                          ExitSuccess -> pure (Right ())
                          ExitFailure _ -> pure (Left ("push failed for " ++ target))

mergeMirrorCandidatePairs :: [([String], String)] -> [([String], String)]
mergeMirrorCandidatePairs = foldl mergePair []
 where
  mergePair [] (sources, target) = [(nub sources, target)]
  mergePair ((existingSources, existingTarget) : rest) (sources, target)
    | target == existingTarget = (nub (existingSources ++ sources), target) : rest
    | otherwise = (existingSources, existingTarget) : mergePair rest (sources, target)

isHarborHostedImage :: String -> Bool
isHarborHostedImage imageRef =
  (harborRegistryEndpoint ++ "/") `isPrefixOf` imageRef

data Rke2ImageImportDecision
  = Rke2ImageAlreadyCurrent
  | Rke2ImageImportRequired
  deriving (Eq, Show)

-- | Closed failures while selecting the exact managed dangling Docker image
-- IDs. The parser never returns a partially trusted deletion plan.
data RuntimeImageRetentionObservationError
  = RuntimeImageRetentionMalformedRow
  | RuntimeImageRetentionInvalidManagedImageId
  | RuntimeImageRetentionDuplicateManagedImageId
  deriving (Eq, Show)

-- | Machine-shaped inventory constrained to dangling images. Tagged images
-- are absent from the observation rather than filtered after parsing.
managedRuntimeImageRetentionInventoryArguments :: [String]
managedRuntimeImageRetentionInventoryArguments =
  [ "image"
  , "ls"
  , "--filter"
  , "dangling=true"
  , "--no-trunc"
  , "--format"
  , "{{.Repository}}\t{{.ID}}"
  ]

-- | Select only canonical IDs still associated with the exact managed runtime
-- repository. Foreign repositories are observed but never become deletion
-- targets. Any malformed machine row or managed ID refuses the whole plan.
selectManagedDanglingRuntimeImageIds
  :: String -> Either RuntimeImageRetentionObservationError [String]
selectManagedDanglingRuntimeImageIds output =
  foldM selectRow [] (lines output)
 where
  selectRow selected row =
    case break (== '\t') row of
      (repository, '\t' : imageId)
        | '\t' `notElem` imageId ->
            if repository /= ContainerImage.harborRuntimeImageRepository
              then Right selected
              else
                if not (isCanonicalSha256Digest imageId)
                  then Left RuntimeImageRetentionInvalidManagedImageId
                  else
                    if imageId `elem` selected
                      then Left RuntimeImageRetentionDuplicateManagedImageId
                      else Right (selected ++ [imageId])
      _ -> Left RuntimeImageRetentionMalformedRow

reconcileManagedRuntimeImageRetention :: FilePath -> IO ExitCode
reconcileManagedRuntimeImageRetention repoRoot = do
  observationResult <-
    captureDockerToolOutput repoRoot managedRuntimeImageRetentionInventoryArguments
  case selectRuntimeImageRetentionObservation observationResult of
    Left err -> failWith (renderRuntimeImageRetentionObservationError err)
    Right [] -> pure ExitSuccess
    Right imageIds -> do
      removalExit <-
        runSequentially
          [ runCommand =<< dockerSubprocessFor repoRoot ["image", "rm", imageId]
          | imageId <- imageIds
          ]
      case removalExit of
        ExitFailure _ -> pure removalExit
        ExitSuccess -> do
          readBackResult <-
            captureDockerToolOutput repoRoot managedRuntimeImageRetentionInventoryArguments
          case selectRuntimeImageRetentionObservation readBackResult of
            Left err -> failWith (renderRuntimeImageRetentionObservationError err)
            Right [] -> pure ExitSuccess
            Right _ -> failWith "Managed runtime-image retention read-back is not empty."

selectRuntimeImageRetentionObservation
  :: Either String ProcessOutput
  -> Either RuntimeImageRetentionObservationError [String]
selectRuntimeImageRetentionObservation outputResult =
  case outputResult of
    Left _ -> Left RuntimeImageRetentionMalformedRow
    Right output ->
      case processExitCode output of
        ExitFailure _ -> Left RuntimeImageRetentionMalformedRow
        ExitSuccess -> selectManagedDanglingRuntimeImageIds (processStdout output)

renderRuntimeImageRetentionObservationError
  :: RuntimeImageRetentionObservationError -> String
renderRuntimeImageRetentionObservationError err = case err of
  RuntimeImageRetentionMalformedRow ->
    "Managed runtime-image retention observation is unavailable or malformed."
  RuntimeImageRetentionInvalidManagedImageId ->
    "Managed runtime-image retention observed a noncanonical managed image ID."
  RuntimeImageRetentionDuplicateManagedImageId ->
    "Managed runtime-image retention observed a duplicate managed image ID."

-- | Skip the multi-gigabyte archive only when both independent stores report
-- the same canonical config digest for the exact tag. Containerd preserves
-- Docker archives with the Docker config media type and may expose native OCI
-- images with the OCI config media type; no other descriptor qualifies. Every
-- unavailable, malformed, absent, or ambiguous observation requires the
-- existing import.
decideRke2ImageImport :: String -> Maybe String -> Maybe String -> Rke2ImageImportDecision
decideRke2ImageImport imageRef maybeDockerIdentity maybeContainerdInspection =
  case ( maybeDockerIdentity >>= parseCanonicalDigestOutput
       , maybeContainerdInspection >>= parseContainerdConfigDigest imageRef
       ) of
    (Just dockerDigest, Just containerdDigest)
      | dockerDigest == containerdDigest -> Rke2ImageAlreadyCurrent
    _ -> Rke2ImageImportRequired

parseCanonicalDigestOutput :: String -> Maybe String
parseCanonicalDigestOutput output =
  case output of
    digest
      | isCanonicalSha256Digest digest -> Just digest
    _ ->
      case reverse output of
        '\n' : reversedDigest ->
          let digest = reverse reversedDigest
           in if isCanonicalSha256Digest digest then Just digest else Nothing
        _ -> Nothing

parseContainerdConfigDigest :: String -> String -> Maybe String
parseContainerdConfigDigest imageRef output = do
  case filter (not . null) (lines output) of
    observedRef : _ | observedRef == imageRef -> pure ()
    _ -> Nothing
  case [ drop 1 digestToken
       | line <- lines output
       , let tokens = words line
       , (mediaType, digestToken) <- zip tokens (drop 1 tokens)
       , mediaType `elem` containerdConfigMediaTypes
       , "@sha256:" `isPrefixOf` digestToken
       , isCanonicalSha256Digest (drop 1 digestToken)
       ] of
    [digest] -> Just digest
    _ -> Nothing

containerdConfigMediaTypes :: [String]
containerdConfigMediaTypes =
  [ "application/vnd.docker.container.image.v1+json"
  , "application/vnd.oci.image.config.v1+json"
  ]

isCanonicalSha256Digest :: String -> Bool
isCanonicalSha256Digest digest =
  case stripPrefix "sha256:" digest of
    Just hex -> length hex == 64 && all (\c -> isDigit c || c `elem` ['a' .. 'f']) hex
    Nothing -> False

importImageIntoRke2Containerd :: FilePath -> String -> IO ExitCode
importImageIntoRke2Containerd repoRoot imageRef = do
  socketResult <- resolveContainerdSocket
  case socketResult of
    Left err -> failWith err
    Right socketPath -> do
      dockerIdentityResult <-
        captureDockerToolOutput repoRoot ["image", "inspect", "--format", "{{.Id}}", imageRef]
      containerdInspectionResult <-
        captureToolOutput
          repoRoot
          "sudo"
          ["ctr", "--address", socketPath, "-n", "k8s.io", "images", "inspect", imageRef]
      let successfulStdout outputResult = do
            output <- either (const Nothing) Just outputResult
            case processExitCode output of
              ExitSuccess -> Just (processStdout output)
              ExitFailure _ -> Nothing
          decision =
            decideRke2ImageImport
              imageRef
              (successfulStdout dockerIdentityResult)
              (successfulStdout containerdInspectionResult)
      case decision of
        Rke2ImageAlreadyCurrent -> do
          writeOutputLine ("RKE2 containerd runtime image already current: " ++ imageRef)
          pure ExitSuccess
        Rke2ImageImportRequired ->
          withTemporaryTextFile "prodbox-image" "" $ \archivePath ->
            runSequentially
              [ runCommand =<< dockerSubprocessFor repoRoot ["save", "-o", archivePath, imageRef]
              , runCommand
                  Subprocess
                    { subprocessPath = "sudo"
                    , subprocessArguments =
                        ["ctr", "--address", socketPath, "-n", "k8s.io", "images", "import", archivePath]
                    , subprocessEnvironment = Nothing
                    , subprocessWorkingDirectory = Just repoRoot
                    }
              ]

-- | Persisted content of 'inotifyDropInPath'. Kept deterministic (stable
-- comment block + trailing newline) so 'ensureHostInotifyLimits' can compare
-- it byte-for-byte against the on-disk file and no-op when already correct.
renderInotifySysctlDropIn :: String
renderInotifySysctlDropIn =
  unlines
    [ "# Managed by `prodbox cluster reconcile`. Raises inotify limits so the systemd"
    , "# manager (PID 1), containerd, and kubelet do not exhaust the per-user instance"
    , "# cap during RKE2 lifecycle operations. See"
    , "# documents/engineering/lifecycle_reconciliation_doctrine.md and"
    , "# documents/engineering/streaming_doctrine.md §6."
    , "fs.inotify.max_user_instances = 8192"
    , "fs.inotify.max_user_watches = 1048576"
    ]

renderRke2ResourceGuardrailConfig :: Capacity.ResourcePlan -> String
renderRke2ResourceGuardrailConfig plan =
  unlines
    [ "# Managed by `prodbox cluster reconcile`. Derived from capacity.resource_plan."
    , "kubelet-arg:"
    , kubeletArgLine ("system-reserved=" ++ renderKubeletReservation systemReserved)
    , kubeletArgLine ("kube-reserved=" ++ renderKubeletReservation kubeReserved)
    , kubeletArgLine ("eviction-hard=" ++ renderEvictionHard (Capacity.eviction_floor plan))
    , kubeletArgLine ("eviction-soft=" ++ renderEvictionSoft (Capacity.eviction_floor plan))
    , kubeletArgLine
        "eviction-soft-grace-period=memory.available=1m,nodefs.available=1m,imagefs.available=1m"
    , kubeletArgLine "image-gc-high-threshold=70"
    , kubeletArgLine "image-gc-low-threshold=60"
    , kubeletArgLine "container-log-max-size=50Mi"
    , kubeletArgLine "container-log-max-files=3"
    ]
 where
  (systemReserved, kubeReserved) = splitReservedVector (Capacity.rke2_reserved plan)

kubeletArgLine :: String -> String
kubeletArgLine value = "  - " ++ show value

renderRke2SystemdResourceDropIn :: Capacity.ResourcePlan -> String
renderRke2SystemdResourceDropIn plan =
  unlines
    [ "# Managed by `prodbox cluster reconcile`. Bounds the RKE2 service process tree."
    , "[Service]"
    , "CPUAccounting=true"
    , "MemoryAccounting=true"
    , "TasksAccounting=true"
    , "CPUQuota=" ++ show (cpuQuotaPercent systemdCpuBudget) ++ "%"
    , "MemoryHigh=" ++ show (Capacity.memory_mib systemdBase) ++ "M"
    , "MemoryMax=" ++ show (Capacity.memory_mib systemdMax) ++ "M"
    , "TasksMax=4096"
    ]
 where
  systemdBase =
    Capacity.rke2_reserved plan
      `Capacity.plusResourceVector` Capacity.resourceVectorScale
        2
        (Capacity.limit Capacity.oneShotSecretWorkerEnvelope)
  systemdMax = systemdBase `Capacity.plusResourceVector` Capacity.eviction_floor plan
  -- The systemd boundary contains the complete RKE2 process tree. Preserve its
  -- established full-core/2GiB containment while kubelet's host-only
  -- reservation excludes the explicit one-shot workload peak.
  systemdCpuBudget = Capacity.milli_cpu systemdBase

renderKubeletReservation :: Capacity.ResourceVector -> String
renderKubeletReservation vector =
  intercalate
    ","
    [ "cpu=" ++ cpuQuantity (Capacity.milli_cpu vector)
    , "memory=" ++ memoryQuantity (Capacity.memory_mib vector)
    , "ephemeral-storage=" ++ memoryQuantity (Capacity.ephemeral_storage_mib vector)
    ]

renderEvictionHard :: Capacity.ResourceVector -> String
renderEvictionHard floorVector =
  intercalate
    ","
    [ "memory.available<" ++ memoryQuantity (Capacity.memory_mib floorVector)
    , "nodefs.available<" ++ memoryQuantity (Capacity.ephemeral_storage_mib floorVector)
    , "imagefs.available<" ++ memoryQuantity (Capacity.ephemeral_storage_mib floorVector)
    ]

renderEvictionSoft :: Capacity.ResourceVector -> String
renderEvictionSoft floorVector =
  intercalate
    ","
    [ "memory.available<" ++ memoryQuantity (2 * Capacity.memory_mib floorVector)
    , "nodefs.available<" ++ memoryQuantity (2 * Capacity.ephemeral_storage_mib floorVector)
    , "imagefs.available<" ++ memoryQuantity (2 * Capacity.ephemeral_storage_mib floorVector)
    ]

splitReservedVector :: Capacity.ResourceVector -> (Capacity.ResourceVector, Capacity.ResourceVector)
splitReservedVector vector =
  (halfVector, vector `Capacity.resourceVectorMinus` halfVector)
 where
  half value = value `div` 2
  halfVector =
    Capacity.ResourceVector
      { Capacity.milli_cpu = half (Capacity.milli_cpu vector)
      , Capacity.memory_mib = half (Capacity.memory_mib vector)
      , Capacity.ephemeral_storage_mib = half (Capacity.ephemeral_storage_mib vector)
      , Capacity.durable_storage_mib = half (Capacity.durable_storage_mib vector)
      }

cpuQuotaPercent :: Natural -> Natural
cpuQuotaPercent milliCpu = (milliCpu + 9) `div` 10

cpuQuantity :: Natural -> String
cpuQuantity = CapacityRender.cpuQuantity

memoryQuantity :: Natural -> String
memoryQuantity = CapacityRender.memoryQuantity

renderResourceVectorRuntime :: Capacity.ResourceVector -> String
renderResourceVectorRuntime = CapacityRender.renderResourceVectorRuntime

ensureRke2ResourceGuardrails :: FilePath -> ValidatedSettings -> IO ExitCode
ensureRke2ResourceGuardrails repoRoot settings = do
  observedResult <- observeHostCapacity repoRoot (resolvedManualPvHostRoot settings)
  case observedResult of
    Left err -> failWith ("failed to observe host capacity before RKE2 reconcile: " ++ err)
    Right observed -> do
      let plan = validatedResourcePlan settings
          observedVector = ObservedHost.observedHostVector observed
      case CapacityAllocation.compileResourcePlanAgainstObserved
        observed
        (validatedAllocatedPlan settings) of
        Left compileError ->
          failWith
            ( CapacityAllocation.renderCompileError compileError
                ++ ": observed="
                ++ renderResourceVectorRuntime observedVector
            )
        Right compiled -> do
          let admittedPlan = CapacityAllocation.someAllocatedPlanSource compiled
          writeOutputLine
            ( "RKE2 resource guardrails: host capacity ok (observed="
                ++ renderResourceVectorRuntime observedVector
                ++ ", required="
                ++ renderResourceVectorRuntime (Capacity.host_capacity plan)
                ++ ")"
            )
          runSequentially
            [ ensureRootFileContent
                repoRoot
                rke2ResourceGuardrailConfigPath
                (renderRke2ResourceGuardrailConfig admittedPlan)
                "RKE2 kubelet resource guardrails"
            , ensureRootFileContent
                repoRoot
                rke2SystemdResourceDropInPath
                (renderRke2SystemdResourceDropIn admittedPlan)
                "RKE2 systemd resource guardrails"
            , runCommand
                Subprocess
                  { subprocessPath = "sudo"
                  , subprocessArguments = ["systemctl", "daemon-reload"]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            ]

ensureRootFileContent :: FilePath -> FilePath -> String -> String -> IO ExitCode
ensureRootFileContent repoRoot path expectedContent label = do
  contentResult <- readRootFile repoRoot path
  case contentResult of
    Left err -> failWith err
    Right existingContent ->
      if existingContent == expectedContent
        then do
          writeOutputLine (label ++ ": already current")
          pure ExitSuccess
        else do
          writeExit <- writeRootFile repoRoot path expectedContent
          case writeExit of
            ExitFailure _ -> pure writeExit
            ExitSuccess -> do
              writeOutputLine (label ++ ": written")
              pure ExitSuccess

-- | First reconcile/delete host-prep step: idempotently raise the host inotify
-- limits via a persisted @/etc/sysctl.d@ drop-in. The kernel default of
-- @fs.inotify.max_user_instances = 128@ is too low for RKE2 + containerd +
-- kubelet (all uid 0) running alongside journald and developer tooling; when
-- the per-user instance cap is exhausted the systemd manager (PID 1) logs
-- @Failed to allocate directory watch: Too many open files@ directly to the
-- console during teardown. Raising the limit durably eliminates the warning at
-- its root rather than filtering it after the fact (see
-- @documents/engineering/streaming_doctrine.md § 6@). Modeled on
-- 'ensureRke2RegistriesConfig': write only on drift, then apply live.
ensureHostInotifyLimits :: FilePath -> IO ExitCode
ensureHostInotifyLimits repoRoot = do
  contentResult <- readRootFile repoRoot inotifyDropInPath
  case contentResult of
    Left err -> failWith err
    Right existingContent ->
      if existingContent == renderInotifySysctlDropIn
        then do
          writeOutputLine "Host inotify limits: already raised"
          pure ExitSuccess
        else do
          writeExit <- writeRootFile repoRoot inotifyDropInPath renderInotifySysctlDropIn
          case writeExit of
            ExitFailure _ -> pure writeExit
            ExitSuccess -> do
              applyResult <- captureToolOutput repoRoot "sudo" ["sysctl", "--system"]
              case applyResult of
                Left err ->
                  failWith ("failed to apply inotify sysctl drop-in: " ++ err)
                Right output ->
                  case processExitCode output of
                    ExitFailure _ ->
                      failWith
                        ("failed to apply inotify sysctl drop-in: " ++ outputDetail output)
                    ExitSuccess -> do
                      writeOutputLine
                        "Host inotify limits: raised (max_user_instances=8192, max_user_watches=1048576)"
                      pure ExitSuccess

ensureRke2RegistriesConfig :: FilePath -> IO ExitCode
ensureRke2RegistriesConfig repoRoot = do
  contentResult <- readRootFile repoRoot rke2RegistriesPath
  case contentResult of
    Left err -> failWith err
    Right existingContent ->
      let updatedContent = renderRke2RegistriesYaml
       in if updatedContent == existingContent
            then pure ExitSuccess
            else do
              writeExit <- writeRootFile repoRoot rke2RegistriesPath updatedContent
              case writeExit of
                ExitFailure _ -> pure writeExit
                ExitSuccess ->
                  runSequentially
                    [ runCommand
                        Subprocess
                          { subprocessPath = "sudo"
                          , subprocessArguments = ["systemctl", "restart", rke2ServiceName]
                          , subprocessEnvironment = Nothing
                          , subprocessWorkingDirectory = Just repoRoot
                          }
                    , verifyClusterInfo repoRoot
                    ]

deleteRke2ClusterSubstrate :: FilePath -> IO ExitCode
deleteRke2ClusterSubstrate repoRoot = do
  uninstallExistsResult <- captureToolOutput repoRoot "test" ["-x", rke2UninstallPath]
  case uninstallExistsResult of
    Left err -> failWith err
    Right output ->
      case processExitCode output of
        ExitSuccess -> do
          uninstallResult <- captureToolOutput repoRoot "sudo" [rke2UninstallPath]
          case uninstallResult of
            Left err -> failWith err
            Right uninstallOutput ->
              case processExitCode uninstallOutput of
                ExitSuccess -> reportDeleteStep "Local RKE2 substrate" "cleanup complete"
                ExitFailure _ ->
                  failWith
                    ( "failed to clean the local RKE2 substrate: "
                        ++ summarizeRke2DeleteFailure uninstallOutput
                    )
        ExitFailure _ -> do
          _ <-
            captureToolOutput
              repoRoot
              "sudo"
              ["systemctl", "disable", "--now", rke2ServiceName]
          cleanupExit <-
            runCommand
              Subprocess
                { subprocessPath = "sudo"
                , subprocessArguments =
                    [ "rm"
                    , "-rf"
                    , "/var/lib/rancher/rke2"
                    , "/var/lib/rancher"
                    , "/etc/rancher/rke2"
                    , "/usr/local/bin/rke2"
                    , "/usr/local/bin/rke2-killall.sh"
                    , "/usr/local/bin/rke2-uninstall.sh"
                    ]
                , subprocessEnvironment = Nothing
                , subprocessWorkingDirectory = Just repoRoot
                }
          case cleanupExit of
            ExitFailure _ -> pure cleanupExit
            ExitSuccess -> reportDeleteStep "Local RKE2 substrate" "cleanup complete"

removeCalicoEndpointStatusResidue :: IO ExitCode
removeCalicoEndpointStatusResidue = do
  maybeOverride <- lookupEnv "PRODBOX_RKE2_ENDPOINT_STATUS_ROOT"
  let endpointStatusRoot = maybe "/run/calico/endpoint-status" id maybeOverride
  existsResult <- try (doesDirectoryExist endpointStatusRoot) :: IO (Either IOException Bool)
  case existsResult of
    Left err -> failWith ("failed to inspect " ++ endpointStatusRoot ++ ": " ++ displayException err)
    Right False -> pure ExitSuccess
    Right True -> do
      pathsResult <- try (listDirectory endpointStatusRoot) :: IO (Either IOException [FilePath])
      case pathsResult of
        Left err -> failWith ("failed to list " ++ endpointStatusRoot ++ ": " ++ displayException err)
        Right fileNames ->
          let matchingPaths =
                [ endpointStatusRoot </> fileName
                | fileName <- fileNames
                , "rke2" `isInfixOf` fileName
                ]
           in if null matchingPaths
                then pure ExitSuccess
                else
                  runCommand
                    Subprocess
                      { subprocessPath = "sudo"
                      , subprocessArguments = ["rm", "-f"] ++ matchingPaths
                      , subprocessEnvironment = Nothing
                      , subprocessWorkingDirectory = Nothing
                      }

removeManagedKubeconfig :: IO ExitCode
removeManagedKubeconfig = do
  homeDirectory <- getHomeDirectory
  let kubeconfigPath = homeDirectory </> ".kube" </> "config"
  exists <- doesFileExist kubeconfigPath
  if not exists
    then reportDeleteStep "Managed kubeconfig" "already absent"
    else do
      readResult <- try (readFile kubeconfigPath) :: IO (Either IOException String)
      case readResult of
        Left err -> failWith ("failed to read " ++ kubeconfigPath ++ ": " ++ displayException err)
        Right kubeconfigText ->
          if "https://127.0.0.1:6443" `isInfixOf` kubeconfigText
            then do
              removeResult <- try (removeFile kubeconfigPath) :: IO (Either IOException ())
              case removeResult of
                Left err -> failWith ("failed to remove " ++ kubeconfigPath ++ ": " ++ displayException err)
                Right () -> reportDeleteStep "Managed kubeconfig" "removed"
            else
              reportDeleteStep
                "Managed kubeconfig"
                "left in place because it does not target the local RKE2 API"

-- | Sprint 4.76: the retained-state notice takes the delete mode it is
-- narrating for. Both delete paths share the uninstall step list, and the
-- notice used to close with advice to run @--cascade@ — which a
-- @--cascade@ run had, by then, already done. Its per-run sentence is now
-- a total function of the mode.
-- | Sprint 4.88: the retained-state notice, rendered from the terminal arm the
-- run reached rather than from the delete mode.
--
-- Only 'RetainedStatePreserved' says the store is preserved; every other arm
-- either says nothing (it reached no delete path) or names what this run did
-- not observe, so no exit path silently reads as permission to delete it.
renderRetainedStateNotice :: DeleteTerminalArm -> FilePath -> IO ExitCode
renderRetainedStateNotice arm retainedManualPvRoot = do
  case retainedStateNarrationFor arm of
    RetainedStateSilent -> pure ()
    RetainedStatePreserved -> do
      renderRetainedRootInventory retainedManualPvRoot
      writeOutputLine (retainedStateNoticePerRunLine arm)
    RetainedStateUnproven -> do
      renderRetainedRootInventory retainedManualPvRoot
      writeOutputLine (retainedStateNoticePerRunLine arm)
  -- Sprint 3.13 chunk 16: the @.prodbox-state/charts/@ chart-state root is
  -- gone; chart secrets and gateway event keys now live in k8s @Secret@s
  -- materialized by the gateway daemon. Nothing under @.prodbox-state/@
  -- is preserved by the supported lifecycle any more.
  pure ExitSuccess

renderRetainedRootInventory :: FilePath -> IO ()
renderRetainedRootInventory retainedManualPvRoot = do
  writeOutputLine "Local cluster uninstalled. Retained host state:"
  writeOutputLine ("  - manual PV root: " ++ retainedManualPvRoot)
  writeOutputLine ("  - `.data/` (MinIO-backed per-run Pulumi state) is retained")
  writeOutputLine ("  - Vault durable PV: " ++ retainedManualPvRoot </> "vault" </> "vault" </> "0")

-- | Pure: the per-run AWS sentence for each terminal arm that renders one.
--
-- The local-only sentence is unchanged. The cascade's used to describe what its
-- phases attempted, which reads as an account of what happened; it now states
-- the licence it does not carry, because a run holding no completion receipt
-- has not proven the obligations that would authorise retiring the store.
retainedStateNoticePerRunLine :: DeleteTerminalArm -> String
retainedStateNoticePerRunLine arm = case arm of
  DeleteArmLocalOnlyNoInstall -> retainedStateLocalOnlyLine
  DeleteArmLocalOnlyUninstalled -> retainedStateLocalOnlyLine
  DeleteArmCascadeNoInstall -> retainedStateCascadeUnprovenLine
  DeleteArmCascadeReachedPhases -> retainedStateCascadeUnprovenLine

retainedStateLocalOnlyLine :: String
retainedStateLocalOnlyLine =
  "Per-run AWS stacks (if any) were NOT destroyed by this local uninstall. To destroy them, run `prodbox cluster delete --cascade` or `prodbox aws stack <name> destroy --yes`. The retained root above is preserved by this uninstall."

retainedStateCascadeUnprovenLine :: String
retainedStateCascadeUnprovenLine =
  "Per-run AWS stack destroys were attempted earlier in this cascade; see the per-run destroy and postflight sweep phases above for what each one reported. This cascade carries NO completion receipt, so it does not establish that the retained root above may be retired: no exit status from this route authorizes deleting it. Any stack whose state could not be observed is still destroyable via `prodbox aws stack <name> destroy --yes` once the backend is readable."

reportDeleteStep :: String -> String -> IO ExitCode
reportDeleteStep label status = do
  writeOutputLine (label ++ ": " ++ status)
  pure ExitSuccess

summarizeRke2DeleteFailure :: ProcessOutput -> String
summarizeRke2DeleteFailure output =
  case reverse . take 3 . reverse $
    filter
      (not . isIgnorableRke2DeleteNoiseLine)
      (nonEmptyLines (processStderr output ++ "\n" ++ processStdout output)) of
    [] -> outputDetail output
    actionableLines -> intercalate " | " actionableLines

isIgnorableRke2DeleteNoiseLine :: String -> Bool
isIgnorableRke2DeleteNoiseLine line =
  let trimmed = trimWhitespace line
      lowered = map toLower trimmed
   in trimmed == ""
        || "+" `isPrefixOf` trimmed
        || "[20" `isPrefixOf` trimmed
        || "cannot find device" `isInfixOf` lowered
        || "failed to reset failed state of unit" `isInfixOf` lowered
        || "semodule: not found" `isInfixOf` lowered
        -- NOTE: the inotify warning below is usually emitted out-of-band by the systemd
        -- manager (PID 1) / journald to the console, NOT through the uninstaller's captured
        -- stdout/stderr. This entry only catches it on the rare path where systemd routes it
        -- to the captured stderr; it cannot suppress the out-of-band console emission (which
        -- stays benign and may still appear on a successful run). See streaming_doctrine.md §6.
        || "failed to allocate directory watch" `isInfixOf` lowered
        || "too many open files" `isInfixOf` lowered
        || "if this cluster was upgraded from an older release of the canal cni" `isPrefixOf` lowered
        || "-e      " `isPrefixOf` trimmed

normalizeLogLines :: Maybe Int -> Either String Int
normalizeLogLines maybeLines =
  case maybeLines of
    Nothing -> Right 50
    Just value ->
      if value > 0
        then Right value
        else Left "--lines must be greater than 0."

runSequentially :: [IO ExitCode] -> IO ExitCode
runSequentially = foldM step ExitSuccess
 where
  step :: ExitCode -> IO ExitCode -> IO ExitCode
  step failure@(ExitFailure _) _ = pure failure
  step ExitSuccess action = action

resolveSingleNodeHostname :: FilePath -> IO (Either String String)
resolveSingleNodeHostname repoRoot = do
  outputResult <-
    captureKubectl
      repoRoot
      ["get", "nodes", "-o", "jsonpath={.items[*].metadata.name}"]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitFailure _ -> Left ("Failed to list cluster nodes for retained storage policy: " ++ outputDetail output)
      ExitSuccess ->
        case words (processStdout output) of
          [nodeName] -> Right nodeName
          names ->
            Left
              ( "Retained storage policy requires a single-node cluster; detected "
                  ++ show (length names)
                  ++ " nodes"
              )

-- | Create a retained PV host directory and chown it to the owning workload's
-- runtime @uid:gid@ (Sprint 4.31: MinIO @1000:1000@, Vault @100:100@) so the
-- non-root container can write to its hostPath-backed volume.
ensureHostStoragePath :: FilePath -> FilePath -> String -> IO ExitCode
ensureHostStoragePath repoRoot hostPath owner =
  runSequentially
    [ runCommand
        Subprocess
          { subprocessPath = "sudo"
          , subprocessArguments = ["mkdir", "-p", hostPath]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    , runCommand
        Subprocess
          { subprocessPath = "sudo"
          , subprocessArguments = ["chown", "-R", owner, hostPath]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    , runCommand
        Subprocess
          { subprocessPath = "sudo"
          , subprocessArguments = ["chmod", "0770", hostPath]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    ]

-- | Sprint 4.31: the retained StorageClass plus the deterministic PV + prebound
-- PVC for every always-on retained StatefulSet (MinIO, Vault), all on the
-- unified @.data/<namespace>/<StatefulSet>/<ordinal>@ scheme.
storageManifestItems :: [RetainedLocalStorageBinding] -> String -> String -> String -> [Value]
storageManifestItems bindings nodeName prodboxId labelValue =
  storageClassItem
    : map
      (\binding -> retainedPersistentVolume binding nodeName prodboxId labelValue)
      bindings
 where
  storageClassItem =
    object
      [ "apiVersion" .= ("storage.k8s.io/v1" :: String)
      , "kind" .= ("StorageClass" :: String)
      , "metadata"
          .= object
            [ "name" .= manualStorageClass
            , "annotations"
                .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels"
                .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "provisioner" .= ("kubernetes.io/no-provisioner" :: String)
      , "volumeBindingMode" .= ("WaitForFirstConsumer" :: String)
      , "reclaimPolicy" .= ("Retain" :: String)
      , "allowVolumeExpansion" .= True
      ]

-- | The deterministic @Retain@ PV (single-node affinity) for one retained
-- StatefulSet ordinal, @claimRef@-bound to the StatefulSet's
-- @data-<sts>-<ordinal>@ PVC. The reconciler creates only the PV — it is
-- cluster-scoped, so it needs no workload namespace to exist yet (the @vault@
-- namespace, for one, is created later by 'ensureVaultRuntime'). Each
-- StatefulSet's @data@ volumeClaimTemplate creates the matching PVC, which the
-- @claimRef@ plus @WaitForFirstConsumer@ binds to this PV on first pod schedule.
retainedPersistentVolume :: RetainedLocalStorageBinding -> String -> String -> String -> Value
retainedPersistentVolume binding nodeName prodboxId labelValue =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("PersistentVolume" :: String)
    , "metadata"
        .= object
          [ "name" .= retainedLocalStorageBindingPersistentVolume binding
          , "annotations"
              .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
          , "labels"
              .= object [Key.fromString prodboxLabelKey .= labelValue]
          ]
    , "spec"
        .= object
          [ "capacity" .= object ["storage" .= retainedLocalStorageBindingStorageSize binding]
          , "volumeMode" .= ("Filesystem" :: String)
          , "accessModes" .= (["ReadWriteOnce" :: String] :: [String])
          , "persistentVolumeReclaimPolicy" .= ("Retain" :: String)
          , "storageClassName" .= manualStorageClass
          , "claimRef"
              .= object
                [ "namespace" .= retainedLocalStorageBindingNamespace binding
                , "name" .= retainedLocalStorageBindingPersistentClaim binding
                ]
          , "hostPath"
              .= object
                [ "path" .= retainedLocalStorageBindingHostPath binding
                , "type" .= ("DirectoryOrCreate" :: String)
                ]
          , "nodeAffinity"
              .= object
                [ "required"
                    .= object
                      [ "nodeSelectorTerms"
                          .= [ object
                                 [ "matchExpressions"
                                     .= [ object
                                            [ "key" .= ("kubernetes.io/hostname" :: String)
                                            , "operator" .= ("In" :: String)
                                            , "values" .= ([nodeName] :: [String])
                                            ]
                                        ]
                                 ]
                             ]
                      ]
                ]
          ]
    ]

ensureProdboxIdentityConfigMap :: FilePath -> String -> String -> String -> IO ExitCode
ensureProdboxIdentityConfigMap repoRoot machineId prodboxId labelValue =
  withTemporaryJsonBytes "prodbox-identity" (encode manifest) $ \manifestPath -> do
    outputResult <- captureKubectl repoRoot ["apply", "-f", manifestPath]
    case outputResult of
      Left err -> failWith err
      Right output ->
        case processExitCode output of
          ExitSuccess -> pure ExitSuccess
          ExitFailure _ -> failWith ("kubectl apply failed: " ++ outputDetail output)
 where
  manifest =
    object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("List" :: String)
      , "items"
          .= ( [ object
                   [ "apiVersion" .= ("v1" :: String)
                   , "kind" .= ("Namespace" :: String)
                   , "metadata"
                       .= object
                         [ "name" .= prodboxNamespace
                         , "annotations"
                             .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
                         , "labels"
                             .= object [Key.fromString prodboxLabelKey .= labelValue]
                         ]
                   ]
               , object
                   [ "apiVersion" .= ("v1" :: String)
                   , "kind" .= ("ConfigMap" :: String)
                   , "metadata"
                       .= object
                         [ "name" .= prodboxIdentityConfigMap
                         , "namespace" .= prodboxNamespace
                         , "annotations"
                             .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
                         , "labels"
                             .= object [Key.fromString prodboxLabelKey .= labelValue]
                         ]
                   , "data"
                       .= object
                         [ "machine_id" .= machineId
                         , "prodbox_id" .= prodboxId
                         ]
                   ]
               ]
                 :: [Value]
             )
      ]

reconcileManagedAnnotations :: FilePath -> String -> String -> IO ExitCode
reconcileManagedAnnotations repoRoot prodboxId labelValue = do
  namespacedResourcesResult <- listApiResources repoRoot True
  clusterResourcesResult <- listApiResources repoRoot False
  case (namespacedResourcesResult, clusterResourcesResult) of
    (Left err, _) -> failWith err
    (_, Left err) -> failWith err
    (Right namespacedResources, Right clusterResources) -> do
      let namespaceActions =
            concat
              [ [ annotateObject repoRoot Nothing ("namespace/" ++ namespace) prodboxId labelValue
                , annotateNamespacedResources repoRoot namespace namespacedResources prodboxId labelValue
                ]
              | namespace <- managedNamespaces
              ]
          instanceActions =
            [ annotateClusterResources repoRoot instanceName clusterResources prodboxId labelValue
            | instanceName <- managedHelmInstances
            ]
      result <-
        runEitherActions
          ( namespaceActions
              ++ instanceActions
              ++ [annotateDoctrineCrds repoRoot prodboxId labelValue]
          )
      either failWith (const (pure ExitSuccess)) result

listApiResources :: FilePath -> Bool -> IO (Either String [String])
listApiResources repoRoot namespaced = do
  outputResult <-
    captureKubectl
      repoRoot
      [ "api-resources"
      , "--verbs=list"
      , "--namespaced=" ++ map toLower (show namespaced)
      , "-o"
      , "name"
      ]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitFailure _ ->
        Left ("Failed to list Kubernetes API resources: " ++ outputDetail output)
      ExitSuccess ->
        Right
          ( filter
              (`notElem` ephemeralResourceKinds)
              (nonEmptyLines (processStdout output))
          )

annotateNamespacedResources
  :: FilePath -> String -> [String] -> String -> String -> IO (Either String ())
annotateNamespacedResources repoRoot namespace resources prodboxId labelValue =
  runEitherActions
    [ annotateNamespacedResource repoRoot namespace resource prodboxId labelValue
    | resource <- resources
    ]

annotateNamespacedResource
  :: FilePath -> String -> String -> String -> String -> IO (Either String ())
annotateNamespacedResource repoRoot namespace resource prodboxId labelValue = do
  outputResult <-
    captureKubectl
      repoRoot
      [ "get"
      , resource
      , "-n"
      , namespace
      , "-o"
      , "name"
      , "--ignore-not-found=true"
      ]
  case outputResult of
    Left err -> pure (Left err)
    Right output ->
      case processExitCode output of
        ExitFailure _ ->
          if isIgnorableListingError (outputDetail output)
            then pure (Right ())
            else pure (Left ("list " ++ resource ++ " in " ++ namespace ++ " failed: " ++ outputDetail output))
        ExitSuccess ->
          if null (parseObjectNames (processStdout output))
            then pure (Right ())
            else annotateResourceSet repoRoot (Just namespace) resource Nothing prodboxId labelValue

annotateClusterResources
  :: FilePath -> String -> [String] -> String -> String -> IO (Either String ())
annotateClusterResources repoRoot instanceName resources prodboxId labelValue =
  runEitherActions
    [ annotateClusterResource repoRoot instanceName resource prodboxId labelValue
    | resource <- resources
    ]

annotateClusterResource :: FilePath -> String -> String -> String -> String -> IO (Either String ())
annotateClusterResource repoRoot instanceName resource prodboxId labelValue = do
  let selector = "app.kubernetes.io/instance=" ++ instanceName
  outputResult <-
    captureKubectl
      repoRoot
      [ "get"
      , resource
      , "-l"
      , selector
      , "-o"
      , "name"
      , "--ignore-not-found=true"
      ]
  case outputResult of
    Left err -> pure (Left err)
    Right output ->
      case processExitCode output of
        ExitFailure _ ->
          if isIgnorableListingError (outputDetail output)
            then pure (Right ())
            else
              pure
                (Left ("list cluster " ++ resource ++ " for " ++ instanceName ++ " failed: " ++ outputDetail output))
        ExitSuccess ->
          if null (parseObjectNames (processStdout output))
            then pure (Right ())
            else annotateResourceSet repoRoot Nothing resource (Just selector) prodboxId labelValue

annotateDoctrineCrds :: FilePath -> String -> String -> IO (Either String ())
annotateDoctrineCrds repoRoot prodboxId labelValue = do
  outputResult <- captureKubectl repoRoot ["get", "crd", "-o", "name"]
  case outputResult of
    Left err -> pure (Left err)
    Right output ->
      case processExitCode output of
        ExitFailure _ ->
          if isIgnorableListingError (outputDetail output)
            then pure (Right ())
            else pure (Left ("list CRDs failed: " ++ outputDetail output))
        ExitSuccess ->
          runEitherActions
            [ annotateObject repoRoot Nothing ref prodboxId labelValue
            | ref <- parseObjectNames (processStdout output)
            , any (`isInfixOf` dropResourcePrefix ref) doctrineCrdSuffixes
            ]

annotateObject :: FilePath -> Maybe String -> String -> String -> String -> IO (Either String ())
annotateObject repoRoot maybeNamespace objectRef prodboxId labelValue = do
  annotateResult <-
    captureKubectl
      repoRoot
      ( appendNamespaceArgs
          maybeNamespace
          ["annotate", objectRef, prodboxAnnotationKey ++ "=" ++ prodboxId, "--overwrite"]
      )
  case annotateResult of
    Left err -> pure (Left err)
    Right annotateOutput ->
      if shouldIgnoreAnnotationFailure annotateOutput
        then pure (Right ())
        else case processExitCode annotateOutput of
          ExitFailure _ -> pure (Left ("annotate " ++ objectRef ++ " failed: " ++ outputDetail annotateOutput))
          ExitSuccess -> do
            labelResult <-
              captureKubectl
                repoRoot
                ( appendNamespaceArgs
                    maybeNamespace
                    ["label", objectRef, prodboxLabelKey ++ "=" ++ labelValue, "--overwrite"]
                )
            case labelResult of
              Left err -> pure (Left err)
              Right labelOutput ->
                if shouldIgnoreAnnotationFailure labelOutput
                  then pure (Right ())
                  else case processExitCode labelOutput of
                    ExitFailure _ -> pure (Left ("label " ++ objectRef ++ " failed: " ++ outputDetail labelOutput))
                    ExitSuccess -> pure (Right ())

annotateResourceSet
  :: FilePath -> Maybe String -> String -> Maybe String -> String -> String -> IO (Either String ())
annotateResourceSet repoRoot maybeNamespace resource maybeSelector prodboxId labelValue = do
  annotateResult <-
    captureKubectl
      repoRoot
      ( appendNamespaceArgs
          maybeNamespace
          ( ["annotate", resource]
              ++ resourceSelectionArgs maybeSelector
              ++ [prodboxAnnotationKey ++ "=" ++ prodboxId, "--overwrite"]
          )
      )
  case annotateResult of
    Left err -> pure (Left err)
    Right annotateOutput ->
      if shouldIgnoreAnnotationFailure annotateOutput
        then pure (Right ())
        else case processExitCode annotateOutput of
          ExitFailure _ -> pure (Left ("annotate " ++ resource ++ " failed: " ++ outputDetail annotateOutput))
          ExitSuccess -> do
            labelResult <-
              captureKubectl
                repoRoot
                ( appendNamespaceArgs
                    maybeNamespace
                    ( ["label", resource]
                        ++ resourceSelectionArgs maybeSelector
                        ++ [prodboxLabelKey ++ "=" ++ labelValue, "--overwrite"]
                    )
                )
            case labelResult of
              Left err -> pure (Left err)
              Right labelOutput ->
                if shouldIgnoreAnnotationFailure labelOutput
                  then pure (Right ())
                  else case processExitCode labelOutput of
                    ExitFailure _ -> pure (Left ("label " ++ resource ++ " failed: " ++ outputDetail labelOutput))
                    ExitSuccess -> pure (Right ())

appendNamespaceArgs :: Maybe String -> [String] -> [String]
appendNamespaceArgs Nothing args = args
appendNamespaceArgs (Just namespace) args = args ++ ["-n", namespace]

resourceSelectionArgs :: Maybe String -> [String]
resourceSelectionArgs Nothing = ["--all"]
resourceSelectionArgs (Just selector) = ["-l", selector]

runEitherActions :: [IO (Either String ())] -> IO (Either String ())
runEitherActions =
  foldM runEitherAction (Right ())

runEitherAction :: Either String () -> IO (Either String ()) -> IO (Either String ())
runEitherAction result action =
  case result of
    Left err -> pure (Left err)
    Right () -> action

captureKubectl :: FilePath -> [String] -> IO (Either String ProcessOutput)
captureKubectl repoRoot arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments = arguments
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case result of
      Failure err -> Left ("failed to start kubectl: " ++ err)
      Success output -> Right output

captureToolOutput :: FilePath -> FilePath -> [String] -> IO (Either String ProcessOutput)
captureToolOutput repoRoot toolName arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = toolName
        , subprocessArguments = arguments
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case result of
      Failure err -> Left ("failed to start " ++ toolName ++ ": " ++ err)
      Success output -> Right output

-- | Build a @docker@ 'Subprocess'. @DOCKER_CONFIG@ is NOT injected here — it is
-- provided process-wide by the enclosing 'withEphemeralDockerConfig' bracket
-- (Sprint 1.47), which points docker at a throwaway config (host @docker.io@
-- auth + inline Harbor entry) and scrubs it on exit. So every docker call inside
-- a wrapped flow authenticates without a persisted config or a @docker login@.
dockerSubprocessFor :: FilePath -> [String] -> IO Subprocess
dockerSubprocessFor repoRoot arguments =
  pure
    Subprocess
      { subprocessPath = "docker"
      , subprocessArguments = arguments
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

-- | 'captureToolOutput' for @docker@. Inherits the @DOCKER_CONFIG@ set by the
-- enclosing 'withEphemeralDockerConfig' bracket (Sprint 1.47).
captureDockerToolOutput :: FilePath -> [String] -> IO (Either String ProcessOutput)
captureDockerToolOutput repoRoot arguments = do
  spec <- dockerSubprocessFor repoRoot arguments
  result <- captureSubprocessResult spec
  pure $
    case result of
      Failure err -> Left ("failed to start docker: " ++ err)
      Success output -> Right output

runTextCommand :: Subprocess -> IO (Either String String)
runTextCommand spec = do
  result <- captureSubprocessResult spec
  pure $
    case result of
      Failure err -> Left ("failed to start " ++ subprocessPath spec ++ ": " ++ err)
      Success output ->
        case processExitCode output of
          ExitFailure _ -> Left (outputDetail output)
          ExitSuccess -> Right (processStdout output)

readRootFile :: FilePath -> FilePath -> IO (Either String String)
readRootFile repoRoot path = do
  outputResult <- captureToolOutput repoRoot "sudo" ["cat", path]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitSuccess -> Right (processStdout output)
      ExitFailure _ ->
        let detail = map toLower (outputDetail output)
         in if "no such file" `isInfixOf` detail || "not found" `isInfixOf` detail
              then Right ""
              else Left ("failed to read " ++ path ++ ": " ++ outputDetail output)

writeRootFile :: FilePath -> FilePath -> String -> IO ExitCode
writeRootFile repoRoot path contents =
  withTemporaryTextFile "prodbox-root" contents $ \tempPath ->
    runSequentially
      [ runCommand
          Subprocess
            { subprocessPath = "sudo"
            , subprocessArguments = ["mkdir", "-p", takeDirectory path]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
      , runCommand
          Subprocess
            { subprocessPath = "sudo"
            , subprocessArguments = ["cp", tempPath, path]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
      ]

withTemporaryTextFile :: String -> String -> (FilePath -> IO ExitCode) -> IO ExitCode
withTemporaryTextFile prefix contents action = do
  temporaryDirectory <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile temporaryDirectory prefix
        hClose handle
        writeFile path contents
        pure path
    )
    ( \tempPath -> do
        _ <- try (removeFile tempPath) :: IO (Either IOException ())
        pure ()
    )
    action

withTemporaryJsonManifest :: String -> [Value] -> (FilePath -> IO ExitCode) -> IO ExitCode
withTemporaryJsonManifest prefix items =
  withTemporaryJsonBytes
    prefix
    (encode (object ["apiVersion" .= ("v1" :: String), "kind" .= ("List" :: String), "items" .= items]))

withTemporaryJsonBytes :: String -> BL.ByteString -> (FilePath -> IO ExitCode) -> IO ExitCode
withTemporaryJsonBytes prefix contents action = do
  temporaryDirectory <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile temporaryDirectory prefix
        hClose handle
        BL.writeFile path contents
        pure path
    )
    ( \tempPath -> do
        _ <- try (removeFile tempPath) :: IO (Either IOException ())
        pure ()
    )
    action

currentOwnerSpec :: FilePath -> IO (Either String String)
currentOwnerSpec repoRoot = do
  uidResult <- captureToolOutput repoRoot "id" ["-u"]
  gidResult <- captureToolOutput repoRoot "id" ["-g"]
  pure $ do
    uidOutput <- uidResult
    gidOutput <- gidResult
    case (processExitCode uidOutput, processExitCode gidOutput) of
      (ExitSuccess, ExitSuccess) ->
        Right (trimWhitespace (processStdout uidOutput) ++ ":" ++ trimWhitespace (processStdout gidOutput))
      _ -> Left "failed to resolve current uid/gid for kubeconfig ownership"

resolveMachineIdentity :: IO (Either String (String, String))
resolveMachineIdentity = do
  machineIdResult <- try (readFile "/etc/machine-id") :: IO (Either IOException String)
  pure $
    case machineIdResult of
      Left err -> Left ("failed to read /etc/machine-id: " ++ displayException err)
      Right rawMachineId ->
        let machineId = map toLower (trimWhitespace rawMachineId)
         in if machineId == ""
              then Left "/etc/machine-id is empty"
              else
                if length machineId /= 32 || any (not . isHexDigit) machineId
                  then Left ("Unexpected machine-id format in /etc/machine-id: " ++ show machineId)
                  else Right (machineId, "prodbox-" ++ machineId)

supportedHostArchitecture :: Either String HostArchitecture
supportedHostArchitecture =
  case map toLower SystemInfo.arch of
    "x86_64" -> Right HostArchitectureAmd64
    "amd64" -> Right HostArchitectureAmd64
    "aarch64" -> Right HostArchitectureArm64
    "arm64" -> Right HostArchitectureArm64
    unsupported ->
      Left
        ( "Unsupported host architecture for the native lifecycle image path: "
            ++ unsupported
            ++ ". Supported architectures are amd64 and arm64."
        )

renderHostArchitecture :: HostArchitecture -> String
renderHostArchitecture hostArchitecture =
  case hostArchitecture of
    HostArchitectureAmd64 -> "linux/amd64"
    HostArchitectureArm64 -> "linux/arm64"

prodboxIdToLabelValue :: String -> String
prodboxIdToLabelValue = take 63

resolveContainerdSocket :: IO (Either String String)
resolveContainerdSocket = do
  maybeOverride <- lookupEnv "PRODBOX_RKE2_CONTAINERD_SOCKET"
  case maybeOverride of
    Just socketPath -> pure (Right socketPath)
    Nothing -> do
      k3sExists <- doesFileExist "/run/k3s/containerd/containerd.sock"
      rke2Exists <- doesFileExist "/run/rke2/containerd/containerd.sock"
      pure $
        if k3sExists
          then Right "/run/k3s/containerd/containerd.sock"
          else
            if rke2Exists
              then Right "/run/rke2/containerd/containerd.sock"
              else
                Left
                  "RKE2 containerd socket not found at expected paths: /run/k3s/containerd/containerd.sock, /run/rke2/containerd/containerd.sock"

renderIngressControllerConfig :: String -> String -> String
renderIngressControllerConfig existingContent controller =
  let canonicalLine = "ingress-controller: " ++ controller
      existingLines = lines (trimTrailingNewlines existingContent)
      updatedLines =
        if any startsWithIngress existingLines
          then [if startsWithIngress line then canonicalLine else line | line <- existingLines]
          else existingLines ++ [canonicalLine]
   in unlines updatedLines
 where
  startsWithIngress line =
    case stripPrefix "ingress-controller:" (dropWhile isSpace line) of
      Just _ -> True
      Nothing -> False

renderRke2RegistriesYaml :: String
renderRke2RegistriesYaml =
  unlines
    [ "mirrors:"
    , "  docker.io:"
    , "    endpoint:"
    , "      - \"http://" ++ harborRegistryEndpoint ++ "\""
    , "    rewrite:"
    , "      \"^(.*)$\": \"prodbox/$1\""
    , "configs:"
    , "  \"" ++ harborRegistryEndpoint ++ "\":"
    , "    tls:"
    , "      insecure_skip_verify: true"
    ]

renderImageRefWithoutTag :: ContainerImage.ImageRef -> String
renderImageRefWithoutTag imageRef =
  ContainerImage.imageRegistry imageRef ++ "/" ++ ContainerImage.imageRepository imageRef

stripPrefix :: String -> String -> Maybe String
stripPrefix prefix value =
  if take (length prefix) value == prefix
    then Just (drop (length prefix) value)
    else Nothing

parseObjectNames :: String -> [String]
parseObjectNames stdoutText =
  [ line
  | rawLine <- lines stdoutText
  , let line = trimWhitespace rawLine
  , line /= ""
  , '/' `elem` line
  ]

dropResourcePrefix :: String -> String
dropResourcePrefix value =
  case break (== '/') value of
    (_, "") -> value
    (_, '/' : suffix) -> suffix
    _ -> value

nonEmptyLines :: String -> [String]
nonEmptyLines = filter (/= "") . map trimWhitespace . lines

shouldIgnoreAnnotationFailure :: ProcessOutput -> Bool
shouldIgnoreAnnotationFailure output =
  case processExitCode output of
    ExitSuccess -> False
    ExitFailure _ ->
      let detail = outputDetail output
       in isNotFoundMessage detail || isIgnorableAnnotationError detail

isNotFoundMessage :: String -> Bool
isNotFoundMessage detail =
  let lowered = map toLower detail
   in "notfound" `isInfixOf` lowered || "not found" `isInfixOf` lowered

isIgnorableListingError :: String -> Bool
isIgnorableListingError detail =
  let lowered = map toLower detail
   in "the server doesn't have a resource type" `isInfixOf` lowered
        || "unable to list" `isInfixOf` lowered
        || "forbidden" `isInfixOf` lowered

isIgnorableAnnotationError :: String -> Bool
isIgnorableAnnotationError detail =
  let lowered = map toLower detail
   in "does not allow this method" `isInfixOf` lowered
        || "methodnotallowed" `isInfixOf` lowered

outputDetail :: ProcessOutput -> String
outputDetail output =
  case filter
    (/= "")
    [trimTrailingNewlines (processStderr output), trimTrailingNewlines (processStdout output)] of
    [] -> "subprocess exited without output"
    rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

emitCapturedProcessOutput :: ProcessOutput -> IO ()
emitCapturedProcessOutput output = do
  let stdoutText = processStdout output
      stderrText = processStderr output
  if stdoutText == ""
    then pure ()
    else writeOutput stdoutText
  if stderrText == ""
    then pure ()
    else writeDiagnostic stderrText

trimTrailingNewlines :: String -> String
trimTrailingNewlines = reverse . dropWhile (`elem` ['\n', '\r']) . reverse

trimWhitespace :: String -> String
trimWhitespace = reverse . dropWhile isSpace . reverse . dropWhile isSpace

rke2NodeDiscoveryAttempts :: Int
rke2NodeDiscoveryAttempts = 150

rke2NodeDiscoveryDelayMicroseconds :: Int
rke2NodeDiscoveryDelayMicroseconds = 2000000

harborEndpointReadinessAttempts :: Int
harborEndpointReadinessAttempts = 60

harborEndpointReadinessDelayMicroseconds :: Int
harborEndpointReadinessDelayMicroseconds = 2000000

harborEndpointStabilityAttempts :: Int
harborEndpointStabilityAttempts = 36

harborEndpointStabilitySuccesses :: Int
harborEndpointStabilitySuccesses = 6

harborEndpointStabilityDelayMicroseconds :: Int
harborEndpointStabilityDelayMicroseconds = 5000000

runCommand :: Subprocess -> IO ExitCode
runCommand spec = do
  result <- runSubprocessStreaming spec
  case result of
    Failure err -> failWith err
    Success exitCode -> pure exitCode

requireLinux :: IO ExitCode -> IO ExitCode
requireLinux action =
  if os == "linux"
    then action
    else failWith "RKE2 commands require Linux"

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

-- | Sprint 4.56: a readiness barrier that refuses yields no admission, so its
-- refusal is a 'Left' rather than a bare exit code. Same operator-facing
-- message; the difference is that the caller now cannot mistake a refusal for
-- an admission it never received.
refuseWith :: String -> IO (Either ExitCode admission)
refuseWith message = Left <$> failWith message
