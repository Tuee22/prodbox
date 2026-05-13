{-# LANGUAGE PatternSynonyms #-}

module Prodbox.Subprocess
  ( BackgroundProcess (..)
  , CommandSpec (..)
  , ProcessOutput (..)
  , Subprocess
  , pattern Subprocess
  , capture
  , captureCommand
  , commandDisplay
  , renderSubprocess
  , runStreaming
  , runStreamingCommand
  , startBackgroundProcess
  , stopBackgroundProcess
  , terminateBackgroundProcess
  , subprocessArguments
  , subprocessEnvironment
  , subprocessPath
  , subprocessWorkingDirectory
  , waitBackgroundProcess
  )
where

import Control.Exception
  ( IOException
  , displayException
  , try
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Error
  ( AppError
  , errorMsg
  , fatalError
  )
import Prodbox.Result
  ( Result (..)
  )
import System.Exit
  ( ExitCode
  )
import System.IO
  ( Handle
  , hClose
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
  , StdStream (CreatePipe, Inherit)
  , createProcess
  , proc
  , readCreateProcessWithExitCode
  , terminateProcess
  , waitForProcess
  )

data CommandSpec = CommandSpec
  { commandPath :: FilePath
  , commandArguments :: [String]
  , commandEnvironment :: Maybe [(String, String)]
  , commandWorkingDirectory :: Maybe FilePath
  }
  deriving (Eq, Show)

type Subprocess = CommandSpec

pattern Subprocess
  :: FilePath
  -> [String]
  -> Maybe [(String, String)]
  -> Maybe FilePath
  -> CommandSpec
pattern Subprocess
  { subprocessPath
  , subprocessArguments
  , subprocessEnvironment
  , subprocessWorkingDirectory
  } <-
  CommandSpec
    { commandPath = subprocessPath
    , commandArguments = subprocessArguments
    , commandEnvironment = subprocessEnvironment
    , commandWorkingDirectory = subprocessWorkingDirectory
    }
  where
    Subprocess subprocessPath subprocessArguments subprocessEnvironment subprocessWorkingDirectory =
      CommandSpec
        { commandPath = subprocessPath
        , commandArguments = subprocessArguments
        , commandEnvironment = subprocessEnvironment
        , commandWorkingDirectory = subprocessWorkingDirectory
        }

{-# COMPLETE Subprocess #-}

data ProcessOutput = ProcessOutput
  { processExitCode :: ExitCode
  , processStdout :: String
  , processStderr :: String
  }
  deriving (Eq, Show)

data BackgroundProcess = BackgroundProcess
  { backgroundStdoutHandle :: Maybe Handle
  , backgroundStderrHandle :: Maybe Handle
  , backgroundProcessHandle :: ProcessHandle
  }

renderSubprocess :: Subprocess -> Text
renderSubprocess spec =
  Text.unwords
    (map Text.pack (subprocessPath spec : subprocessArguments spec))

commandDisplay :: CommandSpec -> String
commandDisplay = Text.unpack . renderSubprocess

runStreaming :: Subprocess -> IO (Either AppError ExitCode)
runStreaming spec = do
  processResult <-
    try
      ( createProcess
          (proc (subprocessPath spec) (subprocessArguments spec))
            { cwd = subprocessWorkingDirectory spec
            , env = subprocessEnvironment spec
            , std_in = Inherit
            , std_out = Inherit
            , std_err = Inherit
            , delegate_ctlc = True
            }
      )
      :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case processResult of
    Left err ->
      pure
        ( Left
            ( fatalError
                (Text.pack (displayException err))
            )
        )
    Right (_, _, _, handle) -> Right <$> waitForProcess handle

runStreamingCommand :: CommandSpec -> IO (Result ExitCode)
runStreamingCommand spec = eitherToResult <$> runStreaming spec

capture :: Subprocess -> IO (Either AppError ProcessOutput)
capture spec = do
  outputResult <-
    try
      ( readCreateProcessWithExitCode
          (proc (subprocessPath spec) (subprocessArguments spec))
            { cwd = subprocessWorkingDirectory spec
            , env = subprocessEnvironment spec
            }
          ""
      )
      :: IO (Either IOException (ExitCode, String, String))
  pure $
    case outputResult of
      Left err ->
        Left
          ( fatalError
              (Text.pack (displayException err))
          )
      Right (exitCode, stdoutText, stderrText) ->
        Right
          ProcessOutput
            { processExitCode = exitCode
            , processStdout = stdoutText
            , processStderr = stderrText
            }

captureCommand :: CommandSpec -> IO (Result ProcessOutput)
captureCommand spec = eitherToResult <$> capture spec

startBackgroundProcess :: Subprocess -> IO (Either AppError BackgroundProcess)
startBackgroundProcess spec = do
  processResult <-
    try
      ( createProcess
          (proc (subprocessPath spec) (subprocessArguments spec))
            { cwd = subprocessWorkingDirectory spec
            , env = subprocessEnvironment spec
            , std_in = Inherit
            , std_out = CreatePipe
            , std_err = CreatePipe
            , delegate_ctlc = False
            }
      )
      :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  pure $
    case processResult of
      Left err ->
        Left
          ( fatalError
              (Text.pack (displayException err))
          )
      Right (_, stdoutHandle, stderrHandle, processHandle) ->
        Right
          BackgroundProcess
            { backgroundStdoutHandle = stdoutHandle
            , backgroundStderrHandle = stderrHandle
            , backgroundProcessHandle = processHandle
            }

stopBackgroundProcess :: BackgroundProcess -> IO ()
stopBackgroundProcess process = do
  terminateBackgroundProcess process
  _ <- try (waitForProcess (backgroundProcessHandle process)) :: IO (Either IOException ExitCode)
  maybe (pure ()) closeHandle (backgroundStdoutHandle process)
  maybe (pure ()) closeHandle (backgroundStderrHandle process)
 where
  closeHandle handle = do
    _ <- try (hClose handle) :: IO (Either IOException ())
    pure ()

terminateBackgroundProcess :: BackgroundProcess -> IO ()
terminateBackgroundProcess process = do
  _ <- try (terminateProcess (backgroundProcessHandle process)) :: IO (Either IOException ())
  pure ()

waitBackgroundProcess :: BackgroundProcess -> IO (Either AppError ExitCode)
waitBackgroundProcess process = do
  waitResult <-
    try (waitForProcess (backgroundProcessHandle process)) :: IO (Either IOException ExitCode)
  pure $
    case waitResult of
      Left err ->
        Left
          ( fatalError
              (Text.pack (displayException err))
          )
      Right exitCode -> Right exitCode

eitherToResult :: Either AppError value -> Result value
eitherToResult eitherValue =
  case eitherValue of
    Left err -> Failure (Text.unpack (renderSubprocessError err))
    Right success -> Success success

renderSubprocessError :: AppError -> Text
renderSubprocessError = errorMsg
