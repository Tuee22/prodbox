module Main (main) where

import Options.Applicative
    ( customExecParser,
      prefs,
      showHelpOnEmpty,
      showHelpOnError,
    )
import Prodbox.CLI.Command (CommandRequest (..))
import Prodbox.CLI.Parser
    ( Options (..),
      parserInfo,
    )
import Prodbox.Native (runNativeCommand)
import Prodbox.Repo (findRepoRoot)
import System.Exit (exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    options <- customExecParser parserPrefs parserInfo
    repoRootResult <- findRepoRoot
    case repoRootResult of
        Left err -> failWith err
        Right repoRoot ->
            case optRequest options of
                DelegateToPython _ -> failWith "Python backend delegation is no longer supported"
                RunNative command -> do
                    exitCode <- runNativeCommand repoRoot command
                    exitWith exitCode
  where
    parserPrefs = prefs (showHelpOnEmpty <> showHelpOnError)

failWith :: String -> IO ()
failWith message = do
    hPutStrLn stderr message
    exitFailure
