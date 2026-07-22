module Prodbox.App
  ( App (..)
  , Env (..)
  , askEnv
  , canRunWithoutRepoRoot
  , liftAppIO
  , main
  , runApp
  )
where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader
  ( ReaderT (..)
  , ask
  )
import Data.Text qualified as Text
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Options.Applicative
  ( customExecParser
  , prefs
  , showHelpOnEmpty
  , showHelpOnError
  )
import Prodbox.CLI.Command
  ( BootstrapBrokerCommand (..)
  , CommandListingFormat (..)
  , CommandRequest (..)
  , ConfigCommand (..)
  , GatewayCommand (..)
  , NativeCommand (..)
  , WorkloadCommand (..)
  )
import Prodbox.CLI.Docs (renderCommandHelp)
import Prodbox.CLI.Json (renderCommandJson)
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.CLI.Parser
  ( Options (..)
  , parserInfo
  , validateCommandArgv
  )
import Prodbox.CLI.Spec (CommandSpec (..), commandRegistry, findCommandSpec)
import Prodbox.CLI.Tree (renderCommandTree)
import Prodbox.Config.SchemaDhall (materializeSchemaFilesIfStale)
import Prodbox.Error (fatalError)
import Prodbox.Native (runNativeCommand)
import Prodbox.Repo (findRepoRoot)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)

data Env = Env
  { envRepoRoot :: FilePath
  }
  deriving (Eq, Show)

newtype App a = App {unApp :: ReaderT Env IO a}

instance Functor App where
  fmap f (App action) = App (fmap f action)

instance Applicative App where
  pure = App . pure
  App function <*> App value = App (function <*> value)

instance Monad App where
  App action >>= next = App (action >>= unApp . next)

runApp :: Env -> App a -> IO a
runApp env (App action) = runReaderT action env

askEnv :: App Env
askEnv = App ask

liftAppIO :: IO a -> App a
liftAppIO = App . liftIO

main :: IO ()
main = do
  -- Force UTF-8 for stdin/stdout/stderr and file handles so the Dhall
  -- decoder, log output, and any file reads work in container Pods that
  -- ship with the C/POSIX default locale (no LANG set). Without this,
  -- `Dhall.inputFile` fails on UTF-8 byte sequences such as `§` (0xC2 0xA7)
  -- that appear in chart-rendered config comments per
  -- documents/engineering/config_doctrine.md §6.
  setLocaleEncoding utf8
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
        Right repoRoot -> do
          -- Sprint 7.17/7.18: ALL Dhall is generated or locally authored and
          -- NONE is version-controlled — including the two `*-types.dhall`
          -- schemas. Materialize them from the Haskell source of truth before
          -- dispatch so any command that decodes a config importing
          -- `./prodbox-config-types.dhall` (e.g. `cluster reconcile` via
          -- `validateAndLoadBootstrapSettings`) resolves the schema even on a
          -- fresh checkout that never committed it. Idempotent + cheap (writes
          -- only when absent/stale).
          materializeSchemaFilesIfStale repoRoot
          dispatch repoRoot command
        Left err ->
          if canRunWithoutRepoRoot command
            then dispatch "." command
            else failWith err
    ShowCommands listingFormat ->
      case listingFormat of
        CommandsPlain -> writeOutput (renderCommandsPlain commandRegistry)
        CommandsTree -> writeOutput (renderCommandTree commandRegistry)
        CommandsJson -> writeOutput (renderCommandJson commandRegistry)
    ShowHelp commandPath ->
      case findCommandSpec commandPath of
        Nothing -> failWith ("Unknown help path: " ++ unwords commandPath)
        Just spec -> writeOutput (renderCommandHelp commandPath spec)
 where
  dispatch repoRoot command = do
    exitCode <- runNativeCommand repoRoot command
    exitWith exitCode

canRunWithoutRepoRoot :: NativeCommand -> Bool
canRunWithoutRepoRoot (NativeBootstrapBroker (BootstrapBrokerStart _)) = True
canRunWithoutRepoRoot (NativeGateway (GatewayDaemonCommand _)) = True
canRunWithoutRepoRoot (NativeGateway (GatewayStatusCommand _)) = True
canRunWithoutRepoRoot (NativeWorkload (WorkloadStart _)) = True
-- Sprint 1.49: `config generate` is binary-owned — it writes the
-- binary-sibling `prodbox.dhall` (`resolveTier0ConfigPath`, which ignores the
-- repo root), so it must run in a non-repo context such as the in-container
-- image build (`RUN prodbox config generate`).
canRunWithoutRepoRoot (NativeConfig ConfigGenerate) = True
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
