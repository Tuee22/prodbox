module Prodbox.CLI.Command
  ( AwsCommand (..)
  , AwsTeardownFlags (..)
  , ChartsCommand (..)
  , buildPlan
  , CommandListingFormat (..)
  , DnsCommand (..)
  , DocsCommand (..)
  , DaemonLaunchOptions (..)
  , DaemonStatusOptions (..)
  , GatewayCommand (..)
  , CommandRequest (..)
  , ConfigCommand (..)
  , CoverageFlags (..)
  , HostCommand (..)
  , IntegrationSuite (..)
  , K8sCommand (..)
  , LintCommand (..)
  , NativeCommand (..)
  , Plan (..)
  , PolicyTier (..)
  , PulumiCommand (..)
  , Rke2Command (..)
  , PlanOptions (..)
  , runPlanWithOptions
  , TestCommand (..)
  , TestScope (..)
  , UsersCommand (..)
  , UsersListStatus (..)
  , WorkloadCommand (..)
  , WorkloadOptions (..)
  , validateCoverage
  )
where

import Prodbox.CLI.Output (writeOutput)
import Prodbox.Substrate (Substrate (..))
import System.Exit
  ( ExitCode (ExitSuccess)
  )

data CommandRequest
  = RunNative NativeCommand
  | ShowCommands CommandListingFormat
  | ShowHelp [String]
  deriving (Eq, Show)

data CommandListingFormat
  = CommandsPlain
  | CommandsTree
  | CommandsJson
  deriving (Eq, Show)

data NativeCommand
  = NativeAws AwsCommand
  | NativeCharts ChartsCommand
  | NativeCheckCode
  | NativeConfig ConfigCommand
  | NativeDns DnsCommand
  | NativeDocs DocsCommand
  | NativeGateway GatewayCommand
  | NativeHost HostCommand
  | NativeK8s K8sCommand
  | NativeLint LintCommand
  | NativePulumi PulumiCommand
  | NativeRke2 Rke2Command
  | NativeTest TestCommand
  | NativeTlaCheck
  | NativeUsers UsersCommand
  | NativeWorkload WorkloadCommand
  deriving (Eq, Show)

data ChartsCommand
  = ChartsList
  | ChartsStatus String
  | ChartsDeploy String Substrate PlanOptions
  | ChartsDelete String Substrate Bool PlanOptions
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

data DaemonLaunchOptions = DaemonLaunchOptions
  { daemonConfigPath :: Maybe FilePath
  , daemonLogLevel :: Maybe String
  , daemonPort :: Maybe Int
  , daemonForeground :: Bool
  , daemonPlanOptions :: PlanOptions
  }
  deriving (Eq, Show)

data DaemonStatusOptions = DaemonStatusOptions
  { daemonStatusConfigPath :: Maybe FilePath
  }
  deriving (Eq, Show)

data GatewayCommand
  = GatewayDaemonCommand DaemonLaunchOptions
  | GatewayStatusCommand DaemonStatusOptions
  | GatewayConfigGen FilePath String
  deriving (Eq, Show)

data WorkloadOptions = WorkloadOptions
  { workloadLogLevel :: Maybe String
  , workloadPort :: Maybe Int
  , workloadForeground :: Bool
  }
  deriving (Eq, Show)

data WorkloadCommand
  = WorkloadStart WorkloadOptions
  deriving (Eq, Show)

data K8sCommand
  = K8sHealth
  | K8sWait Int [String]
  | K8sLogs [String] Int
  deriving (Eq, Show)

data ConfigCommand
  = ConfigSetup PlanOptions
  | ConfigShow Bool
  | ConfigValidate
  deriving (Eq, Show)

data PolicyTier
  = PolicyCore
  | PolicyFull
  deriving (Eq, Show)

data UsersListStatus
  = UsersAll
  | UsersVerified
  | UsersUnverified
  deriving (Eq, Show)

data UsersCommand
  = UsersInvite String (Maybe String) PlanOptions
  | UsersList UsersListStatus
  | UsersRevoke String Bool PlanOptions
  deriving (Eq, Show)

data AwsCommand
  = AwsPolicy PolicyTier
  | AwsSetup PolicyTier PlanOptions
  | AwsTeardown PlanOptions AwsTeardownFlags
  | AwsCheckQuotas
  | AwsRequestQuotas PolicyTier
  deriving (Eq, Show)

-- | Operator-facing flags on @prodbox aws teardown@. The
-- @--allow-pulumi-residue@ flag bypasses the Sprint 7.6 refuse-path
-- check, allowing the operational IAM user to be deleted even while
-- Pulumi-managed stacks (@aws-eks@, @aws-eks-subzone@, @aws-test@,
-- @aws-ses@) still have live resources. Operators use this only as a
-- recovery escape hatch when ordinary destroy paths are unavailable.
data AwsTeardownFlags = AwsTeardownFlags
  { teardownAllowPulumiResidue :: Bool
  }
  deriving (Eq, Show)

data PulumiCommand
  = PulumiEksResources PlanOptions
  | PulumiEksDestroy Bool PlanOptions
  | PulumiTestResources PlanOptions
  | PulumiTestDestroy Bool PlanOptions
  | PulumiAwsSubzoneResources PlanOptions
  | PulumiAwsSubzoneDestroy Bool PlanOptions
  | PulumiAwsSesResources PlanOptions
  | PulumiAwsSesDestroy Bool PlanOptions
  deriving (Eq, Show)

data Rke2Command
  = Rke2Status
  | Rke2Start
  | Rke2Stop
  | Rke2Restart
  | Rke2Reconcile PlanOptions
  | Rke2Delete Bool
  | Rke2Logs (Maybe Int)
  deriving (Eq, Show)

data PlanOptions = PlanOptions
  { dryRun :: Bool
  , planFile :: Maybe FilePath
  }
  deriving (Eq, Show)

data Plan payload = Plan
  { planPayload :: payload
  , planRendered :: String
  }
  deriving (Eq, Show)

buildPlan :: (payload -> String) -> payload -> Plan payload
buildPlan render payload =
  Plan
    { planPayload = payload
    , planRendered = render payload
    }

runPlanWithOptions :: PlanOptions -> Plan payload -> (payload -> IO ExitCode) -> IO ExitCode
runPlanWithOptions options plan applyPlan = do
  persistPlanIfRequested (planFile options) (planRendered plan)
  if dryRun options
    then do
      writeOutput (planRendered plan)
      pure ExitSuccess
    else applyPlan (planPayload plan)

persistPlanIfRequested :: Maybe FilePath -> String -> IO ()
persistPlanIfRequested Nothing _ = pure ()
persistPlanIfRequested (Just path) contents = writeFile path contents

data DocsCommand
  = DocsCheck
  | DocsGenerate
  deriving (Eq, Show)

data LintCommand
  = LintAll
  | LintFiles Bool
  | LintDocs Bool
  | LintHaskell Bool
  | LintChart
  deriving (Eq, Show)

data TestCommand = TestCommand
  { testScope :: TestScope
  , testCoverage :: CoverageFlags
  , testSubstrate :: Substrate
  }
  deriving (Eq, Show)

data TestScope
  = TestAll
  | TestLint
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
  | IntegrationAdminRoutes
  | IntegrationPublicDns
  | IntegrationKeycloakInvite
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
