module Prodbox.CLI.Parser (
    Options (..),
    parserInfo,
)
where

import Data.Version (showVersion)
import Options.Applicative (
    Parser,
    ParserInfo,
    auto,
    command,
    eitherReader,
    fullDesc,
    help,
    helper,
    hsubparser,
    info,
    infoOption,
    long,
    many,
    metavar,
    option,
    optional,
    progDesc,
    short,
    strArgument,
    strOption,
    switch,
    value,
    (<**>),
 )
import Paths_prodbox (version)
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
    WorkloadCommand (..),
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
            <> command "check-code" (info (pure (RunNative NativeCheckCode)) (progDesc "Run policy, lint, and type checks"))
            <> command "config" (info configParser (progDesc "Configuration management"))
            <> command "dns" (info dnsParser (progDesc "Route 53 inspection"))
            <> command "gateway" (info gatewayParser (progDesc "Gateway daemon operations"))
            <> command "host" (info hostParser (progDesc "Host prerequisite checks"))
            <> command "k8s" (info k8sParser (progDesc "Kubernetes health and log utilities"))
            <> command "pulumi" (info pulumiParser (progDesc "AWS validation infrastructure"))
            <> command "rke2" (info rke2Parser (progDesc "Local cluster lifecycle"))
            <> command "test" (info testParser (progDesc "Named test suites"))
            <> command "tla-check" (info (native NativeTlaCheck) (progDesc "Run TLA+ checks"))
            <> command "workload" (info workloadParser (progDesc "Internal public workload runtime"))
        )

native :: NativeCommand -> Parser CommandRequest
native = pure . RunNative

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

withCoverage :: TestScope -> Parser CommandRequest
withCoverage scope =
    fmap (RunNative . NativeTest . TestCommand scope) coverageFlagsParser

configParser :: Parser CommandRequest
configParser =
    hsubparser
        ( command "setup" (info (native (NativeConfig ConfigSetup)) (progDesc "Interactively author config"))
            <> command "show" (info configShowParser (progDesc "Display current config"))
            <> command "validate" (info (native (NativeConfig ConfigValidate)) (progDesc "Validate current config"))
        )

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
            <> command "teardown" (info (native (NativeAws AwsTeardown)) (progDesc "Delete operational IAM user"))
            <> command "check-quotas" (info (native (NativeAws AwsCheckQuotas)) (progDesc "Inspect supported AWS quotas"))
            <> command "request-quotas" (info awsRequestQuotasParser (progDesc "Request supported AWS quotas"))
        )

awsPolicyParser :: Parser CommandRequest
awsPolicyParser =
    fmap (RunNative . NativeAws . AwsPolicy) (tierOptionParser PolicyCore "Operational IAM policy tier to render")

awsSetupParser :: Parser CommandRequest
awsSetupParser =
    fmap (RunNative . NativeAws . AwsSetup) (tierOptionParser PolicyFull "Operational IAM policy tier to provision")

awsRequestQuotasParser :: Parser CommandRequest
awsRequestQuotasParser =
    fmap (RunNative . NativeAws . AwsRequestQuotas) (tierOptionParser PolicyFull "Quota target tier to request")

hostParser :: Parser CommandRequest
hostParser =
    hsubparser
        ( command "ensure-tools" (info (native (NativeHost HostEnsureTools)) (progDesc "Verify required host tools"))
            <> command "check-ports" (info (native (NativeHost HostCheckPorts)) (progDesc "Check required ports"))
            <> command "info" (info (native (NativeHost HostInfo)) (progDesc "Display host diagnostics"))
            <> command "firewall" (info (native (NativeHost HostFirewall)) (progDesc "Check firewall requirements"))
            <> command "public-edge" (info (native (NativeHost HostPublicEdge)) (progDesc "Check public DNS/TLS edge state"))
        )

rke2Parser :: Parser CommandRequest
rke2Parser =
    hsubparser
        ( command "status" (info (native (NativeRke2 Rke2Status)) (progDesc "Check RKE2 status"))
            <> command "start" (info (native (NativeRke2 Rke2Start)) (progDesc "Start RKE2"))
            <> command "stop" (info (native (NativeRke2 Rke2Stop)) (progDesc "Stop RKE2"))
            <> command "restart" (info (native (NativeRke2 Rke2Restart)) (progDesc "Restart RKE2"))
            <> command "install" (info (native (NativeRke2 Rke2Install)) (progDesc "Install or reconcile RKE2"))
            <> command "delete" (info rke2DeleteParser (progDesc "Delete RKE2"))
            <> command "logs" (info rke2LogsParser (progDesc "Show RKE2 logs"))
        )

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
        ( command "eks-resources" (info (native (NativePulumi PulumiEksResources)) (progDesc "Provision or inspect EKS test stack"))
            <> command "eks-destroy" (info pulumiYesParserEksDestroy (progDesc "Destroy EKS test stack"))
            <> command "test-resources" (info (native (NativePulumi PulumiTestResources)) (progDesc "Provision or inspect HA RKE2 test stack"))
            <> command "test-destroy" (info pulumiYesParserTestDestroy (progDesc "Destroy HA RKE2 test stack"))
        )

pulumiYesParserEksDestroy :: Parser CommandRequest
pulumiYesParserEksDestroy =
    fmap (RunNative . NativePulumi . PulumiEksDestroy) (yesSwitchParser "Skip confirmation prompts")

pulumiYesParserTestDestroy :: Parser CommandRequest
pulumiYesParserTestDestroy =
    fmap (RunNative . NativePulumi . PulumiTestDestroy) (yesSwitchParser "Skip confirmation prompts")

dnsParser :: Parser CommandRequest
dnsParser = hsubparser (command "check" (info (native (NativeDns DnsCheck)) (progDesc "Inspect Route 53 state")))

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
        (\(timeoutSeconds, namespaces) -> RunNative (NativeK8s (K8sWait (maybe 300 id timeoutSeconds) (defaultNamespaces namespaces))))
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
        (\(namespaces, tailLines) -> RunNative (NativeK8s (K8sLogs (defaultNamespaces namespaces) (maybe 10 id tailLines))))
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
    fmap (RunNative . NativeGateway . GatewayStart) (strArgument (metavar "CONFIG_PATH"))

gatewayStatusParser :: Parser CommandRequest
gatewayStatusParser =
    fmap (RunNative . NativeGateway . GatewayStatus) (strArgument (metavar "CONFIG_PATH"))

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
        ( command "start" (info (native (NativeWorkload WorkloadStart)) (progDesc "Start the internal public workload runtime"))
        )

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
    fmap (RunNative . NativeCharts . ChartsDeploy) (strArgument (metavar "CHART"))

chartsDeleteParser :: Parser CommandRequest
chartsDeleteParser =
    fmap
        (\(chartName, confirmed) -> RunNative (NativeCharts (ChartsDelete chartName confirmed)))
        ( (,)
            <$> strArgument (metavar "CHART")
            <*> yesSwitchParser "Skip confirmation prompt"
        )

testParser :: Parser CommandRequest
testParser =
    hsubparser
        ( command "all" (info (withCoverage TestAll) (progDesc "Run the full test suite"))
            <> command "unit" (info (withCoverage TestUnit) (progDesc "Run unit tests"))
            <> command "integration" (info integrationParser (progDesc "Run named integration suites"))
        )

integrationParser :: Parser CommandRequest
integrationParser =
    hsubparser
        ( command "all" (info (withCoverage (TestIntegration IntegrationAll)) (progDesc "Run all integration suites"))
            <> command "cli" (info (withCoverage (TestIntegration IntegrationCli)) (progDesc "Run CLI integration tests"))
            <> command "aws-iam" (info (withCoverage (TestIntegration IntegrationAwsIam)) (progDesc "Run AWS IAM integration tests"))
            <> command "dns-aws" (info (withCoverage (TestIntegration IntegrationDnsAws)) (progDesc "Run Route 53 integration tests"))
            <> command "aws-eks" (info (withCoverage (TestIntegration IntegrationAwsEks)) (progDesc "Run EKS integration tests"))
            <> command "env" (info (withCoverage (TestIntegration IntegrationEnv)) (progDesc "Run environment integration tests"))
            <> command "gateway-daemon" (info (withCoverage (TestIntegration IntegrationGatewayDaemon)) (progDesc "Run gateway-daemon integration tests"))
            <> command "gateway-pods" (info (withCoverage (TestIntegration IntegrationGatewayPods)) (progDesc "Run gateway pod integration tests"))
            <> command "gateway-partition" (info (withCoverage (TestIntegration IntegrationGatewayPartition)) (progDesc "Run gateway partition integration tests"))
            <> command "ha-rke2-aws" (info (withCoverage (TestIntegration IntegrationHaRke2Aws)) (progDesc "Run HA RKE2 AWS integration tests"))
            <> command "lifecycle" (info (withCoverage (TestIntegration IntegrationLifecycle)) (progDesc "Run lifecycle integration tests"))
            <> command "pulumi" (info (withCoverage (TestIntegration IntegrationPulumi)) (progDesc "Run Pulumi integration tests"))
            <> command "charts-storage" (info (withCoverage (TestIntegration IntegrationChartsStorage)) (progDesc "Run chart-storage integration tests"))
            <> command "charts-platform" (info (withCoverage (TestIntegration IntegrationChartsPlatform)) (progDesc "Run chart-platform integration tests"))
            <> command "charts-vscode" (info (withCoverage (TestIntegration IntegrationChartsVscode)) (progDesc "Run vscode stack integration tests"))
            <> command "charts-api" (info (withCoverage (TestIntegration IntegrationChartsApi)) (progDesc "Run API stack integration tests"))
            <> command "charts-websocket" (info (withCoverage (TestIntegration IntegrationChartsWebsocket)) (progDesc "Run WebSocket stack integration tests"))
            <> command "public-dns" (info (withCoverage (TestIntegration IntegrationPublicDns)) (progDesc "Run public DNS integration tests"))
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
