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
  [ (["rke2", "reconcile", "--force"], "rke2 reconcile --force")
  , (["rke2", "reconcile", "--reinstall"], "rke2 reconcile --reinstall")
  , (["rke2", "install"], "rke2 install")
  , (["rke2", "install", "--force"], "rke2 install --force")
  , (["rke2", "install", "--reinstall"], "rke2 install --reinstall")
  , (["rke2", "upgrade"], "rke2 upgrade")
  , (["rke2", "repair"], "rke2 repair")
  , (["rke2", "force-install"], "rke2 force-install")
  , (["charts", "deploy", "vscode", "--force"], "charts deploy --force")
  , (["charts", "deploy", "vscode", "--reinstall"], "charts deploy --reinstall")
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
              AwsCheckQuotas -> ["check-quotas"]
              AwsRequestQuotas _ -> ["request-quotas"]
        NativeCharts chartsCommand ->
          "charts"
            : case chartsCommand of
              ChartsList -> ["list"]
              ChartsStatus _ -> ["status"]
              ChartsDeploy {} -> ["deploy"]
              ChartsDelete {} -> ["delete"]
        NativeCheckCode -> ["check-code"]
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
          "docs"
            : case docsCommand of
              DocsCheck -> ["check"]
              DocsGenerate -> ["generate"]
        NativeGateway gatewayCommand ->
          "gateway"
            : case gatewayCommand of
              GatewayDaemonCommand _ -> ["start"]
              GatewayStatusCommand _ -> ["status"]
              GatewayConfigGen _ _ -> ["config-gen"]
        NativeHost hostCommand ->
          "host"
            : case hostCommand of
              HostEnsureTools -> ["ensure-tools"]
              HostCheckPorts -> ["check-ports"]
              HostInfo -> ["info"]
              HostFirewall -> ["firewall"]
              HostPublicEdge _ -> ["public-edge"]
        NativeK8s k8sCommand ->
          "k8s"
            : case k8sCommand of
              K8sHealth -> ["health"]
              K8sWait _ _ -> ["wait"]
              K8sLogs _ _ -> ["logs"]
        NativeLint lintCommand ->
          "lint"
            : case lintCommand of
              LintAll -> ["all"]
              LintFiles _ -> ["files"]
              LintDocs _ -> ["docs"]
              LintHaskell _ -> ["haskell"]
              LintChart -> ["chart"]
        NativePulumi pulumiCommand ->
          "pulumi"
            : case pulumiCommand of
              PulumiEksResources _ -> ["eks-resources"]
              PulumiEksDestroy _ _ -> ["eks-destroy"]
              PulumiTestResources _ -> ["test-resources"]
              PulumiTestDestroy _ _ -> ["test-destroy"]
              PulumiAwsSubzoneResources _ -> ["aws-subzone-resources"]
              PulumiAwsSubzoneDestroy _ _ -> ["aws-subzone-destroy"]
              PulumiAwsSesResources _ -> ["aws-ses-resources"]
              PulumiAwsSesDestroy _ _ -> ["aws-ses-destroy"]
              PulumiAwsSesMigrateBackend _ -> ["aws-ses-migrate-backend"]
        NativeRke2 rke2Command ->
          "rke2"
            : case rke2Command of
              Rke2Status -> ["status"]
              Rke2Start -> ["start"]
              Rke2Stop -> ["stop"]
              Rke2Restart -> ["restart"]
              Rke2Reconcile _ -> ["reconcile"]
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
        NativeTlaCheck -> ["tla-check"]
        NativeUsers usersCommand ->
          "users"
            : case usersCommand of
              UsersInvite {} -> ["invite"]
              UsersList _ -> ["list"]
              UsersRevoke {} -> ["revoke"]
        NativeWorkload workloadCommand ->
          "workload"
            : case workloadCommand of
              WorkloadStart _ -> ["start"]
