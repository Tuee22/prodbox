{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Non-authorizing, write-ahead binding for the ordinary scope submission.
-- Only public identity metadata is encoded. A stored OperationId is a recovery
-- coordinate, never an AWS-scope proof: the Authority must confirm completion.
-- The complete controller request and retirement admission remain separate.
module Prodbox.Lifecycle.Teardown.OrdinaryScopeJournal
  ( OrdinaryScopeBinding
  , OrdinaryScopeJournal
  , OrdinaryScopeJournalError (..)
  , mkOrdinaryScopeBinding
  , encodeOrdinaryScopeBinding
  , decodeOrdinaryScopeBinding
  , ordinaryScopeBindingSubmissionKey
  , ordinaryScopeBindingMatchesCaller
  , ordinaryScopeBindingMatchesParent
  , ordinaryScopeBindingMatchesProgram
  , ordinaryScopeBindingMatchesDomain
  , ordinaryScopeBindingNormalFormBytes
  , withOrdinaryScopeJournal
  , prepareOrdinaryScopeSubmission
  , prepareBoundOrdinaryScopeSubmission
  , observeBoundOrdinaryScopeSubmission
  , bindOrdinaryScopeOperation
  , maximumOrdinaryScopeJournalBytes
  ) where

import Prodbox.Capacity.BoxedNormalForm

import Codec.CBOR.Decoding qualified as Cbor
import Codec.Serialise (Serialise (..), deserialiseOrFail, serialise)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception (IOException, bracket, finally, mask, try, uninterruptibleMask_)
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as BytesText
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.SerialiseString (SerialiseString (..))
import Prodbox.ControlPlane.CallerPrincipal
import Prodbox.ControlPlane.RequestAuthentication (SigningKeyGeneration, signingKeyGenerationValue)
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.Config (ConfigDigest (..))
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.CleanupRun (CleanupRunId, cleanupRunIdText, mkCleanupRunId)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Subprocess.SystemdIdentity
import System.Directory (canonicalizePath, removeFile)
import System.FilePath (isAbsolute, normalise, (</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Directory qualified as Posix
import System.Posix.Files
import System.Posix.IO
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

-- Physical coordinates retain native widths; logical counters use Natural.
-- An outer byte bound precedes public field validation.
-- Canonical re-encoding below rejects alternate/trailing CBOR representations.
data ScopeWire
  = ScopeWire
      !Word32
      !Text
      !String
      !Word64
      !Word64
      !Word64
      !Word64
      !Word64
      !String
      !String
      !String
      !Word32
      !Word32
      !Word64
      !Natural
      !Text
      !ByteString
      !Word
      !Natural
      !ByteString
  deriving stock (Eq, Generic)

-- Retain the SDK's exact Generic product encoder and in-memory field types.
-- Only String decoding changes: the SDK's generalized UTF8 traversal is
-- reached after payload validation, before canonical read-back forces it.
instance Serialise ScopeWire where
  decode = do
    fields <- Cbor.decodeListLen
    unless (fields == 21) (fail "invalid ordinary scope field count")
    tag <- Cbor.decodeWord
    unless (tag == 0) (fail "invalid ordinary scope constructor")
    ScopeWire
      <$> decode
      <*> decode
      <*> checkedString
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> checkedString
      <*> checkedString
      <*> checkedString
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode
      <*> decode

checkedString :: Cbor.Decoder s String
checkedString = serialiseStringValue <$> decode

newtype OrdinaryScopeBinding = ScopeBinding ScopeWire deriving (Eq)

data ScopeProgramWire = ScopeProgramWire !Word32 !ByteString !ByteString
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

data ScopeOperationWire = ScopeOperationWire !Word32 !ByteString !OperationId
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

-- The directory descriptor stays held for the whole borrowing continuation.
data JournalUses = JournalOpen !Natural | JournalClosing !Natural

data OrdinaryScopeJournal = ScopeJournal !Fd !(TVar JournalUses)

data OrdinaryScopeJournalError
  = ScopeJournalBindingInvalid
  | ScopeJournalEncodingInvalid
  | ScopeJournalEncodingTooLarge
  | ScopeJournalCallerChanged
  | ScopeJournalParentChanged
  | ScopeJournalDirectoryUnsafe
  | ScopeJournalClosed
  | ScopeJournalFileUnsafe
  | ScopeJournalRequestConflict
  | ScopeJournalOperationConflict
  | ScopeJournalRequestMissing
  | ScopeJournalProgramBindingMissing
  | ScopeJournalProgramConflict
  | ScopeJournalReadBackMismatch
  | ScopeJournalWriteNoProgress
  | ScopeJournalIoFailure !String
  deriving (Eq, Show)

maximumOrdinaryScopeJournalBytes :: Int
maximumOrdinaryScopeJournalBytes = 4096

mkOrdinaryScopeBinding
  :: CleanupRunId
  -> HostExecutionKey
  -> HostExecutionWindow
  -> HostManagerDomain
  -> AuthorityTime
  -> ConfigDigest
  -> ByteString
  -> CallerPrincipal
  -> SigningKeyGeneration
  -> ByteString
  -> Either OrdinaryScopeJournalError OrdinaryScopeBinding
mkOrdinaryScopeBinding run key window domain deadline (ConfigDigest config) nonce principal generation publicKey = do
  let logical = signingKeyGenerationValue generation
      end = authorityTimeMicros deadline
  checkedBinding $
    ScopeWire
      1
      (cleanupRunIdText run)
      (hostExecutionKeyText key)
      (hostExecutionOuterEnd window)
      (hostExecutionWorkEnd window)
      (hostExecutionHardEnd window)
      (hostExecutionStopEnd window)
      (hostExecutionFinishEnd window)
      (hostManagerBootId domain)
      (hostManagerBusId domain)
      (hostManagerUniqueName domain)
      (hostManagerUserId domain)
      (hostManagerProcessId domain)
      (hostManagerStartTicks domain)
      end
      config
      nonce
      (callerPrincipalCode principal)
      logical
      publicKey

checkedBinding :: ScopeWire -> Either OrdinaryScopeJournalError OrdinaryScopeBinding
checkedBinding
  wire@( ScopeWire
           version
           run
           key
           outer
           work
           hard
           stop
           finish
           boot
           bus
           unique
           uid
           pid
           ticks
           deadline
           config
           nonce
           principal
           generation
           publicKey
         ) = do
    unless
      ( version == 1
          && deadline > 0
          && generation > 0
          && Text.length config == 64
          && Text.all lowerHex config
          && Bytes.length nonce == 32
          && Bytes.length publicKey == 32
          && callerPrincipalFromCode principal `elem` [Just CallerOperatorCli, Just CallerTestHarness]
      )
      (Left ScopeJournalBindingInvalid)
    _ <- either (const (Left ScopeJournalBindingInvalid)) Right (mkCleanupRunId run)
    _ <- maybe (Left ScopeJournalBindingInvalid) Right (hostExecutionKeyFromText key)
    _ <- maybe (Left ScopeJournalBindingInvalid) Right (hostExecutionWindow outer work hard stop finish)
    _ <- maybe (Left ScopeJournalBindingInvalid) Right (hostManagerDomain boot bus unique uid pid ticks)
    _ <- submissionKey run
    let binding = ScopeBinding wire
    unless
      (Bytes.length (encodeOrdinaryScopeBinding binding) <= maximumOrdinaryScopeJournalBytes)
      (Left ScopeJournalEncodingTooLarge)
    pure $! compactBinding wire
   where
    lowerHex c = c >= '0' && c <= '9' || c >= 'a' && c <= 'f'

encodeOrdinaryScopeBinding :: OrdinaryScopeBinding -> ByteString
encodeOrdinaryScopeBinding (ScopeBinding wire) = Lazy.toStrict (serialise wire)

decodeOrdinaryScopeBinding :: ByteString -> Either OrdinaryScopeJournalError OrdinaryScopeBinding
decodeOrdinaryScopeBinding bytes = do
  wire <- decodeCanonical bytes
  checkedBinding wire

decodeCanonical :: (Serialise value) => ByteString -> Either OrdinaryScopeJournalError value
decodeCanonical bytes = do
  unless (Bytes.length bytes <= maximumOrdinaryScopeJournalBytes) (Left ScopeJournalEncodingTooLarge)
  value <-
    either (const (Left ScopeJournalEncodingInvalid)) Right (deserialiseOrFail (Lazy.fromStrict bytes))
  unless (Lazy.toStrict (serialise value) == bytes) (Left ScopeJournalEncodingInvalid)
  pure value

submissionKey :: Text -> Either OrdinaryScopeJournalError ClientSubmissionKey
submissionKey run =
  either
    (const (Left ScopeJournalBindingInvalid))
    Right
    (mkClientSubmissionKey ("cascade-scope:" <> run))

ordinaryScopeBindingSubmissionKey
  :: OrdinaryScopeBinding -> Either OrdinaryScopeJournalError ClientSubmissionKey
ordinaryScopeBindingSubmissionKey (ScopeBinding (ScopeWire _ run _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _)) = submissionKey run

ordinaryScopeBindingMatchesCaller
  :: CallerPrincipal -> SigningKeyGeneration -> ByteString -> OrdinaryScopeBinding -> Bool
ordinaryScopeBindingMatchesCaller
  principal
  generation
  publicKey
  (ScopeBinding (ScopeWire _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ p g k)) =
    callerPrincipalCode principal == p
      && signingKeyGenerationValue generation == fromIntegral g
      && publicKey == k

ordinaryScopeBindingMatchesParent
  :: HostExecutionKey -> HostExecutionWindow -> OrdinaryScopeBinding -> Bool
ordinaryScopeBindingMatchesParent
  key
  window
  (ScopeBinding (ScopeWire _ _ stored outer work hard stop finish _ _ _ _ _ _ _ _ _ _ _ _)) =
    hostExecutionKeyText key == stored && hostExecutionWindow outer work hard stop finish == Just window

ordinaryScopeBindingMatchesProgram
  :: CleanupRunId -> AuthorityTime -> ByteString -> OrdinaryScopeBinding -> Bool
ordinaryScopeBindingMatchesProgram
  run
  deadline
  nonce
  (ScopeBinding (ScopeWire _ storedRun _ _ _ _ _ _ _ _ _ _ _ _ storedEnd _ storedNonce _ _ _)) =
    cleanupRunIdText run == storedRun
      && authorityTimeMicros deadline == fromIntegral storedEnd
      && nonce == storedNonce

-- Process locks alone do not exclude sibling Haskell threads. The short local
-- filesystem critical sections also share this mutex; no network call holds it.
{-# NOINLINE journalMutex #-}
journalMutex :: MVar ()
journalMutex = unsafePerformIO (newMVar ())

withOrdinaryScopeJournal
  :: FilePath -> (OrdinaryScopeJournal -> IO value) -> IO (Either OrdinaryScopeJournalError value)
withOrdinaryScopeJournal control action = catchIo $ runExceptT $ do
  unless
    (isAbsolute control && normalise control == control && control /= "/")
    (throwE ScopeJournalDirectoryUnsafe)
  canonical <- io (canonicalizePath control)
  unless (canonical == control) (throwE ScopeJournalDirectoryUnsafe)
  ExceptT $ bracket (openDirectory control) closeQuietly $ \root -> runExceptT $ do
    validateDirectory root False
    let child = anchored root "ordinary-cascade"
    created <- io (try (Posix.createDirectory child 0o700) :: IO (Either IOException ()))
    case created of
      Left err | not (isAlreadyExistsError err) -> throwE (ScopeJournalIoFailure (show err))
      _ -> pure ()
    io (fileSynchronise root)
    ExceptT $ bracket (openDirectory child) closeQuietly $ \directoryFd -> runExceptT $ do
      validateDirectory directoryFd True
      io (fileSynchronise directoryFd)
      uses <- io (newTVarIO (JournalOpen 0))
      io (action (ScopeJournal directoryFd uses) `finally` closeJournal uses)
 where
  openDirectory path = openFd path ReadOnly defaultFileFlags {directory = True, nofollow = True, cloexec = True}

validateDirectory :: Fd -> Bool -> ExceptT OrdinaryScopeJournalError IO ()
validateDirectory fd private = do
  status <- io (getFdStatus fd)
  uid <- io getEffectiveUserID
  unless
    ( isDirectory status
        && fileOwner status == uid
        && if private then exactMode 0o700 status else fileMode status `intersectFileModes` 0o022 == 0
    )
    (throwE ScopeJournalDirectoryUnsafe)

anchored :: Fd -> FilePath -> FilePath
anchored fd name = "/proc/self/fd" </> show (fromIntegral fd :: Int) </> name

closeJournal :: TVar JournalUses -> IO ()
closeJournal uses = uninterruptibleMask_ $ do
  atomically (modifyTVar' uses closing)
  atomically $ do
    state <- readTVar uses
    check $ case state of
      JournalOpen _ -> False
      JournalClosing count -> count == 0
 where
  closing state = case state of
    JournalOpen count -> JournalClosing count
    JournalClosing count -> JournalClosing count

withJournalUse
  :: TVar JournalUses
  -> IO (Either OrdinaryScopeJournalError value)
  -> IO (Either OrdinaryScopeJournalError value)
withJournalUse uses action = mask $ \restore -> do
  accepted <- atomically $ do
    state <- readTVar uses
    case state of
      JournalOpen count -> writeTVar uses (JournalOpen (count + 1)) >> pure True
      JournalClosing _ -> pure False
  if accepted
    then restore action `finally` atomically (modifyTVar' uses release)
    else pure (Left ScopeJournalClosed)
 where
  release state = case state of
    JournalOpen count -> JournalOpen (count - 1)
    JournalClosing count -> JournalClosing (count - 1)

prepareOrdinaryScopeSubmission
  :: OrdinaryScopeJournal
  -> OrdinaryScopeBinding
  -> IO (Either OrdinaryScopeJournalError (Maybe OperationId))
prepareOrdinaryScopeSubmission journal binding = locked journal (prepareSubmission journal binding)

-- A scope-only predecessor cannot acquire a program identity retrospectively.
-- Commit the digest of the closed public request before the scope WAL or RPC.
prepareBoundOrdinaryScopeSubmission
  :: OrdinaryScopeJournal
  -> OrdinaryScopeBinding
  -> ByteString
  -> IO (Either OrdinaryScopeJournalError (Maybe OperationId))
prepareBoundOrdinaryScopeSubmission journal binding programDigest = locked journal $ do
  unless
    (Bytes.length programDigest == 64 && Bytes.all lowerHex programDigest)
    (throwE ScopeJournalBindingInvalid)
  stored <- readRecord journal (programName binding)
  request <- readRecord journal (requestName binding)
  operation <- readRecord journal (operationName binding)
  when
    (stored == Nothing && (request /= Nothing || operation /= Nothing))
    (throwE ScopeJournalProgramBindingMissing)
  let bytes = Lazy.toStrict (serialise (ScopeProgramWire 1 (requestDigest binding) programDigest))
  persist journal (programName binding) bytes ScopeJournalProgramConflict
  prepareSubmission journal binding
 where
  lowerHex c = c >= 48 && c <= 57 || c >= 97 && c <= 102

-- | Read an existing binding without preparing or repairing any record. The
-- returned operation is only a coordinate: its Authority receipt must still
-- be independently observed and verified before using an AWS scope.
observeBoundOrdinaryScopeSubmission
  :: OrdinaryScopeJournal
  -> OrdinaryScopeBinding
  -> ByteString
  -> IO (Either OrdinaryScopeJournalError (Maybe OperationId))
observeBoundOrdinaryScopeSubmission journal binding programDigest = locked journal $ do
  unless
    (Bytes.length programDigest == 64 && Bytes.all lowerHex programDigest)
    (throwE ScopeJournalBindingInvalid)
  program <- readRecord journal (programName binding)
  request <- readRecord journal (requestName binding)
  operation <- readRecord journal (operationName binding)
  let expectedProgram = Lazy.toStrict (serialise (ScopeProgramWire 1 (requestDigest binding) programDigest))
      expectedRequest = encodeOrdinaryScopeBinding binding
  case (program, request, operation) of
    (Nothing, Nothing, Nothing) -> pure Nothing
    (Nothing, _, _) -> throwE ScopeJournalProgramBindingMissing
    (Just actual, _, _) | actual /= expectedProgram -> throwE ScopeJournalProgramConflict
    (_, Nothing, Nothing) -> pure Nothing
    (_, Nothing, Just _) -> throwE ScopeJournalRequestMissing
    (_, Just actual, _) | actual /= expectedRequest -> throwE ScopeJournalRequestConflict
    (_, Just _, Nothing) -> pure Nothing
    (_, Just _, Just bytes) -> do
      ScopeOperationWire version digest selected <- either throwE pure (decodeCanonical bytes)
      unless (version == 1 && digest == requestDigest binding) (throwE ScopeJournalOperationConflict)
      pure (Just selected)
 where
  lowerHex c = c >= 48 && c <= 57 || c >= 97 && c <= 102

prepareSubmission
  :: OrdinaryScopeJournal
  -> OrdinaryScopeBinding
  -> ExceptT OrdinaryScopeJournalError IO (Maybe OperationId)
prepareSubmission journal binding = do
  persist
    journal
    (requestName binding)
    (encodeOrdinaryScopeBinding binding)
    ScopeJournalRequestConflict
  existing <- readRecord journal (operationName binding)
  case existing of
    Nothing -> pure Nothing
    Just bytes -> do
      ScopeOperationWire version request operation <- either throwE pure (decodeCanonical bytes)
      unless (version == 1 && request == requestDigest binding) (throwE ScopeJournalOperationConflict)
      pure (Just operation)

bindOrdinaryScopeOperation
  :: OrdinaryScopeJournal
  -> OrdinaryScopeBinding
  -> OperationId
  -> IO (Either OrdinaryScopeJournalError ())
bindOrdinaryScopeOperation journal binding operation = locked journal $ do
  prepared <- readRecord journal (requestName binding)
  unless (prepared == Just (encodeOrdinaryScopeBinding binding)) (throwE ScopeJournalRequestMissing)
  let bytes = Lazy.toStrict (serialise (ScopeOperationWire 1 (requestDigest binding) operation))
  when (Bytes.length bytes > maximumOrdinaryScopeJournalBytes) (throwE ScopeJournalEncodingTooLarge)
  persist journal (operationName binding) bytes ScopeJournalOperationConflict

requestDigest :: OrdinaryScopeBinding -> ByteString
requestDigest = hexSha256 . encodeOrdinaryScopeBinding

recordSuffix :: OrdinaryScopeBinding -> FilePath
recordSuffix (ScopeBinding (ScopeWire _ run _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _)) =
  BytesText.unpack (hexSha256 (TextEncoding.encodeUtf8 run)) <> ".cbor"

requestName, operationName, programName :: OrdinaryScopeBinding -> FilePath
requestName binding = "request-" <> recordSuffix binding
operationName binding = "scope-" <> recordSuffix binding
programName binding = "program-" <> recordSuffix binding

locked
  :: OrdinaryScopeJournal
  -> ExceptT OrdinaryScopeJournalError IO value
  -> IO (Either OrdinaryScopeJournalError value)
locked (ScopeJournal directoryFd uses) action = withJournalUse uses $ catchIo $ withMVar journalMutex $ \() -> runExceptT $ do
  ExceptT
    $ bracket
      ( openFd
          (anchored directoryFd "journal.lock")
          ReadWrite
          defaultFileFlags {creat = Just 0o600, nofollow = True, cloexec = True, nonBlock = True}
      )
      closeQuietly
    $ \lock -> runExceptT $ do
      validateFile lock
      io (setLock lock (WriteLock, AbsoluteSeek, 0, 0))
      action

readRecord
  :: OrdinaryScopeJournal -> FilePath -> ExceptT OrdinaryScopeJournalError IO (Maybe ByteString)
readRecord (ScopeJournal directoryFd _) name = do
  opened <-
    io
      ( try
          ( openFd
              (anchored directoryFd name)
              ReadOnly
              defaultFileFlags {nofollow = True, cloexec = True, nonBlock = True}
          )
          :: IO (Either IOException Fd)
      )
  case opened of
    Left err | isDoesNotExistError err -> pure Nothing
    Left err -> throwE (ScopeJournalIoFailure (show err))
    Right fd -> ExceptT $ bracket (pure fd) closeQuietly $ \held -> runExceptT $ do
      validateFile held
      bytes <- io (readBounded held (maximumOrdinaryScopeJournalBytes + 1))
      when (Bytes.length bytes > maximumOrdinaryScopeJournalBytes) (throwE ScopeJournalEncodingTooLarge)
      pure (Just bytes)

validateFile :: Fd -> ExceptT OrdinaryScopeJournalError IO ()
validateFile fd = do
  status <- io (getFdStatus fd)
  uid <- io getEffectiveUserID
  unless
    (isRegularFile status && fileOwner status == uid && exactMode 0o600 status)
    (throwE ScopeJournalFileUnsafe)
  unless
    (fileSize status >= 0 && fileSize status <= fromIntegral maximumOrdinaryScopeJournalBytes)
    (throwE ScopeJournalEncodingTooLarge)

exactMode :: FileMode -> FileStatus -> Bool
exactMode mode status = fileMode status `intersectFileModes` 0o7777 == mode

-- The active file is never overwritten. A crash-only temporary can be removed
-- under the lock after the active slot was observed absent; admission follows
-- only the durable active name and exact fresh read-back.
persist
  :: OrdinaryScopeJournal
  -> FilePath
  -> ByteString
  -> OrdinaryScopeJournalError
  -> ExceptT OrdinaryScopeJournalError IO ()
persist journal@(ScopeJournal directoryFd _) name bytes conflict = do
  existing <- readRecord journal name
  case existing of
    Just stored -> unless (stored == bytes) (throwE conflict)
    Nothing -> do
      let temporary = name <> ".pending"
      stale <- readRecord journal temporary
      case stale of
        Nothing -> pure ()
        Just _ -> io (removeFile (anchored directoryFd temporary))
      ExceptT
        $ bracket
          ( openFd
              (anchored directoryFd temporary)
              WriteOnly
              defaultFileFlags
                { creat = Just 0o600
                , exclusive = True
                , nofollow = True
                , cloexec = True
                , nonBlock = True
                }
          )
          closeQuietly
        $ \fd -> runExceptT $ do
          validateFile fd
          writeAll fd bytes
          io (fileSynchronise fd)
      io (createLink (anchored directoryFd temporary) (anchored directoryFd name))
      io (fileSynchronise directoryFd)
      io (removeFile (anchored directoryFd temporary))
  -- Repeat fsync after a lost acknowledgement, then independently open/read.
  ExceptT
    $ bracket
      ( openFd
          (anchored directoryFd name)
          ReadOnly
          defaultFileFlags {nofollow = True, cloexec = True, nonBlock = True}
      )
      closeQuietly
    $ \fd -> runExceptT $ do
      validateFile fd
      io (fileSynchronise fd)
  io (fileSynchronise directoryFd)
  observed <- readRecord journal name
  unless (observed == Just bytes) (throwE ScopeJournalReadBackMismatch)

readBounded :: Fd -> Int -> IO ByteString
readBounded fd = go []
 where
  go chunks remaining
    | remaining <= 0 = pure (Bytes.concat (reverse chunks))
    | otherwise = do
        attempted <- try (PosixBytes.fdRead fd (fromIntegral remaining))
        case attempted of
          Left (err :: IOException) | isEOFError err -> pure (Bytes.concat (reverse chunks))
          Left err -> ioError err
          Right bytes
            | Bytes.null bytes -> pure (Bytes.concat (reverse chunks))
            | otherwise -> go (bytes : chunks) (remaining - Bytes.length bytes)

writeAll :: Fd -> ByteString -> ExceptT OrdinaryScopeJournalError IO ()
writeAll fd bytes = unless (Bytes.null bytes) $ do
  count <- io (PosixBytes.fdWrite fd bytes)
  when (count <= 0) (throwE ScopeJournalWriteNoProgress)
  writeAll fd (Bytes.drop (fromIntegral count) bytes)

io :: IO value -> ExceptT OrdinaryScopeJournalError IO value
io action = ExceptT $ do
  result <- try action
  pure $ case result of
    Left (err :: IOException) -> Left (ScopeJournalIoFailure (show err))
    Right value -> Right value

catchIo
  :: IO (Either OrdinaryScopeJournalError value) -> IO (Either OrdinaryScopeJournalError value)
catchIo action = do
  result <- try action
  pure $ case result of
    Left (err :: IOException) -> Left (ScopeJournalIoFailure (show err))
    Right value -> value

closeQuietly :: Fd -> IO ()
closeQuietly fd = do
  _ <- try (closeFd fd) :: IO (Either IOException ())
  pure ()

ordinaryScopeBindingMatchesDomain :: HostManagerDomain -> OrdinaryScopeBinding -> Bool
ordinaryScopeBindingMatchesDomain
  domain
  (ScopeBinding (ScopeWire _ _ _ _ _ _ _ _ boot bus name uid pid started _ _ _ _ _ _)) =
    (boot, bus, name, uid, pid, started)
      == ( hostManagerBootId domain
         , hostManagerBusId domain
         , hostManagerUniqueName domain
         , hostManagerUserId domain
         , hostManagerProcessId domain
         , hostManagerStartTicks domain
         )

-- The hidden constructor is returned only through this successful-validation
-- boundary. Both byte fields own their allocations before success is returned.
compactBinding :: ScopeWire -> OrdinaryScopeBinding
compactBinding
  ( ScopeWire
      version
      run
      key
      outer
      work
      hard
      stop
      finish
      boot
      bus
      unique
      uid
      pid
      ticks
      deadline
      config
      nonce
      principal
      generation
      publicKey
    ) =
    ScopeBinding
      ( ScopeWire
          version
          run
          key
          outer
          work
          hard
          stop
          finish
          boot
          bus
          unique
          uid
          pid
          ticks
          deadline
          config
          (Bytes.copy nonce)
          principal
          generation
          (Bytes.copy publicKey)
      )

ordinaryScopeBindingNormalFormBytes :: OrdinaryScopeBinding -> Natural
ordinaryScopeBindingNormalFormBytes
  ( ScopeBinding
      ( ScopeWire
          version
          run
          key
          outer
          work
          hard
          stop
          finish
          boot
          bus
          unique
          uid
          pid
          ticks
          deadline
          config
          nonce
          principal
          generation
          publicKey
        )
    ) =
    boxedRecordBytes
      [ boxedWord32Bytes version
      , boxedTextBytes run
      , string key
      , boxedWord64Bytes outer
      , boxedWord64Bytes work
      , boxedWord64Bytes hard
      , boxedWord64Bytes stop
      , boxedWord64Bytes finish
      , string boot
      , string bus
      , string unique
      , boxedWord32Bytes uid
      , boxedWord32Bytes pid
      , boxedWord64Bytes ticks
      , boxedNaturalBytes deadline
      , boxedTextBytes config
      , boxedCompactBytes nonce
      , boxedWordBytes principal
      , boxedNaturalBytes generation
      , boxedCompactBytes publicKey
      ]
   where
    string = boxedListBytes boxedCharBytes
