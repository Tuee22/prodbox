module Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation (..)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , nativeValidationId
  , retainedSesRequirementForValidations
  , validationInitialPrerequisites
  , validationDeferredPrerequisites
  , derivedManagedAwsHarnessPolicyTier
  , testExecutionPlan
  )
where

import Data.List
  ( nub
  )
import Prodbox.CLI.Command
  ( IntegrationSuite (..)
  , PolicyTier (..)
  , TestScope (..)
  )
import Prodbox.PrerequisiteId
  ( PrerequisiteId (..)
  , prerequisiteIdEngagesIamHarness
  )
import Prodbox.Substrate (Substrate (..))
import Prodbox.TestRestore
  ( RetainedSesRequirement (..)
  )

data NativeValidation
  = ValidationChartsVscode
  | ValidationChartsApi
  | ValidationChartsWebsocket
  | ValidationAdminRoutes
  | ValidationPublicDns
  | ValidationDnsAws
  | ValidationAwsIam
  | ValidationAwsEks
  | ValidationPulumi
  | ValidationHaRke2Aws
  | ValidationGatewayDaemon
  | ValidationGatewayPods
  | ValidationGatewayPartition
  | ValidationChartsPlatform
  | ValidationResourceGuardrails
  | ValidationDaemonBootstrap
  | ValidationPulsarBroker
  | ValidationChartsStorage
  | ValidationEksVolumeRebind
  | ValidationLifecycle
  | ValidationKeycloakInvite
  | ValidationSealedVault
  deriving (Eq, Show)

data NativeSuitePlan = NativeSuitePlan
  { nativeSuiteId :: String
  , nativeValidations :: [NativeValidation]
  , nativeInitialIntegrationGatePrerequisites :: [PrerequisiteId]
  , nativeDeferredIntegrationGatePrerequisites :: [PrerequisiteId]
  , nativeManagedAwsHarnessPolicyTier :: Maybe PolicyTier
  , nativeRequiresIntegrationRunbook :: Bool
  , nativeRequiresSupportedRuntimeBootstrap :: Bool
  , nativeRequiresSupportedRuntimePostflight :: Bool
  , nativeSubstrate :: Substrate
  }
  deriving (Eq, Show)

data TestExecutionMode
  = DelegatedSuite [String]
  | NativeSuite NativeSuitePlan
  deriving (Eq, Show)

data TestExecutionPlan = TestExecutionPlan
  { testPlanLabel :: String
  , testPlanHaskellSuites :: [String]
  , testPlanExecutionMode :: TestExecutionMode
  }
  deriving (Eq, Show)

-- | Derive retained SES preparation from the selected validation capability
-- alone.  Membership makes duplicate invite selections naturally idempotent;
-- bootstrap flags and substrate choice cannot affect this result.
retainedSesRequirementForValidations :: [NativeValidation] -> RetainedSesRequirement
retainedSesRequirementForValidations validations
  | ValidationKeycloakInvite `elem` validations = SesRequired
  | otherwise = SesNotRequired

testExecutionPlan :: Substrate -> TestScope -> TestExecutionPlan
testExecutionPlan substrate scope =
  case scope of
    TestInit _ ->
      nativeExecutionPlan
        "init"
        []
        NativeSuitePlan
          { nativeSuiteId = "init"
          , nativeValidations = []
          , nativeInitialIntegrationGatePrerequisites = []
          , nativeDeferredIntegrationGatePrerequisites = []
          , nativeManagedAwsHarnessPolicyTier = Nothing
          , nativeRequiresIntegrationRunbook = False
          , nativeRequiresSupportedRuntimeBootstrap = False
          , nativeRequiresSupportedRuntimePostflight = False
          , nativeSubstrate = substrate
          }
    TestRun suiteName ->
      nativeExecutionPlan
        ("run " ++ suiteName)
        []
        NativeSuitePlan
          { nativeSuiteId = "run-" ++ suiteName
          , nativeValidations = []
          , nativeInitialIntegrationGatePrerequisites = []
          , nativeDeferredIntegrationGatePrerequisites = []
          , nativeManagedAwsHarnessPolicyTier = Nothing
          , nativeRequiresIntegrationRunbook = False
          , nativeRequiresSupportedRuntimeBootstrap = False
          , nativeRequiresSupportedRuntimePostflight = False
          , nativeSubstrate = substrate
          }
    TestAll ->
      nativeExecutionPlan
        "all"
        [ "test:prodbox-unit"
        , "test:prodbox-integration"
        ]
        ( canonicalSuitePlan
            "all"
            canonicalNativeValidations
            True
            True
            True
        )
    TestLint ->
      nativeExecutionPlan
        "lint"
        []
        NativeSuitePlan
          { nativeSuiteId = "lint"
          , nativeValidations = []
          , nativeInitialIntegrationGatePrerequisites = []
          , nativeDeferredIntegrationGatePrerequisites = []
          , nativeManagedAwsHarnessPolicyTier = Nothing
          , nativeRequiresIntegrationRunbook = False
          , nativeRequiresSupportedRuntimeBootstrap = False
          , nativeRequiresSupportedRuntimePostflight = False
          , nativeSubstrate = substrate
          }
    TestUnit ->
      nativeExecutionPlan
        "unit"
        ["test:prodbox-unit"]
        NativeSuitePlan
          { nativeSuiteId = "unit"
          , nativeValidations = []
          , nativeInitialIntegrationGatePrerequisites = []
          , nativeDeferredIntegrationGatePrerequisites = []
          , nativeManagedAwsHarnessPolicyTier = Nothing
          , nativeRequiresIntegrationRunbook = False
          , nativeRequiresSupportedRuntimeBootstrap = False
          , nativeRequiresSupportedRuntimePostflight = False
          , nativeSubstrate = substrate
          }
    TestIntegration integrationSuite ->
      case integrationSuite of
        IntegrationAll ->
          nativeExecutionPlan
            "integration all"
            ["test:prodbox-integration"]
            ( canonicalSuitePlan
                "integration-all"
                canonicalNativeValidations
                True
                True
                True
            )
        IntegrationCli ->
          nativeIntegrationPlan
            "integration cli"
            ["test:prodbox-integration"]
            "integration-cli"
            []
            False
        IntegrationAwsIam ->
          nativeNamedSuite
            "integration aws-iam"
            "integration-aws-iam"
            [ValidationAwsIam]
            False
        IntegrationDnsAws ->
          nativeNamedSuite
            "integration dns-aws"
            "integration-dns-aws"
            [ValidationDnsAws]
            False
        IntegrationAwsEks ->
          nativeNamedSuite
            "integration aws-eks"
            "integration-aws-eks"
            [ValidationAwsEks]
            True
        IntegrationEnv ->
          nativeIntegrationPlan
            "integration env"
            ["test:prodbox-integration"]
            "integration-env"
            []
            False
        IntegrationGatewayDaemon ->
          nativeNamedSuite
            "integration gateway-daemon"
            "integration-gateway-daemon"
            [ValidationGatewayDaemon]
            True
        IntegrationGatewayPods ->
          nativeNamedSuite
            "integration gateway-pods"
            "integration-gateway-pods"
            [ValidationGatewayPods]
            True
        IntegrationGatewayPartition ->
          nativeNamedSuite
            "integration gateway-partition"
            "integration-gateway-partition"
            [ValidationGatewayPartition]
            False
        IntegrationHaRke2Aws ->
          nativeNamedSuite
            "integration ha-rke2-aws"
            "integration-ha-rke2-aws"
            [ValidationHaRke2Aws]
            True
        IntegrationLifecycle ->
          nativeNamedSuite
            "integration lifecycle"
            "integration-lifecycle"
            [ValidationLifecycle]
            True
        IntegrationPulumi ->
          nativeNamedSuite
            "integration pulumi"
            "integration-pulumi"
            [ValidationPulumi]
            True
        IntegrationEksVolumeRebind ->
          nativeNamedSuite
            "integration eks-volume-rebind"
            "integration-eks-volume-rebind"
            [ValidationEksVolumeRebind]
            True
        IntegrationChartsStorage ->
          nativeNamedSuite
            "integration charts-storage"
            "integration-charts-storage"
            [ValidationChartsStorage]
            True
        IntegrationChartsPlatform ->
          nativeNamedSuite
            "integration charts-platform"
            "integration-charts-platform"
            [ValidationChartsPlatform]
            True
        IntegrationResourceGuardrails ->
          nativeNamedSuite
            "integration resource-guardrails"
            "integration-resource-guardrails"
            [ValidationResourceGuardrails]
            True
        IntegrationDaemonBootstrap ->
          nativeNamedSuite
            "integration daemon-bootstrap"
            "integration-daemon-bootstrap"
            [ValidationDaemonBootstrap]
            False
        IntegrationPulsarBroker ->
          nativeNamedSuite
            "integration pulsar-broker"
            "integration-pulsar-broker"
            [ValidationPulsarBroker]
            False
        IntegrationChartsVscode ->
          nativeExecutionPlan
            "integration charts-vscode"
            []
            (chartsValidationPlan "integration-charts-vscode" ValidationChartsVscode)
        IntegrationChartsApi ->
          nativeExecutionPlan
            "integration charts-api"
            []
            (chartsValidationPlan "integration-charts-api" ValidationChartsApi)
        IntegrationChartsWebsocket ->
          nativeExecutionPlan
            "integration charts-websocket"
            []
            (chartsValidationPlan "integration-charts-websocket" ValidationChartsWebsocket)
        IntegrationAdminRoutes ->
          nativeExecutionPlan
            "integration admin-routes"
            []
            (chartsValidationPlan "integration-admin-routes" ValidationAdminRoutes)
        IntegrationPublicDns ->
          nativeNamedSuite
            "integration public-dns"
            "integration-public-dns"
            [ValidationPublicDns]
            False
        IntegrationKeycloakInvite ->
          nativeExecutionPlan
            "integration keycloak-invite"
            []
            ( ( chartsValidationPlan
                  "integration-keycloak-invite"
                  ValidationKeycloakInvite
              )
                { nativeRequiresIntegrationRunbook = True
                , nativeRequiresSupportedRuntimeBootstrap = True
                , nativeRequiresSupportedRuntimePostflight = False
                }
            )
        IntegrationSealedVault ->
          nativeNamedSuite
            "integration sealed-vault"
            "integration-sealed-vault"
            [ValidationSealedVault]
            True
 where
  -- \| The canonical aggregate suites ('all', 'integration-all'): the full
  -- ordered validation set, with the gate prerequisites and the
  -- IAM-harness tier DERIVED from the per-validation typed sets.
  canonicalSuitePlan suiteId validations requiresRunbook requiresBootstrap requiresPostflight =
    let initialPrerequisites = aggregateInitialPrerequisites validations
        deferredPrerequisites = aggregateDeferredPrerequisites validations
     in NativeSuitePlan
          { nativeSuiteId = suiteId
          , nativeValidations = validations
          , nativeInitialIntegrationGatePrerequisites = initialPrerequisites
          , nativeDeferredIntegrationGatePrerequisites = deferredPrerequisites
          , nativeManagedAwsHarnessPolicyTier =
              derivedTier substrate validations
          , nativeRequiresIntegrationRunbook = requiresRunbook
          , nativeRequiresSupportedRuntimeBootstrap = requiresBootstrap
          , nativeRequiresSupportedRuntimePostflight = requiresPostflight
          , nativeSubstrate = substrate
          }

  -- \| A single charts-family validation plan (the AWS-credential-free
  -- public-edge-readiness validations + keycloak-invite). The gate
  -- prerequisites and tier are derived from the validation's typed set.
  chartsValidationPlan suiteId validation =
    NativeSuitePlan
      { nativeSuiteId = suiteId
      , nativeValidations = [validation]
      , nativeInitialIntegrationGatePrerequisites = validationInitialPrerequisites validation
      , nativeDeferredIntegrationGatePrerequisites = validationDeferredPrerequisites validation
      , nativeManagedAwsHarnessPolicyTier = derivedTier substrate [validation]
      , nativeRequiresIntegrationRunbook = True
      , nativeRequiresSupportedRuntimeBootstrap = True
      , nativeRequiresSupportedRuntimePostflight = False
      , nativeSubstrate = substrate
      }

  nativeIntegrationPlan label haskellSuites suiteId validations requiresRunbook =
    nativeExecutionPlan
      label
      haskellSuites
      NativeSuitePlan
        { nativeSuiteId = suiteId
        , nativeValidations = validations
        , nativeInitialIntegrationGatePrerequisites = aggregateInitialPrerequisites validations
        , nativeDeferredIntegrationGatePrerequisites = aggregateDeferredPrerequisites validations
        , nativeManagedAwsHarnessPolicyTier = derivedTier substrate validations
        , nativeRequiresIntegrationRunbook = requiresRunbook
        , nativeRequiresSupportedRuntimeBootstrap = False
        , nativeRequiresSupportedRuntimePostflight = False
        , nativeSubstrate = substrate
        }

  nativeNamedSuite label suiteId validations requiresRunbook =
    nativeIntegrationPlan
      label
      []
      suiteId
      validations
      requiresRunbook

canonicalNativeValidations :: [NativeValidation]
canonicalNativeValidations =
  [ ValidationChartsVscode
  , ValidationChartsApi
  , ValidationChartsWebsocket
  , ValidationAdminRoutes
  , ValidationPublicDns
  , ValidationDnsAws
  , ValidationAwsIam
  , ValidationAwsEks
  , ValidationPulumi
  , ValidationHaRke2Aws
  , ValidationGatewayDaemon
  , ValidationGatewayPartition
  , ValidationChartsPlatform
  , ValidationResourceGuardrails
  , ValidationDaemonBootstrap
  , ValidationPulsarBroker
  , ValidationKeycloakInvite
  , ValidationChartsStorage
  , ValidationEksVolumeRebind
  , ValidationSealedVault
  , ValidationLifecycle
  , ValidationGatewayPods
  ]

-- | Sprint 5.6: the per-validation initial-gate prerequisites, typed and
-- minimal-and-precise — each validation declares exactly the typed
-- prerequisites it actually consumes, with no over-broad inherited
-- bundle. Exhaustively matched ('PrerequisiteId' is an ADT), so adding a
-- validation forces declaring its prerequisite set.
validationInitialPrerequisites :: NativeValidation -> [PrerequisiteId]
validationInitialPrerequisites validation =
  case validation of
    -- The public-edge-readiness validations gate on the declared
    -- AWS-credential-free 'PublicEdgeReady' node (Sprint 5.6 split out of
    -- 'infra_ready'), plus 'tool_curl' for their real HTTPS / WebSocket
    -- probes. They no longer inherit cluster + AWS-credential bundles.
    ValidationChartsVscode -> [PublicEdgeReady, ToolCurl]
    ValidationChartsApi -> [PublicEdgeReady, ToolCurl]
    ValidationChartsWebsocket -> [PublicEdgeReady, ToolCurl]
    ValidationAdminRoutes -> [PublicEdgeReady, ToolCurl]
    -- public-dns proves NS delegation + FQDN resolution: Route 53
    -- lifecycle capability + dig.
    ValidationPublicDns -> [Route53LifecycleCapable, ToolDig]
    -- dns-aws exercises the Route 53 hosted-zone lifecycle API.
    ValidationDnsAws -> [Route53LifecycleCapable]
    -- aws-iam exercises the IAM-user provisioning loop via the harness.
    ValidationAwsIam -> [AwsIamHarnessReady, ToolAws]
    -- The Pulumi-substrate stacks consume validated AWS credentials +
    -- the cluster (the MinIO Pulumi backend lives in-cluster) + pulumi.
    ValidationAwsEks -> pulumiSubstratePrerequisites
    ValidationPulumi -> pulumiSubstratePrerequisites
    ValidationHaRke2Aws -> pulumiSubstratePrerequisites ++ [ToolSsh]
    -- gateway-daemon runs the daemon locally and probes /healthz: cluster
    -- + curl.
    ValidationGatewayDaemon -> clusterPrerequisites ++ [ToolCurl]
    -- gateway-pods inspects in-cluster pods: cluster only.
    ValidationGatewayPods -> clusterPrerequisites
    -- gateway-partition is fully in-process: no prerequisites.
    ValidationGatewayPartition -> []
    -- The chart-platform / storage / lifecycle validations operate on the
    -- local cluster: cluster only, no AWS credentials.
    ValidationChartsPlatform -> clusterPrerequisites
    ValidationResourceGuardrails -> clusterPrerequisites
    -- daemon-bootstrap is a code-owned transport oracle: live daemon and
    -- object-store parity are separate substrate proof axes.
    ValidationDaemonBootstrap -> []
    ValidationPulsarBroker -> clusterPrerequisites
    ValidationChartsStorage -> clusterPrerequisites
    ValidationEksVolumeRebind -> clusterPrerequisites
    ValidationLifecycle -> clusterPrerequisites
    ValidationSealedVault -> clusterPrerequisites
    -- keycloak-invite drives the full invite flow end-to-end: the
    -- public-edge readiness gate + curl, plus AWS credentials + Route 53
    -- for the SES capture-bucket poll.
    ValidationKeycloakInvite ->
      [PublicEdgeReady, ToolCurl, AwsCredentialsValid, Route53Accessible]

-- | Sprint 5.6: the per-validation deferred-gate prerequisites (probes
-- that run after substrate provisioning), typed and minimal.
validationDeferredPrerequisites :: NativeValidation -> [PrerequisiteId]
validationDeferredPrerequisites validation =
  case validation of
    ValidationChartsVscode -> []
    ValidationChartsApi -> []
    ValidationChartsWebsocket -> []
    ValidationAdminRoutes -> []
    ValidationPublicDns -> []
    ValidationDnsAws -> []
    ValidationAwsIam -> []
    ValidationAwsEks -> [PulumiLoggedIn]
    ValidationPulumi -> [PulumiLoggedIn]
    ValidationHaRke2Aws -> [PulumiLoggedIn]
    ValidationGatewayDaemon -> []
    ValidationGatewayPods -> []
    ValidationGatewayPartition -> []
    ValidationChartsPlatform -> []
    ValidationResourceGuardrails -> []
    ValidationDaemonBootstrap -> []
    ValidationPulsarBroker -> []
    ValidationChartsStorage -> []
    ValidationEksVolumeRebind -> []
    ValidationLifecycle -> []
    ValidationSealedVault -> []
    ValidationKeycloakInvite ->
      [ SesSendingIdentityVerified
      , SesReceiveRuleSetActive
      , SesReceiveBucketAccessible
      ]

-- | Sprint 5.6: derive the managed AWS IAM harness tier from declared
-- capabilities, replacing the deleted @normalizeManagedAwsHarness@
-- @substrate=aws@ blanket override. A validation set engages the harness
-- (tier 'PolicyFull') exactly when it is run on the AWS substrate AND at
-- least one declared prerequisite (initial or deferred) needs live AWS
-- credentials ('prerequisiteIdEngagesIamHarness'), OR when it is the
-- IAM-harness validation itself ('aws-iam') or the invite flow
-- ('keycloak-invite'), which always materialize operational credentials
-- via the harness regardless of substrate. A credential-free validation
-- (e.g. @gateway-partition@) never acquires the harness merely because the
-- active substrate is AWS.
derivedManagedAwsHarnessPolicyTier :: Substrate -> [NativeValidation] -> Maybe PolicyTier
derivedManagedAwsHarnessPolicyTier = derivedTier

derivedTier :: Substrate -> [NativeValidation] -> Maybe PolicyTier
derivedTier substrate validations
  | any alwaysEngagesHarness validations = Just PolicyFull
  | substrate == SubstrateAws && any requiresAwsSubstrateHarness validations = Just PolicyFull
  | substrate == SubstrateAws && any engagesViaCredentials validations = Just PolicyFull
  | otherwise = Nothing
 where
  -- Validations whose body itself materializes operational credentials
  -- through the harness on every substrate.
  alwaysEngagesHarness validation =
    case validation of
      ValidationAwsIam -> True
      ValidationKeycloakInvite -> True
      _ -> False

  -- The EKS volume-rebind validation mutates the AWS per-run EKS stack
  -- directly on the AWS substrate, but the same validation remains
  -- AWS-credential-free on the home substrate.
  requiresAwsSubstrateHarness validation =
    case validation of
      ValidationEksVolumeRebind -> True
      _ -> False

  -- Validations that consume live AWS credentials via a declared
  -- prerequisite; on the AWS substrate those credentials are materialized
  -- by the harness from @aws_admin_for_test_simulation.*@.
  engagesViaCredentials validation =
    any
      prerequisiteIdEngagesIamHarness
      ( validationInitialPrerequisites validation
          ++ validationDeferredPrerequisites validation
      )

aggregateInitialPrerequisites :: [NativeValidation] -> [PrerequisiteId]
aggregateInitialPrerequisites =
  orderedUnion . map validationInitialPrerequisites

aggregateDeferredPrerequisites :: [NativeValidation] -> [PrerequisiteId]
aggregateDeferredPrerequisites =
  orderedUnion . map validationDeferredPrerequisites

-- | The cluster-readiness prerequisite bundle the cluster-backed
-- validations consume (tools + settings the local cluster path needs).
-- AWS-credential-free.
clusterPrerequisites :: [PrerequisiteId]
clusterPrerequisites =
  [ HostSubstrateSupported
  , ToolDocker
  , ToolCtr
  , ToolHelm
  , ToolKubectl
  , ToolSudo
  , ToolSystemctl
  , SettingsObject
  ]

-- | The Pulumi-substrate prerequisite bundle the AWS Pulumi stacks
-- consume: the cluster (the MinIO Pulumi state backend lives in-cluster)
-- plus validated AWS credentials and the pulumi CLI.
pulumiSubstratePrerequisites :: [PrerequisiteId]
pulumiSubstratePrerequisites =
  clusterPrerequisites ++ [AwsCredentialsValid, ToolPulumi]

nativeExecutionPlan :: String -> [String] -> NativeSuitePlan -> TestExecutionPlan
nativeExecutionPlan label haskellSuites suitePlan =
  TestExecutionPlan
    { testPlanLabel = label
    , testPlanHaskellSuites = haskellSuites
    , testPlanExecutionMode = NativeSuite suitePlan
    }

nativeValidationId :: NativeValidation -> String
nativeValidationId validation =
  case validation of
    ValidationChartsVscode -> "charts-vscode"
    ValidationChartsApi -> "charts-api"
    ValidationChartsWebsocket -> "charts-websocket"
    ValidationAdminRoutes -> "admin-routes"
    ValidationPublicDns -> "public-dns"
    ValidationDnsAws -> "dns-aws"
    ValidationAwsIam -> "aws-iam"
    ValidationAwsEks -> "aws-eks"
    ValidationPulumi -> "pulumi"
    ValidationHaRke2Aws -> "ha-rke2-aws"
    ValidationGatewayDaemon -> "gateway-daemon"
    ValidationGatewayPods -> "gateway-pods"
    ValidationGatewayPartition -> "gateway-partition"
    ValidationChartsPlatform -> "charts-platform"
    ValidationResourceGuardrails -> "resource-guardrails"
    ValidationDaemonBootstrap -> "daemon-bootstrap"
    ValidationPulsarBroker -> "pulsar-broker"
    ValidationChartsStorage -> "charts-storage"
    ValidationEksVolumeRebind -> "eks-volume-rebind"
    ValidationLifecycle -> "lifecycle"
    ValidationKeycloakInvite -> "keycloak-invite"
    ValidationSealedVault -> "sealed-vault"

orderedUnion :: [[PrerequisiteId]] -> [PrerequisiteId]
orderedUnion = nub . concat
