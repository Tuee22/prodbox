{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Read-only binding of a recovered worker's existing roots. This does not
-- create resources, exclude external writers or authorize a worker.
module Prodbox.Control.KindDockerWorkerRoots
  ( KindDockerWorkerRoots
  , workerScratch
  , workerBridge
  , workerLock
  , workerRequest
  , workerReply
  , withKindDockerWorkerRoots
  , withRecoveredKindDockerWorkerRoots
  ) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Control.Monad (guard)
import Data.Bits ((.&.), (.|.))
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapScope)
import Prodbox.Config.DeploymentScope
  ( ScopeDescriptorOutcome (..)
  , validRootGeneration
  , withScopeRootDescriptorPreserving
  )
import Prodbox.Control.KindDockerEndpoint
  ( KindDockerEndpoint
  , KindDockerEndpointResult (..)
  , KindDockerRootIoFailure (..)
  , endpointLock
  , endpointReply
  , endpointRequest
  , withKindDockerEndpoint
  )
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import System.IO qualified as IO
import System.IO.Error (ioeGetErrorType)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , getFdStatus
  , isDirectory
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..), UserID)
import System.Posix.User (getEffectiveUserID)
import Text.Read (readMaybe)

foreign import capi "fcntl.h value O_PATH" pathOnly :: CInt
foreign import capi "fcntl.h value O_DIRECTORY" directoryOnly :: CInt
foreign import capi "fcntl.h value O_NOFOLLOW" noFollow :: CInt
foreign import capi "fcntl.h value O_CLOEXEC" closeOnExec :: CInt
foreign import capi "fcntl.h openat" openPathAt :: CInt -> CString -> CInt -> IO CInt

data KindDockerWorkerRoots = KindDockerWorkerRoots
  { workerScratch :: !Fd
  , workerBridge :: !Fd
  , workerLock :: !Fd
  , workerRequest :: !Fd
  , workerReply :: !Fd
  }

data Directories = Directories !Fd !Fd !Fd

data RootProgress value = RootNotStarted | RootStarted | RootReturned !value

-- | Reacquire the matching durable operation and bind its worker roots to the
-- selected deployment scope. This is still read-only: it does not admit
-- effects, exclude noncooperating writers or settle an earlier worker.
withRecoveredKindDockerWorkerRoots
  :: BootstrapProjection
  -> String
  -> (KindDockerWorkerRoots -> IO Bool -> IO value)
  -> IO (KindOperationOutcome (KindDockerEndpointResult value))
withRecoveredKindDockerWorkerRoots bootstrap operation action =
  withRecoveredKindOperation bootstrap operation $ \operationStable -> do
    observed <- withScopeRootDescriptorPreserving (bootstrapScope bootstrap) $ \root scopeStable ->
      withKindDockerWorkerRoots root operation ((&&) <$> operationStable <*> scopeStable) action
    pure $ case observed of
      ScopeDescriptorRefused _ failures -> KindDockerEndpointScopeIoRefused failures
      ScopeDescriptorCallbackFailed failure failures -> KindDockerEndpointScopeCallbackFailed failure failures
      ScopeDescriptorUnconfirmed failure failures -> KindDockerEndpointScopeUnconfirmed failure failures
      ScopeDescriptorReturned value -> value
      ScopeDescriptorCleanupFailedAfter value failures -> KindDockerEndpointScopeCleanupFailed value failures

-- | Borrow O_PATH descriptors under an already held scope root using fixed
-- operation-relative names. All entries must remain on the root's observed
-- mount. The supplied recheck must bind scope, generation and operation lease;
-- callers must also exclude external writers and settle workers separately.
withKindDockerWorkerRoots
  :: forall value
   . Fd
  -> String
  -> IO Bool
  -> (KindDockerWorkerRoots -> IO Bool -> IO value)
  -> IO (KindDockerEndpointResult value)
withKindDockerWorkerRoots root operation rootStable action
  | not (validRootGeneration operation) = pure KindDockerEndpointRefused
  | otherwise = do
      progress <- newIORef RootNotStarted
      failures <- newIORef []
      attempted <- try $ do
        owner <- getEffectiveUserID
        rootStatus <- getFdStatus root
        mount <- fdMountId root
        ready <- rootStable
        case mount of
          Nothing -> pure KindDockerEndpointRefused
          Just mountId
            | not (ready && safeDirectory owner rootStatus) -> pure KindDockerEndpointRefused
            | otherwise -> withDirectories failures $ \directories -> do
                original <- directoryStatuses directories
                valid <- directoriesValid owner rootStatus mountId directories original
                if not valid
                  then pure KindDockerEndpointRefused
                  else do
                    let stable = do
                          first <- rootStable
                          held <- directoryStatuses directories
                          matched <- withDirectories failures $ \named -> do
                            names <- directoryStatuses named
                            heldValid <- directoriesValid owner rootStatus mountId directories held
                            namedValid <- directoriesValid owner rootStatus mountId named names
                            pure (heldValid && namedValid && sameStatuses original held && sameStatuses held names)
                          lastCheck <- rootStable
                          pure (first && matched && lastCheck)
                        Directories _ scratch bridge = directories
                    endpoint <- withKindDockerEndpoint bridge stable $ \bound endpointStable ->
                      withEndpointPaths failures bridge $ \lock request reply -> do
                        let roots = KindDockerWorkerRoots scratch bridge lock request reply
                            stillBound = do
                              first <- endpointStable
                              identical <- endpointPathsMatch mountId bound roots
                              lastCheck <- endpointStable
                              pure (first && identical && lastCheck)
                        initial <- stillBound
                        if initial
                          then mask $ \restore -> do
                            writeIORef progress RootStarted
                            result <- try (restore (action roots stillBound))
                            case result of
                              Left (failure :: IOException) -> do
                                modifyIORef' failures (KindDockerRootCallbackIo (ioeGetErrorType failure) :)
                                throwIO failure
                              Right value -> do
                                writeIORef progress (RootReturned value)
                                pure (Right value)
                          else pure (Left ())
                    pure (flatten endpoint)
      current <- readIORef progress
      details <- reverse <$> readIORef failures
      pure $ case (attempted :: Either IOException (KindDockerEndpointResult value), current, details) of
        (_, RootReturned value, _ : _) -> KindDockerEndpointRootIoFailedAfter value details
        (_, RootStarted, _ : _) -> KindDockerEndpointRootIoFailed details
        (_, RootNotStarted, _ : _) -> KindDockerEndpointRootIoRefused details
        (Left _, RootNotStarted, []) -> KindDockerEndpointRefused
        (Left _, RootStarted, []) -> KindDockerEndpointUnconfirmed
        (Left _, RootReturned value, []) -> KindDockerEndpointUnconfirmedAfter value
        (Right KindDockerEndpointRefused, RootStarted, []) -> KindDockerEndpointUnconfirmed
        (Right KindDockerEndpointRefused, RootReturned value, []) -> KindDockerEndpointUnconfirmedAfter value
        (Right KindDockerEndpointUnconfirmed, RootReturned value, []) -> KindDockerEndpointUnconfirmedAfter value
        (Right result, _, []) -> result
 where
  withDirectories failures callback =
    withPath failures root ("kind-worker-" ++ operation) True $ \worker ->
      withPath failures worker "scratch" True $ \scratch ->
        withPath failures worker "bridge" True $ \bridge -> callback (Directories worker scratch bridge)

withEndpointPaths
  :: IORef [KindDockerRootIoFailure] -> Fd -> (Fd -> Fd -> Fd -> IO value) -> IO value
withEndpointPaths failures bridge callback =
  withPath failures bridge "lock" False $ \lock ->
    withPath failures bridge "request" False $ \request ->
      withPath failures bridge "reply" False $ \reply -> callback lock request reply

withPath
  :: IORef [KindDockerRootIoFailure] -> Fd -> FilePath -> Bool -> (Fd -> IO value) -> IO value
withPath failures (Fd parent) name directory =
  bracket
    ( withCString name $ \path -> Fd <$> throwErrnoIfMinus1 "open kind worker path" (openPathAt parent path flags)
    )
    closePath
 where
  flags = pathOnly .|. noFollow .|. closeOnExec .|. if directory then directoryOnly else 0
  closePath descriptor = do
    result <- try (Posix.closeFd descriptor)
    case result of
      Left (failure :: IOException) -> do
        modifyIORef' failures (KindDockerRootDescriptorCloseIo (ioeGetErrorType failure) :)
        throwIO failure
      Right () -> pure ()

directoryStatuses :: Directories -> IO [FileStatus]
directoryStatuses (Directories worker scratch bridge) = traverse getFdStatus [worker, scratch, bridge]

directoriesValid :: UserID -> FileStatus -> Int -> Directories -> [FileStatus] -> IO Bool
directoriesValid owner rootStatus mount (Directories worker scratch bridge) statuses = do
  mounts <- traverse fdMountId [worker, scratch, bridge]
  pure $
    length statuses == 3
      && all (\status -> safeDirectory owner status && deviceID status == deviceID rootStatus) statuses
      && all (== Just mount) mounts
      && case statuses of
        [a, b, c] -> not (sameIdentity a b || sameIdentity a c || sameIdentity b c)
        _ -> False

endpointPathsMatch :: Int -> KindDockerEndpoint -> KindDockerWorkerRoots -> IO Bool
endpointPathsMatch mount endpoint roots = do
  let held = [endpointLock endpoint, endpointRequest endpoint, endpointReply endpoint]
      paths = [workerLock roots, workerRequest roots, workerReply roots]
  heldStatus <- traverse getFdStatus held
  pathStatus <- traverse getFdStatus paths
  mounts <- traverse fdMountId paths
  pure (sameStatuses heldStatus pathStatus && all (== Just mount) mounts)

safeDirectory :: UserID -> FileStatus -> Bool
safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o077 == 0

sameStatuses :: [FileStatus] -> [FileStatus] -> Bool
sameStatuses left right = length left == length right && and (zipWith sameIdentity left right)

sameIdentity :: FileStatus -> FileStatus -> Bool
sameIdentity left right = deviceID left == deviceID right && fileID left == fileID right

fdMountId :: Fd -> IO (Maybe Int)
fdMountId (Fd descriptor) = IO.withBinaryFile ("/proc/self/fdinfo/" ++ show descriptor) IO.ReadMode $ \handle -> do
  bytes <- Bytes.hGet handle 4097
  pure $ do
    guard (Bytes.length bytes <= 4096)
    value <- case [ part | line <- Bytes.lines bytes, [label, part] <- [Bytes.words line], label == Bytes.pack "mnt_id:"
                  ] of
      [single] -> Just single
      _ -> Nothing
    number <- readMaybe (Bytes.unpack value)
    guard (number > 0)
    pure number

flatten :: KindDockerEndpointResult (Either () value) -> KindDockerEndpointResult value
flatten result = case result of
  KindDockerEndpointRefused -> KindDockerEndpointRefused
  KindDockerEndpointObserved (Left ()) -> KindDockerEndpointRefused
  KindDockerEndpointObserved (Right value) -> KindDockerEndpointObserved value
  KindDockerEndpointChanged (Left ()) -> KindDockerEndpointRefused
  KindDockerEndpointChanged (Right value) -> KindDockerEndpointChanged value
  KindDockerEndpointUnconfirmed -> KindDockerEndpointUnconfirmed
  KindDockerEndpointUnconfirmedAfter (Left ()) -> KindDockerEndpointUnconfirmed
  KindDockerEndpointUnconfirmedAfter (Right value) -> KindDockerEndpointUnconfirmedAfter value
  KindDockerEndpointRootIoFailed failures -> KindDockerEndpointRootIoFailed failures
  KindDockerEndpointRootIoRefused failures -> KindDockerEndpointRootIoRefused failures
  KindDockerEndpointRootIoFailedAfter (Left ()) failures -> KindDockerEndpointRootIoFailed failures
  KindDockerEndpointRootIoFailedAfter (Right value) failures -> KindDockerEndpointRootIoFailedAfter value failures
  KindDockerEndpointScopeIoRefused failures -> KindDockerEndpointScopeIoRefused failures
  KindDockerEndpointScopeCallbackFailed failure failures -> KindDockerEndpointScopeCallbackFailed failure failures
  KindDockerEndpointScopeUnconfirmed failure failures -> KindDockerEndpointScopeUnconfirmed failure failures
  KindDockerEndpointScopeCleanupFailed value failures -> KindDockerEndpointScopeCleanupFailed (flatten value) failures
