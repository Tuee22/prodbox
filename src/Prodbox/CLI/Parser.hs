module Prodbox.CLI.Parser
  ( Options (..)
  , parserInfo
  , validateCommandArgv
  )
where

import Control.Applicative ((<|>))
import Data.Version (showVersion)
import Options.Applicative
  ( Parser
  , ParserInfo
  , auto
  , command
  , eitherReader
  , flag
  , flag'
  , fullDesc
  , help
  , helper
  , hsubparser
  , info
  , infoOption
  , long
  , many
  , metavar
  , option
  , optional
  , progDesc
  , short
  , some
  , strArgument
  , strOption
  , switch
  , value
  , (<**>)
  )
import Paths_prodbox (version)
import Prodbox.CLI.Command
  ( AwsCommand (..)
  , ChartsCommand (..)
  , CommandListingFormat (..)
  , CommandRequest (..)
  , ConfigCommand (..)
  , CoverageFlags (..)
  , DaemonLaunchOptions (..)
  , DaemonStatusOptions (..)
  , DnsCommand (..)
  , DocsCommand (..)
  , GatewayCommand (..)
  , HostCommand (..)
  , IntegrationSuite (..)
  , K8sCommand (..)
  , LintCommand (..)
  , NativeCommand (..)
  , PlanOptions (..)
  , PolicyTier (..)
  , PulumiCommand (..)
  , Rke2Command (..)
  , TestCommand (..)
  , TestScope (..)
  , WorkloadCommand (..)
  , WorkloadOptions (..)
  )
import Prodbox.K8s (defaultInfrastructureNamespaces)

data Options = Options
  { optVerbose :: Bool
  , optRequest :: CommandRequest
  }
  deriving (Eq, Show)

parserInfo :: ParserInfo Options
parserInfo =
  info
    (optionsParser <**> helper <**> versionOption)
    ( fullDesc
        <> progDesc
          "prodbox - Haskell CLI frontend for the current repository command surface"
    )

validateCommandArgv :: [String] -> Either String ()
validateCommandArgv argv =
  case forbiddenArgvMessage argv of
    Just message -> Left message
    Nothing -> Right ()

optionsParser :: Parser Options
optionsParser =
  Options
    <$> switch
      ( long "verbose"
          <> short 'v'
          <> help "Enable verbose output"
      )
    <*> commandParser

versionOption :: Parser (a -> a)
versionOption =
  infoOption
    (showVersion version)
    ( long "version"
        <> help "Show version"
    )

commandParser :: Parser CommandRequest
commandParser =
  hsubparser
    ( command "aws" (info awsParser (progDesc "AWS IAM and quota management"))
        <> command "charts" (info chartsParser (progDesc "Bespoke Helm chart lifecycle"))
        <> command
          "check-code"
          (info (pure (RunNative NativeCheckCode)) (progDesc "Run policy, lint, and type checks"))
        <> command "commands" (info commandsParser (progDesc "Render the command registry"))
        <> command "config" (info configParser (progDesc "Configuration management"))
        <> command "dns" (info dnsParser (progDesc "Route 53 inspection"))
        <> command "docs" (info docsParser (progDesc "Generated-documentation maintenance"))
        <> command "gateway" (info gatewayParser (progDesc "Gateway daemon operations"))
        <> command "help" (info helpParser (progDesc "Render help for a command path"))
        <> command "host" (info hostParser (progDesc "Host prerequisite checks"))
        <> command "k8s" (info k8sParser (progDesc "Kubernetes health and log utilities"))
        <> command "lint" (info lintParser (progDesc "Doctrine lint surfaces"))
        <> command "pulumi" (info pulumiParser (progDesc "AWS validation infrastructure"))
        <> command "rke2" (info rke2Parser (progDesc "Local cluster lifecycle"))
        <> command "test" (info testParser (progDesc "Named test suites"))
        <> command "tla-check" (info (native NativeTlaCheck) (progDesc "Run TLA+ checks"))
        <> command "workload" (info workloadParser (progDesc "Internal public workload runtime"))
    )

native :: NativeCommand -> Parser CommandRequest
native = pure . RunNative

commandsParser :: Parser CommandRequest
commandsParser =
  commandsTreeParser <|> commandsJsonParser <|> pure (ShowCommands CommandsPlain)

commandsTreeParser :: Parser CommandRequest
commandsTreeParser =
  flag'
    (ShowCommands CommandsTree)
    ( long "tree"
        <> help "Render the command registry as a tree"
    )

commandsJsonParser :: Parser CommandRequest
commandsJsonParser =
  flag'
    (ShowCommands CommandsJson)
    ( long "json"
        <> help "Render the command registry as JSON"
    )

helpParser :: Parser CommandRequest
helpParser = ShowHelp <$> some (strArgument (metavar "COMMAND_PATH"))

coverageFlagsParser :: Parser CoverageFlags
coverageFlagsParser =
  CoverageFlags
    <$> switch
      ( long "coverage"
          <> help "Enable coverage reporting for the selected test scope"
      )
    <*> optional
      ( option
          auto
          ( long "cov-fail-under"
              <> metavar "INTEGER"
              <> help "Require a minimum coverage percentage"
          )
      )

planOptionsParser :: Parser PlanOptions
planOptionsParser =
  PlanOptions
    <$> switch
      ( long "dry-run"
          <> help "Render the plan without mutating state"
      )
    <*> optional
      ( strOption
          ( long "plan-file"
              <> metavar "PATH"
              <> help "Write the rendered plan to a file"
          )
      )

foregroundParser :: Parser Bool
foregroundParser =
  flag
    True
    True
    ( long "foreground"
        <> help "Run in the foreground"
    )

withCoverage :: TestScope -> Parser CommandRequest
withCoverage scope =
  fmap (RunNative . NativeTest . TestCommand scope) coverageFlagsParser

configParser :: Parser CommandRequest
configParser =
  hsubparser
    ( command "setup" (info configSetupParser (progDesc "Interactively author config"))
        <> command "show" (info configShowParser (progDesc "Display current config"))
        <> command
          "validate"
          (info (native (NativeConfig ConfigValidate)) (progDesc "Validate current config"))
    )

configSetupParser :: Parser CommandRequest
configSetupParser =
  fmap (RunNative . NativeConfig . ConfigSetup) planOptionsParser

configShowParser :: Parser CommandRequest
configShowParser =
  fmap
    (\showSecrets -> RunNative (NativeConfig (ConfigShow showSecrets)))
    ( switch
        ( long "show-secrets"
            <> help "Show full secret values"
        )
    )

awsParser :: Parser CommandRequest
awsParser =
  hsubparser
    ( command "policy" (info awsPolicyParser (progDesc "Render IAM policy JSON"))
        <> command "setup" (info awsSetupParser (progDesc "Create or refresh operational IAM user"))
        <> command "teardown" (info awsTeardownParser (progDesc "Delete operational IAM user"))
        <> command
          "check-quotas"
          (info (native (NativeAws AwsCheckQuotas)) (progDesc "Inspect supported AWS quotas"))
        <> command "request-quotas" (info awsRequestQuotasParser (progDesc "Request supported AWS quotas"))
    )

awsPolicyParser :: Parser CommandRequest
awsPolicyParser =
  fmap
    (RunNative . NativeAws . AwsPolicy)
    (tierOptionParser PolicyCore "Operational IAM policy tier to render")

awsSetupParser :: Parser CommandRequest
awsSetupParser =
  fmap
    (\(policyTier, planOptions') -> RunNative (NativeAws (AwsSetup policyTier planOptions')))
    ( (,) <$> tierOptionParser PolicyFull "Operational IAM policy tier to provision" <*> planOptionsParser
    )

awsTeardownParser :: Parser CommandRequest
awsTeardownParser =
  fmap (RunNative . NativeAws . AwsTeardown) planOptionsParser

awsRequestQuotasParser :: Parser CommandRequest
awsRequestQuotasParser =
  fmap
    (RunNative . NativeAws . AwsRequestQuotas)
    (tierOptionParser PolicyFull "Quota target tier to request")

hostParser :: Parser CommandRequest
hostParser =
  hsubparser
    ( command
        "ensure-tools"
        (info (native (NativeHost HostEnsureTools)) (progDesc "Verify required host tools"))
        <> command "check-ports" (info (native (NativeHost HostCheckPorts)) (progDesc "Check required ports"))
        <> command "info" (info (native (NativeHost HostInfo)) (progDesc "Display host diagnostics"))
        <> command
          "firewall"
          (info (native (NativeHost HostFirewall)) (progDesc "Check firewall requirements"))
        <> command
          "public-edge"
          (info (native (NativeHost HostPublicEdge)) (progDesc "Check public DNS/TLS edge state"))
    )

rke2Parser :: Parser CommandRequest
rke2Parser =
  hsubparser
    ( command "status" (info (native (NativeRke2 Rke2Status)) (progDesc "Check RKE2 status"))
        <> command "start" (info (native (NativeRke2 Rke2Start)) (progDesc "Start RKE2"))
        <> command "stop" (info (native (NativeRke2 Rke2Stop)) (progDesc "Stop RKE2"))
        <> command "restart" (info (native (NativeRke2 Rke2Restart)) (progDesc "Restart RKE2"))
        <> command "reconcile" (info rke2ReconcileParser (progDesc "Reconcile RKE2"))
        <> command "install" (info rke2InstallParser (progDesc "Deprecated alias for reconcile"))
        <> command "delete" (info rke2DeleteParser (progDesc "Delete RKE2"))
        <> command "logs" (info rke2LogsParser (progDesc "Show RKE2 logs"))
    )

rke2ReconcileParser :: Parser CommandRequest
rke2ReconcileParser =
  fmap (RunNative . NativeRke2 . Rke2Reconcile) planOptionsParser

rke2InstallParser :: Parser CommandRequest
rke2InstallParser =
  fmap (RunNative . NativeRke2 . Rke2Install) planOptionsParser

rke2DeleteParser :: Parser CommandRequest
rke2DeleteParser =
  fmap (RunNative . NativeRke2 . Rke2Delete) (yesSwitchParser "Confirm full RKE2 cluster deletion")

rke2LogsParser :: Parser CommandRequest
rke2LogsParser =
  fmap
    (RunNative . NativeRke2 . Rke2Logs)
    ( optional
        ( option
            auto
            ( long "lines"
                <> short 'n'
                <> metavar "INTEGER"
                <> help "Number of log lines to show"
            )
        )
    )

pulumiParser :: Parser CommandRequest
pulumiParser =
  hsubparser
    ( command
        "eks-resources"
        (info pulumiEksResourcesParser (progDesc "Provision or inspect EKS test stack"))
        <> command "eks-destroy" (info pulumiYesParserEksDestroy (progDesc "Destroy EKS test stack"))
        <> command
          "test-resources"
          (info pulumiTestResourcesParser (progDesc "Provision or inspect HA RKE2 test stack"))
        <> command "test-destroy" (info pulumiYesParserTestDestroy (progDesc "Destroy HA RKE2 test stack"))
    )

pulumiEksResourcesParser :: Parser CommandRequest
pulumiEksResourcesParser =
  fmap (RunNative . NativePulumi . PulumiEksResources) planOptionsParser

pulumiYesParserEksDestroy :: Parser CommandRequest
pulumiYesParserEksDestroy =
  fmap
    (\(confirmed, planOptions') -> RunNative (NativePulumi (PulumiEksDestroy confirmed planOptions')))
    ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)

pulumiTestResourcesParser :: Parser CommandRequest
pulumiTestResourcesParser =
  fmap (RunNative . NativePulumi . PulumiTestResources) planOptionsParser

pulumiYesParserTestDestroy :: Parser CommandRequest
pulumiYesParserTestDestroy =
  fmap
    (\(confirmed, planOptions') -> RunNative (NativePulumi (PulumiTestDestroy confirmed planOptions')))
    ((,) <$> yesSwitchParser "Skip confirmation prompts" <*> planOptionsParser)

dnsParser :: Parser CommandRequest
dnsParser =
  hsubparser
    (command "check" (info (native (NativeDns DnsCheck)) (progDesc "Inspect Route 53 state")))

k8sParser :: Parser CommandRequest
k8sParser =
  hsubparser
    ( command "health" (info (native (NativeK8s K8sHealth)) (progDesc "Check cluster health"))
        <> command "wait" (info k8sWaitParser (progDesc "Wait for deployments to be ready"))
        <> command "logs" (info k8sLogsParser (progDesc "Show recent infrastructure logs"))
    )

k8sWaitParser :: Parser CommandRequest
k8sWaitParser =
  fmap
    ( \(timeoutSeconds, namespaces) -> RunNative (NativeK8s (K8sWait (maybe 300 id timeoutSeconds) (defaultNamespaces namespaces)))
    )
    ( (,)
        <$> optional
          ( option
              auto
              ( long "timeout"
                  <> short 't'
                  <> metavar "INTEGER"
                  <> help "Timeout in seconds"
              )
          )
        <*> manyStringsOption "namespace" 'n' "Namespace to wait for"
    )

k8sLogsParser :: Parser CommandRequest
k8sLogsParser =
  fmap
    ( \(namespaces, tailLines) -> RunNative (NativeK8s (K8sLogs (defaultNamespaces namespaces) (maybe 10 id tailLines)))
    )
    ( (,)
        <$> manyStringsOption "namespace" 'n' "Namespace to get logs from"
        <*> optional
          ( option
              auto
              ( long "tail"
                  <> metavar "INTEGER"
                  <> help "Number of log lines per container"
              )
          )
    )

gatewayParser :: Parser CommandRequest
gatewayParser =
  hsubparser
    ( command "start" (info gatewayStartParser (progDesc "Start gateway daemon"))
        <> command "status" (info gatewayStatusParser (progDesc "Query gateway daemon status"))
        <> command "config-gen" (info gatewayConfigGenParser (progDesc "Generate gateway config"))
    )

gatewayStartParser :: Parser CommandRequest
gatewayStartParser =
  fmap
    (RunNative . NativeGateway . GatewayDaemonCommand)
    daemonLaunchOptionsParser

gatewayStatusParser :: Parser CommandRequest
gatewayStatusParser =
  fmap
    (RunNative . NativeGateway . GatewayStatusCommand)
    daemonStatusOptionsParser

gatewayConfigGenParser :: Parser CommandRequest
gatewayConfigGenParser =
  fmap
    (\(outputPath, nodeId) -> RunNative (NativeGateway (GatewayConfigGen outputPath nodeId)))
    ( (,)
        <$> strArgument (metavar "OUTPUT_PATH")
        <*> strOption
          ( long "node-id"
              <> metavar "NODE_ID"
              <> help "Node ID for the generated config"
          )
    )

workloadParser :: Parser CommandRequest
workloadParser =
  hsubparser
    ( command
        "start"
        (info workloadStartParser (progDesc "Start the internal public workload runtime"))
    )

workloadStartParser :: Parser CommandRequest
workloadStartParser =
  fmap (RunNative . NativeWorkload . WorkloadStart) workloadOptionsParser

chartsParser :: Parser CommandRequest
chartsParser =
  hsubparser
    ( command "list" (info (native (NativeCharts ChartsList)) (progDesc "List supported charts"))
        <> command "status" (info chartsStatusParser (progDesc "Show detailed chart status"))
        <> command "deploy" (info chartsDeployParser (progDesc "Deploy a root chart stack"))
        <> command "delete" (info chartsDeleteParser (progDesc "Delete a root chart stack"))
    )

chartsStatusParser :: Parser CommandRequest
chartsStatusParser =
  fmap (RunNative . NativeCharts . ChartsStatus) (strArgument (metavar "CHART"))

chartsDeployParser :: Parser CommandRequest
chartsDeployParser =
  fmap
    (\(chartName, options') -> RunNative (NativeCharts (ChartsDeploy chartName options')))
    ((,) <$> strArgument (metavar "CHART") <*> planOptionsParser)

chartsDeleteParser :: Parser CommandRequest
chartsDeleteParser =
  ( \chartName confirmed options' -> RunNative (NativeCharts (ChartsDelete chartName confirmed options'))
  )
    <$> strArgument (metavar "CHART")
    <*> yesSwitchParser "Skip confirmation prompt"
    <*> planOptionsParser

testParser :: Parser CommandRequest
testParser =
  hsubparser
    ( command "all" (info (withCoverage TestAll) (progDesc "Run the full test suite"))
        <> command
          "lint"
          ( info
              (native (NativeTest (TestCommand TestLint (CoverageFlags False Nothing))))
              (progDesc "Run lint and build checks")
          )
        <> command "unit" (info (withCoverage TestUnit) (progDesc "Run unit tests"))
        <> command "integration" (info integrationParser (progDesc "Run named integration suites"))
    )

docsParser :: Parser CommandRequest
docsParser =
  hsubparser
    ( command "check" (info (native (NativeDocs DocsCheck)) (progDesc "Check generated docs for drift"))
        <> command
          "generate"
          (info (native (NativeDocs DocsGenerate)) (progDesc "Regenerate generated docs"))
    )

lintParser :: Parser CommandRequest
lintParser =
  hsubparser
    ( command "all" (info (native (NativeLint LintAll)) (progDesc "Run every lint surface"))
        <> command "files" (info lintFilesParser (progDesc "Run repository-policy lint checks"))
        <> command "docs" (info lintDocsParser (progDesc "Check generated documentation sections"))
        <> command "haskell" (info lintHaskellParser (progDesc "Run Haskell formatter and lint checks"))
        <> command
          "chart"
          (info (native (NativeLint LintChart)) (progDesc "Run Helm chart structural lint checks"))
    )

lintFilesParser :: Parser CommandRequest
lintFilesParser =
  fmap (RunNative . NativeLint . LintFiles) writeSwitchParser

lintDocsParser :: Parser CommandRequest
lintDocsParser =
  fmap (RunNative . NativeLint . LintDocs) writeSwitchParser

lintHaskellParser :: Parser CommandRequest
lintHaskellParser =
  fmap (RunNative . NativeLint . LintHaskell) writeSwitchParser

daemonLaunchOptionsParser :: Parser DaemonLaunchOptions
daemonLaunchOptionsParser =
  DaemonLaunchOptions
    <$> optional
      ( strOption
          ( long "config"
              <> metavar "PATH"
              <> help "Gateway config path"
          )
      )
    <*> optional
      ( strOption
          ( long "log-level"
              <> metavar "LEVEL"
              <> help "Override daemon log level"
          )
      )
    <*> optional
      ( option
          auto
          ( long "port"
              <> metavar "INTEGER"
              <> help "Override daemon port"
          )
      )
    <*> foregroundParser
    <*> planOptionsParser

daemonStatusOptionsParser :: Parser DaemonStatusOptions
daemonStatusOptionsParser =
  fmap
    DaemonStatusOptions
    ( optional
        ( strOption
            ( long "config"
                <> metavar "PATH"
                <> help "Gateway config path"
            )
        )
    )

workloadOptionsParser :: Parser WorkloadOptions
workloadOptionsParser =
  WorkloadOptions
    <$> optional
      ( strOption
          ( long "log-level"
              <> metavar "LEVEL"
              <> help "Override daemon log level"
          )
      )
    <*> optional
      ( option
          auto
          ( long "port"
              <> metavar "INTEGER"
              <> help "Override daemon port"
          )
      )
    <*> foregroundParser

writeSwitchParser :: Parser Bool
writeSwitchParser =
  switch
    ( long "write"
        <> help "Rewrite the target surface instead of only checking for drift"
    )

integrationParser :: Parser CommandRequest
integrationParser =
  hsubparser
    ( command
        "all"
        (info (withCoverage (TestIntegration IntegrationAll)) (progDesc "Run all integration suites"))
        <> command
          "cli"
          (info (withCoverage (TestIntegration IntegrationCli)) (progDesc "Run CLI integration tests"))
        <> command
          "aws-iam"
          (info (withCoverage (TestIntegration IntegrationAwsIam)) (progDesc "Run AWS IAM integration tests"))
        <> command
          "dns-aws"
          ( info (withCoverage (TestIntegration IntegrationDnsAws)) (progDesc "Run Route 53 integration tests")
          )
        <> command
          "aws-eks"
          (info (withCoverage (TestIntegration IntegrationAwsEks)) (progDesc "Run EKS integration tests"))
        <> command
          "env"
          ( info (withCoverage (TestIntegration IntegrationEnv)) (progDesc "Run environment integration tests")
          )
        <> command
          "gateway-daemon"
          ( info
              (withCoverage (TestIntegration IntegrationGatewayDaemon))
              (progDesc "Run gateway-daemon integration tests")
          )
        <> command
          "gateway-pods"
          ( info
              (withCoverage (TestIntegration IntegrationGatewayPods))
              (progDesc "Run gateway pod integration tests")
          )
        <> command
          "gateway-partition"
          ( info
              (withCoverage (TestIntegration IntegrationGatewayPartition))
              (progDesc "Run gateway partition integration tests")
          )
        <> command
          "ha-rke2-aws"
          ( info
              (withCoverage (TestIntegration IntegrationHaRke2Aws))
              (progDesc "Run HA RKE2 AWS integration tests")
          )
        <> command
          "lifecycle"
          ( info
              (withCoverage (TestIntegration IntegrationLifecycle))
              (progDesc "Run lifecycle integration tests")
          )
        <> command
          "pulumi"
          (info (withCoverage (TestIntegration IntegrationPulumi)) (progDesc "Run Pulumi integration tests"))
        <> command
          "charts-storage"
          ( info
              (withCoverage (TestIntegration IntegrationChartsStorage))
              (progDesc "Run chart-storage integration tests")
          )
        <> command
          "charts-platform"
          ( info
              (withCoverage (TestIntegration IntegrationChartsPlatform))
              (progDesc "Run chart-platform integration tests")
          )
        <> command
          "charts-vscode"
          ( info
              (withCoverage (TestIntegration IntegrationChartsVscode))
              (progDesc "Run vscode stack integration tests")
          )
        <> command
          "charts-api"
          ( info
              (withCoverage (TestIntegration IntegrationChartsApi))
              (progDesc "Run API stack integration tests")
          )
        <> command
          "charts-websocket"
          ( info
              (withCoverage (TestIntegration IntegrationChartsWebsocket))
              (progDesc "Run WebSocket stack integration tests")
          )
        <> command
          "admin-routes"
          ( info
              (withCoverage (TestIntegration IntegrationAdminRoutes))
              (progDesc "Run shared-host admin-route integration tests")
          )
        <> command
          "public-dns"
          ( info
              (withCoverage (TestIntegration IntegrationPublicDns))
              (progDesc "Run public DNS integration tests")
          )
    )

yesSwitchParser :: String -> Parser Bool
yesSwitchParser helpText =
  switch
    ( long "yes"
        <> short 'y'
        <> help helpText
    )

defaultNamespaces :: [String] -> [String]
defaultNamespaces namespaces =
  case namespaces of
    [] -> defaultInfrastructureNamespaces
    _ -> namespaces

tierOptionParser :: PolicyTier -> String -> Parser PolicyTier
tierOptionParser defaultTier helpText =
  option
    (eitherReader parseTier)
    ( long "tier"
        <> value defaultTier
        <> metavar "TIER"
        <> help helpText
    )

parseTier :: String -> Either String PolicyTier
parseTier rawTier =
  case rawTier of
    "core" -> Right PolicyCore
    "full" -> Right PolicyFull
    _ -> Left "--tier must be one of: core, full"

manyStringsOption :: String -> Char -> String -> Parser [String]
manyStringsOption longName shortName helpText =
  many
    ( strOption
        ( long longName
            <> short shortName
            <> metavar "VALUE"
            <> help helpText
        )
    )

forbiddenArgvMessage :: [String] -> Maybe String
forbiddenArgvMessage argv
  | isRke2ForbiddenFlag argv =
      Just
        "Forbidden lifecycle flags: use `prodbox rke2 reconcile` as the idempotent reconciler; `--force` and `--reinstall` are not supported."
  | isRke2ForbiddenSister argv =
      Just
        "Forbidden lifecycle command: use `prodbox rke2 reconcile`; `upgrade`, `repair`, and `force-install` are not supported."
  | isChartsForbiddenFlag argv =
      Just
        "Forbidden chart reconciler flags: use `prodbox charts deploy` or `prodbox charts delete`; `--force` and `--reinstall` are not supported."
  | isChartsForbiddenSister argv =
      Just
        "Forbidden chart command: use `prodbox charts deploy` or `prodbox charts delete`; `install`, `upgrade`, `repair`, and `force-install` are not supported."
  | otherwise = Nothing

isRke2ForbiddenFlag :: [String] -> Bool
isRke2ForbiddenFlag argv =
  case argv of
    "rke2" : commandName : remaining ->
      commandName `elem` ["reconcile", "install"] && any (`elem` remaining) ["--force", "--reinstall"]
    _ -> False

isRke2ForbiddenSister :: [String] -> Bool
isRke2ForbiddenSister argv =
  case argv of
    ["rke2", commandName] -> commandName `elem` ["upgrade", "repair", "force-install"]
    _ -> False

isChartsForbiddenFlag :: [String] -> Bool
isChartsForbiddenFlag argv =
  case argv of
    "charts" : commandName : remaining ->
      commandName `elem` ["deploy", "delete"] && any (`elem` remaining) ["--force", "--reinstall"]
    _ -> False

isChartsForbiddenSister :: [String] -> Bool
isChartsForbiddenSister argv =
  case argv of
    "charts" : commandName : _ -> commandName `elem` ["install", "upgrade", "repair", "force-install"]
    _ -> False
