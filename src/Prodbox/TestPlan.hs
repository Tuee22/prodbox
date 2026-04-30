module Prodbox.TestPlan (
    NativeSuitePlan (..),
    NativeValidation (..),
    TestExecutionMode (..),
    TestExecutionPlan (..),
    nativeValidationId,
    testExecutionPlan,
)
where

import Data.List (
    nub,
 )
import Prodbox.CLI.Command (
    IntegrationSuite (..),
    PolicyTier (..),
    TestScope (..),
 )

data NativeValidation
    = ValidationChartsVscode
    | ValidationChartsApi
    | ValidationChartsWebsocket
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

testExecutionPlan :: TestScope -> TestExecutionPlan
testExecutionPlan scope =
    case scope of
        TestAll ->
            nativeExecutionPlan
                "all"
                [ "test:prodbox-unit"
                , "test:prodbox-integration-cli"
                , "test:prodbox-integration-env"
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
                    }
        TestIntegration integrationSuite ->
            case integrationSuite of
                IntegrationAll ->
                    nativeExecutionPlan
                        "integration all"
                        [ "test:prodbox-integration-cli"
                        , "test:prodbox-integration-env"
                        ]
                        NativeSuitePlan
                            { nativeSuiteId = "integration-all"
                            , nativeValidations = canonicalNativeValidations
                            , nativeInitialIntegrationGatePrerequisites = allInitialIntegrationPrerequisites
                            , nativeDeferredIntegrationGatePrerequisites = allDeferredIntegrationPrerequisites
                            , nativeManagedAwsHarnessPolicyTier = Just PolicyFull
                            , nativeRequiresIntegrationRunbook = True
                            , nativeRequiresSupportedRuntimeBootstrap = True
                            , nativeRequiresSupportedRuntimePostflight = True
                            }
                IntegrationCli ->
                    nativeIntegrationPlan
                        "integration cli"
                        ["test:prodbox-integration-cli"]
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
                        ["test:prodbox-integration-env"]
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
                }

    nativeNamedSuite label suiteId validations initialPrerequisites deferredPrerequisites requiresRunbook managedAwsHarnessPolicyTier =
        nativeIntegrationPlan label [] suiteId validations initialPrerequisites deferredPrerequisites requiresRunbook managedAwsHarnessPolicyTier

canonicalNativeValidations :: [NativeValidation]
canonicalNativeValidations =
    [ ValidationChartsVscode
    , ValidationChartsApi
    , ValidationChartsWebsocket
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
    ]

allInitialIntegrationPrerequisites :: [String]
allInitialIntegrationPrerequisites =
    orderedUnion
        [ chartsVscodeInitialPrerequisites
        , chartsApiInitialPrerequisites
        , chartsWebsocketInitialPrerequisites
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
        ]

allDeferredIntegrationPrerequisites :: [String]
allDeferredIntegrationPrerequisites =
    orderedUnion
        [ chartsVscodeDeferredPrerequisites
        , chartsApiDeferredPrerequisites
        , chartsWebsocketDeferredPrerequisites
        , awsEksDeferredPrerequisites
        , pulumiDeferredPrerequisites
        , awsHaRke2DeferredPrerequisites
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

publicDnsPrerequisites :: [String]
publicDnsPrerequisites = ["route53_accessible", "tool_dig"]

dnsAwsPrerequisites :: [String]
dnsAwsPrerequisites = ["route53_accessible"]

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
gatewayDaemonPrerequisites = clusterPrerequisites

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

orderedUnion :: [[String]] -> [String]
orderedUnion = nub . concat
