{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Prepare only fresh local worker paths after a durable kind intent. This is
-- not admission for a provider effect or proof that a worker has settled.
module Prodbox.Control.KindDockerWorkerPrepare
  ( KindDockerWorkerPreparation (..)
  , KindDockerClientLinkPreparation (..)
  , KindDockerClientLinkRemoval (..)
  , prepareNewKindDockerWorker
  , prepareKindDockerWorkerPaths
  , prepareKindDockerClientLink
  , removeKindDockerClientLink
  ) where

import Control.Exception (IOException, bracket, mask, try)
import Control.Monad (unless)
import Data.Bits ((.&.))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , validRootGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Control.KindDockerEndpoint (KindDockerEndpointResult (KindDockerEndpointObserved))
import Prodbox.Control.KindDockerWorkerRoots
  ( KindDockerWorkerRoots
  , withKindDockerWorkerRoots
  , workerBridge
  )
import Prodbox.Control.KindLease (KindOperationOutcome, withNewKindOperation)
import Prodbox.Control.SealedTool (isSealedToolDescriptor)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files
  ( deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , linkCount
  , readSymbolicLink
  , setFdMode
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (CMode (..), Fd (..))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "sys/stat.h mkdirat" makeDirectoryAt :: CInt -> CString -> CMode -> IO CInt
foreign import capi "sys/stat.h mkfifoat" makeFifoAt :: CInt -> CString -> CMode -> IO CInt
foreign import capi "unistd.h symlinkat" makeSymbolicLinkAt :: CString -> CInt -> CString -> IO CInt
foreign import capi "unistd.h unlinkat" unlinkAt :: CInt -> CString -> CInt -> IO CInt

data KindDockerWorkerPreparation
  = KindDockerWorkerPrepared
  | KindDockerWorkerAlreadyExists
  | KindDockerWorkerPreparationRefused
  | KindDockerWorkerPreparationIncomplete
  deriving (Eq, Show)

data KindDockerClientLinkPreparation
  = KindDockerClientLinkPrepared
  | KindDockerClientLinkAlreadyExists
  | KindDockerClientLinkRefused
  | KindDockerClientLinkIncomplete
  deriving (Eq, Show)

data KindDockerClientLinkRemoval
  = KindDockerClientLinkRemoved
  | KindDockerClientLinkAbsent
  | KindDockerClientLinkRemovalRefused
  | KindDockerClientLinkRemovalIncomplete
  deriving (Eq, Show)

-- | Remove only the exact link to the still-held sealed client. The caller
-- must hold the operation lease, exclude other writers, confirm that the
-- worker and broker have settled and retain any unresolved marker. This is
-- not recovery of a stale descriptor after a crash or proof of settlement.
removeKindDockerClientLink
  :: KindDockerWorkerRoots -> Fd -> IO Bool -> IO KindDockerClientLinkRemoval
removeKindDockerClientLink roots client stable = do
  touched <- newIORef False
  result <- timeout 10000000 $ try @IOException $ do
    let bridge = workerBridge roots
        Fd number = client
        target = "/proc/self/fd/" ++ show number
        named = "/proc/self/fd/" ++ show bridge ++ "/docker"
        flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
    sealed <- isSealedToolDescriptor client
    protected <- Posix.queryFdOption client Posix.CloseOnExec
    ready <- stable
    if number < 3 || not (sealed && protected && ready)
      then pure KindDockerClientLinkRemovalRefused
      else bracket (Posix.openFdAt (Just bridge) "." Posix.ReadOnly flags) Posix.closeFd $ \directory -> do
        original <- getFdStatus bridge
        opened <- getFdStatus directory
        if deviceID original /= deviceID opened || fileID original /= fileID opened
          then pure KindDockerClientLinkRemovalRefused
          else mask $ \_ -> do
            first <- try (getSymbolicLinkStatus named)
            case first of
              Left (failure :: IOException)
                | isDoesNotExistError failure -> pure KindDockerClientLinkAbsent
                | otherwise -> ioError failure
              Right before -> do
                owner <- getEffectiveUserID
                actual <- if isSymbolicLink before then readSymbolicLink named else pure ""
                after <- getSymbolicLinkStatus named
                stillReady <- stable
                let safe status = isSymbolicLink status && fileOwner status == owner && linkCount status == 1
                if not
                  ( stillReady
                      && safe before
                      && safe after
                      && deviceID before == deviceID after
                      && fileID before == fileID after
                      && actual == target
                  )
                  then pure KindDockerClientLinkRemovalRefused
                  else do
                    let Fd parent = directory
                    withCString "docker" $ \name -> throwErrnoIfMinus1_ "remove kind Docker client link" (unlinkAt parent name 0)
                    writeIORef touched True
                    fileSynchronise directory
                    readback <- try (getSymbolicLinkStatus named)
                    final <- stable
                    pure $ case readback of
                      Left (failure :: IOException) | isDoesNotExistError failure && final -> KindDockerClientLinkRemoved
                      _ -> KindDockerClientLinkRemovalIncomplete
  changed <- readIORef touched
  pure $ case result of
    Just (Right value) -> value
    _ | changed -> KindDockerClientLinkRemovalIncomplete
    _ -> KindDockerClientLinkRemovalRefused

-- | Create a link to the held sealed client descriptor in an already bound
-- worker bridge. The caller must authenticate and fund the client bytes, hold
-- the operation lease, exclude other writers, retain this descriptor at the
-- same number in the worker, and settle the worker before recovering the
-- link. Existing links are never adopted or replaced. A link left after a
-- crash is not evidence that its descriptor or worker still exists.
prepareKindDockerClientLink
  :: KindDockerWorkerRoots -> Fd -> IO Bool -> IO KindDockerClientLinkPreparation
prepareKindDockerClientLink roots client stable = do
  touched <- newIORef False
  result <- timeout 10000000 $ try @IOException $ do
    let bridge = workerBridge roots
        Fd number = client
        target = "/proc/self/fd/" ++ show number
        named = "/proc/self/fd/" ++ show bridge ++ "/docker"
        directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
    sealed <- isSealedToolDescriptor client
    protected <- Posix.queryFdOption client Posix.CloseOnExec
    ready <- stable
    if number < 3 || not (sealed && protected && ready)
      then pure KindDockerClientLinkRefused
      else bracket (Posix.openFdAt (Just bridge) "." Posix.ReadOnly directoryFlags) Posix.closeFd $ \directory -> do
        original <- getFdStatus bridge
        opened <- getFdStatus directory
        if deviceID original /= deviceID opened || fileID original /= fileID opened
          then pure KindDockerClientLinkRefused
          else mask $ \_ -> do
            stillReady <- stable
            if not stillReady
              then pure KindDockerClientLinkRefused
              else do
                created <- try $ withCString target $ \destination -> withCString "docker" $ \name ->
                  throwErrnoIfMinus1_
                    "create kind Docker client link"
                    (makeSymbolicLinkAt destination (fdNumber directory) name)
                case created of
                  Left (failure :: IOException)
                    | isAlreadyExistsError failure -> pure KindDockerClientLinkAlreadyExists
                    | otherwise -> ioError failure
                  Right () -> do
                    writeIORef touched True
                    fileSynchronise directory
                    owner <- getEffectiveUserID
                    first <- getSymbolicLinkStatus named
                    actual <- readSymbolicLink named
                    second <- getSymbolicLinkStatus named
                    final <- stable
                    pure $
                      if final
                        && isSymbolicLink first
                        && fileOwner first == owner
                        && linkCount first == 1
                        && isSymbolicLink second
                        && fileOwner second == owner
                        && linkCount second == 1
                        && deviceID first == deviceID second
                        && fileID first == fileID second
                        && actual == target
                        then KindDockerClientLinkPrepared
                        else KindDockerClientLinkIncomplete
  changed <- readIORef touched
  pure $ case result of
    Just (Right value) -> value
    _ | changed -> KindDockerClientLinkIncomplete
    _ -> KindDockerClientLinkRefused
 where
  fdNumber (Fd descriptor) = descriptor

-- | Write the operation intent before any worker-path creation. Existing
-- intents require recovery and are never silently adopted.
prepareNewKindDockerWorker
  :: BootstrapProjection -> String -> IO (KindOperationOutcome KindDockerWorkerPreparation)
prepareNewKindDockerWorker bootstrap operation =
  withNewKindOperation bootstrap operation (prepareKindDockerWorkerPaths bootstrap operation)

-- | Create only absent fixed names beneath the selected scope. The caller must
-- hold the operation lease, durable intent and writer exclusion, and supply a
-- recheck. Incomplete work is retained for explicit recovery, never removed
-- here. This does not admit a Docker effect, authenticate a peer, or settle a
-- previous worker.
prepareKindDockerWorkerPaths
  :: BootstrapProjection -> String -> IO Bool -> IO KindDockerWorkerPreparation
prepareKindDockerWorkerPaths bootstrap operation recheck
  | not (validRootGeneration operation) = pure KindDockerWorkerPreparationRefused
  | otherwise = do
      touched <- newIORef False
      result <- timeout 10000000 $ try @IOException $ withScopeRootDescriptor scope $ \root sameRoot -> do
        owner <- getEffectiveUserID
        let stable = do
              same <- sameRoot
              generationState <- observeScopeGeneration scope generation
              allowed <- recheck
              pure (same && generationState == Right ScopeGenerationMatches && allowed)
            requireStable = stable >>= \ready -> unless ready (ioError (userError "kind worker scope changed"))
            createDirectory parent name = withCString name $ \encoded ->
              throwErrnoIfMinus1_ "create kind worker directory" (makeDirectoryAt (fdNumber parent) encoded 0o700)
            createFifo parent name = withCString name $ \encoded ->
              throwErrnoIfMinus1_ "create kind worker FIFO" (makeFifoAt (fdNumber parent) encoded 0o600)
            withDirectory parent name callback =
              bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly directoryFlags) Posix.closeFd $ \directory -> do
                status <- getFdStatus directory
                unless
                  (isDirectory status && fileOwner status == owner && fileMode status .&. 0o077 == 0)
                  (ioError (userError "unsafe kind worker directory"))
                callback directory
            makeAndSync parent name create = mask $ \_ -> do
              requireStable
              _ <- create parent name
              writeIORef touched True
              fileSynchronise parent
        rootStatus <- getFdStatus root
        if not (isDirectory rootStatus && fileOwner rootStatus == owner && fileMode rootStatus .&. 0o077 == 0)
          then pure KindDockerWorkerPreparationRefused
          else do
            requireStable
            created <- mask $ \_ -> do
              result <- try (createDirectory root workerName)
              case result of
                Right () -> writeIORef touched True >> fileSynchronise root >> pure True
                Left (failure :: IOException)
                  | isAlreadyExistsError failure -> pure False
                  | otherwise -> ioError failure
            if not created
              then pure KindDockerWorkerAlreadyExists
              else withDirectory root workerName $ \worker -> do
                makeAndSync worker "scratch" createDirectory
                makeAndSync worker "bridge" createDirectory
                withDirectory worker "bridge" $ \bridge -> do
                  mask $ \_ -> do
                    requireStable
                    bracket (Posix.openFdAt (Just bridge) "lock" Posix.ReadWrite lockFlags) Posix.closeFd $ \lock -> do
                      status <- getFdStatus lock
                      unless
                        (isRegularFile status && fileOwner status == owner && linkCount status == 1 && fileSize status == 0)
                        (ioError (userError "unsafe new kind worker lock"))
                      setFdMode lock 0o600
                      fileSynchronise lock
                    fileSynchronise bridge
                  makeAndSync bridge "request" createFifo
                  makeAndSync bridge "reply" createFifo
                  checked <- withKindDockerWorkerRoots root operation stable (\_ _ -> pure ())
                  pure $
                    if checked == KindDockerEndpointObserved ()
                      then KindDockerWorkerPrepared
                      else KindDockerWorkerPreparationIncomplete
      changed <- readIORef touched
      pure $ case result of
        Just (Right (Right prepared)) -> prepared
        _ | changed -> KindDockerWorkerPreparationIncomplete
        _ -> KindDockerWorkerPreparationRefused
 where
  scope = bootstrapScope bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  workerName = "kind-worker-" ++ operation
  fdNumber (Fd descriptor) = descriptor
  directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
  lockFlags =
    Posix.defaultFileFlags
      { Posix.nofollow = True
      , Posix.cloexec = True
      , Posix.exclusive = True
      , Posix.creat = Just 0o600
      }
