{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.13: @prodbox nuke@ total teardown command.
--
-- The only sanctioned path to destroy long-lived shared
-- infrastructure (@aws-ses@, the long-lived
-- @pulumi_state_backend@ bucket) transitively, alongside the
-- explicit per-stack @prodbox pulumi aws-ses-destroy --yes@.
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
--   1. K8s drain + per-run Pulumi destroys + cluster uninstall
--      (delegates to the @rke2 delete --cascade@ arm).
--   2. @aws-ses@ Pulumi destroy (long-lived shared infrastructure).
--   3. @prodbox aws teardown@-equivalent operational IAM cleanup.
--   4. Postflight tag sweep (operator-visible audit; non-fatal here
--      because failures after this point cannot be unwound).
--   5. Long-lived @pulumi_state_backend@ bucket destroy (last because
--      AWS imposes a ~24-hour bucket-name reuse cooldown).
module Prodbox.CLI.Nuke
  ( confirmationLiteral
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
  , promptAdminCredentialsWithRegionChoice
  , validateAdminCredentialsInput
  )
import Prodbox.CLI.Command
  ( NukeOptions (..)
  , PlanOptions (..)
  , PulumiCommand (..)
  , Rke2DeleteFlags (..)
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
import Prodbox.CLI.Rke2 (runNativeDeleteWithResiduePolicy)
import Prodbox.Error (fatalError)
import Prodbox.Infra.LongLivedPulumiBackend
  ( destroyLongLivedPulumiStateBucket
  , longLivedBackendErrorMessage
  )
import Prodbox.Lifecycle.TagSweep
  ( TagSweepInput (..)
  , discoverClusterTaggedAwsResources
  , renderTagSweepRefusal
  )
import Prodbox.Settings
  ( Credentials
  , PulumiStateBackendSection
  , ValidatedSettings (..)
  , pulumi_state_backend
  , validateAndLoadSettings
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
          , "  prodbox pulumi aws-ses-destroy --yes"
          , "  prodbox aws teardown"
          , "  prodbox rke2 delete --cascade"
          , ""
          , "If the long-lived `pulumi_state_backend` bucket should also be"
          , "destroyed, follow up with the explicit S3 bucket-destroy step."
          ]
    }

runNukeCommand :: FilePath -> NukeOptions -> IO ExitCode
runNukeCommand repoRoot options =
  if nukeDryRun options
    then do
      writeOutput (renderNukePlan repoRoot)
      pure ExitSuccess
    else do
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
renderNukePlan :: FilePath -> String
renderNukePlan _repoRoot =
  unlines
    [ "PRODBOX_NUKE_PLAN"
    , "STEP=1 K8s drain + per-run Pulumi destroys + cluster uninstall (rke2 delete --cascade arm)"
    , "STEP=2 prodbox pulumi aws-ses-destroy --yes (long-lived shared infrastructure)"
    , "STEP=3 prodbox aws teardown (operational `prodbox` IAM user + access keys)"
    , "STEP=4 postflight tag sweep (any prodbox-tagged AWS residue)"
    , "STEP=5 destroy long-lived `pulumi_state_backend` S3 bucket"
    , "STATUS=plan-only"
    , "CONFIRMATION_LITERAL=" ++ confirmationLiteral
    , "ALSO_NOTE=Each step is idempotent on retry; the operator may resume after a partial failure."
    ]

-- | Orchestration body. Prompts the operator for admin AWS
-- credentials once at the start (used for steps 3, 4, 5), then runs
-- the five steps in dependency order. Step 1 reuses the existing
-- cascade arm, which already runs the K8s drain. Failure at any
-- step aborts; later steps are idempotent, so the operator may
-- re-run nuke after fixing the failing step.
runNukeOrchestration :: FilePath -> IO ExitCode
runNukeOrchestration repoRoot = do
  writeOutputLine ""
  writeOutputLine "prodbox nuke: prompting once for admin AWS credentials."
  writeOutputLine "These credentials are used for the SES destroy, the operational IAM"
  writeOutputLine "user delete, the postflight tag sweep, and the long-lived"
  writeOutputLine "state-bucket destroy. They are NOT kept after this command exits."
  writeOutputLine ""
  rawCredentials <- promptAdminCredentialsWithRegionChoice repoRoot
  adminCredentials <- validateAdminCredentialsInput rawCredentials
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> do
      writeError (fatalError (Text.pack ("nuke aborted while loading settings: " ++ err)))
      pure (ExitFailure 1)
    Right settings -> do
      let backend = pulumi_state_backend (validatedConfig settings)
      runNukeSteps repoRoot adminCredentials backend

runNukeSteps
  :: FilePath
  -> Credentials
  -> PulumiStateBackendSection
  -> IO ExitCode
runNukeSteps repoRoot adminCredentials backend = do
  step1 <- runStep "1/5 cluster cascade" (nukeStepCascade repoRoot)
  abortOrContinue step1 $ do
    step2 <- runStep "2/5 aws-ses destroy" (nukeStepAwsSesDestroy repoRoot)
    abortOrContinue step2 $ do
      step3 <- runStep "3/5 operational IAM teardown" (nukeStepAwsTeardown repoRoot adminCredentials)
      abortOrContinue step3 $ do
        step4 <-
          runStep
            "4/5 postflight tag sweep"
            (nukeStepTagSweep repoRoot adminCredentials)
        -- Tag sweep is informational; non-zero exit surfaces residue
        -- to the operator but does not abort the bucket destroy.
        case step4 of
          ExitSuccess -> pure ()
          ExitFailure _ ->
            writeDiagnosticLine
              "prodbox nuke: postflight tag sweep surfaced residue; proceeding to bucket destroy. Resolve residue with `aws` CLI before re-provisioning."
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
nukeStepCascade repoRoot =
  runNativeDeleteWithResiduePolicy
    repoRoot
    Rke2DeleteFlags
      { rke2DeleteYes = True
      , rke2DeleteCascade = True
      , rke2DeleteAllowPulumiResidue = False
      }

-- | Step 2: destroy the long-lived @aws-ses@ Pulumi stack.
nukeStepAwsSesDestroy :: FilePath -> IO ExitCode
nukeStepAwsSesDestroy repoRoot =
  runPulumiCommand
    repoRoot
    (PulumiAwsSesDestroy True PlanOptions {dryRun = False, planFile = Nothing})

-- | Step 3: delete the dedicated operational @prodbox@ IAM user and
-- clear operational @aws.*@ from the Dhall config. After step 1 + 2
-- there is no Pulumi residue, so 'RefuseOnAnyResidue' is the
-- appropriate policy; the predicate is a safety net rather than a
-- gate operator action.
nukeStepAwsTeardown :: FilePath -> Credentials -> IO ExitCode
nukeStepAwsTeardown repoRoot adminCredentials = do
  result <-
    applyAwsTeardown
      repoRoot
      AwsTeardownInput
        { awsTeardownAdminCredentials = adminCredentials
        , awsTeardownResiduePolicy = RefuseOnAnyResidue
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
