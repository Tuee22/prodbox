module Prodbox.TestPlan
    ( NativeSuitePlan (..),
      NativeValidation (..),
      TestExecutionMode (..),
      TestExecutionPlan (..),
      nativeValidationId,
      testExecutionPlan,
    )
where

import Data.List
    ( nub,
    )
import Prodbox.CLI.Command
    ( IntegrationSuite (..),
      TestScope (..),
    )

data NativeValidation
    = ValidationChartsVscode
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
    { nativeSuiteId :: String,
      nativeValidations :: [NativeValidation],
      nativeIntegrationGatePrerequisites :: [String],
      nativeRequiresIntegrationRunbook :: Bool,
      nativeRequiresSupportedRuntimeBootstrap :: Bool,
      nativeRequiresSupportedRuntimePostflight :: Bool
    }
    deriving (Eq, Show)

data TestExecutionMode
    = DelegatedSuite [String]
    | NativeSuite NativeSuitePlan
    deriving (Eq, Show)

data TestExecutionPlan = TestExecutionPlan
    { testPlanLabel :: String,
      testPlanHaskellSuites :: [String],
      testPlanExecutionMode :: TestExecutionMode
    }
    deriving (Eq, Show)

testExecutionPlan :: TestScope -> TestExecutionPlan
testExecutionPlan scope =
    case scope of
        TestAll ->
            nativeExecutionPlan
                "all"
                [ "test:prodbox-unit",
                  "test:prodbox-integration-cli",
                  "test:prodbox-integration-env"
                ]
                NativeSuitePlan
                    { nativeSuiteId = "all",
                      nativeValidations = canonicalNativeValidations,
                      nativeIntegrationGatePrerequisites = allIntegrationPrerequisites,
                      nativeRequiresIntegrationRunbook = True,
                      nativeRequiresSupportedRuntimeBootstrap = True,
                      nativeRequiresSupportedRuntimePostflight = True
                    }
        TestUnit ->
            nativeExecutionPlan
                "unit"
                ["test:prodbox-unit"]
                NativeSuitePlan
                    { nativeSuiteId = "unit",
                      nativeValidations = [],
                      nativeIntegrationGatePrerequisites = [],
                      nativeRequiresIntegrationRunbook = False,
                      nativeRequiresSupportedRuntimeBootstrap = False,
                      nativeRequiresSupportedRuntimePostflight = False
                    }
        TestIntegration integrationSuite ->
            case integrationSuite of
                IntegrationAll ->
                    nativeExecutionPlan
                        "integration all"
                        [ "test:prodbox-integration-cli",
                          "test:prodbox-integration-env"
                        ]
                        NativeSuitePlan
                            { nativeSuiteId = "integration-all",
                              nativeValidations = canonicalNativeValidations,
                              nativeIntegrationGatePrerequisites = allIntegrationPrerequisites,
                              nativeRequiresIntegrationRunbook = True,
                              nativeRequiresSupportedRuntimeBootstrap = True,
                              nativeRequiresSupportedRuntimePostflight = True
                            }
                IntegrationCli ->
                    nativeIntegrationPlan
                        "integration cli"
                        ["test:prodbox-integration-cli"]
                        "integration-cli"
                        []
                        []
                        False
                IntegrationAwsIam ->
                    nativeNamedSuite
                        "integration aws-iam"
                        "integration-aws-iam"
                        [ValidationAwsIam]
                        awsIamPrerequisites
                        False
                IntegrationDnsAws ->
                    nativeNamedSuite
                        "integration dns-aws"
                        "integration-dns-aws"
                        [ValidationDnsAws]
                        dnsAwsPrerequisites
                        False
                IntegrationAwsEks ->
                    nativeNamedSuite
                        "integration aws-eks"
                        "integration-aws-eks"
                        [ValidationAwsEks]
                        awsEksPrerequisites
                        True
                IntegrationEnv ->
                    nativeIntegrationPlan
                        "integration env"
                        ["test:prodbox-integration-env"]
                        "integration-env"
                        []
                        []
                        False
                IntegrationGatewayDaemon ->
                    nativeNamedSuite
                        "integration gateway-daemon"
                        "integration-gateway-daemon"
                        [ValidationGatewayDaemon]
                        gatewayDaemonPrerequisites
                        True
                IntegrationGatewayPods ->
                    nativeNamedSuite
                        "integration gateway-pods"
                        "integration-gateway-pods"
                        [ValidationGatewayPods]
                        gatewayPodsPrerequisites
                        True
                IntegrationGatewayPartition ->
                    nativeNamedSuite
                        "integration gateway-partition"
                        "integration-gateway-partition"
                        [ValidationGatewayPartition]
                        gatewayPartitionPrerequisites
                        False
                IntegrationHaRke2Aws ->
                    nativeNamedSuite
                        "integration ha-rke2-aws"
                        "integration-ha-rke2-aws"
                        [ValidationHaRke2Aws]
                        awsHaRke2Prerequisites
                        True
                IntegrationLifecycle ->
                    nativeNamedSuite
                        "integration lifecycle"
                        "integration-lifecycle"
                        [ValidationLifecycle]
                        lifecyclePrerequisites
                        True
                IntegrationPulumi ->
                    nativeNamedSuite
                        "integration pulumi"
                        "integration-pulumi"
                        [ValidationPulumi]
                        pulumiPrerequisites
                        True
                IntegrationChartsStorage ->
                    nativeNamedSuite
                        "integration charts-storage"
                        "integration-charts-storage"
                        [ValidationChartsStorage]
                        chartsStoragePrerequisites
                        True
                IntegrationChartsPlatform ->
                    nativeNamedSuite
                        "integration charts-platform"
                        "integration-charts-platform"
                        [ValidationChartsPlatform]
                        chartsPlatformPrerequisites
                        True
                IntegrationChartsVscode ->
                    nativeExecutionPlan
                        "integration charts-vscode"
                        []
                        NativeSuitePlan
                            { nativeSuiteId = "integration-charts-vscode",
                              nativeValidations = [ValidationChartsVscode],
                              nativeIntegrationGatePrerequisites = chartsVscodePrerequisites,
                              nativeRequiresIntegrationRunbook = True,
                              nativeRequiresSupportedRuntimeBootstrap = True,
                              nativeRequiresSupportedRuntimePostflight = False
                            }
                IntegrationPublicDns ->
                    nativeNamedSuite
                        "integration public-dns"
                        "integration-public-dns"
                        [ValidationPublicDns]
                        publicDnsPrerequisites
                        False
  where
    nativeIntegrationPlan label haskellSuites suiteId validations prerequisites requiresRunbook =
        nativeExecutionPlan
            label
            haskellSuites
            NativeSuitePlan
                { nativeSuiteId = suiteId,
                  nativeValidations = validations,
                  nativeIntegrationGatePrerequisites = prerequisites,
                  nativeRequiresIntegrationRunbook = requiresRunbook,
                  nativeRequiresSupportedRuntimeBootstrap = False,
                  nativeRequiresSupportedRuntimePostflight = False
                }

    nativeNamedSuite label suiteId validations prerequisites requiresRunbook =
        nativeIntegrationPlan label [] suiteId validations prerequisites requiresRunbook

canonicalNativeValidations :: [NativeValidation]
canonicalNativeValidations =
    [ ValidationChartsVscode,
      ValidationPublicDns,
      ValidationDnsAws,
      ValidationAwsIam,
      ValidationAwsEks,
      ValidationPulumi,
      ValidationHaRke2Aws,
      ValidationGatewayDaemon,
      ValidationGatewayPods,
      ValidationGatewayPartition,
      ValidationChartsPlatform,
      ValidationChartsStorage,
      ValidationLifecycle
    ]

allIntegrationPrerequisites :: [String]
allIntegrationPrerequisites =
    orderedUnion
        [ chartsVscodePrerequisites,
          publicDnsPrerequisites,
          dnsAwsPrerequisites,
          awsIamPrerequisites,
          awsEksPrerequisites,
          pulumiPrerequisites,
          awsHaRke2Prerequisites,
          gatewayDaemonPrerequisites,
          gatewayPodsPrerequisites,
          chartsPlatformPrerequisites,
          chartsStoragePrerequisites,
          lifecyclePrerequisites,
          gatewayPartitionPrerequisites
        ]

clusterPrerequisites :: [String]
clusterPrerequisites =
    [ "supported_ubuntu_2404",
      "tool_docker",
      "tool_ctr",
      "tool_helm",
      "tool_kubectl",
      "tool_sudo",
      "tool_systemctl",
      "settings_object"
    ]

chartsVscodePrerequisites :: [String]
chartsVscodePrerequisites = orderedUnion [pulumiPrerequisites, ["tool_curl"]]

publicDnsPrerequisites :: [String]
publicDnsPrerequisites = ["settings_object", "tool_aws", "tool_dig"]

dnsAwsPrerequisites :: [String]
dnsAwsPrerequisites = ["settings_object", "tool_aws"]

pulumiPrerequisites :: [String]
pulumiPrerequisites = orderedUnion [clusterPrerequisites, ["tool_pulumi", "tool_aws"]]

awsIamPrerequisites :: [String]
awsIamPrerequisites = ["tool_aws", "settings_object"]

awsEksPrerequisites :: [String]
awsEksPrerequisites = pulumiPrerequisites

awsHaRke2Prerequisites :: [String]
awsHaRke2Prerequisites = orderedUnion [pulumiPrerequisites, ["tool_ssh"]]

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
        { testPlanLabel = label,
          testPlanHaskellSuites = haskellSuites,
          testPlanExecutionMode = NativeSuite suitePlan
        }

nativeValidationId :: NativeValidation -> String
nativeValidationId validation =
    case validation of
        ValidationChartsVscode -> "charts-vscode"
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
