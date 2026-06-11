module Prodbox.App
  ( App (..)
  , Env (..)
  , askEnv
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
  ( CommandListingFormat (..)
  , CommandRequest (..)
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
import Prodbox.Error (fatalError)
import Prodbox.Native (runNativeCommand)
import Prodbox.Repo (findRepoRoot)
import Prodbox.Secret.GatewayDeriveMode (GatewayDeriveMode, resolveGatewayDeriveMode)
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
  -- The gateway-derive capability is resolved once here, at the process
  -- boundary: production reads no env var and dials the in-cluster gateway;
  -- the integration harness sets PRODBOX_TEST_GATEWAY_DERIVE_SEED_HEX in this
  -- spawned subprocess so the host computes the daemon's response locally. The
  -- resolved 'GatewayDeriveMode' is threaded explicitly to the derived-secret
  -- consumers, so no production code path re-reads the environment.
  modeResult <- resolveGatewayDeriveMode
  case modeResult of
    Left err -> failWith err
    Right mode -> do
      argv <- getArgs
      case validateCommandArgv argv of
        Left err -> failWith err
        Right () -> do
          options <- customExecParser parserPrefs parserInfo
          runCommandRequest mode (optRequest options)
 where
  parserPrefs = prefs (showHelpOnEmpty <> showHelpOnError)

runCommandRequest :: GatewayDeriveMode -> CommandRequest -> IO ()
runCommandRequest mode request =
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
        CommandsPlain -> writeOutput (renderCommandsPlain commandRegistry)
        CommandsTree -> writeOutput (renderCommandTree commandRegistry)
        CommandsJson -> writeOutput (renderCommandJson commandRegistry)
    ShowHelp commandPath ->
      case findCommandSpec commandPath of
        Nothing -> failWith ("Unknown help path: " ++ unwords commandPath)
        Just spec -> writeOutput (renderCommandHelp commandPath spec)
 where
  dispatch repoRoot command = do
    exitCode <- runNativeCommand mode repoRoot command
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
