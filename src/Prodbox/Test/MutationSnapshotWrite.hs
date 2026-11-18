{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Write snapshot inputs beneath a freshly created descriptor-relative root.
-- This is not an isolation, snapshot-authentication or cleanup proof.
module Prodbox.Test.MutationSnapshotWrite
  ( MutationSnapshotWriteResult (..)
  , MutationSnapshotRootIdentity (..)
  , mutationSnapshotRootIdentity
  , writeMutationSnapshot
  ) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Control.Monad (forM_, unless)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.DeploymentScope (validRootGeneration)
import Prodbox.Test.MutationOutputInventory (mutationWorkspaceSameMount)
import Prodbox.Test.MutationSnapshot
  ( MutationSnapshot
  , MutationSnapshotFile (..)
  , mutationSnapshotFiles
  )
import System.FilePath.Posix (splitDirectories)
import System.IO.Error (isAlreadyExistsError, isEOFError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , isDirectory
  , isRegularFile
  , linkCount
  , setFdMode
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "sys/stat.h mkdirat"
  makeSnapshotDirectoryAt :: CInt -> CString -> CMode -> IO CInt

data MutationSnapshotRootIdentity = MutationSnapshotRootIdentity !Integer !Integer
  deriving (Eq, Show)

mutationSnapshotRootIdentity :: FileStatus -> MutationSnapshotRootIdentity
mutationSnapshotRootIdentity status = MutationSnapshotRootIdentity (toInteger (deviceID status)) (toInteger (fileID status))

data MutationSnapshotWriteResult
  = MutationSnapshotWritten !MutationSnapshotRootIdentity
  | MutationSnapshotWriteInvalid
  | MutationSnapshotWriteExists
  | MutationSnapshotWriteIncomplete
  | MutationSnapshotWriteUnobservable
  | MutationSnapshotWriteTimedOut
  deriving (Eq, Show)

-- | The caller owns and authenticates the parent descriptor, chooses a fresh
-- operation ID, retains it for recovery, and independently verifies the whole
-- workspace and cleanup. Failure after root creation leaves that root intact.
-- No worker may run solely because this function returns Written.
writeMutationSnapshot :: Fd -> String -> MutationSnapshot -> IO MutationSnapshotWriteResult
writeMutationSnapshot parent operation snapshot
  | not (validRootGeneration operation) = pure MutationSnapshotWriteInvalid
  | otherwise = do
      started <- newIORef False
      owner <- getEffectiveUserID
      observed <- timeout (120 * 1000000) $ try $ do
        initial <- getFdStatus parent
        unless (safeDirectory owner initial) (ioError (userError "unsafe snapshot parent"))
        mask $ \restore -> do
          created <- try (mkdir parent operation)
          case created of
            Left (failure :: IOException)
              | isAlreadyExistsError failure -> pure MutationSnapshotWriteExists
              | otherwise -> throwIO failure
            Right () -> do
              writeIORef started True
              restore $ do
                fileSynchronise parent
                bracket (openDirectory parent operation) Posix.closeFd $ \root -> do
                  rootInitial <- getFdStatus root
                  rootMount <- mutationWorkspaceSameMount parent root
                  unless (safeDirectory owner rootInitial && deviceID rootInitial == deviceID initial && rootMount) $
                    ioError (userError "unsafe snapshot root")
                  forM_ (mutationSnapshotFiles snapshot) (writeSnapshotFile owner root)
                  fileSynchronise root
                  currentRoot <- getFdStatus root
                  (namedRoot, namedMount) <- bracket (openDirectory parent operation) Posix.closeFd $ \named ->
                    (,) <$> getFdStatus named <*> mutationWorkspaceSameMount parent named
                  currentParent <- getFdStatus parent
                  unless
                    ( sameIdentity rootInitial currentRoot
                        && sameIdentity currentRoot namedRoot
                        && namedMount
                        && sameIdentity initial currentParent
                        && safeDirectory owner currentRoot
                        && safeDirectory owner currentParent
                    )
                    $ ioError (userError "snapshot root changed")
                  pure (MutationSnapshotWritten (mutationSnapshotRootIdentity currentRoot))
      wasStarted <- readIORef started
      pure $ case observed of
        Nothing -> if wasStarted then MutationSnapshotWriteIncomplete else MutationSnapshotWriteTimedOut
        Just (Left (_ :: IOException)) -> if wasStarted then MutationSnapshotWriteIncomplete else MutationSnapshotWriteUnobservable
        Just (Right result) -> result

writeSnapshotFile :: UserID -> Fd -> MutationSnapshotFile -> IO ()
writeSnapshotFile owner root entry = case reverse (splitDirectories (Text.unpack (snapshotFilePath entry))) of
  [] -> ioError (userError "empty snapshot path")
  name : parents -> descend root (reverse parents) name
 where
  descend current parents name = case parents of
    [] -> writeFileAt current name
    component : remaining -> do
      made <- try (mkdir current component)
      case made of
        Left (failure :: IOException) | not (isAlreadyExistsError failure) -> throwIO failure
        _ -> pure ()
      bracket (openDirectory current component) Posix.closeFd $ \next -> do
        parentStatus <- getFdStatus current
        childStatus <- getFdStatus next
        sameMount <- mutationWorkspaceSameMount current next
        unless
          (safeDirectory owner childStatus && deviceID childStatus == deviceID parentStatus && sameMount)
          $ ioError (userError "unsafe snapshot directory")
        descend next remaining name
  writeFileAt directory name = do
    let flags =
          Posix.defaultFileFlags
            { Posix.creat = Just 0o600
            , Posix.exclusive = True
            , Posix.nofollow = True
            , Posix.cloexec = True
            }
        bytes = snapshotFileBytes entry
        mode = if snapshotFileMode entry .&. 0o100 == 0 then 0o600 else 0o700
    bracket (Posix.openFdAt (Just directory) name Posix.WriteOnly flags) Posix.closeFd $ \file -> do
      sameMount <- mutationWorkspaceSameMount directory file
      unless sameMount (ioError (userError "unsafe snapshot file mount"))
      writeAll file bytes
      setFdMode file mode
      fileSynchronise file
      written <- getFdStatus file
      unless (safeFile owner mode bytes written) (ioError (userError "unsafe snapshot file"))
      bracket (Posix.openFdAt (Just directory) name Posix.ReadOnly readFlags) Posix.closeFd $ \check -> do
        checked <- getFdStatus check
        checkedMount <- mutationWorkspaceSameMount directory check
        actual <- readExact check (ByteString.length bytes)
        final <- getFdStatus check
        unless
          ( safeFile owner mode bytes checked
              && safeFile owner mode bytes final
              && sameIdentity written checked
              && sameIdentity checked final
              && checkedMount
              && actual == bytes
          )
          $ ioError (userError "snapshot readback differs")
      fileSynchronise directory

mkdir :: Fd -> FilePath -> IO ()
mkdir (Fd parent) name = withCString name $ \component ->
  throwErrnoIfMinus1_
    "create mutation snapshot directory"
    (makeSnapshotDirectoryAt parent component 0o700)

openDirectory :: Fd -> FilePath -> IO Fd
openDirectory parent name = Posix.openFdAt (Just parent) name Posix.ReadOnly directoryFlags

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}

readFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

safeDirectory :: UserID -> FileStatus -> Bool
safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o077 == 0

safeFile :: UserID -> CMode -> ByteString.ByteString -> FileStatus -> Bool
safeFile owner mode bytes status =
  isRegularFile status
    && fileOwner status == owner
    && fileMode status .&. 0o777 == mode
    && linkCount status == 1
    && fileSize status == fromIntegral (ByteString.length bytes)

sameIdentity :: FileStatus -> FileStatus -> Bool
sameIdentity left right = deviceID left == deviceID right && fileID left == fileID right

writeAll :: Fd -> ByteString.ByteString -> IO ()
writeAll descriptor bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      count <- PosixBytes.fdWrite descriptor bytes
      if count <= 0
        then ioError (userError "short snapshot write")
        else writeAll descriptor (ByteString.drop (fromIntegral count) bytes)

readExact :: Fd -> Int -> IO ByteString.ByteString
readExact descriptor limit = go [] 0
 where
  go chunks count
    | count > limit = ioError (userError "snapshot file grew")
    | otherwise = do
        result <- try (PosixBytes.fdRead descriptor (fromIntegral (min 65535 (limit - count) + 1)))
        case result of
          Left (failure :: IOException) | isEOFError failure -> pure (ByteString.concat (reverse chunks))
          Left failure -> throwIO failure
          Right bytes
            | ByteString.null bytes -> pure (ByteString.concat (reverse chunks))
            | otherwise -> go (bytes : chunks) (count + ByteString.length bytes)
