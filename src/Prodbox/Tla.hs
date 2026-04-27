module Prodbox.Tla (
    runTlaCheck,
)
where

import Prodbox.Result (Result (..))
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
 )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (
    ExitCode (..),
 )
import System.FilePath (takeDirectory)

runTlaCheck :: FilePath -> IO ExitCode
runTlaCheck repoRoot = do
    let tlaDir = repoRoot ++ "/documents/engineering/tla"
        modelPath = tlaDir ++ "/gateway_orders_rule.tla"
        configPath = tlaDir ++ "/gateway_orders_rule.cfg"
        resultPath = tlaDir ++ "/tlc_last_run.txt"
        command = dockerCommand tlaDir
    modelExists <- doesFileExist modelPath
    configExists <- doesFileExist configPath
    case (modelExists, configExists) of
        (False, _) -> writeResult resultPath (renderResult [] 1 "" ("Model file not found: " ++ modelPath)) >> pure (ExitFailure 1)
        (_, False) -> writeResult resultPath (renderResult [] 1 "" ("Config file not found: " ++ configPath)) >> pure (ExitFailure 1)
        (True, True) -> do
            outputResult <-
                captureCommand
                    CommandSpec
                        { commandPath = "docker"
                        , commandArguments = drop 1 command
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Just repoRoot
                        }
            case outputResult of
                Failure err -> do
                    writeResult resultPath (renderResult command 1 "" err)
                    pure (ExitFailure 1)
                Success output -> do
                    writeResult resultPath (renderResult command (exitCodeInt (processExitCode output)) (processStdout output) (processStderr output))
                    pure (processExitCode output)

dockerCommand :: FilePath -> [String]
dockerCommand tlaDir =
    [ "docker"
    , "run"
    , "--rm"
    , "--entrypoint"
    , ""
    , "--volume"
    , tlaDir ++ ":/workspace"
    , "--workdir"
    , "/workspace"
    , "maxdiefenbach/tlaplus"
    , "java"
    , "-XX:+UseParallelGC"
    , "-cp"
    , "/opt/TLA+Toolbox/tla2tools.jar"
    , "tlc2.TLC"
    , "-workers"
    , "8"
    , "-config"
    , "gateway_orders_rule.cfg"
    , "gateway_orders_rule.tla"
    ]

renderResult :: [String] -> Int -> String -> String -> String
renderResult command returnCode stdoutText stderrText =
    unlines
        [ "command: " ++ unwords command
        , "returncode: " ++ show returnCode
        , "stdout:"
        , stdoutText
        , "stderr:"
        , stderrText
        ]

writeResult :: FilePath -> String -> IO ()
writeResult resultPath content = do
    createDirectoryIfMissing True (takeDirectory resultPath)
    writeFile resultPath content

exitCodeInt :: ExitCode -> Int
exitCodeInt ExitSuccess = 0
exitCodeInt (ExitFailure code) = code
