module Prodbox.CLI.Command
  ( AwsCommand (..)
  , AwsTeardownFlags (..)
  , PulumiResiduePolicy (..)
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
  , NukeOptions (..)
  , Plan (..)
  , PolicyTier (..)
  , PulumiCommand (..)
  , Rke2Command (..)
  , Rke2DeleteFlags (..)
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
  | -- | Sprint 4.13: total teardown command. TTY-only, no @--yes@,
    -- typed-confirmation literal. Carries a 'NukeOptions' for the
    -- @--dry-run@ / @--plan-file@ flags but no other arguments.
    NativeNuke NukeOptions
  | NativePulumi PulumiCommand
  | NativeRke2 Rke2Command
  | NativeTest TestCommand
  | NativeTlaCheck
  | NativeUsers UsersCommand
  | NativeWorkload WorkloadCommand
  deriving (Eq, Show)

-- | Sprint 4.13: options for @prodbox nuke@. Duplicated here rather
-- than imported from "Prodbox.CLI.Nuke" so the command record and
-- the optparse-applicative parser surface live in the same module
-- as every other command.
data NukeOptions = NukeOptions
  { nukeDryRun :: Bool
  , nukePlanFile :: Maybe FilePath
  }
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
  | HostFirewallGatewayRestrict Int
  | HostFirewallGatewayUnrestrict Int
  | HostPublicEdge Substrate
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

-- | Operator-facing flags on @prodbox aws teardown@. Sprint 7.7
-- replaced the single @--allow-pulumi-residue@ Bool with a tri-state
-- 'PulumiResiduePolicy' that also exposes @--destroy-pulumi-residue@.
-- The two CLI flags are mutually exclusive at parse time.
data AwsTeardownFlags = AwsTeardownFlags
  { teardownResiduePolicy :: PulumiResiduePolicy
  }
  deriving (Eq, Show)

-- | Sprint 7.7 — operator-facing teardown residue policy. Maps onto two
-- mutually-exclusive CLI flags plus one harness-internal mode. The
-- enum lives in 'Prodbox.CLI.Command' (next to 'AwsTeardownFlags') and
-- is re-exported from 'Prodbox.Aws' for call sites that import the
-- teardown machinery from there.
--
-- * 'RefuseOnAnyResidue' — default. Operator-driven @prodbox aws teardown@
--   without flags. If any Pulumi stack reports live resources, refuse to
--   delete the operational IAM user and emit an actionable message.
-- * 'DestroyPulumiResidueFirst' — operator-driven via
--   @--destroy-pulumi-residue@. Run @prodbox pulumi \<stack>-destroy --yes@
--   for each live stack (per-run AND long-lived) in canonical order, then
--   proceed with the IAM teardown. Long-lived 'aws-ses' destruction
--   emits a stderr warning about SES re-verify + S3 bucket cooldown.
-- * 'AcceptOrphanResidue' — operator-driven via @--allow-pulumi-residue@.
--   Operator-acknowledged orphan: proceed even when stacks are alive.
-- * 'BypassPerRunResidueOnly' — harness-internal only, never CLI-settable.
--   End-of-run @runAwsIamHarnessTeardown@ semantics: bypass per-run
--   stack residue (which the postflight destroys in the same unwind)
--   but still refuse on long-lived shared infrastructure ('aws-ses')
--   so the operator keeps operational @aws.*@ available to destroy it.
-- * 'BypassAllResidueForHarnessRefresh' — harness-internal only, never
--   CLI-settable. Start-of-run @runAwsIamHarnessSetup@ preflight
--   semantics: the preflight is a transient @aws.*@ refresh that
--   immediately re-materializes @aws.*@ from
--   @aws_admin_for_test_simulation.*@ in the same function call, so
--   neither per-run nor long-lived residue strands anything. Refusal
--   on long-lived residue here would block every test-harness run
--   because @aws-ses@ is the intended steady state.
data PulumiResiduePolicy
  = RefuseOnAnyResidue
  | DestroyPulumiResidueFirst
  | AcceptOrphanResidue
  | BypassPerRunResidueOnly
  | BypassAllResidueForHarnessRefresh
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
  | -- | Sprint 4.10 operator-interactive command: migrate the
    -- @aws-ses@ stack's Pulumi state from the in-cluster MinIO backend
    -- onto the dedicated long-lived S3 bucket named by
    -- @pulumi_state_backend@ in @prodbox-config.dhall@. Idempotent;
    -- no-op if the stack already lives in the long-lived backend.
    -- TTY-only; refuses non-interactive contexts.
    PulumiAwsSesMigrateBackend PlanOptions
  deriving (Eq, Show)

data Rke2DeleteFlags = Rke2DeleteFlags
  { rke2DeleteYes :: Bool
  , rke2DeleteCascade :: Bool
  , rke2DeleteAllowPulumiResidue :: Bool
  }
  deriving (Eq, Show)

data Rke2Command
  = Rke2Status
  | Rke2Start
  | Rke2Stop
  | Rke2Restart
  | Rke2Reconcile PlanOptions
  | Rke2Delete Rke2DeleteFlags PlanOptions
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
