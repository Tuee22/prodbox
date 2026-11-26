{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded metadata observations and exact retirement of a held tree.
-- The caller supplies ownership and writer settlement. The inventory reads
-- metadata without reading file contents.
module Prodbox.Control.TreeInventory
  ( TreeInventoryLimits
  , treeInventoryLimits
  , treeInventoryLimitValues
  , TreeInventory
  , TreeObservation (..)
  , TreePolicy (..)
  , observeTreeInventory
  , removeObservedTree
  , sameTreeMount
  , treeInventoryEntryCount
  , inventoryMetadata
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (guard, unless)
import Data.Bits ((.&.))
import Data.ByteString.Char8 qualified as Bytes
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (stripPrefix)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (POSIXTime)
import Prodbox.Config.DeploymentScope (validRootGeneration)
import System.FilePath.Posix (splitDirectories, takeDirectory, takeFileName, (</>))
import System.IO qualified as IO
import System.IO.Error (isDoesNotExistError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream, removeDirectory)
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
  , isNamedPipe
  , isRegularFile
  , isSymbolicLink
  , linkCount
  , modificationTimeHiRes
  , removeLink
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (DeviceID, Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data TreeInventoryLimits = TreeInventoryLimits !Int !Integer !Int !Int
  deriving (Eq, Show)

-- | Maximum entries, aggregate file bytes, depth and elapsed microseconds.
treeInventoryLimits :: Int -> Integer -> Int -> Int -> Maybe TreeInventoryLimits
treeInventoryLimits entries bytes depth micros
  | entries > 0
      && entries <= 100000
      && bytes >= 0
      && bytes <= 107374182400
      && depth > 0
      && depth <= 64
      && micros > 0
      && micros <= 120000000 =
      Just (TreeInventoryLimits entries bytes depth micros)
  | otherwise = Nothing

treeInventoryLimitValues :: TreeInventoryLimits -> (Int, Integer, Int, Int)
treeInventoryLimitValues (TreeInventoryLimits entries bytes depth micros) = (entries, bytes, depth, micros)

data EntryVersion
  = EntryVersion !Integer !Integer !Integer !Integer !Integer !Integer !POSIXTime !POSIXTime
  deriving (Eq, Show)

newtype TreeInventory = TreeInventory (Map.Map FilePath EntryVersion)
  deriving (Eq)

-- Paths may contain untrusted names; do not render them in diagnostics.
instance Show TreeInventory where
  show (TreeInventory entries) = "TreeInventory " ++ show (Map.size entries) ++ " entries"

treeInventoryEntryCount :: TreeInventory -> Int
treeInventoryEntryCount (TreeInventory entries) = Map.size entries

-- | Canonical metadata for a caller that has established the names are
-- non-secret. The returned text may include entry names.
inventoryMetadata :: TreeInventory -> Text.Text
inventoryMetadata (TreeInventory entries) =
  Text.pack (concatMap encode (Map.toAscList entries))
 where
  encode (path, version) = show (length path) ++ ":" ++ path ++ show version ++ "\NUL"

data TreeObservation
  = TreeObserved !TreeInventory
  | TreeUnsafe
  | TreeUnobservable
  | TreeTimedOut
  deriving (Eq, Show)

data TreePolicy = PrivateTree | SettledTestTree

-- | The held root is private for both policies. Settled test roots can
-- contain readable service data and the retired kind bridge members.
-- An observation alone establishes no ownership or worker settlement.
observeTreeInventory :: TreePolicy -> TreeInventoryLimits -> Fd -> IO TreeObservation
observeTreeInventory visibility limits@(TreeInventoryLimits _ _ _ micros) root = do
  owner <- getEffectiveUserID
  observed <- timeout micros $ try $ do
    before <- getFdStatus root
    mount <- fdMountId root
    if not (safeDirectory PrivateTree owner before)
      then pure Nothing
      else do
        count <- newIORef (0 :: Int, 0 :: Integer, 0 :: Int, Set.singleton (identity before))
        entries <- observeDirectory visibility limits owner (deviceID before) mount count "" 0 root
        after <- getFdStatus root
        mountAfter <- fdMountId root
        pure $
          if sameVersion before after && mount == mountAfter
            then TreeInventory . Map.insert "" (entryVersion before) <$> entries
            else Nothing
  pure $ case observed of
    Nothing -> TreeTimedOut
    Just (Left (_ :: IOException)) -> TreeUnobservable
    Just (Right Nothing) -> TreeUnsafe
    Just (Right (Just inventory)) -> TreeObserved inventory

-- | Recheck the full inventory before unlinking, then rebind each name
-- to its observed inode. The caller retains the parent and its disposition.
removeObservedTree
  :: TreePolicy
  -> TreeInventoryLimits
  -> Fd
  -> FilePath
  -> TreeInventory
  -> IO Bool
  -> IO Bool
removeObservedTree visibility limits@(TreeInventoryLimits maxEntries _ _ micros) parent name expected@(TreeInventory inventory) stable
  | not (validName name) = pure False
  | otherwise = do
      result <- timeout micros $ try $ do
        requireStable
        bracket (openChild parent name True) Posix.closeFd $ \root -> do
          sameMount <- sameTreeMount parent root
          observed <- observeTreeInventory visibility limits root
          unless
            (sameMount && observed == TreeObserved expected)
            (refuse "retained tree changed before cleanup")
        removeEntry parent name ""
        fileSynchronise parent
        requireStable
      pure $ case result of
        Just (Right ()) -> True
        Just (Left (_ :: IOException)) -> False
        Nothing -> False
 where
  children =
    Map.fromListWith
      (++)
      [(directoryOf path, [takeFileName path]) | path <- Map.keys inventory, not (null path)]
  directoryOf path = case takeDirectory path of
    "." -> ""
    relative -> relative
  requireStable = do
    held <- stable
    unless held (refuse "retained tree parent changed")
  paths directory entryName =
    let Fd raw = directory
     in "/proc/self/fd/" ++ show raw </> entryName
  removeEntry directory entryName relative = do
    expectedVersion <-
      maybe (refuse "retained tree entry not recorded") pure (Map.lookup relative inventory)
    let target = paths directory entryName
    named <- getSymbolicLinkStatus target
    unless (entryVersion named == expectedVersion) (refuse "retained tree entry changed")
    if isSymbolicLink named
      then removeLink target
      else removeOpenedEntry directory entryName relative target named
    absent <- try (getSymbolicLinkStatus target)
    case absent of
      Left failure | isDoesNotExistError failure -> pure ()
      _ -> refuse "retained tree entry remains"
  removeOpenedEntry directory entryName relative target named =
    bracket (openChild directory entryName (isDirectory named)) Posix.closeFd $ \held -> do
      initial <- getFdStatus held
      sameMount <- sameTreeMount directory held
      unless (sameMount && sameVersion initial named) (refuse "retained tree entry moved")
      if isDirectory initial
        then do
          let expectedChildren = Set.fromList (Map.findWithDefault [] relative children)
          currentChildren <- readNames held maxEntries
          unless (currentChildren == Just expectedChildren) (refuse "retained tree directory changed")
          traverse_
            (\child -> removeEntry held child (if null relative then child else relative </> child))
            (Set.toAscList expectedChildren)
          final <- getSymbolicLinkStatus target
          unless
            ( isDirectory final
                && identity final == identity initial
                && fileOwner final == fileOwner initial
                && fileMode final == fileMode initial
            )
            (refuse "retained tree directory replaced")
          removeDirectory target
        else do
          final <- getSymbolicLinkStatus target
          unless (sameVersion final initial) (refuse "retained tree file replaced")
          removeLink target
  validName value = not (null value) && value `notElem` [".", ".."] && '/' `notElem` value
  refuse = ioError . userError

observeDirectory
  :: TreePolicy
  -> TreeInventoryLimits
  -> UserID
  -> DeviceID
  -> Int
  -> IORef (Int, Integer, Int, Set.Set (Integer, Integer))
  -> FilePath
  -> Int
  -> Fd
  -> IO (Maybe (Map.Map FilePath EntryVersion))
observeDirectory visibility limits@(TreeInventoryLimits maxEntries _ maxDepth _) owner device rootMount counter path depth directory = do
  before <- getFdStatus directory
  mount <- fdMountId directory
  if depth > maxDepth
    || not (safeDirectory visibility owner before)
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
      || not (safeEntry visibility owner childPath named)
      then pure Nothing
      else do
        admitted <- reserve limits counter childPath named
        if not admitted
          then pure Nothing
          else
            if isSymbolicLink named
              then do
                latest <- getSymbolicLinkStatus namedPath
                pure
                  (if sameVersion named latest then Just (Map.singleton childPath (entryVersion named)) else Nothing)
              else bracket (openChild directory name (isDirectory named)) Posix.closeFd $ \child -> do
                initial <- getFdStatus child
                mount <- fdMountId child
                if not (sameVersion named initial) || mount /= rootMount
                  then pure Nothing
                  else do
                    descendants <-
                      if isDirectory initial
                        then observeDirectory visibility limits owner device rootMount counter childPath (depth + 1) child
                        else pure (Just Map.empty)
                    after <- getFdStatus child
                    mountAfter <- fdMountId child
                    latest <- getSymbolicLinkStatus namedPath
                    pure $
                      if sameVersion initial after && sameVersion after latest && mountAfter == rootMount
                        then Map.insert childPath (entryVersion initial) <$> descendants
                        else Nothing

reserve
  :: TreeInventoryLimits
  -> IORef (Int, Integer, Int, Set.Set (Integer, Integer))
  -> FilePath
  -> FileStatus
  -> IO Bool
reserve (TreeInventoryLimits maxEntries maxBytes _ _) counter path status =
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

safeDirectory :: TreePolicy -> UserID -> FileStatus -> Bool
safeDirectory visibility owner status = isDirectory status && safeOwnerMode visibility owner status

safeEntry :: TreePolicy -> UserID -> FilePath -> FileStatus -> Bool
safeEntry visibility owner path status
  | isSymbolicLink status = case visibility of
      PrivateTree -> False
      SettledTestTree -> fileOwner status == owner && linkCount status == 1
  | isNamedPipe status = case visibility of
      PrivateTree -> False
      SettledTestTree ->
        safeOwnerMode PrivateTree owner status && linkCount status == 1 && retainedKindPipe path
  | otherwise =
      safeOwnerMode visibility owner status
        && (isDirectory status || (isRegularFile status && linkCount status == 1 && fileSize status >= 0))

retainedKindPipe :: FilePath -> Bool
retainedKindPipe path = case splitDirectories path of
  [worker, "bridge", endpoint] ->
    maybe False validRootGeneration (stripPrefix "kind-worker-" worker) && bridgeEndpoint endpoint
  ["history", operation, worker, "bridge", endpoint] ->
    validRootGeneration operation && worker == "kind-worker-" ++ operation && bridgeEndpoint endpoint
  _ -> False
 where
  bridgeEndpoint name = name == "request" || name == "reply"

safeOwnerMode :: TreePolicy -> UserID -> FileStatus -> Bool
safeOwnerMode visibility owner status =
  fileOwner status == owner
    && fileMode status .&. forbidden == 0
 where
  forbidden = case visibility of
    PrivateTree -> 0o7077
    SettledTestTree -> 0o7022

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
sameTreeMount :: Fd -> Fd -> IO Bool
sameTreeMount left right = (==) <$> fdMountId left <*> fdMountId right

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
  maybe (ioError (userError "retained tree mount identity unavailable")) pure parsed
