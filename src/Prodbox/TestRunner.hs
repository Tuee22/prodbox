{-# LANGUAGE OverloadedStrings #-}

module Prodbox.TestRunner
  ( runTests
  , clearOperationalCredsAfterPostflight
  , PublicEdgeCertificateFailure (..)
  , awsSubstrateBootstrapCommandArgs
  , awsPostflightDestroyCommandArgs
  , publicEdgeCertificateReissueStatusPatch
  , supportedRuntimeBootstrapNeedsReconcile
  , supportedRuntimeBootstrapNeedsKeycloakSmtpSync
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( SomeException
  , bracket_
  , displayException
  , throwIO
  , try
  )
import Control.Monad (foldM, unless)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Prodbox.Aws
  ( runAwsIamHarnessSetup
  , runAwsIamHarnessTeardown
  )
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , canonicalOperatorBinaryPath
  , syncBuiltOperatorBinary
  )
import Prodbox.CLI.Command
  ( PolicyTier
  , TestCommand (..)
  , TestScope (..)
  , validateCoverage
  )
import Prodbox.CLI.Output
  ( writeDiagnostic
  , writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.CLI.Rke2 (ensureGatewayMinioBootstrap)
import Prodbox.CheckCode (runCheckCode)
import Prodbox.EffectDAG
  ( fromRootIds
  )
import Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , runEffectDAG
  )
import Prodbox.Error (fatalError)
import Prodbox.Infra.AwsEksTestStack (withEksKubeconfig)
import Prodbox.Infra.AwsSesStack qualified as AwsSesStack
import Prodbox.Lib.ChartPlatform
  ( renderPublicEdgePreserveOutcome
  , retainReadyPublicEdgeCertificate
  )
import Prodbox.Prerequisite
  ( prerequisiteRegistry
  )
import Prodbox.Result
  ( Result (..)
  )
import Prodbox.Settings
  ( ConfigFile (..)
  , Credentials (..)
  , ValidatedSettings (..)
  , aws
  , validateAndLoadSettings
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , commandDisplay
  , runSubprocessStreaming
  )
import Prodbox.Substrate (Substrate (..), substrateId)
import Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation (..)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , testExecutionPlan
  )
import Prodbox.TestValidation (runNativeValidation)
import System.Environment
  ( getEnvironment
  , lookupEnv
  , setEnv
  , unsetEnv
  )
import System.Exit
  ( ExitCode (..)
  )

phaseOneGateMessage :: String
phaseOneGateMessage = "Phase 1/2: validating integration prerequisites"

phaseOneNoPrereqMessage :: String
phaseOneNoPrereqMessage = "Phase 1/2: no integration prerequisites required"

phaseOnePointFiveMessage :: String
phaseOnePointFiveMessage = "Phase 1.5/2: enforcing integration runbook"

phaseOnePointSixMessage :: String
phaseOnePointSixMessage = "Phase 1.6/2: restoring supported runtime"

phaseTwoMessage :: String
phaseTwoMessage = "Phase 2/2: running test suites"

postTestRestoreMessage :: String
postTestRestoreMessage = "Post-test: restoring supported runtime"

publicEdgeNamespace :: String
publicEdgeNamespace = "vscode"

publicEdgeCertificateName :: String
publicEdgeCertificateName = "public-edge-tls"

publicEdgeReadyClassification :: String
publicEdgeReadyClassification = "CLASSIFICATION=ready-for-external-proof"

publicEdgeReadyAttempts :: Int
publicEdgeReadyAttempts = 60

publicEdgeReadyDelayMicroseconds :: Int
publicEdgeReadyDelayMicroseconds = 10000000

publicEdgeCertificateRepairAttempts :: Int
publicEdgeCertificateRepairAttempts = 3

data PublicEdgeCertificateFailure = PublicEdgeCertificateFailure
  { publicEdgeFailedIssuanceAttempts :: Int
  , publicEdgeNextPrivateKeySecretName :: Maybe String
  , publicEdgeCertificateObservedGeneration :: Maybe Int
  }
  deriving (Eq, Show)

runTests :: FilePath -> TestCommand -> IO ExitCode
runTests repoRoot command =
  case validateCoverage (testCoverage command) of
    Left err -> failWith err
    Right () -> do
      baseEnvironment <- getEnvironment
      environment <- addBuildSupportEnvironment repoRoot baseEnvironment
      let plan = testExecutionPlan (testSubstrate command) (testScope command)
      writeOutputLine ("Running prodbox test " ++ testPlanLabel plan ++ " (Haskell entrypoint)")
      case testScope command of
        TestLint -> runLintFirst repoRoot environment
        TestAll -> do
          lintExit <- runLintFirst repoRoot environment
          case lintExit of
            ExitSuccess ->
              runPlannedTests repoRoot environment plan
            failure@(ExitFailure _) -> pure failure
        _ -> runPlannedTests repoRoot environment plan

runPlannedTests :: FilePath -> [(String, String)] -> TestExecutionPlan -> IO ExitCode
runPlannedTests repoRoot environment plan =
  case testPlanExecutionMode plan of
    DelegatedSuite _ ->
      runHaskellSuites repoRoot environment (testPlanHaskellSuites plan)
    NativeSuite suitePlan -> do
      prepareExit <- ensureCanonicalOperatorBinary repoRoot environment
      case prepareExit of
        ExitSuccess ->
          runNativeSuite repoRoot environment (testPlanHaskellSuites plan) suitePlan
        failure@(ExitFailure _) -> pure failure

runLintFirst :: FilePath -> [(String, String)] -> IO ExitCode
runLintFirst repoRoot environment = do
  lintExit <- runCheckCode repoRoot
  case lintExit of
    ExitSuccess ->
      runCommandForExitCode
        Subprocess
          { subprocessPath = "cabal"
          , subprocessArguments = ["build", "--builddir=.build", "all"]
          , subprocessEnvironment = Just environment
          , subprocessWorkingDirectory = Just repoRoot
          }
    failure@(ExitFailure _) -> pure failure

runHaskellSuites :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runHaskellSuites repoRoot environment suites = do
  unless (null suites) (writeOutputLine "Running Haskell test suites")
  foldM runSuite ExitSuccess suites
 where
  runSuite :: ExitCode -> String -> IO ExitCode
  runSuite failure@(ExitFailure _) _ = pure failure
  runSuite ExitSuccess suiteName =
    runCommandForExitCode
      Subprocess
        { subprocessPath = "cabal"
        , subprocessArguments =
            [ "test"
            , "--builddir=.build"
            , suiteName
            , "--test-show-details=direct"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }

runNativeSuite :: FilePath -> [(String, String)] -> [String] -> NativeSuitePlan -> IO ExitCode
runNativeSuite repoRoot environment haskellSuites suitePlan = do
  bannerExit <- emitLineAction (phaseOneMessage suitePlan)
  case bannerExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess ->
      case nativeManagedAwsHarnessPolicyTier suitePlan of
        Nothing -> runNativeSuiteBody repoRoot environment haskellSuites suitePlan
        Just policyTier -> do
          setupExit <- runManagedAwsHarnessSetup repoRoot policyTier
          case setupExit of
            failure@(ExitFailure _) -> pure failure
            ExitSuccess ->
              runWithAwsHarnessCleanup
                repoRoot
                environment
                suitePlan
                (runNativeSuiteBody repoRoot environment haskellSuites suitePlan)

-- | Sprint 7.6 orphan-safety: run the suite body, then destroy every
-- per-run Pulumi stack the suite may have provisioned before clearing
-- operational @aws.*@ via the harness teardown. The destroys run on
-- success, failure, and async exception (Ctrl-C) alike, so no
-- `prodbox test all` exit path can strand
-- @aws-eks@ / @aws-eks-subzone@ / @aws-test@ resources in AWS. The
-- @aws-ses@ stack is explicitly excluded per the long-lived
-- cross-substrate shared-infrastructure class in
-- @DEVELOPMENT_PLAN/substrates.md@ § Resource Lifecycle Classes.
--
-- Sprint 7.10 credential-preservation: the per-run destroys still run
-- on every exit path, but the *operational-credential teardown*
-- ('runManagedAwsHarnessTeardown', which clears @aws.*@ + deletes the
-- operational @prodbox@ IAM user) now runs **only when the per-run
-- destroy succeeded** ('clearOperationalCredsAfterPostflight'). When a
-- per-run @pulumi <stack>-destroy@ fails (e.g. the May 28/29
-- @DependencyViolation@ on subnet deletion from lagging orphan ENIs),
-- the orphaned per-run stacks still exist in AWS and need operational
-- creds to be destroyed on retry. Tearing the creds down here would
-- strand those orphans without the credentials required to delete them,
-- so the teardown is held and a diagnostic explains the recovery path.
-- This is the per-run analog of Sprint 7.9 (which made the teardown not
-- gate on admin-managed @aws-ses@): 7.9 said "don't block teardown on
-- aws-ses"; 7.10 says "DO hold the teardown when the per-run
-- auto-destroy — which needs operational creds — failed."
runWithAwsHarnessCleanup
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> IO ExitCode
  -> IO ExitCode
runWithAwsHarnessCleanup repoRoot environment suitePlan body = do
  result <- try body :: IO (Either SomeException ExitCode)
  destroyExit <- runSequentially (awsPostflightDestroyActions repoRoot environment suitePlan)
  cleanupExit <- runConditionalHarnessTeardown destroyExit
  case result of
    Left exc -> do
      writeDiagnosticLine
        ("AWS harness cleanup ran after async exception: " ++ show exc)
      _ <- writeReason destroyExit cleanupExit
      throwIO exc
    Right suiteExit ->
      pure
        ( preferEarlierFailure
            suiteExit
            (preferEarlierFailure destroyExit cleanupExit)
        )
 where
  -- Sprint 7.10: clear operational @aws.*@ + delete the operational
  -- @prodbox@ user only when the per-run destroy succeeded. On a
  -- per-run destroy failure, preserve the operational credentials so the
  -- orphaned per-run stacks can be destroyed on retry, and explain the
  -- recovery path.
  runConditionalHarnessTeardown :: ExitCode -> IO ExitCode
  runConditionalHarnessTeardown destroyExit
    | clearOperationalCredsAfterPostflight destroyExit =
        runManagedAwsHarnessTeardown repoRoot
    | otherwise = do
        writeDiagnosticLine
          ( "Per-run Pulumi destroy failed ("
              ++ show destroyExit
              ++ "); the per-run AWS stacks (aws-eks, aws-eks-subzone, "
              ++ "aws-test) may still hold live resources. PRESERVING "
              ++ "operational aws.* and the operational `prodbox` IAM "
              ++ "user so the orphaned per-run stacks can be destroyed on "
              ++ "retry. Skipping the operational-credential teardown to "
              ++ "avoid stranding the orphans without the credentials "
              ++ "required to delete them. Recover with: resolve the "
              ++ "destroy failure (e.g. wait out / clean up the orphan "
              ++ "ENIs behind a DependencyViolation), then "
              ++ "`prodbox pulumi <stack>-destroy --yes` for each "
              ++ "remaining per-run stack, then `prodbox aws teardown` to "
              ++ "clear the operational credentials."
          )
        -- The per-run destroy failure is already surfaced as the
        -- composed exit code; the held teardown is not itself a failure.
        pure ExitSuccess

  writeReason :: ExitCode -> ExitCode -> IO ()
  writeReason destroyExit cleanupExit =
    case (destroyExit, cleanupExit) of
      (ExitSuccess, ExitSuccess) -> pure ()
      _ ->
        writeDiagnosticLine
          ( "AWS harness cleanup non-zero: destroy="
              ++ show destroyExit
              ++ ", harnessTeardown="
              ++ show cleanupExit
          )

-- | Sprint 7.10 pure decision: should the operational-credential
-- teardown ('runManagedAwsHarnessTeardown') run after the per-run
-- Pulumi destroy postflight?
--
-- Returns 'True' iff the per-run destroy succeeded ('ExitSuccess'). On
-- any 'ExitFailure' the orphaned per-run stacks still hold live AWS
-- resources that require operational creds to destroy on retry, so the
-- teardown is held and the operational @aws.*@ + @prodbox@ IAM user are
-- preserved. Extracted as a pure helper so the decision matrix is
-- unit-testable without harness IO.
clearOperationalCredsAfterPostflight :: ExitCode -> Bool
clearOperationalCredsAfterPostflight destroyExit =
  case destroyExit of
    ExitSuccess -> True
    ExitFailure _ -> False

awsPostflightDestroyActions
  :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
awsPostflightDestroyActions repoRoot environment suitePlan =
  case awsPostflightDestroyCommandArgs suitePlan of
    [] -> []
    commands ->
      emitLineAction
        ( "Auto-destroying per-run AWS Pulumi stacks (aws-eks, "
            ++ "aws-eks-subzone, aws-test). aws-ses is retained per the "
            ++ "long-lived cross-substrate shared-infrastructure class."
        )
        : map (runNativeCliCommandForExitCode repoRoot environment) commands

awsPostflightDestroyCommandArgs :: NativeSuitePlan -> [[String]]
awsPostflightDestroyCommandArgs suitePlan =
  if nativeMayProvisionPerRunAwsStacks suitePlan
    then
      [ ["pulumi", "aws-subzone-destroy", "--yes"]
      , ["pulumi", "eks-destroy", "--yes"]
      , ["pulumi", "test-destroy", "--yes"]
      ]
    else []

nativeMayProvisionPerRunAwsStacks :: NativeSuitePlan -> Bool
nativeMayProvisionPerRunAwsStacks suitePlan =
  nativeRequiresSupportedRuntimePostflight suitePlan
    || (nativeSubstrate suitePlan == SubstrateAws && nativeRequiresSupportedRuntimeBootstrap suitePlan)
    || any validationMayProvisionPerRunAwsStacks (nativeValidations suitePlan)

validationMayProvisionPerRunAwsStacks :: NativeValidation -> Bool
validationMayProvisionPerRunAwsStacks validation =
  case validation of
    ValidationAwsEks -> True
    ValidationPulumi -> True
    ValidationHaRke2Aws -> True
    _ -> False

runNativeSuiteBody :: FilePath -> [(String, String)] -> [String] -> NativeSuitePlan -> IO ExitCode
runNativeSuiteBody repoRoot environment haskellSuites suitePlan = do
  initialPrerequisitesExit <- runPhaseOneInitialPrerequisites repoRoot suitePlan
  case initialPrerequisitesExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      preparationExit <-
        runSequentially
          ( runbookActions repoRoot environment suitePlan
              ++ supportedRuntimeBootstrapActions repoRoot environment suitePlan
          )
      case preparationExit of
        failure@(ExitFailure _) -> pure failure
        ExitSuccess -> do
          deferredPrerequisitesExit <- runPhaseOneDeferredPrerequisites repoRoot suitePlan
          case deferredPrerequisitesExit of
            failure@(ExitFailure _) -> pure failure
            ExitSuccess -> runPhaseTwo repoRoot environment haskellSuites suitePlan

runPhaseTwo :: FilePath -> [(String, String)] -> [String] -> NativeSuitePlan -> IO ExitCode
runPhaseTwo repoRoot environment haskellSuites suitePlan = do
  phaseTwoExit <- emitLineAction phaseTwoMessage
  case phaseTwoExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      haskellExit <- runHaskellSuites repoRoot environment haskellSuites
      case haskellExit of
        failure@(ExitFailure _) -> pure failure
        ExitSuccess ->
          runSequentially
            ( runNativeValidations repoRoot environment suitePlan
                : supportedRuntimePostflightActions repoRoot environment suitePlan
            )

runSequentially :: [IO ExitCode] -> IO ExitCode
runSequentially = foldM step ExitSuccess
 where
  step :: ExitCode -> IO ExitCode -> IO ExitCode
  step failure@(ExitFailure _) _ = pure failure
  step ExitSuccess action = action

emitLineAction :: String -> IO ExitCode
emitLineAction message = writeOutputLine message >> pure ExitSuccess

runbookActions :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
runbookActions repoRoot environment suitePlan =
  if nativeRequiresIntegrationRunbook suitePlan
    then
      [ emitLineAction phaseOnePointFiveMessage
      , runNativeCliCommandForExitCode repoRoot environment ["rke2", "reconcile"]
      ]
    else []

supportedRuntimeBootstrapActions
  :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
supportedRuntimeBootstrapActions repoRoot environment suitePlan =
  if nativeRequiresSupportedRuntimeBootstrap suitePlan
    then
      let reconcileActions =
            [ runNativeCliCommandForExitCode repoRoot environment ["rke2", "reconcile"]
            | supportedRuntimeBootstrapNeedsReconcile suitePlan
            ]
       in [emitLineAction phaseOnePointSixMessage]
            ++ reconcileActions
            ++ [ runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "websocket", "--yes"]
               , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "api", "--yes"]
               , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "vscode", "--yes"]
               , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "gateway", "--yes"]
               , -- Sprint 2.19 closure (2026-05-29): re-ensure the gateway-minio
                 -- Secret + the matching MinIO user AFTER `charts delete gateway`
                 -- (helm uninstall + atomic rollback can delete the Secret despite
                 -- the `helm.sh/resource-policy: keep` annotation) and BEFORE
                 -- `charts deploy gateway` so the Deployment's volume mount can
                 -- bind to a present Secret and the daemon authenticates as a
                 -- user that exists in MinIO. Idempotent: reuses existing Secret
                 -- when present, regenerates when absent; the Job's
                 -- `mc admin user add` / `mc admin policy attach` are no-ops on
                 -- re-run.
                 ensureGatewayMinioBootstrap repoRoot
               , syncKeycloakSmtpForSupportedRuntime repoRoot suitePlan
               , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "gateway"]
               , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "vscode"]
               , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "api"]
               , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "websocket"]
               , runWaitForPublicEdgeReady
                   repoRoot
                   environment
                   SubstrateHomeLocal
                   publicEdgeReadyAttempts
                   publicEdgeReadyDelayMicroseconds
               ]
            ++ awsSubstrateBootstrapActions repoRoot environment suitePlan
    else []

supportedRuntimeBootstrapNeedsReconcile :: NativeSuitePlan -> Bool
supportedRuntimeBootstrapNeedsReconcile suitePlan =
  nativeRequiresSupportedRuntimeBootstrap suitePlan
    && not (nativeRequiresIntegrationRunbook suitePlan)

supportedRuntimeBootstrapNeedsKeycloakSmtpSync :: NativeSuitePlan -> Bool
supportedRuntimeBootstrapNeedsKeycloakSmtpSync suitePlan =
  nativeRequiresSupportedRuntimeBootstrap suitePlan
    && ValidationKeycloakInvite `elem` nativeValidations suitePlan

syncKeycloakSmtpForSupportedRuntime :: FilePath -> NativeSuitePlan -> IO ExitCode
syncKeycloakSmtpForSupportedRuntime repoRoot suitePlan =
  if supportedRuntimeBootstrapNeedsKeycloakSmtpSync suitePlan
    then
      syncKeycloakSmtpForCurrentKubeContext
        repoRoot
        "Supported runtime bootstrap: syncing Keycloak SMTP Secret from aws-ses"
    else pure ExitSuccess

-- | AWS-substrate-specific bootstrap: provision the per-run AWS Pulumi
-- stacks and deploy the AWS chart set so substrate-aware validations
-- (@charts-vscode --substrate aws@, @public-edge --substrate aws@, the
-- cert-manager DNS01 ACME @ClusterIssuer@) can reach EKS, read the Route
-- 53 subzone's hosted-zone ID, and talk to the validation EC2 nodes. The
-- substrate-platform install in
-- 'Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstratePlatformRuntime'
-- documents the Pulumi stacks as preconditions; the test harness owns the
-- provisioning per [CLAUDE.md "AWS Substrate Provisioning
-- Ownership"](../../CLAUDE.md). Idempotent: every @prodbox pulumi
-- <stack>-resources@ entrypoint uses Pulumi's standard @up@ semantics, and
-- every chart deploy uses Helm's upgrade/install path.
--
-- The canonical validation order (@canonicalNativeValidations@ in
-- 'Prodbox.TestPlan') puts @charts-vscode@ first and @aws-eks@ /
-- @ha-rke2-aws@ much later. On the home substrate that ordering is fine
-- because @charts-vscode@ runs against the local cluster brought up by
-- 'supportedRuntimeBootstrapActions'. On the AWS substrate
-- @charts-vscode@ needs EKS already provisioned, so we provision aws-eks
-- (and aws-test for the HA-RKE2 validation) here in the bootstrap rather
-- than waiting for the validation-driven path.
awsSubstrateBootstrapActions
  :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
awsSubstrateBootstrapActions repoRoot environment suitePlan =
  case nativeSubstrate suitePlan of
    SubstrateHomeLocal -> []
    SubstrateAws -> [runAwsSubstrateBootstrap repoRoot environment suitePlan]

runAwsSubstrateBootstrap :: FilePath -> [(String, String)] -> NativeSuitePlan -> IO ExitCode
runAwsSubstrateBootstrap repoRoot environment suitePlan =
  case awsSubstrateBootstrapCommandArgs suitePlan of
    [] -> pure ExitSuccess
    subzoneCommand : remainingCommands -> do
      subzoneExit <- runNativeCliCommandForExitCode repoRoot environment subzoneCommand
      case subzoneExit of
        failure@(ExitFailure _) -> pure failure
        ExitSuccess ->
          -- Sprint 7.13: the subzone Pulumi stack is now provisioned, so
          -- every child `prodbox` process resolves
          -- `aws_substrate.hosted_zone_id` from settings or the live
          -- aws-eks-subzone Pulumi output via
          -- `Prodbox.PublicEdge.resolveSubstrateHostedZoneId`. No
          -- `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` env var is set or read
          -- (config_doctrine.md § 10, no `PRODBOX_*` config reads).
          runAwsSubstrateBootstrapAfterSubzone
            repoRoot
            environment
            remainingCommands

runAwsSubstrateBootstrapAfterSubzone
  :: FilePath -> [(String, String)] -> [[String]] -> IO ExitCode
runAwsSubstrateBootstrapAfterSubzone repoRoot environmentWithHostedZone commands =
  let (stackCommands, chartCommands) = break isAwsSubstrateChartDeployCommand commands
   in do
        stackExit <-
          runSequentially
            ( map
                (runNativeCliCommandForExitCode repoRoot environmentWithHostedZone)
                stackCommands
            )
        case stackExit of
          failure@(ExitFailure _) -> pure failure
          ExitSuccess -> do
            smtpSyncExit <-
              if null chartCommands
                then pure ExitSuccess
                else syncKeycloakSmtpForAwsSubstrate repoRoot
            case smtpSyncExit of
              failure@(ExitFailure _) -> pure failure
              ExitSuccess ->
                runSequentially
                  ( map
                      (runNativeCliCommandForExitCode repoRoot environmentWithHostedZone)
                      chartCommands
                  )

isAwsSubstrateChartDeployCommand :: [String] -> Bool
isAwsSubstrateChartDeployCommand command =
  case command of
    ["charts", "deploy", _chartName, "--substrate", "aws"] -> True
    _ -> False

syncKeycloakSmtpForAwsSubstrate :: FilePath -> IO ExitCode
syncKeycloakSmtpForAwsSubstrate repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings ->
      withEksKubeconfig repoRoot $ \kubeconfigPath -> do
        let awsCreds = aws (validatedConfig settings)
            envOverrides =
              [ ("KUBECONFIG", kubeconfigPath)
              , ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id awsCreds))
              , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key awsCreds))
              , ("AWS_DEFAULT_REGION", Text.unpack (region awsCreds))
              , ("AWS_REGION", Text.unpack (region awsCreds))
              ]
                ++ maybe [] (\tok -> [("AWS_SESSION_TOKEN", Text.unpack tok)]) (session_token awsCreds)
        previousValues <- mapM (\(name, _) -> lookupEnv name) envOverrides
        bracket_
          (mapM_ (\(name, value) -> setEnv name value) envOverrides)
          (mapM_ restoreOne (zip envOverrides previousValues))
          ( syncKeycloakSmtpForCurrentKubeContext
              repoRoot
              "AWS substrate bootstrap: syncing Keycloak SMTP Secret from aws-ses"
          )
 where
  restoreOne :: ((String, String), Maybe String) -> IO ()
  restoreOne ((name, _), Nothing) = unsetEnv name
  restoreOne ((name, _), Just value) = setEnv name value

syncKeycloakSmtpForCurrentKubeContext :: FilePath -> String -> IO ExitCode
syncKeycloakSmtpForCurrentKubeContext repoRoot message = do
  writeOutputLine message
  syncResult <- AwsSesStack.syncKeycloakSmtpChartSecrets repoRoot
  case syncResult of
    Left err -> failWith err
    Right () -> pure ExitSuccess

awsSubstrateBootstrapCommandArgs :: NativeSuitePlan -> [[String]]
awsSubstrateBootstrapCommandArgs suitePlan =
  case nativeSubstrate suitePlan of
    SubstrateHomeLocal -> []
    SubstrateAws ->
      [ ["pulumi", "aws-subzone-resources"]
      , ["pulumi", "eks-resources"]
      , ["pulumi", "test-resources"]
      , ["charts", "deploy", "gateway", "--substrate", "aws"]
      , ["charts", "deploy", "vscode", "--substrate", "aws"]
      , ["charts", "deploy", "api", "--substrate", "aws"]
      , ["charts", "deploy", "websocket", "--substrate", "aws"]
      ]

-- | Post-success suite restore actions: reconcile the local cluster
-- and re-deploy the canonical chart set so the operator's substrate
-- is back to a known-good steady state after destructive tests. AWS
-- per-run-stack destroys are handled separately by
-- 'awsPostflightDestroyActions', which runs on every exit path (Sprint
-- 7.6 orphan-safety guard).
supportedRuntimePostflightActions
  :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
supportedRuntimePostflightActions repoRoot environment suitePlan =
  if nativeRequiresSupportedRuntimePostflight suitePlan
    then
      [ emitLineAction postTestRestoreMessage
      , runNativeCliCommandForExitCode repoRoot environment ["rke2", "reconcile"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "websocket", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "api", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "vscode", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "gateway", "--yes"]
      , -- Sprint 2.19 closure (2026-05-29): re-ensure the gateway-minio
        -- Secret + the matching MinIO user AFTER `charts delete gateway`
        -- (helm uninstall + atomic rollback can delete the Secret despite
        -- the `helm.sh/resource-policy: keep` annotation) and BEFORE
        -- `charts deploy gateway` so the Deployment's volume mount can
        -- bind to a present Secret and the daemon authenticates as a
        -- user that exists in MinIO. Idempotent: reuses existing Secret
        -- when present, regenerates when absent; the Job's
        -- `mc admin user add` / `mc admin policy attach` are no-ops on
        -- re-run.
        ensureGatewayMinioBootstrap repoRoot
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "gateway"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "vscode"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "api"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "websocket"]
      , runWaitForPublicEdgeReady
          repoRoot
          environment
          SubstrateHomeLocal
          publicEdgeReadyAttempts
          publicEdgeReadyDelayMicroseconds
      ]
    else []

runNativeValidations :: FilePath -> [(String, String)] -> NativeSuitePlan -> IO ExitCode
runNativeValidations repoRoot environment suitePlan =
  case nativeValidations suitePlan of
    [] -> pure ExitSuccess
    validations -> foldM runValidation ExitSuccess validations
 where
  runValidation :: ExitCode -> NativeValidation -> IO ExitCode
  runValidation failure@(ExitFailure _) _ = pure failure
  runValidation ExitSuccess validation =
    runNativeValidation (nativeSubstrate suitePlan) repoRoot environment validation

runPhaseOneInitialPrerequisites :: FilePath -> NativeSuitePlan -> IO ExitCode
runPhaseOneInitialPrerequisites repoRoot suitePlan =
  case nativeInitialIntegrationGatePrerequisites suitePlan of
    [] -> pure ExitSuccess
    prerequisites ->
      case fromRootIds prerequisites prerequisiteRegistry of
        Left err -> failWith err
        Right dag -> do
          result <-
            runEffectDAG
              InterpreterContext {interpreterRepoRoot = repoRoot}
              dag
          case result of
            Failure err -> failWith err
            Success () -> pure ExitSuccess

runPhaseOneDeferredPrerequisites :: FilePath -> NativeSuitePlan -> IO ExitCode
runPhaseOneDeferredPrerequisites repoRoot suitePlan =
  case nativeDeferredIntegrationGatePrerequisites suitePlan of
    [] -> pure ExitSuccess
    prerequisites ->
      case fromRootIds prerequisites prerequisiteRegistry of
        Left err -> failWith err
        Right dag -> do
          result <-
            runEffectDAG
              InterpreterContext {interpreterRepoRoot = repoRoot}
              dag
          case result of
            Failure err -> failWith err
            Success () -> pure ExitSuccess

phaseOneMessage :: NativeSuitePlan -> String
phaseOneMessage suitePlan =
  if null (nativeInitialIntegrationGatePrerequisites suitePlan)
    && null (nativeDeferredIntegrationGatePrerequisites suitePlan)
    then phaseOneNoPrereqMessage
    else phaseOneGateMessage

runManagedAwsHarnessSetup :: FilePath -> PolicyTier -> IO ExitCode
runManagedAwsHarnessSetup repoRoot policyTier = do
  setupResult <- try (runAwsIamHarnessSetup repoRoot policyTier) :: IO (Either SomeException String)
  case setupResult of
    Left err ->
      failWith
        ( "Managed AWS IAM harness setup failed: "
            ++ displayException err
        )
    Right output -> do
      writeOutput output
      pure ExitSuccess

runManagedAwsHarnessTeardown :: FilePath -> IO ExitCode
runManagedAwsHarnessTeardown repoRoot = do
  teardownResult <- try (runAwsIamHarnessTeardown repoRoot) :: IO (Either SomeException String)
  case teardownResult of
    Left err ->
      failWith
        ( "Managed AWS IAM harness teardown failed: "
            ++ displayException err
        )
    Right output -> do
      writeOutput output
      pure ExitSuccess

preferEarlierFailure :: ExitCode -> ExitCode -> ExitCode
preferEarlierFailure earlierResult cleanupResult =
  case earlierResult of
    failure@(ExitFailure _) -> failure
    ExitSuccess -> cleanupResult

runCommandForExitCode :: Subprocess -> IO ExitCode
runCommandForExitCode spec = do
  commandResult <- runSubprocessStreaming spec
  case commandResult of
    Failure err -> failWith err
    Success exitCode -> pure exitCode

runWaitForPublicEdgeReady
  :: FilePath -> [(String, String)] -> Substrate -> Int -> Int -> IO ExitCode
runWaitForPublicEdgeReady repoRoot environment substrate attempts delayMicroseconds =
  go attempts publicEdgeCertificateRepairAttempts
 where
  spec =
    nativeCliCommandSpec
      repoRoot
      environment
      ["host", "public-edge", "--substrate", substrateId substrate]

  go :: Int -> Int -> IO ExitCode
  go attemptsLeft repairsLeft = do
    outputResult <- captureSubprocessResult spec
    case outputResult of
      Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
      Success output -> do
        let combinedOutput = processStdout output ++ processStderr output
        writeOutput (processStdout output)
        writeDiagnostic (processStderr output)
        case processExitCode output of
          ExitFailure code ->
            failWith
              ( "`"
                  ++ commandDisplay spec
                  ++ "` exited with code "
                  ++ show code
              )
          ExitSuccess
            | publicEdgeReadyClassification `isInfixOf` combinedOutput -> do
                -- Sprint 8.8 retain-on-ready: capture the freshly-issued cert
                -- to the long-lived S3 store now that it is confirmed ready, so
                -- every subsequent rebuild restores it instead of re-ordering
                -- against ZeroSSL. Best-effort: a retention failure never fails
                -- the run (the cert is already issued and serving).
                retainOutcome <- retainReadyPublicEdgeCertificate repoRoot substrate
                case retainOutcome of
                  Left err ->
                    writeDiagnosticLine
                      ("public-edge cert retain-on-ready failed (non-fatal): " ++ err)
                  Right outcome ->
                    writeDiagnosticLine
                      ("public-edge cert retain-on-ready: " ++ renderPublicEdgePreserveOutcome outcome)
                pure ExitSuccess
            | attemptsLeft <= 1 ->
                failWith
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` did not report required output `"
                      ++ publicEdgeReadyClassification
                      ++ "` before timeout."
                  )
            | otherwise -> do
                repairResult <-
                  if repairsLeft > 0
                    then maybeRepairPublicEdgeCertificateIssuance repoRoot environment combinedOutput
                    else pure (Right False)
                case repairResult of
                  Left err -> failWith err
                  Right repaired -> do
                    writeDiagnosticLine
                      ( if repaired
                          then "Waiting for public-edge certificate reissue before retry."
                          else "Waiting for required native command output before retry."
                      )
                    threadDelay delayMicroseconds
                    go
                      (attemptsLeft - 1)
                      ( if repaired
                          then repairsLeft - 1
                          else repairsLeft
                      )

maybeRepairPublicEdgeCertificateIssuance
  :: FilePath
  -> [(String, String)]
  -> String
  -> IO (Either String Bool)
maybeRepairPublicEdgeCertificateIssuance repoRoot environment combinedOutput
  | "CLASSIFICATION=certificate-not-ready" `notElem` lines combinedOutput = pure (Right False)
  | otherwise = do
      failureInfoResult <- loadPublicEdgeCertificateFailure repoRoot environment
      case failureInfoResult of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right False)
        Right (Just failureInfo) -> do
          repairTargetsResult <- loadPublicEdgeRepairTargets repoRoot environment failureInfo
          case repairTargetsResult of
            Left err -> pure (Left err)
            Right repairTargets ->
              if null repairTargets
                then do
                  writeOutputLine
                    ( "Detected failed public-edge certificate issuance ("
                        ++ show (publicEdgeFailedIssuanceAttempts failureInfo)
                        ++ " failed attempt(s)); no stale ACME resources remain, triggering immediate reissue."
                    )
                  triggerPublicEdgeCertificateReissue repoRoot environment failureInfo
                else do
                  writeOutputLine
                    ( "Detected failed public-edge certificate issuance ("
                        ++ show (publicEdgeFailedIssuanceAttempts failureInfo)
                        ++ " failed attempt(s)); deleting stale ACME resources for an immediate reissue."
                    )
                  deleteResult <-
                    captureSubprocessResult
                      Subprocess
                        { subprocessPath = "kubectl"
                        , subprocessArguments = ["-n", publicEdgeNamespace, "delete", "--ignore-not-found"] ++ repairTargets
                        , subprocessEnvironment = Just environment
                        , subprocessWorkingDirectory = Just repoRoot
                        }
                  case deleteResult of
                    Failure err ->
                      pure
                        ( Left
                            ( "failed to start `kubectl` while repairing public-edge certificate issuance: "
                                ++ err
                            )
                        )
                    Success deleteOutput ->
                      case processExitCode deleteOutput of
                        ExitFailure _ ->
                          pure
                            ( Left
                                ( "Failed to delete stale public-edge ACME resources: "
                                    ++ processStderr deleteOutput
                                    ++ processStdout deleteOutput
                                )
                            )
                        ExitSuccess ->
                          triggerPublicEdgeCertificateReissue repoRoot environment failureInfo

triggerPublicEdgeCertificateReissue
  :: FilePath
  -> [(String, String)]
  -> PublicEdgeCertificateFailure
  -> IO (Either String Bool)
triggerPublicEdgeCertificateReissue repoRoot environment failureInfo = do
  now <- getCurrentTime
  let timestamp = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
      statusPatch = publicEdgeCertificateReissueStatusPatch timestamp failureInfo
  patchResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "-n"
            , publicEdgeNamespace
            , "patch"
            , "certificate"
            , publicEdgeCertificateName
            , "--subresource=status"
            , "--type=merge"
            , "-p"
            , statusPatch
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case patchResult of
      Failure err ->
        Left ("failed to start `kubectl` while triggering public-edge certificate reissue: " ++ err)
      Success patchOutput ->
        case processExitCode patchOutput of
          ExitFailure _ ->
            Left
              ( "Failed to trigger public-edge certificate reissue: "
                  ++ processStderr patchOutput
                  ++ processStdout patchOutput
              )
          ExitSuccess -> Right True

publicEdgeCertificateReissueStatusPatch :: String -> PublicEdgeCertificateFailure -> String
publicEdgeCertificateReissueStatusPatch timestamp failureInfo =
  BL8.unpack
    ( encode
        ( object
            [ "status"
                .= object
                  [ "conditions"
                      .= [ object
                             ( baseConditionFields
                                 ++ maybe
                                   []
                                   (\generation -> ["observedGeneration" .= generation])
                                   (publicEdgeCertificateObservedGeneration failureInfo)
                             )
                         ]
                  ]
            ]
        )
    )
 where
  baseConditionFields =
    [ "type" .= ("Issuing" :: String)
    , "status" .= ("True" :: String)
    , "reason" .= ("ManualTrigger" :: String)
    , "message"
        .= ( "Certificate renewal manually triggered by prodbox after failed public-edge issuance"
               :: String
           )
    , "lastTransitionTime" .= timestamp
    ]

loadPublicEdgeCertificateFailure
  :: FilePath
  -> [(String, String)]
  -> IO (Either String (Maybe PublicEdgeCertificateFailure))
loadPublicEdgeCertificateFailure repoRoot environment = do
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "-n"
            , publicEdgeNamespace
            , "get"
            , "certificate"
            , publicEdgeCertificateName
            , "--ignore-not-found=true"
            , "-o"
            , "jsonpath={.status.failedIssuanceAttempts}{\"|\"}{.status.nextPrivateKeySecretName}{\"|\"}{.metadata.generation}"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case outputResult of
      Failure err ->
        Left ("failed to start `kubectl` while checking public-edge certificate status: " ++ err)
      Success output ->
        case processExitCode output of
          ExitFailure _ ->
            Left
              ( "Failed to inspect public-edge certificate status: "
                  ++ processStderr output
                  ++ processStdout output
              )
          ExitSuccess ->
            Right (parsePublicEdgeCertificateFailure (processStdout output))

loadPublicEdgeRepairTargets
  :: FilePath
  -> [(String, String)]
  -> PublicEdgeCertificateFailure
  -> IO (Either String [String])
loadPublicEdgeRepairTargets repoRoot environment failureInfo = do
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "-n"
            , publicEdgeNamespace
            , "get"
            , "certificaterequest,order,challenge"
            , "-o"
            , "name"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case outputResult of
      Failure err ->
        Left ("failed to start `kubectl` while listing public-edge ACME resources: " ++ err)
      Success output ->
        case processExitCode output of
          ExitFailure _ ->
            Left
              ( "Failed to list public-edge ACME resources: "
                  ++ processStderr output
                  ++ processStdout output
              )
          ExitSuccess ->
            Right
              ( filter isPublicEdgeAcmeResource (nonEmptyLines (processStdout output))
                  ++ maybe [] (\secretName -> ["secret/" ++ secretName]) (publicEdgeNextPrivateKeySecretName failureInfo)
              )

parsePublicEdgeCertificateFailure :: String -> Maybe PublicEdgeCertificateFailure
parsePublicEdgeCertificateFailure stdoutText =
  case splitOnChar '|' (trimWhitespace stdoutText) of
    [] -> Nothing
    [""] -> Nothing
    attemptsText : secretNameText : generationText : _ ->
      parseFailure
        attemptsText
        (normalizeOptionalText secretNameText)
        (parsePositiveInt generationText)
    attemptsText : secretNameText : _ ->
      parseFailure attemptsText (normalizeOptionalText secretNameText) Nothing
    attemptsText : _ ->
      parseFailure attemptsText Nothing Nothing
 where
  parseFailure :: String -> Maybe String -> Maybe Int -> Maybe PublicEdgeCertificateFailure
  parseFailure attemptsText maybeSecretName maybeGeneration =
    case reads attemptsText of
      [(attemptCount, "")]
        | attemptCount > 0 ->
            Just
              PublicEdgeCertificateFailure
                { publicEdgeFailedIssuanceAttempts = attemptCount
                , publicEdgeNextPrivateKeySecretName = maybeSecretName
                , publicEdgeCertificateObservedGeneration = maybeGeneration
                }
      _ -> Nothing

  parsePositiveInt :: String -> Maybe Int
  parsePositiveInt value =
    case reads (trimWhitespace value) of
      [(parsed, "")]
        | parsed > 0 -> Just parsed
      _ -> Nothing

isPublicEdgeAcmeResource :: String -> Bool
isPublicEdgeAcmeResource resourceName =
  case break (== '/') resourceName of
    (_, '/' : objectName) -> (publicEdgeCertificateName ++ "-") `isPrefixOf` objectName
    _ -> False

nonEmptyLines :: String -> [String]
nonEmptyLines =
  filter (not . null) . map trimWhitespace . lines

splitOnChar :: Char -> String -> [String]
splitOnChar separator = go []
 where
  go current [] = [reverse current]
  go current (character : rest)
    | character == separator = reverse current : go [] rest
    | otherwise = go (character : current) rest

trimWhitespace :: String -> String
trimWhitespace = dropWhileEnd isWhitespace . dropWhile isWhitespace
 where
  isWhitespace character = character == ' ' || character == '\n' || character == '\r' || character == '\t'

normalizeOptionalText :: String -> Maybe String
normalizeOptionalText rawValue =
  let trimmed = trimWhitespace rawValue
   in if null trimmed
        then Nothing
        else Just trimmed

runNativeCliCommandForExitCode :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runNativeCliCommandForExitCode repoRoot environment cliArgs = do
  runCommandForExitCode (nativeCliCommandSpec repoRoot environment cliArgs)

nativeCliCommandSpec :: FilePath -> [(String, String)] -> [String] -> Subprocess
nativeCliCommandSpec repoRoot environment cliArgs =
  Subprocess
    { subprocessPath = canonicalOperatorBinaryPath repoRoot
    , subprocessArguments = cliArgs
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just repoRoot
    }

ensureCanonicalOperatorBinary :: FilePath -> [(String, String)] -> IO ExitCode
ensureCanonicalOperatorBinary repoRoot environment = do
  syncResult <- syncBuiltOperatorBinary repoRoot environment
  case syncResult of
    Left err -> failWith err
    Right binaryPath
      | binaryPath == canonicalOperatorBinaryPath repoRoot -> pure ExitSuccess
      | otherwise ->
          failWith
            ( "canonical operator binary synced to unexpected path: "
                ++ binaryPath
            )

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
