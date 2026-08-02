{-# LANGUAGE TupleSections #-}

module Prodbox.Subprocess
  ( BackgroundProcess (..)
  , BoundedSubprocessLimits (..)
  , FramedSubprocessExchangeError (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , capture
  , captureSubprocessBounded
  , captureSubprocessFramedExchangeBounded
  , captureSubprocessWithInputBounded
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

import Control.Concurrent.Async (Async, wait, waitEither, withAsync)
import Control.Exception
  ( IOException
  , displayException
  , finally
  , try
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as ByteStringBuilder
import Data.ByteString.Lazy qualified as LazyByteString
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
  , hFlush
  )
import System.Posix.Signals
  ( Signal
  , sigTERM
  , signalProcess
  )
import System.Process.Typed qualified as Typed
import System.Timeout (timeout)

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

-- | Hard resource limits for subprocesses whose output or lifetime may be
-- attacker-controlled. All four bounds must be positive. The input bound is
-- checked before process creation; stdout/stderr are drained concurrently and
-- the process is stopped as soon as either stream crosses its ceiling or the
-- wall-clock timeout elapses.
data BoundedSubprocessLimits = BoundedSubprocessLimits
  { boundedSubprocessMaximumInputBytes :: !Int
  , boundedSubprocessMaximumStdoutBytes :: !Int
  , boundedSubprocessMaximumStderrBytes :: !Int
  , boundedSubprocessTimeoutMicros :: !Int
  }
  deriving (Eq, Show)

-- | Failure from a bounded two-stage exchange.  A decision refusal carries
-- the completed child output so the domain interpreter can require its exact
-- cleanup acknowledgement before preserving the typed refusal.
data FramedSubprocessExchangeError errorValue
  = FramedSubprocessExchangeTransportError !AppError
  | FramedSubprocessExchangeDecisionError !errorValue !ProcessOutput

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

-- | Run with closed stdin and physically bounded output/lifetime.
captureSubprocessBounded
  :: BoundedSubprocessLimits -> Subprocess -> IO (Either AppError ProcessOutput)
captureSubprocessBounded limits =
  captureSubprocessWithInputBounded limits ByteString.empty

-- | Run with exact binary stdin and physically bounded input, output, and
-- lifetime. The input bytes are never included in an error or rendering.
captureSubprocessWithInputBounded
  :: BoundedSubprocessLimits
  -> ByteString
  -> Subprocess
  -> IO (Either AppError ProcessOutput)
captureSubprocessWithInputBounded limits input spec
  | invalidLimits = pure (Left (boundedSubprocessError "bounded subprocess limits must be positive"))
  | ByteString.length input > boundedSubprocessMaximumInputBytes limits =
      pure (Left (boundedSubprocessError "bounded subprocess input exceeds its configured ceiling"))
  | otherwise = do
      started <-
        try
          ( Typed.startProcess
              ( Typed.setStdin
                  (Typed.byteStringInput (LazyByteString.fromStrict input))
                  ( Typed.setStdout
                      Typed.createPipe
                      (Typed.setStderr Typed.createPipe (typedProcessConfig False spec))
                  )
              )
          )
          :: IO (Either IOException (Typed.Process () Handle Handle))
      case started of
        Left err -> pure (Left (subprocessIOException err))
        Right process -> do
          result <-
            withAsync
              (readBoundedHandle (boundedSubprocessMaximumStdoutBytes limits) (Typed.getStdout process))
              $ \stdoutReader ->
                withAsync
                  (readBoundedHandle (boundedSubprocessMaximumStderrBytes limits) (Typed.getStderr process))
                  $ \stderrReader ->
                    timeout
                      (boundedSubprocessTimeoutMicros limits)
                      (collectBoundedProcess process stdoutReader stderrReader)
          _ <- try (Typed.stopProcess process) :: IO (Either IOException ())
          pure $ case result of
            Nothing -> Left (boundedSubprocessError "bounded subprocess exceeded its wall-clock timeout")
            Just bounded -> bounded
 where
  invalidLimits =
    boundedSubprocessMaximumInputBytes limits <= 0
      || boundedSubprocessMaximumStdoutBytes limits <= 0
      || boundedSubprocessMaximumStderrBytes limits <= 0
      || boundedSubprocessTimeoutMicros limits <= 0

-- | Run a length-delimited two-stage stdin/stdout exchange.  The child first
-- receives the framed initial payload, emits one framed provisional value,
-- and remains blocked while the caller makes a durable decision.  A positive
-- decision supplies the framed follow-up bytes; a refusal closes stdin.  In
-- both cases the child is allowed to finish within the same physical output
-- and wall-clock ceilings, so a domain-specific cleanup acknowledgement can
-- be checked before the decision is returned.
captureSubprocessFramedExchangeBounded
  :: BoundedSubprocessLimits
  -> ByteString
  -> (ByteString -> IO (Either errorValue (ByteString, value)))
  -> Subprocess
  -> IO
       ( Either
           (FramedSubprocessExchangeError errorValue)
           (value, ProcessOutput)
       )
captureSubprocessFramedExchangeBounded limits initialPayload decide spec
  | invalidLimits = transportOnly "bounded subprocess limits must be positive"
  | framedLength initialPayload > boundedSubprocessMaximumInputBytes limits =
      transportOnly "bounded subprocess input exceeds its configured ceiling"
  | otherwise = do
      started <-
        try
          ( Typed.startProcess
              ( Typed.setStdin
                  Typed.createPipe
                  ( Typed.setStdout
                      Typed.createPipe
                      (Typed.setStderr Typed.createPipe (typedProcessConfig False spec))
                  )
              )
          )
          :: IO (Either IOException (Typed.Process Handle Handle Handle))
      case started of
        Left err ->
          pure (Left (FramedSubprocessExchangeTransportError (subprocessIOException err)))
        Right process -> do
          result <-
            ( withAsync
                (readBoundedHandle (boundedSubprocessMaximumStderrBytes limits) (Typed.getStderr process))
                ( \stderrReader ->
                    timeout
                      (boundedSubprocessTimeoutMicros limits)
                      (exchange process stderrReader)
                )
            )
              `finally` stopProcessQuietly process
          pure $ case result of
            Nothing ->
              Left
                ( FramedSubprocessExchangeTransportError
                    (boundedSubprocessError "bounded subprocess exceeded its wall-clock timeout")
                )
            Just exchangeResult -> exchangeResult
 where
  invalidLimits =
    boundedSubprocessMaximumInputBytes limits <= 0
      || boundedSubprocessMaximumStdoutBytes limits <= 0
      || boundedSubprocessMaximumStderrBytes limits <= 0
      || boundedSubprocessTimeoutMicros limits <= 0

  transportOnly detail =
    pure
      ( Left
          (FramedSubprocessExchangeTransportError (boundedSubprocessError detail))
      )

  exchange process stderrReader = do
    sent <- writeFramedHandle (Typed.getStdin process) initialPayload
    case sent of
      Left err -> pure (Left (FramedSubprocessExchangeTransportError err))
      Right () -> do
        provisional <-
          readFramedHandle
            (boundedSubprocessMaximumStdoutBytes limits)
            (Typed.getStdout process)
        case provisional of
          Left err -> pure (Left (FramedSubprocessExchangeTransportError err))
          Right (provisionalBytes, consumedBytes) -> do
            decision <- decide provisionalBytes
            continueAfterDecision
              process
              stderrReader
              consumedBytes
              decision

  continueAfterDecision process stderrReader consumedBytes decision = do
    releaseResult <- case decision of
      Left _ -> closeHandleQuietly (Typed.getStdin process) >> pure (Right ())
      Right (followup, _)
        | framedLength initialPayload + framedLength followup
            > boundedSubprocessMaximumInputBytes limits ->
            closeHandleQuietly (Typed.getStdin process)
              >> pure
                ( Left
                    (boundedSubprocessError "bounded subprocess input exceeds its configured ceiling")
                )
        | otherwise -> do
            written <- writeFramedHandle (Typed.getStdin process) followup
            closeHandleQuietly (Typed.getStdin process)
            pure written
    case releaseResult of
      Left err -> pure (Left (FramedSubprocessExchangeTransportError err))
      Right () -> do
        completed <-
          collectFramedExchangeProcess
            process
            stderrReader
            (boundedSubprocessMaximumStdoutBytes limits - consumedBytes)
        pure $ case completed of
          Left err -> Left (FramedSubprocessExchangeTransportError err)
          Right output -> case decision of
            Left err -> Left (FramedSubprocessExchangeDecisionError err output)
            Right (_, value) -> Right (value, output)

framedLength :: ByteString -> Int
framedLength bytes = 4 + ByteString.length bytes

writeFramedHandle :: Handle -> ByteString -> IO (Either AppError ())
writeFramedHandle handle payload = do
  attempted <-
    try
      ( do
          ByteString.hPut handle (frameLengthPrefix (ByteString.length payload))
          ByteString.hPut handle payload
          hFlush handle
      )
      :: IO (Either IOException ())
  pure (either (Left . subprocessIOException) Right attempted)

readFramedHandle
  :: Int -> Handle -> IO (Either AppError (ByteString, Int))
readFramedHandle maximumBytes handle = do
  prefixResult <- readExactHandle 4 handle
  case prefixResult of
    Left err -> pure (Left err)
    Right prefix -> do
      let declaredLength = decodeFrameLengthPrefix prefix
          consumed = 4 + declaredLength
      if declaredLength > maximumBytes - 4
        then
          pure
            ( Left
                (boundedSubprocessError "bounded subprocess framed stdout exceeds its configured ceiling")
            )
        else do
          payloadResult <- readExactHandle declaredLength handle
          pure (fmap (,consumed) payloadResult)

readExactHandle :: Int -> Handle -> IO (Either AppError ByteString)
readExactHandle expected handle = go expected []
 where
  go remaining chunks
    | remaining == 0 = pure (Right (ByteString.concat (reverse chunks)))
    | otherwise = do
        attempted <-
          try (ByteString.hGetSome handle (min 4096 remaining))
            :: IO (Either IOException ByteString)
        case attempted of
          Left err -> pure (Left (subprocessIOException err))
          Right chunk
            | ByteString.null chunk ->
                pure (Left (boundedSubprocessError "bounded subprocess framed stream ended early"))
            | otherwise -> go (remaining - ByteString.length chunk) (chunk : chunks)

frameLengthPrefix :: Int -> ByteString
frameLengthPrefix lengthValue =
  LazyByteString.toStrict
    (ByteStringBuilder.toLazyByteString (ByteStringBuilder.word32BE (fromIntegral lengthValue)))

decodeFrameLengthPrefix :: ByteString -> Int
decodeFrameLengthPrefix =
  ByteString.foldl' (\accumulator byte -> accumulator * 256 + fromIntegral byte) 0

collectFramedExchangeProcess
  :: Typed.Process Handle Handle Handle
  -> Async BoundedStreamResult
  -> Int
  -> IO (Either AppError ProcessOutput)
collectFramedExchangeProcess process stderrReader remainingStdoutBytes = do
  finalFrameResult <- readFramedHandle remainingStdoutBytes (Typed.getStdout process)
  stderrResult <- wait stderrReader
  case (finalFrameResult, stderrResult) of
    (Left err, _) -> pure (Left err)
    (_, BoundedStreamTooLarge) ->
      pure (Left (boundedSubprocessError "bounded subprocess stderr exceeds its configured ceiling"))
    (_, BoundedStreamReadFailed err) -> pure (Left (subprocessIOException err))
    (Right (finalBytes, finalConsumed), BoundedStreamBytes stderrBytes) -> do
      trailingResult <-
        readBoundedHandle
          (remainingStdoutBytes - finalConsumed)
          (Typed.getStdout process)
      case trailingResult of
        BoundedStreamTooLarge ->
          pure (Left (boundedSubprocessError "bounded subprocess stdout exceeds its configured ceiling"))
        BoundedStreamReadFailed err -> pure (Left (subprocessIOException err))
        BoundedStreamBytes trailing
          | not (ByteString.null trailing) ->
              pure (Left (boundedSubprocessError "bounded subprocess emitted trailing framed output"))
          | otherwise -> do
              exitResult <-
                try (Typed.waitExitCode process) :: IO (Either IOException ExitCode)
              pure $ case exitResult of
                Left err -> Left (subprocessIOException err)
                Right exitCode ->
                  Right
                    ProcessOutput
                      { processExitCode = exitCode
                      , processStdout = BL8.unpack (LazyByteString.fromStrict finalBytes)
                      , processStderr = BL8.unpack (LazyByteString.fromStrict stderrBytes)
                      }

closeHandleQuietly :: Handle -> IO ()
closeHandleQuietly handle = do
  _ <- try (hClose handle) :: IO (Either IOException ())
  pure ()

stopProcessQuietly :: Typed.Process stdin stdout stderr -> IO ()
stopProcessQuietly process = do
  _ <- try (Typed.stopProcess process) :: IO (Either IOException ())
  pure ()

data BoundedStreamResult
  = BoundedStreamBytes !ByteString
  | BoundedStreamTooLarge
  | BoundedStreamReadFailed !IOException

readBoundedHandle :: Int -> Handle -> IO BoundedStreamResult
readBoundedHandle maximumBytes handle = go maximumBytes []
 where
  go remaining chunks = do
    readResult <-
      try (ByteString.hGetSome handle (min 4096 (remaining + 1)))
        :: IO (Either IOException ByteString)
    case readResult of
      Left err -> pure (BoundedStreamReadFailed err)
      Right chunk
        | ByteString.null chunk ->
            pure (BoundedStreamBytes (ByteString.concat (reverse chunks)))
        | ByteString.length chunk > remaining -> pure BoundedStreamTooLarge
        | otherwise -> go (remaining - ByteString.length chunk) (chunk : chunks)

collectBoundedProcess
  :: Typed.Process () Handle Handle
  -> Async BoundedStreamResult
  -> Async BoundedStreamResult
  -> IO (Either AppError ProcessOutput)
collectBoundedProcess process stdoutReader stderrReader = do
  first <- waitEither stdoutReader stderrReader
  case first of
    Left stdoutResult -> case stdoutResult of
      BoundedStreamBytes stdoutBytes -> do
        stderrResult <- wait stderrReader
        complete stdoutBytes stderrResult
      BoundedStreamTooLarge -> pure (Left (boundedSubprocessError "bounded subprocess stdout exceeds its configured ceiling"))
      BoundedStreamReadFailed err -> pure (Left (subprocessIOException err))
    Right stderrResult -> case stderrResult of
      BoundedStreamBytes stderrBytes -> do
        stdoutResult <- wait stdoutReader
        case stdoutResult of
          BoundedStreamBytes stdoutBytes -> finish stdoutBytes stderrBytes
          BoundedStreamTooLarge -> pure (Left (boundedSubprocessError "bounded subprocess stdout exceeds its configured ceiling"))
          BoundedStreamReadFailed err -> pure (Left (subprocessIOException err))
      BoundedStreamTooLarge -> pure (Left (boundedSubprocessError "bounded subprocess stderr exceeds its configured ceiling"))
      BoundedStreamReadFailed err -> pure (Left (subprocessIOException err))
 where
  complete stdoutBytes stderrResult = case stderrResult of
    BoundedStreamBytes stderrBytes -> finish stdoutBytes stderrBytes
    BoundedStreamTooLarge -> pure (Left (boundedSubprocessError "bounded subprocess stderr exceeds its configured ceiling"))
    BoundedStreamReadFailed err -> pure (Left (subprocessIOException err))

  finish stdoutBytes stderrBytes = do
    exitResult <-
      try (Typed.waitExitCode process) :: IO (Either IOException ExitCode)
    pure $ case exitResult of
      Left err -> Left (subprocessIOException err)
      Right exitCode ->
        Right
          ProcessOutput
            { processExitCode = exitCode
            , processStdout = BL8.unpack (LazyByteString.fromStrict stdoutBytes)
            , processStderr = BL8.unpack (LazyByteString.fromStrict stderrBytes)
            }

subprocessIOException :: IOException -> AppError
subprocessIOException = fatalError . Text.pack . displayException

boundedSubprocessError :: String -> AppError
boundedSubprocessError = fatalError . Text.pack

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
