{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Prodbox.Subprocess
  ( BackgroundProcess (..)
  , BoundedSubprocessLimits (..)
  , FramedSubprocessExchangeError (..)
  , FramedSubprocessExchangeTransportStage (..)
  , KillableSubprocessLimits (..)
  , KillableSubprocessOutcome (..)
  , OwnedSubprocessLimits
  , OwnedSubprocessResourceBounds
  , OwnedSubprocessError (..)
  , mkOwnedSubprocessResourceBounds
  , mkOwnedSubprocessLimits
  , captureOwnedSubprocess
  , HostSubprocessPlacement
  , HostSubprocessError (..)
  , hostSubprocessExecutionKey
  , hostSubprocessWorkEnd
  , hostSubprocessOuterEnd
  , hostSubprocessRuntimeDirectory
  , HostExecutionKey
  , hostExecutionKeyFromText
  , HostExecutionWindow
  , hostExecutionWindow
  , hostControllerUnitName
  , hostControllerSliceName
  , hostSubprocessDescription
  , withHostSubprocessPlacement
  , captureHostSubprocess
  , OperationStreamLimits
  , mkOperationStreamLimits
  , validateOperationStreamLimits
  , validateOperationTransportStartupLimits
  , OperationSubprocesses
  , operationSubprocesses
  , operationSubprocessExecutionKey
  , operationSubprocessWindow
  , operationSubprocessRuntimeDirectory
  , verifyOperationSubprocessesBeforeEffect
  , OperationSubprocessError (..)
  , OperationProcessOutput
  , operationProcessExitCode
  , operationProcessStdout
  , operationProcessStderr
  , captureOperationCommand
  , captureOperationCommandBefore
  , captureOperationCommandWithCeilingsBefore
  , captureOperationCommandWithInputBefore
  , captureOperationNativeCommand
  , captureOperationNativeCommandBefore
  , captureOperationNativeCommandWithCeilingsBefore
  , captureOperationNativeCommandWithInputBefore
  , validateOperationCommandInputLimits
  , OperationTransport
  , withOperationTransport
  , withOperationTransportStartup
  , withOperationNativeTransport
  , withOperationNativeTransportStartup
  , observeOperationTransportStartup
  , operationTransportWorkEnd
  , verifyOperationTransportBeforeEffect
  , ProcessOutput (..)
  , Subprocess (..)
  , NativeSubprocess (..)
  , boundedSubprocessTimeoutDetail
  , capture
  , captureSubprocessBounded
  , captureSubprocessKillable
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

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, poll, wait, waitEither, withAsync)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception
  ( IOException
  , SomeException
  , displayException
  , finally
  , mask
  , mask_
  , onException
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Monad (unless, void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as ByteStringBuilder
import Data.ByteString.Char8 qualified as ByteStringChar8
import Data.ByteString.Internal qualified as ByteStringInternal
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , atomicWriteIORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Foreign (Ptr, allocaArray, nullPtr, peekElemOff, plusPtr)
import Foreign.C.Error (Errno (..), eAGAIN, throwErrnoIfMinus1Retry, throwErrnoIfMinus1_)
import Foreign.C.Types (CInt (..), CLong (..), CUInt (..), CULong (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumCapabilities)
import GHC.Foreign qualified as GHCForeign
import GHC.IO.Encoding (getFileSystemEncoding)
import GHC.IO.Exception (ioe_errno)
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Error
  ( AppError
  , errorMsg
  , fatalError
  )
import Prodbox.Result
  ( Result (..)
  )
import Prodbox.Subprocess.HostOperationFamily qualified as Operation
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.OwnedProcessTree
  ( OwnedProcessRoot
  , recordOwnedProcessRoot
  , snapshotOwnedProcessTree
  , stopOwnedProcessDescendants
  )
import Prodbox.Subprocess.ProcessEnvironment qualified as Environment
import Prodbox.Subprocess.ScopeFamily qualified as Family
import Prodbox.Subprocess.StartupLine qualified as Startup
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity
  ( HostExecutionKey
  , HostExecutionWindow
  , hostControllerSliceName
  , hostControllerUnitName
  , hostExecutionKeyFromText
  , hostExecutionWindow
  )
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Environment (getEnvironment)
import System.Exit
  ( ExitCode (..)
  )
import System.IO
  ( Handle
  , hClose
  , hFlush
  , hGetBufSome
  )
import System.IO.Error (isEOFError)
import System.Posix.Directory.ByteString qualified as PosixDirectory
import System.Posix.IO qualified as PosixIO
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Process qualified as PosixProcess
import System.Posix.Process.ByteString qualified as PosixExec
import System.Posix.Signals
  ( Signal
  , sigKILL
  , sigTERM
  , signalProcess
  , signalProcessGroup
  )
import System.Posix.Types (Fd (..), ProcessID)
import System.Posix.Types qualified as PosixTypes
import System.Posix.User (getEffectiveUserID)
import System.Process qualified as Process
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

-- Explicit native bytes never pass through the string environment field.
-- The data carries no process slot, original window or admission grant.
data NativeSubprocess = NativeSubprocess
  { nativeSubprocessPath :: !FilePath
  , nativeSubprocessArguments :: ![String]
  , nativeSubprocessEnvironment :: !Environment.ProcessEnvironment
  , nativeSubprocessWorkingDirectory :: !(Maybe FilePath)
  }

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

-- | Limits for a long-running child that must neither be stopped for what it
-- prints nor be allowed to outlive its deadline.  Output is drained without a
-- ceiling; the wall clock and the kill grace are the only bounds, and both
-- must be positive.
data KillableSubprocessLimits = KillableSubprocessLimits
  { killableSubprocessTimeoutMicros :: !Int
  , killableSubprocessKillGraceMicros :: !Int
  }
  deriving (Eq, Show)

-- | How a killable child ended.  A child stopped at its deadline still reports
-- what it wrote before it was stopped, because that transcript is what names
-- the cause.
data KillableSubprocessOutcome
  = KillableSubprocessCompleted !ProcessOutput
  | KillableSubprocessTimedOut !ProcessOutput
  deriving (Eq, Show)

-- | Failure from a bounded two-stage exchange.  A decision refusal carries
-- the completed child output so the domain interpreter can require its exact
-- cleanup acknowledgement before preserving the typed refusal.
data FramedSubprocessExchangeTransportStage
  = FramedExchangeLimitsValidation
  | FramedExchangeInitialPayloadValidation
  | FramedExchangeProcessStart
  | FramedExchangeInitialPayloadWrite
  | FramedExchangeProvisionalRead
  | FramedExchangeDecisionContinuationWrite
  | FramedExchangeCompletionFrameRead
  | FramedExchangeCompletionStderrRead
  | FramedExchangeCompletionTrailingStdoutRead
  | FramedExchangeCompletionProcessWait
  | FramedExchangeWallClockTimeout
  deriving (Bounded, Enum, Eq, Show)

data FramedSubprocessExchangeError errorValue
  = FramedSubprocessExchangeTransportError
      !FramedSubprocessExchangeTransportStage
      !AppError
  | FramedSubprocessExchangeProvisionalReadError !AppError !ProcessOutput
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
    -- `process` specifies that delegated Ctrl-C is rethrown synchronously by
    -- the thread calling `waitForProcess`. `typed-process` instead performs
    -- that wait on a private reaper; the reaper can receive `UserInterrupt`
    -- before filling its exit-code TMVar and strand the caller forever. The
    -- streaming path therefore waits in this command thread while the process
    -- bracket remains the sole child-lifetime owner.
    try
      ( Process.withCreateProcess
          (streamingProcessConfig spec)
          (\_ _ _ -> Process.waitForProcess)
      )
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
                      `finally` killBoundedChild process
          pure $ case result of
            Nothing -> Left (boundedSubprocessError boundedSubprocessTimeoutDetail)
            Just bounded -> bounded
 where
  invalidLimits =
    boundedSubprocessMaximumInputBytes limits <= 0
      || boundedSubprocessMaximumStdoutBytes limits <= 0
      || boundedSubprocessMaximumStderrBytes limits <= 0
      || boundedSubprocessTimeoutMicros limits <= 0

-- | Stop the direct child of a bounded capture on every exit path (normal,
-- timeout and asynchronous cancellation). SIGKILL cannot be ignored, so
-- unlike a SIGTERM-then-wait stop this cannot wait past the caller's deadline
-- on a child that ignores termination; the reap wait is itself bounded.
-- Scope: the DIRECT child only. A descendant that left the child's process
-- group is not signalled and its absence is not established here.
killBoundedChild :: Typed.Process stdin stdout stderr -> IO ()
killBoundedChild process = do
  maybePid <- Typed.getPid process
  case maybePid of
    Nothing -> pure ()
    Just pid -> do
      exited <- Typed.getExitCode process
      when (exited == Nothing) $ do
        _ <- try (signalProcess sigKILL pid) :: IO (Either IOException ())
        waitReaped (boundedKillReapPolls :: Int)
 where
  waitReaped 0 = pure ()
  waitReaped remaining = do
    exited <- Typed.getExitCode process
    case exited of
      Just _ -> pure ()
      Nothing -> threadDelay 10000 >> waitReaped (remaining - 1)

-- | At most 200 polls of 10 ms: a 2 s reap bound after SIGKILL.
boundedKillReapPolls :: Int
boundedKillReapPolls = 200

-- | Run a long-lived child, such as a Pulumi destroy, under a wall-clock
-- bound.  The child leads its own process group.  That group does NOT hold
-- the plugin processes the child starts: Pulumi puts each plugin in a process
-- group of its own, so a signal to the child's group never reaches them, and a
-- SIGKILL of the child strands them (and leaves the backend lock the update
-- held).  What does stop them is the child's own shutdown, and Pulumi stops
-- at once on a second SIGTERM after the first has told it to cancel (measured
-- on Pulumi 3.228.0: the CLI exits within a second of the second signal, with
-- no plugin left running and no lock left behind, where the first signal alone
-- waits for the operation in flight).  The child is therefore stopped by
-- SIGTERM, a second SIGTERM shortly after, and, after the kill grace, SIGKILL:
-- waiting for a child that ignores SIGTERM would strand the caller past its
-- deadline.  The same stop runs if the caller is cancelled, so no exit path
-- leaves the child running.
captureSubprocessKillable
  :: KillableSubprocessLimits
  -> Subprocess
  -> IO (Either AppError KillableSubprocessOutcome)
captureSubprocessKillable limits spec
  | killableSubprocessTimeoutMicros limits <= 0
      || killableSubprocessKillGraceMicros limits <= 0 =
      pure (Left (boundedSubprocessError "killable subprocess limits must be positive"))
  | otherwise = mask $ \restore -> do
      started <-
        try
          ( Typed.startProcess
              ( Typed.setNewSession
                  True
                  ( Typed.setStdin
                      Typed.nullStream
                      ( Typed.setStdout
                          Typed.createPipe
                          (Typed.setStderr Typed.createPipe (typedProcessConfig False spec))
                      )
                  )
              )
          )
          :: IO (Either IOException (Typed.Process () Handle Handle))
      either (pure . Left . subprocessIOException) (runStarted restore) started
 where
  runStarted restore process = do
    root <- uninterruptibleMask_ (recordStartedRoot process)
    restore (runKillable limits root process)
      `onException` void (stopWithEscalation limits root process)
  recordStartedRoot process = do
    pid <- Typed.getPid process
    case pid of
      Nothing -> pure Nothing
      Just value -> recordOwnedProcessRoot value

runKillable
  :: KillableSubprocessLimits
  -> Maybe OwnedProcessRoot
  -> Typed.Process () Handle Handle
  -> IO (Either AppError KillableSubprocessOutcome)
runKillable limits root process = do
  stdoutChunks <- newIORef []
  stderrChunks <- newIORef []
  let snapshot exitCode = do
        stdoutText <- chunksText <$> readIORef stdoutChunks
        stderrText <- chunksText <$> readIORef stderrChunks
        pure
          ProcessOutput
            { processExitCode = exitCode
            , processStdout = stdoutText
            , processStderr = stderrText
            }
  let supervise (stdoutReader, stderrReader) = do
        finished <-
          timeout
            (killableSubprocessTimeoutMicros limits)
            (Typed.waitExitCode process)
        case finished of
          Just exitCode -> do
            settleReaders stdoutReader stderrReader
            Right . KillableSubprocessCompleted <$> snapshot exitCode
          Nothing -> do
            stopped <- stopWithEscalation limits root process
            settleReaders stdoutReader stderrReader
            case stopped of
              Left detail -> pure (Left (boundedSubprocessError (Text.unpack detail)))
              Right exitCode -> Right . KillableSubprocessTimedOut <$> snapshot exitCode
  withAsync
    (drainHandle (Typed.getStdout process) stdoutChunks)
    ( \stdoutReader ->
        withAsync
          (drainHandle (Typed.getStderr process) stderrChunks)
          (\stderrReader -> supervise (stdoutReader, stderrReader))
    )

-- | SIGTERM the child's group, repeat the SIGTERM once shortly after, give the
-- child the rest of the grace to leave, then SIGKILL the group.  The repeat is
-- harmless to a child that left on the first signal (it is never sent) and to
-- one that ignores both; it is what stops a Pulumi that took the first as a
-- request to cancel and is still waiting on the operation in flight.  Polling
-- rather than waiting on a timer keeps the stop uninterruptible yet bounded, so
-- a cancelled caller cannot skip the kill. The child owns a fresh POSIX session;
-- descendants are recorded before signalling and stopped across process groups.
-- Root and descendant confirmation share one deadline, preserving the existing
-- grace plus confirmation allowance.
stopWithEscalation
  :: KillableSubprocessLimits
  -> Maybe OwnedProcessRoot
  -> Typed.Process stdin stdout stderr
  -> IO (Either Text ExitCode)
stopWithEscalation limits root process = uninterruptibleMask_ $ do
  started <- getMonotonicTimeNSec
  let deadline = started + fromIntegral (grace + killConfirmationMicros) * 1000
  descendants <- case root of
    Nothing -> pure (Left "cannot establish the owned subprocess session")
    Just owned -> snapshotOwnedProcessTree owned
  exitCode <- stopLeader deadline
  now <- getMonotonicTimeNSec
  let remaining =
        min
          killConfirmationMicros
          (if now >= deadline then 0 else fromIntegral ((deadline - now) `div` 1000))
  reaped <- case (root, descendants) of
    (Just owned, Right recorded) -> stopOwnedProcessDescendants remaining owned recorded
    (_, Left detail) -> pure (Left detail)
    (Nothing, Right _) -> pure (Left "cannot establish the owned subprocess session")
  pure (exitCode >>= (\code -> code <$ reaped))
 where
  stopLeader deadline = do
    signalGroup sigTERM
    early <- pollExit deadline repeatGap
    case early of
      Just exitCode -> pure (Right exitCode)
      Nothing -> do
        signalGroup sigTERM
        terminated <- pollExit deadline (grace - repeatGap)
        case terminated of
          Just exitCode -> pure (Right exitCode)
          Nothing -> do
            signalGroup sigKILL
            killed <- pollExit deadline killConfirmationMicros
            pure
              (maybe (Left "owned subprocess leader did not stop within the kill-confirmation bound") Right killed)
  grace = killableSubprocessKillGraceMicros limits
  repeatGap = min repeatTermAfterMicros (grace `div` 2)
  signalGroup signal = do
    maybePid <- Typed.getPid process
    case maybePid of
      Nothing -> pure ()
      Just pid -> do
        _ <- try (signalProcessGroup signal pid) :: IO (Either IOException ())
        pure ()
  pollExit outerDeadline budget = do
    now <- getMonotonicTimeNSec
    pollUntil (min outerDeadline (now + fromIntegral (max 0 budget) * 1000))
  pollUntil deadline = do
    exited <- Typed.getExitCode process
    case exited of
      Just exitCode -> pure (Just exitCode)
      Nothing -> do
        now <- getMonotonicTimeNSec
        if now >= deadline
          then pure Nothing
          else do
            threadDelay (min killPollMicros (fromIntegral ((deadline - now) `div` 1000)))
            pollUntil deadline

-- | Read a handle to its end, keeping every chunk as it arrives so a child
-- that is stopped before it finishes still has its transcript.
drainHandle :: Handle -> IORef [ByteString] -> IO ()
drainHandle handle chunks = loop
 where
  loop = do
    chunk <- try (ByteString.hGetSome handle 65536) :: IO (Either IOException ByteString)
    case chunk of
      Right bytes
        | not (ByteString.null bytes) -> do
            atomicModifyIORef' chunks (\collected -> (bytes : collected, ()))
            loop
      _ -> pure ()

-- | Give the readers a moment to reach end-of-file once the child is gone. A
-- plugin that outlived it and kept a pipe open must not hold the caller.
settleReaders :: Async () -> Async () -> IO ()
settleReaders stdoutReader stderrReader = do
  void (timeout readerSettleMicros (wait stdoutReader))
  void (timeout readerSettleMicros (wait stderrReader))

chunksText :: [ByteString] -> String
chunksText = ByteStringChar8.unpack . ByteString.concat . reverse

killPollMicros :: Int
killPollMicros = 50 * 1000

-- | How long after the first SIGTERM the second is sent. Measured: Pulumi stops
-- within a second of the second signal whether it follows the first by a fifth
-- of a second or by two.
repeatTermAfterMicros :: Int
repeatTermAfterMicros = 2 * 1000 * 1000

killConfirmationMicros :: Int
killConfirmationMicros = 5 * 1000 * 1000

readerSettleMicros :: Int
readerSettleMicros = 5 * 1000 * 1000

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
  | invalidLimits =
      transportOnly
        FramedExchangeLimitsValidation
        "bounded subprocess limits must be positive"
  | framedLength initialPayload > boundedSubprocessMaximumInputBytes limits =
      transportOnly
        FramedExchangeInitialPayloadValidation
        "bounded subprocess input exceeds its configured ceiling"
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
          pure
            ( Left
                ( FramedSubprocessExchangeTransportError
                    FramedExchangeProcessStart
                    (subprocessIOException err)
                )
            )
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
                    FramedExchangeWallClockTimeout
                    (boundedSubprocessError boundedSubprocessTimeoutDetail)
                )
            Just exchangeResult -> exchangeResult
 where
  invalidLimits =
    boundedSubprocessMaximumInputBytes limits <= 0
      || boundedSubprocessMaximumStdoutBytes limits <= 0
      || boundedSubprocessMaximumStderrBytes limits <= 0
      || boundedSubprocessTimeoutMicros limits <= 0

  transportOnly stage detail =
    pure
      ( Left
          ( FramedSubprocessExchangeTransportError
              stage
              (boundedSubprocessError detail)
          )
      )

  exchange process stderrReader = do
    sent <- writeFramedHandle (Typed.getStdin process) initialPayload
    case sent of
      Left err ->
        pure
          ( Left
              ( FramedSubprocessExchangeTransportError
                  FramedExchangeInitialPayloadWrite
                  err
              )
          )
      Right () -> do
        provisional <-
          readFramedHandle
            (boundedSubprocessMaximumStdoutBytes limits)
            (Typed.getStdout process)
        case provisional of
          Left err -> do
            closeHandleQuietly (Typed.getStdin process)
            earlyOutput <- collectProvisionalFailureOutput process stderrReader
            pure $ case earlyOutput of
              Left _ ->
                Left
                  ( FramedSubprocessExchangeTransportError
                      FramedExchangeProvisionalRead
                      err
                  )
              Right output ->
                Left (FramedSubprocessExchangeProvisionalReadError err output)
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
      Left err ->
        pure
          ( Left
              ( FramedSubprocessExchangeTransportError
                  FramedExchangeDecisionContinuationWrite
                  err
              )
          )
      Right () -> do
        completed <-
          collectFramedExchangeProcess
            process
            stderrReader
            (boundedSubprocessMaximumStdoutBytes limits - consumedBytes)
        pure $ case completed of
          Left (stage, err) ->
            Left
              ( FramedSubprocessExchangeTransportError
                  stage
                  err
              )
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
  -> IO
       ( Either
           (FramedSubprocessExchangeTransportStage, AppError)
           ProcessOutput
       )
collectFramedExchangeProcess process stderrReader remainingStdoutBytes = do
  finalFrameResult <- readFramedHandle remainingStdoutBytes (Typed.getStdout process)
  stderrResult <- wait stderrReader
  case (finalFrameResult, stderrResult) of
    (Left err, _) -> pure (Left (FramedExchangeCompletionFrameRead, err))
    (_, BoundedStreamTooLarge) ->
      pure
        ( Left
            ( FramedExchangeCompletionStderrRead
            , boundedSubprocessError "bounded subprocess stderr exceeds its configured ceiling"
            )
        )
    (_, BoundedStreamReadFailed err) ->
      pure (Left (FramedExchangeCompletionStderrRead, subprocessIOException err))
    (Right (finalBytes, finalConsumed), BoundedStreamBytes stderrBytes) -> do
      trailingResult <-
        readBoundedHandle
          (remainingStdoutBytes - finalConsumed)
          (Typed.getStdout process)
      case trailingResult of
        BoundedStreamTooLarge ->
          pure
            ( Left
                ( FramedExchangeCompletionTrailingStdoutRead
                , boundedSubprocessError "bounded subprocess stdout exceeds its configured ceiling"
                )
            )
        BoundedStreamReadFailed err ->
          pure
            ( Left
                ( FramedExchangeCompletionTrailingStdoutRead
                , subprocessIOException err
                )
            )
        BoundedStreamBytes trailing
          | not (ByteString.null trailing) ->
              pure
                ( Left
                    ( FramedExchangeCompletionTrailingStdoutRead
                    , boundedSubprocessError "bounded subprocess emitted trailing framed output"
                    )
                )
          | otherwise -> do
              exitResult <-
                try (Typed.waitExitCode process) :: IO (Either IOException ExitCode)
              pure $ case exitResult of
                Left err ->
                  Left
                    ( FramedExchangeCompletionProcessWait
                    , subprocessIOException err
                    )
                Right exitCode ->
                  Right
                    ProcessOutput
                      { processExitCode = exitCode
                      , processStdout = BL8.unpack (LazyByteString.fromStrict finalBytes)
                      , processStderr = BL8.unpack (LazyByteString.fromStrict stderrBytes)
                      }

-- | Retain only the already-bounded stderr and exit status when a child closes
-- stdout before its provisional frame. The partially consumed framed stdout
-- is deliberately discarded: it may contain attacker-controlled bytes and is
-- not needed to classify an exact domain-owned refusal. A still-running child
-- is stopped here, as it would be by the enclosing bracket immediately after
-- the same terminal read failure.
collectProvisionalFailureOutput
  :: Typed.Process Handle Handle Handle
  -> Async BoundedStreamResult
  -> IO (Either AppError ProcessOutput)
collectProvisionalFailureOutput process stderrReader = do
  stopProcessQuietly process
  stderrResult <- wait stderrReader
  exitResult <- try (Typed.waitExitCode process) :: IO (Either IOException ExitCode)
  pure $ case (stderrResult, exitResult) of
    (BoundedStreamTooLarge, _) ->
      Left (boundedSubprocessError "bounded subprocess stderr exceeds its configured ceiling")
    (BoundedStreamReadFailed err, _) -> Left (subprocessIOException err)
    (_, Left err) -> Left (subprocessIOException err)
    (BoundedStreamBytes stderrBytes, Right exitCode) ->
      Right
        ProcessOutput
          { processExitCode = exitCode
          , processStdout = ""
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
      try (ByteString.hGetSome handle (min 4095 remaining + 1))
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

-- | The detail a bounded child's wall-clock timeout carries. Exported so a caller
-- that must tell a bound that ended a child from a failure the child reported
-- (an EC2 waiter killed at the Provider's per-child limit, which is a reason to
-- run it again and not a verdict) matches the one text and not a copy of it.
boundedSubprocessTimeoutDetail :: String
boundedSubprocessTimeoutDetail = "bounded subprocess exceeded its wall-clock timeout"

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

streamingProcessConfig :: Subprocess -> Process.CreateProcess
streamingProcessConfig spec =
  (Process.proc (subprocessPath spec) (subprocessArguments spec))
    { Process.cwd = subprocessWorkingDirectory spec
    , Process.env = subprocessEnvironment spec
    , Process.delegate_ctlc = True
    }

-- | Work and bounded-output collection reserve their confirmed shutdown inside
-- one total monotonic budget. This remains the sole process-creation boundary.
-- These are explicit wire bounds, not a host-placement or concurrency permit.
data OwnedSubprocessResourceBounds
  = OwnedSubprocessResourceBounds !Word64 !Word64 !Word64 !Word64 !Word64 !Word64 !Word64 !Word64

-- | Child memory bytes, tasks and CPU microseconds per second, followed by
-- the helper's memory, tasks, CPU and start/stop microseconds. CPU quotas use
-- whole percent steps so the manager's kernel projection remains exact.
mkOwnedSubprocessResourceBounds
  :: Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Either OwnedSubprocessError OwnedSubprocessResourceBounds
mkOwnedSubprocessResourceBounds memory tasks cpu helperMemory helperTasks helperCpu helperStart helperStop
  | all
      (\value -> value > 0 && value < maxBound)
      [memory, tasks, cpu, helperMemory, helperTasks, helperCpu, helperStart, helperStop]
      && cpu `mod` 10000 == 0
      && helperCpu `mod` 10000 == 0 =
      Right
        ( OwnedSubprocessResourceBounds
            memory
            tasks
            cpu
            helperMemory
            helperTasks
            helperCpu
            helperStart
            helperStop
        )
  | otherwise = Left OwnedSubprocessInvalidLimits

data OwnedSubprocessLimits = OwnedSubprocessLimits
  { resourceBounds :: !OwnedSubprocessResourceBounds
  , totalMicros :: !Int
  , graceMicros :: !Int
  , confirmationMicros :: !Int
  , settlementMicros :: !Int
  , stdoutCeiling :: !Int
  , stderrCeiling :: !Int
  }

data OwnedSubprocessError
  = OwnedSubprocessInvalidLimits
  | OwnedSubprocessStartFailed
  | OwnedSubprocessSessionUnobservable
  | OwnedSubprocessTreeUnobservable
  | OwnedSubprocessStdoutExceeded
  | OwnedSubprocessStderrExceeded
  | OwnedSubprocessStreamFailed
  | OwnedSubprocessDeadlineReached
  | OwnedSubprocessLeaderStopUnconfirmed
  | OwnedSubprocessDescendantStopUnconfirmed
  | OwnedSubprocessReadersUnsettled
  | OwnedSubprocessRuntimeUnsupported
  | OwnedSubprocessManagerRefused
  | OwnedSubprocessScopeUnobservable
  | OwnedSubprocessAlarmScopeUnobservable
  | OwnedSubprocessFamilyUnconfirmed
  | OwnedSubprocessIoRefused
  deriving (Eq, Show, Enum, Bounded)

-- | Total, graceful-stop, kill-confirmation and reader-settlement microseconds,
-- followed by stdout/stderr byte ceilings. Cleanup is reserved before launch.
mkOwnedSubprocessLimits
  :: OwnedSubprocessResourceBounds
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Either OwnedSubprocessError OwnedSubprocessLimits
mkOwnedSubprocessLimits resources@(OwnedSubprocessResourceBounds _ _ _ _ _ _ helperStart helperStop) total grace confirmation settlement out err
  | any (<= 0) [total, grace, confirmation, settlement, out, err]
      || toInteger total <= sum (map toInteger [grace, confirmation, settlement])
      || toInteger helperStart + toInteger helperStop >= toInteger confirmation =
      Left OwnedSubprocessInvalidLimits
  | otherwise = Right (OwnedSubprocessLimits resources total grace confirmation settlement out err)

data OwnedStreamResult = StreamBytes !ByteString | StreamExceeded | StreamFailed

foreign import capi "unistd.h pipe2" ownedPipe :: Ptr CInt -> CInt -> IO CInt
foreign import capi "fcntl.h value O_CLOEXEC" ownedCloseOnExec :: CInt
foreign import capi "fcntl.h value F_DUPFD_CLOEXEC" ownedDuplicateCommand :: CInt
foreign import capi "fcntl.h fcntl" ownedDuplicate :: CInt -> CInt -> CInt -> IO CInt
foreign import capi "fcntl.h value F_SETPIPE_SZ" ownedSetPipeSize :: CInt
foreign import capi "fcntl.h value F_GETPIPE_SZ" ownedGetPipeSize :: CInt
foreign import capi "unistd.h sysconf" ownedSystemConfiguration :: CInt -> IO CLong
foreign import capi "unistd.h value _SC_PAGESIZE" ownedSystemPageSizeOption :: CInt
foreign import capi "sys/pidfd.h pidfd_open" ownedPidfdOpen :: CInt -> CUInt -> IO CInt
foreign import capi "sys/pidfd.h pidfd_send_signal"
  ownedPidfdSignal :: CInt -> CInt -> Ptr () -> CUInt -> IO CInt
foreign import capi "sys/prctl.h value PR_SET_PDEATHSIG" ownedParentDeathOption :: CInt
foreign import capi "sys/prctl.h prctl"
  ownedParentDeathSignal :: CInt -> CULong -> CULong -> CULong -> CULong -> IO CInt

data OwnedNativeChild = OwnedNativeChild
  { nativePid :: !ProcessID
  , nativePidfd :: !Fd
  , nativeGo :: !Fd
  , nativeExec :: !Fd
  , nativeOut :: !Handle
  , nativeErr :: !Handle
  , nativeStatus :: !(IORef (Maybe PosixProcess.ProcessStatus))
  , nativeInput :: !(Maybe (Fd, IO ()))
  }

data OwnedInput = OwnedClosedInput | OwnedPipeInput !ByteString

data OwnedExec = OwnedExec !ByteString ![ByteString] !(Maybe ByteString) ![(ByteString, ByteString)]

data OperationInvocation
  = StringOperationInvocation !Subprocess
  | NativeOperationInvocation !NativeSubprocess

data OwnedDeadlines = OwnedDeadlines
  { ownedWorkEnd :: !Word64
  , ownedHardEnd :: !Word64
  , ownedStopEnd :: !Word64
  }

-- The observed host lease is distinct from the Authority's operation permit.
-- Closing this bracket invalidates every escaped placement/slot borrow.
data HostSubprocessPlacement
  = HostSubprocessPlacement !Kernel.HostPlacement !HostExecutionKey !HostExecutionWindow

hostSubprocessExecutionKey :: HostSubprocessPlacement -> HostExecutionKey
hostSubprocessExecutionKey (HostSubprocessPlacement _ key _) = key

hostSubprocessWorkEnd :: HostSubprocessPlacement -> Word64
hostSubprocessWorkEnd (HostSubprocessPlacement _ _ window) = Identity.hostExecutionWorkEnd window

hostSubprocessOuterEnd :: HostSubprocessPlacement -> Word64
hostSubprocessOuterEnd (HostSubprocessPlacement _ _ window) = Identity.hostExecutionOuterEnd window

hostSubprocessRuntimeDirectory :: HostSubprocessPlacement -> FilePath
hostSubprocessRuntimeDirectory (HostSubprocessPlacement placement _ _) = Kernel.hostPlacementRuntimeDirectory placement

data HostSubprocessError
  = HostSubprocessPlacementRefused !Kernel.KernelScopeError
  | HostSubprocessManagerRefused !Bus.BusError
  | HostSubprocessCommandRefused !OwnedSubprocessError
  | HostSubprocessCommandAndPlacementRefused !OwnedSubprocessError !Kernel.KernelScopeError
  deriving (Eq, Show)

hostSubprocessDescription
  :: Host.HostExecutionPlan -> HostExecutionKey -> HostExecutionWindow -> String
hostSubprocessDescription = Kernel.hostPlacementDescription

-- Observe this process's own managed PIDFD, resources and original window.
-- There is no caller PID, host-direct fallback, or resource allocation here.
withHostSubprocessPlacement
  :: Host.HostExecutionPlan
  -> HostExecutionKey
  -> HostExecutionWindow
  -> (HostSubprocessPlacement -> IO (Either HostSubprocessError value))
  -> IO (Either HostSubprocessError value)
withHostSubprocessPlacement plan key window action = do
  uid <- getEffectiveUserID
  managed <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) ("/run/user/" <> show uid <> "/bus") $ \connection -> lift $ do
    observed <-
      Kernel.withObservedHostPlacement connection plan key window $ \placement ->
        Right <$> action (HostSubprocessPlacement placement key window)
    pure (either (Left . HostSubprocessPlacementRefused) id observed)
  pure (either (Left . HostSubprocessManagerRefused) id managed)

-- Every command borrows the same caller-owned family and five absolute ends.
-- A present or unobservable family refuses before fork, retaining its location
-- for read-only recovery. Copying limits cannot allocate a second host slot.
captureHostSubprocess
  :: HostSubprocessPlacement
  -> OwnedSubprocessLimits
  -> Subprocess
  -> IO (Either HostSubprocessError ProcessOutput)
captureHostSubprocess (HostSubprocessPlacement placement _ _) limits spec = mask $ \restore -> do
  primaryFailure <- newIORef Nothing
  observed <- Kernel.withHostPlacementSlot placement $ \token connection -> do
    let window = Kernel.hostPlacementWindow token
        finish = Identity.hostExecutionFinishEnd window
        deadlines =
          OwnedDeadlines
            (Identity.hostExecutionWorkEnd window)
            (Identity.hostExecutionHardEnd window)
            (Identity.hostExecutionStopEnd window)
        run = do
          capabilities <- getNumCapabilities
          now <- getMonotonicTimeNSec
          if capabilities /= 1
            then pure (Left OwnedSubprocessRuntimeUnsupported)
            else
              if ownedSpecHasNul spec
                then pure (Left OwnedSubprocessStartFailed)
                else
                  if not (hostLimitsMatch token limits now)
                    then pure (Left OwnedSubprocessInvalidLimits)
                    else do
                      family <- Family.hostScopeFamilyIntent (Kernel.hostPlacementKey token) window
                      case family of
                        Left _ -> pure (Left OwnedSubprocessDeadlineReached)
                        Right intent -> do
                          prior <-
                            runExceptT
                              (Family.observeScopeFamily (Bus.systemdBusWithin (ownedWorkEnd deadlines) connection) intent)
                          case prior of
                            Right inventory | Family.scopeFamilyAbsent inventory -> do
                              executable <- encodeOwnedExec spec
                              withOwnedNativeChild deadlines executable $ \child ->
                                withAsync (readOwnedStream (stdoutCeiling limits) (nativeOut child)) $ \out ->
                                  withAsync (readOwnedStream (stderrCeiling limits) (nativeErr child)) $ \err -> do
                                    let stop = uninterruptibleMask_ (stopUnadmittedChild deadlines connection intent child)
                                    result <-
                                      ownKernelChild
                                        (HostChildOwnership token)
                                        restore
                                        limits
                                        deadlines
                                        (ownedWorkEnd deadlines)
                                        connection
                                        intent
                                        child
                                        out
                                        err
                                        `onException` void stop
                                    streams <- restore (settleOwned finish out err)
                                    pure $ do
                                      exit <- result
                                      (stdoutBytes, stderrBytes) <- streams
                                      Right (ProcessOutput exit (ByteStringChar8.unpack stdoutBytes) (ByteStringChar8.unpack stderrBytes))
                            _ -> pure (Left OwnedSubprocessFamilyUnconfirmed)
    attempted <- try run
    finished <- getMonotonicTimeNSec
    let result
          | finished >= finish = Left OwnedSubprocessDeadlineReached
          | otherwise =
              either
                (const (Left OwnedSubprocessIoRefused))
                id
                (attempted :: Either IOException (Either OwnedSubprocessError ProcessOutput))
    writeIORef primaryFailure (either Just (const Nothing) result)
    pure (Right result)
  primary <- readIORef primaryFailure
  pure $ case observed of
    Right result -> either (Left . HostSubprocessCommandRefused) Right result
    Left cause -> Left $ case primary of
      Just failure -> HostSubprocessCommandAndPlacementRefused failure cause
      Nothing -> HostSubprocessPlacementRefused cause

hostLimitsMatch :: Kernel.HostPlacementUse -> OwnedSubprocessLimits -> Word64 -> Bool
hostLimitsMatch token limits now =
  let plan = Kernel.hostPlacementPlan token
      window = Kernel.hostPlacementWindow token
      OwnedSubprocessResourceBounds memory tasks cpu helperMemory helperTasks helperCpu _ _ = resourceBounds limits
      fits micros end start = toInteger micros * 1000 <= toInteger end - toInteger start
   in memory == Host.hostExecutionChildMemoryBytes plan
        && tasks == Host.hostExecutionChildTasks plan
        && cpu == Host.hostExecutionChildCpuUsecPerSec plan
        && helperMemory == Host.hostExecutionHelperMemoryBytes plan
        && helperTasks == Host.hostExecutionHelperTasks plan
        && helperCpu == Host.hostExecutionHelperCpuUsecPerSec plan
        && toInteger (totalMicros limits) <= toInteger (Host.hostExecutionMaximumChildMicros plan)
        && toInteger (Identity.hostExecutionFinishEnd window) - toInteger now
          <= toInteger (totalMicros limits) * 1000
        && fits
          (graceMicros limits)
          (Identity.hostExecutionHardEnd window)
          (Identity.hostExecutionWorkEnd window)
        && fits
          (graceMicros limits)
          (Identity.hostExecutionStopEnd window)
          (Identity.hostExecutionHardEnd window)
        && fits
          (confirmationMicros limits)
          (Identity.hostExecutionStopEnd window)
          (Identity.hostExecutionHardEnd window)
        && fits
          (settlementMicros limits)
          (Identity.hostExecutionFinishEnd window)
          (Identity.hostExecutionStopEnd window)

-- Output buffers are separate from process resource limits and admission.
-- Two fixed per-role shares prevent copied budget values from over-admitting
-- concurrent transport/command buffers in the one physical operation.
data OperationStreamLimits = OperationStreamLimits !Int !Int !Word64

data OperationSubprocesses
  = OperationSubprocesses !Kernel.OperationParent !OperationStreamLimits !OperationStreamLimits

operationSubprocessExecutionKey :: OperationSubprocesses -> HostExecutionKey
operationSubprocessExecutionKey (OperationSubprocesses parent _ _) = Kernel.operationParentKey parent

operationSubprocessWindow :: OperationSubprocesses -> HostExecutionWindow
operationSubprocessWindow (OperationSubprocesses parent _ _) = Kernel.operationParentWindow parent

operationSubprocessRuntimeDirectory :: OperationSubprocesses -> FilePath
operationSubprocessRuntimeDirectory (OperationSubprocesses parent _ _) = Kernel.operationParentRuntimeDirectory parent

verifyOperationSubprocessesBeforeEffect
  :: OperationSubprocesses -> IO (Either OperationSubprocessError ())
verifyOperationSubprocessesBeforeEffect (OperationSubprocesses parent _ _) =
  either (Left . OperationScopeRefused) Right <$> Kernel.verifyOperationParentBeforeEffect parent

data OperationSubprocessError
  = OperationScopeRefused !Kernel.KernelScopeError
  | OperationProcessRefused !OwnedSubprocessError
  | OperationTransportExited !ExitCode
  | OperationPrimaryAndCleanupRefused !OperationSubprocessError !OperationSubprocessError
  deriving (Eq, Show)

data OperationProcessOutput = OperationProcessOutput !ExitCode !ByteString !ByteString

operationProcessExitCode :: OperationProcessOutput -> ExitCode
operationProcessExitCode (OperationProcessOutput code _ _) = code

operationProcessStdout :: OperationProcessOutput -> ByteString
operationProcessStdout (OperationProcessOutput _ bytes _) = bytes

operationProcessStderr :: OperationProcessOutput -> ByteString
operationProcessStderr (OperationProcessOutput _ _ bytes) = bytes

data OperationTransport
  = OperationTransport
      !Kernel.OperationProcessUse
      !Kernel.KernelScope
      !Word64
      !(MVar Bool)
      !(IORef Startup.StartupLineStatus)

mkOperationStreamLimits :: Int -> Int -> Word64 -> Either OwnedSubprocessError OperationStreamLimits
mkOperationStreamLimits out err grace
  | out > 0 && out < maxBound && err > 0 && err < maxBound && grace > 0 && grace < maxBound =
      Right (OperationStreamLimits out err grace)
  | otherwise = Left OwnedSubprocessInvalidLimits

operationSubprocesses
  :: Kernel.OperationParent
  -> OperationStreamLimits
  -> OperationStreamLimits
  -> Either OwnedSubprocessError OperationSubprocesses
operationSubprocesses parent command transport = do
  mapM_
    ( validateOperationStreamLimits
        (Host.hostExecutionRuntimeMemory (Kernel.operationParentPlan parent))
        (Kernel.operationParentWindow parent)
    )
    [command, transport]
  pure (OperationSubprocesses parent command transport)

-- The request decoder and the physical parent consume the same stream/heap
-- and original-window inequalities. This alone grants no subprocess slot.
validateOperationStreamLimits
  :: RuntimeMemory.RuntimeMemoryPlan
  -> HostExecutionWindow
  -> OperationStreamLimits
  -> Either OwnedSubprocessError ()
validateOperationStreamLimits runtime window limits
  | fits limits = Right ()
  | otherwise = Left OwnedSubprocessInvalidLimits
 where
  reserve =
    toInteger
      ( RuntimeMemory.positiveBytesValue
          ( RuntimeMemory.runtimeMemoryOtherHeapReserveBytes
              runtime
          )
      )
  fits (OperationStreamLimits out err grace) =
    -- Each stream has one admitted working buffer and at most one trimmed copy.
    -- The two roles each receive half the reserve, including overflow probes.
    4 * (toInteger out + toInteger err + 2) <= reserve
      && toInteger grace * 1000
        <= toInteger (Identity.hostExecutionHardEnd window) - toInteger (Identity.hostExecutionWorkEnd window)
      && toInteger grace * 1000
        <= toInteger (Identity.hostExecutionStopEnd window) - toInteger (Identity.hostExecutionHardEnd window)

-- The command's fixed half of the existing reserve covers its two stream
-- buffers and retained input. The existing Go pipe becomes stdin only after
-- its gate byte is consumed and exec is independently confirmed. Its capacity
-- is reduced and read back as one native page before fork, reusing the kernel
-- allocation already needed for Go instead of adding another pipe. A narrowed
-- handle cannot allocate another physical command or increase that reserve.
validateOperationCommandInputLimits
  :: RuntimeMemory.RuntimeMemoryPlan
  -> HostExecutionWindow
  -> OperationStreamLimits
  -> Int
  -> Either OwnedSubprocessError ()
validateOperationCommandInputLimits runtime window limits@(OperationStreamLimits out err _) maximumInput = do
  validateOperationStreamLimits runtime window limits
  let reserve =
        toInteger
          (RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryOtherHeapReserveBytes runtime))
  unless
    ( maximumInput > 0
        && maximumInput < maxBound
        && 4 * (toInteger out + toInteger err + 2 + toInteger maximumInput)
          <= reserve
    )
    (Left OwnedSubprocessInvalidLimits)

-- Startup protocol metadata consumes the transport role's half of the same
-- fixed reserve; it cannot borrow another buffer or enlarge the parent heap.
validateOperationTransportStartupLimits
  :: RuntimeMemory.RuntimeMemoryPlan
  -> HostExecutionWindow
  -> OperationStreamLimits
  -> Startup.StartupLineExpectation
  -> Either OwnedSubprocessError ()
validateOperationTransportStartupLimits runtime window limits@(OperationStreamLimits out err _) expected = do
  validateOperationStreamLimits runtime window limits
  unless
    ( Startup.startupLineMaximumLength expected < out
        && 4 * (toInteger out + toInteger err + 2) + 2 * Startup.startupLineReserveBytes
          <= toInteger
            (RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryOtherHeapReserveBytes runtime))
    )
    (Left OwnedSubprocessInvalidLimits)

operationTransportWorkEnd :: OperationTransport -> Word64
operationTransportWorkEnd (OperationTransport _ _ end _ _) = end

verifyOperationTransportBeforeEffect
  :: OperationTransport -> IO (Either OperationSubprocessError ())
verifyOperationTransportBeforeEffect (OperationTransport token scope _ active _) = withMVar active $ \live ->
  if not live
    then pure (Left (OperationScopeRefused Kernel.KernelHostPlacementClosed))
    else
      either (Left . OperationScopeRefused) Right
        <$> Kernel.verifyOperationProcessBeforeEffect token scope

-- Only a semantic status leaves the exact child-pipe observer. A closed,
-- expired or changed transport cannot supply a startup observation.
observeOperationTransportStartup
  :: OperationTransport -> IO (Either OperationSubprocessError Startup.StartupLineStatus)
observeOperationTransportStartup lease@(OperationTransport _ _ _ _ observed) = do
  before <- verifyOperationTransportBeforeEffect lease
  case before of
    Left cause -> pure (Left cause)
    Right () -> do
      status <- readIORef observed
      closing <- verifyOperationTransportBeforeEffect lease
      pure (status <$ closing)

captureOperationCommand
  :: OperationSubprocesses -> Subprocess -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationCommand owned@(OperationSubprocesses parent _ _) =
  captureOperationCommandBefore
    (Identity.hostExecutionWorkEnd (Kernel.operationParentWindow parent))
    owned

-- A request may tighten work, never refresh the original operation window.
captureOperationCommandBefore
  :: Word64
  -> OperationSubprocesses
  -> Subprocess
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationCommandBefore = captureOperationCommandUsingInputBefore OwnedClosedInput

captureOperationNativeCommand
  :: OperationSubprocesses
  -> NativeSubprocess
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationNativeCommand owned@(OperationSubprocesses parent _ _) =
  captureOperationNativeCommandBefore
    (Identity.hostExecutionWorkEnd (Kernel.operationParentWindow parent))
    owned

captureOperationNativeCommandBefore
  :: Word64
  -> OperationSubprocesses
  -> NativeSubprocess
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationNativeCommandBefore requested owned spec =
  captureOperationInvocationBefore OwnedClosedInput requested owned (NativeOperationInvocation spec)

captureOperationCommandUsingInputBefore
  :: OwnedInput
  -> Word64
  -> OperationSubprocesses
  -> Subprocess
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationCommandUsingInputBefore input requested owned spec = do
  captureOperationInvocationBefore input requested owned (StringOperationInvocation spec)

captureOperationInvocationBefore
  :: OwnedInput
  -> Word64
  -> OperationSubprocesses
  -> OperationInvocation
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationInvocationBefore input requested owned invocation = do
  result <- runOperationProcess Nothing input owned Operation.OperationCommandProcess requested invocation $ \_ deadlines child _ out err _ ->
    either (Left . OperationProcessRefused) Right
      <$> superviseOperationCommandInput input deadlines child out err
  pure $ fmap (\(code, out, err) -> OperationProcessOutput code out err) result

-- A client may borrow a smaller stream share from the original command lane.
-- The parent, process slot, grace and absolute window are retained; copying the
-- narrowed handle cannot allocate another command lane or refresh admission.
captureOperationCommandWithCeilingsBefore
  :: Int
  -> Int
  -> Word64
  -> OperationSubprocesses
  -> Subprocess
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationCommandWithCeilingsBefore outCeiling errCeiling requested owned spec =
  captureOperationInvocationWithCeilingsBefore
    outCeiling
    errCeiling
    requested
    owned
    (StringOperationInvocation spec)

captureOperationNativeCommandWithCeilingsBefore
  :: Int
  -> Int
  -> Word64
  -> OperationSubprocesses
  -> NativeSubprocess
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationNativeCommandWithCeilingsBefore outCeiling errCeiling requested owned spec =
  captureOperationInvocationWithCeilingsBefore
    outCeiling
    errCeiling
    requested
    owned
    (NativeOperationInvocation spec)

captureOperationInvocationWithCeilingsBefore
  :: Int
  -> Int
  -> Word64
  -> OperationSubprocesses
  -> OperationInvocation
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationInvocationWithCeilingsBefore outCeiling errCeiling requested (OperationSubprocesses parent (OperationStreamLimits out err grace) transport) invocation
  | outCeiling <= 0 || errCeiling <= 0 =
      pure (Left (OperationProcessRefused OwnedSubprocessInvalidLimits))
  | otherwise =
      captureOperationInvocationBefore
        OwnedClosedInput
        requested
        ( OperationSubprocesses
            parent
            (OperationStreamLimits (min out outCeiling) (min err errCeiling) grace)
            transport
        )
        invocation

-- Exact binary input is delivered only after the existing PIDFD, parent and
-- Go/exec checks. Input writes and supervision share the original work end.
captureOperationCommandWithInputBefore
  :: Int
  -> Int
  -> Int
  -> Word64
  -> OperationSubprocesses
  -> ByteString
  -> Subprocess
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationCommandWithInputBefore maximumInput outCeiling errCeiling requested owned input spec =
  captureOperationInvocationWithInputBefore
    maximumInput
    outCeiling
    errCeiling
    requested
    owned
    input
    (StringOperationInvocation spec)

captureOperationNativeCommandWithInputBefore
  :: Int
  -> Int
  -> Int
  -> Word64
  -> OperationSubprocesses
  -> ByteString
  -> NativeSubprocess
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationNativeCommandWithInputBefore maximumInput outCeiling errCeiling requested owned input spec =
  captureOperationInvocationWithInputBefore
    maximumInput
    outCeiling
    errCeiling
    requested
    owned
    input
    (NativeOperationInvocation spec)

captureOperationInvocationWithInputBefore
  :: Int
  -> Int
  -> Int
  -> Word64
  -> OperationSubprocesses
  -> ByteString
  -> OperationInvocation
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationInvocationWithInputBefore maximumInput outCeiling errCeiling requested (OperationSubprocesses parent (OperationStreamLimits out err grace) transport) input invocation
  | outCeiling <= 0 || errCeiling <= 0 || ByteString.length input > maximumInput =
      pure (Left (OperationProcessRefused OwnedSubprocessInvalidLimits))
  | otherwise =
      let limits = OperationStreamLimits (min out outCeiling) (min err errCeiling) grace
       in case validateOperationCommandInputLimits
            (Host.hostExecutionRuntimeMemory (Kernel.operationParentPlan parent))
            (Kernel.operationParentWindow parent)
            limits
            maximumInput of
            Left cause -> pure (Left (OperationProcessRefused cause))
            Right () ->
              captureOperationInvocationBefore
                (OwnedPipeInput input)
                requested
                (OperationSubprocesses parent limits transport)
                invocation

superviseOperationCommandInput
  :: OwnedInput
  -> OwnedDeadlines
  -> OwnedNativeChild
  -> Async OwnedStreamResult
  -> Async OwnedStreamResult
  -> IO (Either OwnedSubprocessError ExitCode)
superviseOperationCommandInput input deadlines child out err = case (input, nativeInput child) of
  (OwnedClosedInput, Nothing) -> monitor
  (OwnedPipeInput bytes, Just (descriptor, closeInput)) ->
    withAsync (writeOwnedInputBefore ending descriptor bytes `finally` closeInput) $ \writer ->
      withAsync monitor $ \observer -> do
        first <- waitEither writer observer
        case first of
          Left (Left cause) -> pure (Left cause)
          Left (Right ()) -> wait observer
          Right (Left cause) -> pure (Left cause)
          Right (Right code) -> do
            written <- wait writer
            pure (code <$ written)
  _ -> pure (Left OwnedSubprocessStartFailed)
 where
  ending = ownedWorkEnd deadlines
  monitor = superviseKernelChild ending child out err

writeOwnedInputBefore :: Word64 -> Fd -> ByteString -> IO (Either OwnedSubprocessError ())
writeOwnedInputBefore ending descriptor bytes = do
  now <- getMonotonicTimeNSec
  if now >= ending
    then pure (Left OwnedSubprocessDeadlineReached)
    else
      if ByteString.null bytes
        then pure (Right ())
        else do
          attempted <- try (PosixBytes.fdWrite descriptor (ByteString.take 4096 bytes))
          case attempted of
            Left cause
              | fmap Errno (ioe_errno cause) == Just eAGAIN ->
                  threadDelay 1000 >> writeOwnedInputBefore ending descriptor bytes
            Left (_ :: IOException) -> pure (Left OwnedSubprocessIoRefused)
            Right written
              | written > 0 ->
                  writeOwnedInputBefore ending descriptor (ByteString.drop (fromIntegral written) bytes)
            Right _ -> pure (Left OwnedSubprocessIoRefused)

withOperationTransport
  :: OperationSubprocesses
  -> Subprocess
  -> (OperationTransport -> IO value)
  -> IO (Either OperationSubprocessError value)
withOperationTransport = withOperationTransportUsingStartup Nothing

withOperationTransportStartup
  :: OperationSubprocesses
  -> Subprocess
  -> Startup.StartupLineExpectation
  -> (OperationTransport -> IO value)
  -> IO (Either OperationSubprocessError value)
withOperationTransportStartup owned spec expected =
  withOperationTransportUsingStartup (Just expected) owned spec

withOperationTransportUsingStartup
  :: Maybe Startup.StartupLineExpectation
  -> OperationSubprocesses
  -> Subprocess
  -> (OperationTransport -> IO value)
  -> IO (Either OperationSubprocessError value)
withOperationTransportUsingStartup startup owned spec =
  withOperationTransportInvocation startup owned (StringOperationInvocation spec)

withOperationNativeTransport
  :: OperationSubprocesses
  -> NativeSubprocess
  -> (OperationTransport -> IO value)
  -> IO (Either OperationSubprocessError value)
withOperationNativeTransport owned spec =
  withOperationTransportInvocation Nothing owned (NativeOperationInvocation spec)

withOperationNativeTransportStartup
  :: OperationSubprocesses
  -> NativeSubprocess
  -> Startup.StartupLineExpectation
  -> (OperationTransport -> IO value)
  -> IO (Either OperationSubprocessError value)
withOperationNativeTransportStartup owned spec expected =
  withOperationTransportInvocation (Just expected) owned (NativeOperationInvocation spec)

withOperationTransportInvocation
  :: Maybe Startup.StartupLineExpectation
  -> OperationSubprocesses
  -> OperationInvocation
  -> (OperationTransport -> IO value)
  -> IO (Either OperationSubprocessError value)
withOperationTransportInvocation startup owned@(OperationSubprocesses parent _ _) invocation action = do
  let end = Identity.hostExecutionWorkEnd (Kernel.operationParentWindow parent)
  result <- runOperationProcess
    startup
    OwnedClosedInput
    owned
    Operation.OperationTransportProcess
    end
    invocation
    $ \token deadlines child scope out err observed -> do
      active <- newMVar True
      let lease = OperationTransport token scope (ownedWorkEnd deadlines) active observed
          run = withAsync (superviseKernelChild (ownedWorkEnd deadlines) child out err) $ \monitor ->
            withAsync (action lease) $ \callback -> do
              first <- waitEither monitor callback
              pure $ case first of
                Left (Left cause) -> Left (OperationProcessRefused cause)
                Left (Right code) -> Left (OperationTransportExited code)
                Right value -> Right value
      run `finally` modifyMVar_ active (const (pure False))
  pure (fmap (\(value, _, _) -> value) result)

-- The existing trusted fork/Go/exec/leader machinery remains the process owner.
-- This composition uses the observed role scope and retains the global alarm.
runOperationProcess
  :: Maybe Startup.StartupLineExpectation
  -> OwnedInput
  -> OperationSubprocesses
  -> Operation.HostOperationProcessRole
  -> Word64
  -> OperationInvocation
  -> ( Kernel.OperationProcessUse
       -> OwnedDeadlines
       -> OwnedNativeChild
       -> Kernel.KernelScope
       -> Async OwnedStreamResult
       -> Async OwnedStreamResult
       -> IORef Startup.StartupLineStatus
       -> IO (Either OperationSubprocessError value)
     )
  -> IO (Either OperationSubprocessError (value, ByteString, ByteString))
runOperationProcess startup input (OperationSubprocesses parent command transport) role requested invocation execute = mask $ \restore -> do
  primaryFailure <- newIORef Nothing
  startupStatus <-
    newIORef (maybe Startup.StartupLineUnconfigured (const Startup.StartupLinePending) startup)
  let window = Kernel.operationParentWindow parent
      finish = Identity.hostExecutionFinishEnd window
      deadlines =
        OwnedDeadlines
          (min requested (Identity.hostExecutionWorkEnd window))
          (Identity.hostExecutionHardEnd window)
          (Identity.hostExecutionStopEnd window)
      OperationStreamLimits outLimit errLimit grace = case role of
        Operation.OperationCommandProcess -> command
        Operation.OperationTransportProcess -> transport
      startupFits = case (startup, role) of
        (Nothing, _) -> True
        (Just expected, Operation.OperationTransportProcess) ->
          either (const False) (const True) $
            validateOperationTransportStartupLimits
              (Host.hostExecutionRuntimeMemory (Kernel.operationParentPlan parent))
              window
              transport
              expected
        (Just _, Operation.OperationCommandProcess) -> False
      record result = writeIORef primaryFailure (either Just (const Nothing) result) >> pure result
      run token = do
        capabilities <- getNumCapabilities
        now <- getMonotonicTimeNSec
        if capabilities /= 1
          then pure (Left (OperationProcessRefused OwnedSubprocessRuntimeUnsupported))
          else
            if not startupFits
              then pure (Left (OperationProcessRefused OwnedSubprocessInvalidLimits))
              else
                if operationInvocationHasNul invocation || operationInvocationEnvironmentMissing invocation
                  then pure (Left (OperationProcessRefused OwnedSubprocessStartFailed))
                  else
                    if now >= ownedWorkEnd deadlines
                      then pure (Left (OperationProcessRefused OwnedSubprocessDeadlineReached))
                      else do
                        executable <- encodeOperationInvocation invocation
                        native <- withOwnedNativeChildInput input deadlines executable $ \child ->
                          withAsync
                            ( readOperationStreamObserved
                                outLimit
                                (nativeOut child)
                                ((,startupStatus) <$> startup)
                            )
                            $ \out ->
                              withAsync (readOperationStream errLimit (nativeErr child)) $ \err -> do
                                raised <- newIORef Nothing
                                let stop scope = uninterruptibleMask_ (stopKernelChildProcesses grace deadlines child scope)
                                    effect scope = do
                                      before <- Kernel.verifyOperationProcessBeforeEffect token scope
                                      case before of
                                        Left cause -> pure (Left (OperationScopeRefused cause))
                                        Right () -> do
                                          current <- getMonotonicTimeNSec
                                          if current >= ownedWorkEnd deadlines
                                            then pure (Left (OperationProcessRefused OwnedSubprocessDeadlineReached))
                                            else do
                                              written <- PosixIO.fdWrite (nativeGo child) "G"
                                              if written /= 1
                                                then pure (Left (OperationProcessRefused OwnedSubprocessStartFailed))
                                                else do
                                                  started <- awaitOwnedExec (ownedWorkEnd deadlines) (nativeExec child)
                                                  case started of
                                                    Left cause -> pure (Left (OperationProcessRefused cause))
                                                    Right () -> execute token deadlines child scope out err startupStatus
                                scopeResult <- Kernel.withOperationProcessScope token (nativePidfd child) $ \scope -> do
                                  attempted <- tryOperationAction (restore (effect scope))
                                  case attempted of
                                    Left cause -> writeIORef raised (Just cause)
                                    Right _ -> pure ()
                                  stopped <- either (Left . OperationProcessRefused) Right <$> stop scope
                                  let primary = either (const (Left (OperationProcessRefused OwnedSubprocessIoRefused))) id attempted
                                  combined <- record (combineOperationProcessResult primary stopped)
                                  pure (Right combined)
                                primary <- case scopeResult of
                                  Right value -> pure value
                                  Left cause -> do
                                    leader <- uninterruptibleMask_ (stopNativeLeader (ownedStopEnd deadlines) child)
                                    prior <- readIORef primaryFailure
                                    let refused =
                                          maybe
                                            (OperationScopeRefused cause)
                                            (\failure -> OperationPrimaryAndCleanupRefused failure (OperationScopeRefused cause))
                                            prior
                                    pure
                                      (combineOperationProcessResult (Left refused) (either (Left . OperationProcessRefused) Right leader))
                                streams <- restore (settleOwned finish out err)
                                let result = case (primary, streams) of
                                      (Right value, Right (outBytes, errBytes)) -> Right (value, outBytes, errBytes)
                                      (Left cause, Left cleanup) -> Left (OperationPrimaryAndCleanupRefused cause (OperationProcessRefused cleanup))
                                      (Left cause, Right _) -> Left cause
                                      (Right _, Left cause) -> Left (OperationProcessRefused cause)
                                exception <- readIORef raised
                                case exception of
                                  Just cause -> throwIO cause
                                  Nothing -> pure (Right result)
                        pure (either (Left . OperationProcessRefused) id native)
  attempted <- try $ Kernel.withOperationProcessSlot parent role $ \token -> Right <$> run token
  case attempted of
    Left (_ :: IOException) -> pure (Left (OperationProcessRefused OwnedSubprocessIoRefused))
    Right (Right result) -> pure result
    Right (Left cause) -> do
      primary <- readIORef primaryFailure
      pure
        ( Left
            ( maybe
                (OperationScopeRefused cause)
                (\failure -> OperationPrimaryAndCleanupRefused failure (OperationScopeRefused cause))
                primary
            )
        )

missingEnvironment :: Subprocess -> Bool
missingEnvironment spec = case subprocessEnvironment spec of
  Nothing -> True
  Just _ -> False

operationInvocationHasNul :: OperationInvocation -> Bool
operationInvocationHasNul invocation = case invocation of
  StringOperationInvocation spec -> ownedSpecHasNul spec
  NativeOperationInvocation spec ->
    any (elem '\0') $
      nativeSubprocessPath spec
        : nativeSubprocessArguments spec
          <> maybe [] pure (nativeSubprocessWorkingDirectory spec)

operationInvocationEnvironmentMissing :: OperationInvocation -> Bool
operationInvocationEnvironmentMissing invocation = case invocation of
  StringOperationInvocation spec -> missingEnvironment spec
  NativeOperationInvocation _ -> False

encodeOperationInvocation :: OperationInvocation -> IO OwnedExec
encodeOperationInvocation invocation = case invocation of
  StringOperationInvocation spec -> encodeOwnedExec spec
  NativeOperationInvocation spec -> do
    encoding <- getFileSystemEncoding
    let encode value = GHCForeign.withCStringLen encoding value ByteString.packCStringLen
    OwnedExec
      <$> encode (nativeSubprocessPath spec)
      <*> traverse encode (nativeSubprocessArguments spec)
      <*> traverse encode (nativeSubprocessWorkingDirectory spec)
      <*> pure (Environment.processEnvironmentNativeEntries (nativeSubprocessEnvironment spec))

tryOperationAction :: IO value -> IO (Either SomeException value)
tryOperationAction = try

combineOperationProcessResult
  :: Either OperationSubprocessError value
  -> Either OperationSubprocessError ()
  -> Either OperationSubprocessError value
combineOperationProcessResult primary cleanup = case (primary, cleanup) of
  (Left cause, Left refusal) -> Left (OperationPrimaryAndCleanupRefused cause refusal)
  (Left cause, Right ()) -> Left cause
  (Right _, Left cause) -> Left cause
  (Right value, Right ()) -> Right value

-- One bounded allocation per reader, plus at most its bounded trimmed copy.
-- Fragmentation cannot retain an input-shaped list of tiny chunks.
readOperationStream :: Int -> Handle -> IO OwnedStreamResult
readOperationStream maximumBytes handle = readOperationStreamObserved maximumBytes handle Nothing

readOperationStreamObserved
  :: Int
  -> Handle
  -> Maybe (Startup.StartupLineExpectation, IORef Startup.StartupLineStatus)
  -> IO OwnedStreamResult
readOperationStreamObserved maximumBytes handle startup = do
  let publish status = forMStartup (\(_, observed) -> atomicWriteIORef observed status)
      forMStartup action = maybe (pure ()) action startup
  result <- try $ ByteStringInternal.createAndTrim (maximumBytes + 1) $ \buffer ->
    let feed matcher offset count = case matcher of
          Nothing -> pure Nothing
          Just initial -> do
            let advance index current
                  | index >= count || Startup.startupLineStatus current /= Startup.StartupLinePending = pure current
                  | otherwise = do
                      byte <- peekElemOff buffer (offset + index)
                      advance (index + 1) (Startup.feedStartupLineByte current byte)
            current <- advance 0 initial
            publish (Startup.startupLineStatus current)
            pure (Just current)
        loop size matcher
          | size == maximumBytes + 1 = pure size
          | otherwise = do
              count <- hGetBufSome handle (buffer `plusPtr` size) (min 4096 (maximumBytes + 1 - size))
              if count == 0
                then do
                  maybe (pure ()) (publish . Startup.finishStartupLine) matcher
                  pure size
                else do
                  next <- feed matcher size count
                  loop (size + count) next
     in loop 0 (Startup.beginStartupLine . fst <$> startup)
  case result of
    Left (_ :: IOException) -> publish Startup.StartupLineReadFailed >> pure StreamFailed
    Right bytes
      | ByteString.length bytes > maximumBytes ->
          publish Startup.StartupLineExceeded >> pure StreamExceeded
      | otherwise -> pure (StreamBytes bytes)

data ChildOwnership = StandaloneChildOwnership | HostChildOwnership !Kernel.HostPlacementUse

captureOwnedSubprocess
  :: OwnedSubprocessLimits -> Subprocess -> IO (Either OwnedSubprocessError ProcessOutput)
captureOwnedSubprocess limits spec = mask $ \restore -> do
  started <- getMonotonicTimeNSec
  capabilities <- getNumCapabilities
  let endInteger = toInteger started + toInteger (totalMicros limits) * 1000
  if endInteger > toInteger (maxBound :: Word64)
    then pure (Left OwnedSubprocessInvalidLimits)
    else
      if capabilities /= 1
        then pure (Left OwnedSubprocessRuntimeUnsupported)
        else
          if ownedSpecHasNul spec
            then pure (Left OwnedSubprocessStartFailed)
            else do
              let end = fromInteger endInteger
                  stopEnd = end - fromIntegral (settlementMicros limits) * 1000
                  hardEnd = stopEnd - fromIntegral (confirmationMicros limits) * 1000
                  workEnd = hardEnd - fromIntegral (graceMicros limits) * 1000
                  deadlines = OwnedDeadlines workEnd hardEnd stopEnd
                  creationEnd = started + (workEnd - started) `div` 2
              attempted <- try $ do
                executable <- encodeOwnedExec spec
                family <- Family.newScopeFamilyIntent hardEnd stopEnd
                case family of
                  Left _ -> pure (Left OwnedSubprocessDeadlineReached)
                  Right intent -> withOwnedNativeChild deadlines executable $ \child ->
                    withAsync (readOwnedStream (stdoutCeiling limits) (nativeOut child)) $ \out ->
                      withAsync (readOwnedStream (stderrCeiling limits) (nativeErr child)) $ \err -> do
                        uid <- getEffectiveUserID
                        managed <- Bus.withSystemdBus stopEnd ("/run/user/" <> show uid <> "/bus") $ \connection -> lift $ do
                          let noGoCleanup = uninterruptibleMask_ (stopUnadmittedChild deadlines connection intent child)
                              admitted =
                                ownKernelChild
                                  StandaloneChildOwnership
                                  restore
                                  limits
                                  deadlines
                                  creationEnd
                                  connection
                                  intent
                                  child
                                  out
                                  err
                          admitted `onException` void noGoCleanup
                        result <- case managed of
                          Left _ -> do
                            stopped <- uninterruptibleMask_ (stopNativeLeader stopEnd child)
                            pure (stopped >> Left OwnedSubprocessManagerRefused)
                          Right value -> pure value
                        -- Kernel membership and every auxiliary unit settle before readers.
                        streams <- restore (settleOwned end out err)
                        pure $ do
                          exit <- result
                          (stdoutBytes, stderrBytes) <- streams
                          Right (ProcessOutput exit (ByteStringChar8.unpack stdoutBytes) (ByteStringChar8.unpack stderrBytes))
              finished <- getMonotonicTimeNSec
              pure $
                if finished >= fromInteger endInteger
                  then Left OwnedSubprocessDeadlineReached
                  else
                    either
                      (const (Left OwnedSubprocessIoRefused))
                      id
                      (attempted :: Either IOException (Either OwnedSubprocessError ProcessOutput))

-- Encode all filesystem-facing values before fork. executeFile retains the
-- parent's PATH search behavior while the child receives the declared env.
encodeOwnedExec :: Subprocess -> IO OwnedExec
encodeOwnedExec spec = do
  environment <- maybe getEnvironment pure (subprocessEnvironment spec)
  encoding <- getFileSystemEncoding
  let encode value = GHCForeign.withCStringLen encoding value ByteString.packCStringLen
  OwnedExec
    <$> encode (subprocessPath spec)
    <*> traverse encode (subprocessArguments spec)
    <*> traverse encode (subprocessWorkingDirectory spec)
    <*> traverse (\(key, value) -> (,) <$> encode key <*> encode value) environment

ownedSpecHasNul :: Subprocess -> Bool
ownedSpecHasNul spec =
  any (elem '\0') $
    subprocessPath spec
      : subprocessArguments spec
        <> maybe [] pure (subprocessWorkingDirectory spec)
        <> concatMap (\(key, value) -> [key, value]) (maybe [] id (subprocessEnvironment spec))

-- Every descriptor starts CLOEXEC and above stdio. The parent owns a closing
-- registry so a closed numeric descriptor can never be closed again after reuse.
withOwnedNativeChild
  :: OwnedDeadlines
  -> OwnedExec
  -> (OwnedNativeChild -> IO (Either OwnedSubprocessError value))
  -> IO (Either OwnedSubprocessError value)
withOwnedNativeChild = withOwnedNativeChildInput OwnedClosedInput

withOwnedNativeChildInput
  :: OwnedInput
  -> OwnedDeadlines
  -> OwnedExec
  -> (OwnedNativeChild -> IO (Either OwnedSubprocessError value))
  -> IO (Either OwnedSubprocessError value)
withOwnedNativeChildInput suppliedInput deadlines executable action = do
  descriptors <- newIORef []
  let register fd = modifyIORef' descriptors (fd :) >> pure fd
      close fd = do
        held <- atomicModifyIORef' descriptors (\fds -> (filter (/= fd) fds, fd `elem` fds))
        when held (PosixIO.closeFd fd)
      release = readIORef descriptors >>= mapM_ (\fd -> void (try (close fd) :: IO (Either IOException ())))
      above fd@(Fd raw)
        | raw >= 3 = pure fd
        | otherwise = do
            duplicate <-
              Fd <$> throwErrnoIfMinus1Retry "owned stdio duplicate" (ownedDuplicate raw ownedDuplicateCommand 3)
            registered <- register duplicate
            close fd
            pure registered
      pair = allocaArray 2 $ \pointer -> do
        throwErrnoIfMinus1_ "owned pipe" (ownedPipe pointer ownedCloseOnExec)
        first <- peekElemOff pointer 0
        second <- peekElemOff pointer 1
        a <- register (Fd first)
        b <- register (Fd second)
        (,) <$> above a <*> above b
  flip finally release $ do
    (outRead, outWrite) <- pair
    (errRead, errWrite) <- pair
    (execRead, execWrite) <- pair
    (goRead, goWrite) <- pair
    PosixIO.setFdOption goRead PosixIO.NonBlockingRead True
    PosixIO.setFdOption execRead PosixIO.NonBlockingRead True
    (input, inputWriter) <- case suppliedInput of
      OwnedClosedInput -> do
        descriptor <-
          PosixIO.openFd "/dev/null" PosixIO.ReadOnly PosixIO.defaultFileFlags {PosixIO.cloexec = True}
            >>= register
            >>= above
        pure (descriptor, Nothing)
      OwnedPipeInput _ -> do
        let Fd raw = goWrite
        originalCapacity <-
          throwErrnoIfMinus1Retry "owned Go pipe observation" (ownedDuplicate raw ownedGetPipeSize 0)
        pageSize <- ownedSystemConfiguration ownedSystemPageSizeOption
        unless (pageSize > 0) (ioError (userError "owned native page size unavailable"))
        throwErrnoIfMinus1_ "owned input pipe capacity" (ownedDuplicate raw ownedSetPipeSize 1)
        capacity <-
          throwErrnoIfMinus1Retry "owned input pipe observation" (ownedDuplicate raw ownedGetPipeSize 0)
        unless
          (capacity > 0 && toInteger capacity == toInteger pageSize && capacity <= originalCapacity)
          (ioError (userError "owned input pipe capacity refused"))
        PosixIO.setFdOption goWrite PosixIO.NonBlockingRead True
        pure (goRead, Just goWrite)
    owner <- PosixProcess.getProcessID
    now <- getMonotonicTimeNSec
    if now >= ownedWorkEnd deadlines
      then pure (Left OwnedSubprocessDeadlineReached)
      else do
        child <-
          PosixProcess.forkProcess $
            trustedOwnedChild
              (ownedWorkEnd deadlines)
              owner
              executable
              input
              outRead
              outWrite
              errRead
              errWrite
              execRead
              execWrite
              goRead
              goWrite
        status <- newIORef Nothing
        ownedDescriptor <- newIORef Nothing
        let await = awaitNativeStatus (ownedStopEnd deadlines) child status
            stop = uninterruptibleMask_ $ do
              void (try (close goWrite) :: IO (Either IOException ()))
              known <- readIORef ownedDescriptor
              case known of
                Nothing -> pure ()
                Just descriptor -> void (ownedPidfdSignal descriptor 9 nullPtr 0)
              void await
        flip finally stop $ do
          mapM_ close [input, outWrite, errWrite, execWrite, goRead]
          descriptor <- ownedPidfdOpen (fromIntegral child) 0
          if descriptor < 0
            then do
              close goWrite
              stopped <- await
              pure
                (maybe (Left OwnedSubprocessLeaderStopUnconfirmed) (const (Left OwnedSubprocessStartFailed)) stopped)
            else do
              pidfd <- register (Fd descriptor)
              writeIORef ownedDescriptor (Just descriptor)
              output <- PosixIO.fdToHandle outRead
              modifyIORef' descriptors (filter (/= outRead))
              flip finally (closeOwnedHandle output) $ do
                errors <- PosixIO.fdToHandle errRead
                modifyIORef' descriptors (filter (/= errRead))
                flip finally (closeOwnedHandle errors) $
                  action
                    ( OwnedNativeChild
                        child
                        pidfd
                        goWrite
                        execRead
                        output
                        errors
                        status
                        ((\inputDescriptor -> (inputDescriptor, close inputDescriptor)) <$> inputWriter)
                    )

trustedOwnedChild
  :: Word64
  -> ProcessID
  -> OwnedExec
  -> Fd
  -> Fd
  -> Fd
  -> Fd
  -> Fd
  -> Fd
  -> Fd
  -> Fd
  -> Fd
  -> IO ()
trustedOwnedChild
  deadline
  owner
  (OwnedExec path arguments directory environment)
  input
  outRead
  outWrite
  errRead
  errWrite
  execRead
  execWrite
  goRead
  goWrite = do
    mapM_ PosixIO.closeFd [outRead, errRead, execRead, goWrite]
    attempted <- try $ do
      result <- ownedParentDeathSignal ownedParentDeathOption 9 0 0 0
      actual <- PosixProcess.getParentProcessID
      unless (result == 0 && actual == owner) (ioError (userError "owned parent unavailable"))
      token <- readOwnedGate deadline goRead
      now <- getMonotonicTimeNSec
      unless (token && now < deadline) (ioError (userError "owned effect gate refused"))
      if input == goRead
        then PosixIO.setFdOption input PosixIO.NonBlockingRead False
        else PosixIO.closeFd goRead
      void PosixProcess.createSession
      void (PosixIO.dupTo input PosixIO.stdInput)
      void (PosixIO.dupTo outWrite PosixIO.stdOutput)
      void (PosixIO.dupTo errWrite PosixIO.stdError)
      mapM_ PosixIO.closeFd [input, outWrite, errWrite]
      maybe (pure ()) PosixDirectory.changeWorkingDirectory directory
      beforeExec <- getMonotonicTimeNSec
      unless (beforeExec < deadline) (ioError (userError "owned exec deadline reached"))
      PosixExec.executeFile path True arguments (Just environment)
    case attempted :: Either IOException () of
      Left _ -> void (try (PosixIO.fdWrite execWrite "E") :: IO (Either IOException PosixTypes.ByteCount))
      Right () -> pure ()
    PosixProcess.exitImmediately (ExitFailure 125)

readOwnedGate :: Word64 -> Fd -> IO Bool
readOwnedGate deadline descriptor = do
  now <- getMonotonicTimeNSec
  if now >= deadline
    then pure False
    else do
      token <- try (PosixBytes.fdRead descriptor 1)
      case token of
        Left cause
          | fmap Errno (ioe_errno cause) == Just eAGAIN ->
              threadDelay 1000 >> readOwnedGate deadline descriptor
        Left _ -> pure False
        Right bytes -> pure (bytes == "G")

ownKernelChild
  :: ChildOwnership
  -> (IO (Either OwnedSubprocessError ExitCode) -> IO (Either OwnedSubprocessError ExitCode))
  -> OwnedSubprocessLimits
  -> OwnedDeadlines
  -> Word64
  -> Bus.BusConnection
  -> Family.ScopeFamilyIntent
  -> OwnedNativeChild
  -> Async OwnedStreamResult
  -> Async OwnedStreamResult
  -> IO (Either OwnedSubprocessError ExitCode)
ownKernelChild ownership restore limits deadlines creationEnd connection intent child out err = do
  let OwnedSubprocessResourceBounds
        memory
        tasks
        cpu
        helperMemory
        helperTasks
        helperCpu
        helperStart
        helperStop = resourceBounds limits
      scopeLimits =
        Kernel.scopeKernelLimits
          memory
          0
          tasks
          cpu
          (fromIntegral (totalMicros limits))
          (fromIntegral (graceMicros limits))
      helperLimits = Family.expiryHelperLimits helperMemory helperTasks helperCpu helperStart helperStop
  case (scopeLimits, helperLimits) of
    (Just scopeBounds, Just helperBounds) -> do
      let submit = case ownership of
            StandaloneChildOwnership -> Family.startScopeFamily
            HostChildOwnership token -> Family.startHostScopeFamily token
          observe = case ownership of
            StandaloneChildOwnership -> \busConnection ->
              Kernel.withObservedChildScopeBefore busConnection (ownedWorkEnd deadlines) (ownedStopEnd deadlines)
            HostChildOwnership token -> Kernel.withObservedHostChildScope token
      submitted <-
        submit connection creationEnd intent (nativePidfd child) scopeBounds helperBounds
      observed <- observe
        connection
        (nativePidfd child)
        (Family.scopeFamilyUnitName intent Family.FamilyScope)
        scopeBounds
        $ \scope -> do
          let stop = uninterruptibleMask_ (stopKernelChild limits deadlines connection intent child scope)
              run = do
                armed <-
                  familyAlarmReady
                    (Bus.systemdBusWithin (ownedWorkEnd deadlines) connection)
                    intent
                    (ownedHardEnd deadlines)
                placement <- case ownership of
                  StandaloneChildOwnership -> pure (Right ())
                  HostChildOwnership token -> do
                    helper <- Family.verifyHostScopeFamilyBeforeEffect token connection intent helperBounds
                    case helper of
                      Left _ -> pure (Left Kernel.KernelScopeResourceMismatch)
                      Right () -> do
                        parent <- Kernel.verifyHostPlacementBeforeEffect token
                        case parent of
                          Left cause -> pure (Left cause)
                          Right () -> Kernel.verifyKernelScopeBeforeEffect (ownedWorkEnd deadlines) scopeBounds scope
                if not armed || either (const True) (const False) placement
                  then pure (Left OwnedSubprocessFamilyUnconfirmed)
                  else do
                    now <- getMonotonicTimeNSec
                    if now >= ownedWorkEnd deadlines
                      then pure (Left OwnedSubprocessDeadlineReached)
                      else do
                        written <- PosixIO.fdWrite (nativeGo child) "G"
                        if written /= 1
                          then pure (Left OwnedSubprocessStartFailed)
                          else do
                            started <- awaitOwnedExec (ownedWorkEnd deadlines) (nativeExec child)
                            case started of
                              Left cause -> pure (Left cause)
                              Right () -> superviseKernelChild (ownedWorkEnd deadlines) child out err
          primary <- restore run `onException` void stop
          stopped <- stop
          pure (Right (stopped >> primary))
      case observed of
        Left _ -> do
          cleanup <- stopUnadmittedChild deadlines connection intent child
          pure
            ( cleanup
                >> Left
                  (either (const OwnedSubprocessManagerRefused) (const OwnedSubprocessScopeUnobservable) submitted)
            )
        Right primary -> do
          closing <- awaitOwnedFamilyAbsent connection intent
          pure (closing >> primary)
    _ -> pure (Left OwnedSubprocessInvalidLimits)

familyAlarmReady :: Bus.BusConnection -> Family.ScopeFamilyIntent -> Word64 -> IO Bool
familyAlarmReady connection intent hard = do
  result <- runExceptT $ do
    inventory <- Family.observeScopeFamily connection intent
    timer <-
      Bus.callManager
        connection
        Bus.GetUnit
        (\message -> Bus.appendString message (Family.scopeFamilyUnitName intent Family.FamilyTimer))
        (`Bus.readString` 'o')
    let property interface name = Bus.callManager connection (Bus.ReadUnitProperty timer) $ \message ->
          Bus.appendString message interface >> Bus.appendString message name
    expiry <- property "org.freedesktop.systemd1.Timer" "NextElapseUSecMonotonic" Bus.readVariantWord64
    state <- property "org.freedesktop.systemd1.Unit" "ActiveState" Bus.readVariantString
    pure (inventory, expiry, state)
  pure $ case result of
    Right (inventory, expiry, "active") ->
      expiry == hard `div` 1000
        && case ( Family.scopeFamilyPresence inventory Family.FamilyTimer
                , Family.scopeFamilyPresence inventory Family.FamilyExpiry
                ) of
          ( Family.ScopeFamilyUnitPresent (Bus.InvocationPresent _)
            , Family.ScopeFamilyUnitPresent Bus.InvocationAbsent
            ) -> True
          _ -> False
    _ -> False

awaitOwnedExec :: Word64 -> Fd -> IO (Either OwnedSubprocessError ())
awaitOwnedExec deadline descriptor = do
  now <- getMonotonicTimeNSec
  if now >= deadline
    then pure (Left OwnedSubprocessDeadlineReached)
    else do
      result <- try (PosixBytes.fdRead descriptor 1)
      case result of
        Left cause | isEOFError cause -> pure (Right ())
        Left cause
          | fmap Errno (ioe_errno cause) == Just eAGAIN ->
              threadDelay 1000 >> awaitOwnedExec deadline descriptor
        Left _ -> pure (Left OwnedSubprocessStartFailed)
        Right bytes -> pure (if ByteString.null bytes then Right () else Left OwnedSubprocessStartFailed)

superviseKernelChild
  :: Word64
  -> OwnedNativeChild
  -> Async OwnedStreamResult
  -> Async OwnedStreamResult
  -> IO (Either OwnedSubprocessError ExitCode)
superviseKernelChild deadline child out err = do
  outState <- ownedStreamFailure OwnedSubprocessStdoutExceeded <$> poll out
  errState <- ownedStreamFailure OwnedSubprocessStderrExceeded <$> poll err
  exited <- pollNativeStatus (nativePid child) (nativeStatus child)
  now <- getMonotonicTimeNSec
  case outState >> errState of
    Left cause -> pure (Left cause)
    Right ()
      | now >= deadline -> pure (Left OwnedSubprocessDeadlineReached)
      | Just status <- exited -> pure (Right (nativeExitCode status))
      | otherwise -> threadDelay 1000 >> superviseKernelChild deadline child out err

ownedStreamFailure
  :: OwnedSubprocessError -> Maybe (Either exception OwnedStreamResult) -> Either OwnedSubprocessError ()
ownedStreamFailure exceeded state = case state of
  Just (Left _) -> Left OwnedSubprocessStreamFailed
  Just (Right StreamFailed) -> Left OwnedSubprocessStreamFailed
  Just (Right StreamExceeded) -> Left exceeded
  _ -> Right ()

stopKernelChild
  :: OwnedSubprocessLimits
  -> OwnedDeadlines
  -> Bus.BusConnection
  -> Family.ScopeFamilyIntent
  -> OwnedNativeChild
  -> Kernel.KernelScope
  -> IO (Either OwnedSubprocessError ())
stopKernelChild limits deadlines connection intent child scope = do
  stopped <- stopKernelChildProcesses (fromIntegral (graceMicros limits)) deadlines child scope
  case stopped of
    Left cause -> pure (Left cause)
    Right () -> do
      retired <- Family.retireScopeFamilyAlarms connection (ownedStopEnd deadlines) intent scope
      pure $ case retired of
        Right () -> Right ()
        Left (Family.ScopeFamilyChildRefused _) -> Left OwnedSubprocessAlarmScopeUnobservable
        Left _ -> Left OwnedSubprocessFamilyUnconfirmed

stopKernelChildProcesses
  :: Word64
  -> OwnedDeadlines
  -> OwnedNativeChild
  -> Kernel.KernelScope
  -> IO (Either OwnedSubprocessError ())
stopKernelChildProcesses grace deadlines child scope = do
  now <- getMonotonicTimeNSec
  let graceEnd = fromInteger (min (toInteger (ownedHardEnd deadlines)) (toInteger now + toInteger grace * 1000))
  initially <- Kernel.kernelScopeEmpty scope
  graceful <- case initially of
    Right True -> pure True
    Right False -> do
      void (Kernel.terminateKernelScope graceEnd scope)
      awaitKernelEmpty graceEnd scope
    Left _ -> pure False
  unless graceful (void (Kernel.killKernelScope scope))
  empty <- awaitKernelEmpty (ownedStopEnd deadlines) scope
  leader <- awaitNativeStatus (ownedStopEnd deadlines) (nativePid child) (nativeStatus child)
  pure $
    if not empty
      then Left OwnedSubprocessDescendantStopUnconfirmed
      else
        if leader == Nothing
          then Left OwnedSubprocessLeaderStopUnconfirmed
          else Right ()

awaitKernelEmpty :: Word64 -> Kernel.KernelScope -> IO Bool
awaitKernelEmpty deadline scope = do
  observed <- Kernel.observeKernelScopeEmptyBefore deadline scope
  now <- getMonotonicTimeNSec
  case observed of
    Right True -> pure (now < deadline)
    Right False | now < deadline -> threadDelay 1000 >> awaitKernelEmpty deadline scope
    _ -> pure False

stopUnadmittedChild
  :: OwnedDeadlines
  -> Bus.BusConnection
  -> Family.ScopeFamilyIntent
  -> OwnedNativeChild
  -> IO (Either OwnedSubprocessError ())
stopUnadmittedChild deadlines connection intent child = do
  leader <- stopNativeLeader (ownedStopEnd deadlines) child
  closing <- awaitOwnedFamilyAbsent connection intent
  pure (leader >> closing)

-- A failed connection never reaches the family callback. Its trusted child
-- still owns the pipe writers, so stop it before waiting for reader EOF.
stopNativeLeader :: Word64 -> OwnedNativeChild -> IO (Either OwnedSubprocessError ())
stopNativeLeader deadline child = do
  let Fd descriptor = nativePidfd child
  void (ownedPidfdSignal descriptor 9 nullPtr 0)
  leader <- awaitNativeStatus deadline (nativePid child) (nativeStatus child)
  pure (maybe (Left OwnedSubprocessLeaderStopUnconfirmed) (const (Right ())) leader)

awaitOwnedFamilyAbsent
  :: Bus.BusConnection -> Family.ScopeFamilyIntent -> IO (Either OwnedSubprocessError ())
awaitOwnedFamilyAbsent connection intent = do
  result <- runExceptT (Family.observeScopeFamily connection intent)
  now <- getMonotonicTimeNSec
  case result of
    Right inventory
      | Family.scopeFamilyAbsent inventory && now < Bus.systemdBusDeadline connection -> pure (Right ())
      | now < Bus.systemdBusDeadline connection ->
          threadDelay 1000 >> awaitOwnedFamilyAbsent connection intent
    _ -> pure (Left OwnedSubprocessFamilyUnconfirmed)

pollNativeStatus
  :: ProcessID -> IORef (Maybe PosixProcess.ProcessStatus) -> IO (Maybe PosixProcess.ProcessStatus)
pollNativeStatus child stored = mask_ $ do
  cached <- readIORef stored
  case cached of
    Just _ -> pure cached
    Nothing -> do
      -- Nonblocking waitpid consumption and cache publication are one owned
      -- transition; cancellation must not lose a status already reaped.
      current <- PosixProcess.getProcessStatus False False child
      maybe (pure ()) (writeIORef stored . Just) current
      pure current

awaitNativeStatus
  :: Word64
  -> ProcessID
  -> IORef (Maybe PosixProcess.ProcessStatus)
  -> IO (Maybe PosixProcess.ProcessStatus)
awaitNativeStatus deadline child stored = do
  status <- pollNativeStatus child stored
  now <- getMonotonicTimeNSec
  case status of
    Just _ -> pure status
    Nothing
      | now >= deadline -> pure Nothing
      | otherwise -> threadDelay 1000 >> awaitNativeStatus deadline child stored

nativeExitCode :: PosixProcess.ProcessStatus -> ExitCode
nativeExitCode status = case status of
  PosixProcess.Exited code -> code
  PosixProcess.Terminated signal _ -> ExitFailure (negate (fromIntegral signal))
  PosixProcess.Stopped signal -> ExitFailure (negate (fromIntegral signal))

closeOwnedHandle :: Handle -> IO ()
closeOwnedHandle handle = void (try (hClose handle) :: IO (Either IOException ()))

settleOwned
  :: Word64
  -> Async OwnedStreamResult
  -> Async OwnedStreamResult
  -> IO (Either OwnedSubprocessError (ByteString, ByteString))
settleOwned deadline out err = do
  now <- getMonotonicTimeNSec
  let remaining = if now >= deadline then 0 else fromIntegral ((deadline - now) `div` 1000)
  streams <- timeout remaining ((,) <$> wait out <*> wait err)
  after <- getMonotonicTimeNSec
  pure $ case streams of
    _ | after >= deadline -> Left OwnedSubprocessDeadlineReached
    Nothing -> Left OwnedSubprocessReadersUnsettled
    Just (stdoutResult, stderrResult) ->
      (,)
        <$> bytes OwnedSubprocessStdoutExceeded stdoutResult
        <*> bytes OwnedSubprocessStderrExceeded stderrResult
 where
  bytes _ (StreamBytes value) = Right value
  bytes exceeded StreamExceeded = Left exceeded
  bytes _ StreamFailed = Left OwnedSubprocessStreamFailed

readOwnedStream :: Int -> Handle -> IO OwnedStreamResult
readOwnedStream maximumBytes handle = loop 0 []
 where
  loop size chunks = do
    -- Read one byte beyond the admitted remaining length to distinguish exact
    -- size from overflow without retaining an unbounded extra chunk.
    next <-
      try (ByteString.hGetSome handle (min 4096 (min 4096 (maximumBytes - size) + 1)))
        :: IO (Either IOException ByteString)
    case next of
      Left _ -> pure StreamFailed
      Right chunk
        | ByteString.null chunk -> pure (StreamBytes (ByteString.concat (reverse chunks)))
        | ByteString.length chunk > maximumBytes - size -> pure StreamExceeded
        | otherwise -> loop (size + ByteString.length chunk) (chunk : chunks)
