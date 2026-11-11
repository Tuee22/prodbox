{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Descriptor-owned launch inputs. The fingerprint commits only public stat
-- metadata, never executable, configuration or request contents. Neither this
-- local file lease nor its fingerprint grants manager or Authority admission.
module Prodbox.Subprocess.HostControllerInputs
  ( HostControllerInputs
  , HostControllerInputRole (..)
  , HostControllerInputError (..)
  , HostControllerInputFingerprint
  , parseHostControllerInputFingerprint
  , hostControllerInputFingerprintText
  , hostControllerInputFingerprint
  , withHostControllerInputs
  , withPinnedHostControllerInputs
  , verifyHostControllerInputs
  , HostControllerInputBytes
  , readHostControllerInputs
  , readHostControllerInputsWithInitialDataFloor
  , hostControllerConfigurationBytes
  , hostControllerRequestBytes
  , hostControllerExecutablePath
  , hostControllerConfigurationPath
  , hostControllerRequestPath
  , hostControllerInputWorkEnd
  , HostControllerSubmissionRecord
  , registerHostControllerSubmission
  , readHostControllerSubmission
  , encodeHostControllerSubmission
  , decodeHostControllerSubmission
  , hostControllerSubmissionPath
  , hostControllerSubmissionKey
  , hostControllerSubmissionKind
  , hostControllerSubmissionWindow
  , hostControllerSubmissionDomain
  , hostControllerSubmissionSender
  , hostControllerSubmissionFingerprint
  , hostControllerSubmissionProvider
  , ControllerInputPosition (..)
  , hostControllerRecordedInputPath
  , hostControllerRecordedParentMatches
  , hostControllerRecordedInputMatches
  , hostControllerMetadataBytes
  , hostControllerParentMetadataBytes
  , hostControllerFileVersionMatches
  , hostControllerParentVersionMatches
  , HostControllerAnonymousPayloads
  , captureHostControllerAnonymousPayloads
  , encodeHostControllerAnonymousPayloads
  , decodeHostControllerAnonymousPayloads
  , hostControllerAnonymousParentMatches
  , hostControllerAnonymousFileMatches
  ) where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception
  ( IOException
  , bracket
  , finally
  , mask
  , onException
  , try
  , uninterruptibleMask_
  )
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Internal qualified as BSInternal
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Word (Word32, Word64, Word8)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (plusPtr)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Numeric.Natural (Natural)
import Prodbox.Config.SerialiseString (SerialiseString (..))
import Prodbox.Subprocess.InitialRuntimePolicy qualified as InitialRuntime
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import System.Environment (getExecutablePath)
import System.FilePath (isAbsolute, normalise, takeDirectory, takeFileName)
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileGroup
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
import System.Posix.IO.ByteString qualified as NativeIO
import System.Posix.Types (Fd, UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

data HostControllerInputRole
  = ControllerExecutable
  | ControllerConfiguration
  | ControllerRequest
  | ControllerSubmission
  deriving stock (Bounded, Enum, Eq, Show)

data HostControllerInputError
  = ControllerInputsClosed
  | ControllerInputsExpired
  | ControllerInputUnsafe !HostControllerInputRole
  | ControllerInputChanged !HostControllerInputRole
  | ControllerInputTooLarge !HostControllerInputRole
  | ControllerInputRuntimeRefused !Natural
  | ControllerInputFingerprintMismatch
  | ControllerSubmissionExists
  | ControllerSubmissionMalformed
  | ControllerSubmissionMismatch
  | ControllerSubmissionWriteUnconfirmed
  | ControllerSubmissionProviderRefused !Provider.ProviderError
  | ControllerInputIoRefused !HostControllerInputRole !IOErrorType !(Maybe Int)
  deriving stock (Eq, Show)

newtype HostControllerInputFingerprint = HostControllerInputFingerprint String
  deriving stock (Eq)

parseHostControllerInputFingerprint :: String -> Maybe HostControllerInputFingerprint
parseHostControllerInputFingerprint value
  | length (take 65 value) == 64 && all hexadecimal value =
      Just (HostControllerInputFingerprint value)
  | otherwise = Nothing
 where
  hexadecimal c = c >= '0' && c <= '9' || c >= 'a' && c <= 'f'

hostControllerInputFingerprintText :: HostControllerInputFingerprint -> String
hostControllerInputFingerprintText (HostControllerInputFingerprint value) = value

-- Versioned stat fields are encoded explicitly; payload bytes never enter it.
data FileVersion
  = FileVersion
      !Integer
      !Integer
      !Integer
      !Integer
      !Integer
      !Integer
      !Integer
      !(Integer, Integer)
      !(Integer, Integer)
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

data ParentVersion = ParentVersion !Integer !Integer !Integer !Integer
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

-- Public pre-link observations, never a native ownership or cleanup grant.
data HostControllerAnonymousPayloads
  = HostControllerAnonymousPayloads !ParentVersion !FileVersion !FileVersion
  deriving stock (Generic)
  deriving anyclass (Serialise)

captureHostControllerAnonymousPayloads
  :: FileStatus -> FileStatus -> FileStatus -> Maybe HostControllerAnonymousPayloads
captureHostControllerAnonymousPayloads parent configuration request = do
  let observed =
        HostControllerAnonymousPayloads
          (parentVersion parent)
          (fileVersion configuration)
          (fileVersion request)
  if anonymousPayloadsValid observed then Just observed else Nothing

encodeHostControllerAnonymousPayloads :: HostControllerAnonymousPayloads -> ByteString
encodeHostControllerAnonymousPayloads = Lazy.toStrict . serialise

decodeHostControllerAnonymousPayloads :: ByteString -> Maybe HostControllerAnonymousPayloads
decodeHostControllerAnonymousPayloads bytes = do
  unless (BS.length bytes <= 4096) Nothing
  observed <- either (const Nothing) Just (deserialiseOrFail (Lazy.fromStrict bytes))
  unless
    (anonymousPayloadsValid observed && encodeHostControllerAnonymousPayloads observed == bytes)
    Nothing
  pure observed

anonymousPayloadsValid :: HostControllerAnonymousPayloads -> Bool
anonymousPayloadsValid (HostControllerAnonymousPayloads (ParentVersion dev ino uid mode) config request) =
  dev >= 0 && ino > 0 && uid >= 0 && mode == 0o040700 && all valid [config, request]
 where
  valid (FileVersion fileDev fileIno size filePermissions owner group links (mn, md) (cn, cd)) =
    fileDev == dev
      && fileIno > 0
      && size >= 0
      && size <= toInteger maximumInputBytes
      && filePermissions == 0o100400
      && owner == uid
      && group >= 0
      && links == 0
      && mn >= 0
      && md > 0
      && cn >= 0
      && cd > 0

hostControllerAnonymousParentMatches :: HostControllerAnonymousPayloads -> FileStatus -> Bool
hostControllerAnonymousParentMatches (HostControllerAnonymousPayloads expected _ _) observed =
  isDirectory observed && parentVersion observed == expected

-- Linking the recorded anonymous inode gives it one name and changes ctime;
-- the closed quarantine rename can change ctime again. All other fields,
-- including mtime, remain mandatory. Submitted original matching is unchanged.
hostControllerAnonymousFileMatches
  :: HostControllerAnonymousPayloads -> HostControllerInputRole -> FileStatus -> Bool
hostControllerAnonymousFileMatches (HostControllerAnonymousPayloads _ config request) role observed =
  case role of
    ControllerConfiguration -> matches config
    ControllerRequest -> matches request
    ControllerExecutable -> False
    ControllerSubmission -> False
 where
  matches (FileVersion dev ino size mode uid group _ modified _) =
    isRegularFile observed
      && renamedVersion (fileVersion observed) == (dev, ino, size, mode, uid, group, 1, modified)

data HeldInput = HeldInput !HostControllerInputRole !FilePath !Fd !Fd !ParentVersion !FileVersion

data HostControllerInputs
  = HostControllerInputs !Word64 !UserID !HeldInput !HeldInput !HeldInput !(MVar Bool)

type InputMetadata = (Word8, FilePath, ParentVersion, FileVersion)

type WireInputMetadata = (Word8, SerialiseString, ParentVersion, FileVersion)

-- Public provenance only. No constructor, record update, admission or retirement
-- capability escapes; complete original stat metadata survives binary replacement.
data HostControllerSubmissionRecord
  = HostControllerSubmissionRecord
      !Identity.HostExecutionKey
      !Identity.HostExecutionWindow
      !Identity.HostManagerDomain
      !Identity.HostBusUniqueName
      ![InputMetadata]
  | ProviderBoundSubmission !Provider.RecordedProviderBinding !HostControllerSubmissionRecord
  | OrdinaryCascadeSubmission !HostControllerSubmissionRecord
  deriving stock (Eq)

data SubmissionWire
  = SubmissionWire
      !Word8
      !SerialiseString
      ![Word64]
      !SerialiseString
      !SerialiseString
      !SerialiseString
      !Word32
      !Word32
      !Word64
      !SerialiseString
      ![WireInputMetadata]
  deriving stock (Generic)
  deriving anyclass (Serialise)

hostControllerSubmissionKey :: HostControllerSubmissionRecord -> Identity.HostExecutionKey
hostControllerSubmissionKey (HostControllerSubmissionRecord key _ _ _ _) = key
hostControllerSubmissionKey (ProviderBoundSubmission _ record) = hostControllerSubmissionKey record
hostControllerSubmissionKey (OrdinaryCascadeSubmission record) = hostControllerSubmissionKey record

hostControllerSubmissionKind :: HostControllerSubmissionRecord -> Identity.HostControllerKind
hostControllerSubmissionKind HostControllerSubmissionRecord {} = Identity.RpcBirthController
hostControllerSubmissionKind (ProviderBoundSubmission _ record) = hostControllerSubmissionKind record
hostControllerSubmissionKind (OrdinaryCascadeSubmission _) = Identity.OrdinaryCascadeController

hostControllerSubmissionWindow :: HostControllerSubmissionRecord -> Identity.HostExecutionWindow
hostControllerSubmissionWindow (HostControllerSubmissionRecord _ window _ _ _) = window
hostControllerSubmissionWindow (ProviderBoundSubmission _ record) = hostControllerSubmissionWindow record
hostControllerSubmissionWindow (OrdinaryCascadeSubmission record) = hostControllerSubmissionWindow record

hostControllerSubmissionDomain :: HostControllerSubmissionRecord -> Identity.HostManagerDomain
hostControllerSubmissionDomain (HostControllerSubmissionRecord _ _ domain _ _) = domain
hostControllerSubmissionDomain (ProviderBoundSubmission _ record) = hostControllerSubmissionDomain record
hostControllerSubmissionDomain (OrdinaryCascadeSubmission record) = hostControllerSubmissionDomain record

hostControllerSubmissionSender :: HostControllerSubmissionRecord -> Identity.HostBusUniqueName
hostControllerSubmissionSender (HostControllerSubmissionRecord _ _ _ sender _) = sender
hostControllerSubmissionSender (ProviderBoundSubmission _ record) = hostControllerSubmissionSender record
hostControllerSubmissionSender (OrdinaryCascadeSubmission record) = hostControllerSubmissionSender record

hostControllerSubmissionFingerprint
  :: HostControllerSubmissionRecord -> HostControllerInputFingerprint
hostControllerSubmissionFingerprint (HostControllerSubmissionRecord _ _ _ _ metadata) =
  fingerprintMetadata metadata
hostControllerSubmissionFingerprint (ProviderBoundSubmission _ record) = hostControllerSubmissionFingerprint record
hostControllerSubmissionFingerprint (OrdinaryCascadeSubmission record) = hostControllerSubmissionFingerprint record

hostControllerSubmissionProvider
  :: HostControllerSubmissionRecord -> Maybe Provider.RecordedProviderBinding
hostControllerSubmissionProvider HostControllerSubmissionRecord {} = Nothing
hostControllerSubmissionProvider (ProviderBoundSubmission binding _) = Just binding
hostControllerSubmissionProvider (OrdinaryCascadeSubmission record) = hostControllerSubmissionProvider record

submissionMetadata :: HostControllerSubmissionRecord -> [InputMetadata]
submissionMetadata (HostControllerSubmissionRecord _ _ _ _ metadata) = metadata
submissionMetadata (ProviderBoundSubmission _ record) = submissionMetadata record
submissionMetadata (OrdinaryCascadeSubmission record) = submissionMetadata record

data ControllerInputPosition = InputOriginal | InputQuarantine
  deriving stock (Eq, Show)

-- Metadata observations only. Executable/submission roles never participate
-- in payload retirement, and no historical executable is opened here.
recordedPayload :: HostControllerSubmissionRecord -> HostControllerInputRole -> Maybe InputMetadata
recordedPayload record role = case role of
  ControllerExecutable -> Nothing
  ControllerSubmission -> Nothing
  ControllerConfiguration -> select
  ControllerRequest -> select
 where
  select = case [row | row@(tag, _, _, _) <- submissionMetadata record, tag == fromIntegral (fromEnum role)] of
    [row] -> Just row
    _ -> Nothing

hostControllerRecordedInputPath
  :: HostControllerSubmissionRecord -> HostControllerInputRole -> Maybe FilePath
hostControllerRecordedInputPath record role = do
  (_, path, _, _) <- recordedPayload record role
  pure path

hostControllerRecordedParentMatches
  :: HostControllerSubmissionRecord -> HostControllerInputRole -> FileStatus -> Bool
hostControllerRecordedParentMatches record role status = case recordedPayload record role of
  Just (_, _, parent, _) -> isDirectory status && parentVersion status == parent
  Nothing -> False

hostControllerRecordedInputMatches
  :: HostControllerSubmissionRecord
  -> HostControllerInputRole
  -> ControllerInputPosition
  -> FileStatus
  -> FileStatus
  -> Bool
hostControllerRecordedInputMatches record role position parent status = case recordedPayload record role of
  Nothing -> False
  Just (_, _, _, expected) ->
    hostControllerRecordedParentMatches record role parent
      && isRegularFile status
      && case position of
        InputOriginal -> fileVersion status == expected
        InputQuarantine -> renamedVersion (fileVersion status) == renamedVersion expected

-- Public observations only; these helpers create no ownership capability.
hostControllerMetadataBytes
  :: [(HostControllerInputRole, FilePath, FileStatus, FileStatus)] -> ByteString
hostControllerMetadataBytes rows =
  Lazy.toStrict $
    serialise
      [ (fromIntegral (fromEnum role) :: Word8, path, parentVersion parent, fileVersion file)
      | (role, path, parent, file) <- rows
      ]

hostControllerParentMetadataBytes :: FileStatus -> ByteString
hostControllerParentMetadataBytes = Lazy.toStrict . serialise . parentVersion

hostControllerFileVersionMatches :: ControllerInputPosition -> FileStatus -> FileStatus -> Bool
hostControllerFileVersionMatches position expected observed =
  isRegularFile observed && case position of
    InputOriginal -> fileVersion expected == fileVersion observed
    InputQuarantine -> renamedVersion (fileVersion expected) == renamedVersion (fileVersion observed)

hostControllerParentVersionMatches :: FileStatus -> FileStatus -> Bool
hostControllerParentVersionMatches expected observed =
  isDirectory observed && parentVersion expected == parentVersion observed

-- Rename changes ctime; every other original public version field remains mandatory.
renamedVersion
  :: FileVersion -> (Integer, Integer, Integer, Integer, Integer, Integer, Integer, (Integer, Integer))
renamedVersion (FileVersion dev ino size mode uid group links modified _) =
  (dev, ino, size, mode, uid, group, links, modified)

submissionPrefix :: ByteString
submissionPrefix = "prodbox-host-controller-submission/v1\NUL"

maximumSubmissionBytes :: Int
maximumSubmissionBytes = 65536

encodeHostControllerSubmission :: HostControllerSubmissionRecord -> ByteString
encodeHostControllerSubmission (OrdinaryCascadeSubmission record) =
  "prodbox-host-controller-submission/kind/v1\NUL"
    <> Lazy.toStrict (serialise (1 :: Word8, 1 :: Word8, encodeHostControllerSubmission record))
encodeHostControllerSubmission (ProviderBoundSubmission binding record) =
  "prodbox-host-controller-submission/v2\NUL"
    <> Lazy.toStrict
      ( serialise
          (2 :: Word8, encodeHostControllerSubmission record, Provider.encodeProviderBinding binding)
      )
encodeHostControllerSubmission (HostControllerSubmissionRecord key window domain sender metadata) =
  submissionPrefix <> Lazy.toStrict (serialise wire)
 where
  wire =
    SubmissionWire
      1
      (SerialiseString (Identity.hostExecutionKeyText key))
      [ Identity.hostExecutionOuterEnd window
      , Identity.hostExecutionWorkEnd window
      , Identity.hostExecutionHardEnd window
      , Identity.hostExecutionStopEnd window
      , Identity.hostExecutionFinishEnd window
      ]
      (SerialiseString (Identity.hostManagerBootId domain))
      (SerialiseString (Identity.hostManagerBusId domain))
      (SerialiseString (Identity.hostManagerUniqueName domain))
      (Identity.hostManagerUserId domain)
      (Identity.hostManagerProcessId domain)
      (Identity.hostManagerStartTicks domain)
      (SerialiseString (Identity.hostBusUniqueNameText sender))
      [(role, SerialiseString path, parent, version) | (role, path, parent, version) <- metadata]

decodeHostControllerSubmission
  :: ByteString -> Either HostControllerInputError HostControllerSubmissionRecord
decodeHostControllerSubmission bytes
  | BS.length bytes > maximumSubmissionBytes = Left (ControllerInputTooLarge ControllerSubmission)
  | Just payload <- BS.stripPrefix "prodbox-host-controller-submission/kind/v1\NUL" bytes = do
      (version, kind, original) <-
        either
          (const (Left ControllerSubmissionMalformed))
          Right
          (deserialiseOrFail (Lazy.fromStrict payload))
      unless
        ( version == (1 :: Word8)
            && kind == (1 :: Word8)
            && "prodbox-host-controller-submission/v2\NUL" `BS.isPrefixOf` original
        )
        (Left ControllerSubmissionMalformed)
      record <- decodeHostControllerSubmission original
      let bound = OrdinaryCascadeSubmission record
      unless (encodeHostControllerSubmission bound == bytes) (Left ControllerSubmissionMalformed)
      pure bound
  | Just payload <- BS.stripPrefix "prodbox-host-controller-submission/v2\NUL" bytes = do
      (version, original, encodedBinding) <-
        either
          (const (Left ControllerSubmissionMalformed))
          Right
          (deserialiseOrFail (Lazy.fromStrict payload))
      unless
        (version == (2 :: Word8) && submissionPrefix `BS.isPrefixOf` original)
        (Left ControllerSubmissionMalformed)
      record <- decodeHostControllerSubmission original
      binding <-
        either
          (Left . ControllerSubmissionProviderRefused)
          Right
          (Provider.decodeProviderBinding encodedBinding)
      let bound = ProviderBoundSubmission binding record
      unless (encodeHostControllerSubmission bound == bytes) (Left ControllerSubmissionMalformed)
      pure bound
  | otherwise = decodeLegacySubmission bytes

decodeLegacySubmission
  :: ByteString -> Either HostControllerInputError HostControllerSubmissionRecord
decodeLegacySubmission bytes = do
  unless
    (BS.length bytes <= maximumSubmissionBytes)
    (Left (ControllerInputTooLarge ControllerSubmission))
  payload <- maybe malformed Right (BS.stripPrefix submissionPrefix bytes)
  wire <- either (const malformed) Right (deserialiseOrFail (Lazy.fromStrict payload))
  case wire of
    SubmissionWire
      version
      (SerialiseString key)
      clocks
      (SerialiseString boot)
      (SerialiseString bus)
      (SerialiseString manager)
      user
      pid
      ticks
      (SerialiseString name)
      wireMetadata -> do
        let metadata = [(role, path, parent, file) | (role, SerialiseString path, parent, file) <- wireMetadata]
        unless (version == 1) malformed
        coordinate <- maybe malformed Right (Identity.hostExecutionKeyFromText key)
        window <- case clocks of
          [outer, work, hard, stop, finish] ->
            maybe malformed Right (Identity.hostExecutionWindow outer work hard stop finish)
          _ -> malformed
        domain <- maybe malformed Right (Identity.hostManagerDomain boot bus manager user pid ticks)
        sender <- maybe malformed Right (Identity.hostBusUniqueName name)
        unless (map (\(role, _, _, _) -> role) metadata == [0, 1, 2]) malformed
        unless (all metadataWellFormed metadata) malformed
        let record = HostControllerSubmissionRecord coordinate window domain sender metadata
        unless (encodeHostControllerSubmission record == bytes) malformed
        pure record
 where
  malformed :: Either HostControllerInputError value
  malformed = Left ControllerSubmissionMalformed
  metadataWellFormed
    ( role
      , path
      , ParentVersion dev ino user mode
      , FileVersion fdev fino size fmode owner group links (_, md) (_, cd)
      ) =
      validPath path
        && dev >= 0
        && ino > 0
        && user >= 0
        && mode >= 0
        && mode .&. 0o170000 == 0o040000
        && fdev >= 0
        && fino > 0
        && size >= 0
        && owner >= 0
        && group >= 0
        && links > 0
        && fmode .&. 0o170000 == 0o100000
        && md > 0
        && cd > 0
        && (role == 0 || size <= toInteger maximumInputBytes)

hostControllerSubmissionPath :: FilePath -> Identity.HostExecutionKey -> FilePath
hostControllerSubmissionPath request key =
  takeDirectory request <> "/submission-" <> Identity.hostExecutionKeyText key <> ".cbor"

-- Exclusive publication is the cross-process attempt fence. A partial file is
-- retained on every failure; it can never be overwritten into a retry permit.
registerHostControllerSubmission
  :: Identity.HostControllerKind
  -> HostControllerInputs
  -> Identity.HostExecutionKey
  -> Identity.HostExecutionWindow
  -> Identity.HostManagerDomain
  -> Identity.HostBusUniqueName
  -> Provider.QualifiedProvider
  -> IO (Either HostControllerInputError HostControllerSubmissionRecord)
registerHostControllerSubmission kind inputs@(HostControllerInputs ending uid executable configuration request active) key window domain sender provider =
  withMVar active $ \live ->
    if not live
      then pure (Left ControllerInputsClosed)
      else runExceptT $ do
        ExceptT (validateInputs inputs)
        ExceptT
          ( fmap
              (either (Left . ControllerSubmissionProviderRefused) Right)
              (Provider.verifyQualifiedProviderBefore ending provider)
          )
        unless
          ( ending == Identity.hostExecutionWorkEnd window
              && toInteger uid == toInteger (Identity.hostManagerUserId domain)
              && validPath path
              && domain == Provider.qualifiedProviderDomain provider
          )
          (throwE ControllerSubmissionMismatch)
        let record =
              bindKind $
                ProviderBoundSubmission
                  (Provider.qualifiedProviderBinding provider)
                  ( HostControllerSubmissionRecord
                      key
                      window
                      domain
                      sender
                      (map inputMetadata [executable, configuration, request])
                  )
            bytes = encodeHostControllerSubmission record
        when
          (BS.length bytes > maximumSubmissionBytes)
          (throwE (ControllerInputTooLarge ControllerSubmission))
        ExceptT (publish bytes)
        ExceptT (validateInputs inputs)
        pure record
 where
  bindKind = case kind of
    Identity.RpcBirthController -> id
    Identity.OrdinaryCascadeController -> OrdinaryCascadeSubmission
  HeldInput _ requestPath parent _ expectedParent _ = request
  path = hostControllerSubmissionPath requestPath key
  publish bytes = mask $ \restore -> do
    acquired <-
      try
        ( Posix.openFdAt
            (Just parent)
            (takeFileName path)
            Posix.ReadWrite
            safeFlags {Posix.creat = Just 0o400, Posix.exclusive = True}
        )
    case acquired of
      Left (cause :: IOException)
        | isAlreadyExistsError cause -> pure (Left ControllerSubmissionExists)
        | otherwise -> ownIO ControllerSubmission (ioError cause)
      Right file ->
        restore
          ( runExceptT $ do
              ExceptT (writeSubmissionBytes ending file bytes)
              ExceptT (ownIO ControllerSubmission (fileSynchronise file >> fileSynchronise parent))
              status <- ExceptT (ownIO ControllerSubmission (getFdStatus file))
              let held = HeldInput ControllerSubmission path parent file expectedParent (fileVersion status)
              ExceptT (validateHeldInput ending uid held)
              observed <- ExceptT (readHeldInput ending held)
              unless (observed == bytes) (throwE ControllerSubmissionWriteUnconfirmed)
              ExceptT (validateHeldInput ending uid held)
          )
          `finally` Posix.closeFd file

writeSubmissionBytes :: Word64 -> Fd -> ByteString -> IO (Either HostControllerInputError ())
writeSubmissionBytes ending file bytes = runExceptT $ do
  ExceptT (checkTime ending)
  unless (BS.null bytes) $ do
    written <- ExceptT (ownIO ControllerSubmission (NativeIO.fdWrite file bytes))
    when (written == 0) (throwE ControllerSubmissionWriteUnconfirmed)
    ExceptT (writeSubmissionBytes ending file (BS.drop (fromIntegral written) bytes))

-- Fresh reads may outlive the old work window. They return metadata only and
-- never open the historical executable or construct another effect intent.
readHostControllerSubmission
  :: Word64
  -> FilePath
  -> Identity.HostExecutionKey
  -> IO (Either HostControllerInputError HostControllerSubmissionRecord)
readHostControllerSubmission ending request key
  | not (validPath request) = pure (Left (ControllerInputUnsafe ControllerRequest))
  | otherwise = do
      uid <- getEffectiveUserID
      withHeldInput ending uid ControllerSubmission (hostControllerSubmissionPath request key) $ \held -> runExceptT $ do
        bytes <- ExceptT (readHeldInput ending held)
        ExceptT (validateHeldInput ending uid held)
        record <- either throwE pure (decodeHostControllerSubmission bytes)
        unless (hostControllerSubmissionKey record == key) (throwE ControllerSubmissionMismatch)
        case submissionMetadata record of
          [_, _, (_, original, _, _)] ->
            unless (original == request) (throwE ControllerSubmissionMismatch)
          _ -> throwE ControllerSubmissionMalformed
        pure record

-- No Show instance: these may contain credential material in a future mounted
-- configuration. The caller must fund retained/decoded bytes independently.
data HostControllerInputBytes = HostControllerInputBytes !ByteString !ByteString

hostControllerConfigurationBytes :: HostControllerInputBytes -> ByteString
hostControllerConfigurationBytes (HostControllerInputBytes configuration _) = configuration

hostControllerRequestBytes :: HostControllerInputBytes -> ByteString
hostControllerRequestBytes (HostControllerInputBytes _ request) = request

withHostControllerInputs
  :: Word64
  -> FilePath
  -> FilePath
  -> (HostControllerInputs -> IO value)
  -> IO (Either HostControllerInputError value)
withHostControllerInputs ending configuration request action = do
  executable <- ownIO ControllerExecutable getExecutablePath
  case executable of
    Left cause -> pure (Left cause)
    Right path -> do
      uid <- getEffectiveUserID
      withHeldInput ending uid ControllerExecutable path $ \program ->
        withHeldInput ending uid ControllerConfiguration configuration $ \config ->
          withHeldInput ending uid ControllerRequest request $ \command -> do
            self <- checkExecutingFile program
            case self of
              Left cause -> pure (Left cause)
              Right () -> do
                active <- newMVar True
                let inputs = HostControllerInputs ending uid program config command active
                Right <$> action inputs `finally` uninterruptibleMask_ (modifyMVar_ active (const (pure False)))

withPinnedHostControllerInputs
  :: Word64
  -> HostControllerInputFingerprint
  -> FilePath
  -> FilePath
  -> (HostControllerInputs -> IO value)
  -> IO (Either HostControllerInputError value)
withPinnedHostControllerInputs ending expected configuration request action = do
  admitted <- withHostControllerInputs ending configuration request $ \inputs ->
    if hostControllerInputFingerprint inputs == expected
      then Right <$> action inputs
      else pure (Left ControllerInputFingerprintMismatch)
  pure (admitted >>= id)

hostControllerInputWorkEnd :: HostControllerInputs -> Word64
hostControllerInputWorkEnd (HostControllerInputs ending _ _ _ _ _) = ending

hostControllerExecutablePath
  , hostControllerConfigurationPath
  , hostControllerRequestPath
    :: HostControllerInputs -> FilePath
hostControllerExecutablePath (HostControllerInputs _ _ (HeldInput _ path _ _ _ _) _ _ _) = path
hostControllerConfigurationPath (HostControllerInputs _ _ _ (HeldInput _ path _ _ _ _) _ _) = path
hostControllerRequestPath (HostControllerInputs _ _ _ _ (HeldInput _ path _ _ _ _) _) = path

hostControllerInputFingerprint :: HostControllerInputs -> HostControllerInputFingerprint
hostControllerInputFingerprint (HostControllerInputs _ _ executable configuration request _) =
  fingerprintMetadata (map inputMetadata [executable, configuration, request])

inputMetadata :: HeldInput -> InputMetadata
inputMetadata (HeldInput role path _ _ parent version) = (fromIntegral (fromEnum role), path, parent, version)

fingerprintMetadata :: [InputMetadata] -> HostControllerInputFingerprint
fingerprintMetadata metadata =
  HostControllerInputFingerprint (concatMap hexadecimal (BS.unpack digest))
 where
  digest =
    SHA256.hash
      ( Lazy.toStrict
          ( serialise
              ( "prodbox-host-controller-input-metadata/v1" :: Text
              , metadata
              )
          )
      )
  hexadecimal byte =
    [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
    , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
    ]

withHeldInput
  :: Word64
  -> UserID
  -> HostControllerInputRole
  -> FilePath
  -> (HeldInput -> IO (Either HostControllerInputError value))
  -> IO (Either HostControllerInputError value)
withHeldInput ending uid role path action
  | not (validPath path) = pure (Left (ControllerInputUnsafe role))
  | otherwise = mask $ \restore -> do
      available <- checkTime ending
      case available of
        Left cause -> pure (Left cause)
        Right () -> do
          acquired <- ownIO role $ do
            parent <- Posix.openFd (takeDirectory path) Posix.ReadOnly (safeFlags {Posix.directory = True})
            let releaseParent = Posix.closeFd parent
            file <-
              Posix.openFdAt (Just parent) (takeFileName path) Posix.ReadOnly safeFlags
                `onException` releaseParent
            let release = Posix.closeFd file `finally` releaseParent
            ( do
                parentStatus <- getFdStatus parent
                status <- getFdStatus file
                pure (HeldInput role path parent file (parentVersion parentStatus) (fileVersion status))
              )
              `onException` release
          case acquired of
            Left cause -> pure (Left cause)
            Right held@(HeldInput _ _ parent file _ _) ->
              restore
                ( do
                    checked <- validateHeldInput ending uid held
                    either (pure . Left) (const (action held)) checked
                )
                `finally` (Posix.closeFd file `finally` Posix.closeFd parent)
validPath :: FilePath -> Bool
validPath value =
  length (take 4097 value) <= 4096
    && '\0' `notElem` value
    && isAbsolute value
    && normalise value == value
    && takeFileName value `notElem` ["", ".", ".."]

safeFlags :: Posix.OpenFileFlags
safeFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

fileVersion :: FileStatus -> FileVersion
fileVersion status =
  FileVersion
    (toInteger (deviceID status))
    (toInteger (fileID status))
    (toInteger (fileSize status))
    (toInteger (fileMode status))
    (toInteger (fileOwner status))
    (toInteger (fileGroup status))
    (toInteger (linkCount status))
    (fraction (modificationTimeHiRes status))
    (fraction (statusChangeTimeHiRes status))
 where
  fraction time = let value = toRational time in (numerator value, denominator value)

-- Sibling files may be created during work. Directory identity/owner/mode is
-- stable; its modification time and link count are not an input-file version.
parentVersion :: FileStatus -> ParentVersion
parentVersion status =
  ParentVersion
    (toInteger (deviceID status))
    (toInteger (fileID status))
    (toInteger (fileOwner status))
    (toInteger (fileMode status))

validateHeldInput :: Word64 -> UserID -> HeldInput -> IO (Either HostControllerInputError ())
validateHeldInput ending uid (HeldInput role path parent file expectedParent expectedFile) = runExceptT $ do
  ExceptT (checkTime ending)
  status <- ExceptT (ownIO role (getFdStatus file))
  parentStatus <- ExceptT (ownIO role (getFdStatus parent))
  linked <- ExceptT (ownIO role (getSymbolicLinkStatus path))
  linkedParent <- ExceptT (ownIO role (getSymbolicLinkStatus (takeDirectory path)))
  let permissions value = fileMode value .&. 0o7777
      trustedOwner value = fileOwner value == uid || role == ControllerExecutable && fileOwner value == 0
      parentSafe =
        isDirectory parentStatus
          && trustedOwner parentStatus
          && ( if role == ControllerExecutable
                 then permissions parentStatus .&. 0o022 == 0
                 else permissions parentStatus == 0o700
             )
      fileSafe =
        isRegularFile status
          && trustedOwner status
          && ( if role == ControllerExecutable
                 then permissions status .&. 0o7022 == 0 && permissions status .&. 0o100 /= 0
                 else permissions status `elem` [0o400, 0o600] && linkCount status == 1
             )
  unless (parentSafe && fileSafe) (throwE (ControllerInputUnsafe role))
  when (fileSize status < 0) (throwE (ControllerInputUnsafe role))
  when
    (role /= ControllerExecutable && toInteger (fileSize status) > toInteger (inputByteLimit role))
    (throwE (ControllerInputTooLarge role))
  unless
    ( isDirectory linkedParent
        && isRegularFile linked
        && parentVersion parentStatus == expectedParent
        && parentVersion linkedParent == expectedParent
        && fileVersion status == expectedFile
        && fileVersion linked == expectedFile
    )
    (throwE (ControllerInputChanged role))
  when
    (role == ControllerSubmission && permissions status /= 0o400)
    (throwE (ControllerInputUnsafe role))
  ExceptT (checkTime ending)

checkExecutingFile :: HeldInput -> IO (Either HostControllerInputError ())
checkExecutingFile (HeldInput role _ _ _ _ expected) = do
  -- This one compiled procfs link denotes the running image; input paths never
  -- follow links. Compare its opened descriptor rather than trusting its text.
  observed <-
    ownIO role $
      bracket
        ( Posix.openFd
            "/proc/self/exe"
            Posix.ReadOnly
            (Posix.defaultFileFlags {Posix.cloexec = True, Posix.nonBlock = True})
        )
        Posix.closeFd
        (fmap fileVersion . getFdStatus)
  pure $ case observed of
    Left cause -> Left cause
    Right current | current == expected -> Right ()
    Right _ -> Left (ControllerInputChanged ControllerExecutable)

verifyHostControllerInputs :: HostControllerInputs -> IO (Either HostControllerInputError ())
verifyHostControllerInputs inputs@(HostControllerInputs _ _ _ _ _ active) = withMVar active $ \live ->
  if live then validateInputs inputs else pure (Left ControllerInputsClosed)

validateInputs :: HostControllerInputs -> IO (Either HostControllerInputError ())
validateInputs (HostControllerInputs ending uid executable configuration request _) = runExceptT $ do
  mapM_ (ExceptT . validateHeldInput ending uid) [executable, configuration, request]
  ExceptT (checkExecutingFile executable)

-- A rejection ceiling for each serialized input, not a runtime-memory grant.
-- The actual loader still owns schema validation and decoded-state admission.
maximumInputBytes :: Int
maximumInputBytes = 1024 * 1024

inputByteLimit :: HostControllerInputRole -> Int
inputByteLimit role = if role == ControllerSubmission then maximumSubmissionBytes else maximumInputBytes

readHostControllerInputs
  :: HostControllerInputs -> IO (Either HostControllerInputError HostControllerInputBytes)
readHostControllerInputs = readInputs ExistingRead

-- The trusted caller supplies its minimum data floor with both zero-payload
-- originating buffer headers already included. Held sizes add only rounded
-- payloads. No bytes, serialized capacity or callback supplies this demand.
-- Successful policy observation grants neither free heap nor admission.
readHostControllerInputsWithInitialDataFloor
  :: Natural -> HostControllerInputs -> IO (Either HostControllerInputError HostControllerInputBytes)
readHostControllerInputsWithInitialDataFloor floorBytes = readInputs (InitialDataRead floorBytes)

data InputReadPolicy = ExistingRead | InitialDataRead !Natural

readInputs
  :: InputReadPolicy
  -> HostControllerInputs
  -> IO (Either HostControllerInputError HostControllerInputBytes)
readInputs policy inputs@(HostControllerInputs ending _ _ configuration request active) = withMVar active $ \live ->
  if not live
    then pure (Left ControllerInputsClosed)
    else runExceptT $ do
      ExceptT (validateInputs inputs)
      case policy of
        ExistingRead -> pure ()
        InitialDataRead floorBytes -> do
          configPayload <- either throwE pure (heldPayloadBytes configuration)
          requestPayload <- either throwE pure (heldPayloadBytes request)
          let required = floorBytes + configPayload + requestPayload
          observed <-
            ExceptT
              (ownIO ControllerConfiguration (InitialRuntime.verifyInitialRuntimePolicyBefore ending required))
          case observed of
            Left InitialRuntime.InitialRuntimePolicyExpired -> throwE ControllerInputsExpired
            Left InitialRuntime.InitialRuntimePolicyRefused -> throwE (ControllerInputRuntimeRefused required)
            Right () -> pure ()
      configBytes <- ExceptT (readHeldInput ending configuration)
      requestBytes <- ExceptT (readHeldInput ending request)
      ExceptT (validateInputs inputs)
      pure (HostControllerInputBytes configBytes requestBytes)

-- These are the same held versions revalidated before and after both reads.
-- The payload allocator never exceeds their sizes, even if a file changes.
heldPayloadBytes :: HeldInput -> Either HostControllerInputError Natural
heldPayloadBytes (HeldInput role _ _ _ _ (FileVersion _ _ expected _ _ _ _ _ _))
  | expected < 0 = Left (ControllerInputUnsafe role)
  | expected > toInteger (inputByteLimit role) = Left (ControllerInputTooLarge role)
  | otherwise = Right (8 * ((fromInteger expected + 7) `div` 8))

-- The held stat version fixes the exact payload size. Allocate that size once,
-- then probe EOF with one stack byte; the rejection ceiling is never scratch.
-- A short read or extra byte refuses before any partial buffer can escape.
readHeldInput :: Word64 -> HeldInput -> IO (Either HostControllerInputError ByteString)
readHeldInput ending (HeldInput role _ _ file _ (FileVersion _ _ expected _ _ _ _ _ _))
  | expected < 0 = pure (Left (ControllerInputUnsafe role))
  | expected > toInteger (inputByteLimit role) = pure (Left (ControllerInputTooLarge role))
  | otherwise = do
      let expectedBytes = fromInteger expected
      failure <- newIORef Nothing
      attempted <- ownIO role $ do
        _ <- Posix.fdSeek file AbsoluteSeek 0
        BSInternal.create expectedBytes $ \buffer -> do
          let refuse cause = writeIORef failure (Just cause)
              finish = allocaBytes 1 $ \sentinel -> do
                obtained <- Posix.fdReadBuf file sentinel 1
                when (obtained /= 0) $
                  refuse $
                    if expectedBytes == inputByteLimit role
                      then ControllerInputTooLarge role
                      else ControllerInputChanged role
              loop count = do
                available <- checkTime ending
                case available of
                  Left cause -> refuse cause
                  Right ()
                    | count == expectedBytes -> finish
                    | otherwise -> do
                        obtained <-
                          Posix.fdReadBuf
                            file
                            (buffer `plusPtr` count)
                            (fromIntegral (min 8192 (expectedBytes - count)))
                        if obtained == 0
                          then refuse (ControllerInputChanged role)
                          else loop (count + fromIntegral obtained)
          loop 0
      refused <- readIORef failure
      pure $ case (attempted, refused) of
        (Left cause, _) -> Left cause
        (_, Just cause) -> Left cause
        (Right bytes, Nothing) -> Right bytes

checkTime :: Word64 -> IO (Either HostControllerInputError ())
checkTime ending = do
  now <- getMonotonicTimeNSec
  pure (if now < ending then Right () else Left ControllerInputsExpired)

ownIO :: HostControllerInputRole -> IO value -> IO (Either HostControllerInputError value)
ownIO role action = do
  result <- try action
  pure $ case result of
    Left cause ->
      Left
        (ControllerInputIoRefused role (ioe_type (cause :: IOException)) (fromIntegral <$> ioe_errno cause))
    Right value -> Right value
