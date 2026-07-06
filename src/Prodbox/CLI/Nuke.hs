{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.13: @prodbox nuke@ total teardown command.
--
-- The only sanctioned path to destroy long-lived shared
-- infrastructure (@aws-ses@, the long-lived
-- @pulumi_state_backend@ bucket) transitively, alongside the
-- explicit per-stack @prodbox aws stack aws-ses destroy --yes@.
--
-- Operator-only by design:
--   * TTY-only: refuses non-interactive contexts with the canonical
--     command sequence to compose manually.
--   * Typed-confirmation literal: operator must type
--     @NUKE EVERYTHING@ (not @yes@). No @--yes@ shorthand.
--   * @--dry-run@ / @--plan-file@ render the exact sequence without
--     mutating.
--
-- The orchestration sequence (run in dependency order):
--   1. @aws-ses@ Pulumi destroy while Vault/MinIO are still reachable
--      for the encrypted checkpoint backend.
--   2. K8s drain + per-run Pulumi destroys + cluster uninstall
--      (delegates to the @rke2 delete --cascade@ arm).
--   3. @prodbox aws teardown@-equivalent operational IAM cleanup.
--   4. Postflight tag sweep (operator-visible audit; non-fatal here
--      because failures after this point cannot be unwound).
--   5. Long-lived @pulumi_state_backend@ bucket destroy (last because
--      AWS imposes a ~24-hour bucket-name reuse cooldown).
module Prodbox.CLI.Nuke
  ( abortOrContinue
  , confirmationLiteral
  , defaultNukeOptions
  , renderNukePlan
  , runNukeCommand
  )
where

import Data.Text qualified as Text
import Prodbox.Aws
  ( AwsTeardownInput (..)
  , PulumiResiduePolicy (..)
  , adminAwsEnvironment
  , applyAwsTeardown
  )
import Prodbox.CLI.Command
  ( NukeOptions (..)
  , PlanOptions (..)
  , PulumiCommand (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Interactive
  ( InteractiveGuard (..)
  , requireInteractiveTty
  )
import Prodbox.CLI.Output
  ( writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.CLI.Pulumi (runPulumiCommand)
import Prodbox.CLI.Rke2 (runNativeDeleteCascade)
import Prodbox.Error (fatalError)
import Prodbox.Infra.LongLivedPulumiBackend
  ( destroyLongLivedPulumiStateBucket
  , loadAdminAwsCredentials
  , longLivedBackendErrorMessage
  )
import Prodbox.Lifecycle.ResourceRegistry
  ( awsSesPulumiResource
  , longLivedManagedResources
  , perRunManagedResources
  , resourceDestroyCommand
  , resourceName
  )
import Prodbox.Lifecycle.TagSweep
  ( TagSweepInput (..)
  , discoverClusterTaggedAwsResources
  , renderTagSweepRefusal
  )
import Prodbox.Settings
  ( Credentials
  , PulumiStateBackendSection
  , loadConfigFile
  , pulumi_state_backend
  )
import System.Exit (ExitCode (..))
import System.IO
  ( hFlush
  , stdout
  )

defaultNukeOptions :: NukeOptions
defaultNukeOptions = NukeOptions {nukeDryRun = False, nukePlanFile = Nothing}

-- | The literal an operator must type at the confirmation prompt.
-- Capitalized intentionally so operators can't typo "yes" into a
-- nuke. Comparison is case-sensitive.
confirmationLiteral :: String
confirmationLiteral = "NUKE EVERYTHING"

nukeInteractiveGuard :: InteractiveGuard
nukeInteractiveGuard =
  InteractiveGuard
    { guardCommand = "prodbox nuke"
    , guardAutomationHint =
        unlines
          [ "prodbox nuke has no automation alias because it destroys long-lived"
          , "cross-substrate shared infrastructure. Automation contexts must"
          , "compose the canonical commands individually:"
          , ""
          , "  prodbox aws stack aws-ses destroy --yes"
          , "  prodbox aws teardown"
          , "  prodbox cluster delete --cascade"
          , ""
          , "If the long-lived `pulumi_state_backend` bucket should also be"
          , "destroyed, follow up with the explicit S3 bucket-destroy step."
          ]
    }

-- | Sprint 4.26: route @prodbox nuke@ through the shared Plan / Apply
-- entrypoint so @--dry-run@ renders the full teardown plan and exits 0
-- without mutating, and @--plan-file@ writes the rendered plan. The
-- @nukePlanFile@ field is now read (previously threaded into
-- 'NukeOptions' but unread). 'runPlanWithOptions' maps @NukeOptions@'s
-- @nukeDryRun@/@nukePlanFile@ onto 'PlanOptions' so the dry-run/plan-file
-- semantics match every other destructive command. The interactive
-- confirmation + orchestration live entirely inside the apply closure so
-- dry-run never prompts or mutates.
runNukeCommand :: FilePath -> NukeOptions -> IO ExitCode
runNukeCommand repoRoot options =
  runPlanWithOptions
    PlanOptions {dryRun = nukeDryRun options, planFile = nukePlanFile options}
    (buildPlan (const (renderNukePlan repoRoot)) ())
    (\() -> runNukeInteractive repoRoot)

runNukeInteractive :: FilePath -> IO ExitCode
runNukeInteractive repoRoot = do
  requireInteractiveTty nukeInteractiveGuard
  writeOutputLine "prodbox nuke — total teardown."
  writeOutputLine ""
  writeOutputLine "This will destroy:"
  writeOutputLine "  - K8s LoadBalancer Services, ALB Ingresses, Delete-reclaim PVCs"
  writeOutputLine "  - aws-eks-subzone, aws-eks, aws-test (per-run substrate stacks)"
  writeOutputLine "  - aws-ses (long-lived cross-substrate sending identity)"
  writeOutputLine "  - operational `prodbox` IAM user + access keys"
  writeOutputLine "  - local RKE2 cluster (etcd, kubelet, containerd)"
  writeOutputLine "  - prodbox-tagged AWS resources surfaced by the postflight tag sweep"
  writeOutputLine "  - long-lived `pulumi_state_backend` S3 bucket"
  writeOutputLine ""
  writeOutputLine ("Type `" ++ confirmationLiteral ++ "` to proceed (case-sensitive).")
  writeOutputLine "Anything else aborts."
  writeOutputLine ""
  writeOutput "> "
  hFlush stdout
  typed <- getLine
  if normalize typed == confirmationLiteral
    then runNukeOrchestration repoRoot
    else do
      writeDiagnosticLine "prodbox nuke: confirmation rejected; nothing destroyed."
      pure (ExitFailure 1)
 where
  -- Trim trailing whitespace only; literal is case-sensitive.
  normalize value = reverse (dropWhile (== ' ') (reverse value))

-- | The dependency-ordered teardown plan. Rendered verbatim by
-- @--dry-run@ so operators can review what would happen without
-- mutating any state.
--
-- Sprint 5.6: the per-run, @aws-ses@, and long-lived-S3 destroy lines are
-- DERIVED from the managed-resource registry / 'StackDescriptor' SSoT
-- (Sprints 4.26/4.27) — 'awsSesPulumiResource' for step 1,
-- 'perRunManagedResources' for step 2's cascade targets, and 'longLivedManagedResources'
-- for the long-lived S3-object destroys — so the rendered plan tracks the
-- registry rather than drifting from it. A registry-generated golden pins
-- this, and a parity check fails if a registered resource is added without
-- updating the golden.
renderNukePlan :: FilePath -> String
renderNukePlan _repoRoot =
  unlines
    ( [ "PRODBOX_NUKE_PLAN"
      , "STEP=1 "
          ++ resourceDestroyCommand awsSesPulumiResource
          ++ " (long-lived shared infrastructure; requires live Vault/MinIO encrypted backend)"
      , "STEP=2 K8s drain + per-run Pulumi destroys + cluster uninstall (rke2 delete --cascade arm)"
      ]
        ++ [ "STEP=2 per_run_destroy " ++ resourceName resource
           | resource <- perRunManagedResources
           ]
        ++ [ "STEP=3 prodbox aws teardown (operational `prodbox` IAM user + access keys)"
           , "STEP=4 postflight tag sweep (fail-closed: any prodbox-tagged AWS residue OR an unconfirmable sweep aborts nuke non-zero before step 5)"
           ]
        ++ [ "STEP=4 long_lived_destroy " ++ resourceName resource
           | resource <- longLivedManagedResources
           ]
        ++ [ "STEP=5 destroy long-lived `pulumi_state_backend` S3 bucket"
           , "ADMIN_CREDENTIAL_SOURCE=ephemeral admin AWS credential from the interactive prompt (harness-simulated from test-secrets.dhall::aws_admin_for_test_simulation.*); never read from prodbox.dhall or Vault"
           , "STATUS=plan-only"
           , "CONFIRMATION_LITERAL=" ++ confirmationLiteral
           , "ALSO_NOTE=Each step is idempotent on retry; the operator may resume after a partial failure."
           ]
    )

-- | Orchestration body. Acquires the EPHEMERAL admin AWS credential before
-- destructive work begins. Because @prodbox nuke@ is TTY-only, the operator is
-- prompted for a temporary admin key (the harness simulates the prompt from
-- @test-secrets.dhall@'s @aws_admin_for_test_simulation@ block); it is never
-- read from @prodbox.dhall@ or Vault. That same credential is used by
-- long-lived stack operations. The aws-ses destroy runs before the
-- local-cluster cascade so the encrypted Pulumi backend can still read
-- Vault/MinIO. Failure at any step aborts; later steps are idempotent, so the
-- operator may re-run nuke after fixing the failing step.
runNukeOrchestration :: FilePath -> IO ExitCode
runNukeOrchestration repoRoot = do
  writeOutputLine ""
  writeOutputLine
    "prodbox nuke: acquiring the ephemeral admin AWS credential (interactive prompt; harness-simulated from test-secrets.dhall)."
  writeOutputLine "That ephemeral admin credential is used for the SES destroy,"
  writeOutputLine
    "operational IAM teardown, postflight tag sweep, and long-lived state-bucket destroy."
  writeOutputLine ""
  adminResult <- loadAdminAwsCredentials repoRoot
  configResult <- loadConfigFile repoRoot
  case (adminResult, configResult) of
    (Left err, _) -> do
      writeError (fatalError (Text.pack ("nuke aborted while loading admin credentials: " ++ err)))
      pure (ExitFailure 1)
    (_, Left err) -> do
      writeError (fatalError (Text.pack ("nuke aborted while loading config: " ++ err)))
      pure (ExitFailure 1)
    (Right adminCredentials, Right config) -> do
      let backend = pulumi_state_backend config
      runNukeSteps repoRoot adminCredentials backend

runNukeSteps
  :: FilePath
  -> Credentials
  -> PulumiStateBackendSection
  -> IO ExitCode
runNukeSteps repoRoot adminCredentials backend = do
  step1 <- runStep "1/5 aws-ses destroy" (nukeStepAwsSesDestroy repoRoot)
  abortOrContinue step1 $ do
    step2 <- runStep "2/5 cluster cascade" (nukeStepCascade repoRoot)
    abortOrContinue step2 $ do
      step3 <- runStep "3/5 operational IAM teardown" (nukeStepAwsTeardown repoRoot adminCredentials)
      abortOrContinue step3 $ do
        step4 <-
          runStep
            "4/5 postflight tag sweep"
            (nukeStepTagSweep repoRoot adminCredentials)
        -- Sprint 4.26: the postflight tag sweep is FAIL-CLOSED per
        -- lifecycle_reconciliation_doctrine.md § 6. A non-empty leak list
        -- OR an unconfirmable sweep is a hard failure: it aborts nuke with
        -- the surfaced residue and a non-zero exit BEFORE the step-5 bucket
        -- destroy, never "proceed and report success." "Could not observe
        -- the absence of residue" is treated as "residue may be present,"
        -- never as "residue is absent" (the same soundness rule as § 3.1
        -- invariant 2: Unreachable → refuse).
        abortOrContinue step4 $ do
          step5 <-
            runStep
              "5/5 long-lived state-bucket destroy"
              (nukeStepStateBucket repoRoot adminCredentials backend)
          case step5 of
            ExitSuccess -> do
              writeOutputLine ""
              writeOutputLine "prodbox nuke: total teardown complete."
              writeOutputLine "AWS imposes a ~24h cooldown on long-lived state-bucket name reuse;"
              writeOutputLine "next reprovision must wait that window before re-creating the bucket."
              pure ExitSuccess
            failed -> pure failed

-- | Run one nuke step and emit a structured header before/after.
runStep :: String -> IO ExitCode -> IO ExitCode
runStep label action = do
  writeOutputLine ""
  writeOutputLine ("prodbox nuke: step " ++ label ++ " starting.")
  exitCode <- action
  case exitCode of
    ExitSuccess ->
      writeOutputLine ("prodbox nuke: step " ++ label ++ " complete.")
    ExitFailure code ->
      writeDiagnosticLine
        ("prodbox nuke: step " ++ label ++ " failed with exit code " ++ show code)
  pure exitCode

abortOrContinue :: ExitCode -> IO ExitCode -> IO ExitCode
abortOrContinue ExitSuccess continuation = continuation
abortOrContinue failure@(ExitFailure _) _ = do
  writeDiagnosticLine
    "prodbox nuke: aborting. Subsequent steps are skipped. Re-run after resolving the failure."
  pure failure

-- | Step 1: delegate to the cascade arm of @rke2 delete --cascade@,
-- which already runs the K8s drain phase before the per-run Pulumi
-- destroys and cluster uninstall.
nukeStepCascade :: FilePath -> IO ExitCode
nukeStepCascade = runNativeDeleteCascade

-- | Step 2: destroy the long-lived @aws-ses@ Pulumi stack.
nukeStepAwsSesDestroy :: FilePath -> IO ExitCode
nukeStepAwsSesDestroy repoRoot =
  runPulumiCommand
    repoRoot
    (PulumiAwsSesDestroy True PlanOptions {dryRun = False, planFile = Nothing})

-- | Step 3: delete the dedicated operational @prodbox@ IAM user and
-- clear operational @aws.*@ from the Dhall config. After step 1 + 2
-- the destructive cascade and long-lived destroy have already run.
-- The local MinIO backend may be gone by this point, so total teardown
-- uses the explicit orphan-accepting policy and relies on the
-- surrounding cascade + tag-sweep backstops rather than the ordinary
-- operator teardown refusal.
nukeStepAwsTeardown :: FilePath -> Credentials -> IO ExitCode
nukeStepAwsTeardown repoRoot adminCredentials = do
  result <-
    applyAwsTeardown
      repoRoot
      AwsTeardownInput
        { awsTeardownAdminCredentials = adminCredentials
        , awsTeardownResiduePolicy = AcceptOrphanResidue
        }
  case result of
    Left err -> do
      writeError (fatalError (Text.pack ("operational IAM teardown failed: " ++ err)))
      pure (ExitFailure 1)
    Right _ -> pure ExitSuccess

-- | Step 4: scan AWS for any remaining prodbox-tagged resources.
-- Non-fatal: surfaces residue to the operator so they can resolve
-- before re-provisioning, but does not block the bucket destroy.
nukeStepTagSweep :: FilePath -> Credentials -> IO ExitCode
nukeStepTagSweep repoRoot adminCredentials = do
  environment <- adminAwsEnvironment adminCredentials
  result <-
    discoverClusterTaggedAwsResources
      TagSweepInput
        { tagSweepEnvironment = environment
        , tagSweepClusterName = Nothing
        , tagSweepWorkingDirectory = Just repoRoot
        }
  case result of
    Left err -> do
      writeDiagnosticLine ("prodbox nuke: tag sweep query failed: " ++ err)
      pure (ExitFailure 1)
    Right [] -> do
      writeOutputLine "prodbox nuke: tag sweep clean; no surviving prodbox-tagged resources."
      pure ExitSuccess
    Right resources -> do
      writeDiagnosticLine (renderTagSweepRefusal resources)
      pure (ExitFailure 1)

-- | Step 5: destroy the long-lived @pulumi_state_backend@ S3 bucket.
-- Empties all object versions and delete-markers, then deletes the
-- bucket. Idempotent — does nothing if the bucket is already gone.
nukeStepStateBucket
  :: FilePath -> Credentials -> PulumiStateBackendSection -> IO ExitCode
nukeStepStateBucket repoRoot adminCredentials backend = do
  environment <- adminAwsEnvironment adminCredentials
  result <- destroyLongLivedPulumiStateBucket repoRoot environment backend
  case result of
    Left err -> do
      writeError
        ( fatalError
            ( Text.pack
                ( "long-lived state-bucket destroy failed: "
                    ++ longLivedBackendErrorMessage err
                )
            )
        )
      pure (ExitFailure 1)
    Right () -> pure ExitSuccess
