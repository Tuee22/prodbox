{-# LANGUAGE ScopedTypeVariables #-}

-- | Read-only snapshot inventory comparison on a held parent descriptor.
-- This is a point-in-time observation, not an isolation or execution permit.
module Prodbox.Test.MutationSnapshotObserve
  ( MutationSnapshotObservation (..)
  , observeMutationSnapshot
  , observeMutationSnapshotBefore
  ) where

import Control.Exception (IOException, bracket, throwIO, try)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Config.DeploymentScope (validRootGeneration)
import Prodbox.Test.MutationOutputInventory (mutationWorkspaceSameMount)
import Prodbox.Test.MutationSnapshot
  ( MutationSnapshot
  , MutationSnapshotFile (..)
  , mutationSnapshotFiles
  )
import System.FilePath.Posix (splitDirectories, (</>))
import System.IO.Error (isEOFError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
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
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (CMode, Fd (..), UserID)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data MutationSnapshotObservation
  = MutationSnapshotMatches
  | MutationSnapshotDiffers
  | MutationSnapshotObservationInvalid
  | MutationSnapshotObservationUnobservable
  | MutationSnapshotObservationTimedOut
  deriving (Eq, Show)

data Expected = ExpectedDirectory | ExpectedFile !MutationSnapshotFile
  deriving (Eq, Show)

type Inventory = Map.Map FilePath (Map.Map FilePath Expected)

-- | The caller supplies an authenticated parent and an independently bound
-- snapshot. A matching result does not prevent subsequent changes, establish
-- root provenance, verify the build toolchain, or authorize a worker.
observeMutationSnapshot :: Fd -> String -> MutationSnapshot -> IO MutationSnapshotObservation
observeMutationSnapshot parent operation snapshot
  | not (validRootGeneration operation) = pure MutationSnapshotObservationInvalid
  | otherwise = do
      owner <- getEffectiveUserID
      observed <- timeout (120 * 1000000) $ try $ do
        parentBefore <- getFdStatus parent
        if not (safeDirectory owner parentBefore)
          then pure False
          else bracket (openDirectory parent operation) Posix.closeFd $ \root -> do
            rootBefore <- getFdStatus root
            rootMount <- mutationWorkspaceSameMount parent root
            if not (safeDirectory owner rootBefore && deviceID rootBefore == deviceID parentBefore && rootMount)
              then pure False
              else do
                matched <- observeDirectory owner (expectedInventory (mutationSnapshotFiles snapshot)) "" root
                rootAfter <- getFdStatus root
                (named, namedMount) <- bracket (openDirectory parent operation) Posix.closeFd $ \namedRoot ->
                  (,) <$> getFdStatus namedRoot <*> mutationWorkspaceSameMount parent namedRoot
                parentAfter <- getFdStatus parent
                pure
                  ( matched
                      && sameVersion rootBefore rootAfter
                      && sameVersion rootAfter named
                      && namedMount
                      && sameVersion parentBefore parentAfter
                  )
      pure $ case observed of
        Nothing -> MutationSnapshotObservationTimedOut
        Just (Left (_ :: IOException)) -> MutationSnapshotObservationUnobservable
        Just (Right True) -> MutationSnapshotMatches
        Just (Right False) -> MutationSnapshotDiffers

-- | Observe only within the supplied absolute monotonic deadline. A late or
-- timed-out result remains incomplete even if the underlying scan matched.
observeMutationSnapshotBefore
  :: Word64 -> Fd -> String -> MutationSnapshot -> IO MutationSnapshotObservation
observeMutationSnapshotBefore ending parent operation snapshot = do
  now <- getMonotonicTimeNSec
  if now >= ending
    then pure MutationSnapshotObservationTimedOut
    else do
      let micros = fromInteger (min 120000000 ((toInteger ending - toInteger now + 999) `div` 1000))
      result <- timeout micros (observeMutationSnapshot parent operation snapshot)
      after <- getMonotonicTimeNSec
      pure $ case result of
        Just observed | after < ending -> observed
        _ -> MutationSnapshotObservationTimedOut

expectedInventory :: [MutationSnapshotFile] -> Inventory
expectedInventory = foldl' insertFile Map.empty
 where
  insertFile inventory entry = add inventory "" (splitDirectories (Text.unpack (snapshotFilePath entry))) entry
  add inventory parent parts entry = case parts of
    [] -> inventory
    [name] -> insertChild inventory parent name (ExpectedFile entry)
    name : rest -> add (insertChild inventory parent name ExpectedDirectory) (parent </> name) rest entry
  insertChild inventory parent name expected = Map.insertWith Map.union parent (Map.singleton name expected) inventory

observeDirectory :: UserID -> Inventory -> FilePath -> Fd -> IO Bool
observeDirectory owner inventory path directory = do
  before <- getFdStatus directory
  if not (safeDirectory owner before)
    then pure False
    else case Map.lookup path inventory of
      Nothing -> pure False
      Just expected -> do
        names <- readNames directory (Map.size expected)
        case names of
          Nothing -> pure False
          Just actual
            | actual /= Map.keysSet expected -> pure False
            | otherwise -> do
                children <- traverse (observeChild before) (Map.toList expected)
                after <- getFdStatus directory
                pure (and children && sameVersion before after)
 where
  observeChild parentStatus (name, expected) = case expected of
    ExpectedDirectory -> bracket (openDirectory directory name) Posix.closeFd $ \child -> do
      childBefore <- getFdStatus child
      sameMount <- mutationWorkspaceSameMount directory child
      if not (safeDirectory owner childBefore && deviceID childBefore == deviceID parentStatus && sameMount)
        then pure False
        else do
          matched <- observeDirectory owner inventory (path </> name) child
          after <- getFdStatus child
          (named, namedMount) <- bracket (openDirectory directory name) Posix.closeFd $ \namedChild ->
            (,) <$> getFdStatus namedChild <*> mutationWorkspaceSameMount directory namedChild
          pure (matched && sameVersion childBefore after && sameVersion after named && namedMount)
    ExpectedFile entry -> bracket (Posix.openFdAt (Just directory) name Posix.ReadOnly readFlags) Posix.closeFd $ \file -> do
      before <- getFdStatus file
      sameMount <- mutationWorkspaceSameMount directory file
      if not (safeFile owner entry before && deviceID before == deviceID parentStatus && sameMount)
        then pure False
        else do
          bytes <- readExact file (ByteString.length (snapshotFileBytes entry))
          after <- getFdStatus file
          (named, namedMount) <-
            bracket (Posix.openFdAt (Just directory) name Posix.ReadOnly readFlags) Posix.closeFd $ \namedFile ->
              (,) <$> getFdStatus namedFile <*> mutationWorkspaceSameMount directory namedFile
          pure
            ( bytes == snapshotFileBytes entry
                && sameVersion before after
                && sameVersion after named
                && namedMount
            )

-- Read at most the expected number of names plus one, without following any
-- named entry. The descriptor is held for the duration of this observation.
readNames :: Fd -> Int -> IO (Maybe (Set.Set FilePath))
readNames (Fd descriptor) limit =
  bracket (openDirStream ("/proc/self/fd/" ++ show descriptor)) closeDirStream $ \stream -> go stream Set.empty
 where
  go stream names = do
    name <- readDirStream stream
    if null name
      then pure (Just names)
      else
        if name == "." || name == ".."
          then go stream names
          else
            if Set.size names >= limit || Set.member name names
              then pure Nothing
              else go stream (Set.insert name names)

openDirectory :: Fd -> FilePath -> IO Fd
openDirectory parent name = Posix.openFdAt (Just parent) name Posix.ReadOnly directoryFlags

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}

readFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

safeDirectory :: UserID -> FileStatus -> Bool
safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o077 == 0

safeFile :: UserID -> MutationSnapshotFile -> FileStatus -> Bool
safeFile owner entry status =
  isRegularFile status
    && fileOwner status == owner
    && fileMode status .&. 0o777 == mode
    && linkCount status == 1
    && fileSize status == fromIntegral (ByteString.length (snapshotFileBytes entry))
 where
  mode :: CMode
  mode = if snapshotFileMode entry .&. 0o100 == 0 then 0o600 else 0o700

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion left right =
  deviceID left == deviceID right
    && fileID left == fileID right
    && fileMode left == fileMode right
    && fileOwner left == fileOwner right
    && linkCount left == linkCount right
    && fileSize left == fileSize right
    && modificationTimeHiRes left == modificationTimeHiRes right
    && statusChangeTimeHiRes left == statusChangeTimeHiRes right

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
