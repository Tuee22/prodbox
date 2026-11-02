{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Exclusive native publication. Descriptor release never deletes files:
-- an uncertain submission may still need them after the caller has gone.
module Prodbox.Subprocess.HostControllerPublication
  ( HostControllerPublicationError (..)
  , withPublishedHostControllerInputs
  , HostPublicationOwner
  , HostPublicationSubmission
  , HostPublicationNeverSent
  , HostPublicationDisposition (..)
  , withPublishedHostControllerOwner
  , withRecoveredHostPublicationNeverSent
  , hostPublicationPaths
  , withHostPublicationSubmission
  , hostPublicationSubmissionKind
  , markHostPublicationPossibleSend
  , withHostPublicationNeverSentBorrow
  , verifyHostPublicationNeverSentBefore
  , hostPublicationNeverSentKey
  , hostPublicationNeverSentKind
  , hostPublicationNeverSentMetadata
  , hostPublicationNeverSentParentMatches
  , hostPublicationNeverSentFileMatches
  , hostPublicationNeverSentHasInput
  , hostPublicationNeverSentAllowsMissingOriginal
  , hostPublicationNeverSentDeadline
  , hostPublicationNeverSentOriginalWorkEnd
  , hostControllerPublishedDirectory
  , hostControllerConfigurationName
  , hostControllerRequestName
  , hostControllerPublicationPathReserved
  ) where

import Codec.Serialise (serialise)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, putMVar, tryTakeMVar, withMVar)
import Control.Exception
  ( IOException
  , SomeException
  , finally
  , mask
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Monad (unless, void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bits ((.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Word (Word64)
import Foreign.C.Error (eAGAIN, eWOULDBLOCK, getErrno, throwErrno, throwErrnoIfMinus1Retry)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublicationRecord qualified as Record
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.FilePath (splitDirectories)
import System.IO (SeekMode (AbsoluteSeek))
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
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as IO
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

foreign import capi "sys/stat.h mkdirat"
  makeDirectoryAt :: CInt -> CString -> CMode -> IO CInt
foreign import capi "fcntl.h value O_TMPFILE" temporaryFlag :: CInt
foreign import capi "fcntl.h value O_RDWR" readWriteFlag :: CInt
foreign import capi "fcntl.h value O_CLOEXEC" closeExecFlag :: CInt
foreign import capi "fcntl.h value AT_FDCWD" currentDirectory :: CInt
foreign import capi "fcntl.h value AT_SYMLINK_FOLLOW" followOwnedDescriptor :: CInt
foreign import capi "sys/file.h value LOCK_EX" exclusiveLock :: CInt
foreign import capi "sys/file.h value LOCK_NB" nonBlockingLock :: CInt
foreign import capi "sys/file.h flock" lockFile :: CInt -> CInt -> IO CInt
foreign import capi "fcntl.h openat" openAnonymous :: CInt -> CString -> CInt -> CMode -> IO CInt
foreign import capi "unistd.h linkat"
  linkAnonymous :: CInt -> CString -> CInt -> CString -> CInt -> IO CInt

data HostControllerPublicationError
  = ControllerPublicationExpired
  | ControllerPublicationTooLarge
  | ControllerPublicationExists
  | ControllerPublicationUnsafe
  | ControllerPublicationChanged
  | ControllerPublicationWriteUnconfirmed
  | ControllerPublicationClosed
  | ControllerPublicationBusy
  | ControllerPublicationAlreadyAttempted
  | ControllerPublicationSubmissionMismatch
  | ControllerPublicationInterrupted
  | ControllerPublicationRecordMissing
  | ControllerPublicationRecordMalformed
  | ControllerPublicationPossiblySent
  | ControllerPublicationIoRefused !IOErrorType !(Maybe Int)
  deriving (Eq, Show)

hostControllerPublishedDirectory
  :: Identity.HostControllerKind -> UserID -> Identity.HostExecutionKey -> FilePath
hostControllerPublishedDirectory kind uid key =
  "/run/user/" <> show uid <> "/" <> publicationDirectoryName kind key

publicationDirectoryPrefix :: Identity.HostControllerKind -> String
publicationDirectoryPrefix kind = case kind of
  Identity.RpcBirthController -> "prodbox-rpc-birth-inputs-"
  Identity.OrdinaryCascadeController -> "prodbox-cascade-inputs-"

publicationDirectoryName :: Identity.HostControllerKind -> Identity.HostExecutionKey -> String
publicationDirectoryName kind key = publicationDirectoryPrefix kind <> Identity.hostExecutionKeyText key

-- The raw-file launcher cannot re-open a reserved publisher namespace under
-- an unrelated lifetime and bypass its possible-send latch.
hostControllerPublicationPathReserved :: FilePath -> Bool
hostControllerPublicationPathReserved = any reserved . splitDirectories
 where
  reserved component =
    any
      (\kind -> publicationDirectoryPrefix kind `isPrefixOf` component)
      [Identity.RpcBirthController, Identity.OrdinaryCascadeController]

hostControllerConfigurationName, hostControllerRequestName :: String
hostControllerConfigurationName = "settings.cbor"
hostControllerRequestName = "request.cbor"

data PublicationAttempt = PublicationReady | PublicationSpent | PublicationClosed

data HostPublicationOwner
  = HostPublicationOwner
      !Identity.HostControllerKind
      !Word64
      !Identity.HostExecutionKey
      !UserID
      !Fd
      !Fd
      !FileStatus
      !(Maybe PublishedFile)
      !(Maybe PublishedFile)
      !(Maybe PublishedBirth)
      !(MVar Bool)
      !(MVar PublicationAttempt)
      !(IORef Bool)

data HostPublicationSubmission = HostPublicationSubmission !HostPublicationOwner !(MVar Bool)

data HostPublicationNeverSent = HostPublicationNeverSent !HostPublicationOwner !Word64 !(MVar Bool)

-- Public identity only; a closed/escaped borrow still grants no use.
hostPublicationSubmissionKind :: HostPublicationSubmission -> Identity.HostControllerKind
hostPublicationSubmissionKind (HostPublicationSubmission owner _) = publicationOwnerKind owner

hostPublicationNeverSentKind :: HostPublicationNeverSent -> Identity.HostControllerKind
hostPublicationNeverSentKind (HostPublicationNeverSent owner _ _) = publicationOwnerKind owner

publicationOwnerKind :: HostPublicationOwner -> Identity.HostControllerKind
publicationOwnerKind (HostPublicationOwner kind _ _ _ _ _ _ _ _ _ _ _ _) = kind

data HostPublicationDisposition
  = PublicationNeverSent !HostPublicationNeverSent
  | PublicationPossiblySent

hostPublicationPaths :: HostPublicationOwner -> (FilePath, FilePath)
hostPublicationPaths (HostPublicationOwner kind _ key uid _ _ _ _ _ _ _ _ _) =
  let path = hostControllerPublishedDirectory kind uid key
   in (path <> "/" <> hostControllerConfigurationName, path <> "/" <> hostControllerRequestName)

useOwner
  :: HostPublicationOwner
  -> (HostPublicationOwner -> IO (Either HostControllerPublicationError value))
  -> (HostPublicationDisposition -> IO closing)
  -> IO (Either HostControllerPublicationError (value, closing))
useOwner = useOwnerWithNeverSentEnd maxBound

useOwnerWithNeverSentEnd
  :: Word64
  -> HostPublicationOwner
  -> (HostPublicationOwner -> IO (Either HostControllerPublicationError value))
  -> (HostPublicationDisposition -> IO closing)
  -> IO (Either HostControllerPublicationError (value, closing))
useOwnerWithNeverSentEnd readEnd owner@(HostPublicationOwner _ _ _ _ _ _ _ _ _ _ active gate sent) action closing = mask $ \restore ->
  ( do
      result <- tryAny (restore (action owner))
      seal
      mayHaveSent <- readIORef sent
      closed <-
        tryAny $
          restore $
            if mayHaveSent
              then closing PublicationPossiblySent
              else do
                live <- newMVar True
                closing (PublicationNeverSent (HostPublicationNeverSent owner readEnd live))
                  `finally` uninterruptibleMask_ (modifyMVar_ live (const (pure False)))
      case result of
        Left cause -> throwIO cause
        Right (Left cause) -> pure (Left cause)
        Right (Right value) -> either throwIO (\finished -> pure (Right (value, finished))) closed
  )
    `finally` (seal >> uninterruptibleMask_ (modifyMVar_ active (const (pure False))))
 where
  seal = uninterruptibleMask_ (modifyMVar_ gate (const (pure PublicationClosed)))

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

withHostPublicationSubmission
  :: HostPublicationOwner
  -> (HostPublicationSubmission -> IO value)
  -> IO (Either HostControllerPublicationError value)
withHostPublicationSubmission owner@(HostPublicationOwner _ ending _ _ _ _ _ _ _ _ _ gate _) action = mask $ \restore -> do
  acquired <- tryTakeMVar gate
  case acquired of
    Nothing -> pure (Left ControllerPublicationBusy)
    Just PublicationClosed -> putMVar gate PublicationClosed >> pure (Left ControllerPublicationClosed)
    Just PublicationSpent -> putMVar gate PublicationSpent >> pure (Left ControllerPublicationAlreadyAttempted)
    Just PublicationReady -> flip finally (putMVar gate PublicationSpent) $ do
      live <- newMVar True
      ( do
          checked <- verifyPublication ending True owner
          case checked of
            Left cause -> pure (Left cause)
            Right () -> Right <$> restore (action (HostPublicationSubmission owner live))
        )
        `finally` uninterruptibleMask_ (modifyMVar_ live (const (pure False)))

-- The closed family interpreter calls this before entering its native send.
-- An uncertain/failed call never resets the latch to never-sent.
markHostPublicationPossibleSend
  :: HostPublicationSubmission
  -> Identity.HostControllerKind
  -> Identity.HostExecutionKey
  -> Word64
  -> FilePath
  -> FilePath
  -> IO (Either HostControllerPublicationError ())
markHostPublicationPossibleSend
  ( HostPublicationSubmission
      owner@(HostPublicationOwner expectedKind ending expected uid _ parent _ _ _ birth _ _ sent)
      active
    )
  kind
  key
  work
  cfg
  req =
    withMVar active $ \live ->
      if not live
        then pure (Left ControllerPublicationClosed)
        else
          if kind /= expectedKind
            || key /= expected
            || work /= ending
            || (cfg, req) /= hostPublicationPaths owner
            then pure (Left ControllerPublicationSubmissionMismatch)
            else do
              attempted <- readIORef sent
              if attempted
                then pure (Left ControllerPublicationAlreadyAttempted)
                else do
                  checked <- verifyPublication ending True owner
                  case checked of
                    Left cause -> pure (Left cause)
                    Right () -> do
                      writeIORef sent True
                      case birth of
                        Nothing -> pure (Left ControllerPublicationRecordMissing)
                        Just (PublishedBirth _ _ recorded) ->
                          publishMetadata
                            ending
                            uid
                            parent
                            Record.publicationPossibleSendName
                            (Record.publicationBirthPossibleSendBytes recorded)

withHostPublicationNeverSentBorrow
  :: Word64
  -> HostPublicationNeverSent
  -> (HostPublicationNeverSent -> IO value)
  -> IO (Either HostControllerPublicationError value)
withHostPublicationNeverSentBorrow supplied (HostPublicationNeverSent owner original active) action = mask $ \restore -> do
  acquired <- tryTakeMVar active
  case acquired of
    Nothing -> pure (Left ControllerPublicationBusy)
    Just False -> putMVar active False >> pure (Left ControllerPublicationClosed)
    Just True -> flip finally (putMVar active True) $ do
      local <- newMVar True
      let borrowed = HostPublicationNeverSent owner (min supplied original) local
      ( do
          checked <- verifyHostPublicationNeverSentBefore supplied borrowed
          case checked of
            Left cause -> pure (Left cause)
            Right () -> Right <$> restore (action borrowed)
        )
        `finally` uninterruptibleMask_ (modifyMVar_ local (const (pure False)))

verifyHostPublicationNeverSentBefore
  :: Word64 -> HostPublicationNeverSent -> IO (Either HostControllerPublicationError ())
verifyHostPublicationNeverSentBefore supplied (HostPublicationNeverSent owner ending active) =
  withMVar active $ \live ->
    if live
      then verifyPublication (min supplied ending) False owner
      else pure (Left ControllerPublicationClosed)

verifyPublication
  :: Word64 -> Bool -> HostPublicationOwner -> IO (Either HostControllerPublicationError ())
verifyPublication ending payloads owner@(HostPublicationOwner kind _ key uid root parent expected config command birth active _ _) =
  withMVar active $ \live ->
    if not live
      then pure (Left ControllerPublicationClosed)
      else runExceptT $ do
        ExceptT (checkTime ending)
        ExceptT (checkDirectory ending uid root ("/run/user/" <> show uid))
        ExceptT (checkDirectory ending uid parent (hostControllerPublishedDirectory kind uid key))
        observed <- ExceptT (ownIO (getFdStatus parent))
        unless
          (Inputs.hostControllerParentVersionMatches expected observed)
          (throwE ControllerPublicationChanged)
        case birth of
          Nothing -> when payloads (throwE ControllerPublicationRecordMissing)
          Just recorded -> do
            verifyBirth ending uid kind key parent recorded
            marker <- ExceptT (readMetadata ending uid parent Record.publicationPossibleSendName)
            unless (marker == Nothing) (throwE ControllerPublicationPossiblySent)
        when payloads $ case (config, command) of
          (Just cfgFile, Just reqFile) -> do
            let (cfg, req) = hostPublicationPaths owner
            ExceptT (checkFile ending uid cfgFile cfg)
            ExceptT (checkFile ending uid reqFile req)
          _ -> throwE ControllerPublicationWriteUnconfirmed

hostPublicationNeverSentKey :: HostPublicationNeverSent -> Identity.HostExecutionKey
hostPublicationNeverSentKey (HostPublicationNeverSent (HostPublicationOwner _ _ key _ _ _ _ _ _ _ _ _ _) _ _) = key

hostPublicationNeverSentDeadline :: HostPublicationNeverSent -> Word64
hostPublicationNeverSentDeadline (HostPublicationNeverSent _ ending _) = ending

hostPublicationNeverSentOriginalWorkEnd :: HostPublicationNeverSent -> Word64
hostPublicationNeverSentOriginalWorkEnd (HostPublicationNeverSent (HostPublicationOwner _ ending _ _ _ _ _ _ _ _ _ _ _) _ _) = ending

hostPublicationNeverSentAllowsMissingOriginal :: HostPublicationNeverSent -> Bool
hostPublicationNeverSentAllowsMissingOriginal (HostPublicationNeverSent (HostPublicationOwner _ _ _ _ _ _ _ _ _ birth _ _ _) _ _) =
  case birth of
    Nothing -> False
    Just _ -> True

hostPublicationNeverSentMetadata :: HostPublicationNeverSent -> ByteString
hostPublicationNeverSentMetadata
  ( HostPublicationNeverSent
      owner@(HostPublicationOwner kind ending key _ _ _ parent config command birth _ _ _)
      _
      _
    ) =
    case birth of
      Just (PublishedBirth _ _ recorded) -> Record.publicationBirthNeverSentBytes recorded
      Nothing -> unlinkedMetadata
   where
    unlinkedMetadata =
      let (cfg, req) = hostPublicationPaths owner
          rows = [(Inputs.ControllerConfiguration, cfg, config), (Inputs.ControllerRequest, req, command)]
          metadata =
            Inputs.hostControllerMetadataBytes
              [(role, path, parent, status) | (role, path, Just (PublishedFile _ status)) <- rows]
          legacy =
            "prodbox-host-never-sent-unlinked/v2\NUL"
              <> Lazy.toStrict
                ( serialise
                    ( Identity.hostExecutionKeyText key
                    , ending
                    , Inputs.hostControllerParentMetadataBytes parent
                    , metadata
                    )
                )
       in case kind of
            Identity.RpcBirthController -> legacy
            Identity.OrdinaryCascadeController ->
              "prodbox-host-never-sent-unlinked/kind/v1\NUL" <> legacy

hostPublicationNeverSentParentMatches :: HostPublicationNeverSent -> FileStatus -> Bool
hostPublicationNeverSentParentMatches (HostPublicationNeverSent (HostPublicationOwner _ _ _ _ _ _ expected _ _ _ _ _ _) _ _) =
  Inputs.hostControllerParentVersionMatches expected

hostPublicationNeverSentFileMatches
  :: HostPublicationNeverSent
  -> Inputs.HostControllerInputRole
  -> Inputs.ControllerInputPosition
  -> FileStatus
  -> Bool
hostPublicationNeverSentFileMatches (HostPublicationNeverSent (HostPublicationOwner _ _ _ _ _ _ _ config command birth _ _ _) _ _) role position observed =
  case role of
    Inputs.ControllerConfiguration -> matches config
    Inputs.ControllerRequest -> matches command
    Inputs.ControllerExecutable -> False
    Inputs.ControllerSubmission -> False
 where
  matches Nothing = case birth of
    Nothing -> False
    Just (PublishedBirth _ _ recorded) -> Record.publicationBirthFileMatches recorded role observed
  matches (Just (PublishedFile _ expected)) =
    fileSize expected <= fromIntegral maximumInputBytes
      && Inputs.hostControllerFileVersionMatches position expected observed

hostPublicationNeverSentHasInput
  :: HostPublicationNeverSent -> Inputs.HostControllerInputRole -> Bool
hostPublicationNeverSentHasInput (HostPublicationNeverSent (HostPublicationOwner _ _ _ _ _ _ _ config command birth _ _ _) _ _) role =
  case role of
    Inputs.ControllerConfiguration -> present config
    Inputs.ControllerRequest -> present command
    Inputs.ControllerExecutable -> False
    Inputs.ControllerSubmission -> False
 where
  present Nothing = case birth of
    Nothing -> False
    Just _ -> True
  present (Just _) = True

-- Only the compiled runtime root and operation-key basename are accepted.
-- The callback borrows paths, not a cleanup or manager-admission capability.
withPublishedHostControllerInputs
  :: Identity.HostControllerKind
  -> Word64
  -> Identity.HostExecutionKey
  -> ByteString
  -> ByteString
  -> (FilePath -> FilePath -> IO value)
  -> IO (Either HostControllerPublicationError value)
withPublishedHostControllerInputs kind ending key configuration request action =
  fmap (fmap fst) $
    withPublishedHostControllerOwner
      kind
      ending
      key
      configuration
      request
      (\owner -> uncurry action (hostPublicationPaths owner))
      (const (pure ()))

-- The callback cannot create another publisher for this occupied namespace.
-- Its closing arm runs while the exclusive publisher's native handles live.
withPublishedHostControllerOwner
  :: Identity.HostControllerKind
  -> Word64
  -> Identity.HostExecutionKey
  -> ByteString
  -> ByteString
  -> (HostPublicationOwner -> IO value)
  -> (HostPublicationDisposition -> IO closing)
  -> IO (Either HostControllerPublicationError (value, closing))
withPublishedHostControllerOwner kind ending key configuration request action closing
  | any ((> maximumInputBytes) . BS.length) [configuration, request] =
      pure (Left ControllerPublicationTooLarge)
  | otherwise = do
      uid <- getEffectiveUserID
      withRuntimeRoot uid (publish uid)
 where
  name = publicationDirectoryName kind key
  directory uid = hostControllerPublishedDirectory kind uid key
  publish uid root = runExceptT $ do
    ExceptT (checkTime ending)
    ExceptT (create root)
    ExceptT (syncBefore ending root)
    ExceptT $
      withDescriptor
        (IO.openFdAt (Just root) name IO.ReadOnly directoryFlags)
        (writeInputs uid root)
  writeInputs uid root parent = runExceptT $ do
    ExceptT (checkDirectory ending uid parent (directory uid))
    ExceptT $
      withPreparedAnonymous ending uid parent configuration (configurationReady uid root parent)
  configurationReady uid root parent written = case written of
    Left cause -> finish uid root parent Nothing Nothing Nothing (Just cause)
    Right config ->
      withPreparedAnonymous ending uid parent request (requestReady uid root parent config)
  requestReady uid root parent config written = case written of
    Left cause -> finish uid root parent Nothing Nothing Nothing (Just cause)
    Right command -> runExceptT $ do
      status <- ExceptT (ownIO (getFdStatus parent))
      let PublishedFile _ cfgStatus = config
          PublishedFile _ reqStatus = command
      recorded <-
        maybe
          (throwE ControllerPublicationUnsafe)
          pure
          (Record.preparePublicationBirth kind key ending status cfgStatus reqStatus)
      ExceptT $
        withPublishedBirth
          ending
          uid
          parent
          (directory uid)
          recorded
          (birthReady uid root parent config command)
  birthReady uid root parent config command birth written = case written of
    Left cause -> finish uid root parent Nothing Nothing birth (Just cause)
    Right () -> do
      projected <- runExceptT $ do
        cfg <-
          ExceptT (linkPayload ending uid parent (directory uid) hostControllerConfigurationName config)
        req <- ExceptT (linkPayload ending uid parent (directory uid) hostControllerRequestName command)
        pure (cfg, req)
      case projected of
        Left cause -> finish uid root parent Nothing Nothing birth (Just cause)
        Right (cfg, req) -> finish uid root parent (Just cfg) (Just req) birth Nothing
  finish uid root parent config command birth failure = runExceptT $ do
    status <- ExceptT (ownIO (getFdStatus parent))
    active <- lift (newMVar True)
    gate <- lift (newMVar PublicationReady)
    sent <- lift (newIORef False)
    let owner = HostPublicationOwner kind ending key uid root parent status config command birth active gate sent
        use held = case failure of
          Just cause -> pure (Left cause)
          Nothing -> do
            checked <- verifyPublication ending True held
            case checked of
              Left cause -> pure (Left cause)
              Right () -> Right <$> action held
    ExceptT (useOwner owner use closing)
  create (Fd root) = do
    attempted <- try $ withCString name $ \pointer ->
      void (throwErrnoIfMinus1Retry "controller input directory" (makeDirectoryAt root pointer 0o700))
    pure $ case attempted of
      Left (cause :: IOException)
        | isAlreadyExistsError cause -> Left ControllerPublicationExists
        | otherwise -> Left (ioRefusal cause)
      Right () -> Right ()

-- The fresh lock is on the original immutable birth inode, not a pathname or
-- a decoded assertion. The creator retains its lock until its complete scope
-- has sealed/joined and released all borrows. No directory lock is held here.
withRecoveredHostPublicationNeverSent
  :: Identity.HostControllerKind
  -> Word64
  -> Identity.HostExecutionKey
  -> (HostPublicationNeverSent -> IO value)
  -> IO (Either HostControllerPublicationError value)
withRecoveredHostPublicationNeverSent kind ending key action = runExceptT $ do
  ExceptT (checkTime ending)
  uid <- lift getEffectiveUserID
  ExceptT (withRuntimeRoot uid (openNamespace uid))
 where
  openNamespace uid root =
    withDescriptor
      (IO.openFdAt (Just root) (publicationDirectoryName kind key) IO.ReadOnly directoryFlags)
      (openBirth uid root)
  openBirth uid root parent = runExceptT $ do
    ExceptT (checkTime ending)
    ExceptT (checkDirectory ending uid parent (hostControllerPublishedDirectory kind uid key))
    ExceptT $
      withDescriptor
        (IO.openFdAt (Just parent) Record.publicationBirthName IO.ReadOnly safeFlags)
        (recover uid root parent)
  recover uid root parent descriptor = runExceptT $ do
    before <- ExceptT (ownIO (getFdStatus descriptor))
    unless (safeMetadata uid before) (throwE ControllerPublicationUnsafe)
    ExceptT (acquireExclusive descriptor)
    bytes <- ExceptT (ownIO (readAllAtMost 8192 descriptor))
    ExceptT (checkTime ending)
    recorded <-
      maybe (throwE ControllerPublicationRecordMalformed) pure (Record.decodePublicationBirth bytes)
    unless
      (Record.publicationBirthKind recorded == kind && Record.publicationBirthKey recorded == key)
      (throwE ControllerPublicationSubmissionMismatch)
    status <- ExceptT (ownIO (getFdStatus parent))
    unless (Record.publicationBirthParentMatches recorded status) (throwE ControllerPublicationChanged)
    active <- lift (newMVar True)
    gate <- lift (newMVar PublicationClosed)
    sent <- lift (newIORef False)
    let birth = PublishedBirth descriptor before recorded
        owner =
          HostPublicationOwner
            kind
            (Record.publicationBirthWorkEnd recorded)
            key
            uid
            root
            parent
            status
            Nothing
            Nothing
            (Just birth)
            active
            gate
            sent
    ExceptT (verifyPublication ending False owner)
    (_, result) <- ExceptT (useOwnerWithNeverSentEnd ending owner (const (pure (Right ()))) close)
    either throwE pure result
  close disposition = case disposition of
    PublicationNeverSent proof -> Right <$> action proof
    PublicationPossiblySent -> pure (Left ControllerPublicationPossiblySent)

maximumInputBytes :: Int
maximumInputBytes = 1048576

safeFlags :: IO.OpenFileFlags
safeFlags = IO.defaultFileFlags {IO.nofollow = True, IO.cloexec = True, IO.nonBlock = True}

directoryFlags :: IO.OpenFileFlags
directoryFlags = safeFlags {IO.directory = True}

withDescriptor
  :: IO Fd
  -> (Fd -> IO (Either HostControllerPublicationError value))
  -> IO (Either HostControllerPublicationError value)
withDescriptor acquire action = mask $ \restore -> do
  opened <- ownIO acquire
  case opened of
    Left cause -> pure (Left cause)
    Right descriptor -> restore (action descriptor) `finally` IO.closeFd descriptor

withRuntimeRoot
  :: UserID
  -> (Fd -> IO (Either HostControllerPublicationError value))
  -> IO (Either HostControllerPublicationError value)
withRuntimeRoot uid action =
  withDescriptor (IO.openFd "/" IO.ReadOnly directoryFlags) $ \root ->
    descend root ["run", "user", show uid]
 where
  descend parent [] = do
    status <- ownIO (getFdStatus parent)
    case status of
      Left cause -> pure (Left cause)
      Right observed
        | isDirectory observed && fileOwner observed == uid && fileMode observed .&. 0o7777 == 0o700 ->
            action parent
        | otherwise -> pure (Left ControllerPublicationUnsafe)
  descend parent (name : rest) = do
    status <- ownIO (getFdStatus parent)
    case status of
      Left cause -> pure (Left cause)
      Right observed
        | not (isDirectory observed && fileOwner observed == 0 && fileMode observed .&. 0o022 == 0) ->
            pure (Left ControllerPublicationUnsafe)
        | otherwise ->
            withDescriptor (IO.openFdAt (Just parent) name IO.ReadOnly directoryFlags) $ \next ->
              descend next rest

data PublishedFile = PublishedFile !Fd !FileStatus

data PublishedBirth = PublishedBirth !Fd !FileStatus !Record.PublicationBirth

acquireAnonymous :: Fd -> IO Fd
acquireAnonymous (Fd parent) =
  Fd
    <$> withCString
      "."
      ( \path ->
          throwErrnoIfMinus1Retry
            "anonymous controller publication"
            (openAnonymous parent path (temporaryFlag .|. readWriteFlag .|. closeExecFlag) 0o400)
      )

acquireExclusive :: Fd -> IO (Either HostControllerPublicationError ())
acquireExclusive (Fd descriptor) = do
  locked <- lockFile descriptor (exclusiveLock .|. nonBlockingLock)
  if locked == 0
    then pure (Right ())
    else do
      cause <- getErrno
      if cause == eAGAIN || cause == eWOULDBLOCK
        then pure (Left ControllerPublicationBusy)
        else ownIO (throwErrno "controller publication fence")

linkCreated :: Word64 -> Fd -> String -> Fd -> IO (Either HostControllerPublicationError ())
linkCreated ending (Fd parent) name fd = runExceptT $ do
  ExceptT (checkTime ending)
  let path = "/proc/self/fd/" <> show fd
  _ <- ExceptT $ ownIO $ withCString path $ \source -> withCString name $ \target ->
    throwErrnoIfMinus1Retry
      "controller publication link"
      (linkAnonymous currentDirectory source parent target followOwnedDescriptor)
  pure ()

withPreparedAnonymous
  :: Word64
  -> UserID
  -> Fd
  -> ByteString
  -> ( Either HostControllerPublicationError PublishedFile
       -> IO (Either HostControllerPublicationError value)
     )
  -> IO (Either HostControllerPublicationError value)
withPreparedAnonymous ending uid parent bytes action = mask $ \restore -> do
  opened <- runExceptT $ do
    ExceptT (checkTime ending)
    ExceptT (ownIO (acquireAnonymous parent))
  case opened of
    Left cause -> restore (action (Left cause))
    Right descriptor ->
      ( do
          written <- tryAny (restore (prepare descriptor))
          case written of
            Left cause -> do
              _ <- tryAny (restore (action (Left ControllerPublicationInterrupted)))
              throwIO cause
            Right result -> restore (action result)
      )
        `finally` IO.closeFd descriptor
 where
  prepare descriptor = runExceptT $ do
    ExceptT (writeAll ending descriptor bytes)
    expected <- ExceptT (ownIO (getFdStatus descriptor))
    unless
      ( isRegularFile expected
          && fileOwner expected == uid
          && fileMode expected .&. 0o7777 == 0o400
          && linkCount expected == 0
      )
      (throwE ControllerPublicationUnsafe)
    readback <- ExceptT (ownIO (readAll descriptor))
    unless (readback == bytes) (throwE ControllerPublicationWriteUnconfirmed)
    confirmed <- ExceptT (ownIO (getFdStatus descriptor))
    unless (sameVersion expected confirmed) (throwE ControllerPublicationChanged)
    ExceptT (checkTime ending)
    pure (PublishedFile descriptor expected)

linkPayload
  :: Word64
  -> UserID
  -> Fd
  -> FilePath
  -> String
  -> PublishedFile
  -> IO (Either HostControllerPublicationError PublishedFile)
linkPayload ending uid parent directory name (PublishedFile descriptor expected) = runExceptT $ do
  before <- ExceptT (ownIO (getFdStatus descriptor))
  unless (sameVersion expected before && linkCount before == 0) (throwE ControllerPublicationChanged)
  ExceptT (linkCreated ending parent name descriptor)
  ExceptT (syncBefore ending parent)
  observed <- ExceptT (ownIO (getFdStatus descriptor))
  let published = PublishedFile descriptor observed
  ExceptT (checkFile ending uid published (directory <> "/" <> name))
  pure published

-- The lock is taken before the manifest gets a name and remains held through
-- the complete creator/closing scope. Failed or interrupted publication never
-- enables its user callback. A linked candidate is revalidated before cleanup.
withPublishedBirth
  :: Word64
  -> UserID
  -> Fd
  -> FilePath
  -> Record.PublicationBirthDraft
  -> ( Maybe PublishedBirth
       -> Either HostControllerPublicationError ()
       -> IO (Either HostControllerPublicationError value)
     )
  -> IO (Either HostControllerPublicationError value)
withPublishedBirth ending uid parent directory draft action = mask $ \restore -> do
  opened <- ownIO (acquireAnonymous parent)
  case opened of
    Left cause -> restore (action Nothing (Left cause))
    Right descriptor ->
      ( do
          before <- ownIO (getFdStatus descriptor)
          let captured = before >>= maybe (Left ControllerPublicationUnsafe) Right . Record.capturePublicationBirth draft
          case captured of
            Left cause -> restore (action Nothing (Left cause))
            Right recorded -> do
              result <- tryAny (restore (prepare descriptor recorded))
              status <- ownIO (getFdStatus descriptor)
              let candidate = case status of
                    Right observed | linkCount observed == 1 -> Just (PublishedBirth descriptor observed recorded)
                    _ -> Nothing
              case result of
                Left cause -> do
                  _ <- tryAny (restore (action candidate (Left ControllerPublicationInterrupted)))
                  throwIO cause
                Right outcome -> do
                  let confirmed = case (outcome, status) of
                        (Right (), Left cause) -> Left cause
                        (Right (), Right observed) | linkCount observed /= 1 -> Left ControllerPublicationWriteUnconfirmed
                        _ -> outcome
                  restore (action candidate confirmed)
      )
        `finally` IO.closeFd descriptor
 where
  prepare descriptor recorded = runExceptT $ do
    ExceptT (acquireExclusive descriptor)
    ExceptT (writeAll ending descriptor (Record.encodePublicationBirth recorded))
    ExceptT (linkCreated ending parent Record.publicationBirthName descriptor)
    ExceptT (syncBefore ending parent)
    status <- ExceptT (ownIO (getFdStatus descriptor))
    ExceptT
      ( checkFile
          ending
          uid
          (PublishedFile descriptor status)
          (directory <> "/" <> Record.publicationBirthName)
      )
    confirmed <- ExceptT (readMetadata ending uid parent Record.publicationBirthName)
    unless
      (confirmed == Just (Record.encodePublicationBirth recorded))
      (throwE ControllerPublicationWriteUnconfirmed)

verifyBirth
  :: Word64
  -> UserID
  -> Identity.HostControllerKind
  -> Identity.HostExecutionKey
  -> Fd
  -> PublishedBirth
  -> ExceptT HostControllerPublicationError IO ()
verifyBirth ending uid kind key parent (PublishedBirth descriptor status recorded) = do
  unless
    (Record.publicationBirthKind recorded == kind && Record.publicationBirthKey recorded == key)
    (throwE ControllerPublicationSubmissionMismatch)
  unless
    (Record.publicationBirthIdentityMatches recorded status)
    (throwE ControllerPublicationChanged)
  observed <- ExceptT (ownIO (getFdStatus parent))
  unless
    (Record.publicationBirthParentMatches recorded observed)
    (throwE ControllerPublicationChanged)
  ExceptT
    ( checkFile
        ending
        uid
        (PublishedFile descriptor status)
        (hostControllerPublishedDirectory kind uid key <> "/" <> Record.publicationBirthName)
    )
  confirmed <- ExceptT (readMetadata ending uid parent Record.publicationBirthName)
  unless
    (confirmed == Just (Record.encodePublicationBirth recorded))
    (throwE ControllerPublicationRecordMalformed)

safeMetadata :: UserID -> FileStatus -> Bool
safeMetadata uid status =
  isRegularFile status
    && fileOwner status == uid
    && fileMode status .&. 0o7777 == 0o400
    && linkCount status == 1
    && fileSize status <= 8192

readMetadata
  :: Word64 -> UserID -> Fd -> String -> IO (Either HostControllerPublicationError (Maybe ByteString))
readMetadata ending uid parent name = mask $ \restore -> do
  opened <- try (IO.openFdAt (Just parent) name IO.ReadOnly safeFlags)
  case opened of
    Left (cause :: IOException)
      | isDoesNotExistError cause ->
          fmap (const Nothing) <$> checkTime ending
    Left cause -> pure (Left (ioRefusal cause))
    Right descriptor -> restore (readOpened descriptor) `finally` IO.closeFd descriptor
 where
  readOpened descriptor = runExceptT $ do
    ExceptT (checkTime ending)
    before <- ExceptT (ownIO (getFdStatus descriptor))
    unless (safeMetadata uid before) (throwE ControllerPublicationUnsafe)
    bytes <- ExceptT (ownIO (readAllAtMost 8192 descriptor))
    after <- ExceptT (ownIO (getFdStatus descriptor))
    unless (BS.length bytes <= 8192 && sameVersion before after) (throwE ControllerPublicationChanged)
    ExceptT (checkTime ending)
    pure (Just bytes)

publishMetadata
  :: Word64 -> UserID -> Fd -> String -> ByteString -> IO (Either HostControllerPublicationError ())
publishMetadata ending uid parent name bytes =
  withDescriptor (acquireAnonymous parent) publish
 where
  publish descriptor = runExceptT $ do
    when (BS.length bytes > 8192) (throwE ControllerPublicationTooLarge)
    ExceptT (writeAll ending descriptor bytes)
    ExceptT (linkCreated ending parent name descriptor)
    ExceptT (syncBefore ending parent)
    confirmed <- ExceptT (readMetadata ending uid parent name)
    unless (confirmed == Just bytes) (throwE ControllerPublicationWriteUnconfirmed)

syncBefore :: Word64 -> Fd -> IO (Either HostControllerPublicationError ())
syncBefore ending descriptor = runExceptT $ do
  ExceptT (checkTime ending)
  ExceptT (ownIO (fileSynchronise descriptor))
  ExceptT (checkTime ending)

writeAll :: Word64 -> Fd -> ByteString -> IO (Either HostControllerPublicationError ())
writeAll ending descriptor bytes = runExceptT $ do
  ExceptT (checkTime ending)
  if BS.null bytes
    then ExceptT (syncBefore ending descriptor)
    else do
      written <- ExceptT (ownIO (Posix.fdWrite descriptor bytes))
      when (written == 0) (throwE ControllerPublicationWriteUnconfirmed)
      ExceptT (writeAll ending descriptor (BS.drop (fromIntegral written) bytes))

readAll :: Fd -> IO ByteString
readAll = readAllAtMost maximumInputBytes

readAllAtMost :: Int -> Fd -> IO ByteString
readAllAtMost maximumBytes descriptor = do
  _ <- IO.fdSeek descriptor AbsoluteSeek 0
  loop [] 0
 where
  loop chunks total = do
    result <- try (Posix.fdRead descriptor (fromIntegral (min 65536 (maximumBytes + 1 - total))))
    case result of
      Left (cause :: IOException)
        | isEOFError cause -> pure (BS.concat (reverse chunks))
        | otherwise -> ioError cause
      Right bytes
        | BS.null bytes -> pure (BS.concat (reverse chunks))
        | total + BS.length bytes > maximumBytes -> pure (BS.concat (reverse (bytes : chunks)))
        | otherwise -> loop (bytes : chunks) (total + BS.length bytes)

checkDirectory
  :: Word64 -> UserID -> Fd -> FilePath -> IO (Either HostControllerPublicationError ())
checkDirectory ending uid descriptor path = runExceptT $ do
  ExceptT (checkTime ending)
  held <- ExceptT (ownIO (getFdStatus descriptor))
  linked <- ExceptT (ownIO (getSymbolicLinkStatus path))
  unless
    ( all
        (\status -> isDirectory status && fileOwner status == uid && fileMode status .&. 0o7777 == 0o700)
        [held, linked]
    )
    (throwE ControllerPublicationUnsafe)
  unless (sameIdentity held linked) (throwE ControllerPublicationChanged)

checkFile
  :: Word64 -> UserID -> PublishedFile -> FilePath -> IO (Either HostControllerPublicationError ())
checkFile ending uid (PublishedFile descriptor expected) path = runExceptT $ do
  ExceptT (checkTime ending)
  held <- ExceptT (ownIO (getFdStatus descriptor))
  linked <- ExceptT (ownIO (getSymbolicLinkStatus path))
  unless
    ( all
        ( \status ->
            isRegularFile status
              && fileOwner status == uid
              && fileMode status .&. 0o7777 == 0o400
              && linkCount status == 1
        )
        [held, linked]
    )
    (throwE ControllerPublicationUnsafe)
  unless
    (all (sameVersion expected) [held, linked])
    (throwE ControllerPublicationChanged)

sameIdentity :: FileStatus -> FileStatus -> Bool
sameIdentity left right = deviceID left == deviceID right && fileID left == fileID right

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion expected actual =
  sameIdentity expected actual
    && fileSize expected == fileSize actual
    && fileMode expected == fileMode actual
    && fileOwner expected == fileOwner actual
    && fileGroup expected == fileGroup actual
    && linkCount expected == linkCount actual
    && modificationTimeHiRes expected == modificationTimeHiRes actual
    && statusChangeTimeHiRes expected == statusChangeTimeHiRes actual

checkTime :: Word64 -> IO (Either HostControllerPublicationError ())
checkTime ending = do
  now <- getMonotonicTimeNSec
  pure (if now < ending then Right () else Left ControllerPublicationExpired)

ownIO :: IO value -> IO (Either HostControllerPublicationError value)
ownIO action = either (Left . ioRefusal) Right <$> try action

ioRefusal :: IOException -> HostControllerPublicationError
ioRefusal cause = ControllerPublicationIoRefused (ioe_type cause) (fromIntegral <$> ioe_errno cause)
