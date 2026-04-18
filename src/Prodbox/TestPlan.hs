module Prodbox.TestPlan
    ( NativeSuitePlan (..),
      PytestInvocation (..),
      TestExecutionMode (..),
      TestExecutionPlan (..),
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

data PytestInvocation = PytestInvocation
    { pytestInvocationId :: String,
      pytestInvocationArgs :: [String]
    }
    deriving (Eq, Show)

data NativeSuitePlan = NativeSuitePlan
    { nativeSuiteId :: String,
      nativePytestInvocations :: [PytestInvocation],
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
                      nativePytestInvocations = unitPytestInvocation : canonicalIntegrationAllPytestInvocations,
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
                      nativePytestInvocations = [unitPytestInvocation],
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
                              nativePytestInvocations = canonicalIntegrationAllPytestInvocations,
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
                        [pytestInvocation "integration-cli" ["tests/integration/test_cli_commands.py"]]
                        []
                        False
                IntegrationAwsIam ->
                    nativeNamedSuite
                        "integration aws-iam"
                        "integration-aws-iam"
                        [pytestInvocation "integration-aws-iam" ["tests/integration/test_aws_iam_lifecycle.py"]]
                        awsIamPrerequisites
                        False
                IntegrationDnsAws ->
                    nativeNamedSuite
                        "integration dns-aws"
                        "integration-dns-aws"
                        [pytestInvocation "integration-dns-aws" ["tests/integration/test_dns_route53_aws.py"]]
                        dnsAwsPrerequisites
                        False
                IntegrationAwsEks ->
                    nativeNamedSuite
                        "integration aws-eks"
                        "integration-aws-eks"
                        [pytestInvocation "integration-aws-eks" ["tests/integration/test_aws_eks.py"]]
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
                        [pytestInvocation "integration-gateway-daemon" ["tests/integration/test_gateway_daemon_k8s.py"]]
                        clusterPrerequisites
                        True
                IntegrationGatewayPods ->
                    nativeNamedSuite
                        "integration gateway-pods"
                        "integration-gateway-pods"
                        [pytestInvocation "integration-gateway-pods" ["tests/integration/test_gateway_k8s_pods.py"]]
                        clusterPrerequisites
                        True
                IntegrationGatewayPartition ->
                    nativeNamedSuite
                        "integration gateway-partition"
                        "integration-gateway-partition"
                        [pytestInvocation "integration-gateway-partition" ["tests/integration/test_gateway_partition.py"]]
                        clusterPrerequisites
                        True
                IntegrationHaRke2Aws ->
                    nativeNamedSuite
                        "integration ha-rke2-aws"
                        "integration-ha-rke2-aws"
                        [pytestInvocation "integration-ha-rke2-aws" ["tests/integration/test_ha_rke2_aws.py"]]
                        awsHaRke2Prerequisites
                        True
                IntegrationLifecycle ->
                    nativeNamedSuite
                        "integration lifecycle"
                        "integration-lifecycle"
                        [pytestInvocation "integration-lifecycle" ["tests/integration/test_prodbox_lifecycle.py"]]
                        clusterPrerequisites
                        True
                IntegrationPulumi ->
                    nativeNamedSuite
                        "integration pulumi"
                        "integration-pulumi"
                        [pytestInvocation "integration-pulumi" ["tests/integration/test_pulumi_real.py"]]
                        pulumiPrerequisites
                        True
                IntegrationChartsStorage ->
                    nativeNamedSuite
                        "integration charts-storage"
                        "integration-charts-storage"
                        [pytestInvocation "integration-charts-storage" ["tests/integration/test_charts_storage.py"]]
                        clusterPrerequisites
                        True
                IntegrationChartsPlatform ->
                    nativeNamedSuite
                        "integration charts-platform"
                        "integration-charts-platform"
                        [pytestInvocation "integration-charts-platform" ["tests/integration/test_charts_platform.py"]]
                        clusterPrerequisites
                        True
                IntegrationChartsVscode ->
                    nativeNamedSuite
                        "integration charts-vscode"
                        "integration-charts-vscode"
                        [pytestInvocation "integration-charts-vscode" ["tests/integration/test_charts_vscode.py"]]
                        []
                        False
                IntegrationPublicDns ->
                    nativeNamedSuite
                        "integration public-dns"
                        "integration-public-dns"
                        [pytestInvocation "integration-public-dns" ["tests/integration/test_public_dns_delegation.py"]]
                        []
                        False
  where
    nativeIntegrationPlan label haskellSuites suiteId pytestInvocations prerequisites requiresRunbook =
        nativeExecutionPlan
            label
            haskellSuites
            NativeSuitePlan
                { nativeSuiteId = suiteId,
                  nativePytestInvocations = pytestInvocations,
                  nativeIntegrationGatePrerequisites = prerequisites,
                  nativeRequiresIntegrationRunbook = requiresRunbook,
                  nativeRequiresSupportedRuntimeBootstrap = False,
                  nativeRequiresSupportedRuntimePostflight = False
                }

    nativeNamedSuite label suiteId pytestInvocations prerequisites requiresRunbook =
        nativeIntegrationPlan label [] suiteId pytestInvocations prerequisites requiresRunbook

unitPytestInvocation :: PytestInvocation
unitPytestInvocation = pytestInvocation "unit" ["tests/unit"]

canonicalIntegrationAllPytestInvocations :: [PytestInvocation]
canonicalIntegrationAllPytestInvocations =
    [ pytestInvocation "charts-vscode" ["tests/integration/test_charts_vscode.py"],
      pytestInvocation "public-dns" ["tests/integration/test_public_dns_delegation.py"],
      pytestInvocation "cli" ["tests/integration/test_cli_commands.py"],
      pytestInvocation "dns-aws" ["tests/integration/test_dns_route53_aws.py"],
      pytestInvocation "aws-eks" ["tests/integration/test_aws_eks.py"],
      pytestInvocation "pulumi" ["tests/integration/test_pulumi_real.py"],
      pytestInvocation "ha-rke2-aws" ["tests/integration/test_ha_rke2_aws.py"],
      pytestInvocation "gateway-daemon" ["tests/integration/test_gateway_daemon_k8s.py"],
      pytestInvocation "gateway-pods" ["tests/integration/test_gateway_k8s_pods.py"],
      pytestInvocation "gateway-partition" ["tests/integration/test_gateway_partition.py"],
      pytestInvocation "charts-platform" ["tests/integration/test_charts_platform.py"],
      pytestInvocation "charts-storage" ["tests/integration/test_charts_storage.py"],
      pytestInvocation "lifecycle" ["tests/integration/test_prodbox_lifecycle.py"],
      pytestInvocation "aws-iam" ["tests/integration/test_aws_iam_lifecycle.py"]
    ]

allIntegrationPrerequisites :: [String]
allIntegrationPrerequisites =
    orderedUnion
        [ clusterPrerequisites,
          dnsAwsPrerequisites,
          awsIamPrerequisites,
          pulumiPrerequisites,
          awsHaRke2Prerequisites,
          awsEksPrerequisites
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

dnsAwsPrerequisites :: [String]
dnsAwsPrerequisites = ["tool_aws"]

pulumiPrerequisites :: [String]
pulumiPrerequisites = orderedUnion [clusterPrerequisites, ["tool_pulumi", "tool_aws"]]

awsIamPrerequisites :: [String]
awsIamPrerequisites = ["tool_aws", "tool_dhall_to_json", "settings_object"]

awsEksPrerequisites :: [String]
awsEksPrerequisites = pulumiPrerequisites

awsHaRke2Prerequisites :: [String]
awsHaRke2Prerequisites = orderedUnion [pulumiPrerequisites, ["tool_ssh"]]

nativeExecutionPlan :: String -> [String] -> NativeSuitePlan -> TestExecutionPlan
nativeExecutionPlan label haskellSuites suitePlan =
    TestExecutionPlan
        { testPlanLabel = label,
          testPlanHaskellSuites = haskellSuites,
          testPlanExecutionMode = NativeSuite suitePlan
        }

pytestInvocation :: String -> [String] -> PytestInvocation
pytestInvocation invocationId invocationArgs =
    PytestInvocation
        { pytestInvocationId = invocationId,
          pytestInvocationArgs = invocationArgs
        }

orderedUnion :: [[String]] -> [String]
orderedUnion = nub . concat
