module Prodbox.TestRunner
    ( runTests,
    )
where

import Control.Monad (foldM, unless)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Prodbox.BuildSupport
    ( addBuildSupportEnvironment,
    )
import Prodbox.CLI.Command
    ( TestCommand (..),
      validateCoverage,
    )
import Prodbox.Effect
    ( Effect (EmitLine),
    )
import Prodbox.EffectDAG
    ( EffectDAG,
      EffectNode (..),
      fromRootIds,
      transitiveClosureIds,
    )
import Prodbox.EffectInterpreter
    ( InterpreterContext (..),
      runEffectDAG,
    )
import Prodbox.Prerequisite
    ( prerequisiteRegistry,
    )
import Prodbox.Result
    ( Result (..),
    )
import Prodbox.Subprocess
    ( CommandSpec (..),
      ProcessOutput (..),
      captureCommand,
      runStreamingCommand,
    )
import Prodbox.TestPlan
    ( NativeSuitePlan (..),
      NativeValidation,
      TestExecutionMode (..),
      TestExecutionPlan (..),
      testExecutionPlan,
    )
import Prodbox.TestValidation (runNativeValidation)
import System.Environment
    ( getEnvironment,
      getExecutablePath,
    )
import System.Exit
    ( ExitCode (..),
    )
import System.IO
    ( hPutStr,
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

phaseOneHeaderId :: String
phaseOneHeaderId = "test_phase_one_header"

publicEdgeReadyClassification :: String
publicEdgeReadyClassification = "CLASSIFICATION=ready-for-external-proof"

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
                        NativeSuite suitePlan ->
                            runNativeSuite repoRoot environment suitePlan
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
                { commandPath = "cabal",
                  commandArguments =
                    [ "test",
                      "--builddir=.build",
                      suiteName,
                      "--test-show-details=direct"
                    ],
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Just repoRoot
                }

runNativeSuite :: FilePath -> [(String, String)] -> NativeSuitePlan -> IO ExitCode
runNativeSuite repoRoot environment suitePlan = do
    case buildPhaseOneDag suitePlan of
        Left err -> failWith err
        Right dag -> do
            result <-
                runEffectDAG
                    InterpreterContext{interpreterRepoRoot = repoRoot}
                    dag
            case result of
                Failure err -> failWith err
                Success () ->
                    runNativeWorkflow repoRoot environment suitePlan

runNativeWorkflow :: FilePath -> [(String, String)] -> NativeSuitePlan -> IO ExitCode
runNativeWorkflow repoRoot environment suitePlan =
    runSequentially
        ( runbookActions repoRoot environment suitePlan
            ++ supportedRuntimeBootstrapActions repoRoot environment suitePlan
            ++ [emitLineAction phaseTwoMessage, runNativeValidations repoRoot environment suitePlan]
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
    case nativeRequiresIntegrationRunbook suitePlan of
        False -> []
        True ->
            [ emitLineAction phaseOnePointFiveMessage,
              runNativeCliCommandForExitCode repoRoot environment ["rke2", "install"]
            ]

supportedRuntimeBootstrapActions :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
supportedRuntimeBootstrapActions repoRoot environment suitePlan =
    case nativeRequiresSupportedRuntimeBootstrap suitePlan of
        False -> []
        True ->
            [ emitLineAction phaseOnePointSixMessage,
              runNativeCliCommandForExitCode repoRoot environment ["pulumi", "refresh"],
              runNativeCliCommandForExitCode repoRoot environment ["pulumi", "up", "--yes"],
              runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "vscode", "--yes"],
              runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "gateway", "--yes"],
              runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "gateway"],
              runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "vscode"],
              runAssertNativeCommandOutputContains
                repoRoot
                environment
                ["host", "public-edge"]
                publicEdgeReadyClassification
            ]

supportedRuntimePostflightActions :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
supportedRuntimePostflightActions repoRoot environment suitePlan =
    case nativeRequiresSupportedRuntimePostflight suitePlan of
        False -> []
        True ->
            [ emitLineAction postTestRestoreMessage,
              runNativeCliCommandForExitCode repoRoot environment ["rke2", "install"],
              runNativeCliCommandForExitCode repoRoot environment ["pulumi", "refresh"],
              runNativeCliCommandForExitCode repoRoot environment ["pulumi", "up", "--yes"],
              runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "vscode", "--yes"],
              runNativeCliCommandForExitCode repoRoot environment ["charts", "delete", "gateway", "--yes"],
              runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "gateway"],
              runNativeCliCommandForExitCode repoRoot environment ["charts", "deploy", "vscode"],
              runAssertNativeCommandOutputContains
                repoRoot
                environment
                ["host", "public-edge"]
                publicEdgeReadyClassification,
              runNativeCliCommandForExitCode repoRoot environment ["pulumi", "eks-destroy", "--yes"],
              runNativeCliCommandForExitCode repoRoot environment ["pulumi", "test-destroy", "--yes"]
            ]

runNativeValidations :: FilePath -> [(String, String)] -> NativeSuitePlan -> IO ExitCode
runNativeValidations repoRoot environment suitePlan =
    case nativeValidations suitePlan of
        [] -> pure ExitSuccess
        validations -> foldM runValidation ExitSuccess validations

  where
    runValidation :: ExitCode -> NativeValidation -> IO ExitCode
    runValidation failure@(ExitFailure _) _ = pure failure
    runValidation ExitSuccess validation = runNativeValidation repoRoot environment validation

buildPhaseOneDag :: NativeSuitePlan -> Either String EffectDAG
buildPhaseOneDag suitePlan = do
    registryWithPhaseOne <- addPhaseOneHeader suitePlan
    fromRootIds (phaseOneDependencies suitePlan) registryWithPhaseOne

addPhaseOneHeader :: NativeSuitePlan -> Either String (Map.Map String EffectNode)
addPhaseOneHeader suitePlan
    | null (nativeIntegrationGatePrerequisites suitePlan) =
        Right (Map.insert phaseOneHeaderId (phaseOneHeaderNode suitePlan) prerequisiteRegistry)
    | otherwise = do
        let baseRegistry =
                Map.insert phaseOneHeaderId (phaseOneHeaderNode suitePlan) prerequisiteRegistry
        closureIds <-
            transitiveClosureIds
                (nativeIntegrationGatePrerequisites suitePlan)
                baseRegistry
        pure (foldr addHeaderDependency baseRegistry closureIds)
  where
    addHeaderDependency :: String -> Map.Map String EffectNode -> Map.Map String EffectNode
    addHeaderDependency effectId =
        Map.adjust
            (\node ->
                node
                    { effectNodePrerequisites =
                        orderedPrepend phaseOneHeaderId (effectNodePrerequisites node)
                    }
            )
            effectId

phaseOneHeaderNode :: NativeSuitePlan -> EffectNode
phaseOneHeaderNode suitePlan =
    EffectNode
        { effectNodeId = phaseOneHeaderId,
          effectNodeDescription = "Phase 1 header",
          effectNodePrerequisites = [],
          effectNodeEffect = EmitLine gateMessage
        }
  where
    gateMessage =
        case null (nativeIntegrationGatePrerequisites suitePlan) of
            True -> phaseOneNoPrereqMessage
            False -> phaseOneGateMessage

phaseOneDependencies :: NativeSuitePlan -> [String]
phaseOneDependencies suitePlan =
    case nativeIntegrationGatePrerequisites suitePlan of
        [] -> [phaseOneHeaderId]
        prerequisites -> prerequisites

runCommandForExitCode :: CommandSpec -> IO ExitCode
runCommandForExitCode spec = do
    commandResult <- runStreamingCommand spec
    case commandResult of
        Failure err -> failWith err
        Success exitCode -> pure exitCode

runAssertCommandOutputContains :: CommandSpec -> String -> IO ExitCode
runAssertCommandOutputContains spec expectedText = do
    outputResult <- captureCommand spec
    case outputResult of
        Failure err -> failWith ("failed to start `" ++ unwords (commandPath spec : commandArguments spec) ++ "`: " ++ err)
        Success output -> do
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
                ExitSuccess ->
                    if expectedText `isInfixOf` processStdout output
                        then pure ExitSuccess
                        else
                            failWith
                                ( "`"
                                    ++ unwords (commandPath spec : commandArguments spec)
                                    ++ "` did not report required output `"
                                    ++ expectedText
                                    ++ "`."
                                )

runAssertNativeCommandOutputContains :: FilePath -> [(String, String)] -> [String] -> String -> IO ExitCode
runAssertNativeCommandOutputContains repoRoot environment cliArgs expectedText = do
    spec <- nativeCliCommandSpec repoRoot environment cliArgs
    runAssertCommandOutputContains spec expectedText

runNativeCliCommandForExitCode :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runNativeCliCommandForExitCode repoRoot environment cliArgs = do
    spec <- nativeCliCommandSpec repoRoot environment cliArgs
    runCommandForExitCode spec

nativeCliCommandSpec :: FilePath -> [(String, String)] -> [String] -> IO CommandSpec
nativeCliCommandSpec repoRoot environment cliArgs = do
    executablePath <- getExecutablePath
    pure
        CommandSpec
            { commandPath = executablePath,
              commandArguments = cliArgs,
              commandEnvironment = Just environment,
              commandWorkingDirectory = Just repoRoot
            }

orderedPrepend :: String -> [String] -> [String]
orderedPrepend value existing = value : filter (/= value) existing

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
