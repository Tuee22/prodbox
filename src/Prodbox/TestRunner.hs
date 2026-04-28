module Prodbox.TestRunner (
    runTests,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (
    SomeException,
    displayException,
    try,
 )
import Control.Monad (foldM, unless)
import Data.List (isInfixOf)
import Prodbox.Aws (
    runAwsIamHarnessSetup,
    runAwsIamHarnessTeardown,
 )
import Prodbox.BuildSupport (
    addBuildSupportEnvironment,
    canonicalOperatorBinaryPath,
    syncBuiltOperatorBinary,
 )
import Prodbox.CLI.Command (
    PolicyTier,
    TestCommand (..),
    validateCoverage,
 )
import Prodbox.EffectDAG (
    fromRootIds,
 )
import Prodbox.EffectInterpreter (
    InterpreterContext (..),
    runEffectDAG,
 )
import Prodbox.Prerequisite (
    prerequisiteRegistry,
 )
import Prodbox.Result (
    Result (..),
 )
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
    runStreamingCommand,
 )
import Prodbox.TestPlan (
    NativeSuitePlan (..),
    NativeValidation,
    TestExecutionMode (..),
    TestExecutionPlan (..),
    testExecutionPlan,
 )
import Prodbox.TestValidation (runNativeValidation)
import System.Environment (
    getEnvironment,
 )
import System.Exit (
    ExitCode (..),
 )
import System.IO (
    hPutStr,
    hPutStrLn,
    stderr,
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

publicEdgeReadyClassification :: String
publicEdgeReadyClassification = "CLASSIFICATION=ready-for-external-proof"

publicEdgeReadyAttempts :: Int
publicEdgeReadyAttempts = 30

publicEdgeReadyDelayMicroseconds :: Int
publicEdgeReadyDelayMicroseconds = 10000000

runTests :: FilePath -> TestCommand -> IO ExitCode
runTests repoRoot command =
    case validateCoverage (testCoverage command) of
        Left err -> failWith err
        Right () -> do
            baseEnvironment <- getEnvironment
            environment <- addBuildSupportEnvironment repoRoot baseEnvironment
            let plan = testExecutionPlan (testScope command)
            putStrLn ("Running prodbox test " ++ testPlanLabel plan ++ " (Haskell entrypoint)")
            haskellExit <- runHaskellSuites repoRoot environment (testPlanHaskellSuites plan)
            case haskellExit of
                ExitSuccess ->
                    case testPlanExecutionMode plan of
                        DelegatedSuite _ ->
                            pure ExitSuccess
                        NativeSuite suitePlan -> do
                            prepareExit <- ensureCanonicalOperatorBinary repoRoot environment
                            case prepareExit of
                                ExitSuccess -> runNativeSuite repoRoot environment suitePlan
                                failure@(ExitFailure _) -> pure failure
                failure@(ExitFailure _) -> pure failure

runHaskellSuites :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runHaskellSuites repoRoot environment suites = do
    unless (null suites) (putStrLn "Running Haskell test suites")
    foldM runSuite ExitSuccess suites
  where
    runSuite :: ExitCode -> String -> IO ExitCode
    runSuite failure@(ExitFailure _) _ = pure failure
    runSuite ExitSuccess suiteName =
        runCommandForExitCode
            CommandSpec
                { commandPath = "cabal"
                , commandArguments =
                    [ "test"
                    , "--builddir=.build"
                    , suiteName
                    , "--test-show-details=direct"
                    ]
                , commandEnvironment = Just environment
                , commandWorkingDirectory = Just repoRoot
                }

runNativeSuite :: FilePath -> [(String, String)] -> NativeSuitePlan -> IO ExitCode
runNativeSuite repoRoot environment suitePlan = do
    bannerExit <- emitLineAction (phaseOneMessage suitePlan)
    case bannerExit of
        failure@(ExitFailure _) -> pure failure
        ExitSuccess ->
            case nativeManagedAwsHarnessPolicyTier suitePlan of
                Nothing -> runNativeSuiteBody repoRoot environment suitePlan
                Just policyTier -> do
                    setupExit <- runManagedAwsHarnessSetup repoRoot policyTier
                    case setupExit of
                        failure@(ExitFailure _) -> pure failure
                        ExitSuccess -> do
                            suiteExit <- runNativeSuiteBody repoRoot environment suitePlan
                            cleanupExit <- runManagedAwsHarnessTeardown repoRoot
                            pure (preferEarlierFailure suiteExit cleanupExit)

runNativeSuiteBody :: FilePath -> [(String, String)] -> NativeSuitePlan -> IO ExitCode
runNativeSuiteBody repoRoot environment suitePlan = do
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
                        ExitSuccess -> runNativeWorkflow repoRoot environment suitePlan

runNativeWorkflow :: FilePath -> [(String, String)] -> NativeSuitePlan -> IO ExitCode
runNativeWorkflow repoRoot environment suitePlan =
    runSequentially
        ( [emitLineAction phaseTwoMessage, runNativeValidations repoRoot environment suitePlan]
            ++ supportedRuntimePostflightActions repoRoot environment suitePlan
        )

runSequentially :: [IO ExitCode] -> IO ExitCode
runSequentially = foldM step ExitSuccess
  where
    step :: ExitCode -> IO ExitCode -> IO ExitCode
    step failure@(ExitFailure _) _ = pure failure
    step ExitSuccess action = action

emitLineAction :: String -> IO ExitCode
emitLineAction message = putStrLn message >> pure ExitSuccess

runbookActions :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
runbookActions repoRoot environment suitePlan =
    if nativeRequiresIntegrationRunbook suitePlan
        then
            [ emitLineAction phaseOnePointFiveMessage
            , runNativeCliCommandForExitCode repoRoot environment ["rke2", "install"]
            ]
        else []

supportedRuntimeBootstrapActions :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
supportedRuntimeBootstrapActions repoRoot environment suitePlan =
    if nativeRequiresSupportedRuntimeBootstrap suitePlan
        then
            [ emitLineAction phaseOnePointSixMessage
            , runNativeCliCommandForExitCode repoRoot environment ["rke2", "install"]
            , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "vscode", "--yes"]
            , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "gateway", "--yes"]
            , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "gateway"]
            , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "vscode"]
            , runWaitForNativeCommandOutputContains
                repoRoot
                environment
                ["host", "public-edge"]
                publicEdgeReadyClassification
                publicEdgeReadyAttempts
                publicEdgeReadyDelayMicroseconds
            ]
        else []

supportedRuntimePostflightActions :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
supportedRuntimePostflightActions repoRoot environment suitePlan =
    if nativeRequiresSupportedRuntimePostflight suitePlan
        then
            [ emitLineAction postTestRestoreMessage
            , runNativeCliCommandForExitCode repoRoot environment ["rke2", "install"]
            , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "vscode", "--yes"]
            , runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "gateway", "--yes"]
            , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "gateway"]
            , runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "vscode"]
            , runWaitForNativeCommandOutputContains
                repoRoot
                environment
                ["host", "public-edge"]
                publicEdgeReadyClassification
                publicEdgeReadyAttempts
                publicEdgeReadyDelayMicroseconds
            , runNativeCliCommandForExitCode repoRoot environment ["pulumi", "eks-destroy", "--yes"]
            , runNativeCliCommandForExitCode repoRoot environment ["pulumi", "test-destroy", "--yes"]
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
    runValidation ExitSuccess validation = runNativeValidation repoRoot environment validation

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
                            InterpreterContext{interpreterRepoRoot = repoRoot}
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
                            InterpreterContext{interpreterRepoRoot = repoRoot}
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
            putStr output
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
            putStr output
            pure ExitSuccess

preferEarlierFailure :: ExitCode -> ExitCode -> ExitCode
preferEarlierFailure earlierResult cleanupResult =
    case earlierResult of
        failure@(ExitFailure _) -> failure
        ExitSuccess -> cleanupResult

runCommandForExitCode :: CommandSpec -> IO ExitCode
runCommandForExitCode spec = do
    commandResult <- runStreamingCommand spec
    case commandResult of
        Failure err -> failWith err
        Success exitCode -> pure exitCode

runWaitForCommandOutputContains :: CommandSpec -> String -> Int -> Int -> IO ExitCode
runWaitForCommandOutputContains spec expectedText attemptsLeft delayMicroseconds = do
    outputResult <- captureCommand spec
    case outputResult of
        Failure err -> failWith ("failed to start `" ++ unwords (commandPath spec : commandArguments spec) ++ "`: " ++ err)
        Success output -> do
            let combinedOutput = processStdout output ++ processStderr output
            putStr (processStdout output)
            hPutStr stderr (processStderr output)
            case processExitCode output of
                ExitFailure code ->
                    failWith
                        ( "`"
                            ++ unwords (commandPath spec : commandArguments spec)
                            ++ "` exited with code "
                            ++ show code
                        )
                ExitSuccess
                    | expectedText `isInfixOf` combinedOutput -> pure ExitSuccess
                    | attemptsLeft <= 1 ->
                        failWith
                            ( "`"
                                ++ unwords (commandPath spec : commandArguments spec)
                                ++ "` did not report required output `"
                                ++ expectedText
                                ++ "` before timeout."
                            )
                    | otherwise -> do
                        hPutStrLn stderr "Waiting for required native command output before retry."
                        threadDelay delayMicroseconds
                        runWaitForCommandOutputContains spec expectedText (attemptsLeft - 1) delayMicroseconds

runWaitForNativeCommandOutputContains :: FilePath -> [(String, String)] -> [String] -> String -> Int -> Int -> IO ExitCode
runWaitForNativeCommandOutputContains repoRoot environment cliArgs expectedText attempts delayMicroseconds = do
    runWaitForCommandOutputContains
        (nativeCliCommandSpec repoRoot environment cliArgs)
        expectedText
        attempts
        delayMicroseconds

runNativeCliCommandForExitCode :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runNativeCliCommandForExitCode repoRoot environment cliArgs = do
    runCommandForExitCode (nativeCliCommandSpec repoRoot environment cliArgs)

nativeCliCommandSpec :: FilePath -> [(String, String)] -> [String] -> CommandSpec
nativeCliCommandSpec repoRoot environment cliArgs =
    CommandSpec
        { commandPath = canonicalOperatorBinaryPath repoRoot
        , commandArguments = cliArgs
        , commandEnvironment = Just environment
        , commandWorkingDirectory = Just repoRoot
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
    hPutStrLn stderr message
    pure (ExitFailure 1)
