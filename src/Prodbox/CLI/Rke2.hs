{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Rke2
  ( acmeRuntimeManifest
  , acmeRuntimeManifestWith
  , acmeClusterIssuerSpec
  , ensureGatewayImagesForSubstrate
  , ensureGatewayMinioBootstrap
  , ensureAdminPublicEdgeRoutes
  , adminPublicEdgeManifestItems
  , ensureHarborRegistryRuntime
  , ensureHarborRegistryStorageBackend
  , ensureMinioRuntime
  , ensurePostgresOperatorRuntime
  , ensurePublicEdgeWorkloadImageForSubstrate
  , MinioImageSource (..)
  , cascadeOrderNarration
  , inferCascadeSubstrate
  , renderNativeInstallPlan
  , renderInotifySysctlDropIn
  , renderMinioChartArgs
  , runNativeDeleteCascade
  , runNativeDeleteWithResiduePolicy
  , runRke2Command
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , displayException
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
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char
  ( isAsciiLower
  , isAsciiUpper
  , isDigit
  , isHexDigit
  , isSpace
  , toLower
  )
import Data.List
  ( intercalate
  , isInfixOf
  , isPrefixOf
  , nub
  )
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Word (Word8)
import Prodbox.Aws (adminAwsEnvironment)
import Prodbox.AwsEnvironment
  ( overlayAwsCredentials
  )
import Prodbox.CLI.Command
  ( Plan (..)
  , PlanOptions (..)
  , PulumiCommand (..)
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
import Prodbox.CLI.Pulumi (runPulumiCommand)
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Dns (fetchPublicIp)
import Prodbox.Dns qualified as Dns
import Prodbox.Error (fatalError)
import Prodbox.Host
  ( LanAddressing (..)
  , defaultGatewayNodePort
  , detectLanAddressing
  , runHostFirewallGatewayUnrestrict
  )
import Prodbox.Infra.AwsEksTestStack (awsEksCanonicalClusterName, withEksKubeconfig)
import Prodbox.Infra.LongLivedPulumiBackend (loadAdminAwsCredentials)
import Prodbox.Infra.MinioBackend (withCurrentMinioPortForward)
import Prodbox.Lib.ChartPlatform
  ( keycloakRealmName
  , keycloakVscodeClientId
  )
import Prodbox.Lib.EksCustomImagePush
  ( EksCustomImagePushConfig (..)
  , defaultEksCustomImagePushConfig
  , eksCustomImagePushPodManifest
  , rewriteChartRefForInClusterPush
  )
import Prodbox.Lifecycle.K8sDrain qualified as K8sDrain
import Prodbox.Lifecycle.LiveResidue
  ( PerRunResidueStatuses (..)
  , queryPerRunResidueStatuses
  )
import Prodbox.Lifecycle.Preconditions qualified as Preconditions
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.ResourceRegistry qualified as ResourceRegistry
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.PostgresPlatform
  ( patroniOperatorDeploymentName
  , patroniOperatorNamespace
  , patroniOperatorReleaseName
  , patroniPostgresqlCrdName
  )
import Prodbox.PublicEdge
  ( PublicEdgeRoute (..)
  , authPathPrefix
  , harborPathPrefix
  , minioPathPrefix
  , publicEdgeClusterIssuerName
  , substrateHostedZoneId
  , substrateIdentityIssuerUrl
  , substratePublicFqdn
  , substratePublicRouteUrl
  )
import Prodbox.Result (Result (..))
import Prodbox.Retry
  ( RetryPolicy (..)
  , retryDelayMicros
  )
import Prodbox.Secret.Derive (MasterSeed, deriveBase64Url, masterSeed, oidcClientSecretContext)
import Prodbox.Secret.MasterSeed
  ( defaultMinioMasterSeedConfig
  , ensureMasterSeed
  , renderMasterSeedError
  )
import Prodbox.Settings
  ( AcmeSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , MetallbBgpPeer (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , access_key_id
  , acme
  , aws
  , bootstrap_public_ip_override
  , defaultConfigFile
  , demo_ttl
  , domain
  , eab_hmac_key
  , eab_key_id
  , email
  , loadConfigFile
  , manual_pv_host_root
  , pulumi_enable_dns_bootstrap
  , region
  , route53
  , secret_access_key
  , server
  , session_token
  , storage
  , validateAndLoadSettings
  , validatedConfig
  , zone_id
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import Prodbox.Substrate (Substrate (..), substrateId)
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

rke2BinaryPath :: FilePath
rke2BinaryPath = "/usr/local/bin/rke2"

rke2ConfigPath :: FilePath
rke2ConfigPath = "/etc/rancher/rke2/config.yaml"

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

harborReleaseName :: String
harborReleaseName = "harbor"

harborRepositoryName :: String
harborRepositoryName = "harbor"

harborRepositoryUrl :: String
harborRepositoryUrl = "https://helm.goharbor.io"

harborRegistryEndpoint :: String
harborRegistryEndpoint = ContainerImage.harborRegistryEndpoint

harborMirrorProject :: String
harborMirrorProject = ContainerImage.harborMirrorProject

harborGatewayRepository :: String
harborGatewayRepository = ContainerImage.harborGatewayRepository

harborAdminUser :: String
harborAdminUser = "admin"

harborAdminPassword :: String
harborAdminPassword = "Harbor12345"

harborReadyPath :: String
harborReadyPath = "/readyz"

harborReadyAnnotationKey :: String
harborReadyAnnotationKey = "prodbox.io/harbor-nginx-readiness-contract"

harborReadyAnnotationValue :: String
harborReadyAnnotationValue = "readyz-v1"

publicEdgeListenerName :: String
publicEdgeListenerName = "https"

harborAdminRouteName :: String
harborAdminRouteName = "harbor-ui"

harborAdminSecurityPolicyName :: String
harborAdminSecurityPolicyName = "harbor-oidc"

harborAdminClientSecretName :: String
harborAdminClientSecretName = "harbor-oidc-client"

harborServiceName :: String
harborServiceName = "harbor"

harborServicePort :: Int
harborServicePort = 80

minioNamespace :: String
minioNamespace = prodboxNamespace

minioReleaseName :: String
minioReleaseName = "minio"

minioRepositoryName :: String
minioRepositoryName = "minio"

minioRepositoryUrl :: String
minioRepositoryUrl = "https://charts.min.io/"

minioChartRef :: String
minioChartRef = "minio/minio"

minioChartVersion :: String
minioChartVersion = "5.4.0"

minioServiceName :: String
minioServiceName = "minio"

minioAdminRouteName :: String
minioAdminRouteName = "minio-console"

minioAdminSecurityPolicyName :: String
minioAdminSecurityPolicyName = "minio-oidc"

minioAdminClientSecretName :: String
minioAdminClientSecretName = "minio-oidc-client"

minioConsoleServiceName :: String
minioConsoleServiceName = "minio-console"

minioConsoleServicePort :: Int
minioConsoleServicePort = 9001

harborRegistryStorageSecretName :: String
harborRegistryStorageSecretName = "harbor-registry-s3"

harborRegistryStorageBucket :: String
harborRegistryStorageBucket = "prodbox-harbor-registry"

harborRegistryStorageBootstrapJobName :: String
harborRegistryStorageBootstrapJobName = "harbor-registry-bucket-init"

-- | Sprint 2.19: the Job name + bucket name + canonical IAM principal
-- and policy name for the gateway daemon's master-seed MinIO surface,
-- provisioned in one unified pass by 'ensureGatewayMinioBootstrap'.
gatewayMinioBootstrapJobName :: String
gatewayMinioBootstrapJobName = "gateway-minio-bootstrap"

gatewayMinioBucket :: String
gatewayMinioBucket = "prodbox"

-- | Namespace where the gateway chart deploys. Reconcile pre-creates
-- it so the chart-side 'gateway-minio-creds' Secret has a place to
-- live before @prodbox charts deploy gateway@ runs.
gatewayNamespace :: String
gatewayNamespace = "gateway"

-- | k8s Secret name carrying the @prodbox-gateway@ MinIO credentials
-- (as a Dhall fragment under the @minio.dhall@ key). Created by
-- 'ensureGatewayMinioBootstrap' and consumed by the gateway chart's
-- @secret-minio-creds.yaml@ template via Helm @lookup@.
gatewayMinioCredsSecretName :: String
gatewayMinioCredsSecretName = "gateway-minio-creds"

-- | Canonical IAM principal name for the gateway daemon's MinIO
-- access. Suffixed with 8 random hex chars on first provisioning so
-- the principal name doesn't collide if cluster state diverges.
gatewayMinioUserPrefix :: String
gatewayMinioUserPrefix = "prodbox-gateway-"

-- | Canonical IAM policy name granting the gateway user
-- @s3:GetObject@/@s3:PutObject@/@s3:ListBucket@ on @prodbox/*@.
gatewayMinioPolicyName :: String
gatewayMinioPolicyName = "prodbox-gateway-policy"

minioClusterEndpoint :: String
minioClusterEndpoint =
  "http://" ++ minioServiceName ++ "." ++ minioNamespace ++ ".svc.cluster.local:9000"

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

envoyGatewayChartVersion :: String
envoyGatewayChartVersion = "v1.7.2"

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

certManagerChartVersion :: String
certManagerChartVersion = "v1.16.2"

postgresOperatorRepositoryName :: String
postgresOperatorRepositoryName = "percona"

postgresOperatorRepositoryUrl :: String
postgresOperatorRepositoryUrl = "https://percona.github.io/percona-helm-charts/"

postgresOperatorChartRef :: String
postgresOperatorChartRef = "percona/pg-operator"

postgresOperatorChartVersion :: String
postgresOperatorChartVersion = "2.9.0"

-- | The cert-manager ACME account-key Secret name. cert-manager stores
-- the ZeroSSL ACME account registration under this @privateKeySecretRef@.
zerosslAccountKeySecretName :: String
zerosslAccountKeySecretName = "zerossl-account-key"

route53CredentialsSecretName :: String
route53CredentialsSecretName = "route53-credentials"

acmeEabSecretName :: String
acmeEabSecretName = "acme-eab-credentials"

acmeEabSecretKey :: String
acmeEabSecretKey = "secret"

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

minioPersistentVolume :: String
minioPersistentVolume = "prodbox-minio-pv-0"

minioPersistentClaim :: String
minioPersistentClaim = "minio"

minioStorageSize :: String
minioStorageSize = "200Gi"

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
      requireLinux $
        runCommand
          Subprocess
            { subprocessPath = "systemctl"
            , subprocessArguments = ["is-active", rke2ServiceName]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
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
    Rke2Reconcile planOptions ->
      requireLinux (runNativeInstall repoRoot planOptions)
    Rke2Delete flags _planOptions ->
      requireLinux $
        if not (rke2DeleteYes flags)
          then failWith "rke2 delete requires --yes confirmation"
          else do
            -- No RKE2 install on this host means there is nothing to delete, so
            -- short-circuit to a no-op success BEFORE the per-run residue gate.
            -- An unreachable in-cluster MinIO backend (the gate's fail-closed
            -- case) is otherwise indistinguishable from "cluster already gone",
            -- which would wrongly refuse a delete that has nothing to do. The
            -- gate and --cascade orchestration are unchanged when a cluster
            -- (even a stopped one) is present.
            present <- rke2InstallPresent
            if not present
              then do
                writeOutputLine noRke2ClusterMessage
                pure ExitSuccess
              else
                -- Raise the host inotify limits BEFORE systemd unwinds the
                -- RKE2 units during teardown, so PID 1 does not log
                -- `Failed to allocate directory watch: Too many open files`
                -- to the console (see streaming_doctrine.md § 6). Idempotent
                -- and shared with reconcile; covers both delete paths.
                runSequentially
                  [ ensureHostInotifyLimits repoRoot
                  , if rke2DeleteCascade flags
                      then runNativeDeleteCascade repoRoot
                      else runNativeDeleteWithResiduePolicy repoRoot flags
                  ]
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

runNativeInstall :: FilePath -> PlanOptions -> IO ExitCode
runNativeInstall repoRoot planOptions = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      identityResult <- resolveMachineIdentity
      case identityResult of
        Left err -> failWith err
        Right (machineId, prodboxId) ->
          let labelValue = prodboxIdToLabelValue prodboxId
              plan = buildNativeInstallExecutionPlan repoRoot settings machineId prodboxId labelValue
           in runPlanWithOptions
                planOptions
                plan
                (applyNativeInstallPlan repoRoot settings)

renderNativeInstallPlan :: FilePath -> ValidatedSettings -> String -> String -> String -> String
renderNativeInstallPlan repoRoot settings machineId prodboxId labelValue =
  unlines
    [ "RKE2_RECONCILE_PLAN"
    , "REPO_ROOT=" ++ repoRoot
    , "MACHINE_ID=" ++ machineId
    , "PRODBOX_ID=" ++ prodboxId
    , "LABEL_VALUE=" ++ labelValue
    , "MANUAL_PV_ROOT=" ++ resolvedManualPvHostRoot settings
    , "STEP=ensure_host_inotify_limits"
    , "STEP=ensure_rke2_server_installed"
    , "STEP=ensure_rke2_ingress_controller"
    , "STEP=enable_rke2_service"
    , "STEP=restart_rke2_service"
    , "STEP=sync_user_kubeconfig"
    , "STEP=verify_cluster_info"
    , "STEP=wait_for_cluster_nodes_ready"
    , "STEP=delete_non_manual_storage_classes"
    , "STEP=ensure_prodbox_identity_config_map"
    , "STEP=ensure_retained_local_storage"
    , "STEP=ensure_minio_runtime_bootstrap"
    , "STEP=ensure_harbor_registry_storage_backend"
    , "STEP=ensure_harbor_registry_runtime"
    , "STEP=mirror_cluster_images_once"
    , "STEP=ensure_gateway_images"
    , "STEP=ensure_public_edge_workload_image"
    , "STEP=ensure_rke2_registries_config"
    , "STEP=ensure_cluster_platform_runtime"
    , "STEP=reconcile_dns_bootstrap_record"
    , "STEP=ensure_minio_runtime_steady_state"
    , "STEP=ensure_gateway_minio_bootstrap"
    , "STEP=ensure_admin_public_edge_routes"
    , "STEP=reconcile_managed_annotations"
    ]

buildNativeInstallExecutionPlan
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> String
  -> Plan (String, String, String)
buildNativeInstallExecutionPlan repoRoot settings machineId prodboxId labelValue =
  buildPlan
    ( \(resolvedMachineId, resolvedProdboxId, resolvedLabelValue) ->
        renderNativeInstallPlan
          repoRoot
          settings
          resolvedMachineId
          resolvedProdboxId
          resolvedLabelValue
    )
    (machineId, prodboxId, labelValue)

applyNativeInstallPlan
  :: FilePath
  -> ValidatedSettings
  -> (String, String, String)
  -> IO ExitCode
applyNativeInstallPlan repoRoot settings (machineId, prodboxId, labelValue) =
  runSequentially
    [ ensureHostInotifyLimits repoRoot
    , ensureRke2ServerInstalled repoRoot
    , ensureRke2IngressController repoRoot
    , runCommand
        Subprocess
          { subprocessPath = "sudo"
          , subprocessArguments = ["systemctl", "enable", rke2ServiceName]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    , runCommand
        Subprocess
          { subprocessPath = "sudo"
          , subprocessArguments = ["systemctl", "restart", rke2ServiceName]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    , syncUserKubeconfig repoRoot
    , verifyClusterInfo repoRoot
    , waitForClusterNodesReady repoRoot
    , deleteNonManualStorageClasses repoRoot
    , ensureProdboxIdentityConfigMap repoRoot machineId prodboxId labelValue
    , ensureRetainedLocalStorage repoRoot settings prodboxId labelValue
    , ensureMinioRuntime repoRoot SubstrateHomeLocal MinioBootstrapPublic
    , ensureHarborRegistryStorageBackend repoRoot
    , ensureHarborRegistryRuntime repoRoot SubstrateHomeLocal
    , mirrorClusterImagesOnce repoRoot
    , ensureGatewayImages repoRoot prodboxId
    , ensurePublicEdgeWorkloadImage repoRoot prodboxId
    , ensureRke2RegistriesConfig repoRoot
    , ensureClusterPlatformRuntime repoRoot settings prodboxId labelValue
    , reconcileDnsBootstrapRecord repoRoot settings
    , ensureMinioRuntime repoRoot SubstrateHomeLocal MinioSteadyStateHarbor
    , ensureGatewayMinioBootstrap repoRoot
    , ensureAdminPublicEdgeRoutes repoRoot settings SubstrateHomeLocal prodboxId labelValue
    , reconcileManagedAnnotations repoRoot prodboxId labelValue
    ]

runNativeDelete :: FilePath -> IO ExitCode
runNativeDelete repoRoot = do
  retainedManualPvRoot <- resolveRetainedManualPvRoot repoRoot
  writeOutputLine "Deleting local RKE2 environment..."
  runSequentially
    [ runPulumiCommand repoRoot (PulumiEksDestroy True (PlanOptions False Nothing))
    , runPulumiCommand repoRoot (PulumiTestDestroy True (PlanOptions False Nothing))
    , deleteRke2ClusterSubstrate repoRoot
    , removeCalicoEndpointStatusResidue
    , removeManagedKubeconfig
    , runHostFirewallGatewayUnrestrict defaultGatewayNodePort
    , renderRetainedStateNotice repoRoot retainedManualPvRoot
    ]

-- | Sprint 4.11: @prodbox rke2 delete@ (default mode) opens with
-- @checkAll [noLivePerRunPulumiStacks]@. When @--allow-pulumi-residue@
-- is set the operator has explicitly acknowledged the risk and the
-- precondition is skipped. Per the doctrine, the K8s drain phase and
-- postflight tag sweep land in Sprints 4.12; this sprint only adds
-- the refuse-path and the @--cascade@ entry point.
runNativeDeleteWithResiduePolicy :: FilePath -> Rke2DeleteFlags -> IO ExitCode
runNativeDeleteWithResiduePolicy repoRoot flags
  | rke2DeleteAllowPulumiResidue flags = runNativeDelete repoRoot
  | otherwise = do
      checkResult <-
        Preconditions.checkAll [Preconditions.noLivePerRunPulumiStacks repoRoot]
      case checkResult of
        Left failures -> do
          writeOutputLine (Preconditions.renderPreconditionFailures failures)
          pure (ExitFailure 1)
        Right () -> runNativeDelete repoRoot

-- | Sprint 4.17.a canonical cascade order:
-- confirm-MinIO → drain → per-run destroys → uninstall → sweep.
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
-- | Sprint 4.17.a: the operator-facing narration string for the canonical
-- cascade phase order. Exposed as a top-level constant so unit tests can pin
-- the drain-before-destroys order without re-implementing it. The order text
-- must match the doctrine table at
-- @documents/engineering/lifecycle_reconciliation_doctrine.md §5b@.
cascadeOrderNarration :: String
cascadeOrderNarration =
  "rke2 delete --cascade: confirm-MinIO → drain → per-run destroys → uninstall → sweep"

runNativeDeleteCascade :: FilePath -> IO ExitCode
runNativeDeleteCascade repoRoot = do
  writeOutputLine cascadeOrderNarration
  -- Step 1: confirm-MinIO — live source-of-truth query against the
  -- per-run MinIO backend (one shared port-forward across the three
  -- per-run stacks).
  perRun <- queryPerRunResidueStatuses repoRoot
  let eksStatus = perRunAwsEksTest perRun
      subzoneStatus = perRunAwsEksSubzone perRun
      testStatus = perRunAwsTest perRun
      -- Sprint 4.21: pair the per-run managed resources with their
      -- already-batched statuses; `reconcileAbsent` destroys the present
      -- ones (canonical order) using the same PulumiCommands as before.
      perRunPairs = ResourceRegistry.pairPerRunResidue eksStatus subzoneStatus testStatus
      liveSummary =
        intercalate
          ", "
          ( [ "aws-eks=" ++ ResidueStatus.renderResidueStatus eksStatus
            , "aws-eks-subzone=" ++ ResidueStatus.renderResidueStatus subzoneStatus
            , "aws-test=" ++ ResidueStatus.renderResidueStatus testStatus
            ]
          )
  writeOutputLine ("Per-run residue status: " ++ liveSummary)
  -- Step 2: K8s drain. Runs before per-run destroys so in-cluster
  -- controllers (AWS LBC, EBS CSI) release their AWS-side ENIs / ALBs /
  -- EBS volumes while still alive. Substrate is inferred from per-run
  -- residue presence (Sprint 4.17.b): any AWS per-run stack with residue
  -- means the EKS cluster is in scope and the drain must target the
  -- substrate's own kubeconfig instead of the local RKE2 cluster's.
  let cascadeSubstrate = inferCascadeSubstrate eksStatus subzoneStatus testStatus
  drainExit <- runCascadeDrainPhase repoRoot cascadeSubstrate
  case drainExit of
    ExitFailure _ -> pure drainExit
    ExitSuccess -> do
      -- Step 3: per-run Pulumi destroys (fail-fast). Controller-owned
      -- AWS resources are now drained, so subnet / VPC deletes succeed
      -- without DependencyViolation. Sprint 4.21: routed through the
      -- managed-resource registry's `reconcileAbsent` (destroys the
      -- present per-run stacks; skips absent/unreachable per the
      -- per-run graceful-degradation rule).
      destroyExit <- ResourceRegistry.reconcileAbsent repoRoot perRunPairs
      case destroyExit of
        ExitFailure _ -> pure destroyExit
        ExitSuccess -> do
          -- Step 4: RKE2 uninstall + cluster-substrate cleanup.
          retainedManualPvRoot <- resolveRetainedManualPvRoot repoRoot
          uninstallExit <-
            runSequentially
              [ deleteRke2ClusterSubstrate repoRoot
              , removeCalicoEndpointStatusResidue
              , removeManagedKubeconfig
              , runHostFirewallGatewayUnrestrict defaultGatewayNodePort
              , renderRetainedStateNotice repoRoot retainedManualPvRoot
              ]
          case uninstallExit of
            ExitFailure _ -> pure uninstallExit
            ExitSuccess -> do
              -- Step 5: postflight cluster-tag sweep (best effort).
              runCascadePostflightTagSweep repoRoot
              pure ExitSuccess

-- Sprint 4.21: the per-run cascade inventory (which present stacks to
-- destroy, in canonical order) moved into the managed-resource registry
-- as 'Prodbox.Lifecycle.ResourceRegistry.pairPerRunResidue' +
-- 'resourcesToDestroy', and the destroy dispatch into
-- 'Prodbox.Lifecycle.ResourceRegistry.reconcileAbsent'.

-- | Sprint 4.17.b: derive the cascade's substrate from per-run residue
-- presence. Any per-run AWS stack with @ResiduePresent@ residue means
-- the AWS substrate is in scope (the EKS cluster is alive and the
-- substrate-platform install's controllers may have created AWS-side
-- ENIs / ALBs / EBS volumes that the drain phase must release). The
-- home substrate is the fallback when no per-run AWS residue is
-- detected.
inferCascadeSubstrate
  :: ResidueStatus.ResidueStatus
  -> ResidueStatus.ResidueStatus
  -> ResidueStatus.ResidueStatus
  -> Substrate
inferCascadeSubstrate eksStatus subzoneStatus testStatus =
  if any
    ResidueStatus.isResiduePresent
    [eksStatus, subzoneStatus, testStatus]
    then SubstrateAws
    else SubstrateHomeLocal

-- | Sprint 4.17.a/4.17.b helper: the K8s drain phase extracted from the
-- prior single-block cascade so step 2 of the canonical order is
-- callable in isolation, with substrate-aware kubeconfig + AWS env
-- handling.
--
-- For @SubstrateHomeLocal@: keeps the Sprint 4.15 skip-is-success
-- semantics — when the local Kubernetes cluster is absent, the drain
-- phase emits @DrainSkipped@ and the cascade continues (no in-cluster
-- controllers means nothing to drain).
--
-- For @SubstrateAws@: sets @KUBECONFIG@ to the substrate's kubeconfig
-- (@.prodbox-state\/aws-eks-test\/kubeconfig@) plus
-- @AWS_ACCESS_KEY_ID@ \/ @AWS_SECRET_ACCESS_KEY@ \/ @AWS_DEFAULT_REGION@
-- \/ @AWS_REGION@ \/ @AWS_SESSION_TOKEN@ from
-- @settings.aws@ so @aws eks get-token@ can authenticate. Treats
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
  let drainAndDecide drainEnvVars = do
        let drainEnv =
              K8sDrain.K8sDrainEnv
                { K8sDrain.drainEnvironment = drainEnvVars
                , K8sDrain.drainWorkingDirectory = Just repoRoot
                }
        drainResult <- K8sDrain.drainAwsAffectingK8sResources drainEnv K8sDrain.defaultDrainTimeout
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
              -- Sprint 4.17.b: skipped drain on AWS substrate is a hard failure.
              -- The EKS cluster is the source of the AWS resources the per-run
              -- destroys would need to delete; skipping the drain guarantees
              -- the next phase will fail with DependencyViolation on subnet
              -- deletion. See lifecycle_reconciliation_doctrine.md §5b.
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
  case substrate of
    SubstrateHomeLocal -> do
      drainEnvVars <- buildDrainEnvironment repoRoot SubstrateHomeLocal Nothing
      drainAndDecide drainEnvVars
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
              drainAndDecide drainEnvVars
          )
          :: IO (Either SomeException ExitCode)
      case bracketResult of
        Left exc -> do
          writeOutputLine
            ( "K8s drain phase failed on the AWS substrate: kubeconfig "
                ++ "materialization failed ("
                ++ show exc
                ++ "). Cascade aborts because the per-run Pulumi destroys "
                ++ "would fail with DependencyViolation on subnet deletion."
            )
          pure (ExitFailure 1)
        Right ec -> pure ec

-- | Sprint 4.17.b helper, re-shaped for Sprint 4.18 fifth chunk: build
-- the env-var list passed to 'K8sDrain.K8sDrainEnv' per substrate. For
-- home-local, prepends @KUBECONFIG=\/etc\/rancher\/rke2\/rke2.yaml@ when
-- that file exists. For AWS, the caller materializes the kubeconfig via
-- 'withEksKubeconfig' and threads the resulting scoped temp path in via
-- the third argument. @KUBECONFIG@ + @AWS_*@ are projected from
-- @settings.aws@.
buildDrainEnvironment
  :: FilePath -> Substrate -> Maybe FilePath -> IO [(String, String)]
buildDrainEnvironment repoRoot substrate maybeAwsKubeconfig = do
  parentEnv <- getEnvironment
  case (substrate, maybeAwsKubeconfig) of
    (SubstrateHomeLocal, _) -> do
      rke2KubeconfigPresent <- doesFileExist rke2KubeconfigPath
      pure $
        if rke2KubeconfigPresent
          then ("KUBECONFIG", rke2KubeconfigPath) : parentEnv
          else parentEnv
    (SubstrateAws, Nothing) -> pure parentEnv
    (SubstrateAws, Just kubeconfigPath) -> do
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left _ -> pure (("KUBECONFIG", kubeconfigPath) : parentEnv)
        Right settings ->
          let awsCreds = aws (validatedConfig settings)
              baseOverrides =
                [ ("KUBECONFIG", kubeconfigPath)
                , ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id awsCreds))
                , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key awsCreds))
                , ("AWS_DEFAULT_REGION", Text.unpack (region awsCreds))
                , ("AWS_REGION", Text.unpack (region awsCreds))
                ]
              tokenOverrides = case session_token awsCreds of
                Nothing -> []
                Just tok -> [("AWS_SESSION_TOKEN", Text.unpack tok)]
           in pure (baseOverrides ++ tokenOverrides ++ parentEnv)

-- | Sprint 4.17 helper: the postflight cluster-tag sweep extracted from
-- the canonical cascade. Best-effort: a non-zero sweep exit is reported
-- as a diagnostic so the operator can resolve any cluster-tagged
-- residue, but the cascade itself succeeded. Per
-- @documents/engineering/lifecycle_reconciliation_doctrine.md §6@, the
-- sweep is the backstop for K8s-operator-created AWS resources that
-- escape the drain.
--
-- The sweep runs when admin AWS credentials are present in
-- @aws_admin_for_test_simulation.*@. When they are absent (operator
-- has not yet bootstrapped admin credentials, or is running on a
-- home-only cluster with no AWS substrate provisioned), the sweep
-- emits a single-line diagnostic and the cascade continues — the
-- absence of admin credentials is itself evidence that no AWS resources
-- could have been created by this cluster lifecycle.
--
-- Best-effort: when admin credentials are present the sweep calls the
-- AWS Resource Tagging API for any resource carrying the canonical
-- @aws-eks-test-cluster@ Kubernetes cluster tag or the
-- @prodbox.io/managed-by=prodbox@ ownership tag. A non-zero sweep is
-- reported with the structured refusal block so the operator can
-- resolve any cluster-tagged residue, but the cascade itself still
-- returns 'ExitSuccess' — destructive lifecycle commands do not retry
-- on a postflight diagnostic per
-- @documents\/engineering\/lifecycle_reconciliation_doctrine.md § 6@.
runCascadePostflightTagSweep :: FilePath -> IO ()
runCascadePostflightTagSweep repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left _ -> do
      writeOutputLine
        "Postflight tag sweep: skipped (aws_admin_for_test_simulation.* not configured, \
        \so no AWS resources could have been created by this cluster lifecycle)."
    Right adminCredentials -> do
      environment <- adminAwsEnvironment adminCredentials
      let input =
            TagSweep.TagSweepInput
              { TagSweep.tagSweepEnvironment = environment
              , TagSweep.tagSweepClusterName = Just awsEksCanonicalClusterName
              , TagSweep.tagSweepWorkingDirectory = Just repoRoot
              }
      sweepResult <- TagSweep.discoverClusterTaggedAwsResources input
      case sweepResult of
        Left err ->
          writeOutputLine
            ("Postflight tag sweep: query failed (continuing): " ++ err)
        Right [] ->
          writeOutputLine
            "Postflight tag sweep: clean (no cluster-tagged or prodbox-owned AWS residue)."
        Right resources -> do
          writeOutputLine
            ( "Postflight tag sweep: "
                ++ show (length resources)
                ++ " resource(s) still tagged — operator action required:"
            )
          writeOutputLine (TagSweep.renderTagSweepRefusal resources)

resolveRetainedManualPvRoot :: FilePath -> IO FilePath
resolveRetainedManualPvRoot repoRoot = do
  configResult <- loadConfigFile repoRoot
  let configuredRoot =
        case configResult of
          Right config -> Text.unpack (manual_pv_host_root (storage config))
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

ensureRetainedLocalStorage :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureRetainedLocalStorage repoRoot settings prodboxId labelValue = do
  nodeNameResult <- resolveSingleNodeHostname repoRoot
  case nodeNameResult of
    Left err -> failWith err
    Right nodeName -> do
      let hostPath = resolvedManualPvHostRoot settings </> prodboxId </> minioPersistentVolume
      hostPathExit <- ensureHostStoragePath repoRoot hostPath
      case hostPathExit of
        ExitFailure _ -> pure hostPathExit
        ExitSuccess -> do
          pvPhaseResult <-
            captureKubectl
              repoRoot
              ["get", "pv", minioPersistentVolume, "-o", "jsonpath={.status.phase}", "--ignore-not-found=true"]
          case pvPhaseResult of
            Left err -> failWith err
            Right pvPhaseOutput -> do
              let existingPhase = trimWhitespace (processStdout pvPhaseOutput)
              resetExit <-
                if existingPhase `elem` ["Released", "Failed"]
                  then
                    runCommand
                      Subprocess
                        { subprocessPath = "kubectl"
                        , subprocessArguments =
                            ["delete", "pv", minioPersistentVolume, "--ignore-not-found=true", "--wait=true"]
                        , subprocessEnvironment = Nothing
                        , subprocessWorkingDirectory = Just repoRoot
                        }
                  else pure ExitSuccess
              case resetExit of
                ExitFailure _ -> pure resetExit
                ExitSuccess -> do
                  pvcPhaseResult <-
                    captureKubectl
                      repoRoot
                      [ "get"
                      , "pvc"
                      , minioPersistentClaim
                      , "-n"
                      , minioNamespace
                      , "-o"
                      , "jsonpath={.status.phase}"
                      ]
                  case pvcPhaseResult of
                    Left err -> failWith err
                    Right pvcPhaseOutput -> do
                      let pvcAlreadyBound =
                            processExitCode pvcPhaseOutput == ExitSuccess
                              && trimWhitespace (processStdout pvcPhaseOutput) == "Bound"
                          manifestItems =
                            if pvcAlreadyBound
                              then take 2 (storageManifestItems hostPath nodeName prodboxId labelValue)
                              else storageManifestItems hostPath nodeName prodboxId labelValue
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

ensureMinioRuntime :: FilePath -> Substrate -> MinioImageSource -> IO ExitCode
ensureMinioRuntime repoRoot substrate imageSource = do
  repoAddResult <-
    captureToolOutput repoRoot "helm" ["repo", "add", minioRepositoryName, minioRepositoryUrl]
  case repoAddResult of
    Left err -> failWith err
    Right repoAddOutput ->
      case processExitCode repoAddOutput of
        ExitFailure _
          | "already exists" `isInfixOf` map toLower (outputDetail repoAddOutput) -> continue
          | otherwise -> failWith ("Failed to add MinIO helm repo: " ++ outputDetail repoAddOutput)
        ExitSuccess -> continue
 where
  continue =
    runSequentially
      [ runHelmCommandWithRetries repoRoot ["repo", "update"]
      , runHelmCommandWithRetries
          repoRoot
          ( [ "upgrade"
            , "--install"
            , minioReleaseName
            , minioChartRef
            , "--version"
            , minioChartVersion
            , "--namespace"
            , minioNamespace
            , "--create-namespace"
            ]
              ++ renderMinioChartArgs substrate imageSource
          )
      , runCommand
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments =
                [ "wait"
                , "--for=condition=Available"
                , "deployment/minio"
                , "-n"
                , minioNamespace
                , "--timeout=300s"
                ]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
      ]

-- | Pure render of @--set@ flag pairs for the MinIO chart install,
-- substrate-aware per Sprint @7.5.c.i@:
--
--   * 'SubstrateHomeLocal' binds to the operator-host @hostPath@ PVC
--     pre-created by 'ensureRetainedLocalStorage'
--     (@persistence.existingClaim=minio@).
--   * 'SubstrateAws' lets the chart dynamically provision an EBS
--     volume against the EKS default @gp2@ storage class
--     (@persistence.storageClass=gp2@), with no @existingClaim@. The
--     volume size is bounded at 20 GiB to keep test-substrate EBS
--     cost predictable; the home substrate's 200 GiB size argument
--     was hostPath-backed and effectively ignored by the chart.
--
-- Substrate-agnostic core (chart mode, replicas, service type,
-- image refs, resource requests) is shared. The function is total:
-- the @[String]@ output is a flat alternating @["--set", "k=v", …]@
-- list ready to splice into a @helm upgrade --install@ invocation.
renderMinioChartArgs :: Substrate -> MinioImageSource -> [String]
renderMinioChartArgs substrate imageSource =
  let (minioImage, minioMcImage) = minioChartImages imageSource
      coreArgs =
        [ "--set"
        , "mode=standalone"
        , "--set"
        , "replicas=1"
        , "--set"
        , "persistence.enabled=true"
        , "--set"
        , "image.repository=" ++ renderImageRefWithoutTag minioImage
        , "--set"
        , "image.tag=" ++ ContainerImage.imageTag minioImage
        , "--set"
        , "mcImage.repository=" ++ renderImageRefWithoutTag minioMcImage
        , "--set"
        , "mcImage.tag=" ++ ContainerImage.imageTag minioMcImage
        , "--set"
        , "service.type=ClusterIP"
        , "--set"
        , "consoleService.type=ClusterIP"
        , "--set"
        , "resources.requests.memory=512Mi"
        , "--set"
        , "resources.requests.cpu=100m"
        , "--set"
        , "resources.limits.memory=2Gi"
        ]
   in coreArgs ++ minioSubstratePersistenceArgs substrate

-- | Substrate-specific MinIO persistence args. See
-- 'renderMinioChartArgs' for the rationale.
minioSubstratePersistenceArgs :: Substrate -> [String]
minioSubstratePersistenceArgs substrate =
  case substrate of
    SubstrateHomeLocal ->
      [ "--set"
      , "persistence.existingClaim=minio"
      , "--set"
      , "persistence.size=200Gi"
      ]
    SubstrateAws ->
      [ "--set"
      , "persistence.storageClass=gp2"
      , "--set"
      , "persistence.size=20Gi"
      ]

minioChartImages :: MinioImageSource -> (ContainerImage.ImageRef, ContainerImage.ImageRef)
minioChartImages imageSource =
  case imageSource of
    MinioBootstrapPublic ->
      (ContainerImage.publicMinioImage, ContainerImage.publicMinioMcImage)
    MinioSteadyStateHarbor ->
      (ContainerImage.harborMinioImage, ContainerImage.harborMinioMcImage)

ensureHarborRegistryStorageBackend :: FilePath -> IO ExitCode
ensureHarborRegistryStorageBackend repoRoot = do
  credentialsResult <- readMinioRootCredentials repoRoot
  case credentialsResult of
    Left err -> failWith err
    Right (accessKey, secretKey) ->
      runSequentially
        [ runCommand
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments =
                  [ "delete"
                  , "job"
                  , harborRegistryStorageBootstrapJobName
                  , "-n"
                  , minioNamespace
                  , "--ignore-not-found=true"
                  , "--wait=true"
                  ]
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
              , subprocessArguments =
                  [ "wait"
                  , "--for=condition=complete"
                  , "job/" ++ harborRegistryStorageBootstrapJobName
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
                  , harborRegistryStorageBootstrapJobName
                  , "-n"
                  , minioNamespace
                  , "--ignore-not-found=true"
                  , "--wait=true"
                  ]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
        ]

-- | Sprint 2.19: idempotently bootstrap the gateway daemon's MinIO
-- surface in one unified pass:
--
--   1. Create the @gateway@ namespace if absent.
--   2. Read existing 'gateway-minio-creds' Secret if any (extracting
--      the @prodbox-gateway-...@ username + password from its
--      @minio.dhall@ Dhall fragment); otherwise generate fresh
--      credentials.
--   3. Write/overwrite the 'gateway-minio-creds' Secret with the
--      resolved credentials so the gateway chart's
--      @secret-minio-creds.yaml@ template finds it via Helm @lookup@
--      and the daemon Pod mounts the canonical Dhall fragment.
--   4. Apply a Job in the @minio@ namespace that uses the cluster
--      MinIO root Secret to: create the @prodbox@ bucket
--      (idempotent), create or update the @prodbox-gateway-...@ user
--      with the resolved password, create or update the
--      @prodbox-gateway-policy@ IAM policy granting
--      @s3:GetObject@/@s3:PutObject@ on @prodbox/*@ and
--      @s3:ListBucket@ on @prodbox@, and attach the policy to the
--      user.
--
-- Idempotent across reconciles: the existing credentials are reused;
-- @mc admin user add@ silently overwrites the password if it differs
-- (ensuring MinIO state matches the Secret); @mc admin policy create@
-- + @attach@ are tolerant of pre-existing state via @|| true@.
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
      -- Step 2: resolve gateway-minio credentials (read existing or
      -- generate fresh).
      credsResult <- resolveGatewayMinioCredentials repoRoot
      case credsResult of
        Left err -> failWith err
        Right (gwUser, gwPass) -> do
          -- Step 3: write/overwrite gateway-minio-creds Secret.
          secretExit <- writeGatewayMinioCredsSecret repoRoot gwUser gwPass
          case secretExit of
            ExitFailure _ -> pure secretExit
            ExitSuccess ->
              -- Step 4: apply MinIO bootstrap Job (bucket + user + policy + attach).
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
                    (gatewayMinioBootstrapManifestItems gwUser gwPass)
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

-- | Sprint 2.19: resolve the gateway-minio credentials, preferring
-- existing values in the 'gateway-minio-creds' Secret. The Secret
-- carries credentials as a Dhall fragment under the @minio.dhall@
-- key — we extract the username and password by scanning for the
-- @minio_access_key = "..."@ and @minio_secret_key = "..."@ literal
-- lines (the Dhall content is small and operator-controlled, so a
-- token-boundary parse is sufficient). When the Secret is absent,
-- generate fresh credentials by reading from @/dev/urandom@.
resolveGatewayMinioCredentials :: FilePath -> IO (Either String (String, String))
resolveGatewayMinioCredentials repoRoot = do
  existingResult <- readGatewayMinioCredsSecret repoRoot
  case existingResult of
    Right (user, password) -> pure (Right (user, password))
    Left _ -> do
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
                ( "failed to read /dev/urandom for gateway-minio credentials: "
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
          pure (Right (gatewayMinioUserPrefix ++ suffixHex, password))
 where
  isAsciiAlphaNumeric c = isAsciiUpper c || isAsciiLower c || isDigit c

-- | Sprint 2.19: read the existing 'gateway-minio-creds' Secret (if
-- any). Returns 'Left' when the Secret is absent or unparseable so
-- 'resolveGatewayMinioCredentials' can fall through to fresh
-- generation.
readGatewayMinioCredsSecret :: FilePath -> IO (Either String (String, String))
readGatewayMinioCredsSecret repoRoot = do
  dhallTextResult <-
    runTextCommand
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "secret"
            , gatewayMinioCredsSecretName
            , "-n"
            , gatewayNamespace
            , "-o"
            , "go-template={{index .data \"minio.dhall\" | base64decode}}"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case dhallTextResult of
    Left err -> Left err
    Right dhallText ->
      case extractMinioCredsFromDhall dhallText of
        Nothing ->
          Left "gateway-minio-creds Dhall content did not contain a minio_access_key/minio_secret_key pair"
        Just creds -> Right creds

-- | Sprint 2.19: extract @(access_key, secret_key)@ from the
-- chart-rendered Dhall fragment shape. The expected shape is
-- @{ minio_access_key = "<user>", minio_secret_key = "<password>" }@;
-- the helper scans on @=@ and quote boundaries.
extractMinioCredsFromDhall :: String -> Maybe (String, String)
extractMinioCredsFromDhall dhallText =
  let lns = lines dhallText
      extractFor needle =
        listToMaybeFirst
          [ scanQuoted rest
          | line <- lns
          , Just rest <- [stripPrefix needle (dropWhile (`elem` (" ,{" :: String)) line)]
          ]
      access = extractFor "minio_access_key = "
      secret = extractFor "minio_secret_key = "
   in (,) <$> access <*> secret
 where
  scanQuoted :: String -> String
  scanQuoted s = case dropWhile (/= '"') s of
    '"' : rest -> takeWhile (/= '"') rest
    _ -> ""
  listToMaybeFirst :: [String] -> Maybe String
  listToMaybeFirst [] = Nothing
  listToMaybeFirst (x : _) = if null x then Nothing else Just x

-- | Sprint 2.19: write/overwrite the 'gateway-minio-creds' Secret in
-- the gateway namespace with the canonical Dhall fragment shape. Uses
-- the @kubectl create secret --dry-run | apply@ idiom so the Secret
-- is created on first reconcile and updated on subsequent reconciles.
--
-- Sprint 2.19 closure (2026-05-29): also stamps
-- @helm.sh/resource-policy: keep@ so a subsequent
-- @prodbox charts delete gateway@ (the suite bootstrap's helm
-- uninstall) does NOT delete this Secret. Together with the chart-side
-- consume-only template (no @randAlphaNum@), this makes
-- 'ensureGatewayMinioBootstrap' the single source of truth for the
-- gateway MinIO credentials: the Secret persists across
-- @charts delete gateway@ + @charts deploy gateway@ cycles, so the
-- daemon's mounted credentials always match the user that the
-- bootstrap Job registered in MinIO (closing the master-seed 403
-- multi-writer credential divergence diagnosed live on 2026-05-29).
-- @kubectl annotate --overwrite@ is idempotent.
writeGatewayMinioCredsSecret :: FilePath -> String -> String -> IO ExitCode
writeGatewayMinioCredsSecret repoRoot gwUser gwPass = do
  let dhallContent =
        "{ minio_access_key = "
          ++ show gwUser
          ++ "\n, minio_secret_key = "
          ++ show gwPass
          ++ "\n}\n"
  runCommand
    Subprocess
      { subprocessPath = "sh"
      , subprocessArguments =
          [ "-c"
          , "kubectl create secret generic "
              ++ gatewayMinioCredsSecretName
              ++ " --from-literal=minio.dhall="
              ++ shellQuote dhallContent
              ++ " -n "
              ++ gatewayNamespace
              ++ " --dry-run=client -o yaml | kubectl apply -f - && "
              ++ "kubectl annotate secret "
              ++ gatewayMinioCredsSecretName
              ++ " -n "
              ++ gatewayNamespace
              ++ " helm.sh/resource-policy=keep --overwrite"
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

-- | Shell-quote a string for safe inclusion inside a single-quoted
-- shell argument. Replaces every internal single quote with the
-- @'\\''@ escape sequence.
shellQuote :: String -> String
shellQuote s = "'" ++ concatMap escape s ++ "'"
 where
  escape '\'' = "'\\''"
  escape c = [c]

-- | Sprint 2.19: Job manifest that bootstraps the gateway daemon's
-- MinIO surface (@prodbox@ bucket + @prodbox-gateway-...@ user + IAM
-- policy + policy attachment) in one pass.
gatewayMinioBootstrapManifestItems :: String -> String -> [Value]
gatewayMinioBootstrapManifestItems gwUser gwPass =
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
                        , "containers"
                            .= [ object
                                   [ "name" .= ("gateway-minio-bootstrap" :: String)
                                   , "image" .= ContainerImage.renderImageRef ContainerImage.publicMinioMcImage
                                   , "command" .= ["sh" :: String, "-c"]
                                   , "args"
                                       .= [ unlines
                                              [ "set -eu"
                                              , "mc alias set local "
                                                  ++ minioClusterEndpoint
                                                  ++ " \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\""
                                              , "mc mb --ignore-existing local/" ++ gatewayMinioBucket
                                              , "mc admin user add local \"$GW_USER\" \"$GW_PASS\""
                                              , "cat > /tmp/policy.json <<'POLICY_EOF'"
                                              , gatewayMinioPolicyJson
                                              , "POLICY_EOF"
                                              , "mc admin policy create local "
                                                  ++ gatewayMinioPolicyName
                                                  ++ " /tmp/policy.json || mc admin policy add local "
                                                  ++ gatewayMinioPolicyName
                                                  ++ " /tmp/policy.json || true"
                                              , "mc admin policy attach local "
                                                  ++ gatewayMinioPolicyName
                                                  ++ " --user \"$GW_USER\" || mc admin policy set local "
                                                  ++ gatewayMinioPolicyName
                                                  ++ " user=\"$GW_USER\""
                                              ]
                                          ]
                                   , "env"
                                       .= [ object
                                              [ "name" .= ("MINIO_ROOT_USER" :: String)
                                              , "valueFrom"
                                                  .= object
                                                    [ "secretKeyRef"
                                                        .= object
                                                          [ "name" .= minioReleaseName
                                                          , "key" .= ("rootUser" :: String)
                                                          ]
                                                    ]
                                              ]
                                          , object
                                              [ "name" .= ("MINIO_ROOT_PASSWORD" :: String)
                                              , "valueFrom"
                                                  .= object
                                                    [ "secretKeyRef"
                                                        .= object
                                                          [ "name" .= minioReleaseName
                                                          , "key" .= ("rootPassword" :: String)
                                                          ]
                                                    ]
                                              ]
                                          , object
                                              [ "name" .= ("GW_USER" :: String)
                                              , "value" .= gwUser
                                              ]
                                          , object
                                              [ "name" .= ("GW_PASS" :: String)
                                              , "value" .= gwPass
                                              ]
                                          ]
                                   ]
                               ]
                        ]
                  ]
            ]
      ]
  ]

-- | Sprint 2.19: canonical IAM policy granting the @prodbox-gateway@
-- principal the minimum permissions needed for master-seed
-- read/write: @s3:GetObject@/@s3:PutObject@ on @prodbox/*@ plus
-- @s3:ListBucket@ on @prodbox@.
gatewayMinioPolicyJson :: String
gatewayMinioPolicyJson =
  unlines
    [ "{"
    , "  \"Version\": \"2012-10-17\","
    , "  \"Statement\": ["
    , "    {"
    , "      \"Effect\": \"Allow\","
    , "      \"Action\": [\"s3:GetObject\", \"s3:PutObject\"],"
    , "      \"Resource\": [\"arn:aws:s3:::" ++ gatewayMinioBucket ++ "/*\"]"
    , "    },"
    , "    {"
    , "      \"Effect\": \"Allow\","
    , "      \"Action\": [\"s3:ListBucket\"],"
    , "      \"Resource\": [\"arn:aws:s3:::" ++ gatewayMinioBucket ++ "\"]"
    , "    }"
    , "  ]"
    , "}"
    ]

readMinioRootCredentials :: FilePath -> IO (Either String (String, String))
readMinioRootCredentials repoRoot = do
  accessKeyResult <-
    runTextCommand
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "secret"
            , minioReleaseName
            , "-n"
            , minioNamespace
            , "-o"
            , "go-template={{index .data \"rootUser\" | base64decode}}"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  secretKeyResult <-
    runTextCommand
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "secret"
            , minioReleaseName
            , "-n"
            , minioNamespace
            , "-o"
            , "go-template={{index .data \"rootPassword\" | base64decode}}"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ do
    accessKey <- accessKeyResult
    secretKey <- secretKeyResult
    let trimmedAccessKey = trimWhitespace accessKey
        trimmedSecretKey = trimWhitespace secretKey
    if trimmedAccessKey == ""
      then Left "MinIO rootUser secret field is empty"
      else
        if trimmedSecretKey == ""
          then Left "MinIO rootPassword secret field is empty"
          else Right (trimmedAccessKey, trimmedSecretKey)

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
            , "ttlSecondsAfterFinished" .= (60 :: Int)
            , "template"
                .= object
                  [ "spec"
                      .= object
                        [ "restartPolicy" .= ("OnFailure" :: String)
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
                                              ]
                                          ]
                                   , "env"
                                       .= [ object
                                              [ "name" .= ("MINIO_ROOT_USER" :: String)
                                              , "valueFrom"
                                                  .= object
                                                    [ "secretKeyRef"
                                                        .= object
                                                          [ "name" .= minioReleaseName
                                                          , "key" .= ("rootUser" :: String)
                                                          ]
                                                    ]
                                              ]
                                          , object
                                              [ "name" .= ("MINIO_ROOT_PASSWORD" :: String)
                                              , "valueFrom"
                                                  .= object
                                                    [ "secretKeyRef"
                                                        .= object
                                                          [ "name" .= minioReleaseName
                                                          , "key" .= ("rootPassword" :: String)
                                                          ]
                                                    ]
                                              ]
                                          ]
                                   ]
                               ]
                        ]
                  ]
            ]
      ]
  ]

ensureHarborRegistryRuntime :: FilePath -> Substrate -> IO ExitCode
ensureHarborRegistryRuntime repoRoot substrate = do
  repoAddResult <-
    captureToolOutput repoRoot "helm" ["repo", "add", harborRepositoryName, harborRepositoryUrl]
  case repoAddResult of
    Left err -> failWith err
    Right repoAddOutput ->
      case processExitCode repoAddOutput of
        ExitFailure _
          | "already exists" `isInfixOf` map toLower (outputDetail repoAddOutput) -> continue
          | otherwise -> failWith ("Failed to add Harbor helm repo: " ++ outputDetail repoAddOutput)
        ExitSuccess -> continue
 where
  continue = do
    installExit <-
      runSequentially
        [ runHelmCommandWithRetries repoRoot ["repo", "update"]
        , runHelmCommandWithRetries
            repoRoot
            [ "upgrade"
            , "--install"
            , harborReleaseName
            , harborRepositoryName ++ "/harbor"
            , "--namespace"
            , harborNamespace
            , "--create-namespace"
            , "--set"
            , "expose.type=nodePort"
            , "--set"
            , "expose.tls.enabled=false"
            , "--set"
            , "expose.nodePort.ports.http.nodePort=30080"
            , "--set"
            , "externalURL=http://" ++ harborRegistryEndpoint
            , "--set"
            , "harborAdminPassword=Harbor12345"
            , "--set"
            , "persistence.enabled=false"
            , "--set"
            , "persistence.imageChartStorage.type=s3"
            , "--set"
            , "persistence.imageChartStorage.disableredirect=true"
            , "--set"
            , "persistence.imageChartStorage.s3.region=us-east-1"
            , "--set"
            , "persistence.imageChartStorage.s3.bucket=" ++ harborRegistryStorageBucket
            , "--set"
            , "persistence.imageChartStorage.s3.regionendpoint=" ++ minioClusterEndpoint
            , "--set"
            , "persistence.imageChartStorage.s3.existingSecret=" ++ harborRegistryStorageSecretName
            , "--set"
            , "persistence.imageChartStorage.s3.secure=false"
            , "--set"
            , "persistence.imageChartStorage.s3.v4auth=true"
            ]
        ]
    case installExit of
      ExitFailure _ -> pure installExit
      ExitSuccess -> do
        readinessExit <- ensureHarborNginxReadinessContract repoRoot
        case readinessExit of
          ExitFailure _ -> pure readinessExit
          ExitSuccess -> do
            waitExit <-
              runSequentially
                [ waitForDeployment repoRoot harborNamespace (harborComponentName harborReleaseName component)
                | component <- ["core", "registry", "nginx"]
                ]
            case waitExit of
              ExitFailure _ -> pure waitExit
              ExitSuccess -> do
                harborEndpointExit <-
                  runSequentially
                    [ waitForHarborReadyEndpoint repoRoot
                    , waitForHarborRegistryEndpoint repoRoot
                    , waitForHarborStableEndpoints repoRoot
                    ]
                case harborEndpointExit of
                  ExitFailure _ -> pure harborEndpointExit
                  ExitSuccess -> ensureHarborProjectsForSubstrate substrate repoRoot

-- | Harbor project bootstrap tail. On the home substrate the operator
-- host's Docker daemon authenticates to the in-cluster Harbor NodePort
-- (so subsequent host-side @docker push@ steps in the image-mirror loop
-- can publish images) and the bootstrap projects are created via the
-- Harbor REST API. On the AWS substrate the operator host has no
-- network path into the EKS-side Harbor NodePort, so the docker-login
-- step is skipped; the in-cluster image-mirror Job from Sprint
-- @7.5.c.iv@ replaces the host-Docker path. Bootstrap-project
-- creation also runs in-cluster on AWS: a one-shot pod in the
-- @harbor@ namespace POSTs to @http:\/\/harbor.harbor.svc.cluster.local
-- \/api\/v2.0\/projects@ since the operator-host @127.0.0.1:30080@
-- endpoint @ensureHarborProject@ uses on the home substrate only
-- resolves to Harbor on RKE2.
ensureHarborProjectsForSubstrate :: Substrate -> FilePath -> IO ExitCode
ensureHarborProjectsForSubstrate substrate repoRoot =
  case substrate of
    SubstrateHomeLocal -> do
      loginExit <- ensureHarborDockerLogin repoRoot
      case loginExit of
        ExitFailure _ -> pure loginExit
        ExitSuccess -> createHarborProjectsHomeLocal repoRoot
    SubstrateAws -> createHarborProjectsAws repoRoot

createHarborProjectsHomeLocal :: FilePath -> IO ExitCode
createHarborProjectsHomeLocal repoRoot =
  runSequentially
    [ ensureHarborProject repoRoot projectName
    | projectName <- nub harborBootstrapProjects
    ]

-- | On the AWS substrate the operator host cannot reach Harbor at
-- @127.0.0.1:30080@. Exec into the already-running Harbor core pod
-- and call Harbor's in-cluster DNS endpoint, avoiding a pre-mirror
-- bootstrap dependency on any additional pod image.
createHarborProjectsAws :: FilePath -> IO ExitCode
createHarborProjectsAws repoRoot = do
  let projects = nub harborBootstrapProjects
      podNamespace = harborNamespace
      script =
        "set -eu\n"
          ++ concatMap
            ( \p ->
                "echo \"prodbox-harbor-projects: creating "
                  ++ p
                  ++ "\"\n"
                  ++ "code=$(curl -sS -u admin:Harbor12345 -H 'Content-Type: application/json' -X POST "
                  ++ "-d '{\"project_name\":\""
                  ++ p
                  ++ "\",\"public\":true}' "
                  ++ "-o /dev/null -w '%{http_code}' "
                  ++ "http://harbor.harbor.svc.cluster.local/api/v2.0/projects)\n"
                  ++ "case \"$code\" in 201|409) echo \"  HTTP $code (ok)\" ;; *) echo \"  HTTP $code (FAIL)\"; exit 1 ;; esac\n"
            )
            projects
  runCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "exec"
          , "-n"
          , podNamespace
          , "deployment/" ++ harborComponentName harborReleaseName "core"
          , "--"
          , "sh"
          , "-c"
          , script
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

harborBootstrapProjects :: [String]
harborBootstrapProjects =
  [harborMirrorProject, harborProjectFromRepository harborGatewayRepository]

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

waitForHarborReadyEndpoint :: FilePath -> IO ExitCode
waitForHarborReadyEndpoint repoRoot =
  waitForHarborHttpStatus repoRoot harborReadyPath ["200"] "Harbor nginx readiness endpoint"

waitForHarborRegistryEndpoint :: FilePath -> IO ExitCode
waitForHarborRegistryEndpoint repoRoot =
  waitForHarborHttpStatus repoRoot "/v2/" ["200", "401"] "Harbor registry endpoint"

waitForHarborStableEndpoints :: FilePath -> IO ExitCode
waitForHarborStableEndpoints repoRoot =
  go harborEndpointStabilityAttempts 0 "Harbor endpoints not yet checked"
 where
  go :: Int -> Int -> String -> IO ExitCode
  go attemptsRemaining consecutiveSuccesses lastDetail
    | consecutiveSuccesses >= harborEndpointStabilitySuccesses = pure ExitSuccess
    | attemptsRemaining <= 0 =
        failWith
          ( "Failed to observe stable Harbor endpoints before continuing: "
              ++ lastDetail
          )
    | otherwise = do
        readyStatusResult <- probeHarborHttpStatus repoRoot harborReadyPath
        registryStatusResult <- probeHarborHttpStatus repoRoot "/v2/"
        case (readyStatusResult, registryStatusResult) of
          (Right "200", Right registryStatus)
            | registryStatus `elem` ["200", "401"] ->
                let nextSuccesses = consecutiveSuccesses + 1
                 in if nextSuccesses >= harborEndpointStabilitySuccesses
                      then pure ExitSuccess
                      else retry attemptsRemaining nextSuccesses "Harbor endpoints are stable"
          (Left err, _) -> retry attemptsRemaining 0 err
          (_, Left err) -> retry attemptsRemaining 0 err
          (Right readyStatus, Right registryStatus) ->
            retry
              attemptsRemaining
              0
              ( "unexpected Harbor statuses: /readyz="
                  ++ readyStatus
                  ++ ", /v2/="
                  ++ registryStatus
              )

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

ensureHarborNginxReadinessContract :: FilePath -> IO ExitCode
ensureHarborNginxReadinessContract repoRoot = do
  configOutputResult <-
    captureKubectl
      repoRoot
      [ "get"
      , "configmap"
      , harborComponentName harborReleaseName "nginx"
      , "-n"
      , harborNamespace
      , "-o"
      , "jsonpath={.data.nginx\\.conf}"
      ]
  case configOutputResult of
    Left err -> failWith err
    Right configOutput ->
      case processExitCode configOutput of
        ExitFailure _ -> failWith ("Failed to read Harbor nginx ConfigMap: " ++ outputDetail configOutput)
        ExitSuccess ->
          case renderHarborNginxReadyzConfig (processStdout configOutput) of
            Nothing -> failWith "Failed to inject Harbor nginx readiness path into ConfigMap"
            Just patchedConfig -> do
              let configMapManifest =
                    object
                      [ "apiVersion" .= ("v1" :: String)
                      , "kind" .= ("ConfigMap" :: String)
                      , "metadata"
                          .= object
                            [ "name" .= harborComponentName harborReleaseName "nginx"
                            , "namespace" .= harborNamespace
                            ]
                      , "data" .= object ["nginx.conf" .= patchedConfig]
                      ]
                  deploymentPatch =
                    object
                      [ "spec"
                          .= object
                            [ "template"
                                .= object
                                  [ "metadata"
                                      .= object
                                        [ "annotations"
                                            .= object
                                              [ Key.fromString harborReadyAnnotationKey .= harborReadyAnnotationValue
                                              ]
                                        ]
                                  , "spec"
                                      .= object
                                        [ "containers"
                                            .= ( [ object
                                                     [ "name" .= ("nginx" :: String)
                                                     , "readinessProbe"
                                                         .= object
                                                           [ "httpGet"
                                                               .= object
                                                                 [ "path" .= harborReadyPath
                                                                 , "port" .= (8080 :: Int)
                                                                 , "scheme" .= ("HTTP" :: String)
                                                                 ]
                                                           ]
                                                     , "livenessProbe"
                                                         .= object
                                                           [ "httpGet"
                                                               .= object
                                                                 [ "path" .= harborReadyPath
                                                                 , "port" .= (8080 :: Int)
                                                                 , "scheme" .= ("HTTP" :: String)
                                                                 ]
                                                           ]
                                                     ]
                                                 ]
                                                   :: [Value]
                                               )
                                        ]
                                  ]
                            ]
                      ]
              applyExit <-
                withTemporaryJsonBytes "prodbox-harbor-nginx" (encode configMapManifest) $ \manifestPath -> do
                  outputResult <- captureKubectl repoRoot ["apply", "-f", manifestPath]
                  case outputResult of
                    Left err -> failWith err
                    Right applyOutput ->
                      case processExitCode applyOutput of
                        ExitFailure _ -> failWith ("Failed to apply Harbor nginx ConfigMap: " ++ outputDetail applyOutput)
                        ExitSuccess -> pure ExitSuccess
              case applyExit of
                ExitFailure _ -> pure applyExit
                ExitSuccess -> do
                  patchResult <-
                    captureKubectl
                      repoRoot
                      [ "patch"
                      , "deployment"
                      , harborComponentName harborReleaseName "nginx"
                      , "-n"
                      , harborNamespace
                      , "--type"
                      , "strategic"
                      , "--patch"
                      , trimTrailingNewlines (BL8.unpack (encode deploymentPatch))
                      ]
                  case patchResult of
                    Left err -> failWith err
                    Right patchOutput ->
                      case processExitCode patchOutput of
                        ExitFailure _ -> failWith ("Failed to patch Harbor nginx Deployment: " ++ outputDetail patchOutput)
                        ExitSuccess -> pure ExitSuccess

ensureHarborProject :: FilePath -> String -> IO ExitCode
ensureHarborProject repoRoot projectName = do
  let payload = "{\"project_name\":\"" ++ projectName ++ "\",\"public\":true}"
  outputResult <-
    captureToolOutput
      repoRoot
      "curl"
      [ "-sS"
      , "-u"
      , harborAdminUser ++ ":" ++ harborAdminPassword
      , "-H"
      , "Content-Type: application/json"
      , "-X"
      , "POST"
      , "-d"
      , payload
      , "-o"
      , "/dev/null"
      , "-w"
      , "%{http_code}"
      , "http://" ++ harborRegistryEndpoint ++ "/api/v2.0/projects"
      ]
  case outputResult of
    Left err -> failWith err
    Right output ->
      case trimWhitespace (processStdout output) of
        "201" -> pure ExitSuccess
        "409" -> pure ExitSuccess
        statusCode ->
          failWith
            ( "Failed to create Harbor project '"
                ++ projectName
                ++ "': HTTP "
                ++ statusCode
            )

ensureClusterPlatformRuntime :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureClusterPlatformRuntime repoRoot settings prodboxId labelValue = do
  lanDefaultsResult <- resolveClusterPlatformLanDefaults
  case lanDefaultsResult of
    Left err -> failWith err
    Right (metallbPool, edgeLbIp) ->
      runSequentially
        [ ensureMetalLbRuntime repoRoot settings prodboxId labelValue metallbPool
        , ensureEnvoyGatewayRuntime repoRoot settings prodboxId labelValue edgeLbIp
        , ensureCertManagerRuntime repoRoot prodboxId labelValue
        , ensureAcmeRuntime repoRoot settings prodboxId labelValue
        , ensurePostgresOperatorRuntime repoRoot prodboxId labelValue
        ]

ensureAdminPublicEdgeRoutes
  :: FilePath -> ValidatedSettings -> Substrate -> String -> String -> IO ExitCode
ensureAdminPublicEdgeRoutes repoRoot settings substrate prodboxId labelValue = do
  -- Sprint 3.13 chunks 11 + 12: the OIDC client secrets (vscode / api /
  -- websocket / demo-user) are now master-seed-derived and materialized
  -- by the gateway daemon's `ensure-namespace` handler into the
  -- `keycloak-oidc-clients` Secret in the `keycloak` namespace. The
  -- host-side `resolveChartSecrets` cache is gone; this function reads
  -- `VSCODE_CLIENT_SECRET` (which the harbor / minio admin SecurityPolicies
  -- both reuse) directly from the cluster Secret via @kubectl@.
  clientSecretResult <- readKeycloakVscodeClientSecret repoRoot
  case clientSecretResult of
    Left err -> failWith err
    Right clientSecret ->
      withTemporaryJsonManifest
        "prodbox-admin-public-edge"
        (adminPublicEdgeManifestItems settings substrate prodboxId labelValue clientSecret)
        ( \manifestPath -> do
            outputResult <- captureKubectl repoRoot ["apply", "-f", manifestPath]
            case outputResult of
              Left err -> failWith err
              Right output ->
                case processExitCode output of
                  ExitSuccess -> pure ExitSuccess
                  ExitFailure _ -> failWith ("kubectl apply failed: " ++ outputDetail output)
        )

-- | Host-side derivation of the @VSCODE_CLIENT_SECRET@ from the master
-- seed in MinIO, matching what the gateway daemon writes into the
-- @keycloak-oidc-clients@ Secret. This function is the
-- @ensureAdminPublicEdgeRoutes@ ordering fix: that reconciler runs
-- /during/ platform setup, before any chart deploys, so the
-- @keycloak-oidc-clients@ Secret doesn't exist yet (the keycloak
-- namespace doesn't even exist). The host can still derive the
-- correct value because the master seed is materialized into MinIO
-- by the gateway-minio bootstrap that runs immediately before
-- this function, and 'oidcClientSecretContext' /
-- 'deriveBase64Url' are deterministic over the master seed.
--
-- Returns the URL-safe-base64 string Keycloak will register for the
-- @vscode@ OIDC client, which the harbor and minio admin
-- @SecurityPolicy@'s reuse as their client secret too.
readKeycloakVscodeClientSecret :: FilePath -> IO (Either String String)
readKeycloakVscodeClientSecret repoRoot = do
  overrideResult <- readHostMasterSeedOverride
  case overrideResult of
    Just (Left err) -> pure (Left err)
    Just (Right seed) -> pure (Right (deriveVscodeClientSecret seed))
    Nothing -> do
      credsResult <- resolveGatewayMinioCredentials repoRoot
      case credsResult of
        Left err ->
          pure
            ( Left
                ( "could not resolve gateway-minio credentials for master-seed read: "
                    ++ err
                )
            )
        Right (accessKey, secretKey) -> do
          portForwardResult <- withCurrentMinioPortForward $ \localPort -> do
            let cfg = defaultMinioMasterSeedConfig localPort accessKey secretKey
            ensureMasterSeed cfg
          case portForwardResult of
            Left err ->
              pure
                ( Left
                    ( "could not port-forward to MinIO for master-seed read: "
                        ++ err
                    )
                )
            Right (Left masterSeedErr) ->
              pure
                ( Left
                    ( "master-seed read failed: "
                        ++ renderMasterSeedError masterSeedErr
                    )
                )
            Right (Right seed) -> pure (Right (deriveVscodeClientSecret seed))
 where
  -- Sprint 3.13 chunk 32: the daemon's Inventory uses the deploy-namespace
  -- (`vscode` for the vscode root chart's transitive keycloak dep), so the
  -- host-side derivation must match. Pre-chunk-32 this was hardcoded to
  -- `"keycloak"` and computed a value Keycloak never registered, breaking
  -- the harbor/minio admin SecurityPolicy OIDC handshake.
  deriveVscodeClientSecret seed =
    Text.unpack (deriveBase64Url seed (oidcClientSecretContext "vscode" "vscode"))

-- | Test-only injection seam mirroring 'PRODBOX_TEST_RESIDUE_ABSENT' /
-- 'PRODBOX_TEST_RESIDUE_UNREACHABLE' in 'Prodbox.Lifecycle.LiveResidue':
-- when the env var is set to a 64-character hex string the host-side
-- master-seed read short-circuits to those bytes instead of port-forwarding
-- to MinIO. Production never sets this; the integration test harness in
-- 'fakeRke2Environment' provides a deterministic constant so reconcile
-- tests can exercise 'ensureAdminPublicEdgeRoutes' without a real MinIO.
readHostMasterSeedOverride :: IO (Maybe (Either String MasterSeed))
readHostMasterSeedOverride = do
  maybeHex <- lookupEnv "PRODBOX_TEST_HOST_MASTER_SEED_HEX"
  pure $ case maybeHex of
    Nothing -> Nothing
    Just hex ->
      case decodeHex hex of
        Left err -> Just (Left ("PRODBOX_TEST_HOST_MASTER_SEED_HEX: " ++ err))
        Right bytes ->
          case masterSeed bytes of
            Left err -> Just (Left ("PRODBOX_TEST_HOST_MASTER_SEED_HEX: " ++ err))
            Right seed -> Just (Right seed)

decodeHex :: String -> Either String BS.ByteString
decodeHex input
  | odd (length input) = Left "odd-length hex string"
  | not (all isHexDigit input) = Left "non-hex characters in input"
  | otherwise = Right (BS.pack (parsePairs input))
 where
  parsePairs [] = []
  parsePairs (a : b : rest) = fromIntegral (hexValue a * 16 + hexValue b) : parsePairs rest
  parsePairs _ = []
  hexValue c
    | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
    | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
    | c >= 'A' && c <= 'F' = fromEnum c - fromEnum 'A' + 10
    | otherwise = 0

adminPublicEdgeManifestItems
  :: ValidatedSettings -> Substrate -> String -> String -> String -> [Value]
adminPublicEdgeManifestItems settings substrate prodboxId labelValue clientSecret =
  [ adminOidcClientSecretManifest
      harborNamespace
      harborAdminClientSecretName
      prodboxId
      labelValue
      clientSecret
  , adminHttpRouteManifest
      harborNamespace
      harborAdminRouteName
      harborPathPrefix
      harborServiceName
      harborServicePort
      prodboxId
      labelValue
      (substratePublicFqdn settings substrate)
  , adminSecurityPolicyManifest
      harborNamespace
      harborAdminSecurityPolicyName
      harborAdminRouteName
      harborAdminClientSecretName
      (substratePublicRouteUrl settings substrate PublicRouteHarbor)
      prodboxId
      labelValue
      substrate
      settings
  , adminOidcClientSecretManifest
      minioNamespace
      minioAdminClientSecretName
      prodboxId
      labelValue
      clientSecret
  , adminHttpRouteManifest
      minioNamespace
      minioAdminRouteName
      minioPathPrefix
      minioConsoleServiceName
      minioConsoleServicePort
      prodboxId
      labelValue
      (substratePublicFqdn settings substrate)
  , adminSecurityPolicyManifest
      minioNamespace
      minioAdminSecurityPolicyName
      minioAdminRouteName
      minioAdminClientSecretName
      (substratePublicRouteUrl settings substrate PublicRouteMinio)
      prodboxId
      labelValue
      substrate
      settings
  ]

adminOidcClientSecretManifest :: String -> String -> String -> String -> String -> Value
adminOidcClientSecretManifest namespace secretName prodboxId labelValue clientSecret =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Secret" :: String)
    , "metadata"
        .= object
          [ "name" .= secretName
          , "namespace" .= namespace
          , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
          , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
          ]
    , "type" .= ("Opaque" :: String)
    , "stringData" .= object ["client-secret" .= clientSecret]
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
  -> Substrate
  -> ValidatedSettings
  -> Value
adminSecurityPolicyManifest namespace policyName routeName secretName baseUrl prodboxId labelValue substrate settings =
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
                [ "provider" .= adminOidcProviderManifest settings substrate
                , "clientID" .= keycloakVscodeClientId
                , "clientSecret" .= object ["name" .= secretName]
                , "redirectURL" .= (baseUrl ++ "/oauth2/callback")
                , "logoutPath" .= ("/logout" :: String)
                ]
          ]
    ]

adminOidcProviderManifest :: ValidatedSettings -> Substrate -> Value
adminOidcProviderManifest settings substrate =
  object
    [ "issuer" .= issuer
    , "authorizationEndpoint" .= (issuer ++ "/protocol/openid-connect/auth")
    , "tokenEndpoint" .= sharedKeycloakInternalTokenEndpoint
    ]
 where
  issuer = substrateIdentityIssuerUrl settings substrate

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
        helmUpgradeInstallWithJsonValues
          repoRoot
          metallbReleaseName
          metallbChartRef
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

configuredPublicEdgeAdvertisementMode :: ValidatedSettings -> String
configuredPublicEdgeAdvertisementMode settings =
  case fmap (map toLower . trimWhitespace . Text.unpack) (public_edge_advertisement_mode deploymentSection) of
    Just "bgp" -> "bgp"
    _ -> "l2"
 where
  deploymentSection = deployment (validatedConfig settings)

configuredPublicEdgeBgpPeers :: ValidatedSettings -> [MetallbBgpPeer]
configuredPublicEdgeBgpPeers settings =
  fromMaybe [] (public_edge_bgp_peers (deployment (validatedConfig settings)))

configuredEnvoyGatewayControllerReplicas :: ValidatedSettings -> Int
configuredEnvoyGatewayControllerReplicas settings =
  maybe 1 fromIntegral (envoy_gateway_controller_replicas (deployment (validatedConfig settings)))

configuredEnvoyGatewayDataPlaneReplicas :: ValidatedSettings -> Int
configuredEnvoyGatewayDataPlaneReplicas settings =
  maybe 1 fromIntegral (envoy_gateway_data_plane_replicas (deployment (validatedConfig settings)))

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
ensureAcmeRuntime repoRoot settings prodboxId labelValue = do
  currentEnvironment <- getEnvironment
  withTemporaryJsonManifest
    "prodbox-acme-runtime"
    (acmeRuntimeManifest SubstrateHomeLocal settings prodboxId labelValue)
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
            issuerWaitEnv <- awsCommandEnvironment currentEnvironment settings
            -- Wait for the ZeroSSL ClusterIssuer rendered from the manifest
            -- to become Ready before reporting the ACME runtime up.
            runCommand
              Subprocess
                { subprocessPath = "kubectl"
                , subprocessArguments =
                    [ "wait"
                    , "--for=condition=Ready"
                    , "clusterissuer/" ++ publicEdgeClusterIssuerName
                    , "--timeout=300s"
                    ]
                , subprocessEnvironment = Just issuerWaitEnv
                , subprocessWorkingDirectory = Just repoRoot
                }
    )

acmeRuntimeManifest :: Substrate -> ValidatedSettings -> String -> String -> [Value]
acmeRuntimeManifest substrate settings =
  acmeRuntimeManifestWith substrate settings (substrateHostedZoneId settings substrate)

-- | Sprint 7.5.c.v follow-up: variant of 'acmeRuntimeManifest' that takes
-- an externally-resolved hosted-zone ID so the IO caller can fall back to
-- the live aws-eks-subzone Pulumi stack snapshot when
-- @aws_substrate.hosted_zone_id@ is empty in @prodbox-config.dhall@. See
-- 'Prodbox.PublicEdge.resolveSubstrateHostedZoneId' for the doctrine-
-- compliant resolution algorithm.
acmeRuntimeManifestWith
  :: Substrate -> ValidatedSettings -> Text.Text -> String -> String -> [Value]
acmeRuntimeManifestWith _substrate settings hostedZoneId prodboxId labelValue =
  route53Secret
    : maybe [] pure maybeEabSecret
    ++ [clusterIssuer]
 where
  config = validatedConfig settings
  route53Secret =
    object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("Secret" :: String)
      , "metadata"
          .= object
            [ "name" .= route53CredentialsSecretName
            , "namespace" .= certManagerNamespace
            , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "type" .= ("Opaque" :: String)
      , "stringData"
          .= object
            [ "access-key-id" .= Text.unpack (access_key_id (aws config))
            , "secret-access-key" .= Text.unpack (secret_access_key (aws config))
            ]
      ]
  maybeEabSecret =
    case (eab_key_id (acme config), eab_hmac_key (acme config)) of
      (Just _, Just hmacKey) ->
        Just
          ( object
              [ "apiVersion" .= ("v1" :: String)
              , "kind" .= ("Secret" :: String)
              , "metadata"
                  .= object
                    [ "name" .= acmeEabSecretName
                    , "namespace" .= certManagerNamespace
                    , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
                    , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
                    ]
              , "type" .= ("Opaque" :: String)
              , "stringData" .= object [Key.fromString acmeEabSecretKey .= Text.unpack hmacKey]
              ]
          )
      _ -> Nothing
  clusterIssuer =
    clusterIssuerResource publicEdgeClusterIssuerName (acmeClusterIssuerSpec settings hostedZoneId)
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

-- | The ZeroSSL ACME @ClusterIssuer@ @spec.acme@ object: the
-- @acme.server@ directory, the ZeroSSL account key, the DNS-01 Route 53
-- solver, and the required ZeroSSL external account binding.
acmeClusterIssuerSpec :: ValidatedSettings -> Text.Text -> Value
acmeClusterIssuerSpec settings hostedZoneId =
  object $
    [ "server" .= Text.unpack (server acmeConfig)
    , "email" .= Text.unpack (email acmeConfig)
    , "privateKeySecretRef" .= object ["name" .= zerosslAccountKeySecretName]
    , "solvers" .= [acmeRoute53Solver (region awsConfig) hostedZoneId]
    ]
      ++ maybe [] (\binding -> ["externalAccountBinding" .= binding]) externalAccountBinding
 where
  config = validatedConfig settings
  awsConfig = aws config
  acmeConfig = acme config
  externalAccountBinding =
    case (eab_key_id acmeConfig, eab_hmac_key acmeConfig) of
      (Just keyId, Just _) ->
        Just
          ( object
              [ "keyID" .= Text.unpack keyId
              , "keySecretRef"
                  .= object
                    [ "name" .= acmeEabSecretName
                    , "key" .= acmeEabSecretKey
                    ]
              ]
          )
      _ -> Nothing

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

reconcileDnsBootstrapRecord :: FilePath -> ValidatedSettings -> IO ExitCode
reconcileDnsBootstrapRecord repoRoot settings =
  if not (pulumi_enable_dns_bootstrap (deployment (validatedConfig settings)))
    then pure ExitSuccess
    else do
      publicIpResult <- resolveDnsBootstrapIp settings
      case publicIpResult of
        Left err -> failWith err
        Right publicIp -> do
          environment <- getEnvironment
          awsEnvironment <- awsCommandEnvironment environment settings
          let config = validatedConfig settings
              zoneIdValue = Text.unpack (zone_id (route53 config))
              ttlValue = fromIntegral (demo_ttl (domain config)) :: Integer
              fqdnValues = Dns.configuredPublicHostFqdns settings
          foldM
            (reconcileDnsBootstrapFqdn repoRoot awsEnvironment zoneIdValue ttlValue publicIp)
            ExitSuccess
            fqdnValues

reconcileDnsBootstrapFqdn
  :: FilePath
  -> [(String, String)]
  -> String
  -> Integer
  -> String
  -> ExitCode
  -> String
  -> IO ExitCode
reconcileDnsBootstrapFqdn repoRoot awsEnvironment zoneIdValue ttlValue publicIp exitCode fqdn =
  case exitCode of
    ExitFailure _ -> pure exitCode
    ExitSuccess ->
      withTemporaryJsonBytes
        "prodbox-dns-bootstrap"
        (encode (route53AChangeBatch "UPSERT" fqdn publicIp ttlValue))
        ( \payloadPath ->
            runAwsRoute53ChangeWithRetries
              repoRoot
              awsEnvironment
              [ "route53"
              , "change-resource-record-sets"
              , "--hosted-zone-id"
              , zoneIdValue
              , "--change-batch"
              , "file://" ++ payloadPath
              ]
        )

runAwsRoute53ChangeWithRetries :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runAwsRoute53ChangeWithRetries repoRoot awsEnvironment arguments =
  go (retryPolicyMaxAttempts route53CredentialPropagationRetryPolicy)
 where
  go attemptsRemaining = do
    outputResult <-
      captureSubprocessResult
        Subprocess
          { subprocessPath = "aws"
          , subprocessArguments = arguments
          , subprocessEnvironment = Just awsEnvironment
          , subprocessWorkingDirectory = Just repoRoot
          }
    case outputResult of
      Failure err -> failWith ("failed to start aws: " ++ err)
      Success output ->
        case processExitCode output of
          ExitSuccess -> do
            emitCapturedProcessOutput output
            pure ExitSuccess
          failure@(ExitFailure _)
            | attemptsRemaining > 1 && isRetryableRoute53CredentialFailure output -> do
                writeDiagnosticLine
                  ( "Retrying aws "
                      ++ unwords arguments
                      ++ " after AWS credential propagation failure ("
                      ++ show (retryPolicyMaxAttempts route53CredentialPropagationRetryPolicy - attemptsRemaining + 1)
                      ++ "/"
                      ++ show (retryPolicyMaxAttempts route53CredentialPropagationRetryPolicy)
                      ++ "): "
                      ++ outputDetail output
                  )
                threadDelay
                  ( retryDelayMicros
                      route53CredentialPropagationRetryPolicy
                      (retryPolicyMaxAttempts route53CredentialPropagationRetryPolicy - attemptsRemaining)
                  )
                go (attemptsRemaining - 1)
            | otherwise -> do
                emitCapturedProcessOutput output
                pure failure

isRetryableRoute53CredentialFailure :: ProcessOutput -> Bool
isRetryableRoute53CredentialFailure output =
  let detail = map toLower (outputDetail output)
   in any
        (`isInfixOf` detail)
        [ "invalidclienttokenid"
        , "security token included in the request is invalid"
        , "unrecognizedclientexception"
        , "accessdenied"
        , "not authorized to perform: route53:"
        ]

resolveDnsBootstrapIp :: ValidatedSettings -> IO (Either String String)
resolveDnsBootstrapIp settings = do
  maybeBootstrapIp <- lookupNonEmptyEnv "PRODBOX_PULUMI_DNS_BOOTSTRAP_IP"
  case maybeBootstrapIp of
    Just value -> pure (Right value)
    Nothing ->
      case nonEmptyTextValue =<< bootstrap_public_ip_override (deployment (validatedConfig settings)) of
        Just value -> pure (Right value)
        Nothing -> fetchPublicIp

route53AChangeBatch :: String -> String -> String -> Integer -> Value
route53AChangeBatch action fqdn publicIp ttlValue =
  object
    [ "Comment" .= ("prodbox bootstrap DNS reconcile" :: String)
    , "Changes"
        .= [ object
               [ "Action" .= action
               , "ResourceRecordSet"
                   .= object
                     [ "Name" .= fqdn
                     , "Type" .= ("A" :: String)
                     , "TTL" .= ttlValue
                     , "ResourceRecords" .= [object ["Value" .= publicIp]]
                     ]
               ]
           ]
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
  withTemporaryJsonBytes ("prodbox-helm-values-" ++ releaseName) (encode values) $ \valuesPath ->
    runHelmCommandWithRetries
      repoRoot
      [ "upgrade"
      , "--install"
      , releaseName
      , chartRef
      , "--version"
      , chartVersion
      , "--namespace"
      , namespace
      , "--create-namespace"
      , "-f"
      , valuesPath
      ]

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
                  ( retryDelayMicros
                      helmTransientRetryPolicy
                      (retryPolicyMaxAttempts helmTransientRetryPolicy - attemptsRemaining)
                  )
                go (attemptsRemaining - 1)
            | otherwise -> do
                emitCapturedProcessOutput output
                pure failure

isRetryableHelmFailure :: ProcessOutput -> Bool
isRetryableHelmFailure output =
  let detail = map toLower (outputDetail output)
   in any
        (`isInfixOf` detail)
        [ "502 bad gateway"
        , "503 service unavailable"
        , "504 gateway timeout"
        , "429 too many requests"
        , "failed to fetch"
        , "failed to download"
        , "connection reset by peer"
        , "tls handshake timeout"
        , "i/o timeout"
        , "context deadline exceeded"
        , "temporary failure"
        ]

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

awsCommandEnvironment :: [(String, String)] -> ValidatedSettings -> IO [(String, String)]
awsCommandEnvironment baseEnvironment settings =
  pure (overlayAwsCredentials baseEnvironment (aws (validatedConfig settings)))

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

nonEmptyTextValue :: Text.Text -> Maybe String
nonEmptyTextValue rawValue =
  let trimmed = trimWhitespace (Text.unpack rawValue)
   in if trimmed == ""
        then Nothing
        else Just trimmed

mirrorClusterImagesOnce :: FilePath -> IO ExitCode
mirrorClusterImagesOnce repoRoot = do
  imagesResult <- collectClusterImages repoRoot
  case imagesResult of
    Left err -> failWith err
    Right images ->
      let requiredPairs = ContainerImage.requiredPublicImageCandidatePairs
          discoveredPairs =
            [ (sources, target)
            | image <- images
            , Just source <- [ContainerImage.normalizeImageRefText image]
            , not (isHarborBootstrapImage source)
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

ensureGatewayImages :: FilePath -> String -> IO ExitCode
ensureGatewayImages = ensureGatewayImagesForSubstrate SubstrateHomeLocal

ensurePublicEdgeWorkloadImage :: FilePath -> String -> IO ExitCode
ensurePublicEdgeWorkloadImage = ensurePublicEdgeWorkloadImageForSubstrate SubstrateHomeLocal

-- | Sprint 7.5.c.v.b — substrate-aware gateway image publication.
ensureGatewayImagesForSubstrate :: Substrate -> FilePath -> String -> IO ExitCode
ensureGatewayImagesForSubstrate substrate repoRoot prodboxId = do
  let gatewayTag = prodboxIdToLabelValue prodboxId
      gatewayImage = ContainerImage.harborGatewayImageRepository ++ ":" ++ gatewayTag
      latestImage = ContainerImage.harborGatewayImageRepository ++ ":latest"
  ensureCustomImageVariantsForSubstrate
    substrate
    repoRoot
    CustomImageBuildPlan
      { customImageDockerfile = "docker/gateway.Dockerfile"
      }
    [gatewayImage, latestImage]
    gatewayImage

-- | Sprint 7.5.c.v.b — substrate-aware public-edge workload image
-- publication.
ensurePublicEdgeWorkloadImageForSubstrate :: Substrate -> FilePath -> String -> IO ExitCode
ensurePublicEdgeWorkloadImageForSubstrate substrate repoRoot prodboxId = do
  let workloadTag = prodboxIdToLabelValue prodboxId
      workloadImage = ContainerImage.harborPublicEdgeWorkloadImageRepository ++ ":" ++ workloadTag
      latestImage = ContainerImage.harborPublicEdgeWorkloadImageRepository ++ ":latest"
  ensureCustomImageVariantsForSubstrate
    substrate
    repoRoot
    CustomImageBuildPlan
      { customImageDockerfile = "docker/prodbox.Dockerfile"
      }
    [workloadImage, latestImage]
    workloadImage

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
ensureCustomImageVariantsHomeLocal repoRoot imageBuildPlan taggedRefs importRef = do
  loginExit <- ensureHarborDockerLogin repoRoot
  case loginExit of
    ExitFailure _ -> pure loginExit
    ExitSuccess -> do
      buildExit <- buildAndPushCustomImageVariants repoRoot imageBuildPlan taggedRefs
      case buildExit of
        ExitFailure _ -> pure buildExit
        ExitSuccess ->
          runSequentially
            [ runCommand
                Subprocess
                  { subprocessPath = "docker"
                  , subprocessArguments = ["pull", importRef]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            , importImageIntoRke2Containerd repoRoot importRef
            ]

-- | AWS-substrate custom-image publication path. Builds the image on
-- the operator host via @docker build@ (which is available locally),
-- @docker save@'s the image to a tarball, then publishes via an
-- authenticated in-cluster crane pod. The @ctr@ import step is intentionally
-- omitted — EKS nodes pull from in-cluster Harbor via the
-- containerd registry-mirror DaemonSet.
ensureCustomImageVariantsAws
  :: FilePath -> CustomImageBuildPlan -> [String] -> IO ExitCode
ensureCustomImageVariantsAws repoRoot imageBuildPlan taggedRefs =
  case taggedRefs of
    [] -> pure ExitSuccess
    (primaryRef : _) -> do
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
-- chart-platform tmp dir, @kubectl cp@ the tarball into the pod,
-- @kubectl exec@ @crane auth login@, @kubectl exec@
-- @crane push --insecure@ once per requested tag,
-- then delete the pod.
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
  saveExit <-
    runCommand
      Subprocess
        { subprocessPath = "docker"
        , subprocessArguments = ["save", "-o", tarPath, primaryRef]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
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
                  ExitSuccess -> do
                    authExit <- authenticateCranePodToHarbor cfg podNs podNm repoRoot
                    case authExit of
                      ExitFailure _ -> do
                        _ <- deleteCranePushPod podNs podNm repoRoot
                        pure authExit
                      ExitSuccess -> do
                        pushExits <-
                          mapM
                            (pushOneRefViaCranePod cfg podNs podNm podPath repoRoot)
                            taggedRefs
                        _ <- deleteCranePushPod podNs podNm repoRoot
                        pure $ firstNonSuccess pushExits

authenticateCranePodToHarbor
  :: EksCustomImagePushConfig -> String -> String -> FilePath -> IO ExitCode
authenticateCranePodToHarbor cfg podNs podNm repoRoot = do
  writeOutputLine
    ( "  crane auth login "
        ++ customPushHarborInternalEndpoint cfg
        ++ " --username "
        ++ customPushHarborAdminUser cfg
        ++ " --password <redacted>"
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
          ]
            ++ [ "/busybox/sh"
               , "-c"
               , "/ko-app/crane auth login \"${HARBOR_INTERNAL}\" --username \"${HARBOR_USER}\" --password \"${HARBOR_PASSWORD}\""
               ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

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
            [ pushDockerImageWithRetry repoRoot tagRef ("custom image " ++ tagRef)
            | tagRef <- taggedRefs
            ]

buildCustomImageOnce
  :: FilePath -> HostArchitecture -> CustomImageBuildPlan -> [String] -> IO ExitCode
buildCustomImageOnce repoRoot hostArchitecture imageBuildPlan taggedRefs = do
  let arguments =
        [ "build"
        , "-f"
        , customImageDockerfile imageBuildPlan
        ]
          ++ concat [["-t", tagRef] | tagRef <- taggedRefs]
          ++ ["."]
  outputResult <- captureToolOutput repoRoot "docker" arguments
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

pushDockerImageWithRetry :: FilePath -> String -> String -> IO ExitCode
pushDockerImageWithRetry repoRoot imageRef description = go (retryPolicyMaxAttempts customImagePushRetryPolicy)
 where
  go attemptsRemaining = do
    outputResult <- captureToolOutput repoRoot "docker" ["push", imageRef]
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
                  ( retryDelayMicros
                      customImagePushRetryPolicy
                      (retryPolicyMaxAttempts customImagePushRetryPolicy - attemptsRemaining)
                  )
                go (attemptsRemaining - 1)
            | otherwise -> do
                emitCapturedProcessOutput output
                pure (ExitFailure 1)

isRetryableHarborPublicationFailure :: String -> Bool
isRetryableHarborPublicationFailure detail =
  let lowered = map toLower detail
   in any
        (`isInfixOf` lowered)
        [ "502 bad gateway"
        , "503 service unavailable"
        , "504 gateway timeout"
        , "429 too many requests"
        , "connection reset by peer"
        , "connection refused"
        , "tls handshake timeout"
        , "i/o timeout"
        , "temporary failure"
        , "unexpected eof"
        , "unexpected status from put request"
        ]

harborTargetAvailableForHostArchitecture :: FilePath -> String -> IO (Either String Bool)
harborTargetAvailableForHostArchitecture repoRoot imageRef = do
  pullResult <- captureToolOutput repoRoot "docker" ["pull", imageRef]
  pure $
    case pullResult of
      Left err -> Left err
      Right output ->
        case processExitCode output of
          ExitSuccess -> Right True
          ExitFailure _ -> Right False

purgeHarborMirrorTarget :: FilePath -> String -> IO ExitCode
purgeHarborMirrorTarget repoRoot target =
  case parseHarborTargetRepository target of
    Left err -> failWith err
    Right Nothing -> pure ExitSuccess
    Right (Just (projectName, repositoryName)) -> do
      outputResult <-
        captureToolOutput
          repoRoot
          "curl"
          [ "-sS"
          , "-u"
          , harborAdminUser ++ ":" ++ harborAdminPassword
          , "-X"
          , "DELETE"
          , "-o"
          , "/dev/null"
          , "-w"
          , "%{http_code}"
          , "http://"
              ++ harborRegistryEndpoint
              ++ "/api/v2.0/projects/"
              ++ projectName
              ++ "/repositories/"
              ++ encodeHarborRepositoryName repositoryName
          ]
      case outputResult of
        Left err -> failWith err
        Right output ->
          case trimWhitespace (processStdout output) of
            "200" -> pure ExitSuccess
            "201" -> pure ExitSuccess
            "202" -> pure ExitSuccess
            "204" -> pure ExitSuccess
            "404" -> pure ExitSuccess
            statusCode ->
              failWith
                ( "Failed to reset Harbor mirror target '"
                    ++ target
                    ++ "': HTTP "
                    ++ statusCode
                )

parseHarborTargetRepository :: String -> Either String (Maybe (String, String))
parseHarborTargetRepository target = do
  imageRef <- ContainerImage.parseImageRef target
  if ContainerImage.imageRegistry imageRef /= harborRegistryEndpoint
    then Right Nothing
    else case break (== '/') (ContainerImage.imageRepository imageRef) of
      (projectName, '/' : repositoryName)
        | projectName /= "" && repositoryName /= "" ->
            Right (Just (projectName, repositoryName))
      _ ->
        Left ("invalid Harbor image repository path: " ++ ContainerImage.imageRepository imageRef)

encodeHarborRepositoryName :: String -> String
encodeHarborRepositoryName =
  concatMap encodeCharacter
 where
  encodeCharacter '/' = "%252F"
  encodeCharacter character = [character]

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
mirrorHostArchitectureTarget repoRoot source target = do
  pullResult <- captureToolOutput repoRoot "docker" ["pull", source]
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
              tagResult <- captureToolOutput repoRoot "docker" ["tag", source, target]
              case tagResult of
                Left err -> pure (Left err)
                Right tagOutput ->
                  case processExitCode tagOutput of
                    ExitFailure _ -> pure (Left (outputDetail tagOutput))
                    ExitSuccess ->
                      do
                        pushExit <- pushDockerImageWithRetry repoRoot target ("mirror target " ++ target)
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

ensureHarborDockerLogin :: FilePath -> IO ExitCode
ensureHarborDockerLogin repoRoot = go (retryPolicyMaxAttempts harborLoginRetryPolicy)
 where
  arguments =
    ["login", harborRegistryEndpoint, "--username", harborAdminUser, "--password", harborAdminPassword]

  go attemptsRemaining = do
    outputResult <- captureToolOutput repoRoot "docker" arguments
    case outputResult of
      Left err -> failWith err
      Right output ->
        case processExitCode output of
          ExitSuccess -> do
            emitCapturedProcessOutput output
            pure ExitSuccess
          ExitFailure _
            | attemptsRemaining > 1 && isRetryableHarborLoginFailure (outputDetail output) -> do
                writeDiagnosticLine
                  ( "Retrying Harbor docker login ("
                      ++ show (retryPolicyMaxAttempts harborLoginRetryPolicy - attemptsRemaining + 1)
                      ++ "/"
                      ++ show (retryPolicyMaxAttempts harborLoginRetryPolicy)
                      ++ "): "
                      ++ outputDetail output
                  )
                threadDelay
                  ( retryDelayMicros
                      harborLoginRetryPolicy
                      (retryPolicyMaxAttempts harborLoginRetryPolicy - attemptsRemaining)
                  )
                go (attemptsRemaining - 1)
            | otherwise -> do
                emitCapturedProcessOutput output
                pure (ExitFailure 1)

isRetryableHarborLoginFailure :: String -> Bool
isRetryableHarborLoginFailure detail =
  let lowered = map toLower detail
   in any
        (`isInfixOf` lowered)
        [ "unauthorized"
        , "502 bad gateway"
        , "503 service unavailable"
        , "504 gateway timeout"
        , "connection reset by peer"
        , "connection refused"
        , "tls handshake timeout"
        , "i/o timeout"
        , "temporary failure"
        , "unexpected eof"
        ]

isHarborHostedImage :: String -> Bool
isHarborHostedImage imageRef =
  (harborRegistryEndpoint ++ "/") `isPrefixOf` imageRef

isHarborBootstrapImage :: String -> Bool
isHarborBootstrapImage imageRef = "goharbor/" `isInfixOf` imageRef

importImageIntoRke2Containerd :: FilePath -> String -> IO ExitCode
importImageIntoRke2Containerd repoRoot imageRef = do
  socketResult <- resolveContainerdSocket
  case socketResult of
    Left err -> failWith err
    Right socketPath ->
      withTemporaryTextFile "prodbox-image" "" $ \archivePath ->
        runSequentially
          [ runCommand
              Subprocess
                { subprocessPath = "docker"
                , subprocessArguments = ["save", "-o", archivePath, imageRef]
                , subprocessEnvironment = Nothing
                , subprocessWorkingDirectory = Just repoRoot
                }
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
    [ "# Managed by `prodbox rke2 reconcile`. Raises inotify limits so the systemd"
    , "# manager (PID 1), containerd, and kubelet do not exhaust the per-user instance"
    , "# cap during RKE2 lifecycle operations. See"
    , "# documents/engineering/lifecycle_reconciliation_doctrine.md and"
    , "# documents/engineering/streaming_doctrine.md §6."
    , "fs.inotify.max_user_instances = 8192"
    , "fs.inotify.max_user_watches = 1048576"
    ]

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

renderRetainedStateNotice :: FilePath -> FilePath -> IO ExitCode
renderRetainedStateNotice _repoRoot retainedManualPvRoot = do
  writeOutputLine "Preserved host state:"
  writeOutputLine ("  - manual PV root: " ++ retainedManualPvRoot)
  -- Sprint 3.13 chunk 16: the @.prodbox-state/charts/@ chart-state root is
  -- gone; chart secrets and gateway event keys now live in k8s @Secret@s
  -- materialized by the gateway daemon. Nothing under @.prodbox-state/@
  -- is preserved by the supported lifecycle any more.
  pure ExitSuccess

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

ensureHostStoragePath :: FilePath -> FilePath -> IO ExitCode
ensureHostStoragePath repoRoot hostPath =
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
          , subprocessArguments = ["chown", "-R", "1000:1000", hostPath]
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

storageManifestItems :: FilePath -> String -> String -> String -> [Value]
storageManifestItems hostPath nodeName prodboxId labelValue =
  [ object
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
  , object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("PersistentVolume" :: String)
      , "metadata"
          .= object
            [ "name" .= minioPersistentVolume
            , "annotations"
                .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels"
                .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "spec"
          .= object
            [ "capacity" .= object ["storage" .= minioStorageSize]
            , "volumeMode" .= ("Filesystem" :: String)
            , "accessModes" .= (["ReadWriteOnce" :: String] :: [String])
            , "persistentVolumeReclaimPolicy" .= ("Retain" :: String)
            , "storageClassName" .= manualStorageClass
            , "claimRef"
                .= object
                  [ "namespace" .= minioNamespace
                  , "name" .= minioPersistentClaim
                  ]
            , "hostPath"
                .= object
                  [ "path" .= hostPath
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
  , object
      [ "apiVersion" .= ("v1" :: String)
      , "kind" .= ("PersistentVolumeClaim" :: String)
      , "metadata"
          .= object
            [ "name" .= minioPersistentClaim
            , "namespace" .= minioNamespace
            , "annotations"
                .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
            , "labels"
                .= object [Key.fromString prodboxLabelKey .= labelValue]
            ]
      , "spec"
          .= object
            [ "accessModes" .= (["ReadWriteOnce" :: String] :: [String])
            , "volumeMode" .= ("Filesystem" :: String)
            , "storageClassName" .= manualStorageClass
            , "volumeName" .= minioPersistentVolume
            , "resources" .= object ["requests" .= object ["storage" .= minioStorageSize]]
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

renderHarborNginxReadyzConfig :: String -> Maybe String
renderHarborNginxReadyzConfig nginxConf
  | ("location = " ++ harborReadyPath ++ " {") `isInfixOf` nginxConf = Just nginxConf
  | otherwise =
      case break isRootLocation (lines nginxConf) of
        (_, []) -> Nothing
        (before, rootLine : after) ->
          let indent = takeWhile isSpace rootLine
              readyLines =
                [ indent ++ "location = " ++ harborReadyPath ++ " {"
                , indent ++ "  access_log off;"
                , indent ++ "  return 200 \"ok\\n\";"
                , indent ++ "}"
                , ""
                ]
           in Just (unlines (before ++ readyLines ++ (rootLine : after)))
 where
  isRootLocation line = trimWhitespace line == "location / {"

harborComponentName :: String -> String -> String
harborComponentName releaseName component = releaseName ++ "-" ++ component

harborProjectFromRepository :: String -> String
harborProjectFromRepository repository =
  case break (== '/') repository of
    (projectName, '/' : _) | projectName /= "" -> projectName
    _ -> harborMirrorProject

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

helmTransientRetryPolicy :: RetryPolicy
helmTransientRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 3
    , retryPolicyBaseDelayMicros = 10000000
    , retryPolicyMultiplier = 1
    , retryPolicyMaxDelayMicros = 10000000
    }

customImagePushRetryPolicy :: RetryPolicy
customImagePushRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 3
    , retryPolicyBaseDelayMicros = 5000000
    , retryPolicyMultiplier = 1
    , retryPolicyMaxDelayMicros = 5000000
    }

harborLoginRetryPolicy :: RetryPolicy
harborLoginRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 6
    , retryPolicyBaseDelayMicros = 5000000
    , retryPolicyMultiplier = 1
    , retryPolicyMaxDelayMicros = 5000000
    }

route53CredentialPropagationRetryPolicy :: RetryPolicy
route53CredentialPropagationRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 30
    , retryPolicyBaseDelayMicros = 10000000
    , retryPolicyMultiplier = 1
    , retryPolicyMaxDelayMicros = 10000000
    }

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
