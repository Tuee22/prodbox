{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Closed, journaled removal of the fixed publisher's submitted payloads.
-- Public metadata remains as the one-shot fence; no historical executable or
-- configuration/request contents are opened to decide file ownership.
module Prodbox.Subprocess.HostControllerInputRetirement
  ( InputRetirementError (..)
  , HostInputRetirementReceipt
  , retireHostControllerInputs
  , hostInputRetirementReceiptMatches
  , HostNeverSentInputRetirementReceipt
  , retireNeverSentHostControllerInputs
  , recoverNeverSentHostControllerInputs
  ) where

import Control.Exception (IOException, finally, mask, try)
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word64)
import Foreign.C.Error (eAGAIN, eWOULDBLOCK, getErrno, throwErrno, throwErrnoIfMinus1Retry)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.FilePath (takeFileName, (</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileGroup
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
import System.Posix.IO.ByteString qualified as Native
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

foreign import capi "fcntl.h value O_TMPFILE" temporaryFlag :: CInt
foreign import capi "fcntl.h value O_RDWR" readWriteFlag :: CInt
foreign import capi "fcntl.h value O_CLOEXEC" closeExecFlag :: CInt
foreign import capi "fcntl.h value AT_FDCWD" currentDirectory :: CInt
foreign import capi "fcntl.h value AT_SYMLINK_FOLLOW" followOwnedDescriptor :: CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" noReplace :: CUInt
foreign import capi "sys/file.h value LOCK_EX" exclusiveLock :: CInt
foreign import capi "sys/file.h value LOCK_NB" nonBlockingLock :: CInt
foreign import capi "sys/file.h flock" lockDirectory :: CInt -> CInt -> IO CInt
foreign import capi "fcntl.h openat" openAnonymous :: CInt -> CString -> CInt -> CMode -> IO CInt
foreign import capi "unistd.h linkat"
  linkAnonymous :: CInt -> CString -> CInt -> CString -> CInt -> IO CInt
foreign import capi "stdio.h renameat2"
  moveFile :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "unistd.h unlinkat" removeFileAt :: CInt -> CString -> CInt -> IO CInt

data InputRetirementError
  = InputRetirementExpired
  | InputRetirementBusy
  | InputRetirementPhysicalRefused !Retirement.RetirementError
  | InputRetirementPublicationRefused !Publication.HostControllerPublicationError
  | InputRetirementRecordMismatch
  | InputRetirementNamespaceRefused
  | InputRetirementMetadataRefused
  | InputRetirementJournalMismatch
  | InputRetirementFileChanged !Inputs.HostControllerInputRole
  | InputRetirementFileMissing !Inputs.HostControllerInputRole
  | InputRetirementConflictingNames !Inputs.HostControllerInputRole
  | InputRetirementUnexpectedResidue !Inputs.HostControllerInputRole
  | InputRetirementIoRefused !IOErrorType !(Maybe Int)
  deriving (Eq, Show)

data Payload = Settings | Request
  deriving (Bounded, Enum)

newtype HostInputRetirementReceipt = HostInputRetirementReceipt Inputs.HostControllerSubmissionRecord

newtype HostNeverSentInputRetirementReceipt = HostNeverSentInputRetirementReceipt ByteString

data InputRetirementSource
  = SubmittedSource !Retirement.HostOperationRetirement !Inputs.HostControllerSubmissionRecord
  | NeverSentSource !Publication.HostPublicationNeverSent

hostInputRetirementReceiptMatches
  :: HostInputRetirementReceipt -> Inputs.HostControllerSubmissionRecord -> Bool
hostInputRetirementReceiptMatches (HostInputRetirementReceipt original) = (== original)

retireHostControllerInputs
  :: Word64
  -> Retirement.HostOperationRetirement
  -> Inputs.HostControllerSubmissionRecord
  -> IO (Either InputRetirementError HostInputRetirementReceipt)
retireHostControllerInputs supplied owner record = do
  let ending = min supplied (Retirement.hostOperationRetirementDeadline owner)
  borrowed <- Retirement.withHostOperationRetirementBorrow ending owner $ \lease ->
    if not (Retirement.hostOperationRetirementMatches lease record)
      then pure (Left InputRetirementRecordMismatch)
      else do
        result <- runLocked ending (SubmittedSource lease record)
        pure (HostInputRetirementReceipt record <$ result)
  pure (either (Left . InputRetirementPhysicalRefused) id borrowed)

retireNeverSentHostControllerInputs
  :: Word64
  -> Publication.HostPublicationNeverSent
  -> IO (Either InputRetirementError HostNeverSentInputRetirementReceipt)
retireNeverSentHostControllerInputs supplied owner = do
  let ending = min supplied (Publication.hostPublicationNeverSentDeadline owner)
  borrowed <- Publication.withHostPublicationNeverSentBorrow ending owner $ \lease -> do
    result <- runLocked ending (NeverSentSource lease)
    pure
      (HostNeverSentInputRetirementReceipt (Publication.hostPublicationNeverSentMetadata lease) <$ result)
  pure (either (Left . InputRetirementPublicationRefused) id borrowed)

recoverNeverSentHostControllerInputs
  :: Word64
  -> Identity.HostControllerKind
  -> Identity.HostExecutionKey
  -> IO (Either InputRetirementError HostNeverSentInputRetirementReceipt)
recoverNeverSentHostControllerInputs ending kind key = do
  recovered <-
    Publication.withRecoveredHostPublicationNeverSent
      kind
      ending
      key
      (retireNeverSentHostControllerInputs ending)
  pure (either (Left . InputRetirementPublicationRefused) id recovered)

runLocked :: Word64 -> InputRetirementSource -> IO (Either InputRetirementError ())
runLocked ending source = do
  uid <- getEffectiveUserID
  withDirectory ending uid source $ \parent -> do
    locked <- lockDirectory (descriptor parent) (exclusiveLock .|. nonBlockingLock)
    if locked == 0
      then runExceptT (reconcile ending uid source parent)
      else do
        cause <- getErrno
        if cause == eAGAIN || cause == eWOULDBLOCK
          then pure (Left InputRetirementBusy)
          else ownIO (throwErrno "input retirement directory lock")

reconcile
  :: Word64
  -> UserID
  -> InputRetirementSource
  -> Fd
  -> ExceptT InputRetirementError IO ()
reconcile ending uid record parent = do
  verifyRoot ending uid record parent
  verifySubmission ending uid record parent
  prepared <- ExceptT (readMetadata ending uid parent preparedName)
  terminal <- ExceptT (readMetadata ending uid parent terminalName)
  case prepared of
    Nothing -> do
      unless (terminal == Nothing) (throwE InputRetirementJournalMismatch)
      mapM_ (requireOriginal ending uid record parent) [minBound .. maxBound]
      verifyPermission ending record
      publishMetadata ending uid parent preparedName (preparedBytes record)
    Just bytes -> unless (bytes == preparedBytes record) (throwE InputRetirementJournalMismatch)
  -- A prior link may have succeeded even when its directory sync failed.
  -- Confirm preparation durability on resume before the first payload move.
  sync ending parent
  case terminal of
    Just bytes -> do
      unless (bytes == terminalBytes record) (throwE InputRetirementJournalMismatch)
      mapM_ (requirePayloadAbsent ending parent) [minBound .. maxBound]
    Nothing -> do
      mapM_ (retirePayload ending uid record parent) [minBound .. maxBound]
      verifyPermission ending record
      verifyRoot ending uid record parent
      mapM_ (requirePayloadAbsent ending parent) [minBound .. maxBound]
      publishMetadata ending uid parent terminalName (terminalBytes record)
  verifyPermission ending record
  verifyRoot ending uid record parent
  mapM_ (requirePayloadAbsent ending parent) [minBound .. maxBound]
  verifySubmission ending uid record parent
  preparedConfirmed <- ExceptT (readMetadata ending uid parent preparedName)
  unless
    (preparedConfirmed == Just (preparedBytes record))
    (throwE InputRetirementJournalMismatch)
  confirmed <- ExceptT (readMetadata ending uid parent terminalName)
  unless (confirmed == Just (terminalBytes record)) (throwE InputRetirementJournalMismatch)
  sync ending parent

verifySubmission
  :: Word64 -> UserID -> InputRetirementSource -> Fd -> ExceptT InputRetirementError IO ()
verifySubmission ending uid source parent = case source of
  NeverSentSource _ -> pure ()
  SubmittedSource _ record -> do
    let request = directory uid source </> Publication.hostControllerRequestName
        submission =
          takeFileName
            (Inputs.hostControllerSubmissionPath request (Inputs.hostControllerSubmissionKey record))
    observed <- ExceptT (readMetadata ending uid parent submission)
    unless
      (observed == Just (Inputs.encodeHostControllerSubmission record))
      (throwE InputRetirementRecordMismatch)

preparedName, terminalName :: String
preparedName = "retirement-prepared.cbor"
terminalName = "retirement-terminal.cbor"

preparedBytes, terminalBytes :: InputRetirementSource -> ByteString
preparedBytes record = "prodbox-host-input-retirement/prepared/v1\NUL" <> sourceBytes record
terminalBytes record = "prodbox-host-input-retirement/terminal/v1\NUL" <> sourceBytes record

sourceBytes :: InputRetirementSource -> ByteString
sourceBytes source = case source of
  SubmittedSource _ record -> Inputs.encodeHostControllerSubmission record
  NeverSentSource owner -> Publication.hostPublicationNeverSentMetadata owner

sourceKey :: InputRetirementSource -> Identity.HostExecutionKey
sourceKey source = case source of
  SubmittedSource _ record -> Inputs.hostControllerSubmissionKey record
  NeverSentSource owner -> Publication.hostPublicationNeverSentKey owner

directory :: UserID -> InputRetirementSource -> FilePath
directory uid source =
  Publication.hostControllerPublishedDirectory (sourceKind source) uid (sourceKey source)

sourceKind :: InputRetirementSource -> Identity.HostControllerKind
sourceKind source = case source of
  SubmittedSource _ record -> Inputs.hostControllerSubmissionKind record
  NeverSentSource owner -> Publication.hostPublicationNeverSentKind owner

payloadRole :: Payload -> Inputs.HostControllerInputRole
payloadRole Settings = Inputs.ControllerConfiguration
payloadRole Request = Inputs.ControllerRequest

payloadName, quarantineName :: Payload -> String
payloadName Settings = Publication.hostControllerConfigurationName
payloadName Request = Publication.hostControllerRequestName
quarantineName payload = "retirement-" <> payloadName payload

data FoundFile = MissingFile | FoundFile !Fd !FileStatus

withFile
  :: Word64
  -> Fd
  -> String
  -> (FoundFile -> IO (Either InputRetirementError value))
  -> IO (Either InputRetirementError value)
withFile ending parent name action = mask $ \restore -> do
  opened <- runExceptT $ do
    checkTime ending
    lift (try (Posix.openFdAt (Just parent) name Posix.ReadOnly safeFlags))
  case opened of
    Left cause -> pure (Left cause)
    Right (Left (cause :: IOException)) | isDoesNotExistError cause -> do
      available <- runExceptT (checkTime ending)
      either (pure . Left) (const (restore (action MissingFile))) available
    Right (Left cause) -> pure (Left (ioRefusal cause))
    Right (Right fd) ->
      restore
        ( do
            checked <- runExceptT $ checkTime ending >> ExceptT (ownIO (getFdStatus fd))
            either (pure . Left) (action . FoundFile fd) checked
        )
        `finally` Posix.closeFd fd

withPair
  :: Word64
  -> Fd
  -> Payload
  -> (FoundFile -> FoundFile -> IO (Either InputRetirementError value))
  -> IO (Either InputRetirementError value)
withPair ending parent payload action = withFile ending parent (payloadName payload) $ \original ->
  withFile ending parent (quarantineName payload) (action original)

requireOriginal
  :: Word64
  -> UserID
  -> InputRetirementSource
  -> Fd
  -> Payload
  -> ExceptT InputRetirementError IO ()
requireOriginal ending uid record parent payload = ExceptT $ withPair ending parent payload $ \original moved ->
  runExceptT $
    if not (expectsPayload record payload)
      then case (original, moved) of
        (MissingFile, MissingFile) -> pure ()
        _ -> throwE (InputRetirementUnexpectedResidue (payloadRole payload))
      else case (original, moved) of
        (FoundFile _ status, MissingFile) -> verifyPayload uid record parent payload Inputs.InputOriginal status
        (MissingFile, MissingFile)
          | allowsMissingOriginal record -> pure ()
          | otherwise -> throwE (InputRetirementFileMissing (payloadRole payload))
        _ -> throwE (InputRetirementConflictingNames (payloadRole payload))

expectsPayload :: InputRetirementSource -> Payload -> Bool
expectsPayload source payload = case source of
  SubmittedSource _ _ -> True
  NeverSentSource owner -> Publication.hostPublicationNeverSentHasInput owner (payloadRole payload)

allowsMissingOriginal :: InputRetirementSource -> Bool
allowsMissingOriginal source = case source of
  SubmittedSource _ _ -> False
  NeverSentSource owner -> Publication.hostPublicationNeverSentAllowsMissingOriginal owner

retirePayload
  :: Word64
  -> UserID
  -> InputRetirementSource
  -> Fd
  -> Payload
  -> ExceptT InputRetirementError IO ()
retirePayload ending uid record parent payload = ExceptT $ withPair ending parent payload $ \original moved ->
  runExceptT $ do
    verifyRoot ending uid record parent
    verifyPermission ending record
    if not (expectsPayload record payload)
      then requirePayloadAbsent ending parent payload
      else retire original moved
    sync ending parent
    requirePayloadAbsent ending parent payload
 where
  retire original moved = case (original, moved) of
    (MissingFile, MissingFile) -> pure ()
    (FoundFile _ status, MissingFile) -> do
      verifyPayload uid record parent payload Inputs.InputOriginal status
      mutate ending parent (payloadName payload) (quarantineName payload)
      ExceptT $ withFile ending parent (quarantineName payload) $ \found -> runExceptT $ case found of
        MissingFile -> throwE (InputRetirementFileMissing (payloadRole payload))
        FoundFile _ movedStatus -> do
          verifyPayload uid record parent payload Inputs.InputQuarantine movedStatus
          verifyPermission ending record
          removeOwned ending parent (quarantineName payload)
    (MissingFile, FoundFile _ status) -> do
      verifyPayload uid record parent payload Inputs.InputQuarantine status
      verifyPermission ending record
      removeOwned ending parent (quarantineName payload)
    (FoundFile {}, FoundFile {}) -> throwE (InputRetirementConflictingNames (payloadRole payload))

verifyPayload
  :: UserID
  -> InputRetirementSource
  -> Fd
  -> Payload
  -> Inputs.ControllerInputPosition
  -> FileStatus
  -> ExceptT InputRetirementError IO ()
verifyPayload uid record parent payload position status = do
  root <- ExceptT (ownIO (getFdStatus parent))
  unless
    ( safeMetadata uid status
        && fileMatches record (payloadRole payload) position root status
    )
    (throwE (InputRetirementFileChanged (payloadRole payload)))

requirePayloadAbsent :: Word64 -> Fd -> Payload -> ExceptT InputRetirementError IO ()
requirePayloadAbsent ending parent payload = ExceptT $ withPair ending parent payload $ \original moved ->
  pure $ case (original, moved) of
    (MissingFile, MissingFile) -> Right ()
    _ -> Left (InputRetirementUnexpectedResidue (payloadRole payload))

fileMatches
  :: InputRetirementSource
  -> Inputs.HostControllerInputRole
  -> Inputs.ControllerInputPosition
  -> FileStatus
  -> FileStatus
  -> Bool
fileMatches source role position root status = case source of
  SubmittedSource _ record -> Inputs.hostControllerRecordedInputMatches record role position root status
  NeverSentSource owner ->
    Publication.hostPublicationNeverSentParentMatches owner root
      && Publication.hostPublicationNeverSentFileMatches owner role position status

verifyPermission :: Word64 -> InputRetirementSource -> ExceptT InputRetirementError IO ()
verifyPermission ending source = do
  checkTime ending
  ExceptT $ case source of
    SubmittedSource owner _ ->
      fmap
        (either (Left . InputRetirementPhysicalRefused) Right)
        (Retirement.verifyHostOperationRetirementBefore ending owner)
    NeverSentSource owner ->
      fmap
        (either (Left . InputRetirementPublicationRefused) Right)
        (Publication.verifyHostPublicationNeverSentBefore ending owner)

verifyRoot
  :: Word64
  -> UserID
  -> InputRetirementSource
  -> Fd
  -> ExceptT InputRetirementError IO ()
verifyRoot ending uid record parent = do
  checkTime ending
  held <- ExceptT (ownIO (getFdStatus parent))
  linked <- ExceptT (withDirectory ending uid record (ownIO . getFdStatus))
  unless
    (deviceID held == deviceID linked && fileID held == fileID linked)
    (throwE InputRetirementNamespaceRefused)
  mapM_ (verifyRole held) [Settings, Request]
 where
  verifyRole status payload =
    unless
      (parentMatches record payload status)
      (throwE InputRetirementNamespaceRefused)
  parentMatches source payload status = case source of
    SubmittedSource _ original ->
      Inputs.hostControllerRecordedInputPath original (payloadRole payload)
        == Just (directory uid source </> payloadName payload)
        && Inputs.hostControllerRecordedParentMatches original (payloadRole payload) status
    NeverSentSource owner -> Publication.hostPublicationNeverSentParentMatches owner status

withDirectory
  :: Word64
  -> UserID
  -> InputRetirementSource
  -> (Fd -> IO (Either InputRetirementError value))
  -> IO (Either InputRetirementError value)
withDirectory ending uid record action = withDescriptor (Posix.openFd "/" Posix.ReadOnly directoryFlags) $ \root ->
  descend root ["run", "user", show uid, takeFileName (directory uid record)]
 where
  descend parent [] = do
    checked <- runExceptT $ do
      checkTime ending
      status <- ExceptT (ownIO (getFdStatus parent))
      unless
        (isDirectory status && fileOwner status == uid && fileMode status .&. 0o7777 == 0o700)
        (throwE InputRetirementNamespaceRefused)
    either (pure . Left) (const (action parent)) checked
  descend parent (name : rest) = do
    checked <- runExceptT $ do
      checkTime ending
      status <- ExceptT (ownIO (getFdStatus parent))
      let safeParent =
            if name == takeFileName (directory uid record)
              then fileOwner status == uid && fileMode status .&. 0o7777 == 0o700
              else fileOwner status == 0 && fileMode status .&. 0o022 == 0
      unless (isDirectory status && safeParent) (throwE InputRetirementNamespaceRefused)
    case checked of
      Left cause -> pure (Left cause)
      Right () -> withDescriptor (Posix.openFdAt (Just parent) name Posix.ReadOnly directoryFlags) $ \next -> descend next rest

safeFlags, directoryFlags :: Posix.OpenFileFlags
safeFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
directoryFlags = safeFlags {Posix.directory = True}

withDescriptor
  :: IO Fd -> (Fd -> IO (Either InputRetirementError value)) -> IO (Either InputRetirementError value)
withDescriptor acquire action = mask $ \restore -> do
  opened <- ownIO acquire
  case opened of
    Left cause -> pure (Left cause)
    Right fd -> restore (action fd) `finally` Posix.closeFd fd

readMetadata
  :: Word64 -> UserID -> Fd -> String -> IO (Either InputRetirementError (Maybe ByteString))
readMetadata ending uid parent name = withFile ending parent name $ \found -> runExceptT $ case found of
  MissingFile -> pure Nothing
  FoundFile fd before -> do
    unless (safeMetadata uid before && fileSize before <= 69632) (throwE InputRetirementMetadataRefused)
    bytes <- readBounded ending fd [] 0
    after <- ExceptT (ownIO (getFdStatus fd))
    unless (sameVersion before after) (throwE InputRetirementMetadataRefused)
    pure (Just bytes)

readBounded :: Word64 -> Fd -> [ByteString] -> Int -> ExceptT InputRetirementError IO ByteString
readBounded ending fd chunks total = do
  checkTime ending
  result <- lift (try (Native.fdRead fd (fromIntegral (min 4096 (69633 - total)))))
  bytes <- case result of
    Left (cause :: IOException) | isEOFError cause -> pure BS.empty
    Left cause -> throwE (ioRefusal cause)
    Right value -> pure value
  let next = total + BS.length bytes
  when (next > 69632) (throwE InputRetirementMetadataRefused)
  if BS.null bytes
    then pure (BS.concat (reverse chunks))
    else readBounded ending fd (bytes : chunks) next

publishMetadata
  :: Word64 -> UserID -> Fd -> String -> ByteString -> ExceptT InputRetirementError IO ()
publishMetadata ending uid parent name bytes = do
  when (BS.length bytes > 69632) (throwE InputRetirementMetadataRefused)
  checkTime ending
  ExceptT $ withDescriptor acquire $ \fd -> runExceptT $ do
    writeAll fd bytes
    sync ending fd
    let path = "/proc/self/fd/" <> show fd
    linked <- lift $ try $ withCString path $ \source -> withCString name $ \target ->
      throwErrnoIfMinus1Retry
        "input retirement journal link"
        (linkAnonymous currentDirectory source (descriptor parent) target followOwnedDescriptor)
    case linked of
      Left (cause :: IOException) | isAlreadyExistsError cause -> pure ()
      Left cause -> throwE (ioRefusal cause)
      Right _ -> pure ()
    sync ending parent
    confirmed <- ExceptT (readMetadata ending uid parent name)
    unless (confirmed == Just bytes) (throwE InputRetirementJournalMismatch)
 where
  acquire =
    Fd
      <$> withCString
        "."
        ( \path ->
            throwErrnoIfMinus1Retry
              "anonymous input retirement journal"
              (openAnonymous (descriptor parent) path (temporaryFlag .|. readWriteFlag .|. closeExecFlag) 0o400)
        )
  writeAll fd remaining = do
    checkTime ending
    unless (BS.null remaining) $ do
      written <- ExceptT (ownIO (Native.fdWrite fd remaining))
      when (written == 0) (throwE InputRetirementMetadataRefused)
      writeAll fd (BS.drop (fromIntegral written) remaining)

mutate :: Word64 -> Fd -> String -> String -> ExceptT InputRetirementError IO ()
mutate ending parent source target = do
  checkTime ending
  _ <- ExceptT $ ownIO $ withCString source $ \from -> withCString target $ \to ->
    throwErrnoIfMinus1Retry
      "input retirement quarantine"
      (moveFile (descriptor parent) from (descriptor parent) to noReplace)
  sync ending parent

removeOwned :: Word64 -> Fd -> String -> ExceptT InputRetirementError IO ()
removeOwned ending parent name = do
  checkTime ending
  _ <- ExceptT $ ownIO $ withCString name $ \path ->
    throwErrnoIfMinus1Retry "owned input retirement unlink" (removeFileAt (descriptor parent) path 0)
  sync ending parent

sync :: Word64 -> Fd -> ExceptT InputRetirementError IO ()
sync ending fd = checkTime ending >> ExceptT (ownIO (fileSynchronise fd)) >> checkTime ending

safeMetadata :: UserID -> FileStatus -> Bool
safeMetadata uid status =
  isRegularFile status
    && fileOwner status == uid
    && fileMode status .&. 0o7777 == 0o400
    && linkCount status == 1
    && fileSize status >= 0

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion a b =
  deviceID a == deviceID b
    && fileID a == fileID b
    && fileMode a == fileMode b
    && fileOwner a == fileOwner b
    && fileGroup a == fileGroup b
    && linkCount a == linkCount b
    && fileSize a == fileSize b
    && modificationTimeHiRes a == modificationTimeHiRes b
    && statusChangeTimeHiRes a == statusChangeTimeHiRes b

descriptor :: Fd -> CInt
descriptor (Fd fd) = fd

checkTime :: Word64 -> ExceptT InputRetirementError IO ()
checkTime ending = do
  now <- lift getMonotonicTimeNSec
  when (now >= ending) (throwE InputRetirementExpired)

ownIO :: IO value -> IO (Either InputRetirementError value)
ownIO action = either (Left . ioRefusal) Right <$> try action

ioRefusal :: IOException -> InputRetirementError
ioRefusal cause = InputRetirementIoRefused (ioe_type cause) (fromIntegral <$> ioe_errno cause)
