module Prodbox.Subprocess
  ( CommandSpec (..)
  , ProcessOutput (..)
  , captureCommand
  , commandDisplay
  , runStreamingCommand
  )
where

import Control.Exception
  ( IOException
  , displayException
  , try
  )
import Prodbox.Result
  ( Result (..)
  )
import System.Exit
  ( ExitCode
  )
import System.IO
  ( Handle
  )
import System.Process
  ( CreateProcess
      ( cwd
      , delegate_ctlc
      , env
      , std_err
      , std_in
      , std_out
      )
  , ProcessHandle
  , StdStream (Inherit)
  , createProcess
  , proc
  , readCreateProcessWithExitCode
  , waitForProcess
  )

data CommandSpec = CommandSpec
  { commandPath :: FilePath
  , commandArguments :: [String]
  , commandEnvironment :: Maybe [(String, String)]
  , commandWorkingDirectory :: Maybe FilePath
  }
  deriving (Eq, Show)

data ProcessOutput = ProcessOutput
  { processExitCode :: ExitCode
  , processStdout :: String
  , processStderr :: String
  }
  deriving (Eq, Show)

commandDisplay :: CommandSpec -> String
commandDisplay spec = unwords (commandPath spec : commandArguments spec)

runStreamingCommand :: CommandSpec -> IO (Result ExitCode)
runStreamingCommand spec = do
  processResult <-
    try
      ( createProcess
          (proc (commandPath spec) (commandArguments spec))
            { cwd = commandWorkingDirectory spec
            , env = commandEnvironment spec
            , std_in = Inherit
            , std_out = Inherit
            , std_err = Inherit
            , delegate_ctlc = True
            }
      )
      :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case processResult of
    Left err -> pure (Failure (displayException err))
    Right (_, _, _, handle) -> Success <$> waitForProcess handle

captureCommand :: CommandSpec -> IO (Result ProcessOutput)
captureCommand spec = do
  outputResult <-
    try
      ( readCreateProcessWithExitCode
          (proc (commandPath spec) (commandArguments spec))
            { cwd = commandWorkingDirectory spec
            , env = commandEnvironment spec
            }
          ""
      )
      :: IO (Either IOException (ExitCode, String, String))
  pure $
    case outputResult of
      Left err -> Failure (displayException err)
      Right (exitCode, stdoutText, stderrText) ->
        Success
          ProcessOutput
            { processExitCode = exitCode
            , processStdout = stdoutText
            , processStderr = stderrText
            }
