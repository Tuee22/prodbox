{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Rke2
    ( runRke2Command,
    )
where

import Control.Concurrent (threadDelay)
import Control.Exception
    ( IOException,
      bracket,
      displayException,
      finally,
      try,
    )
import Control.Monad (foldM)
import Data.Aeson
    ( FromJSON (parseJSON),
      Value,
      eitherDecode,
      encode,
      object,
      withObject,
      (.:),
      (.:?),
      (.=),
    )
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Char
    ( isHexDigit,
      isSpace,
      toLower,
    )
import Data.List
    ( intercalate,
      isInfixOf,
      isPrefixOf,
      nub,
    )
import Prodbox.CLI.Command
    ( PulumiCommand (..),
      Rke2Command (..),
    )
import Prodbox.CLI.Pulumi (runPulumiCommand)
import qualified Prodbox.ContainerImage as ContainerImage
import Prodbox.Result (Result (..))
import Prodbox.Settings
    ( ValidatedSettings (..),
      validateAndLoadSettings,
    )
import Prodbox.Subprocess
    ( CommandSpec (..),
      ProcessOutput (..),
      captureCommand,
      runStreamingCommand,
    )
import System.Directory
    ( doesDirectoryExist,
      doesFileExist,
      getHomeDirectory,
      getTemporaryDirectory,
      listDirectory,
      removeFile,
    )
import System.Environment (lookupEnv)
import System.Exit
    ( ExitCode (ExitFailure, ExitSuccess),
    )
import System.FilePath
    ( takeDirectory,
      (</>),
    )
import System.Info (os)
import System.IO
    ( hClose,
      hPutStrLn,
      stderr,
      openTempFile,
    )

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

buildxBuilderName :: String
buildxBuilderName = "prodbox-multiarch-hostnet"

data CustomImageBuildMode
    = CustomImageBuildDirect
    | CustomImageBuildWithHaskellToolchain
    deriving (Eq, Show)

data CustomImageBuildPlan = CustomImageBuildPlan
    { customImageDockerfile :: FilePath,
      customImageBuildMode :: CustomImageBuildMode
    }
    deriving (Eq, Show)

haskellToolchainBuildContextName :: String
haskellToolchainBuildContextName = "haskell-toolchain"

haskellToolchainImageRef :: String
haskellToolchainImageRef = "haskell:9.6.7-slim"

minioPersistentVolume :: String
minioPersistentVolume = "prodbox-minio-pv-0"

minioPersistentClaim :: String
minioPersistentClaim = "minio"

minioStorageSize :: String
minioStorageSize = "200Gi"

managedNamespaces :: [String]
managedNamespaces =
    [ prodboxNamespace,
      harborNamespace,
      "metallb-system",
      "traefik-system",
      "cert-manager",
      "gateway",
      "vscode"
    ]

managedHelmInstances :: [String]
managedHelmInstances =
    [ "harbor",
      "minio",
      "metallb",
      "traefik",
      "cert-manager"
    ]

ephemeralResourceKinds :: [String]
ephemeralResourceKinds =
    [ "events",
      "events.events.k8s.io"
    ]

doctrineCrdSuffixes :: [String]
doctrineCrdSuffixes =
    [ ".metallb.io",
      ".cert-manager.io",
      ".acme.cert-manager.io",
      ".traefik.io",
      ".containo.us"
    ]

runRke2Command :: FilePath -> Rke2Command -> IO ExitCode
runRke2Command repoRoot command =
    case command of
        Rke2Status ->
            requireLinux $
                runCommand
                    CommandSpec
                        { commandPath = "systemctl",
                          commandArguments = ["is-active", rke2ServiceName],
                          commandEnvironment = Nothing,
                          commandWorkingDirectory = Just repoRoot
                        }
        Rke2Start ->
            requireLinux $
                runCommand
                    CommandSpec
                        { commandPath = "sudo",
                          commandArguments = ["systemctl", "start", rke2ServiceName],
                          commandEnvironment = Nothing,
                          commandWorkingDirectory = Just repoRoot
                        }
        Rke2Stop ->
            requireLinux $
                runCommand
                    CommandSpec
                        { commandPath = "sudo",
                          commandArguments = ["systemctl", "stop", rke2ServiceName],
                          commandEnvironment = Nothing,
                          commandWorkingDirectory = Just repoRoot
                        }
        Rke2Restart ->
            requireLinux $
                runCommand
                    CommandSpec
                        { commandPath = "sudo",
                          commandArguments = ["systemctl", "restart", rke2ServiceName],
                          commandEnvironment = Nothing,
                          commandWorkingDirectory = Just repoRoot
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
                                { commandPath = "journalctl",
                                  commandArguments =
                                    [ "-u",
                                      rke2ServiceName,
                                      "-n",
                                      show linesToShow,
                                      "--no-pager"
                                    ],
                                  commandEnvironment = Nothing,
                                  commandWorkingDirectory = Just repoRoot
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
                            [ ensureRke2ServerInstalled repoRoot,
                              ensureRke2IngressController repoRoot,
                              runCommand
                                CommandSpec
                                    { commandPath = "sudo",
                                      commandArguments = ["systemctl", "enable", rke2ServiceName],
                                      commandEnvironment = Nothing,
                                      commandWorkingDirectory = Just repoRoot
                                    },
                              runCommand
                                CommandSpec
                                    { commandPath = "sudo",
                                      commandArguments = ["systemctl", "restart", rke2ServiceName],
                                      commandEnvironment = Nothing,
                                      commandWorkingDirectory = Just repoRoot
                                    },
                              syncUserKubeconfig repoRoot,
                              verifyClusterInfo repoRoot,
                              waitForClusterNodesReady repoRoot,
                              deleteNonManualStorageClasses repoRoot,
                              ensureProdboxIdentityConfigMap repoRoot machineId prodboxId labelValue,
                              ensureRetainedLocalStorage repoRoot settings prodboxId labelValue,
                              ensureHarborRegistryRuntime repoRoot prodboxId,
                              ensureMinioRuntime repoRoot,
                              reconcileManagedAnnotations repoRoot prodboxId labelValue
                            ]

runNativeDelete :: FilePath -> IO ExitCode
runNativeDelete repoRoot = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> failWith err
        Right settings ->
            runSequentially
                [ runPulumiCommand repoRoot (PulumiEksDestroy True),
                  runPulumiCommand repoRoot (PulumiTestDestroy True),
                  deleteRke2ClusterSubstrate repoRoot,
                  removeCalicoEndpointStatusResidue,
                  removeManagedKubeconfig,
                  renderRetainedStateNotice repoRoot settings
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
                                                { commandPath = "sudo",
                                                  commandArguments = ["env", "INSTALL_RKE2_TYPE=server", "sh", installerPath],
                                                  commandEnvironment = Nothing,
                                                  commandWorkingDirectory = Just repoRoot
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
                            { commandPath = "sudo",
                              commandArguments = ["mkdir", "-p", takeDirectory targetPath],
                              commandEnvironment = Nothing,
                              commandWorkingDirectory = Just repoRoot
                            },
                      runCommand
                        CommandSpec
                            { commandPath = "sudo",
                              commandArguments = ["cp", rke2KubeconfigPath, targetPath],
                              commandEnvironment = Nothing,
                              commandWorkingDirectory = Just repoRoot
                            },
                      runCommand
                        CommandSpec
                            { commandPath = "sudo",
                              commandArguments = ["chown", ownerSpec, targetPath],
                              commandEnvironment = Nothing,
                              commandWorkingDirectory = Just repoRoot
                            },
                      runCommand
                        CommandSpec
                            { commandPath = "chmod",
                              commandArguments = ["600", targetPath],
                              commandEnvironment = Nothing,
                              commandWorkingDirectory = Just repoRoot
                            }
                    ]

verifyClusterInfo :: FilePath -> IO ExitCode
verifyClusterInfo repoRoot =
    runCommand
        CommandSpec
            { commandPath = "kubectl",
              commandArguments = ["cluster-info"],
              commandEnvironment = Nothing,
              commandWorkingDirectory = Just repoRoot
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
                                            { commandPath = "kubectl",
                                              commandArguments =
                                                [ "wait",
                                                  "--for=condition=Ready",
                                                  "node",
                                                  "--all",
                                                  "--timeout=300s"
                                                ],
                                              commandEnvironment = Nothing,
                                              commandWorkingDirectory = Just repoRoot
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
                            | ref <- parseObjectNames (processStdout output),
                              dropResourcePrefix ref /= manualStorageClass
                            ]
                     in runSequentially
                            [ runCommand
                                CommandSpec
                                    { commandPath = "kubectl",
                                      commandArguments = ["delete", "storageclass", ref, "--ignore-not-found=true"],
                                      commandEnvironment = Nothing,
                                      commandWorkingDirectory = Just repoRoot
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
                                    then runCommand
                                        CommandSpec
                                            { commandPath = "kubectl",
                                              commandArguments = ["delete", "pv", minioPersistentVolume, "--ignore-not-found=true", "--wait=true"],
                                              commandEnvironment = Nothing,
                                              commandWorkingDirectory = Just repoRoot
                                            }
                                    else pure ExitSuccess
                            case resetExit of
                                ExitFailure _ -> pure resetExit
                                ExitSuccess -> do
                                    pvcPhaseResult <-
                                        captureKubectl
                                            repoRoot
                                            [ "get",
                                              "pvc",
                                              minioPersistentClaim,
                                              "-n",
                                              minioNamespace,
                                              "-o",
                                              "jsonpath={.status.phase}"
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

ensureMinioRuntime :: FilePath -> IO ExitCode
ensureMinioRuntime repoRoot = do
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
        runSequentially
            [ runCommand
                CommandSpec
                    { commandPath = "helm",
                      commandArguments = ["repo", "update"],
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    },
              runCommand
                CommandSpec
                    { commandPath = "helm",
                      commandArguments =
                        [ "upgrade",
                          "--install",
                          minioReleaseName,
                          minioChartRef,
                          "--version",
                          minioChartVersion,
                          "--namespace",
                          minioNamespace,
                          "--create-namespace",
                          "--set",
                          "mode=standalone",
                          "--set",
                          "replicas=1",
                          "--set",
                          "persistence.enabled=true",
                          "--set",
                          "persistence.existingClaim=minio",
                          "--set",
                          "image.repository=" ++ renderImageRefWithoutTag ContainerImage.harborMinioImage,
                          "--set",
                          "image.tag=" ++ ContainerImage.imageTag ContainerImage.harborMinioImage,
                          "--set",
                          "mcImage.repository=" ++ renderImageRefWithoutTag ContainerImage.harborMinioMcImage,
                          "--set",
                          "mcImage.tag=" ++ ContainerImage.imageTag ContainerImage.harborMinioMcImage,
                          "--set",
                          "persistence.size=200Gi",
                          "--set",
                          "service.type=ClusterIP",
                          "--set",
                          "consoleService.type=ClusterIP",
                          "--set",
                          "resources.requests.memory=256Mi",
                          "--set",
                          "resources.requests.cpu=100m",
                          "--set",
                          "resources.limits.memory=512Mi"
                        ],
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    },
              runCommand
                CommandSpec
                    { commandPath = "kubectl",
                      commandArguments =
                        [ "wait",
                          "--for=condition=Available",
                          "deployment/minio",
                          "-n",
                          minioNamespace,
                          "--timeout=300s"
                        ],
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    }
            ]

ensureHarborRegistryRuntime :: FilePath -> String -> IO ExitCode
ensureHarborRegistryRuntime repoRoot prodboxId = do
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
        installExit <-
            runSequentially
                [ runCommand
                    CommandSpec
                        { commandPath = "kubectl",
                          commandArguments = ["delete", "namespace", harborNamespace, "--ignore-not-found=true", "--wait=true", "--timeout=300s"],
                          commandEnvironment = Nothing,
                          commandWorkingDirectory = Just repoRoot
                        },
                  runCommand
                    CommandSpec
                        { commandPath = "helm",
                          commandArguments = ["repo", "update"],
                          commandEnvironment = Nothing,
                          commandWorkingDirectory = Just repoRoot
                        },
                  runCommand
                    CommandSpec
                        { commandPath = "helm",
                          commandArguments =
                            [ "upgrade",
                              "--install",
                              harborReleaseName,
                              harborRepositoryName ++ "/harbor",
                              "--namespace",
                              harborNamespace,
                              "--create-namespace",
                              "--set",
                              "expose.type=nodePort",
                              "--set",
                              "expose.tls.enabled=false",
                              "--set",
                              "expose.nodePort.ports.http.nodePort=30080",
                              "--set",
                              "externalURL=http://" ++ harborRegistryEndpoint,
                              "--set",
                              "harborAdminPassword=Harbor12345",
                              "--set",
                              "persistence.enabled=false"
                            ],
                          commandEnvironment = Nothing,
                          commandWorkingDirectory = Just repoRoot
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
                                        [ waitForHarborReadyEndpoint repoRoot,
                                          waitForHarborRegistryEndpoint repoRoot,
                                          waitForHarborStableEndpoints repoRoot
                                        ]
                                case harborEndpointExit of
                                    ExitFailure _ -> pure harborEndpointExit
                                    ExitSuccess -> do
                                        loginExit <-
                                            runCommand
                                                CommandSpec
                                                    { commandPath = "docker",
                                                      commandArguments = ["login", harborRegistryEndpoint, "--username", harborAdminUser, "--password", harborAdminPassword],
                                                      commandEnvironment = Nothing,
                                                      commandWorkingDirectory = Just repoRoot
                                                    }
                                        case loginExit of
                                            ExitFailure _ -> pure loginExit
                                            ExitSuccess -> do
                                                projectExit <-
                                                    runSequentially
                                                        [ ensureHarborProject repoRoot projectName
                                                        | projectName <- nub [harborMirrorProject, harborProjectFromRepository harborGatewayRepository]
                                                        ]
                                                case projectExit of
                                                    ExitFailure _ -> pure projectExit
                                                    ExitSuccess -> do
                                                        mirrorExit <- mirrorClusterImagesOnce repoRoot
                                                        case mirrorExit of
                                                            ExitFailure _ -> pure mirrorExit
                                                            ExitSuccess -> do
                                                                gatewayExit <- ensureGatewayImages repoRoot prodboxId
                                                                case gatewayExit of
                                                                    ExitFailure _ -> pure gatewayExit
                                                                    ExitSuccess -> do
                                                                        vscodeExit <- ensureVscodeNginxImage repoRoot
                                                                        case vscodeExit of
                                                                            ExitFailure _ -> pure vscodeExit
                                                                            ExitSuccess -> ensureRke2RegistriesConfig repoRoot

waitForDeployment :: FilePath -> String -> String -> IO ExitCode
waitForDeployment repoRoot namespace deploymentName =
    runCommand
        CommandSpec
            { commandPath = "kubectl",
              commandArguments =
                [ "wait",
                  "--for=condition=Available",
                  "deployment/" ++ deploymentName,
                  "-n",
                  namespace,
                  "--timeout=300s"
                ],
              commandEnvironment = Nothing,
              commandWorkingDirectory = Just repoRoot
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
            [ "-sS",
              "--max-time",
              "5",
              "-o",
              "/dev/null",
              "-w",
              "%{http_code}",
              "http://" ++ harborRegistryEndpoint ++ path
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
            [ "get",
              "configmap",
              harborComponentName harborReleaseName "nginx",
              "-n",
              harborNamespace,
              "-o",
              "jsonpath={.data.nginx\\.conf}"
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
                                        [ "apiVersion" .= ("v1" :: String),
                                          "kind" .= ("ConfigMap" :: String),
                                          "metadata"
                                            .= object
                                                [ "name" .= harborComponentName harborReleaseName "nginx",
                                                  "namespace" .= harborNamespace
                                                ],
                                          "data" .= object ["nginx.conf" .= patchedConfig]
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
                                                                ],
                                                          "spec"
                                                            .= object
                                                                [ "containers"
                                                                    .= ([ object
                                                                            [ "name" .= ("nginx" :: String),
                                                                              "readinessProbe"
                                                                                .= object
                                                                                    [ "httpGet"
                                                                                        .= object
                                                                                            [ "path" .= harborReadyPath,
                                                                                              "port" .= (8080 :: Int),
                                                                                              "scheme" .= ("HTTP" :: String)
                                                                                            ]
                                                                                    ],
                                                                              "livenessProbe"
                                                                                .= object
                                                                                    [ "httpGet"
                                                                                        .= object
                                                                                            [ "path" .= harborReadyPath,
                                                                                              "port" .= (8080 :: Int),
                                                                                              "scheme" .= ("HTTP" :: String)
                                                                                            ]
                                                                                    ]
                                                                            ] ] :: [Value])
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
                                            [ "patch",
                                              "deployment",
                                              harborComponentName harborReleaseName "nginx",
                                              "-n",
                                              harborNamespace,
                                              "--type",
                                              "strategic",
                                              "--patch",
                                              trimTrailingNewlines (BL8.unpack (encode deploymentPatch))
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
            [ "-sS",
              "-u",
              harborAdminUser ++ ":" ++ harborAdminPassword,
              "-H",
              "Content-Type: application/json",
              "-X",
              "POST",
              "-d",
              payload,
              "-o",
              "/dev/null",
              "-w",
              "%{http_code}",
              "http://" ++ harborRegistryEndpoint ++ "/api/v2.0/projects"
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

data ManifestPlatform = ManifestPlatform
    { manifestPlatformOs :: String,
      manifestPlatformArchitecture :: String
    }

instance FromJSON ManifestPlatform where
    parseJSON =
        withObject "ManifestPlatform" $ \payload ->
            ManifestPlatform
                <$> payload .: "os"
                <*> payload .: "architecture"

data ManifestDescriptor = ManifestDescriptor
    { manifestDescriptorDigest :: Maybe String,
      manifestDescriptorPlatform :: Maybe ManifestPlatform
    }

instance FromJSON ManifestDescriptor where
    parseJSON =
        withObject "ManifestDescriptor" $ \payload ->
            ManifestDescriptor
                <$> payload .:? "digest"
                <*> payload .:? "platform"

data RawImageManifest = RawImageManifest
    { rawImageManifestManifests :: Maybe [ManifestDescriptor],
      rawImageManifestOs :: Maybe String,
      rawImageManifestArchitecture :: Maybe String
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
                    | image <- images,
                      Just source <- [ContainerImage.normalizeImageRefText image],
                      not (isHarborBootstrapImage source),
                      not (isHarborHostedImage source),
                      Just target <- [ContainerImage.harborMirrorTargetForSource source],
                      Just sources <- [ContainerImage.harborMirrorSourceCandidates source]
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
            [ "get",
              "pods",
              "-A",
              "-o",
              "jsonpath={range .items[*]}{range .spec.initContainers[*]}{.image}{\"\\n\"}{end}{range .spec.containers[*]}{.image}{\"\\n\"}{end}{end}"
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
            sourceManifestResult <- selectCanonicalMirrorSource repoRoot sourceCandidates target
            case sourceManifestResult of
                Left err -> failWith err
                Right (source, sourceManifest) -> do
                    purgeExit <- purgeHarborMirrorTarget repoRoot target
                    case purgeExit of
                        ExitFailure _ -> pure purgeExit
                        ExitSuccess -> pushCanonicalMirrorTarget repoRoot source sourceManifest target

ensureGatewayImages :: FilePath -> String -> IO ExitCode
ensureGatewayImages repoRoot prodboxId = do
    let gatewayTag = prodboxIdToLabelValue prodboxId
        gatewayImage = ContainerImage.harborGatewayImageRepository ++ ":" ++ gatewayTag
        latestImage = ContainerImage.harborGatewayImageRepository ++ ":latest"
    ensureCustomImageVariants
        repoRoot
        CustomImageBuildPlan
            { customImageDockerfile = "docker/gateway.Dockerfile",
              customImageBuildMode = CustomImageBuildWithHaskellToolchain
            }
        [gatewayImage, latestImage]
        gatewayImage

ensureVscodeNginxImage :: FilePath -> IO ExitCode
ensureVscodeNginxImage repoRoot = do
    let imageRef = ContainerImage.renderImageRef ContainerImage.harborVscodeNginxImage
    ensureCustomImageVariants
        repoRoot
        CustomImageBuildPlan
            { customImageDockerfile = "docker/nginx-oidc.Dockerfile",
              customImageBuildMode = CustomImageBuildDirect
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
                                { commandPath = "docker",
                                  commandArguments = ["pull", importRef],
                                  commandEnvironment = Nothing,
                                  commandWorkingDirectory = Just repoRoot
                                },
                          importImageIntoRke2Containerd repoRoot importRef
                        ]

buildMissingCustomImageVariants :: FilePath -> CustomImageBuildPlan -> [String] -> IO ExitCode
buildMissingCustomImageVariants repoRoot buildPlan taggedRefs =
    case customImageBuildMode buildPlan of
        CustomImageBuildDirect ->
            runCommand
                CommandSpec
                    { commandPath = "docker",
                      commandArguments =
                        [ "buildx",
                          "build",
                          "--platform",
                          canonicalPlatformArgument,
                          "--push",
                          "-f",
                          customImageDockerfile buildPlan
                        ]
                            ++ concat [["-t", tagRef] | tagRef <- taggedRefs]
                            ++ ["."],
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    }
        CustomImageBuildWithHaskellToolchain ->
            buildCustomImageVariantsWithHaskellToolchain repoRoot buildPlan taggedRefs

buildCustomImageVariantsWithHaskellToolchain :: FilePath -> CustomImageBuildPlan -> [String] -> IO ExitCode
buildCustomImageVariantsWithHaskellToolchain repoRoot buildPlan taggedRefs =
    let manifestSourcesResult =
            sequence
                [ do
                    platformRefs <- traverse (`stagedImageRefForPlatform` tagRef) ContainerImage.canonicalImagePlatforms
                    pure (tagRef, platformRefs)
                | tagRef <- taggedRefs
                ]
     in case manifestSourcesResult of
            Left err -> failWith err
            Right manifestSources -> do
                buildExit <-
                    runSequentially
                        [ buildSinglePlatformCustomImage repoRoot buildPlan platform taggedRefs
                        | platform <- ContainerImage.canonicalImagePlatforms
                        ]
                case buildExit of
                    ExitFailure _ -> pure buildExit
                    ExitSuccess ->
                        runSequentially
                            [ runCommand
                                CommandSpec
                                    { commandPath = "docker",
                                      commandArguments = ["buildx", "imagetools", "create", "--tag", targetRef] ++ platformRefs,
                                      commandEnvironment = Nothing,
                                      commandWorkingDirectory = Just repoRoot
                                    }
                            | (targetRef, platformRefs) <- manifestSources
                            ]

buildSinglePlatformCustomImage :: FilePath -> CustomImageBuildPlan -> (String, String) -> [String] -> IO ExitCode
buildSinglePlatformCustomImage repoRoot buildPlan platform taggedRefs =
    case traverse (stagedImageRefForPlatform platform) taggedRefs of
        Left err -> failWith err
        Right stagedRefs ->
            runCommand
                CommandSpec
                    { commandPath = "docker",
                      commandArguments =
                        [ "buildx",
                          "build",
                          "--platform",
                          renderPlatformArgument platform,
                          "--build-context",
                          haskellToolchainBuildContextName ++ "=docker-image://docker.io/library/" ++ haskellToolchainImageRef,
                          "--push",
                          "-f",
                          customImageDockerfile buildPlan
                        ]
                            ++ concat [["-t", tagRef] | tagRef <- stagedRefs]
                            ++ ["."],
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    }

stagedImageRefForPlatform :: (String, String) -> String -> Either String String
stagedImageRefForPlatform platform targetRef = do
    imageRef <- ContainerImage.parseImageRef targetRef
    pure
        ( ContainerImage.renderImageRef
            imageRef
                { ContainerImage.imageTag =
                    ContainerImage.imageTag imageRef ++ renderPlatformTagSuffix platform
                }
        )

renderPlatformArgument :: (String, String) -> String
renderPlatformArgument (osName, architecture) = osName ++ "/" ++ architecture

renderPlatformLabel :: (String, String) -> String
renderPlatformLabel (osName, architecture) = osName ++ "-" ++ architecture

renderPlatformTagSuffix :: (String, String) -> String
renderPlatformTagSuffix platform = "-" ++ renderPlatformLabel platform

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
                            else Right Nothing

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
                    [ "-sS",
                      "-u",
                      harborAdminUser ++ ":" ++ harborAdminPassword,
                      "-X",
                      "DELETE",
                      "-o",
                      "/dev/null",
                      "-w",
                      "%{http_code}",
                      "http://" ++ harborRegistryEndpoint ++ "/api/v2.0/projects/" ++ projectName ++ "/repositories/" ++ encodeHarborRepositoryName repositoryName
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
        else
            case break (== '/') (ContainerImage.imageRepository imageRef) of
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

pushCanonicalMirrorTarget :: FilePath -> String -> RawImageManifest -> String -> IO ExitCode
pushCanonicalMirrorTarget repoRoot source sourceManifest target =
    case buildCanonicalMirrorSourceRefs source sourceManifest of
        Left err -> failWith err
        Right sourceRefs ->
            runCommand
                CommandSpec
                    { commandPath = "docker",
                      commandArguments = ["buildx", "imagetools", "create", "--tag", target] ++ sourceRefs,
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    }

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
        case
            [ digest
            | descriptor <- descriptors,
              Just platform <- [manifestDescriptorPlatform descriptor],
              manifestPlatformOs platform == osName,
              manifestPlatformArchitecture platform == architecture,
              Just digest <- [manifestDescriptorDigest descriptor]
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

selectCanonicalMirrorSource :: FilePath -> [String] -> String -> IO (Either String (String, RawImageManifest))
selectCanonicalMirrorSource repoRoot sourceCandidates target = go [] sourceCandidates
  where
    go diagnostics [] =
        let detail =
                if null diagnostics
                    then "Tried: " ++ intercalate ", " sourceCandidates
                    else intercalate " | " (reverse diagnostics)
         in pure
                ( Left
                    ( "Unable to select a canonical upstream mirror source for "
                        ++ target
                        ++ ". "
                        ++ detail
                    )
                )
    go diagnostics (source : remainingSources) = do
        sourceManifestResult <- inspectRawImageManifest repoRoot source
        case sourceManifestResult of
            Left err -> pure (Left err)
            Right (Just sourceManifest)
                | supportsCanonicalImagePlatforms (manifestPlatforms sourceManifest) ->
                    pure (Right (source, sourceManifest))
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
            [ "buildx",
              "create",
              "--name",
              buildxBuilderName,
              "--driver",
              "docker-container",
              "--driver-opt",
              "network=host",
              "--use"
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
                    { commandPath = "docker",
                      commandArguments = ["buildx", "use", buildxBuilderName],
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    },
              bootstrapBuilder
            ]

    bootstrapBuilder =
        runCommand
            CommandSpec
                { commandPath = "docker",
                  commandArguments = ["buildx", "inspect", "--bootstrap", buildxBuilderName],
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Just repoRoot
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
                | descriptor <- descriptors,
                  Just platform <- [manifestDescriptorPlatform descriptor]
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
                            { commandPath = "docker",
                              commandArguments = ["save", "-o", archivePath, imageRef],
                              commandEnvironment = Nothing,
                              commandWorkingDirectory = Just repoRoot
                            },
                      runCommand
                        CommandSpec
                            { commandPath = "sudo",
                              commandArguments = ["ctr", "--address", socketPath, "-n", "k8s.io", "images", "import", archivePath],
                              commandEnvironment = Nothing,
                              commandWorkingDirectory = Just repoRoot
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
                                            { commandPath = "sudo",
                                              commandArguments = ["systemctl", "restart", rke2ServiceName],
                                              commandEnvironment = Nothing,
                                              commandWorkingDirectory = Just repoRoot
                                            },
                                      verifyClusterInfo repoRoot
                                    ]

deleteRke2ClusterSubstrate :: FilePath -> IO ExitCode
deleteRke2ClusterSubstrate repoRoot = do
    uninstallExistsResult <- captureToolOutput repoRoot "test" ["-x", rke2UninstallPath]
    case uninstallExistsResult of
        Left err -> failWith err
        Right output ->
            case processExitCode output of
                ExitSuccess ->
                    runCommand
                        CommandSpec
                            { commandPath = "sudo",
                              commandArguments = [rke2UninstallPath],
                              commandEnvironment = Nothing,
                              commandWorkingDirectory = Just repoRoot
                            }
                ExitFailure _ -> do
                    _ <-
                        captureToolOutput
                            repoRoot
                            "sudo"
                            ["systemctl", "disable", "--now", rke2ServiceName]
                    runCommand
                        CommandSpec
                            { commandPath = "sudo",
                              commandArguments = ["rm", "-rf", "/var/lib/rancher/rke2", "/var/lib/rancher", "/etc/rancher/rke2", "/usr/local/bin/rke2", "/usr/local/bin/rke2-killall.sh", "/usr/local/bin/rke2-uninstall.sh"],
                              commandEnvironment = Nothing,
                              commandWorkingDirectory = Just repoRoot
                            }

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
                            | fileName <- fileNames,
                              "rke2" `isInfixOf` fileName
                            ]
                     in if null matchingPaths
                            then pure ExitSuccess
                            else
                                runCommand
                                    CommandSpec
                                        { commandPath = "sudo",
                                          commandArguments = ["rm", "-f"] ++ matchingPaths,
                                          commandEnvironment = Nothing,
                                          commandWorkingDirectory = Nothing
                                        }

removeManagedKubeconfig :: IO ExitCode
removeManagedKubeconfig = do
    homeDirectory <- getHomeDirectory
    let kubeconfigPath = homeDirectory </> ".kube" </> "config"
    exists <- doesFileExist kubeconfigPath
    if not exists
        then pure ExitSuccess
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
                                Right () -> pure ExitSuccess
                        else pure ExitSuccess

renderRetainedStateNotice :: FilePath -> ValidatedSettings -> IO ExitCode
renderRetainedStateNotice repoRoot settings = do
    putStrLn "Preserved host state:"
    putStrLn ("  - manual PV root: " ++ resolvedManualPvHostRoot settings)
    putStrLn ("  - retained chart state root: " ++ repoRoot </> ".prodbox-state")
    pure ExitSuccess

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
                { commandPath = "sudo",
                  commandArguments = ["mkdir", "-p", hostPath],
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Just repoRoot
                },
          runCommand
            CommandSpec
                { commandPath = "sudo",
                  commandArguments = ["chown", "-R", "1000:1000", hostPath],
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Just repoRoot
                },
          runCommand
            CommandSpec
                { commandPath = "sudo",
                  commandArguments = ["chmod", "0770", hostPath],
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Just repoRoot
                }
        ]

storageManifestItems :: FilePath -> String -> String -> String -> [Value]
storageManifestItems hostPath nodeName prodboxId labelValue =
    [ object
        [ "apiVersion" .= ("storage.k8s.io/v1" :: String),
          "kind" .= ("StorageClass" :: String),
          "metadata"
            .= object
                [ "name" .= manualStorageClass,
                  "annotations"
                    .= object [Key.fromString prodboxAnnotationKey .= prodboxId],
                  "labels"
                    .= object [Key.fromString prodboxLabelKey .= labelValue]
                ],
          "provisioner" .= ("kubernetes.io/no-provisioner" :: String),
          "volumeBindingMode" .= ("WaitForFirstConsumer" :: String),
          "reclaimPolicy" .= ("Retain" :: String),
          "allowVolumeExpansion" .= True
        ],
      object
        [ "apiVersion" .= ("v1" :: String),
          "kind" .= ("PersistentVolume" :: String),
          "metadata"
            .= object
                [ "name" .= minioPersistentVolume,
                  "annotations"
                    .= object [Key.fromString prodboxAnnotationKey .= prodboxId],
                  "labels"
                    .= object [Key.fromString prodboxLabelKey .= labelValue]
                ],
          "spec"
            .= object
                [ "capacity" .= object ["storage" .= minioStorageSize],
                  "volumeMode" .= ("Filesystem" :: String),
                  "accessModes" .= (["ReadWriteOnce" :: String] :: [String]),
                  "persistentVolumeReclaimPolicy" .= ("Retain" :: String),
                  "storageClassName" .= manualStorageClass,
                  "claimRef"
                    .= object
                        [ "namespace" .= minioNamespace,
                          "name" .= minioPersistentClaim
                        ],
                  "hostPath"
                    .= object
                        [ "path" .= hostPath,
                          "type" .= ("DirectoryOrCreate" :: String)
                        ],
                  "nodeAffinity"
                    .= object
                        [ "required"
                            .= object
                                [ "nodeSelectorTerms"
                                    .= [ object
                                            [ "matchExpressions"
                                                .= [ object
                                                        [ "key" .= ("kubernetes.io/hostname" :: String),
                                                          "operator" .= ("In" :: String),
                                                          "values" .= ([nodeName] :: [String])
                                                        ]
                                                   ]
                                            ]
                                       ]
                                ]
                        ]
                ]
        ],
      object
        [ "apiVersion" .= ("v1" :: String),
          "kind" .= ("PersistentVolumeClaim" :: String),
          "metadata"
            .= object
                [ "name" .= minioPersistentClaim,
                  "namespace" .= minioNamespace,
                  "annotations"
                    .= object [Key.fromString prodboxAnnotationKey .= prodboxId],
                  "labels"
                    .= object [Key.fromString prodboxLabelKey .= labelValue]
                ],
          "spec"
            .= object
                [ "accessModes" .= (["ReadWriteOnce" :: String] :: [String]),
                  "volumeMode" .= ("Filesystem" :: String),
                  "storageClassName" .= manualStorageClass,
                  "volumeName" .= minioPersistentVolume,
                  "resources" .= object ["requests" .= object ["storage" .= minioStorageSize]]
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
            [ "apiVersion" .= ("v1" :: String),
              "kind" .= ("List" :: String),
              "items"
                .= ([ object
                        [ "apiVersion" .= ("v1" :: String),
                          "kind" .= ("Namespace" :: String),
                          "metadata"
                            .= object
                                [ "name" .= prodboxNamespace,
                                  "annotations"
                                    .= object [Key.fromString prodboxAnnotationKey .= prodboxId],
                                  "labels"
                                    .= object [Key.fromString prodboxLabelKey .= labelValue]
                                ]
                        ],
                     object
                        [ "apiVersion" .= ("v1" :: String),
                          "kind" .= ("ConfigMap" :: String),
                          "metadata"
                            .= object
                                [ "name" .= prodboxIdentityConfigMap,
                                  "namespace" .= prodboxNamespace,
                                  "annotations"
                                    .= object [Key.fromString prodboxAnnotationKey .= prodboxId],
                                  "labels"
                                    .= object [Key.fromString prodboxLabelKey .= labelValue]
                                ],
                          "data"
                            .= object
                                [ "machine_id" .= machineId,
                                  "prodbox_id" .= prodboxId
                                ]
                        ] ] :: [Value])
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
                        [ [ annotateObject repoRoot Nothing ("namespace/" ++ namespace) prodboxId labelValue,
                            annotateNamespacedResources repoRoot namespace namespacedResources prodboxId labelValue
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
            [ "api-resources",
              "--verbs=list",
              "--namespaced=" ++ map toLower (show namespaced),
              "-o",
              "name"
            ]
    pure $ do
        output <- outputResult
        case processExitCode output of
            ExitFailure _ ->
                Left ("Failed to list Kubernetes API resources: " ++ outputDetail output)
            ExitSuccess ->
                Right
                    ( filter (`notElem` ephemeralResourceKinds)
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
            [ "get",
              resource,
              "-n",
              namespace,
              "-o",
              "name",
              "--ignore-not-found=true"
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
            [ "get",
              resource,
              "-l",
              selector,
              "-o",
              "name",
              "--ignore-not-found=true"
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
                        | ref <- parseObjectNames (processStdout output),
                          any (`isInfixOf` dropResourcePrefix ref) doctrineCrdSuffixes
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
                else
                    case processExitCode annotateOutput of
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
                                        else
                                            case processExitCode labelOutput of
                                                ExitFailure _ -> pure (Left ("label " ++ objectRef ++ " failed: " ++ outputDetail labelOutput))
                                                ExitSuccess -> pure (Right ())

annotateResourceSet :: FilePath -> Maybe String -> String -> Maybe String -> String -> String -> IO (Either String ())
annotateResourceSet repoRoot maybeNamespace resource maybeSelector prodboxId labelValue = do
    annotateResult <-
        captureKubectl
            repoRoot
            ( appendNamespaceArgs maybeNamespace
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
                else
                    case processExitCode annotateOutput of
                        ExitFailure _ -> pure (Left ("annotate " ++ resource ++ " failed: " ++ outputDetail annotateOutput))
                        ExitSuccess -> do
                            labelResult <-
                                captureKubectl
                                    repoRoot
                                    ( appendNamespaceArgs maybeNamespace
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
                                        else
                                            case processExitCode labelOutput of
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
                { commandPath = "kubectl",
                  commandArguments = arguments,
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Just repoRoot
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
                { commandPath = toolName,
                  commandArguments = arguments,
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Just repoRoot
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
                    { commandPath = "sudo",
                      commandArguments = ["mkdir", "-p", takeDirectory path],
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    },
              runCommand
                CommandSpec
                    { commandPath = "sudo",
                      commandArguments = ["cp", tempPath, path],
                      commandEnvironment = Nothing,
                      commandWorkingDirectory = Just repoRoot
                    }
            ]

withTemporaryTextFile :: String -> String -> (FilePath -> IO ExitCode) -> IO ExitCode
withTemporaryTextFile prefix contents action = do
    temporaryDirectory <- getTemporaryDirectory
    bracket
        (do
            (path, handle) <- openTempFile temporaryDirectory prefix
            hClose handle
            writeFile path contents
            pure path
        )
        (\tempPath -> do
            _ <- try (removeFile tempPath) :: IO (Either IOException ())
            pure ())
        action

withTemporaryJsonManifest :: String -> [Value] -> (FilePath -> IO ExitCode) -> IO ExitCode
withTemporaryJsonManifest prefix items =
    withTemporaryJsonBytes prefix (encode (object ["apiVersion" .= ("v1" :: String), "kind" .= ("List" :: String), "items" .= items]))

withTemporaryJsonBytes :: String -> BL.ByteString -> (FilePath -> IO ExitCode) -> IO ExitCode
withTemporaryJsonBytes prefix contents action = do
    temporaryDirectory <- getTemporaryDirectory
    bracket
        (do
            (path, handle) <- openTempFile temporaryDirectory prefix
            hClose handle
            BL.writeFile path contents
            pure path
        )
        (\tempPath -> do
            _ <- try (removeFile tempPath) :: IO (Either IOException ())
            pure ())
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
                        else if length machineId /= 32 || any (not . isHexDigit) machineId
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
                    else if rke2Exists
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
        [ "mirrors:",
          "  docker.io:",
          "    endpoint:",
          "      - \"http://" ++ harborRegistryEndpoint ++ "\"",
          "    rewrite:",
          "      \"^(.*)$\": \"prodbox/$1\"",
          "configs:",
          "  \"" ++ harborRegistryEndpoint ++ "\":",
          "    tls:",
          "      insecure_skip_verify: true"
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
                        [ indent ++ "location = " ++ harborReadyPath ++ " {",
                          indent ++ "  access_log off;",
                          indent ++ "  return 200 \"ok\\n\";",
                          indent ++ "}",
                          ""
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
    | rawLine <- lines stdoutText,
      let line = trimWhitespace rawLine,
      line /= "",
      '/' `elem` line
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
    case filter (/= "") [trimTrailingNewlines (processStderr output), trimTrailingNewlines (processStdout output)] of
        [] -> "subprocess exited without output"
        rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

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
