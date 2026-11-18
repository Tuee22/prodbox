{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Descriptor-bound observations for an already prepared Docker bridge.
-- This module does not create endpoints, confine processes, or authorize work.
module Prodbox.Control.KindDockerEndpoint
  ( KindDockerEndpoint
  , endpointLock
  , endpointRequest
  , endpointReply
  , KindDockerEndpointResult (..)
  , KindDockerRootIoFailure (..)
  , withKindDockerEndpoint
  , exchangeBoundKindDockerRead
  , exchangeBoundKindDockerRequest
  , serveBoundKindDockerReads
  , serveBoundKindDockerRequests
  , serveBoundKindDockerInputRequests
  , KindDockerBrokerExit (..)
  , KindDockerWorkerExit (..)
  , runBoundKindDockerReadWorker
  , runBoundKindDockerWorker
  ) where

import Control.Concurrent.Async (AsyncCancelled (..), cancel, waitCatch, waitEitherCatch, withAsync)
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , finally
  , fromException
  , mask
  , onException
  , try
  )
import Data.Bits ((.&.))
import Data.IORef (newIORef, readIORef, writeIORef)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.DeploymentScope (ScopeDescriptorIoFailure)
import Prodbox.Control.DockerConnectedInfo (DockerSession)
import Prodbox.Control.KindDockerReadGate
  ( KindDockerReadGate
  , KindDockerReply
  , closeKindDockerReadGate
  )
import Prodbox.Control.KindDockerReadProtocol
  ( KindDockerClientFailure
  , KindDockerProtocolOutcome
  , KindDockerRequest (..)
  , exchangeSerializedKindDockerRequest
  , serveKindDockerInputRequestsWhile
  , serveKindDockerReadsWhile
  , serveKindDockerRequestsWhile
  )
import System.IO qualified as IO
import System.IO.Error (IOErrorType)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , getFdStatus
  , isDirectory
  , isNamedPipe
  , isRegularFile
  , linkCount
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..), UserID)
import System.Posix.User (getEffectiveUserID)

foreign import capi "fcntl.h value F_DUPFD_CLOEXEC" duplicateCloseOnExec :: CInt
foreign import capi "fcntl.h fcntl" duplicateDescriptor :: CInt -> CInt -> CInt -> IO CInt

data KindDockerEndpoint = KindDockerEndpoint
  { endpointLock :: !Fd
  , endpointRequest :: !Fd
  , endpointReply :: !Fd
  }

data KindDockerEndpointResult value
  = KindDockerEndpointRefused
  | KindDockerEndpointObserved !value
  | KindDockerEndpointChanged !value
  | KindDockerEndpointUnconfirmed
  | KindDockerEndpointUnconfirmedAfter !value
  | KindDockerEndpointRootIoRefused ![KindDockerRootIoFailure]
  | KindDockerEndpointRootIoFailed ![KindDockerRootIoFailure]
  | KindDockerEndpointRootIoFailedAfter !value ![KindDockerRootIoFailure]
  | KindDockerEndpointScopeIoRefused ![ScopeDescriptorIoFailure]
  | KindDockerEndpointScopeCallbackFailed !IOErrorType ![ScopeDescriptorIoFailure]
  | KindDockerEndpointScopeUnconfirmed !IOErrorType ![ScopeDescriptorIoFailure]
  | KindDockerEndpointScopeCleanupFailed !(KindDockerEndpointResult value) ![ScopeDescriptorIoFailure]
  deriving (Eq, Show)

-- | Error categories omit paths and exception text. These observations are
-- independent of resource settlement or lifecycle recovery.
data KindDockerRootIoFailure
  = KindDockerRootCallbackIo !IOErrorType
  | KindDockerRootDescriptorCloseIo !IOErrorType
  deriving (Eq, Show)

data Progress value = NotStarted | Started | Returned !value

-- | Borrow three independently opened, no-follow descriptors from an explicit
-- directory. The caller supplies a separate root-identity recheck and must
-- confine all writers, bind every client to this directory, impose deadlines,
-- settle workers and handle recovery. Rechecks are observations, not exclusion.
withKindDockerEndpoint
  :: Fd
  -> IO Bool
  -> (KindDockerEndpoint -> IO Bool -> IO value)
  -> IO (KindDockerEndpointResult value)
withKindDockerEndpoint directory rootStable action = do
  progress <- newIORef NotStarted
  attempted <- try $ mask $ \restore -> do
    owner <- getEffectiveUserID
    root <- getFdStatus directory
    ready <- rootStable
    if not (ready && validDirectory owner root)
      then pure (Left ())
      else withEntries $ \endpoint -> do
        initial <- traverse getFdStatus (endpointDescriptors endpoint)
        if not (validEntries owner root initial)
          then pure (Left ())
          else do
            let stable = verify owner root initial endpoint
            before <- stable
            if not before
              then pure (Left ())
              else do
                writeIORef progress Started
                value <- restore (action endpoint stable)
                writeIORef progress (Returned value)
                after <- stable
                pure (Right (value, after))
  case attempted of
    Right (Left ()) -> pure KindDockerEndpointRefused
    Right (Right (value, True)) -> pure (KindDockerEndpointObserved value)
    Right (Right (value, False)) -> pure (KindDockerEndpointChanged value)
    Left (_ :: IOException) -> do
      current <- readIORef progress
      pure $ case current of
        NotStarted -> KindDockerEndpointRefused
        Started -> KindDockerEndpointUnconfirmed
        Returned value -> KindDockerEndpointUnconfirmedAfter value
 where
  flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  withEntry name = bracket (Posix.openFdAt (Just directory) name Posix.ReadWrite flags) Posix.closeFd
  withEntries callback =
    withEntry "lock" $ \lock ->
      withEntry "request" $ \request ->
        withEntry "reply" $ \reply -> callback (KindDockerEndpoint lock request reply)
  verify owner originalRoot originals endpoint = do
    first <- rootStable
    currentRoot <- getFdStatus directory
    held <- traverse getFdStatus (endpointDescriptors endpoint)
    named <- withEntries (traverse getFdStatus . endpointDescriptors)
    lastRoot <- rootStable
    pure $
      first
        && lastRoot
        && validDirectory owner currentRoot
        && sameIdentity originalRoot currentRoot
        && validEntries owner currentRoot held
        && validEntries owner currentRoot named
        && and (zipWith sameIdentity originals held)
        && and (zipWith sameIdentity held named)

endpointDescriptors :: KindDockerEndpoint -> [Fd]
endpointDescriptors endpoint = [endpointLock endpoint, endpointRequest endpoint, endpointReply endpoint]

validDirectory :: UserID -> FileStatus -> Bool
validDirectory owner status =
  isDirectory status && fileOwner status == owner && fileMode status .&. 0o077 == 0

validEntries :: UserID -> FileStatus -> [FileStatus] -> Bool
validEntries owner root statuses = case statuses of
  [lock, request, reply] ->
    valid isRegularFile lock
      && valid isNamedPipe request
      && valid isNamedPipe reply
      && fileID request /= fileID reply
  _ -> False
 where
  valid kind status =
    kind status
      && deviceID status == deviceID root
      && fileOwner status == owner
      && fileMode status .&. 0o077 == 0
      && linkCount status == 1

sameIdentity :: FileStatus -> FileStatus -> Bool
sameIdentity left right = deviceID left == deviceID right && fileID left == fileID right

-- | Exchange through independently opened endpoint descriptors. Rechecks
-- detect changes but do not exclude them: the caller must confine writers,
-- bind the root, settle the peer, and recover any retained in-flight marker.
exchangeBoundKindDockerRead
  :: Int
  -> Fd
  -> IO Bool
  -> [String]
  -> IO (KindDockerEndpointResult (Either KindDockerClientFailure KindDockerReply))
exchangeBoundKindDockerRead limit directory rootStable argv =
  exchangeBoundKindDockerRequest limit directory rootStable (KindDockerRequest argv mempty)

exchangeBoundKindDockerRequest
  :: Int
  -> Fd
  -> IO Bool
  -> KindDockerRequest
  -> IO (KindDockerEndpointResult (Either KindDockerClientFailure KindDockerReply))
exchangeBoundKindDockerRequest limit directory rootStable request =
  withKindDockerEndpoint directory rootStable $ \endpoint _ ->
    withEndpointHandle (endpointReply endpoint) $ \input ->
      withEndpointHandle (endpointRequest endpoint) $ \output -> do
        IO.hSetBuffering input IO.NoBuffering
        IO.hSetBuffering output IO.NoBuffering
        exchangeSerializedKindDockerRequest limit (endpointLock endpoint) input output request

-- | Serve only while the held endpoints remain observable. The caller must
-- separately exclude writers, bound the worker and settle it on all exits.
serveBoundKindDockerReads
  :: Fd
  -> IO Bool
  -> KindDockerReadGate
  -> DockerSession
  -> String
  -> IO (KindDockerEndpointResult KindDockerProtocolOutcome)
serveBoundKindDockerReads directory rootStable gate session daemon =
  action `finally` closeKindDockerReadGate gate
 where
  action = withKindDockerEndpoint directory rootStable $ \endpoint stable ->
    withEndpointHandle (endpointRequest endpoint) $ \input ->
      withEndpointHandle (endpointReply endpoint) $ \output -> do
        IO.hSetBuffering input IO.NoBuffering
        IO.hSetBuffering output IO.NoBuffering
        serveKindDockerReadsWhile stable gate session daemon input output

-- | Borrow the same verified endpoints for a supplied interpreter. The caller
-- must serialize requests and provide admission, settlement and recovery.
serveBoundKindDockerRequests
  :: Fd
  -> IO Bool
  -> ([String] -> IO KindDockerReply)
  -> IO ()
  -> IO (KindDockerEndpointResult KindDockerProtocolOutcome)
serveBoundKindDockerRequests directory rootStable interpret closeGate =
  action `finally` closeGate
 where
  action = withKindDockerEndpoint directory rootStable $ \endpoint stable ->
    withEndpointHandle (endpointRequest endpoint) $ \input ->
      withEndpointHandle (endpointReply endpoint) $ \output -> do
        IO.hSetBuffering input IO.NoBuffering
        IO.hSetBuffering output IO.NoBuffering
        serveKindDockerRequestsWhile stable interpret closeGate input output

-- | Input-capable framing retains the same descriptor and endpoint checks;
-- the supplied interpreter must separately admit and recover every effect.
serveBoundKindDockerInputRequests
  :: Fd
  -> IO Bool
  -> (KindDockerRequest -> IO KindDockerReply)
  -> IO ()
  -> IO (KindDockerEndpointResult KindDockerProtocolOutcome)
serveBoundKindDockerInputRequests directory rootStable interpret closeGate =
  action `finally` closeGate
 where
  action = withKindDockerEndpoint directory rootStable $ \endpoint stable ->
    withEndpointHandle (endpointRequest endpoint) $ \input ->
      withEndpointHandle (endpointReply endpoint) $ \output -> do
        IO.hSetBuffering input IO.NoBuffering
        IO.hSetBuffering output IO.NoBuffering
        serveKindDockerInputRequestsWhile stable interpret closeGate input output

-- | The caller must inspect both outcomes. Cancellation here settles these
-- Haskell actions only; it is not proof that a daemon-side effect or a
-- separately spawned process has settled.
data KindDockerBrokerExit
  = KindDockerBrokerCancelled
  | KindDockerBrokerReturned !(KindDockerEndpointResult KindDockerProtocolOutcome)
  | KindDockerBrokerFailed !SomeException
  deriving (Show)

data KindDockerWorkerExit value
  = KindDockerWorkerCancelled
  | KindDockerWorkerReturned !value
  | KindDockerWorkerFailed !SomeException
  deriving (Show)

-- | Run one bounded worker against a bound read-only broker. If either action
-- finishes first, cancel and wait for the other, preserving both observations
-- even when they finish concurrently. The caller must bound both actions,
-- ensure cancellation settles the actual worker, authenticate the daemon,
-- exclude writers, and retain any in-flight marker for recovery. This is not
-- lifecycle admission or authorization for provider mutations.
runBoundKindDockerReadWorker
  :: Fd
  -> IO Bool
  -> KindDockerReadGate
  -> DockerSession
  -> String
  -> IO value
  -> IO (KindDockerBrokerExit, KindDockerWorkerExit value)
runBoundKindDockerReadWorker directory stable gate session daemon action =
  runBoundKindDockerWorker (serveBoundKindDockerReads directory stable gate session daemon) action

-- | Settle the Haskell broker and worker actions together. A caller must
-- separately bound and settle any processes or provider effects they start.
runBoundKindDockerWorker
  :: IO (KindDockerEndpointResult KindDockerProtocolOutcome)
  -> IO value
  -> IO (KindDockerBrokerExit, KindDockerWorkerExit value)
runBoundKindDockerWorker serve action =
  withAsync serve $ \broker ->
    withAsync action $ \worker -> do
      first <- waitEitherCatch broker worker
      case first of
        Left brokerResult -> do
          cancel worker
          workerResult <- waitCatch worker
          pure (brokerExit brokerResult, workerExit workerResult)
        Right workerResult -> do
          cancel broker
          brokerResult <- waitCatch broker
          pure (brokerExit brokerResult, workerExit workerResult)
 where
  brokerExit result = case result of
    Right value -> KindDockerBrokerReturned value
    Left failure -> case fromException failure of
      Just AsyncCancelled -> KindDockerBrokerCancelled
      Nothing -> KindDockerBrokerFailed failure
  workerExit result = case result of
    Right value -> KindDockerWorkerReturned value
    Left failure -> case fromException failure of
      Just AsyncCancelled -> KindDockerWorkerCancelled
      Nothing -> KindDockerWorkerFailed failure

withEndpointHandle :: Fd -> (IO.Handle -> IO value) -> IO value
withEndpointHandle descriptor = bracket (duplicateHandle descriptor) IO.hClose

duplicateHandle :: Fd -> IO IO.Handle
duplicateHandle (Fd descriptor) = mask $ \restore -> do
  duplicate <-
    Fd
      <$> throwErrnoIfMinus1
        "duplicate kind Docker endpoint"
        (duplicateDescriptor descriptor duplicateCloseOnExec 3)
  restore (Posix.fdToHandle duplicate) `onException` Posix.closeFd duplicate
