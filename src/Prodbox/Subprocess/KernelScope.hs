{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Private kernel observations for a child created by the subprocess boundary.
-- This does not create a process, admit host resources, or own the expiry family.
module Prodbox.Subprocess.KernelScope
  ( ScopeKernelLimits
  , scopeKernelLimits
  , KernelScope
  , KernelScopeError (..)
  , KernelScopeBusStage (..)
  , KernelOperationIoStage (..)
  , withObservedChildScope
  , withObservedChildScopeBefore
  , withObservedHostChildScope
  , withVerifiedChildDescriptor
  , appendScopeKernelLimits
  , kernelScopeInvocation
  , kernelScopeControlGroup
  , kernelScopeEmpty
  , observeKernelScopeEmptyBefore
  , verifyKernelScopeBeforeEffect
  , killKernelScope
  , terminateKernelScope
  , HostPlacement
  , HostPlacementUse
  , withObservedHostPlacement
  , withHostPlacementSlot
  , verifyHostPlacementBeforeEffect
  , verifyHostPlacementBeforeAdmission
  , hostPlacementPlan
  , hostPlacementKey
  , hostPlacementWindow
  , hostPlacementSliceName
  , hostPlacementDescription
  , hostPlacementRuntimeDirectory
  , OperationParent
  , withObservedOperationParent
  , verifyOperationParentBeforeEffect
  , operationParentRuntimeDirectory
  , operationParentChildDeclarations
  , operationParentPlan
  , operationParentWindow
  , operationParentKey
  , OperationProcessUse
  , withOperationProcessSlot
  , withOperationProcessScope
  , verifyOperationProcessBeforeEffect
  , verifyCgroupDescriptorsBefore
  , hostManagerControlGroupPath
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , modifyMVar_
  , newMVar
  , putMVar
  , tryTakeMVar
  , withMVar
  )
import Control.Exception (IOException, bracket, catch, finally, mask, onException)
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Maybe (mapMaybe)
import Data.Text.Encoding qualified as Text
import Data.Word (Word64)
import Foreign (Ptr, nullPtr)
import Foreign.C.Error (Errno (..), eNODEV, throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..), CSize (..), CUInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumCapabilities)
import GHC.IO.Exception (ioe_errno)
import GHC.RTS.Flags qualified as Rts
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Capacity.RuntimeMemory qualified as Runtime
import Prodbox.Subprocess.HostOperationFamily qualified as Operation
import Prodbox.Subprocess.OwnedProcessTree (ProcessStat (..), parseProcessStat)
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (IOErrorType, ioeGetErrorType, isDoesNotExistError, isEOFError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files
  ( deviceID
  , fileID
  , fileMode
  , fileOwner
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , readSymbolicLink
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (..)
  , closeFd
  , defaultFileFlags
  , fdSeek
  , fdWrite
  , openFd
  , openFdAt
  )
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd (..), ProcessID, UserID)
import System.Posix.User (getEffectiveUserID)
import Text.Read (readMaybe)

foreign import capi "fcntl.h value F_DUPFD_CLOEXEC" duplicateCommand :: CInt
foreign import capi "fcntl.h fcntl" duplicateDescriptor :: CInt -> CInt -> CInt -> IO CInt
foreign import capi "sys/pidfd.h pidfd_send_signal"
  signalDescriptor :: CInt -> CInt -> Ptr () -> CUInt -> IO CInt
foreign import capi "sys/pidfd.h pidfd_open" openSelfDescriptor :: CInt -> CUInt -> IO CInt
foreign import capi "Rts.h value BLOCK_SIZE" runtimeBlockBytes :: CSize

-- Expected wire/kernel limits, not a host placement or concurrency permit.
data ScopeKernelLimits = ScopeKernelLimits !Word64 !Word64 !Word64 !Word64 !Word64 !Word64
  deriving (Eq, Show)

scopeKernelLimits
  :: Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Maybe ScopeKernelLimits
scopeKernelLimits memory swap tasks cpu runtime stop
  | all (\value -> value > 0 && value < maxBound) [memory, tasks, cpu, runtime, stop]
      && swap < maxBound =
      Just (ScopeKernelLimits memory swap tasks cpu runtime stop)
  | otherwise = Nothing

data KernelScopeError
  = KernelScopeInvalidInput
  | KernelScopeDeadlineReached
  | KernelScopeIoRefused
  | KernelOperationIoRefused !KernelOperationIoStage !IOErrorType !(Maybe CInt)
  | KernelScopeChildRefused
  | KernelScopeIdentityChanged
  | KernelScopeResourceMismatch
  | KernelScopeFilesystemRefused
  | KernelScopeObservationRefused
  | KernelScopeHandleClosed
  | KernelScopeBusRefused !KernelScopeBusStage !BusError
  | KernelScopeReleaseRefused !BusError
  | KernelScopePrimaryAndReleaseRefused !KernelScopeError !BusError
  | KernelHostParentRefused
  | KernelHostWindowRefused
  | KernelHostPlacementBusy
  | KernelHostPlacementClosed
  | KernelHostFamilyPresent
  | KernelHostRoleUnsettled !Operation.HostOperationProcessRole
  | KernelHostRoleAlreadyAttempted
  | KernelHostForeignGroup
  | KernelHostOperationRefused !Operation.HostOperationError
  | KernelScopePrimaryAndRecheckRefused !KernelScopeError !KernelScopeError
  deriving (Eq, Show)

data KernelScopeBusStage
  = ScopeChildLookup
  | ScopeReferenceAcquire
  | ScopeInvocationLookup
  | ScopeUnitMetadata
  | ScopeResourceMetadata
  | ScopeTerminateRequest
  deriving (Eq, Show)

data KernelOperationIoStage
  = OperationSelfDescriptor
  | OperationSliceOpen
  | OperationParentOpen
  | OperationRuntimeOpen
  | OperationParentReadback
  | OperationRuntimeIdentity
  | OperationParentLimits
  | OperationSliceLimits
  | OperationParentMembership
  | OperationSliceMembership
  | OperationGroupDirectories
  | OperationProcessAdmission
  deriving (Eq, Show)

type ScopeAction = ExceptT KernelScopeError IO
type ChildIdentity = (String, String, InvocationId)

data GroupHandles = GroupHandles !Fd !Fd !Fd

-- No record update or descriptor projection can retarget a signalling handle.
data KernelScope
  = KernelScope !BusConnection !InvocationPath !String !GroupHandles !Word64 !(MVar Bool) !Fd

data ChildPlacement = AppChildPlacement | HostChildPlacement !HostPlacementUse

kernelScopeInvocation :: KernelScope -> InvocationId
kernelScopeInvocation (KernelScope _ identifier _ _ _ _ _) = invocationPathId identifier

kernelScopeControlGroup :: KernelScope -> String
kernelScopeControlGroup (KernelScope _ _ path _ _ _ _) = path

-- | The descriptor must refer to a live direct child of this process. Its
-- duplicate, manager reference and anchored group descriptors stay held through
-- the callback. The caller retains process/expiry/stream lifecycle ownership.
withObservedChildScope
  :: BusConnection
  -> Word64
  -> Fd
  -> String
  -> ScopeKernelLimits
  -> (KernelScope -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withObservedChildScope connection deadline = withObservedChildScopeBefore connection deadline deadline

-- Admission has an earlier bound than the held lease's shutdown lifetime.
withObservedChildScopeBefore
  :: BusConnection
  -> Word64
  -> Word64
  -> Fd
  -> String
  -> ScopeKernelLimits
  -> (KernelScope -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withObservedChildScopeBefore = withObservedPlacedChildScope AppChildPlacement

-- The host's original window and held slice determine placement and lifetime.
-- No caller-provided cgroup path can replace the anchored parent descriptor.
withObservedHostChildScope
  :: HostPlacementUse
  -> BusConnection
  -> Fd
  -> String
  -> ScopeKernelLimits
  -> (KernelScope -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withObservedHostChildScope token connection =
  withObservedPlacedChildScope
    (HostChildPlacement token)
    connection
    (Identity.hostExecutionWorkEnd window)
    (Identity.hostExecutionStopEnd window)
 where
  window = hostPlacementWindow token

withObservedPlacedChildScope
  :: ChildPlacement
  -> BusConnection
  -> Word64
  -> Word64
  -> Fd
  -> String
  -> ScopeKernelLimits
  -> (KernelScope -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withObservedPlacedChildScope placement connection requestedAdmissionEnd requestedDeadline child name limits action = scopeIO $ mask $ \restore ->
  bracket (duplicateChild child) closeFd $ \owned -> do
    observed <- runExceptT $ do
      checkDeadline admissionEnd
      unless (validScopeName name) (throwE KernelScopeInvalidInput)
      _ <- verifyDirectChild owned
      identity <- awaitIdentity admission admissionEnd owned name
      bus
        ScopeReferenceAcquire
        (callManager admission (RefUnit name) (const (pure ())) (const (pure ())))
      pure identity
    case observed of
      Left cause -> pure (Left cause)
      Right identity -> do
        released <- newIORef Nothing
        let release = do
              result <- runExceptT (callManager connection (UnrefUnit name) (const (pure ())) (const (pure ())))
              writeIORef released (either Just (const Nothing) result)
            use = do
              prepared <- runExceptT (preparePlacedGroup placement admission admissionEnd owned identity limits)
              case prepared of
                Left cause -> pure (Left cause)
                Right (invocation, path, handles) ->
                  bracket (pure handles) closeGroup $ \held -> do
                    active <- newMVar True
                    restore (action (KernelScope connection invocation path held deadline active owned))
                      `finally` modifyMVar_ active (const (pure False))
        result <- use `finally` release
        refusal <- readIORef released
        pure $ case (result, refusal) of
          (Right _, Just cause) -> Left (KernelScopeReleaseRefused cause)
          (Left primary, Just cause) -> Left (KernelScopePrimaryAndReleaseRefused primary cause)
          (_, Nothing) -> result
 where
  deadline = min requestedDeadline (systemdBusDeadline connection)
  admissionEnd = min requestedAdmissionEnd deadline
  admission = systemdBusWithin admissionEnd connection

duplicateChild :: Fd -> IO Fd
duplicateChild (Fd descriptor) =
  Fd
    <$> throwErrnoIfMinus1Retry
      "duplicate owned child descriptor"
      (duplicateDescriptor descriptor duplicateCommand 3)

-- Borrow a duplicate only after proving it refers to our live direct child.
-- The caller still needs exact scope admission before releasing its exec gate.
withVerifiedChildDescriptor
  :: Word64 -> Fd -> (Fd -> IO value) -> IO (Either KernelScopeError value)
withVerifiedChildDescriptor deadline child action = scopeIO $ mask $ \restore ->
  bracket (duplicateChild child) closeFd $ \owned -> do
    checked <- runExceptT (checkDeadline deadline >> verifyDirectChild owned)
    case checked of
      Left cause -> pure (Left cause)
      Right _ -> do
        result <- restore (action owned)
        finished <- getMonotonicTimeNSec
        pure (if finished >= deadline then Left KernelScopeDeadlineReached else Right result)

appendScopeKernelLimits :: BusMessage -> ScopeKernelLimits -> BusAction ()
appendScopeKernelLimits message (ScopeKernelLimits memory swap tasks cpu runtime stop) =
  mapM_
    property
    [ ("MemoryMax", memory)
    , ("MemorySwapMax", swap)
    , ("TasksMax", tasks)
    , ("CPUQuotaPerSecUSec", cpu)
    , ("RuntimeMaxUSec", runtime)
    , ("TimeoutStopUSec", stop)
    ]
 where
  property (name, value) = withContainer message 'r' "sv" $ do
    appendString message name
    withContainer message 'v' "t" (appendWord64 message value)

scopeIO :: IO (Either KernelScopeError value) -> IO (Either KernelScopeError value)
scopeIO action = action `catch` refused
 where
  refused :: IOException -> IO (Either KernelScopeError value)
  refused _ = pure (Left KernelScopeIoRefused)

operationIOAt
  :: KernelOperationIoStage
  -> IO (Either KernelScopeError value)
  -> IO (Either KernelScopeError value)
operationIOAt stage action = action `catch` refused
 where
  refused :: IOException -> IO (Either KernelScopeError value)
  refused cause = pure (Left (KernelOperationIoRefused stage (ioeGetErrorType cause) (ioe_errno cause)))

operationObservationAt :: KernelOperationIoStage -> ScopeAction value -> ScopeAction value
operationObservationAt stage = ExceptT . operationIOAt stage . runExceptT

bus :: KernelScopeBusStage -> BusAction value -> ScopeAction value
bus stage action = ExceptT $ either (Left . KernelScopeBusRefused stage) Right <$> runExceptT action

checkDeadline :: Word64 -> ScopeAction ()
checkDeadline deadline = do
  now <- lift getMonotonicTimeNSec
  when (now >= deadline) (throwE KernelScopeDeadlineReached)

validScopeName :: String -> Bool
validScopeName name =
  null (drop 128 name)
    && "prodbox-owned-" `isPrefixOf` name
    && ".scope" `isSuffixOf` name
    && all (\c -> c `elem` ("abcdefghijklmnopqrstuvwxyz0123456789-." :: String)) name

verifyDirectChild :: Fd -> ScopeAction ProcessID
verifyDirectChild descriptor@(Fd native) = do
  info <- lift (readBoundedFile ("/proc/self/fdinfo/" <> show descriptor) 4096)
  pid <- case mapMaybe readPid (Bytes.lines info) of
    [value] | value > 0 -> pure value
    _ -> throwE KernelScopeChildRefused
  current <- lift (getProcessID)
  stat <- lift (readBoundedFile ("/proc/" <> show pid <> "/stat") 4096)
  case Text.decodeUtf8' stat of
    Left _ -> throwE KernelScopeChildRefused
    Right text -> case parseProcessStat text of
      Just row
        | statPid row == pid && statParent row == current && statState row `notElem` ["Z", "X"] -> do
            live <- lift (signalDescriptor native 0 nullPtr 0)
            unless (live == 0) (throwE KernelScopeChildRefused)
      _ -> throwE KernelScopeChildRefused
  pure pid
 where
  readPid line = case Bytes.words line of
    [label, value] | label == Bytes.pack "Pid:" -> readMaybe (Bytes.unpack value) :: Maybe ProcessID
    _ -> Nothing

readChildIdentity :: BusConnection -> Fd -> BusAction ChildIdentity
readChildIdentity connection (Fd descriptor) =
  callManager connection (GetUnitByPIDFD descriptor) (const (pure ())) $ \reply ->
    (,,) <$> readString reply 'o' <*> readString reply 's' <*> readInvocationId reply

awaitIdentity :: BusConnection -> Word64 -> Fd -> String -> ScopeAction ChildIdentity
awaitIdentity connection deadline child expected = do
  checkDeadline deadline
  _ <- verifyDirectChild child
  observed <-
    lift (runExceptT (callManager connection (GetUnitByPIDFD descriptor) (const (pure ())) decode))
  case observed of
    Right (path, name, InvocationPresent identifier) | name == expected -> pure (path, name, identifier)
    Right _ -> pending
    Left (BusMethodRefused code) | code == 2 || code == 3 -> pending
    Left cause -> throwE (KernelScopeBusRefused ScopeChildLookup cause)
 where
  Fd descriptor = child
  decode reply = (,,) <$> readString reply 'o' <*> readString reply 's' <*> readInvocationObservation reply
  pending = lift (threadDelay 1000) >> awaitIdentity connection deadline child expected

preparePlacedGroup
  :: ChildPlacement
  -> BusConnection
  -> Word64
  -> Fd
  -> ChildIdentity
  -> ScopeKernelLimits
  -> ScopeAction (InvocationPath, String, GroupHandles)
preparePlacedGroup placement connection deadline child expected@(_, name, _) limits =
  case placement of
    AppChildPlacement -> do
      uid <- lift getEffectiveUserID
      let path = expectedControlGroup uid name
      prepareGroup connection deadline child expected limits path (openGroup path) []
    HostChildPlacement
      token@(HostPlacementUse host@(HostPlacement _ _ _ (HostGroup pool _) _ _ _ window _ _) _) ->
        ExceptT $ withHostPlacementUse token $ do
          verifyHostChildLimits token name limits
          verifyHostPlacement HostChildAdmitted (Identity.hostExecutionWorkEnd window) host
          uid <- lift getEffectiveUserID
          let path = hostControlGroup uid <> "/" <> name
          prepareGroup connection deadline child expected limits path (openGroupAt pool name) [pool]

prepareGroup
  :: BusConnection
  -> Word64
  -> Fd
  -> ChildIdentity
  -> ScopeKernelLimits
  -> String
  -> IO GroupHandles
  -> [Fd]
  -> ScopeAction (InvocationPath, String, GroupHandles)
prepareGroup connection deadline child expected@(_, name, invocation) limits path acquire ancestors = do
  checkDeadline deadline
  alias <-
    bus
      ScopeInvocationLookup
      ( callManager
          connection
          (GetUnitByInvocationID invocation)
          (const (pure ()))
          (readInvocationPath invocation)
      )
  let verify = do
        pid <- verifyDirectChild child
        membership <- lift (readBoundedFile ("/proc/" <> show pid <> "/cgroup") 4096)
        unless (Bytes.lines membership == [Bytes.pack ("0::" <> path)]) (throwE KernelScopeIdentityChanged)
        observed <- bus ScopeChildLookup (readChildIdentity connection child)
        unless (observed == expected) (throwE KernelScopeIdentityChanged)
        actualName <- unitProperty connection alias "Id" readVariantString
        actualId <- unitProperty connection alias "InvocationID" readVariantInvocationId
        actualGroup <- scopeProperty connection alias "ControlGroup" readVariantString
        unless
          (actualName == name && actualId == invocation && actualGroup == path)
          (throwE KernelScopeIdentityChanged)
        _ <- verifyDirectChild child
        pure ()
  verify
  verifyManagerLimits connection alias limits
  acquired <- lift $ scopeIO $ bracketOnRefusal acquire closeGroup $ \handles ->
    runExceptT $ do
      let GroupHandles root events killer = handles
      verifyDescriptorMounts (ancestors <> [root, events, killer])
      verifyKernelLimits handles limits
      verify
      checkDeadline deadline
      pure (alias, path, handles)
  either throwE pure acquired

-- Keep successful handles; close every acquired descriptor on refusal/exception.
bracketOnRefusal
  :: IO resource
  -> (resource -> IO ())
  -> (resource -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
bracketOnRefusal acquire release use = mask $ \restore -> do
  resource <- acquire
  result <- restore (use resource) `onException` release resource
  case result of
    Left _ -> release resource >> pure result
    Right _ -> pure result

unitProperty
  :: BusConnection -> InvocationPath -> String -> (BusMessage -> BusAction value) -> ScopeAction value
unitProperty connection alias property decode =
  bus ScopeUnitMetadata $
    callManager connection (ReadUnitProperty (invocationPathText alias)) build decode
 where
  build message = appendString message "org.freedesktop.systemd1.Unit" >> appendString message property

verifyManagerLimits :: BusConnection -> InvocationPath -> ScopeKernelLimits -> ScopeAction ()
verifyManagerLimits connection alias (ScopeKernelLimits memory swap tasks cpu runtime stop) = do
  values <-
    traverse
      property
      [ "MemoryMax"
      , "MemorySwapMax"
      , "TasksMax"
      , "CPUQuotaPerSecUSec"
      , "RuntimeMaxUSec"
      , "TimeoutStopUSec"
      ]
  unless (values == [memory, swap, tasks, cpu, runtime, stop]) (throwE KernelScopeResourceMismatch)
 where
  property name =
    bus ScopeResourceMetadata $
      callManager connection (ReadUnitProperty (invocationPathText alias)) build readVariantWord64
   where
    build message = appendString message "org.freedesktop.systemd1.Scope" >> appendString message name

expectedControlGroup :: UserID -> String -> String
expectedControlGroup uid name =
  "/user.slice/user-" <> show uid <> ".slice/user@" <> show uid <> ".service/app.slice/" <> name

scopeProperty
  :: BusConnection -> InvocationPath -> String -> (BusMessage -> BusAction value) -> ScopeAction value
scopeProperty connection alias name decode =
  bus ScopeUnitMetadata $
    callManager connection (ReadUnitProperty (invocationPathText alias)) build decode
 where
  build message = appendString message "org.freedesktop.systemd1.Scope" >> appendString message name

safeFlags :: OpenFileFlags
safeFlags = defaultFileFlags {nofollow = True, cloexec = True}

openGroup :: String -> IO GroupHandles
openGroup path = do
  root <- openAnchored (filter (not . null) (splitPath ("/sys/fs/cgroup" <> path)))
  openGroupHandles root

openGroupAt :: Fd -> String -> IO GroupHandles
openGroupAt parent name = do
  root <- openFdAt (Just parent) name ReadOnly (safeFlags {directory = True})
  openGroupHandles root

openGroupHandles :: Fd -> IO GroupHandles
openGroupHandles root = do
  let flags = safeFlags
  events <- openFdAt (Just root) "cgroup.events" ReadOnly flags `onException` closeFd root
  killer <-
    openFdAt (Just root) "cgroup.kill" WriteOnly flags `onException` (closeFd events >> closeFd root)
  pure (GroupHandles root events killer)

openAnchored :: [String] -> IO Fd
openAnchored components = bracket (openFd "/" ReadOnly (safeFlags {directory = True})) closeFd $ \root -> descend root components
 where
  descend parent remaining = case remaining of
    [] -> duplicateChild parent
    component : rest ->
      bracket (openFdAt (Just parent) component ReadOnly (safeFlags {directory = True})) closeFd $ \next -> descend next rest

splitPath :: String -> [String]
splitPath path = case break (== '/') path of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitPath rest

closeGroup :: GroupHandles -> IO ()
closeGroup (GroupHandles root events killer) = closeFd killer `finally` (closeFd events `finally` closeFd root)

verifyKernelLimits :: GroupHandles -> ScopeKernelLimits -> ScopeAction ()
verifyKernelLimits (GroupHandles root events killer) (ScopeKernelLimits memory swap tasks cpu _ _) = do
  verifyDescriptorMounts [root, events, killer]
  values <- lift $ traverse (readRelative root) ["memory.max", "memory.swap.max", "pids.max"]
  unless
    (values == map (Bytes.pack . show) [memory, swap, tasks])
    (throwE KernelScopeResourceMismatch)
  cpuLimit <- lift (readRelative root "cpu.max")
  unless (cpuQuotaMatches cpu cpuLimit) (throwE KernelScopeResourceMismatch)

cpuQuotaMatches :: Word64 -> ByteString -> Bool
cpuQuotaMatches expected value = case traverse (readMaybe . Bytes.unpack) (Bytes.words value) of
  Just [quota, period] ->
    quota > (0 :: Integer) && period > 0 && quota * 1000000 == toInteger expected * period
  _ -> False

readRelative :: Fd -> String -> IO ByteString
readRelative parent path = bracket (openFdAt (Just parent) path ReadOnly safeFlags) closeFd $ \descriptor ->
  Bytes.strip <$> Posix.fdRead descriptor 4096

readCgroupProcesses :: Fd -> IO ByteString
readCgroupProcesses parent =
  bracket (openFdAt (Just parent) "cgroup.procs" ReadOnly safeFlags) closeFd $ \descriptor ->
    (Bytes.strip <$> Posix.fdRead descriptor 4096) `catch` emptyMembership
 where
  -- An existing cgroup may have no direct processes. Open failures and other
  -- read errors remain failures; EOF says nothing about the group's existence.
  emptyMembership :: IOException -> IO ByteString
  emptyMembership cause
    | isEOFError cause = pure Bytes.empty
    | otherwise = ioError cause

readBoundedFile :: FilePath -> Int -> IO ByteString
readBoundedFile path maximumBytes = bracket (openFd path ReadOnly safeFlags) closeFd $ \descriptor -> do
  let loop size chunks = do
        bytes <- nextChunk descriptor (fromIntegral (min 4096 (maximumBytes + 1 - size)))
        let total = size + Bytes.length bytes
        if total > maximumBytes
          then pure Bytes.empty
          else
            if Bytes.null bytes
              then pure (Bytes.concat (reverse chunks))
              else loop total (bytes : chunks)
  loop 0 []
 where
  nextChunk descriptor amount = Posix.fdRead descriptor amount `catch` ended
  ended :: IOException -> IO ByteString
  ended cause
    | isEOFError cause = pure Bytes.empty
    | otherwise = ioError cause

withLiveScope
  :: KernelScope -> (GroupHandles -> ScopeAction value) -> IO (Either KernelScopeError value)
withLiveScope (KernelScope _ _ _ handles deadline active _) action = scopeIO $ withMVar active $ \live -> runExceptT $ do
  unless live (throwE KernelScopeHandleClosed)
  checkDeadline deadline
  result <- action handles
  checkDeadline deadline
  pure result

-- Re-observe the held child rather than trusting only the earlier admission.
-- The duplicated PIDFD and group handles remain owned by the surrounding lease.
verifyKernelScopeBeforeEffect
  :: Word64 -> ScopeKernelLimits -> KernelScope -> IO (Either KernelScopeError ())
verifyKernelScopeBeforeEffect bound limits scope@(KernelScope original alias path _ _ _ child) =
  withLiveScope scope $ \handles -> do
    let connection = systemdBusWithin bound original
    checkDeadline bound
    pid <- verifyDirectChild child
    membership <- lift (readBoundedFile ("/proc/" <> show pid <> "/cgroup") 4096)
    (canonical, name, invocation) <- bus ScopeChildLookup (readChildIdentity connection child)
    actualName <- unitProperty connection alias "Id" readVariantString
    actualId <- unitProperty connection alias "InvocationID" readVariantInvocationId
    actualGroup <- scopeProperty connection alias "ControlGroup" readVariantString
    unless
      ( not (null canonical)
          && name == actualName
          && invocation == invocationPathId alias
          && actualId == invocation
          && actualGroup == path
          && Bytes.lines membership == [Bytes.pack ("0::" <> path)]
      )
      (throwE KernelScopeIdentityChanged)
    verifyManagerLimits connection alias limits
    verifyKernelLimits handles limits
    _ <- verifyDirectChild child
    checkDeadline bound

killKernelScope :: KernelScope -> IO (Either KernelScopeError ())
killKernelScope scope = withLiveScope scope $ \(GroupHandles _ _ killer) -> do
  written <- lift (fdWrite killer "1")
  unless (written == 1) (throwE KernelScopeObservationRefused)

-- A graceful attempt targets the original invocation, never its reusable name.
-- The owner still confirms emptiness and retains its independent hard expiry.
terminateKernelScope :: Word64 -> KernelScope -> IO (Either KernelScopeError ())
terminateKernelScope graceEnd scope@(KernelScope connection invocation _ _ _ _ _) = withLiveScope scope $ \_ -> do
  checkDeadline graceEnd
  bus
    ScopeTerminateRequest
    ( callManager
        (systemdBusWithin graceEnd connection)
        (TerminateInvocationUnit invocation)
        (const (pure ()))
        (const (pure ()))
    )
  checkDeadline graceEnd

kernelScopeEmpty :: KernelScope -> IO (Either KernelScopeError Bool)
kernelScopeEmpty scope = withLiveScope scope $ \(GroupHandles root events _) -> do
  observed <- lift (readEvents events)
  case observed of
    Right bytes -> case [ value
                        | line <- Bytes.lines bytes
                        , [label, value] <- [Bytes.words line]
                        , label == Bytes.pack "populated"
                        ] of
      [value] | value == Bytes.pack "0" -> pure True
      [value] | value == Bytes.pack "1" -> pure False
      _ -> throwE KernelScopeObservationRefused
    Left True -> do
      target <- lift (readSymbolicLink ("/proc/self/fd/" <> show root))
      retired <- lift (relativeGone root)
      if retired && " (deleted)" `isSuffixOf` target
        then pure True
        else throwE KernelScopeObservationRefused
    Left False -> throwE KernelScopeObservationRefused
 where
  readEvents events = (Right <$> (fdSeek events AbsoluteSeek 0 >> Posix.fdRead events 4096)) `catch` failed
  failed :: IOException -> IO (Either Bool ByteString)
  failed cause = pure (Left (fmap Errno (ioe_errno cause) == Just eNODEV))
  relativeGone root =
    (bracket (openFdAt (Just root) "cgroup.events" ReadOnly safeFlags) closeFd (const (pure False)))
      `catch` missing
  missing :: IOException -> IO Bool
  missing = pure . isDoesNotExistError

-- A retiring kernfs node may refuse an observation before its held descriptors
-- supply positive retirement evidence. Retry only that observation, under the
-- original lease and caller bound; a populated group returns immediately.
observeKernelScopeEmptyBefore :: Word64 -> KernelScope -> IO (Either KernelScopeError Bool)
observeKernelScopeEmptyBefore bound scope@(KernelScope _ _ _ _ deadline _ _) = observe
 where
  ending = min bound deadline
  observe = do
    now <- getMonotonicTimeNSec
    if now >= ending
      then pure (Left KernelScopeDeadlineReached)
      else do
        result <- kernelScopeEmpty scope
        finished <- getMonotonicTimeNSec
        if finished >= ending
          then pure (Left KernelScopeDeadlineReached)
          else case result of
            Left KernelScopeObservationRefused -> retry
            Left KernelScopeIoRefused -> retry
            other -> pure other
  retry = threadDelay 1000 >> observe

-- Read-only handles never grant a kill capability over the parent or slice.
data HostGroup = HostGroup !Fd !Fd

data HostPlacement
  = HostPlacement
      !BusConnection
      !InvocationPath
      !String
      !HostGroup
      !HostGroup
      !Host.HostExecutionPlan
      !Identity.HostExecutionKey
      !Identity.HostExecutionWindow
      !HostRuntimeDirectory
      !(MVar Bool)

data HostRuntimeDirectory = HostRuntimeDirectory !FilePath !Fd

hostPlacementRuntimeDirectory :: HostPlacement -> FilePath
hostPlacementRuntimeDirectory (HostPlacement _ _ _ _ _ _ _ _ (HostRuntimeDirectory path _) _) = path

data HostPlacementUse = HostPlacementUse !HostPlacement !(MVar Bool)

data HostPlacementPhase = HostSlotEmpty | HostChildWaiting !ProcessID | HostChildAdmitted

hostPlacementPlan :: HostPlacementUse -> Host.HostExecutionPlan
hostPlacementPlan (HostPlacementUse (HostPlacement _ _ _ _ _ plan _ _ _ _) _) = plan

hostPlacementKey :: HostPlacementUse -> Identity.HostExecutionKey
hostPlacementKey (HostPlacementUse (HostPlacement _ _ _ _ _ _ key _ _ _) _) = key

hostPlacementWindow :: HostPlacementUse -> Identity.HostExecutionWindow
hostPlacementWindow (HostPlacementUse (HostPlacement _ _ _ _ _ _ _ window _ _) _) = window

hostPlacementSliceName :: HostPlacementUse -> String
hostPlacementSliceName _ = Identity.hostControllerSliceName

hostPlacementDescription
  :: Host.HostExecutionPlan -> Identity.HostExecutionKey -> Identity.HostExecutionWindow -> String
hostPlacementDescription plan key window =
  Identity.hostControllerDescription key window
    <> " resources "
    <> unwords
      ( map
          (show . ($ plan))
          [ Host.hostExecutionParentMemoryBytes
          , Host.hostExecutionChildMemoryBytes
          , Host.hostExecutionHelperMemoryBytes
          , Host.hostExecutionSliceMemoryBytes
          , Host.hostExecutionParentCpuUsecPerSec
          , Host.hostExecutionChildCpuUsecPerSec
          , Host.hostExecutionHelperCpuUsecPerSec
          , Host.hostExecutionSliceCpuUsecPerSec
          , Host.hostExecutionParentTasks
          , Host.hostExecutionChildTasks
          , Host.hostExecutionHelperTasks
          , Host.hostExecutionSliceTasks
          , Host.hostExecutionMaximumChildMicros
          ]
          <> [ show
                 ( Runtime.positiveBytesValue
                     (Runtime.runtimeMemoryHeapCapBytes (Host.hostExecutionRuntimeMemory plan))
                 )
             ]
      )

-- This observes one already managed parent. It creates neither a process nor
-- an Authority reservation. Only the outer interpreter can combine those proofs.
withObservedHostPlacement
  :: BusConnection
  -> Host.HostExecutionPlan
  -> Identity.HostExecutionKey
  -> Identity.HostExecutionWindow
  -> (HostPlacement -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withObservedHostPlacement connection plan key window action = scopeIO $ mask $ \restore -> do
  held <- newIORef []
  releaseFailure <- newIORef Nothing
  let admission = systemdBusWithin (Identity.hostExecutionWorkEnd window) connection
      reference name = do
        bus
          ScopeReferenceAcquire
          (callManager admission (RefUnit name) (const (pure ())) (const (pure ())))
        lift (modifyIORef' held (name :))
      release = do
        names <- readIORef held
        results <-
          traverse
            (\name -> runExceptT (callManager connection (UnrefUnit name) (const (pure ())) (const (pure ()))))
            names
        writeIORef
          releaseFailure
          (case [failure | Left failure <- results] of first : _ -> Just first; [] -> Nothing)
      acquire = do
        checkDeadline (Identity.hostExecutionWorkEnd window)
        unless
          (Identity.hostExecutionOuterEnd window <= systemdBusDeadline connection)
          (throwE KernelHostWindowRefused)
        current <- lift getProcessID
        (parent, name, invocation) <-
          ExceptT $
            bracket
              (Fd <$> throwErrnoIfMinus1Retry "owned parent pidfd" (openSelfDescriptor (fromIntegral current) 0))
              closeFd
              (\fd -> runExceptT (bus ScopeChildLookup (readChildIdentity admission fd)))
        unless (name == Identity.hostControllerUnitName) (throwE KernelHostParentRefused)
        reference name
        reference Identity.hostControllerSliceName
        alias <-
          bus ScopeInvocationLookup $
            callManager
              admission
              (GetUnitByInvocationID invocation)
              (const (pure ()))
              (readInvocationPath invocation)
        slice <-
          bus ScopeUnitMetadata $
            callManager
              admission
              GetUnit
              (\message -> appendString message Identity.hostControllerSliceName)
              (`readString` 'o')
        uid <- lift getEffectiveUserID
        let poolPath =
              "/user.slice/user-"
                <> show uid
                <> ".slice/user@"
                <> show uid
                <> ".service/"
                <> Identity.hostControllerSliceName
            parentPath = poolPath <> "/" <> name
        parentGroup <-
          hostProperty admission (invocationPathText alias) "Service" "ControlGroup" readVariantString
        poolGroup <- hostProperty admission slice "Slice" "ControlGroup" readVariantString
        unless (parentGroup == parentPath && poolGroup == poolPath) (throwE KernelHostParentRefused)
        -- The canonical object from PIDFD lookup must agree before any handle
        -- is retained; subsequent parent reads use the returned invocation alias.
        initial <- hostProperty admission parent "Unit" "InvocationID" readVariantInvocationId
        unless (initial == invocation) (throwE KernelScopeIdentityChanged)
        pure (alias, slice, poolPath)
      use = do
        prepared <- runExceptT acquire
        case prepared of
          Left cause -> pure (Left cause)
          Right (alias, slice, poolPath) ->
            bracket (openHostGroup poolPath) closeHostGroup $ \pool@(HostGroup root _) ->
              bracket (openHostGroupAt root Identity.hostControllerUnitName) closeHostGroup $ \parent ->
                bracket openHostRuntimeDirectory closeHostRuntimeDirectory $ \runtimeDirectory -> do
                  active <- newMVar True
                  let placement = HostPlacement connection alias slice pool parent plan key window runtimeDirectory active
                  initial <-
                    runExceptT (verifyHostPlacement HostSlotEmpty (Identity.hostExecutionWorkEnd window) placement)
                  case initial of
                    Left cause -> pure (Left cause)
                    Right () ->
                      restore (action placement)
                        `finally` modifyMVar_ active (const (pure False))
  result <- use `finally` release
  released <- readIORef releaseFailure
  pure $ case (result, released) of
    (Right _, Just failure) -> Left (KernelScopeReleaseRefused failure)
    (Left primary, Just failure) -> Left (KernelScopePrimaryAndReleaseRefused primary failure)
    (_, Nothing) -> result

-- The transport-indexed controller is observed independently of the serial
-- placement API. This initial lease admits neither transport nor command work.
data OperationParentBase
  = OperationParentBase
      !BusConnection
      !Operation.HostOperationIntent
      !Operation.HostControllerProgram
      !Fd
      !InvocationPath
      !String
      !HostGroup
      !HostGroup
      !HostRuntimeDirectory
      !(MVar OperationRoles)

data OperationParent
  = OperationParent
      !OperationParentBase
      !InvocationId
      !(Operation.HostOperationChildDeclaration, Operation.HostOperationChildDeclaration)
      !(MVar Bool)
      !(MVar Bool)
      !(MVar Bool)

data OperationRoles = OperationRoles !OperationRoleState !OperationRoleState

data OperationRoleState
  = OperationRoleIdle
  | OperationRoleLive !KernelScope !ScopeKernelLimits
  | OperationRoleUnsettled

data OperationProcessUse
  = OperationProcessUse !OperationParent !Operation.HostOperationProcessRole !(MVar Bool) !(MVar Bool)

operationParentRuntimeDirectory :: OperationParent -> FilePath
operationParentRuntimeDirectory (OperationParent (OperationParentBase _ _ _ _ _ _ _ _ (HostRuntimeDirectory path _) _) _ _ _ _ _) = path

operationParentChildDeclarations
  :: OperationParent
  -> (Operation.HostOperationChildDeclaration, Operation.HostOperationChildDeclaration)
operationParentChildDeclarations (OperationParent _ _ declarations _ _ _) = declarations

operationParentPlan :: OperationParent -> Host.HostExecutionTransportPlan
operationParentPlan (OperationParent (OperationParentBase _ intent _ _ _ _ _ _ _ _) _ _ _ _ _) = Operation.hostOperationPlan intent

operationParentWindow :: OperationParent -> Identity.HostExecutionWindow
operationParentWindow (OperationParent (OperationParentBase _ intent _ _ _ _ _ _ _ _) _ _ _ _ _) = Operation.hostOperationWindow intent

operationParentKey :: OperationParent -> Identity.HostExecutionKey
operationParentKey (OperationParent (OperationParentBase _ intent _ _ _ _ _ _ _ _) _ _ _ _ _) = Operation.hostOperationKey intent

withObservedOperationParent
  :: BusConnection
  -> Operation.HostOperationIntent
  -> Operation.HostControllerProgram
  -> (OperationParent -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withObservedOperationParent original intent program action = operationIOAt OperationSelfDescriptor
  $ bracket
    ( getProcessID >>= \current ->
        Fd <$> throwErrnoIfMinus1Retry "operation self pidfd" (openSelfDescriptor (fromIntegral current) 0)
    )
    closeFd
  $ \self -> do
    identity <- runExceptT $ do
      checkDeadline work
      unless
        (Identity.hostExecutionOuterEnd window <= systemdBusDeadline connection)
        (throwE KernelHostWindowRefused)
      (_, name, _) <- bus ScopeChildLookup (readChildIdentity admission self)
      unless (name == controllerName) (throwE KernelHostParentRefused)
    case identity of
      Left cause -> pure (Left cause)
      Right () -> withOperationReferences connection intent $ do
        acquired <- runExceptT $ do
          checkDeadline work
          unless
            (Identity.hostExecutionOuterEnd window <= systemdBusDeadline connection)
            (throwE KernelHostWindowRefused)
          (_, name, invocation) <- bus ScopeChildLookup (readChildIdentity admission self)
          unless (name == controllerName) (throwE KernelHostParentRefused)
          alias <-
            bus ScopeInvocationLookup $
              callManager
                admission
                (GetUnitByInvocationID invocation)
                (const (pure ()))
                (readInvocationPath invocation)
          slice <-
            bus ScopeUnitMetadata $
              callManager admission GetUnit (\message -> appendString message sliceName) (`readString` 'o')
          uid <- lift getEffectiveUserID
          let poolPath = operationControlGroup uid intent
          parentPath <-
            hostProperty admission (invocationPathText alias) "Service" "ControlGroup" readVariantString
          slicePath <- hostProperty admission slice "Slice" "ControlGroup" readVariantString
          unless
            (parentPath == poolPath <> "/" <> controllerName && slicePath == poolPath)
            (throwE KernelHostParentRefused)
          pure (alias, slice, poolPath)
        case acquired of
          Left cause -> pure (Left cause)
          Right (alias, slice, poolPath) ->
            operationIOAt OperationSliceOpen $ bracket (openHostGroup poolPath) closeHostGroup $ \pool@(HostGroup root _) ->
              operationIOAt OperationParentOpen $ bracket (openHostGroupAt root controllerName) closeHostGroup $ \parent ->
                operationIOAt OperationRuntimeOpen
                  $ bracket
                    (openHostRuntimeDirectoryNamed (Operation.hostOperationRuntimeDirectory intent))
                    closeHostRuntimeDirectory
                  $ \runtime -> do
                    roles <- newMVar (OperationRoles OperationRoleIdle OperationRoleIdle)
                    let base = OperationParentBase connection intent program self alias slice pool parent runtime roles
                    initial <- operationIOAt OperationParentReadback (runExceptT (verifyOperationParentBase base))
                    case initial of
                      Left cause -> pure (Left cause)
                      Right (timer, Just command, Just transport) -> mask $ \restore -> do
                        active <- newMVar True
                        commandLane <- newMVar True
                        transportLane <- newMVar True
                        let lease = OperationParent base timer (command, transport) active commandLane transportLane
                            close = do
                              modifyMVar_ active (const (pure False))
                              modifyMVar_ commandLane (const (pure False))
                              modifyMVar_ transportLane (const (pure False))
                        primary <- restore (action lease) `finally` close
                        closing <- operationIOAt OperationParentReadback (runExceptT (verifyOperationParentBase base))
                        pure $ case (primary, closing) of
                          (Left cause, Left recheck) -> Left (KernelScopePrimaryAndRecheckRefused cause recheck)
                          (Left cause, Right _) -> Left cause
                          (Right _, Left cause) -> Left cause
                          (Right value, Right (observed, _, _))
                            | observed == timer ->
                                Right value
                            | otherwise -> Left KernelScopeIdentityChanged
                      Right _ -> pure (Left KernelHostFamilyPresent)
 where
  window = Operation.hostOperationWindow intent
  connection = systemdBusWithin (Identity.hostExecutionOuterEnd window) original
  work = Identity.hostExecutionWorkEnd window
  admission = systemdBusWithin work connection
  controllerName = Operation.hostOperationUnitName intent Operation.OperationController
  sliceName = Operation.hostOperationUnitName intent Operation.OperationSlice

verifyOperationParentBeforeEffect :: OperationParent -> IO (Either KernelScopeError ())
verifyOperationParentBeforeEffect (OperationParent base initial _ active _ _) = operationIOAt OperationParentReadback $ withMVar active $ \live ->
  if not live
    then pure (Left KernelHostPlacementClosed)
    else runExceptT $ do
      (observed, _, _) <- verifyOperationParentBase base
      unless
        (observed == initial)
        (throwE KernelScopeIdentityChanged)

-- A retained manager object is not an invocation fence. Controller reads use
-- the PIDFD-derived alias; the timer is rechecked by its original invocation.
type OperationParentObservation =
  ( InvocationId
  , Maybe Operation.HostOperationChildDeclaration
  , Maybe Operation.HostOperationChildDeclaration
  )

verifyOperationParentBase :: OperationParentBase -> ScopeAction OperationParentObservation
verifyOperationParentBase base@(OperationParentBase _ _ _ _ _ _ _ _ _ roles) = ExceptT $
  withMVar roles $
    \states -> runExceptT (verifyOperationParentState states Nothing base)

verifyOperationParentState
  :: OperationRoles -> Maybe ProcessID -> OperationParentBase -> ScopeAction OperationParentObservation
verifyOperationParentState states waiting (OperationParentBase original intent program self alias slice pool parent runtimeDirectory _) = do
  let plan = Operation.hostOperationPlan intent
      window = Operation.hostOperationWindow intent
      bound = Identity.hostExecutionWorkEnd window
      connection = systemdBusWithin bound original
      controllerName = Operation.hostOperationUnitName intent Operation.OperationController
      sliceName = Operation.hostOperationUnitName intent Operation.OperationSlice
      path = invocationPathText alias
      service = hostProperty connection path "Service"
      unit = hostProperty connection path "Unit"
  checkDeadline bound
  mapM_ requireSettledRole [Operation.OperationCommandProcess, Operation.OperationTransportProcess]
  capabilities <- lift getNumCapabilities
  flags <- lift Rts.getRTSFlags
  let actualHeap = toInteger (Rts.maxHeapSize (Rts.gcFlags flags)) * toInteger runtimeBlockBytes
      expectedHeap =
        toInteger
          ( Runtime.positiveBytesValue
              (Runtime.runtimeMemoryHeapCapBytes (Host.hostExecutionRuntimeMemory plan))
          )
  unless
    (capabilities == 1 && actualHeap > 0 && actualHeap == expectedHeap)
    (throwE KernelHostParentRefused)
  current <- lift getProcessID
  (_, name, invocation) <- bus ScopeChildLookup (readChildIdentity connection self)
  checkInvocation <- unit "InvocationID" readVariantInvocationId
  mainPid <- service "MainPID" readVariantWord32
  kind <- service "Type" readVariantString
  ownSlice <- service "Slice" readVariantString
  remain <- service "RemainAfterExit" readVariantBoolean
  restart <- service "Restart" readVariantString
  mode <- service "KillMode" readVariantString
  signal <- service "KillSignal" readVariantInt32
  final <- service "FinalKillSignal" readVariantInt32
  sendKill <- service "SendSIGKILL" readVariantBoolean
  unless
    ( name == controllerName
        && invocation == invocationPathId alias
        && checkInvocation == invocation
        && toInteger mainPid == toInteger current
        && kind == "exec"
        && ownSlice == sliceName
        && not remain
        && restart == "no"
        && mode == "control-group"
        && signal == 9
        && final == 9
        && sendKill
    )
    (throwE KernelHostParentRefused)
  runtime <- service "RuntimeMaxUSec" readVariantWord64
  stop <- service "TimeoutStopUSec" readVariantWord64
  extra <- service "RuntimeRandomizedExtraUSec" readVariantWord64
  unless
    ( runtime > 0
        && runtime <= Host.hostExecutionMaximumChildMicros plan
        && stop > 0
        && toInteger stop * 1000
          <= toInteger (Identity.hostExecutionStopEnd window) - toInteger (Identity.hostExecutionHardEnd window)
        && extra == 0
    )
    (throwE KernelHostWindowRefused)
  uid <- lift getEffectiveUserID
  let poolPath = operationControlGroup uid intent
      parentPath = poolPath <> "/" <> controllerName
  actualParent <- service "ControlGroup" readVariantString
  actualSlice <- hostProperty connection slice "Slice" "ControlGroup" readVariantString
  identifier <- hostProperty connection slice "Unit" "Id" readVariantString
  membership <- lift (readBoundedFile "/proc/self/cgroup" 4096)
  unless
    ( actualParent == parentPath
        && actualSlice == poolPath
        && identifier == sliceName
        && Bytes.lines membership == [Bytes.pack ("0::" <> parentPath)]
    )
    (throwE KernelScopeIdentityChanged)
  directoryName <- service "RuntimeDirectory" readVariantSingleString
  directoryMode <- service "RuntimeDirectoryMode" readVariantWord32
  directoryPreserve <- service "RuntimeDirectoryPreserve" readVariantString
  unless
    ( directoryName == Operation.hostOperationRuntimeDirectory intent
        && directoryMode == 0o700
        && directoryPreserve == "no"
    )
    (throwE KernelHostParentRefused)
  operationObservationAt OperationRuntimeIdentity (verifyHostRuntimeDirectory uid runtimeDirectory)
  verifyHostManagerCaps
    connection
    path
    "Service"
    (Host.hostExecutionParentMemoryBytes plan)
    (Host.hostExecutionParentTasks plan)
    (Host.hostExecutionParentCpuUsecPerSec plan)
  verifyHostManagerCaps
    connection
    slice
    "Slice"
    (Host.hostExecutionSliceMemoryBytes plan)
    (Host.hostExecutionSliceTasks plan)
    (Host.hostExecutionSliceCpuUsecPerSec plan)
  operationObservationAt OperationParentLimits $
    verifyHostKernelCaps
      parent
      (Host.hostExecutionParentMemoryBytes plan)
      (Host.hostExecutionParentTasks plan)
      (Host.hostExecutionParentCpuUsecPerSec plan)
  operationObservationAt OperationSliceLimits $
    verifyHostKernelCaps
      pool
      (Host.hostExecutionSliceMemoryBytes plan)
      (Host.hostExecutionSliceTasks plan)
      (Host.hostExecutionSliceCpuUsecPerSec plan)
  let HostGroup parentRoot parentEvents = parent
      HostGroup poolRoot poolEvents = pool
  verifyDescriptorMounts [parentRoot, parentEvents, poolRoot, poolEvents]
  processes <-
    operationObservationAt OperationParentMembership (lift (readCgroupProcesses parentRoot))
  unless
    (sort (Bytes.words processes) == sort (map (Bytes.pack . show) (current : maybe [] pure waiting)))
    (throwE KernelHostParentRefused)
  directPool <-
    operationObservationAt OperationSliceMembership (lift (readCgroupProcesses poolRoot))
  unless (null (Bytes.words directPool)) (throwE KernelHostForeignGroup)
  nested <- operationObservationAt OperationGroupDirectories (ExceptT (hostDirectories parentRoot))
  unless (null nested) (throwE KernelHostForeignGroup)
  directories <- operationObservationAt OperationGroupDirectories (ExceptT (hostDirectories poolRoot))
  let occupied role = case operationRoleState role states of
        OperationRoleIdle -> []
        OperationRoleLive _ _ -> [operationProcessName intent role]
        OperationRoleUnsettled -> []
      expectedDirectories =
        controllerName
          : concatMap occupied [Operation.OperationCommandProcess, Operation.OperationTransportProcess]
  unless (sort directories == sort expectedDirectories) (throwE KernelHostForeignGroup)
  timer <-
    ExceptT $
      either (Left . KernelHostOperationRefused) Right
        <$> Operation.verifyHostOperationCoreDeclaration connection intent program alias
  command <- verifyRole Operation.OperationCommandProcess
  transport <- verifyRole Operation.OperationTransportProcess
  checkDeadline bound
  pure (timer, command, transport)
 where
  requireSettledRole role = case operationRoleState role states of
    OperationRoleUnsettled -> throwE (KernelHostRoleUnsettled role)
    OperationRoleIdle -> pure ()
    OperationRoleLive _ _ -> pure ()
  verifyRole role = case operationRoleState role states of
    OperationRoleIdle ->
      Just
        <$> ExceptT
          ( either (Left . KernelHostOperationRefused) Right
              <$> Operation.observeHostOperationIdleChild original intent role
          )
    OperationRoleLive scope limits -> do
      ExceptT
        ( verifyKernelScopeBeforeEffect
            (Identity.hostExecutionWorkEnd (Operation.hostOperationWindow intent))
            limits
            scope
        )
      verifyOperationRoleDeclaration original intent role scope
      pure Nothing
    OperationRoleUnsettled -> throwE (KernelHostRoleUnsettled role)

verifyOperationRoleDeclaration
  :: BusConnection
  -> Operation.HostOperationIntent
  -> Operation.HostOperationProcessRole
  -> KernelScope
  -> ScopeAction ()
verifyOperationRoleDeclaration original intent role (KernelScope _ alias _ _ _ _ _) = do
  let connection = systemdBusWithin (Identity.hostExecutionWorkEnd (Operation.hostOperationWindow intent)) original
      path = invocationPathText alias
      property = hostProperty connection path "Unit"
      controller = Operation.hostOperationUnitName intent Operation.OperationController
      timer = Operation.hostOperationUnitName intent Operation.OperationTimer
      slice = Operation.hostOperationUnitName intent Operation.OperationSlice
  description <- property "Description" readVariantString
  transient <- property "Transient" readVariantBoolean
  load <- property "LoadState" readVariantString
  state <- property "ActiveState" readVariantString
  job <- property "Job" readVariantJob
  binds <- property "BindsTo" (readVariantStrings 16)
  after <- property "After" (readVariantStrings 16)
  requires <- property "Requires" (readVariantStrings 16)
  ownSlice <- hostProperty connection path "Scope" "Slice" readVariantString
  unless
    ( description
        == Operation.hostOperationDescription intent <> " " <> show (Operation.hostOperationProcessRole role)
        && transient
        && load == "loaded"
        && state == "active"
        && job == UnitJobAbsent
        && binds == [controller]
        && ownSlice == slice
        && all (`elem` after) [controller, timer, slice]
        && all (`elem` [controller, timer, slice]) after
        && all (`elem` requires) [timer, slice]
        && all (`elem` [controller, timer, slice]) requires
    )
    (throwE KernelScopeIdentityChanged)

operationProcessName
  :: Operation.HostOperationIntent -> Operation.HostOperationProcessRole -> String
operationProcessName intent = Operation.hostOperationUnitName intent . Operation.hostOperationProcessRole

operationRoleState :: Operation.HostOperationProcessRole -> OperationRoles -> OperationRoleState
operationRoleState role (OperationRoles command transport) = case role of
  Operation.OperationCommandProcess -> command
  Operation.OperationTransportProcess -> transport

setOperationRoleState
  :: Operation.HostOperationProcessRole -> OperationRoleState -> OperationRoles -> OperationRoles
setOperationRoleState role value (OperationRoles command transport) = case role of
  Operation.OperationCommandProcess -> OperationRoles value transport
  Operation.OperationTransportProcess -> OperationRoles command value

withOperationProcessSlot
  :: OperationParent
  -> Operation.HostOperationProcessRole
  -> (OperationProcessUse -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withOperationProcessSlot parent@(OperationParent _ _ _ _ command transport) role action = scopeIO $ mask $ \restore -> do
  let lane = case role of
        Operation.OperationCommandProcess -> command
        Operation.OperationTransportProcess -> transport
  claimed <- tryTakeMVar lane
  case claimed of
    Nothing -> pure (Left KernelHostPlacementBusy)
    Just False -> putMVar lane False >> pure (Left KernelHostPlacementClosed)
    Just True -> flip finally (putMVar lane True) $ do
      active <- newMVar True
      attempted <- newMVar False
      before <- verifyOperationParentBeforeEffect parent
      case before of
        Left cause -> pure (Left cause)
        Right () ->
          restore (action (OperationProcessUse parent role active attempted))
            `finally` modifyMVar_ active (const (pure False))

operationProcessLimits
  :: Operation.HostOperationIntent
  -> Operation.HostOperationProcessRole
  -> Word64
  -> Maybe ScopeKernelLimits
operationProcessLimits intent role now
  | now >= Identity.hostExecutionWorkEnd window = Nothing
  | otherwise = scopeKernelLimits memory 0 tasks cpu runtime stop
 where
  plan = Operation.hostOperationPlan intent
  window = Operation.hostOperationWindow intent
  (memory, tasks, cpu) = case role of
    Operation.OperationCommandProcess ->
      ( Host.hostExecutionChildMemoryBytes plan
      , Host.hostExecutionChildTasks plan
      , Host.hostExecutionChildCpuUsecPerSec plan
      )
    Operation.OperationTransportProcess ->
      let limits = Host.hostExecutionTransportLimits plan
       in ( Host.hostTransportMemoryBytes limits
          , Host.hostTransportTasks limits
          , Host.hostTransportCpuUsecPerSec limits
          )
  runtime = (Identity.hostExecutionHardEnd window - now) `div` 1000
  stop = (Identity.hostExecutionStopEnd window - Identity.hostExecutionHardEnd window) `div` 1000

-- One create attempt per borrow. A lost request keeps an unsettled role in the
-- original family; it cannot allocate a successor name or refresh the alarm.
withOperationProcessScope
  :: OperationProcessUse
  -> Fd
  -> (KernelScope -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withOperationProcessScope (OperationProcessUse (OperationParent base timer _ parentActive _ _) role active attempted) child action =
  operationIOAt OperationProcessAdmission $ mask $ \restore -> do
    live <- withMVar active pure
    first <- modifyMVar attempted (\prior -> pure (True, not prior))
    if not live
      then pure (Left KernelHostPlacementClosed)
      else
        if not first
          then pure (Left KernelHostRoleAlreadyAttempted)
          else bracket (duplicateChild child) closeFd $ \owned -> do
            referenced <- newIORef False
            releaseFailure <- newIORef Nothing
            submitted <- newIORef False
            let OperationParentBase connection intent _ _ _ _ (HostGroup pool _) _ _ states = base
                window = Operation.hostOperationWindow intent
                work = Identity.hostExecutionWorkEnd window
                admission = systemdBusWithin work connection
                name = operationProcessName intent role
                poison = modifyMVar_ states (pure . setOperationRoleState role OperationRoleUnsettled)
                release = do
                  held <- readIORef referenced
                  when held $ do
                    writeIORef referenced False
                    result <- runExceptT (callManager connection (UnrefUnit name) (const (pure ())) (const (pure ())))
                    writeIORef releaseFailure (either Just (const Nothing) result)
                acquire current = runExceptT $ do
                  checkDeadline work
                  case operationRoleState role current of
                    OperationRoleIdle -> pure ()
                    OperationRoleLive _ _ -> throwE KernelHostPlacementBusy
                    OperationRoleUnsettled -> throwE (KernelHostRoleUnsettled role)
                  pid <- verifyDirectChild owned
                  (observedTimer, _, _) <- verifyOperationParentState current (Just pid) base
                  unless (observedTimer == timer) (throwE KernelScopeIdentityChanged)
                  now <- lift getMonotonicTimeNSec
                  limits <- maybe (throwE KernelHostWindowRefused) pure (operationProcessLimits intent role now)
                  lift (writeIORef submitted True)
                  _ <-
                    bus
                      ScopeUnitMetadata
                      ( callManager
                          admission
                          StartTransientUnit
                          (buildOperationProcess intent role owned limits)
                          (`readString` 'o')
                      )
                  identity <- awaitIdentity admission work owned name
                  bus ScopeReferenceAcquire (callManager admission (RefUnit name) (const (pure ())) (const (pure ())))
                  lift (writeIORef referenced True)
                  uid <- lift getEffectiveUserID
                  let path = operationControlGroup uid intent <> "/" <> name
                  (alias, actualPath, handles) <-
                    prepareGroup admission work owned identity limits path (openGroupAt pool name) [pool]
                  scopeActive <- lift (newMVar True)
                  let scope =
                        KernelScope
                          connection
                          alias
                          actualPath
                          handles
                          (Identity.hostExecutionStopEnd window)
                          scopeActive
                          owned
                  pure (scope, handles, scopeActive, limits)
                setup = withMVar parentActive $ \parentLive ->
                  if not parentLive
                    then pure (Left KernelHostPlacementClosed)
                    else modifyMVar states $ \current -> do
                      result <- acquire current
                      didSubmit <- readIORef submitted
                      pure $ case result of
                        Left cause ->
                          ( if didSubmit then setOperationRoleState role OperationRoleUnsettled current else current
                          , Left cause
                          )
                        Right prepared@(scope, _, _, limits) -> (setOperationRoleState role (OperationRoleLive scope limits) current, Right prepared)
                use = do
                  prepared <- setup
                  case prepared of
                    Left cause -> pure (Left cause)
                    Right (scope, handles, scopeActive, _) ->
                      let close handlesToClose = modifyMVar_ scopeActive (const (pure False)) `finally` closeGroup handlesToClose
                       in bracket (pure handles) close $ \_ -> do
                            primary <- restore (action scope) `onException` poison
                            settled <- modifyMVar states $ \current -> do
                              terminal <- observeKernelScopeEmptyBefore (Identity.hostExecutionStopEnd window) scope
                              modifyMVar_ scopeActive (const (pure False))
                              release
                              releaseCause <- readIORef releaseFailure
                              closing <- case (terminal, releaseCause) of
                                (_, Just _) -> pure (Left (KernelHostRoleUnsettled role))
                                (Right True, Nothing) -> awaitOperationRoleIdle base role
                                (Right False, Nothing) -> pure (Left (KernelHostRoleUnsettled role))
                                (Left cause, Nothing) -> pure (Left cause)
                              pure
                                ( setOperationRoleState
                                    role
                                    (either (const OperationRoleUnsettled) (const OperationRoleIdle) closing)
                                    current
                                , closing
                                )
                            pure (combineOperationResult primary settled)
            result <- (use `onException` poison) `finally` release
            refusal <- readIORef releaseFailure
            pure $ case (result, refusal) of
              (Right _, Just cause) -> Left (KernelScopeReleaseRefused cause)
              (Left primary, Just cause) -> Left (KernelScopePrimaryAndReleaseRefused primary cause)
              (_, Nothing) -> result

combineOperationResult
  :: Either KernelScopeError value -> Either KernelScopeError () -> Either KernelScopeError value
combineOperationResult primary closing = case (primary, closing) of
  (Left cause, Left recheck) -> Left (KernelScopePrimaryAndRecheckRefused cause recheck)
  (Left cause, Right ()) -> Left cause
  (Right _, Left cause) -> Left cause
  (Right value, Right ()) -> Right value

verifyOperationProcessBeforeEffect
  :: OperationProcessUse -> KernelScope -> IO (Either KernelScopeError ())
verifyOperationProcessBeforeEffect (OperationProcessUse parent@(OperationParent base _ _ _ _ _) role active _) scope =
  operationIOAt OperationProcessAdmission $ withMVar active $ \live ->
    if not live
      then pure (Left KernelHostPlacementClosed)
      else do
        observed <- verifyOperationParentBeforeEffect parent
        case observed of
          Left cause -> pure (Left cause)
          Right () -> do
            let OperationParentBase _ _ _ _ _ _ _ _ _ states = base
            withMVar states verifyObservedRole
 where
  verifyObservedRole current = case operationRoleState role current of
    OperationRoleLive original _
      | kernelScopeInvocation original == kernelScopeInvocation scope
          && kernelScopeControlGroup original == kernelScopeControlGroup scope ->
          pure (Right ())
    _ -> pure (Left KernelScopeIdentityChanged)

buildOperationProcess
  :: Operation.HostOperationIntent
  -> Operation.HostOperationProcessRole
  -> Fd
  -> ScopeKernelLimits
  -> BusMessage
  -> BusAction ()
buildOperationProcess intent role (Fd descriptor) limits message = do
  appendString message (operationProcessName intent role)
  appendString message "fail"
  withContainer message 'a' "(sv)" $ do
    property
      "Description"
      "s"
      ( appendString
          message
          (Operation.hostOperationDescription intent <> " " <> show (Operation.hostOperationProcessRole role))
      )
    property
      "Slice"
      "s"
      (appendString message (Operation.hostOperationUnitName intent Operation.OperationSlice))
    property "PIDFDs" "ah" (withContainer message 'a' "h" (appendDescriptor message descriptor))
    property "CollectMode" "s" (appendString message "inactive-or-failed")
    property "KillSignal" "i" (appendInt32 message 9)
    property
      "Requires"
      "as"
      ( withContainer
          message
          'a'
          "s"
          (appendString message (Operation.hostOperationUnitName intent Operation.OperationTimer))
      )
    property "BindsTo" "as" (withContainer message 'a' "s" (appendString message controller))
    property
      "After"
      "as"
      ( withContainer
          message
          'a'
          "s"
          ( mapM_
              (appendString message)
              [Operation.hostOperationUnitName intent Operation.OperationTimer, controller]
          )
      )
    appendScopeKernelLimits message limits
  withContainer message 'a' "(sa(sv))" (pure ())
 where
  controller = Operation.hostOperationUnitName intent Operation.OperationController
  property label signature body = withContainer message 'r' "sv" $ do
    appendString message label
    withContainer message 'v' signature body

awaitOperationRoleIdle
  :: OperationParentBase -> Operation.HostOperationProcessRole -> IO (Either KernelScopeError ())
awaitOperationRoleIdle (OperationParentBase original intent _ _ _ _ _ _ _ _) role = loop
 where
  finish = Identity.hostExecutionFinishEnd (Operation.hostOperationWindow intent)
  loop = do
    now <- getMonotonicTimeNSec
    if now >= finish
      then pure (Left KernelScopeDeadlineReached)
      else do
        observed <- Operation.observeHostOperationIdleChildBefore finish original intent role
        case observed of
          Right _ -> pure (Right ())
          Left (Operation.HostOperationDeclarationRefused _) -> threadDelay 1000 >> loop
          Left cause -> pure (Left (KernelHostOperationRefused cause))

withOperationReferences
  :: BusConnection
  -> Operation.HostOperationIntent
  -> IO (Either KernelScopeError value)
  -> IO (Either KernelScopeError value)
withOperationReferences connection intent action = mask $ \restore -> do
  held <- newIORef []
  released <- newIORef Nothing
  let admission =
        systemdBusWithin (Identity.hostExecutionWorkEnd (Operation.hostOperationWindow intent)) connection
      reference role = do
        let name = Operation.hostOperationUnitName intent role
        bus ScopeReferenceAcquire (callManager admission (RefUnit name) (const (pure ())) (const (pure ())))
        lift (modifyIORef' held (name :))
      release = do
        names <- readIORef held
        results <-
          traverse
            (\name -> runExceptT (callManager connection (UnrefUnit name) (const (pure ())) (const (pure ()))))
            names
        writeIORef released (case [cause | Left cause <- results] of first : _ -> Just first; [] -> Nothing)
      use = do
        references <-
          runExceptT
            ( mapM_
                reference
                [ Operation.OperationController
                , Operation.OperationSlice
                , Operation.OperationTimer
                , Operation.OperationExpiry
                ]
            )
        case references of
          Left cause -> pure (Left cause)
          Right () -> restore action
  result <- use `finally` release
  closing <- readIORef released
  pure $ case (result, closing) of
    (Right _, Just cause) -> Left (KernelScopeReleaseRefused cause)
    (Left primary, Just cause) -> Left (KernelScopePrimaryAndReleaseRefused primary cause)
    (_, Nothing) -> result

-- Serialize the physical child slot. Closing a placement joins an outstanding
-- borrow before its descriptors are released; an escaped borrow is invalidated.
withHostPlacementSlot
  :: HostPlacement
  -> (HostPlacementUse -> BusConnection -> IO (Either KernelScopeError value))
  -> IO (Either KernelScopeError value)
withHostPlacementSlot placement@(HostPlacement connection _ _ _ _ _ _ window _ active) action = scopeIO $ mask $ \restore -> do
  claimed <- tryTakeMVar active
  case claimed of
    Nothing -> pure (Left KernelHostPlacementBusy)
    Just False -> putMVar active False >> pure (Left KernelHostPlacementClosed)
    Just True -> do
      borrowed <- newMVar True
      let token = HostPlacementUse placement borrowed
          run = do
            before <-
              runExceptT (verifyHostPlacement HostSlotEmpty (Identity.hostExecutionWorkEnd window) placement)
            case before of
              Left cause -> pure (Left cause)
              Right () -> do
                primary <-
                  restore (action token (systemdBusWithin (Identity.hostExecutionStopEnd window) connection))
                closing <-
                  runExceptT (verifyHostPlacement HostSlotEmpty (Identity.hostExecutionFinishEnd window) placement)
                pure (closing >> primary)
      result <-
        (run `finally` modifyMVar_ borrowed (const (pure False)))
          `onException` putMVar active False
      putMVar active (case result of Right _ -> True; Left _ -> False)
      pure result

verifyHostPlacementBeforeEffect :: HostPlacementUse -> IO (Either KernelScopeError ())
verifyHostPlacementBeforeEffect token@(HostPlacementUse placement _) =
  withHostPlacementUse
    token
    ( verifyHostPlacement
        HostChildAdmitted
        (Identity.hostExecutionWorkEnd (hostPlacementWindow token))
        placement
    )

-- The blocked direct child still shares the controller's cgroup until the
-- manager admits its PIDFD. It is the sole additional process allowed there.
verifyHostPlacementBeforeAdmission
  :: HostPlacementUse -> Fd -> ScopeKernelLimits -> IO (Either KernelScopeError ())
verifyHostPlacementBeforeAdmission token@(HostPlacementUse placement _) child limits =
  withHostPlacementUse token $ do
    pid <- verifyDirectChild child
    verifyHostChildLimits token (hostScopeName token) limits
    verifyHostPlacement
      (HostChildWaiting pid)
      (Identity.hostExecutionWorkEnd (hostPlacementWindow token))
      placement

hostScopeName :: HostPlacementUse -> String
hostScopeName token = "prodbox-owned-" <> Identity.hostExecutionKeyText (hostPlacementKey token) <> ".scope"

verifyHostChildLimits :: HostPlacementUse -> String -> ScopeKernelLimits -> ScopeAction ()
verifyHostChildLimits token name (ScopeKernelLimits memory swap tasks cpu runtime stop) = do
  let plan = hostPlacementPlan token
      window = hostPlacementWindow token
  unless
    ( name == hostScopeName token
        && memory == Host.hostExecutionChildMemoryBytes plan
        && swap == 0
        && tasks == Host.hostExecutionChildTasks plan
        && cpu == Host.hostExecutionChildCpuUsecPerSec plan
        && runtime > 0
        && runtime <= Host.hostExecutionMaximumChildMicros plan
        && stop > 0
        && toInteger stop * 1000
          <= toInteger (Identity.hostExecutionStopEnd window) - toInteger (Identity.hostExecutionHardEnd window)
    )
    (throwE KernelScopeResourceMismatch)

withHostPlacementUse :: HostPlacementUse -> ScopeAction value -> IO (Either KernelScopeError value)
withHostPlacementUse (HostPlacementUse _ active) action = scopeIO $ withMVar active $ \open ->
  if open then runExceptT action else pure (Left KernelHostPlacementClosed)

verifyHostPlacement :: HostPlacementPhase -> Word64 -> HostPlacement -> ScopeAction ()
verifyHostPlacement phase bound (HostPlacement original alias slice pool parent plan key window runtimeDirectory _) = do
  checkDeadline bound
  current <- lift getProcessID
  flags <- lift Rts.getRTSFlags
  let actualHeap = toInteger (Rts.maxHeapSize (Rts.gcFlags flags)) * toInteger runtimeBlockBytes
      declaredHeap =
        toInteger
          ( Runtime.positiveBytesValue
              (Runtime.runtimeMemoryHeapCapBytes (Host.hostExecutionRuntimeMemory plan))
          )
  unless (actualHeap > 0 && actualHeap == declaredHeap) (throwE KernelHostParentRefused)
  let connection = systemdBusWithin bound original
      path = invocationPathText alias
      unit name decode = hostProperty connection path "Unit" name decode
      service name decode = hostProperty connection path "Service" name decode
  name <- unit "Id" readVariantString
  invocation <- unit "InvocationID" readVariantInvocationId
  description <- unit "Description" readVariantString
  state <- unit "ActiveState" readVariantString
  transient <- unit "Transient" readVariantBoolean
  mainPid <- service "MainPID" readVariantWord32
  kind <- service "Type" readVariantString
  ownSlice <- service "Slice" readVariantString
  remain <- service "RemainAfterExit" readVariantBoolean
  mode <- service "KillMode" readVariantString
  finalSignal <- service "FinalKillSignal" readVariantInt32
  sendKill <- service "SendSIGKILL" readVariantBoolean
  directoryName <- service "RuntimeDirectory" readVariantSingleString
  directoryMode <- service "RuntimeDirectoryMode" readVariantWord32
  directoryPreserve <- service "RuntimeDirectoryPreserve" readVariantString
  _ <- service "ExecStop" readVariantNoExecStop
  _ <- service "ExecStopPost" readVariantNoExecStop
  unless
    ( name == Identity.hostControllerUnitName
        && invocation == invocationPathId alias
        && description == hostPlacementDescription plan key window
        && state == "active"
        && transient
        && toInteger mainPid == toInteger current
        && kind == "exec"
        && not remain
        && ownSlice == Identity.hostControllerSliceName
        && mode == "control-group"
        && finalSignal == 9
        && sendKill
        && directoryName == Identity.hostControllerRuntimeDirectoryName
        && directoryMode == 0o700
        && directoryPreserve == "no"
    )
    (throwE KernelHostParentRefused)
  activeSince <- unit "ActiveEnterTimestampMonotonic" readVariantWord64
  runtime <- service "RuntimeMaxUSec" readVariantWord64
  stop <- service "TimeoutStopUSec" readVariantWord64
  extra <- service "RuntimeRandomizedExtraUSec" readVariantWord64
  now <- lift getMonotonicTimeNSec
  let workExpiry = (toInteger activeSince + toInteger runtime) * 1000
      terminal = workExpiry + toInteger stop * 1000
  unless
    ( activeSince > 0
        && toInteger activeSince * 1000 <= toInteger now
        && runtime > 0
        && runtime < maxBound
        && stop > 0
        && stop < maxBound
        && extra == 0
        && toInteger (Identity.hostExecutionFinishEnd window) < workExpiry
        && terminal <= toInteger (Identity.hostExecutionOuterEnd window)
        && now < Identity.hostExecutionFinishEnd window
        && toInteger (Identity.hostExecutionFinishEnd window) - toInteger now
          <= toInteger (Host.hostExecutionMaximumChildMicros plan) * 1000
    )
    (throwE KernelHostWindowRefused)
  uid <- lift getEffectiveUserID
  verifyHostRuntimeDirectory uid runtimeDirectory
  let poolPath = hostControlGroup uid
      parentPath = poolPath <> "/" <> Identity.hostControllerUnitName
  actualParent <- service "ControlGroup" readVariantString
  actualSlice <- hostProperty connection slice "Slice" "ControlGroup" readVariantString
  sliceName <- hostProperty connection slice "Unit" "Id" readVariantString
  membership <- lift (readBoundedFile "/proc/self/cgroup" 4096)
  unless
    ( actualParent == parentPath
        && actualSlice == poolPath
        && sliceName == Identity.hostControllerSliceName
        && Bytes.lines membership == [Bytes.pack ("0::" <> parentPath)]
    )
    (throwE KernelScopeIdentityChanged)
  verifyHostManagerCaps
    connection
    path
    "Service"
    (Host.hostExecutionParentMemoryBytes plan)
    (Host.hostExecutionParentTasks plan)
    (Host.hostExecutionParentCpuUsecPerSec plan)
  verifyHostManagerCaps
    connection
    slice
    "Slice"
    (Host.hostExecutionSliceMemoryBytes plan)
    (Host.hostExecutionSliceTasks plan)
    (Host.hostExecutionSliceCpuUsecPerSec plan)
  verifyHostKernelCaps
    parent
    (Host.hostExecutionParentMemoryBytes plan)
    (Host.hostExecutionParentTasks plan)
    (Host.hostExecutionParentCpuUsecPerSec plan)
  verifyHostKernelCaps
    pool
    (Host.hostExecutionSliceMemoryBytes plan)
    (Host.hostExecutionSliceTasks plan)
    (Host.hostExecutionSliceCpuUsecPerSec plan)
  let HostGroup parentRoot _ = parent
      HostGroup poolRoot _ = pool
      HostGroup _ parentEvents = parent
      HostGroup _ poolEvents = pool
  verifyDescriptorMounts [poolRoot, poolEvents, parentRoot, parentEvents]
  processes <- lift (readRelative parentRoot "cgroup.procs")
  let expectedProcesses = case phase of
        HostChildWaiting child -> [current, child]
        HostSlotEmpty -> [current]
        HostChildAdmitted -> [current]
      actualProcesses = Bytes.words processes
  unless
    ( length actualProcesses == length expectedProcesses
        && all (\pid -> Bytes.pack (show pid) `elem` actualProcesses) expectedProcesses
    )
    (throwE KernelHostParentRefused)
  directories <- ExceptT (hostDirectories poolRoot)
  let field = "prodbox-owned-" <> Identity.hostExecutionKeyText key
      ours = [Identity.hostControllerUnitName, field <> ".scope", field <> "-expiry.service"]
  unless (all (`elem` ours) directories) (throwE KernelHostForeignGroup)
  let expected = case phase of
        HostSlotEmpty -> [Identity.hostControllerUnitName]
        HostChildWaiting _ -> [Identity.hostControllerUnitName]
        HostChildAdmitted -> [Identity.hostControllerUnitName, field <> ".scope"]
  unless
    (length directories == length expected && all (`elem` expected) directories)
    (throwE KernelHostFamilyPresent)
  checkDeadline bound

openHostRuntimeDirectory :: IO HostRuntimeDirectory
openHostRuntimeDirectory = openHostRuntimeDirectoryNamed Identity.hostControllerRuntimeDirectoryName

openHostRuntimeDirectoryNamed :: String -> IO HostRuntimeDirectory
openHostRuntimeDirectoryNamed name = do
  uid <- getEffectiveUserID
  let path = "/run/user/" <> show uid <> "/" <> name
  HostRuntimeDirectory path <$> openAnchored (filter (not . null) (splitPath path))

closeHostRuntimeDirectory :: HostRuntimeDirectory -> IO ()
closeHostRuntimeDirectory (HostRuntimeDirectory _ descriptor) = closeFd descriptor

-- A held descriptor alone could outlive replacement of its path. Require the
-- linked directory to retain the same private identity before every effect.
verifyHostRuntimeDirectory :: UserID -> HostRuntimeDirectory -> ScopeAction ()
verifyHostRuntimeDirectory uid (HostRuntimeDirectory path descriptor) = do
  held <- lift (getFdStatus descriptor)
  linked <- lift $ bracket (openAnchored (filter (not . null) (splitPath path))) closeFd getFdStatus
  unless
    ( all
        (\status -> isDirectory status && fileOwner status == uid && fileMode status .&. 0o7777 == 0o700)
        [held, linked]
        && deviceID held == deviceID linked
        && fileID held == fileID linked
    )
    (throwE KernelScopeFilesystemRefused)

hostControlGroup :: UserID -> String
hostControlGroup uid =
  hostManagerControlGroupPath uid <> "/" <> Identity.hostControllerSliceName

operationControlGroup :: UserID -> Operation.HostOperationIntent -> String
operationControlGroup uid intent =
  hostManagerControlGroupPath uid
    <> "/"
    <> Operation.hostOperationUnitName intent Operation.OperationSlice

hostManagerControlGroupPath :: UserID -> String
hostManagerControlGroupPath uid =
  "/user.slice/user-"
    <> show uid
    <> ".slice/user@"
    <> show uid
    <> ".service"

hostProperty
  :: BusConnection -> String -> String -> String -> (BusMessage -> BusAction value) -> ScopeAction value
hostProperty connection path interface name decode =
  bus ScopeUnitMetadata $
    callManager
      connection
      (ReadUnitProperty path)
      ( \message -> appendString message ("org.freedesktop.systemd1." <> interface) >> appendString message name
      )
      decode

verifyHostManagerCaps
  :: BusConnection -> String -> String -> Word64 -> Word64 -> Word64 -> ScopeAction ()
verifyHostManagerCaps connection path interface memory tasks cpu = do
  values <-
    traverse
      (\name -> hostProperty connection path interface name readVariantWord64)
      ["MemoryMax", "MemorySwapMax", "TasksMax", "CPUQuotaPerSecUSec"]
  unless (values == [memory, 0, tasks, cpu]) (throwE KernelScopeResourceMismatch)

verifyHostKernelCaps :: HostGroup -> Word64 -> Word64 -> Word64 -> ScopeAction ()
verifyHostKernelCaps (HostGroup root events) memory tasks cpu = do
  verifyDescriptorMounts [root, events]
  values <- lift (traverse (readRelative root) ["memory.max", "memory.swap.max", "pids.max"])
  unless (values == map (Bytes.pack . show) [memory, 0, tasks]) (throwE KernelScopeResourceMismatch)
  quota <- lift (readRelative root "cpu.max")
  unless (cpuQuotaMatches cpu quota) (throwE KernelScopeResourceMismatch)

openHostGroup :: String -> IO HostGroup
openHostGroup path = do
  root <- openAnchored (filter (not . null) (splitPath ("/sys/fs/cgroup" <> path)))
  hostGroupFromRoot root

openHostGroupAt :: Fd -> String -> IO HostGroup
openHostGroupAt parent name = openFdAt (Just parent) name ReadOnly (safeFlags {directory = True}) >>= hostGroupFromRoot

hostGroupFromRoot :: Fd -> IO HostGroup
hostGroupFromRoot root = do
  events <- openFdAt (Just root) "cgroup.events" ReadOnly safeFlags `onException` closeFd root
  pure (HostGroup root events)

closeHostGroup :: HostGroup -> IO ()
closeHostGroup (HostGroup root events) = closeFd events `finally` closeFd root

hostDirectories :: Fd -> IO (Either KernelScopeError [String])
hostDirectories root = bracket (openDirStream descriptor) closeDirStream $ \stream ->
  let collect count result = do
        entry <- readDirStream stream
        case entry of
          "" -> pure (Right result)
          "." -> collect count result
          ".." -> collect count result
          _
            | count >= (512 :: Int) -> pure (Left KernelScopeObservationRefused)
            | otherwise -> do
                status <- getSymbolicLinkStatus (descriptor <> "/" <> entry)
                collect (count + 1) (if isDirectory status then entry : result else result)
   in collect 0 []
 where
  descriptor = "/proc/self/fd/" <> show root

-- All anchored handles must belong to the same observed cgroup2 mount.
verifyCgroupDescriptorsBefore :: Word64 -> [Fd] -> IO (Either KernelScopeError ())
verifyCgroupDescriptorsBefore ending descriptors = scopeIO $ runExceptT $ do
  checkDeadline ending
  verifyDescriptorMounts descriptors
  checkDeadline ending

verifyDescriptorMounts :: [Fd] -> ScopeAction ()
verifyDescriptorMounts descriptors = do
  info <- lift $ traverse (\fd -> readBoundedFile ("/proc/self/fdinfo/" <> show fd) 4096) descriptors
  mounts <- lift (readBoundedFile "/proc/self/mountinfo" 1048576)
  let mountIdentifier bytes = case [ value
                                   | line <- Bytes.lines bytes
                                   , [label, value] <- [Bytes.words line]
                                   , label == Bytes.pack "mnt_id:"
                                   ] of
        [value] -> Just value
        _ -> Nothing
      cgroupMounts =
        [ identifier
        | line <- Bytes.lines mounts
        , let fields = Bytes.words line
        , Bytes.pack "cgroup2" `elem` take 1 (drop 1 (dropWhile (/= Bytes.pack "-") fields))
        , identifier : _ <- [fields]
        ]
  unless
    ( case traverse mountIdentifier info of
        Just (first : rest) -> all (== first) rest && first `elem` cgroupMounts
        _ -> False
    )
    (throwE KernelScopeFilesystemRefused)
