module Parser
  ( parserSuite
  )
where

import Data.Set qualified as Set
import Options.Applicative
  ( ParserResult (..)
  , defaultPrefs
  , execParserPure
  , renderFailure
  )
import Prodbox.CLI.Command
  ( AwsCommand (..)
  , ChartsCommand (..)
  , CommandListingFormat (..)
  , CommandRequest (..)
  , ConfigCommand (..)
  , DnsCommand (..)
  , DocsCommand (..)
  , EdgeCommand (..)
  , GatewayCommand (..)
  , HostCommand (..)
  , IntegrationSuite (..)
  , K8sCommand (..)
  , LintCommand (..)
  , NativeCommand (..)
  , PulumiCommand (..)
  , Rke2Command (..)
  , TestCommand (..)
  , TestScope (..)
  , UsersCommand (..)
  , VaultCommand (..)
  , WorkloadCommand (..)
  )
import Prodbox.CLI.Parser
  ( Options (..)
  , parserInfo
  , validateCommandArgv
  )
import Prodbox.CLI.Spec
  ( CommandSpec (..)
  , Example (..)
  , commandRegistry
  , leafCommandPaths
  )
import TestSupport

parserSuite :: SuiteBuilder ()
parserSuite =
  describe "CLI parser coverage" $ do
    propertyTest "every leaf command has at least one example" leafExampleCoverageProperty
    propertyTest
      "every leaf example roundtrips to its registered command path"
      leafParserRoundtripProperty
    mapM_ happyCase (collectLeafExamples commandRegistry)
    mapM_ unhappyCase (collectLeafExamples commandRegistry)
    mapM_ forbiddenCase forbiddenArgvCases

happyCase :: ([String], Example) -> SuiteBuilder ()
happyCase (commandPath, exampleSpec) =
  it ("accepts " ++ unwords ("prodbox" : commandPath)) $
    parseArgs (exampleCommand exampleSpec) `shouldSatisfy` isRight

unhappyCase :: ([String], Example) -> SuiteBuilder ()
unhappyCase (commandPath, exampleSpec) =
  it ("rejects unsupported flag for " ++ unwords ("prodbox" : commandPath)) $
    parseArgs (exampleCommand exampleSpec ++ ["--definitely-unsupported-flag"])
      `shouldSatisfy` isLeft

forbiddenCase :: ([String], String) -> SuiteBuilder ()
forbiddenCase (argv, label) =
  it ("rejects forbidden reconciler surface " ++ label) $
    case parseArgs argv of
      Left message -> message `shouldContain` "Forbidden"
      Right _ -> expectationFailure ("expected parse failure for " ++ unwords ("prodbox" : argv))

forbiddenArgvCases :: [([String], String)]
forbiddenArgvCases =
  [ (["cluster", "reconcile", "--force"], "cluster reconcile --force")
  , (["cluster", "reconcile", "--reinstall"], "cluster reconcile --reinstall")
  , (["cluster", "install"], "cluster install")
  , (["cluster", "install", "--force"], "cluster install --force")
  , (["cluster", "install", "--reinstall"], "cluster install --reinstall")
  , (["cluster", "upgrade"], "cluster upgrade")
  , (["cluster", "repair"], "cluster repair")
  , (["cluster", "force-install"], "cluster force-install")
  , (["charts", "reconcile", "vscode", "--force"], "charts reconcile --force")
  , (["charts", "reconcile", "vscode", "--reinstall"], "charts reconcile --reinstall")
  , (["charts", "delete", "vscode", "--force"], "charts delete --force")
  , (["charts", "delete", "vscode", "--reinstall"], "charts delete --reinstall")
  , (["charts", "install", "vscode"], "charts install")
  , (["charts", "upgrade", "vscode"], "charts upgrade")
  , (["charts", "repair", "vscode"], "charts repair")
  , (["charts", "force-install", "vscode"], "charts force-install")
  ]

leafExampleCoverageProperty :: Bool
leafExampleCoverageProperty =
  Set.fromList (map fst (collectLeafExamples commandRegistry)) == Set.fromList leafCommandPaths

leafParserRoundtripProperty :: Bool
leafParserRoundtripProperty =
  all roundtrips (collectLeafExamples commandRegistry)
 where
  roundtrips (commandPath, exampleSpec) =
    case parseArgs (exampleCommand exampleSpec) of
      Right options -> commandPathOfRequest (optRequest options) == commandPath
      Left _ -> False

collectLeafExamples :: CommandSpec -> [([String], Example)]
collectLeafExamples = go []
 where
  go prefix spec =
    let commandPath =
          if name spec == "prodbox"
            then prefix
            else prefix ++ [name spec]
     in case children spec of
          [] ->
            case examples spec of
              firstExample : _ -> [(commandPath, firstExample)]
              [] -> []
          nested -> concatMap (go commandPath) nested

parseArgs :: [String] -> Either String Options
parseArgs argv =
  case validateCommandArgv argv of
    Left err -> Left err
    Right () ->
      case execParserPure defaultPrefs parserInfo argv of
        Success options -> Right options
        Failure failure -> Left (fst (renderFailure failure "prodbox"))
        CompletionInvoked _ -> Left "shell completion requested"

isLeft :: Either left right -> Bool
isLeft eitherValue =
  case eitherValue of
    Left _ -> True
    Right _ -> False

isRight :: Either left right -> Bool
isRight eitherValue =
  case eitherValue of
    Left _ -> False
    Right _ -> True

commandPathOfRequest :: CommandRequest -> [String]
commandPathOfRequest request =
  case request of
    ShowCommands format ->
      case format of
        CommandsPlain -> ["commands"]
        CommandsTree -> ["commands"]
        CommandsJson -> ["commands"]
    ShowHelp _ -> ["help"]
    RunNative nativeCommand ->
      case nativeCommand of
        NativeAws awsCommand ->
          "aws"
            : case awsCommand of
              AwsPolicy _ -> ["policy"]
              AwsSetup _ _ -> ["setup"]
              AwsTeardown _ _ -> ["teardown"]
              AwsCheckQuotas -> ["quotas", "check"]
              AwsRequestQuotas _ -> ["quotas", "request"]
        NativeCharts chartsCommand ->
          "charts"
            : case chartsCommand of
              ChartsList -> ["list"]
              ChartsStatus _ -> ["status"]
              ChartsDeploy {} -> ["reconcile"]
              ChartsDelete {} -> ["delete"]
        NativeCheckCode -> ["dev", "check"]
        NativeConfig configCommand ->
          "config"
            : case configCommand of
              ConfigSetup _ -> ["setup"]
              ConfigShow _ -> ["show"]
              ConfigValidate -> ["validate"]
        NativeDns dnsCommand ->
          "dns"
            : case dnsCommand of
              DnsCheck -> ["check"]
        NativeDocs docsCommand ->
          ["dev", "docs"]
            ++ case docsCommand of
              DocsCheck -> ["check"]
              DocsGenerate -> ["generate"]
        NativeGateway gatewayCommand ->
          "gateway"
            : case gatewayCommand of
              GatewayDaemonCommand _ -> ["start"]
              GatewayStatusCommand _ -> ["status"]
              GatewayConfigGen _ _ -> ["config-gen"]
        NativeHost hostCommand ->
          case hostCommand of
            HostEnsureTools -> ["host", "ensure-tools"]
            HostCheckPorts -> ["host", "check-ports"]
            HostInfo -> ["host", "info"]
            HostFirewall -> ["host", "firewall"]
            HostFirewallGatewayRestrict _ -> ["host", "firewall", "gateway-restrict"]
            HostFirewallGatewayUnrestrict _ -> ["host", "firewall", "gateway-unrestrict"]
            -- Regrouped under `edge status` (Phase 5); the handler still
            -- routes through 'HostPublicEdge'.
            HostPublicEdge _ -> ["edge", "status"]
        NativeEdge edgeCommand ->
          "edge"
            : case edgeCommand of
              EdgeReconcile _ -> ["reconcile"]
        NativeK8s k8sCommand ->
          "cluster"
            : case k8sCommand of
              K8sHealth -> ["health"]
              K8sWait _ _ -> ["wait"]
              K8sLogs _ _ -> ["workload-logs"]
        NativeLint lintCommand ->
          ["dev", "lint"]
            ++ case lintCommand of
              LintAll -> ["all"]
              LintFiles _ -> ["files"]
              LintDocs _ -> ["docs"]
              LintHaskell _ -> ["haskell"]
              LintChart -> ["chart"]
        NativePulumi pulumiCommand ->
          ["aws", "stack"]
            ++ case pulumiCommand of
              PulumiEksResources _ -> ["eks", "reconcile"]
              PulumiEksDestroy _ _ -> ["eks", "destroy"]
              PulumiTestResources _ -> ["test", "reconcile"]
              PulumiTestDestroy _ _ -> ["test", "destroy"]
              PulumiAwsSubzoneResources _ -> ["aws-subzone", "reconcile"]
              PulumiAwsSubzoneDestroy _ _ -> ["aws-subzone", "destroy"]
              PulumiAwsSesResources _ -> ["aws-ses", "reconcile"]
              PulumiAwsSesDestroy _ _ -> ["aws-ses", "destroy"]
              PulumiAwsSesMigrateBackend _ -> ["aws-ses", "migrate-backend"]
        NativeRke2 rke2Command ->
          "cluster"
            : case rke2Command of
              Rke2Status -> ["status"]
              Rke2Start -> ["start"]
              Rke2Stop -> ["stop"]
              Rke2Restart -> ["restart"]
              Rke2Reconcile _ _ -> ["reconcile"]
              Rke2Delete _ _ -> ["delete"]
              Rke2Logs _ -> ["logs"]
        NativeTest testCommand ->
          "test"
            : case testScope testCommand of
              TestAll -> ["all"]
              TestLint -> ["lint"]
              TestUnit -> ["unit"]
              TestIntegration integrationSuite ->
                "integration"
                  : case integrationSuite of
                    IntegrationAll -> ["all"]
                    IntegrationCli -> ["cli"]
                    IntegrationAwsIam -> ["aws-iam"]
                    IntegrationDnsAws -> ["dns-aws"]
                    IntegrationAwsEks -> ["aws-eks"]
                    IntegrationEnv -> ["env"]
                    IntegrationGatewayDaemon -> ["gateway-daemon"]
                    IntegrationGatewayPods -> ["gateway-pods"]
                    IntegrationGatewayPartition -> ["gateway-partition"]
                    IntegrationHaRke2Aws -> ["ha-rke2-aws"]
                    IntegrationLifecycle -> ["lifecycle"]
                    IntegrationPulumi -> ["pulumi"]
                    IntegrationChartsStorage -> ["charts-storage"]
                    IntegrationChartsPlatform -> ["charts-platform"]
                    IntegrationChartsVscode -> ["charts-vscode"]
                    IntegrationChartsApi -> ["charts-api"]
                    IntegrationChartsWebsocket -> ["charts-websocket"]
                    IntegrationAdminRoutes -> ["admin-routes"]
                    IntegrationPublicDns -> ["public-dns"]
                    IntegrationKeycloakInvite -> ["keycloak-invite"]
        NativeNuke _ -> ["nuke"]
        NativeTlaCheck -> ["dev", "tla-check"]
        NativeUsers usersCommand ->
          "users"
            : case usersCommand of
              UsersInvite {} -> ["invite"]
              UsersList _ -> ["list"]
              UsersRevoke {} -> ["revoke"]
        NativeVault vaultCommand ->
          "vault"
            : case vaultCommand of
              VaultStatus -> ["status"]
              VaultInit -> ["init"]
              VaultUnseal -> ["unseal"]
              VaultSeal -> ["seal"]
              VaultReconcile -> ["reconcile"]
              VaultRotateUnlockBundle -> ["rotate-unlock-bundle"]
              VaultRotateTransitKey _ -> ["rotate-transit-key"]
              VaultPkiStatus -> ["pki", "status"]
              VaultPkiIssueTestCert -> ["pki", "issue-test-cert"]
        NativeWorkload workloadCommand ->
          "workload"
            : case workloadCommand of
              WorkloadStart _ -> ["start"]
