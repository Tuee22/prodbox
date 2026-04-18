{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Aeson
    ( Value (..),
      eitherDecode,
    )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy.Char8 as BL8
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List
    ( sort,
    )
import qualified Data.Vector as Vector
import Options.Applicative
    ( ParserResult (..),
      defaultPrefs,
      execParserPure,
      renderFailure,
    )
import Prodbox.Aws
    ( buildIamPolicyDocument,
    )
import Prodbox.CLI.Command
    ( AwsCommand (..),
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
import Prodbox.CLI.Parser
    ( Options (..),
      parserInfo,
    )
import Prodbox.Effect
    ( Effect (..),
      Validation (..),
    )
import Prodbox.EffectDAG
    ( EffectNode (..),
      transitiveClosureIds,
    )
import Prodbox.Gateway
    ( renderGatewayConfigTemplate,
      renderGatewayStatusReport,
    )
import Prodbox.Host
    ( PortStatus (..),
      renderPortAvailabilityReport,
    )
import Prodbox.K8s
    ( defaultInfrastructureNamespaces,
      parseKubectlObjectNames,
    )
import Prodbox.Lib.ChartPlatform
    ( ChartDeploymentPlan (..),
      ChartReleasePlan (..),
      buildChartDeletePlan,
      buildChartDeploymentPlan,
      supportedChartNames,
    )
import Prodbox.Lib.Storage
    ( ChartStorageBinding (..),
      ChartStorageSpec (..),
      storageBinding,
    )
import Prodbox.Prerequisite
    ( prerequisiteRegistry,
    )
import Prodbox.Settings
    ( ConfigFile (..),
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
import Prodbox.SupportedRuntime
    ( removeDeletePendingAwsResources,
      removeFqdnFromHostsText,
    )
import Prodbox.TestPlan
    ( NativeSuitePlan (..),
      NativeValidation (..),
      TestExecutionMode (..),
      TestExecutionPlan (..),
      nativeValidationId,
      testExecutionPlan,
    )
import System.Directory
    ( doesFileExist,
      getCurrentDirectory,
    )
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
            parseArgs ["pulumi", "up", "--yes"]
                `shouldBe` Right (Options False (RunNative (NativePulumi (PulumiUp True))))

        it "routes charts commands through the native Haskell runtime" $ do
            parseArgs ["charts", "delete", "gateway", "--yes"]
                `shouldBe` Right
                    ( Options
                        False
                        (RunNative (NativeCharts (ChartsDelete "gateway" True)))
                    )

        it "routes native k8s commands through the Haskell runtime with defaults" $ do
            parseArgs ["k8s", "logs"]
                `shouldBe` Right (Options False (RunNative (NativeK8s (K8sLogs defaultInfrastructureNamespaces 10))))

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
                                    | Object statement <- Vector.toList statements,
                                      Just (String sid) <- [KeyMap.lookup (Key.fromString "Sid") statement]
                                    ]
                            sids `shouldContain` ["Ec2HaTestStackLifecycle", "IamEksRoleLifecycle", "EksTestStackLifecycle"]
                        _ -> expectationFailure "expected Statement array"
                _ -> expectationFailure "expected policy document object"

    describe "frontend scaffold doctrine" $ do
        it "keeps the Phase 1.1 Haskell frontend scaffold in the repository" $ do
            repoRoot <- getCurrentDirectory
            scaffoldExists <-
                mapM (doesFileExist . (repoRoot </>))
                    [ "app/prodbox/Main.hs",
                      "src/Prodbox/CLI/Parser.hs",
                      "src/Prodbox/Gateway/Daemon.hs",
                      "prodbox.cabal",
                      "cabal.project",
                      "Dockerfile",
                      "test/integration/env/Main.hs"
                    ]

            scaffoldExists `shouldBe` replicate 7 True

        it "keeps cabal.project minimal for nix-style builds" $ do
            repoRoot <- getCurrentDirectory
            cabalProject <- readFile (repoRoot </> "cabal.project")

            cabalProject `shouldContain` "packages: ."
            cabalProject `shouldNotContain` "builddir:"

        it "builds the container frontend under /opt/build" $ do
            repoRoot <- getCurrentDirectory
            dockerfile <- readFile (repoRoot </> "Dockerfile")

            dockerfile `shouldContain` "WORKDIR /opt/build"
            dockerfile `shouldContain` "cabal build --builddir=.build exe:prodbox"
            dockerfile `shouldContain` "cabal list-bin --builddir=.build exe:prodbox"

    describe "test planning" $ do
        it "maps aggregate all to the native ordered validation workflow" $ do
            case testExecutionPlan TestAll of
                testPlan -> do
                    testPlanLabel testPlan `shouldBe` "all"
                    testPlanHaskellSuites testPlan
                        `shouldBe`
                            [ "test:prodbox-unit",
                              "test:prodbox-integration-cli",
                              "test:prodbox-integration-env"
                            ]
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "all"
                            nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
                            nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
                            nativeRequiresSupportedRuntimePostflight suitePlan `shouldBe` True
                            map nativeValidationId (nativeValidations suitePlan)
                                `shouldBe`
                                    [ "charts-vscode",
                                      "public-dns",
                                      "dns-aws",
                                      "aws-iam",
                                      "aws-eks",
                                      "pulumi",
                                      "ha-rke2-aws",
                                      "gateway-daemon",
                                      "gateway-pods",
                                      "gateway-partition",
                                      "charts-platform",
                                      "charts-storage",
                                      "lifecycle"
                                    ]
                        DelegatedSuite _ -> expectationFailure "expected native aggregate test plan"

        it "keeps integration-all in the canonical external-proof-first order" $ do
            case testExecutionPlan (TestIntegration IntegrationAll) of
                testPlan ->
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "integration-all"
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
                            nativeIntegrationGatePrerequisites suitePlan
                                `shouldBe`
                                    [ "supported_ubuntu_2404",
                                      "tool_docker",
                                      "tool_ctr",
                                      "tool_helm",
                                      "tool_kubectl",
                                      "tool_sudo",
                                      "tool_systemctl",
                                      "settings_object",
                                      "tool_pulumi",
                                      "tool_aws"
                                    ]
                            nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
                        DelegatedSuite _ -> expectationFailure "expected native aws-eks plan"

        it "keeps integration-cli fully on the Haskell-owned CLI suite" $ do
            case testExecutionPlan (TestIntegration IntegrationCli) of
                testPlan -> do
                    testPlanHaskellSuites testPlan `shouldBe` ["test:prodbox-integration-cli"]
                    case testPlanExecutionMode testPlan of
                        NativeSuite suitePlan -> do
                            nativeSuiteId suitePlan `shouldBe` "integration-cli"
                            nativeValidations suitePlan `shouldBe` []
                            nativeIntegrationGatePrerequisites suitePlan `shouldBe` []
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
                            nativeIntegrationGatePrerequisites suitePlan `shouldBe` []
                            nativeRequiresIntegrationRunbook suitePlan `shouldBe` False
                        DelegatedSuite _ -> expectationFailure "expected native integration-env plan"

        it "expands prerequisite closures transitively and deterministically" $ do
            transitiveClosureIds ["tool_systemctl", "supported_ubuntu_2404"] prerequisiteRegistry
                `shouldBe` Right ["platform_linux", "supported_ubuntu_2404", "systemd_available", "tool_systemctl"]

    describe "prerequisite registry" $ do
        it "covers the full shared prerequisite inventory" $ do
            sort (Map.keys prerequisiteRegistry)
                `shouldBe` sort
                    [ "platform_linux",
                      "systemd_available",
                      "supported_ubuntu_2404",
                      "machine_identity",
                      "tool_curl",
                      "tool_dig",
                      "tool_kubectl",
                      "tool_docker",
                      "tool_ctr",
                      "tool_helm",
                      "tool_sudo",
                      "tool_pulumi",
                      "tool_aws",
                      "tool_ssh",
                      "tool_rke2",
                      "tool_systemctl",
                      "tool_dhall",
                      "settings_loaded",
                      "settings_object",
                      "kubeconfig_exists",
                      "kubeconfig_home_exists",
                      "rke2_config_exists",
                      "aws_credentials_valid",
                      "route53_accessible",
                      "rke2_installed",
                      "rke2_service_exists",
                      "rke2_service_active",
                      "k8s_cluster_reachable",
                      "pulumi_logged_in",
                      "k8s_ready",
                      "infra_ready"
                    ]

        it "keeps registry keys aligned with effect node ids and descriptions" $ do
            mapM_
                (\(key, node) -> do
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
                `shouldBe` ["settings_loaded"]
            effectNodePrerequisites (lookupPrerequisiteNode "route53_accessible")
                `shouldBe` ["aws_credentials_valid"]
            effectNodePrerequisites (lookupPrerequisiteNode "rke2_service_exists")
                `shouldBe` ["rke2_installed", "systemd_available", "supported_ubuntu_2404"]
            effectNodePrerequisites (lookupPrerequisiteNode "rke2_service_active")
                `shouldBe` ["rke2_service_exists"]
            effectNodePrerequisites (lookupPrerequisiteNode "k8s_cluster_reachable")
                `shouldBe` ["tool_kubectl", "kubeconfig_exists", "rke2_service_active"]
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
            lookupPrerequisiteEffect "tool_rke2" `shouldBe` Validate (RequireTool "/usr/local/bin/rke2" ["--version"])
            lookupPrerequisiteEffect "tool_dhall" `shouldBe` Validate (RequireTool "dhall" ["version"])
            lookupPrerequisiteEffect "settings_loaded" `shouldBe` Validate RequireSettings
            lookupPrerequisiteEffect "settings_object" `shouldBe` Validate RequireSettings
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
                `shouldBe`
                    Right
                        [ "platform_linux",
                          "rke2_installed",
                          "rke2_service_active",
                          "rke2_service_exists",
                          "supported_ubuntu_2404",
                          "systemd_available"
                        ]
            transitiveClosureIds ["route53_accessible"] prerequisiteRegistry
                `shouldBe`
                    Right
                        [ "aws_credentials_valid",
                          "route53_accessible",
                          "settings_loaded"
                        ]
            transitiveClosureIds ["infra_ready"] prerequisiteRegistry
                `shouldBe`
                    Right
                        [ "aws_credentials_valid",
                          "infra_ready",
                          "k8s_cluster_reachable",
                          "k8s_ready",
                          "kubeconfig_exists",
                          "platform_linux",
                          "rke2_installed",
                          "rke2_service_active",
                          "rke2_service_exists",
                          "settings_loaded",
                          "supported_ubuntu_2404",
                          "systemd_available",
                          "tool_kubectl"
                        ]

    describe "native chart platform helpers" $ do
        it "derives deterministic storage bindings" $ do
            let spec =
                    ChartStorageSpec
                        { chartStorageSpecStatefulSetName = "keycloak-postgres",
                          chartStorageSpecPersistentVolumeClaimName = "keycloak-postgres-data-0",
                          chartStorageSpecStorageSize = "20Gi",
                          chartStorageSpecOrdinal = 0,
                          chartStorageSpecClaimSuffix = "data"
                        }
                binding = storageBinding "/tmp/prodbox/.data" "vscode" "keycloak-postgres" spec
            chartStorageBindingPersistentVolumeName binding
                `shouldBe` "prodbox-chart-vscode-keycloak-postgres-keycloak-postgres-0-data"
            chartStorageBindingHostPath binding
                `shouldBe` "/tmp/prodbox/.data/vscode/keycloak-postgres/keycloak-postgres/0/data"

        it "lists supported charts in canonical order" $ do
            supportedChartNames `shouldBe` ["keycloak-postgres", "keycloak", "vscode", "gateway"]

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
                                [ ( chartReleasePlanReleaseName release,
                                    eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value
                                  )
                                | release <- chartDeploymentPlanReleases plan
                                ]

                    case Map.lookup "keycloak-postgres" releaseValues of
                        Just (Right (Object payload)) ->
                            KeyMap.lookup (Key.fromString "replicaCount") payload `shouldBe` Just (Number 1)
                        _ -> expectationFailure "expected keycloak-postgres values payload"
                    case Map.lookup "keycloak" releaseValues of
                        Just (Right (Object payload)) ->
                            KeyMap.lookup (Key.fromString "replicaCount") payload `shouldBe` Just (Number 2)
                        _ -> expectationFailure "expected keycloak values payload"
                    case Map.lookup "vscode" releaseValues of
                        Just (Right (Object payload)) ->
                            KeyMap.lookup (Key.fromString "replicaCount") payload `shouldBe` Just (Number 1)
                        _ -> expectationFailure "expected vscode values payload"

                    case chartDeploymentPlanReleases plan of
                        firstRelease : _ ->
                            case chartReleasePlanStorageBindings firstRelease of
                                [binding] ->
                                    chartStorageBindingPersistentVolumeName binding
                                        `shouldBe` "prodbox-chart-vscode-keycloak-postgres-keycloak-postgres-0-data"
                                _ -> expectationFailure "expected keycloak-postgres storage binding"
                        [] -> expectationFailure "expected releases in chart deployment plan"

    describe "native gateway helpers" $ do
        it "renders deterministic gateway status output" $ do
            let payload =
                    Object
                        ( KeyMap.fromList
                            [ (Key.fromString "node_id", String "node-a"),
                              (Key.fromString "gateway_owner", String "node-a"),
                              (Key.fromString "has_active_claim", Bool True),
                              (Key.fromString "mesh_peers", Array (Vector.fromList [String "node-b"])),
                              (Key.fromString "event_count", Number 5),
                              (Key.fromString "last_public_ip_observed", String "203.0.113.10"),
                              (Key.fromString "last_dns_write_ip", String "203.0.113.10"),
                              (Key.fromString "last_dns_write_at_utc", String "2026-04-06T10:00:00Z"),
                              ( Key.fromString "dns_write_gate",
                                Object
                                    ( KeyMap.fromList
                                        [ (Key.fromString "zone_id", String "Z123"),
                                          (Key.fromString "fqdn", String "code.example.com"),
                                          (Key.fromString "ttl", Number 60)
                                        ]
                                    )
                              ),
                              ( Key.fromString "heartbeat_age_seconds",
                                Object
                                    ( KeyMap.fromList
                                        [ (Key.fromString "node-a", Number 0.0),
                                          (Key.fromString "node-b", Number 1.5)
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
                [ PortStatus 80 True "no listening socket detected",
                  PortStatus 443 False "listening socket detected"
                ]
                `shouldBe`
                    unlines
                        [ "Host port check",
                          "PORT=80 AVAILABLE=true DETAIL=no listening socket detected",
                          "PORT=443 AVAILABLE=false DETAIL=listening socket detected",
                          "Ports unavailable: 443",
                          "STATUS=busy"
                        ]

        it "parses kubectl object names into a deterministic list" $ do
            parseKubectlObjectNames "pod/alpha\n\npod/bravo\n"
                `shouldBe` ["pod/alpha", "pod/bravo"]

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
                            [ ( Key.fromString "deployment",
                                Object
                                    ( KeyMap.fromList
                                        [ ( Key.fromString "resources",
                                            Array
                                                ( Vector.fromList
                                                    [ Object
                                                        ( KeyMap.fromList
                                                            [ (Key.fromString "type", String "pulumi:providers:aws"),
                                                              (Key.fromString "delete", Bool True)
                                                            ]
                                                        ),
                                                      Object
                                                        ( KeyMap.fromList
                                                            [ (Key.fromString "type", String "aws:route53/record:Record"),
                                                              (Key.fromString "delete", Bool True)
                                                            ]
                                                        ),
                                                      Object
                                                        ( KeyMap.fromList
                                                            [ (Key.fromString "type", String "kubernetes:core/v1:Namespace"),
                                                              (Key.fromString "delete", Bool False)
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

parseArgs :: [String] -> Either String Options
parseArgs argv =
    case execParserPure defaultPrefs parserInfo argv of
        Success options -> Right options
        Failure failure ->
            let (message, _) = renderFailure failure "prodbox"
             in Left message
        CompletionInvoked _ -> Left "shell completion requested"

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
        , ", aws_admin = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
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
        , ", aws_admin = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
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
                        { access_key_id = "test-access-key",
                          secret_access_key = "test-secret-key",
                          session_token = Just "test-session-token",
                          region = "us-east-1"
                        },
                  route53 = Route53Section{zone_id = "Z1234567890ABC"},
                  domain =
                    DomainSection
                        { demo_fqdn = "test.example.com",
                          demo_ttl = 60,
                          vscode_fqdn = Just "vscode.example.com"
                        },
                  deployment =
                    DeploymentSection
                        { dev_mode = True,
                          bootstrap_public_ip_override = Nothing,
                          pulumi_enable_dns_bootstrap = True
                        },
                  storage = StorageSection{manual_pv_host_root = ".data"}
                },
          resolvedManualPvHostRoot = manualRoot
        }

testChartSecrets :: Map.Map String String
testChartSecrets =
    Map.fromList
        [ ("keycloak_admin_password", "adminpass"),
          ("keycloak_postgres_password", "pgpass"),
          ("keycloak_nginx_client_secret", "nginxsecret")
        ]
