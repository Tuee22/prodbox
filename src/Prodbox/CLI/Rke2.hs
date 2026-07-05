{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Rke2
  ( acmeRuntimeManifest
  , acmeRuntimeManifestWith
  , acmeRuntimeManifestWithCredentials
  , acmeClusterIssuerSpec
  , resolveAcmeEabKeyId
  , ensureRuntimeImageForSubstrate
  , ensureGatewayMinioBootstrap
  , ensureAdminPublicEdgeRoutes
  , ensureGatewayChartReady
  , adminPublicEdgeManifestItems
  , ensureHarborRegistryRuntime
  , ensureHarborRegistryStorageBackend
  , ensureMinioRuntime
  , ensurePostgresOperatorRuntime
  , ensureVaultRuntime
  , ensureRootVaultLifecycle
  , MinioImageSource (..)
  , RetainedStorageInventoryEntry (..)
  , cascadeOrderNarration
  , inferCascadeSubstrate
  , isMinioSecretKeyArgumentSafe
  , OperationalAwsCredentialGate (..)
  , buildNativeDeletePlan
  , renderNativeDeletePlan
  , renderNativeInstallPlan
  , renderInotifySysctlDropIn
  , renderResourceVectorRuntime
  , renderRke2ResourceGuardrailConfig
  , renderRke2SystemdResourceDropIn
  , parseHostCapacityObservation
  , hostCapacityCoversPlan
  , renderMinioChartArgs
  , retainedStorageInventoryEntries
  , rke2InstallPresent
  , operationalAwsCredentialGateFromResult
  , runEdgeCommand
  , runNativeDeleteCascade
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
  , try
  )
import Control.Monad (foldM, unless)
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
  ( find
  , intercalate
  , isInfixOf
  , isPrefixOf
  , nub
  )
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)
import Numeric.Natural (Natural)
import Prodbox.Aws (adminAwsEnvironment)
import Prodbox.AwsEnvironment
  ( overlayAwsCredentials
  )
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
  ( VaultReconcileCommandResult (..)
  , runVaultInit
  , runVaultReconcileCommandDetailed
  , runVaultUnseal
  )
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Cluster.Federation
  ( ChildBootstrapCredential (..)
  , ChildIndex (..)
  , ChildInitCustody (..)
  , ChildMetadata (..)
  , ChildRegistrationPlan (..)
  , childBootstrapKvLogicalPath
  , childBootstrapVaultFields
  , childIndexVaultFields
  , childInitKvLogicalPath
  , childMetadataKvLogicalPath
  , childMetadataVaultFields
  , childRegistrationPlan
  , childRegistrationTransitKey
  , childRegistrationVaultNamespace
  , childTransitSealPolicyDocument
  , decodeChildIndex
  , decodeChildInitCustody
  , decodePayloadJsonField
  , federationChildrenIndexKvLogicalPath
  , renderChildRegistrationPlan
  , upsertChildIndex
  )
import Prodbox.Config.Basics
  ( ParentRef (..)
  , UnencryptedBasics (..)
  )
import Prodbox.Config.Tier0
  ( Tier0ParentRef (..)
  , ensureBasicsFloor
  , ensureChildBasicsFloor
  )
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Dns (fetchPublicIp)
import Prodbox.Dns qualified as Dns
import Prodbox.DockerConfig (withEphemeralDockerConfig)
import Prodbox.Error (fatalError)
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
  ( buildChartDeploymentPlanForSubstrate
  , deployChartPlan
  , keycloakRealmName
  , keycloakVscodeClientId
  , resolveChartSecrets
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
import Prodbox.Lifecycle.LiveResidue
  ( PerRunResidueStatuses (..)
  , queryPerRunResidueStatuses
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.ResourceRegistry qualified as ResourceRegistry
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
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
import Prodbox.Settings
  ( AcmeSection (..)
  , AwsCredentialsRef (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , MetallbBgpPeer (..)
  , Route53Section (..)
  , ValidatedSettings (..)
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
  , loadUnencryptedBasics
  , manual_pv_host_root
  , pulumi_enable_dns_bootstrap
  , region
  , renderSeedInForceOutcome
  , resolveAwsCredentialsRefFromHostVault
  , route53
  , seedInForceConfigFromFileWithToken
  , server
  , storage
  , validateAndLoadBootstrapSettings
  , validateAndLoadSettings
  , validateAndLoadSettingsWithVaultToken
  , validateOperationalAwsCredentials
  , validatedConfig
  , zone_id
  )
import Prodbox.Settings.SecretRef
  ( SecretRef (..)
  , VaultSecretRef (..)
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import Prodbox.Substrate (Substrate (..), replicasForSubstrate, substrateId)
import Prodbox.Vault.Client
  ( BootstrapAction (..)
  , VaultAddress (..)
  , VaultToken (..)
  , bootstrapAction
  , vaultCreateToken
  , vaultCreateTransitKey
  , vaultInit
  , vaultKvReadV2
  , vaultKvWriteV2
  , vaultReadTransitKey
  , vaultSealStatus
  , vaultWritePolicy
  )
import Prodbox.Vault.Host
  ( hostVaultAddress
  , loadReadyVaultRootToken
  , readHostVaultKvField
  , seedAcmeEabFromTestSecrets
  )
import Prodbox.Vault.Reconcile
  ( defaultVaultReconcilePlan
  , renderVaultReconcileError
  , renderVaultReconcileStep
  , runVaultReconcile
  )
import Prodbox.Vault.Seal
  ( ChildSealCustody (..)
  , VaultSealMode (..)
  , childInitCustodyVaultFields
  , childSealCustodyFromInitResponse
  , defaultTransitSealConfig
  , initRequestForSealMode
  )
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

harborRuntimeRepository :: String
harborRuntimeRepository = ContainerImage.harborRuntimeRepository

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

harborHelmFieldManager :: String
harborHelmFieldManager = "helm"

vaultApiReadinessAttempts :: Int
vaultApiReadinessAttempts = 60

vaultApiReadinessDelayMicroseconds :: Int
vaultApiReadinessDelayMicroseconds = 2000000

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

harborStorageUserPrefix :: String
harborStorageUserPrefix = "prodbox-harbor-"

harborStoragePolicyName :: String
harborStoragePolicyName = "prodbox-harbor-registry-policy"

harborRegistryStorageBootstrapJobName :: String
harborRegistryStorageBootstrapJobName = "harbor-registry-bucket-init"

-- | Job name + bucket name + canonical IAM principal and policy name for the
-- gateway daemon's MinIO object-store surface, provisioned in one unified pass
-- by 'ensureGatewayMinioBootstrap'.
gatewayMinioBootstrapJobName :: String
gatewayMinioBootstrapJobName = "gateway-minio-bootstrap"

gatewayMinioBucket :: String
gatewayMinioBucket = "prodbox-state"

-- | Namespace where the gateway chart deploys. Reconcile pre-creates it
-- before @prodbox charts deploy gateway@ runs.
gatewayNamespace :: String
gatewayNamespace = "gateway"

gatewayBootstrapNamespaces :: [String]
gatewayBootstrapNamespaces =
  ["keycloak", "vscode"]

-- | Canonical IAM policy name granting the gateway user
-- @s3:GetObject@/@s3:PutObject@/@s3:ListBucket@ on @prodbox-state/*@.
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

acmeEabSecretName :: String
acmeEabSecretName = "acme-eab-credentials"

acmeEabSecretKey :: String
acmeEabSecretKey = "secret"

-- | Sprint 7.15: the EAB HMAC key is materialized into the
-- 'acmeEabSecretName' Secret from Vault @secret/acme/eab@ (field
-- @hmac_key@) by a Vault-login Job in the @cert-manager@ namespace,
-- reusing the Sprint 3.18 chart-side materialization pattern (init
-- container logs into Vault via Kubernetes auth, main container creates
-- the k8s Secret). The HMAC key never transits the operator host; only
-- the non-secret EAB key ID is read host-side for the issuer @keyID@.
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
      mapM_ writeOutputLine =<< resourceStatusLines repoRoot defaultResourceStatusSettings
      (vaultLine, _vaultExit) <- probeVaultStatusLine hostVaultAddress
      writeOutputLine vaultLine
      pure (processExitCode serviceOutput)
 where
  serviceStatusLine output =
    case trimWhitespace (processStdout output) of
      "" -> trimWhitespace (outputDetail output)
      status -> status
  defaultResourceStatusSettings =
    ValidatedSettings
      { validatedConfig = defaultConfigFile
      , resolvedManualPvHostRoot = ".data"
      }

resourceStatusLines :: FilePath -> ValidatedSettings -> IO [String]
resourceStatusLines repoRoot settings = do
  observedResult <- observeHostCapacity repoRoot
  let plan = Capacity.resource_plan (capacity (validatedConfig settings))
      authored = Capacity.host_capacity plan
      allocatable = clusterAllocatable plan
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
          ++ [ "RESOURCE_HOST_OBSERVED=" ++ renderResourceVectorRuntime observed
             , "RESOURCE_HOST_CAPACITY="
                 ++ if hostCapacityCoversPlan observed plan then "sufficient" else "insufficient"
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
                  (childTransitSealPolicyDocument childId transitKey)
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
                        vaultKvWriteV2
                          parentAddress
                          parentToken
                          "secret"
                          (childMetadataKvLogicalPath childId)
                          (childMetadataVaultFields metadata)
                      case metadataResult of
                        Left err -> failWith ("write child metadata Vault KV: " ++ renderHttpError err)
                        Right () -> do
                          bootstrapResult <-
                            vaultKvWriteV2
                              parentAddress
                              parentToken
                              "secret"
                              (childBootstrapKvLogicalPath childId)
                              (childBootstrapVaultFields bootstrapCredential)
                          case bootstrapResult of
                            Left err -> failWith ("write child bootstrap Vault KV: " ++ renderHttpError err)
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
                                            , "  init_kv_path=secret/" ++ Text.unpack (childInitKvLogicalPath childId)
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

updateParentChildIndex :: VaultAddress -> VaultToken -> Text.Text -> IO (Either String ())
updateParentChildIndex parentAddress parentToken childId = do
  readResult <- vaultKvReadV2 parentAddress parentToken "secret" federationChildrenIndexKvLogicalPath
  case readResult of
    Left (HttpStatus 404 _) ->
      writeIndex (ChildIndex [])
    Left err ->
      pure (Left ("read child federation index Vault KV: " ++ renderHttpError err))
    Right fields ->
      case decodePayloadJsonField decodeChildIndex fields of
        Left err -> pure (Left ("decode child federation index Vault KV: " ++ err))
        Right index -> writeIndex index
 where
  writeIndex index = do
    let updatedIndex = upsertChildIndex childId index
    writeResult <-
      vaultKvWriteV2
        parentAddress
        parentToken
        "secret"
        federationChildrenIndexKvLogicalPath
        (childIndexVaultFields updatedIndex)
    pure $ case writeResult of
      Left err -> Left ("write child federation index Vault KV: " ++ renderHttpError err)
      Right () -> Right ()

loadParentFederationAuthority
  :: FilePath -> IO (Either String (Text.Text, VaultAddress, VaultToken))
loadParentFederationAuthority repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  case basicsResult of
    Left err -> pure (Left ("cluster federation register requires unencrypted basics for the parent: " ++ err))
    Right basics ->
      case vaultLifecycleFromBasics basics of
        Left err -> pure (Left err)
        Right (RootVaultLifecycle parentClusterId parentVaultAddress) -> do
          let parentAddress = VaultAddress parentVaultAddress
          tokenResult <- loadReadyVaultRootToken repoRoot parentAddress
          pure $ case tokenResult of
            Left err -> Left err
            Right token -> Right (parentClusterId, parentAddress, token)
        Right ChildVaultLifecycle {} ->
          pure (Left "cluster federation register currently requires a root-cluster parent authority")

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
        Right (machineId, prodboxId) ->
          let labelValue = prodboxIdToLabelValue prodboxId
              plan =
                buildNativeInstallExecutionPlan repoRoot bootstrapSettings machineId prodboxId labelValue withEdge
           in runPlanWithOptions
                planOptions
                plan
                (applyNativeInstallPlan repoRoot bootstrapSettings withEdge)

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

renderNativeInstallPlan
  :: FilePath -> ValidatedSettings -> String -> String -> String -> Bool -> String
renderNativeInstallPlan repoRoot settings machineId prodboxId labelValue withEdge =
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
      , "CLUSTER_ALLOCATABLE=" ++ renderResourceVectorRuntime (clusterAllocatable resourcePlan)
      , "STEP=ensure_rke2_resource_guardrails"
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
      , "STEP=ensure_vault_runtime"
      , "STEP=ensure_federated_vault_lifecycle"
      , "STEP=ensure_minio_runtime_bootstrap"
      , "STEP=restart_minio_if_vault_root_changed"
      , "STEP=load_in_force_settings_after_vault_and_minio"
      , "STEP=ensure_harbor_registry_storage_backend"
      , "STEP=ensure_harbor_registry_runtime"
      , "STEP=mirror_cluster_images_once"
      , "STEP=ensure_gateway_images"
      , "STEP=ensure_public_edge_workload_image"
      , "STEP=ensure_rke2_registries_config"
      , "STEP=ensure_cluster_platform_runtime"
      , "STEP=ensure_minio_runtime_steady_state"
      , "STEP=ensure_gateway_minio_bootstrap"
      , "STEP=ensure_gateway_chart_ready"
      , "STEP=ensure_root_chart_namespace_guardrails"
      , "STEP=ensure_admin_public_edge_routes"
      , "STEP=reconcile_managed_annotations"
      ]
        -- Public-edge steps are AWS-gated and run only under @--with-edge@.
        ++ [ "STEP=require_operational_aws_credentials" | withEdge
           ]
        ++ [ "STEP=ensure_public_edge_acme_runtime" | withEdge
           ]
        ++ [ "STEP=reconcile_dns_bootstrap_record" | withEdge
           ]
    )
 where
  resourcePlan = Capacity.resource_plan (capacity (validatedConfig settings))

buildNativeInstallExecutionPlan
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> String
  -> Bool
  -> Plan (String, String, String)
buildNativeInstallExecutionPlan repoRoot settings machineId prodboxId labelValue withEdge =
  buildPlan
    ( \(resolvedMachineId, resolvedProdboxId, resolvedLabelValue) ->
        renderNativeInstallPlan
          repoRoot
          settings
          resolvedMachineId
          resolvedProdboxId
          resolvedLabelValue
          withEdge
    )
    (machineId, prodboxId, labelValue)

applyNativeInstallPlan
  :: FilePath
  -> ValidatedSettings
  -> Bool
  -> (String, String, String)
  -> IO ExitCode
applyNativeInstallPlan repoRoot bootstrapSettings withEdge (machineId, prodboxId, labelValue) = do
  bootstrapExit <-
    runSequentially
      [ ensureRke2ResourceGuardrails repoRoot bootstrapSettings
      , ensureHostInotifyLimits repoRoot
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
      , ensureHostControlDataDirectory repoRoot bootstrapSettings
      , ensureRetainedLocalStorage repoRoot bootstrapSettings prodboxId labelValue
      , -- Sprint 7.25: MinIO comes up BEFORE Vault (it depends only on the cluster
        -- + its retained PV — static root cred, no Vault init container), so Vault
        -- init writes the unlock bundle to a live MinIO and unseal reads it FROM
        -- MinIO (disk-free).
        ensureMinioRuntime repoRoot SubstrateHomeLocal MinioBootstrapPublic
      , ensureVaultRuntime repoRoot
      ]
  case bootstrapExit of
    ExitFailure _ -> pure bootstrapExit
    ExitSuccess -> do
      vaultLifecycleResult <- ensureFederatedVaultLifecycleDetailed repoRoot
      case vaultLifecycleExitCode vaultLifecycleResult of
        ExitFailure _ -> pure (vaultLifecycleExitCode vaultLifecycleResult)
        ExitSuccess -> do
          -- Sprint 7.25: MinIO (MinioBootstrapPublic) is already up from Phase 1
          -- above and the static root cred never changes, so no post-Vault MinIO
          -- bootstrap or restart-on-root-change step is needed here.
          settingsResult <- loadPostMinioLifecycleSettings repoRoot bootstrapSettings
          case settingsResult of
            Left err -> failWith err
            Right settings ->
              runSequentially
                ( [ ensureHarborRegistryStorageBackend repoRoot
                  , ensureHarborRegistryRuntime repoRoot SubstrateHomeLocal
                  , mirrorClusterImagesOnce repoRoot
                  , ensureRuntimeImage repoRoot prodboxId
                  , ensureRke2RegistriesConfig repoRoot
                  , ensureClusterPlatformRuntime repoRoot settings prodboxId labelValue
                  , ensureMinioRuntime repoRoot SubstrateHomeLocal MinioSteadyStateHarbor
                  , ensureGatewayMinioBootstrap repoRoot
                  , ensureGatewayChartReady repoRoot settings SubstrateHomeLocal
                  , ensureRootChartNamespaceGuardrails repoRoot settings
                  , ensureAdminPublicEdgeRoutes repoRoot settings SubstrateHomeLocal prodboxId labelValue
                  , reconcileManagedAnnotations repoRoot prodboxId labelValue
                  ]
                    -- The public edge (Route 53 DNS + ZeroSSL DNS-01 TLS) is the only
                    -- part of reconcile that needs operational AWS credentials. It runs
                    -- only with @--with-edge@; bare @cluster reconcile@ stands up a fully
                    -- working local cluster with an empty @aws.*@ block.
                    ++ [applyPublicEdgeReconcile repoRoot settings prodboxId labelValue | withEdge]
                )

loadPostMinioLifecycleSettings
  :: FilePath -> ValidatedSettings -> IO (Either String ValidatedSettings)
loadPostMinioLifecycleSettings repoRoot bootstrapSettings = do
  basicsResult <- loadUnencryptedBasics repoRoot
  case basicsResult of
    Left err
      | "Missing unencrypted basics file:" `isPrefixOf` err ->
          pure (Right bootstrapSettings)
      | otherwise -> pure (Left err)
    Right basics ->
      case vaultLifecycleFromBasics basics of
        Left err -> pure (Left err)
        Right (RootVaultLifecycle _ _) -> do
          tokenResult <- loadReadyVaultRootToken repoRoot (VaultAddress (basicsVaultAddress basics))
          case tokenResult of
            Left err -> pure (Left err)
            Right rootToken -> do
              seedInForceConfigStep repoRoot rootToken basics
              validateAndLoadSettings repoRoot
        Right (ChildVaultLifecycle childId _ parent) -> do
          tokenResult <- readChildRootTokenFromParentCustody repoRoot childId parent
          case tokenResult of
            Left err -> pure (Left err)
            Right childRootToken -> do
              seedInForceConfigStep repoRoot childRootToken basics
              validateAndLoadSettingsWithVaultToken repoRoot childRootToken

-- | Sprint 1.42 PART A: the @load_in_force_settings_after_vault_and_minio@
-- seed step. After MinIO is up and Vault is unsealed and @secret/minio/root@ +
-- @secret/object-store/hmac@ are reconciled (the same prerequisites the read
-- path 'loadRuntimeInForceConfigWithToken' needs), establish the in-force MinIO
-- SSoT from the filesystem operator config if it is absent. It is the establish
-- step; the subsequent settings read is the consumer.
--
-- SAFETY: a seed failure (transient MinIO/Vault) MUST NOT brick the reconcile.
-- The existing 'inForceConfigObjectAbsent' filesystem fallback in
-- 'loadConfigForSettingsWith' still covers the read this run, and the seed is
-- retried on the next reconcile, so a failed seed is logged and swallowed
-- rather than propagated.
seedInForceConfigStep :: FilePath -> VaultToken -> UnencryptedBasics -> IO ()
seedInForceConfigStep repoRoot token basics = do
  seedResult <- seedInForceConfigFromFileWithToken repoRoot token basics
  case seedResult of
    Left err ->
      writeOutputLine
        ( "WARN: in-force config SSoT seed step failed (continuing; the filesystem"
            ++ " seed/propose fallback still covers this run, and the seed is retried"
            ++ " on the next reconcile): "
            ++ err
        )
    Right outcome -> writeOutputLine (renderSeedInForceOutcome outcome)

readChildRootTokenFromParentCustody
  :: FilePath -> Text.Text -> ParentRef -> IO (Either String VaultToken)
readChildRootTokenFromParentCustody repoRoot childId parent = do
  parentTokenResult <- readChildTransitSealToken repoRoot
  case parentTokenResult of
    Left err -> pure (Left ("child in-force settings reload cannot read transit-seal token: " ++ err))
    Right parentToken -> do
      custodyResult <- readChildInitCustodyFromParent childId parent parentToken
      pure $ case custodyResult of
        Left err -> Left err
        Right custody -> Right (VaultToken (childInitRootToken custody))

-- | The AWS-gated public-edge reconcile, factored out of the local cluster
-- plan (Phase 2). Fails fast naming @prodbox aws setup@ when operational
-- @aws.*@ is empty, then applies the ZeroSSL DNS-01 ClusterIssuer and the
-- Route 53 bootstrap record.
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
    Right () ->
      runSequentially
        [ ensureAcmeRuntime repoRoot settings prodboxId labelValue
        , reconcileDnsBootstrapRecord repoRoot settings
        ]

-- | Sprint 4.26: the Plan for @prodbox rke2 delete@ (default and
-- @--cascade@). The payload is the 'Rke2DeleteFlags' so the apply closure
-- branches on @--cascade@ / @--allow-pulumi-residue@ exactly as the dispatch
-- arm used to; the rendered plan is the operator-visible destructive
-- sequence so @--dry-run@ shows the full teardown without mutating.
buildNativeDeletePlan :: FilePath -> Rke2DeleteFlags -> Plan Rke2DeleteFlags
buildNativeDeletePlan repoRoot =
  buildPlan (renderNativeDeletePlan repoRoot)

-- | Sprint 4.26: render the destructive @rke2 delete@ plan. The cascade
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

-- | Sprint 4.26: the apply closure for @prodbox rke2 delete@. Performs the
-- effects @--dry-run@ deliberately skips: the no-RKE2-install
-- short-circuit, the inotify-limit host prep, and either the cascade
-- reconciler (@--cascade@) or the refuse-gate default path.
applyNativeDelete :: FilePath -> Rke2DeleteFlags -> IO ExitCode
applyNativeDelete repoRoot flags = do
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
            else runNativeLocalUninstall repoRoot
        ]

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
    , renderRetainedStateNotice repoRoot retainedManualPvRoot
    ]

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
          -- Step 4: Sprint 4.40 test-scoped EBS reaper. After per-run
          -- stack destroys, sweep only
          -- test-scoped EBS volumes. Retained-production EBS survives by
          -- tag policy and by the reaper's test-scoped discover filter.
          runCascadeTestEbsReaper repoRoot
          -- Step 5: RKE2 uninstall + cluster-substrate cleanup.
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
              -- Step 6: postflight cluster-tag sweep (best effort).
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
        Right settings -> do
          credentialsResult <-
            resolveAwsCredentialsRefFromHostVault
              repoRoot
              "aws"
              (aws (validatedConfig settings))
          pure $
            case credentialsResult of
              Left _ -> ("KUBECONFIG", kubeconfigPath) : parentEnv
              Right credentials ->
                overlayAwsCredentials
                  (("KUBECONFIG", kubeconfigPath) : parentEnv)
                  credentials

runCascadeTestEbsReaper :: FilePath -> IO ()
runCascadeTestEbsReaper repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left _ ->
      writeOutputLine
        "Test-scoped EBS reaper: skipped (no ephemeral admin AWS credential available)."
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
        Left err ->
          writeOutputLine
            ("Test-scoped EBS reaper: query/delete failed (continuing): " ++ err)
        Right report ->
          writeOutputLine (EbsVolume.renderTestScopedEbsReaperReport report)

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
        "Postflight tag sweep: skipped (no ephemeral admin AWS credential available \
        \— no test-secrets.dhall and no TTY — so no AWS resources could have been \
        \created by this cluster lifecycle)."
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
        Right resources -> do
          -- Sprint 7.26: carve out intentionally-RETAINED long-lived shared
          -- infrastructure (the `pulumi_state_backend` bucket + `aws-ses`) —
          -- `cluster delete --cascade` keeps these by design (only `prodbox nuke`
          -- destroys them), so they are NOT escaped residue. Refuse only on the
          -- genuine per-run/cluster escapees.
          let (retained, escaped) = TagSweep.partitionRetainedLongLived resources
              retainedArns = nub (map TagSweep.taggedResourceArn retained)
          unless (null retainedArns) $
            writeOutputLine
              ( "Postflight tag sweep: "
                  ++ show (length retainedArns)
                  ++ " intentionally-retained long-lived resource(s) left in place by design "
                  ++ "(destroyed only by `prodbox nuke`): "
                  ++ intercalate ", " retainedArns
                  ++ "."
              )
          if null escaped
            then
              writeOutputLine
                "Postflight tag sweep: clean (no per-run or cluster-tagged AWS residue escaped)."
            else do
              writeOutputLine
                ( "Postflight tag sweep: "
                    ++ show (length escaped)
                    ++ " resource(s) still tagged — operator action required:"
                )
              writeOutputLine (TagSweep.renderTagSweepRefusal escaped)

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
ensureVaultRuntime :: FilePath -> IO ExitCode
ensureVaultRuntime repoRoot = do
  lifecycleResult <- resolveVaultLifecycle repoRoot
  case lifecycleResult of
    Left err -> failWith err
    Right lifecycle ->
      case lifecycle of
        RootVaultLifecycle _ _ ->
          applyVaultRuntime repoRoot lifecycle
        ChildVaultLifecycle _ _ parent -> do
          parentReadiness <- probeParentVaultReadiness parent
          case renderParentReadinessBlock parent parentReadiness of
            Just block -> failWith block
            Nothing -> do
              tokenResult <- childTransitSealTokenPresent repoRoot
              case tokenResult of
                Left err -> failWith err
                Right () -> applyVaultRuntime repoRoot lifecycle

applyVaultRuntime :: FilePath -> FederatedVaultLifecycle -> IO ExitCode
applyVaultRuntime repoRoot lifecycle =
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
ensureRootVaultLifecycle :: FilePath -> IO ExitCode
ensureRootVaultLifecycle repoRoot =
  vaultLifecycleExitCode <$> ensureRootVaultLifecycleDetailed repoRoot

ensureRootVaultLifecycleDetailed :: FilePath -> IO VaultLifecycleResult
ensureRootVaultLifecycleDetailed repoRoot = do
  testLifecycle <- lookupEnv "PRODBOX_TEST_ROOT_VAULT_LIFECYCLE"
  case testLifecycle of
    Just "ready" -> do
      writeOutputLine "Vault lifecycle: test-ready"
      pure (VaultLifecycleResult ExitSuccess)
    Just other ->
      lifecycleFailure <$> failWith ("invalid PRODBOX_TEST_ROOT_VAULT_LIFECYCLE=" ++ other)
    Nothing -> do
      waitExit <- waitForVaultApiReadiness hostVaultAddress
      case waitExit of
        ExitFailure _ -> pure (lifecycleFailure waitExit)
        ExitSuccess -> continue
 where
  continue = do
    initExit <- runVaultInit repoRoot hostVaultAddress
    case initExit of
      ExitFailure _ -> pure (lifecycleFailure initExit)
      ExitSuccess -> do
        unsealExit <- runVaultUnseal repoRoot hostVaultAddress
        case unsealExit of
          ExitFailure _ -> pure (lifecycleFailure unsealExit)
          ExitSuccess -> do
            -- Sprint 1.39 (self-heal): @vault init@ writes the Tier-0 basics
            -- floor only at first-ever bring-up; on a rebuild against a
            -- durable Vault PV it early-returns and the floor is never
            -- rewritten. Guarantee it idempotently here — AFTER init/unseal
            -- succeed and BEFORE reconcile — so the per-run Pulumi destroy and
            -- the other `loadUnencryptedBasics` consumers always find it.
            floorResult <- ensureBasicsFloor repoRoot (unVaultAddress hostVaultAddress)
            case floorResult of
              Left err -> lifecycleFailure <$> failWith err
              Right () -> do
                reconcileResult <- runVaultReconcileCommandDetailed repoRoot hostVaultAddress
                pure
                  VaultLifecycleResult
                    { vaultLifecycleExitCode = vaultReconcileCommandExitCode reconcileResult
                    }

waitForVaultApiReadiness :: VaultAddress -> IO ExitCode
waitForVaultApiReadiness address =
  go vaultApiReadinessAttempts "Vault API not yet checked"
 where
  go :: Int -> String -> IO ExitCode
  go attemptsRemaining lastDetail
    | attemptsRemaining <= 0 =
        failWith
          ( "Vault API did not become reachable before lifecycle reconciliation: "
              ++ lastDetail
          )
    | otherwise = do
        statusResult <- vaultSealStatus address
        case statusResult of
          Right _ -> pure ExitSuccess
          Left err -> do
            threadDelay vaultApiReadinessDelayMicroseconds
            go (attemptsRemaining - 1) (renderHttpError err)

ensureFederatedVaultLifecycleDetailed :: FilePath -> IO VaultLifecycleResult
ensureFederatedVaultLifecycleDetailed repoRoot = do
  lifecycleResult <- resolveVaultLifecycle repoRoot
  case lifecycleResult of
    Left err -> lifecycleFailure <$> failWith err
    Right (RootVaultLifecycle _ _) -> ensureRootVaultLifecycleDetailed repoRoot
    Right (ChildVaultLifecycle childId _ parent) ->
      ensureChildVaultLifecycleDetailed repoRoot childId parent

ensureChildVaultLifecycleDetailed :: FilePath -> Text.Text -> ParentRef -> IO VaultLifecycleResult
ensureChildVaultLifecycleDetailed repoRoot childId parent = do
  tokenResult <- readChildTransitSealToken repoRoot
  case tokenResult of
    Left err ->
      lifecycleFailure <$> failWith ("child Vault lifecycle cannot read transit-seal token: " ++ err)
    Right parentToken -> do
      statusResult <- vaultSealStatus hostVaultAddress
      case statusResult of
        Left err -> lifecycleFailure <$> failWith ("child Vault status failed: " ++ renderHttpError err)
        Right status ->
          case bootstrapAction status of
            BootstrapInitialize ->
              initializeChildVaultAndWriteCustody repoRoot childId parent parentToken
            BootstrapUnseal ->
              lifecycleFailure
                <$> failWith
                  ( "Blocked: child Vault is initialized but sealed after the parent readiness check. "
                      ++ "Transit auto-unseal did not complete; no local unseal fallback exists."
                  )
            BootstrapReady ->
              reconcileChildVaultFromParentCustody repoRoot childId parent parentToken

initializeChildVaultAndWriteCustody
  :: FilePath -> Text.Text -> ParentRef -> VaultToken -> IO VaultLifecycleResult
initializeChildVaultAndWriteCustody repoRoot childId parent parentToken = do
  let parentAddress = VaultAddress (parentRefVaultAddress parent)
      transitKey = normalizeTransitKeyName (parentRefTransitKey parent)
      sealConfig = defaultTransitSealConfig parentAddress transitKey
  initResult <-
    vaultInit
      hostVaultAddress
      (initRequestForSealMode (VaultSealChildTransit sealConfig))
  case initResult of
    Left err -> lifecycleFailure <$> failWith ("child Vault init failed: " ++ renderHttpError err)
    Right initResponse -> do
      let custody =
            childSealCustodyFromInitResponse
              (parentRefClusterId parent)
              childId
              (unVaultAddress hostVaultAddress)
              ("child-local")
              transitKey
              initResponse
          initFields = childInitCustodyVaultFields (childSealCustodyInit custody)
      writeResult <-
        vaultKvWriteV2
          parentAddress
          parentToken
          "secret"
          (childInitKvLogicalPath childId)
          initFields
      case writeResult of
        Left err ->
          lifecycleFailure
            <$> failWith ("write child init custody to parent Vault KV: " ++ renderHttpError err)
        Right () ->
          reconcileChildVaultWithToken
            repoRoot
            childId
            parent
            (VaultToken (childInitRootToken (childSealCustodyInit custody)))

reconcileChildVaultFromParentCustody
  :: FilePath -> Text.Text -> ParentRef -> VaultToken -> IO VaultLifecycleResult
reconcileChildVaultFromParentCustody repoRoot childId parent parentToken = do
  custodyResult <- readChildInitCustodyFromParent childId parent parentToken
  case custodyResult of
    Left err -> lifecycleFailure <$> failWith err
    Right custody ->
      reconcileChildVaultWithToken repoRoot childId parent (VaultToken (childInitRootToken custody))

readChildInitCustodyFromParent
  :: Text.Text -> ParentRef -> VaultToken -> IO (Either String ChildInitCustody)
readChildInitCustodyFromParent childId parent parentToken = do
  readResult <-
    vaultKvReadV2
      (VaultAddress (parentRefVaultAddress parent))
      parentToken
      "secret"
      (childInitKvLogicalPath childId)
  pure $ case readResult of
    Left err -> Left ("read child init custody from parent Vault KV: " ++ renderHttpError err)
    Right fields ->
      case Map.lookup "payload_json" fields of
        Nothing -> Left "child init custody in parent Vault KV is missing field `payload_json`"
        Just payload ->
          case decodeChildInitCustody (TextEncoding.encodeUtf8 payload) of
            Left err -> Left ("decode child init custody from parent Vault KV: " ++ err)
            Right custody -> Right custody

reconcileChildVaultWithToken
  :: FilePath -> Text.Text -> ParentRef -> VaultToken -> IO VaultLifecycleResult
reconcileChildVaultWithToken repoRoot childId parent childRootToken = do
  -- Sprint 1.39 (self-heal): guarantee this child's Transit-mode basics floor
  -- exists before reconcile, mirroring the root self-heal. The floor carries
  -- the parent reference this child auto-unseals against, reconstructed from the
  -- in-scope identity when missing (e.g. a rebuild against a durable child PV).
  floorResult <-
    ensureChildBasicsFloor
      repoRoot
      childId
      (unVaultAddress hostVaultAddress)
      (parentRefToTier0 parent)
  case floorResult of
    Left err -> lifecycleFailure <$> failWith err
    Right () -> reconcileChildVaultBody childId childRootToken

parentRefToTier0 :: ParentRef -> Tier0ParentRef
parentRefToTier0 ref =
  Tier0ParentRef
    { parent_cluster_id = parentRefClusterId ref
    , parent_vault_address = parentRefVaultAddress ref
    , parent_transit_key = parentRefTransitKey ref
    }

reconcileChildVaultBody :: Text.Text -> VaultToken -> IO VaultLifecycleResult
reconcileChildVaultBody _childId childRootToken = do
  reconcileResult <- runVaultReconcile hostVaultAddress childRootToken defaultVaultReconcilePlan
  case reconcileResult of
    Left err -> do
      writeOutput ("Child Vault reconcile failed: " ++ renderVaultReconcileError err)
      pure (VaultLifecycleResult (ExitFailure 1))
    Right steps -> do
      writeOutput
        ( unlines
            ( "Child Vault reconcile complete:"
                : map (("  " ++) . renderVaultReconcileStep) steps
            )
        )
      pure
        VaultLifecycleResult
          { vaultLifecycleExitCode = ExitSuccess
          }

lifecycleFailure :: ExitCode -> VaultLifecycleResult
lifecycleFailure exitCode =
  VaultLifecycleResult
    { vaultLifecycleExitCode = exitCode
    }

resolveVaultLifecycle :: FilePath -> IO (Either String FederatedVaultLifecycle)
resolveVaultLifecycle repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  pure $ case basicsResult of
    Left err
      | "Missing unencrypted basics file:" `isPrefixOf` err ->
          Right (RootVaultLifecycle "prodbox-home" (unVaultAddress hostVaultAddress))
      | otherwise -> Left err
    Right basics -> vaultLifecycleFromBasics basics

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

normalizeTransitKeyName :: Text.Text -> Text.Text
normalizeTransitKeyName raw =
  fromMaybe stripped (Text.stripPrefix "transit/" stripped)
 where
  stripped = Text.dropWhileEnd (== '/') (Text.dropWhile (== '/') raw)

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
ensureMinioRuntime :: FilePath -> Substrate -> MinioImageSource -> IO ExitCode
ensureMinioRuntime repoRoot substrate imageSource =
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
            ++ renderMinioChartArgs substrate imageSource
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
renderMinioChartArgs :: Substrate -> MinioImageSource -> [String]
renderMinioChartArgs substrate _imageSource =
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
        ++ minioSubstratePersistenceArgs substrate

-- | Substrate-specific MinIO storage args for the @data@ volumeClaimTemplate:
-- both substrates use the retained @manual@ StorageClass. Home binds to the
-- hostPath PV at @.data/prodbox/minio/0@; AWS binds to the pre-created EBS
-- volume lifted in as a static CSI PV. Both are bounded at 20 GiB so the
-- default full-workflow resource plan fits a small single-node host.
minioSubstratePersistenceArgs :: Substrate -> [String]
minioSubstratePersistenceArgs substrate =
  case substrate of
    SubstrateHomeLocal ->
      ["--set", "storage.className=manual", "--set", "storage.size=20Gi"]
    SubstrateAws ->
      ["--set", "storage.className=manual", "--set", "storage.size=20Gi"]

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

-- | Sprint 3.18: Job manifest that bootstraps the gateway daemon's MinIO
-- surface (@prodbox-state@ bucket + @prodbox-gateway@ user + IAM policy + policy
-- attachment) in one pass, with every secret-bearing input read from Vault
-- inside the cluster.
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
                                              , "mc alias set local "
                                                  ++ minioClusterEndpoint
                                                  ++ " \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\""
                                              , "mc mb --ignore-existing local/" ++ gatewayMinioBucket
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
                                              ]
                                          ]
                                   , "env"
                                       .= ( minioRootFileEnv
                                              ++ gatewayMinioFileEnv
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

minioRootVaultInitContainer :: Value
minioRootVaultInitContainer =
  object
    [ "name" .= ("vault-minio-root" :: String)
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
               , "value" .= ("minio" :: String)
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
               ]
           ]
    , "volumeMounts" .= [minioRootVaultMaterializedInitVolumeMount]
    ]

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
            , "ttlSecondsAfterFinished" .= (60 :: Int)
            , "template"
                .= object
                  [ "spec"
                      .= object
                        [ "restartPolicy" .= ("OnFailure" :: String)
                        , "serviceAccountName" .= minioReleaseName
                        , "initContainers" .= [minioRootVaultInitContainer]
                        , "volumes" .= [minioRootVaultMaterializedVolume]
                        , "containers"
                            .= [ object
                                   [ "name" .= ("bucket-bootstrap" :: String)
                                   , "image" .= ContainerImage.renderImageRef ContainerImage.publicMinioMcImage
                                   , "command" .= ["sh" :: String, "-c"]
                                   , "args"
                                       .= [ unlines
                                              [ "set -eu"
                                              , "MINIO_ROOT_USER=\"$(cat \"$MINIO_ROOT_USER_FILE\")\""
                                              , "MINIO_ROOT_PASSWORD=\"$(cat \"$MINIO_ROOT_PASSWORD_FILE\")\""
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
                                       .= ( minioRootFileEnv
                                              ++ [ object
                                                     [ "name" .= ("HARBOR_STORAGE_ACCESS_KEY" :: String)
                                                     , "value" .= accessKey
                                                     ]
                                                 , object
                                                     [ "name" .= ("HARBOR_STORAGE_SECRET_KEY" :: String)
                                                     , "value" .= secretKey
                                                     ]
                                                 ]
                                          )
                                   , "volumeMounts" .= [minioRootVaultMaterializedVolumeMount]
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
            , "--force-conflicts"
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
    -- Sprint 1.47: no docker login — project creation uses the Harbor REST API
    -- with inline `curl -u admin:Harbor12345`; Harbor readiness is gated by the
    -- preceding waitForHarbor* probes, and image pushes authenticate via the
    -- per-flow ephemeral DOCKER_CONFIG.
    SubstrateHomeLocal -> createHarborProjectsHomeLocal repoRoot
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
  [harborMirrorProject, harborProjectFromRepository harborRuntimeRepository]

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
    readHarborNginxConfig repoRoot
  case configOutputResult of
    Left err -> failWith err
    Right configOutput ->
      case processExitCode configOutput of
        ExitFailure _ -> failWith ("Failed to read Harbor nginx ConfigMap: " ++ outputDetail configOutput)
        ExitSuccess ->
          case renderHarborNginxReadyzConfig (processStdout configOutput) of
            Nothing -> failWith "Failed to inject Harbor nginx readiness path into ConfigMap"
            Just patchedConfig -> do
              applyHarborNginxReadinessContract repoRoot patchedConfig

applyHarborNginxReadinessContract :: FilePath -> String -> IO ExitCode
applyHarborNginxReadinessContract repoRoot patchedConfig = do
  configPatchExit <- patchHarborNginxConfigMap repoRoot patchedConfig
  case configPatchExit of
    ExitFailure _ -> pure configPatchExit
    ExitSuccess -> patchHarborNginxDeployment repoRoot

readHarborNginxConfig :: FilePath -> IO (Either String ProcessOutput)
readHarborNginxConfig repoRoot =
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

patchHarborNginxConfigMap :: FilePath -> String -> IO ExitCode
patchHarborNginxConfigMap repoRoot patchedConfig = do
  let configMapPatch =
        object
          [ "data" .= object ["nginx.conf" .= patchedConfig]
          ]
  patchResult <-
    captureKubectl
      repoRoot
      [ "patch"
      , "configmap"
      , harborComponentName harborReleaseName "nginx"
      , "-n"
      , harborNamespace
      , "--type"
      , "merge"
      , "--field-manager=" ++ harborHelmFieldManager
      , "--patch"
      , trimTrailingNewlines (BL8.unpack (encode configMapPatch))
      ]
  case patchResult of
    Left err -> failWith err
    Right patchOutput ->
      case processExitCode patchOutput of
        ExitFailure _ -> failWith ("Failed to patch Harbor nginx ConfigMap: " ++ outputDetail patchOutput)
        ExitSuccess -> pure ExitSuccess

patchHarborNginxDeployment :: FilePath -> IO ExitCode
patchHarborNginxDeployment repoRoot = do
  let deploymentPatch =
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
      , "--field-manager=" ++ harborHelmFieldManager
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
        , ensurePostgresOperatorRuntime repoRoot prodboxId labelValue
        ]

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

-- | Deploy the gateway chart as a reconcile-time platform component and
-- install the loopback-only NodePort iptables restriction on home (mirrors
-- the @charts deploy gateway@ post-hook).
--
-- Idempotent: 'deployChartPlan' no-ops when the gateway release is already
-- installed, and the firewall step is safe to repeat.
ensureGatewayChartReady
  :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
ensureGatewayChartReady repoRoot settings substrate =
  ensureGatewayChartReadyForSubstrate repoRoot settings substrate

resolveOperationalAwsCredentialGate
  :: FilePath -> ValidatedSettings -> IO OperationalAwsCredentialGate
resolveOperationalAwsCredentialGate repoRoot settings =
  case validateOperationalAwsCredentials config of
    Left err -> pure (operationalAwsCredentialGateFromResult (Left err))
    Right () -> do
      credentialsResult <- resolveAwsCredentialsRefFromHostVault repoRoot "aws" (aws config)
      pure (operationalAwsCredentialGateFromResult credentialsResult)
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
ensureGatewayChartReadyForSubstrate repoRoot settings substrate = do
  credentialGate <- resolveOperationalAwsCredentialGate repoRoot settings
  case credentialGate of
    -- The gateway chart needs resolved operational AWS credentials for its
    -- Route 53 DNS write gate. A bare @cluster reconcile@ is allowed to stand
    -- up the local substrate before @aws.*@ has been materialized into Vault,
    -- so skip the gateway daemon rather than deploy pods that crash on a
    -- missing SecretRef.
    OperationalAwsCredentialsAbsent _ -> do
      writeOutputLine
        ( "Skipping gateway daemon deploy: operational aws.* is empty or"
            ++ " missing in Vault (bare local cluster reconcile). The gateway"
            ++ " chart needs Route 53 credentials; populate aws.* via the test harness or"
            ++ " `prodbox aws setup` to bring the gateway up."
        )
      pure ExitSuccess
    OperationalAwsCredentialsInvalid err ->
      failWith ("load operational AWS credentials from Vault: " ++ err)
    OperationalAwsCredentialsReady ->
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
ensureAdminPublicEdgeRoutes repoRoot settings substrate prodboxId labelValue = do
  credentialGate <- resolveOperationalAwsCredentialGate repoRoot settings
  case credentialGate of
    -- Admin public-edge routes need the vscode OIDC secret from Vault and are
    -- only meaningful once the Route 53-writing gateway is credentialed.
    OperationalAwsCredentialsAbsent _ -> pure ExitSuccess
    OperationalAwsCredentialsInvalid err ->
      failWith ("load operational AWS credentials from Vault: " ++ err)
    OperationalAwsCredentialsReady ->
      ensureAdminPublicEdgeRoutesCredentialed repoRoot settings substrate prodboxId labelValue

ensureAdminPublicEdgeRoutesCredentialed
  :: FilePath -> ValidatedSettings -> Substrate -> String -> String -> IO ExitCode
ensureAdminPublicEdgeRoutesCredentialed repoRoot settings substrate prodboxId labelValue = do
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

-- | Host-side acquisition of the @vscode@ OIDC client secret, which the
-- harbor and minio admin @SecurityPolicy@ resources reuse.
readKeycloakVscodeClientSecret :: FilePath -> IO (Either String String)
readKeycloakVscodeClientSecret repoRoot = do
  result <- readHostVaultKvField repoRoot "secret" "vscode/oidc/vscode" "client_secret"
  pure (Text.unpack <$> result)

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
ensureAcmeRuntime repoRoot settings prodboxId labelValue = do
  currentEnvironment <- getEnvironment
  credentialsResult <-
    resolveAwsCredentialsRefFromHostVault
      repoRoot
      "aws"
      (aws (validatedConfig settings))
  case credentialsResult of
    Left err -> failWith ("load operational AWS credentials from Vault: " ++ err)
    Right route53Credentials -> do
      -- Sprint 7.15: resolve the non-secret EAB key ID host-side from Vault
      -- (the HMAC key is never read here — it is materialized in-cluster).
      eabKeyIdResult <- resolveAcmeEabKeyId repoRoot settings
      case eabKeyIdResult of
        Left err -> failWith ("resolve ACME EAB key ID from Vault: " ++ err)
        Right resolvedEabKeyId -> do
          -- Sprint 7.18: seed @secret/acme/eab@ in Vault from the optional
          -- @acme_eab@ block of @test-secrets.dhall@ BEFORE applying the manifest
          -- below, which includes the in-cluster EAB materializer Job. Without
          -- this, the materializer reads an empty @secret/acme/eab#hmac_key@ and
          -- writes an empty @acme-eab-credentials@ Secret, so the ZeroSSL
          -- ClusterIssuer fails with "cannot sign JWS with an empty MAC key".
          -- A no-op when @test-secrets.dhall@ is absent or its @acme_eab@ is
          -- empty (real operators seed the EAB via interactive @config setup@).
          seedAcmeEabFromTestSecrets repoRoot
          withTemporaryJsonManifest
            "prodbox-acme-runtime"
            ( acmeRuntimeManifestWithCredentials
                SubstrateHomeLocal
                settings
                (substrateHostedZoneId settings SubstrateHomeLocal)
                route53Credentials
                resolvedEabKeyId
                prodboxId
                labelValue
            )
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
                    issuerWaitEnv <- awsCommandEnvironment repoRoot currentEnvironment settings
                    -- Wait for the ZeroSSL ClusterIssuer rendered from the
                    -- manifest to become Ready before reporting the ACME
                    -- runtime up.
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

-- | Sprint 7.15: resolve the non-secret ACME EAB key ID host-side from
-- Vault. Returns @Right Nothing@ when EAB is not configured (no
-- @eab_key_id@ reference); @Right (Just keyId)@ when the configured
-- @SecretRef.Vault@ resolves; and @Left@ on a non-Vault reference or a
-- Vault read failure (a sealed Vault therefore fails closed). The HMAC key
-- is intentionally never read here.
resolveAcmeEabKeyId :: FilePath -> ValidatedSettings -> IO (Either String (Maybe Text.Text))
resolveAcmeEabKeyId repoRoot settings =
  case eab_key_id (acme (validatedConfig settings)) of
    Nothing -> pure (Right Nothing)
    Just (SecretRefVault vaultRef) -> do
      result <-
        readHostVaultKvField
          repoRoot
          (vaultSecretMount vaultRef)
          (vaultSecretPath vaultRef)
          (vaultSecretField vaultRef)
      pure (fmap Just result)
    Just _ ->
      pure
        ( Left
            "acme.eab_key_id must be a SecretRef.Vault reference"
        )

acmeRuntimeManifest
  :: Substrate -> ValidatedSettings -> Maybe Text.Text -> String -> String -> [Value]
acmeRuntimeManifest substrate settings =
  acmeRuntimeManifestWith substrate settings (substrateHostedZoneId settings substrate)

-- | Sprint 7.5.c.v follow-up: variant of 'acmeRuntimeManifest' that takes
-- an externally-resolved hosted-zone ID so the IO caller can fall back to
-- the live aws-eks-subzone Pulumi stack snapshot when
-- @aws_substrate.hosted_zone_id@ is empty in @prodbox.dhall@. See
-- 'Prodbox.PublicEdge.resolveSubstrateHostedZoneId' for the doctrine-
-- compliant resolution algorithm.
--
-- Sprint 7.15: the ACME EAB key ID is no longer plaintext in config; the
-- IO caller resolves it host-side from Vault @secret/acme/eab#key_id@ and
-- threads it through as @Maybe Text@. The EAB HMAC key is never read
-- host-side — it is materialized in-cluster by the EAB materializer Job.
acmeRuntimeManifestWith
  :: Substrate -> ValidatedSettings -> Text.Text -> Maybe Text.Text -> String -> String -> [Value]
acmeRuntimeManifestWith substrate settings hostedZoneId =
  acmeRuntimeManifestWithCredentials
    substrate
    settings
    hostedZoneId
    (emptyRoute53Credentials settings)

acmeRuntimeManifestWithCredentials
  :: Substrate
  -> ValidatedSettings
  -> Text.Text
  -> Credentials
  -> Maybe Text.Text
  -> String
  -> String
  -> [Value]
acmeRuntimeManifestWithCredentials _substrate settings hostedZoneId route53Credentials resolvedEabKeyId prodboxId labelValue =
  route53Secret
    : eabMaterializerResources
    ++ [clusterIssuer]
 where
  config = validatedConfig settings
  acmeConfig = acme config
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
            [ "access-key-id" .= Text.unpack (access_key_id route53Credentials)
            , "secret-access-key" .= Text.unpack (secret_access_key route53Credentials)
            ]
      ]
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
  clusterIssuer =
    clusterIssuerResource
      publicEdgeClusterIssuerName
      (acmeClusterIssuerSpec settings resolvedEabKeyId hostedZoneId)
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
      , -- The sibling 'materialize-eab-secret' container runs the curl image
        -- as a different (non-root) UID than this vault-image init container,
        -- so the @umask 077@ file (0600, owned by the init UID) is otherwise
        -- unreadable to it — base64 reads nothing and the materialized Secret
        -- comes out empty (ZeroSSL then fails with "empty MAC key"). The
        -- volume is a pod-scoped in-memory emptyDir, so widening this handoff
        -- file to 0644 for the sibling read keeps the secret inside the pod
        -- trust boundary.
        "chmod 0644 /vault-materialized/hmac-key"
      ]
  materializeScript =
    unlines
      [ "set -eu"
      , "api_server=\"https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}\""
      , "token=\"$(cat \"${SERVICEACCOUNT_TOKEN_FILE}\")\""
      , "hmac_b64=\"$(base64 < /vault-materialized/hmac-key | tr -d '\\n')\""
      , -- Fail loud rather than materialize an empty Secret: an empty HMAC
        -- here surfaces only later as the opaque ZeroSSL "cannot sign JWS
        -- with an empty MAC key" error. If the handoff file is empty or
        -- unreadable, abort the Job (backoffLimit retries) instead.
        "[ -n \"${hmac_b64}\" ] || { echo 'materialized EAB HMAC is empty: secret/acme/eab#hmac_key is missing/empty in Vault or the handoff file was unreadable' >&2 ; exit 1 ; }"
      , "cat > /tmp/secret-create.json <<EOF"
      , "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${SECRET_NAME}\",\"labels\":{\"app.kubernetes.io/managed-by\":\"prodbox\"}},\"type\":\"Opaque\",\"data\":{\""
          ++ acmeEabSecretKey
          ++ "\":\"${hmac_b64}\"}}"
      , "EOF"
      , "cat > /tmp/secret-patch.json <<EOF"
      , "{\"type\":\"Opaque\",\"data\":{\"" ++ acmeEabSecretKey ++ "\":\"${hmac_b64}\"}}"
      , "EOF"
      , "create_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/json\" -o /tmp/secret-create-response.json -w '%{http_code}' --data-binary @/tmp/secret-create.json \"${api_server}/api/v1/namespaces/${POD_NAMESPACE}/secrets\" || true)\""
      , "case \"${create_code}\" in"
      , "  201) exit 0 ;;"
      , "  409)"
      , "    patch_code=\"$(curl -sS --cacert \"${SERVICEACCOUNT_CA_FILE}\" -H \"Authorization: Bearer ${token}\" -H \"Content-Type: application/merge-patch+json\" -o /tmp/secret-patch-response.json -w '%{http_code}' --request PATCH --data-binary @/tmp/secret-patch.json \"${api_server}/api/v1/namespaces/${POD_NAMESPACE}/secrets/${SECRET_NAME}\" || true)\""
      , "    case \"${patch_code}\" in 200|201) exit 0 ;; *) cat /tmp/secret-patch-response.json >&2 ; exit 1 ;; esac ;;"
      , "  *) cat /tmp/secret-create-response.json >&2 ; exit 1 ;;"
      , "esac"
      ]
  job =
    object
      [ "apiVersion" .= ("batch/v1" :: String)
      , "kind" .= ("Job" :: String)
      , "metadata" .= managedMetadata []
      , "spec"
          .= object
            [ "backoffLimit" .= (6 :: Int)
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
                        , "restartPolicy" .= ("OnFailure" :: String)
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
                                              , "readOnly" .= True
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

emptyRoute53Credentials :: ValidatedSettings -> Credentials
emptyRoute53Credentials settings =
  Credentials
    { access_key_id = ""
    , secret_access_key = ""
    , session_token = Nothing
    , region = awsCredentialRegion (aws (validatedConfig settings))
    }

-- | The ZeroSSL ACME @ClusterIssuer@ @spec.acme@ object: the
-- @acme.server@ directory, the ZeroSSL account key, the DNS-01 Route 53
-- solver, and the required ZeroSSL external account binding.
--
-- Sprint 7.15: the @externalAccountBinding.keyID@ is no longer plaintext
-- in config; the IO caller resolves it host-side from Vault
-- @secret/acme/eab#key_id@ and supplies it as @Maybe Text@. The binding is
-- rendered only when EAB is configured (both @SecretRef.Vault@ references
-- present) /and/ the key ID resolved; its @keySecretRef@ points at the
-- @acme-eab-credentials@ Secret the EAB materializer Job creates from
-- Vault. The key ID is not secret, hence inline; the HMAC key never
-- transits the operator host.
acmeClusterIssuerSpec :: ValidatedSettings -> Maybe Text.Text -> Text.Text -> Value
acmeClusterIssuerSpec settings resolvedEabKeyId hostedZoneId =
  object $
    [ "server" .= Text.unpack (server acmeConfig)
    , "email" .= Text.unpack (email acmeConfig)
    , "privateKeySecretRef" .= object ["name" .= zerosslAccountKeySecretName]
    , "solvers" .= [acmeRoute53Solver (awsCredentialRegion awsConfig) hostedZoneId]
    ]
      ++ maybe [] (\binding -> ["externalAccountBinding" .= binding]) externalAccountBinding
 where
  config = validatedConfig settings
  awsConfig = aws config
  acmeConfig = acme config
  eabConfigured =
    case (eab_key_id acmeConfig, eab_hmac_key acmeConfig) of
      (Just _, Just _) -> True
      _ -> False
  externalAccountBinding =
    case (eabConfigured, resolvedEabKeyId) of
      (True, Just keyId) ->
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
          awsEnvironment <- awsCommandEnvironment repoRoot environment settings
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
  plan = Capacity.resource_plan (capacity (validatedConfig settings))

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
  namespaceQuota <- requireGuardrailNamespaceQuota plan namespace
  limitEnvelope <- requireGuardrailLimitEnvelope plan namespace
  pure
    [ rootChartResourceQuotaManifest namespace namespaceQuota
    , rootChartLimitRangeManifest namespace limitEnvelope
    ]

requireGuardrailNamespaceQuota
  :: Capacity.ResourcePlan -> String -> Either String Capacity.NamespaceQuota
requireGuardrailNamespaceQuota plan namespace =
  case find ((== Text.pack namespace) . Capacity.namespace_name) (Capacity.namespace_quotas plan) of
    Just namespaceQuota -> Right namespaceQuota
    Nothing -> Left ("capacity.resource_plan is missing namespace quota `" ++ namespace ++ "`")

requireGuardrailLimitEnvelope
  :: Capacity.ResourcePlan -> String -> Either String Capacity.ResourceEnvelope
requireGuardrailLimitEnvelope plan namespace =
  case find ((== Text.pack namespace) . Capacity.profile_namespace) (Capacity.workload_profiles plan) of
    Just profile -> Right (Capacity.resources profile)
    Nothing -> Left ("capacity.resource_plan has no workload profile for namespace `" ++ namespace ++ "`")

rootChartResourceQuotaManifest :: String -> Capacity.NamespaceQuota -> Value
rootChartResourceQuotaManifest namespace namespaceQuota =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("ResourceQuota" :: String)
    , "metadata" .= rootChartGuardrailMetadata namespace (namespace ++ "-resource-quota")
    , "spec" .= resourceQuotaSpec (Capacity.quota namespaceQuota)
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
                     , "default" .= runtimeResourceVectorValue (Capacity.limit envelope)
                     , "defaultRequest" .= runtimeResourceVectorValue (Capacity.request envelope)
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

resourceQuotaSpec :: Capacity.ResourceVector -> Value
resourceQuotaSpec vector =
  object
    [ "hard"
        .= object
          [ "requests.cpu" .= cpuQuantity (Capacity.milli_cpu vector)
          , "limits.cpu" .= cpuQuantity (Capacity.milli_cpu vector)
          , "requests.memory" .= memoryQuantity (Capacity.memory_mib vector)
          , "limits.memory" .= memoryQuantity (Capacity.memory_mib vector)
          , "requests.ephemeral-storage" .= memoryQuantity (Capacity.ephemeral_storage_mib vector)
          , "limits.ephemeral-storage" .= memoryQuantity (Capacity.ephemeral_storage_mib vector)
          , "requests.storage" .= memoryQuantity (Capacity.durable_storage_mib vector)
          ]
    ]

runtimeResourceVectorValue :: Capacity.ResourceVector -> Value
runtimeResourceVectorValue vector =
  object
    [ "cpu" .= cpuQuantity (Capacity.milli_cpu vector)
    , "memory" .= memoryQuantity (Capacity.memory_mib vector)
    , "ephemeral-storage" .= memoryQuantity (Capacity.ephemeral_storage_mib vector)
    ]

awsCommandEnvironment
  :: FilePath -> [(String, String)] -> ValidatedSettings -> IO [(String, String)]
awsCommandEnvironment repoRoot baseEnvironment settings = do
  credentialsResult <-
    resolveAwsCredentialsRefFromHostVault
      repoRoot
      "aws"
      (aws (validatedConfig settings))
  case credentialsResult of
    Left err -> fail ("load operational AWS credentials from Vault: " ++ err)
    Right credentials -> pure (overlayAwsCredentials baseEnvironment credentials)

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
mirrorClusterImagesOnce repoRoot =
  -- Sprint 1.47: run the mirror pulls + Harbor pushes inside an ephemeral
  -- DOCKER_CONFIG (host docker.io auth read-only for public pulls + inline Harbor
  -- auth for pushes), scrubbed on exit — no docker login, nothing persisted.
  withEphemeralDockerConfig harborAdminUser harborAdminPassword $ do
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
  ensureCustomImageVariantsForSubstrate
    substrate
    repoRoot
    CustomImageBuildPlan
      { customImageDockerfile = "docker/prodbox.Dockerfile"
      }
    [runtimeImage, latestImage]
    runtimeImage

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
  -- Sprint 1.47: build + push + Harbor pull + ctr import inside an ephemeral
  -- DOCKER_CONFIG (no docker login; the Harbor auth is inline, the base-image
  -- build pull uses the host docker.io login), scrubbed on exit.
  withEphemeralDockerConfig harborAdminUser harborAdminPassword $ do
    buildExit <- buildAndPushCustomImageVariants repoRoot imageBuildPlan taggedRefs
    case buildExit of
      ExitFailure _ -> pure buildExit
      ExitSuccess ->
        runSequentially
          [ runCommand =<< dockerSubprocessFor repoRoot ["pull", importRef]
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
    (primaryRef : _) ->
      -- Sprint 1.47: the host `docker build` base-image pull authenticates to
      -- Docker Hub via an ephemeral DOCKER_CONFIG; the Harbor push runs
      -- in-cluster (crane pod) and the `docker save` is local.
      withEphemeralDockerConfig harborAdminUser harborAdminPassword $ do
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

pushDockerImageWithRetry :: FilePath -> String -> String -> IO ExitCode
pushDockerImageWithRetry repoRoot imageRef description = go (retryPolicyMaxAttempts customImagePushRetryPolicy)
 where
  go attemptsRemaining = do
    outputResult <- captureDockerToolOutput repoRoot ["push", imageRef]
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
  pullResult <- captureDockerToolOutput repoRoot ["pull", imageRef]
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
  pullResult <- captureDockerToolOutput repoRoot ["pull", source]
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
    , "CPUQuota=" ++ show (cpuQuotaPercent (Capacity.milli_cpu (Capacity.rke2_reserved plan))) ++ "%"
    , "MemoryHigh=" ++ show (Capacity.memory_mib (Capacity.rke2_reserved plan)) ++ "M"
    , "MemoryMax=" ++ show (Capacity.memory_mib systemdMax) ++ "M"
    , "TasksMax=4096"
    ]
 where
  systemdMax = Capacity.rke2_reserved plan `Capacity.plusResourceVector` Capacity.eviction_floor plan

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
cpuQuantity value = show value ++ "m"

memoryQuantity :: Natural -> String
memoryQuantity value = show value ++ "Mi"

renderResourceVectorRuntime :: Capacity.ResourceVector -> String
renderResourceVectorRuntime vector =
  intercalate
    ","
    [ "cpu=" ++ cpuQuantity (Capacity.milli_cpu vector)
    , "memory=" ++ memoryQuantity (Capacity.memory_mib vector)
    , "ephemeral-storage=" ++ memoryQuantity (Capacity.ephemeral_storage_mib vector)
    , "durable-storage=" ++ memoryQuantity (Capacity.durable_storage_mib vector)
    ]

clusterAllocatable :: Capacity.ResourcePlan -> Capacity.ResourceVector
clusterAllocatable plan =
  Capacity.host_capacity plan
    `Capacity.resourceVectorMinus` Capacity.rke2_reserved plan
    `Capacity.resourceVectorMinus` Capacity.eviction_floor plan

hostCapacityCoversPlan :: Capacity.ResourceVector -> Capacity.ResourcePlan -> Bool
hostCapacityCoversPlan observed plan =
  Capacity.host_capacity plan `Capacity.resourceVectorFitsWithin` observed

parseHostCapacityObservation :: String -> Either String Capacity.ResourceVector
parseHostCapacityObservation raw =
  Capacity.ResourceVector
    <$> lookupNatural "milli_cpu"
    <*> lookupNatural "memory_mib"
    <*> lookupNatural "ephemeral_storage_mib"
    <*> lookupNatural "durable_storage_mib"
 where
  fields = map splitField (splitOnChar ',' raw)
  lookupNatural key =
    case lookup key fields of
      Just value -> parseNatural key value
      Nothing -> Left ("missing host capacity field `" ++ key ++ "`")
  splitField field =
    case break (== '=') field of
      (key, '=' : value) -> (trimWhitespace key, trimWhitespace value)
      _ -> (trimWhitespace field, "")

parseNatural :: String -> String -> Either String Natural
parseNatural key value =
  case reads value of
    [(parsed, "")] -> Right parsed
    _ -> Left ("invalid natural for `" ++ key ++ "`: " ++ value)

splitOnChar :: Char -> String -> [String]
splitOnChar _ "" = [""]
splitOnChar delimiter input =
  case break (== delimiter) input of
    (before, _ : remaining) -> before : splitOnChar delimiter remaining
    (before, []) -> [before]

observeHostCapacity :: FilePath -> IO (Either String Capacity.ResourceVector)
observeHostCapacity repoRoot = do
  override <- lookupEnv "PRODBOX_TEST_HOST_CAPACITY"
  case override of
    Just raw -> pure (parseHostCapacityObservation raw)
    Nothing -> observeHostCapacityFromHost repoRoot

observeHostCapacityFromHost :: FilePath -> IO (Either String Capacity.ResourceVector)
observeHostCapacityFromHost repoRoot = do
  cpuResult <- observedCpuMilli repoRoot
  memoryResult <- observedMemoryMib
  storageResult <- observedFilesystemMib repoRoot "/"
  pure $ do
    cpu <- cpuResult
    memory <- memoryResult
    storage <- storageResult
    Right
      Capacity.ResourceVector
        { Capacity.milli_cpu = cpu
        , Capacity.memory_mib = memory
        , Capacity.ephemeral_storage_mib = storage
        , Capacity.durable_storage_mib = storage
        }

observedCpuMilli :: FilePath -> IO (Either String Natural)
observedCpuMilli repoRoot = do
  outputResult <- captureToolOutput repoRoot "nproc" []
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitFailure _ -> Left ("failed to observe host CPU count: " ++ outputDetail output)
      ExitSuccess -> (* 1000) <$> parseNatural "nproc" (trimWhitespace (processStdout output))

observedMemoryMib :: IO (Either String Natural)
observedMemoryMib = do
  meminfoResult <- try (readFile "/proc/meminfo") :: IO (Either IOException String)
  pure $ do
    meminfo <- either (Left . displayException) Right meminfoResult
    line <-
      maybe
        (Left "failed to observe host memory: /proc/meminfo has no MemTotal line")
        Right
        (find ("MemTotal:" `isPrefixOf`) (lines meminfo))
    case words line of
      ["MemTotal:", kibText, "kB"] -> (`div` 1024) <$> parseNatural "MemTotal" kibText
      _ -> Left ("failed to parse host memory line: " ++ line)

observedFilesystemMib :: FilePath -> FilePath -> IO (Either String Natural)
observedFilesystemMib repoRoot path = do
  outputResult <- captureToolOutput repoRoot "df" ["-Pm", path]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitFailure _ -> Left ("failed to observe filesystem capacity for " ++ path ++ ": " ++ outputDetail output)
      ExitSuccess ->
        case drop 1 (lines (processStdout output)) of
          line : _ ->
            case words line of
              _filesystem : blocks : _ -> parseNatural "df-1M-blocks" blocks
              _ -> Left ("failed to parse df output line: " ++ line)
          [] -> Left "failed to parse df output: missing data line"

ensureRke2ResourceGuardrails :: FilePath -> ValidatedSettings -> IO ExitCode
ensureRke2ResourceGuardrails repoRoot settings = do
  observedResult <- observeHostCapacity repoRoot
  case observedResult of
    Left err -> failWith ("failed to observe host capacity before RKE2 reconcile: " ++ err)
    Right observed -> do
      let plan = Capacity.resource_plan (capacity (validatedConfig settings))
          authored = Capacity.host_capacity plan
      if not (hostCapacityCoversPlan observed plan)
        then
          failWith
            ( "observed host capacity is below capacity.resource_plan.host_capacity: observed="
                ++ renderResourceVectorRuntime observed
                ++ " required="
                ++ renderResourceVectorRuntime authored
            )
        else do
          writeOutputLine
            ( "RKE2 resource guardrails: host capacity ok (observed="
                ++ renderResourceVectorRuntime observed
                ++ ", required="
                ++ renderResourceVectorRuntime authored
                ++ ")"
            )
          runSequentially
            [ ensureRootFileContent
                repoRoot
                rke2ResourceGuardrailConfigPath
                (renderRke2ResourceGuardrailConfig plan)
                "RKE2 kubelet resource guardrails"
            , ensureRootFileContent
                repoRoot
                rke2SystemdResourceDropInPath
                (renderRke2SystemdResourceDropIn plan)
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

renderRetainedStateNotice :: FilePath -> FilePath -> IO ExitCode
renderRetainedStateNotice _repoRoot retainedManualPvRoot = do
  writeOutputLine "Local cluster uninstalled. Preserved host state:"
  writeOutputLine ("  - manual PV root: " ++ retainedManualPvRoot)
  writeOutputLine ("  - `.data/` (MinIO-backed per-run Pulumi state) is preserved")
  writeOutputLine ("  - Vault durable PV: " ++ retainedManualPvRoot </> "vault" </> "vault" </> "0")
  writeOutputLine
    "Per-run AWS stacks (if any) were NOT destroyed by this local uninstall. To destroy them, run `prodbox cluster delete --cascade` or `prodbox aws stack <name> destroy --yes`."
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
