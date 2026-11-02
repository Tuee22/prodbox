{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Cooperative publication of the operator's public Tier-0 document. The
-- lock protects every canonical writer, including threads in the same process.
-- No lock or temporary file is lifecycle authority or a recovery receipt.
module Prodbox.Config.Tier0File
  ( Tier0FileError (..)
  , Tier0FileUpdate (..)
  , modifyTier0File
  , tier0FileMaximumBytes
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception (IOException, bracket, displayException, finally, mask_, throwIO, try)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (POSIXTime)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , makeAbsolute
  , removeFile
  , renameFile
  )
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isDoesNotExistError, isEOFError)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files
  ( FileStatus
  , accessModes
  , createLink
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , groupReadMode
  , groupWriteMode
  , intersectFileModes
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , otherReadMode
  , otherWriteMode
  , ownerReadMode
  , ownerWriteMode
  , setFdMode
  , statusChangeTimeHiRes
  , unionFileModes
  )
import System.Posix.IO
  ( LockRequest (WriteLock)
  , OpenFileFlags (..)
  , OpenMode (ReadOnly, ReadWrite, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  , setLock
  )
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Types (DeviceID, Fd, FileID, FileMode)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

data Tier0FileError
  = Tier0FileBusy
  | Tier0FileUnsafe
  | Tier0FileTooLarge
  | Tier0FileChanged
  | Tier0FileWriteUnconfirmed
  | Tier0FileRejected !Text
  | Tier0FileIoFailed !Text
  deriving (Eq, Show)

data Tier0FileUpdate value
  = Tier0FileKeep !value
  | Tier0FileReplace !ByteString !value

data FileVersion = FileVersion !DeviceID !FileID !POSIXTime !POSIXTime !FileMode
  deriving (Eq)

data FileSnapshot = FileMissing | FilePresent !FileVersion !ByteString
  deriving (Eq)

tier0FileMaximumBytes :: Int
tier0FileMaximumBytes = 1024 * 1024

-- POSIX record locks belong to a process, not its individual threads. This
-- registry only arbitrates local file access; it retains no config or authority.
{-# NOINLINE processPaths #-}
processPaths :: MVar (Set FilePath)
processPaths = unsafePerformIO (newMVar Set.empty)

modifyTier0File
  :: FilePath
  -> (Maybe ByteString -> IO (Either Text (Tier0FileUpdate value)))
  -> IO (Either Tier0FileError value)
modifyTier0File supplied transform = do
  attempted <- try $ do
    absolute <- makeAbsolute supplied
    createDirectoryIfMissing True (takeDirectory absolute)
    parent <- canonicalizePath (takeDirectory absolute)
    let path = parent </> takeFileName absolute
    bracket
      (modifyMVar processPaths (claim path))
      (release path)
      (\claimed -> if claimed then withFileLock path (update path) else pure (Left Tier0FileBusy))
  pure $ case attempted of
    Left (failure :: IOException) -> Left (Tier0FileIoFailed (Text.take 1024 (Text.pack (displayException failure))))
    Right result -> result
 where
  claim path held
    | Set.member path held = pure (held, False)
    | otherwise = pure (Set.insert path held, True)
  release path claimed =
    if claimed then modifyMVar_ processPaths (pure . Set.delete path) else pure ()
  update path = do
    before <- readSnapshot path
    case before of
      Left failure -> pure (Left failure)
      Right snapshot -> do
        proposed <- transform (snapshotBytes snapshot)
        case proposed of
          Left failure -> pure (Left (Tier0FileRejected (Text.take 4096 failure)))
          Right (Tier0FileKeep value) -> do
            durable <- synchroniseSnapshot path snapshot
            closing <- readSnapshot path
            pure $ do
              durable
              if closing == Right snapshot then Right value else Left Tier0FileChanged
          Right (Tier0FileReplace bytes value)
            | BS.length bytes > tier0FileMaximumBytes -> pure (Left Tier0FileTooLarge)
            | otherwise -> publish path snapshot bytes value

snapshotBytes :: FileSnapshot -> Maybe ByteString
snapshotBytes snapshot = case snapshot of
  FileMissing -> Nothing
  FilePresent _ bytes -> Just bytes

-- An idempotent retry may follow cancellation between rename and directory
-- fsync. Readback alone cannot confirm durable publication in that case.
synchroniseSnapshot :: FilePath -> FileSnapshot -> IO (Either Tier0FileError ())
synchroniseSnapshot path snapshot = do
  synced <- case snapshot of
    FileMissing -> pure (Right ())
    FilePresent expectedVersion _ ->
      bracket (openFd path ReadOnly safeFlags) safeClose $ \fd -> do
        before <- getFdStatus fd
        safe <- safeStatus before
        if not safe || version before /= expectedVersion
          then pure (Left Tier0FileChanged)
          else do
            fileSynchronise fd
            after <- getFdStatus fd
            pure (if version after == expectedVersion then Right () else Left Tier0FileChanged)
  case synced of
    Left failure -> pure (Left failure)
    Right () -> synchroniseParent path >> pure (Right ())

synchroniseParent :: FilePath -> IO ()
synchroniseParent path =
  bracket
    (openFd (takeDirectory path) ReadOnly (safeFlags {directory = True}))
    safeClose
    fileSynchronise

withFileLock :: FilePath -> IO (Either Tier0FileError value) -> IO (Either Tier0FileError value)
withFileLock path action =
  bracket
    (openFd (path <> ".lock") ReadWrite (safeFlags {creat = Just ownerMode}))
    safeClose
    ( \fd -> do
        status <- getFdStatus fd
        safe <- safeStatus status
        if not safe
          then pure (Left Tier0FileUnsafe)
          else do
            setFdMode fd ownerMode
            locked <- try (setLock fd (WriteLock, AbsoluteSeek, 0, 0))
            case locked of
              Left (_ :: IOException) -> pure (Left Tier0FileBusy)
              Right () -> action
    )

readSnapshot :: FilePath -> IO (Either Tier0FileError FileSnapshot)
readSnapshot path = do
  attempted <- try $ bracket (openFd path ReadOnly safeFlags) safeClose $ \fd -> do
    before <- getFdStatus fd
    safe <- safeStatus before
    if not safe
      then pure (Left Tier0FileUnsafe)
      else
        if fileSize before > fromIntegral tier0FileMaximumBytes
          then pure (Left Tier0FileTooLarge)
          else do
            bytes <- readBounded fd [] 0
            after <- getFdStatus fd
            pure $ do
              contents <- bytes
              unless (version before == version after) (Left Tier0FileChanged)
              pure (FilePresent (version after) contents)
  pure $ case attempted of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> Right FileMissing
      | otherwise -> Left (Tier0FileIoFailed (Text.take 1024 (Text.pack (displayException failure))))
    Right result -> result

readBounded :: Fd -> [ByteString] -> Int -> IO (Either Tier0FileError ByteString)
readBounded fd chunks total = do
  attempted <- try (Posix.fdRead fd (fromIntegral (min 65536 (tier0FileMaximumBytes - total + 1))))
  case attempted of
    Left (failure :: IOException)
      | isEOFError failure -> pure (Right (BS.concat (reverse chunks)))
      | otherwise -> throwIO failure
    Right next
      | BS.null next -> pure (Right (BS.concat (reverse chunks)))
      | total + BS.length next > tier0FileMaximumBytes -> pure (Left Tier0FileTooLarge)
      | otherwise -> readBounded fd (next : chunks) (total + BS.length next)

version :: FileStatus -> FileVersion
version status =
  FileVersion
    (deviceID status)
    (fileID status)
    (modificationTimeHiRes status)
    (statusChangeTimeHiRes status)
    (fileMode status `intersectFileModes` accessModes)

safeStatus :: FileStatus -> IO Bool
safeStatus status = do
  owner <- getEffectiveUserID
  pure
    ( isRegularFile status
        && fileOwner status == owner
        && linkCount status == 1
        && fileMode status `intersectFileModes` (groupWriteMode `unionFileModes` otherWriteMode) == 0
    )

publish :: FilePath -> FileSnapshot -> ByteString -> value -> IO (Either Tier0FileError value)
publish path expected bytes value = do
  let temporary = path <> ".publish.tmp"
  stale <- removeTemporary temporary
  case stale of
    Left failure -> pure (Left failure)
    Right () -> publishFrom temporary `finally` void (removeTemporary temporary)
 where
  publishFrom temporary = do
    bracket
      (openFd temporary WriteOnly (safeFlags {creat = Just ownerMode, exclusive = True}))
      safeClose
      (\fd -> writeAll fd bytes >> setFdMode fd (publicationMode expected) >> fileSynchronise fd)
    closing <- readSnapshot path
    if closing /= Right expected
      then pure (Left Tier0FileChanged)
      else do
        -- Other canonical writers hold the same process/file lock. Creation
        -- additionally refuses an unexpected destination atomically.
        mask_ $ do
          case expected of
            FileMissing -> createLink temporary path >> removeFile temporary
            FilePresent _ _ -> renameFile temporary path
          synchroniseParent path
        confirmed <- readSnapshot path
        pure $ case confirmed of
          Right (FilePresent _ observed) | observed == bytes -> Right value
          _ -> Left Tier0FileWriteUnconfirmed

removeTemporary :: FilePath -> IO (Either Tier0FileError ())
removeTemporary path = do
  observed <- try (getSymbolicLinkStatus path)
  case observed of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure (Right ())
      | otherwise ->
          pure (Left (Tier0FileIoFailed (Text.take 1024 (Text.pack (displayException failure)))))
    Right status -> do
      safe <- safeStatus status
      if safe then removeFile path >> pure (Right ()) else pure (Left Tier0FileUnsafe)

writeAll :: Fd -> ByteString -> IO ()
writeAll fd bytes
  | BS.null bytes = pure ()
  | otherwise = do
      written <- Posix.fdWrite fd bytes
      if written == 0
        then ioError (userError "Tier-0 write made no progress")
        else writeAll fd (BS.drop (fromIntegral written) bytes)

safeFlags :: OpenFileFlags
safeFlags = defaultFileFlags {nofollow = True, cloexec = True, nonBlock = True}

ownerMode :: FileMode
ownerMode = ownerReadMode `unionFileModes` ownerWriteMode

-- New public documents remain readable by the image's unprivileged daemon.
-- Replacements preserve the operator's existing permission bits.
publicationMode :: FileSnapshot -> FileMode
publicationMode snapshot = case snapshot of
  FileMissing -> ownerMode `unionFileModes` groupReadMode `unionFileModes` otherReadMode
  FilePresent (FileVersion _ _ _ _ mode) _ -> mode

safeClose :: Fd -> IO ()
safeClose fd = void (try (closeFd fd) :: IO (Either IOException ()))
