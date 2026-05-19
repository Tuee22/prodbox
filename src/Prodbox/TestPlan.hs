module Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation (..)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , nativeValidationId
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
import Prodbox.Substrate (Substrate)

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
  | ValidationChartsStorage
  | ValidationLifecycle
  | ValidationKeycloakInvite
  deriving (Eq, Show)

data NativeSuitePlan = NativeSuitePlan
  { nativeSuiteId :: String
  , nativeValidations :: [NativeValidation]
  , nativeInitialIntegrationGatePrerequisites :: [String]
  , nativeDeferredIntegrationGatePrerequisites :: [String]
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

testExecutionPlan :: Substrate -> TestScope -> TestExecutionPlan
testExecutionPlan substrate scope =
  case scope of
    TestAll ->
      nativeExecutionPlan
        "all"
        [ "test:prodbox-unit"
        , "test:prodbox-integration"
        ]
        NativeSuitePlan
          { nativeSuiteId = "all"
          , nativeValidations = canonicalNativeValidations
          , nativeInitialIntegrationGatePrerequisites = allInitialIntegrationPrerequisites
          , nativeDeferredIntegrationGatePrerequisites = allDeferredIntegrationPrerequisites
          , nativeManagedAwsHarnessPolicyTier = Just PolicyFull
          , nativeRequiresIntegrationRunbook = True
          , nativeRequiresSupportedRuntimeBootstrap = True
          , nativeRequiresSupportedRuntimePostflight = True
          , nativeSubstrate = substrate
          }
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
            NativeSuitePlan
              { nativeSuiteId = "integration-all"
              , nativeValidations = canonicalNativeValidations
              , nativeInitialIntegrationGatePrerequisites = allInitialIntegrationPrerequisites
              , nativeDeferredIntegrationGatePrerequisites = allDeferredIntegrationPrerequisites
              , nativeManagedAwsHarnessPolicyTier = Just PolicyFull
              , nativeRequiresIntegrationRunbook = True
              , nativeRequiresSupportedRuntimeBootstrap = True
              , nativeRequiresSupportedRuntimePostflight = True
              , nativeSubstrate = substrate
              }
        IntegrationCli ->
          nativeIntegrationPlan
            "integration cli"
            ["test:prodbox-integration"]
            "integration-cli"
            []
            []
            []
            False
            Nothing
        IntegrationAwsIam ->
          nativeNamedSuite
            "integration aws-iam"
            "integration-aws-iam"
            [ValidationAwsIam]
            awsIamInitialPrerequisites
            []
            False
            (Just PolicyFull)
        IntegrationDnsAws ->
          nativeNamedSuite
            "integration dns-aws"
            "integration-dns-aws"
            [ValidationDnsAws]
            dnsAwsPrerequisites
            []
            False
            Nothing
        IntegrationAwsEks ->
          nativeNamedSuite
            "integration aws-eks"
            "integration-aws-eks"
            [ValidationAwsEks]
            awsEksInitialPrerequisites
            awsEksDeferredPrerequisites
            True
            Nothing
        IntegrationEnv ->
          nativeIntegrationPlan
            "integration env"
            ["test:prodbox-integration"]
            "integration-env"
            []
            []
            []
            False
            Nothing
        IntegrationGatewayDaemon ->
          nativeNamedSuite
            "integration gateway-daemon"
            "integration-gateway-daemon"
            [ValidationGatewayDaemon]
            gatewayDaemonPrerequisites
            []
            True
            Nothing
        IntegrationGatewayPods ->
          nativeNamedSuite
            "integration gateway-pods"
            "integration-gateway-pods"
            [ValidationGatewayPods]
            gatewayPodsPrerequisites
            []
            True
            Nothing
        IntegrationGatewayPartition ->
          nativeNamedSuite
            "integration gateway-partition"
            "integration-gateway-partition"
            [ValidationGatewayPartition]
            gatewayPartitionPrerequisites
            []
            False
            Nothing
        IntegrationHaRke2Aws ->
          nativeNamedSuite
            "integration ha-rke2-aws"
            "integration-ha-rke2-aws"
            [ValidationHaRke2Aws]
            awsHaRke2InitialPrerequisites
            awsHaRke2DeferredPrerequisites
            True
            Nothing
        IntegrationLifecycle ->
          nativeNamedSuite
            "integration lifecycle"
            "integration-lifecycle"
            [ValidationLifecycle]
            lifecyclePrerequisites
            []
            True
            Nothing
        IntegrationPulumi ->
          nativeNamedSuite
            "integration pulumi"
            "integration-pulumi"
            [ValidationPulumi]
            pulumiInitialPrerequisites
            pulumiDeferredPrerequisites
            True
            Nothing
        IntegrationChartsStorage ->
          nativeNamedSuite
            "integration charts-storage"
            "integration-charts-storage"
            [ValidationChartsStorage]
            chartsStoragePrerequisites
            []
            True
            Nothing
        IntegrationChartsPlatform ->
          nativeNamedSuite
            "integration charts-platform"
            "integration-charts-platform"
            [ValidationChartsPlatform]
            chartsPlatformPrerequisites
            []
            True
            Nothing
        IntegrationChartsVscode ->
          nativeExecutionPlan
            "integration charts-vscode"
            []
            NativeSuitePlan
              { nativeSuiteId = "integration-charts-vscode"
              , nativeValidations = [ValidationChartsVscode]
              , nativeInitialIntegrationGatePrerequisites = chartsVscodeInitialPrerequisites
              , nativeDeferredIntegrationGatePrerequisites = chartsVscodeDeferredPrerequisites
              , nativeManagedAwsHarnessPolicyTier = Nothing
              , nativeRequiresIntegrationRunbook = True
              , nativeRequiresSupportedRuntimeBootstrap = True
              , nativeRequiresSupportedRuntimePostflight = False
              , nativeSubstrate = substrate
              }
        IntegrationChartsApi ->
          nativeExecutionPlan
            "integration charts-api"
            []
            NativeSuitePlan
              { nativeSuiteId = "integration-charts-api"
              , nativeValidations = [ValidationChartsApi]
              , nativeInitialIntegrationGatePrerequisites = chartsApiInitialPrerequisites
              , nativeDeferredIntegrationGatePrerequisites = chartsApiDeferredPrerequisites
              , nativeManagedAwsHarnessPolicyTier = Nothing
              , nativeRequiresIntegrationRunbook = True
              , nativeRequiresSupportedRuntimeBootstrap = True
              , nativeRequiresSupportedRuntimePostflight = False
              , nativeSubstrate = substrate
              }
        IntegrationChartsWebsocket ->
          nativeExecutionPlan
            "integration charts-websocket"
            []
            NativeSuitePlan
              { nativeSuiteId = "integration-charts-websocket"
              , nativeValidations = [ValidationChartsWebsocket]
              , nativeInitialIntegrationGatePrerequisites = chartsWebsocketInitialPrerequisites
              , nativeDeferredIntegrationGatePrerequisites = chartsWebsocketDeferredPrerequisites
              , nativeManagedAwsHarnessPolicyTier = Nothing
              , nativeRequiresIntegrationRunbook = True
              , nativeRequiresSupportedRuntimeBootstrap = True
              , nativeRequiresSupportedRuntimePostflight = False
              , nativeSubstrate = substrate
              }
        IntegrationAdminRoutes ->
          nativeExecutionPlan
            "integration admin-routes"
            []
            NativeSuitePlan
              { nativeSuiteId = "integration-admin-routes"
              , nativeValidations = [ValidationAdminRoutes]
              , nativeInitialIntegrationGatePrerequisites = adminRoutesInitialPrerequisites
              , nativeDeferredIntegrationGatePrerequisites = adminRoutesDeferredPrerequisites
              , nativeManagedAwsHarnessPolicyTier = Nothing
              , nativeRequiresIntegrationRunbook = True
              , nativeRequiresSupportedRuntimeBootstrap = True
              , nativeRequiresSupportedRuntimePostflight = False
              , nativeSubstrate = substrate
              }
        IntegrationPublicDns ->
          nativeNamedSuite
            "integration public-dns"
            "integration-public-dns"
            [ValidationPublicDns]
            publicDnsPrerequisites
            []
            False
            Nothing
        IntegrationKeycloakInvite ->
          nativeExecutionPlan
            "integration keycloak-invite"
            []
            NativeSuitePlan
              { nativeSuiteId = "integration-keycloak-invite"
              , nativeValidations = [ValidationKeycloakInvite]
              , nativeInitialIntegrationGatePrerequisites = keycloakInviteInitialPrerequisites
              , nativeDeferredIntegrationGatePrerequisites = keycloakInviteDeferredPrerequisites
              , nativeManagedAwsHarnessPolicyTier = Nothing
              , nativeRequiresIntegrationRunbook = True
              , nativeRequiresSupportedRuntimeBootstrap = True
              , nativeRequiresSupportedRuntimePostflight = False
              , nativeSubstrate = substrate
              }
 where
  nativeIntegrationPlan label haskellSuites suiteId validations initialPrerequisites deferredPrerequisites requiresRunbook managedAwsHarnessPolicyTier =
    nativeExecutionPlan
      label
      haskellSuites
      NativeSuitePlan
        { nativeSuiteId = suiteId
        , nativeValidations = validations
        , nativeInitialIntegrationGatePrerequisites = initialPrerequisites
        , nativeDeferredIntegrationGatePrerequisites = deferredPrerequisites
        , nativeManagedAwsHarnessPolicyTier = managedAwsHarnessPolicyTier
        , nativeRequiresIntegrationRunbook = requiresRunbook
        , nativeRequiresSupportedRuntimeBootstrap = False
        , nativeRequiresSupportedRuntimePostflight = False
        , nativeSubstrate = substrate
        }

  nativeNamedSuite label suiteId validations initialPrerequisites deferredPrerequisites requiresRunbook managedAwsHarnessPolicyTier =
    nativeIntegrationPlan
      label
      []
      suiteId
      validations
      initialPrerequisites
      deferredPrerequisites
      requiresRunbook
      managedAwsHarnessPolicyTier

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
  , ValidationGatewayPods
  , ValidationGatewayPartition
  , ValidationChartsPlatform
  , ValidationChartsStorage
  , ValidationLifecycle
  , ValidationKeycloakInvite
  ]

allInitialIntegrationPrerequisites :: [String]
allInitialIntegrationPrerequisites =
  orderedUnion
    [ chartsVscodeInitialPrerequisites
    , chartsApiInitialPrerequisites
    , chartsWebsocketInitialPrerequisites
    , adminRoutesInitialPrerequisites
    , publicDnsPrerequisites
    , dnsAwsPrerequisites
    , ["aws_iam_harness_ready"]
    , awsIamInitialPrerequisites
    , awsEksInitialPrerequisites
    , pulumiInitialPrerequisites
    , awsHaRke2InitialPrerequisites
    , gatewayDaemonPrerequisites
    , gatewayPodsPrerequisites
    , chartsPlatformPrerequisites
    , chartsStoragePrerequisites
    , lifecyclePrerequisites
    , gatewayPartitionPrerequisites
    , keycloakInviteInitialPrerequisites
    ]

allDeferredIntegrationPrerequisites :: [String]
allDeferredIntegrationPrerequisites =
  orderedUnion
    [ chartsVscodeDeferredPrerequisites
    , chartsApiDeferredPrerequisites
    , chartsWebsocketDeferredPrerequisites
    , adminRoutesDeferredPrerequisites
    , awsEksDeferredPrerequisites
    , pulumiDeferredPrerequisites
    , awsHaRke2DeferredPrerequisites
    , keycloakInviteDeferredPrerequisites
    ]

clusterPrerequisites :: [String]
clusterPrerequisites =
  [ "supported_ubuntu_2404"
  , "tool_docker"
  , "tool_ctr"
  , "tool_helm"
  , "tool_kubectl"
  , "tool_sudo"
  , "tool_systemctl"
  , "settings_object"
  ]

chartsVscodeInitialPrerequisites :: [String]
chartsVscodeInitialPrerequisites = orderedUnion [pulumiInitialPrerequisites, ["tool_curl"]]

chartsVscodeDeferredPrerequisites :: [String]
chartsVscodeDeferredPrerequisites = pulumiDeferredPrerequisites

chartsApiInitialPrerequisites :: [String]
chartsApiInitialPrerequisites = orderedUnion [pulumiInitialPrerequisites, ["tool_curl"]]

chartsApiDeferredPrerequisites :: [String]
chartsApiDeferredPrerequisites = pulumiDeferredPrerequisites

chartsWebsocketInitialPrerequisites :: [String]
chartsWebsocketInitialPrerequisites = orderedUnion [pulumiInitialPrerequisites, ["tool_curl"]]

chartsWebsocketDeferredPrerequisites :: [String]
chartsWebsocketDeferredPrerequisites = pulumiDeferredPrerequisites

adminRoutesInitialPrerequisites :: [String]
adminRoutesInitialPrerequisites = orderedUnion [pulumiInitialPrerequisites, ["tool_curl"]]

adminRoutesDeferredPrerequisites :: [String]
adminRoutesDeferredPrerequisites = pulumiDeferredPrerequisites

publicDnsPrerequisites :: [String]
publicDnsPrerequisites = ["route53_lifecycle_capable", "tool_dig"]

dnsAwsPrerequisites :: [String]
dnsAwsPrerequisites = ["route53_lifecycle_capable"]

pulumiInitialPrerequisites :: [String]
pulumiInitialPrerequisites = orderedUnion [clusterPrerequisites, ["aws_credentials_valid", "tool_pulumi"]]

pulumiDeferredPrerequisites :: [String]
pulumiDeferredPrerequisites = ["pulumi_logged_in"]

awsIamInitialPrerequisites :: [String]
awsIamInitialPrerequisites = ["aws_iam_harness_ready", "tool_aws"]

awsEksInitialPrerequisites :: [String]
awsEksInitialPrerequisites = pulumiInitialPrerequisites

awsEksDeferredPrerequisites :: [String]
awsEksDeferredPrerequisites = pulumiDeferredPrerequisites

awsHaRke2InitialPrerequisites :: [String]
awsHaRke2InitialPrerequisites = orderedUnion [pulumiInitialPrerequisites, ["tool_ssh"]]

awsHaRke2DeferredPrerequisites :: [String]
awsHaRke2DeferredPrerequisites = pulumiDeferredPrerequisites

gatewayDaemonPrerequisites :: [String]
gatewayDaemonPrerequisites = orderedUnion [clusterPrerequisites, ["tool_curl"]]

gatewayPodsPrerequisites :: [String]
gatewayPodsPrerequisites = clusterPrerequisites

gatewayPartitionPrerequisites :: [String]
gatewayPartitionPrerequisites = []

chartsPlatformPrerequisites :: [String]
chartsPlatformPrerequisites = clusterPrerequisites

chartsStoragePrerequisites :: [String]
chartsStoragePrerequisites = clusterPrerequisites

lifecyclePrerequisites :: [String]
lifecyclePrerequisites = clusterPrerequisites

keycloakInviteInitialPrerequisites :: [String]
keycloakInviteInitialPrerequisites =
  orderedUnion
    [ chartsVscodeInitialPrerequisites
    , ["aws_credentials_valid", "route53_accessible", "tool_curl"]
    ]

keycloakInviteDeferredPrerequisites :: [String]
keycloakInviteDeferredPrerequisites =
  orderedUnion
    [ pulumiDeferredPrerequisites
    , ["ses_sending_identity_verified", "ses_receive_rule_set_active", "ses_receive_bucket_accessible"]
    ]

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
    ValidationChartsStorage -> "charts-storage"
    ValidationLifecycle -> "lifecycle"
    ValidationKeycloakInvite -> "keycloak-invite"

orderedUnion :: [[String]] -> [String]
orderedUnion = nub . concat
