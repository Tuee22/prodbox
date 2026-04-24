module Main (main) where

import Options.Applicative (
    customExecParser,
    prefs,
    showHelpOnEmpty,
    showHelpOnError,
 )
import Prodbox.CLI.Command (
    CommandRequest (..),
    GatewayCommand (..),
    NativeCommand (..),
 )
import Prodbox.CLI.Parser (
    Options (..),
    parserInfo,
 )
import Prodbox.Native (runNativeCommand)
import Prodbox.Repo (findRepoRoot)
import System.Exit (exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    options <- customExecParser parserPrefs parserInfo
    let RunNative command = optRequest options
    repoRootResult <- findRepoRoot
    case repoRootResult of
        Right repoRoot -> dispatch repoRoot command
        Left err ->
            if canRunWithoutRepoRoot command
                then dispatch "." command
                else failWith err
  where
    parserPrefs = prefs (showHelpOnEmpty <> showHelpOnError)

    dispatch repoRoot command = do
        exitCode <- runNativeCommand repoRoot command
        exitWith exitCode

canRunWithoutRepoRoot :: NativeCommand -> Bool
canRunWithoutRepoRoot (NativeGateway (GatewayStart _)) = True
canRunWithoutRepoRoot (NativeGateway (GatewayStatus _)) = True
canRunWithoutRepoRoot _ = False

failWith :: String -> IO ()
failWith message = do
    hPutStrLn stderr message
    exitFailure
