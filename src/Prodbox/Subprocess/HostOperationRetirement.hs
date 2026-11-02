{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Qualified method completion and independent terminal physical observations.
-- No stop/delete operation, work renewal or Authority admission is provided here.
module Prodbox.Subprocess.HostOperationRetirement
  ( HostOperationRetirement
  , RetirementError (..)
  , withHostOperationRetirement
  , verifyHostOperationRetirement
  , verifyHostOperationRetirementBefore
  , hostOperationRetirementMatches
  , hostOperationRetirementDeadline
  , withHostOperationRetirementBorrow
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, putMVar, tryTakeMVar, withMVar)
import Control.Exception (IOException, finally, mask, try, uninterruptibleMask_)
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE, withExceptT)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Chars
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostOperationFamily qualified as Operation
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import System.FilePath (splitDirectories)
import System.IO.Error (isDoesNotExistError, isEOFError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileGroup
  , fileID
  , fileMode
  , fileOwner
  , getFdStatus
  , isDirectory
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as Native
import System.Posix.Types (Fd, UserID)
import System.Posix.User (getEffectiveUserID)

data RetirementError
  = RetirementExpired
  | RetirementClosed
  | RetirementBusy
  | RetirementProcessingRefused !Operation.HostOperationError
  | RetirementProviderRefused !Provider.ProviderError
  | RetirementManagerRefused !Bus.BusError
  | RetirementManagerRootMismatch
  | RetirementRuntimeRootMismatch
  | RetirementKernelRefused !Kernel.KernelScopeError
  | RetirementRolePresent !Operation.HostOperationRole
  | RetirementKernelPresent
  | RetirementWorkspacePresent
  | RetirementAnchorUnsafe
  | RetirementAnchorChanged
  | RetirementRecordMismatch
  | RetirementIoRefused !IOErrorType !(Maybe Int)
  deriving (Eq, Show)

data Anchor = Anchor !FilePath !Fd !FileStatus

data AnchorRole = KernelAnchor | RuntimeAnchor

-- No constructor, encoding or record update. The original record is data;
-- anchored native handles and their live provider remain inside this owner.
data HostOperationRetirement
  = HostOperationRetirement
      !Bus.BusConnection
      !Inputs.HostControllerSubmissionRecord
      !Operation.HostSubmissionCausalClosure
      !Provider.QualifiedProvider
      !Anchor
      !Anchor
      !(MVar Bool)

hostOperationRetirementMatches
  :: HostOperationRetirement -> Inputs.HostControllerSubmissionRecord -> Bool
hostOperationRetirementMatches (HostOperationRetirement _ original proof _ _ _ _) record =
  original == record && Operation.hostSubmissionCausalMatches proof record

hostOperationRetirementDeadline :: HostOperationRetirement -> Word64
hostOperationRetirementDeadline (HostOperationRetirement connection _ _ _ _ _ _) = Bus.systemdBusDeadline connection

-- A closed filesystem transaction holds the parent lifetime throughout its
-- bounded work. A concurrent close joins it before any native handle release.
withHostOperationRetirementBorrow
  :: Word64
  -> HostOperationRetirement
  -> (HostOperationRetirement -> IO value)
  -> IO (Either RetirementError value)
withHostOperationRetirementBorrow ending (HostOperationRetirement connection record proof provider kernel runtime active) action = mask $ \restore -> do
  claimed <- tryTakeMVar active
  case claimed of
    Nothing -> pure (Left RetirementBusy)
    Just False -> putMVar active False >> pure (Left RetirementClosed)
    Just True -> flip finally (putMVar active True) $ do
      live <- newMVar True
      let borrowed =
            HostOperationRetirement
              (Bus.systemdBusWithin ending connection)
              record
              proof
              provider
              kernel
              runtime
              live
      ( do
          checked <- verifyHostOperationRetirement borrowed
          case checked of
            Left cause -> pure (Left cause)
            Right () -> Right <$> restore (action borrowed)
        )
        `finally` uninterruptibleMask_ (modifyMVar_ live (const (pure False)))

withHostOperationRetirement
  :: Bus.BusConnection
  -> Inputs.HostControllerSubmissionRecord
  -> (HostOperationRetirement -> IO value)
  -> IO (Either RetirementError value)
withHostOperationRetirement connection record action = do
  observed <- Operation.withHostSubmissionCausalClosure connection record $ \provider proof -> do
    uid <- getEffectiveUserID
    let managerParent = "/sys/fs/cgroup" <> Kernel.hostManagerControlGroupPath uid
        runtimeRoot = "/run/user/" <> show uid
        ending = Bus.systemdBusDeadline connection
    withAnchor ending uid KernelAnchor managerParent $ \kernel ->
      withAnchor ending uid RuntimeAnchor runtimeRoot $ \runtime -> do
        active <- newMVar True
        let owner = HostOperationRetirement connection record proof provider kernel runtime active
        ( do
            checked <- verifyHostOperationRetirement owner
            case checked of
              Left cause -> pure (Left cause)
              Right () -> Right <$> action owner
          )
          `finally` uninterruptibleMask_ (modifyMVar_ active (const (pure False)))
  pure (either (Left . RetirementProcessingRefused) id observed)

verifyHostOperationRetirement :: HostOperationRetirement -> IO (Either RetirementError ())
verifyHostOperationRetirement = verifyHostOperationRetirementBefore maxBound

verifyHostOperationRetirementBefore
  :: Word64 -> HostOperationRetirement -> IO (Either RetirementError ())
verifyHostOperationRetirementBefore earlier owner@(HostOperationRetirement original record proof provider kernel runtime active) =
  withMVar active $ \live ->
    if not live
      then pure (Left RetirementClosed)
      else runExceptT $ do
        checkTime ending
        unless (hostOperationRetirementMatches owner record) (throwE RetirementRecordMismatch)
        unless
          ( Operation.hostSubmissionCausalMatches proof record
              && Inputs.hostControllerSubmissionDomain record == Provider.qualifiedProviderDomain provider
              && Inputs.hostControllerSubmissionProvider record == Just (Provider.qualifiedProviderBinding provider)
          )
          (throwE RetirementRecordMismatch)
        verifyProvider
        senderAbsent
        managerAbsent
        physicalAbsent
        managerAbsent
        verifyProvider
        senderAbsent
        physicalAbsent
        checkTime ending
 where
  connection = Bus.systemdBusWithin earlier original
  ending = Bus.systemdBusDeadline connection
  field = Operation.hostControllerSubmissionField record
  verifyProvider =
    ExceptT $
      fmap
        (either (Left . RetirementProviderRefused) Right)
        (Provider.verifyQualifiedProviderBefore ending provider)
  senderAbsent = do
    found <-
      withExceptT
        RetirementManagerRefused
        (Bus.observeBusNamePresence connection (Inputs.hostControllerSubmissionSender record))
    unless
      (found == Bus.BusNameAbsent)
      (throwE (RetirementProcessingRefused Operation.HostSubmissionSenderPresent))
  managerAbsent = do
    inventory <-
      withExceptT RetirementManagerRefused (Operation.observeHostOperationField connection field)
    let states = [(role, Operation.hostOperationPresence inventory role) | role <- [minBound .. maxBound]]
    case [cause | (_, Operation.HostOperationUnobservable cause) <- states] of
      cause : _ -> throwE (RetirementManagerRefused cause)
      [] -> case [role | (role, Operation.HostOperationPresent _) <- states] of
        role : _ -> throwE (RetirementRolePresent role)
        [] -> pure ()
  physicalAbsent = do
    actualRoot <-
      withExceptT RetirementManagerRefused $
        Bus.callManager
          connection
          (Bus.ReadUnitProperty "/org/freedesktop/systemd1")
          ( \message ->
              Bus.appendString message "org.freedesktop.systemd1.Manager"
                >> Bus.appendString message "ControlGroup"
          )
          Bus.readVariantString
    unless
      ( actualRoot
          == Kernel.hostManagerControlGroupPath
            (fromIntegral (Identity.hostManagerUserId (Inputs.hostControllerSubmissionDomain record)))
      )
      (throwE RetirementManagerRootMismatch)
    let Anchor runtimePath _ _ = runtime
    verifyRuntimePrefix ending (Inputs.hostControllerSubmissionDomain record) runtimePath
    verifyAnchor ending kernel
    verifyAnchor ending runtime
    let Anchor _ kernelFd _ = kernel
        Anchor _ runtimeFd _ = runtime
    ExceptT $
      fmap
        (either (Left . RetirementKernelRefused) Right)
        (Kernel.verifyCgroupDescriptorsBefore ending [kernelFd])
    requireMissing
      ending
      kernelFd
      (Operation.hostOperationFieldUnitName field Operation.OperationSlice)
      RetirementKernelPresent
    requireMissing
      ending
      runtimeFd
      (Operation.hostOperationFieldRuntimeDirectory field)
      RetirementWorkspacePresent

safeFlags :: Posix.OpenFileFlags
safeFlags =
  Posix.defaultFileFlags
    { Posix.nofollow = True
    , Posix.cloexec = True
    , Posix.nonBlock = True
    , Posix.directory = True
    }

withDescriptor
  :: IO Fd -> (Fd -> IO (Either RetirementError value)) -> IO (Either RetirementError value)
withDescriptor acquire action = mask $ \restore -> do
  opened <- ownIO acquire
  case opened of
    Left cause -> pure (Left cause)
    Right fd -> restore (action fd) `finally` Posix.closeFd fd

withPath
  :: Word64 -> FilePath -> (Fd -> IO (Either RetirementError value)) -> IO (Either RetirementError value)
withPath ending path action = withDescriptor (Posix.openFd "/" Posix.ReadOnly safeFlags) $ \root ->
  descend root (drop 1 (splitDirectories path))
 where
  descend parent [] = action parent
  descend parent (name : rest) = do
    checked <- runExceptT (checkTime ending)
    case checked of
      Left cause -> pure (Left cause)
      Right () -> withDescriptor (Posix.openFdAt (Just parent) name Posix.ReadOnly safeFlags) $ \next -> descend next rest

withAnchor
  :: Word64
  -> UserID
  -> AnchorRole
  -> FilePath
  -> (Anchor -> IO (Either RetirementError value))
  -> IO (Either RetirementError value)
withAnchor ending uid role path action = withPath ending path $ \fd -> do
  observed <- runExceptT $ do
    checkTime ending
    status <- ExceptT (ownIO (getFdStatus fd))
    unless
      ( isDirectory status
          && ( case role of
                 RuntimeAnchor -> fileOwner status == uid && fileMode status .&. 0o7777 == 0o700
                 KernelAnchor -> (fileOwner status == uid || fileOwner status == 0) && fileMode status .&. 0o022 == 0
             )
      )
      (throwE RetirementAnchorUnsafe)
    pure (Anchor path fd status)
  either (pure . Left) action observed

verifyAnchor :: Word64 -> Anchor -> ExceptT RetirementError IO ()
verifyAnchor ending (Anchor path fd expected) = do
  checkTime ending
  held <- ExceptT (ownIO (getFdStatus fd))
  linked <- ExceptT $ withPath ending path (ownIO . getFdStatus)
  unless (sameAnchor expected held && sameAnchor expected linked) (throwE RetirementAnchorChanged)
 where
  sameAnchor a b =
    isDirectory b
      && deviceID a == deviceID b
      && fileID a == fileID b
      && fileOwner a == fileOwner b
      && fileGroup a == fileGroup b
      && fileMode a == fileMode b

requireMissing :: Word64 -> Fd -> String -> RetirementError -> ExceptT RetirementError IO ()
requireMissing ending parent name present = do
  checkTime ending
  observed <- lift (try (Posix.openFdAt (Just parent) name Posix.ReadOnly safeFlags))
  case observed of
    Left (cause :: IOException) | isDoesNotExistError cause -> pure ()
    Left cause -> throwE (ioRefusal cause)
    Right fd -> lift (Posix.closeFd fd) >> throwE present
  checkTime ending

-- The pinned manager caches its user runtime prefix from startup
-- XDG_RUNTIME_DIR. This bounded observation checks that one non-secret path;
-- it exports, logs and hashes no environment bytes and supplies no config/auth.
verifyRuntimePrefix
  :: Word64 -> Identity.HostManagerDomain -> FilePath -> ExceptT RetirementError IO ()
verifyRuntimePrefix ending domain expected =
  ExceptT $
    withDescriptor
      ( Posix.openFd
          ("/proc/" <> show (Identity.hostManagerProcessId domain) <> "/environ")
          Posix.ReadOnly
          safeFlags {Posix.directory = False}
      )
      ( \fd -> runExceptT $ do
          bytes <- collect fd [] 0
          unless
            ( not (BS.null bytes)
                && BS.last bytes == 0
                && [value | entry <- BS.split 0 bytes, Just value <- [BS.stripPrefix "XDG_RUNTIME_DIR=" entry]]
                  == [Chars.pack expected]
            )
            (throwE RetirementRuntimeRootMismatch)
          checkTime ending
      )
 where
  collect fd chunks total = do
    checkTime ending
    result <- lift (try (Native.fdRead fd (fromIntegral (min 4096 (131073 - total)))))
    bytes <- case result of
      Left (cause :: IOException) | isEOFError cause -> pure BS.empty
      Left cause -> throwE (ioRefusal cause)
      Right value -> pure value
    let next = total + BS.length bytes
    when (next > 131072) (throwE RetirementRuntimeRootMismatch)
    if BS.null bytes then pure (BS.concat (reverse chunks)) else collect fd (bytes : chunks) next
checkTime :: Word64 -> ExceptT RetirementError IO ()
checkTime ending = do
  now <- lift getMonotonicTimeNSec
  when (now >= ending) (throwE RetirementExpired)

ownIO :: IO value -> IO (Either RetirementError value)
ownIO action = either (Left . ioRefusal) Right <$> try action

ioRefusal :: IOException -> RetirementError
ioRefusal cause = RetirementIoRefused (ioe_type cause) (fromIntegral <$> ioe_errno cause)
