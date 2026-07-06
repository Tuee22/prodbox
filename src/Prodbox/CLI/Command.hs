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
  , EdgeCommand (..)
  , FederationRegisterOptions (..)
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
  , PerRunPruneTarget (..)
  , Rke2Command (..)
  , Rke2DeleteFlags (..)
  , PlanOptions (..)
  , runPlanWithOptions
  , TestCommand (..)
  , TestScope (..)
  , UsersCommand (..)
  , UsersListStatus (..)
  , VaultCommand (..)
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
  | NativeEdge EdgeCommand
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
  | NativeVault VaultCommand
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
  | HostFirewallGatewayRestrict Int
  | HostFirewallGatewayUnrestrict Int
  | HostPublicEdge Substrate
  deriving (Eq, Show)

data DnsCommand
  = DnsCheck
  deriving (Eq, Show)

-- | The public-edge surface (Route 53 DNS + ZeroSSL TLS). 'EdgeReconcile'
-- is the AWS-gated edge-only reconcile (the same plan @cluster reconcile
-- --with-edge@ appends); it fails fast naming @prodbox aws setup@ when
-- operational @aws.*@ is empty. @edge status@ reuses the existing
-- public-edge readiness check via 'HostPublicEdge'.
data EdgeCommand
  = EdgeReconcile PlanOptions
  deriving (Eq, Show)

-- | Sprint 1.36: the in-cluster Vault lifecycle surface. 'VaultStatus' probes
-- seal state; the mutating subcommands drive init / unseal / seal / reconcile
-- / key rotation / PKI inspection through the Vault CLI handlers.
-- 'VaultRotateTransitKey' carries the Transit key name.
data VaultCommand
  = VaultStatus
  | VaultInit
  | VaultUnseal
  | VaultSeal
  | VaultReconcile
  | VaultRotateUnlockBundle
  | VaultRotateTransitKey String
  | VaultPkiStatus
  | VaultPkiIssueTestCert
  deriving (Eq, Show)

data DaemonLaunchOptions = DaemonLaunchOptions
  { daemonConfigPath :: Maybe FilePath
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
  { workloadConfigPath :: Maybe FilePath
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
  | -- | Sprint 7.17: regenerate the committed Dhall schema files
    -- (@prodbox-config-types.dhall@ + @test-secrets-types.dhall@) from the
    -- Haskell source of truth.
    ConfigSchema
  | -- | Sprint 7.25: NON-INTERACTIVELY generate the repo-root @prodbox.dhall@
    -- from the Haskell-default non-secret config ('defaultConfigFile') when it
    -- is absent. The binary-generated, non-secret Tier-0 file the test harness
    -- (and operators bringing a cluster up headlessly) use instead of relying on
    -- any fail-fast-removed default fallback. Idempotent: leaves an existing
    -- file unchanged.
    ConfigGenerate
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
  | AwsReapTestEbs Bool
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
    -- @pulumi_state_backend@ in @prodbox.dhall@. Idempotent;
    -- no-op if the stack already lives in the long-lived backend.
    -- TTY-only; refuses non-interactive contexts.
    PulumiAwsSesMigrateBackend PlanOptions
  | -- | Sprint 7.22: recovery command that clears a genuinely-corrupt (or
    -- empty) per-run encrypted Pulumi checkpoint from the Model-B object
    -- store so a cluster carrying stale corrupt checkpoints can converge.
    -- Observes the checkpoint first and refuses to prune a valid (present)
    -- one. The 'Bool' is the @--yes@ confirmation. Per-run stacks only;
    -- a corrupt long-lived @aws-ses@ checkpoint always refuses.
    PulumiPruneCorruptCheckpoint PerRunPruneTarget Bool
  deriving (Eq, Show)

-- | Sprint 7.22: which per-run stack's corrupt checkpoint to prune.
data PerRunPruneTarget
  = PrunePerRunEks
  | PrunePerRunSubzone
  | PrunePerRunTest
  deriving (Eq, Show)

data Rke2DeleteFlags = Rke2DeleteFlags
  { rke2DeleteYes :: Bool
  , rke2DeleteCascade :: Bool
  }
  deriving (Eq, Show)

data Rke2Command
  = Rke2Status
  | Rke2Start
  | Rke2Stop
  | Rke2Restart
  | -- | @Bool@ is @--with-edge@: also reconcile the AWS-gated public edge
    -- (Route 53 DNS + ZeroSSL TLS). Bare reconcile is local-only and needs
    -- no operational @aws.*@.
    Rke2Reconcile PlanOptions Bool
  | Rke2Delete Rke2DeleteFlags PlanOptions
  | Rke2FederationRegister String FederationRegisterOptions
  | Rke2Logs (Maybe Int)
  deriving (Eq, Show)

data FederationRegisterOptions = FederationRegisterOptions
  { federationRegisterPlanOptions :: PlanOptions
  , federationRegisterChildVaultAddress :: Maybe String
  , federationRegisterChildKubeconfig :: Maybe FilePath
  , federationRegisterChildEndpoints :: [(String, String)]
  , federationRegisterChildKubeconfigReference :: Maybe String
  , federationRegisterChildAccountId :: Maybe String
  , federationRegisterChildPulumiStacks :: [(String, String)]
  }
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
  = TestInit Bool
  | TestRun String
  | TestAll
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
  | IntegrationEksVolumeRebind
  | IntegrationChartsStorage
  | IntegrationChartsPlatform
  | IntegrationResourceGuardrails
  | IntegrationDaemonBootstrap
  | IntegrationPulsarBroker
  | IntegrationChartsVscode
  | IntegrationChartsApi
  | IntegrationChartsWebsocket
  | IntegrationAdminRoutes
  | IntegrationPublicDns
  | IntegrationKeycloakInvite
  | IntegrationSealedVault
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
