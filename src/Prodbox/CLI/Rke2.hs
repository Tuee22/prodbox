{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Rke2 (
    runRke2Command,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (
    IOException,
    bracket,
    displayException,
    finally,
    try,
 )
import Control.Monad (foldM)
import Data.Aeson (
    FromJSON (parseJSON),
    Value,
    eitherDecode,
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (
    isHexDigit,
    isSpace,
    toLower,
 )
import Data.List (
    intercalate,
    isInfixOf,
    isPrefixOf,
    nub,
 )
import Data.Text qualified as Text
import Prodbox.CLI.Command (
    PulumiCommand (..),
    Rke2Command (..),
 )
import Prodbox.CLI.Pulumi (runPulumiCommand)
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Dns (fetchPublicIp)
import Prodbox.Host (
    LanAddressing (..),
    detectLanAddressing,
 )
import Prodbox.PostgresPlatform (
    patroniOperatorDeploymentName,
    patroniOperatorNamespace,
    patroniOperatorReleaseName,
    patroniPostgresqlCrdName,
 )
import Prodbox.Result (Result (..))
import Prodbox.Settings (
    AcmeSection (..),
    ConfigFile (..),
    Credentials (..),
    DeploymentSection (..),
    DomainSection (..),
    Route53Section (..),
    ValidatedSettings (..),
    access_key_id,
    acme,
    aws,
    bootstrap_public_ip_override,
    demo_fqdn,
    demo_ttl,
    domain,
    eab_hmac_key,
    eab_key_id,
    email,
    pulumi_enable_dns_bootstrap,
    region,
    route53,
    secret_access_key,
    server,
    session_token,
    validateAndLoadSettings,
    validatedConfig,
    zone_id,
 )
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
    runStreamingCommand,
 )
import System.Directory (
    doesDirectoryExist,
    doesFileExist,
    getHomeDirectory,
    getTemporaryDirectory,
    listDirectory,
    removeFile,
 )
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (
    ExitCode (ExitFailure, ExitSuccess),
 )
import System.FilePath (
    takeDirectory,
    (</>),
 )
import System.IO (
    hClose,
    hPutStr,
    hPutStrLn,
    openTempFile,
    stderr,
 )
import System.Info (os)

rke2BinaryPath :: FilePath
rke2BinaryPath = "/usr/local/bin/rke2"

rke2ConfigPath :: FilePath
rke2ConfigPath = "/etc/rancher/rke2/config.yaml"

rke2KubeconfigPath :: FilePath
rke2KubeconfigPath = "/etc/rancher/rke2/rke2.yaml"

rke2RegistriesPath :: FilePath
rke2RegistriesPath = "/etc/rancher/rke2/registries.yaml"

rke2UninstallPath :: FilePath
rke2UninstallPath = "/usr/local/bin/rke2-uninstall.sh"

rke2ServiceName :: String
rke2ServiceName = "rke2-server.service"

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

traefikNamespace :: String
traefikNamespace = "traefik-system"

traefikReleaseName :: String
traefikReleaseName = "traefik"

traefikRepositoryName :: String
traefikRepositoryName = "traefik"

traefikRepositoryUrl :: String
traefikRepositoryUrl = "https://traefik.github.io/charts"

traefikChartRef :: String
traefikChartRef = "traefik/traefik"

traefikChartVersion :: String
traefikChartVersion = "32.0.0"

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

perconaPostgresOperatorAppName :: String
perconaPostgresOperatorAppName = "pg-operator"

chartClusterIssuer :: String
chartClusterIssuer = "letsencrypt-http01"

route53CredentialsSecretName :: String
route53CredentialsSecretName = "route53-credentials"

acmeEabSecretName :: String
acmeEabSecretName = "acme-eab-credentials"

acmeEabSecretKey :: String
acmeEabSecretKey = "secret"

buildxBuilderName :: String
buildxBuilderName = "prodbox-multiarch-hostnet"

data MinioImageSource
    = MinioBootstrapPublic
    | MinioSteadyStateHarbor
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
    , traefikNamespace
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
    , "traefik"
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
    , ".traefik.io"
    , ".containo.us"
    , ".pgv2.percona.com"
    , ".postgres-operator.crunchydata.com"
    ]

runRke2Command :: FilePath -> Rke2Command -> IO ExitCode
runRke2Command repoRoot command =
    case command of
        Rke2Status ->
            requireLinux $
                runCommand
                    CommandSpec
                        { commandPath = "systemctl"
                        , commandArguments = ["is-active", rke2ServiceName]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
        Rke2Start ->
            requireLinux $
                runCommand
                    CommandSpec
                        { commandPath = "sudo"
                        , commandArguments = ["systemctl", "start", rke2ServiceName]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
        Rke2Stop ->
            requireLinux $
                runCommand
                    CommandSpec
                        { commandPath = "sudo"
                        , commandArguments = ["systemctl", "stop", rke2ServiceName]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
        Rke2Restart ->
            requireLinux $
                runCommand
                    CommandSpec
                        { commandPath = "sudo"
                        , commandArguments = ["systemctl", "restart", rke2ServiceName]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
        Rke2Install -> requireLinux (runNativeInstall repoRoot)
        Rke2Delete confirmed ->
            requireLinux $
                if confirmed
                    then runNativeDelete repoRoot
                    else failWith "rke2 delete requires --yes confirmation"
        Rke2Logs maybeLines ->
            requireLinux $
                case normalizeLogLines maybeLines of
                    Left err -> failWith err
                    Right linesToShow ->
                        runCommand
                            CommandSpec
                                { commandPath = "journalctl"
                                , commandArguments =
                                    [ "-u"
                                    , rke2ServiceName
                                    , "-n"
                                    , show linesToShow
                                    , "--no-pager"
                                    ]
                                , commandEnvironment = Nothing
                                , commandWorkingDirectory = Just repoRoot
                                }

runNativeInstall :: FilePath -> IO ExitCode
runNativeInstall repoRoot = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> failWith err
        Right settings -> do
            identityResult <- resolveMachineIdentity
            case identityResult of
                Left err -> failWith err
                Right (machineId, prodboxId) ->
                    let labelValue = prodboxIdToLabelValue prodboxId
                     in runSequentially
                            [ ensureRke2ServerInstalled repoRoot
                            , ensureRke2IngressController repoRoot
                            , runCommand
                                CommandSpec
                                    { commandPath = "sudo"
                                    , commandArguments = ["systemctl", "enable", rke2ServiceName]
                                    , commandEnvironment = Nothing
                                    , commandWorkingDirectory = Just repoRoot
                                    }
                            , runCommand
                                CommandSpec
                                    { commandPath = "sudo"
                                    , commandArguments = ["systemctl", "restart", rke2ServiceName]
                                    , commandEnvironment = Nothing
                                    , commandWorkingDirectory = Just repoRoot
                                    }
                            , syncUserKubeconfig repoRoot
                            , verifyClusterInfo repoRoot
                            , waitForClusterNodesReady repoRoot
                            , deleteNonManualStorageClasses repoRoot
                            , ensureProdboxIdentityConfigMap repoRoot machineId prodboxId labelValue
                            , ensureRetainedLocalStorage repoRoot settings prodboxId labelValue
                            , ensureHarborRegistryRuntime repoRoot
                            , ensureMinioRuntime repoRoot MinioBootstrapPublic
                            , mirrorClusterImagesOnce repoRoot
                            , ensureGatewayImages repoRoot prodboxId
                            , ensureVscodeNginxImage repoRoot
                            , ensureRke2RegistriesConfig repoRoot
                            , ensureClusterPlatformRuntime repoRoot settings prodboxId labelValue
                            , reconcileDnsBootstrapRecord repoRoot settings
                            , ensureMinioRuntime repoRoot MinioSteadyStateHarbor
                            , reconcileManagedAnnotations repoRoot prodboxId labelValue
                            ]

runNativeDelete :: FilePath -> IO ExitCode
runNativeDelete repoRoot = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> failWith err
        Right settings -> do
            putStrLn "Deleting local RKE2 environment..."
            runSequentially
                [ runPulumiCommand repoRoot (PulumiEksDestroy True)
                , runPulumiCommand repoRoot (PulumiTestDestroy True)
                , deleteRke2ClusterSubstrate repoRoot
                , removeCalicoEndpointStatusResidue
                , removeManagedKubeconfig
                , renderRetainedStateNotice repoRoot settings
                ]

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
                                            CommandSpec
                                                { commandPath = "sudo"
                                                , commandArguments = ["env", "INSTALL_RKE2_TYPE=server", "sh", installerPath]
                                                , commandEnvironment = Nothing
                                                , commandWorkingDirectory = Just repoRoot
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
                        CommandSpec
                            { commandPath = "sudo"
                            , commandArguments = ["mkdir", "-p", takeDirectory targetPath]
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Just repoRoot
                            }
                    , runCommand
                        CommandSpec
                            { commandPath = "sudo"
                            , commandArguments = ["cp", rke2KubeconfigPath, targetPath]
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Just repoRoot
                            }
                    , runCommand
                        CommandSpec
                            { commandPath = "sudo"
                            , commandArguments = ["chown", ownerSpec, targetPath]
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Just repoRoot
                            }
                    , runCommand
                        CommandSpec
                            { commandPath = "chmod"
                            , commandArguments = ["600", targetPath]
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Just repoRoot
                            }
                    ]

verifyClusterInfo :: FilePath -> IO ExitCode
verifyClusterInfo repoRoot =
    runCommand
        CommandSpec
            { commandPath = "kubectl"
            , commandArguments = ["cluster-info"]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Just repoRoot
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
                                        CommandSpec
                                            { commandPath = "kubectl"
                                            , commandArguments =
                                                [ "wait"
                                                , "--for=condition=Ready"
                                                , "node"
                                                , "--all"
                                                , "--timeout=300s"
                                                ]
                                            , commandEnvironment = Nothing
                                            , commandWorkingDirectory = Just repoRoot
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
                                CommandSpec
                                    { commandPath = "kubectl"
                                    , commandArguments = ["delete", "storageclass", ref, "--ignore-not-found=true"]
                                    , commandEnvironment = Nothing
                                    , commandWorkingDirectory = Just repoRoot
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
                    pvPhaseResult <- captureKubectl repoRoot ["get", "pv", minioPersistentVolume, "-o", "jsonpath={.status.phase}", "--ignore-not-found=true"]
                    case pvPhaseResult of
                        Left err -> failWith err
                        Right pvPhaseOutput -> do
                            let existingPhase = trimWhitespace (processStdout pvPhaseOutput)
                            resetExit <-
                                if existingPhase `elem` ["Released", "Failed"]
                                    then
                                        runCommand
                                            CommandSpec
                                                { commandPath = "kubectl"
                                                , commandArguments = ["delete", "pv", minioPersistentVolume, "--ignore-not-found=true", "--wait=true"]
                                                , commandEnvironment = Nothing
                                                , commandWorkingDirectory = Just repoRoot
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

ensureMinioRuntime :: FilePath -> MinioImageSource -> IO ExitCode
ensureMinioRuntime repoRoot imageSource = do
    repoAddResult <- captureToolOutput repoRoot "helm" ["repo", "add", minioRepositoryName, minioRepositoryUrl]
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
        let (minioImage, minioMcImage) = minioChartImages imageSource
         in runSequentially
                [ runCommand
                    CommandSpec
                        { commandPath = "helm"
                        , commandArguments = ["repo", "update"]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
                , runCommand
                    CommandSpec
                        { commandPath = "helm"
                        , commandArguments =
                            [ "upgrade"
                            , "--install"
                            , minioReleaseName
                            , minioChartRef
                            , "--version"
                            , minioChartVersion
                            , "--namespace"
                            , minioNamespace
                            , "--create-namespace"
                            , "--set"
                            , "mode=standalone"
                            , "--set"
                            , "replicas=1"
                            , "--set"
                            , "persistence.enabled=true"
                            , "--set"
                            , "persistence.existingClaim=minio"
                            , "--set"
                            , "image.repository=" ++ renderImageRefWithoutTag minioImage
                            , "--set"
                            , "image.tag=" ++ ContainerImage.imageTag minioImage
                            , "--set"
                            , "mcImage.repository=" ++ renderImageRefWithoutTag minioMcImage
                            , "--set"
                            , "mcImage.tag=" ++ ContainerImage.imageTag minioMcImage
                            , "--set"
                            , "persistence.size=200Gi"
                            , "--set"
                            , "service.type=ClusterIP"
                            , "--set"
                            , "consoleService.type=ClusterIP"
                            , "--set"
                            , "resources.requests.memory=256Mi"
                            , "--set"
                            , "resources.requests.cpu=100m"
                            , "--set"
                            , "resources.limits.memory=512Mi"
                            ]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
                , runCommand
                    CommandSpec
                        { commandPath = "kubectl"
                        , commandArguments =
                            [ "wait"
                            , "--for=condition=Available"
                            , "deployment/minio"
                            , "-n"
                            , minioNamespace
                            , "--timeout=300s"
                            ]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
                ]

minioChartImages :: MinioImageSource -> (ContainerImage.ImageRef, ContainerImage.ImageRef)
minioChartImages imageSource =
    case imageSource of
        MinioBootstrapPublic ->
            (ContainerImage.publicMinioImage, ContainerImage.publicMinioMcImage)
        MinioSteadyStateHarbor ->
            (ContainerImage.harborMinioImage, ContainerImage.harborMinioMcImage)

ensureHarborRegistryRuntime :: FilePath -> IO ExitCode
ensureHarborRegistryRuntime repoRoot = do
    repoAddResult <- captureToolOutput repoRoot "helm" ["repo", "add", harborRepositoryName, harborRepositoryUrl]
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
        existingHarborHealthy <- harborRuntimeAlreadyHealthy repoRoot
        installExit <-
            if existingHarborHealthy
                then pure ExitSuccess
                else
                    runSequentially
                        [ runCommand
                            CommandSpec
                                { commandPath = "helm"
                                , commandArguments = ["repo", "update"]
                                , commandEnvironment = Nothing
                                , commandWorkingDirectory = Just repoRoot
                                }
                        , runCommand
                            CommandSpec
                                { commandPath = "helm"
                                , commandArguments =
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
                                    ]
                                , commandEnvironment = Nothing
                                , commandWorkingDirectory = Just repoRoot
                                }
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
                                    ExitSuccess -> do
                                        loginExit <-
                                            runCommand
                                                CommandSpec
                                                    { commandPath = "docker"
                                                    , commandArguments = ["login", harborRegistryEndpoint, "--username", harborAdminUser, "--password", harborAdminPassword]
                                                    , commandEnvironment = Nothing
                                                    , commandWorkingDirectory = Just repoRoot
                                                    }
                                        case loginExit of
                                            ExitFailure _ -> pure loginExit
                                            ExitSuccess ->
                                                runSequentially
                                                    [ ensureHarborProject repoRoot projectName
                                                    | projectName <- nub [harborMirrorProject, harborProjectFromRepository harborGatewayRepository]
                                                    ]

harborRuntimeAlreadyHealthy :: FilePath -> IO Bool
harborRuntimeAlreadyHealthy repoRoot = do
    deploymentsPresent <- harborDeploymentsExist repoRoot
    if not deploymentsPresent
        then pure False
        else do
            readyStatusResult <- probeHarborHttpStatus repoRoot harborReadyPath
            registryStatusResult <- probeHarborHttpStatus repoRoot "/v2/"
            pure $
                case (readyStatusResult, registryStatusResult) of
                    (Right "200", Right registryStatus) -> registryStatus `elem` ["200", "401"]
                    _ -> False

harborDeploymentsExist :: FilePath -> IO Bool
harborDeploymentsExist repoRoot = do
    outputResult <-
        captureKubectl
            repoRoot
            [ "get"
            , "deployment"
            , harborComponentName harborReleaseName "core"
            , harborComponentName harborReleaseName "registry"
            , harborComponentName harborReleaseName "nginx"
            , "-n"
            , harborNamespace
            , "-o"
            , "name"
            ]
    pure $
        case outputResult of
            Left _ -> False
            Right output ->
                processExitCode output == ExitSuccess
                    && trimWhitespace (processStdout output) /= ""

waitForDeployment :: FilePath -> String -> String -> IO ExitCode
waitForDeployment repoRoot namespace deploymentName =
    runCommand
        CommandSpec
            { commandPath = "kubectl"
            , commandArguments =
                [ "wait"
                , "--for=condition=Available"
                , "deployment/" ++ deploymentName
                , "-n"
                , namespace
                , "--timeout=300s"
                ]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Just repoRoot
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
                                                                         ] ::
                                                                            [Value]
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
        Right (metallbPool, ingressLbIp) ->
            runSequentially
                [ ensureMetalLbRuntime repoRoot prodboxId labelValue metallbPool
                , ensureTraefikRuntime repoRoot prodboxId labelValue ingressLbIp
                , ensureCertManagerRuntime repoRoot prodboxId labelValue
                , ensureAcmeRuntime repoRoot settings prodboxId labelValue
                , ensurePostgresOperatorRuntime repoRoot prodboxId labelValue
                ]

resolveClusterPlatformLanDefaults :: IO (Either String (String, String))
resolveClusterPlatformLanDefaults = do
    maybeMetallbPool <- lookupNonEmptyEnv "PRODBOX_PULUMI_METALLB_POOL"
    maybeIngressLbIp <- lookupNonEmptyEnv "PRODBOX_PULUMI_INGRESS_LB_IP"
    case (maybeMetallbPool, maybeIngressLbIp) of
        (Just metallbPool, Just ingressLbIp) -> pure (Right (metallbPool, ingressLbIp))
        (Just _, Nothing) ->
            pure
                (Left "set both PRODBOX_PULUMI_METALLB_POOL and PRODBOX_PULUMI_INGRESS_LB_IP, or set neither")
        (Nothing, Just _) ->
            pure
                (Left "set both PRODBOX_PULUMI_METALLB_POOL and PRODBOX_PULUMI_INGRESS_LB_IP, or set neither")
        (Nothing, Nothing) ->
            fmap
                ( \lanResult ->
                    case lanResult of
                        Left err ->
                            Left ("failed to derive MetalLB defaults from host networking: " ++ err)
                        Right lan -> Right (lanMetallbPool lan, lanIngressLbIp lan)
                )
                detectLanAddressing

ensureMetalLbRuntime :: FilePath -> String -> String -> String -> IO ExitCode
ensureMetalLbRuntime repoRoot prodboxId labelValue metallbPool = do
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
                    waitExit <-
                        runSequentially
                            [ rolloutStatus repoRoot metallbNamespace "deployment/metallb-controller"
                            , rolloutStatus repoRoot metallbNamespace "daemonset/metallb-speaker"
                            , waitForCrdEstablished repoRoot "ipaddresspools.metallb.io"
                            , waitForCrdEstablished repoRoot "l2advertisements.metallb.io"
                            ]
                    case waitExit of
                        ExitFailure _ -> pure waitExit
                        ExitSuccess ->
                            kubectlApplyJsonManifest
                                repoRoot
                                "prodbox-metallb-resources"
                                (metallbRuntimeManifest prodboxId labelValue metallbPool)

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

metallbRuntimeManifest :: String -> String -> String -> [Value]
metallbRuntimeManifest prodboxId labelValue metallbPool =
    [ object
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
    , object
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
    ]

ensureTraefikRuntime :: FilePath -> String -> String -> String -> IO ExitCode
ensureTraefikRuntime repoRoot prodboxId labelValue ingressLbIp = do
    repoExit <- ensureHelmRepoAdded repoRoot traefikRepositoryName traefikRepositoryUrl
    case repoExit of
        ExitFailure _ -> pure repoExit
        ExitSuccess -> do
            installExit <-
                helmUpgradeInstallWithJsonValues
                    repoRoot
                    traefikReleaseName
                    traefikChartRef
                    traefikChartVersion
                    traefikNamespace
                    (traefikHelmValues prodboxId labelValue ingressLbIp)
            case installExit of
                ExitFailure _ -> pure installExit
                ExitSuccess -> waitForDeployment repoRoot traefikNamespace traefikReleaseName

traefikHelmValues :: String -> String -> String -> Value
traefikHelmValues prodboxId labelValue ingressLbIp =
    object
        [ "image"
            .= object
                [ "registry" .= ContainerImage.imageRegistry ContainerImage.harborTraefikImage
                , "repository" .= ContainerImage.imageRepository ContainerImage.harborTraefikImage
                , "tag" .= ContainerImage.imageTag ContainerImage.harborTraefikImage
                ]
        , "service"
            .= object
                [ "type" .= ("LoadBalancer" :: String)
                , "spec" .= object ["loadBalancerIP" .= ingressLbIp]
                ]
        , "ports"
            .= object
                [ "web" .= object ["expose" .= object ["default" .= True]]
                , "websecure" .= object ["expose" .= object ["default" .= True]]
                ]
        , "ingressClass"
            .= object
                [ "name" .= ("traefik" :: String)
                , "isDefaultClass" .= False
                ]
        , "logs" .= object ["access" .= object ["enabled" .= True]]
        , "metrics" .= object ["prometheus" .= object ["entryPoint" .= ("metrics" :: String)]]
        , "commonLabels" .= object [Key.fromString prodboxLabelKey .= labelValue]
        , "commonAnnotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
        ]

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
        (acmeRuntimeManifest settings prodboxId labelValue)
        ( \manifestPath -> do
            applyExit <-
                runCommand
                    CommandSpec
                        { commandPath = "kubectl"
                        , commandArguments = ["apply", "-f", manifestPath]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
            case applyExit of
                ExitFailure _ -> pure applyExit
                ExitSuccess -> do
                    issuerWaitEnv <- awsCommandEnvironment currentEnvironment settings
                    runCommand
                        CommandSpec
                            { commandPath = "kubectl"
                            , commandArguments =
                                [ "wait"
                                , "--for=condition=Ready"
                                , "clusterissuer/" ++ chartClusterIssuer
                                , "--timeout=300s"
                                ]
                            , commandEnvironment = Just issuerWaitEnv
                            , commandWorkingDirectory = Just repoRoot
                            }
        )

acmeRuntimeManifest :: ValidatedSettings -> String -> String -> [Value]
acmeRuntimeManifest settings prodboxId labelValue =
    route53Secret : maybe [] pure maybeEabSecret ++ [clusterIssuer]
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
        object
            [ "apiVersion" .= ("cert-manager.io/v1" :: String)
            , "kind" .= ("ClusterIssuer" :: String)
            , "metadata"
                .= object
                    [ "name" .= chartClusterIssuer
                    , "annotations" .= object [Key.fromString prodboxAnnotationKey .= prodboxId]
                    , "labels" .= object [Key.fromString prodboxLabelKey .= labelValue]
                    ]
            , "spec" .= object ["acme" .= acmeClusterIssuerSpec settings]
            ]

acmeClusterIssuerSpec :: ValidatedSettings -> Value
acmeClusterIssuerSpec settings =
    object $
        [ "server" .= Text.unpack (server acmeConfig)
        , "email" .= Text.unpack (email acmeConfig)
        , "privateKeySecretRef" .= object ["name" .= ("letsencrypt-account-key" :: String)]
        , "solvers"
            .= [ object
                    [ "dns01"
                        .= object
                            [ "route53"
                                .= object
                                    [ "region" .= Text.unpack (region awsConfig)
                                    , "hostedZoneID" .= Text.unpack (zone_id (route53 config))
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
               ]
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
    removeLegacyExit <- removeLegacyPostgresOperatorIfPresent repoRoot
    case removeLegacyExit of
        ExitFailure _ -> pure removeLegacyExit
        ExitSuccess -> do
            repoExit <- ensureHelmRepoAdded repoRoot postgresOperatorRepositoryName postgresOperatorRepositoryUrl
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

removeLegacyPostgresOperatorIfPresent :: FilePath -> IO ExitCode
removeLegacyPostgresOperatorIfPresent repoRoot = do
    deploymentResult <-
        captureKubectl
            repoRoot
            [ "get"
            , "deployment"
            , patroniOperatorDeploymentName
            , "--namespace"
            , patroniOperatorNamespace
            , "-o"
            , "jsonpath={.metadata.labels.app\\.kubernetes\\.io/name}"
            ]
    case deploymentResult of
        Left err -> failWith err
        Right output ->
            case processExitCode output of
                ExitFailure _
                    | isNotFoundMessage (outputDetail output) -> pure ExitSuccess
                    | otherwise ->
                        failWith
                            ( "Failed to inspect existing PostgreSQL operator deployment: "
                                ++ outputDetail output
                            )
                ExitSuccess ->
                    let appName = trimWhitespace (processStdout output)
                     in if appName == "" || appName == perconaPostgresOperatorAppName
                            then pure ExitSuccess
                            else removeLegacyPostgresOperator repoRoot appName

removeLegacyPostgresOperator :: FilePath -> String -> IO ExitCode
removeLegacyPostgresOperator repoRoot appName = do
    uninstallResult <-
        captureToolOutput
            repoRoot
            "helm"
            ["uninstall", patroniOperatorReleaseName, "--namespace", patroniOperatorNamespace, "--wait"]
    case uninstallResult of
        Left err -> failWith err
        Right output -> do
            emitCapturedProcessOutput output
            case processExitCode output of
                ExitSuccess -> deleteLegacyOperatorNamespace repoRoot
                ExitFailure _
                    | isMissingHelmReleaseError (outputDetail output) -> deleteLegacyOperatorNamespace repoRoot
                    | otherwise ->
                        failWith
                            ( "Failed to remove incompatible PostgreSQL operator deployment `"
                                ++ patroniOperatorReleaseName
                                ++ "` labeled as `"
                                ++ appName
                                ++ "` before installing `"
                                ++ perconaPostgresOperatorAppName
                                ++ "`: "
                                ++ outputDetail output
                            )

deleteLegacyOperatorNamespace :: FilePath -> IO ExitCode
deleteLegacyOperatorNamespace repoRoot =
    runCommand
        CommandSpec
            { commandPath = "kubectl"
            , commandArguments =
                [ "delete"
                , "namespace"
                , patroniOperatorNamespace
                , "--ignore-not-found=true"
                , "--wait=true"
                , "--timeout=300s"
                ]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Just repoRoot
            }

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
                        fqdn = Text.unpack (demo_fqdn (domain config))
                        ttlValue = fromIntegral (demo_ttl (domain config)) :: Integer
                    withTemporaryJsonBytes
                        "prodbox-dns-bootstrap"
                        (encode (route53AChangeBatch "UPSERT" fqdn publicIp ttlValue))
                        ( \payloadPath ->
                            runCommand
                                CommandSpec
                                    { commandPath = "aws"
                                    , commandArguments =
                                        [ "route53"
                                        , "change-resource-record-sets"
                                        , "--hosted-zone-id"
                                        , zoneIdValue
                                        , "--change-batch"
                                        , "file://" ++ payloadPath
                                        ]
                                    , commandEnvironment = Just awsEnvironment
                                    , commandWorkingDirectory = Just repoRoot
                                    }
                        )

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
                    | otherwise -> failWith ("Failed to add Helm repo " ++ repoName ++ ": " ++ outputDetail repoAddOutput)
                ExitSuccess -> updateRepo
  where
    updateRepo =
        runCommand
            CommandSpec
                { commandPath = "helm"
                , commandArguments = ["repo", "update", repoName]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }

helmUpgradeInstallWithJsonValues :: FilePath -> String -> String -> String -> String -> Value -> IO ExitCode
helmUpgradeInstallWithJsonValues repoRoot releaseName chartRef chartVersion namespace values =
    withTemporaryJsonBytes ("prodbox-helm-values-" ++ releaseName) (encode values) $ \valuesPath ->
        runCommand
            CommandSpec
                { commandPath = "helm"
                , commandArguments =
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
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }

waitForCrdEstablished :: FilePath -> String -> IO ExitCode
waitForCrdEstablished repoRoot crdName =
    runCommand
        CommandSpec
            { commandPath = "kubectl"
            , commandArguments =
                [ "wait"
                , "--for=condition=Established"
                , "--timeout=300s"
                , "crd/" ++ crdName
                ]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Just repoRoot
            }

rolloutStatus :: FilePath -> String -> String -> IO ExitCode
rolloutStatus repoRoot namespace resourceRef =
    runCommand
        CommandSpec
            { commandPath = "kubectl"
            , commandArguments =
                [ "rollout"
                , "status"
                , resourceRef
                , "--namespace"
                , namespace
                , "--timeout=300s"
                ]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Just repoRoot
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
    pure (mergeEnvironmentEntries (awsEnvironmentEntries (aws (validatedConfig settings))) baseEnvironment)

awsEnvironmentEntries :: Credentials -> [(String, String)]
awsEnvironmentEntries credentials =
    [ ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id credentials))
    , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key credentials))
    , ("AWS_REGION", Text.unpack (region credentials))
    , ("AWS_DEFAULT_REGION", Text.unpack (region credentials))
    ]
        ++ case session_token credentials of
            Nothing -> []
            Just token -> [("AWS_SESSION_TOKEN", Text.unpack token)]

mergeEnvironmentEntries :: [(String, String)] -> [(String, String)] -> [(String, String)]
mergeEnvironmentEntries updates baseEnvironment =
    updates ++ filter (not . (`elem` updatedKeys) . fst) baseEnvironment
  where
    updatedKeys = map fst updates

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

data ManifestPlatform = ManifestPlatform
    { manifestPlatformOs :: String
    , manifestPlatformArchitecture :: String
    }

instance FromJSON ManifestPlatform where
    parseJSON =
        withObject "ManifestPlatform" $ \payload ->
            ManifestPlatform
                <$> payload .: "os"
                <*> payload .: "architecture"

data ManifestDescriptor = ManifestDescriptor
    { manifestDescriptorDigest :: Maybe String
    , manifestDescriptorPlatform :: Maybe ManifestPlatform
    }

instance FromJSON ManifestDescriptor where
    parseJSON =
        withObject "ManifestDescriptor" $ \payload ->
            ManifestDescriptor
                <$> payload .:? "digest"
                <*> payload .:? "platform"

data RawImageManifest = RawImageManifest
    { rawImageManifestManifests :: Maybe [ManifestDescriptor]
    , rawImageManifestOs :: Maybe String
    , rawImageManifestArchitecture :: Maybe String
    }

instance FromJSON RawImageManifest where
    parseJSON =
        withObject "RawImageManifest" $ \payload ->
            RawImageManifest
                <$> payload .:? "manifests"
                <*> payload .:? "os"
                <*> payload .:? "architecture"

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
    targetPlatformsResult <- inspectImagePlatforms repoRoot target
    case targetPlatformsResult of
        Left err -> failWith err
        Right (Just targetPlatforms)
            | supportsCanonicalImagePlatforms targetPlatforms -> pure ExitSuccess
        Right _ -> do
            mirrorResult <- mirrorCanonicalTargetFromCandidates repoRoot sourceCandidates target
            case mirrorResult of
                Left err -> failWith err
                Right () -> pure ExitSuccess

ensureGatewayImages :: FilePath -> String -> IO ExitCode
ensureGatewayImages repoRoot prodboxId = do
    let gatewayTag = prodboxIdToLabelValue prodboxId
        gatewayImage = ContainerImage.harborGatewayImageRepository ++ ":" ++ gatewayTag
        latestImage = ContainerImage.harborGatewayImageRepository ++ ":latest"
    ensureCustomImageVariants
        repoRoot
        CustomImageBuildPlan
            { customImageDockerfile = "docker/gateway.Dockerfile"
            }
        [gatewayImage, latestImage]
        gatewayImage

ensureVscodeNginxImage :: FilePath -> IO ExitCode
ensureVscodeNginxImage repoRoot = do
    let imageRef = ContainerImage.renderImageRef ContainerImage.harborVscodeNginxImage
    ensureCustomImageVariants
        repoRoot
        CustomImageBuildPlan
            { customImageDockerfile = "docker/nginx-oidc.Dockerfile"
            }
        [imageRef]
        imageRef

ensureCustomImageVariants :: FilePath -> CustomImageBuildPlan -> [String] -> String -> IO ExitCode
ensureCustomImageVariants repoRoot buildPlan taggedRefs importRef = do
    readinessResult <- mapM (inspectImagePlatforms repoRoot) taggedRefs
    case sequence readinessResult of
        Left err -> failWith err
        Right maybePlatforms -> do
            let allTargetsReady = all (maybe False supportsCanonicalImagePlatforms) maybePlatforms
            buildExit <-
                if allTargetsReady
                    then pure ExitSuccess
                    else withDockerBuildxBuilder repoRoot (buildMissingCustomImageVariants repoRoot buildPlan taggedRefs)
            case buildExit of
                ExitFailure _ -> pure buildExit
                ExitSuccess ->
                    runSequentially
                        [ runCommand
                            CommandSpec
                                { commandPath = "docker"
                                , commandArguments = ["pull", importRef]
                                , commandEnvironment = Nothing
                                , commandWorkingDirectory = Just repoRoot
                                }
                        , importImageIntoRke2Containerd repoRoot importRef
                        ]

buildMissingCustomImageVariants :: FilePath -> CustomImageBuildPlan -> [String] -> IO ExitCode
buildMissingCustomImageVariants repoRoot buildPlan taggedRefs =
    runCommand
        CommandSpec
            { commandPath = "docker"
            , commandArguments =
                [ "buildx"
                , "build"
                , "--platform"
                , canonicalPlatformArgument
                , "--push"
                , "-f"
                , customImageDockerfile buildPlan
                ]
                    ++ concat [["-t", tagRef] | tagRef <- taggedRefs]
                    ++ ["."]
            , commandEnvironment = Nothing
            , commandWorkingDirectory = Just repoRoot
            }

inspectImagePlatforms :: FilePath -> String -> IO (Either String (Maybe [(String, String)]))
inspectImagePlatforms repoRoot imageRef = do
    manifestResult <- inspectRawImageManifest repoRoot imageRef
    pure (fmap (fmap manifestPlatforms) manifestResult)

inspectRawImageManifest :: FilePath -> String -> IO (Either String (Maybe RawImageManifest))
inspectRawImageManifest repoRoot imageRef = do
    inspectResult <- captureToolOutput repoRoot "docker" ["buildx", "imagetools", "inspect", "--raw", imageRef]
    pure $
        case inspectResult of
            Left err -> Left err
            Right output ->
                case processExitCode output of
                    ExitSuccess ->
                        case eitherDecode (BL8.pack (processStdout output)) of
                            Left decodeErr ->
                                Left
                                    ( "Failed to decode raw image manifest for "
                                        ++ imageRef
                                        ++ ": "
                                        ++ decodeErr
                                    )
                            Right manifest -> Right (Just manifest)
                    ExitFailure _ ->
                        if isBuildxUnavailable (outputDetail output)
                            then Left "docker buildx imagetools support is required for the Harbor multi-arch reconcile path"
                            else
                                if isMissingImageInspectError (outputDetail output)
                                    || isHarborUnauthorizedInspectError imageRef (outputDetail output)
                                    then Right Nothing
                                    else Left (outputDetail output)

isMissingImageInspectError :: String -> Bool
isMissingImageInspectError detail =
    let lowered = map toLower detail
     in any
            (`isInfixOf` lowered)
            [ "not found"
            , "manifest unknown"
            , "name unknown"
            , "no such manifest"
            , "repository does not exist"
            ]

isHarborUnauthorizedInspectError :: String -> String -> Bool
isHarborUnauthorizedInspectError imageRef detail =
    let lowered = map toLower detail
     in isHarborHostedImage imageRef
            && "unexpected status from head request" `isInfixOf` lowered
            && "401 unauthorized" `isInfixOf` lowered

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
                    , "http://" ++ harborRegistryEndpoint ++ "/api/v2.0/projects/" ++ projectName ++ "/repositories/" ++ encodeHarborRepositoryName repositoryName
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

pushCanonicalMirrorTarget :: FilePath -> String -> RawImageManifest -> String -> IO (Either String ())
pushCanonicalMirrorTarget repoRoot source sourceManifest target =
    case buildCanonicalMirrorSourceRefs source sourceManifest of
        Left err -> pure (Left err)
        Right sourceRefs ->
            do
                createResult <-
                    captureToolOutput
                        repoRoot
                        "docker"
                        (["buildx", "imagetools", "create", "--tag", target] ++ sourceRefs)
                case createResult of
                    Left err -> pure (Left err)
                    Right output ->
                        case processExitCode output of
                            ExitSuccess -> do
                                emitCapturedProcessOutput output
                                pure (Right ())
                            ExitFailure _ -> pure (Left (outputDetail output))

buildCanonicalMirrorSourceRefs :: String -> RawImageManifest -> Either String [String]
buildCanonicalMirrorSourceRefs source sourceManifest = do
    imageRef <- ContainerImage.parseImageRef source
    descriptors <-
        case rawImageManifestManifests sourceManifest of
            Just manifestDescriptors -> Right manifestDescriptors
            Nothing -> Left ("Source image is missing manifest descriptors for Harbor mirroring: " ++ source)
    traverse (buildPlatformSourceRef imageRef descriptors) ContainerImage.canonicalImagePlatforms
  where
    buildPlatformSourceRef imageRef descriptors (osName, architecture) =
        case [ digest
             | descriptor <- descriptors
             , Just platform <- [manifestDescriptorPlatform descriptor]
             , manifestPlatformOs platform == osName
             , manifestPlatformArchitecture platform == architecture
             , Just digest <- [manifestDescriptorDigest descriptor]
             ] of
            digest : _ ->
                Right (renderDigestedImageRef imageRef digest)
            [] ->
                Left
                    ( "Source image is missing a published digest for "
                        ++ osName
                        ++ "/"
                        ++ architecture
                        ++ ": "
                        ++ source
                    )

mirrorCanonicalTargetFromCandidates :: FilePath -> [String] -> String -> IO (Either String ())
mirrorCanonicalTargetFromCandidates repoRoot sourceCandidates target = go [] sourceCandidates
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
        sourceManifestResult <- inspectRawImageManifest repoRoot source
        case sourceManifestResult of
            Left err
                | isFatalMirrorCandidateError err -> pure (Left err)
                | otherwise ->
                    go
                        (("Failed to inspect candidate source " ++ source ++ ": " ++ err) : diagnostics)
                        remainingSources
            Right (Just sourceManifest)
                | supportsCanonicalImagePlatforms (manifestPlatforms sourceManifest) ->
                    do
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
                                pushResult <- pushCanonicalMirrorTarget repoRoot source sourceManifest target
                                case pushResult of
                                    Right () -> pure (Right ())
                                    Left err
                                        | isFatalMirrorCandidateError err -> pure (Left err)
                                        | otherwise ->
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
                | otherwise ->
                    go
                        ( ( "Image "
                                ++ source
                                ++ " does not publish both linux/amd64 and linux/arm64 variants"
                          )
                            : diagnostics
                        )
                        remainingSources
            Right Nothing ->
                go
                    (("Source image is unavailable for Harbor mirroring: " ++ source) : diagnostics)
                    remainingSources

isFatalMirrorCandidateError :: String -> Bool
isFatalMirrorCandidateError detail =
    "docker buildx imagetools support is required" `isInfixOf` map toLower detail

mergeMirrorCandidatePairs :: [([String], String)] -> [([String], String)]
mergeMirrorCandidatePairs = foldl mergePair []
  where
    mergePair [] (sources, target) = [(nub sources, target)]
    mergePair ((existingSources, existingTarget) : rest) (sources, target)
        | target == existingTarget = (nub (existingSources ++ sources), target) : rest
        | otherwise = (existingSources, existingTarget) : mergePair rest (sources, target)

renderDigestedImageRef :: ContainerImage.ImageRef -> String -> String
renderDigestedImageRef imageRef digest =
    ContainerImage.imageRegistry imageRef ++ "/" ++ ContainerImage.imageRepository imageRef ++ "@" ++ digest

ensureDockerBuildxBuilder :: FilePath -> IO ExitCode
ensureDockerBuildxBuilder repoRoot = do
    createResult <-
        captureToolOutput
            repoRoot
            "docker"
            [ "buildx"
            , "create"
            , "--name"
            , buildxBuilderName
            , "--driver"
            , "docker-container"
            , "--driver-opt"
            , "network=host"
            , "--use"
            ]
    case createResult of
        Left err -> failWith err
        Right output ->
            case processExitCode output of
                ExitSuccess -> bootstrapBuilder
                ExitFailure _
                    | buildxBuilderAlreadyExists (outputDetail output) -> useAndBootstrapBuilder
                    | isBuildxUnavailable (outputDetail output) ->
                        failWith "docker buildx support is required for multi-platform custom image builds"
                    | otherwise ->
                        failWith ("Failed to create Docker buildx builder: " ++ outputDetail output)
  where
    useAndBootstrapBuilder =
        runSequentially
            [ runCommand
                CommandSpec
                    { commandPath = "docker"
                    , commandArguments = ["buildx", "use", buildxBuilderName]
                    , commandEnvironment = Nothing
                    , commandWorkingDirectory = Just repoRoot
                    }
            , bootstrapBuilder
            ]

    bootstrapBuilder =
        runCommand
            CommandSpec
                { commandPath = "docker"
                , commandArguments = ["buildx", "inspect", "--bootstrap", buildxBuilderName]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }

buildxBuilderAlreadyExists :: String -> Bool
buildxBuilderAlreadyExists detail =
    let lowered = map toLower detail
     in "existing instance" `isInfixOf` lowered || "already exists" `isInfixOf` lowered

withDockerBuildxBuilder :: FilePath -> IO ExitCode -> IO ExitCode
withDockerBuildxBuilder repoRoot action = do
    builderExit <- ensureDockerBuildxBuilder repoRoot
    case builderExit of
        ExitFailure _ -> pure builderExit
        ExitSuccess ->
            action `finally` stopDockerBuildxBuilder repoRoot

stopDockerBuildxBuilder :: FilePath -> IO ()
stopDockerBuildxBuilder repoRoot = do
    stopResult <- captureToolOutput repoRoot "docker" ["buildx", "stop", buildxBuilderName]
    case stopResult of
        Left err ->
            hPutStrLn stderr ("Warning: failed to stop Docker buildx builder " ++ buildxBuilderName ++ ": " ++ err)
        Right output ->
            case processExitCode output of
                ExitSuccess -> pure ()
                ExitFailure _ ->
                    hPutStrLn
                        stderr
                        ( "Warning: failed to stop Docker buildx builder "
                            ++ buildxBuilderName
                            ++ ": "
                            ++ outputDetail output
                        )

manifestPlatforms :: RawImageManifest -> [(String, String)]
manifestPlatforms manifest =
    nub $
        case rawImageManifestManifests manifest of
            Just descriptors ->
                [ (manifestPlatformOs platform, manifestPlatformArchitecture platform)
                | descriptor <- descriptors
                , Just platform <- [manifestDescriptorPlatform descriptor]
                ]
            Nothing ->
                case (rawImageManifestOs manifest, rawImageManifestArchitecture manifest) of
                    (Just osName, Just architecture) -> [(osName, architecture)]
                    _ -> []

supportsCanonicalImagePlatforms :: [(String, String)] -> Bool
supportsCanonicalImagePlatforms platforms =
    all (`elem` platforms) ContainerImage.canonicalImagePlatforms

canonicalPlatformArgument :: String
canonicalPlatformArgument = "linux/amd64,linux/arm64"

isBuildxUnavailable :: String -> Bool
isBuildxUnavailable detail =
    let lowered = map toLower detail
     in "buildx" `isInfixOf` lowered
            && ("not a docker command" `isInfixOf` lowered || "unknown command" `isInfixOf` lowered)

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
                        CommandSpec
                            { commandPath = "docker"
                            , commandArguments = ["save", "-o", archivePath, imageRef]
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Just repoRoot
                            }
                    , runCommand
                        CommandSpec
                            { commandPath = "sudo"
                            , commandArguments = ["ctr", "--address", socketPath, "-n", "k8s.io", "images", "import", archivePath]
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Just repoRoot
                            }
                    ]

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
                                        CommandSpec
                                            { commandPath = "sudo"
                                            , commandArguments = ["systemctl", "restart", rke2ServiceName]
                                            , commandEnvironment = Nothing
                                            , commandWorkingDirectory = Just repoRoot
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
                            CommandSpec
                                { commandPath = "sudo"
                                , commandArguments = ["rm", "-rf", "/var/lib/rancher/rke2", "/var/lib/rancher", "/etc/rancher/rke2", "/usr/local/bin/rke2", "/usr/local/bin/rke2-killall.sh", "/usr/local/bin/rke2-uninstall.sh"]
                                , commandEnvironment = Nothing
                                , commandWorkingDirectory = Just repoRoot
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
                                    CommandSpec
                                        { commandPath = "sudo"
                                        , commandArguments = ["rm", "-f"] ++ matchingPaths
                                        , commandEnvironment = Nothing
                                        , commandWorkingDirectory = Nothing
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

renderRetainedStateNotice :: FilePath -> ValidatedSettings -> IO ExitCode
renderRetainedStateNotice repoRoot settings = do
    putStrLn "Preserved host state:"
    putStrLn ("  - manual PV root: " ++ resolvedManualPvHostRoot settings)
    putStrLn ("  - retained chart state root: " ++ repoRoot </> ".prodbox-state")
    pure ExitSuccess

reportDeleteStep :: String -> String -> IO ExitCode
reportDeleteStep label status = do
    putStrLn (label ++ ": " ++ status)
    pure ExitSuccess

summarizeRke2DeleteFailure :: ProcessOutput -> String
summarizeRke2DeleteFailure output =
    case reverse . take 3 . reverse $
        filter (not . isIgnorableRke2DeleteNoiseLine) (nonEmptyLines (processStderr output ++ "\n" ++ processStdout output)) of
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
                    names -> Left ("Retained storage policy requires a single-node cluster; detected " ++ show (length names) ++ " nodes")

ensureHostStoragePath :: FilePath -> FilePath -> IO ExitCode
ensureHostStoragePath repoRoot hostPath =
    runSequentially
        [ runCommand
            CommandSpec
                { commandPath = "sudo"
                , commandArguments = ["mkdir", "-p", hostPath]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }
        , runCommand
            CommandSpec
                { commandPath = "sudo"
                , commandArguments = ["chown", "-R", "1000:1000", hostPath]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }
        , runCommand
            CommandSpec
                { commandPath = "sudo"
                , commandArguments = ["chmod", "0770", hostPath]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
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
                     ] ::
                        [Value]
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

annotateNamespacedResources :: FilePath -> String -> [String] -> String -> String -> IO (Either String ())
annotateNamespacedResources repoRoot namespace resources prodboxId labelValue =
    runEitherActions
        [ annotateNamespacedResource repoRoot namespace resource prodboxId labelValue
        | resource <- resources
        ]

annotateNamespacedResource :: FilePath -> String -> String -> String -> String -> IO (Either String ())
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

annotateClusterResources :: FilePath -> String -> [String] -> String -> String -> IO (Either String ())
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
                        else pure (Left ("list cluster " ++ resource ++ " for " ++ instanceName ++ " failed: " ++ outputDetail output))
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

annotateResourceSet :: FilePath -> Maybe String -> String -> Maybe String -> String -> String -> IO (Either String ())
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
    foldM
        ( \result action ->
            case result of
                Left err -> pure (Left err)
                Right () -> action
        )
        (Right ())

captureKubectl :: FilePath -> [String] -> IO (Either String ProcessOutput)
captureKubectl repoRoot arguments = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "kubectl"
                , commandArguments = arguments
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }
    pure $
        case result of
            Failure err -> Left ("failed to start kubectl: " ++ err)
            Success output -> Right output

captureToolOutput :: FilePath -> FilePath -> [String] -> IO (Either String ProcessOutput)
captureToolOutput repoRoot toolName arguments = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = toolName
                , commandArguments = arguments
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }
    pure $
        case result of
            Failure err -> Left ("failed to start " ++ toolName ++ ": " ++ err)
            Success output -> Right output

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
                CommandSpec
                    { commandPath = "sudo"
                    , commandArguments = ["mkdir", "-p", takeDirectory path]
                    , commandEnvironment = Nothing
                    , commandWorkingDirectory = Just repoRoot
                    }
            , runCommand
                CommandSpec
                    { commandPath = "sudo"
                    , commandArguments = ["cp", tempPath, path]
                    , commandEnvironment = Nothing
                    , commandWorkingDirectory = Just repoRoot
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
    withTemporaryJsonBytes prefix (encode (object ["apiVersion" .= ("v1" :: String), "kind" .= ("List" :: String), "items" .= items]))

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
                            else Left "RKE2 containerd socket not found at expected paths: /run/k3s/containerd/containerd.sock, /run/rke2/containerd/containerd.sock"

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

isMissingHelmReleaseError :: String -> Bool
isMissingHelmReleaseError detail =
    let lowered = map toLower detail
     in "release: not found" `isInfixOf` lowered
            || "release not loaded" `isInfixOf` lowered

outputDetail :: ProcessOutput -> String
outputDetail output =
    case filter (/= "") [trimTrailingNewlines (processStderr output), trimTrailingNewlines (processStdout output)] of
        [] -> "subprocess exited without output"
        rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

emitCapturedProcessOutput :: ProcessOutput -> IO ()
emitCapturedProcessOutput output = do
    let stdoutText = processStdout output
        stderrText = processStderr output
    if stdoutText == ""
        then pure ()
        else putStr stdoutText
    if stderrText == ""
        then pure ()
        else hPutStr stderr stderrText

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

runCommand :: CommandSpec -> IO ExitCode
runCommand spec = do
    result <- runStreamingCommand spec
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
    hPutStrLn stderr message
    pure (ExitFailure 1)
