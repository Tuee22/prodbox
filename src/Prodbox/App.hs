module Prodbox.App
  ( main
  )
where

import Data.Text qualified as Text
import Options.Applicative
  ( customExecParser
  , prefs
  , showHelpOnEmpty
  , showHelpOnError
  )
import Prodbox.CLI.Command
  ( CommandListingFormat (..)
  , CommandRequest (..)
  , GatewayCommand (..)
  , NativeCommand (..)
  , WorkloadCommand (..)
  )
import Prodbox.CLI.Docs (renderCommandHelp)
import Prodbox.CLI.Json (renderCommandJson)
import Prodbox.CLI.Output (writeError)
import Prodbox.CLI.Parser
  ( Options (..)
  , parserInfo
  , validateCommandArgv
  )
import Prodbox.CLI.Spec (CommandSpec (..), commandRegistry, findCommandSpec)
import Prodbox.CLI.Tree (renderCommandTree)
import Prodbox.Error (fatalError)
import Prodbox.Native (runNativeCommand)
import Prodbox.Repo (findRepoRoot)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)

main :: IO ()
main = do
  argv <- getArgs
  case validateCommandArgv argv of
    Left err -> failWith err
    Right () -> do
      options <- customExecParser parserPrefs parserInfo
      runCommandRequest (optRequest options)
 where
  parserPrefs = prefs (showHelpOnEmpty <> showHelpOnError)

runCommandRequest :: CommandRequest -> IO ()
runCommandRequest request =
  case request of
    RunNative command -> do
      repoRootResult <- findRepoRoot
      case repoRootResult of
        Right repoRoot -> dispatch repoRoot command
        Left err ->
          if canRunWithoutRepoRoot command
            then dispatch "." command
            else failWith err
    ShowCommands listingFormat ->
      case listingFormat of
        CommandsPlain -> putStr (renderCommandsPlain commandRegistry)
        CommandsTree -> putStr (renderCommandTree commandRegistry)
        CommandsJson -> putStr (renderCommandJson commandRegistry)
    ShowHelp commandPath ->
      case findCommandSpec commandPath of
        Nothing -> failWith ("Unknown help path: " ++ unwords commandPath)
        Just spec -> putStr (renderCommandHelp commandPath spec)
 where
  dispatch repoRoot command = do
    exitCode <- runNativeCommand repoRoot command
    exitWith exitCode

canRunWithoutRepoRoot :: NativeCommand -> Bool
canRunWithoutRepoRoot (NativeGateway (GatewayDaemonCommand _)) = True
canRunWithoutRepoRoot (NativeGateway (GatewayStatusCommand _)) = True
canRunWithoutRepoRoot (NativeWorkload (WorkloadStart _)) = True
canRunWithoutRepoRoot _ = False

failWith :: String -> IO ()
failWith message = do
  writeError (fatalError (Text.pack message))
  exitWith (ExitFailure 1)

renderCommandsPlain :: CommandSpec -> String
renderCommandsPlain = unlines . go []
 where
  go prefix spec =
    case children spec of
      [] ->
        [ unwords ("prodbox" : prefix ++ [name spec])
            ++ " - "
            ++ summary spec
        ]
      nested ->
        concatMap
          ( \child ->
              let nextPrefix =
                    if name spec == "prodbox"
                      then prefix
                      else prefix ++ [name spec]
               in go nextPrefix child
          )
          nested
