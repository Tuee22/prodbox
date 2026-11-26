{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Durable relocation of one retired kind operation. Every renamed entry
-- remains in the live root or the private staging directory until publication.
module Prodbox.Control.KindArchiveTransaction
  ( ArchiveTransactionRecovery (..)
  , kindArchivePendingAbsent
  , authorityArchiveRecordName
  , confirmPublishedAuthorityArchive
  , retireArchivedAuthorityFence
  , observeActiveAuthorityFence
  , publishKindArchive
  , recoverKindArchive
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (forM, forM_, guard, unless)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Bits ((.&.))
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.List (sort)
import Data.Text (Text)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import GHC.Generics (Generic)
import System.IO (IOMode (ReadMode), hClose, hFlush, withBinaryFile)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import Text.Read (readMaybe)

data ArchiveTransactionRecovery
  = ArchiveTransactionAbsent
  | ArchiveTransactionRestored
  | ArchiveTransactionUnconfirmed
  deriving (Eq, Show)

data EntryIdentity = EntryIdentity !Integer !Integer !Bool !Integer !Integer
  deriving (Eq, FromJSON, Generic, Show, ToJSON)

data ArchiveEntry = ArchiveEntry !String !EntryIdentity
  deriving (Eq, FromJSON, Generic, Show, ToJSON)

data ArchiveManifest = ArchiveManifest
  { version :: !Int
  , generation :: !Text
  , operation :: !String
  , rootIdentity :: !EntryIdentity
  , stagingIdentity :: !EntryIdentity
  , entries :: ![ArchiveEntry]
  }
  deriving (FromJSON, Generic, ToJSON)

authorityArchiveRecordName :: FilePath
authorityArchiveRecordName = "kind-authority-retirement.json"

kindArchivePendingName, manifestName, manifestTemporary, retiredCredential :: FilePath
kindArchivePendingName = "kind-archive-pending"
manifestName = "archive-manifest.json"
manifestTemporary = ".manifest.tmp"
retiredCredential = "retired-kubeconfig"

maximumEntries, maximumManifestBytes :: Int
maximumEntries = 512
maximumManifestBytes = 128 * 1024

kindArchivePendingAbsent :: Fd -> IO Bool
kindArchivePendingAbsent root = do
  owner <- getEffectiveUserID
  observed <- try (entryIdentity root owner kindArchivePendingName)
  pure $ case observed of
    Right Nothing -> True
    Right (Just _) -> False
    Left (_ :: IOException) -> False

foreign import capi "stdio.h renameat2"
  renameAt :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" noReplace :: CUInt
foreign import capi "sys/stat.h mkdirat" makeDirectoryAt :: CInt -> CString -> CMode -> IO CInt
foreign import capi "unistd.h unlinkat" unlinkAt :: CInt -> CString -> CInt -> IO CInt
foreign import capi "fcntl.h value AT_REMOVEDIR" removeDirectoryFlag :: CInt

-- The final folder only appears after every moved entry and the archive
-- manifest have been read back and synchronised under the root lease.
publishKindArchive
  :: Fd -> IO Bool -> Text -> String -> [FilePath] -> Bool -> IO [FilePath]
publishKindArchive root stable selectedGeneration oldOperation recordNames credential = do
  let (records, fences) = break (== "kind-intent.json") recordNames
      names = records ++ [retiredCredential | credential] ++ fences
      allowed = admissibleNames oldOperation (const True) names
  require (validOperation oldOperation && allowed) "invalid archive entries"
  owner <- getEffectiveUserID
  rootKey <- identity <$> Files.getFdStatus root
  withCredentialParent root owner credential $ \control -> do
    captured <- forM names $ \name -> do
      observed <- liveEntry root owner control name
      key <- maybe (ioError (userError "missing live archive entry")) pure observed
      pure (ArchiveEntry name key)
    requireM stable "archive lease changed before staging"
    makeDirectory root "history" True
    withDirectory root owner "history" $ \history -> do
      requirePrivateDirectory history
      previous <- entryIdentity history owner oldOperation
      require (previous == Nothing) "archive already exists"
      makeDirectory root kindArchivePendingName False
      fileSynchronise root
      withDirectory root owner kindArchivePendingName $ \staging -> do
        requirePrivateDirectory staging
        stagingKey <- identity <$> Files.getFdStatus staging
        let manifest = ArchiveManifest 1 selectedGeneration oldOperation rootKey stagingKey captured
        writeManifest staging manifest
        forM_ captured $ \(ArchiveEntry name key) -> do
          requireM stable "archive lease changed before move"
          observed <- liveEntry root owner control name
          require (observed == Just key) "live record changed before moving"
          let (source, sourceName) = entryLocation root control name
          rename source sourceName staging name
          fileSynchronise staging
          fileSynchronise source
        expectStaging staging owner manifest
        requireM stable "archive lease changed before publication"
        now <- entryIdentity root owner kindArchivePendingName
        require (now == Just stagingKey) "archive staging directory changed"
        rename root kindArchivePendingName history oldOperation
        fileSynchronise history
        fileSynchronise root
        published <- entryIdentity history owner oldOperation
        require (published == Just stagingKey) "archive publication is unconfirmed"
        requireM stable "archive lease changed after publication"
  pure (recordNames ++ ["control/kubeconfig" | credential])

-- Restore a partially moved archive before the ordinary removal observers
-- run again. An ambiguous pathname or inode leaves the transaction in place.
recoverKindArchive
  :: Fd -> IO Bool -> Text -> (String -> FilePath -> Bool) -> IO ArchiveTransactionRecovery
recoverKindArchive root stable selectedGeneration allowed = do
  outcome <- try recover :: IO (Either IOException ArchiveTransactionRecovery)
  pure (either (const ArchiveTransactionUnconfirmed) id outcome)
 where
  recover = do
    owner <- getEffectiveUserID
    found <- entryIdentity root owner kindArchivePendingName
    case found of
      Nothing -> pure ArchiveTransactionAbsent
      Just key -> withDirectory root owner kindArchivePendingName $ \staging -> do
        requirePrivateDirectory staging
        initial <- identity <$> Files.getFdStatus staging
        require (initial == key) "archive staging changed"
        names <- listEntries staging
        if manifestName `notElem` names
          then do
            require (all (== manifestTemporary) names) "archive without a manifest has moved entries"
            requireM stable "archive lease changed before dropping incomplete staging"
            forM_ names $ \name -> do
              temporary <- entryIdentity staging owner name
              require (isRegularIdentity temporary) "archive manifest staging is unsafe"
              remove staging name 0
            closeStaging root stable owner staging initial
          else do
            manifest <- readManifest staging owner
            rootKey <- identity <$> Files.getFdStatus root
            let oldOperation = operation manifest
                expected = [name | ArchiveEntry name _ <- entries manifest]
            require
              ( version manifest == 1
                  && generation manifest == selectedGeneration
                  && rootIdentity manifest == rootKey
                  && stagingIdentity manifest == initial
                  && validOperation oldOperation
                  && admissibleNames oldOperation (allowed oldOperation) expected
                  && all (\name -> name == manifestName || name `elem` expected) names
              )
              "invalid archive recovery manifest"
            withDirectory root owner "history" $ \history -> do
              requirePrivateDirectory history
              existing <- entryIdentity history owner oldOperation
              require (existing == Nothing) "interrupted archive has a conflicting publication"
            withCredentialParent root owner (retiredCredential `elem` expected) $ \control -> do
              inventory <- forM (entries manifest) $ \entry@(ArchiveEntry name entryKey) -> do
                live <- liveEntry root owner control name
                moved <- entryIdentity staging owner name
                if live == Just entryKey && moved == Nothing
                  then pure Nothing
                  else do
                    require (live == Nothing && moved == Just entryKey) "archive entry placement is ambiguous"
                    pure (Just entry)
              forM_ (reverse inventory) $ \candidate -> forM_ candidate $ \(ArchiveEntry name entryKey) -> do
                requireM stable "archive lease changed during restoration"
                let (destination, destinationName) = entryLocation root control name
                rename staging name destination destinationName
                restored <- liveEntry root owner control name
                require (restored == Just entryKey) "restored archive entry is unconfirmed"
                fileSynchronise destination
                fileSynchronise staging
            closing <- listEntries staging
            require (closing == [manifestName]) "archive retains unexpected staged entries"
            requireM stable "archive lease changed before closing restoration"
            remove staging manifestName 0
            closeStaging root stable owner staging initial
        pure ArchiveTransactionRestored

-- | Certify an Authority-backed removal from the completed, exact kind
-- archive. An interrupted archive still prevents retiring the active fence.
confirmPublishedAuthorityArchive
  :: Fd
  -> IO Bool
  -> Text
  -> String
  -> (FilePath -> Bool)
  -> Aeson.Value
  -> IO Bool
confirmPublishedAuthorityArchive root stable selectedGeneration oldOperation allowed expected = do
  observed <- try $ do
    requireM stable "scope changed before archive read-back"
    requireM (kindArchivePendingAbsent root) "a kind archive is still staged"
    require (validOperation oldOperation) "invalid archived operation"
    owner <- getEffectiveUserID
    rootKey <- identity <$> Files.getFdStatus root
    withDirectory root owner "history" $ \history -> do
      requirePrivateDirectory history
      withDirectory history owner oldOperation $ \archived -> do
        requirePrivateDirectory archived
        archivedIdentity <- identity <$> Files.getFdStatus archived
        manifest <- readManifest archived owner
        let names = [name | ArchiveEntry name _ <- entries manifest]
        require
          ( version manifest == 1
              && generation manifest == selectedGeneration
              && operation manifest == oldOperation
              && rootIdentity manifest == rootKey
              && stagingIdentity manifest == archivedIdentity
              && admissibleNames oldOperation allowed names
              && authorityArchiveRecordName `elem` names
          )
          "published kind archive does not match the Authority removal"
        expectStaging archived owner manifest
        (record, _) <- readPrivateArchiveRecord archived owner authorityArchiveRecordName
        closing <- entryIdentity history owner oldOperation
        require (record == expected && closing == Just archivedIdentity) "archived Authority record changed"
        requireM stable "scope changed during archive read-back"
  pure (either (const False) (const True) (observed :: Either IOException ()))

-- | Read the exact, private fence by its held custody descriptor. Missing and
-- unreadable evidence are separate observations.
observeActiveAuthorityFence :: Fd -> IO (Either IOException (Maybe Aeson.Value))
observeActiveAuthorityFence custody = try $ do
  owner <- getEffectiveUserID
  let name = "control-removal.json"
  entry <- entryIdentity custody owner name
  case entry of
    Nothing -> pure Nothing
    Just _ -> do
      (record, observed) <- readPrivateArchiveRecord custody owner name
      require (entry == Just observed) "Authority control removal fence was replaced"
      pure (Just record)

-- | Retire an exact active fence after its already-published kind archive has
-- been independently certified. The fence and its original bytes are retained.
retireArchivedAuthorityFence :: Fd -> IO Bool -> String -> Aeson.Value -> IO Bool
retireArchivedAuthorityFence custody stable oldOperation expected = do
  result <- try $ do
    require (validOperation oldOperation) "invalid Authority removal operation"
    requireM stable "custody changed before fence retirement"
    owner <- getEffectiveUserID
    let active = "control-removal.json"
        retired = "control-removal-" ++ oldOperation ++ ".json"
    (current, before) <- readPrivateArchiveRecord custody owner active
    vacant <- entryIdentity custody owner retired
    require (current == expected && vacant == Nothing) "active or retired Authority fence differs"
    requireM stable "custody changed before fence move"
    rename custody active custody retired
    fileSynchronise custody
    missing <- entryIdentity custody owner active
    (archived, after) <- readPrivateArchiveRecord custody owner retired
    require
      (missing == Nothing && before == after && archived == expected)
      "retired Authority fence is unconfirmed"
    requireM stable "custody changed during fence retirement"
  pure (either (const False) (const True) (result :: Either IOException ()))

readPrivateArchiveRecord :: Fd -> UserID -> FilePath -> IO (Aeson.Value, EntryIdentity)
readPrivateArchiveRecord parent owner name =
  bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly flags) Posix.closeFd $ \record -> do
    initial <- Files.getFdStatus record
    require
      (Files.isRegularFile initial && Files.fileMode initial .&. 0o077 == 0)
      "Authority archive record is unsafe"
    duplicate <- Posix.dup record
    bytes <- bracket (Posix.fdToHandle duplicate) hClose (\handle -> Bytes.hGet handle 4097)
    current <- Files.getFdStatus record
    named <- entryIdentity parent owner name
    require
      ( Bytes.length bytes <= 4096
          && fromIntegral (Bytes.length bytes) == Files.fileSize initial
          && identity initial == identity current
          && named == Just (identity current)
          && Files.statusChangeTimeHiRes initial == Files.statusChangeTimeHiRes current
      )
      "Authority archive record changed"
    value <-
      either
        (const (ioError (userError "Authority archive record did not decode")))
        pure
        (Aeson.eitherDecodeStrict' bytes)
    pure (value, identity current)

expectStaging :: Fd -> UserID -> ArchiveManifest -> IO ()
expectStaging staging owner manifest = do
  names <- listEntries staging
  let expected = [name | ArchiveEntry name _ <- entries manifest]
  require (sort names == sort (manifestName : expected)) "archive staging inventory differs"
  forM_ (entries manifest) $ \(ArchiveEntry name key) -> do
    seen <- entryIdentity staging owner name
    require (seen == Just key) "staged archive entry identity differs"

closeStaging :: Fd -> IO Bool -> UserID -> Fd -> EntryIdentity -> IO ()
closeStaging root stable owner staging initial = do
  requireM stable "archive lease changed before restoring custody"
  fileSynchronise staging
  named <- entryIdentity root owner kindArchivePendingName
  require (named == Just initial) "archive staging changed before closing"
  remove root kindArchivePendingName removeDirectoryFlag
  fileSynchronise root
  requireM stable "archive lease changed after restoring custody"

entryLocation :: Fd -> Maybe Fd -> FilePath -> (Fd, FilePath)
entryLocation root control name = case control of
  Just parent | name == retiredCredential -> (parent, "kubeconfig")
  _ -> (root, name)

liveEntry :: Fd -> UserID -> Maybe Fd -> FilePath -> IO (Maybe EntryIdentity)
liveEntry root owner control name = do
  let (parent, liveName) = entryLocation root control name
  entryIdentity parent owner liveName

withCredentialParent :: Fd -> UserID -> Bool -> (Maybe Fd -> IO a) -> IO a
withCredentialParent root owner credential action =
  if credential then withDirectory root owner "control" (action . Just) else action Nothing

admissibleNames :: String -> (FilePath -> Bool) -> [FilePath] -> Bool
admissibleNames oldOperation permitted names =
  length names <= maximumEntries
    && length names == length (unique names)
    && all admissible names
    && "kind-intent.json" `elem` names
    && length (filter (`elem` ["kind-teardown-admission.json", authorityArchiveRecordName]) names) == 1
 where
  unique = foldr (\name present -> if name `elem` present then present else name : present) []
  admissible name =
    not (null name)
      && length name <= 128
      && all (\c -> c == '-' || c == '.' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9') name
      && name `notElem` [".", "..", manifestName, kindArchivePendingName]
      && (name == retiredCredential || name == "kind-worker-" ++ oldOperation || permitted name)

validOperation :: String -> Bool
validOperation value = length value == 32 && all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value

isRegularIdentity :: Maybe EntryIdentity -> Bool
isRegularIdentity (Just (EntryIdentity _ _ False _ _)) = True
isRegularIdentity _ = False

identity :: Files.FileStatus -> EntryIdentity
identity info =
  let directory = Files.isDirectory info
      size = if directory then 0 else toInteger (Files.fileSize info)
      changed = if directory then 0 else floor (Files.modificationTimeHiRes info * 1000000000)
   in EntryIdentity
        (toInteger (Files.deviceID info))
        (toInteger (Files.fileID info))
        directory
        size
        changed

entryIdentity :: Fd -> UserID -> FilePath -> IO (Maybe EntryIdentity)
entryIdentity parent owner name = do
  opened <- try (Posix.openFdAt (Just parent) name Posix.ReadOnly flags)
  case opened of
    Left failure
      | isDoesNotExistError failure -> pure Nothing
      | otherwise -> ioError failure
    Right entry -> bracket (pure entry) Posix.closeFd $ \held -> do
      info <- Files.getFdStatus held
      sameMount <- (==) <$> mountIdentity parent <*> mountIdentity held
      require
        ( sameMount
            && Files.fileOwner info == owner
            && Files.fileMode info .&. 0o022 == 0
            && (name `notElem` ["kubeconfig", retiredCredential] || Files.fileMode info .&. 0o077 == 0)
            && (Files.isDirectory info || Files.isRegularFile info && Files.linkCount info == 1)
        )
        "archive entry is unsafe"
      pure (Just (identity info))

withDirectory :: Fd -> UserID -> FilePath -> (Fd -> IO a) -> IO a
withDirectory parent owner name action =
  bracket
    (Posix.openFdAt (Just parent) name Posix.ReadOnly flags {Posix.directory = True})
    Posix.closeFd
    $ \directory -> do
      info <- Files.getFdStatus directory
      sameMount <- (==) <$> mountIdentity parent <*> mountIdentity directory
      require
        ( sameMount
            && Files.isDirectory info
            && Files.fileOwner info == owner
            && Files.fileMode info .&. 0o022 == 0
        )
        "archive directory is unsafe"
      action directory

flags :: Posix.OpenFileFlags
flags = Posix.defaultFileFlags {Posix.cloexec = True, Posix.nofollow = True, Posix.nonBlock = True}

requirePrivateDirectory :: Fd -> IO ()
requirePrivateDirectory descriptor = do
  status <- Files.getFdStatus descriptor
  require (Files.fileMode status .&. 0o077 == 0) "archive directory is not private"

mountIdentity :: Fd -> IO Int
mountIdentity (Fd raw) = withBinaryFile ("/proc/self/fdinfo/" ++ show raw) ReadMode $ \file -> do
  bytes <- Bytes.hGet file 4097
  let parsed = do
        guard (Bytes.length bytes <= 4096)
        shown <- case [ value | row <- Char8.lines bytes, [field, value] <- [Char8.words row], field == Char8.pack "mnt_id:"
                      ] of
          [value] -> Just value
          _ -> Nothing
        result <- readMaybe (Char8.unpack shown)
        guard (result > 0)
        pure result
  maybe (ioError (userError "archive mount identity is unavailable")) pure parsed

writeManifest :: Fd -> ArchiveManifest -> IO ()
writeManifest staging manifest = do
  let bytes = Lazy.toStrict (Aeson.encode manifest)
  require (Bytes.length bytes <= maximumManifestBytes) "archive manifest exceeds bound"
  let exclusive = flags {Posix.creat = Just 0o600, Posix.exclusive = True}
  bracket (Posix.openFdAt (Just staging) manifestTemporary Posix.WriteOnly exclusive) Posix.closeFd $ \target -> do
    copy <- Posix.dup target
    bracket (Posix.fdToHandle copy) hClose $ \file -> Bytes.hPut file bytes >> hFlush file
    fileSynchronise target
  rename staging manifestTemporary staging manifestName
  fileSynchronise staging

readManifest :: Fd -> UserID -> IO ArchiveManifest
readManifest staging owner = bracket (Posix.openFdAt (Just staging) manifestName Posix.ReadOnly flags) Posix.closeFd $ \source -> do
  info <- Files.getFdStatus source
  named <- entryIdentity staging owner manifestName
  require
    (named == Just (identity info) && isRegularIdentity named && Files.fileMode info .&. 0o077 == 0)
    "archive manifest is unsafe"
  copy <- Posix.dup source
  bytes <-
    bracket (Posix.fdToHandle copy) hClose (\file -> Bytes.hGet file (maximumManifestBytes + 1))
  closing <- Files.getFdStatus source
  stillNamed <- entryIdentity staging owner manifestName
  require
    ( Bytes.length bytes <= maximumManifestBytes
        && identity closing == identity info
        && stillNamed == named
        && Files.statusChangeTimeHiRes info == Files.statusChangeTimeHiRes closing
    )
    "archive manifest changed or exceeded its bound"
  either
    (const (ioError (userError "archive manifest does not decode")))
    pure
    (Aeson.eitherDecodeStrict' bytes)

listEntries :: Fd -> IO [FilePath]
listEntries (Fd raw) = bracket (openDirStream ("/proc/self/fd/" ++ show raw)) closeDirStream (\stream -> go stream [] 0)
 where
  go stream seen count = do
    name <- readDirStream stream
    if null name
      then pure seen
      else
        if name `elem` [".", ".."]
          then go stream seen count
          else do
            require (count <= maximumEntries) "archive staging inventory exceeds bound"
            go stream (name : seen) (count + 1)

makeDirectory :: Fd -> FilePath -> Bool -> IO ()
makeDirectory (Fd raw) name existing = do
  created <- try $ withCString name $ \path -> throwErrnoIfMinus1_ "create archive directory" (makeDirectoryAt raw path 0o700)
  case created of
    Left failure -> unless (existing && isAlreadyExistsError failure) (ioError failure)
    Right () -> pure ()

rename :: Fd -> FilePath -> Fd -> FilePath -> IO ()
rename (Fd source) oldName (Fd destination) newName =
  withCString oldName $ \old -> withCString newName $ \new ->
    throwErrnoIfMinus1_ "move archive record" (renameAt source old destination new noReplace)

remove :: Fd -> FilePath -> CInt -> IO ()
remove (Fd raw) name options = withCString name $ \path -> throwErrnoIfMinus1_ "remove archive staging" (unlinkAt raw path options)

require :: Bool -> String -> IO ()
require okay message = unless okay (ioError (userError message))

requireM :: IO Bool -> String -> IO ()
requireM check message = check >>= \okay -> require okay message
