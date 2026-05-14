module Prodbox.Subprocess
  ( BackgroundProcess (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , capture
  , captureSubprocessResult
  , commandDisplay
  , renderSubprocess
  , runSubprocessStreaming
  , runStreaming
  , signalBackgroundProcess
  , startBackgroundProcess
  , stopBackgroundProcess
  , terminateBackgroundProcess
  , waitBackgroundProcess
  )
where

import Control.Exception
  ( IOException
  , displayException
  , try
  )
import Data.ByteString.Lazy.Char8 qualified as BL8
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
import System.Posix.Signals
  ( Signal
  , sigTERM
  , signalProcess
  )
import System.Process.Typed qualified as Typed

data Subprocess = Subprocess
  { subprocessPath
      :: FilePath
  , subprocessArguments
      :: [String]
  , subprocessEnvironment
      :: Maybe [(String, String)]
  , subprocessWorkingDirectory
      :: Maybe FilePath
  }
  deriving (Eq, Show)

data ProcessOutput = ProcessOutput
  { processExitCode :: ExitCode
  , processStdout :: String
  , processStderr :: String
  }
  deriving (Eq, Show)

data BackgroundProcess = BackgroundProcess
  { backgroundStdoutHandle :: Maybe Handle
  , backgroundStderrHandle :: Maybe Handle
  , backgroundProcess :: Typed.Process () Handle Handle
  }

renderSubprocess :: Subprocess -> Text
renderSubprocess spec =
  Text.unwords
    (map Text.pack (subprocessPath spec : subprocessArguments spec))

commandDisplay :: Subprocess -> String
commandDisplay = Text.unpack . renderSubprocess

runStreaming :: Subprocess -> IO (Either AppError ExitCode)
runStreaming spec = do
  processResult <-
    try (Typed.runProcess (typedProcessConfig True spec))
      :: IO (Either IOException ExitCode)
  case processResult of
    Left err ->
      pure
        ( Left
            ( fatalError
                (Text.pack (displayException err))
            )
        )
    Right exitCode -> pure (Right exitCode)

capture :: Subprocess -> IO (Either AppError ProcessOutput)
capture spec = do
  outputResult <-
    try (Typed.readProcess (typedProcessConfig False spec))
      :: IO (Either IOException (ExitCode, BL8.ByteString, BL8.ByteString))
  pure $
    case outputResult of
      Left err ->
        Left
          ( fatalError
              (Text.pack (displayException err))
          )
      Right (exitCode, stdoutBytes, stderrBytes) ->
        Right
          ProcessOutput
            { processExitCode = exitCode
            , processStdout = BL8.unpack stdoutBytes
            , processStderr = BL8.unpack stderrBytes
            }

captureSubprocessResult :: Subprocess -> IO (Result ProcessOutput)
captureSubprocessResult spec = eitherToResult <$> capture spec

startBackgroundProcess :: Subprocess -> IO (Either AppError BackgroundProcess)
startBackgroundProcess spec = do
  processResult <-
    try
      ( Typed.startProcess
          ( Typed.setStdout
              Typed.createPipe
              (Typed.setStderr Typed.createPipe (typedProcessConfig False spec))
          )
      )
      :: IO (Either IOException (Typed.Process () Handle Handle))
  pure $
    case processResult of
      Left err ->
        Left
          ( fatalError
              (Text.pack (displayException err))
          )
      Right process ->
        Right
          BackgroundProcess
            { backgroundStdoutHandle = Just (Typed.getStdout process)
            , backgroundStderrHandle = Just (Typed.getStderr process)
            , backgroundProcess = process
            }

stopBackgroundProcess :: BackgroundProcess -> IO ()
stopBackgroundProcess process = do
  _ <- try (Typed.stopProcess (backgroundProcess process)) :: IO (Either IOException ())
  maybe (pure ()) closeHandle (backgroundStdoutHandle process)
  maybe (pure ()) closeHandle (backgroundStderrHandle process)
 where
  closeHandle handle = do
    _ <- try (hClose handle) :: IO (Either IOException ())
    pure ()

terminateBackgroundProcess :: BackgroundProcess -> IO ()
terminateBackgroundProcess process =
  signalBackgroundProcess sigTERM process

signalBackgroundProcess :: Signal -> BackgroundProcess -> IO ()
signalBackgroundProcess signal process = do
  maybePid <- Typed.getPid (backgroundProcess process)
  case maybePid of
    Nothing -> pure ()
    Just pid -> do
      _ <- try (signalProcess signal pid) :: IO (Either IOException ())
      pure ()

waitBackgroundProcess :: BackgroundProcess -> IO (Either AppError ExitCode)
waitBackgroundProcess process = do
  waitResult <-
    try (Typed.waitExitCode (backgroundProcess process)) :: IO (Either IOException ExitCode)
  pure $
    case waitResult of
      Left err ->
        Left
          ( fatalError
              (Text.pack (displayException err))
          )
      Right exitCode -> Right exitCode

runSubprocessStreaming :: Subprocess -> IO (Result ExitCode)
runSubprocessStreaming spec = eitherToResult <$> runStreaming spec

eitherToResult :: Either AppError value -> Result value
eitherToResult eitherValue =
  case eitherValue of
    Left err -> Failure (Text.unpack (errorMsg err))
    Right success -> Success success

typedProcessConfig :: Bool -> Subprocess -> Typed.ProcessConfig () () ()
typedProcessConfig delegateCtlc spec =
  applyWorkingDirectory $
    applyEnvironment $
      Typed.setDelegateCtlc delegateCtlc $
        Typed.proc (subprocessPath spec) (subprocessArguments spec)
 where
  applyWorkingDirectory config =
    case subprocessWorkingDirectory spec of
      Nothing -> config
      Just workingDirectory -> Typed.setWorkingDir workingDirectory config

  applyEnvironment config =
    case subprocessEnvironment spec of
      Nothing -> config
      Just environment -> Typed.setEnv environment config
