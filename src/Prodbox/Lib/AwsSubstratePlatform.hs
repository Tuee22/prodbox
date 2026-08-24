{-# LANGUAGE OverloadedStrings #-}

-- | Substrate-aware platform install paths for the AWS substrate.
--
-- The home substrate's chart-platform install (MetalLB, Envoy Gateway,
-- cert-manager, ACME ClusterIssuer, Percona operator) lives in
-- `src/Prodbox/CLI/Rke2.hs::ensureClusterPlatformRuntime` and is
-- specialized to the operator's home cluster — including Harbor-mirrored
-- image references and MetalLB-based LoadBalancer IPs. The AWS substrate
-- (EKS) keeps a different install path but stands up the SAME shared
-- service set (Sprint 7.12 substrate equivalence): Harbor + MinIO + the
-- Percona operator are installed on BOTH substrates. The two installers
-- differ only in their LOWER layer — AWS Load Balancer Controller
-- (replacing MetalLB), the EKS-side Harbor reached through the node-local
-- registry proxy (the EKS containerd registry-mirror DaemonSet that makes
-- `127.0.0.1:30080/prodbox/...` resolve on EKS, mirroring the home
-- NodePort-on-`127.0.0.1` pattern), and cert-manager scoped to the
-- per-substrate Route 53 subzone (rendered by
-- `acmeClusterIssuerSpec SubstrateAws` in `Prodbox.CLI.Rke2`). The shared
-- platform-component pins (Envoy Gateway, cert-manager, Harbor, MinIO,
-- Percona, Vault) come from the single `Prodbox.ContainerImage` SSoT; there
-- is no per-substrate chart-version / image re-pin.
--
-- Sprint 7.5.b.ii.d.II lands the AWS Load Balancer Controller install
-- function `ensureAwsLoadBalancerControllerRuntime`. The corresponding
-- Envoy Gateway + cert-manager install paths land in follow-up
-- sub-sprints; see the deliverable inventory in
-- `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`.
module Prodbox.Lib.AwsSubstratePlatform
  ( AwsPlatformPayload (..)
  , AwsPlatformStepId (..)
  , runReconcileSlices
  , applyEksContainerdMirrorDaemonSet
  , applyEksImageMirrorJob
  , awsComponentReadinessTarget
  , classifyEksNodesReadiness
  , ensureAwsLoadBalancerControllerRuntime
  , awsLoadBalancerControllerChartRef
  , awsLoadBalancerControllerChartVersion
  , awsLoadBalancerControllerReleaseName
  , awsLoadBalancerControllerNamespace
  , awsLoadBalancerControllerServiceAccountName
  , ensureAwsSubstrateEnvoyGatewayRuntime
  , awsSubstrateEnvoyGatewayChartRef
  , awsSubstrateEnvoyGatewayChartVersion
  , awsSubstrateEnvoyGatewayReleaseName
  , awsSubstrateEnvoyGatewayNamespace
  , ensureAwsSubstrateCertManagerRuntime
  , awsSubstrateCertManagerChartRef
  , awsSubstrateCertManagerChartVersion
  , awsSubstrateCertManagerReleaseName
  , awsSubstrateCertManagerNamespace
  , ensureAwsSubstrateAcmeRuntime
  , ensureAwsSubstrateVaultRuntime
  , ensureAwsSubstratePlatformRuntime
  , buildAwsSubstratePlatformExecutionPlan
  , runAwsSubstratePlatformPlanWith
  , awsStepsForComponent
  , awsSubstratePlatformStepOrderRespectsGraph
  , awsSubstratePlatformRuntimeStepDescriptions
  , awsSubstratePlatformComponents
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (foldM, unless)
import Data.Aeson
  ( Value
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiUpper, isDigit, isSpace, toLower)
import Data.List (isSuffixOf, nub)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.CLI.Output
  ( writeError
  , writeOutputLine
  )
import Prodbox.CLI.Rke2
  ( KubernetesReadinessCheck (..)
  , MinioImageSource (..)
  , RetainedStorageInventoryEntry (..)
  , ensureAcmeRuntimeForSubstrate
  , ensureAdminPublicEdgeRoutes
  , ensureGatewayChartReadyPostVaultAt
  , ensureGatewayMinioBootstrap
  , ensureHarborRegistryRuntime
  , ensureHarborRegistryStorageBackend
  , ensureInternalControlPlaneChartReady
  , ensureMinioRuntime
  , ensurePostgresOperatorRuntime
  , ensureRegistryStorageBackendEdgeReady
  , ensureRuntimeImageForSubstrate
  , ensureVaultRuntime
  , gatewayNamespace
  , minioNamespace
  , minioReleaseName
  , observeGatewayBackendRoundTripOnceAt
  , observeKubernetesReadinessOnce
  , observeRegistryBackendRoundTripOnce
  , observeVaultUnsealedOnce
  , retainedStorageInventoryEntries
  , vaultNamespace
  )
import Prodbox.CLI.Vault (runVaultBootstrapViaBroker)
import Prodbox.Config.ComponentGraph
  ( ComponentDag
  , ComponentId (..)
  , componentCapabilityRequirement
  , componentDagEdges
  , componentIdText
  , defaultComponentGraph
  , lookupComponentNode
  , readiness
  )
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.ControlPlane.CapabilityRequirement (requirementCoordinate')
import Prodbox.ControlPlane.ControllerOwnerRepository
  ( ControllerOwnerTransition (..)
  )
import Prodbox.ControlPlane.ControllerOwnerTransportClient
  ( lifecycleAuthorityControllerOwnerAuthenticatedClient
  )
import Prodbox.ControlPlane.Coordinate (coordGeneration)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchAuthenticatedProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.Error (fatalError)
import Prodbox.Gateway.PortForward
  ( GatewayServicePortForward (..)
  , renderGatewayPortForwardError
  , withGatewayServicePortForward
  )
import Prodbox.Gateway.Types (PeerEndpoint)
import Prodbox.Infra.AwsEksTestStack
  ( AwsEksTestStackSnapshot (..)
  , parseAwsEksTestStackFromOutputs
  )
import Prodbox.Infra.StackOutputs (StackName (..))
import Prodbox.Lib.AwsControlPlaneIsolation qualified as AwsIsolation
import Prodbox.Lib.ChartPlatform
  ( gatewayRestServiceName
  , gatewayRestServicePort
  , operatorAvailableTarget
  )
import Prodbox.Lib.EksContainerdMirror
  ( ContainerdMirrorConfig (..)
  , defaultProdboxMirrorConfig
  , eksContainerdMirrorDaemonSetManifest
  )
import Prodbox.Lib.EksImageMirror
  ( defaultEksImageMirrorConfig
  , eksImageMirrorJobManifest
  , isRetryableEksImageMirrorFailure
  , mirrorJobName
  , mirrorJobNamespace
  )
import Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , chartEbsPersistentVolumeManifest
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
import Prodbox.Lifecycle.CapabilityReadinessBarrier
  ( newReadinessObservationClient
  , observeReadinessThroughCapability
  )
import Prodbox.Lifecycle.DependencyAdmission
  ( AdmissionSet
  , DependencyAdmission
  , mutationAdmittedComponent
  , renderAdmissionRefusal
  )
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.LiveResidue
  ( awsEksTestStackName
  , fetchPerRunStackOutputs
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveEksLoadBalancerControllerFamily)
  )
import Prodbox.Lifecycle.ReadinessObservation
  ( BackendRoundTripResult (..)
  , ComponentReadinessTarget (..)
  , ReadinessProbeResult (..)
  , componentReadinessRetryPolicy
  )
import Prodbox.Lifecycle.Teardown.AwsLoadBalancerControllerFamilyAdapter
  ( awsLoadBalancerControllerObservationArns
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( awsEksLoadBalancerControllerName
  , awsEksLoadBalancerControllerTags
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( ConfigFile (..)
  , DeploymentSection (..)
  , ValidatedSettings (..)
  , requireAwsSubstrateProfile
  , requireOperationalAwsRegion
  )
import Prodbox.Settings.AwsSubstrateProfile (awsSubstrateStaticEbsVolumeType)
import Prodbox.Settings.Coordinate (AwsRegion, awsRegionText)
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import Prodbox.Substrate (Substrate (..), replicasForSubstrate)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (hClose, openTempFile)

-- | Closed AWS-substrate platform inventory. Component topology comes from the
-- validated config graph; this ADT owns only the stable within-component order.
data AwsPlatformStepId
  = StepAwsLoadBalancerControllerRuntime
  | StepAwsClusterBaseReady
  | StepAwsRetainedStorage
  | StepAwsMinioRuntimeBootstrap
  | StepAwsMinioReady
  | StepAwsVaultRuntime
  | StepAwsVaultWorkloadReady
  | StepAwsContainerdMirror
  | StepAwsRegistryStorageBackend
  | StepAwsRegistryRuntime
  | StepAwsRegistryMinioEdge
  | StepAwsImageMirror
  | StepAwsRuntimeImage
  | StepAwsRegistryReady
  | StepAwsCertManagerRuntime
  | StepAwsCertManagerReady
  | StepAwsBootstrapBroker
  | StepAwsBootstrapBrokerReady
  | StepAwsVaultLifecycle
  | StepAwsVaultUnsealedReady
  | StepAwsEnvoyGatewayRuntime
  | StepAwsEnvoyGatewayReady
  | StepAwsPostgresOperatorRuntime
  | StepAwsPostgresOperatorReady
  | StepAwsTargetSecretAgent
  | StepAwsTargetSecretAgentReady
  | StepAwsLifecycleAuthority
  | StepAwsLifecycleAuthorityReady
  | StepAwsGatewayMinioBootstrap
  | StepAwsGatewayPostVault
  | StepAwsGatewayFullReady
  | StepAwsAuthorityBackup
  | StepAwsAuthorityBackupReady
  | StepAwsProviderWorker
  | StepAwsProviderWorkerReady
  | StepAwsTlsRetention
  | StepAwsTlsRetentionReady
  | StepAwsAcmeRuntime
  | StepAwsAdminPublicEdgeRoutes
  deriving (Eq, Show, Enum, Bounded)

data AwsPlatformPayload = AwsPlatformPayload
  { awsPlatformDag :: ComponentDag
  , awsPlatformStepOrder :: [AwsPlatformStepId]
  }
  deriving (Eq, Show)

awsStepToken :: AwsPlatformStepId -> String
awsStepToken step = case step of
  StepAwsLoadBalancerControllerRuntime -> "ensureAwsLoadBalancerControllerRuntime"
  StepAwsClusterBaseReady -> "observeAwsClusterBaseReady"
  StepAwsRetainedStorage -> "ensureAwsSubstrateRetainedStorage"
  StepAwsMinioRuntimeBootstrap -> "ensureMinioRuntime SubstrateAws MinioBootstrapPublic"
  StepAwsMinioReady -> "observeAwsMinioReady"
  StepAwsVaultRuntime -> "ensureAwsSubstrateVaultRuntime"
  StepAwsVaultWorkloadReady -> "observeAwsVaultWorkloadReady"
  StepAwsContainerdMirror -> "applyEksContainerdMirrorDaemonSet"
  StepAwsRegistryStorageBackend -> "ensureHarborRegistryStorageBackend"
  StepAwsRegistryRuntime -> "ensureHarborRegistryRuntime SubstrateAws"
  StepAwsRegistryMinioEdge -> "ensureRegistryStorageBackendEdgeReady"
  StepAwsImageMirror -> "applyEksImageMirrorJob"
  StepAwsRuntimeImage -> "ensureRuntimeImageForSubstrate SubstrateAws"
  StepAwsRegistryReady -> "observeAwsRegistryReady"
  StepAwsCertManagerRuntime -> "ensureAwsSubstrateCertManagerRuntime"
  StepAwsCertManagerReady -> "observeAwsCertManagerReady"
  StepAwsBootstrapBroker -> "ensureInternalControlPlaneChartReady SubstrateAws bootstrap-broker"
  StepAwsBootstrapBrokerReady -> "observeAwsBootstrapBrokerReady"
  StepAwsVaultLifecycle -> "runVaultBootstrapViaBroker"
  StepAwsVaultUnsealedReady -> "observeAwsVaultUnsealedReady"
  StepAwsEnvoyGatewayRuntime -> "ensureAwsSubstrateEnvoyGatewayRuntime"
  StepAwsEnvoyGatewayReady -> "observeAwsEnvoyGatewayReady"
  StepAwsPostgresOperatorRuntime -> "ensurePostgresOperatorRuntime"
  StepAwsPostgresOperatorReady -> "observeAwsPostgresOperatorReady"
  StepAwsTargetSecretAgent -> "ensureInternalControlPlaneChartReady SubstrateAws target-secret-agent"
  StepAwsTargetSecretAgentReady -> "observeAwsTargetSecretAgentReady"
  StepAwsLifecycleAuthority -> "ensureInternalControlPlaneChartReady SubstrateAws lifecycle-authority"
  StepAwsLifecycleAuthorityReady -> "observeAwsLifecycleAuthorityReady"
  StepAwsGatewayMinioBootstrap -> "ensureGatewayMinioBootstrap"
  StepAwsGatewayPostVault -> "ensureGatewayChartReadyPostVaultAt SubstrateAws"
  StepAwsGatewayFullReady -> "observeAwsGatewayFullReady"
  StepAwsAuthorityBackup -> "ensureInternalControlPlaneChartReady SubstrateAws authority-backup"
  StepAwsAuthorityBackupReady -> "observeAwsAuthorityBackupReady"
  StepAwsProviderWorker -> "ensureInternalControlPlaneChartReady SubstrateAws provider-worker"
  StepAwsProviderWorkerReady -> "observeAwsProviderWorkerReady"
  StepAwsTlsRetention -> "ensureInternalControlPlaneChartReady SubstrateAws tls-retention"
  StepAwsTlsRetentionReady -> "observeAwsTlsRetentionReady"
  StepAwsAcmeRuntime -> "ensureAwsSubstrateAcmeRuntime"
  StepAwsAdminPublicEdgeRoutes -> "ensureAdminPublicEdgeRoutes SubstrateAws"

awsStepPhase :: AwsPlatformStepId -> ReconcilePhase
awsStepPhase step = case step of
  StepAwsLoadBalancerControllerRuntime -> PhaseBootstrap
  StepAwsClusterBaseReady -> PhaseBootstrap
  StepAwsRetainedStorage -> PhaseBootstrap
  StepAwsMinioRuntimeBootstrap -> PhaseBootstrap
  StepAwsMinioReady -> PhaseBootstrap
  StepAwsVaultRuntime -> PhaseBootstrap
  StepAwsVaultWorkloadReady -> PhaseBootstrap
  StepAwsContainerdMirror -> PhaseBootstrap
  StepAwsRegistryStorageBackend -> PhaseBootstrap
  StepAwsRegistryRuntime -> PhaseBootstrap
  StepAwsRegistryMinioEdge -> PhaseBootstrap
  StepAwsImageMirror -> PhaseBootstrap
  StepAwsRuntimeImage -> PhaseBootstrap
  StepAwsRegistryReady -> PhaseBootstrap
  StepAwsCertManagerRuntime -> PhaseSteady
  StepAwsCertManagerReady -> PhaseSteady
  StepAwsBootstrapBroker -> PhaseBootstrap
  StepAwsBootstrapBrokerReady -> PhaseBootstrap
  StepAwsVaultLifecycle -> PhaseTransition
  StepAwsVaultUnsealedReady -> PhaseTransition
  StepAwsEnvoyGatewayRuntime -> PhaseSteady
  StepAwsEnvoyGatewayReady -> PhaseSteady
  StepAwsPostgresOperatorRuntime -> PhaseSteady
  StepAwsPostgresOperatorReady -> PhaseSteady
  StepAwsTargetSecretAgent -> PhaseSteady
  StepAwsTargetSecretAgentReady -> PhaseSteady
  StepAwsLifecycleAuthority -> PhaseSteady
  StepAwsLifecycleAuthorityReady -> PhaseSteady
  StepAwsGatewayMinioBootstrap -> PhaseSteady
  StepAwsGatewayPostVault -> PhaseSteady
  StepAwsGatewayFullReady -> PhaseSteady
  StepAwsAuthorityBackup -> PhaseSteady
  StepAwsAuthorityBackupReady -> PhaseSteady
  StepAwsProviderWorker -> PhaseSteady
  StepAwsProviderWorkerReady -> PhaseSteady
  StepAwsTlsRetention -> PhaseSteady
  StepAwsTlsRetentionReady -> PhaseSteady
  StepAwsAcmeRuntime -> PhaseEdge
  StepAwsAdminPublicEdgeRoutes -> PhaseEdge

awsStepAnchor :: AwsPlatformStepId -> ReconcileStepAnchor
awsStepAnchor step = case step of
  StepAwsLoadBalancerControllerRuntime -> ComponentMutation ComponentClusterBase
  StepAwsClusterBaseReady -> ComponentReadiness ComponentClusterBase
  StepAwsRetainedStorage -> ComponentMutation ComponentMinio
  StepAwsMinioRuntimeBootstrap -> ComponentMutation ComponentMinio
  StepAwsMinioReady -> ComponentReadiness ComponentMinio
  StepAwsVaultRuntime -> ComponentMutation ComponentVaultWorkload
  StepAwsVaultWorkloadReady -> ComponentReadiness ComponentVaultWorkload
  StepAwsContainerdMirror -> HostPrepBefore ComponentRegistry
  StepAwsRegistryStorageBackend -> ComponentMutation ComponentRegistry
  StepAwsRegistryRuntime -> ComponentMutation ComponentRegistry
  StepAwsRegistryMinioEdge -> ComponentMutation ComponentRegistry
  StepAwsImageMirror -> ComponentMutation ComponentRegistry
  StepAwsRuntimeImage -> ComponentMutation ComponentRegistry
  StepAwsRegistryReady -> ComponentReadiness ComponentRegistry
  StepAwsCertManagerRuntime -> ComponentMutation ComponentCertManager
  StepAwsCertManagerReady -> ComponentReadiness ComponentCertManager
  StepAwsBootstrapBroker -> ComponentMutation ComponentChartBootstrapBroker
  StepAwsBootstrapBrokerReady -> ComponentReadiness ComponentChartBootstrapBroker
  StepAwsVaultLifecycle -> TransitionFor ComponentVaultUnsealed
  StepAwsVaultUnsealedReady -> ComponentReadiness ComponentVaultUnsealed
  StepAwsEnvoyGatewayRuntime -> ComponentMutation ComponentEnvoyGateway
  StepAwsEnvoyGatewayReady -> ComponentReadiness ComponentEnvoyGateway
  StepAwsPostgresOperatorRuntime -> ComponentMutation ComponentPerconaPostgresOperator
  StepAwsPostgresOperatorReady -> ComponentReadiness ComponentPerconaPostgresOperator
  StepAwsTargetSecretAgent -> ComponentMutation ComponentChartTargetSecretAgent
  StepAwsTargetSecretAgentReady -> ComponentReadiness ComponentChartTargetSecretAgent
  StepAwsLifecycleAuthority -> ComponentMutation ComponentChartLifecycleAuthority
  StepAwsLifecycleAuthorityReady -> ComponentReadiness ComponentChartLifecycleAuthority
  StepAwsGatewayMinioBootstrap -> ComponentMutation ComponentGatewayDaemonFull
  StepAwsGatewayPostVault -> ComponentMutation ComponentGatewayDaemonFull
  StepAwsGatewayFullReady -> ComponentReadiness ComponentGatewayDaemonFull
  StepAwsAuthorityBackup -> ComponentMutation ComponentChartAuthorityBackup
  StepAwsAuthorityBackupReady -> ComponentReadiness ComponentChartAuthorityBackup
  StepAwsProviderWorker -> ComponentMutation ComponentChartProviderWorker
  StepAwsProviderWorkerReady -> ComponentReadiness ComponentChartProviderWorker
  StepAwsTlsRetention -> ComponentMutation ComponentChartTlsRetention
  StepAwsTlsRetentionReady -> ComponentReadiness ComponentChartTlsRetention
  StepAwsAcmeRuntime -> EdgeOnly
  StepAwsAdminPublicEdgeRoutes -> EdgeOnly

awsStepsForComponent :: ComponentId -> [AwsPlatformStepId]
awsStepsForComponent component = case component of
  ComponentClusterBase ->
    [StepAwsLoadBalancerControllerRuntime, StepAwsClusterBaseReady]
  ComponentMinio ->
    [ StepAwsRetainedStorage
    , StepAwsMinioRuntimeBootstrap
    , StepAwsMinioReady
    ]
  ComponentVaultWorkload ->
    [StepAwsVaultRuntime, StepAwsVaultWorkloadReady]
  ComponentVaultUnsealed ->
    [StepAwsVaultLifecycle, StepAwsVaultUnsealedReady]
  ComponentRegistry ->
    [ StepAwsContainerdMirror
    , StepAwsRegistryStorageBackend
    , StepAwsRegistryRuntime
    , StepAwsRegistryMinioEdge
    , StepAwsImageMirror
    , StepAwsRuntimeImage
    , StepAwsRegistryReady
    ]
  ComponentMetalLB -> []
  ComponentEnvoyGateway ->
    [StepAwsEnvoyGatewayRuntime, StepAwsEnvoyGatewayReady]
  ComponentCertManager ->
    [StepAwsCertManagerRuntime, StepAwsCertManagerReady]
  ComponentPerconaPostgresOperator ->
    [StepAwsPostgresOperatorRuntime, StepAwsPostgresOperatorReady]
  ComponentGatewayDaemonPreVault -> []
  ComponentGatewayDaemonFull ->
    [ StepAwsGatewayMinioBootstrap
    , StepAwsGatewayPostVault
    , StepAwsGatewayFullReady
    ]
  ComponentChartPulsar -> []
  ComponentChartRedis -> []
  ComponentChartKeycloakPostgres -> []
  ComponentChartKeycloak -> []
  ComponentChartVscode -> []
  ComponentChartApi -> []
  ComponentChartWebsocket -> []
  ComponentChartGateway -> []
  ComponentChartBootstrapBroker ->
    [StepAwsBootstrapBroker, StepAwsBootstrapBrokerReady]
  ComponentChartLifecycleAuthority ->
    [StepAwsLifecycleAuthority, StepAwsLifecycleAuthorityReady]
  ComponentChartProviderWorker ->
    [StepAwsProviderWorker, StepAwsProviderWorkerReady]
  ComponentChartAuthorityBackup ->
    [StepAwsAuthorityBackup, StepAwsAuthorityBackupReady]
  ComponentChartTlsRetention ->
    [StepAwsTlsRetention, StepAwsTlsRetentionReady]
  ComponentChartTargetSecretAgent ->
    [StepAwsTargetSecretAgent, StepAwsTargetSecretAgentReady]

awsEdgeSteps :: [AwsPlatformStepId]
awsEdgeSteps = [StepAwsAcmeRuntime, StepAwsAdminPublicEdgeRoutes]

awsRequiredComponents :: [ComponentId]
awsRequiredComponents =
  [ ComponentClusterBase
  , ComponentMinio
  , ComponentVaultWorkload
  , ComponentRegistry
  , ComponentChartBootstrapBroker
  , ComponentCertManager
  , ComponentVaultUnsealed
  , ComponentEnvoyGateway
  , ComponentPerconaPostgresOperator
  , ComponentChartTargetSecretAgent
  , ComponentChartLifecycleAuthority
  , ComponentGatewayDaemonFull
  , ComponentChartAuthorityBackup
  , ComponentChartProviderWorker
  , ComponentChartTlsRetention
  ]

awsAnchoredOrderSpec :: AnchoredOrderSpec AwsPlatformStepId
awsAnchoredOrderSpec =
  AnchoredOrderSpec
    { anchoredSurfaceName = "AWS substrate reconcile"
    , anchoredAllSteps = [minBound .. maxBound]
    , anchoredRequiredComponents = awsRequiredComponents
    , anchoredStepsForComponent = awsStepsForComponent
    , anchoredTailSteps = awsEdgeSteps
    , anchoredStepAnchor = awsStepAnchor
    , anchoredStepPhase = awsStepPhase
    , anchoredStepToken = awsStepToken
    }

buildAwsSubstratePlatformExecutionPlan
  :: ValidatedSettings -> Either String AwsPlatformPayload
buildAwsSubstratePlatformExecutionPlan settings = do
  (dag, order) <-
    compileAnchoredOrder
      awsAnchoredOrderSpec
      (components (validatedConfig settings))
  validateAwsDependencyCoverage dag
  pure AwsPlatformPayload {awsPlatformDag = dag, awsPlatformStepOrder = order}

validateAwsDependencyCoverage :: ComponentDag -> Either String ()
validateAwsDependencyCoverage dag =
  unless
    (null unmappedDependencies)
    ( Left
        ( "AWS substrate reconcile maps a component to concrete steps while one of its "
            ++ "declared dependencies is AWS-inapplicable: "
            ++ show
              [ componentIdText consumer ++ " -> " ++ componentIdText dependency
              | (consumer, dependency) <- unmappedDependencies
              ]
        )
    )
 where
  unmappedDependencies =
    [ (consumer, dependency)
    | (consumer, dependency) <- componentDagEdges dag
    , not (null (awsStepsForComponent consumer))
    , null (awsStepsForComponent dependency)
    ]

awsSubstratePlatformStepOrderRespectsGraph
  :: ComponentDag -> [AwsPlatformStepId] -> Either String ()
awsSubstratePlatformStepOrderRespectsGraph =
  anchoredOrderRespectsGraph awsAnchoredOrderSpec

awsLoadBalancerControllerRepoName :: String
awsLoadBalancerControllerRepoName = "eks"

awsLoadBalancerControllerRepoUrl :: String
awsLoadBalancerControllerRepoUrl = "https://aws.github.io/eks-charts"

awsLoadBalancerControllerChartRef :: String
awsLoadBalancerControllerChartRef =
  awsLoadBalancerControllerRepoName ++ "/aws-load-balancer-controller"

-- Pinned to a known-good upstream release. Update in lockstep with the
-- vendored IAM policy at pulumi/aws-eks/aws-lb-controller-iam-policy.json.
awsLoadBalancerControllerChartVersion :: String
awsLoadBalancerControllerChartVersion = "1.8.4"

awsLoadBalancerControllerReleaseName :: String
awsLoadBalancerControllerReleaseName = "aws-load-balancer-controller"

awsLoadBalancerControllerNamespace :: String
awsLoadBalancerControllerNamespace = "kube-system"

awsLoadBalancerControllerServiceAccountName :: String
awsLoadBalancerControllerServiceAccountName = "aws-load-balancer-controller"

-- | Install (or upgrade) the AWS Load Balancer Controller on the
-- AWS-substrate EKS cluster. The caller must have `KUBECONFIG` pointed at
-- the EKS cluster (see
-- `Prodbox.CLI.Charts.withSubstrateEnvironment`).
--
-- The function:
--   1. Validates that the snapshot carries the IRSA role ARN and cluster
--      name fields populated by Sprint 7.5.b.ii.b.
--   2. Applies a service account manifest into kube-system annotated
--      with the IRSA role ARN.
--   3. Adds the eks-charts Helm repo and installs the controller chart
--      with `serviceAccount.create=false` (we own the service account).
--   4. Waits for the controller deployment to become ready.
-- Sprint 1.90: the region is an 'AwsRegion', so the empty inhabitant this
-- function used to be handed is unrepresentable rather than defaulted.
ensureAwsLoadBalancerControllerRuntime
  :: FilePath -> AwsRegion -> AwsEksTestStackSnapshot -> IO ExitCode
ensureAwsLoadBalancerControllerRuntime repoRoot region snapshot
  | null (eksSnapshotAwsLbControllerRoleArn snapshot) =
      failWith
        "AWS LB Controller role ARN is empty; the AWS EKS Pulumi stack must be re-provisioned at or after Sprint 7.5.b.ii.b before installing the controller."
  | null (eksSnapshotClusterName snapshot) =
      failWith "AWS EKS cluster name is empty in the captured snapshot."
  | otherwise = do
      writeOutputLine
        ( "Installing AWS Load Balancer Controller on EKS cluster "
            ++ eksSnapshotClusterName snapshot
        )
      saExit <- applyServiceAccountManifest repoRoot snapshot
      case saExit of
        ExitFailure _ -> pure saExit
        ExitSuccess -> do
          repoExit <-
            ensureHelmRepoAdded
              awsLoadBalancerControllerRepoName
              awsLoadBalancerControllerRepoUrl
          case repoExit of
            ExitFailure _ -> pure repoExit
            ExitSuccess -> do
              installExit <- helmUpgradeInstall region snapshot
              case installExit of
                ExitFailure _ -> pure installExit
                ExitSuccess -> waitForDeployment awsLoadBalancerControllerNamespace awsLoadBalancerControllerReleaseName

applyServiceAccountManifest :: FilePath -> AwsEksTestStackSnapshot -> IO ExitCode
applyServiceAccountManifest repoRoot snapshot =
  withTempJsonFile
    repoRoot
    "aws-lb-controller-sa"
    (encode (serviceAccountManifest snapshot))
    ( \manifestPath ->
        runStreaming
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments = ["apply", "-f", manifestPath]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    )

serviceAccountManifest :: AwsEksTestStackSnapshot -> Value
serviceAccountManifest snapshot =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("ServiceAccount" :: String)
    , "metadata"
        .= object
          [ "name" .= awsLoadBalancerControllerServiceAccountName
          , "namespace" .= awsLoadBalancerControllerNamespace
          , "annotations"
              .= object
                [ Key.fromString "eks.amazonaws.com/role-arn"
                    .= eksSnapshotAwsLbControllerRoleArn snapshot
                ]
          , "labels"
              .= object
                [ Key.fromString "app.kubernetes.io/name"
                    .= ("aws-load-balancer-controller" :: String)
                , Key.fromString "app.kubernetes.io/managed-by"
                    .= ("prodbox" :: String)
                ]
          ]
    ]

ensureHelmRepoAdded :: String -> String -> IO ExitCode
ensureHelmRepoAdded repoName repoUrl = do
  repoAddResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "helm"
        , subprocessArguments = ["repo", "add", repoName, repoUrl]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  case repoAddResult of
    Failure err -> failWith ("failed to start helm repo add: " ++ err)
    Success output ->
      case processExitCode output of
        ExitSuccess -> updateRepo
        ExitFailure _
          | isAlreadyExistsError output -> updateRepo
          | otherwise ->
              failWith
                ("Failed to add Helm repo " ++ repoName ++ ": " ++ outputDetail output)
 where
  updateRepo =
    runStreaming
      Subprocess
        { subprocessPath = "helm"
        , subprocessArguments = ["repo", "update", repoName]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }

helmUpgradeInstall :: AwsRegion -> AwsEksTestStackSnapshot -> IO ExitCode
helmUpgradeInstall region snapshot =
  runStreaming
    Subprocess
      { subprocessPath = "helm"
      , subprocessArguments =
          [ "upgrade"
          , "--install"
          , awsLoadBalancerControllerReleaseName
          , awsLoadBalancerControllerChartRef
          , "--version"
          , awsLoadBalancerControllerChartVersion
          , "--namespace"
          , awsLoadBalancerControllerNamespace
          , "--create-namespace"
          , "--wait"
          , "--atomic"
          , "--timeout"
          , "10m0s"
          , "--set-string"
          , "clusterName=" ++ eksSnapshotClusterName snapshot
          , "--set"
          , "serviceAccount.create=false"
          , "--set-string"
          , "serviceAccount.name=" ++ awsLoadBalancerControllerServiceAccountName
          , "--set-string"
          , "region="
              ++ extractRegionFromArn
                (Text.unpack (awsRegionText region))
                (eksSnapshotAwsLbControllerRoleArn snapshot)
          , "--set-string"
          , "vpcId=" ++ eksSnapshotVpcId snapshot
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Nothing
      }

waitForDeployment :: String -> String -> IO ExitCode
waitForDeployment namespace deploymentName =
  runStreaming
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "-n"
          , namespace
          , "rollout"
          , "status"
          , "deployment/" ++ deploymentName
          , "--timeout=10m"
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Nothing
      }

waitForCrdEstablished :: String -> IO ExitCode
waitForCrdEstablished crdName =
  runStreaming
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "wait"
          , "--for=condition=Established"
          , "--timeout=300s"
          , "crd/" ++ crdName
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Nothing
      }

-- Envoy Gateway upstream OCI chart. Both substrates run the same Envoy
-- Gateway release — Harbor + the in-cluster registry are installed on BOTH
-- substrates (home: the in-cluster Harbor NodePort; AWS: the EKS-side Harbor
-- + node-local registry proxy that makes @127.0.0.1:30080/prodbox/...@
-- resolve on EKS), so the control-plane and data-plane images come from the
-- same Harbor-mirrored refs as the home substrate.
awsSubstrateEnvoyGatewayChartRef :: String
awsSubstrateEnvoyGatewayChartRef = "oci://docker.io/envoyproxy/gateway-helm"

-- Sprint 7.12: the Envoy Gateway chart version is sourced from the single
-- 'ContainerImage.envoyGatewayRelease' SSoT — the same value the home
-- installer uses — so the previous EG-@1.4.4@-chart / Envoy-@1.37@-data-plane
-- skew (audit C79) is eliminated by construction. There is no second place
-- to set an Envoy Gateway version.
awsSubstrateEnvoyGatewayChartVersion :: String
awsSubstrateEnvoyGatewayChartVersion = ContainerImage.envoyGatewayChartVersion

awsSubstrateEnvoyGatewayReleaseName :: String
awsSubstrateEnvoyGatewayReleaseName = "envoy-gateway"

awsSubstrateEnvoyGatewayNamespace :: String
awsSubstrateEnvoyGatewayNamespace = "envoy-gateway-system"

-- | Install (or upgrade) Envoy Gateway on the AWS-substrate EKS cluster.
-- The caller must have `KUBECONFIG` pointed at the EKS cluster (see
-- `Prodbox.CLI.Charts.withSubstrateEnvironment`).
--
-- Unlike the AWS Load Balancer Controller install, Envoy Gateway is
-- installed from an OCI chart reference rather than a classic Helm
-- repository, so this function does not call `helm repo add` first. The
-- chart provisions the Envoy Gateway controller deployment plus its
-- supporting CRDs; the controller picks up `Gateway`/`HTTPRoute` resources
-- created later by the chart-platform layer.
ensureAwsSubstrateEnvoyGatewayRuntime
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> AwsEksTestStackSnapshot
  -> IO ExitCode
ensureAwsSubstrateEnvoyGatewayRuntime
  repoRoot
  settings
  prodboxId
  labelValue
  snapshot = do
    writeOutputLine
      ( "Installing Envoy Gateway "
          ++ awsSubstrateEnvoyGatewayChartVersion
          ++ " on the AWS-substrate EKS cluster"
      )
    installExit <-
      runStreaming
        Subprocess
          { subprocessPath = "helm"
          , subprocessArguments =
              [ "upgrade"
              , "--install"
              , awsSubstrateEnvoyGatewayReleaseName
              , awsSubstrateEnvoyGatewayChartRef
              , "--version"
              , awsSubstrateEnvoyGatewayChartVersion
              , "--namespace"
              , awsSubstrateEnvoyGatewayNamespace
              , "--create-namespace"
              , "--wait"
              , "--atomic"
              , "--timeout"
              , "10m0s"
              , -- Sprint 7.12: pin the control-plane (gateway controller) image
                -- to the single 'ContainerImage.envoyGatewayRelease' SSoT — the
                -- same Harbor-mirrored ref the home installer uses — so both
                -- substrates run the identical Envoy Gateway control plane.
                "--set"
              , "deployment.envoyGateway.image.repository="
                  ++ awsSubstrateEnvoyGatewayControlPlaneRepository
              , "--set"
              , "deployment.envoyGateway.image.tag="
                  ++ ContainerImage.imageTag controlPlaneImage
              ]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Nothing
          }
    case installExit of
      ExitFailure _ -> pure installExit
      ExitSuccess ->
        runSequentially
          [ waitForDeployment awsSubstrateEnvoyGatewayNamespace awsSubstrateEnvoyGatewayReleaseName
          , waitForCrdEstablished "gatewayclasses.gateway.networking.k8s.io"
          , waitForCrdEstablished "gateways.gateway.networking.k8s.io"
          , waitForCrdEstablished "httproutes.gateway.networking.k8s.io"
          , waitForCrdEstablished "envoyproxies.gateway.envoyproxy.io"
          , waitForCrdEstablished "securitypolicies.gateway.envoyproxy.io"
          , reconcileAwsSubstrateEnvoyGatewayControllerOwner
              repoRoot
              settings
              prodboxId
              labelValue
              snapshot
          ]
   where
    controlPlaneImage = ContainerImage.harborEnvoyGatewayImage

-- | The Envoy Gateway control-plane image repository (registry + repo, no
-- tag) sourced from the single 'ContainerImage.envoyGatewayRelease' SSoT.
awsSubstrateEnvoyGatewayControlPlaneRepository :: String
awsSubstrateEnvoyGatewayControlPlaneRepository =
  ContainerImage.imageRegistry image ++ "/" ++ ContainerImage.imageRepository image
 where
  image = ContainerImage.harborEnvoyGatewayImage

publicEdgeGatewayClassName :: String
publicEdgeGatewayClassName = "prodbox-public-edge"

publicEdgeEnvoyProxyName :: String
publicEdgeEnvoyProxyName = "prodbox-public-edge"

applyAwsSubstrateEnvoyGatewayRuntime
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> ControllerOwnerManifestMode
  -> IO ExitCode
applyAwsSubstrateEnvoyGatewayRuntime repoRoot settings prodboxId labelValue mode = do
  writeOutputLine "Applying AWS-substrate Envoy Gateway runtime (GatewayClass + EnvoyProxy)"
  let manifestList =
        object
          [ "apiVersion" .= ("v1" :: String)
          , "kind" .= ("List" :: String)
          , "items"
              .= awsSubstrateEnvoyGatewayRuntimeManifest
                settings
                prodboxId
                labelValue
                mode
          ]
  withTempJsonFile
    repoRoot
    "aws-envoy-gateway-runtime"
    (encode manifestList)
    ( \manifestPath ->
        runStreaming
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments = ["apply", "-f", manifestPath]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    )

data ControllerOwnerManifestMode
  = ControllerOwnerManifestInert
  | ControllerOwnerManifestEnabled
  deriving (Eq, Show)

awsSubstrateEnvoyGatewayRuntimeManifest
  :: ValidatedSettings -> String -> String -> ControllerOwnerManifestMode -> [Value]
awsSubstrateEnvoyGatewayRuntimeManifest settings prodboxId labelValue mode =
  [ object
      [ "apiVersion" .= ("gateway.envoyproxy.io/v1alpha1" :: String)
      , "kind" .= ("EnvoyProxy" :: String)
      , "metadata"
          .= object
            [ "name" .= publicEdgeEnvoyProxyName
            , "namespace" .= awsSubstrateEnvoyGatewayNamespace
            , "annotations" .= object [Key.fromString "prodbox.io/id" .= prodboxId]
            , "labels" .= object [Key.fromString "prodbox.io/id" .= labelValue]
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
                              , "type" .= controllerOwnerServiceType mode
                              , "annotations"
                                  .= object
                                    [ Key.fromString "service.beta.kubernetes.io/aws-load-balancer-type"
                                        .= ("external" :: String)
                                    , Key.fromString "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"
                                        .= ("ip" :: String)
                                    , Key.fromString "service.beta.kubernetes.io/aws-load-balancer-scheme"
                                        .= ("internet-facing" :: String)
                                    , Key.fromString "service.beta.kubernetes.io/aws-load-balancer-ip-address-type"
                                        .= ("ipv4" :: String)
                                    , Key.fromString "service.beta.kubernetes.io/aws-load-balancer-name"
                                        .= Text.unpack awsEksLoadBalancerControllerName
                                    , Key.fromString "service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags"
                                        .= renderControllerOwnerServiceTags
                                    ]
                              , "labels" .= object [Key.fromString "prodbox.io/id" .= labelValue]
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
            , "annotations" .= object [Key.fromString "prodbox.io/id" .= prodboxId]
            , "labels" .= object [Key.fromString "prodbox.io/id" .= labelValue]
            ]
      , "spec"
          .= object
            [ "controllerName" .= ("gateway.envoyproxy.io/gatewayclass-controller" :: String)
            , "parametersRef"
                .= object
                  [ "group" .= ("gateway.envoyproxy.io" :: String)
                  , "kind" .= ("EnvoyProxy" :: String)
                  , "name" .= publicEdgeEnvoyProxyName
                  , "namespace" .= awsSubstrateEnvoyGatewayNamespace
                  ]
            ]
      ]
  ]

controllerOwnerServiceType :: ControllerOwnerManifestMode -> String
controllerOwnerServiceType mode = case mode of
  ControllerOwnerManifestInert -> "ClusterIP"
  ControllerOwnerManifestEnabled -> "LoadBalancer"

renderControllerOwnerServiceTags :: String
renderControllerOwnerServiceTags =
  Text.unpack
    ( Text.intercalate
        ","
        ( map
            (\(key, value) -> key <> "=" <> value)
            awsEksLoadBalancerControllerTags
        )
    )

reconcileAwsSubstrateEnvoyGatewayControllerOwner
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> AwsEksTestStackSnapshot
  -> IO ExitCode
reconcileAwsSubstrateEnvoyGatewayControllerOwner
  repoRoot
  settings
  prodboxId
  labelValue
  snapshot =
    case controllerOwnerDescriptor settings prodboxId labelValue snapshot of
      Left detail -> failWith detail
      Right descriptor -> do
        authenticated <-
          withHostLifecycleAuthorityAuthentication
            LifecycleAuthorityOperator
            repoRoot
            ( \authentication -> do
                transported <-
                  withLifecycleAuthorityAuthenticatedTransport
                    authentication
                    ( \transport ->
                        runControllerOwnerSequence
                          authentication
                          ( lifecycleAuthorityControllerOwnerAuthenticatedClient
                              transport
                          )
                          descriptor
                    )
                pure $ case transported of
                  Left err ->
                    Left (renderLifecycleAuthorityAuthenticationError err)
                  Right exitCode -> Right exitCode
            )
        case authenticated of
          Left err -> failWith (renderLifecycleAuthorityAuthenticationError err)
          Right (Left detail) -> failWith detail
          Right (Right exitCode) -> pure exitCode
   where
    runControllerOwnerSequence authentication client descriptor = do
      registered <- client (RegisterControllerOwnerInert descriptor)
      case registered of
        Left err -> failWith ("register inert controller owner: " ++ show err)
        Right state -> do
          uidState <- ensureControllerOwnerUid client descriptor state
          case uidState of
            Left exitCode -> pure exitCode
            Right stateWithUid -> do
              enabledState <- ensureControllerOwnerEnabled client descriptor stateWithUid
              case enabledState of
                Left exitCode -> pure exitCode
                Right _ -> do
                  childArns <- observeControllerOwnerChildArns authentication (60 :: Int)
                  case childArns of
                    Left detail -> failWith detail
                    Right arns -> do
                      registeredChildren <-
                        client (RegisterControllerOwnerChildArns descriptor arns)
                      case registeredChildren of
                        Left err ->
                          failWith
                            ("register controller-owned AWS child ARNs: " ++ show err)
                        Right _ -> pure ExitSuccess

    ensureControllerOwnerUid client descriptor state = case state of
      AwsIsolation.ControllerOwnerRegisteredInert {} -> applyInertAndRegister client descriptor
      AwsIsolation.ControllerOwnerUidRegistered _ expectedUid ->
        applyInertAndConfirm client descriptor expectedUid
      AwsIsolation.ControllerOwnerEnabled {} -> pure (Right state)
      AwsIsolation.ControllerChildArnsRegistered {} -> pure (Right state)

    applyInertAndRegister client descriptor = do
      applied <-
        applyAwsSubstrateEnvoyGatewayRuntime
          repoRoot
          settings
          prodboxId
          labelValue
          ControllerOwnerManifestInert
      case applied of
        ExitFailure _ -> pure (Left applied)
        ExitSuccess -> do
          uid <- observeControllerOwnerUid repoRoot
          case uid of
            Left detail -> Left <$> failWith detail
            Right observedUid -> do
              registered <- client (RegisterControllerOwnerUid descriptor observedUid)
              case registered of
                Left err ->
                  Left <$> failWith ("register controller-owner UID: " ++ show err)
                Right state -> pure (Right state)

    applyInertAndConfirm client descriptor expectedUid = do
      applied <-
        applyAwsSubstrateEnvoyGatewayRuntime
          repoRoot
          settings
          prodboxId
          labelValue
          ControllerOwnerManifestInert
      case applied of
        ExitFailure _ -> pure (Left applied)
        ExitSuccess -> do
          uid <- observeControllerOwnerUid repoRoot
          case uid of
            Left detail -> Left <$> failWith detail
            Right observedUid
              | observedUid /= expectedUid ->
                  Left
                    <$> failWith
                      ( "controller-owner UID changed before enable: expected "
                          ++ Text.unpack expectedUid
                          ++ ", observed "
                          ++ Text.unpack observedUid
                      )
              | otherwise -> do
                  replayed <- client (RegisterControllerOwnerUid descriptor observedUid)
                  case replayed of
                    Left err ->
                      Left <$> failWith ("read back controller-owner UID: " ++ show err)
                    Right state -> pure (Right state)

    ensureControllerOwnerEnabled client descriptor state = case state of
      AwsIsolation.ControllerOwnerEnabled {} -> applyEnabled state
      AwsIsolation.ControllerChildArnsRegistered {} -> applyEnabled state
      AwsIsolation.ControllerOwnerUidRegistered {} -> do
        applied <- applyEnabledManifest
        case applied of
          ExitFailure _ -> pure (Left applied)
          ExitSuccess -> do
            enabled <- client (EnableRegisteredControllerOwner descriptor)
            case enabled of
              Left err ->
                Left <$> failWith ("read back enabled controller owner: " ++ show err)
              Right enabledState -> pure (Right enabledState)
      AwsIsolation.ControllerOwnerRegisteredInert {} ->
        Left <$> failWith "controller owner remained inert after UID registration"
     where
      applyEnabled stateValue = do
        applied <- applyEnabledManifest
        pure $ case applied of
          ExitSuccess -> Right stateValue
          ExitFailure _ -> Left applied
      applyEnabledManifest =
        applyAwsSubstrateEnvoyGatewayRuntime
          repoRoot
          settings
          prodboxId
          labelValue
          ControllerOwnerManifestEnabled

    observeControllerOwnerChildArns authentication remaining
      | remaining <= 0 =
          pure
            ( Left
                "AWS Load Balancer Controller did not expose the registered public-edge family before the bounded deadline"
            )
      | otherwise = do
          observed <-
            dispatchAuthenticatedProviderIntentFresh
              authentication
              "aws-public-edge-controller-owner-observe"
              ( ObserveEksLoadBalancerControllerFamily
                  awsEksLoadBalancerControllerName
                  renderedControllerOwnerProviderTags
              )
          case observed of
            Left err ->
              pure
                ( Left
                    ( "observe registered public-edge AWS family: "
                        ++ renderProviderCallerError err
                    )
                )
            Right evidence ->
              case awsLoadBalancerControllerObservationArns evidence of
                Left detail -> pure (Left (Text.unpack detail))
                Right [] -> do
                  threadDelay 10000000
                  observeControllerOwnerChildArns authentication (remaining - 1)
                Right arns -> pure (Right arns)

controllerOwnerDescriptor
  :: ValidatedSettings
  -> String
  -> String
  -> AwsEksTestStackSnapshot
  -> Either String AwsIsolation.ControllerOwnerDescriptor
controllerOwnerDescriptor settings prodboxId labelValue snapshot = do
  region <- requireOperationalAwsRegion settings
  account <- accountFromIamRoleArn (eksSnapshotAwsLbControllerRoleArn snapshot)
  let canonicalEnabledManifest =
        encode
          ( awsSubstrateEnvoyGatewayRuntimeManifest
              settings
              prodboxId
              labelValue
              ControllerOwnerManifestEnabled
          )
      digest =
        TextEncoding.decodeUtf8
          (hexSha256 (BL.toStrict canonicalEnabledManifest))
  Right
    AwsIsolation.ControllerOwnerDescriptor
      { AwsIsolation.controllerOwnerAccount = account
      , AwsIsolation.controllerOwnerRegion = awsRegionText region
      , AwsIsolation.controllerOwnerCluster =
          Text.pack (eksSnapshotClusterName snapshot)
      , AwsIsolation.controllerOwnerResourceName =
          "envoy-gateway-system.envoyproxy.prodbox-public-edge"
      , AwsIsolation.controllerOwnerManifestDigest = digest
      , AwsIsolation.controllerOwnerTags = awsEksLoadBalancerControllerTags
      }

accountFromIamRoleArn :: String -> Either String Text.Text
accountFromIamRoleArn raw = case Text.splitOn ":" (Text.pack raw) of
  ["arn", partition, "iam", "", account, resource]
    | partition `elem` ["aws", "aws-us-gov", "aws-cn"]
    , Text.length account == 12
    , Text.all isDigit account
    , "role/" `Text.isPrefixOf` resource ->
        Right account
  _ -> Left "AWS Load Balancer Controller role ARN did not contain an exact 12-digit account binding"

observeControllerOwnerUid :: FilePath -> IO (Either String Text.Text)
observeControllerOwnerUid repoRoot = do
  observed <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "-n"
            , awsSubstrateEnvoyGatewayNamespace
            , "get"
            , "envoyproxy.gateway.envoyproxy.io/" ++ publicEdgeEnvoyProxyName
            , "-o"
            , "jsonpath={.metadata.uid}"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case observed of
    Failure detail -> Left ("observe controller-owner UID: " ++ detail)
    Success output -> case processExitCode output of
      ExitFailure _ ->
        Left ("observe controller-owner UID: " ++ outputDetail output)
      ExitSuccess ->
        let uid = Text.strip (Text.pack (processStdout output))
         in if Text.null uid
              then Left "controller-owner UID observation returned an empty UID"
              else Right uid

renderedControllerOwnerProviderTags :: Text.Text
renderedControllerOwnerProviderTags =
  Text.intercalate
    "|"
    ( map
        (\(key, value) -> key <> "=" <> value)
        awsEksLoadBalancerControllerTags
    )

configuredEnvoyGatewayDataPlaneReplicas :: ValidatedSettings -> Int
configuredEnvoyGatewayDataPlaneReplicas settings =
  fromIntegral
    ( replicasForSubstrate
        SubstrateAws
        (envoy_gateway_data_plane_scaling (deployment (validatedConfig settings)))
    )

-- cert-manager Helm chart. cert-manager is a SHARED platform component
-- installed on BOTH substrates from the upstream Jetstack chart; its chart
-- version comes from the single `Prodbox.ContainerImage.certManagerChartVersion`
-- SSoT (the same value the home installer uses), so there is no
-- per-substrate version skew. The substrate-aware ACME `ClusterIssuer`
-- rendering (with `substrateHostedZoneId settings SubstrateAws` resolving to
-- the per-substrate subzone) is already in place from Sprint `7.5.b.ii.a`;
-- this install lays down the cert-manager runtime that the ClusterIssuer
-- needs.
awsSubstrateCertManagerRepoName :: String
awsSubstrateCertManagerRepoName = "jetstack"

awsSubstrateCertManagerRepoUrl :: String
awsSubstrateCertManagerRepoUrl = "https://charts.jetstack.io"

awsSubstrateCertManagerChartRef :: String
awsSubstrateCertManagerChartRef = awsSubstrateCertManagerRepoName ++ "/cert-manager"

-- Sprint 7.12: cert-manager is a SHARED platform component, so its chart
-- version is sourced from the single 'ContainerImage.certManagerChartVersion'
-- SSoT — the same value the home installer uses. There is no per-substrate
-- re-pin.
awsSubstrateCertManagerChartVersion :: String
awsSubstrateCertManagerChartVersion = ContainerImage.certManagerChartVersion

awsSubstrateCertManagerReleaseName :: String
awsSubstrateCertManagerReleaseName = "cert-manager"

awsSubstrateCertManagerNamespace :: String
awsSubstrateCertManagerNamespace = "cert-manager"

-- | Install (or upgrade) cert-manager on the AWS-substrate EKS cluster.
-- The caller must have `KUBECONFIG` pointed at the EKS cluster.
--
-- The chart provisions the cert-manager controller, webhook, and
-- cainjector deployments plus the cert-manager CRDs (`crds.enabled=true`).
-- After the install, the function waits for the three deployments to
-- become ready. The downstream substrate-aware `ClusterIssuer` (rendered
-- with `SubstrateAws` to target the per-substrate Route 53 subzone) is
-- applied separately by the orchestrator in Sprint `7.5.b.ii.d.II.δ`.
ensureAwsSubstrateCertManagerRuntime :: IO ExitCode
ensureAwsSubstrateCertManagerRuntime = do
  writeOutputLine
    ( "Installing cert-manager "
        ++ awsSubstrateCertManagerChartVersion
        ++ " on the AWS-substrate EKS cluster"
    )
  repoExit <-
    ensureHelmRepoAdded awsSubstrateCertManagerRepoName awsSubstrateCertManagerRepoUrl
  case repoExit of
    ExitFailure _ -> pure repoExit
    ExitSuccess -> do
      installExit <-
        runStreaming
          Subprocess
            { subprocessPath = "helm"
            , subprocessArguments =
                [ "upgrade"
                , "--install"
                , awsSubstrateCertManagerReleaseName
                , awsSubstrateCertManagerChartRef
                , "--version"
                , awsSubstrateCertManagerChartVersion
                , "--namespace"
                , awsSubstrateCertManagerNamespace
                , "--create-namespace"
                , "--wait"
                , "--atomic"
                , "--timeout"
                , "10m0s"
                , "--set"
                , "crds.enabled=true"
                ]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Nothing
            }
      case installExit of
        ExitFailure _ -> pure installExit
        ExitSuccess ->
          waitForCertManagerDeployments

waitForCertManagerDeployments :: IO ExitCode
waitForCertManagerDeployments = go deployments
 where
  deployments =
    [ awsSubstrateCertManagerReleaseName
    , awsSubstrateCertManagerReleaseName ++ "-webhook"
    , awsSubstrateCertManagerReleaseName ++ "-cainjector"
    ]
  go [] = pure ExitSuccess
  go (deployment : rest) = do
    exitCode <- waitForDeployment awsSubstrateCertManagerNamespace deployment
    case exitCode of
      ExitFailure _ -> pure exitCode
      ExitSuccess -> go rest

-- | Apply the substrate-aware ACME `ClusterIssuer` and its supporting
-- Route 53 credentials secret on the AWS-substrate EKS cluster. The
-- `acmeClusterIssuerSpec` invocation here passes `SubstrateAws`, so the
-- ClusterIssuer's DNS01 `hostedZoneID` resolves to
-- `aws_substrate.hosted_zone_id` (the per-substrate subzone provisioned
-- by `pulumi aws-subzone-resources`).
ensureAwsSubstrateAcmeRuntime :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureAwsSubstrateAcmeRuntime repoRoot settings prodboxId labelValue =
  ensureAcmeRuntimeForSubstrate SubstrateAws repoRoot settings prodboxId labelValue

-- | Install the shared Vault chart on the AWS substrate. This intentionally
-- reuses the same @charts/vault@ Helm helper as the home substrate so both
-- substrates run the same Vault StatefulSet, Service, and PVC shape.
ensureAwsSubstrateVaultRuntime :: FilePath -> ValidatedSettings -> IO ExitCode
ensureAwsSubstrateVaultRuntime repoRoot settings = do
  writeOutputLine "Installing Vault on the AWS-substrate EKS cluster"
  ensureVaultRuntime repoRoot settings

-- | Orchestrate the full AWS-substrate platform install: AWS Load
-- Balancer Controller, Envoy Gateway, cert-manager, the substrate-aware
-- ACME `ClusterIssuer`, Vault, and the shared storage/registry/workload
-- bootstrap. Idempotent: each underlying step uses `helm upgrade --install`
-- and `kubectl apply`, so repeated runs converge to the desired state.
--
-- Preconditions:
--   * `prodbox aws stack eks reconcile` has been run, so the live
--     `aws-eks-test` Pulumi stack carries the IAM/IRSA output fields
--     added in Sprint `7.5.b.ii.b`. Sprint 4.18: this step reads those
--     fields live from the MinIO Pulumi backend via
--     `fetchPerRunStackOutputs`, not from a host-side snapshot cache.
--   * `prodbox aws stack aws-subzone reconcile` has been run, so
--     `aws_substrate.hosted_zone_id` and `aws_substrate.subzone_name` in
--     `prodbox.dhall` point at a live Route 53 subzone.
--   * The caller has `KUBECONFIG` pointed at the EKS cluster (see
--     `Prodbox.CLI.Charts.withSubstrateEnvironment`).
ensureAwsSubstratePlatformRuntime
  :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureAwsSubstratePlatformRuntime repoRoot settings prodboxId labelValue =
  runAwsSubstratePlatformPlanWith settings $ \payload -> do
    writeOutputLine
      ( "Reconciling AWS-substrate platform (graph-derived LB Controller + Envoy Gateway "
          ++ "+ cert-manager + ACME + Vault + containerd registry mirror + MinIO + Harbor + admin routes)"
      )
    applyAwsSubstratePlatformPayload repoRoot settings prodboxId labelValue payload

-- | Compile and validate the complete graph projection before invoking the
-- effectful continuation. Tests inject a mutation sentinel here to prove an
-- invalid/inverted graph cannot reach any platform action.
runAwsSubstratePlatformPlanWith
  :: ValidatedSettings
  -> (AwsPlatformPayload -> IO ExitCode)
  -> IO ExitCode
runAwsSubstratePlatformPlanWith settings applyPayload =
  case AwsIsolation.validateAwsControlPlaneIsolation AwsIsolation.canonicalAwsRoleTransports of
    Left defect ->
      failWith
        ( "AWS control-plane isolation refused before mutation: "
            ++ show defect
        )
    Right () ->
      case buildAwsSubstratePlatformExecutionPlan settings of
        Left detail ->
          failWith
            ( "AWS-substrate platform graph refused before mutation: "
                ++ detail
            )
        Right payload -> applyPayload payload

applyAwsSubstratePlatformPayload
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> AwsPlatformPayload
  -> IO ExitCode
applyAwsSubstratePlatformPayload repoRoot settings prodboxId labelValue payload = do
  writeOutputLine
    ( "AWS_SUBSTRATE_GRAPH_ORDER="
        ++ unwords (map awsStepToken (awsPlatformStepOrder payload))
    )
  outputsResult <-
    fetchPerRunStackOutputs repoRoot (StackName (Text.pack awsEksTestStackName))
  case outputsResult of
    Left err ->
      failWith
        ( "AWS-substrate platform install could not read aws-eks-test Pulumi "
            ++ "outputs from the in-cluster MinIO backend: "
            ++ err
            ++ ". Run `prodbox aws stack eks reconcile` first."
        )
    Right outputs ->
      case parseAwsEksTestStackFromOutputs outputs of
        Left err -> failWith ("AWS-substrate platform install could not parse aws-eks-test Pulumi outputs: " ++ err)
        Right snapshot ->
          runAwsSubstratePlatformOrder
            repoRoot
            settings
            prodboxId
            labelValue
            snapshot
            payload

runAwsSubstratePlatformOrder
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> AwsEksTestStackSnapshot
  -> AwsPlatformPayload
  -> IO ExitCode
runAwsSubstratePlatformOrder repoRoot settings prodboxId labelValue snapshot payload = do
  let (beforeGatewayEndpoint, fromGatewayEndpoint) =
        break (== StepAwsGatewayPostVault) (awsPlatformStepOrder payload)
      -- Sprint 5.31: a refusal arrives as itself and is rendered here. Lowering
      -- it inside the runner discarded the reason on a path that printed
      -- nothing, so a refused AWS platform order exited 1 in silence.
      --
      -- Sprint 4.69: this answers the same `Either ExitCode AdmissionSet` the
      -- opening slice answers. It used to answer a pair whose second component
      -- the final call site dropped with `fst <$>` — correct only because that
      -- call was last, and silently wrong the moment a third slice appeared.
      runSlice endpoint steps carried = do
        outcome <- runOrder endpoint carried steps
        case outcome of
          Left refusal -> Left <$> failWith (Text.unpack (renderAdmissionRefusal refusal))
          Right (ExitFailure code, _) -> pure (Left (ExitFailure code))
          Right (ExitSuccess, admissions) -> pure (Right admissions)
      -- Sprint 4.64: the first slice begins the run, so it takes the executor's
      -- own empty set rather than naming one. On any failure there is no
      -- admission set worth carrying, which is why every slice answers
      -- `Either`.
      runFirstSlice endpoint steps = do
        outcome <-
          runFirstAnchoredStepOrder
            (awsPlatformDag payload)
            awsReconcileClockMicros
            awsStepAnchor
            (mutatingStepAction endpoint)
            (runAwsSubstratePlatformStep repoRoot settings prodboxId labelValue snapshot endpoint)
            (requireAwsComponentReadiness repoRoot (awsPlatformDag payload) endpoint)
            steps
        case outcome of
          Left refusal -> Left <$> failWith (Text.unpack (renderAdmissionRefusal refusal))
          Right (ExitFailure code, _) -> pure (Left (ExitFailure code))
          Right (ExitSuccess, admissions) -> pure (Right admissions)
      mutatingStepAction endpoint admission step =
        mutationAdmittedComponent admission `seq`
          runAwsSubstratePlatformStep
            repoRoot
            settings
            prodboxId
            labelValue
            snapshot
            endpoint
            step
      runOrder endpoint =
        runAnchoredStepOrder
          (awsPlatformDag payload)
          awsReconcileClockMicros
          awsStepAnchor
          -- Sprint 4.56: the mutating arm requires the admission the executor
          -- re-validated, so it stays a required argument all the way to the act.
          ( \admission step ->
              mutationAdmittedComponent admission `seq`
                runAwsSubstratePlatformStep
                  repoRoot
                  settings
                  prodboxId
                  labelValue
                  snapshot
                  endpoint
                  step
          )
          (runAwsSubstratePlatformStep repoRoot settings prodboxId labelValue snapshot endpoint)
          (requireAwsComponentReadiness repoRoot (awsPlatformDag payload) endpoint)
  -- Sprint 4.61: the second slice inherits the first slice's admissions. They
  -- are two calls only because the gateway port-forward has to be established
  -- between them; a readiness observation from before the forward is still
  -- evidence after it, until its age bound expires it.
  case fromGatewayEndpoint of
    [] -> failWith "AWS-substrate platform graph has no post-Vault Gateway convergence step."
    _ ->
      runReconcileSlices
        (runFirstSlice Nothing beforeGatewayEndpoint)
        [ \carried -> do
            portForwarded <-
              withGatewayServicePortForward
                GatewayServicePortForward
                  { gatewayPortForwardNamespace = gatewayNamespace
                  , gatewayPortForwardServiceName = gatewayRestServiceName
                  , gatewayPortForwardRemotePort = gatewayRestServicePort
                  , gatewayPortForwardEnvironment = Nothing
                  , gatewayPortForwardWorkingDirectory = Just repoRoot
                  }
                (\endpoint -> runSlice (Just endpoint) fromGatewayEndpoint carried)
            case portForwarded of
              Left err -> Left <$> failWith (renderGatewayPortForwardError err)
              Right sliceOutcome -> pure sliceOutcome
        ]

-- | Run a reconcile as an opening slice followed by continuing slices, carrying
-- the admission set between them.
--
-- Sprint 4.69. The two slices used to be hand-written calls, and the last one
-- dropped the 'AdmissionSet' it returned with @fst \<$\>@ — correct only because
-- it happened to be last. Sprint 4.64 made a slice that starts from /no/
-- admissions unnameable; it did nothing about a slice that starts from a
-- /stale/ set because an intervening slice's admissions were thrown away, and
-- adding a third slice would have reintroduced Sprint 4.61's defect with no
-- compile error and no lint.
--
-- Threading is now the fold's job. A continuing slice cannot be written without
-- taking the carrier, because it /is/ a function of the carrier, and the run's
-- final admissions are discarded in exactly one place — here, where the run
-- ends and there is nothing left to hand them to.
--
-- The shape is deliberately asymmetric. Only the opening slice may start from
-- the executor's own empty set, so it is a separate argument rather than the
-- head of the list: a list of uniform slices would need a starting
-- 'AdmissionSet' from somewhere, and the only honest source of an empty one is
-- package-internal by construction.
runReconcileSlices
  :: IO (Either ExitCode AdmissionSet)
  -> [AdmissionSet -> IO (Either ExitCode AdmissionSet)]
  -> IO ExitCode
runReconcileSlices opening continuing = do
  opened <- opening
  case opened of
    Left exitCode -> pure exitCode
    Right admissions -> continue admissions continuing
 where
  continue _ [] = pure ExitSuccess
  continue carried (slice : remaining) = do
    outcome <- slice carried
    case outcome of
      Left exitCode -> pure exitCode
      Right admissions -> continue admissions remaining

runAwsSubstratePlatformStep
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> AwsEksTestStackSnapshot
  -> Maybe PeerEndpoint
  -> AwsPlatformStepId
  -> IO ExitCode
runAwsSubstratePlatformStep repoRoot settings prodboxId labelValue snapshot endpoint step =
  case step of
    StepAwsLoadBalancerControllerRuntime ->
      case requireOperationalAwsRegion settings of
        Left err -> failWith err
        Right region ->
          ensureAwsLoadBalancerControllerRuntime repoRoot region snapshot
    StepAwsClusterBaseReady -> pure ExitSuccess
    StepAwsRetainedStorage -> ensureAwsSubstrateRetainedStorage repoRoot settings snapshot
    StepAwsMinioRuntimeBootstrap ->
      ensureMinioRuntime repoRoot settings SubstrateAws MinioBootstrapPublic
    StepAwsMinioReady -> pure ExitSuccess
    StepAwsVaultRuntime -> ensureAwsSubstrateVaultRuntime repoRoot settings
    StepAwsVaultWorkloadReady -> pure ExitSuccess
    StepAwsContainerdMirror -> applyEksContainerdMirrorDaemonSet repoRoot
    StepAwsRegistryStorageBackend -> ensureHarborRegistryStorageBackend repoRoot
    StepAwsRegistryRuntime -> ensureHarborRegistryRuntime repoRoot SubstrateAws
    StepAwsRegistryMinioEdge -> ensureRegistryStorageBackendEdgeReady repoRoot
    StepAwsImageMirror -> applyEksImageMirrorJob repoRoot
    StepAwsRuntimeImage -> ensureRuntimeImageForSubstrate SubstrateAws repoRoot prodboxId
    StepAwsRegistryReady -> pure ExitSuccess
    StepAwsCertManagerRuntime -> ensureAwsSubstrateCertManagerRuntime
    StepAwsCertManagerReady -> pure ExitSuccess
    StepAwsBootstrapBroker ->
      ensureInternalControlPlaneChartReady
        repoRoot
        settings
        SubstrateAws
        ComponentChartBootstrapBroker
    StepAwsBootstrapBrokerReady -> pure ExitSuccess
    StepAwsVaultLifecycle ->
      runVaultBootstrapViaBroker repoRoot
    StepAwsVaultUnsealedReady -> pure ExitSuccess
    StepAwsEnvoyGatewayRuntime ->
      ensureAwsSubstrateEnvoyGatewayRuntime
        repoRoot
        settings
        prodboxId
        labelValue
        snapshot
    StepAwsEnvoyGatewayReady -> pure ExitSuccess
    StepAwsPostgresOperatorRuntime ->
      ensurePostgresOperatorRuntime repoRoot prodboxId labelValue
    StepAwsPostgresOperatorReady -> pure ExitSuccess
    StepAwsTargetSecretAgent ->
      ensureInternalControlPlaneChartReady
        repoRoot
        settings
        SubstrateAws
        ComponentChartTargetSecretAgent
    StepAwsTargetSecretAgentReady -> pure ExitSuccess
    StepAwsLifecycleAuthority ->
      ensureInternalControlPlaneChartReady
        repoRoot
        settings
        SubstrateAws
        ComponentChartLifecycleAuthority
    StepAwsLifecycleAuthorityReady -> pure ExitSuccess
    StepAwsGatewayMinioBootstrap -> ensureGatewayMinioBootstrap repoRoot
    StepAwsGatewayPostVault ->
      withRequiredGatewayEndpoint step endpoint $ \gatewayEndpoint ->
        ensureGatewayChartReadyPostVaultAt
          repoRoot
          settings
          SubstrateAws
          gatewayEndpoint
    StepAwsGatewayFullReady -> pure ExitSuccess
    StepAwsAuthorityBackup ->
      ensureInternalControlPlaneChartReady
        repoRoot
        settings
        SubstrateAws
        ComponentChartAuthorityBackup
    StepAwsAuthorityBackupReady -> pure ExitSuccess
    StepAwsProviderWorker ->
      ensureInternalControlPlaneChartReady
        repoRoot
        settings
        SubstrateAws
        ComponentChartProviderWorker
    StepAwsProviderWorkerReady -> pure ExitSuccess
    StepAwsTlsRetention ->
      ensureInternalControlPlaneChartReady
        repoRoot
        settings
        SubstrateAws
        ComponentChartTlsRetention
    StepAwsTlsRetentionReady -> pure ExitSuccess
    StepAwsAcmeRuntime ->
      ensureAwsSubstrateAcmeRuntime repoRoot settings prodboxId labelValue
    StepAwsAdminPublicEdgeRoutes ->
      ensureAdminPublicEdgeRoutes repoRoot settings SubstrateAws prodboxId labelValue

withRequiredGatewayEndpoint
  :: AwsPlatformStepId
  -> Maybe PeerEndpoint
  -> (PeerEndpoint -> IO ExitCode)
  -> IO ExitCode
withRequiredGatewayEndpoint step endpoint action =
  case endpoint of
    Nothing ->
      failWith
        ( "AWS-substrate step `"
            ++ awsStepToken step
            ++ "` requires the scoped gateway Service port-forward endpoint."
        )
    Just value -> action value

requireAwsComponentReadiness
  :: FilePath
  -> ComponentDag
  -> Maybe PeerEndpoint
  -> ComponentId
  -> IO (Either ExitCode DependencyAdmission)
requireAwsComponentReadiness repoRoot dag endpoint component =
  case (lookupComponentNode component dag, componentCapabilityRequirement component dag) of
    (Nothing, _) ->
      awsRefuseWith
        ( "AWS-substrate readiness has no graph node for component `"
            ++ componentIdText component
            ++ "`."
        )
    (_, Nothing) ->
      awsRefuseWith
        ( "AWS-substrate readiness has no capability requirement for component `"
            ++ componentIdText component
            ++ "`."
        )
    (Just node, Just requirement) ->
      case awsComponentReadinessTarget repoRoot endpoint component of
        Left reason -> awsRefuseWith (Text.unpack reason)
        Right target -> do
          -- Sprint 1.61: same shared capability-handle routing as the native
          -- driver (see 'Prodbox.CLI.Rke2.requireNativeComponentReadiness'); the
          -- AWS probe I/O ('awsComponentReadinessTarget') is unchanged.
          let client =
                newReadinessObservationClient
                  (coordGeneration (requirementCoordinate' requirement))
                  (readiness node)
                  target
          result <-
            observeReadinessThroughCapability
              componentReadinessRetryPolicy
              client
              component
              requirement
          case result of
            Right admission -> pure (Right admission)
            Left detail ->
              awsRefuseWith
                ( "AWS-substrate component `"
                    ++ componentIdText component
                    ++ "` did not satisfy "
                    ++ show (readiness node)
                    ++ " within the bounded readiness budget: "
                    ++ Text.unpack detail
                )

-- | AWS-owned one-shot bindings for every graph component this platform
-- driver mutates. MetalLB is explicitly inapplicable on EKS and chart nodes
-- remain owned by ChartPlatform; either route fails closed if misprojected.
awsComponentReadinessTarget
  :: FilePath
  -> Maybe PeerEndpoint
  -> ComponentId
  -> Either Text.Text ComponentReadinessTarget
awsComponentReadinessTarget repoRoot endpoint component =
  case component of
    ComponentClusterBase ->
      Right
        ( ServiceActiveTarget
            component
            (observeAwsClusterBaseOnce repoRoot)
        )
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
            ( observeKubernetesReadinessOnce
                repoRoot
                [StatefulSetReady vaultNamespace "vault"]
            )
        )
    ComponentVaultUnsealed ->
      Right
        ( VaultUnsealedTarget
            component
            (observeVaultUnsealedOnce repoRoot)
        )
    ComponentRegistry ->
      Right
        ( BackendRoundTripTarget
            component
            ComponentMinio
            ( observeKubernetesThenRoundTrip
                repoRoot
                [ DaemonSetReady
                    (mirrorNamespace defaultProdboxMirrorConfig)
                    (mirrorDaemonSetName defaultProdboxMirrorConfig)
                ]
                (observeRegistryBackendRoundTripOnce repoRoot)
            )
        )
    ComponentMetalLB ->
      Left "AWS substrate uses AWS Load Balancer Controller; MetalLB is explicitly inapplicable."
    ComponentEnvoyGateway ->
      Right
        ( RolloutCompleteTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                [ DeploymentAvailable
                    awsSubstrateEnvoyGatewayNamespace
                    awsSubstrateEnvoyGatewayReleaseName
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
                [ DeploymentAvailable
                    awsSubstrateCertManagerNamespace
                    awsSubstrateCertManagerReleaseName
                , DeploymentAvailable
                    awsSubstrateCertManagerNamespace
                    (awsSubstrateCertManagerReleaseName ++ "-webhook")
                , DeploymentAvailable
                    awsSubstrateCertManagerNamespace
                    (awsSubstrateCertManagerReleaseName ++ "-cainjector")
                , CrdEstablished "clusterissuers.cert-manager.io"
                ]
            )
        )
    ComponentPerconaPostgresOperator -> operatorAvailableTarget component
    ComponentGatewayDaemonPreVault -> unsupportedAwsReadiness component
    ComponentGatewayDaemonFull ->
      BackendRoundTripTarget component ComponentMinio
        <$> requiredReadinessEndpoint component endpoint observeGatewayBackendRoundTripOnceAt
    ComponentChartPulsar -> unsupportedAwsReadiness component
    ComponentChartRedis -> unsupportedAwsReadiness component
    ComponentChartKeycloakPostgres -> unsupportedAwsReadiness component
    ComponentChartKeycloak -> unsupportedAwsReadiness component
    ComponentChartVscode -> unsupportedAwsReadiness component
    ComponentChartApi -> unsupportedAwsReadiness component
    ComponentChartWebsocket -> unsupportedAwsReadiness component
    ComponentChartGateway -> unsupportedAwsReadiness component
    ComponentChartBootstrapBroker -> deploymentRolloutTarget component "bootstrap-broker"
    ComponentChartLifecycleAuthority ->
      Right
        ( RolloutCompleteTarget
            component
            ( observeKubernetesReadinessOnce
                repoRoot
                [StatefulSetReady "lifecycle-authority" "lifecycle-authority"]
            )
        )
    ComponentChartProviderWorker -> deploymentRolloutTarget component "provider-worker"
    ComponentChartAuthorityBackup -> deploymentRolloutTarget component "authority-backup"
    ComponentChartTlsRetention -> deploymentRolloutTarget component "tls-retention"
    ComponentChartTargetSecretAgent -> deploymentRolloutTarget component "target-secret-agent"
 where
  deploymentRolloutTarget targetComponent name =
    Right
      ( RolloutCompleteTarget
          targetComponent
          ( observeKubernetesReadinessOnce
              repoRoot
              [DeploymentAvailable name name]
          )
      )

requiredReadinessEndpoint
  :: ComponentId
  -> Maybe PeerEndpoint
  -> (PeerEndpoint -> action)
  -> Either Text.Text action
requiredReadinessEndpoint component endpoint action =
  case endpoint of
    Nothing ->
      Left
        ( Text.pack
            ( "AWS-substrate readiness for `"
                ++ componentIdText component
                ++ "` requires the scoped gateway Service port-forward endpoint."
            )
        )
    Just value -> Right (action value)

unsupportedAwsReadiness :: ComponentId -> Either Text.Text value
unsupportedAwsReadiness component =
  Left
    ( Text.pack
        ( "AWS platform reconcile has no readiness target for chart-owned component `"
            ++ componentIdText component
            ++ "`."
        )
    )

-- | Sprint 1.76: the deep-probe variant. The Kubernetes precondition is
-- read-shaped and stays so; only the continuation may yield write-shaped
-- evidence, and a pending precondition is lowered into the deep result type
-- rather than being allowed to masquerade as a confirmed round trip.
observeKubernetesThenRoundTrip
  :: FilePath
  -> [KubernetesReadinessCheck]
  -> IO (Either Text.Text BackendRoundTripResult)
  -> IO (Either Text.Text BackendRoundTripResult)
observeKubernetesThenRoundTrip repoRoot checks next = do
  observation <- observeKubernetesReadinessOnce repoRoot checks
  case observation of
    Right ReadinessProbeReady -> next
    Right (ReadinessProbePending detail) -> pure (Right (BackendRoundTripPending detail))
    Left reason -> pure (Left reason)

observeAwsClusterBaseOnce :: FilePath -> IO (Either Text.Text ReadinessProbeResult)
observeAwsClusterBaseOnce repoRoot = do
  nodes <- observeEksNodesReadyOnce repoRoot
  case nodes of
    Right ReadinessProbeReady ->
      observeKubernetesReadinessOnce
        repoRoot
        [ DeploymentAvailable
            awsLoadBalancerControllerNamespace
            awsLoadBalancerControllerReleaseName
        ]
    Right pending@(ReadinessProbePending _) -> pure (Right pending)
    Left reason -> pure (Left reason)

observeEksNodesReadyOnce :: FilePath -> IO (Either Text.Text ReadinessProbeResult)
observeEksNodesReadyOnce repoRoot = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "nodes"
            , "--ignore-not-found"
            , "-o"
            , "jsonpath={range .items[*]}{.metadata.name}:{range .status.conditions[?(@.type==\"Ready\")]}{.status}{end}{\"\\n\"}{end}"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case result of
      Failure err -> Left (Text.pack err)
      Success output ->
        case processExitCode output of
          ExitFailure _ -> Left (Text.pack (outputDetail output))
          ExitSuccess -> classifyEksNodesReadiness (processStdout output)

classifyEksNodesReadiness :: String -> Either Text.Text ReadinessProbeResult
classifyEksNodesReadiness raw =
  let records = filter (not . null) (map trim (lines raw))
      nonReady = filter (not . isSuffixOf ":true" . map toLower) records
   in if null records
        then Right (ReadinessProbePending "EKS has no observable nodes")
        else
          if null nonReady
            then Right ReadinessProbeReady
            else
              Right
                ( ReadinessProbePending
                    (Text.pack ("EKS nodes are not Ready: " ++ unwords nonReady))
                )
 where
  trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

ensureAwsSubstrateRetainedStorage
  :: FilePath -> ValidatedSettings -> AwsEksTestStackSnapshot -> IO ExitCode
ensureAwsSubstrateRetainedStorage repoRoot settings snapshot = do
  writeOutputLine
    ( "Reconciling AWS retained EBS PVs in "
        ++ eksSnapshotRetainedEbsAvailabilityZone snapshot
    )
  let inventory = retainedStorageInventoryEntries SubstrateAws
      bindings = map inventoryStorageBinding inventory
      requiredResult =
        mapM
          (EbsVolume.ebsRequiredVolumeFromChartStorageBinding (eksSnapshotRetainedEbsAvailabilityZone snapshot))
          bindings
  case (requiredResult, requireAwsSubstrateProfile settings) of
    (Left err, _) -> failWith err
    (_, Left err) -> failWith err
    (Right required, Right authoredProfile) -> do
      environment <- getEnvironment
      ebsBindingsResult <-
        EbsVolume.ensureRetainedEbsVolumes
          EbsVolume.EbsEnsureInput
            { EbsVolume.ebsEnsureEnvironment = environment
            , EbsVolume.ebsEnsureWorkingDirectory = Just repoRoot
            , EbsVolume.ebsEnsureVolumeType =
                awsSubstrateStaticEbsVolumeType authoredProfile
            }
          required
      case ebsBindingsResult of
        Left err -> failWith ("AWS retained EBS storage reconcile failed: " ++ err)
        Right ebsBindings ->
          foldM
            (applyNamespaceManifest ebsBindings inventory bindings)
            ExitSuccess
            (storageNamespaces inventory)
 where
  inventoryStorageBinding entry =
    ChartStorageBinding
      { chartStorageBindingStatefulSetName = retainedStorageInventoryStatefulSet entry
      , chartStorageBindingReleaseName = retainedStorageInventoryStatefulSet entry
      , chartStorageBindingPersistentVolumeName = retainedStorageInventoryPersistentVolume entry
      , chartStorageBindingPersistentVolumeClaimName = retainedStorageInventoryPersistentClaim entry
      , chartStorageBindingStorageSize = retainedStorageInventoryStorageSize entry
      , chartStorageBindingHostPath = ""
      , chartStorageBindingOrdinal = retainedStorageInventoryOrdinal entry
      , chartStorageBindingClaimSuffix = "data"
      }

  storageNamespaces inventory =
    nub (map retainedStorageInventoryNamespace inventory)

  applyNamespaceManifest _ _ _ (ExitFailure code) _ = pure (ExitFailure code)
  applyNamespaceManifest ebsBindings inventory bindings ExitSuccess namespace =
    let namespaceBindings =
          [ binding
          | (entry, binding) <- zip inventory bindings
          , retainedStorageInventoryNamespace entry == namespace
          ]
     in case chartEbsPersistentVolumeManifest namespace namespace namespaceBindings ebsBindings of
          Left err -> failWith ("AWS retained EBS storage manifest failed: " ++ err)
          Right manifest ->
            withTempJsonFile
              repoRoot
              ("aws-retained-ebs-" ++ namespace)
              (encode manifest)
              ( \manifestPath ->
                  runStreaming
                    Subprocess
                      { subprocessPath = "kubectl"
                      , subprocessArguments = ["apply", "-f", manifestPath]
                      , subprocessEnvironment = Nothing
                      , subprocessWorkingDirectory = Just repoRoot
                      }
              )

-- | Pure narration projected from the same compiled default graph and typed
-- step table as the production executor. There is no parallel ordered list to
-- keep in lockstep.
awsSubstratePlatformRuntimeStepDescriptions :: [String]
awsSubstratePlatformRuntimeStepDescriptions =
  case compileAnchoredOrder awsAnchoredOrderSpec defaultComponentGraph of
    Left detail -> ["INVALID_AWS_SUBSTRATE_GRAPH=" ++ detail]
    Right (_dag, order) -> map awsStepToken order

-- | Sprint 7.12: the shared platform components the AWS-substrate install
-- path stands up. The lower-layer pieces (the AWS Load Balancer Controller
-- — 'ensureAwsLoadBalancerControllerRuntime', the EKS containerd
-- registry-mirror DaemonSet / node-local registry proxy, and the delegated
-- Route 53 subzone) are intentionally substrate-specific and are NOT part of
-- the shared inventory. This list is asserted equal (as a set) to
-- 'ContainerImage.sharedPlatformComponents' by the 'test/unit/Main.hs'
-- coverage test, so the AWS install can never silently omit a shared
-- component.
--
-- Harbor + MinIO + the Percona operator are installed on the AWS substrate
-- just as on home: the EKS-side Harbor + node-local registry proxy makes
-- @127.0.0.1:30080/prodbox/...@ resolve on EKS (mirroring the home
-- NodePort-on-@127.0.0.1@ pattern), so the canonical chart image refs are
-- identical across substrates. The seven workload charts (@gateway@,
-- @keycloak@, @keycloak-postgres@, @vscode@, @api@, @redis@, @websocket@)
-- are deployed through the substrate-independent 'Prodbox.Lib.ChartPlatform'
-- on BOTH substrates.
awsSubstratePlatformComponents :: [ContainerImage.PlatformComponent]
awsSubstratePlatformComponents =
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

-- | Sprint 7.5.c.iv: apply the in-cluster image-mirror Job rendered
-- by 'Prodbox.Lib.EksImageMirror' so every public image required by
-- the canonical chart set lands in the EKS-side Harbor before the
-- Percona operator + steady-state MinIO reconcile steps (which both
-- pull from Harbor) execute. After applying the Job manifest, blocks
-- until @kubectl wait --for=condition=complete@ on the Job returns
-- success; the @backoffLimit=2@ on the Job means transient pull
-- failures (e.g. upstream registry rate-limit) retry within the
-- single Job rather than failing the orchestrator immediately.
applyEksImageMirrorJob :: FilePath -> IO ExitCode
applyEksImageMirrorJob repoRoot = go eksImageMirrorMaxAttempts
 where
  cfg = defaultEksImageMirrorConfig
  jobNs = mirrorJobNamespace cfg
  jobNm = mirrorJobName cfg
  manifestList =
    object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("List" :: String)
      , "items" .= [eksImageMirrorJobManifest cfg ContainerImage.requiredPublicImagePairs]
      ]

  go :: Int -> IO ExitCode
  go attemptsRemaining = do
    writeOutputLine
      ( "Applying in-cluster image-mirror Job ("
          ++ jobNs
          ++ "/"
          ++ jobNm
          ++ ")"
      )
    applyExit <-
      withTempJsonFile
        repoRoot
        "eks-image-mirror-job"
        (encode manifestList)
        ( \manifestPath ->
            runStreaming
              Subprocess
                { subprocessPath = "kubectl"
                , subprocessArguments = ["apply", "-f", manifestPath]
                , subprocessEnvironment = Nothing
                , subprocessWorkingDirectory = Just repoRoot
                }
        )
    case applyExit of
      ExitFailure _ -> pure applyExit
      ExitSuccess -> do
        waitExit <-
          runStreaming
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments =
                  [ "wait"
                  , "--for=condition=complete"
                  , "job/" ++ jobNm
                  , "-n"
                  , jobNs
                  , "--timeout=20m"
                  ]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        case waitExit of
          ExitSuccess -> pure ExitSuccess
          ExitFailure _
            | attemptsRemaining > 1 -> do
                -- Sprint 7.31: the crane push edge fails transiently with
                -- name-resolution errors while endpoint programming settles. The
                -- Job's own `backoffLimit=2` bounds in-Job retries; when the whole
                -- Job fails we classify its logs and re-apply once more if the
                -- failure is a retryable transient (bootstrap_readiness_doctrine.md
                -- §4). A non-retryable failure fails fast.
                detail <- captureEksImageMirrorFailureDetail repoRoot jobNs jobNm
                if isRetryableEksImageMirrorFailure detail
                  then do
                    writeOutputLine
                      ( "Retrying EKS image-mirror Job after a transient failure ("
                          ++ show (eksImageMirrorMaxAttempts - attemptsRemaining + 1)
                          ++ "/"
                          ++ show eksImageMirrorMaxAttempts
                          ++ "): "
                          ++ detail
                      )
                    _ <- deleteEksImageMirrorJob repoRoot jobNs jobNm
                    threadDelay eksImageMirrorRetryDelayMicros
                    go (attemptsRemaining - 1)
                  else pure waitExit
            | otherwise -> pure waitExit

-- | How many times the EKS image-mirror Job is (re)applied before failing.
eksImageMirrorMaxAttempts :: Int
eksImageMirrorMaxAttempts = 3

-- | Delay between EKS image-mirror Job re-applies.
eksImageMirrorRetryDelayMicros :: Int
eksImageMirrorRetryDelayMicros = 10 * 1000000

-- | Capture the mirror Job's pod logs so the failure can be classified. Best
-- effort: an empty detail simply classifies as non-retryable.
captureEksImageMirrorFailureDetail :: FilePath -> String -> String -> IO String
captureEksImageMirrorFailureDetail repoRoot jobNs jobNm = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "logs"
            , "job/" ++ jobNm
            , "-n"
            , jobNs
            , "--all-containers=true"
            , "--tail=200"
            , "--ignore-errors"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case result of
    Failure err -> err
    Success output -> outputDetail output

-- | Delete a failed mirror Job so the next attempt can re-create it.
deleteEksImageMirrorJob :: FilePath -> String -> String -> IO ExitCode
deleteEksImageMirrorJob repoRoot jobNs jobNm =
  runStreaming
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          ["delete", "job", jobNm, "-n", jobNs, "--ignore-not-found"]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

-- | Sprint 7.5.c.iii: apply the EKS containerd registry-mirror
-- DaemonSet rendered by 'Prodbox.Lib.EksContainerdMirror' so EKS nodes
-- route @127.0.0.1:30080@ chart-image pulls into the in-cluster Harbor
-- NodePort installed two steps later in this orchestrator. Idempotent:
-- the bootstrap script only restarts containerd when its on-disk
-- config actually changed.
applyEksContainerdMirrorDaemonSet :: FilePath -> IO ExitCode
applyEksContainerdMirrorDaemonSet repoRoot = do
  writeOutputLine
    "Applying EKS containerd registry-mirror DaemonSet (kube-system/prodbox-containerd-mirror)"
  let manifestList =
        object
          [ "apiVersion" .= ("v1" :: String)
          , "kind" .= ("List" :: String)
          , "items" .= [eksContainerdMirrorDaemonSetManifest defaultProdboxMirrorConfig]
          ]
  withTempJsonFile
    repoRoot
    "eks-containerd-mirror"
    (encode manifestList)
    ( \manifestPath ->
        runStreaming
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments = ["apply", "-f", manifestPath]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    )

runSequentially :: [IO ExitCode] -> IO ExitCode
runSequentially [] = pure ExitSuccess
runSequentially (step : rest) = do
  exitCode <- step
  case exitCode of
    ExitFailure _ -> pure exitCode
    ExitSuccess -> runSequentially rest

-- | Extract the region segment from an IAM role ARN. IAM roles use the
-- form `arn:aws:iam::<account>:role/<name>` and do not embed a region,
-- so the empty fourth segment is the expected case for IRSA role ARNs.
-- We preserve empty segments during parsing (unlike `words`-style helpers
-- that collapse adjacent delimiters) so the account number isn't
-- mistakenly returned as the region; when the region segment is empty
-- the caller's fallback is used.
--
-- __Sprint 1.90: read the sentence above carefully — the fallback is the
-- normal path, not the exceptional one.__ IRSA role ARNs never embed a
-- region, so the caller's value is what reaches the controller on every
-- ordinary install. That is why the caller now supplies an 'AwsRegion'
-- resolved from config: before this sprint it supplied a compiled region whenever
-- @aws.region@ was unset, which was not a rare degradation but the value
-- every unconfigured install would have shipped.
extractRegionFromArn :: String -> String -> String
extractRegionFromArn defaultRegion arn =
  case splitKeepingEmpty ':' arn of
    _ : _ : _ : regionField : _
      | not (null regionField) -> regionField
    _ -> defaultRegion
 where
  splitKeepingEmpty :: Char -> String -> [String]
  splitKeepingEmpty delim s =
    let (chunk, rest) = break (== delim) s
     in case rest of
          [] -> [chunk]
          _ : remainder -> chunk : splitKeepingEmpty delim remainder

isAlreadyExistsError :: ProcessOutput -> Bool
isAlreadyExistsError output =
  let combined = outputDetail output
   in "already exists" `containsCI` combined

containsCI :: String -> String -> Bool
containsCI needle haystack =
  let lc = map toAsciiLower
   in lc needle `isInfixOf'` lc haystack
 where
  isInfixOf' n h = case h of
    [] -> null n
    _ : rest -> startsWith n h || isInfixOf' n rest
  startsWith [] _ = True
  startsWith _ [] = False
  startsWith (x : xs) (y : ys) = x == y && startsWith xs ys
  toAsciiLower c
    | isAsciiUpper c = toEnum (fromEnum c + 32)
    | otherwise = c

outputDetail :: ProcessOutput -> String
outputDetail output = processStderr output ++ processStdout output

runStreaming :: Subprocess -> IO ExitCode
runStreaming spec = do
  result <- runSubprocessStreaming spec
  case result of
    Failure err -> failWith err
    Success exitCode -> pure exitCode

-- | Sprint 4.56: a refused readiness barrier yields no admission.
awsRefuseWith :: String -> IO (Either ExitCode admission)
awsRefuseWith message = Left <$> failWith message

-- | The reconcile clock an admission's age is measured against.
awsReconcileClockMicros :: IO Natural
awsReconcileClockMicros = do
  posix <- getPOSIXTime
  pure (fromInteger (max 0 (floor (toRational posix * 1000000) :: Integer)))

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

-- | Sprint 4.18: scratch JSON payloads stage under the system temp
-- directory so they do not contribute to the repo-local
-- @.prodbox-state\/@ surface. The file is removed after the action
-- completes.
withTempJsonFile :: FilePath -> String -> BL.ByteString -> (FilePath -> IO ExitCode) -> IO ExitCode
withTempJsonFile _repoRoot prefix payload action = do
  systemTemp <- getTemporaryDirectory
  (path, handle) <- openTempFile systemTemp (prefix ++ "-")
  BL.hPut handle payload
  hClose handle
  exitCode <- action path
  removeFile path
  pure exitCode
