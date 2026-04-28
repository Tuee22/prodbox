{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (finally)
import Data.Aeson (
    Value (..),
    eitherDecode,
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (
    sort,
 )
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Vector qualified as Vector
import Options.Applicative (
    ParserResult (..),
    defaultPrefs,
    execParserPure,
    renderFailure,
 )
import Prodbox.Aws (
    buildIamPolicyDocument,
 )
import Prodbox.AwsEnvironment (
    isolatedAwsEnvironment,
    overlayAwsCredentials,
 )
import Prodbox.CLI.Command (
    AwsCommand (..),
    ChartsCommand (..),
    CommandRequest (..),
    ConfigCommand (..),
    CoverageFlags (..),
    DnsCommand (..),
    GatewayCommand (..),
    HostCommand (..),
    IntegrationSuite (..),
    K8sCommand (..),
    NativeCommand (..),
    PolicyTier (..),
    PulumiCommand (..),
    Rke2Command (..),
    TestCommand (..),
    TestScope (..),
 )
import Prodbox.CLI.Parser (
    Options (..),
    parserInfo,
 )
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Effect (
    Effect (..),
    Validation (..),
 )
import Prodbox.EffectDAG (
    EffectNode (..),
    transitiveClosureIds,
 )
import Prodbox.Gateway (
    renderGatewayConfigTemplate,
    renderGatewayStatusReport,
 )
import Prodbox.Host (
    PortStatus (..),
    renderPortAvailabilityReport,
 )
import Prodbox.Infra.AwsTestStack qualified as AwsTest
import Prodbox.Infra.MinioBackend (
    parseDeletedMinioExportHostPath,
 )
import Prodbox.K8s (
    parseKubectlObjectNames,
 )
import Prodbox.Lib.ChartPlatform (
    ChartDeploymentPlan (..),
    ChartReleasePlan (..),
    buildChartDeletePlan,
    buildChartDeploymentPlan,
    mergeChartSecretValues,
    resolveChartSecrets,
    supportedChartNames,
 )
import Prodbox.Lib.Storage (
    ChartStorageBinding (..),
    ChartStorageSpec (..),
    storageBinding,
 )
import Prodbox.Prerequisite (
    prerequisiteRegistry,
 )
import Prodbox.Settings (
    ConfigFile (..),
    Credentials (..),
    DeploymentSection (..),
    DomainSection (..),
    Route53Section (..),
    StorageSection (..),
    ValidatedSettings (..),
    defaultConfigFile,
    renderSettingsDisplay,
    validateAndLoadSettings,
 )
import Prodbox.SupportedRuntime (
    removeDeletePendingAwsResources,
    removeFqdnFromHostsText,
 )
import Prodbox.TestPlan (
    NativeSuitePlan (..),
    NativeValidation (..),
    TestExecutionMode (..),
    TestExecutionPlan (..),
    nativeValidationId,
    testExecutionPlan,
 )
import Prodbox.TestValidation (
    verifyAwsTestSshReachability,
 )
import System.Directory (
    Permissions (..),
    createDirectoryIfMissing,
    doesFileExist,
    getCurrentDirectory,
    getPermissions,
    setPermissions,
 )
import System.Environment (
    lookupEnv,
    setEnv,
    unsetEnv,
 )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "CLI parser" $ do
        it "routes config show to the native Haskell command" $ do
            parseArgs ["config", "show", "--show-secrets"]
                `shouldBe` Right (Options False (RunNative (NativeConfig (ConfigShow True))))

        it "routes native host commands through the Haskell runtime" $ do
            parseArgs ["host", "info"]
                `shouldBe` Right (Options False (RunNative (NativeHost HostInfo)))

        it "routes host public-edge through the native Haskell runtime" $ do
            parseArgs ["host", "public-edge"]
                `shouldBe` Right (Options False (RunNative (NativeHost HostPublicEdge)))

        it "routes dns check through the native Haskell runtime" $ do
            parseArgs ["dns", "check"]
                `shouldBe` Right (Options False (RunNative (NativeDns DnsCheck)))

        it "routes gateway status through the native Haskell runtime" $ do
            parseArgs ["gateway", "status", "/tmp/gateway.json"]
                `shouldBe` Right (Options False (RunNative (NativeGateway (GatewayStatus "/tmp/gateway.json"))))

        it "routes gateway start through the native Haskell runtime" $ do
            parseArgs ["gateway", "start", "/tmp/gateway.json"]
                `shouldBe` Right (Options False (RunNative (NativeGateway (GatewayStart "/tmp/gateway.json"))))

        it "routes gateway config-gen through the native Haskell runtime" $ do
            parseArgs ["gateway", "config-gen", "/tmp/gateway.json", "--node-id", "node-a"]
                `shouldBe` Right (Options False (RunNative (NativeGateway (GatewayConfigGen "/tmp/gateway.json" "node-a"))))

        it "routes config setup to the native Haskell runtime" $ do
            parseArgs ["config", "setup"]
                `shouldBe` Right (Options False (RunNative (NativeConfig ConfigSetup)))

        it "routes aws policy to the native Haskell runtime" $ do
            parseArgs ["aws", "policy", "--tier", "full"]
                `shouldBe` Right (Options False (RunNative (NativeAws (AwsPolicy PolicyFull))))

        it "routes aws setup to the native Haskell runtime" $ do
            parseArgs ["aws", "setup", "--tier", "full"]
                `shouldBe` Right (Options False (RunNative (NativeAws (AwsSetup PolicyFull))))

        it "routes aws teardown to the native Haskell runtime" $ do
            parseArgs ["aws", "teardown"]
                `shouldBe` Right (Options False (RunNative (NativeAws AwsTeardown)))

        it "routes aws check-quotas to the native Haskell runtime" $ do
            parseArgs ["aws", "check-quotas"]
                `shouldBe` Right (Options False (RunNative (NativeAws AwsCheckQuotas)))

        it "routes aws request-quotas to the native Haskell runtime" $ do
            parseArgs ["aws", "request-quotas", "--tier", "core"]
                `shouldBe` Right (Options False (RunNative (NativeAws (AwsRequestQuotas PolicyCore))))

        it "routes tla-check through the native Haskell runtime" $ do
            parseArgs ["tla-check"]
                `shouldBe` Right (Options False (RunNative NativeTlaCheck))

        it "routes rke2 commands through the native Haskell runtime" $ do
            parseArgs ["rke2", "delete", "--yes"]
                `shouldBe` Right (Options False (RunNative (NativeRke2 (Rke2Delete True))))

        it "routes pulumi commands through the native Haskell runtime" $ do
            parseArgs ["pulumi", "test-resources"]
                `shouldBe` Right (Options False (RunNative (NativePulumi PulumiTestResources)))

            parseArgs ["pulumi", "eks-destroy", "--yes"]
                `shouldBe` Right (Options False (RunNative (NativePulumi (PulumiEksDestroy True))))

        it "routes charts commands through the native Haskell runtime" $ do
            parseArgs ["charts", "delete", "gateway", "--yes"]
                `shouldBe` Right
                    ( Options
                        False
                        (RunNative (NativeCharts (ChartsDelete "gateway" True)))
                    )

        it "routes native k8s commands through the Haskell runtime with defaults" $ do
            parseArgs ["k8s", "logs"]
                `shouldBe` Right
                    ( Options
                        False
                        ( RunNative
                            ( NativeK8s
                                ( K8sLogs
                                    ["metallb-system", "traefik-system", "cert-manager", "postgres-operator"]
                                    10
                                )
                            )
                        )
                    )

        it "parses native test-suite ownership with coverage flags" $ do
            parseArgs ["test", "integration", "cli", "--coverage", "--cov-fail-under", "90"]
                `shouldBe` Right
                    ( Options
                        False
                        ( RunNative
                            ( NativeTest
                                ( TestCommand
                                    (TestIntegration IntegrationCli)
                                    (CoverageFlags True (Just 90))
                                )
                            )
                        )
                    )

        it "renders the full AWS policy with EKS lifecycle statements" $ do
            case buildIamPolicyDocument PolicyFull of
                Object payload -> do
                    case KeyMap.lookup (Key.fromString "Statement") payload of
                        Just (Array statements) -> do
                            let sids =
                                    [ sid
                                    | Object statement <- Vector.toList statements
                                    , Just (String sid) <- [KeyMap.lookup (Key.fromString "Sid") statement]
                                    ]
                            sids `shouldContain` ["Ec2HaTestStackLifecycle", "IamEksRoleLifecycle", "EksTestStackLifecycle"]
                        _ -> expectationFailure "expected Statement array"
                _ -> expectationFailure "expected policy document object"

    describe "frontend scaffold doctrine" $ do
        it "keeps the Phase 1.1 Haskell frontend scaffold in the repository" $ do
            repoRoot <- getCurrentDirectory
            scaffoldExists <-
                mapM
                    (doesFileExist . (repoRoot </>))
                    [ "app/prodbox/Main.hs"
                    , "src/Prodbox/CLI/Parser.hs"
                    , "src/Prodbox/Gateway/Daemon.hs"
                    , "prodbox.cabal"
                    , "cabal.project"
                    , "docker/prodbox.Dockerfile"
                    , "test/integration/env/Main.hs"
                    ]

            scaffoldExists `shouldBe` replicate 7 True

        it "keeps cabal.project minimal for nix-style builds" $ do
            repoRoot <- getCurrentDirectory
            cabalProject <- readFile (repoRoot </> "cabal.project")

            cabalProject `shouldContain` "packages: ."
            cabalProject `shouldContain` "with-compiler: ghc-9.14.1"
            cabalProject `shouldContain` "allow-newer: *:base, *:template-haskell"
            cabalProject `shouldNotContain` "builddir:"

        it "builds the container frontend under /opt/build" $ do
            repoRoot <- getCurrentDirectory
            dockerfile <- readFile (repoRoot </> "docker" </> "prodbox.Dockerfile")

            dockerfile `shouldContain` "# syntax=docker/dockerfile:1.7"
            dockerfile `shouldContain` "FROM ubuntu:24.04"
            dockerfile `shouldContain` "ARG GHC_VERSION=9.14.1"
            dockerfile `shouldContain` "ARG CABAL_VERSION=3.16.1.0"
            dockerfile `shouldContain` "WORKDIR /opt/build"
            dockerfile `shouldContain` "BOOTSTRAP_HASKELL_MINIMAL=1"
            dockerfile `shouldContain` "ghcup install ghc \"${GHC_VERSION}\""
            dockerfile `shouldContain` "ghcup install cabal \"${CABAL_VERSION}\""
            dockerfile `shouldNotContain` "--mount=type=bind,from=haskell-toolchain"
            dockerfile `shouldContain` "cabal build --builddir=.build exe:prodbox"
            dockerfile `shouldContain` "cabal list-bin --builddir=.build exe:prodbox"

        it "keeps the Haskell quality gate on repo-owned formatter and lint inputs" $ do
            repoRoot <- getCurrentDirectory
            checkCode <- readFile (repoRoot </> "src" </> "Prodbox" </> "CheckCode.hs")
            fourmoluConfig <- readFile (repoRoot </> "fourmolu.toml")
            hlintConfig <- readFile (repoRoot </> ".hlint.yaml")
            editorConfig <- readFile (repoRoot </> ".editorconfig")

            checkCode `shouldContain` "fourmolu"
            checkCode `shouldContain` "hlint"
            checkCode `shouldContain` "--ghc-options=-Werror"
            fourmoluConfig `shouldContain` "indentation = 2"
            fourmoluConfig `shouldContain` "column-limit = 100"
            hlintConfig `shouldContain` "--cpp-simple"
            editorConfig `shouldContain` "indent_style = space"
            editorConfig `shouldContain` "indent_size = 2"

        it "keeps the gateway chart on repo-rootless startup with env-based AWS auth" $ do
            repoRoot <- getCurrentDirectory
            deploymentTemplate <- readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "deployments.yaml")
            awsSecretTemplate <- readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "secret-aws-credentials.yaml")

            deploymentTemplate `shouldContain` "name: AWS_ACCESS_KEY_ID"
            deploymentTemplate `shouldContain` "name: gateway-aws-credentials"
            deploymentTemplate `shouldContain` "scheme: HTTP"
            deploymentTemplate `shouldNotContain` "scheme: HTTPS"
            deploymentTemplate `shouldNotContain` "/app/prodbox-config.json"
            awsSecretTemplate `shouldContain` "name: gateway-aws-credentials"
            awsSecretTemplate `shouldNotContain` "prodbox-config.json"

        it "renders retained PostgreSQL credential secrets before the Percona cluster resource" $ do
            repoRoot <- getCurrentDirectory
            secretsTemplate <- readFile (repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "00-secrets.yaml")
            postgresTemplate <- readFile (repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "postgresql.yaml")

            secretsTemplate `shouldContain` "kind: Secret"
            secretsTemplate `shouldContain` ".Values.secrets.application.name"
            secretsTemplate `shouldContain` ".Values.secrets.superuser.name"
            secretsTemplate `shouldContain` ".Values.secrets.standby.name"
            secretsTemplate `shouldContain` "postgres-operator.crunchydata.com/cluster"
            secretsTemplate `shouldNotContain` "application: spilo"
            postgresTemplate `shouldContain` "kind: PerconaPGCluster"
            postgresTemplate `shouldContain` "apiVersion: pgv2.percona.com/v2"

        it "gates Keycloak liveness behind a startup probe during cold restores" $ do
            repoRoot <- getCurrentDirectory
            deploymentTemplate <- readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "deployment.yaml")

            deploymentTemplate `shouldContain` "progressDeadlineSeconds: 1800"
            deploymentTemplate `shouldContain` "startupProbe:"
            deploymentTemplate `shouldContain` "path: {{ printf \"%s/health/ready\" .Values.keycloak.relativePath }}"
            deploymentTemplate `shouldContain` "failureThreshold: 60"

        it "keeps the gateway image on the single-stage ubuntu doctrine" $ do
            repoRoot <- getCurrentDirectory
            dockerfile <- readFile (repoRoot </> "docker" </> "gateway.Dockerfile")

            dockerfile `shouldContain` "# syntax=docker/dockerfile:1.7"
            dockerfile `shouldContain` "FROM ubuntu:24.04"
            dockerfile `shouldContain` "ARG GHC_VERSION=9.14.1"
            dockerfile `shouldContain` "ARG CABAL_VERSION=3.16.1.0"
            dockerfile `shouldContain` "awscli.amazonaws.com"
            dockerfile `shouldContain` "TARGETARCH"
            dockerfile `shouldContain` "BOOTSTRAP_HASKELL_MINIMAL=1"
            dockerfile `shouldContain` "ghcup install ghc \"${GHC_VERSION}\""
            dockerfile `shouldContain` "ghcup install cabal \"${CABAL_VERSION}\""
            dockerfile `shouldNotContain` "--mount=type=bind,from=haskell-toolchain"
            dockerfile `shouldContain` "ENTRYPOINT [\"/usr/bin/tini\", \"--\", \"/usr/local/bin/prodbox\", \"gateway\", \"start\"]"

        it "keeps AWS validation Pulumi YAML stacks on explicit stack config inputs" $ do
            repoRoot <- getCurrentDirectory
            awsEksMain <- readFile (repoRoot </> "pulumi" </> "aws-eks" </> "Main.yaml")
            awsTestMain <- readFile (repoRoot </> "pulumi" </> "aws-test" </> "Main.yaml")
            pulumiCli <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Pulumi.hs")
            awsEksInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsEksTestStack.hs")
            awsTestInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs")

            doesFileExist (repoRoot </> "pulumi" </> "home" </> "Main.yaml") `shouldReturn` False
            pulumiCli `shouldNotContain` "PulumiUp"
            pulumiCli `shouldNotContain` "PulumiRefresh"
            awsEksMain `shouldContain` "operatorCidr:"
            awsEksMain `shouldContain` "type: string"
            awsEksMain `shouldNotContain` "std:getenv"
            awsEksInfra `shouldContain` "\"config\", \"set\", \"--stack\", awsEksTestStackName"
            awsTestMain `shouldContain` "operatorCidr:"
            awsTestMain `shouldContain` "publicKey:"
            awsTestMain `shouldContain` "type: string"
            awsTestMain `shouldNotContain` "std:getenv"
            awsTestInfra `shouldContain` "\"config\", \"set\", \"--stack\", awsTestStackName"

        it "treats IAM NoSuchEntity as successful absence during EKS destroy residue checks" $ do
            repoRoot <- getCurrentDirectory
            awsEksInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsEksTestStack.hs")

            awsEksInfra `shouldContain` "\"nosuchentity\""

        it "treats terminated EC2 instances as absent during AWS test destroy residue checks" $ do
            repoRoot <- getCurrentDirectory
            awsTestInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs")

            awsTestInfra `shouldContain` "instanceDescribeShowsActiveInstance"
            awsTestInfra `shouldContain` "\"terminated\""
            awsTestInfra `shouldContain` "Just _ -> finalizeDestroy repoRoot currentSnapshot"

    describe "test planning" $ do
        it "maps aggregate all to the native ordered validation workflow" $ do
            case testExecutionPlan TestAll of
                testPlan -> do
                    testPlanLabel testPlan `shouldBe` "all"
                    testPlanHaskellSuites testPlan
                        `shouldBe` [ "test:prodbox-unit"
                                   , "test:prodbox-integration-cli"
                                   , "test:prodbox-integration-env"
                                   ]
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "all"
                            nativeInitialIntegrationGatePrerequisites suitePlan
                                `shouldBe` [ "supported_ubuntu_2404"
                                           , "tool_docker"
                                           , "tool_ctr"
                                           , "tool_helm"
                                           , "tool_kubectl"
                                           , "tool_sudo"
                                           , "tool_systemctl"
                                           , "settings_object"
                                           , "aws_credentials_valid"
                                           , "tool_pulumi"
                                           , "tool_curl"
                                           , "route53_accessible"
                                           , "tool_dig"
                                           , "aws_iam_harness_ready"
                                           , "tool_aws"
                                           , "tool_ssh"
                                           ]
                            nativeDeferredIntegrationGatePrerequisites suitePlan
                                `shouldBe` ["pulumi_logged_in"]
                            nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
                            nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
                            nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
                            nativeRequiresSupportedRuntimePostflight suitePlan `shouldBe` True
                            map nativeValidationId (nativeValidations suitePlan)
                                `shouldBe` [ "charts-vscode"
                                           , "public-dns"
                                           , "dns-aws"
                                           , "aws-iam"
                                           , "aws-eks"
                                           , "pulumi"
                                           , "ha-rke2-aws"
                                           , "gateway-daemon"
                                           , "gateway-pods"
                                           , "gateway-partition"
                                           , "charts-platform"
                                           , "charts-storage"
                                           , "lifecycle"
                                           ]
                        DelegatedSuite _ -> expectationFailure "expected native aggregate test plan"

        it "keeps integration-all in the canonical external-proof-first order" $ do
            case testExecutionPlan (TestIntegration IntegrationAll) of
                testPlan ->
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "integration-all"
                            nativeInitialIntegrationGatePrerequisites suitePlan
                                `shouldBe` [ "supported_ubuntu_2404"
                                           , "tool_docker"
                                           , "tool_ctr"
                                           , "tool_helm"
                                           , "tool_kubectl"
                                           , "tool_sudo"
                                           , "tool_systemctl"
                                           , "settings_object"
                                           , "aws_credentials_valid"
                                           , "tool_pulumi"
                                           , "tool_curl"
                                           , "route53_accessible"
                                           , "tool_dig"
                                           , "aws_iam_harness_ready"
                                           , "tool_aws"
                                           , "tool_ssh"
                                           ]
                            nativeDeferredIntegrationGatePrerequisites suitePlan
                                `shouldBe` ["pulumi_logged_in"]
                            nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
                            nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
                            nativeRequiresSupportedRuntimePostflight suitePlan `shouldBe` True
                            take 2 (map nativeValidationId (nativeValidations suitePlan))
                                `shouldBe` ["charts-vscode", "public-dns"]
                            last (nativeValidations suitePlan) `shouldBe` ValidationLifecycle
                        DelegatedSuite _ -> expectationFailure "expected native integration-all plan"

        it "maps cluster-backed named suites to native validations plus prerequisites" $ do
            case testExecutionPlan (TestIntegration IntegrationAwsEks) of
                testPlan ->
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "integration-aws-eks"
                            nativeValidations suitePlan `shouldBe` [ValidationAwsEks]
                            nativeInitialIntegrationGatePrerequisites suitePlan
                                `shouldBe` [ "supported_ubuntu_2404"
                                           , "tool_docker"
                                           , "tool_ctr"
                                           , "tool_helm"
                                           , "tool_kubectl"
                                           , "tool_sudo"
                                           , "tool_systemctl"
                                           , "settings_object"
                                           , "aws_credentials_valid"
                                           , "tool_pulumi"
                                           ]
                            nativeDeferredIntegrationGatePrerequisites suitePlan
                                `shouldBe` ["pulumi_logged_in"]
                            nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
                        DelegatedSuite _ -> expectationFailure "expected native aws-eks plan"

        it "gates AWS-backed named suites on validated access before validation bodies run" $ do
            case testExecutionPlan (TestIntegration IntegrationPublicDns) of
                testPlan ->
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeInitialIntegrationGatePrerequisites suitePlan
                                `shouldBe` ["route53_accessible", "tool_dig"]
                            nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
                        DelegatedSuite _ -> expectationFailure "expected native public-dns plan"

            case testExecutionPlan (TestIntegration IntegrationDnsAws) of
                testPlan ->
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeInitialIntegrationGatePrerequisites suitePlan
                                `shouldBe` ["route53_accessible"]
                            nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
                        DelegatedSuite _ -> expectationFailure "expected native dns-aws plan"

            case testExecutionPlan (TestIntegration IntegrationAwsIam) of
                testPlan ->
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeInitialIntegrationGatePrerequisites suitePlan
                                `shouldBe` ["aws_iam_harness_ready", "tool_aws"]
                            nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
                            nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
                        DelegatedSuite _ -> expectationFailure "expected native aws-iam plan"

        it "keeps charts-vscode on the supported runtime bootstrap path" $ do
            case testExecutionPlan (TestIntegration IntegrationChartsVscode) of
                testPlan ->
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "integration-charts-vscode"
                            nativeValidations suitePlan `shouldBe` [ValidationChartsVscode]
                            nativeInitialIntegrationGatePrerequisites suitePlan
                                `shouldBe` [ "supported_ubuntu_2404"
                                           , "tool_docker"
                                           , "tool_ctr"
                                           , "tool_helm"
                                           , "tool_kubectl"
                                           , "tool_sudo"
                                           , "tool_systemctl"
                                           , "settings_object"
                                           , "aws_credentials_valid"
                                           , "tool_pulumi"
                                           , "tool_curl"
                                           ]
                            nativeDeferredIntegrationGatePrerequisites suitePlan
                                `shouldBe` ["pulumi_logged_in"]
                            nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
                            nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
                        DelegatedSuite _ -> expectationFailure "expected native charts-vscode plan"

        it "waits for public-edge readiness during supported runtime restore actions" $ do
            repoRoot <- getCurrentDirectory
            runnerSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestRunner.hs")

            runnerSource `shouldContain` "runWaitForNativeCommandOutputContains"
            runnerSource `shouldContain` "publicEdgeReadyAttempts = 30"
            runnerSource `shouldContain` "publicEdgeReadyDelayMicroseconds = 10000000"

        it "waits for stable Harbor endpoints before lifecycle image reconcile begins" $ do
            repoRoot <- getCurrentDirectory
            rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")

            rke2Source `shouldContain` "waitForHarborStableEndpoints repoRoot"
            rke2Source `shouldContain` "harborEndpointStabilitySuccesses = 6"
            rke2Source `shouldContain` "harborEndpointStabilityDelayMicroseconds = 5000000"

        it "retries transient Harbor push failures during custom image publication" $ do
            repoRoot <- getCurrentDirectory
            rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")

            rke2Source `shouldContain` "customImagePushRetryAttempts = 3"
            rke2Source `shouldContain` "customImagePushRetryDelayMicroseconds = 5000000"
            rke2Source `shouldContain` "isRetryableCustomImageBuildFailure"
            rke2Source `shouldContain` "\"unexpected eof\""
            rke2Source `shouldContain` "\"unexpected status from put request\""

        it "keeps postgres-operator runtime on explicit Percona chart values" $ do
            repoRoot <- getCurrentDirectory
            rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")

            rke2Source `shouldContain` "\"operatorImageRepository\""
            rke2Source `shouldContain` "\"watchAllNamespaces\" .= True"
            rke2Source `shouldContain` "\"disableTelemetry\" .= True"
            rke2Source `shouldContain` "\"fullnameOverride\" .= patroniOperatorDeploymentName"

        it "checks Pulumi login against the local MinIO backend path" $ do
            repoRoot <- getCurrentDirectory
            interpreterSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "EffectInterpreter.hs")
            minioSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "MinioBackend.hs")

            interpreterSource `shouldContain` "withMinioPortForward"
            interpreterSource `shouldContain` "ensureMinioBackendBucket"
            interpreterSource `shouldContain` "\"login\""
            interpreterSource `shouldContain` "\"--non-interactive\""
            interpreterSource `shouldContain` "PULUMI_BACKEND_URL"
            minioSource `shouldContain` "parseDeletedMinioExportHostPath"
            minioSource `shouldContain` "\"rollout\", \"restart\", \"deployment/\" ++ minioDeploymentName"

        it "keeps Pulumi AWS provider credentials out of stack-local config" $ do
            repoRoot <- getCurrentDirectory
            eksProgram <- readFile (repoRoot </> "pulumi" </> "aws-eks" </> "Main.yaml")
            testProgram <- readFile (repoRoot </> "pulumi" </> "aws-test" </> "Main.yaml")
            eksStackSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsEksTestStack.hs")
            testStackSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs")

            eksProgram `shouldContain` "envVarMappings"
            eksProgram `shouldContain` "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
            eksProgram `shouldNotContain` "awsAccessKeyId:"
            eksProgram `shouldNotContain` "awsSecretAccessKey:"
            eksProgram `shouldNotContain` "awsSessionToken:"
            testProgram `shouldContain` "envVarMappings"
            testProgram `shouldContain` "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
            testProgram `shouldNotContain` "awsAccessKeyId:"
            testProgram `shouldNotContain` "awsSecretAccessKey:"
            testProgram `shouldNotContain` "awsSessionToken:"
            eksStackSource `shouldContain` "clearLegacyAwsProviderConfig"
            eksStackSource `shouldContain` "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
            eksStackSource `shouldNotContain` "(True, \"awsAccessKeyId\""
            eksStackSource `shouldNotContain` "(True, \"awsSecretAccessKey\""
            eksStackSource `shouldNotContain` "(True, \"awsSessionToken\""
            testStackSource `shouldContain` "clearLegacyAwsProviderConfig"
            testStackSource `shouldContain` "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
            testStackSource `shouldNotContain` "(True, \"awsAccessKeyId\""
            testStackSource `shouldNotContain` "(True, \"awsSecretAccessKey\""
            testStackSource `shouldNotContain` "(True, \"awsSessionToken\""

        it "keeps integration-cli fully on the Haskell-owned CLI suite" $ do
            case testExecutionPlan (TestIntegration IntegrationCli) of
                testPlan -> do
                    testPlanHaskellSuites testPlan `shouldBe` ["test:prodbox-integration-cli"]
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "integration-cli"
                            nativeValidations suitePlan `shouldBe` []
                            nativeInitialIntegrationGatePrerequisites suitePlan `shouldBe` []
                            nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
                            nativeRequiresIntegrationRunbook suitePlan `shouldBe` False
                        DelegatedSuite _ -> expectationFailure "expected native integration-cli plan"

        it "keeps integration-env fully on the Haskell-owned env suite" $ do
            case testExecutionPlan (TestIntegration IntegrationEnv) of
                testPlan -> do
                    testPlanHaskellSuites testPlan `shouldBe` ["test:prodbox-integration-env"]
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "integration-env"
                            nativeValidations suitePlan `shouldBe` []
                            nativeInitialIntegrationGatePrerequisites suitePlan `shouldBe` []
                            nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
                            nativeRequiresIntegrationRunbook suitePlan `shouldBe` False
                        DelegatedSuite _ -> expectationFailure "expected native integration-env plan"

        it "expands prerequisite closures transitively and deterministically" $ do
            transitiveClosureIds ["tool_systemctl", "supported_ubuntu_2404"] prerequisiteRegistry
                `shouldBe` Right ["platform_linux", "supported_ubuntu_2404", "systemd_available", "tool_systemctl"]

    describe "prerequisite registry" $ do
        it "covers the full shared prerequisite inventory" $ do
            sort (Map.keys prerequisiteRegistry)
                `shouldBe` sort
                    [ "platform_linux"
                    , "systemd_available"
                    , "supported_ubuntu_2404"
                    , "machine_identity"
                    , "tool_curl"
                    , "tool_dig"
                    , "tool_kubectl"
                    , "tool_docker"
                    , "tool_ctr"
                    , "tool_helm"
                    , "tool_sudo"
                    , "tool_pulumi"
                    , "tool_aws"
                    , "tool_ssh"
                    , "tool_rke2"
                    , "tool_systemctl"
                    , "tool_dhall"
                    , "settings_loaded"
                    , "settings_object"
                    , "aws_iam_harness_ready"
                    , "kubeconfig_exists"
                    , "kubeconfig_home_exists"
                    , "rke2_config_exists"
                    , "aws_credentials_valid"
                    , "route53_accessible"
                    , "rke2_installed"
                    , "rke2_service_exists"
                    , "rke2_service_active"
                    , "k8s_cluster_reachable"
                    , "pulumi_logged_in"
                    , "k8s_ready"
                    , "infra_ready"
                    ]

        it "keeps registry keys aligned with effect node ids and descriptions" $ do
            mapM_
                ( \(key, node) -> do
                    effectNodeId node `shouldBe` key
                    effectNodeDescription node `shouldNotBe` ""
                )
                (Map.toList prerequisiteRegistry)

        it "keeps every prerequisite reference inside the registry" $ do
            mapM_
                (\node -> all (`Map.member` prerequisiteRegistry) (effectNodePrerequisites node) `shouldBe` True)
                (Map.elems prerequisiteRegistry)

        it "has no direct self-reference or dependency cycles" $ do
            all
                (\(key, node) -> key `notElem` effectNodePrerequisites node)
                (Map.toList prerequisiteRegistry)
                `shouldBe` True
            all (not . hasCycle Set.empty) (Map.keys prerequisiteRegistry) `shouldBe` True

        it "keeps the expected dependency chains for infrastructure prerequisites" $ do
            effectNodePrerequisites (lookupPrerequisiteNode "aws_credentials_valid")
                `shouldBe` ["settings_loaded", "tool_aws"]
            effectNodePrerequisites (lookupPrerequisiteNode "aws_iam_harness_ready")
                `shouldBe` []
            effectNodePrerequisites (lookupPrerequisiteNode "route53_accessible")
                `shouldBe` ["aws_credentials_valid"]
            effectNodePrerequisites (lookupPrerequisiteNode "rke2_service_exists")
                `shouldBe` ["rke2_installed", "systemd_available", "supported_ubuntu_2404"]
            effectNodePrerequisites (lookupPrerequisiteNode "rke2_service_active")
                `shouldBe` ["rke2_service_exists"]
            effectNodePrerequisites (lookupPrerequisiteNode "k8s_cluster_reachable")
                `shouldBe` ["tool_kubectl", "kubeconfig_exists", "rke2_service_active"]
            effectNodePrerequisites (lookupPrerequisiteNode "pulumi_logged_in")
                `shouldBe` ["tool_pulumi", "k8s_cluster_reachable"]
            effectNodePrerequisites (lookupPrerequisiteNode "k8s_ready")
                `shouldBe` ["k8s_cluster_reachable", "rke2_service_active"]
            effectNodePrerequisites (lookupPrerequisiteNode "infra_ready")
                `shouldBe` ["k8s_ready", "aws_credentials_valid"]

        it "uses the expected validation and no-op effect shapes" $ do
            lookupPrerequisiteEffect "platform_linux" `shouldBe` Validate RequireLinux
            lookupPrerequisiteEffect "systemd_available" `shouldBe` Validate RequireSystemd
            lookupPrerequisiteEffect "supported_ubuntu_2404" `shouldBe` Validate RequireUbuntu2404
            lookupPrerequisiteEffect "machine_identity" `shouldBe` Validate RequireMachineIdentity
            lookupPrerequisiteEffect "tool_curl" `shouldBe` Validate (RequireTool "curl" ["--version"])
            lookupPrerequisiteEffect "tool_dig" `shouldBe` Validate (RequireTool "dig" ["-v"])
            lookupPrerequisiteEffect "tool_kubectl" `shouldBe` Validate (RequireTool "kubectl" ["version", "--client=true"])
            lookupPrerequisiteEffect "tool_ctr" `shouldBe` Validate (RequireTool "ctr" ["--help"])
            lookupPrerequisiteEffect "tool_rke2" `shouldBe` Validate (RequireTool "/usr/local/bin/rke2" ["--version"])
            lookupPrerequisiteEffect "tool_dhall" `shouldBe` Validate (RequireTool "dhall-to-json" ["--version"])
            lookupPrerequisiteEffect "settings_loaded" `shouldBe` Validate RequireSettings
            lookupPrerequisiteEffect "settings_object" `shouldBe` Validate RequireSettings
            lookupPrerequisiteEffect "aws_iam_harness_ready" `shouldBe` Validate RequireAwsIamHarnessReady
            lookupPrerequisiteEffect "kubeconfig_exists" `shouldBe` Validate (RequireFileExists "/etc/rancher/rke2/rke2.yaml")
            lookupPrerequisiteEffect "kubeconfig_home_exists" `shouldBe` Validate RequireHomeKubeconfig
            lookupPrerequisiteEffect "rke2_config_exists" `shouldBe` Validate (RequireFileExists "/etc/rancher/rke2/config.yaml")
            lookupPrerequisiteEffect "aws_credentials_valid" `shouldBe` Validate RequireAwsCredentials
            lookupPrerequisiteEffect "route53_accessible" `shouldBe` Validate RequireRoute53Access
            lookupPrerequisiteEffect "rke2_installed" `shouldBe` Validate (RequireFileExists "/usr/local/bin/rke2")
            lookupPrerequisiteEffect "rke2_service_exists" `shouldBe` Validate (RequireServiceExists "rke2-server.service")
            lookupPrerequisiteEffect "rke2_service_active" `shouldBe` Validate (RequireServiceActive "rke2-server.service")
            lookupPrerequisiteEffect "k8s_cluster_reachable" `shouldBe` Validate RequireKubectlClusterReachable
            lookupPrerequisiteEffect "pulumi_logged_in" `shouldBe` Validate RequirePulumiLogin
            lookupPrerequisiteEffect "k8s_ready" `shouldBe` Noop
            lookupPrerequisiteEffect "infra_ready" `shouldBe` Noop

        it "expands shared prerequisite chains transitively" $ do
            transitiveClosureIds ["rke2_service_active"] prerequisiteRegistry
                `shouldBe` Right
                    [ "platform_linux"
                    , "rke2_installed"
                    , "rke2_service_active"
                    , "rke2_service_exists"
                    , "supported_ubuntu_2404"
                    , "systemd_available"
                    ]
            transitiveClosureIds ["route53_accessible"] prerequisiteRegistry
                `shouldBe` Right
                    [ "aws_credentials_valid"
                    , "route53_accessible"
                    , "settings_loaded"
                    , "tool_aws"
                    ]
            transitiveClosureIds ["pulumi_logged_in"] prerequisiteRegistry
                `shouldBe` Right
                    [ "k8s_cluster_reachable"
                    , "kubeconfig_exists"
                    , "platform_linux"
                    , "pulumi_logged_in"
                    , "rke2_installed"
                    , "rke2_service_active"
                    , "rke2_service_exists"
                    , "supported_ubuntu_2404"
                    , "systemd_available"
                    , "tool_kubectl"
                    , "tool_pulumi"
                    ]
            transitiveClosureIds ["infra_ready"] prerequisiteRegistry
                `shouldBe` Right
                    [ "aws_credentials_valid"
                    , "infra_ready"
                    , "k8s_cluster_reachable"
                    , "k8s_ready"
                    , "kubeconfig_exists"
                    , "platform_linux"
                    , "rke2_installed"
                    , "rke2_service_active"
                    , "rke2_service_exists"
                    , "settings_loaded"
                    , "supported_ubuntu_2404"
                    , "systemd_available"
                    , "tool_aws"
                    , "tool_kubectl"
                    ]

    describe "native chart platform helpers" $ do
        it "extracts deleted MinIO export host paths from mountinfo" $ do
            parseDeletedMinioExportHostPath
                "14443 14435 8:2 /home/matthewnowak/prodbox/.data/prodbox-123/prodbox-minio-pv-0//deleted /export rw,relatime - ext4 /dev/sda2 rw\n"
                `shouldBe` Just "/home/matthewnowak/prodbox/.data/prodbox-123/prodbox-minio-pv-0"

            parseDeletedMinioExportHostPath
                "14443 14435 8:2 /home/matthewnowak/prodbox/.data/prodbox-123/prodbox-minio-pv-0 /export rw,relatime - ext4 /dev/sda2 rw\n"
                `shouldBe` Nothing

        it "derives deterministic storage bindings" $ do
            let spec =
                    ChartStorageSpec
                        { chartStorageSpecStatefulSetName = "vscode"
                        , chartStorageSpecPersistentVolumeClaimName = "vscode-data-0"
                        , chartStorageSpecStorageSize = "20Gi"
                        , chartStorageSpecOrdinal = 0
                        , chartStorageSpecClaimSuffix = "data"
                        }
                binding = storageBinding "/tmp/prodbox/.data" "vscode" "vscode" spec
            chartStorageBindingPersistentVolumeName binding
                `shouldBe` "prodbox-chart-vscode-vscode-vscode-0-data"
            chartStorageBindingHostPath binding
                `shouldBe` "/tmp/prodbox/.data/vscode/vscode/vscode/0/data"

        it "lists supported charts in canonical order" $ do
            supportedChartNames `shouldBe` ["keycloak", "vscode", "gateway"]

        it "builds delete plans in reverse dependency order" $ do
            case buildChartDeletePlan "/tmp/prodbox" Nothing "vscode" of
                Left err -> expectationFailure err
                Right plan -> do
                    chartDeploymentPlanRootChart plan `shouldBe` "vscode"
                    chartDeploymentPlanNamespace plan `shouldBe` "vscode"
                    map chartReleasePlanReleaseName (chartDeploymentPlanReleases plan)
                        `shouldBe` ["vscode", "keycloak", "keycloak-postgres"]

        it "builds vscode deployment plans with dependency order and deterministic values" $ do
            result <-
                buildChartDeploymentPlan
                    "/tmp/prodbox"
                    (testValidatedSettings "/tmp/prodbox/.data")
                    "vscode"
                    testChartSecrets
                    Map.empty
            case result of
                Left err -> expectationFailure err
                Right plan -> do
                    chartDeploymentPlanRootChart plan `shouldBe` "vscode"
                    chartDeploymentPlanNamespace plan `shouldBe` "vscode"
                    chartDeploymentPlanPublicFqdn plan `shouldBe` Just "vscode.example.com"
                    map chartReleasePlanReleaseName (chartDeploymentPlanReleases plan)
                        `shouldBe` ["keycloak-postgres", "keycloak", "vscode"]

                    let releaseValues =
                            Map.fromList
                                [ ( chartReleasePlanReleaseName release
                                  , eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value
                                  )
                                | release <- chartDeploymentPlanReleases plan
                                ]

                    case Map.lookup "keycloak-postgres" releaseValues of
                        Just (Right (Object payload)) -> do
                            case KeyMap.lookup (Key.fromString "cluster") payload of
                                Just (Object clusterPayload) -> do
                                    KeyMap.lookup (Key.fromString "name") clusterPayload
                                        `shouldBe` Just (String "prodbox-vscode-pg")
                                    KeyMap.lookup (Key.fromString "instances") clusterPayload
                                        `shouldBe` Just (Number 3)
                                    KeyMap.lookup (Key.fromString "crVersion") clusterPayload
                                        `shouldBe` Just (String "2.9.0")
                                _ -> expectationFailure "expected keycloak-postgres cluster payload"
                            case KeyMap.lookup (Key.fromString "image") payload of
                                Just (Object imagePayload) -> do
                                    case KeyMap.lookup (Key.fromString "postgres") imagePayload of
                                        Just (Object postgresImagePayload) -> do
                                            KeyMap.lookup (Key.fromString "repository") postgresImagePayload
                                                `shouldBe` Just (String "127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror")
                                            KeyMap.lookup (Key.fromString "tag") postgresImagePayload
                                                `shouldBe` Just (String "17.9-1")
                                        _ -> expectationFailure "expected keycloak-postgres postgres image payload"
                                    case KeyMap.lookup (Key.fromString "pgBackRest") imagePayload of
                                        Just (Object pgbackrestImagePayload) -> do
                                            KeyMap.lookup (Key.fromString "repository") pgbackrestImagePayload
                                                `shouldBe` Just (String "127.0.0.1:30080/prodbox/percona-pgbackrest-mirror")
                                            KeyMap.lookup (Key.fromString "tag") pgbackrestImagePayload
                                                `shouldBe` Just (String "2.58.0-1")
                                        _ -> expectationFailure "expected keycloak-postgres pgBackRest image payload"
                                    case KeyMap.lookup (Key.fromString "pgBouncer") imagePayload of
                                        Just (Object pgbouncerImagePayload) -> do
                                            KeyMap.lookup (Key.fromString "repository") pgbouncerImagePayload
                                                `shouldBe` Just (String "127.0.0.1:30080/prodbox/percona-pgbouncer-mirror")
                                            KeyMap.lookup (Key.fromString "tag") pgbouncerImagePayload
                                                `shouldBe` Just (String "1.25.1-1")
                                        _ -> expectationFailure "expected keycloak-postgres pgBouncer image payload"
                                _ -> expectationFailure "expected keycloak-postgres image payload"
                            case KeyMap.lookup (Key.fromString "postgres") payload of
                                Just (Object postgresPayload) -> do
                                    KeyMap.lookup (Key.fromString "version") postgresPayload
                                        `shouldBe` Just (Number 17)
                                    KeyMap.lookup (Key.fromString "database") postgresPayload
                                        `shouldBe` Just (String "keycloak")
                                    KeyMap.lookup (Key.fromString "username") postgresPayload
                                        `shouldBe` Just (String "keycloak")
                                _ -> expectationFailure "expected keycloak-postgres postgres payload"
                            case KeyMap.lookup (Key.fromString "secrets") payload of
                                Just (Object secretsPayload) -> do
                                    case KeyMap.lookup (Key.fromString "application") secretsPayload of
                                        Just (Object applicationPayload) ->
                                            KeyMap.lookup (Key.fromString "name") applicationPayload
                                                `shouldBe` Just (String "prodbox-vscode-pg-pguser-keycloak")
                                        _ -> expectationFailure "expected keycloak-postgres application secret payload"
                                    case KeyMap.lookup (Key.fromString "superuser") secretsPayload of
                                        Just (Object superuserPayload) ->
                                            KeyMap.lookup (Key.fromString "name") superuserPayload
                                                `shouldBe` Just (String "prodbox-vscode-pg-pguser-postgres")
                                        _ -> expectationFailure "expected keycloak-postgres superuser secret payload"
                                    case KeyMap.lookup (Key.fromString "standby") secretsPayload of
                                        Just (Object standbyPayload) -> do
                                            KeyMap.lookup (Key.fromString "name") standbyPayload
                                                `shouldBe` Just (String "prodbox-vscode-pg-primaryuser")
                                            KeyMap.lookup (Key.fromString "username") standbyPayload
                                                `shouldBe` Just (String "primaryuser")
                                        _ -> expectationFailure "expected keycloak-postgres standby secret payload"
                                _ -> expectationFailure "expected keycloak-postgres secrets payload"
                            case KeyMap.lookup (Key.fromString "security") payload of
                                Just (Object securityPayload) -> do
                                    KeyMap.lookup (Key.fromString "runAsUser") securityPayload
                                        `shouldBe` Just (Number 1001)
                                    KeyMap.lookup (Key.fromString "runAsGroup") securityPayload
                                        `shouldBe` Just (Number 1001)
                                    KeyMap.lookup (Key.fromString "fsGroup") securityPayload
                                        `shouldBe` Just (Number 1001)
                                _ -> expectationFailure "expected keycloak-postgres security payload"
                            case KeyMap.lookup (Key.fromString "proxy") payload of
                                Just (Object proxyPayload) ->
                                    KeyMap.lookup (Key.fromString "pgBouncerReplicas") proxyPayload
                                        `shouldBe` Just (Number 0)
                                _ -> expectationFailure "expected keycloak-postgres proxy payload"
                            case KeyMap.lookup (Key.fromString "backups") payload of
                                Just (Object backupsPayload) ->
                                    KeyMap.lookup (Key.fromString "enabled") backupsPayload
                                        `shouldBe` Just (Bool False)
                                _ -> expectationFailure "expected keycloak-postgres security payload"
                        _ -> expectationFailure "expected keycloak-postgres values payload"

                    case Map.lookup "keycloak" releaseValues of
                        Just (Right (Object payload)) -> do
                            KeyMap.lookup (Key.fromString "replicaCount") payload `shouldBe` Just (Number 2)
                            case KeyMap.lookup (Key.fromString "image") payload of
                                Just (Object imagePayload) -> do
                                    KeyMap.lookup (Key.fromString "repository") imagePayload `shouldBe` Just (String "127.0.0.1:30080/prodbox/keycloak-mirror")
                                    KeyMap.lookup (Key.fromString "tag") imagePayload `shouldBe` Just (String "26.0.0")
                                _ -> expectationFailure "expected keycloak image payload"
                            case KeyMap.lookup (Key.fromString "postgres") payload of
                                Just (Object postgresPayload) -> do
                                    KeyMap.lookup (Key.fromString "host") postgresPayload
                                        `shouldBe` Just (String "prodbox-vscode-pg-ha.vscode.svc.cluster.local")
                                    KeyMap.lookup (Key.fromString "database") postgresPayload `shouldBe` Just (String "keycloak")
                                    KeyMap.lookup (Key.fromString "username") postgresPayload `shouldBe` Just (String "keycloak")
                                    KeyMap.lookup (Key.fromString "passwordSecretName") postgresPayload
                                        `shouldBe` Just (String "prodbox-vscode-pg-pguser-keycloak")
                                _ -> expectationFailure "expected keycloak postgres payload"
                        _ -> expectationFailure "expected keycloak values payload"
                    case Map.lookup "vscode" releaseValues of
                        Just (Right (Object payload)) -> do
                            KeyMap.lookup (Key.fromString "replicaCount") payload `shouldBe` Just (Number 1)
                            case KeyMap.lookup (Key.fromString "nginx") payload of
                                Just (Object nginxPayload) ->
                                    KeyMap.lookup (Key.fromString "image") nginxPayload `shouldBe` Just (String "127.0.0.1:30080/prodbox/prodbox-nginx-oidc:latest")
                                _ -> expectationFailure "expected vscode nginx payload"
                            case KeyMap.lookup (Key.fromString "vscode") payload of
                                Just (Object vscodePayload) ->
                                    KeyMap.lookup (Key.fromString "image") vscodePayload `shouldBe` Just (String "127.0.0.1:30080/prodbox/code-server-mirror:4.98.2")
                                _ -> expectationFailure "expected vscode image payload"
                        _ -> expectationFailure "expected vscode values payload"

                    case chartDeploymentPlanReleases plan of
                        [keycloakPostgresRelease, _keycloakRelease, vscodeRelease] -> do
                            length (chartReleasePlanStorageBindings keycloakPostgresRelease) `shouldBe` 3
                            case chartReleasePlanStorageBindings vscodeRelease of
                                [binding] ->
                                    chartStorageBindingPersistentVolumeName binding
                                        `shouldBe` "prodbox-chart-vscode-vscode-vscode-0-data"
                                _ -> expectationFailure "expected vscode storage binding"
                        [] -> expectationFailure "expected releases in chart deployment plan"
                        _ -> expectationFailure "expected keycloak-postgres, keycloak, and vscode releases"

        it "merges new Patroni secret keys into retained chart secret state" $
            withSystemTempDirectory "prodbox-chart-secrets" $ \tempRoot -> do
                let namespaceDir = tempRoot </> ".prodbox-state" </> "vscode"
                    secretPath = namespaceDir </> ".secrets.json"
                createDirectoryIfMissing True namespaceDir
                writeFile secretPath "{\"keycloak_admin_password\":\"adminpass\",\"keycloak_nginx_client_secret\":\"nginxsecret\"}\n"
                result <- resolveChartSecrets tempRoot "vscode"
                case result of
                    Left err -> expectationFailure err
                    Right secrets -> do
                        Map.lookup "keycloak_admin_password" secrets `shouldBe` Just "adminpass"
                        Map.lookup "keycloak_nginx_client_secret" secrets `shouldBe` Just "nginxsecret"
                        case Map.lookup "patroni_app_password" secrets of
                            Just value -> value `shouldSatisfy` (not . null)
                            Nothing -> expectationFailure "expected patroni_app_password"
                        case Map.lookup "patroni_standby_password" secrets of
                            Just value -> value `shouldSatisfy` (not . null)
                            Nothing -> expectationFailure "expected patroni_standby_password"
                        case Map.lookup "patroni_superuser_password" secrets of
                            Just value -> value `shouldSatisfy` (not . null)
                            Nothing -> expectationFailure "expected patroni_superuser_password"

        it "prefers live Patroni secret recovery over stale retained Patroni values" $ do
            let existingSecrets =
                    Map.fromList
                        [ ("keycloak_admin_password", "adminpass")
                        , ("keycloak_nginx_client_secret", "nginxsecret")
                        , ("patroni_app_password", "stale-app")
                        , ("patroni_standby_password", "stale-standby")
                        , ("patroni_superuser_password", "stale-superuser")
                        ]
                recoveredSecrets =
                    Map.fromList
                        [ ("patroni_app_password", "live-app")
                        , ("patroni_standby_password", "live-standby")
                        , ("patroni_superuser_password", "live-superuser")
                        ]
                mergedSecrets = mergeChartSecretValues existingSecrets recoveredSecrets
            Map.lookup "keycloak_admin_password" mergedSecrets `shouldBe` Just "adminpass"
            Map.lookup "keycloak_nginx_client_secret" mergedSecrets `shouldBe` Just "nginxsecret"
            Map.lookup "patroni_app_password" mergedSecrets `shouldBe` Just "live-app"
            Map.lookup "patroni_standby_password" mergedSecrets `shouldBe` Just "live-standby"
            Map.lookup "patroni_superuser_password" mergedSecrets `shouldBe` Just "live-superuser"

    describe "native gateway helpers" $ do
        it "renders deterministic gateway status output" $ do
            let payload =
                    Object
                        ( KeyMap.fromList
                            [ (Key.fromString "node_id", String "node-a")
                            , (Key.fromString "gateway_owner", String "node-a")
                            , (Key.fromString "has_active_claim", Bool True)
                            , (Key.fromString "mesh_peers", Array (Vector.fromList [String "node-b"]))
                            , (Key.fromString "event_count", Number 5)
                            , (Key.fromString "last_public_ip_observed", String "203.0.113.10")
                            , (Key.fromString "last_dns_write_ip", String "203.0.113.10")
                            , (Key.fromString "last_dns_write_at_utc", String "2026-04-06T10:00:00Z")
                            ,
                                ( Key.fromString "dns_write_gate"
                                , Object
                                    ( KeyMap.fromList
                                        [ (Key.fromString "zone_id", String "Z123")
                                        , (Key.fromString "fqdn", String "code.example.com")
                                        , (Key.fromString "ttl", Number 60)
                                        ]
                                    )
                                )
                            ,
                                ( Key.fromString "heartbeat_age_seconds"
                                , Object
                                    ( KeyMap.fromList
                                        [ (Key.fromString "node-a", Number 0.0)
                                        , (Key.fromString "node-b", Number 1.5)
                                        ]
                                    )
                                )
                            ]
                        )
            case renderGatewayStatusReport payload of
                Left err -> expectationFailure err
                Right report -> do
                    report `shouldContain` "ACTIVE_CLAIM=true"
                    report `shouldContain` "DNS_WRITE_GATE=code.example.com@Z123 ttl=60"
                    report `shouldContain` "HEARTBEAT_NODE_B=1.5"

        it "renders gateway config templates with dns_write_gate" $
            withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
                writeFile (tmpDir </> "prodbox-config.dhall") validConfig

                result <- validateAndLoadSettings tmpDir

                case result of
                    Left err -> expectationFailure err
                    Right settings ->
                        case eitherDecode (BL8.pack (renderGatewayConfigTemplate settings "node-a")) of
                            Left err -> expectationFailure err
                            Right (Object payload) ->
                                case KeyMap.lookup (Key.fromString "dns_write_gate") payload of
                                    Just (Object gate) -> do
                                        KeyMap.lookup (Key.fromString "fqdn") gate `shouldBe` Just (String "vscode.example.com")
                                        KeyMap.lookup (Key.fromString "zone_id") gate `shouldBe` Just (String "Z1234567890ABC")
                                        KeyMap.lookup (Key.fromString "ttl") gate `shouldBe` Just (Number 60)
                                        KeyMap.lookup (Key.fromString "aws_region") gate `shouldBe` Just (String "us-east-1")
                                    _ -> expectationFailure "expected dns_write_gate object"
                            Right _ -> expectationFailure "expected config template object"

    describe "native host and k8s helpers" $ do
        it "renders deterministic host port availability output" $ do
            renderPortAvailabilityReport
                [ PortStatus 80 True "no listening socket detected"
                , PortStatus 443 False "listening socket detected"
                ]
                `shouldBe` unlines
                    [ "Host port check"
                    , "PORT=80 AVAILABLE=true DETAIL=no listening socket detected"
                    , "PORT=443 AVAILABLE=false DETAIL=listening socket detected"
                    , "Ports unavailable: 443"
                    , "STATUS=busy"
                    ]

        it "parses kubectl object names into a deterministic list" $ do
            parseKubectlObjectNames "pod/alpha\n\npod/bravo\n"
                `shouldBe` ["pod/alpha", "pod/bravo"]

    describe "container image mapping" $ do
        it "keeps the supported platform image mirrors on explicit Harbor targets" $ do
            mapM_
                (\expectedPair -> ContainerImage.requiredPublicImagePairs `shouldContain` [expectedPair])
                [ ("ghcr.io/coder/code-server:4.98.2", "127.0.0.1:30080/prodbox/code-server-mirror:4.98.2")
                , ("ghcr.io/traefik/traefik:v3.1.4", "127.0.0.1:30080/prodbox/traefik-mirror:v3.1.4")
                ]

        it "maps supported public-image aliases to stable Harbor targets only for mirrored upstreams" $ do
            ContainerImage.harborMirrorTargetForSource "docker.io/percona/percona-postgresql-operator:2.9.0"
                `shouldBe` Just "127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
            ContainerImage.harborMirrorTargetForSource "docker.io/percona/percona-distribution-postgresql:17.9-1"
                `shouldBe` Just "127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"
            ContainerImage.harborMirrorTargetForSource "docker.io/percona/percona-pgbackrest:2.58.0-1"
                `shouldBe` Just "127.0.0.1:30080/prodbox/percona-pgbackrest-mirror:2.58.0-1"
            ContainerImage.harborMirrorTargetForSource "docker.io/percona/percona-pgbouncer:1.25.1-1"
                `shouldBe` Just "127.0.0.1:30080/prodbox/percona-pgbouncer-mirror:1.25.1-1"
            ContainerImage.harborMirrorTargetForSource "docker.io/codercom/code-server:4.98.2"
                `shouldBe` Just "127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
            ContainerImage.harborMirrorTargetForSource "docker.io/library/traefik:v3.1.4"
                `shouldBe` Just "127.0.0.1:30080/prodbox/traefik-mirror:v3.1.4"

        it "orders public-image mirror candidates with the discovered source first" $ do
            ContainerImage.harborMirrorSourceCandidates "docker.io/percona/percona-postgresql-operator:2.9.0"
                `shouldBe` Just ["docker.io/percona/percona-postgresql-operator:2.9.0"]
            ContainerImage.harborMirrorSourceCandidates "docker.io/percona/percona-pgbackrest:2.58.0-1"
                `shouldBe` Just ["docker.io/percona/percona-pgbackrest:2.58.0-1"]
            ContainerImage.harborMirrorSourceCandidates "ghcr.io/coder/code-server:4.98.2"
                `shouldBe` Just ["ghcr.io/coder/code-server:4.98.2", "docker.io/codercom/code-server:4.98.2"]

        it "tracks candidate upstream sets for required public images" $ do
            ContainerImage.requiredPublicImageCandidatePairs
                `shouldContain` [
                                    (
                                        [ "ghcr.io/coder/code-server:4.98.2"
                                        , "docker.io/codercom/code-server:4.98.2"
                                        ]
                                    , "127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
                                    )
                                ]

    describe "supported runtime helpers" $ do
        it "removes only the target FQDN from hosts text" $ do
            let hostsText = unlines ["127.0.0.1 localhost vscode.example.com demo.example.com # keep comment", "192.168.1.10 printer"]
                (updatedText, removedEntries) = removeFqdnFromHostsText hostsText "vscode.example.com"
            removedEntries `shouldBe` 1
            updatedText `shouldBe` unlines ["127.0.0.1 localhost demo.example.com  # keep comment", "192.168.1.10 printer"]

        it "drops delete-pending AWS resources from a Pulumi export" $ do
            let exportedValue =
                    Object
                        ( KeyMap.fromList
                            [
                                ( Key.fromString "deployment"
                                , Object
                                    ( KeyMap.fromList
                                        [
                                            ( Key.fromString "resources"
                                            , Array
                                                ( Vector.fromList
                                                    [ Object
                                                        ( KeyMap.fromList
                                                            [ (Key.fromString "type", String "pulumi:providers:aws")
                                                            , (Key.fromString "delete", Bool True)
                                                            ]
                                                        )
                                                    , Object
                                                        ( KeyMap.fromList
                                                            [ (Key.fromString "type", String "aws:route53/record:Record")
                                                            , (Key.fromString "delete", Bool True)
                                                            ]
                                                        )
                                                    , Object
                                                        ( KeyMap.fromList
                                                            [ (Key.fromString "type", String "kubernetes:core/v1:Namespace")
                                                            , (Key.fromString "delete", Bool False)
                                                            ]
                                                        )
                                                    ]
                                                )
                                            )
                                        ]
                                    )
                                )
                            ]
                        )
            case removeDeletePendingAwsResources exportedValue of
                Left err -> expectationFailure err
                Right (updatedValue, removedCount) -> do
                    removedCount `shouldBe` 2
                    case updatedValue of
                        Object rootObject ->
                            case KeyMap.lookup (Key.fromString "deployment") rootObject of
                                Just (Object deploymentObject) ->
                                    case KeyMap.lookup (Key.fromString "resources") deploymentObject of
                                        Just (Array resources) -> Vector.length resources `shouldBe` 1
                                        _ -> expectationFailure "expected deployment resources array"
                                _ -> expectationFailure "expected deployment object"
                        _ -> expectationFailure "expected exported object"

    describe "AWS environment helpers" $ do
        let credentialsWithoutSession =
                Credentials
                    { access_key_id = "config-access-key"
                    , secret_access_key = "config-secret-key"
                    , session_token = Nothing
                    , region = "us-west-2"
                    }
            credentialsWithSession =
                credentialsWithoutSession{session_token = Just "config-session-token"}

        it "replaces ambient AWS auth sources with repo-owned credentials" $ do
            let environment =
                    [ ("PATH", "/usr/bin")
                    , ("AWS_PROFILE", "default")
                    , ("AWS_SHARED_CREDENTIALS_FILE", "/tmp/creds")
                    , ("AWS_ACCESS_KEY_ID", "ambient-access-key")
                    , ("AWS_SECRET_ACCESS_KEY", "ambient-secret-key")
                    , ("AWS_SESSION_TOKEN", "ambient-session-token")
                    ]
                updatedEnvironment = overlayAwsCredentials environment credentialsWithoutSession
            lookup "PATH" updatedEnvironment `shouldBe` Just "/usr/bin"
            lookup "AWS_ACCESS_KEY_ID" updatedEnvironment `shouldBe` Just "config-access-key"
            lookup "AWS_SECRET_ACCESS_KEY" updatedEnvironment `shouldBe` Just "config-secret-key"
            lookup "AWS_REGION" updatedEnvironment `shouldBe` Just "us-west-2"
            lookup "AWS_DEFAULT_REGION" updatedEnvironment `shouldBe` Just "us-west-2"
            lookup "AWS_EC2_METADATA_DISABLED" updatedEnvironment `shouldBe` Just "true"
            lookup "AWS_PAGER" updatedEnvironment `shouldBe` Just ""
            lookup "AWS_PROFILE" updatedEnvironment `shouldBe` Nothing
            lookup "AWS_SHARED_CREDENTIALS_FILE" updatedEnvironment `shouldBe` Nothing
            lookup "AWS_SESSION_TOKEN" updatedEnvironment `shouldBe` Nothing

        it "projects an explicit session token when the repo config provides one" $ do
            let updatedEnvironment = isolatedAwsEnvironment credentialsWithSession
            lookup "AWS_ACCESS_KEY_ID" updatedEnvironment `shouldBe` Just "config-access-key"
            lookup "AWS_SECRET_ACCESS_KEY" updatedEnvironment `shouldBe` Just "config-secret-key"
            lookup "AWS_SESSION_TOKEN" updatedEnvironment `shouldBe` Just "config-session-token"
            lookup "AWS_REGION" updatedEnvironment `shouldBe` Just "us-west-2"
            lookup "AWS_DEFAULT_REGION" updatedEnvironment `shouldBe` Just "us-west-2"

    describe "native validation helpers" $ do
        it "retries AWS test-stack SSH validation until a node accepts connections" $
            withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
                let stateDir = tmpDir </> ".prodbox-state" </> AwsTest.awsTestStackName
                    privateKeyPath = stateDir </> "id_ed25519"
                    publicKeyPath = stateDir </> "id_ed25519.pub"
                    sshStateDir = tmpDir </> "ssh-state"
                    binDir = tmpDir </> "bin"
                    fakeSshPath = binDir </> "ssh"
                    snapshot =
                        AwsTest.AwsTestStackSnapshot
                            { AwsTest.testSnapshotStackName = AwsTest.awsTestStackName
                            , AwsTest.testSnapshotBackendBucket = "prodbox-test-pulumi-backends"
                            , AwsTest.testSnapshotVpcId = "vpc-1234567890"
                            , AwsTest.testSnapshotSubnetIds = ["subnet-1", "subnet-2", "subnet-3"]
                            , AwsTest.testSnapshotSecurityGroupId = "sg-1234567890"
                            , AwsTest.testSnapshotNodes =
                                [ AwsTest.AwsTestNode
                                    { AwsTest.testNodeName = "aws-test-node-0"
                                    , AwsTest.testNodeAvailabilityZone = "us-west-2a"
                                    , AwsTest.testNodeInstanceId = "i-1234567890"
                                    , AwsTest.testNodePrivateIp = "10.0.0.10"
                                    , AwsTest.testNodePublicIp = "203.0.113.10"
                                    }
                                ]
                            }
                createDirectoryIfMissing True stateDir
                createDirectoryIfMissing True sshStateDir
                createDirectoryIfMissing True binDir
                writeFile privateKeyPath "fake-private-key\n"
                writeFile publicKeyPath "fake-public-key\n"
                AwsTest.saveAwsTestStackSnapshot tmpDir snapshot
                writeFile fakeSshPath (unlines fakeAwsTestSshScript)
                makeExecutable fakeSshPath

                originalPath <- lookupEnv "PATH"
                originalSshStateDir <- lookupEnv "PRODBOX_TEST_SSH_STATE_DIR"
                let restoreEnv key previous =
                        case previous of
                            Just value -> setEnv key value
                            Nothing -> unsetEnv key
                    configuredPath =
                        case originalPath of
                            Just currentPath -> binDir ++ ":" ++ currentPath
                            Nothing -> binDir

                setEnv "PATH" configuredPath
                setEnv "PRODBOX_TEST_SSH_STATE_DIR" sshStateDir
                validationResult <-
                    verifyAwsTestSshReachability tmpDir
                        `finally` do
                            restoreEnv "PATH" originalPath
                            restoreEnv "PRODBOX_TEST_SSH_STATE_DIR" originalSshStateDir

                validationResult `shouldBe` ExitSuccess
                readFile (sshStateDir </> "count") `shouldReturn` "3"

    describe "settings" $ do
        it "validates Dhall config and renders masked output without materializing JSON" $
            withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
                writeFile (tmpDir </> "prodbox-config.dhall") validConfig

                result <- validateAndLoadSettings tmpDir

                case result of
                    Left err -> expectationFailure err
                    Right settings -> do
                        renderSettingsDisplay False settings `shouldContain` "aws.access_key_id=****-key"
                        renderSettingsDisplay False settings `shouldContain` "acme.email=****.com"
                        renderSettingsDisplay True settings `shouldContain` "aws.access_key_id=test-access-key"
                        renderSettingsDisplay False settings `shouldContain` ("storage.manual_pv_host_root=" ++ (tmpDir </> ".data"))
                        doesFileExist (tmpDir </> "prodbox-config.json") `shouldReturn` False

        it "fails fast on invalid ZeroSSL EAB configuration" $
            withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
                writeFile (tmpDir </> "prodbox-config.dhall") invalidZeroSslConfig

                result <- validateAndLoadSettings tmpDir

                case result of
                    Left err -> err `shouldContain` "required for ZeroSSL ACME"
                    Right _ -> expectationFailure "expected validation failure"

        it "fails fast with setup guidance when the repo Dhall config is missing" $
            withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
                result <- validateAndLoadSettings tmpDir

                case result of
                    Left err -> do
                        err `shouldContain` "Missing required repository config"
                        err `shouldContain` (tmpDir </> "prodbox-config.dhall")
                        err `shouldContain` "./.build/prodbox config setup"
                    Right _ -> expectationFailure "expected missing-config failure"

parseArgs :: [String] -> Either String Options
parseArgs argv =
    case execParserPure defaultPrefs parserInfo argv of
        Success options -> Right options
        Failure failure ->
            let (message, _) = renderFailure failure "prodbox"
             in Left message
        CompletionInvoked _ -> Left "shell completion requested"

makeExecutable :: FilePath -> IO ()
makeExecutable path = do
    permissions <- getPermissions path
    setPermissions path permissions{executable = True}

fakeAwsTestSshScript :: [String]
fakeAwsTestSshScript =
    [ "#!/usr/bin/env bash"
    , "set -eu"
    , "state_dir=\"${PRODBOX_TEST_SSH_STATE_DIR:?}\""
    , "count_file=\"$state_dir/count\""
    , "count=0"
    , "if [ -f \"$count_file\" ]; then"
    , "  count=$(cat \"$count_file\")"
    , "fi"
    , "count=$((count + 1))"
    , "printf '%s' \"$count\" > \"$count_file\""
    , "if [ \"$count\" -lt 3 ]; then"
    , "  echo \"ssh: connect to host 203.0.113.10 port 22: Connection refused\" >&2"
    , "  exit 255"
    , "fi"
    , "echo \"aws-test-node-0\""
    ]

lookupPrerequisiteNode :: String -> EffectNode
lookupPrerequisiteNode prerequisiteId =
    case Map.lookup prerequisiteId prerequisiteRegistry of
        Just node -> node
        Nothing -> error ("missing prerequisite in test registry: " ++ prerequisiteId)

lookupPrerequisiteEffect :: String -> Effect
lookupPrerequisiteEffect = effectNodeEffect . lookupPrerequisiteNode

hasCycle :: Set.Set String -> String -> Bool
hasCycle visited prerequisiteId
    | Set.member prerequisiteId visited = True
    | otherwise =
        case Map.lookup prerequisiteId prerequisiteRegistry of
            Nothing -> False
            Just node ->
                any (hasCycle (Set.insert prerequisiteId visited)) (effectNodePrerequisites node)

validConfig :: String
validConfig =
    unlines
        [ "{ aws = { access_key_id = \"test-access-key\", secret_access_key = \"test-secret-key\", session_token = Some \"test-session-token\", region = \"us-east-1\" }"
        , ", aws_admin_for_test_simulation = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
        , ", route53 = { zone_id = \"Z1234567890ABC\" }"
        , ", domain = { demo_fqdn = \"test.example.com\", demo_ttl = 60, vscode_fqdn = Some \"vscode.example.com\" }"
        , ", acme = { email = \"test@example.com\", server = \"https://acme-staging-v02.api.letsencrypt.org/directory\", eab_key_id = None Text, eab_hmac_key = None Text }"
        , ", deployment = { dev_mode = True, bootstrap_public_ip_override = None Text, pulumi_enable_dns_bootstrap = True }"
        , ", storage = { manual_pv_host_root = \".data\" }"
        , "}"
        ]
invalidZeroSslConfig :: String
invalidZeroSslConfig =
    unlines
        [ "{ aws = { access_key_id = \"test-access-key\", secret_access_key = \"test-secret-key\", session_token = None Text, region = \"us-east-1\" }"
        , ", aws_admin_for_test_simulation = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
        , ", route53 = { zone_id = \"Z1234567890ABC\" }"
        , ", domain = { demo_fqdn = \"test.example.com\", demo_ttl = 60, vscode_fqdn = None Text }"
        , ", acme = { email = \"test@example.com\", server = \"https://acme.zerossl.com/v2/DV90\", eab_key_id = None Text, eab_hmac_key = None Text }"
        , ", deployment = { dev_mode = True, bootstrap_public_ip_override = None Text, pulumi_enable_dns_bootstrap = True }"
        , ", storage = { manual_pv_host_root = \".data\" }"
        , "}"
        ]

testValidatedSettings :: FilePath -> ValidatedSettings
testValidatedSettings manualRoot =
    ValidatedSettings
        { validatedConfig =
            defaultConfigFile
                { aws =
                    Credentials
                        { access_key_id = "test-access-key"
                        , secret_access_key = "test-secret-key"
                        , session_token = Just "test-session-token"
                        , region = "us-east-1"
                        }
                , route53 = Route53Section{zone_id = "Z1234567890ABC"}
                , domain =
                    DomainSection
                        { demo_fqdn = "test.example.com"
                        , demo_ttl = 60
                        , vscode_fqdn = Just "vscode.example.com"
                        }
                , deployment =
                    DeploymentSection
                        { dev_mode = True
                        , bootstrap_public_ip_override = Nothing
                        , pulumi_enable_dns_bootstrap = True
                        }
                , storage = StorageSection{manual_pv_host_root = ".data"}
                }
        , resolvedManualPvHostRoot = manualRoot
        }

testChartSecrets :: Map.Map String String
testChartSecrets =
    Map.fromList
        [ ("keycloak_admin_password", "adminpass")
        , ("keycloak_nginx_client_secret", "nginxsecret")
        , ("patroni_app_password", "patroniapppassword")
        , ("patroni_standby_password", "patronistandbypassword")
        , ("patroni_superuser_password", "patronisuperuserpassword")
        ]
