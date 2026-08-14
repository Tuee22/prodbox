{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Lib.ChartPlatform
  ( ChartDefinition (..)
  , ChartDeploymentPlan (..)
  , ChartInstallSnapshot (..)
  , ChartReleasePlan (..)
  , PublicEdgePreserveOutcome (..)
  , ResolvedCustomImage (..)
  , buildChartDeletePlan
  , buildChartDeletePlanForSubstrate
  , buildChartDeploymentPlan
  , buildChartDeploymentPlanForSubstrate
  , certManagerAdoptionAnnotations
  , chartReleasesToDeploy
  , KubernetesApiEgressCoordinate (..)
  , kubernetesApiEgressChartNames
  , parseKubernetesApiEgressCoordinate
  , classifyPublicEdgePreserve
  , deleteChartPlan
  , deployChartPlan
  , deploymentConditionReportsTrue
  , gatewayNodeIdsForSubstrate
  , gatewayRestServiceName
  , gatewayRestServicePort
  , keycloakVscodeClientId
  , keycloakRealmName
  , observePatroniOperatorAvailableWith
  , operatorAvailableTarget
  , operatorGateResult
  , renderChartList
  , renderChartStatus
  , renderPublicEdgePreserveOutcome
  , retainReadyPublicEdgeCertificate
  , retainedPublicEdgeTlsSecretManifest
  , resolveChart
  , resolveChartSecrets
  , resolveRuntimeChartImageForSubstrate
  , resolveDependencyOrder
  , supportedChartNames
  , validateOperatorGatesWith
  , valuesForBootstrapBroker
  , controlPlaneRoleChartNames
  , valuesForLifecycleAuthority
  , valuesForProviderWorker
  , valuesForAuthorityBackup
  , valuesForTlsRetention
  , valuesForTargetSecretAgent
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
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isDigit, isHexDigit, isSpace, toLower)
import Data.List
  ( dropWhileEnd
  , find
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
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.ChartStatics qualified as BrokerChartStatics
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.Placement qualified as Placement
import Prodbox.Capacity.Render qualified as CapacityRender
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Config.Basics
  ( ParentRef
  , basicsClusterId
  , basicsParentRef
  , parentRefAuthorityEndpoint
  , parentRefClusterId
  )
import Prodbox.Config.ComponentGraph
  ( ComponentId (..)
  , ComponentNode
  , ReadinessProbe (ProbeOperatorAvailable)
  , chartComponentDeployOrder
  , chartNameForComponent
  , componentIdForChartName
  , componentIdText
  , defaultComponentGraph
  , directChartDependencies
  , operatorAvailableGates
  , renderComponentGraphError
  , validateComponentGraph
  )
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyName
  , controlPlaneSigningKeyRefFor
  , localServiceCaller
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.CallerPrincipal (callerPrincipalCode)
import Prodbox.ControlPlane.DedicatedAdapterStore (awsS3EndpointForRegion)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  , withSelectedTargetSecretAgentAuthenticatedTransport
  , withTargetSecretAgentAuthenticatedTransport
  , withTlsRetentionAuthenticatedTransport
  )
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import Prodbox.ControlPlane.Route
  ( controlPlaneRoutePath
  , routesForRole
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( mkTargetAgentRolloutIdentity
  , targetAgentIdentityText
  , targetAgentRolloutDigest
  )
import Prodbox.ControlPlane.TlsRetentionAuthorityClient
  ( mkTlsRetentionAuthorityClient
  )
import Prodbox.ControlPlane.TlsRetentionClient
  ( tlsRetentionClientWithTransport
  )
import Prodbox.ControlPlane.TlsRetentionWorkflow
  ( TlsRetentionWorkflow (..)
  , TlsRetentionWorkflowError
  , TlsWorkflowRestoreOutcome (..)
  , TlsWorkflowRetainOutcome (..)
  , restorePublicEdgeTlsWorkflow
  , retainPublicEdgeTlsWorkflow
  )
import Prodbox.ControlPlane.TlsTargetAgentClient
  ( tlsTargetAgentClientWithTransport
  )
import Prodbox.Gateway.ChartStatics qualified as ChartStatics
import Prodbox.Gateway.Emitter.Persistence qualified as EmitterPersistence
import Prodbox.Gateway.Probe qualified as GatewayProbe
import Prodbox.Infra.AwsEksTestStack qualified as AwsEks
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
  , workloadStorageSize
  )
import Prodbox.Lifecycle.Authority.ChartStatics qualified as AuthorityStatics
import Prodbox.Lifecycle.Authority.TlsRetention
  ( KeyRotationApproval (KeyRotationNotApproved)
  )
import Prodbox.Lifecycle.AuthorityBackup.ChartStatics qualified as AuthorityBackupStatics
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.HelmRelease qualified as HelmRelease
import Prodbox.Lifecycle.ProviderWorker.ChartStatics qualified as ProviderWorkerStatics
import Prodbox.Lifecycle.ReadinessObservation
  ( ComponentReadinessTarget (OperatorAvailableTarget)
  , ReadinessObservation (..)
  , ReadinessProbeResult (..)
  , observeComponentReadiness
  )
import Prodbox.Lifecycle.TargetSecretAgent.ChartStatics qualified as TargetSecretAgentStatics
import Prodbox.Lifecycle.TlsRetention.ChartStatics qualified as TlsRetentionStatics
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
  , requireSubstrateCertScopeSet
  , requireSubstratePublicFqdn
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
  , patroniClusterReadyRetryPolicy
  , perconaPatroniClaimRetryPolicy
  , pollUntilReady
  , retryPolicyBaseDelayMicros
  , retryPolicyMaxAttempts
  )
import Prodbox.Runtime.Role (RuntimeRole (..))
import Prodbox.Service
  ( AsServiceError (..)
  , HasPg (..)
  , serviceErrorMessage
  )
import Prodbox.Settings
  ( ConfigFile (..)
  , DeploymentSection (..)
  , ValidatedCoordinates (..)
  , ValidatedSettings (..)
  , validateAndLoadSettings
  , validatedResourcePlan
  )
import Prodbox.Settings.Coordinate (awsRegionText, s3BucketNameText)
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Substrate (Substrate (..), replicasForSubstrate, substrateId)
import Prodbox.Tls.CertScope (CertScopeSet, certScopeSetDnsNames, renderCertScopeSet)
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

-- | The gateway emitter node identities, per substrate. Each id renders one
-- stable @gateway-\<nodeId>@ StatefulSet with its own registered retained
-- emitter journal (Sprint 2.32 / 3.26 Increment E).
--
-- Sprint 3.26 reduces the HOME substrate from three emitter identities to two.
-- The home cluster is a single physical node whose allocatable budget was
-- already fully committed (6450m of 6500m); dropping one 750m Guaranteed-QoS
-- gateway StatefulSet frees the 750m CPU / 512 MiB that funds the physically
-- separated control-plane workloads (Lifecycle Authority, Authority Backup /
-- TLS Retention Adapters, fenced Provider Worker, Target Secret Agent) on the
-- maxed single-node budget (operator-approved). The AWS substrate keeps three
-- identities across its EKS nodes with their own retained-EBS journals, so its
-- gateway resilience and its Sprint 7.28 static retained EBS provisioning are
-- unchanged.
gatewayNodeIdsForSubstrate :: Substrate -> [String]
gatewayNodeIdsForSubstrate SubstrateHomeLocal = ["node-a", "node-b"]
gatewayNodeIdsForSubstrate SubstrateAws = ["node-a", "node-b", "node-c"]

gatewayRestServiceName :: String
gatewayRestServiceName = "gateway"

-- | Sprint 2.34: a projection of the one compiled 'ChartStatics.gatewayChartStatics'
-- REST port, so this exported constant and the deployed values / generated
-- @values.yaml@ section share a single source of truth.
gatewayRestServicePort :: Int
gatewayRestServicePort = ChartStatics.gatewayStaticRestPort ChartStatics.gatewayChartStatics

machineIdPath :: FilePath
machineIdPath = "/etc/machine-id"

-- | Sprint 3.23: a chart's dependency edges and its operator-platform
-- requirement are no longer carried here — both are sourced from the Tier-0
-- component dependency/readiness graph ("Prodbox.Config.ComponentGraph"). This
-- record now describes only the chart's on-disk identity, storage, and
-- public-host requirement.
data ChartDefinition = ChartDefinition
  { chartDefinitionName :: String
  , chartDefinitionChartDir :: FilePath
  , chartDefinitionStorage :: [ChartStorageSpec]
  , chartDefinitionRequiresPublicHost :: Bool
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
  , chartDeploymentPlanCertScopeSet :: Maybe CertScopeSet
  -- ^ Sprint 2.35: the exact canonical certificate scope compiled from the
  -- selected substrate's served host. Retention consumes this typed value; it
  -- never reconstructs a key from an independently supplied hostname.
  , chartDeploymentPlanOperatorGates :: [ComponentId]
  -- ^ Sprint 3.23: the operator components (readiness 'ProbeOperatorAvailable')
  -- this plan's charts depend on, projected from the component graph. Each is
  -- gated on the operator Deployment reporting @Available@ before deploy —
  -- replacing the retired @ChartRequiresPatroniPlatform@ literal.
  , chartDeploymentPlanSubstrate :: Substrate
  }
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

-- | Sprint 3.26: the five standing control-plane role charts. They are internal
-- (deliberately NOT in 'supportedChartNames', so off the public
-- @prodbox charts ...@ surface) but are resolvable/renderable by the chart
-- platform and run the union runtime image, selected by their container args.
controlPlaneRoleChartNames :: [String]
controlPlaneRoleChartNames =
  [ "lifecycle-authority"
  , "provider-worker"
  , "authority-backup"
  , "tls-retention"
  , "target-secret-agent"
  ]

resolveChart :: FilePath -> String -> Either String ChartDefinition
resolveChart repoRoot chartName =
  case chartName of
    "keycloak-postgres" ->
      Right
        ChartDefinition
          { chartDefinitionName = "keycloak-postgres"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "keycloak-postgres"
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = False
          }
    "keycloak" ->
      Right
        ChartDefinition
          { chartDefinitionName = "keycloak"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "keycloak"
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = True
          }
    "vscode" ->
      Right
        ChartDefinition
          { chartDefinitionName = "vscode"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "vscode"
          , chartDefinitionStorage =
              [ ChartStorageSpec
                  { chartStorageSpecStatefulSetName = "vscode"
                  , chartStorageSpecPersistentVolumeClaimName = "data-vscode-0"
                  , chartStorageSpecWorkloadProfileId = "vscode"
                  , chartStorageSpecOrdinal = 0
                  , chartStorageSpecClaimSuffix = "data"
                  }
              ]
          , chartDefinitionRequiresPublicHost = True
          }
    "redis" ->
      Right
        ChartDefinition
          { chartDefinitionName = "redis"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "redis"
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = False
          }
    "pulsar" ->
      Right
        ChartDefinition
          { chartDefinitionName = "pulsar"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "pulsar"
          , chartDefinitionStorage =
              [ ChartStorageSpec
                  { chartStorageSpecStatefulSetName = "pulsar"
                  , chartStorageSpecPersistentVolumeClaimName = "data-pulsar-0"
                  , chartStorageSpecWorkloadProfileId = "pulsar"
                  , chartStorageSpecOrdinal = 0
                  , chartStorageSpecClaimSuffix = "data"
                  }
              ]
          , chartDefinitionRequiresPublicHost = False
          }
    "api" ->
      Right
        ChartDefinition
          { chartDefinitionName = "api"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "api"
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = True
          }
    "websocket" ->
      Right
        ChartDefinition
          { chartDefinitionName = "websocket"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "websocket"
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = True
          }
    "gateway" ->
      Right
        ChartDefinition
          { chartDefinitionName = "gateway"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "gateway"
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = True
          }
    "bootstrap-broker" ->
      -- Sprint 3.26: the physically separate pre-Vault Bootstrap Broker. It is an
      -- internal control-plane chart (like `redis`), resolvable and renderable but
      -- deliberately absent from `supportedChartNames`, so it is not exposed on
      -- the public `prodbox charts ...` surface. It owns no PVC and requires no
      -- public host.
      Right
        ChartDefinition
          { chartDefinitionName = "bootstrap-broker"
          , chartDefinitionChartDir = repoRoot </> "charts" </> "bootstrap-broker"
          , chartDefinitionStorage = []
          , chartDefinitionRequiresPublicHost = False
          }
    _
      | chartName `elem` controlPlaneRoleChartNames ->
          -- The five standing control-plane role charts are internal (absent
          -- from `supportedChartNames`, so off the public `prodbox charts`
          -- surface) and require no public host. The Lifecycle Authority's
          -- retained journal is pre-provisioned through ChartPlatform; the four
          -- stateless roles have no storage binding.
          Right
            ChartDefinition
              { chartDefinitionName = chartName
              , chartDefinitionChartDir = repoRoot </> "charts" </> chartName
              , chartDefinitionStorage = controlPlaneChartStorage chartName
              , chartDefinitionRequiresPublicHost = False
              }
    _ ->
      Left
        ( "Unsupported chart '"
            ++ chartName
            ++ "'. Supported charts: "
            ++ intercalate ", " supportedChartNames
        )

-- | Standing-role storage is normally empty. The retained home Lifecycle
-- Authority is the exception: its StatefulSet journal claim must be
-- pre-provisioned through the same typed ChartPlatform storage path as every
-- other repo-owned manual-PV workload. Keeping the exact generated PVC name in
-- the chart definition makes `helm --wait` observe a bindable claim rather than
-- timing out on an unowned volumeClaimTemplate.
controlPlaneChartStorage :: String -> [ChartStorageSpec]
controlPlaneChartStorage chartName =
  case chartName of
    "lifecycle-authority" ->
      [ ChartStorageSpec
          { chartStorageSpecStatefulSetName = "lifecycle-authority"
          , chartStorageSpecPersistentVolumeClaimName =
              "authority-journal-lifecycle-authority-0"
          , chartStorageSpecWorkloadProfileId = "lifecycle-authority"
          , chartStorageSpecOrdinal = 0
          , chartStorageSpecClaimSuffix = "authority-journal"
          }
      ]
    _ -> []

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
  let dependencyOrderResult =
        resolveDependencyOrder (components (validatedConfig settings)) repoRoot chartName
  case dependencyOrderResult of
    Left err -> pure (Left err)
    Right releaseOrder -> do
      runtimeImageResult <-
        -- Sprint 3.26: the Bootstrap Broker runs the union runtime image, so the
        -- plan builder must resolve it when the broker is in the release order.
        if any
          (`elem` releaseOrder)
          (["gateway", "api", "websocket", "bootstrap-broker"] ++ controlPlaneRoleChartNames)
          then resolveRuntimeChartImageForSubstrate substrate
          else pure (Right Nothing)
      gatewayHostedZoneIdResult <-
        if "gateway" `elem` releaseOrder
          then resolveGatewayHostedZoneIdForSubstrate substrate repoRoot settings
          else pure (Right Nothing)
      gatewayTier0DhallResult <-
        if "gateway" `elem` releaseOrder
          then fmap (fmap Just) (resolveGatewayTier0DhallForSubstrate substrate repoRoot)
          else pure (Right Nothing)
      controlPlaneClusterIdResult <-
        if "gateway" `elem` releaseOrder
          || "bootstrap-broker" `elem` releaseOrder
          || any (`elem` releaseOrder) controlPlaneRoleChartNames
          then fmap (fmap Just) (resolveClusterIdentityForSubstrate substrate repoRoot)
          else pure (Right Nothing)
      controlPlaneParentRefResult <-
        if "bootstrap-broker" `elem` releaseOrder
          then resolveParentRegistrationForSubstrate substrate repoRoot
          else pure (Right Nothing)
      -- Sprint 3.34: the sixth observation, of the same shape as the five
      -- above. Only the two charts whose NetworkPolicy carries the Kubernetes
      -- API egress coordinate need it.
      apiEgressCoordinateResult <-
        if any (`elem` releaseOrder) kubernetesApiEgressChartNames
          then fmap (fmap Just) readKubernetesApiEgressCoordinate
          else pure (Right Nothing)
      pure $ do
        maybeRuntimeImage <- runtimeImageResult
        maybeGatewayHostedZoneId <- gatewayHostedZoneIdResult
        maybeGatewayTier0Dhall <- gatewayTier0DhallResult
        maybeControlPlaneClusterId <- controlPlaneClusterIdResult
        maybeControlPlaneParentRef <- controlPlaneParentRefResult
        maybeApiEgressCoordinate <- apiEgressCoordinateResult
        buildChartDeploymentPlanPure
          substrate
          repoRoot
          settings
          chartName
          chartSecrets
          gatewayEventKeys
          maybeRuntimeImage
          maybeGatewayHostedZoneId
          maybeGatewayTier0Dhall
          maybeControlPlaneClusterId
          maybeControlPlaneParentRef
          maybeApiEgressCoordinate

buildChartDeletePlan
  :: FilePath
  -> Maybe ValidatedSettings
  -> String
  -> Either String ChartDeploymentPlan
buildChartDeletePlan = buildChartDeletePlanForSubstrate SubstrateHomeLocal

buildChartDeletePlanForSubstrate
  :: Substrate
  -> FilePath
  -> Maybe ValidatedSettings
  -> String
  -> Either String ChartDeploymentPlan
buildChartDeletePlanForSubstrate substrate repoRoot maybeSettings chartName = do
  let graph = maybe defaultComponentGraph (components . validatedConfig) maybeSettings
  releaseOrder <- resolveDependencyOrder graph repoRoot chartName
  let manualPvRoot = maybe (repoRoot </> defaultChartDataRootRelative) resolvedManualPvHostRoot maybeSettings
      reversedOrder = reverse releaseOrder
      ownsPublicEdgeCertificate = chartName == publicEdgeTlsNamespace && "keycloak" `elem` releaseOrder
  (maybePublicFqdn, maybeCertScopeSet) <-
    case (ownsPublicEdgeCertificate, maybeSettings) of
      (True, Just settings) -> do
        fqdn <- resolveRootPublicFqdn substrate settings chartName
        scopeSet <- requireSubstrateCertScopeSet settings substrate
        Right (Just fqdn, Just scopeSet)
      _ -> Right (Nothing, Nothing)
  let resourcePlan = maybe Capacity.defaultResourcePlan validatedResourcePlan maybeSettings
  releases <-
    forM reversedOrder $ \releaseName -> do
      definition <- resolveChart repoRoot releaseName
      storageBindings <-
        mapM
          (storageBinding resourcePlan manualPvRoot chartName releaseName)
          (chartStorageSpecsForRelease chartName releaseName definition)
      pure
        ChartReleasePlan
          { chartReleasePlanChartName = releaseName
          , chartReleasePlanReleaseName = releaseName
          , chartReleasePlanNamespace = chartName
          , chartReleasePlanChartDir = chartDefinitionChartDir definition
          , chartReleasePlanValuesJson = "{}"
          , chartReleasePlanStorageBindings = storageBindings
          }
  pure
    ChartDeploymentPlan
      { chartDeploymentPlanRepoRoot = repoRoot
      , chartDeploymentPlanRootChart = chartName
      , chartDeploymentPlanNamespace = chartName
      , chartDeploymentPlanReleases = releases
      , chartDeploymentPlanPublicFqdn = maybePublicFqdn
      , chartDeploymentPlanCertScopeSet = maybeCertScopeSet
      , chartDeploymentPlanOperatorGates = []
      , chartDeploymentPlanSubstrate = substrate
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
            directDeps = chartDirectDependencyNames (components (validatedConfig settings)) chartName
            dependencies =
              if null directDeps
                then "<none>"
                else intercalate "," directDeps
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
            let directDeps = chartDirectDependencyNames (components (validatedConfig settings)) chartName
                dependencies =
                  if null directDeps
                    then "<none>"
                    else intercalate "," directDeps
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
                    (renderStatusRelease snapshots runtimeNamespace chartName directDeps)
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
          requirementResult <- validateOperatorGates planToDeploy
          case requirementResult of
            Left err -> pure (Left err)
            Right () -> do
              ensureResult <- ensureChartStorage planToDeploy
              case ensureResult of
                Left err -> pure (Left err)
                Right () -> do
                  accessResult <- ensurePublicEdgeTlsAgentAccess planToDeploy
                  case accessResult of
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

  -- Keycloak consumes the PGO-adopted pguser Secret directly through its exact
  -- @postgres.passwordSecretName@ projection. No host or Target Agent payload
  -- read/write is needed after Patroni becomes ready. PGO controls that Secret
  -- object; Vault owns the password value the chart hook materialized into it
  -- (secret_derivation_doctrine.md 5.1).
  finishStagedPatroniRelease :: ChartReleasePlan -> IO (Either String ())
  finishStagedPatroniRelease = validateReleaseReady

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

-- | Sprint 3.23 / 3.24: gate the plan behind each operator dependency reporting
-- @Available@. The gate set is projected from the component graph
-- ('chartDeploymentPlanOperatorGates') — a chart's graph edge onto an
-- operator component is what requires it, replacing the retired
-- @ChartRequiresPatroniPlatform@ literal. Every projected gate must resolve to
-- a concrete readiness target; an unbound target fails closed.
validateOperatorGates :: ChartDeploymentPlan -> IO (Either String ())
validateOperatorGates plan =
  validateOperatorGatesWith
    operatorAvailableTarget
    (chartDeploymentPlanOperatorGates plan)

-- | Execute graph-projected operator gates through the typed readiness seam.
-- The factory argument is the unit-test boundary; production supplies the
-- exhaustive 'operatorAvailableTarget'.
validateOperatorGatesWith
  :: (ComponentId -> Either Text.Text ComponentReadinessTarget)
  -> [ComponentId]
  -> IO (Either String ())
validateOperatorGatesWith targetFor =
  foldM validateGate (Right ())
 where
  validateGate :: Either String () -> ComponentId -> IO (Either String ())
  validateGate (Left err) _ = pure (Left err)
  validateGate (Right ()) gate =
    case targetFor gate of
      Left reason -> pure (Left (Text.unpack reason))
      Right target ->
        operatorGateResult gate
          <$> observeComponentReadiness target ProbeOperatorAvailable

-- | Lower the three-valued observation without losing its authoritative
-- detail. Only an affirmative observation opens the chart mutation gate.
operatorGateResult :: ComponentId -> ReadinessObservation -> Either String ()
operatorGateResult gate observation =
  case observation of
    ReadyObserved -> Right ()
    -- Sprint 1.76: this gate declares a shallow probe
    -- ('ProbeOperatorAvailable'), so a write-shaped observation cannot arise
    -- from it. Refusing rather than admitting keeps the arm honest if the
    -- declaration ever changes: a round trip is not evidence that an operator
    -- reported Available.
    RoundTripObserved _ ->
      Left
        ( "Operator readiness for `"
            ++ componentIdText gate
            ++ "` was answered with backend round-trip evidence, which does not "
            ++ "establish an operator Available condition."
        )
    NotReadyYet detail -> Left (Text.unpack detail)
    Unreachable reason ->
      Left
        ( "Cannot observe operator readiness for `"
            ++ componentIdText gate
            ++ "`: "
            ++ Text.unpack reason
        )

-- | Production target registry for @ProbeOperatorAvailable@. The match is
-- intentionally exhaustive: adding a new 'ComponentId' constructor requires
-- an explicit decision in the warning-clean build. Existing components that
-- are not operator gates fail closed if configuration projects them here.
operatorAvailableTarget :: ComponentId -> Either Text.Text ComponentReadinessTarget
operatorAvailableTarget component =
  case component of
    ComponentPerconaPostgresOperator ->
      Right
        ( OperatorAvailableTarget
            ComponentPerconaPostgresOperator
            observePatroniOperatorAvailable
        )
    ComponentClusterBase -> unsupportedOperatorGate component
    ComponentMinio -> unsupportedOperatorGate component
    ComponentVaultWorkload -> unsupportedOperatorGate component
    ComponentVaultUnsealed -> unsupportedOperatorGate component
    ComponentRegistry -> unsupportedOperatorGate component
    ComponentMetalLB -> unsupportedOperatorGate component
    ComponentEnvoyGateway -> unsupportedOperatorGate component
    ComponentCertManager -> unsupportedOperatorGate component
    ComponentGatewayDaemonPreVault -> unsupportedOperatorGate component
    ComponentGatewayDaemonFull -> unsupportedOperatorGate component
    ComponentChartPulsar -> unsupportedOperatorGate component
    ComponentChartRedis -> unsupportedOperatorGate component
    ComponentChartKeycloakPostgres -> unsupportedOperatorGate component
    ComponentChartKeycloak -> unsupportedOperatorGate component
    ComponentChartVscode -> unsupportedOperatorGate component
    ComponentChartApi -> unsupportedOperatorGate component
    ComponentChartWebsocket -> unsupportedOperatorGate component
    ComponentChartGateway -> unsupportedOperatorGate component
    ComponentChartBootstrapBroker -> unsupportedOperatorGate component
    ComponentChartLifecycleAuthority -> unsupportedOperatorGate component
    ComponentChartProviderWorker -> unsupportedOperatorGate component
    ComponentChartAuthorityBackup -> unsupportedOperatorGate component
    ComponentChartTlsRetention -> unsupportedOperatorGate component
    ComponentChartTargetSecretAgent -> unsupportedOperatorGate component

unsupportedOperatorGate :: ComponentId -> Either Text.Text value
unsupportedOperatorGate component =
  Left
    ( Text.pack
        ( "No ProbeOperatorAvailable executor is registered for component `"
            ++ componentIdText component
            ++ "`."
        )
    )

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

-- | Sprint 3.23 / 3.24: observe the Percona operator once. Authoritative
-- absence or @Available=False@ is pending convergence; a failed kubectl
-- observation is unreachable. The caller routes this through the shared
-- three-valued readiness seam.
observePatroniOperatorAvailable :: IO (Either Text.Text ReadinessProbeResult)
observePatroniOperatorAvailable =
  observePatroniOperatorAvailableWith $ \arguments -> do
    result <- runPg arguments
    pure $
      case result of
        Left err -> Left (serviceErrorMessage (toServiceError err))
        Right output -> Right output

-- | Injected one-shot adapter used to prove the Percona target classification
-- without a live cluster.
observePatroniOperatorAvailableWith
  :: ([String] -> IO (Either Text.Text ProcessOutput))
  -> IO (Either Text.Text ReadinessProbeResult)
observePatroniOperatorAvailableWith runKubectl = do
  crdResult <-
    runKubectl
      [ "get"
      , "crd"
      , patroniPostgresqlCrdName
      , "--ignore-not-found"
      , "-o"
      , "name"
      ]
  case crdResult of
    Left reason -> pure (Left reason)
    Right crdOutput ->
      case processExitCode crdOutput of
        ExitFailure _ -> pure (Left (operatorObservationFailure "Percona CRD" crdOutput))
        ExitSuccess
          | null (trimWhitespace (processStdout crdOutput)) ->
              pure
                ( Right
                    ( ReadinessProbePending
                        ( Text.pack
                            ( patroniNotReadyMessage
                                ++ " The CRD `"
                                ++ patroniPostgresqlCrdName
                                ++ "` has not been created yet."
                            )
                        )
                    )
                )
          | otherwise -> observeDeployment
 where
  observeDeployment = do
    availableResult <-
      runKubectl
        [ "get"
        , "deployment"
        , patroniOperatorDeploymentName
        , "--namespace"
        , patroniOperatorNamespace
        , "--ignore-not-found"
        , "-o"
        , "jsonpath={.status.conditions[?(@.type==\"Available\")].status}"
        ]
    pure $
      case availableResult of
        Left reason -> Left reason
        Right output ->
          case processExitCode output of
            ExitFailure _ -> Left (operatorObservationFailure "Percona operator Deployment" output)
            ExitSuccess
              | deploymentConditionReportsTrue (processStdout output) ->
                  Right ReadinessProbeReady
              | otherwise ->
                  Right
                    ( ReadinessProbePending
                        ( Text.pack
                            ( patroniNotReadyMessage
                                ++ " The operator Deployment `"
                                ++ patroniOperatorDeploymentName
                                ++ "` in namespace `"
                                ++ patroniOperatorNamespace
                                ++ "` is absent or is not yet reporting condition Available=True "
                                ++ "(presence is not readiness)."
                            )
                        )
                    )

operatorObservationFailure :: String -> ProcessOutput -> Text.Text
operatorObservationFailure subject output =
  Text.pack
    ( subject
        ++ " observation failed with "
        ++ show (processExitCode output)
        ++ ": "
        ++ processStderr output
        ++ processStdout output
    )

-- | Shared remediation prefix for an authoritative pending observation.
patroniNotReadyMessage :: String
patroniNotReadyMessage =
  "Patroni PostgreSQL platform is not ready. "
    ++ "Run `prodbox cluster reconcile` before deploying charts that depend on PostgreSQL."

-- | Sprint 3.23 (pure): whether a @kubectl get ... -o jsonpath@ Deployment
-- condition-status field reports @True@ (case/whitespace-insensitive). An empty
-- string (no such condition) or any other value is __not__ ready.
deploymentConditionReportsTrue :: String -> Bool
deploymentConditionReportsTrue raw =
  map toLower (dropWhile isSpace (dropWhileEnd isSpace raw)) == "true"

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
  -> Maybe String
  -> Maybe Text.Text
  -> Maybe ParentRef
  -> Maybe KubernetesApiEgressCoordinate
  -> Either String ChartDeploymentPlan
buildChartDeploymentPlanPure substrate repoRoot settings chartName chartSecrets gatewayEventKeys maybeRuntimeImage maybeGatewayHostedZoneId maybeGatewayTier0Dhall maybeControlPlaneClusterId maybeControlPlaneParentRef maybeApiEgressCoordinate = do
  when
    (chartStorageClassName /= "manual")
    (Left "Chart platform requires StorageClass 'manual'; dynamic provisioners are not permitted")
  let storageClassName = chartStorageClassNameForSubstrate substrate
      graph = effectiveComponentGraph (components (validatedConfig settings))
  releaseOrder <- resolveDependencyOrder graph repoRoot chartName
  dag <- either (Left . renderComponentGraphError) Right (validateComponentGraph graph)
  let operatorGates =
        operatorAvailableGates
          dag
          [cid | name <- releaseOrder, Just cid <- [componentIdForChartName name]]
  definitions <- mapM (resolveChart repoRoot) releaseOrder
  maybePublicFqdn <-
    if any chartDefinitionRequiresPublicHost definitions
      then Just <$> resolveRootPublicFqdn substrate settings chartName
      else Right Nothing
  maybeCertScopeSet <-
    case maybePublicFqdn of
      Just _
        | chartName == publicEdgeTlsNamespace && "keycloak" `elem` releaseOrder ->
            Just <$> requireSubstrateCertScopeSet settings substrate
      _ -> Right Nothing
  releases <-
    forM definitions $ \definition -> do
      storageBindings <-
        mapM
          ( storageBinding
              (validatedResourcePlan settings)
              (resolvedManualPvHostRoot settings)
              chartName
              (chartDefinitionName definition)
          )
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
          maybeGatewayTier0Dhall
          maybeControlPlaneClusterId
          maybeControlPlaneParentRef
          maybeApiEgressCoordinate
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
      , chartDeploymentPlanCertScopeSet = maybeCertScopeSet
      , chartDeploymentPlanOperatorGates = operatorGates
      , chartDeploymentPlanSubstrate = substrate
      }

chartStorageClassNameForSubstrate :: Substrate -> String
chartStorageClassNameForSubstrate substrate =
  case substrate of
    SubstrateHomeLocal -> chartStorageClassName
    SubstrateAws -> chartStorageClassName

-- | Sprint 3.23: the chart deploy order (dependencies-before-dependents),
-- sourced from the Tier-0 component dependency/readiness graph rather than the
-- retired hardcoded @chartDefinitionDependencies@ literals
-- (bootstrap_readiness_doctrine.md M1/M2). Cycle rejection and the resulting
-- order are unchanged — the chart→chart edges of the default graph reproduce the
-- historical order exactly. 'resolveChart' still validates the chart name.
-- | Sprint 4.43: an empty config-sourced component graph means "no operator
-- override" — fall back to the built-in 'defaultComponentGraph'. Production
-- @prodbox.dhall@ (generated via the schema default) always carries the full
-- graph, so the config remains the source there (M2); only degenerate fixtures
-- and legacy configs decode with an empty list, and they get the default.
effectiveComponentGraph :: [ComponentNode] -> [ComponentNode]
effectiveComponentGraph graph
  | null graph = defaultComponentGraph
  | otherwise = graph

resolveDependencyOrder :: [ComponentNode] -> FilePath -> String -> Either String [String]
resolveDependencyOrder rawGraph repoRoot chartName = do
  _ <- resolveChart repoRoot chartName
  let graph = effectiveComponentGraph rawGraph
  dag <- either (Left . renderComponentGraphError) Right (validateComponentGraph graph)
  rootId <-
    maybe
      (Left ("Chart '" ++ chartName ++ "' has no component-graph node."))
      Right
      (componentIdForChartName chartName)
  order <- chartComponentDeployOrder dag rootId
  traverse toChartName order
 where
  toChartName cid =
    maybe
      (Left ("Component `" ++ componentIdText cid ++ "` is not a chart."))
      Right
      (chartNameForComponent cid)

-- | Sprint 3.23: a chart's direct chart-level dependency names, sourced from the
-- component graph, for the @charts list@ / @charts status@ DEPENDENCIES display
-- (replacing the retired hardcoded @chartDefinitionDependencies@ literal). An
-- invalid graph or unknown chart yields no dependencies (display-robust).
chartDirectDependencyNames :: [ComponentNode] -> String -> [String]
chartDirectDependencyNames rawGraph chartName =
  case (validateComponentGraph (effectiveComponentGraph rawGraph), componentIdForChartName chartName) of
    (Right dag, Just cid) ->
      [name | dep <- directChartDependencies dag cid, Just name <- [chartNameForComponent dep]]
    _ -> []

-- | Sprint 1.83: the served host comes from the parse config validation
-- performed ('Prodbox.Settings.validatedPublicEdge'), not from a second reading
-- of the raw record followed by an emptiness test. The @chartName@ argument is
-- retained because every caller passes one and the root chart is what the
-- resolution is *about*, but it has never participated: the served host is a
-- property of the substrate.
resolveRootPublicFqdn :: Substrate -> ValidatedSettings -> String -> Either String String
resolveRootPublicFqdn substrate settings _chartName =
  requireSubstratePublicFqdn settings substrate

resolveGatewayHostedZoneIdForSubstrate
  :: Substrate -> FilePath -> ValidatedSettings -> IO (Either String (Maybe String))
-- Sprint 1.89: both substrates go through the one resolver.
--
-- The home arm used to read @route53.zone_id@ raw and wrap it in @Just@
-- unconditionally, so an unset zone produced @Just ""@ — a hosted-zone id that
-- is not one — and the refusal lived two functions away in 'valuesForGateway',
-- as a @null@ test on a string. 'resolveSubstrateHostedZoneId' now refuses on
-- both substrates, which is what lets that test be deleted rather than
-- duplicated.
resolveGatewayHostedZoneIdForSubstrate substrate repoRoot settings = do
  hostedZoneResult <- resolveSubstrateHostedZoneId repoRoot settings substrate
  pure (fmap (Just . Text.unpack) hostedZoneResult)

-- | Render the non-secret daemon-frame Tier-0 document mounted beside the
-- runtime @config.dhall@. The home identity comes from the established
-- binary-sibling Tier-0 floor; the per-run AWS identity is the canonical EKS
-- cluster name. Both paths reuse the daemon default and change only
-- @context.cluster_id@, so parameters, witness, capabilities, and frame kind
-- cannot drift from the daemon-owned schema.
resolveGatewayTier0DhallForSubstrate
  :: Substrate -> FilePath -> IO (Either String String)
resolveGatewayTier0DhallForSubstrate substrate repoRoot = do
  clusterIdResult <- resolveClusterIdentityForSubstrate substrate repoRoot
  pure (renderGatewayTier0Dhall <$> clusterIdResult)

-- | Resolve the same substrate identity for every standing control-plane role.
-- It is mounted explicitly in schema-v3 role config; no role guesses identity
-- from its namespace or consults environment variables.
resolveClusterIdentityForSubstrate
  :: Substrate -> FilePath -> IO (Either String Text.Text)
resolveClusterIdentityForSubstrate substrate repoRoot =
  case substrate of
    SubstrateHomeLocal -> do
      basicsResult <- loadUnencryptedBasics repoRoot
      pure $ case basicsResult of
        Left err -> Left ("control-plane Tier-0 home cluster identity unavailable: " ++ err)
        Right basics -> Right (basicsClusterId basics)
    SubstrateAws ->
      pure (Right (Text.pack AwsEks.awsEksCanonicalClusterName))

resolveParentRegistrationForSubstrate
  :: Substrate -> FilePath -> IO (Either String (Maybe ParentRef))
resolveParentRegistrationForSubstrate substrate repoRoot =
  case substrate of
    SubstrateHomeLocal -> do
      basicsResult <- loadUnencryptedBasics repoRoot
      pure $ case basicsResult of
        Left err -> Left ("bootstrap-broker Tier-0 parent reference unavailable: " ++ err)
        Right basics -> Right (basicsParentRef basics)
    -- The harness-owned EKS substrate is a clean root deployment.  A future
    -- federated EKS child must carry its own substrate Tier-0 projection rather
    -- than borrowing the home cluster's parent reference.
    SubstrateAws -> pure (Right Nothing)

renderGatewayTier0Dhall :: Text.Text -> String
renderGatewayTier0Dhall clusterId =
  Text.unpack
    ( Tier0.renderProjectConfigDhall
        Tier0.defaultDaemonProjectConfig
          { Tier0.context =
              (Tier0.context Tier0.defaultDaemonProjectConfig)
                { Tier0.cluster_id = clusterId
                }
          }
    )

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
  -> Maybe String
  -> Maybe Text.Text
  -> Maybe ParentRef
  -> Maybe KubernetesApiEgressCoordinate
  -> Either String String
renderReleaseValuesJson substrate definition namespace rootChart settings chartSecrets gatewayEventKeys storageClassName storageBindings maybePublicFqdn maybeRuntimeImage maybeGatewayHostedZoneId maybeGatewayTier0Dhall maybeControlPlaneClusterId maybeControlPlaneParentRef maybeApiEgressCoordinate = do
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
            valuesForKeycloak substrate namespace rootChart settings chartSecrets fqdn
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
        case (maybePublicFqdn, maybeGatewayHostedZoneId, maybeGatewayTier0Dhall, maybeControlPlaneClusterId) of
          (Just fqdn, Just zoneId, Just gatewayTier0Dhall, Just clusterId) ->
            valuesForGateway
              substrate
              namespace
              rootChart
              settings
              gatewayEventKeys
              fqdn
              maybeRuntimeImage
              zoneId
              gatewayTier0Dhall
              clusterId
          (Nothing, _, _, _) -> Left "gateway requires a public host"
          (_, Nothing, _, _) -> Left "gateway requires a Route 53 hosted zone id"
          (_, _, Nothing, _) -> Left "gateway requires a substrate-specific Tier-0 document"
          (_, _, _, Nothing) -> Left "gateway requires an explicit Lifecycle Authority scope"
      "bootstrap-broker" ->
        requireControlPlaneClusterId >>= \clusterId ->
          valuesForBootstrapBrokerWithParent
            clusterId
            maybeControlPlaneParentRef
            namespace
            rootChart
            maybeRuntimeImage
      "lifecycle-authority" ->
        requireControlPlaneClusterId >>= \clusterId ->
          valuesForLifecycleAuthority clusterId namespace rootChart maybeRuntimeImage
      "provider-worker" ->
        requireControlPlaneClusterId >>= \clusterId ->
          valuesForProviderWorker clusterId namespace rootChart maybeRuntimeImage
      "authority-backup" ->
        requireControlPlaneClusterId >>= \clusterId ->
          valuesForAuthorityBackup
            settings
            clusterId
            namespace
            rootChart
            maybeRuntimeImage
      "tls-retention" ->
        requireControlPlaneClusterId >>= \clusterId ->
          valuesForTlsRetention
            substrate
            settings
            clusterId
            namespace
            rootChart
            maybeRuntimeImage
      "target-secret-agent" ->
        requireControlPlaneClusterId >>= \clusterId ->
          valuesForTargetSecretAgent clusterId namespace rootChart maybeRuntimeImage
      _ -> Left ("Unsupported chart definition '" ++ chartDefinitionName definition ++ "'")
  values <- attachResourcePlanValues substrate settings definition rootChart baseValues
  valuesWithApiEgress <-
    attachKubernetesApiEgressValues definition maybeApiEgressCoordinate values
  pure (BL8.unpack (Pretty.encodePretty' prettyJsonConfig valuesWithApiEgress))
 where
  requireControlPlaneClusterId =
    maybe
      (Left "standing control-plane role requires an explicit substrate cluster identity")
      Right
      maybeControlPlaneClusterId

-- | Sprint 3.34: bind the observed Kubernetes API egress coordinate into the
-- values of the two charts whose NetworkPolicy carries it.
--
-- The chart is the consumer and this is the only producer, so a chart in
-- 'kubernetesApiEgressChartNames' rendered without an observation is a loud
-- failure rather than a silently absent binding — the template would otherwise
-- render an egress rule with an empty peer list and admit nothing, reproducing
-- the outage this sprint exists to remove.
attachKubernetesApiEgressValues
  :: ChartDefinition -> Maybe KubernetesApiEgressCoordinate -> Value -> Either String Value
attachKubernetesApiEgressValues definition maybeCoordinate values
  | chartDefinitionName definition `notElem` kubernetesApiEgressChartNames = Right values
  | otherwise =
      case maybeCoordinate of
        Nothing ->
          Left
            ( "chart '"
                ++ chartDefinitionName definition
                ++ "' renders the Kubernetes API egress rule but no `endpoints/kubernetes` "
                ++ "observation was supplied"
            )
        Just coordinate ->
          mergeObjectValues
            values
            (object ["kubernetesApiEgress" .= kubernetesApiEgressValues coordinate])

attachResourcePlanValues
  :: Substrate -> ValidatedSettings -> ChartDefinition -> String -> Value -> Either String Value
attachResourcePlanValues substrate settings definition rootChart values = do
  let plan = validatedResourcePlan settings
  resources <- chartResourcesValue plan (chartDefinitionName definition)
  guardrails <-
    resourceGuardrailsValue substrate plan rootChart (chartDefinitionName definition == rootChart)
  withResources <-
    mergeObjectValues
      values
      ( object
          [ "resources" .= resources
          , "resourceGuardrails" .= guardrails
          ]
      )
  case chartDefinitionName definition of
    "lifecycle-authority" -> do
      size <- workloadStorageSize plan "lifecycle-authority"
      mergeObjectValues withResources (object ["storage" .= object ["size" .= size]])
    _ -> Right withResources

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
    -- Sprint 3.26: the value key is camelCase (`bootstrapBroker`) to match the
    -- broker deployment template's `.Values.resources.bootstrapBroker`, while the
    -- profile id is the kebab-case `bootstrap-broker` capacity profile.
    "bootstrap-broker" -> [("bootstrapBroker", "bootstrap-broker")]
    "lifecycle-authority" -> [("lifecycleAuthority", "lifecycle-authority")]
    "provider-worker" -> [("providerWorker", "provider-worker")]
    "authority-backup" -> [("authorityBackup", "authority-backup")]
    "tls-retention" -> [("tlsRetention", "tls-retention")]
    "target-secret-agent" -> [("targetSecretAgent", "target-secret-agent")]
    other -> [(other, other)]

resourceGuardrailsValue
  :: Substrate -> Capacity.ResourcePlan -> String -> Bool -> Either String Value
resourceGuardrailsValue substrate plan rootChart enabled = do
  namespaceAdmission <-
    Placement.planNamespaceAdmission substrate (Text.pack rootChart) plan
  limitEnvelope <-
    Placement.planNamespaceLimits substrate (Text.pack rootChart) plan
  pure
    ( object
        [ "enabled" .= enabled
        , "quota" .= CapacityRender.resourceQuotaEnvelopeSpec namespaceAdmission
        , "limitRange" .= CapacityRender.limitRangeValue limitEnvelope
        ]
    )

requireResourceProfile
  :: Capacity.ResourcePlan -> String -> Either String Capacity.WorkloadResourceProfile
requireResourceProfile plan profileId =
  case find ((== Text.pack profileId) . Capacity.profile_id) (Capacity.workload_profiles plan) of
    Just profile -> Right profile
    Nothing -> Left ("capacity.resource_plan is missing workload profile `" ++ profileId ++ "`")

resourceEnvelopeValue :: Capacity.ResourceEnvelope -> Value
resourceEnvelopeValue envelope =
  object
    [ "requests" .= CapacityRender.resourceVectorRuntimeValue (Capacity.request envelope)
    , "limits" .= CapacityRender.resourceVectorRuntimeValue (Capacity.limit envelope)
    ]

mergeObjectValues :: Value -> Value -> Either String Value
mergeObjectValues base additions =
  case (base, additions) of
    (Object baseObject, Object additionsObject) ->
      Right (Object (KeyMap.union additionsObject baseObject))
    _ -> Left "chart resource-plan injection requires object values"

valuesForKeycloak
  :: Substrate
  -> String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> String
  -> Either String Value
valuesForKeycloak substrate namespace rootChart settings _chartSecrets sharedHostFqdn = do
  -- Sprint 3.18: Keycloak's admin password, Patroni application-role
  -- password, OIDC client secrets, demo-user password, and SMTP settings are
  -- read directly from Vault KV by the Pod's Kubernetes-auth init container.
  -- The namespace controls the least-privilege Vault role and the
  -- namespace-scoped KV paths used by the transitive vscode deployment.
  let keycloakVaultRole =
        if namespace == "keycloak" then "keycloak" else namespace ++ "-keycloak"
  -- Sprint 2.35: the public-edge Certificate dnsNames are a projection of the one
  -- configured certificate scope set, keyed on this substrate's served host. Empty
  -- @cert_scopes@ yields exactly @[sharedHostFqdn]@, so the rendered dnsNames are
  -- behavior-identical to the prior single-host list until an operator widens scope.
  -- Sprint 1.83: projected from the carried scope set rather than re-parsed.
  certDnsNames <- certScopeSetDnsNames <$> requireSubstrateCertScopeSet settings substrate
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
              , "certDnsNames" .= certDnsNames
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
  storageSize <-
    case storageBindings of
      binding : _ -> Right (chartStorageBindingStorageSize binding)
      [] -> Left "keycloak-postgres requires storage bindings"
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
              , "size" .= storageSize
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

-- | Sprint 3.26: deployed values for the physically separate Bootstrap Broker
-- workload. Every identity/probe value is projected from the one compiled
-- 'BrokerChartStatics.brokerChartStatics', so the deployed values, the generated
-- @values.yaml@ block, and the hand-written templates cannot diverge. The
-- Guaranteed-QoS resource envelope is attached from the typed capacity plan by
-- 'attachResourcePlanValues' (the @bootstrap-broker@ workload profile), so it is
-- intentionally absent here.
valuesForBootstrapBroker
  :: Text.Text -> String -> String -> Maybe ResolvedCustomImage -> Either String Value
valuesForBootstrapBroker clusterId =
  valuesForBootstrapBrokerWithParent clusterId Nothing

valuesForBootstrapBrokerWithParent
  :: Text.Text
  -> Maybe ParentRef
  -> String
  -> String
  -> Maybe ResolvedCustomImage
  -> Either String Value
valuesForBootstrapBrokerWithParent clusterId maybeParent namespace rootChart maybeRuntimeImage = do
  resolvedImage <-
    case maybeRuntimeImage of
      Just imageInfo -> Right imageInfo
      Nothing -> Left "bootstrap-broker chart requires a resolved image reference"
  let statics = BrokerChartStatics.brokerChartStatics
  pure
    ( object
        [ "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              ]
        , "podAnnotations"
            .= customImagePodAnnotationsValue (resolvedCustomImageRolloutToken resolvedImage)
        , "image"
            .= object
              [ "repository" .= resolvedCustomImageRepository resolvedImage
              , "tag" .= resolvedCustomImageTag resolvedImage
              , "pullPolicy" .= ("IfNotPresent" :: String)
              ]
        , "runtime" .= object ["rtsArguments" .= ([] :: [String])]
        , -- ServiceAccount / Vault role / probe paths are projections of the one
          -- compiled BrokerChartStatics, matching the generated @values.yaml@
          -- block and the hand-written templates.
          "serviceAccount" .= BrokerChartStatics.brokerChartStaticsServiceAccountValue
        , "client" .= BrokerChartStatics.brokerChartStaticsClientValue
        , "worker"
            .= object
              [ "imageRepository"
                  .= BrokerChartStatics.brokerStaticWorkerImageRepository statics
              ]
        , "vault"
            .= object
              [ "role" .= BrokerChartStatics.brokerStaticVaultRole statics
              ]
        , "probes"
            .= object
              [ "liveness" .= BrokerChartStatics.brokerStaticLivenessPath statics
              , "readiness" .= BrokerChartStatics.brokerStaticReadinessPath statics
              ]
        , "probeTiming"
            .= object
              [ "liveness"
                  .= object
                    [ "initialDelaySeconds" .= (5 :: Int)
                    , "periodSeconds" .= (15 :: Int)
                    , "timeoutSeconds" .= (1 :: Int)
                    , "failureThreshold" .= (3 :: Int)
                    , "successThreshold" .= (1 :: Int)
                    ]
              , "readiness"
                  .= object
                    [ "initialDelaySeconds" .= (3 :: Int)
                    , "periodSeconds" .= (10 :: Int)
                    , "timeoutSeconds" .= (1 :: Int)
                    , "failureThreshold" .= (6 :: Int)
                    , "successThreshold" .= (1 :: Int)
                    ]
              ]
        , "listener" .= object ["port" .= controlPlaneListenPort]
        , "config"
            .= object
              [ "brokerDhall"
                  .= renderBootstrapBrokerConfigDhall clusterId maybeParent statics
              ]
        ]
    )

renderBootstrapBrokerConfigDhall
  :: Text.Text -> Maybe ParentRef -> BrokerChartStatics.BrokerChartStatics -> String
renderBootstrapBrokerConfigDhall clusterId maybeParent statics =
  "{ schemaVersion = 2"
    ++ ", cluster_id = "
    ++ renderDhallText clusterId
    ++ ", vault_address = "
    ++ renderDhallText "http://vault.vault.svc.cluster.local:8200"
    ++ ", service_identity = "
    ++ renderDhallText (BrokerChartStatics.brokerStaticClientServiceAccount statics)
    ++ ", listener = { listen_host = \"127.0.0.1\", listen_port = "
    ++ show controlPlaneListenPort
    ++ " }"
    ++ ", bootstrap_store = "
    ++ "{ store_endpoint = \"http://minio.prodbox.svc.cluster.local:9000\""
    ++ ", store_bucket = \"prodbox-state\""
    ++ storeKey "vault_storage_generation_key" "vault-storage-generation"
    ++ storeKey "bootstrap_session_fence_key" "bootstrap-session-fence"
    ++ storeKey "prepared_init_envelope_key" "prepared-init-envelope"
    ++ storeKey "encrypted_init_response_key" "encrypted-init-response"
    ++ storeKey "final_unlock_bundle_key" "final-unlock-bundle"
    ++ storeKey "child_custody_receipt_key" "child-custody-receipt"
    ++ storeKey "child_recovery_delivery_key" "child-recovery-delivery"
    ++ storeKey "root_init_journal_key" "root-init-journal"
    ++ storeKey "root_session_journal_key" "root-session-journal"
    ++ storeKey "child_custody_journal_key" "child-custody-journal"
    ++ storeKey "child_recovery_journal_key" "child-recovery-journal"
    ++ storeKey "post_unseal_handoff_key" "post-unseal-handoff"
    ++ storeKey "secret_worker_checkpoint_key" "secret-worker-checkpoint"
    ++ " }"
    ++ ", limits = { queue_capacity = 64, max_request_body_bytes = 65536"
    ++ ", request_deadline_milliseconds = 300000, drain_deadline_milliseconds = 60000 }"
    ++ ", parent_registration = "
    ++ renderParentRegistration maybeParent
    ++ " }"
 where
  storeKey field suffix =
    ", "
      ++ field
      ++ " = "
      ++ renderDhallText ("bootstrap/" <> Text.strip clusterId <> "/" <> suffix)
  renderParentRegistration parent = case parent of
    Nothing ->
      "None { parent_cluster_id : Text, parent_authority_endpoint : Text }"
    Just ref ->
      "Some { parent_cluster_id = "
        ++ renderDhallText (parentRefClusterId ref)
        ++ ", parent_authority_endpoint = "
        ++ renderDhallText (parentRefAuthorityEndpoint ref)
        ++ " }"

-- | Sprint 3.26: shared deployed-values builder for the five standing
-- control-plane role charts. Every identity/probe value is projected from the
-- role's one compiled @ChartStatics@ (passed in by the thin per-role wrappers),
-- so the deployed values, the generated @values.yaml@ block, and the
-- hand-written templates cannot diverge. The Guaranteed-QoS envelope is attached
-- separately from the typed capacity plan by 'attachResourcePlanValues', so it
-- is intentionally absent here. StatefulSet-specific values (the Lifecycle
-- Authority journal storage class) come from the chart's @values.yaml@ default.
valuesForControlPlaneRole
  :: Text.Text
  -> RuntimeRole
  -> String
  -> Value
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> String
  -> String
  -> String
  -> Maybe ResolvedCustomImage
  -> Either String Value
valuesForControlPlaneRole clusterId runtimeRole chartName serviceAccountValue vaultRole livenessPath readinessPath roleStoreDhall namespace rootChart maybeRuntimeImage = do
  resolvedImage <-
    case maybeRuntimeImage of
      Just imageInfo -> Right imageInfo
      Nothing -> Left (chartName ++ " chart requires a resolved image reference")
  rolloutToken <-
    maybe
      (Left (chartName ++ " chart requires an immutable runtime image rollout digest"))
      Right
      (resolvedCustomImageRolloutToken resolvedImage)
  targetAgentIdentity <-
    first
      Text.unpack
      (mkTargetAgentRolloutIdentity clusterId (Text.pack rolloutToken))
  pure
    ( object
        [ "global"
            .= object
              [ "namespace" .= namespace
              , "rootChart" .= rootChart
              , "clusterIdentity" .= clusterId
              , "targetAgentIdentity" .= targetAgentIdentityText targetAgentIdentity
              , "targetAgentRolloutDigest" .= targetAgentRolloutDigest targetAgentIdentity
              ]
        , "podAnnotations"
            .= customImagePodAnnotationsValue (resolvedCustomImageRolloutToken resolvedImage)
        , "image"
            .= object
              [ "repository" .= resolvedCustomImageRepository resolvedImage
              , "tag" .= resolvedCustomImageTag resolvedImage
              , "pullPolicy" .= ("IfNotPresent" :: String)
              ]
        , "runtime" .= object ["rtsArguments" .= ([] :: [String])]
        , "serviceAccount" .= serviceAccountValue
        , "vault" .= object ["role" .= vaultRole]
        , "probes"
            .= object
              [ "liveness" .= livenessPath
              , "readiness" .= readinessPath
              ]
        , "probeTiming" .= controlPlaneProbeTimingValue
        , "listener" .= object ["port" .= controlPlaneListenPort]
        , "config"
            .= object
              [ "roleDhall"
                  .= ( "{ schema_version = 7, runtime_role = "
                         ++ renderDhallText (Text.pack chartName)
                         ++ ", cluster_id = "
                         ++ renderDhallText clusterId
                         ++ ", target_agent_identity = "
                         ++ renderDhallText (targetAgentIdentityText targetAgentIdentity)
                         ++ ", role_store = "
                         ++ roleStoreDhall
                         ++ ", vault_address = "
                         ++ renderDhallText "http://vault.vault.svc.cluster.local:8200"
                         ++ ", vault_auth_path = "
                         ++ renderDhallText "kubernetes"
                         ++ ", vault_role = "
                         ++ renderDhallText vaultRole
                         ++ ", service_account_token_file = "
                         ++ renderDhallText "/var/run/secrets/kubernetes.io/serviceaccount/token"
                         ++ ", request_authentication = "
                         ++ renderControlPlaneAuthenticationDhall runtimeRole
                         ++ " }"
                         :: String
                     )
              ]
        ]
    )

renderControlPlaneAuthenticationDhall :: RuntimeRole -> String
renderControlPlaneAuthenticationDhall role =
  "{ maximum_trusted_callers_per_route = "
    ++ show maximumPerRoute
    ++ ", signing_principal_code = "
    ++ show (callerPrincipalCode signingCaller)
    ++ ", signing_key_name = "
    ++ renderDhallText
      (controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor signingCaller))
    ++ ", trusted_callers = "
    ++ renderEntries entries
    ++ " }"
 where
  signingCaller = localServiceCaller role
  routes = routesForRole role
  entries =
    [ (route, caller)
    | route <- routes
    , caller <- trustedCallersForRoute route
    ]
  maximumPerRoute = maximum (1 : fmap (length . trustedCallersForRoute) routes)
  renderEntries values =
    "[ "
      ++ intercalate ", " (fmap renderEntry values)
      ++ " ]"
  renderEntry (route, caller) =
    "{ trusted_route_path = "
      ++ renderDhallText (Text.pack (controlPlaneRoutePath route))
      ++ ", trusted_caller_code = "
      ++ show (callerPrincipalCode caller)
      ++ ", trusted_signing_key_name = "
      ++ renderDhallText
        ( controlPlaneSigningKeyName
            (controlPlaneSigningKeyRefFor caller)
        )
      ++ " }"

-- | The constant-time liveness/readiness probe timing shared by every standing
-- control-plane role chart (identical to the Bootstrap Broker's).
controlPlaneProbeTimingValue :: Value
controlPlaneProbeTimingValue =
  object
    [ "liveness"
        .= object
          [ "initialDelaySeconds" .= (5 :: Int)
          , "periodSeconds" .= (15 :: Int)
          , "timeoutSeconds" .= (1 :: Int)
          , "failureThreshold" .= (3 :: Int)
          , "successThreshold" .= (1 :: Int)
          ]
    , "readiness"
        .= object
          [ "initialDelaySeconds" .= (3 :: Int)
          , "periodSeconds" .= (10 :: Int)
          , "timeoutSeconds" .= (1 :: Int)
          , "failureThreshold" .= (6 :: Int)
          , "successThreshold" .= (1 :: Int)
          ]
    ]

valuesForLifecycleAuthority
  :: Text.Text -> String -> String -> Maybe ResolvedCustomImage -> Either String Value
valuesForLifecycleAuthority clusterId namespace rootChart maybeRuntimeImage =
  valuesForControlPlaneRole
    clusterId
    LifecycleAuthorityRuntime
    "lifecycle-authority"
    AuthorityStatics.lifecycleAuthorityChartStaticsServiceAccountValue
    (AuthorityStatics.lifecycleAuthorityStaticVaultRole s)
    (AuthorityStatics.lifecycleAuthorityStaticLivenessPath s)
    (AuthorityStatics.lifecycleAuthorityStaticReadinessPath s)
    ( roleStorePrimaryDhall
        "http://minio.prodbox.svc.cluster.local:9000"
        "prodbox-state"
    )
    namespace
    rootChart
    maybeRuntimeImage
 where
  s = AuthorityStatics.lifecycleAuthorityChartStatics

valuesForProviderWorker
  :: Text.Text -> String -> String -> Maybe ResolvedCustomImage -> Either String Value
valuesForProviderWorker clusterId namespace rootChart maybeRuntimeImage =
  valuesForControlPlaneRole
    clusterId
    ProviderWorkerRuntime
    "provider-worker"
    ProviderWorkerStatics.providerWorkerChartStaticsServiceAccountValue
    (ProviderWorkerStatics.providerWorkerStaticVaultRole s)
    (ProviderWorkerStatics.providerWorkerStaticLivenessPath s)
    (ProviderWorkerStatics.providerWorkerStaticReadinessPath s)
    roleStoreProviderWorkerDhall
    namespace
    rootChart
    maybeRuntimeImage
 where
  s = ProviderWorkerStatics.providerWorkerChartStatics

valuesForAuthorityBackup
  :: ValidatedSettings
  -> Text.Text
  -> String
  -> String
  -> Maybe ResolvedCustomImage
  -> Either String Value
valuesForAuthorityBackup settings clusterId namespace rootChart maybeRuntimeImage = do
  (bucket, region) <- dedicatedAdapterBackend settings
  let prefix = "authority-backup-store/" <> Text.strip clusterId
  valuesForControlPlaneRole
    clusterId
    AuthorityBackupRuntime
    "authority-backup"
    AuthorityBackupStatics.authorityBackupChartStaticsServiceAccountValue
    (AuthorityBackupStatics.authorityBackupStaticVaultRole s)
    (AuthorityBackupStatics.authorityBackupStaticLivenessPath s)
    (AuthorityBackupStatics.authorityBackupStaticReadinessPath s)
    (roleStoreAuthorityBackupDhall (awsS3EndpointForRegion region) region bucket prefix)
    namespace
    rootChart
    maybeRuntimeImage
 where
  s = AuthorityBackupStatics.authorityBackupChartStatics

valuesForTlsRetention
  :: Substrate
  -> ValidatedSettings
  -> Text.Text
  -> String
  -> String
  -> Maybe ResolvedCustomImage
  -> Either String Value
valuesForTlsRetention substrate settings clusterId namespace rootChart maybeRuntimeImage = do
  (bucket, region) <- dedicatedAdapterBackend settings
  _servedFqdn <- resolveRootPublicFqdn substrate settings rootChart
  scopeSet <- requireSubstrateCertScopeSet settings substrate
  let prefix = Text.pack (publicEdgeTlsRetentionKey substrate scopeSet)
      prefixStem = Text.pack ("public-edge-tls/" ++ substrateId substrate ++ "/")
  scopeKey <-
    maybe
      (Left "TLS retention key is outside its canonical substrate prefix")
      Right
      (Text.stripPrefix prefixStem prefix)
  valuesForControlPlaneRole
    clusterId
    TlsRetentionRuntime
    "tls-retention"
    TlsRetentionStatics.tlsRetentionChartStaticsServiceAccountValue
    (TlsRetentionStatics.tlsRetentionStaticVaultRole s)
    (TlsRetentionStatics.tlsRetentionStaticLivenessPath s)
    (TlsRetentionStatics.tlsRetentionStaticReadinessPath s)
    ( roleStoreTlsRetentionDhall
        (awsS3EndpointForRegion region)
        region
        bucket
        (Text.pack (substrateId substrate))
        scopeKey
        prefix
    )
    namespace
    rootChart
    maybeRuntimeImage
 where
  s = TlsRetentionStatics.tlsRetentionChartStatics

valuesForTargetSecretAgent
  :: Text.Text -> String -> String -> Maybe ResolvedCustomImage -> Either String Value
valuesForTargetSecretAgent clusterId namespace rootChart maybeRuntimeImage =
  valuesForControlPlaneRole
    clusterId
    TargetSecretAgentRuntime
    "target-secret-agent"
    TargetSecretAgentStatics.targetSecretAgentChartStaticsServiceAccountValue
    (TargetSecretAgentStatics.targetSecretAgentStaticVaultRole s)
    (TargetSecretAgentStatics.targetSecretAgentStaticLivenessPath s)
    (TargetSecretAgentStatics.targetSecretAgentStaticReadinessPath s)
    roleStoreTargetSecretAgentDhall
    namespace
    rootChart
    maybeRuntimeImage
 where
  s = TargetSecretAgentStatics.targetSecretAgentChartStatics

-- | Sprint 1.89: the dedicated adapter's backend coordinates, from the parsed
-- projection.
--
-- The two @Text.null@ tests this replaced were the only thing standing between a
-- malformed bucket name and an S3 call, because @pulumi_state_backend.region@
-- had no validation rule anywhere and the bucket's rule discarded its result.
-- What remains here is the /presence/ decision, which is genuinely this
-- function's: an adapter needs a backend, while the config as a whole does not.
dedicatedAdapterBackend :: ValidatedSettings -> Either String (Text.Text, Text.Text)
dedicatedAdapterBackend settings = do
  let coordinates = validatedCoordinates settings
  bucket <-
    maybe
      (Left "pulumi_state_backend.bucket_name is required for a dedicated adapter")
      (Right . s3BucketNameText)
      (coordinatePulumiBackendBucket coordinates)
  region <-
    maybe
      (Left "pulumi_state_backend.region is required for a dedicated adapter")
      (Right . awsRegionText)
      (coordinatePulumiBackendRegion coordinates)
  Right (bucket, region)

roleStoreTypeDhall :: String
roleStoreTypeDhall =
  "< None"
    ++ " | ProviderWorker"
    ++ " | TargetSecretAgent"
    ++ " | Primary : { primary_endpoint : Text, primary_bucket : Text }"
    ++ " | AuthorityBackup : { authority_backup_endpoint : Text, authority_backup_region : Text, authority_backup_bucket : Text, authority_backup_prefix : Text }"
    ++ " | TlsRetention : { tls_retention_endpoint : Text, tls_retention_region : Text, tls_retention_bucket : Text, tls_retention_substrate : Text, tls_retention_scope_key : Text, tls_retention_prefix : Text }"
    ++ " >"

roleStoreProviderWorkerDhall :: String
roleStoreProviderWorkerDhall = roleStoreTypeDhall ++ ".ProviderWorker"

roleStoreTargetSecretAgentDhall :: String
roleStoreTargetSecretAgentDhall = roleStoreTypeDhall ++ ".TargetSecretAgent"

roleStorePrimaryDhall :: Text.Text -> Text.Text -> String
roleStorePrimaryDhall endpoint bucket =
  roleStoreTypeDhall
    ++ ".Primary { primary_endpoint = "
    ++ renderDhallText endpoint
    ++ ", primary_bucket = "
    ++ renderDhallText bucket
    ++ " }"

roleStoreAuthorityBackupDhall
  :: Text.Text
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> String
roleStoreAuthorityBackupDhall endpoint region bucket prefix =
  roleStoreTypeDhall
    ++ ".AuthorityBackup { authority_backup_endpoint = "
    ++ renderDhallText endpoint
    ++ ", authority_backup_region = "
    ++ renderDhallText region
    ++ ", authority_backup_bucket = "
    ++ renderDhallText bucket
    ++ ", authority_backup_prefix = "
    ++ renderDhallText prefix
    ++ " }"

roleStoreTlsRetentionDhall
  :: Text.Text
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> String
roleStoreTlsRetentionDhall endpoint region bucket substrate scopeKey prefix =
  roleStoreTypeDhall
    ++ ".TlsRetention { tls_retention_endpoint = "
    ++ renderDhallText endpoint
    ++ ", tls_retention_region = "
    ++ renderDhallText region
    ++ ", tls_retention_bucket = "
    ++ renderDhallText bucket
    ++ ", tls_retention_substrate = "
    ++ renderDhallText substrate
    ++ ", tls_retention_scope_key = "
    ++ renderDhallText scopeKey
    ++ ", tls_retention_prefix = "
    ++ renderDhallText prefix
    ++ " }"

renderDhallText :: Text.Text -> String
renderDhallText = show . Text.unpack

valuesForGateway
  :: Substrate
  -> String
  -> String
  -> ValidatedSettings
  -> Map String String
  -> String
  -> Maybe ResolvedCustomImage
  -> String
  -> String
  -> Text.Text
  -> Either String Value
valuesForGateway substrate namespace rootChart settings _gatewayEventKeys sharedHostFqdn maybeRuntimeImage zoneId gatewayTier0Dhall lifecycleAuthorityScope = do
  -- Sprint 3.18: the per-node event keys and gateway AWS/MinIO credentials
  -- are Vault KV objects rendered into config.dhall as SecretRef.Vault
  -- references. The legacy 'gatewayEventKeys' parameter is vestigial and
  -- arrives empty; the chart no longer reads or writes a k8s Secret for these
  -- fields.
  let config = validatedConfig settings
  runtimeMemoryPlan <-
    Capacity.runtimeMemoryPlanForProfile (capacity config) "gateway"
  -- Sprint 1.89: the region is the parsed coordinate. The `null` test that used
  -- to stand here is gone rather than restated: an 'AwsRegion' has no empty
  -- inhabitant, so "present and well-formed" is the only state this binding can
  -- be in, and "absent" is the refusal below. The companion `null zoneId` test
  -- is gone for the same reason — 'resolveSubstrateHostedZoneId' now refuses on
  -- both substrates, so the string reaching `zoneId` cannot be empty.
  awsRegion <-
    case coordinateOperationalAwsRegion (validatedCoordinates settings) of
      Just region -> Right (Text.unpack (awsRegionText region))
      Nothing -> Left "gateway chart requires aws.region in settings"
  resolvedGatewayImage <-
    case maybeRuntimeImage of
      Just imageInfo -> Right imageInfo
      Nothing -> Left "gateway chart requires a resolved image reference"
  emitterPersistence <-
    EmitterPersistence.emitterPersistenceValues
      substrate
      (map Text.pack (gatewayNodeIdsForSubstrate substrate))
  let gatewayRepository = resolvedCustomImageRepository resolvedGatewayImage
      gatewayTag = resolvedCustomImageTag resolvedGatewayImage
  pure
    ( object
        [ "replicaCount" .= length (gatewayNodeIdsForSubstrate substrate)
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
        , "runtime"
            .= object
              [ "rtsArguments"
                  .= RuntimeMemory.runtimeMemoryRtsArguments runtimeMemoryPlan
              ]
        , -- Sprint 2.34: ports / NodePort / ServiceAccount are projections of
          -- the one compiled 'ChartStatics.gatewayChartStatics', so the deployed
          -- values, the generated @values.yaml@ section, and the hand-written
          -- templates cannot diverge.
          "ports" .= ChartStatics.gatewayChartStaticsPortsValue
        , "nodePort" .= ChartStatics.gatewayChartStaticsNodePortValue
        , "serviceAccount" .= ChartStatics.gatewayChartStaticsServiceAccountValue
        , "externalCallers" .= ChartStatics.gatewayChartStaticsExternalCallersValue
        , "probes" .= GatewayProbe.gatewayLifecycleProbeValues
        , "timing"
            .= object
              [ "heartbeatIntervalSeconds" .= (0.5 :: Double)
              , "reconnectIntervalSeconds" .= (0.5 :: Double)
              , "syncIntervalSeconds" .= (1.0 :: Double)
              , "heartbeatTimeoutSeconds" .= (5 :: Int)
              ]
        , "nodes" .= object ["rankedIds" .= gatewayNodeIdsForSubstrate substrate]
        , -- Sprint 2.32: typed stable-controller, journal-volume, and native
          -- Lease/RBAC inputs. Sprint 3.26 consumes this exact projection when
          -- it renders the physically separated StatefulSet workloads.
          "emitterPersistence" .= emitterPersistence
        , "tier0" .= object ["prodboxDhall" .= gatewayTier0Dhall]
        , "lifecycleAuthority"
            .= object
              [ "scope" .= lifecycleAuthorityScope
              , "endpoint"
                  .= ( "http://lifecycle-authority."
                         ++ namespace
                         ++ ".svc.cluster.local:"
                         ++ show controlPlaneListenPort
                     )
              ]
        , "dnsWriteGate" .= gatewayDnsWriteGateValue substrate zoneId sharedHostFqdn awsRegion
        , "vault"
            .= object
              [ "address" .= ("http://vault.vault.svc.cluster.local:8200" :: String)
              , "authPath" .= ("kubernetes" :: String)
              , -- The shared typed role is bound to both the object-store /
                -- Transit policy and the event-key / AWS / MinIO KV policy in
                -- Vault.Reconcile. Either grant missing here produces a 403.
                -- Sprint 2.34: projected from the one compiled GatewayChartStatics.
                "role" .= ChartStatics.gatewayStaticVaultRole ChartStatics.gatewayChartStatics
              , "serviceAccountTokenFile"
                  .= ("/var/run/secrets/kubernetes.io/serviceaccount/token" :: String)
              , -- Sprint 3.26: the per-node event-key paths are no longer projected
                -- as fixed `eventKeyNode{A,B,C}` values; the gateway config template
                -- derives each peer's `gateway/gateway/<nodeId>/event-key` path
                -- parametrically from `nodes.rankedIds`, so the event-key set is
                -- substrate-variable (2 on home, 3 on AWS) and matches Orders
                -- membership exactly. The Vault inventory still seeds/grants all
                -- node event keys (VaultInventory).
                "paths"
                  .= object
                    [ "aws" .= ("aws/gateway-dns" :: String)
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
  -> String
  -> [String]
  -> ChartReleasePlan
  -> [String]
renderStatusRelease snapshots runtimeNamespace rootChartName directDeps release
  | chartReleasePlanReleaseName release == rootChartName
      || chartReleasePlanReleaseName release `elem` directDeps =
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
  -- The old mismatch probe exported the Target password to the host. The
  -- mismatch state is now structurally removed: Keycloak consumes the same
  -- PGO-adopted pguser Secret that PGO uses for the live role, and Vault is the
  -- one authority for the value inside it (secret_derivation_doctrine.md 5.1).
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
    && chartDeploymentPlanRootChart plan == "vscode"

-- | Install the exact-name Kubernetes capability before restore. Non-forcing
-- server-side apply names the object even on first creation, so
-- @resourceNames@ constrains restore creation. The Target Agent refuses a
-- differing existing Secret before apply. Only the one-shot worker
-- ServiceAccount receives this capability; the standing Agent is coordinator-
-- and metadata-only.
ensurePublicEdgeTlsAgentAccess :: ChartDeploymentPlan -> IO (Either String ())
ensurePublicEdgeTlsAgentAccess plan
  | not (planOwnsPublicEdgeCertificate plan) = pure (Right ())
  | otherwise = do
      roleApplied <- applyManifest role
      case roleApplied of
        Left err -> pure (Left err)
        Right () -> do
          bindingApplied <- applyManifest binding
          case bindingApplied of
            Left err -> pure (Left err)
            Right () -> do
              apiCoordinate <- readKubernetesApiEgressCoordinate
              case apiCoordinate of
                Left err -> pure (Left err)
                Right coordinate -> applyManifest (apiEgress coordinate)
 where
  namespace = chartDeploymentPlanNamespace plan
  roleName :: String
  roleName = "prodbox-public-edge-tls-target-agent"
  targetWorkerServiceAccount = "prodbox-target-secret-worker" :: String
  role =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("Role" :: String)
      , "metadata"
          .= object
            [ "name" .= roleName
            , "namespace" .= namespace
            , "labels" .= object ["app.kubernetes.io/managed-by" .= ("prodbox" :: String)]
            ]
      , "rules"
          .= [ object
                 [ "apiGroups" .= ([""] :: [String])
                 , "resources" .= (["secrets"] :: [String])
                 , "resourceNames" .= [publicEdgeTlsSecretName]
                 , "verbs" .= (["get", "patch"] :: [String])
                 ]
             ]
      ]
  binding =
    object
      [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: String)
      , "kind" .= ("RoleBinding" :: String)
      , "metadata"
          .= object
            [ "name" .= roleName
            , "namespace" .= namespace
            , "labels" .= object ["app.kubernetes.io/managed-by" .= ("prodbox" :: String)]
            ]
      , "subjects"
          .= [ object
                 [ "kind" .= ("ServiceAccount" :: String)
                 , "name" .= targetWorkerServiceAccount
                 , "namespace" .= ("target-secret-agent" :: String)
                 ]
             ]
      , "roleRef"
          .= object
            [ "apiGroup" .= ("rbac.authorization.k8s.io" :: String)
            , "kind" .= ("Role" :: String)
            , "name" .= roleName
            ]
      ]
  apiEgress coordinate =
    object
      [ "apiVersion" .= ("networking.k8s.io/v1" :: String)
      , "kind" .= ("NetworkPolicy" :: String)
      , "metadata"
          .= object
            [ "name" .= ("target-secret-agent-kubernetes-api" :: String)
            , "namespace" .= ("target-secret-agent" :: String)
            , "labels" .= object ["app.kubernetes.io/managed-by" .= ("prodbox" :: String)]
            ]
      , "spec"
          .= object
            [ "podSelector"
                .= object
                  [ "matchLabels"
                      .= object
                        [ "app.kubernetes.io/name"
                            .= ("prodbox-target-secret-worker" :: String)
                        ]
                  ]
            , "policyTypes" .= (["Egress"] :: [String])
            , -- Sprint 3.34: one `ipBlock` per observed endpoint address, and
              -- the observed endpoint port. Both halves come from the same
              -- `endpoints/kubernetes` observation, so the rule matches the
              -- post-DNAT coordinate the CNI evaluates rather than the
              -- pre-DNAT Service coordinate it never sees.
              "egress"
                .= [ object
                       [ "to"
                           .= [ object
                                  [ "ipBlock"
                                      .= object ["cidr" .= (address ++ "/32")]
                                  ]
                              | address <- kubernetesApiEgressAddresses coordinate
                              ]
                       , "ports"
                           .= [ object
                                  [ "protocol" .= ("TCP" :: String)
                                  , "port" .= kubernetesApiEgressPort coordinate
                                  ]
                              ]
                       ]
                   ]
            ]
      ]

-- | Sprint 3.34: the Kubernetes API egress coordinate — the compiled owner of
-- the address and port a NetworkPolicy egress rule must match to admit traffic
-- to the Kubernetes API.
--
-- __Both halves come from one observation, and the layer is the point.__
-- @service\/kubernetes@ reports @10.43.0.1:443@; kube-proxy DNATs that to the
-- endpoint before the CNI evaluates egress, so a policy matching the Service
-- coordinate matches nothing. @endpoints\/kubernetes@ reports the post-DNAT
-- address and port together — the coordinate the policy engine actually sees.
-- Deriving the two halves from one source is what
-- [chaos_hardening_doctrine.md § 24](../../../documents/engineering/chaos_hardening_doctrine.md)
-- requires: an observation has a layer, and observing the wrong layer from a
-- single source fixes the encoder count and not the correctness.
--
-- This is __not__ a restatement of @kubernetes.default.svc.cluster.local:443@
-- in "Prodbox.K8s.InCluster" and "Prodbox.Vault.Reconcile". That is what a
-- client dials and is correct pre-DNAT; this is what a policy engine matches.
-- Collapsing the two breaks the client path.
data KubernetesApiEgressCoordinate = KubernetesApiEgressCoordinate
  { kubernetesApiEgressAddresses :: [String]
  , kubernetesApiEgressPort :: Int
  }
  deriving (Eq, Show)

-- | Sprint 3.34: the charts whose rendered NetworkPolicy carries the Kubernetes
-- API egress coordinate, and therefore the only charts that consume
-- 'readKubernetesApiEgressCoordinate'. Every other chart's `443` egress is
-- public-internet HTTPS to `0.0.0.0/0` — a different coordinate this owner does
-- not speak for.
kubernetesApiEgressChartNames :: [String]
kubernetesApiEgressChartNames = ["bootstrap-broker", "target-secret-agent"]

-- | Sprint 3.34: the values object both charts consume, so the rendered rule is
-- a binding rather than a literal.
kubernetesApiEgressValues :: KubernetesApiEgressCoordinate -> Value
kubernetesApiEgressValues coordinate =
  object
    [ "addresses" .= kubernetesApiEgressAddresses coordinate
    , "port" .= kubernetesApiEgressPort coordinate
    ]

-- | Observe the Kubernetes API egress coordinate from @endpoints/kubernetes@.
readKubernetesApiEgressCoordinate :: IO (Either String KubernetesApiEgressCoordinate)
readKubernetesApiEgressCoordinate = do
  observed <-
    runCaptured
      "kubectl get kubernetes API Endpoints address and port"
      "kubectl"
      [ "get"
      , "endpoints"
      , "kubernetes"
      , "--namespace"
      , "default"
      , "-o"
      , "jsonpath={.subsets[*].addresses[*].ip}|{.subsets[*].ports[*].port}"
      ]
  pure $ do
    output <- observed
    case processExitCode output of
      ExitFailure _ ->
        Left
          ( "kubectl get kubernetes API Endpoints failed: "
              ++ processStderr output
              ++ processStdout output
          )
      ExitSuccess -> parseKubernetesApiEgressCoordinate (processStdout output)

-- | Pure projection of the @endpoints/kubernetes@ jsonpath output into the
-- coordinate. Kept separate from the observation so it is testable without a
-- cluster.
parseKubernetesApiEgressCoordinate :: String -> Either String KubernetesApiEgressCoordinate
parseKubernetesApiEgressCoordinate raw =
  case break (== '|') (trimWhitespace raw) of
    (addressField, '|' : portField) ->
      let addresses = filter (not . null) (words addressField)
          portWords = filter (not . null) (words portField)
       in if null addresses || not (all validIpv4Literal addresses)
            then Left "kubernetes API Endpoints did not report a valid IPv4 address"
            else case nub portWords of
              [solePort]
                | all isDigit solePort && not (null solePort) ->
                    Right
                      KubernetesApiEgressCoordinate
                        { kubernetesApiEgressAddresses = addresses
                        , kubernetesApiEgressPort = read solePort
                        }
              [] -> Left "kubernetes API Endpoints did not report a port"
              _ -> Left "kubernetes API Endpoints reported more than one distinct port"
    _ -> Left "kubernetes API Endpoints observation was not in the expected form"

validIpv4Literal :: String -> Bool
validIpv4Literal value = case splitOnDot value of
  [a, b, c, d] -> all validOctet [a, b, c, d]
  _ -> False
 where
  validOctet octet =
    not (null octet)
      && all isDigit octet
      && case (reads octet :: [(Int, String)]) of
        [(number, "")] -> number >= 0 && number <= 255
        _ -> False
  splitOnDot input = case break (== '.') input of
    (part, []) -> [part]
    (part, _ : rest) -> part : splitOnDot rest

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
    "public-edge cert: retained through the Authority and TLS Retention Adapter."
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
  | otherwise = case chartDeploymentPlanCertScopeSet plan of
      Nothing ->
        pure
          ( Right
              ( PreserveSkippedNoRetentionStore
                  "no canonical certificate scope resolved for the deployment"
              )
          )
      Just scopeSet -> do
        retained <-
          runPublicEdgeTlsWorkflow
            (chartDeploymentPlanRepoRoot plan)
            (chartDeploymentPlanSubstrate plan)
            scopeSet
            (`retainPublicEdgeTlsWorkflow` KeyRotationNotApproved)
        case retained of
          Left err -> pure (Left err)
          Right (TlsWorkflowRetained _) -> pure (Right PreservedToRetentionStore)
          Right TlsWorkflowNothingToRetain -> classifyMissingSource
 where
  classifyMissingSource = do
    observed <-
      readOptionalKubernetesCertificate
        (chartDeploymentPlanNamespace plan)
        publicEdgeTlsCertificateName
    pure $ case observed of
      Left err -> Left err
      Right (Just _) -> Right PreserveDeferredIssuanceInFlight
      Right Nothing -> Right PreserveNothingToRetain

-- | Sprint 8.8: retain the freshly-issued public-edge production cert to the
-- durable TLS workflow the moment it is confirmed ready (called from the
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
        Right _fqdn ->
          case requireSubstrateCertScopeSet settings substrate of
            Left err -> pure (Left err)
            Right scopeSet -> do
              retained <-
                runPublicEdgeTlsWorkflow
                  repoRoot
                  substrate
                  scopeSet
                  (`retainPublicEdgeTlsWorkflow` KeyRotationNotApproved)
              pure $ case retained of
                Left err -> Left err
                Right TlsWorkflowNothingToRetain -> Right PreserveNothingToRetain
                Right (TlsWorkflowRetained _) -> Right PreservedToRetentionStore

restorePublicEdgeTlsSecretAfterNamespaceCreate :: ChartDeploymentPlan -> IO (Either String ())
restorePublicEdgeTlsSecretAfterNamespaceCreate plan
  | not (planOwnsPublicEdgeCertificate plan) = pure (Right ())
  | otherwise = case chartDeploymentPlanCertScopeSet plan of
      Nothing -> pure (Right ())
      Just scopeSet -> do
        trustedNow <- currentTrustedTlsTime
        restored <-
          runPublicEdgeTlsWorkflow
            (chartDeploymentPlanRepoRoot plan)
            (chartDeploymentPlanSubstrate plan)
            scopeSet
            (`restorePublicEdgeTlsWorkflow` trustedNow)
        pure $ case restored of
          Left err -> Left err
          Right TlsWorkflowIssuancePermitted -> Right ()
          Right (TlsWorkflowRestored _) -> Right ()

runPublicEdgeTlsWorkflow
  :: FilePath
  -> Substrate
  -> CertScopeSet
  -> ( TlsRetentionWorkflow IO
       -> IO (Either TlsRetentionWorkflowError value)
     )
  -> IO (Either String value)
runPublicEdgeTlsWorkflow repoRoot substrate scopeSet action = do
  selectedEnvironment <- getEnvironment
  opened <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      (\authentication -> withAuthority authentication selectedEnvironment)
  pure (flattenAuthentication opened)
 where
  withAuthority authentication selectedEnvironment = do
    opened <-
      withLifecycleAuthorityAuthenticatedTransport
        authentication
        (withTlsRetentionAuthority authentication selectedEnvironment)
    pure (flattenAuthentication opened)

  withTlsRetentionAuthority authentication selectedEnvironment authorityTransport =
    case mkTlsRetentionAuthorityClient
      authorityTransport
      (Text.pack (substrateId substrate))
      (renderCertScopeSet scopeSet) of
      Left err -> pure (Left (show err))
      Right authorityClient ->
        withRetainedHome authentication selectedEnvironment authorityClient

  withRetainedHome authentication selectedEnvironment authorityClient = do
    opened <-
      withTargetSecretAgentAuthenticatedTransport authentication $ \homeTransport ->
        let homeAgent = tlsTargetAgentClientWithTransport homeTransport
         in case substrate of
              SubstrateHomeLocal ->
                withAdapter authentication authorityClient homeAgent homeAgent
              SubstrateAws -> do
                selected <-
                  withSelectedTargetSecretAgentAuthenticatedTransport
                    authentication
                    selectedEnvironment
                    ( \selectedTransport ->
                        withAdapter
                          authentication
                          authorityClient
                          homeAgent
                          (tlsTargetAgentClientWithTransport selectedTransport)
                    )
                pure (flattenAuthentication selected)
    pure (flattenAuthentication opened)

  withAdapter authentication authorityClient homeAgent selectedAgent = do
    opened <-
      withTlsRetentionAuthenticatedTransport authentication $ \adapterTransport ->
        first show
          <$> action
            TlsRetentionWorkflow
              { tlsWorkflowAuthority = authorityClient
              , tlsWorkflowAdapter = tlsRetentionClientWithTransport adapterTransport
              , tlsWorkflowRetainedHomeAgent = homeAgent
              , tlsWorkflowSelectedAgent = selectedAgent
              }
    pure (flattenAuthentication opened)

flattenAuthentication
  :: Either LifecycleAuthorityAuthenticationError (Either String value)
  -> Either String value
flattenAuthentication =
  either (Left . renderLifecycleAuthorityAuthenticationError) id

currentTrustedTlsTime :: IO Natural
currentTrustedTlsTime = do
  now <- getPOSIXTime
  pure (fromInteger (max 0 (floor now)))

-- | Read an optional cert-manager @Certificate@ resource as JSON
-- (@Nothing@ when absent). This non-secret resource distinguishes a genuine
-- empty deployment from issuance in flight after the selected Agent reports
-- that the exact TLS Secret is absent.
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
            cleanupDetail <- reconcileFailedReleaseAbsent release
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

-- | Sprint 3.31: what a failed @helm upgrade --install@ does about the release
-- it left behind.
--
-- It used to answer __any__ non-zero exit with @helm uninstall --wait@,
-- fire-and-forget. Two consequences that made that wrong: Helm's
-- @"another operation (install\/upgrade\/rollback) is in progress"@ is the
-- concurrency error, so the recovery deleted the release another writer was
-- mid-install on; and a @--wait --timeout 30m0s@ timeout is indistinguishable
-- from a failure at the exit code, so a healthy-but-slow rollout was answered by
-- deleting a working release.
--
-- It now routes through the shared absence reconciler, which __re-observes__
-- before acting and refuses a release whose decoded status says another writer
-- holds it. The refusal is reported; nothing is destroyed.
reconcileFailedReleaseAbsent :: ChartReleasePlan -> IO String
reconcileFailedReleaseAbsent release =
  case HelmRelease.mkHelmReleaseCoordinate
    (chartReleasePlanReleaseName release)
    (chartReleasePlanNamespace release) of
    Left err ->
      pure ("\nFailed release cleanup diagnostic:\n" ++ show err)
    Right coordinate -> do
      -- `helmUpgradeInstall` runs helm with no working directory, inheriting
      -- the process CWD; "." preserves exactly that for the reconciler.
      outcome <- HelmRelease.reconcileHelmReleaseAbsent "." coordinate
      pure $ case outcome of
        Right HelmRelease.HelmReleaseAlreadyAbsent ->
          "\nFailed release cleanup: the release was already absent."
        Right HelmRelease.HelmReleaseRemovedAndVerified ->
          "\nFailed release cleanup: helm uninstall completed and absence was verified."
        Left (HelmRelease.HelmReleaseWriteRefused refusal) ->
          "\nFailed release cleanup REFUSED: "
            ++ HelmRelease.renderHelmWriteRefusal coordinate refusal
        Left failure ->
          "\nFailed release cleanup diagnostic:\n" ++ show failure

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
