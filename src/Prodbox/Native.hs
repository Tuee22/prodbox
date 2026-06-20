module Prodbox.Native
  ( runNativeCommand
  , commandPrerequisites
  )
where

import Data.Text qualified as Text
import Prodbox.Aws
  ( runAwsCommand
  , runInteractiveConfigSetupWithPlan
  )
import Prodbox.CLI.Charts (runChartsCommand)
import Prodbox.CLI.Command
  ( AwsCommand (..)
  , ConfigCommand (..)
  , EdgeCommand (..)
  , GatewayCommand (..)
  , NativeCommand (..)
  , VaultCommand (..)
  )
import Prodbox.CLI.Nuke (runNukeCommand)
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.CLI.Pulumi (runPulumiCommand)
import Prodbox.CLI.Rke2 (runEdgeCommand, runRke2Command)
import Prodbox.CLI.Users (runUsersCommand)
import Prodbox.CLI.Vault (runVaultCommand)
import Prodbox.CheckCode
  ( runCheckCode
  , runDocsCommand
  , runLintCommand
  )
import Prodbox.Config.SchemaDhall
  ( configTypesSchemaPath
  , materializeSchemaFilesIfStale
  , testSecretsTypesSchemaPath
  , writeSchemaFiles
  )
import Prodbox.Dns (runDnsCommand)
import Prodbox.Error (fatalError)
import Prodbox.Gateway (runGatewayCommand)
import Prodbox.Host (runHostCommand)
import Prodbox.K8s (runK8sCommand)
import Prodbox.Lifecycle.Preconditions (noLiveLongLivedPulumiStacksPreflight)
import Prodbox.PrerequisiteId (PrerequisiteId (..))
import Prodbox.Settings
  ( renderSettingsDisplay
  , validateAndLoadSettings
  )
import Prodbox.TestRunner (runTests)
import Prodbox.Tla (runTlaCheck)
import Prodbox.Workload (runWorkloadCommand)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )

runNativeCommand :: FilePath -> NativeCommand -> IO ExitCode
runNativeCommand repoRoot command =
  case command of
    NativeAws awsCommand ->
      -- Sprint 4.26: inject the long-lived teardown preflight here (rather
      -- than inside 'Prodbox.Aws') because the precondition module imports
      -- 'Prodbox.Aws' — wiring it from 'Prodbox.Aws' would be an import
      -- cycle. Only the operator 'aws teardown' default path consults it;
      -- the harness teardown paths bypass it, preserving Sprint 7.9's
      -- aws-ses relaxation.
      runAwsCommand repoRoot noLiveLongLivedPulumiStacksPreflight awsCommand
    NativeCharts chartsCommand -> runChartsCommand repoRoot chartsCommand
    NativeCheckCode -> runCheckCode repoRoot
    NativeConfig configCommand -> runConfigCommand repoRoot configCommand
    NativeDns dnsCommand -> runDnsCommand repoRoot dnsCommand
    NativeDocs docsCommand -> runDocsCommand repoRoot docsCommand
    NativeEdge edgeCommand -> runEdgeCommand repoRoot edgeCommand
    NativeGateway gatewayCommand -> runGatewayCommand repoRoot gatewayCommand
    NativeHost hostCommand -> runHostCommand repoRoot hostCommand
    NativeK8s k8sCommand -> runK8sCommand repoRoot k8sCommand
    NativeLint lintCommand -> runLintCommand repoRoot lintCommand
    NativeNuke nukeOptions -> runNukeCommand repoRoot nukeOptions
    NativePulumi pulumiCommand -> runPulumiCommand repoRoot pulumiCommand
    NativeRke2 rke2Command -> runRke2Command repoRoot rke2Command
    NativeTest testCommand -> runTests repoRoot testCommand
    NativeTlaCheck -> runTlaCheck repoRoot
    NativeUsers usersCommand -> runUsersCommand repoRoot usersCommand
    NativeVault vaultCommand -> runVaultCommand repoRoot vaultCommand
    NativeWorkload workloadCommand -> runWorkloadCommand workloadCommand

-- | Phase 4: the declarative single-source-of-truth for the typed
-- 'PrerequisiteId' set each command's APPLY path requires. The function is
-- total over 'NativeCommand', so the compiler guarantees every command is
-- classified — a new command cannot ship without an explicit (possibly
-- empty) prerequisite declaration.
--
-- Deliberately NOT wired into a universal dispatch-level gate: prerequisites
-- run inside each command's apply path (after @--dry-run@ short-circuits via
-- 'runPlanWithOptions'), never at dispatch. A dispatch-level gate would break
-- the Plan/Apply dry-run contract — rendering a plan must not require live
-- infrastructure (e.g. `charts reconcile --dry-run` renders without a
-- cluster). This declaration is the SSoT that the apply paths and help/
-- introspection consult; folding the per-handler prerequisite running onto it
-- is the remaining follow-up (see legacy-tracking-for-deletion.md).
commandPrerequisites :: NativeCommand -> [PrerequisiteId]
commandPrerequisites command =
  case command of
    NativeAws awsCommand ->
      case awsCommand of
        AwsPolicy _ -> []
        AwsSetup _ _ -> [AwsIamHarnessReady]
        AwsTeardown _ _ -> [AwsIamHarnessReady]
        AwsCheckQuotas -> [AwsCredentialsValid]
        AwsRequestQuotas _ -> [AwsCredentialsValid]
    -- Chart reconcile/delete apply against the active cluster.
    NativeCharts _ -> [K8sClusterReachable]
    NativeCheckCode -> []
    NativeConfig _ -> []
    -- Route 53 inspection needs validated AWS credentials + zone access.
    NativeDns _ -> [Route53Accessible]
    NativeDocs _ -> []
    -- Edge reconcile attaches Route 53 DNS + ZeroSSL TLS to a running cluster.
    NativeEdge (EdgeReconcile _) -> [K8sClusterReachable, AwsCredentialsValid]
    NativeGateway gatewayCommand ->
      case gatewayCommand of
        GatewayDaemonCommand _ -> [GatewayDaemonAcquire]
        _ -> []
    -- Host checks + firewall + `edge status` report state; they self-handle
    -- absence rather than gating.
    NativeHost _ -> []
    -- `cluster health/wait/workload-logs` operate on a reachable cluster.
    NativeK8s _ -> [K8sClusterReachable]
    NativeLint _ -> []
    -- Empty-record pattern (not a `_` binder) so the checkPlanOptionsHonored
    -- lint does not mistake this classification arm for a dispatch arm that
    -- drops --dry-run; nuke carries no upstream prerequisite here.
    NativeNuke {} -> []
    NativePulumi _ -> [AwsCredentialsValid]
    -- `cluster` service ops + reconcile (which creates the cluster) carry no
    -- cluster precondition; the test harness owns its own prerequisite DAG.
    NativeRke2 _ -> []
    NativeTest _ -> []
    NativeTlaCheck -> []
    NativeUsers _ -> []
    -- `vault status` self-handles an unreachable Vault (reports it); the
    -- mutating subcommands act against the in-cluster Vault and gate on a
    -- reachable cluster. `rotate-unlock-bundle` is a host-only re-encryption.
    NativeVault vaultCommand ->
      case vaultCommand of
        VaultStatus -> []
        VaultInit -> [K8sClusterReachable]
        VaultUnseal -> [K8sClusterReachable]
        VaultSeal -> [K8sClusterReachable]
        VaultReconcile -> [K8sClusterReachable]
        VaultRotateUnlockBundle -> []
        VaultRotateTransitKey _ -> [K8sClusterReachable]
        VaultPkiStatus -> [K8sClusterReachable]
        VaultPkiIssueTestCert -> [K8sClusterReachable]
    NativeWorkload _ -> []

runConfigCommand :: FilePath -> ConfigCommand -> IO ExitCode
runConfigCommand repoRoot configCommand =
  case configCommand of
    ConfigSetup planOptions -> do
      -- Sprint 7.17: ensure the operator's `import ./prodbox-config-types.dhall`
      -- always resolves to the in-sync, Haskell-generated schema before
      -- `config setup` authors (and re-decodes) `prodbox.dhall`.
      materializeSchemaFilesIfStale repoRoot
      runInteractiveConfigSetupWithPlan repoRoot planOptions
    ConfigShow showSecrets -> do
      result <- validateAndLoadSettings repoRoot
      case result of
        Left err -> failWith err
        Right settings -> do
          writeOutput (renderSettingsDisplay showSecrets settings)
          pure ExitSuccess
    ConfigValidate -> do
      -- Materialize the schema first so a config that imports it can decode
      -- even when the committed schema file is absent or stale.
      materializeSchemaFilesIfStale repoRoot
      result <- validateAndLoadSettings repoRoot
      either failWith (const (pure ExitSuccess)) result
    ConfigSchema -> do
      writeSchemaFiles repoRoot
      writeOutput
        ( unlines
            [ "Regenerated Dhall config schema from the Haskell source of truth:"
            , "  " ++ configTypesSchemaPath repoRoot
            , "  " ++ testSecretsTypesSchemaPath repoRoot
            ]
        )
      pure ExitSuccess

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
