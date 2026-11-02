{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded anonymous input for an ordinary controller. Only a descriptor
-- enters the manager message. Payloads have no Show instance, file or digest.
module Prodbox.Subprocess.HostControllerStdin
  ( HostControllerStdin
  , HostControllerStdinError (..)
  , hostControllerStdinMaximumBytes
  , withHostControllerStdin
  , verifyHostControllerStdin
  , appendHostControllerStdin
  , deliverHostControllerStdin
  , readHostControllerStdin
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Exception
  ( IOException
  , SomeException
  , bracketOnError
  , finally
  , mask
  , mask_
  , throwIO
  , try
  )
import Control.Monad (void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (throwE)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Internal qualified as BytesInternal
import Data.Word (Word64)
import Foreign (Ptr, allocaArray, peekElemOff, plusPtr)
import Foreign.C.Error (Errno (..), eAGAIN, throwErrnoIfMinus1Retry, throwErrnoIfMinus1_)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdIdentity
import System.IO (hGetBufSome, stdin)
import System.Posix.Files (deviceID, fileID, fileOwner, getFdStatus, isNamedPipe, readSymbolicLink)
import System.Posix.IO (FdOption (NonBlockingRead), closeFd, setFdOption)
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (DeviceID, Fd (..), FileID, UserID)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data HostControllerStdinError
  = ControllerStdinEmpty
  | ControllerStdinTooLarge
  | ControllerStdinExpired
  | ControllerStdinBindingMismatch
  | ControllerStdinClosed
  | ControllerStdinAlreadyOffered
  | ControllerStdinNotOffered
  | ControllerStdinAlreadyAttempted
  | ControllerStdinDescriptorChanged
  | ControllerStdinPipeUnfunded
  | ControllerStdinIoRefused !IOErrorType !(Maybe Int)
  deriving (Eq, Show)

-- Separate from public input-file and subprocess stream ceilings. The
-- anonymous pipe is at most this size; the writer streams without growing it.
hostControllerStdinMaximumBytes :: Int
hostControllerStdinMaximumBytes = 64 * 1024

data InputStage = InputReady !ByteString | InputOffered !ByteString | InputSpent | InputClosed

data HostControllerStdin
  = HostControllerStdin
      !HostExecutionKey
      !HostExecutionWindow
      !Fd
      !DeviceID
      !FileID
      !UserID
      !(MVar (Maybe Fd))
      !(MVar InputStage)

foreign import capi "unistd.h pipe2" inputPipe :: Ptr CInt -> CInt -> IO CInt
foreign import capi "fcntl.h value O_CLOEXEC" inputCloseOnExec :: CInt
foreign import capi "fcntl.h value F_SETPIPE_SZ" inputSetPipeSize :: CInt
foreign import capi "fcntl.h value F_GETPIPE_SZ" inputGetPipeSize :: CInt
foreign import capi "fcntl.h fcntl" inputPipeSize :: CInt -> CInt -> CInt -> IO CInt

withHostControllerStdin
  :: HostExecutionKey
  -> HostExecutionWindow
  -> ByteString
  -> (HostControllerStdin -> IO value)
  -> IO (Either HostControllerStdinError value)
withHostControllerStdin key window bytes action
  | Bytes.null bytes = pure (Left ControllerStdinEmpty)
  | Bytes.length bytes > hostControllerStdinMaximumBytes = pure (Left ControllerStdinTooLarge)
  | otherwise = mask $ \restore -> do
      current <- beforeEnd (hostExecutionWorkEnd window)
      case current of
        Left cause -> pure (Left cause)
        Right () -> do
          opened <- newInput key window bytes
          case opened of
            Left cause -> pure (Left cause)
            Right owner -> do
              attempted <- try (restore (action owner))
              closed <- closeInput owner
              clock <- beforeEnd (hostExecutionWorkEnd window)
              case attempted of
                Left (cause :: SomeException) -> throwIO cause
                Right value -> pure (value <$ (clock >> closed))

newInput
  :: HostExecutionKey
  -> HostExecutionWindow
  -> ByteString
  -> IO (Either HostControllerStdinError HostControllerStdin)
newInput key window bytes = ioResult $ bracketOnError open closeRaw $ \(reader, writer) -> do
  writing <- newMVar (Just writer)
  stage <- newMVar $! InputReady (Bytes.copy bytes)
  uid <- getEffectiveUserID
  status <- getFdStatus reader
  let owner = HostControllerStdin key window reader (deviceID status) (fileID status) uid writing stage
  prepared <- try $ do
    setFdOption writer NonBlockingRead True
    let Fd descriptor = writer
    _ <-
      throwErrnoIfMinus1Retry "controller pipe bound" (inputPipeSize descriptor inputSetPipeSize 4096)
    capacity <-
      throwErrnoIfMinus1Retry "controller pipe capacity" (inputPipeSize descriptor inputGetPipeSize 0)
    pure (capacity > 0 && toInteger capacity <= toInteger hostControllerStdinMaximumBytes)
  case prepared of
    Left (cause :: IOException) -> throwIO cause
    Right False -> do
      void (closeInput owner)
      pure (Left ControllerStdinPipeUnfunded)
    Right True -> pure (Right owner)
 where
  open = allocaArray 2 $ \descriptors -> do
    throwErrnoIfMinus1_ "controller anonymous pipe" (inputPipe descriptors inputCloseOnExec)
    reader <- Fd <$> peekElemOff descriptors 0
    writer <- Fd <$> peekElemOff descriptors 1
    pure (reader, writer)
  closeRaw (reader, writer) = closeFd writer `finally` closeFd reader

verifyHostControllerStdin
  :: HostExecutionKey
  -> HostExecutionWindow
  -> HostControllerStdin
  -> IO (Either HostControllerStdinError ())
verifyHostControllerStdin key window owner@(HostControllerStdin original originalWindow _ _ _ _ _ stage)
  | key /= original || window /= originalWindow = pure (Left ControllerStdinBindingMismatch)
  | otherwise = withMVar stage verifyStage
 where
  verifyStage current = case current of
    InputClosed -> pure (Left ControllerStdinClosed)
    InputSpent -> pure (Left ControllerStdinAlreadyAttempted)
    InputReady _ -> verifyDescriptor owner
    InputOffered _ -> verifyDescriptor owner

verifyDescriptor :: HostControllerStdin -> IO (Either HostControllerStdinError ())
verifyDescriptor (HostControllerStdin _ window reader device identity uid _ _) = do
  checked <- beforeEnd (hostExecutionWorkEnd window)
  case checked of
    Left cause -> pure (Left cause)
    Right () -> ioResult $ do
      status <- getFdStatus reader
      closing <- beforeEnd (hostExecutionWorkEnd window)
      pure $
        if isNamedPipe status
          && deviceID status == device
          && fileID status == identity
          && fileOwner status == uid
          then closing
          else Left ControllerStdinDescriptorChanged

-- Only the existing published-family message builder consumes this operation.
-- Claiming precedes append; an interrupted offer never becomes ready again.
appendHostControllerStdin :: HostControllerStdin -> BusMessage -> BusAction ()
appendHostControllerStdin owner@(HostControllerStdin _ _ (Fd descriptor) _ _ _ _ stage) message = do
  offered <- liftInput $ modifyMVar stage offer
  case offered of
    Left _ -> throwE BusInputRefused
    Right () ->
      withContainer message 'r' "sv" $ do
        appendString message "StandardInputFileDescriptor"
        withContainer message 'v' "h" (appendDescriptor message descriptor)
 where
  offer current = case current of
    InputReady bytes -> do
      checked <- verifyDescriptor owner
      pure $ case checked of
        Left cause -> (current, Left cause)
        Right () -> (InputOffered bytes, Right ())
    InputOffered _ -> pure (current, Left ControllerStdinAlreadyOffered)
    InputSpent -> pure (current, Left ControllerStdinAlreadyAttempted)
    InputClosed -> pure (current, Left ControllerStdinClosed)

deliverHostControllerStdin :: HostControllerStdin -> IO (Either HostControllerStdinError ())
deliverHostControllerStdin (HostControllerStdin _ window _ _ _ _ writing stage) = mask $ \restore -> do
  claimed <- modifyMVar stage $ \current -> pure $ case current of
    InputReady _ -> (current, Left ControllerStdinNotOffered)
    InputOffered bytes -> (InputSpent, Right bytes)
    InputSpent -> (current, Left ControllerStdinAlreadyAttempted)
    InputClosed -> (current, Left ControllerStdinClosed)
  case claimed of
    Left cause -> pure (Left cause)
    Right bytes -> do
      attempted <-
        try
          ( restore
              ( withMVar
                  writing
                  ( maybe
                      (pure (Left ControllerStdinClosed))
                      (\writer -> writeInput (hostExecutionWorkEnd window) writer bytes)
                  )
              )
          )
      closed <- closeWriter writing
      closing <- beforeEnd (hostExecutionWorkEnd window)
      case attempted of
        Left (cause :: SomeException) -> throwIO cause
        Right result -> pure (result >> closed >> closing)

writeInput :: Word64 -> Fd -> ByteString -> IO (Either HostControllerStdinError ())
writeInput ending descriptor bytes = do
  checked <- beforeEnd ending
  case checked of
    Left cause -> pure (Left cause)
    Right ()
      | Bytes.null bytes -> pure (Right ())
      | otherwise -> do
          written <- try (PosixBytes.fdWrite descriptor (Bytes.take 4096 bytes))
          case written of
            Left cause
              | fmap Errno (ioe_errno cause) == Just eAGAIN ->
                  threadDelay 1000 >> writeInput ending descriptor bytes
            Left (cause :: IOException) -> pure (Left (ioErrorValue cause))
            Right count
              | count > 0 -> writeInput ending descriptor (Bytes.drop (fromIntegral count) bytes)
              | otherwise -> pure (Left ControllerStdinDescriptorChanged)

-- Called only after the fixed controller's actual original-parent borrow.
-- A regular file, terminal or ambient fallback is never an ingress source.
readHostControllerStdin :: Word64 -> IO (Either HostControllerStdinError ByteString)
readHostControllerStdin ending = do
  result <- ioResult $ do
    status <- getFdStatus (Fd 0)
    uid <- getEffectiveUserID
    target <- readSymbolicLink "/proc/self/fd/0"
    if not
      (isNamedPipe status && fileOwner status == uid && target == "pipe:[" <> show (fileID status) <> "]")
      then pure (Left ControllerStdinDescriptorChanged)
      else do
        now <- getMonotonicTimeNSec
        let remaining = if now >= ending then 0 else (ending - now) `div` 1000
        if remaining == 0 || toInteger remaining > toInteger (maxBound :: Int)
          then pure (Left ControllerStdinExpired)
          else do
            captured <- timeout (fromIntegral remaining) readInput
            pure $ case captured of
              Nothing -> Left ControllerStdinExpired
              Just bytes
                | Bytes.null bytes -> Left ControllerStdinEmpty
                | Bytes.length bytes > hostControllerStdinMaximumBytes -> Left ControllerStdinTooLarge
                | otherwise -> Right bytes
  closing <- beforeEnd ending
  pure (result <* closing)
 where
  readInput = BytesInternal.createAndTrim (hostControllerStdinMaximumBytes + 1) $ \buffer ->
    let loop size
          | size == hostControllerStdinMaximumBytes + 1 = pure size
          | otherwise = do
              count <-
                hGetBufSome stdin (buffer `plusPtr` size) (min 4096 (hostControllerStdinMaximumBytes + 1 - size))
              if count == 0 then pure size else loop (size + count)
     in loop 0

beforeEnd :: Word64 -> IO (Either HostControllerStdinError ())
beforeEnd ending = do
  now <- getMonotonicTimeNSec
  pure (if now < ending then Right () else Left ControllerStdinExpired)

closeWriter :: MVar (Maybe Fd) -> IO (Either HostControllerStdinError ())
closeWriter writing = mask_ $ do
  selected <- modifyMVar writing (\current -> pure (Nothing, current))
  maybe (pure (Right ())) (\fd -> ioResult (Right <$> closeFd fd)) selected

closeInput :: HostControllerStdin -> IO (Either HostControllerStdinError ())
closeInput (HostControllerStdin _ _ reader _ _ _ writing stage) = mask_ $ do
  modifyMVar_ stage (const (pure InputClosed))
  writer <- closeWriter writing
  readEnd <- ioResult (Right <$> closeFd reader)
  pure (writer >> readEnd)

ioResult :: IO (Either HostControllerStdinError value) -> IO (Either HostControllerStdinError value)
ioResult action = do
  attempted <- try action
  pure $ case attempted of
    Left (cause :: IOException) -> Left (ioErrorValue cause)
    Right value -> value

ioErrorValue :: IOException -> HostControllerStdinError
ioErrorValue cause = ControllerStdinIoRefused (ioe_type cause) (fromIntegral <$> ioe_errno cause)

liftInput :: IO value -> BusAction value
liftInput = lift
