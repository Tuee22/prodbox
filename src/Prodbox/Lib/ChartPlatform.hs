{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Lib.ChartPlatform
    ( ChartDefinition (..),
      ChartDeploymentPlan (..),
      ChartInstallSnapshot (..),
      ChartReleasePlan (..),
      buildChartDeletePlan,
      buildChartDeploymentPlan,
      chartStateRootRelative,
      deleteChartPlan,
      deployChartPlan,
      gatewayNodeIds,
      keycloakNginxClientId,
      keycloakRealmName,
      renderChartList,
      renderChartStatus,
      resolveChart,
      resolveChartSecrets,
      resolveGatewayEventKeys,
      supportedChartNames,
    )
where

import Control.Exception
    ( IOException,
      bracket,
      displayException,
      try,
    )
import Control.Monad
    ( foldM,
      forM,
      forM_,
      unless,
      when,
    )
import Data.Aeson
    ( FromJSON (parseJSON),
      Value,
      eitherDecode,
      object,
      withObject,
      (.:),
      (.=),
    )
import qualified Data.Aeson.Encode.Pretty as Pretty
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BL8
import Data.Char (isHexDigit, toLower)
import Data.List
    ( intercalate,
      isInfixOf,
      sort,
    )
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text as Text
import Data.Word (Word8)
import Numeric (showHex)
import Prodbox.Lib.Storage
    ( ChartStorageBinding (..),
      ChartStorageSpec (..),
      chartStorageClassName,
      chartStorageManifest,
      defaultChartDataRootRelative,
      renderStorageReport,
      storageBinding,
    )
import Prodbox.Result
    ( Result (..),
    )
import Prodbox.Settings
    ( ConfigFile (..),
      Credentials (..),
      DeploymentSection (..),
      DomainSection (..),
      Route53Section (..),
      ValidatedSettings (..),
    )
import Prodbox.Subprocess
    ( CommandSpec (..),
      ProcessOutput (..),
      captureCommand,
    )
import System.Directory
    ( Permissions,
      createDirectoryIfMissing,
      doesFileExist,
      getPermissions,
      getTemporaryDirectory,
      removeFile,
      searchable,
      writable,
    )
import System.Exit
    ( ExitCode (ExitFailure, ExitSuccess),
    )
import System.FilePath ((</>))
import System.IO
    ( IOMode (ReadMode),
      Handle,
      hClose,
      openTempFile,
      withBinaryFile,
    )

chartStateRootRelative :: FilePath
chartStateRootRelative = ".prodbox-state"

chartClusterIssuer :: String
chartClusterIssuer = "letsencrypt-http01"

keycloakRealmName :: String
keycloakRealmName = "prodbox"

keycloakNginxClientId :: String
keycloakNginxClientId = "vscode-nginx"

gatewayNodeIds :: [String]
gatewayNodeIds = ["node-a", "node-b", "node-c"]

requiredChartSecretKeys :: [String]
requiredChartSecretKeys =
    [ "keycloak_admin_password",
      "keycloak_postgres_password",
      "keycloak_nginx_client_secret"
    ]

machineIdPath :: FilePath
machineIdPath = "/etc/machine-id"

data ChartDefinition = ChartDefinition
    { chartDefinitionName :: String,
      chartDefinitionChartDir :: FilePath,
      chartDefinitionDependencies :: [String],
      chartDefinitionStorage :: [ChartStorageSpec],
      chartDefinitionRequiresPublicHost :: Bool
    }
    deriving (Eq, Show)

data ChartReleasePlan = ChartReleasePlan
    { chartReleasePlanChartName :: String,
      chartReleasePlanReleaseName :: String,
      chartReleasePlanNamespace :: String,
      chartReleasePlanChartDir :: FilePath,
      chartReleasePlanValuesJson :: String,
      chartReleasePlanStorageBindings :: [ChartStorageBinding]
    }
    deriving (Eq, Show)

data ChartDeploymentPlan = ChartDeploymentPlan
    { chartDeploymentPlanRootChart :: String,
      chartDeploymentPlanNamespace :: String,
      chartDeploymentPlanReleases :: [ChartReleasePlan],
      chartDeploymentPlanPublicFqdn :: Maybe String
    }
    deriving (Eq, Show)

data ChartInstallSnapshot = ChartInstallSnapshot
    { chartInstallSnapshotReleaseName :: String,
      chartInstallSnapshotNamespace :: String,
      chartInstallSnapshotStatus :: String
    }
    deriving (Eq, Show)

instance FromJSON ChartInstallSnapshot where
    parseJSON = withObject "helm list entry" $ \obj ->
        ChartInstallSnapshot
            <$> obj .: "name"
            <*> obj .: "namespace"
            <*> obj .: "status"

supportedChartNames :: [String]
supportedChartNames = ["keycloak-postgres", "keycloak", "vscode", "gateway"]

resolveChart :: FilePath -> String -> Either String ChartDefinition
resolveChart repoRoot chartName =
    case chartName of
        "keycloak-postgres" ->
            Right
                ChartDefinition
                    { chartDefinitionName = "keycloak-postgres",
                      chartDefinitionChartDir = repoRoot </> "charts" </> "keycloak-postgres",
                      chartDefinitionDependencies = [],
                      chartDefinitionStorage =
                        [ ChartStorageSpec
                            { chartStorageSpecStatefulSetName = "keycloak-postgres",
                              chartStorageSpecPersistentVolumeClaimName = "keycloak-postgres-data-0",
                              chartStorageSpecStorageSize = "20Gi",
                              chartStorageSpecOrdinal = 0,
                              chartStorageSpecClaimSuffix = "data"
                            }
                        ],
                      chartDefinitionRequiresPublicHost = False
                    }
        "keycloak" ->
            Right
                ChartDefinition
                    { chartDefinitionName = "keycloak",
                      chartDefinitionChartDir = repoRoot </> "charts" </> "keycloak",
                      chartDefinitionDependencies = ["keycloak-postgres"],
                      chartDefinitionStorage = [],
                      chartDefinitionRequiresPublicHost = True
                    }
        "vscode" ->
            Right
                ChartDefinition
                    { chartDefinitionName = "vscode",
                      chartDefinitionChartDir = repoRoot </> "charts" </> "vscode",
                      chartDefinitionDependencies = ["keycloak"],
                      chartDefinitionStorage =
                        [ ChartStorageSpec
                            { chartStorageSpecStatefulSetName = "vscode",
                              chartStorageSpecPersistentVolumeClaimName = "vscode-data-0",
                              chartStorageSpecStorageSize = "50Gi",
                              chartStorageSpecOrdinal = 0,
                              chartStorageSpecClaimSuffix = "data"
                            }
                        ],
                      chartDefinitionRequiresPublicHost = True
                    }
        "gateway" ->
            Right
                ChartDefinition
                    { chartDefinitionName = "gateway",
                      chartDefinitionChartDir = repoRoot </> "charts" </> "gateway",
                      chartDefinitionDependencies = [],
                      chartDefinitionStorage = [],
                      chartDefinitionRequiresPublicHost = True
                    }
        _ ->
            Left
                ( "Unsupported chart '"
                    ++ chartName
                    ++ "'. Supported charts: "
                    ++ intercalate ", " supportedChartNames
                )

buildChartDeploymentPlan ::
    FilePath ->
    ValidatedSettings ->
    String ->
    Map String String ->
    Map String String ->
    IO (Either String ChartDeploymentPlan)
buildChartDeploymentPlan repoRoot settings chartName chartSecrets gatewayEventKeys = do
    let dependencyOrderResult = resolveDependencyOrder repoRoot chartName
    case dependencyOrderResult of
        Left err -> pure (Left err)
        Right releaseOrder -> do
            gatewayImageResult <-
                if "gateway" `elem` releaseOrder
                    then resolveGatewayChartImage
                    else pure (Right Nothing)
            pure $ do
                maybeGatewayImage <- gatewayImageResult
                buildChartDeploymentPlanPure repoRoot settings chartName chartSecrets gatewayEventKeys maybeGatewayImage

buildChartDeletePlan ::
    FilePath ->
    Maybe ValidatedSettings ->
    String ->
    Either String ChartDeploymentPlan
buildChartDeletePlan repoRoot maybeSettings chartName = do
    releaseOrder <- resolveDependencyOrder repoRoot chartName
    let manualPvRoot = maybe (repoRoot </> defaultChartDataRootRelative) resolvedManualPvHostRoot maybeSettings
        reversedOrder = reverse releaseOrder
    releases <-
        forM reversedOrder $ \releaseName -> do
            definition <- resolveChart repoRoot releaseName
            pure
                ChartReleasePlan
                    { chartReleasePlanChartName = releaseName,
                      chartReleasePlanReleaseName = releaseName,
                      chartReleasePlanNamespace = chartName,
                      chartReleasePlanChartDir = chartDefinitionChartDir definition,
                      chartReleasePlanValuesJson = "{}",
                      chartReleasePlanStorageBindings =
                        map
                            (storageBinding manualPvRoot chartName releaseName)
                            (chartDefinitionStorage definition)
                    }
    pure
        ChartDeploymentPlan
            { chartDeploymentPlanRootChart = chartName,
              chartDeploymentPlanNamespace = chartName,
              chartDeploymentPlanReleases = releases,
              chartDeploymentPlanPublicFqdn = Nothing
            }

renderChartList :: FilePath -> ValidatedSettings -> IO (Either String String)
renderChartList repoRoot settings = do
    snapshotsResult <- helmReleaseSnapshots
    pure $ do
        snapshots <- snapshotsResult
        let publicFqdn = either (const Nothing) Just (resolvePublicFqdn settings)
            renderedLines = "CHART_LIST" : concatMap (renderChartEntry snapshots publicFqdn) supportedChartNames
        pure (unlines renderedLines)
  where
    renderChartEntry snapshots publicFqdn chartName =
        case resolveChart repoRoot chartName of
            Left _ -> []
            Right definition ->
                let snapshot = Map.lookup chartName snapshots
                    dependencies =
                        if null (chartDefinitionDependencies definition)
                            then "<none>"
                            else intercalate "," (chartDefinitionDependencies definition)
                    baseLines =
                        [ "CHART",
                          "NAME=" ++ chartName,
                          "STATUS=" ++ maybe "not-installed" chartInstallSnapshotStatus snapshot,
                          "NAMESPACE=" ++ maybe "<none>" chartInstallSnapshotNamespace snapshot,
                          "DEPENDENCIES=" ++ dependencies
                        ]
                 in case (chartDefinitionRequiresPublicHost definition, publicFqdn) of
                        (True, Just fqdn) -> baseLines ++ ["PUBLIC_FQDN=" ++ fqdn]
                        _ -> baseLines

renderChartStatus :: FilePath -> ValidatedSettings -> String -> IO (Either String String)
renderChartStatus repoRoot settings chartName = do
    snapshotsResult <- helmReleaseSnapshots
    case snapshotsResult of
        Left err -> pure (Left err)
        Right snapshots -> do
            let installedSnapshot = Map.lookup chartName snapshots
                runtimeNamespace = maybe chartName chartInstallSnapshotNamespace installedSnapshot
            secretsResult <- resolveChartSecrets repoRoot runtimeNamespace
            case secretsResult of
                Left err -> pure (Left err)
                Right chartSecrets -> do
                    eventKeysResult <- resolveGatewayEventKeys repoRoot runtimeNamespace
                    case eventKeysResult of
                        Left err -> pure (Left err)
                        Right gatewayEventKeys -> do
                            rootPlanResult <-
                                buildChartDeploymentPlan repoRoot settings runtimeNamespace chartSecrets gatewayEventKeys
                            pure $ do
                                rootPlan <- rootPlanResult
                                definition <- resolveChart repoRoot chartName
                                chartRelease <-
                                    case filter ((== chartName) . chartReleasePlanReleaseName) (chartDeploymentPlanReleases rootPlan) of
                                        [release] -> Right release
                                        _ -> Left ("Chart '" ++ chartName ++ "' is not part of root plan '" ++ runtimeNamespace ++ "'")
                                let dependencies =
                                        if null (chartDefinitionDependencies definition)
                                            then "<none>"
                                            else intercalate "," (chartDefinitionDependencies definition)
                                    headerLines =
                                        [ "CHART_STATUS",
                                          "NAME=" ++ chartName,
                                          "STATUS=" ++ maybe "not-installed" chartInstallSnapshotStatus installedSnapshot,
                                          "ROOT_CHART=" ++ runtimeNamespace,
                                          "NAMESPACE=" ++ runtimeNamespace,
                                          "DEPENDENCIES=" ++ dependencies
                                        ]
                                    publicHostLines =
                                        case (chartDefinitionRequiresPublicHost definition, chartDeploymentPlanPublicFqdn rootPlan) of
                                            (True, Just fqdn) -> ["PUBLIC_FQDN=" ++ fqdn]
                                            _ -> []
                                    releaseLines =
                                        concatMap
                                            (renderStatusRelease snapshots runtimeNamespace definition)
                                            (chartDeploymentPlanReleases rootPlan)
                                pure . unlines $ headerLines ++ publicHostLines ++ releaseLines ++ renderStorageReport (chartReleasePlanStorageBindings chartRelease)

deployChartPlan :: ChartDeploymentPlan -> IO (Either String String)
deployChartPlan plan = do
    snapshotsResult <- helmReleaseSnapshots
    case snapshotsResult of
        Left err -> pure (Left err)
        Right snapshots -> do
            let duplicates =
                    sort
                        [ chartReleasePlanReleaseName release
                        | release <- chartDeploymentPlanReleases plan,
                          Map.member (chartReleasePlanReleaseName release) snapshots
                        ]
            if not (null duplicates)
                then pure (Left ("Chart singleton violation. Existing releases already installed: " ++ intercalate ", " duplicates))
                else do
                    ensureResult <- ensureChartStorage plan
                    case ensureResult of
                        Left err -> pure (Left err)
                        Right () -> do
                            deployResult <- foldM deployRelease (Right ()) (chartDeploymentPlanReleases plan)
                            pure (deployResult >> Right (renderDeployReport plan))
  where
    deployRelease :: Either String () -> ChartReleasePlan -> IO (Either String ())
    deployRelease (Left err) _ = pure (Left err)
    deployRelease (Right ()) release = helmUpgradeInstall release

deleteChartPlan :: ChartDeploymentPlan -> IO (Either String String)
deleteChartPlan plan = do
    uninstallResult <- foldM uninstallRelease (Right ()) (chartDeploymentPlanReleases plan)
    case uninstallResult of
        Left err -> pure (Left err)
        Right () -> do
            bindingsResult <- foldM deleteReleaseBindings (Right ()) (chartDeploymentPlanReleases plan)
            case bindingsResult of
                Left err -> pure (Left err)
                Right () -> do
                    namespaceResult <-
                        deleteKubectlObject
                            [ "delete",
                              "namespace",
                              chartDeploymentPlanNamespace plan,
                              "--ignore-not-found=true",
                              "--wait=true"
                            ]
                    pure (namespaceResult >> Right (renderDeleteReport plan))
  where
    uninstallRelease :: Either String () -> ChartReleasePlan -> IO (Either String ())
    uninstallRelease (Left err) _ = pure (Left err)
    uninstallRelease (Right ()) release = do
        outputResult <-
            runCaptured
                ("helm uninstall " ++ chartReleasePlanReleaseName release)
                "helm"
                ["uninstall", chartReleasePlanReleaseName release, "--namespace", chartReleasePlanNamespace release]
        pure $ do
            output <- outputResult
            case processExitCode output of
                ExitSuccess -> Right ()
                ExitFailure _ ->
                    let detail = map toLower (processStderr output ++ processStdout output)
                     in if "not found" `isInfixOf` detail || "release: not found" `isInfixOf` detail
                            then Right ()
                            else Left ("helm uninstall " ++ chartReleasePlanReleaseName release ++ " failed: " ++ processStderr output ++ processStdout output)

    deleteReleaseBindings :: Either String () -> ChartReleasePlan -> IO (Either String ())
    deleteReleaseBindings (Left err) _ = pure (Left err)
    deleteReleaseBindings (Right ()) release =
        foldM deleteBinding (Right ()) (chartReleasePlanStorageBindings release)

    deleteBinding :: Either String () -> ChartStorageBinding -> IO (Either String ())
    deleteBinding (Left err) _ = pure (Left err)
    deleteBinding (Right ()) binding = do
        pvcResult <-
            deleteKubectlObject
                [ "delete",
                  "pvc",
                  chartStorageBindingPersistentVolumeClaimName binding,
                  "--namespace",
                  chartDeploymentPlanNamespace plan,
                  "--ignore-not-found=true",
                  "--wait=true"
                ]
        case pvcResult of
            Left err -> pure (Left err)
            Right () ->
                deleteKubectlObject
                    [ "delete",
                      "pv",
                      chartStorageBindingPersistentVolumeName binding,
                      "--ignore-not-found=true",
                      "--wait=true"
                    ]

resolveChartSecrets :: FilePath -> String -> IO (Either String (Map String String))
resolveChartSecrets repoRoot namespace =
    resolveOrGenerateStringMap repoRoot namespace ".secrets.json" requiredChartSecretKeys 24

resolveGatewayEventKeys :: FilePath -> String -> IO (Either String (Map String String))
resolveGatewayEventKeys repoRoot namespace =
    resolveOrGenerateStringMap repoRoot namespace ".gateway-event-keys.json" gatewayNodeIds 32

buildChartDeploymentPlanPure ::
    FilePath ->
    ValidatedSettings ->
    String ->
    Map String String ->
    Map String String ->
    Maybe (String, String) ->
    Either String ChartDeploymentPlan
buildChartDeploymentPlanPure repoRoot settings chartName chartSecrets gatewayEventKeys maybeGatewayImage = do
    when (chartStorageClassName /= "manual")
        (Left "Chart platform requires StorageClass 'manual'; dynamic provisioners are not permitted")
    releaseOrder <- resolveDependencyOrder repoRoot chartName
    definitions <- mapM (resolveChart repoRoot) releaseOrder
    publicFqdn <-
        if any chartDefinitionRequiresPublicHost definitions
            then Just <$> resolvePublicFqdn settings
            else Right Nothing
    releases <-
        forM definitions $ \definition -> do
            let storageBindings =
                    map
                        (storageBinding (resolvedManualPvHostRoot settings) chartName (chartDefinitionName definition))
                        (chartDefinitionStorage definition)
            valuesJson <-
                renderReleaseValuesJson
                    definition
                    chartName
                    chartName
                    settings
                    chartSecrets
                    gatewayEventKeys
                    storageBindings
                    publicFqdn
                    maybeGatewayImage
            pure
                ChartReleasePlan
                    { chartReleasePlanChartName = chartDefinitionName definition,
                      chartReleasePlanReleaseName = chartDefinitionName definition,
                      chartReleasePlanNamespace = chartName,
                      chartReleasePlanChartDir = chartDefinitionChartDir definition,
                      chartReleasePlanValuesJson = valuesJson,
                      chartReleasePlanStorageBindings = storageBindings
                    }
    pure
        ChartDeploymentPlan
            { chartDeploymentPlanRootChart = chartName,
              chartDeploymentPlanNamespace = chartName,
              chartDeploymentPlanReleases = releases,
              chartDeploymentPlanPublicFqdn = publicFqdn
            }

resolveDependencyOrder :: FilePath -> String -> Either String [String]
resolveDependencyOrder repoRoot chartName = do
    _ <- resolveChart repoRoot chartName
    (_, ordered) <- visit chartName [] [] []
    pure ordered
  where
    visit :: String -> [String] -> [String] -> [String] -> Either String ([String], [String])
    visit current visiting visited ordered
        | current `elem` visited = Right (visited, ordered)
        | current `elem` visiting = Left ("Chart dependency cycle detected at '" ++ current ++ "'")
        | otherwise = do
            definition <- resolveChart repoRoot current
            (visitedAfter, orderedAfter) <-
                foldM
                    (\(visitedAcc, orderedAcc) dependency ->
                        visit dependency (current : visiting) visitedAcc orderedAcc
                    )
                    (visited, ordered)
                    (chartDefinitionDependencies definition)
            pure (current : visitedAfter, orderedAfter ++ [current])

resolvePublicFqdn :: ValidatedSettings -> Either String String
resolvePublicFqdn settings =
    case maybeNonEmptyText (vscode_fqdn domainSection) of
        Just fqdn -> Right fqdn
        Nothing -> requireNonEmptyText "public FQDN" (demo_fqdn domainSection)
  where
    domainSection = domain (validatedConfig settings)

renderReleaseValuesJson ::
    ChartDefinition ->
    String ->
    String ->
    ValidatedSettings ->
    Map String String ->
    Map String String ->
    [ChartStorageBinding] ->
    Maybe String ->
    Maybe (String, String) ->
    Either String String
renderReleaseValuesJson definition namespace rootChart settings chartSecrets gatewayEventKeys storageBindings publicFqdn maybeGatewayImage = do
    values <-
        case chartDefinitionName definition of
            "keycloak-postgres" ->
                case storageBindings of
                    [binding] -> valuesForKeycloakPostgres namespace rootChart settings chartSecrets binding
                    _ -> Left "keycloak-postgres requires exactly one storage binding"
            "keycloak" ->
                case publicFqdn of
                    Just fqdn -> valuesForKeycloak namespace rootChart settings chartSecrets fqdn
                    Nothing -> Left "keycloak requires a public host"
            "vscode" ->
                case (publicFqdn, storageBindings) of
                    (Just fqdn, [binding]) -> valuesForVscode namespace rootChart settings chartSecrets binding fqdn
                    (Nothing, _) -> Left "vscode requires a public host"
                    _ -> Left "vscode requires exactly one storage binding"
            "gateway" ->
                case publicFqdn of
                    Just fqdn -> valuesForGateway namespace rootChart settings gatewayEventKeys fqdn maybeGatewayImage
                    Nothing -> Left "gateway requires a public host"
            _ -> Left ("Unsupported chart definition '" ++ chartDefinitionName definition ++ "'")
    pure (BL8.unpack (Pretty.encodePretty' prettyJsonConfig values))

valuesForKeycloakPostgres ::
    String ->
    String ->
    ValidatedSettings ->
    Map String String ->
    ChartStorageBinding ->
    Either String Value
valuesForKeycloakPostgres namespace rootChart settings chartSecrets binding = do
    postgresPassword <- requireMapValue "keycloak_postgres_password" chartSecrets "keycloak_postgres_password is required in chart secrets"
    pure
        ( object
            [ "replicaCount" .= (1 :: Int),
              "podAntiAffinity" .= podAntiAffinityValue settings,
              "global"
                .= object
                    [ "namespace" .= namespace,
                      "rootChart" .= rootChart
                    ],
              "postgres"
                .= object
                    [ "database" .= ("keycloak" :: String),
                      "username" .= ("keycloak" :: String),
                      "password" .= postgresPassword
                    ],
              "persistence"
                .= object
                    [ "existingClaim" .= chartStorageBindingPersistentVolumeClaimName binding,
                      "size" .= chartStorageBindingStorageSize binding
                    ]
            ]
        )

valuesForKeycloak ::
    String ->
    String ->
    ValidatedSettings ->
    Map String String ->
    String ->
    Either String Value
valuesForKeycloak namespace rootChart settings chartSecrets publicFqdn = do
    adminPassword <- requireMapValue "keycloak_admin_password" chartSecrets "keycloak_admin_password is required in chart secrets"
    postgresPassword <- requireMapValue "keycloak_postgres_password" chartSecrets "keycloak_postgres_password is required in chart secrets"
    nginxSecret <- requireMapValue "keycloak_nginx_client_secret" chartSecrets "keycloak_nginx_client_secret is required in chart secrets"
    pure
        ( object
            [ "replicaCount" .= (2 :: Int),
              "podAntiAffinity" .= podAntiAffinityValue settings,
              "global"
                .= object
                    [ "namespace" .= namespace,
                      "rootChart" .= rootChart
                    ],
              "keycloak"
                .= object
                    [ "adminUser" .= ("admin" :: String),
                      "adminPassword" .= adminPassword,
                      "publicHost" .= publicFqdn,
                      "relativePath" .= ("/auth" :: String),
                      "realmName" .= keycloakRealmName
                    ],
              "postgres"
                .= object
                    [ "host" .= ("keycloak-postgres" :: String),
                      "database" .= ("keycloak" :: String),
                      "username" .= ("keycloak" :: String),
                      "password" .= postgresPassword
                    ],
              "nginx"
                .= object
                    [ "clientId" .= keycloakNginxClientId,
                      "clientSecret" .= nginxSecret
                    ]
            ]
        )

valuesForGateway ::
    String ->
    String ->
    ValidatedSettings ->
    Map String String ->
    String ->
    Maybe (String, String) ->
    Either String Value
valuesForGateway namespace rootChart settings gatewayEventKeys publicFqdn maybeGatewayImage = do
    when (Map.null gatewayEventKeys) (Left "gateway chart requires non-empty event_keys")
    forM_ gatewayNodeIds $ \nodeId ->
        unless (Map.member nodeId gatewayEventKeys)
            (Left ("gateway chart event_keys missing entry for '" ++ nodeId ++ "'"))
    let config = validatedConfig settings
        operationalAws = aws config
        awsAccessKeyId = Text.unpack (access_key_id operationalAws)
        awsSecretAccessKey = Text.unpack (secret_access_key operationalAws)
        awsRegion = Text.unpack (region operationalAws)
        zoneId = Text.unpack (zone_id (route53 config))
        sessionTokenValue = maybe "" Text.unpack (session_token operationalAws)
    when (null awsAccessKeyId) (Left "gateway chart requires aws_access_key_id in settings")
    when (null awsSecretAccessKey) (Left "gateway chart requires aws_secret_access_key in settings")
    when (null awsRegion) (Left "gateway chart requires aws_region in settings")
    when (null zoneId) (Left "gateway chart requires route53_zone_id in settings")
    (gatewayRepository, gatewayTag) <-
        case maybeGatewayImage of
            Just imageInfo -> Right imageInfo
            Nothing -> Left "gateway chart requires a resolved image reference"
    pure
        ( object
            [ "replicaCount" .= length gatewayNodeIds,
              "podAntiAffinity" .= podAntiAffinityValue settings,
              "global"
                .= object
                    [ "namespace" .= namespace,
                      "rootChart" .= rootChart
                    ],
              "image"
                .= object
                    [ "repository" .= gatewayRepository,
                      "tag" .= gatewayTag,
                      "pullPolicy" .= ("IfNotPresent" :: String)
                    ],
              "ports"
                .= object
                    [ "rest" .= (8443 :: Int),
                      "events" .= (8444 :: Int)
                    ],
              "timing"
                .= object
                    [ "heartbeatIntervalSeconds" .= (0.5 :: Double),
                      "reconnectIntervalSeconds" .= (0.5 :: Double),
                      "syncIntervalSeconds" .= (1.0 :: Double),
                      "heartbeatTimeoutSeconds" .= (5 :: Int)
                    ],
              "nodes" .= object ["rankedIds" .= gatewayNodeIds],
              "eventKeys" .= Map.fromList [(nodeId, mapLookupDefault nodeId gatewayEventKeys) | nodeId <- gatewayNodeIds],
              "dnsWriteGate"
                .= object
                    [ "enabled" .= True,
                      "zoneId" .= zoneId,
                      "fqdn" .= publicFqdn,
                      "ttl" .= (60 :: Int),
                      "awsRegion" .= awsRegion
                    ],
              "aws"
                .= object
                    [ "accessKeyId" .= awsAccessKeyId,
                      "secretAccessKey" .= awsSecretAccessKey,
                      "sessionToken" .= sessionTokenValue
                    ],
              "certManager"
                .= object
                    [ "enabled" .= True,
                      "caIssuerName" .= ("gateway-ca-issuer" :: String),
                      "caCertificateName" .= ("gateway-ca" :: String),
                      "caSecretName" .= ("gateway-ca-tls" :: String),
                      "caCommonName" .= ("gateway-mesh-ca" :: String)
                    ]
            ]
        )

valuesForVscode ::
    String ->
    String ->
    ValidatedSettings ->
    Map String String ->
    ChartStorageBinding ->
    String ->
    Either String Value
valuesForVscode namespace rootChart settings chartSecrets binding publicFqdn = do
    nginxSecret <- requireMapValue "keycloak_nginx_client_secret" chartSecrets "keycloak_nginx_client_secret is required in chart secrets"
    pure
        ( object
            [ "replicaCount" .= (1 :: Int),
              "podAntiAffinity" .= podAntiAffinityValue settings,
              "global"
                .= object
                    [ "namespace" .= namespace,
                      "rootChart" .= rootChart
                    ],
              "ingress"
                .= object
                    [ "host" .= publicFqdn,
                      "clusterIssuer" .= chartClusterIssuer
                    ],
              "nginx"
                .= object
                    [ "clientId" .= keycloakNginxClientId,
                      "clientSecret" .= nginxSecret,
                      "realm" .= keycloakRealmName,
                      "keycloakInternalUrl" .= ("http://keycloak:8080" :: String),
                      "image" .= ("127.0.0.1:30080/prodbox/prodbox-nginx-oidc:latest" :: String)
                    ],
              "vscode"
                .= object
                    [ "existingClaim" .= chartStorageBindingPersistentVolumeClaimName binding,
                      "image" .= ("codercom/code-server:4.98.2" :: String)
                    ]
            ]
        )

podAntiAffinityValue :: ValidatedSettings -> Value
podAntiAffinityValue settings =
    object
        [ "enabled" .= not (dev_mode (deployment (validatedConfig settings)))
        ]

resolveGatewayChartImage :: IO (Either String (Maybe (String, String)))
resolveGatewayChartImage = do
    machineIdExists <- doesFileExist machineIdPath
    if not machineIdExists
        then pure (Left ("gateway chart requires machine identity file " ++ machineIdPath))
        else do
            rawMachineId <- readFile machineIdPath
            let machineId = map toLower (trimWhitespace rawMachineId)
            pure
                ( if length machineId /= 32 || any (not . isHexDigit) machineId
                    then Left ("Unexpected machine-id format in " ++ machineIdPath ++ ": " ++ show machineId)
                    else Right (Just ("127.0.0.1:30080/prodbox/prodbox-gateway", take 63 ("prodbox-" ++ machineId)))
                )

renderStatusRelease ::
    Map String ChartInstallSnapshot ->
    String ->
    ChartDefinition ->
    ChartReleasePlan ->
    [String]
renderStatusRelease snapshots runtimeNamespace definition release
    | chartReleasePlanReleaseName release == chartDefinitionName definition
        || chartReleasePlanReleaseName release `elem` chartDefinitionDependencies definition =
            let snapshot = Map.lookup (chartReleasePlanReleaseName release) snapshots
             in [ "RELEASE",
                  "NAME=" ++ chartReleasePlanReleaseName release,
                  "CHART=" ++ chartReleasePlanChartName release,
                  "STATUS=" ++ maybe "not-installed" chartInstallSnapshotStatus snapshot,
                  "NAMESPACE=" ++ maybe runtimeNamespace chartInstallSnapshotNamespace snapshot
                ]
    | otherwise = []

renderDeployReport :: ChartDeploymentPlan -> String
renderDeployReport plan =
    unlines $
        [ "CHART_DEPLOYMENT",
          "ROOT_CHART=" ++ chartDeploymentPlanRootChart plan,
          "NAMESPACE=" ++ chartDeploymentPlanNamespace plan
        ]
            ++ maybe [] (\fqdn -> ["PUBLIC_FQDN=" ++ fqdn]) (chartDeploymentPlanPublicFqdn plan)
            ++ concatMap renderRelease (chartDeploymentPlanReleases plan)
  where
    renderRelease release =
        [ "RELEASE",
          "NAME=" ++ chartReleasePlanReleaseName release,
          "CHART=" ++ chartReleasePlanChartName release,
          "CHART_PATH=" ++ chartReleasePlanChartDir release
        ]
            ++ renderStorageReport (chartReleasePlanStorageBindings release)

renderDeleteReport :: ChartDeploymentPlan -> String
renderDeleteReport plan =
    unlines $
        [ "CHART_DELETION",
          "ROOT_CHART=" ++ chartDeploymentPlanRootChart plan,
          "NAMESPACE=" ++ chartDeploymentPlanNamespace plan,
          "HOST_STORAGE_PRESERVED=true"
        ]
            ++ concatMap renderRelease (chartDeploymentPlanReleases plan)
  where
    renderRelease release =
        [ "RELEASE",
          "NAME=" ++ chartReleasePlanReleaseName release,
          "CHART=" ++ chartReleasePlanChartName release
        ]
            ++ renderStorageReport (chartReleasePlanStorageBindings release)

ensureChartStorage :: ChartDeploymentPlan -> IO (Either String ())
ensureChartStorage plan = do
    let bindings = concatMap chartReleasePlanStorageBindings (chartDeploymentPlanReleases plan)
    if null bindings
        then applyManifest (namespaceManifest (chartDeploymentPlanNamespace plan) (chartDeploymentPlanRootChart plan))
        else do
            nodeHostnameResult <- singleNodeHostname
            case nodeHostnameResult of
                Left err -> pure (Left err)
                Right nodeHostname -> do
                    prepareResult <- foldM prepareBinding (Right ()) bindings
                    case prepareResult of
                        Left err -> pure (Left err)
                        Right () ->
                            applyManifest
                                ( chartStorageManifest
                                    (chartDeploymentPlanNamespace plan)
                                    (chartDeploymentPlanRootChart plan)
                                    bindings
                                    nodeHostname
                                )
  where
    prepareBinding :: Either String () -> ChartStorageBinding -> IO (Either String ())
    prepareBinding (Left err) _ = pure (Left err)
    prepareBinding (Right ()) binding = do
        ensureResult <- ensureChartStateDir (chartStorageBindingHostPath binding)
        case ensureResult of
            Left err -> pure (Left err)
            Right () -> do
                phaseResult <- persistentVolumePhase (chartStorageBindingPersistentVolumeName binding)
                case phaseResult of
                    Left err -> pure (Left err)
                    Right (Just phase)
                        | phase == "Released" || phase == "Failed" ->
                            deleteKubectlObject
                                [ "delete",
                                  "pv",
                                  chartStorageBindingPersistentVolumeName binding,
                                  "--ignore-not-found=true",
                                  "--wait=true"
                                ]
                    Right _ -> pure (Right ())

namespaceManifest :: String -> String -> Value
namespaceManifest namespace rootChart =
    object
        [ "apiVersion" .= ("v1" :: String),
          "kind" .= ("Namespace" :: String),
          "metadata"
            .= object
                [ "name" .= namespace,
                  "labels" .= object ["prodbox.io/chart-root" .= rootChart]
                ]
        ]

singleNodeHostname :: IO (Either String String)
singleNodeHostname = do
    outputResult <- runCaptured "kubectl get nodes" "kubectl" ["get", "nodes", "-o", "json"]
    pure $ do
        output <- outputResult
        case processExitCode output of
            ExitSuccess ->
                either (Left . ("kubectl get nodes returned unexpected JSON payload: " ++)) Right (parseNodeHostname (processStdout output))
            ExitFailure _ -> Left ("kubectl get nodes failed: " ++ processStderr output ++ processStdout output)

parseNodeHostname :: String -> Either String String
parseNodeHostname stdoutText = do
    payload <- eitherDecode (BL8.pack stdoutText) :: Either String Value
    parseEither parser payload
  where
    parser = withObject "kubectl get nodes" $ \obj -> do
        items <- obj .: "items"
        case items of
            [nodeValue] ->
                withObject "node entry" (\nodeObj -> do
                    metadata <- nodeObj .: "metadata"
                    withObject "node metadata" (.: "name") metadata
                )
                    nodeValue
            _ -> fail "chart storage requires exactly one Kubernetes node"

persistentVolumePhase :: String -> IO (Either String (Maybe String))
persistentVolumePhase persistentVolumeName = do
    outputResult <- runCaptured "kubectl get pv" "kubectl" ["get", "pv", persistentVolumeName, "-o", "json"]
    pure $ do
        output <- outputResult
        case processExitCode output of
            ExitSuccess -> Just <$> parsePersistentVolumePhase (processStdout output)
            ExitFailure _ ->
                let detail = map toLower (processStderr output ++ processStdout output)
                 in if "notfound" `isInfixOf` detail || "not found" `isInfixOf` detail
                        then Right Nothing
                        else Left ("Failed to query PersistentVolume " ++ persistentVolumeName ++ ": " ++ processStderr output ++ processStdout output)

parsePersistentVolumePhase :: String -> Either String String
parsePersistentVolumePhase stdoutText = do
    payload <- eitherDecode (BL8.pack stdoutText) :: Either String Value
    parseEither parser payload
  where
    parser = withObject "persistent volume" $ \obj -> do
        statusObject <- obj .: "status"
        withObject "persistent volume status" (.: "phase") statusObject

applyManifest :: Value -> IO (Either String ())
applyManifest manifest =
    withTempFile "prodbox-chart-manifest-" $ \path handle -> do
        BL.hPutStr handle (Pretty.encodePretty' prettyJsonConfig manifest)
        hClose handle
        outputResult <- runCaptured "kubectl apply" "kubectl" ["apply", "-f", path]
        pure $ do
            output <- outputResult
            case processExitCode output of
                ExitSuccess -> Right ()
                ExitFailure _ -> Left ("kubectl apply failed: " ++ processStderr output ++ processStdout output)

deleteKubectlObject :: [String] -> IO (Either String ())
deleteKubectlObject args = do
    outputResult <- runCaptured ("kubectl " ++ unwords args) "kubectl" args
    pure $ do
        output <- outputResult
        case processExitCode output of
            ExitSuccess -> Right ()
            ExitFailure _ ->
                let detail = map toLower (processStderr output ++ processStdout output)
                 in if "notfound" `isInfixOf` detail || "not found" `isInfixOf` detail
                        then Right ()
                        else Left ("kubectl " ++ unwords args ++ " failed: " ++ processStderr output ++ processStdout output)

helmUpgradeInstall :: ChartReleasePlan -> IO (Either String ())
helmUpgradeInstall release =
    withTempFile (chartReleasePlanReleaseName release ++ "-values-") $ \path handle -> do
        BL8.hPutStr handle (BL8.pack (chartReleasePlanValuesJson release))
        hClose handle
        outputResult <-
            runCaptured
                "helm upgrade --install"
                "helm"
                [ "upgrade",
                  "--install",
                  "--wait",
                  "--atomic",
                  "--timeout",
                  "30m0s",
                  chartReleasePlanReleaseName release,
                  chartReleasePlanChartDir release,
                  "--namespace",
                  chartReleasePlanNamespace release,
                  "--create-namespace",
                  "--values",
                  path
                ]
        pure $ do
            output <- outputResult
            case processExitCode output of
                ExitSuccess -> Right ()
                ExitFailure _ -> Left ("helm upgrade --install " ++ chartReleasePlanReleaseName release ++ " failed: " ++ processStderr output ++ processStdout output)

helmReleaseSnapshots :: IO (Either String (Map String ChartInstallSnapshot))
helmReleaseSnapshots = do
    outputResult <- runCaptured "helm list" "helm" ["list", "--all-namespaces", "--output", "json"]
    pure $ do
        output <- outputResult
        case processExitCode output of
            ExitSuccess -> do
                snapshots <-
                    either
                        (Left . ("helm list returned unexpected JSON payload: " ++))
                        Right
                        (eitherDecode (BL8.pack (processStdout output)) :: Either String [ChartInstallSnapshot])
                pure (Map.fromList [(chartInstallSnapshotReleaseName snapshot, snapshot) | snapshot <- snapshots])
            ExitFailure _ -> Left ("helm list failed: " ++ processStderr output ++ processStdout output)

resolveOrGenerateStringMap ::
    FilePath ->
    String ->
    FilePath ->
    [String] ->
    Int ->
    IO (Either String (Map String String))
resolveOrGenerateStringMap repoRoot namespace fileName requiredKeys byteLength = do
    let namespaceDir = chartStateDir repoRoot namespace
        targetPath = namespaceDir </> fileName
    ensureResult <- ensureChartStateDir namespaceDir
    case ensureResult of
        Left err -> pure (Left err)
        Right () -> do
            targetExists <- doesFileExist targetPath
            if targetExists
                then do
                    existingResult <- readRequiredStringMap targetPath requiredKeys
                    case existingResult of
                        Right values -> pure (Right values)
                        Left _ -> writeGeneratedMap targetPath requiredKeys byteLength
                else writeGeneratedMap targetPath requiredKeys byteLength

writeGeneratedMap :: FilePath -> [String] -> Int -> IO (Either String (Map String String))
writeGeneratedMap targetPath requiredKeys byteLength = do
    generatedPairsResult <- mapM (\key -> fmap ((,) key) <$> randomHexString byteLength) requiredKeys
    case sequence generatedPairsResult of
        Left err -> pure (Left err)
        Right generatedPairs -> do
            let values = Map.fromList generatedPairs
            writeResult <- try (BL.writeFile targetPath (Pretty.encodePretty' prettyJsonConfig values <> BL8.pack "\n")) :: IO (Either IOException ())
            pure $ case writeResult of
                Left err -> Left (displayException err)
                Right () -> Right values

randomHexString :: Int -> IO (Either String String)
randomHexString byteLength = do
    readResult <-
        try
            ( withBinaryFile "/dev/urandom" ReadMode $ \handle ->
                BS.hGet handle byteLength
            ) :: IO (Either IOException BS.ByteString)
    pure $ do
        bytes <- either (Left . displayException) Right readResult
        if BS.length bytes /= byteLength
            then Left ("Failed to read " ++ show byteLength ++ " random bytes from /dev/urandom")
            else Right (concatMap byteToHex (BS.unpack bytes))

byteToHex :: Word8 -> String
byteToHex byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered

chartStateDir :: FilePath -> String -> FilePath
chartStateDir repoRoot namespace = repoRoot </> chartStateRootRelative </> namespace

ensureChartStateDir :: FilePath -> IO (Either String ())
ensureChartStateDir path = do
    createResult <- try (createDirectoryIfMissing True path) :: IO (Either IOException ())
    case createResult of
        Left _ -> repairChartStateDir path
        Right () -> do
            permissionsResult <- try (getPermissions path) :: IO (Either IOException Permissions)
            case permissionsResult of
                Left _ -> repairChartStateDir path
                Right permissions ->
                    if writable permissions && searchable permissions
                        then pure (Right ())
                        else repairChartStateDir path

repairChartStateDir :: FilePath -> IO (Either String ())
repairChartStateDir path = do
    uidResult <- commandStdout "id" ["-u"]
    case uidResult of
        Left err -> pure (Left err)
        Right uid -> do
            gidResult <- commandStdout "id" ["-g"]
            case gidResult of
                Left err -> pure (Left err)
                Right gid -> do
                    mkdirResult <- runCommandExpectSuccess "sudo mkdir" "sudo" ["mkdir", "-p", path]
                    case mkdirResult of
                        Left err -> pure (Left err)
                        Right () -> do
                            chownResult <- runCommandExpectSuccess "sudo chown" "sudo" ["chown", "-R", uid ++ ":" ++ gid, path]
                            case chownResult of
                                Left err -> pure (Left err)
                                Right () -> runCommandExpectSuccess "sudo chmod" "sudo" ["chmod", "0770", path]

runCaptured :: String -> FilePath -> [String] -> IO (Either String ProcessOutput)
runCaptured action commandPath args = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = commandPath,
                  commandArguments = args,
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Nothing
                }
    pure $ case result of
        Failure err -> Left (action ++ " failed: " ++ err)
        Success output -> Right output

runCommandExpectSuccess :: String -> FilePath -> [String] -> IO (Either String ())
runCommandExpectSuccess action commandPath args = do
    outputResult <- runCaptured action commandPath args
    pure $ do
        output <- outputResult
        case processExitCode output of
            ExitSuccess -> Right ()
            ExitFailure _ -> Left (processStderr output ++ processStdout output)

commandStdout :: FilePath -> [String] -> IO (Either String String)
commandStdout commandPath args = do
    outputResult <- runCaptured (commandPath ++ " " ++ unwords args) commandPath args
    pure $ do
        output <- outputResult
        case processExitCode output of
            ExitSuccess -> Right (trimWhitespace (processStdout output))
            ExitFailure _ -> Left (processStderr output ++ processStdout output)

readRequiredStringMap :: FilePath -> [String] -> IO (Either String (Map String String))
readRequiredStringMap path requiredKeys = do
    readResult <- try (BL.readFile path) :: IO (Either IOException BL.ByteString)
    pure $ do
        contents <- either (Left . displayException) Right readResult
        parsed <- eitherDecode contents :: Either String (Map String String)
        pairs <-
            forM requiredKeys $ \key -> do
                value <- requireMapValue key parsed (key ++ " missing")
                pure (key, value)
        pure (Map.fromList pairs)

requireMapValue :: String -> Map String String -> String -> Either String String
requireMapValue key values err =
    case Map.lookup key values of
        Just value | not (null (trimWhitespace value)) -> Right value
        _ -> Left err

requireNonEmptyText :: String -> Text.Text -> Either String String
requireNonEmptyText description value =
    let rendered = Text.unpack (Text.strip value)
     in if null rendered
            then Left (description ++ " is required for the chart platform")
            else Right rendered

maybeNonEmptyText :: Maybe Text.Text -> Maybe String
maybeNonEmptyText maybeValue =
    case maybeValue of
        Nothing -> Nothing
        Just value ->
            let rendered = Text.unpack (Text.strip value)
             in if null rendered then Nothing else Just rendered

mapLookupDefault :: Ord key => key -> Map key String -> String
mapLookupDefault key values = maybe "" id (Map.lookup key values)

withTempFile :: String -> (FilePath -> Handle -> IO (Either String a)) -> IO (Either String a)
withTempFile prefix action = do
    tempDir <- getTemporaryDirectory
    bracket
        (openTempFile tempDir prefix)
        cleanupTempFile
        (\(path, handle) -> action path handle)

cleanupTempFile :: (FilePath, Handle) -> IO ()
cleanupTempFile (path, handle) = do
    ignoreIOException (hClose handle)
    ignoreIOException (removeFile path)

ignoreIOException :: IO () -> IO ()
ignoreIOException action = do
    _ <- try action :: IO (Either IOException ())
    pure ()

prettyJsonConfig :: Pretty.Config
prettyJsonConfig = Pretty.defConfig{Pretty.confIndent = Pretty.Spaces 2}

trimWhitespace :: String -> String
trimWhitespace = Text.unpack . Text.strip . Text.pack
