module Prodbox.CLI.Command (
    AwsCommand (..),
    ChartsCommand (..),
    DnsCommand (..),
    GatewayCommand (..),
    CommandRequest (..),
    ConfigCommand (..),
    CoverageFlags (..),
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
    validateCoverage,
)
where

newtype CommandRequest = RunNative NativeCommand
    deriving (Eq, Show)

data NativeCommand
    = NativeAws AwsCommand
    | NativeCharts ChartsCommand
    | NativeCheckCode
    | NativeConfig ConfigCommand
    | NativeDns DnsCommand
    | NativeGateway GatewayCommand
    | NativeHost HostCommand
    | NativeK8s K8sCommand
    | NativePulumi PulumiCommand
    | NativeRke2 Rke2Command
    | NativeTest TestCommand
    | NativeTlaCheck
    | NativeWorkload WorkloadCommand
    deriving (Eq, Show)

data ChartsCommand
    = ChartsList
    | ChartsStatus String
    | ChartsDeploy String
    | ChartsDelete String Bool
    deriving (Eq, Show)

data HostCommand
    = HostEnsureTools
    | HostCheckPorts
    | HostInfo
    | HostFirewall
    | HostPublicEdge
    deriving (Eq, Show)

data DnsCommand
    = DnsCheck
    deriving (Eq, Show)

data GatewayCommand
    = GatewayStart FilePath
    | GatewayStatus FilePath
    | GatewayConfigGen FilePath String
    deriving (Eq, Show)

data WorkloadCommand
    = WorkloadStart
    deriving (Eq, Show)

data K8sCommand
    = K8sHealth
    | K8sWait Int [String]
    | K8sLogs [String] Int
    deriving (Eq, Show)

data ConfigCommand
    = ConfigSetup
    | ConfigShow Bool
    | ConfigValidate
    deriving (Eq, Show)

data PolicyTier
    = PolicyCore
    | PolicyFull
    deriving (Eq, Show)

data AwsCommand
    = AwsPolicy PolicyTier
    | AwsSetup PolicyTier
    | AwsTeardown
    | AwsCheckQuotas
    | AwsRequestQuotas PolicyTier
    deriving (Eq, Show)

data PulumiCommand
    = PulumiEksResources
    | PulumiEksDestroy Bool
    | PulumiTestResources
    | PulumiTestDestroy Bool
    deriving (Eq, Show)

data Rke2Command
    = Rke2Status
    | Rke2Start
    | Rke2Stop
    | Rke2Restart
    | Rke2Install
    | Rke2Delete Bool
    | Rke2Logs (Maybe Int)
    deriving (Eq, Show)

data TestCommand = TestCommand
    { testScope :: TestScope
    , testCoverage :: CoverageFlags
    }
    deriving (Eq, Show)

data TestScope
    = TestAll
    | TestUnit
    | TestIntegration IntegrationSuite
    deriving (Eq, Show)

data IntegrationSuite
    = IntegrationAll
    | IntegrationCli
    | IntegrationAwsIam
    | IntegrationDnsAws
    | IntegrationAwsEks
    | IntegrationEnv
    | IntegrationGatewayDaemon
    | IntegrationGatewayPods
    | IntegrationGatewayPartition
    | IntegrationHaRke2Aws
    | IntegrationLifecycle
    | IntegrationPulumi
    | IntegrationChartsStorage
    | IntegrationChartsPlatform
    | IntegrationChartsVscode
    | IntegrationChartsApi
    | IntegrationChartsWebsocket
    | IntegrationPublicDns
    deriving (Eq, Show)

data CoverageFlags = CoverageFlags
    { coverageEnabled :: Bool
    , coverageFailUnder :: Maybe Int
    }
    deriving (Eq, Show)

validateCoverage :: CoverageFlags -> Either String ()
validateCoverage flags =
    case (coverageEnabled flags, coverageFailUnder flags) of
        (False, Just _) -> Left "--cov-fail-under requires --coverage."
        (_, Just minimumPercent)
            | minimumPercent < 0 || minimumPercent > 100 ->
                Left "--cov-fail-under must be between 0 and 100."
        _ -> Right ()
