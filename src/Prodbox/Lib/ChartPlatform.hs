{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Lib.ChartPlatform
  ( ChartDefinition (..)
  , ChartDeploymentPlan (..)
  , ChartInstallSnapshot (..)
  , ChartReleasePlan (..)
  , PatroniAuthObservation (..)
  , PatroniResetDecision (..)
  , PublicEdgePreserveOutcome (..)
  , buildChartDeletePlan
  , buildChartDeploymentPlan
  , buildChartDeploymentPlanForSubstrate
  , certManagerAdoptionAnnotations
  , chartReleasesToDeploy
  , classifyPublicEdgePreserve
  , deleteChartPlan
  , deployChartPlan
  , gatewayNodeIds
  , keycloakVscodeClientId
  , keycloakRealmName
  , kubernetesSecretDecodedDataField
  , patroniSeedMismatchDecision
  , renderChartList
  , renderChartStatus
  , renderPatroniResetDecision
  , renderPublicEdgePreserveOutcome
  , retainReadyPublicEdgeCertificate
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
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Base64 qualified as B64
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
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Infra.AwsEksTestStack qualified as AwsEks
import Prodbox.Infra.LongLivedPulumiBackend
  ( getLongLivedObject
  , putLongLivedObject
  , resolveLongLivedAdminS3Context
  )
import Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , ChartStorageSpec (..)
  , StaticEbsVolumeBinding
  , chartEbsPersistentVolumeManifest
  , chartEbsStorageManifest
  , chartPersistentVolumeManifest
  , chartStorageClassName
  , chartStorageManifest
  , defaultChartDataRootRelative
  , renderStorageReport
  , storageBinding
  )
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
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
  , patroniVaultMaterializerServiceAccountName
  )
import Prodbox.PublicEdge
  ( apiPathPrefix
  , authPathPrefix
  , minioPathPrefix
  , publicEdgeClusterIssuerName
  , publicEdgeTlsRetentionKey
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
  ( PollOutcome (..)
  , RetryPolicy (..)
  , pollUntilReady
  )
import Prodbox.Service
  ( AsServiceError (..)
  , HasPg (..)
  , serviceErrorMessage
  )
import Prodbox.Settings
  ( AwsCredentialsRef (..)
  , AwsSubstrateSection (..)
  , ConfigFile (..)
  , DeploymentSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , validateAndLoadSettings
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Substrate (Substrate (..), replicasForSubstrate, substrateId)
import Prodbox.Vault.Host (readHostVaultKvField, writeHostVaultKvObject)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getTemporaryDirectory
  , removeFile
  )
import System.Environment (getEnvironment)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )
import System.FilePath ((</>))
import System.IO
  ( Handle
  , hClose
  , openTempFile
  )

-- Sprint 3.19: the retired chart-secret cache and daemon-derived Secret
-- materialization paths are gone. Chart secrets are sourced from Vault KV by
-- explicit init / hook materializers; nothing in @src/@ writes to
-- @.prodbox-state/charts/@ any more.

-- The keycloak / vscode chart @Certificate@ issuer is the single ZeroSSL
-- @ClusterIssuer@ ('Prodbox.PublicEdge.publicEdgeClusterIssuerName').
-- Rebuild cycles avoid re-ordering the production certificate through the
-- S3-backed retention store, not through a separate test issuer.

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

-- | The namespace the public-edge production cert Secret lives in (the
-- canonical shared-edge root chart's namespace). Matches the namespace
-- gate in 'planOwnsPublicEdgeCertificate'.
publicEdgeTlsNamespace :: String
publicEdgeTlsNamespace = "vscode"

-- Sprint 8.7: the in-cluster @prodbox/public-edge-tls-retained@ Secret
-- store is replaced by the S3-backed long-lived retention store
-- (`publicEdgeTlsRetentionKey` in the `pulumi_state_backend` bucket), so
-- the retained production certificate survives a fresh cluster /
-- post-`rke2 delete` rebuild. The former
-- @retainedPublicEdgeTlsSecret{Name,Namespace}@ constants and the
-- @publicEdgeTlsRetentionNamespaceManifest@ are removed.

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
                  , chartStorageSpecPersistentVolumeClaimName = "data-vscode-0"
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
    "pulsar" ->
      Right
        ChartDefinition
          { chartDefinitionName = "pulsar"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "pulsar"
          , chartDefinitionDependencies = []
          , chartDefinitionStorage =
              [ ChartStorageSpec
                  { chartStorageSpecStatefulSetName = "pulsar"
                  , chartStorageSpecPersistentVolumeClaimName = "data-pulsar-0"
                  , chartStorageSpecStorageSize = "20Gi"
                  , chartStorageSpecOrdinal = 0
                  , chartStorageSpecClaimSuffix = "data"
                  }
              ]
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
          , chartDefinitionDependencies = ["pulsar"]
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
      runtimeImageResult <-
        if any (`elem` releaseOrder) ["gateway", "api", "websocket"]
          then resolveRuntimeChartImageForSubstrate substrate
          else pure (Right Nothing)
      gatewayHostedZoneIdResult <-
        if "gateway" `elem` releaseOrder
          then resolveGatewayHostedZoneIdForSubstrate substrate repoRoot settings
          else pure (Right Nothing)
      pure $ do
        maybeRuntimeImage <- runtimeImageResult
        maybeGatewayHostedZoneId <- gatewayHostedZoneIdResult
        buildChartDeploymentPlanPure
          substrate
          repoRoot
          settings
          chartName
          chartSecrets
          gatewayEventKeys
          maybeRuntimeImage
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
          -- Gateway event keys are Vault materialized by the gateway chart.
          -- No host-side resolution needed.
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

-- | Pure: the releases in @plan@ that are not in Helm's steady-state
-- @deployed@ status. @reconcile@ deploys exactly these, so a chart root whose
-- deploy was partially rolled back, failed, or interrupted in a pending state
-- converges on the next reconcile. An empty result means every release is
-- already installed and deployed — an idempotent no-op. Exposed for unit
-- testing because 'deployChartPlan' is otherwise IO-bound on @helm@.
chartReleasesToDeploy
  :: Map.Map String ChartInstallSnapshot -> ChartDeploymentPlan -> [ChartReleasePlan]
chartReleasesToDeploy snapshots plan =
  [ release
  | release <- chartDeploymentPlanReleases plan
  , releaseRequiresDeploy release
  ]
 where
  releaseRequiresDeploy release =
    case Map.lookup (chartReleasePlanReleaseName release) snapshots of
      Nothing -> True
      Just snapshot -> map toLower (chartInstallSnapshotStatus snapshot) /= "deployed"

deployChartPlan :: ChartDeploymentPlan -> IO (Either String String)
deployChartPlan plan = do
  snapshotsResult <- helmReleaseSnapshots
  case snapshotsResult of
    Left err -> pure (Left err)
    Right snapshots -> do
      case chartReleasesToDeploy snapshots plan of
        -- Every release in this chart root is already present in `helm list`:
        -- idempotent no-op. (Was: "ANY release in the plan present → skip the
        -- WHOLE plan", which could never re-deploy a single rolled-back release
        -- while its siblings remained installed — leaving a partially-rolled-back
        -- chart root unrecoverable without a full `charts delete`.)
        [] -> pure (Right (renderDeployReport plan))
        missing -> do
          -- Deploy only the releases MISSING from `helm list`, so `reconcile`
          -- converges a partially-deployed chart root. Already-present siblings
          -- are left untouched. The plan preamble (requirements / storage / TLS
          -- restore) runs over the missing-release subset.
          let planToDeploy = plan {chartDeploymentPlanReleases = missing}
          requirementResult <- validateExternalRequirements planToDeploy
          case requirementResult of
            Left err -> pure (Left err)
            Right () -> do
              ensureResult <- ensureChartStorage planToDeploy
              case ensureResult of
                Left err -> pure (Left err)
                Right () -> do
                  restoreResult <- restorePublicEdgeTlsSecretAfterNamespaceCreate planToDeploy
                  case restoreResult of
                    Left err -> pure (Left err)
                    Right () -> do
                      deployResult <- foldM deployRelease (Right ()) missing
                      pure (deployResult >> Right (renderDeployReport plan))
 where
  deployRelease :: Either String () -> ChartReleasePlan -> IO (Either String ())
  deployRelease (Left err) _ = pure (Left err)
  deployRelease (Right ()) release
    | chartReleasePlanReleaseName release == "keycloak-postgres" =
        deployPatroniRelease release
    | otherwise = do
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
              Right () -> finishStagedPatroniRelease release
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
                              Right () -> finishStagedPatroniRelease release

  -- After the staged Patroni bring-up reports ready, mirror the
  -- operator-generated pguser password into Vault so the keycloak release
  -- deployed later in this same plan reads a @KC_DB_PASSWORD@ that matches the
  -- live role (see 'syncPatroniAppPasswordToVault'). Scoped to the home
  -- substrate's staged path, mirroring the preflight reset.
  finishStagedPatroniRelease :: ChartReleasePlan -> IO (Either String ())
  finishStagedPatroniRelease release = do
    readyResult <- validateReleaseReady release
    case readyResult of
      Left err -> pure (Left err)
      Right () ->
        syncPatroniAppPasswordToVault
          (chartDeploymentPlanRepoRoot plan)
          (chartReleasePlanNamespace release)
          (chartDeploymentPlanRootChart plan)

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

-- | Readiness poll for the expected Patroni PVC set. The PVCs not yet
-- existing is a steady-state "not ready yet" reading, not a failure, so
-- this routes through 'pollUntilReady' rather than the error retrier.
waitForPerconaPatroniClaims :: String -> Int -> IO (Either String [PerconaPatroniClaim])
waitForPerconaPatroniClaims namespace expectedClaimCount =
  mapPollFailure <$> pollUntilReady perconaPatroniClaimRetryPolicy observeExpectedClaims
 where
  clusterName = patroniClusterName namespace

  observeExpectedClaims :: IO (PollOutcome [PerconaPatroniClaim])
  observeExpectedClaims = do
    claimsResult <- discoverPerconaPatroniClaims namespace
    pure $
      case claimsResult of
        Left err -> PollFailed (Text.pack err)
        Right claims
          | length claims == expectedClaimCount ->
              PollReady (sortOn perconaPatroniClaimName claims)
          | otherwise ->
              PollPending
                ( Text.pack
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
                  ++ "Run `prodbox cluster reconcile` before deploying charts that depend on PostgreSQL. "
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
                          ++ "Run `prodbox cluster reconcile` before deploying charts that depend on PostgreSQL."
                      )

waitForPatroniClusterReady :: String -> IO (Either String ())
waitForPatroniClusterReady namespace =
  waitForPatroniClusterReadyWithReplicaCount namespace 3

-- | Readiness poll for Patroni cluster convergence. A "pending" cluster
-- status is a steady-state observation, not a failure, so this routes
-- through 'pollUntilReady' rather than the error retrier.
waitForPatroniClusterReadyWithReplicaCount :: String -> Int -> IO (Either String ())
waitForPatroniClusterReadyWithReplicaCount namespace expectedReadyReplicas =
  mapPollFailure <$> pollUntilReady patroniClusterReadyRetryPolicy observeReadiness
 where
  clusterName = patroniClusterName namespace
  timeoutSeconds =
    ( retryPolicyMaxAttempts patroniClusterReadyRetryPolicy
        * retryPolicyBaseDelayMicros patroniClusterReadyRetryPolicy
    )
      `div` 1000000

  observeReadiness :: IO (PollOutcome ())
  observeReadiness = do
    readinessResult <- patroniClusterReadiness namespace expectedReadyReplicas
    pure $
      case readinessResult of
        Left err ->
          PollFailed (Text.pack ("Patroni cluster " ++ clusterName ++ " did not converge: " ++ err))
        Right PatroniClusterReady -> PollReady ()
        Right (PatroniClusterPending detail) ->
          PollPending
            ( Text.pack
                ( "Patroni cluster "
                    ++ clusterName
                    ++ " did not converge within "
                    ++ show timeoutSeconds
                    ++ " seconds. Last status: "
                    ++ detail
                    ++ "."
                )
            )

mapPollFailure :: Either Text.Text value -> Either String value
mapPollFailure result =
  case result of
    Left detail -> Left (Text.unpack detail)
    Right value -> Right value

mapPgError :: (AsServiceError errorType) => Either errorType value -> Either String value
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
    -- Sprint 8.7/8.8: the typed outcome (retained / deferred-in-flight /
    -- nothing-to-retain / store-unavailable) replaces the prior silent
    -- success-on-absent; any S3 retention has already happened inside the
    -- preserve step, and the rendered outcome is surfaced in the returned
    -- delete summary so the "nothing to retain" / "store unavailable" states
    -- are never silent (the § 3 soundness rule).
    Right preserveOutcome -> do
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
                  pure
                    ( namespaceResult
                        >> Right
                          ( renderPublicEdgePreserveOutcome preserveOutcome
                              ++ "\n"
                              ++ renderDeleteReport plan
                          )
                    )
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

-- | The retired per-namespace @.prodbox-state/charts/<ns>/.secrets.json@
-- cache is gone. Vault KV plus chart-local materializers are the structural
-- source of truth; this function returns an empty map for signature
-- compatibility while every current consumer ignores it.
resolveChartSecrets :: FilePath -> String -> IO (Either String (Map String String))
resolveChartSecrets _repoRoot _namespace = pure (Right Map.empty)

-- 'resolveGatewayEventKeys' is gone. Per-node event keys are Vault KV
-- objects materialized by the gateway chart; no host-side resolution is
-- needed.

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
-- mismatch check (Vault-backed password vs @pg_authid@ probe) lands when the live
-- preserved-data exercise drives the failure paths.
discoverPatroniAnchorPersistentVolumeName :: String -> IO (Maybe String)
discoverPatroniAnchorPersistentVolumeName namespace = do
  maybePrimaryPodName <- readOptionalPatroniPrimaryPodName namespace
  case maybePrimaryPodName >>= patroniClaimNameFromPodName of
    Nothing -> pure Nothing
    Just claimName -> readOptionalPersistentVolumeNameForClaim namespace claimName

-- | Observe whether the Vault-backed Patroni application-role password still
-- authenticates against the preserved cluster's @pg_authid@ hash. This is
-- the effectful half of the loud-failure guard; the pure policy is
-- 'patroniSeedMismatchDecision'.
--
-- Steps, all best-effort (any failure short of a definite authentication
-- rejection classifies as 'PatroniAuthUnobservable' so a fresh install or
-- a transient probe miss never blocks the deploy):
--
--   1. Read the application-role password from Vault KV through the host
--      Vault helper.
--   2. Resolve the primary Pod for the cluster. Absent ⇒ no running
--      Postgres to probe ⇒ unobservable.
--   3. Run a probe-only @psql@ connection inside the primary Pod using the
--      Vault-backed password. Exit 0 ⇒ matches; an authentication-failure
--      diagnostic ⇒ rejected; anything else ⇒ unobservable.
probePatroniAppRoleAuth :: FilePath -> String -> IO PatroniAuthObservation
probePatroniAppRoleAuth repoRoot namespace = do
  passwordResult <-
    readHostVaultKvField
      repoRoot
      "secret"
      (Text.pack (keycloakPostgresAppVaultPath namespace))
      "password"
  case passwordResult of
    Left err ->
      pure
        ( PatroniAuthUnobservable
            ("Vault read of Patroni app-role password failed: " ++ err)
        )
    Right password -> do
      maybePrimaryPodName <- readOptionalPatroniPrimaryPodName namespace
      case maybePrimaryPodName of
        Nothing ->
          pure (PatroniAuthUnobservable "no Patroni primary Pod found; nothing to probe")
        Just primaryPodName ->
          probePatroniPsqlAuth namespace primaryPodName (Text.unpack password)

-- | Sprint 3.16 (boundary probe). Run a probe-only @psql@ connection in the
-- primary Pod authenticating as the Patroni application role with the
-- supplied password, and classify the result. The password is passed via
-- @PGPASSWORD@ in the exec environment and is never written to a log or
-- argv slot (it would otherwise show in process listings).
probePatroniPsqlAuth :: String -> String -> String -> IO PatroniAuthObservation
probePatroniPsqlAuth namespace primaryPodName derivedPassword = do
  result <-
    runPg
      [ "exec"
      , primaryPodName
      , "--namespace"
      , namespace
      , "--container"
      , "database"
      , "--"
      , "env"
      , "PGPASSWORD=" ++ derivedPassword
      , "psql"
      , "--host"
      , "127.0.0.1"
      , "--username"
      , patroniUsername
      , "--dbname"
      , patroniDatabaseName
      , "--no-password"
      , "--tuples-only"
      , "--command"
      , "SELECT 1"
      ]
  pure $ case result of
    Left err ->
      PatroniAuthUnobservable
        ("psql probe subprocess failed: " ++ Text.unpack (serviceErrorMessage (toServiceError err)))
    Right output ->
      case processExitCode output of
        ExitSuccess -> PatroniAuthMatches
        ExitFailure _ ->
          let diagnostic = processStderr output ++ "\n" ++ processStdout output
           in if isPostgresAuthenticationFailure diagnostic
                then PatroniAuthRejected
                else
                  PatroniAuthUnobservable
                    ("psql probe did not yield an authentication verdict: " ++ trimWhitespace diagnostic)

-- | Sprint 3.16 (pure). Recognise a Postgres password-authentication
-- rejection in a @psql@ diagnostic blob. PostgreSQL emits
-- @"password authentication failed for user"@ (SQLSTATE @28P01@) for a
-- wrong password; @"role ... does not exist"@ (@28000@) is a different
-- failure that must NOT be read as a seed mismatch. Pure so the unit
-- suite can pin the recognition without a live Postgres.
isPostgresAuthenticationFailure :: String -> Bool
isPostgresAuthenticationFailure diagnostic =
  "password authentication failed" `isInfixOf` diagnostic
    || "28P01" `isInfixOf` diagnostic

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
  -> Maybe String
  -> Either String ChartDeploymentPlan
buildChartDeploymentPlanPure substrate repoRoot settings chartName chartSecrets gatewayEventKeys maybeRuntimeImage maybeGatewayHostedZoneId = do
  when
    (chartStorageClassName /= "manual")
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
          maybeRuntimeImage
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
    SubstrateAws -> chartStorageClassName

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
  -> Maybe String
  -> Either String String
renderReleaseValuesJson substrate definition namespace rootChart settings chartSecrets gatewayEventKeys storageClassName storageBindings maybePublicFqdn maybeRuntimeImage maybeGatewayHostedZoneId = do
  baseValues <-
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
            valuesForVscode namespace rootChart settings chartSecrets storageClassName binding fqdn
          (Nothing, _) -> Left "vscode requires a public host"
          _ -> Left "vscode requires exactly one storage binding"
      "redis" ->
        valuesForRedis namespace rootChart
      "pulsar" ->
        case storageBindings of
          [binding] -> valuesForPulsar namespace rootChart storageClassName binding
          _ -> Left "pulsar requires exactly one storage binding"
      "api" ->
        case maybePublicFqdn of
          Just fqdn ->
            valuesForApi substrate namespace rootChart settings fqdn maybeRuntimeImage
          Nothing -> Left "api requires a public host"
      "websocket" ->
        case maybePublicFqdn of
          Just fqdn ->
            valuesForWebsocket substrate namespace rootChart settings chartSecrets fqdn maybeRuntimeImage
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
              maybeRuntimeImage
              zoneId
          (Nothing, _) -> Left "gateway requires a public host"
          (_, Nothing) -> Left "gateway requires a Route 53 hosted zone id"
      _ -> Left ("Unsupported chart definition '" ++ chartDefinitionName definition ++ "'")
  values <- attachResourcePlanValues settings definition rootChart baseValues
  pure (BL8.unpack (Pretty.encodePretty' prettyJsonConfig values))

attachResourcePlanValues
  :: ValidatedSettings -> ChartDefinition -> String -> Value -> Either String Value
attachResourcePlanValues settings definition rootChart values = do
  let plan = Capacity.resource_plan (capacity (validatedConfig settings))
  resources <- chartResourcesValue plan (chartDefinitionName definition)
  guardrails <- resourceGuardrailsValue plan rootChart (chartDefinitionName definition == rootChart)
  mergeObjectValues
    values
    ( object
        [ "resources" .= resources
        , "resourceGuardrails" .= guardrails
        ]
    )

chartResourcesValue :: Capacity.ResourcePlan -> String -> Either String Value
chartResourcesValue plan chartName =
  object <$> traverse profilePair (chartResourceProfiles chartName)
 where
  profilePair (valueKey, profileId) = do
    profile <- requireResourceProfile plan profileId
    pure (Key.fromString valueKey .= resourceEnvelopeValue (Capacity.resources profile))

chartResourceProfiles :: String -> [(String, String)]
chartResourceProfiles chartName =
  case chartName of
    "keycloak-postgres" ->
      [ ("postgres", "keycloak-postgres")
      , ("replicaCertCopy", "keycloak-postgres-replica-cert-copy")
      , ("vaultSecrets", "keycloak-postgres-vault-secrets")
      , ("secretMaterializer", "keycloak-postgres-secret-materializer")
      ]
    "keycloak" ->
      [ ("keycloak", "keycloak")
      , ("vaultSecrets", "keycloak-vault-secrets")
      ]
    "vscode" ->
      [ ("vscode", "vscode")
      , ("vaultSecrets", "vscode-vault-secrets")
      , ("secretMaterializer", "vscode-secret-materializer")
      ]
    "redis" -> [("redis", "redis")]
    "pulsar" -> [("pulsar", "pulsar")]
    "api" -> [("api", "api")]
    "websocket" -> [("websocket", "websocket")]
    "gateway" -> [("gateway", "gateway")]
    other -> [(other, other)]

resourceGuardrailsValue :: Capacity.ResourcePlan -> String -> Bool -> Either String Value
resourceGuardrailsValue plan rootChart enabled = do
  namespaceQuota <- requireNamespaceQuota plan rootChart
  limitEnvelope <- namespaceLimitEnvelope plan rootChart
  pure
    ( object
        [ "enabled" .= enabled
        , "quota" .= resourceQuotaValue namespaceQuota
        , "limitRange" .= limitRangeValue limitEnvelope
        ]
    )

requireResourceProfile
  :: Capacity.ResourcePlan -> String -> Either String Capacity.WorkloadResourceProfile
requireResourceProfile plan profileId =
  case find ((== Text.pack profileId) . Capacity.profile_id) (Capacity.workload_profiles plan) of
    Just profile -> Right profile
    Nothing -> Left ("capacity.resource_plan is missing workload profile `" ++ profileId ++ "`")

requireNamespaceQuota :: Capacity.ResourcePlan -> String -> Either String Capacity.NamespaceQuota
requireNamespaceQuota plan namespace =
  case find ((== Text.pack namespace) . Capacity.namespace_name) (Capacity.namespace_quotas plan) of
    Just namespaceQuota -> Right namespaceQuota
    Nothing -> Left ("capacity.resource_plan is missing namespace quota `" ++ namespace ++ "`")

namespaceLimitEnvelope :: Capacity.ResourcePlan -> String -> Either String Capacity.ResourceEnvelope
namespaceLimitEnvelope plan namespace =
  case find ((== Text.pack namespace) . Capacity.profile_namespace) (Capacity.workload_profiles plan) of
    Just profile -> Right (Capacity.resources profile)
    Nothing -> Left ("capacity.resource_plan has no workload profile for namespace `" ++ namespace ++ "`")

resourceEnvelopeValue :: Capacity.ResourceEnvelope -> Value
resourceEnvelopeValue envelope =
  object
    [ "requests" .= resourceVectorRuntimeValue (Capacity.request envelope)
    , "limits" .= resourceVectorRuntimeValue (Capacity.limit envelope)
    ]

resourceVectorRuntimeValue :: Capacity.ResourceVector -> Value
resourceVectorRuntimeValue vector =
  object
    [ "cpu" .= cpuQuantity (Capacity.milli_cpu vector)
    , "memory" .= memoryQuantity (Capacity.memory_mib vector)
    , "ephemeral-storage" .= memoryQuantity (Capacity.ephemeral_storage_mib vector)
    ]

resourceQuotaValue :: Capacity.NamespaceQuota -> Value
resourceQuotaValue namespaceQuota =
  let vector = Capacity.quota namespaceQuota
   in object
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

limitRangeValue :: Capacity.ResourceEnvelope -> Value
limitRangeValue envelope =
  object
    [ "defaultRequest" .= resourceVectorRuntimeValue (Capacity.request envelope)
    , "default" .= resourceVectorRuntimeValue (Capacity.limit envelope)
    ]

cpuQuantity :: (Show a) => a -> String
cpuQuantity value = show value ++ "m"

memoryQuantity :: (Show a) => a -> String
memoryQuantity value = show value ++ "Mi"

mergeObjectValues :: Value -> Value -> Either String Value
mergeObjectValues base additions =
  case (base, additions) of
    (Object baseObject, Object additionsObject) ->
      Right (Object (KeyMap.union additionsObject baseObject))
    _ -> Left "chart resource-plan injection requires object values"

valuesForKeycloak
  :: String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> String
  -> Either String Value
valuesForKeycloak namespace rootChart settings _chartSecrets sharedHostFqdn = do
  -- Sprint 3.18: Keycloak's admin password, Patroni application-role
  -- password, OIDC client secrets, demo-user password, and SMTP settings are
  -- read directly from Vault KV by the Pod's Kubernetes-auth init container.
  -- The namespace controls the least-privilege Vault role and the
  -- namespace-scoped KV paths used by the transitive vscode deployment.
  let keycloakVaultRole =
        if namespace == "keycloak" then "keycloak" else namespace ++ "-keycloak"
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
        , "vault"
            .= object
              [ "address" .= ("http://vault.vault.svc.cluster.local:8200" :: String)
              , "authPath" .= ("kubernetes" :: String)
              , "role" .= keycloakVaultRole
              , "serviceAccountTokenFile" .= ("/var/run/secrets/kubernetes.io/serviceaccount/token" :: String)
              , "image"
                  .= object
                    [ "repository" .= ("hashicorp/vault" :: String)
                    , "tag" .= ("1.18.3" :: String)
                    , "pullPolicy" .= ("IfNotPresent" :: String)
                    ]
              , "paths"
                  .= object
                    [ "admin" .= keycloakAdminVaultPath namespace
                    , "db" .= keycloakPostgresAppVaultPath namespace
                    , "oidcVscode" .= (namespace ++ "/oidc/vscode")
                    , "oidcApi" .= (namespace ++ "/oidc/prodbox-api")
                    , "oidcWebsocket" .= (namespace ++ "/oidc/prodbox-websocket")
                    , "demoUser" .= (namespace ++ "/oidc/demo-user")
                    , "smtp" .= ("keycloak/smtp" :: String)
                    ]
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
              , "clusterIssuer" .= publicEdgeClusterIssuerName
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
                  .= [ "https://" ++ sharedHostFqdn ++ minioPathPrefix ++ "/oauth2/callback"
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

keycloakAdminVaultPath :: String -> String
keycloakAdminVaultPath namespace =
  if namespace == "keycloak" then "keycloak/admin" else namespace ++ "/keycloak/admin"

keycloakPostgresAppVaultPath :: String -> String
keycloakPostgresAppVaultPath namespace =
  namespace ++ "/keycloak-postgres/patroni/app"

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
  -- Sprint 3.18: the three Patroni Secrets the Percona operator watches are
  -- materialized by a pre-install Vault-auth Job. The CRD does not expose a
  -- generated-Pod serviceAccountName field, so the least-privilege Vault read
  -- belongs to that materializer instead of the operator-created Postgres Pods.
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
        , "vault"
            .= object
              [ "address" .= ("http://vault.vault.svc.cluster.local:8200" :: String)
              , "authPath" .= ("kubernetes" :: String)
              , "role" .= (namespace ++ "-keycloak-postgres-pg")
              , "serviceAccountTokenFile"
                  .= ("/var/run/secrets/kubernetes.io/serviceaccount/token" :: String)
              , "image"
                  .= object
                    [ "repository" .= ("hashicorp/vault" :: String)
                    , "tag" .= ("1.18.3" :: String)
                    , "pullPolicy" .= ("IfNotPresent" :: String)
                    ]
              , "paths"
                  .= object
                    [ "application" .= (namespace ++ "/keycloak-postgres/patroni/app")
                    , "superuser" .= (namespace ++ "/keycloak-postgres/patroni/superuser")
                    , "standby" .= (namespace ++ "/keycloak-postgres/patroni/standby")
                    ]
              ]
        , "secretMaterializer"
            .= object
              [ "serviceAccountName" .= patroniVaultMaterializerServiceAccountName namespace
              , "image"
                  .= object
                    [ "repository" .= ("127.0.0.1:30080/prodbox/curl-mirror" :: String)
                    , "tag" .= ("8.11.0" :: String)
                    , "pullPolicy" .= ("IfNotPresent" :: String)
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
valuesForGateway substrate namespace rootChart settings _gatewayEventKeys sharedHostFqdn maybeRuntimeImage zoneId = do
  -- Sprint 3.18: the per-node event keys and gateway AWS/MinIO credentials
  -- are Vault KV objects rendered into config.dhall as SecretRef.Vault
  -- references. The legacy 'gatewayEventKeys' parameter is vestigial and
  -- arrives empty; the chart no longer reads or writes a k8s Secret for these
  -- fields.
  let config = validatedConfig settings
      operationalAws = aws config
      awsRegion = Text.unpack (awsCredentialRegion operationalAws)
  when (null awsRegion) (Left "gateway chart requires aws_region in settings")
  when
    (substrate == SubstrateHomeLocal && null zoneId)
    (Left "gateway chart requires route53_zone_id in settings")
  resolvedGatewayImage <-
    case maybeRuntimeImage of
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
        , "vault"
            .= object
              [ "address" .= ("http://vault.vault.svc.cluster.local:8200" :: String)
              , "authPath" .= ("kubernetes" :: String)
              , "role" .= ("gateway-gateway" :: String)
              , "serviceAccountTokenFile"
                  .= ("/var/run/secrets/kubernetes.io/serviceaccount/token" :: String)
              , "paths"
                  .= object
                    [ "eventKeyNodeA" .= ("gateway/gateway/node-a/event-key" :: String)
                    , "eventKeyNodeB" .= ("gateway/gateway/node-b/event-key" :: String)
                    , "eventKeyNodeC" .= ("gateway/gateway/node-c/event-key" :: String)
                    , "aws" .= ("gateway/gateway/aws" :: String)
                    , "minio" .= ("gateway/gateway/minio" :: String)
                    ]
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
  -> String
  -> ChartStorageBinding
  -> String
  -> Either String Value
valuesForVscode namespace rootChart settings _chartSecrets storageClassName binding sharedHostFqdn = do
  -- The browser authorization endpoint stays on the public issuer, but Envoy's
  -- provider backchannel uses the in-cluster Keycloak Service so EKS never
  -- depends on public-NLB hairpin behavior. The Envoy `SecurityPolicy` client
  -- Secret is materialized from Vault by the vscode chart's hook Job.
  let keycloakIssuer =
        "https://" ++ sharedHostFqdn ++ authPathPrefix ++ "/realms/" ++ keycloakRealmName
      keycloakOidcPath =
        authPathPrefix ++ "/realms/" ++ keycloakRealmName ++ "/protocol/openid-connect"
      keycloakInternalBase =
        "http://keycloak." ++ namespace ++ ".svc.cluster.local:8080"
      curlImage = ContainerImage.harborCurlImage
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
              , "clusterIssuer" .= publicEdgeClusterIssuerName
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
        , "vault"
            .= object
              [ "address" .= ("http://vault.vault.svc.cluster.local:8200" :: String)
              , "authPath" .= ("kubernetes" :: String)
              , "role" .= ("vscode-oidc" :: String)
              , "serviceAccountTokenFile" .= ("/var/run/secrets/kubernetes.io/serviceaccount/token" :: String)
              , "image"
                  .= object
                    [ "repository" .= ("hashicorp/vault" :: String)
                    , "tag" .= ("1.18.3" :: String)
                    , "pullPolicy" .= ("IfNotPresent" :: String)
                    ]
              , "paths"
                  .= object
                    [ "oidcVscode" .= (namespace ++ "/oidc/vscode")
                    ]
              ]
        , "secretMaterializer"
            .= object
              [ "image"
                  .= object
                    [ "repository"
                        .= ( ContainerImage.imageRegistry curlImage
                               ++ "/"
                               ++ ContainerImage.imageRepository curlImage
                           )
                    , "tag" .= ContainerImage.imageTag curlImage
                    , "pullPolicy" .= ("IfNotPresent" :: String)
                    ]
              ]
        , "vscode"
            .= object
              [ "image" .= ContainerImage.renderImageRef ContainerImage.harborCodeServerImage
              , "basePath" .= vscodePathPrefix
              ]
        , -- Sprint 4.31: the `data` volumeClaimTemplate class + size. The
          -- StatefulSet adopts the prebound PVC the chart-storage reconciler
          -- creates at `.data/vscode/vscode/0`.
          "storage"
            .= object
              [ "className" .= storageClassName
              , "size" .= chartStorageBindingStorageSize binding
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

valuesForPulsar :: String -> String -> String -> ChartStorageBinding -> Either String Value
valuesForPulsar namespace rootChart storageClassName binding =
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
                  .= ( ContainerImage.imageRegistry ContainerImage.harborPulsarImage
                         ++ "/"
                         ++ ContainerImage.imageRepository ContainerImage.harborPulsarImage
                     )
              , "tag" .= ContainerImage.imageTag ContainerImage.harborPulsarImage
              , "pullPolicy" .= ("IfNotPresent" :: String)
              ]
        , "pulsar"
            .= object
              [ "brokerPort" .= (6650 :: Int)
              , "httpPort" .= (8080 :: Int)
              , "clusterName" .= ("prodbox" :: String)
              , "memoryOptions" .= ("-Xms512m -Xmx1024m -XX:MaxDirectMemorySize=512m" :: String)
              ]
        , "storage"
            .= object
              [ "className" .= storageClassName
              , "size" .= chartStorageBindingStorageSize binding
              ]
        ]
    )

valuesForApi
  :: Substrate
  -> String
  -> String
  -> ValidatedSettings
  -> String
  -> Maybe ResolvedCustomImage
  -> Either String Value
valuesForApi substrate namespace rootChart settings sharedHostFqdn maybeRuntimeImage = do
  resolvedWorkloadImage <-
    case maybeRuntimeImage of
      Just imageInfo -> Right imageInfo
      Nothing -> Left "api chart requires a resolved runtime image reference"
  let workloadRepository = resolvedCustomImageRepository resolvedWorkloadImage
      workloadTag = resolvedCustomImageTag resolvedWorkloadImage
      keycloakIssuer =
        "https://" ++ sharedHostFqdn ++ authPathPrefix ++ "/realms/" ++ keycloakRealmName
      keycloakCertsPath =
        authPathPrefix ++ "/realms/" ++ keycloakRealmName ++ "/protocol/openid-connect/certs"
  pure
    ( object
        [ "replicaCount"
            .= ( fromIntegral
                   (replicasForSubstrate substrate (api_scaling (deployment (validatedConfig settings))))
                   :: Int
               )
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
  :: Substrate
  -> String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> String
  -> Maybe ResolvedCustomImage
  -> Either String Value
valuesForWebsocket substrate namespace rootChart settings _chartSecrets sharedHostFqdn maybeRuntimeImage = do
  resolvedWorkloadImage <-
    case maybeRuntimeImage of
      Just imageInfo -> Right imageInfo
      Nothing -> Left "websocket chart requires a resolved runtime image reference"
  -- Sprint 3.18: the websocket chart renders a SecretRef.Vault for the OIDC
  -- client secret. The workload binary authenticates to Vault through its
  -- Kubernetes service account and reads KV directly; Helm no longer looks up
  -- or renders the secret value.
  let workloadRepository = resolvedCustomImageRepository resolvedWorkloadImage
      workloadTag = resolvedCustomImageTag resolvedWorkloadImage
      keycloakIssuer =
        "https://" ++ sharedHostFqdn ++ authPathPrefix ++ "/realms/" ++ keycloakRealmName
      keycloakOidcPath =
        authPathPrefix ++ "/realms/" ++ keycloakRealmName ++ "/protocol/openid-connect"
  pure
    ( object
        [ "replicaCount"
            .= ( fromIntegral
                   (replicasForSubstrate substrate (websocket_scaling (deployment (validatedConfig settings))))
                   :: Int
               )
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
        , "vault"
            .= object
              [ "address" .= ("http://vault.vault.svc.cluster.local:8200" :: String)
              , "authPath" .= ("kubernetes" :: String)
              , "role" .= ("websocket-oidc" :: String)
              , "serviceAccountTokenFile" .= ("/var/run/secrets/kubernetes.io/serviceaccount/token" :: String)
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
              , "clientSecretVaultRef"
                  .= object
                    [ "mount" .= ("secret" :: String)
                    , "path" .= ("vscode/oidc/prodbox-websocket" :: String)
                    , "field" .= ("client_secret" :: String)
                    ]
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

-- | Resolve the single union runtime image consumed by every in-cluster role
-- (gateway daemon + api / websocket workloads).
resolveRuntimeChartImageForSubstrate :: Substrate -> IO (Either String (Maybe ResolvedCustomImage))
resolveRuntimeChartImageForSubstrate substrate =
  case substrate of
    SubstrateHomeLocal ->
      resolveCustomImageTag ContainerImage.harborRuntimeImageRepository
    SubstrateAws ->
      resolveCustomImageFixedTag
        ContainerImage.harborRuntimeImageRepository
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

-- | The observable result of probing a preserved Patroni datadir for whether
-- the Vault-backed role password still authenticates against the @pg_authid@
-- hash the datadir carries. Kept deliberately separate from the boundary
-- probe so the loud-failure policy is unit-testable without a live Postgres.
data PatroniAuthObservation
  = -- | The probe connected with the Vault-backed password — the preserved
    -- @pg_authid@ hash matches the current Vault KV value.
    PatroniAuthMatches
  | -- | The probe reached Postgres but the Vault-backed password was
    -- rejected: the preserved @.data/@ does not match the current Vault KV
    -- value.
    PatroniAuthRejected
  | -- | The probe could not observe @pg_authid@ at all (no primary Pod
    -- yet, psql unavailable, connection refused). The 'String' carries the
    -- operator-facing reason. "Cannot observe" is never treated as
    -- "mismatch": a first install (no running Postgres) and a transient
    -- probe failure must not block the deploy with a destructive-sounding
    -- error.
    PatroniAuthUnobservable !String
  deriving (Eq, Show)

-- | Sprint 3.16 (pure decision). Whether the Patroni storage step may
-- proceed, or must fail loudly before any chart deploy mutates state.
data PatroniResetDecision
  = -- | Proceed: either the Vault-backed password authenticates, or the datadir
    -- could not be observed (so there is no proven mismatch to be loud
    -- about).
    PatroniResetProceed
  | -- | A proven seed\/@pg_authid@ mismatch. Carries the structured,
    -- operator-facing message naming the namespace\/role pair and the
    -- resolution options. Never a silent destructive reset.
    PatroniResetLoudFailure !String
  deriving (Eq, Show)

-- | Sprint 3.16 (pure decision). Map an authentication observation for a
-- @(namespace, role)@ pair to the reset decision. The only path to a loud
-- failure is a definite 'PatroniAuthRejected'; a match or an
-- un-observable probe both proceed, so a fresh install or a transient
-- probe miss never surfaces as the destructive-mismatch error. This is the
-- doctrine-prescribed replacement for the former silent @pure (Right ())@
-- no-op (@secret_derivation_doctrine.md §8@).
patroniSeedMismatchDecision
  :: String
  -- ^ Kubernetes namespace of the preserved Patroni cluster.
  -> String
  -- ^ Patroni role name whose Vault-backed password was probed.
  -> PatroniAuthObservation
  -> PatroniResetDecision
patroniSeedMismatchDecision namespace role observation =
  case observation of
    PatroniAuthMatches -> PatroniResetProceed
    PatroniAuthUnobservable _ -> PatroniResetProceed
    PatroniAuthRejected ->
      PatroniResetLoudFailure
        ( "Patroni preserved-data mismatch: the Vault-backed password for role `"
            ++ role
            ++ "` in namespace `"
            ++ namespace
            ++ "` does not authenticate against the preserved `pg_authid` hash. "
            ++ "The preserved `.data/"
            ++ namespace
            ++ "/keycloak-postgres/...` datadir was written under a different "
            ++ "Vault KV password (or an earlier secret root) while the datadir was "
            ++ "retained. prodbox refuses to silently reset preserved Postgres "
            ++ "storage. Resolve by either (a) restoring the Vault data / `.data/` "
            ++ "snapshot pair whose password matches this datadir, or (b) deliberately wiping the "
            ++ "affected `.data/"
            ++ namespace
            ++ "/keycloak-postgres/` subtree so a fresh cluster is provisioned "
            ++ "against the current Vault password."
        )

-- | Sprint 3.16. Render a 'PatroniResetDecision' to the
-- @Either String ()@ shape the storage step consumes: a proceed decision
-- is @Right ()@; a loud failure is @Left@ with the structured message.
renderPatroniResetDecision :: PatroniResetDecision -> Either String ()
renderPatroniResetDecision decision =
  case decision of
    PatroniResetProceed -> Right ()
    PatroniResetLoudFailure message -> Left message

ensureChartStorage :: ChartDeploymentPlan -> IO (Either String ())
ensureChartStorage plan = do
  let bindings = concatMap chartReleasePlanStorageBindings (chartDeploymentPlanReleases plan)
      patroniBindings =
        [ binding
        | release <- chartDeploymentPlanReleases plan
        , chartReleasePlanReleaseName release == "keycloak-postgres"
        , binding <- chartReleasePlanStorageBindings release
        ]
      eagerBindings =
        [ binding
        | release <- chartDeploymentPlanReleases plan
        , chartReleasePlanReleaseName release /= "keycloak-postgres"
        , binding <- chartReleasePlanStorageBindings release
        ]
  case chartDeploymentPlanSubstrate plan of
    SubstrateAws ->
      if null bindings
        then
          applyManifest
            (namespaceManifest (chartDeploymentPlanNamespace plan) (chartDeploymentPlanRootChart plan))
        else do
          ebsBindingsResult <- ensureAwsEbsVolumeBindings bindings
          case ebsBindingsResult of
            Left err -> pure (Left err)
            Right ebsBindings ->
              applyAwsEbsStorageManifests ebsBindings patroniBindings eagerBindings
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
                          resetPulsarResult <-
                            foldM resetPulsarStorageBindingIfNeeded (Right ()) eagerBindings
                          case resetPulsarResult of
                            Left err -> pure (Left err)
                            Right () -> do
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
  ensureAwsEbsVolumeBindings :: [ChartStorageBinding] -> IO (Either String [StaticEbsVolumeBinding])
  ensureAwsEbsVolumeBindings awsBindings = do
    snapshotMaybe <- AwsEks.fetchAwsEksTestSnapshotFromBackend (chartDeploymentPlanRepoRoot plan)
    case snapshotMaybe of
      Nothing ->
        pure
          ( Left
              "AWS retained EBS storage requires a live aws-eks-test stack snapshot with retained_ebs_availability_zone; run `prodbox aws stack eks reconcile` first."
          )
      Just snapshot -> do
        let availabilityZone = AwsEks.eksSnapshotRetainedEbsAvailabilityZone snapshot
            requiredResult =
              mapM
                (EbsVolume.ebsRequiredVolumeFromChartStorageBinding availabilityZone)
                awsBindings
        case requiredResult of
          Left err -> pure (Left err)
          Right required -> do
            environment <- getEnvironment
            EbsVolume.ensureRetainedEbsVolumes
              EbsVolume.EbsEnsureInput
                { EbsVolume.ebsEnsureEnvironment = environment
                , EbsVolume.ebsEnsureWorkingDirectory = Just (chartDeploymentPlanRepoRoot plan)
                }
              required

  applyAwsEbsStorageManifests
    :: [StaticEbsVolumeBinding] -> [ChartStorageBinding] -> [ChartStorageBinding] -> IO (Either String ())
  applyAwsEbsStorageManifests ebsBindings patroniStorageBindings eagerStorageBindings = do
    let renderedManifestsResult =
          sequence
            ( [ chartEbsPersistentVolumeManifest
                  (chartDeploymentPlanNamespace plan)
                  (chartDeploymentPlanRootChart plan)
                  patroniStorageBindings
                  ebsBindings
              | not (null patroniStorageBindings)
              ]
                ++ [ chartEbsStorageManifest
                       (chartDeploymentPlanNamespace plan)
                       (chartDeploymentPlanRootChart plan)
                       eagerStorageBindings
                       ebsBindings
                   | not (null eagerStorageBindings)
                   ]
            )
    case renderedManifestsResult of
      Left err -> pure (Left err)
      Right manifests -> foldM applyOne (Right ()) manifests

  applyOne :: Either String () -> Value -> IO (Either String ())
  applyOne (Left err) _ = pure (Left err)
  applyOne (Right ()) manifest = applyManifest manifest

  -- Sprint 3.13 chunks 12 + 13 + 14: with the host-side `.prodbox-state`
  -- chart-secret cache gone, no code path writes the `.patroni-reset-required`
  -- marker any more, so the legacy "rm -rf host paths if marker present"
  -- escape hatch can never fire. The previous silent-reset arm of
  -- 'shouldResetPatroniStorage' (chunk 14 in the spec) is therefore dead too.
  --
  -- Instead of silently resetting preserved storage, probe whether the
  -- Vault-backed Patroni app-role password still authenticates against the
  -- preserved `pg_authid` hash and
  -- FAIL LOUDLY on a proven mismatch. The pure loud-failure policy lives in
  -- 'patroniSeedMismatchDecision' (unit-tested); this arm is only the
  -- boundary probe that reads the expected password from Vault and observes
  -- `pg_authid` through a probe-only Postgres connection. The probe is
  -- best-effort: a fresh install (no primary Pod) or any
  -- transient probe failure classifies as "cannot observe" and proceeds —
  -- only a definite authentication rejection triggers the loud failure.
  resetPatroniStorageIfRequested :: IO (Either String ())
  resetPatroniStorageIfRequested = do
    -- Percona owns the pguser password (see 'syncPatroniAppPasswordToVault');
    -- mirror the live operator-generated value into Vault BEFORE probing so a
    -- cluster that is already running is measured against the password the
    -- operator actually applied — not the now-stale Vault seed. On a fresh
    -- install the operator Secret is absent and this is a no-op, leaving the
    -- probe's "no primary Pod ⇒ unobservable ⇒ proceed" path intact.
    syncResult <-
      syncPatroniAppPasswordToVault
        (chartDeploymentPlanRepoRoot plan)
        (chartDeploymentPlanNamespace plan)
        (chartDeploymentPlanRootChart plan)
    case syncResult of
      Left err -> pure (Left ("sync Patroni app password to Vault: " ++ err))
      Right () -> do
        observation <-
          probePatroniAppRoleAuth (chartDeploymentPlanRepoRoot plan) (chartDeploymentPlanNamespace plan)
        pure
          ( renderPatroniResetDecision
              (patroniSeedMismatchDecision (chartDeploymentPlanNamespace plan) patroniUsername observation)
          )

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

  resetPulsarStorageBindingIfNeeded
    :: Either String () -> ChartStorageBinding -> IO (Either String ())
  resetPulsarStorageBindingIfNeeded (Left err) _ = pure (Left err)
  resetPulsarStorageBindingIfNeeded (Right ()) binding
    | chartStorageBindingReleaseName binding /= "pulsar" = pure (Right ())
    | otherwise = do
        statefulSetResult <-
          deleteKubectlObject
            [ "delete"
            , "statefulset"
            , chartStorageBindingStatefulSetName binding
            , "--namespace"
            , chartDeploymentPlanNamespace plan
            , "--ignore-not-found=true"
            , "--wait=true"
            ]
        case statefulSetResult of
          Left err -> pure (Left err)
          Right () -> do
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
              Left err -> pure (Left err)
              Right () -> do
                pvResult <-
                  deleteKubectlObject
                    [ "delete"
                    , "pv"
                    , chartStorageBindingPersistentVolumeName binding
                    , "--ignore-not-found=true"
                    , "--wait=true"
                    ]
                case pvResult of
                  Left err -> pure (Left err)
                  Right () ->
                    runCommandExpectSuccess
                      "sudo rm"
                      "sudo"
                      ["rm", "-rf", chartStorageBindingHostPath binding]

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

planOwnsPublicEdgeCertificate :: ChartDeploymentPlan -> Bool
planOwnsPublicEdgeCertificate plan =
  chartDeploymentPlanNamespace plan == "vscode"
    && any ((== "keycloak") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan)

-- | Sprint 8.7: the cert-manager @Certificate@ resource name for the
-- public-edge listener (the chart names it after @gateway.tlsSecretName@).
publicEdgeTlsCertificateName :: String
publicEdgeTlsCertificateName = publicEdgeTlsSecretName

-- | Sprint 8.7: the typed outcome of attempting to preserve the
-- public-edge production certificate before a chart-namespace reset.
-- Replaces the prior silent @Right ()@-on-absent gap with an explicit,
-- returned classification, so an unobservable owned certificate cannot
-- collapse to "absent/clean"
-- (lifecycle_reconciliation_doctrine.md § 3 soundness).
data PublicEdgePreserveOutcome
  = -- | The plan does not own the public-edge certificate; nothing to do.
    PreserveNotOwned
  | -- | The live cert Secret was present and retained to the long-lived
    -- S3 store.
    PreservedToRetentionStore
  | -- | The live cert Secret was present but the long-lived retention
    -- store was unavailable (admin creds / bucket / FQDN); the live cert
    -- is left in place, not backed up. Non-fatal (the deploy proceeds).
    PreserveSkippedNoRetentionStore !String
  | -- | No cert Secret yet, but a @Certificate@ is mid-issuance; the next
    -- deploy restores or re-orders.
    PreserveDeferredIssuanceInFlight
  | -- | Neither a cert Secret nor a @Certificate@ exists; the next deploy
    -- triggers a fresh order.
    PreserveNothingToRetain
  deriving (Eq, Show)

-- | Pure: classify the preserve outcome from the observed live state —
-- the owned cert Secret (if any) and the public-edge @Certificate@ (if
-- any). Secret present → retain; Secret absent but a @Certificate@
-- exists → issuance in flight; neither → nothing to retain. Exported for
-- unit testing.
classifyPublicEdgePreserve :: Maybe Value -> Maybe Value -> PublicEdgePreserveOutcome
classifyPublicEdgePreserve maybeSecret maybeCertificate =
  case (maybeSecret, maybeCertificate) of
    (Just _, _) -> PreservedToRetentionStore
    (Nothing, Just _) -> PreserveDeferredIssuanceInFlight
    (Nothing, Nothing) -> PreserveNothingToRetain

-- | One-line operator-facing rendering of a preserve outcome. Exported
-- for unit testing and for surfacing through the delete summary so the
-- "nothing to retain" / "store unavailable" states are never silent.
renderPublicEdgePreserveOutcome :: PublicEdgePreserveOutcome -> String
renderPublicEdgePreserveOutcome outcome = case outcome of
  PreserveNotOwned ->
    "public-edge cert: not owned by this release; nothing to preserve."
  PreservedToRetentionStore ->
    "public-edge cert: retained to the long-lived S3 store."
  PreserveSkippedNoRetentionStore detail ->
    "public-edge cert: retention store unavailable ("
      ++ detail
      ++ "); live cert left in place, not backed up."
  PreserveDeferredIssuanceInFlight ->
    "public-edge cert: no Secret yet but a Certificate is mid-issuance; \
    \the next deploy restores or re-orders."
  PreserveNothingToRetain ->
    "public-edge cert: no Secret and no Certificate; the next deploy \
    \triggers a fresh order."

preservePublicEdgeTlsSecretBeforeDelete
  :: ChartDeploymentPlan -> IO (Either String PublicEdgePreserveOutcome)
preservePublicEdgeTlsSecretBeforeDelete plan
  | not (planOwnsPublicEdgeCertificate plan) = pure (Right PreserveNotOwned)
  | otherwise = do
      maybeSecretResult <-
        readOptionalKubernetesSecret
          (chartDeploymentPlanNamespace plan)
          publicEdgeTlsSecretName
      case maybeSecretResult of
        -- An unobservable owned certificate refuses; it never collapses
        -- to "absent/clean".
        Left err -> pure (Left err)
        Right maybeSecret -> do
          maybeCertResult <-
            readOptionalKubernetesCertificate
              (chartDeploymentPlanNamespace plan)
              publicEdgeTlsCertificateName
          case maybeCertResult of
            Left err -> pure (Left err)
            Right maybeCertificate ->
              case (classifyPublicEdgePreserve maybeSecret maybeCertificate, maybeSecret) of
                (PreservedToRetentionStore, Just secretValue) ->
                  retainPublicEdgeSecretToStore plan secretValue
                (other, _) -> pure (Right other)

-- | Sprint 8.7: write the live public-edge cert Secret into the
-- long-lived S3 retention store under the substrate-scoped key. Degrades
-- gracefully: when the retention store (admin creds / long-lived bucket)
-- or the deploy FQDN is unavailable, the live cert is left in place and a
-- non-fatal 'PreserveSkippedNoRetentionStore' is returned — the delete is
-- not failed, and the certificate still exists in-cluster.
retainPublicEdgeSecretToStore
  :: ChartDeploymentPlan -> Value -> IO (Either String PublicEdgePreserveOutcome)
retainPublicEdgeSecretToStore plan secretValue =
  case chartDeploymentPlanPublicFqdn plan of
    Nothing ->
      pure (Right (PreserveSkippedNoRetentionStore "no public FQDN resolved for the deployment"))
    Just fqdn ->
      putPublicEdgeCertToStore
        (chartDeploymentPlanRepoRoot plan)
        (chartDeploymentPlanSubstrate plan)
        fqdn
        secretValue

-- | Sprint 8.8: the shared S3 write for the public-edge production cert
-- retention store. Writes @secretValue@ (the full @kubectl get secret -o
-- json@ payload) under the substrate-scoped retention key
-- (@public-edge-tls/\<substrate\>/\<fqdn\>@). Degrades to a typed
-- 'PreserveSkippedNoRetentionStore' when the admin S3 context is unavailable;
-- only a genuine put failure is fatal ('Left').
putPublicEdgeCertToStore
  :: FilePath -> Substrate -> String -> Value -> IO (Either String PublicEdgePreserveOutcome)
putPublicEdgeCertToStore repoRoot substrate fqdn secretValue = do
  contextResult <- resolveLongLivedAdminS3Context repoRoot
  case contextResult of
    Left detail -> pure (Right (PreserveSkippedNoRetentionStore detail))
    Right (environment, section) -> do
      let key = publicEdgeTlsRetentionKey substrate (Text.pack fqdn)
      putResult <-
        withTempFile "prodbox-public-edge-tls-retain-" $ \path handle -> do
          BL.hPutStr handle (Pretty.encodePretty' prettyJsonConfig secretValue)
          hClose handle
          putLongLivedObject repoRoot environment section key path
      pure $ case putResult of
        Left err -> Left ("public-edge cert retention put failed: " ++ err)
        Right () -> Right PreservedToRetentionStore

-- | Sprint 8.8: retain the freshly-issued public-edge production cert to the
-- long-lived S3 store the moment it is confirmed ready (called from the
-- harness public-edge readiness gate). This closes the vicious cycle where a
-- cert that issued but was never captured — the prior design only retained on
-- the next @charts delete@, and flaky ZeroSSL issuance meant the cert was
-- often absent by then — forced a fresh ZeroSSL order on every rebuild. With
-- retain-on-ready the first successful issuance is captured immediately, and
-- 'restorePublicEdgeTlsSecretAfterNamespaceCreate' replays it on every
-- subsequent rebuild (no re-order). Self-contained: resolves the public FQDN
-- from config; degrades gracefully (typed outcome) when the cert Secret or
-- the retention store is unavailable.
retainReadyPublicEdgeCertificate
  :: FilePath -> Substrate -> IO (Either String PublicEdgePreserveOutcome)
retainReadyPublicEdgeCertificate repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> pure (Left err)
    Right settings ->
      case resolveRootPublicFqdn substrate settings publicEdgeTlsNamespace of
        Left detail -> pure (Right (PreserveSkippedNoRetentionStore detail))
        Right fqdn -> do
          secretResult <-
            readOptionalKubernetesSecret publicEdgeTlsNamespace publicEdgeTlsSecretName
          case secretResult of
            Left err -> pure (Left err)
            Right Nothing -> pure (Right PreserveNothingToRetain)
            Right (Just secretValue) ->
              putPublicEdgeCertToStore repoRoot substrate fqdn secretValue

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
        -- A live cert is already present; nothing to restore.
        Right (Just _) -> pure (Right ())
        Right Nothing -> restorePublicEdgeSecretFromStore plan

-- | Sprint 8.7: restore the retained public-edge cert from the long-lived
-- S3 store into the deploy namespace before cert-manager would order a
-- fresh certificate. Because the S3 store is durable across cluster
-- lifetime, this restore-before-issue works on EVERY rebuild path —
-- including a fresh cluster / post-@rke2 delete@ — not just a
-- chart-delete → redeploy. Degrades gracefully: if the store is
-- unavailable (no admin creds / bucket on this host) or holds no retained
-- cert, the deploy proceeds and cert-manager issues a fresh certificate.
restorePublicEdgeSecretFromStore :: ChartDeploymentPlan -> IO (Either String ())
restorePublicEdgeSecretFromStore plan =
  case chartDeploymentPlanPublicFqdn plan of
    Nothing -> pure (Right ())
    Just fqdn -> do
      contextResult <- resolveLongLivedAdminS3Context (chartDeploymentPlanRepoRoot plan)
      case contextResult of
        -- No retention store on this host; cert-manager issues fresh.
        Left _ -> pure (Right ())
        Right (environment, section) -> do
          let key =
                publicEdgeTlsRetentionKey (chartDeploymentPlanSubstrate plan) (Text.pack fqdn)
          fetchResult <-
            withTempFile "prodbox-public-edge-tls-restore-" $ \path handle -> do
              hClose handle
              getResult <-
                getLongLivedObject (chartDeploymentPlanRepoRoot plan) environment section key path
              case getResult of
                Left err -> pure (Left err)
                Right False -> pure (Right Nothing)
                Right True -> do
                  contents <- BL.readFile path
                  case eitherDecode contents :: Either String Value of
                    Left decodeErr ->
                      pure (Left ("retained public-edge cert decode failed: " ++ decodeErr))
                    Right value -> pure (Right (Just value))
          case fetchResult of
            Left err -> pure (Left ("public-edge cert restore get failed: " ++ err))
            -- Nothing retained; cert-manager issues fresh on this deploy.
            Right Nothing -> pure (Right ())
            Right (Just retainedValue) ->
              case retainedPublicEdgeTlsSecretManifest
                (chartDeploymentPlanNamespace plan)
                publicEdgeTlsSecretName
                retainedValue of
                Left err -> pure (Left err)
                Right restoredSecret -> applyManifest restoredSecret

-- | Read an optional cert-manager @Certificate@ resource as JSON
-- (@Nothing@ when absent). Mirrors 'readOptionalKubernetesSecret'; used
-- by the preserve classifier to detect issuance-in-flight.
readOptionalKubernetesCertificate :: String -> String -> IO (Either String (Maybe Value))
readOptionalKubernetesCertificate namespace certificateName = do
  outputResult <-
    runCaptured
      ("kubectl get certificate " ++ certificateName)
      "kubectl"
      [ "get"
      , "certificate.cert-manager.io"
      , certificateName
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
                  (Left . ("kubectl get certificate returned unexpected JSON payload: " ++))
                  (Right . Just)
                  (eitherDecode (BL8.pack stdoutText))
      ExitFailure _ ->
        Left
          ( "kubectl get certificate "
              ++ certificateName
              ++ " failed: "
              ++ processStderr output
              ++ processStdout output
          )

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

-- | Extract and base64-decode a @data@ field from a Kubernetes Secret JSON
-- payload (as returned by @kubectl get secret -o json@). Returns @Right
-- Nothing@ when the Secret has no @data@ map or the field is absent/null, so a
-- caller can treat "not present yet" as a benign no-op. Pure so the
-- Secret→Vault password sync's decode step can be unit-tested without a live
-- cluster.
kubernetesSecretDecodedDataField :: Text.Text -> Value -> Either String (Maybe String)
kubernetesSecretDecodedDataField field =
  parseEither parser
 where
  parser = withObject "Secret" $ \obj -> do
    maybeData <- obj .:? "data"
    case (maybeData :: Maybe (KeyMap.KeyMap Value)) of
      Nothing -> pure Nothing
      Just dataObj ->
        case KeyMap.lookup (Key.fromText field) dataObj of
          Nothing -> pure Nothing
          Just Null -> pure Nothing
          Just (String b64) ->
            case decodeBase64SecretField b64 of
              Left err -> fail err
              Right decoded -> pure (Just decoded)
          Just _ ->
            fail ("Secret data field `" ++ Text.unpack field ++ "` is not a string")

-- | Decode a standard (single-line) base64 Secret @data@ value to its plain
-- text. Pure; shared by 'kubernetesSecretDecodedDataField'.
decodeBase64SecretField :: Text.Text -> Either String String
decodeBase64SecretField b64 =
  case B64.decode (TextEncoding.encodeUtf8 (Text.strip b64)) of
    Left err -> Left ("base64 decode of Secret data field failed: " ++ err)
    Right bytes ->
      case TextEncoding.decodeUtf8' bytes of
        Left err -> Left ("utf8 decode of Secret data field failed: " ++ show err)
        Right text -> Right (Text.unpack text)

-- | Percona PGO v2 (crVersion 2.9.0) OWNS the @pguser@ password: the operator
-- generates its own random value, writes it into the operator-managed
-- @<cluster>-pguser-keycloak@ Secret, and computes the role's SCRAM verifier
-- from it — overwriting the password the pre-install materializer seeded from
-- Vault. The Vault-authority model therefore inverts for this one role: Vault
-- must FOLLOW the operator-generated password, not seed it. This reads the
-- operator-owned Secret's @password@ and writes it into the Vault KV object the
-- keycloak Deployment and the preserved-data preflight both read
-- (@secret/<ns>/keycloak-postgres/patroni/app@), so all three — the live
-- @pg_authid@ hash, keycloak's @KC_DB_PASSWORD@, and the preflight probe — agree.
--
-- Idempotent and best-effort: when the operator Secret is absent (fresh
-- install, cluster not yet created) it is a no-op success; the post-readiness
-- caller re-runs it once the operator has generated the password. Because the
-- chart-secret bootstrap only ever generates a Vault field that is absent
-- ('materializeMissingFields'/'fieldSatisfied'), a value synced here survives
-- every subsequent reconcile.
syncPatroniAppPasswordToVault :: FilePath -> String -> String -> IO (Either String ())
syncPatroniAppPasswordToVault repoRoot namespace rootChart = do
  secretResult <-
    readOptionalKubernetesSecret namespace (patroniCredentialsSecretName rootChart)
  case secretResult of
    Left err -> pure (Left ("read operator pguser Secret: " ++ err))
    Right Nothing -> pure (Right ())
    Right (Just secretValue) ->
      case kubernetesSecretDecodedDataField "password" secretValue of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right ())
        Right (Just password)
          | null (trimWhitespace password) -> pure (Right ())
          | otherwise ->
              writeHostVaultKvObject
                repoRoot
                "secret"
                (Text.pack (keycloakPostgresAppVaultPath namespace))
                ( Map.fromList
                    [ ("username", Text.pack patroniUsername)
                    , ("password", Text.pack password)
                    ]
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
                , -- Sprint 8.8: carry the cert-manager adoption annotations so a
                  -- restored Secret is adopted by cert-manager instead of
                  -- triggering a fresh ZeroSSL order on every rebuild.
                  "annotations" .= certManagerAdoptionAnnotations secretValue
                ]
          , "type" .= maybe "kubernetes.io/tls" id (secretType :: Maybe String)
          , "data" .= secretData
          ]

-- | Sprint 8.8: the @cert-manager.io/*@ annotations to carry from a retained
-- public-edge cert Secret onto its restored copy. cert-manager's certificate
-- trigger policies (@SecretCertificateNameAnnotationsMismatch@ /
-- @SecretIssuerAnnotationsMismatch@) re-issue a fresh certificate when the
-- target Secret's @cert-manager.io/certificate-name@ + @issuer-*@ annotations
-- are missing or mismatched, so a restored Secret that strips them is never
-- adopted — it re-orders against ZeroSSL on every rebuild. This preserves the
-- original Secret's @cert-manager.io/*@ annotations (verbatim) so the restored
-- Secret is recognized as up to date. Pure; exported for unit testing.
certManagerAdoptionAnnotations :: Value -> Value
certManagerAdoptionAnnotations secretValue =
  case secretValue of
    Object obj -> case KeyMap.lookup "metadata" obj of
      Just (Object metadata) -> case KeyMap.lookup "annotations" metadata of
        Just (Object annotations) ->
          Object
            ( KeyMap.filterWithKey
                (\key _ -> "cert-manager.io/" `Text.isPrefixOf` Key.toText key)
                annotations
            )
        _ -> object []
      _ -> object []
    _ -> object []

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

-- 'resolveOrGenerateStringMap', 'writeGeneratedMap', 'mergeRequiredKeys',
-- and 'writeStringMap' are all gone. They were the random-key-generation +
-- JSON persistence machinery that backed the retired @.prodbox-state/@
-- caches. Current secrets flow through Vault KV plus chart-local
-- materializers.

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
