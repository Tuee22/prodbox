{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Lib.ChartPlatform
  ( ChartDefinition (..)
  , ChartDeploymentPlan (..)
  , ChartInstallSnapshot (..)
  , ChartReleasePlan (..)
  , buildChartDeletePlan
  , buildChartDeploymentPlan
  , buildChartDeploymentPlanForSubstrate
  , deleteChartPlan
  , deployChartPlan
  , gatewayNodeIds
  , keycloakVscodeClientId
  , keycloakRealmName
  , renderChartList
  , renderChartStatus
  , retainedPublicEdgeTlsSecretManifest
  , resolveChart
  , resolveChartSecrets
  , supportedChartNames
  )
where

import Control.Exception
  ( IOException
  , bracket
  , try
  )
import Control.Monad
  ( filterM
  , foldM
  , forM
  , unless
  , when
  )
import Data.Aeson
  ( FromJSON (parseJSON)
  , Value (..)
  , eitherDecode
  , object
  , toJSON
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isDigit, isHexDigit, toLower)
import Data.List
  ( find
  , intercalate
  , isInfixOf
  , nub
  , sort
  , sortOn
  , stripPrefix
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , ChartStorageSpec (..)
  , chartDynamicStorageManifest
  , chartPersistentVolumeManifest
  , chartStorageClassName
  , chartStorageManifest
  , defaultChartDataRootRelative
  , renderStorageReport
  , storageBinding
  )
import Prodbox.PostgresPlatform
  ( patroniClusterName
  , patroniCredentialsSecretName
  , patroniDatabaseName
  , patroniFsGroup
  , patroniOperatorDeploymentName
  , patroniOperatorNamespace
  , patroniPostgresqlCrdName
  , patroniPrimaryServiceHost
  , patroniPrimaryServiceName
  , patroniRunAsGroup
  , patroniRunAsUser
  , patroniStandbySecretName
  , patroniStorageSize
  , patroniStorageSpecs
  , patroniSuperuserSecretName
  , patroniUsername
  )
import Prodbox.PublicEdge
  ( apiPathPrefix
  , authPathPrefix
  , harborPathPrefix
  , minioPathPrefix
  , publicFqdn
  , resolveSubstrateHostedZoneId
  , vscodePathPrefix
  , websocketOidcPathPrefix
  , websocketPathPrefix
  )
import Prodbox.Result
  ( Result (..)
  )
import Prodbox.Retry
  ( RetryPolicy (..)
  )
import Prodbox.Secret.HostBootstrap (preApplyDerivedSecretsForRelease)
import Prodbox.Service
  ( HasPg (..)
  , PgError (..)
  , ServiceError (..)
  , retryServiceAction
  , toServiceError
  )
import Prodbox.Settings
  ( AwsSubstrateSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Substrate (Substrate (..), substrateId)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getTemporaryDirectory
  , removeFile
  )
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )
import System.FilePath ((</>))
import System.IO
  ( Handle
  , hClose
  , openTempFile
  )

-- Sprint 3.13 chunk 16: the @chartStateRootRelative = ".prodbox-state"@
-- constant + its derived 'chartStateDir' helper are removed. Every Sprint
-- 3.13 consumer of the @.prodbox-state/<ns>/.secrets.json@ chart-secret
-- cache (chunks 8\8211\&14) and the @.gateway-event-keys.json@ event-key
-- cache (chunk 16) reads its values from k8s @Secret@s instead — the
-- daemon writes them via 'Prodbox.Secret.EnsureNamespace.applyDerivedSecrets'
-- and the charts read them via Helm @lookup@. With these consumers gone,
-- nothing in @src/@ writes to @.prodbox-state/charts/@ any more, and
-- 'Prodbox.CheckCode.checkForbidDotProdboxState' broadens to refuse any
-- new @.prodbox-state/@ string literal anywhere in @src/@ + @app/@.

chartClusterIssuer :: String
chartClusterIssuer = "letsencrypt-http01"

keycloakRealmName :: String
keycloakRealmName = "prodbox"

keycloakVscodeClientId :: String
keycloakVscodeClientId = "vscode"

keycloakApiClientId :: String
keycloakApiClientId = "prodbox-api"

keycloakWebsocketClientId :: String
keycloakWebsocketClientId = "prodbox-websocket"

publicEdgeGatewayClassName :: String
publicEdgeGatewayClassName = "prodbox-public-edge"

publicEdgeGatewayName :: String
publicEdgeGatewayName = "public-edge"

publicEdgeKeycloakRouteName :: String
publicEdgeKeycloakRouteName = "keycloak"

publicEdgeKeycloakListenerName :: String
publicEdgeKeycloakListenerName = "https"

publicEdgeHttpRedirectListenerName :: String
publicEdgeHttpRedirectListenerName = "http"

publicEdgeHttpRedirectRouteName :: String
publicEdgeHttpRedirectRouteName = "public-edge-http-redirect"

publicEdgeTlsSecretName :: String
publicEdgeTlsSecretName = "public-edge-tls"

retainedPublicEdgeTlsSecretNamespace :: String
retainedPublicEdgeTlsSecretNamespace = "prodbox"

retainedPublicEdgeTlsSecretName :: String
retainedPublicEdgeTlsSecretName = "public-edge-tls-retained"

publicEdgeVscodeListenerName :: String
publicEdgeVscodeListenerName = "https"

publicEdgeApiListenerName :: String
publicEdgeApiListenerName = "https"

publicEdgeWebsocketListenerName :: String
publicEdgeWebsocketListenerName = "https"

publicEdgeVscodeSecurityPolicyName :: String
publicEdgeVscodeSecurityPolicyName = "vscode-oidc"

publicEdgeApiSecurityPolicyName :: String
publicEdgeApiSecurityPolicyName = "api-jwt"

publicEdgeWebsocketSecurityPolicyName :: String
publicEdgeWebsocketSecurityPolicyName = "websocket-jwt"

publicEdgeRouteClaimName :: String
publicEdgeRouteClaimName = "prodbox_route"

gatewayNodeIds :: [String]
gatewayNodeIds = ["node-a", "node-b", "node-c"]

machineIdPath :: FilePath
machineIdPath = "/etc/machine-id"

data ChartDefinition = ChartDefinition
  { chartDefinitionName :: String
  , chartDefinitionChartDir :: FilePath
  , chartDefinitionDependencies :: [String]
  , chartDefinitionStorage :: [ChartStorageSpec]
  , chartDefinitionRequiresPublicHost :: Bool
  , chartDefinitionExternalRequirements :: [ChartExternalRequirement]
  }
  deriving (Eq, Show)

data ChartReleasePlan = ChartReleasePlan
  { chartReleasePlanChartName :: String
  , chartReleasePlanReleaseName :: String
  , chartReleasePlanNamespace :: String
  , chartReleasePlanChartDir :: FilePath
  , chartReleasePlanValuesJson :: String
  , chartReleasePlanStorageBindings :: [ChartStorageBinding]
  }
  deriving (Eq, Show)

data ChartDeploymentPlan = ChartDeploymentPlan
  { chartDeploymentPlanRepoRoot :: FilePath
  , chartDeploymentPlanRootChart :: String
  , chartDeploymentPlanNamespace :: String
  , chartDeploymentPlanReleases :: [ChartReleasePlan]
  , chartDeploymentPlanPublicFqdn :: Maybe String
  , chartDeploymentPlanExternalRequirements :: [ChartExternalRequirement]
  , chartDeploymentPlanSubstrate :: Substrate
  }
  deriving (Eq, Show)

data ChartExternalRequirement
  = ChartRequiresPatroniPlatform
  deriving (Eq, Show)

data ChartInstallSnapshot = ChartInstallSnapshot
  { chartInstallSnapshotReleaseName :: String
  , chartInstallSnapshotNamespace :: String
  , chartInstallSnapshotStatus :: String
  }
  deriving (Eq, Show)

data ResolvedCustomImage = ResolvedCustomImage
  { resolvedCustomImageRepository :: String
  , resolvedCustomImageTag :: String
  , resolvedCustomImageRolloutToken :: Maybe String
  }
  deriving (Eq, Show)

data PatroniClusterReadiness
  = PatroniClusterReady
  | PatroniClusterPending String
  deriving (Eq, Show)

data PerconaPatroniClaim = PerconaPatroniClaim
  { perconaPatroniClaimName :: String
  , perconaPatroniClaimVolumeName :: Maybe String
  }
  deriving (Eq, Show)

instance FromJSON ChartInstallSnapshot where
  parseJSON = withObject "helm list entry" $ \obj ->
    ChartInstallSnapshot
      <$> obj .: "name"
      <*> obj .: "namespace"
      <*> obj .: "status"

supportedChartNames :: [String]
supportedChartNames = ["keycloak", "vscode", "api", "websocket", "gateway"]

resolveChart :: FilePath -> String -> Either String ChartDefinition
resolveChart repoRoot chartName =
  case chartName of
    "keycloak-postgres" ->
      Right
        ChartDefinition
          { chartDefinitionName = "keycloak-postgres"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "keycloak-postgres"
          , chartDefinitionDependencies = []
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = False
          , chartDefinitionExternalRequirements = [ChartRequiresPatroniPlatform]
          }
    "keycloak" ->
      Right
        ChartDefinition
          { chartDefinitionName = "keycloak"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "keycloak"
          , chartDefinitionDependencies = ["keycloak-postgres"]
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = True
          , chartDefinitionExternalRequirements = []
          }
    "vscode" ->
      Right
        ChartDefinition
          { chartDefinitionName = "vscode"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "vscode"
          , chartDefinitionDependencies = ["keycloak"]
          , chartDefinitionStorage =
              [ ChartStorageSpec
                  { chartStorageSpecStatefulSetName = "vscode"
                  , chartStorageSpecPersistentVolumeClaimName = "vscode-data-0"
                  , chartStorageSpecStorageSize = "50Gi"
                  , chartStorageSpecOrdinal = 0
                  , chartStorageSpecClaimSuffix = "data"
                  }
              ]
          , chartDefinitionRequiresPublicHost = True
          , chartDefinitionExternalRequirements = []
          }
    "redis" ->
      Right
        ChartDefinition
          { chartDefinitionName = "redis"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "redis"
          , chartDefinitionDependencies = []
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = False
          , chartDefinitionExternalRequirements = []
          }
    "api" ->
      Right
        ChartDefinition
          { chartDefinitionName = "api"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "api"
          , chartDefinitionDependencies = []
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = True
          , chartDefinitionExternalRequirements = []
          }
    "websocket" ->
      Right
        ChartDefinition
          { chartDefinitionName = "websocket"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "websocket"
          , chartDefinitionDependencies = ["redis"]
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = True
          , chartDefinitionExternalRequirements = []
          }
    "gateway" ->
      Right
        ChartDefinition
          { chartDefinitionName = "gateway"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "gateway"
          , chartDefinitionDependencies = []
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = True
          , chartDefinitionExternalRequirements = []
          }
    _ ->
      Left
        ( "Unsupported chart '"
            ++ chartName
            ++ "'. Supported charts: "
            ++ intercalate ", " supportedChartNames
        )

buildChartDeploymentPlan
  :: FilePath
  -> ValidatedSettings
  -> String
  -> Map String String
  -> Map String String
  -> IO (Either String ChartDeploymentPlan)
buildChartDeploymentPlan =
  buildChartDeploymentPlanForSubstrate SubstrateHomeLocal

buildChartDeploymentPlanForSubstrate
  :: Substrate
  -> FilePath
  -> ValidatedSettings
  -> String
  -> Map String String
  -> Map String String
  -> IO (Either String ChartDeploymentPlan)
buildChartDeploymentPlanForSubstrate substrate repoRoot settings chartName chartSecrets gatewayEventKeys = do
  let dependencyOrderResult = resolveDependencyOrder repoRoot chartName
  case dependencyOrderResult of
    Left err -> pure (Left err)
    Right releaseOrder -> do
      gatewayImageResult <-
        if "gateway" `elem` releaseOrder
          then resolveGatewayChartImageForSubstrate substrate
          else pure (Right Nothing)
      publicEdgeWorkloadImageResult <-
        if "api" `elem` releaseOrder || "websocket" `elem` releaseOrder
          then resolvePublicEdgeWorkloadChartImageForSubstrate substrate
          else pure (Right Nothing)
      gatewayHostedZoneIdResult <-
        if "gateway" `elem` releaseOrder
          then resolveGatewayHostedZoneIdForSubstrate substrate repoRoot settings
          else pure (Right Nothing)
      pure $ do
        maybeGatewayImage <- gatewayImageResult
        maybePublicEdgeWorkloadImage <- publicEdgeWorkloadImageResult
        maybeGatewayHostedZoneId <- gatewayHostedZoneIdResult
        buildChartDeploymentPlanPure
          substrate
          repoRoot
          settings
          chartName
          chartSecrets
          gatewayEventKeys
          maybeGatewayImage
          maybePublicEdgeWorkloadImage
          maybeGatewayHostedZoneId

buildChartDeletePlan
  :: FilePath
  -> Maybe ValidatedSettings
  -> String
  -> Either String ChartDeploymentPlan
buildChartDeletePlan repoRoot maybeSettings chartName = do
  releaseOrder <- resolveDependencyOrder repoRoot chartName
  let manualPvRoot = maybe (repoRoot </> defaultChartDataRootRelative) resolvedManualPvHostRoot maybeSettings
      reversedOrder = reverse releaseOrder
  releases <-
    forM reversedOrder $ \releaseName -> do
      definition <- resolveChart repoRoot releaseName
      pure
        ChartReleasePlan
          { chartReleasePlanChartName = releaseName
          , chartReleasePlanReleaseName = releaseName
          , chartReleasePlanNamespace = chartName
          , chartReleasePlanChartDir = chartDefinitionChartDir definition
          , chartReleasePlanValuesJson = "{}"
          , chartReleasePlanStorageBindings =
              map
                (storageBinding manualPvRoot chartName releaseName)
                (chartStorageSpecsForRelease chartName releaseName definition)
          }
  pure
    ChartDeploymentPlan
      { chartDeploymentPlanRepoRoot = repoRoot
      , chartDeploymentPlanRootChart = chartName
      , chartDeploymentPlanNamespace = chartName
      , chartDeploymentPlanReleases = releases
      , chartDeploymentPlanPublicFqdn = Nothing
      , chartDeploymentPlanExternalRequirements = []
      , chartDeploymentPlanSubstrate = SubstrateHomeLocal
      }

renderChartList :: FilePath -> ValidatedSettings -> IO (Either String String)
renderChartList repoRoot settings = do
  snapshotsResult <- helmReleaseSnapshots
  pure $ do
    snapshots <- snapshotsResult
    let renderedLines = "CHART_LIST" : concatMap (renderChartEntry snapshots) supportedChartNames
    pure (unlines renderedLines)
 where
  renderChartEntry snapshots chartName =
    case resolveChart repoRoot chartName of
      Left _ -> []
      Right definition ->
        let snapshot = Map.lookup chartName snapshots
            maybePublicFqdn =
              either
                (const Nothing)
                Just
                (resolveRootPublicFqdn SubstrateHomeLocal settings chartName)
            dependencies =
              if null (chartDefinitionDependencies definition)
                then "<none>"
                else intercalate "," (chartDefinitionDependencies definition)
            baseLines =
              [ "CHART"
              , "NAME=" ++ chartName
              , "STATUS=" ++ maybe "not-installed" chartInstallSnapshotStatus snapshot
              , "NAMESPACE=" ++ maybe "<none>" chartInstallSnapshotNamespace snapshot
              , "DEPENDENCIES=" ++ dependencies
              ]
         in case (chartDefinitionRequiresPublicHost definition, maybePublicFqdn) of
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
          -- Sprint 3.13 chunk 16: gateway event keys self-bootstrap from the
          -- daemon Pod after master-seed acquisition (see
          -- 'Prodbox.Gateway.Daemon.selfBootstrapOwnSecrets'). The chart
          -- reads them via Helm `lookup` of the daemon-written
          -- `gateway-event-keys` Secret. No host-side resolution needed.
          let gatewayEventKeys = Map.empty :: Map String String
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
                  [ "CHART_STATUS"
                  , "NAME=" ++ chartName
                  , "STATUS=" ++ maybe "not-installed" chartInstallSnapshotStatus installedSnapshot
                  , "ROOT_CHART=" ++ runtimeNamespace
                  , "NAMESPACE=" ++ runtimeNamespace
                  , "DEPENDENCIES=" ++ dependencies
                  ]
                publicHostLines =
                  case (chartDefinitionRequiresPublicHost definition, chartDeploymentPlanPublicFqdn rootPlan) of
                    (True, Just fqdn) -> ["PUBLIC_FQDN=" ++ fqdn]
                    _ -> []
                releaseLines =
                  concatMap
                    (renderStatusRelease snapshots runtimeNamespace definition)
                    (chartDeploymentPlanReleases rootPlan)
            pure . unlines $
              headerLines
                ++ publicHostLines
                ++ releaseLines
                ++ renderStorageReport (chartReleasePlanStorageBindings chartRelease)

deployChartPlan :: ChartDeploymentPlan -> IO (Either String String)
deployChartPlan plan = do
  snapshotsResult <- helmReleaseSnapshots
  case snapshotsResult of
    Left err -> pure (Left err)
    Right snapshots -> do
      let duplicates =
            sort
              [ chartReleasePlanReleaseName release
              | release <- chartDeploymentPlanReleases plan
              , Map.member (chartReleasePlanReleaseName release) snapshots
              ]
      if not (null duplicates)
        then pure (Right (renderDeployReport plan))
        else do
          requirementResult <- validateExternalRequirements plan
          case requirementResult of
            Left err -> pure (Left err)
            Right () -> do
              ensureResult <- ensureChartStorage plan
              case ensureResult of
                Left err -> pure (Left err)
                Right () -> do
                  restoreResult <- restorePublicEdgeTlsSecretAfterNamespaceCreate plan
                  case restoreResult of
                    Left err -> pure (Left err)
                    Right () -> do
                      deployResult <- foldM deployRelease (Right ()) (chartDeploymentPlanReleases plan)
                      pure (deployResult >> Right (renderDeployReport plan))
 where
  deployRelease :: Either String () -> ChartReleasePlan -> IO (Either String ())
  deployRelease (Left err) _ = pure (Left err)
  deployRelease (Right ()) release
    | chartReleasePlanReleaseName release == "keycloak-postgres" =
        deployPatroniRelease release
    | otherwise = do
        -- Sprint 3.13 chunk 33: host-side pre-apply of every Inventory
        -- entry for (namespace, release) so Helm @lookup@ in the chart
        -- templates finds the daemon-derived Secret at render time on
        -- first install. The chart's pre-install Job remains the
        -- in-cluster idempotent fallback.
        preApplyResult <-
          preApplyDerivedSecretsForRelease
            (chartReleasePlanNamespace release)
            (chartReleasePlanReleaseName release)
        case preApplyResult of
          Left err -> pure (Left err)
          Right () -> do
            installResult <- helmUpgradeInstall release
            case installResult of
              Left err -> pure (Left err)
              Right () -> do
                storageResult <- ensureReleaseStorageBindings release
                case storageResult of
                  Left err -> pure (Left err)
                  Right () -> validateReleaseReady release

  deployPatroniRelease :: ChartReleasePlan -> IO (Either String ())
  deployPatroniRelease release = do
    -- Sprint 3.13 chunk 33: same pre-apply as the non-Patroni path so
    -- the Crunchy operator finds the three Patroni-role Secrets when
    -- it reconciles the PostgresCluster CR. See 'deployRelease'.
    preApplyResult <-
      preApplyDerivedSecretsForRelease
        (chartReleasePlanNamespace release)
        (chartReleasePlanReleaseName release)
    case preApplyResult of
      Left err -> pure (Left err)
      Right () ->
        case chartDeploymentPlanSubstrate plan of
          SubstrateHomeLocal -> deployPatroniReleaseStaged release
          SubstrateAws -> do
            installResult <- helmUpgradeInstall release
            case installResult of
              Left err -> pure (Left err)
              Right () -> validateReleaseReady release

  deployPatroniReleaseStaged :: ChartReleasePlan -> IO (Either String ())
  deployPatroniReleaseStaged release = do
    maybeBootstrapAnchorBinding <- readOptionalPatroniBootstrapAnchorBinding release
    case maybeBootstrapAnchorBinding of
      Nothing -> do
        installResult <- helmUpgradeInstall release
        case installResult of
          Left err -> pure (Left err)
          Right () -> do
            storageResult <- ensureReleaseStorageBindings release
            case storageResult of
              Left err -> pure (Left err)
              Right () -> validateReleaseReady release
      Just anchorBinding ->
        case chartReleaseWithPatroniInstanceCount 1 release of
          Left err -> pure (Left err)
          Right bootstrapRelease -> do
            installBootstrapResult <- helmUpgradeInstall bootstrapRelease
            case installBootstrapResult of
              Left err -> pure (Left err)
              Right () -> do
                bootstrapStorageResult <-
                  ensurePerconaPatroniStorageBindingsWithExpectedClaims
                    (chartReleasePlanNamespace release)
                    (chartDeploymentPlanRootChart plan)
                    [anchorBinding]
                    1
                    (Just (chartStorageBindingPersistentVolumeName anchorBinding))
                case bootstrapStorageResult of
                  Left err -> pure (Left err)
                  Right () -> do
                    bootstrapReadyResult <-
                      waitForPatroniClusterReadyWithReplicaCount
                        (chartReleasePlanNamespace release)
                        1
                    case bootstrapReadyResult of
                      Left err -> pure (Left err)
                      Right () -> do
                        installFullResult <- helmUpgradeInstall release
                        case installFullResult of
                          Left err -> pure (Left err)
                          Right () -> do
                            storageResult <- ensureReleaseStorageBindings release
                            case storageResult of
                              Left err -> pure (Left err)
                              Right () -> validateReleaseReady release

  -- Sprint 3.13 chunk 13: derive the bootstrap anchor PV from live k8s state
  -- (the Patroni primary endpoint -> primary pod -> its PVC -> bound PV) when
  -- the previous cluster is still present. After a supported chart delete, the
  -- only surviving anchor is the retained ordinal-0 host root, so fall back to
  -- that path before allowing a full three-replica cold bootstrap.
  readOptionalPatroniBootstrapAnchorBinding :: ChartReleasePlan -> IO (Maybe ChartStorageBinding)
  readOptionalPatroniBootstrapAnchorBinding release = do
    maybeAnchorVolumeName <-
      discoverPatroniAnchorPersistentVolumeName (chartReleasePlanNamespace release)
    case maybeAnchorVolumeName >>= findBindingByVolumeName of
      Just anchorBinding -> pure (Just anchorBinding)
      Nothing -> retainedOrdinalZeroAnchorBinding
   where
    findBindingByVolumeName anchorVolumeName =
      find
        ((== anchorVolumeName) . chartStorageBindingPersistentVolumeName)
        (chartReleasePlanStorageBindings release)

    retainedOrdinalZeroAnchorBinding = do
      case find ((== 0) . chartStorageBindingOrdinal) (chartReleasePlanStorageBindings release) of
        Nothing -> pure Nothing
        Just binding -> do
          exists <- doesDirectoryExist (chartStorageBindingHostPath binding)
          pure (if exists then Just binding else Nothing)

  ensureReleaseStorageBindings :: ChartReleasePlan -> IO (Either String ())
  ensureReleaseStorageBindings release
    | chartDeploymentPlanSubstrate plan == SubstrateAws = pure (Right ())
    | chartReleasePlanReleaseName release == "keycloak-postgres" =
        ensurePerconaPatroniStorageBindings
          (chartDeploymentPlanRepoRoot plan)
          (chartDeploymentPlanNamespace plan)
          (chartDeploymentPlanRootChart plan)
          (chartReleasePlanStorageBindings release)
    | otherwise = pure (Right ())

validateReleaseReady :: ChartReleasePlan -> IO (Either String ())
validateReleaseReady release
  | chartReleasePlanReleaseName release == "keycloak-postgres" =
      waitForPatroniClusterReady (chartReleasePlanNamespace release)
  | otherwise = pure (Right ())

validateExternalRequirements :: ChartDeploymentPlan -> IO (Either String ())
validateExternalRequirements plan =
  foldM validateRequirement (Right ()) (chartDeploymentPlanExternalRequirements plan)
 where
  validateRequirement :: Either String () -> ChartExternalRequirement -> IO (Either String ())
  validateRequirement (Left err) _ = pure (Left err)
  validateRequirement (Right ()) requirement =
    case requirement of
      ChartRequiresPatroniPlatform -> validatePatroniPlatformReady

ensurePerconaPatroniStorageBindings
  :: FilePath
  -> String
  -> String
  -> [ChartStorageBinding]
  -> IO (Either String ())
ensurePerconaPatroniStorageBindings _repoRoot namespace rootChart logicalBindings = do
  -- Sprint 3.13 chunk 13: anchor PV comes from live k8s state via
  -- 'discoverPatroniAnchorPersistentVolumeName' (Patroni primary endpoint).
  -- The @.patroni-anchor-volume@ marker is gone.
  maybeAnchorVolumeName <- discoverPatroniAnchorPersistentVolumeName namespace
  ensurePerconaPatroniStorageBindingsWithExpectedClaims
    namespace
    rootChart
    logicalBindings
    (length logicalBindings)
    maybeAnchorVolumeName

ensurePerconaPatroniStorageBindingsWithExpectedClaims
  :: String
  -> String
  -> [ChartStorageBinding]
  -> Int
  -> Maybe String
  -> IO (Either String ())
ensurePerconaPatroniStorageBindingsWithExpectedClaims namespace rootChart logicalBindings expectedClaimCount maybeAnchorVolumeName = do
  claimsResult <- waitForPerconaPatroniClaims namespace expectedClaimCount
  case claimsResult of
    Left err -> pure (Left err)
    Right claims
      | length claims /= length logicalBindings ->
          pure
            ( Left
                ( "Percona Patroni storage reconcile expected "
                    ++ show (length logicalBindings)
                    ++ " PostgreSQL PVCs but discovered "
                    ++ show (length claims)
                    ++ "."
                )
            )
      | otherwise -> do
          nodeHostnameResult <- singleNodeHostname
          case nodeHostnameResult of
            Left err -> pure (Left err)
            Right nodeHostname -> do
              let runtimeBindingsResult =
                    resolvePerconaPatroniRuntimeBindings logicalBindings claims maybeAnchorVolumeName
              case runtimeBindingsResult of
                Left err -> pure (Left err)
                Right runtimeBindings -> do
                  prepareResult <- foldM prepareStorageBinding (Right ()) runtimeBindings
                  case prepareResult of
                    Left err -> pure (Left err)
                    Right () ->
                      applyManifest
                        ( chartPersistentVolumeManifest
                            namespace
                            rootChart
                            runtimeBindings
                            nodeHostname
                        )

waitForPerconaPatroniClaims :: String -> Int -> IO (Either String [PerconaPatroniClaim])
waitForPerconaPatroniClaims namespace expectedClaimCount =
  mapPgError <$> retryServiceAction perconaPatroniClaimRetryPolicy discoverExpectedClaims
 where
  clusterName = patroniClusterName namespace

  discoverExpectedClaims :: IO (Either PgError [PerconaPatroniClaim])
  discoverExpectedClaims = do
    claimsResult <- discoverPerconaPatroniClaims namespace
    pure $
      case claimsResult of
        Left err -> Left (retryablePgError err)
        Right claims
          | length claims == expectedClaimCount ->
              Right (sortOn perconaPatroniClaimName claims)
          | otherwise ->
              Left
                ( retryablePgError
                    ( "Percona Patroni cluster "
                        ++ clusterName
                        ++ " did not create the expected PostgreSQL PVC set. "
                        ++ "Discovered claims: "
                        ++ if null claims
                          then "<none>"
                          else intercalate ", " (sort (map perconaPatroniClaimName claims)) ++ "."
                    )
                )

discoverPerconaPatroniClaims :: String -> IO (Either String [PerconaPatroniClaim])
discoverPerconaPatroniClaims namespace = do
  let clusterName = patroniClusterName namespace
      selector =
        "postgres-operator.crunchydata.com/cluster="
          ++ clusterName
          ++ ",postgres-operator.crunchydata.com/data=postgres"
  outputResult <- runPg ["get", "pvc", "--namespace", namespace, "--selector", selector, "-o", "json"]
  pure $ do
    output <- mapPgError outputResult
    case processExitCode output of
      ExitFailure _ ->
        Left
          ( "kubectl get pvc failed: "
              ++ processStderr output
              ++ processStdout output
          )
      ExitSuccess ->
        either
          (Left . ("kubectl get pvc returned unexpected JSON payload: " ++))
          Right
          (eitherDecode (BL8.pack (processStdout output)) >>= parseEither parsePerconaPatroniClaims)

parsePerconaPatroniClaims :: Value -> Parser [PerconaPatroniClaim]
parsePerconaPatroniClaims =
  withObject "pvc list" $ \obj -> do
    items <- obj .: "items"
    forM items $
      withObject "pvc item" $ \item -> do
        metadata <- item .: "metadata"
        claimName <- metadata .: "name"
        maybeSpec <- item .:? "spec"
        volumeName <-
          case maybeSpec of
            Nothing -> pure Nothing
            Just specValue ->
              withObject "pvc spec" (\specObj -> specObj .:? "volumeName") specValue
        pure
          PerconaPatroniClaim
            { perconaPatroniClaimName = claimName
            , perconaPatroniClaimVolumeName = volumeName
            }

resolvePerconaPatroniRuntimeBindings
  :: [ChartStorageBinding]
  -> [PerconaPatroniClaim]
  -> Maybe String
  -> Either String [ChartStorageBinding]
resolvePerconaPatroniRuntimeBindings logicalBindings claims maybeAnchorVolumeName =
  case maybeAnchorVolumeName >>= \anchorVolumeName -> find ((== anchorVolumeName) . chartStorageBindingPersistentVolumeName) logicalBindings of
    Nothing -> assignBindingsBySortedClaims logicalBindings claims
    Just anchorBinding ->
      let anchorVolumeName = chartStorageBindingPersistentVolumeName anchorBinding
          maybeAnchorClaimName =
            perconaPatroniClaimName
              <$> find ((== Just anchorVolumeName) . perconaPatroniClaimVolumeName) claims
          sortedClaimNames = sort (map perconaPatroniClaimName claims)
          anchorClaimName =
            case maybeAnchorClaimName of
              Just claimName -> Right claimName
              Nothing ->
                case sortedClaimNames of
                  [] -> Left "Percona Patroni PVC discovery returned no claims for the preserved cluster anchor."
                  claimName : _ -> Right claimName
          remainingBindings =
            [ binding
            | binding <- logicalBindings
            , chartStorageBindingPersistentVolumeName binding /= anchorVolumeName
            ]
       in do
            assignedAnchorClaimName <- anchorClaimName
            let remainingClaimNames =
                  [ claimName
                  | claimName <- sortedClaimNames
                  , claimName /= assignedAnchorClaimName
                  ]
            if length remainingBindings /= length remainingClaimNames
              then
                Left
                  ( "Percona Patroni PVC discovery did not leave the expected follower claims after preserving anchor volume "
                      ++ anchorVolumeName
                      ++ "."
                  )
              else
                Right
                  ( runtimeStorageBindingForClaim anchorBinding assignedAnchorClaimName
                      : zipWith runtimeStorageBindingForClaim remainingBindings remainingClaimNames
                  )

assignBindingsBySortedClaims
  :: [ChartStorageBinding]
  -> [PerconaPatroniClaim]
  -> Either String [ChartStorageBinding]
assignBindingsBySortedClaims logicalBindings claims =
  let sortedClaimNames = sort (map perconaPatroniClaimName claims)
   in if length logicalBindings /= length sortedClaimNames
        then
          Left
            ( "Percona Patroni storage reconcile expected "
                ++ show (length logicalBindings)
                ++ " claims but discovered "
                ++ show (length sortedClaimNames)
                ++ "."
            )
        else Right (zipWith runtimeStorageBindingForClaim logicalBindings sortedClaimNames)

runtimeStorageBindingForClaim :: ChartStorageBinding -> String -> ChartStorageBinding
runtimeStorageBindingForClaim binding claimName =
  binding
    { chartStorageBindingStatefulSetName = perconaStatefulSetNameFromClaim claimName
    , chartStorageBindingPersistentVolumeClaimName = claimName
    }

perconaStatefulSetNameFromClaim :: String -> String
perconaStatefulSetNameFromClaim claimName =
  maybe claimName id (dropSuffix "-pgdata" claimName)

dropSuffix :: (Eq a) => [a] -> [a] -> Maybe [a]
dropSuffix suffix value =
  reverse <$> stripPrefix (reverse suffix) (reverse value)

perconaPatroniClaimRetryPolicy :: RetryPolicy
perconaPatroniClaimRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 60
    , retryPolicyBaseDelayMicros = 5 * 1000000
    , retryPolicyMultiplier = 1
    , retryPolicyMaxDelayMicros = 5 * 1000000
    }

validatePatroniPlatformReady :: IO (Either String ())
validatePatroniPlatformReady = do
  crdResult <-
    runPg ["get", "crd", patroniPostgresqlCrdName, "-o", "name"]
  outputResult <-
    runPg
      [ "get"
      , "deployment"
      , patroniOperatorDeploymentName
      , "--namespace"
      , patroniOperatorNamespace
      , "-o"
      , "name"
      ]
  pure $
    case crdResult of
      Left err -> Left (Text.unpack (serviceErrorMessage (toServiceError err)))
      Right crdOutput ->
        case processExitCode crdOutput of
          ExitFailure _ ->
            Left
              ( "Patroni PostgreSQL platform is not ready. "
                  ++ "Run `prodbox rke2 reconcile` before deploying charts that depend on PostgreSQL. "
                  ++ processStderr crdOutput
                  ++ processStdout crdOutput
              )
          ExitSuccess ->
            case outputResult of
              Left err -> Left (Text.unpack (serviceErrorMessage (toServiceError err)))
              Right output ->
                case processExitCode output of
                  ExitSuccess -> Right ()
                  ExitFailure _ ->
                    Left
                      ( "Patroni PostgreSQL platform is not ready. "
                          ++ "Run `prodbox rke2 reconcile` before deploying charts that depend on PostgreSQL."
                      )

waitForPatroniClusterReady :: String -> IO (Either String ())
waitForPatroniClusterReady namespace =
  waitForPatroniClusterReadyWithReplicaCount namespace 3

waitForPatroniClusterReadyWithReplicaCount :: String -> Int -> IO (Either String ())
waitForPatroniClusterReadyWithReplicaCount namespace expectedReadyReplicas =
  mapPgError <$> retryServiceAction patroniClusterReadyRetryPolicy checkReadiness
 where
  clusterName = patroniClusterName namespace
  timeoutSeconds =
    ( retryPolicyMaxAttempts patroniClusterReadyRetryPolicy
        * retryPolicyBaseDelayMicros patroniClusterReadyRetryPolicy
    )
      `div` 1000000

  checkReadiness :: IO (Either PgError ())
  checkReadiness = do
    readinessResult <- patroniClusterReadiness namespace expectedReadyReplicas
    pure $
      case readinessResult of
        Left err ->
          Left (retryablePgError ("Patroni cluster " ++ clusterName ++ " did not converge: " ++ err))
        Right PatroniClusterReady -> Right ()
        Right (PatroniClusterPending detail) ->
          Left
            ( retryablePgError
                ( "Patroni cluster "
                    ++ clusterName
                    ++ " did not converge within "
                    ++ show timeoutSeconds
                    ++ " seconds. Last status: "
                    ++ detail
                    ++ "."
                )
            )

retryablePgError :: String -> PgError
retryablePgError message =
  PgError
    ServiceError
      { serviceErrorMessage = Text.pack message
      , serviceErrorRetryable = True
      }

mapPgError :: Either PgError value -> Either String value
mapPgError result =
  case result of
    Left err -> Left (Text.unpack (serviceErrorMessage (toServiceError err)))
    Right value -> Right value

runPgExpectSuccess :: String -> [String] -> IO (Either String ())
runPgExpectSuccess action arguments = do
  outputResult <- runPg arguments
  pure $ do
    output <- mapPgError outputResult
    case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure _ -> Left (action ++ " failed: " ++ processStderr output ++ processStdout output)

patroniClusterReadyRetryPolicy :: RetryPolicy
patroniClusterReadyRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 180
    , retryPolicyBaseDelayMicros = 10 * 1000000
    , retryPolicyMultiplier = 1
    , retryPolicyMaxDelayMicros = 10 * 1000000
    }

patroniClusterReadiness :: String -> Int -> IO (Either String PatroniClusterReadiness)
patroniClusterReadiness namespace expectedReadyReplicas = do
  clusterStatus <- readOptionalPatroniClusterStatus namespace
  readyPostgresCount <- readOptionalPatroniReadyPostgresCount namespace
  pure $
    case normalizedPatroniClusterStatus clusterStatus of
      Just "ready" ->
        if readyPostgresCount == Just expectedReadyReplicas
          then Right PatroniClusterReady
          else
            Right
              ( PatroniClusterPending
                  ( "status=ready,postgres.ready="
                      ++ maybe "<missing>" show readyPostgresCount
                      ++ ",expected.postgres.ready="
                      ++ show expectedReadyReplicas
                  )
              )
      _ ->
        Right
          ( PatroniClusterPending
              ( "status="
                  ++ maybe "<missing>" id (normalizedPatroniClusterStatus clusterStatus)
                  ++ ",postgres.ready="
                  ++ maybe "<missing>" show readyPostgresCount
                  ++ ",expected.postgres.ready="
                  ++ show expectedReadyReplicas
              )
          )

deleteChartPlan :: ChartDeploymentPlan -> IO (Either String String)
deleteChartPlan plan = do
  preserveTlsResult <- preservePublicEdgeTlsSecretBeforeDelete plan
  case preserveTlsResult of
    Left err -> pure (Left err)
    Right () -> do
      preserveResult <- preserveChartSecretsBeforeDelete plan
      case preserveResult of
        Left err -> pure (Left err)
        Right () -> do
          persistPatroniAnchorBindingBeforeDelete
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
                      [ "delete"
                      , "namespace"
                      , chartDeploymentPlanNamespace plan
                      , "--ignore-not-found=true"
                      , "--wait=true"
                      ]
                  pure (namespaceResult >> Right (renderDeleteReport plan))
 where
  preserveChartSecretsBeforeDelete :: ChartDeploymentPlan -> IO (Either String ())
  preserveChartSecretsBeforeDelete deletePlan
    | any
        ((== "keycloak-postgres") . chartReleasePlanReleaseName)
        (chartDeploymentPlanReleases deletePlan) = do
        secretsResult <-
          resolveChartSecrets
            (chartDeploymentPlanRepoRoot deletePlan)
            (chartDeploymentPlanNamespace deletePlan)
        pure (secretsResult >> Right ())
    | otherwise = pure (Right ())

  -- Sprint 3.13 chunk 13: the @.patroni-anchor-volume@ marker is gone.
  -- 'resetRetainedPatroniReplicaBindings' now queries
  -- 'discoverPatroniAnchorPersistentVolumeName' directly at reset time
  -- (k8s state is the single source of truth). This post-install hook has
  -- nothing to record.
  persistPatroniAnchorBindingBeforeDelete :: IO ()
  persistPatroniAnchorBindingBeforeDelete = pure ()

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
                else
                  Left
                    ( "helm uninstall "
                        ++ chartReleasePlanReleaseName release
                        ++ " failed: "
                        ++ processStderr output
                        ++ processStdout output
                    )

  deleteReleaseBindings :: Either String () -> ChartReleasePlan -> IO (Either String ())
  deleteReleaseBindings (Left err) _ = pure (Left err)
  deleteReleaseBindings (Right ()) release =
    if chartReleasePlanReleaseName release == "keycloak-postgres"
      then deletePerconaPatroniBindings release
      else foldM deleteBinding (Right ()) (chartReleasePlanStorageBindings release)

  deleteBinding :: Either String () -> ChartStorageBinding -> IO (Either String ())
  deleteBinding (Left err) _ = pure (Left err)
  deleteBinding (Right ()) binding = do
    podResult <-
      deleteKubectlObject
        [ "delete"
        , "pod"
        , chartStorageBindingStatefulSetName binding ++ "-" ++ show (chartStorageBindingOrdinal binding)
        , "--namespace"
        , chartDeploymentPlanNamespace plan
        , "--ignore-not-found=true"
        , "--wait=true"
        ]
    case podResult of
      Left err -> pure (Left err)
      Right () ->
        do
          pvcResult <-
            deleteKubectlObject
              [ "delete"
              , "pvc"
              , chartStorageBindingPersistentVolumeClaimName binding
              , "--namespace"
              , chartDeploymentPlanNamespace plan
              , "--ignore-not-found=true"
              , "--wait=true"
              ]
          case pvcResult of
            Left pvcErr -> pure (Left pvcErr)
            Right () ->
              deleteKubectlObject
                [ "delete"
                , "pv"
                , chartStorageBindingPersistentVolumeName binding
                , "--ignore-not-found=true"
                , "--wait=true"
                ]

  deletePerconaPatroniBindings :: ChartReleasePlan -> IO (Either String ())
  deletePerconaPatroniBindings release = do
    let namespace = chartReleasePlanNamespace release
        selector =
          "postgres-operator.crunchydata.com/cluster="
            ++ patroniClusterName namespace
            ++ ",postgres-operator.crunchydata.com/data=postgres"
    podResult <-
      runPgExpectSuccess
        "delete Patroni PostgreSQL pods"
        [ "delete"
        , "pod"
        , "--selector"
        , selector
        , "--namespace"
        , namespace
        , "--ignore-not-found=true"
        , "--wait=true"
        ]
    case podResult of
      Left err -> pure (Left err)
      Right () -> do
        pvcResult <-
          runPgExpectSuccess
            "delete Patroni PostgreSQL PVCs"
            [ "delete"
            , "pvc"
            , "--selector"
            , selector
            , "--namespace"
            , namespace
            , "--ignore-not-found=true"
            , "--wait=true"
            ]
        case pvcResult of
          Left err -> pure (Left err)
          Right () ->
            foldM
              deleteDeterministicPersistentVolume
              (Right ())
              (chartReleasePlanStorageBindings release)

  deleteDeterministicPersistentVolume
    :: Either String () -> ChartStorageBinding -> IO (Either String ())
  deleteDeterministicPersistentVolume (Left err) _ = pure (Left err)
  deleteDeterministicPersistentVolume (Right ()) binding =
    deleteKubectlObject
      [ "delete"
      , "pv"
      , chartStorageBindingPersistentVolumeName binding
      , "--ignore-not-found=true"
      , "--wait=true"
      ]

-- | Sprint 3.13 chunk 12: the per-namespace @.prodbox-state/charts/<ns>/.secrets.json@
-- cache is gone. Every key that previously lived here is now either materialized
-- by the gateway daemon's @ensure-namespace@ pre-install Job into a k8s
-- @Secret@ (see [secret_derivation_doctrine.md §6](../../documents/engineering/secret_derivation_doctrine.md))
-- or read via Helm @lookup@ from a sibling cluster Secret. This function
-- therefore returns an empty map; the returned @Map@ is still threaded through
-- 'buildChartDeploymentPlanPure' / 'valuesForXxx' for signature compatibility,
-- but every consumer ignores it. The chart's own pre-install Job + cluster
-- Secret lookups are the structural source-of-truth.
resolveChartSecrets :: FilePath -> String -> IO (Either String (Map String String))
resolveChartSecrets _repoRoot _namespace = pure (Right Map.empty)

-- Sprint 3.13 chunk 16: 'resolveGatewayEventKeys' is gone. Per-node event
-- keys are now derived from the master seed and materialized by the
-- gateway daemon's startup self-bootstrap loop (see
-- 'Prodbox.Gateway.Daemon.selfBootstrapOwnSecrets'); the chart reads the
-- resulting @gateway-event-keys@ Secret via Helm @lookup@. No host-side
-- resolution needed.

readOptionalPatroniClusterStatus :: String -> IO (Maybe String)
readOptionalPatroniClusterStatus namespace = do
  result <-
    runPg
      [ "get"
      , patroniPostgresqlCrdName
      , patroniClusterName namespace
      , "-n"
      , namespace
      , "-o"
      , "jsonpath={.status.state}"
      ]
  pure $
    case result of
      Left _ -> Nothing
      Right output ->
        case processExitCode output of
          ExitFailure _ -> Nothing
          ExitSuccess ->
            let value = trimWhitespace (processStdout output)
             in if null value then Nothing else Just value

readOptionalPatroniReadyPostgresCount :: String -> IO (Maybe Int)
readOptionalPatroniReadyPostgresCount namespace = do
  result <-
    runPg
      [ "get"
      , patroniPostgresqlCrdName
      , patroniClusterName namespace
      , "-n"
      , namespace
      , "-o"
      , "jsonpath={.status.postgres.ready}"
      ]
  pure $
    case result of
      Left _ -> Nothing
      Right output ->
        case processExitCode output of
          ExitFailure _ -> Nothing
          ExitSuccess ->
            case reads (trimWhitespace (processStdout output)) of
              [(value, "")] -> Just value
              _ -> Nothing

normalizedPatroniClusterStatus :: Maybe String -> Maybe String
normalizedPatroniClusterStatus = fmap (map toLower . trimWhitespace)

-- Sprint 3.13 chunks 13 + 14: 'shouldResetPatroniStorage', the
-- @.patroni-reset-required@ marker writer/reader, the @.patroni-anchor-volume@
-- marker, 'readOptionalPatroniAnchorVolumeName', and 'patroniStorageExists'
-- are all gone. The reset arm of 'resolveChartSecrets' is gone (chunk 12), so
-- the only marker writer disappeared with it; the reset path in
-- 'reconcileChartPlatform' is now a no-op, and 'resetRetainedPatroniReplicaBindings'
-- derives the anchor PV from live k8s state via
-- 'discoverPatroniAnchorPersistentVolumeName'. The spec's loud-failure
-- mismatch check (derived password vs @pg_authid@ probe) lands when the live
-- preserved-data exercise drives the failure paths.
discoverPatroniAnchorPersistentVolumeName :: String -> IO (Maybe String)
discoverPatroniAnchorPersistentVolumeName namespace = do
  maybePrimaryPodName <- readOptionalPatroniPrimaryPodName namespace
  case maybePrimaryPodName >>= patroniClaimNameFromPodName of
    Nothing -> pure Nothing
    Just claimName -> readOptionalPersistentVolumeNameForClaim namespace claimName

readOptionalPatroniPrimaryPodName :: String -> IO (Maybe String)
readOptionalPatroniPrimaryPodName namespace = do
  result <-
    runPg
      [ "get"
      , "endpoints"
      , patroniPrimaryServiceName namespace
      , "--namespace"
      , namespace
      , "-o"
      , "jsonpath={.subsets[0].addresses[0].targetRef.name}"
      ]
  pure $
    case result of
      Left _ -> Nothing
      Right output ->
        case processExitCode output of
          ExitFailure _ -> Nothing
          ExitSuccess ->
            let value = trimWhitespace (processStdout output)
             in if null value then Nothing else Just value

patroniClaimNameFromPodName :: String -> Maybe String
patroniClaimNameFromPodName podName = do
  instanceName <- dropPodOrdinal podName
  pure (instanceName ++ "-pgdata")

dropPodOrdinal :: String -> Maybe String
dropPodOrdinal podName =
  case break (== '-') (reverse podName) of
    (reversedOrdinal, '-' : reversedPrefix)
      | not (null reversedOrdinal) && all isDigit reversedOrdinal -> Just (reverse reversedPrefix)
    _ -> Nothing

readOptionalPersistentVolumeNameForClaim :: String -> String -> IO (Maybe String)
readOptionalPersistentVolumeNameForClaim namespace claimName = do
  result <-
    runPg
      [ "get"
      , "pvc"
      , claimName
      , "--namespace"
      , namespace
      , "-o"
      , "jsonpath={.spec.volumeName}"
      ]
  pure $
    case result of
      Left _ -> Nothing
      Right output ->
        case processExitCode output of
          ExitFailure _ -> Nothing
          ExitSuccess ->
            let value = trimWhitespace (processStdout output)
             in if null value then Nothing else Just value

chartReleaseWithPatroniInstanceCount :: Int -> ChartReleasePlan -> Either String ChartReleasePlan
chartReleaseWithPatroniInstanceCount instanceCount release = do
  updatedValuesJson <-
    setPatroniClusterInstanceCount instanceCount (chartReleasePlanValuesJson release)
  pure release {chartReleasePlanValuesJson = updatedValuesJson}

setPatroniClusterInstanceCount :: Int -> String -> Either String String
setPatroniClusterInstanceCount instanceCount valuesJson = do
  values <- eitherDecode (BL8.pack valuesJson) :: Either String Value
  updatedValues <- updatePatroniClusterInstanceCount instanceCount values
  pure (BL8.unpack (Pretty.encodePretty updatedValues))

updatePatroniClusterInstanceCount :: Int -> Value -> Either String Value
updatePatroniClusterInstanceCount instanceCount (Object valuesObject) =
  case KeyMap.lookup "cluster" valuesObject of
    Just (Object clusterObject) ->
      Right
        ( Object
            ( KeyMap.insert
                "cluster"
                (Object (KeyMap.insert "instances" (toJSON instanceCount) clusterObject))
                valuesObject
            )
        )
    _ -> Left "keycloak-postgres values payload does not contain a cluster object."
updatePatroniClusterInstanceCount _ _ = Left "keycloak-postgres values payload must be a JSON object."

buildChartDeploymentPlanPure
  :: Substrate
  -> FilePath
  -> ValidatedSettings
  -> String
  -> Map String String
  -> Map String String
  -> Maybe ResolvedCustomImage
  -> Maybe ResolvedCustomImage
  -> Maybe String
  -> Either String ChartDeploymentPlan
buildChartDeploymentPlanPure substrate repoRoot settings chartName chartSecrets gatewayEventKeys maybeGatewayImage maybePublicEdgeWorkloadImage maybeGatewayHostedZoneId = do
  when
    (substrate == SubstrateHomeLocal && chartStorageClassName /= "manual")
    (Left "Chart platform requires StorageClass 'manual'; dynamic provisioners are not permitted")
  let storageClassName = chartStorageClassNameForSubstrate substrate
  releaseOrder <- resolveDependencyOrder repoRoot chartName
  definitions <- mapM (resolveChart repoRoot) releaseOrder
  maybePublicFqdn <-
    if any chartDefinitionRequiresPublicHost definitions
      then Just <$> resolveRootPublicFqdn substrate settings chartName
      else Right Nothing
  releases <-
    forM definitions $ \definition -> do
      let storageBindings =
            map
              (storageBinding (resolvedManualPvHostRoot settings) chartName (chartDefinitionName definition))
              (chartStorageSpecsForRelease chartName (chartDefinitionName definition) definition)
      valuesJson <-
        renderReleaseValuesJson
          substrate
          definition
          chartName
          chartName
          settings
          chartSecrets
          gatewayEventKeys
          storageClassName
          storageBindings
          maybePublicFqdn
          maybeGatewayImage
          maybePublicEdgeWorkloadImage
          maybeGatewayHostedZoneId
      pure
        ChartReleasePlan
          { chartReleasePlanChartName = chartDefinitionName definition
          , chartReleasePlanReleaseName = chartDefinitionName definition
          , chartReleasePlanNamespace = chartName
          , chartReleasePlanChartDir = chartDefinitionChartDir definition
          , chartReleasePlanValuesJson = valuesJson
          , chartReleasePlanStorageBindings = storageBindings
          }
  pure
    ChartDeploymentPlan
      { chartDeploymentPlanRepoRoot = repoRoot
      , chartDeploymentPlanRootChart = chartName
      , chartDeploymentPlanNamespace = chartName
      , chartDeploymentPlanReleases = releases
      , chartDeploymentPlanPublicFqdn = maybePublicFqdn
      , chartDeploymentPlanExternalRequirements =
          nub (concatMap chartDefinitionExternalRequirements definitions)
      , chartDeploymentPlanSubstrate = substrate
      }

chartStorageClassNameForSubstrate :: Substrate -> String
chartStorageClassNameForSubstrate substrate =
  case substrate of
    SubstrateHomeLocal -> chartStorageClassName
    SubstrateAws -> awsChartStorageClassName

awsChartStorageClassName :: String
awsChartStorageClassName = "gp2"

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
            ( \(visitedAcc, orderedAcc) dependency ->
                visit dependency (current : visiting) visitedAcc orderedAcc
            )
            (visited, ordered)
            (chartDefinitionDependencies definition)
        pure (current : visitedAfter, orderedAfter ++ [current])

resolveRootPublicFqdn :: Substrate -> ValidatedSettings -> String -> Either String String
resolveRootPublicFqdn substrate settings _chartName = do
  let fqdn =
        case substrate of
          SubstrateHomeLocal -> publicFqdn settings
          SubstrateAws ->
            Text.unpack (Text.strip (subzone_name (aws_substrate (validatedConfig settings))))
  unless (fqdn /= "") (Left (substrateId substrate ++ " public FQDN must not be empty"))
  Right fqdn

resolveGatewayHostedZoneIdForSubstrate
  :: Substrate -> FilePath -> ValidatedSettings -> IO (Either String (Maybe String))
resolveGatewayHostedZoneIdForSubstrate substrate repoRoot settings =
  case substrate of
    SubstrateHomeLocal ->
      pure (Right (Just (Text.unpack (zone_id (route53 (validatedConfig settings))))))
    SubstrateAws -> do
      hostedZoneResult <- resolveSubstrateHostedZoneId repoRoot settings SubstrateAws
      pure (fmap (Just . Text.unpack) hostedZoneResult)

chartStorageSpecsForRelease :: String -> String -> ChartDefinition -> [ChartStorageSpec]
chartStorageSpecsForRelease rootChart _releaseName definition =
  case chartDefinitionName definition of
    "keycloak-postgres" -> patroniStorageSpecs rootChart
    _ -> chartDefinitionStorage definition

renderReleaseValuesJson
  :: Substrate
  -> ChartDefinition
  -> String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> Map String String
  -> String
  -> [ChartStorageBinding]
  -> Maybe String
  -> Maybe ResolvedCustomImage
  -> Maybe ResolvedCustomImage
  -> Maybe String
  -> Either String String
renderReleaseValuesJson substrate definition namespace rootChart settings chartSecrets gatewayEventKeys storageClassName storageBindings maybePublicFqdn maybeGatewayImage maybePublicEdgeWorkloadImage maybeGatewayHostedZoneId = do
  values <-
    case chartDefinitionName definition of
      "keycloak-postgres" ->
        case storageBindings of
          [_, _, _] ->
            valuesForKeycloakPostgres
              namespace
              rootChart
              settings
              chartSecrets
              storageClassName
              storageBindings
          _ -> Left "keycloak-postgres requires exactly three storage bindings"
      "keycloak" ->
        case maybePublicFqdn of
          Just fqdn ->
            valuesForKeycloak namespace rootChart settings chartSecrets fqdn
          Nothing -> Left "keycloak requires a public host"
      "vscode" ->
        case (maybePublicFqdn, storageBindings) of
          (Just fqdn, [binding]) ->
            valuesForVscode namespace rootChart settings chartSecrets binding fqdn
          (Nothing, _) -> Left "vscode requires a public host"
          _ -> Left "vscode requires exactly one storage binding"
      "redis" ->
        valuesForRedis namespace rootChart
      "api" ->
        case maybePublicFqdn of
          Just fqdn ->
            valuesForApi namespace rootChart settings fqdn maybePublicEdgeWorkloadImage
          Nothing -> Left "api requires a public host"
      "websocket" ->
        case maybePublicFqdn of
          Just fqdn ->
            valuesForWebsocket namespace rootChart settings chartSecrets fqdn maybePublicEdgeWorkloadImage
          Nothing -> Left "websocket requires a public host"
      "gateway" ->
        case (maybePublicFqdn, maybeGatewayHostedZoneId) of
          (Just fqdn, Just zoneId) ->
            valuesForGateway
              substrate
              namespace
              rootChart
              settings
              gatewayEventKeys
              fqdn
              maybeGatewayImage
              zoneId
          (Nothing, _) -> Left "gateway requires a public host"
          (_, Nothing) -> Left "gateway requires a Route 53 hosted zone id"
      _ -> Left ("Unsupported chart definition '" ++ chartDefinitionName definition ++ "'")
  pure (BL8.unpack (Pretty.encodePretty' prettyJsonConfig values))

valuesForKeycloak
  :: String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> String
  -> Either String Value
valuesForKeycloak namespace rootChart settings _chartSecrets sharedHostFqdn = do
  -- Sprint 3.13 chunks 8 + 11: the admin password, OAuth client secrets, and
  -- demo-user password are all materialized into k8s Secrets by the gateway
  -- daemon's pre-install Job and consumed by the chart via Helm `lookup`
  -- (see `charts/keycloak/templates/configmap.yaml` and `secret.yaml`). The
  -- chart's `values.yaml` still carries `change-me` defaults so `helm template`
  -- (no cluster) renders deterministically; on a live install the lookup
  -- supersedes the default.
  pure
    ( object
        [ "replicaCount" .= (1 :: Int)
        , "podAntiAffinity" .= podAntiAffinityValue settings
        , "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              ]
        , "image"
            .= object
              [ "repository"
                  .= ( ContainerImage.imageRegistry ContainerImage.harborKeycloakImage
                         ++ "/"
                         ++ ContainerImage.imageRepository ContainerImage.harborKeycloakImage
                     )
              , "tag" .= ContainerImage.imageTag ContainerImage.harborKeycloakImage
              ]
        , "keycloak"
            .= object
              [ "adminUser" .= ("admin" :: String)
              , "publicHost" .= sharedHostFqdn
              , "httpRelativePath" .= authPathPrefix
              , "realmName" .= keycloakRealmName
              ]
        , "gateway"
            .= object
              [ "className" .= publicEdgeGatewayClassName
              , "name" .= publicEdgeGatewayName
              , "listenerName" .= publicEdgeKeycloakListenerName
              , "httpRedirectListenerName" .= publicEdgeHttpRedirectListenerName
              , "httpRedirectRouteName" .= publicEdgeHttpRedirectRouteName
              , "apiListenerName" .= publicEdgeApiListenerName
              , "websocketListenerName" .= publicEdgeWebsocketListenerName
              , "routeName" .= publicEdgeKeycloakRouteName
              , "tlsSecretName" .= publicEdgeTlsSecretName
              , "clusterIssuer" .= chartClusterIssuer
              , "host" .= sharedHostFqdn
              , "authPathPrefix" .= authPathPrefix
              , "vscodePathPrefix" .= vscodePathPrefix
              , "apiPathPrefix" .= apiPathPrefix
              , "websocketPathPrefix" .= websocketPathPrefix
              ]
        , "oidc"
            .= object
              [ "vscodeClientId" .= keycloakVscodeClientId
              , "redirectUri" .= ("https://" ++ sharedHostFqdn ++ vscodePathPrefix ++ "/oauth2/callback")
              , "adminRedirectUris"
                  .= [ "https://" ++ sharedHostFqdn ++ harborPathPrefix ++ "/oauth2/callback"
                     , "https://" ++ sharedHostFqdn ++ minioPathPrefix ++ "/oauth2/callback"
                     ]
              , "apiClientId" .= keycloakApiClientId
              , "apiAudience" .= keycloakApiClientId
              , "apiRouteClaimName" .= publicEdgeRouteClaimName
              , "apiRouteClaimValue" .= ("api" :: String)
              , "websocketClientId" .= keycloakWebsocketClientId
              , "websocketAudience" .= keycloakWebsocketClientId
              , "websocketRouteClaimName" .= publicEdgeRouteClaimName
              , "websocketRouteClaimValue" .= ("websocket" :: String)
              , "websocketRedirectUri" .= ("https://" ++ sharedHostFqdn ++ websocketOidcPathPrefix ++ "/callback")
              , "demoUserName" .= ("demo-user" :: String)
              ]
        , "postgres"
            .= object
              [ "host" .= patroniPrimaryServiceHost namespace rootChart
              , "database" .= patroniDatabaseName
              , "username" .= patroniUsername
              , "passwordSecretName" .= patroniCredentialsSecretName rootChart
              ]
        ]
    )

valuesForKeycloakPostgres
  :: String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> String
  -> [ChartStorageBinding]
  -> Either String Value
valuesForKeycloakPostgres namespace rootChart settings _chartSecrets storageClassName storageBindings = do
  let clusterName = patroniClusterName rootChart
  when
    (length storageBindings /= 3)
    (Left "keycloak-postgres requires exactly three storage bindings")
  -- Sprint 3.13 chunk 8: the three Patroni Secrets the Crunchy operator
  -- watches (`prodbox-keycloak-pg-pguser-{keycloak,postgres}` and
  -- `prodbox-keycloak-pg-primaryuser`) are materialized by the gateway
  -- daemon's pre-install Job with `username` + master-seed-derived `password`.
  -- The chart no longer renders `00-secrets.yaml`; this function therefore
  -- no longer needs to project the passwords into Helm values.
  pure
    ( object
        [ "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              ]
        , "cluster"
            .= object
              [ "name" .= clusterName
              , "instances" .= (3 :: Int)
              , "crVersion" .= ("2.9.0" :: String)
              ]
        , "image"
            .= object
              [ "postgres"
                  .= object
                    [ "repository"
                        .= ( ContainerImage.imageRegistry ContainerImage.harborPostgresDatabaseImage
                               ++ "/"
                               ++ ContainerImage.imageRepository ContainerImage.harborPostgresDatabaseImage
                           )
                    , "tag" .= ContainerImage.imageTag ContainerImage.harborPostgresDatabaseImage
                    ]
              , "pgBackRest"
                  .= object
                    [ "repository"
                        .= ( ContainerImage.imageRegistry ContainerImage.harborPostgresPgbackrestImage
                               ++ "/"
                               ++ ContainerImage.imageRepository ContainerImage.harborPostgresPgbackrestImage
                           )
                    , "tag" .= ContainerImage.imageTag ContainerImage.harborPostgresPgbackrestImage
                    ]
              , "pgBouncer"
                  .= object
                    [ "repository"
                        .= ( ContainerImage.imageRegistry ContainerImage.harborPostgresPgbouncerImage
                               ++ "/"
                               ++ ContainerImage.imageRepository ContainerImage.harborPostgresPgbouncerImage
                           )
                    , "tag" .= ContainerImage.imageTag ContainerImage.harborPostgresPgbouncerImage
                    ]
              ]
        , "postgres"
            .= object
              [ "version" .= (17 :: Int)
              , "database" .= patroniDatabaseName
              , "username" .= patroniUsername
              ]
        , "secrets"
            .= object
              [ "application"
                  .= object
                    [ "name" .= patroniCredentialsSecretName rootChart
                    , "username" .= patroniUsername
                    ]
              , "standby"
                  .= object
                    [ "name" .= patroniStandbySecretName rootChart
                    , "username" .= ("primaryuser" :: String)
                    ]
              , "superuser"
                  .= object
                    [ "name" .= patroniSuperuserSecretName rootChart
                    , "username" .= ("postgres" :: String)
                    ]
              ]
        , "storage"
            .= object
              [ "className" .= storageClassName
              , "size" .= patroniStorageSize
              ]
        , "security"
            .= object
              [ "runAsUser" .= patroniRunAsUser
              , "runAsGroup" .= patroniRunAsGroup
              , "fsGroup" .= patroniFsGroup
              ]
        , "proxy"
            .= object
              [ "pgBouncerReplicas" .= (0 :: Int)
              ]
        , "backups"
            .= object
              [ "enabled" .= False
              ]
        , "podAntiAffinity" .= podAntiAffinityValue settings
        ]
    )

valuesForGateway
  :: Substrate
  -> String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> String
  -> Maybe ResolvedCustomImage
  -> String
  -> Either String Value
valuesForGateway substrate namespace rootChart settings _gatewayEventKeys sharedHostFqdn maybeGatewayImage zoneId = do
  -- Sprint 3.13 chunk 16: the per-node event keys are owned by the
  -- gateway daemon's startup self-bootstrap (see
  -- 'Prodbox.Gateway.Daemon.selfBootstrapOwnSecrets'); the chart's
  -- 'configmap-config.yaml' reads them via Helm `lookup` of the
  -- daemon-applied @gateway-event-keys@ Secret. The legacy
  -- 'gatewayEventKeys' parameter is vestigial and arrives empty; the
  -- prior non-empty / per-node membership preconditions are gone with
  -- it. The Helm `eventKeys` value below is left empty for the same
  -- reason — the chart no longer reads it.
  let config = validatedConfig settings
      operationalAws = aws config
      awsAccessKeyId = Text.unpack (access_key_id operationalAws)
      awsSecretAccessKey = Text.unpack (secret_access_key operationalAws)
      awsRegion = Text.unpack (region operationalAws)
      sessionTokenValue = maybe "" Text.unpack (session_token operationalAws)
  when (null awsAccessKeyId) (Left "gateway chart requires aws_access_key_id in settings")
  when (null awsSecretAccessKey) (Left "gateway chart requires aws_secret_access_key in settings")
  when (null awsRegion) (Left "gateway chart requires aws_region in settings")
  when
    (substrate == SubstrateHomeLocal && null zoneId)
    (Left "gateway chart requires route53_zone_id in settings")
  resolvedGatewayImage <-
    case maybeGatewayImage of
      Just imageInfo -> Right imageInfo
      Nothing -> Left "gateway chart requires a resolved image reference"
  let gatewayRepository = resolvedCustomImageRepository resolvedGatewayImage
      gatewayTag = resolvedCustomImageTag resolvedGatewayImage
  pure
    ( object
        [ "replicaCount" .= length gatewayNodeIds
        , "podAntiAffinity" .= podAntiAffinityValue settings
        , "podAnnotations"
            .= customImagePodAnnotationsValue (resolvedCustomImageRolloutToken resolvedGatewayImage)
        , "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              ]
        , "image"
            .= object
              [ "repository" .= gatewayRepository
              , "tag" .= gatewayTag
              , "pullPolicy" .= ("IfNotPresent" :: String)
              ]
        , "ports"
            .= object
              [ "rest" .= (8443 :: Int)
              , "events" .= (8444 :: Int)
              ]
        , "timing"
            .= object
              [ "heartbeatIntervalSeconds" .= (0.5 :: Double)
              , "reconnectIntervalSeconds" .= (0.5 :: Double)
              , "syncIntervalSeconds" .= (1.0 :: Double)
              , "heartbeatTimeoutSeconds" .= (5 :: Int)
              ]
        , "nodes" .= object ["rankedIds" .= gatewayNodeIds]
        , "dnsWriteGate" .= gatewayDnsWriteGateValue substrate zoneId sharedHostFqdn awsRegion
        , "aws"
            .= object
              [ "accessKeyId" .= awsAccessKeyId
              , "secretAccessKey" .= awsSecretAccessKey
              , "sessionToken" .= sessionTokenValue
              ]
        , "certManager"
            .= object
              [ "enabled" .= True
              , "caIssuerName" .= ("gateway-ca-issuer" :: String)
              , "caCertificateName" .= ("gateway-ca" :: String)
              , "caSecretName" .= ("gateway-ca-tls" :: String)
              , "caCommonName" .= ("gateway-mesh-ca" :: String)
              ]
        ]
    )

gatewayDnsWriteGateValue :: Substrate -> String -> String -> String -> Value
gatewayDnsWriteGateValue substrate zoneId sharedHostFqdn awsRegion =
  case substrate of
    SubstrateHomeLocal ->
      object
        [ "enabled" .= True
        , "zoneId" .= zoneId
        , "fqdn" .= sharedHostFqdn
        , "ttl" .= (60 :: Int)
        , "awsRegion" .= awsRegion
        ]
    SubstrateAws ->
      object
        [ "enabled" .= False
        , "zoneId" .= ("" :: String)
        , "fqdn" .= ("" :: String)
        , "ttl" .= (60 :: Int)
        , "awsRegion" .= awsRegion
        ]

valuesForVscode
  :: String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> ChartStorageBinding
  -> String
  -> Either String Value
valuesForVscode namespace rootChart settings _chartSecrets binding sharedHostFqdn = do
  -- Sprint 3.13 chunk 11: the vscode chart reads the OIDC `client-secret`
  -- via Helm `lookup` of the gateway-daemon-managed `keycloak-oidc-clients`
  -- Secret in the release namespace. The chart's `values.yaml` `change-me`
  -- default flows through only on `helm template` (no cluster); on a real
  -- install the lookup supersedes. Keep the browser authorization endpoint on
  -- the public issuer, but send Envoy's provider backchannel to the in-cluster
  -- Keycloak Service so EKS never depends on public-NLB hairpin behavior.
  let keycloakIssuer =
        "https://" ++ sharedHostFqdn ++ authPathPrefix ++ "/realms/" ++ keycloakRealmName
      keycloakOidcPath =
        authPathPrefix ++ "/realms/" ++ keycloakRealmName ++ "/protocol/openid-connect"
      keycloakInternalBase =
        "http://keycloak." ++ namespace ++ ".svc.cluster.local:8080"
  pure
    ( object
        [ "replicaCount" .= (1 :: Int)
        , "podAntiAffinity" .= podAntiAffinityValue settings
        , "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              ]
        , "gateway"
            .= object
              [ "className" .= publicEdgeGatewayClassName
              , "name" .= publicEdgeGatewayName
              , "listenerName" .= publicEdgeVscodeListenerName
              , "tlsSecretName" .= publicEdgeTlsSecretName
              , "clusterIssuer" .= chartClusterIssuer
              , "host" .= sharedHostFqdn
              , "pathPrefix" .= vscodePathPrefix
              ]
        , "oidc"
            .= object
              [ "clientId" .= keycloakVscodeClientId
              , "issuer" .= keycloakIssuer
              , "authorizationEndpoint" .= (keycloakIssuer ++ "/protocol/openid-connect/auth")
              , "tokenEndpoint" .= (keycloakInternalBase ++ keycloakOidcPath ++ "/token")
              , "providerBackend"
                  .= object
                    [ "serviceName" .= ("keycloak" :: String)
                    , "servicePort" .= (8080 :: Int)
                    ]
              , "redirectURL" .= ("https://" ++ sharedHostFqdn ++ vscodePathPrefix ++ "/oauth2/callback")
              , "logoutPath" .= ("/logout" :: String)
              , "securityPolicyName" .= publicEdgeVscodeSecurityPolicyName
              ]
        , "vscode"
            .= object
              [ "existingClaim" .= chartStorageBindingPersistentVolumeClaimName binding
              , "image" .= ContainerImage.renderImageRef ContainerImage.harborCodeServerImage
              , "basePath" .= vscodePathPrefix
              ]
        ]
    )

valuesForRedis :: String -> String -> Either String Value
valuesForRedis namespace rootChart =
  pure
    ( object
        [ "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              ]
        , "image"
            .= object
              [ "repository"
                  .= ( ContainerImage.imageRegistry ContainerImage.harborRedisImage
                         ++ "/"
                         ++ ContainerImage.imageRepository ContainerImage.harborRedisImage
                     )
              , "tag" .= ContainerImage.imageTag ContainerImage.harborRedisImage
              ]
        , "redis"
            .= object
              [ "port" .= (6379 :: Int)
              ]
        ]
    )

valuesForApi
  :: String
  -> String
  -> ValidatedSettings
  -> String
  -> Maybe ResolvedCustomImage
  -> Either String Value
valuesForApi namespace rootChart settings sharedHostFqdn maybePublicEdgeWorkloadImage = do
  resolvedWorkloadImage <-
    case maybePublicEdgeWorkloadImage of
      Just imageInfo -> Right imageInfo
      Nothing -> Left "api chart requires a resolved public-edge workload image reference"
  let workloadRepository = resolvedCustomImageRepository resolvedWorkloadImage
      workloadTag = resolvedCustomImageTag resolvedWorkloadImage
      keycloakIssuer =
        "https://" ++ sharedHostFqdn ++ authPathPrefix ++ "/realms/" ++ keycloakRealmName
      keycloakCertsPath =
        authPathPrefix ++ "/realms/" ++ keycloakRealmName ++ "/protocol/openid-connect/certs"
  pure
    ( object
        [ "replicaCount"
            .= (maybe 2 fromIntegral (api_replicas (deployment (validatedConfig settings))) :: Int)
        , "podAntiAffinity" .= podAntiAffinityValue settings
        , "podAnnotations"
            .= customImagePodAnnotationsValue (resolvedCustomImageRolloutToken resolvedWorkloadImage)
        , "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              ]
        , "image"
            .= object
              [ "repository" .= workloadRepository
              , "tag" .= workloadTag
              ]
        , "gateway"
            .= object
              [ "name" .= publicEdgeGatewayName
              , "namespace" .= ("vscode" :: String)
              , "listenerName" .= publicEdgeApiListenerName
              , "host" .= sharedHostFqdn
              , "pathPrefix" .= apiPathPrefix
              ]
        , "jwt"
            .= object
              [ "securityPolicyName" .= publicEdgeApiSecurityPolicyName
              , "providerName" .= ("keycloak" :: String)
              , "issuer" .= keycloakIssuer
              , "audience" .= keycloakApiClientId
              , "jwksUri" .= ("http://keycloak.vscode.svc.cluster.local:8080" ++ keycloakCertsPath)
              , "jwksBackend"
                  .= object
                    [ "namespace" .= ("vscode" :: String)
                    , "serviceName" .= ("keycloak" :: String)
                    , "servicePort" .= (8080 :: Int)
                    , "referenceGrantName" .= ("api-keycloak-jwks" :: String)
                    ]
              , "routeClaimName" .= publicEdgeRouteClaimName
              , "routeClaimValue" .= ("api" :: String)
              ]
        , "api"
            .= object
              [ "port" .= (8080 :: Int)
              ]
        ]
    )

valuesForWebsocket
  :: String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> String
  -> Maybe ResolvedCustomImage
  -> Either String Value
valuesForWebsocket namespace rootChart settings _chartSecrets sharedHostFqdn maybePublicEdgeWorkloadImage = do
  resolvedWorkloadImage <-
    case maybePublicEdgeWorkloadImage of
      Just imageInfo -> Right imageInfo
      Nothing -> Left "websocket chart requires a resolved public-edge workload image reference"
  -- Sprint 3.13 chunk 11: the websocket chart reads the OIDC `client_secret`
  -- via cross-namespace Helm `lookup` of the gateway-daemon-managed
  -- `keycloak-oidc-clients` Secret in the shared `vscode` namespace. The
  -- chart's `values.yaml` `change-me` default flows through only on `helm
  -- template` (no cluster); on a real install the lookup supersedes.
  let workloadRepository = resolvedCustomImageRepository resolvedWorkloadImage
      workloadTag = resolvedCustomImageTag resolvedWorkloadImage
      keycloakIssuer =
        "https://" ++ sharedHostFqdn ++ authPathPrefix ++ "/realms/" ++ keycloakRealmName
      keycloakOidcPath =
        authPathPrefix ++ "/realms/" ++ keycloakRealmName ++ "/protocol/openid-connect"
  pure
    ( object
        [ "replicaCount"
            .= (maybe 2 fromIntegral (websocket_replicas (deployment (validatedConfig settings))) :: Int)
        , "podAntiAffinity" .= podAntiAffinityValue settings
        , "podAnnotations"
            .= customImagePodAnnotationsValue (resolvedCustomImageRolloutToken resolvedWorkloadImage)
        , "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              ]
        , "image"
            .= object
              [ "repository" .= workloadRepository
              , "tag" .= workloadTag
              ]
        , "gateway"
            .= object
              [ "name" .= publicEdgeGatewayName
              , "namespace" .= ("vscode" :: String)
              , "listenerName" .= publicEdgeWebsocketListenerName
              , "host" .= sharedHostFqdn
              , "oidcPathPrefix" .= websocketOidcPathPrefix
              ]
        , "jwt"
            .= object
              [ "securityPolicyName" .= publicEdgeWebsocketSecurityPolicyName
              , "providerName" .= ("keycloak" :: String)
              , "issuer" .= keycloakIssuer
              , "audience" .= keycloakWebsocketClientId
              , "jwksUri" .= ("http://keycloak.vscode.svc.cluster.local:8080" ++ keycloakOidcPath ++ "/certs")
              , "jwksBackend"
                  .= object
                    [ "namespace" .= ("vscode" :: String)
                    , "serviceName" .= ("keycloak" :: String)
                    , "servicePort" .= (8080 :: Int)
                    , "referenceGrantName" .= ("websocket-keycloak-jwks" :: String)
                    ]
              , "routeClaimName" .= publicEdgeRouteClaimName
              , "routeClaimValue" .= ("websocket" :: String)
              ]
        , "oidc"
            .= object
              [ "issuer" .= keycloakIssuer
              , "tokenEndpoint"
                  .= ( "http://keycloak.vscode.svc.cluster.local:8080"
                         ++ keycloakOidcPath
                         ++ "/token"
                         :: String
                     )
              , "clientId" .= keycloakWebsocketClientId
              , "publicBaseUrl" .= ("https://" ++ sharedHostFqdn ++ websocketPathPrefix)
              ]
        , "redis"
            .= object
              [ "host" .= ("redis" :: String)
              , "port" .= (6379 :: Int)
              ]
        , "websocket"
            .= object
              [ "port" .= (8080 :: Int)
              , "path" .= ("/ws" :: String)
              ]
        ]
    )

podAntiAffinityValue :: ValidatedSettings -> Value
podAntiAffinityValue settings =
  object
    [ "enabled" .= not (dev_mode (deployment (validatedConfig settings)))
    ]

customImagePodAnnotationsValue :: Maybe String -> Value
customImagePodAnnotationsValue maybeRolloutToken =
  object
    (maybe [] (\rolloutToken -> ["prodbox.io/image-build-id" .= rolloutToken]) maybeRolloutToken)

resolveGatewayChartImageForSubstrate :: Substrate -> IO (Either String (Maybe ResolvedCustomImage))
resolveGatewayChartImageForSubstrate substrate =
  case substrate of
    SubstrateHomeLocal ->
      resolveCustomImageTag ContainerImage.harborGatewayImageRepository
    SubstrateAws ->
      resolveCustomImageFixedTag
        ContainerImage.harborGatewayImageRepository
        awsSubstrateCustomImageTag

resolvePublicEdgeWorkloadChartImageForSubstrate
  :: Substrate -> IO (Either String (Maybe ResolvedCustomImage))
resolvePublicEdgeWorkloadChartImageForSubstrate substrate =
  case substrate of
    SubstrateHomeLocal ->
      resolveCustomImageTag ContainerImage.harborPublicEdgeWorkloadImageRepository
    SubstrateAws ->
      resolveCustomImageFixedTag
        ContainerImage.harborPublicEdgeWorkloadImageRepository
        awsSubstrateCustomImageTag

awsSubstrateCustomImageTag :: String
awsSubstrateCustomImageTag = "prodbox-aws-substrate"

resolveCustomImageTag :: String -> IO (Either String (Maybe ResolvedCustomImage))
resolveCustomImageTag repository = do
  machineIdExists <- doesFileExist machineIdPath
  if not machineIdExists
    then pure (Left ("custom chart image requires machine identity file " ++ machineIdPath))
    else do
      rawMachineId <- readFile machineIdPath
      let machineId = map toLower (trimWhitespace rawMachineId)
      if length machineId /= 32 || any (not . isHexDigit) machineId
        then pure (Left ("Unexpected machine-id format in " ++ machineIdPath ++ ": " ++ show machineId))
        else do
          let imageTag = take 63 ("prodbox-" ++ machineId)
              imageRef = repository ++ ":" ++ imageTag
          maybeRolloutToken <- resolveLocalImageBuildToken imageRef
          pure
            ( Right
                ( Just
                    ResolvedCustomImage
                      { resolvedCustomImageRepository = repository
                      , resolvedCustomImageTag = imageTag
                      , resolvedCustomImageRolloutToken = maybeRolloutToken
                      }
                )
            )

resolveCustomImageFixedTag :: String -> String -> IO (Either String (Maybe ResolvedCustomImage))
resolveCustomImageFixedTag repository imageTag = do
  maybeRolloutToken <- resolveLocalImageBuildToken (repository ++ ":" ++ imageTag)
  pure
    ( Right
        ( Just
            ResolvedCustomImage
              { resolvedCustomImageRepository = repository
              , resolvedCustomImageTag = imageTag
              , resolvedCustomImageRolloutToken = maybeRolloutToken
              }
        )
    )

resolveLocalImageBuildToken :: String -> IO (Maybe String)
resolveLocalImageBuildToken imageRef = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "docker"
        , subprocessArguments = ["image", "inspect", "--format", "{{.Id}}", imageRef]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  pure $
    case result of
      Failure _ -> Nothing
      Success output ->
        case processExitCode output of
          ExitSuccess ->
            let buildToken = trimWhitespace (processStdout output)
             in if null buildToken then Nothing else Just buildToken
          ExitFailure _ -> Nothing

renderStatusRelease
  :: Map String ChartInstallSnapshot
  -> String
  -> ChartDefinition
  -> ChartReleasePlan
  -> [String]
renderStatusRelease snapshots runtimeNamespace definition release
  | chartReleasePlanReleaseName release == chartDefinitionName definition
      || chartReleasePlanReleaseName release `elem` chartDefinitionDependencies definition =
      let snapshot = Map.lookup (chartReleasePlanReleaseName release) snapshots
       in [ "RELEASE"
          , "NAME=" ++ chartReleasePlanReleaseName release
          , "CHART=" ++ chartReleasePlanChartName release
          , "STATUS=" ++ maybe "not-installed" chartInstallSnapshotStatus snapshot
          , "NAMESPACE=" ++ maybe runtimeNamespace chartInstallSnapshotNamespace snapshot
          ]
  | otherwise = []

renderDeployReport :: ChartDeploymentPlan -> String
renderDeployReport plan =
  unlines $
    [ "CHART_DEPLOYMENT"
    , "ROOT_CHART=" ++ chartDeploymentPlanRootChart plan
    , "NAMESPACE=" ++ chartDeploymentPlanNamespace plan
    ]
      ++ maybe [] (\fqdn -> ["PUBLIC_FQDN=" ++ fqdn]) (chartDeploymentPlanPublicFqdn plan)
      ++ concatMap renderRelease (chartDeploymentPlanReleases plan)
 where
  renderRelease release =
    [ "RELEASE"
    , "NAME=" ++ chartReleasePlanReleaseName release
    , "CHART=" ++ chartReleasePlanChartName release
    , "CHART_PATH=" ++ chartReleasePlanChartDir release
    ]
      ++ renderStorageReport (chartReleasePlanStorageBindings release)

renderDeleteReport :: ChartDeploymentPlan -> String
renderDeleteReport plan =
  unlines $
    [ "CHART_DELETION"
    , "ROOT_CHART=" ++ chartDeploymentPlanRootChart plan
    , "NAMESPACE=" ++ chartDeploymentPlanNamespace plan
    , "HOST_STORAGE_PRESERVED=true"
    ]
      ++ concatMap renderRelease (chartDeploymentPlanReleases plan)
 where
  renderRelease release =
    [ "RELEASE"
    , "NAME=" ++ chartReleasePlanReleaseName release
    , "CHART=" ++ chartReleasePlanChartName release
    ]
      ++ renderStorageReport (chartReleasePlanStorageBindings release)

ensureChartStorage :: ChartDeploymentPlan -> IO (Either String ())
ensureChartStorage plan = do
  let bindings = concatMap chartReleasePlanStorageBindings (chartDeploymentPlanReleases plan)
      eagerBindings =
        [ binding
        | release <- chartDeploymentPlanReleases plan
        , chartReleasePlanReleaseName release /= "keycloak-postgres"
        , binding <- chartReleasePlanStorageBindings release
        ]
  case chartDeploymentPlanSubstrate plan of
    SubstrateAws ->
      if null eagerBindings
        then
          applyManifest
            (namespaceManifest (chartDeploymentPlanNamespace plan) (chartDeploymentPlanRootChart plan))
        else
          applyManifest
            ( chartDynamicStorageManifest
                (chartDeploymentPlanNamespace plan)
                (chartDeploymentPlanRootChart plan)
                awsChartStorageClassName
                eagerBindings
            )
    SubstrateHomeLocal ->
      if null bindings
        then
          applyManifest
            (namespaceManifest (chartDeploymentPlanNamespace plan) (chartDeploymentPlanRootChart plan))
        else do
          resetResult <- resetPatroniStorageIfRequested
          case resetResult of
            Left err -> pure (Left err)
            Right () -> do
              replicaResetResult <- resetRetainedPatroniReplicaBindings
              case replicaResetResult of
                Left err -> pure (Left err)
                Right ()
                  | null eagerBindings ->
                      applyManifest
                        ( chartStorageManifest
                            (chartDeploymentPlanNamespace plan)
                            (chartDeploymentPlanRootChart plan)
                            []
                            ""
                        )
                  | otherwise -> do
                      nodeHostnameResult <- singleNodeHostname
                      case nodeHostnameResult of
                        Left err -> pure (Left err)
                        Right nodeHostname -> do
                          prepareResult <- foldM prepareStorageBinding (Right ()) eagerBindings
                          case prepareResult of
                            Left err -> pure (Left err)
                            Right () ->
                              applyManifest
                                ( chartStorageManifest
                                    (chartDeploymentPlanNamespace plan)
                                    (chartDeploymentPlanRootChart plan)
                                    eagerBindings
                                    nodeHostname
                                )
 where
  -- Sprint 3.13 chunks 12 + 13 + 14: with the host-side `.prodbox-state`
  -- chart-secret cache gone, no code path writes the `.patroni-reset-required`
  -- marker any more, so the legacy "rm -rf host paths if marker present"
  -- escape hatch can never fire. The previous silent-reset arm of
  -- 'shouldResetPatroniStorage' (chunk 14 in the spec) is therefore dead too.
  -- The replacement loud-failure check — comparing the daemon-derived
  -- @KEYCLOAK_ADMIN_PASSWORD@/Patroni @password@ against what @pg_authid@
  -- reports via a probe Postgres connection — is left for the live four-block
  -- exercise to drive, since the failure paths only make sense in the context
  -- of a real preserved-data run. Until that lands, the reset arm is simply
  -- a no-op.
  resetPatroniStorageIfRequested :: IO (Either String ())
  resetPatroniStorageIfRequested = pure (Right ())

  -- The Patroni anchor decision now derives from live k8s state alone
  -- (Sprint 3.13 chunk 13). 'discoverPatroniAnchorPersistentVolumeName'
  -- queries the Patroni primary endpoint; when the cluster is unreachable
  -- the fall-back is the ordinal-0 binding, matching the prior marker-absent
  -- behavior. The previous @.patroni-anchor-volume@ marker file is gone.
  resetRetainedPatroniReplicaBindings :: IO (Either String ())
  resetRetainedPatroniReplicaBindings = do
    let patroniBindings =
          [ binding
          | release <- chartDeploymentPlanReleases plan
          , chartReleasePlanReleaseName release == "keycloak-postgres"
          , binding <- chartReleasePlanStorageBindings release
          ]
    maybeAnchorVolumeName <-
      discoverPatroniAnchorPersistentVolumeName (chartDeploymentPlanNamespace plan)
    let preservedBinding =
          case maybeAnchorVolumeName of
            Just anchorVolumeName ->
              find ((== anchorVolumeName) . chartStorageBindingPersistentVolumeName) patroniBindings
            Nothing ->
              find ((== 0) . chartStorageBindingOrdinal) patroniBindings
        bindingsToReset =
          case preservedBinding of
            Just binding ->
              [ candidate
              | candidate <- patroniBindings
              , chartStorageBindingPersistentVolumeName candidate /= chartStorageBindingPersistentVolumeName binding
              ]
            Nothing -> []
    existingReplicaBindings <-
      filterM (doesDirectoryExist . chartStorageBindingHostPath) bindingsToReset
    foldM resetBinding (Right ()) existingReplicaBindings

  resetBinding :: Either String () -> ChartStorageBinding -> IO (Either String ())
  resetBinding (Left err) _ = pure (Left err)
  resetBinding (Right ()) binding =
    runCommandExpectSuccess "sudo rm" "sudo" ["rm", "-rf", chartStorageBindingHostPath binding]

prepareStorageBinding :: Either String () -> ChartStorageBinding -> IO (Either String ())
prepareStorageBinding (Left err) _ = pure (Left err)
prepareStorageBinding (Right ()) binding = do
  ensureResult <- ensureStorageHostDir (chartStorageBindingHostPath binding)
  case ensureResult of
    Left err -> pure (Left err)
    Right () -> do
      phaseResult <- persistentVolumePhase (chartStorageBindingPersistentVolumeName binding)
      case phaseResult of
        Left err -> pure (Left err)
        Right (Just phase)
          | phase == "Released" || phase == "Failed" ->
              deleteKubectlObject
                [ "delete"
                , "pv"
                , chartStorageBindingPersistentVolumeName binding
                , "--ignore-not-found=true"
                , "--wait=true"
                ]
        Right _ -> pure (Right ())

namespaceManifest :: String -> String -> Value
namespaceManifest namespace rootChart =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Namespace" :: String)
    , "metadata"
        .= object
          [ "name" .= namespace
          , "labels" .= object ["prodbox.io/chart-root" .= rootChart]
          ]
    ]

publicEdgeTlsRetentionNamespaceManifest :: Value
publicEdgeTlsRetentionNamespaceManifest =
  namespaceManifest retainedPublicEdgeTlsSecretNamespace "public-edge-tls-retention"

planOwnsPublicEdgeCertificate :: ChartDeploymentPlan -> Bool
planOwnsPublicEdgeCertificate plan =
  chartDeploymentPlanNamespace plan == "vscode"
    && any ((== "keycloak") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan)

preservePublicEdgeTlsSecretBeforeDelete :: ChartDeploymentPlan -> IO (Either String ())
preservePublicEdgeTlsSecretBeforeDelete plan
  | not (planOwnsPublicEdgeCertificate plan) = pure (Right ())
  | otherwise = do
      maybeSecretResult <-
        readOptionalKubernetesSecret
          (chartDeploymentPlanNamespace plan)
          publicEdgeTlsSecretName
      case maybeSecretResult of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right ())
        Right (Just secretValue) ->
          case retainedPublicEdgeTlsSecretManifest
            retainedPublicEdgeTlsSecretNamespace
            retainedPublicEdgeTlsSecretName
            secretValue of
            Left err -> pure (Left err)
            Right retainedSecret -> do
              namespaceResult <- applyManifest publicEdgeTlsRetentionNamespaceManifest
              case namespaceResult of
                Left err -> pure (Left err)
                Right () -> applyManifest retainedSecret

restorePublicEdgeTlsSecretAfterNamespaceCreate :: ChartDeploymentPlan -> IO (Either String ())
restorePublicEdgeTlsSecretAfterNamespaceCreate plan
  | not (planOwnsPublicEdgeCertificate plan) = pure (Right ())
  | otherwise = do
      targetResult <-
        readOptionalKubernetesSecret
          (chartDeploymentPlanNamespace plan)
          publicEdgeTlsSecretName
      case targetResult of
        Left err -> pure (Left err)
        Right (Just _) -> pure (Right ())
        Right Nothing -> do
          backupResult <-
            readOptionalKubernetesSecret
              retainedPublicEdgeTlsSecretNamespace
              retainedPublicEdgeTlsSecretName
          case backupResult of
            Left err -> pure (Left err)
            Right Nothing -> pure (Right ())
            Right (Just backupValue) ->
              case retainedPublicEdgeTlsSecretManifest
                (chartDeploymentPlanNamespace plan)
                publicEdgeTlsSecretName
                backupValue of
                Left err -> pure (Left err)
                Right restoredSecret -> applyManifest restoredSecret

readOptionalKubernetesSecret :: String -> String -> IO (Either String (Maybe Value))
readOptionalKubernetesSecret namespace secretName = do
  outputResult <-
    runCaptured
      ("kubectl get secret " ++ secretName)
      "kubectl"
      [ "get"
      , "secret"
      , secretName
      , "--namespace"
      , namespace
      , "--ignore-not-found=true"
      , "-o"
      , "json"
      ]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitSuccess ->
        let stdoutText = trimWhitespace (processStdout output)
         in if null stdoutText
              then Right Nothing
              else
                either
                  (Left . ("kubectl get secret returned unexpected JSON payload: " ++))
                  (Right . Just)
                  (eitherDecode (BL8.pack stdoutText))
      ExitFailure _ ->
        Left
          ( "kubectl get secret "
              ++ secretName
              ++ " failed: "
              ++ processStderr output
              ++ processStdout output
          )

retainedPublicEdgeTlsSecretManifest :: String -> String -> Value -> Either String Value
retainedPublicEdgeTlsSecretManifest targetNamespace targetName secretValue =
  parseEither parseSecret secretValue
 where
  parseSecret :: Value -> Parser Value
  parseSecret =
    withObject "Secret" $ \obj -> do
      secretType <- obj .:? "type"
      secretData <- obj .: "data"
      case secretData of
        Object _ -> pure ()
        _ -> fail "Secret.data must be an object"
      pure $
        object
          [ "apiVersion" .= ("v1" :: String)
          , "kind" .= ("Secret" :: String)
          , "metadata"
              .= object
                [ "name" .= targetName
                , "namespace" .= targetNamespace
                , "labels"
                    .= object
                      [ "prodbox.io/retained-secret" .= (publicEdgeTlsSecretName :: String)
                      ]
                ]
          , "type" .= maybe "kubernetes.io/tls" id (secretType :: Maybe String)
          , "data" .= secretData
          ]

singleNodeHostname :: IO (Either String String)
singleNodeHostname = do
  outputResult <- runCaptured "kubectl get nodes" "kubectl" ["get", "nodes", "-o", "json"]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitSuccess ->
        either
          (Left . ("kubectl get nodes returned unexpected JSON payload: " ++))
          Right
          (parseNodeHostname (processStdout output))
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
        withObject
          "node entry"
          ( \nodeObj -> do
              metadata <- nodeObj .: "metadata"
              withObject "node metadata" (.: "name") metadata
          )
          nodeValue
      _ -> fail "chart storage requires exactly one Kubernetes node"

persistentVolumePhase :: String -> IO (Either String (Maybe String))
persistentVolumePhase persistentVolumeName = do
  outputResult <-
    runCaptured "kubectl get pv" "kubectl" ["get", "pv", persistentVolumeName, "-o", "json"]
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitSuccess -> Just <$> parsePersistentVolumePhase (processStdout output)
      ExitFailure _ ->
        let detail = map toLower (processStderr output ++ processStdout output)
         in if "notfound" `isInfixOf` detail || "not found" `isInfixOf` detail
              then Right Nothing
              else
                Left
                  ( "Failed to query PersistentVolume "
                      ++ persistentVolumeName
                      ++ ": "
                      ++ processStderr output
                      ++ processStdout output
                  )

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
              else
                Left ("kubectl " ++ unwords args ++ " failed: " ++ processStderr output ++ processStdout output)

helmUpgradeInstall :: ChartReleasePlan -> IO (Either String ())
helmUpgradeInstall release =
  withTempFile (chartReleasePlanReleaseName release ++ "-values-") $ \path handle -> do
    BL8.hPutStr handle (BL8.pack (chartReleasePlanValuesJson release))
    hClose handle
    outputResult <-
      runCaptured
        "helm upgrade --install"
        "helm"
        [ "upgrade"
        , "--install"
        , "--wait"
        , "--timeout"
        , "30m0s"
        , chartReleasePlanReleaseName release
        , chartReleasePlanChartDir release
        , "--namespace"
        , chartReleasePlanNamespace release
        , "--create-namespace"
        , "--values"
        , path
        ]
    case outputResult of
      Left err -> pure (Left err)
      Right output ->
        case processExitCode output of
          ExitSuccess -> pure (Right ())
          ExitFailure _ -> do
            diagnostics <- helmUpgradeFailureDiagnostics release
            cleanupResult <-
              runCaptured
                ("helm uninstall " ++ chartReleasePlanReleaseName release)
                "helm"
                [ "uninstall"
                , chartReleasePlanReleaseName release
                , "--namespace"
                , chartReleasePlanNamespace release
                , "--wait"
                ]
            let cleanupDetail =
                  case cleanupResult of
                    Left err -> "\nFailed release cleanup diagnostic:\n" ++ err
                    Right cleanupOutput
                      | processExitCode cleanupOutput == ExitSuccess ->
                          "\nFailed release cleanup: helm uninstall completed."
                      | otherwise ->
                          "\nFailed release cleanup diagnostic:\n" ++ renderProcessOutput cleanupOutput
            pure
              ( Left
                  ( "helm upgrade --install "
                      ++ chartReleasePlanReleaseName release
                      ++ " failed: "
                      ++ renderProcessOutput output
                      ++ diagnostics
                      ++ cleanupDetail
                  )
              )

helmUpgradeFailureDiagnostics :: ChartReleasePlan -> IO String
helmUpgradeFailureDiagnostics release = do
  let namespace = chartReleasePlanNamespace release
      releaseName = chartReleasePlanReleaseName release
      selector = "app.kubernetes.io/instance=" ++ releaseName
  outputs <-
    sequence
      [ diagnosticCommand
          "helm status"
          "helm"
          ["status", releaseName, "--namespace", namespace]
      , diagnosticCommand
          "kubectl get release resources"
          "kubectl"
          [ "get"
          , "deployments,pods,svc"
          , "-n"
          , namespace
          , "-l"
          , selector
          , "-o"
          , "wide"
          ]
      , diagnosticCommand
          "kubectl describe release pods"
          "kubectl"
          ["describe", "pods", "-n", namespace, "-l", selector]
      , diagnosticCommand
          "kubectl namespace events"
          "kubectl"
          [ "get"
          , "events"
          , "-n"
          , namespace
          , "--sort-by=.lastTimestamp"
          ]
      ]
  pure ("\nRelease diagnostics before cleanup:\n" ++ concat outputs)

diagnosticCommand :: String -> FilePath -> [String] -> IO String
diagnosticCommand label subprocessPath args = do
  outputResult <- runCaptured label subprocessPath args
  pure $
    unlines
      [ "== " ++ label ++ " =="
      , case outputResult of
          Left err -> err
          Right output -> renderProcessOutput output
      ]

renderProcessOutput :: ProcessOutput -> String
renderProcessOutput output =
  case filter
    (/= "")
    [trimWhitespace (processStderr output), trimWhitespace (processStdout output)] of
    [] -> "subprocess exited without output"
    rendered -> intercalate "\n" rendered

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

-- Sprint 3.13 chunk 16: 'resolveOrGenerateStringMap', 'writeGeneratedMap',
-- 'mergeRequiredKeys', 'writeStringMap' are all gone. They were the
-- random-key-generation + JSON persistence machinery that backed the
-- @.prodbox-state/<ns>/.gateway-event-keys.json@ cache (and the prior
-- chart-secret cache before chunk 12). Both caches now flow through
-- k8s @Secret@s materialized by the gateway daemon's ensure-namespace
-- handler / startup self-bootstrap.

-- Sprint 3.13 chunk 16: 'chartStateDir', 'ensureChartStateDir', and
-- 'repairChartStateDir' are removed alongside 'chartStateRootRelative'.
-- The @.prodbox-state/charts/<ns>/@ host-side directory is no longer
-- written to by any supported path; chart secrets live in k8s @Secret@s,
-- and 'Prodbox.CheckCode.checkForbidDotProdboxState' refuses any
-- regression in @src/@ + @app/@.

ensureStorageHostDir :: FilePath -> IO (Either String ())
ensureStorageHostDir path = do
  createResult <- try (createDirectoryIfMissing True path) :: IO (Either IOException ())
  case createResult of
    Left _ -> repairStorageHostDir path
    Right () -> repairStorageHostDir path

repairStorageHostDir :: FilePath -> IO (Either String ())
repairStorageHostDir path = do
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
              chownResult <- runCommandExpectSuccess "sudo chown" "sudo" ["chown", uid ++ ":" ++ gid, path]
              case chownResult of
                Left err -> pure (Left err)
                Right () -> runCommandExpectSuccess "sudo chmod" "sudo" ["chmod", "0777", path]

runCaptured :: String -> FilePath -> [String] -> IO (Either String ProcessOutput)
runCaptured action subprocessPath args = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = subprocessPath
        , subprocessArguments = args
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case result of
    Failure err -> Left (action ++ " failed: " ++ err)
    Success output -> Right output

runCommandExpectSuccess :: String -> FilePath -> [String] -> IO (Either String ())
runCommandExpectSuccess action subprocessPath args = do
  outputResult <- runCaptured action subprocessPath args
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure _ -> Left (processStderr output ++ processStdout output)

commandStdout :: FilePath -> [String] -> IO (Either String String)
commandStdout subprocessPath args = do
  outputResult <- runCaptured (subprocessPath ++ " " ++ unwords args) subprocessPath args
  pure $ do
    output <- outputResult
    case processExitCode output of
      ExitSuccess -> Right (trimWhitespace (processStdout output))
      ExitFailure _ -> Left (processStderr output ++ processStdout output)

-- Sprint 3.13 chunk 16: 'mapLookupDefault' was only used by the now-gone
-- gatewayEventKeys value-injection path. With chart-side Helm `lookup`
-- as the source of truth, no more callers remain.

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
prettyJsonConfig = Pretty.defConfig {Pretty.confIndent = Pretty.Spaces 2}

trimWhitespace :: String -> String
trimWhitespace = Text.unpack . Text.strip . Text.pack
