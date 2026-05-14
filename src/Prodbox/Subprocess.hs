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
  , signalBackgroundProcess
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
  , backgroundProcess :: Typed.Process () Handle Handle
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

runStreamingCommand :: CommandSpec -> IO (Result ExitCode)
runStreamingCommand spec = eitherToResult <$> runStreaming spec

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

captureCommand :: CommandSpec -> IO (Result ProcessOutput)
captureCommand spec = eitherToResult <$> capture spec

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

eitherToResult :: Either AppError value -> Result value
eitherToResult eitherValue =
  case eitherValue of
    Left err -> Failure (Text.unpack (renderSubprocessError err))
    Right success -> Success success

renderSubprocessError :: AppError -> Text
renderSubprocessError = errorMsg

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
