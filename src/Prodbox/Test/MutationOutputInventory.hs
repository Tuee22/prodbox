{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded metadata observations of a held mutation-output directory.
-- These observations do not authenticate content, exclude outside aliases or
-- writers, establish worker settlement, or authorize reuse or cleanup.
module Prodbox.Test.MutationOutputInventory
  ( MutationOutputLimits
  , mutationOutputLimits
  , mutationOutputLimitValues
  , MutationOutputInventory
  , MutationOutputObservation (..)
  , observeMutationOutputInventory
  , mutationWorkspaceSameMount
  , mutationOutputInventoryFingerprint
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (guard)
import Data.Bits ((.&.))
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (POSIXTime)
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest, hashPublicEvidence)
import System.FilePath.Posix ((</>))
import System.IO qualified as IO
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (DeviceID, Fd (..), UserID)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data MutationOutputLimits = MutationOutputLimits !Int !Integer !Int !Int
  deriving (Eq, Show)

-- | Maximum entries, aggregate file bytes, depth and elapsed microseconds.
mutationOutputLimits :: Int -> Integer -> Int -> Int -> Maybe MutationOutputLimits
mutationOutputLimits entries bytes depth micros
  | entries > 0
      && entries <= 100000
      && bytes >= 0
      && bytes <= 107374182400
      && depth > 0
      && depth <= 64
      && micros > 0
      && micros <= 120000000 =
      Just (MutationOutputLimits entries bytes depth micros)
  | otherwise = Nothing

mutationOutputLimitValues :: MutationOutputLimits -> (Int, Integer, Int, Int)
mutationOutputLimitValues (MutationOutputLimits entries bytes depth micros) = (entries, bytes, depth, micros)

data EntryVersion
  = EntryVersion !Integer !Integer !Integer !Integer !Integer !Integer !POSIXTime !POSIXTime
  deriving (Eq, Show)

newtype MutationOutputInventory = MutationOutputInventory (Map.Map FilePath EntryVersion)
  deriving (Eq)

-- Paths may contain untrusted names; do not render them in diagnostics.
instance Show MutationOutputInventory where
  show (MutationOutputInventory entries) = "MutationOutputInventory " ++ show (Map.size entries) ++ " entries"

-- | Fingerprint non-secret metadata only, never file contents. The caller
-- must establish that all names are non-secret before retaining this value.
-- A fingerprint is not authentication, content integrity or settlement.
mutationOutputInventoryFingerprint :: MutationOutputInventory -> PublicEvidenceDigest
mutationOutputInventoryFingerprint (MutationOutputInventory entries) =
  hashPublicEvidence $
    Text.pack $
      "prodbox-mutation-output-metadata-v1\NUL"
        ++ concatMap encode (Map.toAscList entries)
 where
  encode (path, version) = show (length path) ++ ":" ++ path ++ show version ++ "\NUL"

data MutationOutputObservation
  = MutationOutputObserved !MutationOutputInventory
  | MutationOutputUnsafe
  | MutationOutputUnobservable
  | MutationOutputTimedOut
  deriving (Eq, Show)

-- | Observe metadata, not file contents. The caller must retain the root and
-- independently establish its provenance, disjointness and writer settlement.
observeMutationOutputInventory :: MutationOutputLimits -> Fd -> IO MutationOutputObservation
observeMutationOutputInventory limits@(MutationOutputLimits _ _ _ micros) root = do
  owner <- getEffectiveUserID
  observed <- timeout micros $ try $ do
    before <- getFdStatus root
    mount <- fdMountId root
    if not (safeDirectory owner before)
      then pure Nothing
      else do
        count <- newIORef (0 :: Int, 0 :: Integer, 0 :: Int, Set.singleton (identity before))
        entries <- observeDirectory limits owner (deviceID before) mount count "" 0 root
        after <- getFdStatus root
        mountAfter <- fdMountId root
        pure $
          if sameVersion before after && mount == mountAfter
            then MutationOutputInventory . Map.insert "" (entryVersion before) <$> entries
            else Nothing
  pure $ case observed of
    Nothing -> MutationOutputTimedOut
    Just (Left (_ :: IOException)) -> MutationOutputUnobservable
    Just (Right Nothing) -> MutationOutputUnsafe
    Just (Right (Just inventory)) -> MutationOutputObserved inventory

observeDirectory
  :: MutationOutputLimits
  -> UserID
  -> DeviceID
  -> Int
  -> IORef (Int, Integer, Int, Set.Set (Integer, Integer))
  -> FilePath
  -> Int
  -> Fd
  -> IO (Maybe (Map.Map FilePath EntryVersion))
observeDirectory limits@(MutationOutputLimits maxEntries _ maxDepth _) owner device rootMount counter path depth directory = do
  before <- getFdStatus directory
  mount <- fdMountId directory
  if depth > maxDepth
    || not (safeDirectory owner before)
    || deviceID before /= device
    || mount /= rootMount
    then pure Nothing
    else do
      names <- readNames directory maxEntries
      case names of
        Nothing -> pure Nothing
        Just children -> do
          observations <- traverse observeChild (Set.toAscList children)
          after <- getFdStatus directory
          mountAfter <- fdMountId directory
          pure $
            if sameVersion before after && mountAfter == rootMount
              then Map.unions <$> sequence observations
              else Nothing
 where
  observeChild name = do
    let Fd descriptor = directory
        childPath = if null path then name else path </> name
        namedPath = "/proc/self/fd/" ++ show descriptor ++ "/" ++ name
    named <- getSymbolicLinkStatus namedPath
    if name == "test-secrets.dhall"
      || Text.unpack (Text.pack name) /= name
      || depth + 1 > maxDepth
      || length childPath > 4096
      || deviceID named /= device
      || not (safeEntry owner named)
      then pure Nothing
      else do
        admitted <- reserve limits counter childPath named
        if not admitted
          then pure Nothing
          else bracket (openChild directory name (isDirectory named)) Posix.closeFd $ \child -> do
            initial <- getFdStatus child
            mount <- fdMountId child
            if not (sameVersion named initial) || mount /= rootMount
              then pure Nothing
              else do
                descendants <-
                  if isDirectory initial
                    then observeDirectory limits owner device rootMount counter childPath (depth + 1) child
                    else pure (Just Map.empty)
                after <- getFdStatus child
                mountAfter <- fdMountId child
                latest <- getSymbolicLinkStatus namedPath
                pure $
                  if sameVersion initial after && sameVersion after latest && mountAfter == rootMount
                    then Map.insert childPath (entryVersion initial) <$> descendants
                    else Nothing

reserve
  :: MutationOutputLimits
  -> IORef (Int, Integer, Int, Set.Set (Integer, Integer))
  -> FilePath
  -> FileStatus
  -> IO Bool
reserve (MutationOutputLimits maxEntries maxBytes _ _) counter path status =
  atomicModifyIORef' counter $ \(count, bytes, nameChars, identities) ->
    let nextBytes = bytes + if isRegularFile status then toInteger (fileSize status) else 0
        nextCount = count + 1
        nextNames = nameChars + length path
        key = identity status
        valid =
          nextCount <= maxEntries
            && nextBytes <= maxBytes
            && nextNames <= 2097152
            && not (Set.member key identities)
     in ((nextCount, nextBytes, nextNames, Set.insert key identities), valid)

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

openChild :: Fd -> FilePath -> Bool -> IO Fd
openChild parent name directory =
  Posix.openFdAt (Just parent) name Posix.ReadOnly $
    Posix.defaultFileFlags
      { Posix.nofollow = True
      , Posix.cloexec = True
      , Posix.nonBlock = True
      , Posix.directory = directory
      }

safeDirectory :: UserID -> FileStatus -> Bool
safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o7077 == 0

safeEntry :: UserID -> FileStatus -> Bool
safeEntry owner status =
  fileOwner status == owner
    && fileMode status .&. 0o7077 == 0
    && (isDirectory status || (isRegularFile status && linkCount status == 1 && fileSize status >= 0))

identity :: FileStatus -> (Integer, Integer)
identity status = (toInteger (deviceID status), toInteger (fileID status))

entryVersion :: FileStatus -> EntryVersion
entryVersion status =
  EntryVersion
    (toInteger (deviceID status))
    (toInteger (fileID status))
    (toInteger (fileMode status))
    (toInteger (fileOwner status))
    (toInteger (linkCount status))
    (toInteger (fileSize status))
    (modificationTimeHiRes status)
    (statusChangeTimeHiRes status)

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion left right = entryVersion left == entryVersion right

-- | Compare held descriptors in the current mount namespace. This observes
-- only mount identity; it does not exclude aliases or establish ownership.
-- Unavailable descriptor metadata raises an ordinary IO failure.
mutationWorkspaceSameMount :: Fd -> Fd -> IO Bool
mutationWorkspaceSameMount left right = (==) <$> fdMountId left <*> fdMountId right

-- A bind mount may share a device and inode with its source. Require every
-- opened entry to be on the held root's mount; unavailable or malformed
-- descriptor metadata refuses the inventory. This does not exclude aliases
-- to the root itself or prove that no outside writer exists.
fdMountId :: Fd -> IO Int
fdMountId (Fd descriptor) = IO.withBinaryFile ("/proc/self/fdinfo/" ++ show descriptor) IO.ReadMode $ \handle -> do
  bytes <- Bytes.hGet handle 4097
  let parsed = do
        guard (Bytes.length bytes <= 4096)
        value <- case [ part | line <- Bytes.lines bytes, [label, part] <- [Bytes.words line], label == Bytes.pack "mnt_id:"
                      ] of
          [single] -> Just single
          _ -> Nothing
        number <- readMaybe (Bytes.unpack value)
        guard (number > 0)
        pure number
  maybe (ioError (userError "mutation output mount identity unavailable")) pure parsed
