module Prodbox.TestRunner
  ( runTests
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( SomeException
  , displayException
  , throwIO
  , try
  )
import Control.Monad (foldM, unless)
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf)
import Data.Text qualified as Text
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
import Prodbox.CheckCode (runCheckCode)
import Prodbox.EffectDAG
  ( fromRootIds
  )
import Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , runEffectDAG
  )
import Prodbox.Error (fatalError)
import Prodbox.Prerequisite
  ( prerequisiteRegistry
  )
import Prodbox.Result
  ( Result (..)
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , commandDisplay
  , runSubprocessStreaming
  )
import Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , testExecutionPlan
  )
import Prodbox.TestValidation (runNativeValidation)
import System.Environment
  ( getEnvironment
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

-- | Sprint 7.6 orphan-safety: run the suite body, then unconditionally
-- destroy every per-run Pulumi stack the suite may have provisioned
-- before clearing operational @aws.*@ via the harness teardown. The
-- destroys run on success, failure, and async exception (Ctrl-C)
-- alike, so no `prodbox test all` exit path can strand
-- @aws-eks@ / @aws-eks-subzone@ / @aws-test@ resources in AWS. The
-- @aws-ses@ stack is explicitly excluded per the long-lived
-- cross-substrate shared-infrastructure class in
-- @DEVELOPMENT_PLAN/substrates.md@ § Resource Lifecycle Classes.
runWithAwsHarnessCleanup
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> IO ExitCode
  -> IO ExitCode
runWithAwsHarnessCleanup repoRoot environment suitePlan body = do
  result <- try body :: IO (Either SomeException ExitCode)
  destroyExit <- runSequentially (awsPostflightDestroyActions repoRoot environment suitePlan)
  cleanupExit <- runManagedAwsHarnessTeardown repoRoot
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

awsPostflightDestroyActions
  :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
awsPostflightDestroyActions repoRoot environment suitePlan =
  if nativeRequiresSupportedRuntimePostflight suitePlan
    then
      [ emitLineAction
          ( "Auto-destroying per-run AWS Pulumi stacks (aws-eks, "
              ++ "aws-eks-subzone, aws-test). aws-ses is retained per the "
              ++ "long-lived cross-substrate shared-infrastructure class."
          )
      , runNativeCliCommandForExitCode repoRoot environment ["pulumi", "aws-subzone-destroy", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["pulumi", "eks-destroy", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["pulumi", "test-destroy", "--yes"]
      ]
    else []

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
      [ emitLineAction phaseOnePointSixMessage
      , runNativeCliCommandForExitCode repoRoot environment ["rke2", "reconcile"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "websocket", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "api", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "vscode", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "gateway", "--yes"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "gateway"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "vscode"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "api"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "websocket"]
      , runWaitForPublicEdgeReady
          repoRoot
          environment
          publicEdgeReadyAttempts
          publicEdgeReadyDelayMicroseconds
      ]
    else []

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
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "gateway"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "vscode"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "api"]
      , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "websocket"]
      , runWaitForPublicEdgeReady
          repoRoot
          environment
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

runWaitForPublicEdgeReady :: FilePath -> [(String, String)] -> Int -> Int -> IO ExitCode
runWaitForPublicEdgeReady repoRoot environment attempts delayMicroseconds =
  go attempts publicEdgeCertificateRepairAttempts
 where
  spec = nativeCliCommandSpec repoRoot environment ["host", "public-edge"]

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
            | publicEdgeReadyClassification `isInfixOf` combinedOutput -> pure ExitSuccess
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
                then pure (Right False)
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
                  pure $
                    case deleteResult of
                      Failure err ->
                        Left ("failed to start `kubectl` while repairing public-edge certificate issuance: " ++ err)
                      Success deleteOutput ->
                        case processExitCode deleteOutput of
                          ExitFailure _ ->
                            Left
                              ( "Failed to delete stale public-edge ACME resources: "
                                  ++ processStderr deleteOutput
                                  ++ processStdout deleteOutput
                              )
                          ExitSuccess -> Right True

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
            , "jsonpath={.status.failedIssuanceAttempts}{\"|\"}{.status.nextPrivateKeySecretName}"
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
  case break (== '|') (trimWhitespace stdoutText) of
    ("", _) -> Nothing
    (attemptsText, "") ->
      parseFailure attemptsText Nothing
    (attemptsText, _ : secretNameText) ->
      parseFailure attemptsText (normalizeOptionalText secretNameText)
 where
  parseFailure :: String -> Maybe String -> Maybe PublicEdgeCertificateFailure
  parseFailure attemptsText maybeSecretName =
    case reads attemptsText of
      [(attemptCount, "")]
        | attemptCount > 0 ->
            Just
              PublicEdgeCertificateFailure
                { publicEdgeFailedIssuanceAttempts = attemptCount
                , publicEdgeNextPrivateKeySecretName = maybeSecretName
                }
      _ -> Nothing

isPublicEdgeAcmeResource :: String -> Bool
isPublicEdgeAcmeResource resourceName =
  case break (== '/') resourceName of
    (_, '/' : objectName) -> (publicEdgeCertificateName ++ "-") `isPrefixOf` objectName
    _ -> False

nonEmptyLines :: String -> [String]
nonEmptyLines =
  filter (not . null) . map trimWhitespace . lines

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
