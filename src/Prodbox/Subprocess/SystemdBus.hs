{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- | Package-private transport for the subprocess owner's local systemd calls.
-- Authentication and replies consume the same original monotonic deadline.
-- A connection is transport only: it grants no ownership over a unit or PID.
module Prodbox.Subprocess.SystemdBus
  ( BusAction
  , BusConnection
  , BusMessage
  , BusError (..)
  , BusStage (..)
  , ManagerMethod (..)
  , withSystemdBus
  , callManager
  , managerPeerIdentity
  , observeManagerDomain
  , observeBusSender
  , observeBusRouter
  , BusNamePresence (..)
  , observeBusNamePresence
  , systemdBusDeadline
  , systemdBusWithin
  , appendString
  , appendWord64
  , appendWord32
  , appendInt32
  , appendBoolean
  , appendDescriptor
  , withContainer
  , readString
  , InvocationId
  , invocationIdFromBytes
  , invocationIdBytes
  , InvocationObservation (..)
  , invocationObservationFromBytes
  , InvocationPath
  , invocationPathFromReply
  , invocationPathText
  , invocationPathId
  , readInvocationId
  , readInvocationObservation
  , readInvocationPath
  , readVariantString
  , readVariantSingleString
  , readVariantStrings
  , readVariantExactCommand
  , readVariantOriginalBootTimer
  , readVariantNoCalendarTimers
  , readVariantInvocationId
  , readVariantInvocationObservation
  , readVariantWord64
  , readVariantWord32
  , readVariantInt32
  , readVariantBoolean
  , readVariantNoExecStop
  , readVariantDormantNoOp
  , UnitJobObservation (..)
  , readVariantJob
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception
  ( IOException
  , bracket
  , bracketOnError
  , finally
  , mask
  , mask_
  , try
  , uninterruptibleMask_
  )
import Control.Monad (unless, void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as ByteChars
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Word (Word32, Word64)
import Foreign (FunPtr, Ptr, alloca, castPtr, freeHaskellFunPtr, nullPtr, peek, poke, with)
import Foreign.C.String (CString, peekCStringLen, withCString)
import Foreign.C.Types (CChar (..), CInt (..), CSize (..))
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.OwnedProcessTree (ProcessStat (..), parseProcessStat)
import Prodbox.Subprocess.SystemdIdentity
import System.Posix.DynamicLinker (DL, RTLDFlags (RTLD_NOW), dlclose, dlopen, dlsym)
import System.Posix.Files (fileOwner, getSymbolicLinkStatus, isSocket)
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as NativeIO
import System.Posix.Process (getProcessID)
import System.Posix.Signals (sigTERM)
import System.Posix.User (getEffectiveUserID)

data NativeBus
data NativeMessage
data NativeSlot

type AllocateBus = Ptr (Ptr NativeBus) -> IO CInt
type SetAddress = Ptr NativeBus -> CString -> IO CInt
type SetClient = Ptr NativeBus -> CInt -> IO CInt
type BusState = Ptr NativeBus -> IO CInt
type ProcessBus = Ptr NativeBus -> Ptr (Ptr NativeMessage) -> IO CInt
type WaitBus = Ptr NativeBus -> Word64 -> IO CInt
type NewMessage =
  Ptr NativeBus -> Ptr (Ptr NativeMessage) -> CString -> CString -> CString -> CString -> IO CInt
type MessageHandler = Ptr NativeMessage -> Ptr () -> Ptr () -> IO CInt
type CallAsync =
  Ptr NativeBus
  -> Ptr (Ptr NativeSlot)
  -> Ptr NativeMessage
  -> FunPtr MessageHandler
  -> Ptr ()
  -> Word64
  -> IO CInt
type OpenContainer = Ptr NativeMessage -> CChar -> CString -> IO CInt
type CloseContainer = Ptr NativeMessage -> IO CInt
type AppendBasic = Ptr NativeMessage -> CChar -> Ptr () -> IO CInt
type ReadBasic = Ptr NativeMessage -> CChar -> Ptr () -> IO CInt
type NameValidity = CString -> IO CInt
type GetUniqueName = Ptr NativeBus -> Ptr CString -> IO CInt
type ReadArray = Ptr NativeMessage -> CChar -> Ptr (Ptr ()) -> Ptr CSize -> IO CInt
type AppendArray = Ptr NativeMessage -> CChar -> Ptr () -> CSize -> IO CInt
type MessageError = Ptr NativeMessage -> CString -> IO CInt
type MessageErrno = Ptr NativeMessage -> IO CInt
type RefMessage = Ptr NativeMessage -> IO (Ptr NativeMessage)
type UnrefBus = Ptr NativeBus -> IO (Ptr NativeBus)
type UnrefSlot = Ptr NativeSlot -> IO (Ptr NativeSlot)

foreign import ccall "dynamic" allocateBusCall :: FunPtr AllocateBus -> AllocateBus
foreign import ccall "dynamic" setAddressCall :: FunPtr SetAddress -> SetAddress
foreign import ccall "dynamic" setClientCall :: FunPtr SetClient -> SetClient
foreign import ccall "dynamic" busStateCall :: FunPtr BusState -> BusState
foreign import ccall "dynamic" processBusCall :: FunPtr ProcessBus -> ProcessBus
foreign import ccall "dynamic" waitBusCall :: FunPtr WaitBus -> WaitBus
foreign import ccall "dynamic" newMessageCall :: FunPtr NewMessage -> NewMessage
foreign import ccall "dynamic" callAsyncCall :: FunPtr CallAsync -> CallAsync
foreign import ccall "wrapper" wrapHandler :: MessageHandler -> IO (FunPtr MessageHandler)
foreign import ccall "dynamic" openContainerCall :: FunPtr OpenContainer -> OpenContainer
foreign import ccall "dynamic" closeContainerCall :: FunPtr CloseContainer -> CloseContainer
foreign import ccall "dynamic" appendBasicCall :: FunPtr AppendBasic -> AppendBasic
foreign import ccall "dynamic" readBasicCall :: FunPtr ReadBasic -> ReadBasic
foreign import ccall "dynamic" nameValidityCall :: FunPtr NameValidity -> NameValidity
foreign import ccall "dynamic" getUniqueNameCall :: FunPtr GetUniqueName -> GetUniqueName
foreign import ccall "dynamic" readArrayCall :: FunPtr ReadArray -> ReadArray
foreign import ccall "dynamic" appendArrayCall :: FunPtr AppendArray -> AppendArray
foreign import ccall "dynamic" messageErrorCall :: FunPtr MessageError -> MessageError
foreign import ccall "dynamic" messageErrnoCall :: FunPtr MessageErrno -> MessageErrno
foreign import ccall "dynamic" refMessageCall :: FunPtr RefMessage -> RefMessage
foreign import ccall "dynamic" unrefBusCall :: FunPtr UnrefBus -> UnrefBus
foreign import ccall "dynamic" unrefSlotCall :: FunPtr UnrefSlot -> UnrefSlot
foreign import ccall unsafe "strnlen" boundedStringLength :: CString -> CSize -> IO CSize

data Api = Api
  { allocateBus :: AllocateBus
  , setAddress :: SetAddress
  , setClient :: SetClient
  , startBus :: BusState
  , isReady :: BusState
  , processBus :: ProcessBus
  , waitBus :: WaitBus
  , newMessage :: NewMessage
  , callAsync :: CallAsync
  , openContainer :: OpenContainer
  , closeContainer :: CloseContainer
  , enterContainer :: OpenContainer
  , exitContainer :: CloseContainer
  , appendBasic :: AppendBasic
  , readBasic :: ReadBasic
  , readArray :: ReadArray
  , appendArray :: AppendArray
  , isMethodError :: MessageError
  , messageErrno :: MessageErrno
  , refMessage :: RefMessage
  , unrefMessage :: RefMessage
  , unrefBus :: UnrefBus
  , unrefSlot :: UnrefSlot
  , validServiceName :: NameValidity
  , getUniqueName :: GetUniqueName
  }

data BusStage = BusConnect | BusAuthenticate | BusRequest | BusReply | BusDecode | BusRelease
  deriving (Eq, Show)

data BusError
  = BusDeadlineReached !BusStage
  | BusSocketRefused
  | BusLibraryUnavailable
  | BusIoRefused
  | BusActionIoRefused
  | BusNativeRefused !BusStage !Int
  | BusMethodRefused !Int
  | BusMalformedReply
  | BusInputRefused
  | BusManagerIdentityRefused
  | BusConnectionClosed
  deriving (Eq, Show)

type BusAction = ExceptT BusError IO

data ManagerPeer = ManagerPeer !String !Word32
  deriving (Eq, Show)

data BusConnection = BusConnection !Api !(Ptr NativeBus) !Word64 !(Maybe ManagerPeer) !(MVar Bool)

systemdBusDeadline :: BusConnection -> Word64
systemdBusDeadline (BusConnection _ _ deadline _ _) = deadline

-- A borrowed view can consume less of the original bound, never renew it.
systemdBusWithin :: Word64 -> BusConnection -> BusConnection
systemdBusWithin earlier (BusConnection api pointer original peer live) =
  BusConnection api pointer (min earlier original) peer live

-- Identifier observation only; ownership still needs the exact child/unit proof.
managerPeerIdentity :: BusConnection -> Maybe (String, Word32)
managerPeerIdentity (BusConnection _ _ _ peer _) = projectPeer peer
 where
  projectPeer Nothing = Nothing
  projectPeer (Just (ManagerPeer name user)) = Just (name, user)

data NativeRequest
  = ManagerRequest !ManagerMethod
  | ResolveManagerOwner
  | ResolveManagerUser !String
  | ResolveBusId
  | ResolveManagerProcess !String
  | ResolveNamePresence !HostBusUniqueName
data BusMessage = BusMessage !Api !(Ptr NativeMessage) !Word64

data BusNamePresence = BusNamePresent | BusNameAbsent
  deriving (Eq, Show)

-- Exact-name ownership is data only. Absence cannot certify that an earlier
-- method completed, qualify a provider contract or authorize input retirement.
observeBusNamePresence :: BusConnection -> HostBusUniqueName -> BusAction BusNamePresence
observeBusNamePresence connection name =
  callNative connection (ResolveNamePresence name) (const (pure ())) $ \message -> do
    value <- readSigned32 message 'b'
    case value of
      0 -> pure BusNameAbsent
      1 -> pure BusNamePresent
      _ -> throwE BusMalformedReply

-- | These are the owner's closed manager operations, not an arbitrary bus RPC.
data ManagerMethod
  = StartTransientUnit
  | StopUnit
  | GetUnit
  | GetUnitByPIDFD !CInt
  | GetUnitByInvocationID !InvocationId
  | RefUnit !String
  | UnrefUnit !String
  | StopInvocationUnit !InvocationPath
  | TerminateInvocationUnit !InvocationPath
  | ReadUnitProperty !String
  deriving (Eq, Show)

loadApi :: DL -> IO Api
loadApi library =
  Api . allocateBusCall
    <$> dlsym library "sd_bus_new"
    <*> (setAddressCall <$> dlsym library "sd_bus_set_address")
    <*> (setClientCall <$> dlsym library "sd_bus_set_bus_client")
    <*> (busStateCall <$> dlsym library "sd_bus_start")
    <*> (busStateCall <$> dlsym library "sd_bus_is_ready")
    <*> (processBusCall <$> dlsym library "sd_bus_process")
    <*> (waitBusCall <$> dlsym library "sd_bus_wait")
    <*> (newMessageCall <$> dlsym library "sd_bus_message_new_method_call")
    <*> (callAsyncCall <$> dlsym library "sd_bus_call_async")
    <*> (openContainerCall <$> dlsym library "sd_bus_message_open_container")
    <*> (closeContainerCall <$> dlsym library "sd_bus_message_close_container")
    <*> (openContainerCall <$> dlsym library "sd_bus_message_enter_container")
    <*> (closeContainerCall <$> dlsym library "sd_bus_message_exit_container")
    <*> (appendBasicCall <$> dlsym library "sd_bus_message_append_basic")
    <*> (readBasicCall <$> dlsym library "sd_bus_message_read_basic")
    <*> (readArrayCall <$> dlsym library "sd_bus_message_read_array")
    <*> (appendArrayCall <$> dlsym library "sd_bus_message_append_array")
    <*> (messageErrorCall <$> dlsym library "sd_bus_message_is_method_error")
    <*> (messageErrnoCall <$> dlsym library "sd_bus_message_get_errno")
    <*> (refMessageCall <$> dlsym library "sd_bus_message_ref")
    <*> (refMessageCall <$> dlsym library "sd_bus_message_unref")
    <*> (unrefBusCall <$> dlsym library "sd_bus_unref")
    <*> (unrefSlotCall <$> dlsym library "sd_bus_slot_unref")
    <*> (nameValidityCall <$> dlsym library "sd_bus_service_name_is_valid")
    <*> (getUniqueNameCall <$> dlsym library "sd_bus_get_unique_name")

-- The daemon-assigned name of this exact opened connection. It remains data:
-- neither its later disappearance nor this snapshot proves a queued call drained.
observeBusSender :: BusConnection -> BusAction HostBusUniqueName
observeBusSender connection@(BusConnection api bus deadline _ _) = do
  _ <- remaining BusDecode deadline
  name <- ExceptT $ withOpenConnection connection $ fmap Right $ alloca $ \output -> do
    poke output nullPtr
    status <- getUniqueName api bus output
    pointer <- peek output
    if status < 0 || pointer == nullPtr
      then pure Nothing
      else do
        size <- boundedStringLength pointer 256
        if size > 255
          then pure Nothing
          else hostBusUniqueName <$> peekCStringLen (pointer, fromIntegral size)
  sender <- maybe (throwE BusManagerIdentityRefused) pure name
  let text = hostBusUniqueNameText sender
  user <- callNative connection (ResolveManagerUser text) (const (pure ())) readWord32
  pid <- callNative connection (ResolveManagerProcess text) (const (pure ())) readWord32
  expectedUser <- lift getEffectiveUserID
  expectedPid <- lift getProcessID
  unless
    (toInteger user == toInteger expectedUser && toInteger pid == toInteger expectedPid)
    (throwE BusManagerIdentityRefused)
  _ <- remaining BusDecode deadline
  pure sender

-- Router identity data, from the same authenticated bus instance. A later
-- interpreter independently verifies the exact process and approved code.
observeBusRouter :: BusConnection -> BusAction (Word32, Word32)
observeBusRouter connection = do
  pid <-
    callNative connection (ResolveManagerProcess "org.freedesktop.DBus") (const (pure ())) readWord32
  uid <-
    callNative connection (ResolveManagerUser "org.freedesktop.DBus") (const (pure ())) readWord32
  unless (pid > 0 && pid <= 2147483647) (throwE BusManagerIdentityRefused)
  pure (pid, uid)

withOpenConnection :: BusConnection -> IO (Either BusError value) -> IO (Either BusError value)
withOpenConnection (BusConnection _ _ _ _ active) action = withMVar active $ \live ->
  if live then action else pure (Left BusConnectionClosed)

-- | Explicit local Unix socket, never ambient DBUS/XDG address discovery.
-- The caller must separately attest the manager, unit identity and resource plan.
withSystemdBus
  :: Word64
  -> FilePath
  -> (BusConnection -> BusAction value)
  -> IO (Either BusError value)
withSystemdBus deadline socket action = do
  entered <- getMonotonicTimeNSec
  if entered >= deadline
    then pure (Left (BusDeadlineReached BusConnect))
    else do
      accepted <- try (validateSocket socket) :: IO (Either IOException Bool)
      case accepted of
        Left _ -> pure (Left BusSocketRefused)
        Right False -> pure (Left BusSocketRefused)
        Right True -> do
          result <- tryIO withLibrary
          case result of
            Left _ -> pure (Left BusIoRefused)
            Right (Left cause) -> pure (Left cause)
            Right (Right value) -> do
              finished <- getMonotonicTimeNSec
              pure (if finished >= deadline then Left (BusDeadlineReached BusRelease) else Right value)
 where
  withLibrary = bracket acquireLibrary releaseLibrary useLibrary
  useLibrary loaded = case loaded of
    Left _ -> pure (Left BusLibraryUnavailable)
    Right (_, api) -> bracket (acquire api) (release api) (useBus api)
  useBus api allocated = case allocated of
    Left cause -> pure (Left cause)
    Right bus -> do
      active <- newMVar True
      runExceptT
        ( do
            _ <- remaining BusConnect deadline
            checked BusConnect (withCString ("unix:path=" <> socket) (setAddress api bus))
            checked BusConnect (setClient api bus 1)
            checked BusConnect (startBus api bus)
            awaitReady api bus deadline
            pinned <- pinManager (BusConnection api bus deadline Nothing active)
            ExceptT $ do
              outcome <- tryIO (runExceptT (action pinned))
              pure $ case outcome of
                Left _ -> Left BusActionIoRefused
                Right value -> value
        )
        `finally` uninterruptibleMask_ (modifyMVar_ active (const (pure False)))
  acquireLibrary = tryIO $
    bracketOnError (dlopen "libsystemd.so.0" [RTLD_NOW]) dlclose $ \library -> do
      api <- loadApi library
      pure (library, api)
  releaseLibrary (Left _) = pure ()
  releaseLibrary (Right (library, _)) = dlclose library
  acquire api = runExceptT $ do
    _ <- remaining BusConnect deadline
    allocated <- lift $ alloca $ \output -> do
      poke output nullPtr
      status <- allocateBus api output
      pointer <- peek output
      pure $
        if status < 0 || pointer == nullPtr
          then Left (BusNativeRefused BusConnect (fromIntegral status))
          else Right pointer
    either throwE pure allocated
  release _ (Left _) = pure ()
  release api (Right bus) = void (unrefBus api bus)

tryIO :: IO value -> IO (Either IOException value)
tryIO = try

validateSocket :: FilePath -> IO Bool
validateSocket path
  | null path || not (lengthWithin 107 path) || not (all allowed path) = pure False
  | otherwise = case path of
      '/' : _ -> do
        status <- getSymbolicLinkStatus path
        owner <- getEffectiveUserID
        pure (isSocket status && fileOwner status == owner)
      _ -> pure False
 where
  allowed c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("/._-" :: String)

remaining :: BusStage -> Word64 -> BusAction Word64
remaining stage deadline = do
  now <- lift getMonotonicTimeNSec
  if now >= deadline
    then throwE (BusDeadlineReached stage)
    else pure (max 1 ((deadline - now) `div` 1000))

checked :: BusStage -> IO CInt -> BusAction ()
checked stage action = do
  result <- lift action
  when (result < 0) (throwE (BusNativeRefused stage (fromIntegral result)))

awaitReady :: Api -> Ptr NativeBus -> Word64 -> BusAction ()
awaitReady api bus deadline = do
  _ <- remaining BusAuthenticate deadline
  ready <- lift (isReady api bus)
  if ready > 0
    then pure ()
    else do
      when (ready < 0) (throwE (BusNativeRefused BusAuthenticate (fromIntegral ready)))
      pump api bus deadline BusAuthenticate
      awaitReady api bus deadline

pump :: Api -> Ptr NativeBus -> Word64 -> BusStage -> BusAction ()
pump api bus deadline stage = do
  _ <- remaining stage deadline
  processed <- lift (processBus api bus nullPtr)
  when (processed < 0) (throwE (BusNativeRefused stage (fromIntegral processed)))
  when (processed == 0) $ do
    allowance <- remaining stage deadline
    -- A short bounded poll also makes cancellation observable on non-threaded RTS.
    checked stage (waitBus api bus (min allowance 1000))

callManager
  :: BusConnection
  -> ManagerMethod
  -> (BusMessage -> BusAction ())
  -> (BusMessage -> BusAction value)
  -> BusAction value
callManager connection method = callNative connection (ManagerRequest method)

callNative
  :: BusConnection
  -> NativeRequest
  -> (BusMessage -> BusAction ())
  -> (BusMessage -> BusAction value)
  -> BusAction value
callNative connection@(BusConnection api bus deadline peer _) requestKind build decode = ExceptT $ withOpenConnection connection $ mask $ \restore -> do
  allocated <- runExceptT acquire
  case allocated of
    Left cause -> pure (Left cause)
    Right message -> bracket (pure message) (void . unrefMessage api) $ \request ->
      restore $ runExceptT $ do
        appendRequestArguments requestKind (BusMessage api request deadline)
        build (BusMessage api request deadline)
        ExceptT (exchange request)
 where
  acquire = do
    _ <- remaining BusRequest deadline
    (destination, path, interface, member) <- either throwE pure (requestRoute peer requestKind)
    unless (validObjectPath path) (throwE BusInputRefused)
    lift
      ( alloca $ \output -> do
          poke output nullPtr
          status <- withCString destination $ \targetService ->
            withCString path $ \object ->
              withCString interface $ \target ->
                withCString member $ \name -> newMessage api bus output targetService object target name
          pointer <- peek output
          pure $
            if status < 0 || pointer == nullPtr
              then Left (BusNativeRefused BusRequest (fromIntegral status))
              else Right pointer
      )
      >>= either throwE pure
  exchange request = do
    reply <- newIORef nullPtr
    let handler incoming _ _ = mask_ $ do
          retained <- refMessage api incoming
          old <- readIORef reply
          if old == nullPtr then writeIORef reply retained else void (unrefMessage api retained)
          pure 1
        cleanupReply = readIORef reply >>= \pointer -> unless (pointer == nullPtr) (void (unrefMessage api pointer))
    bracket (wrapHandler handler) freeHaskellFunPtr $ \callback ->
      bracket (pure ()) (const cleanupReply) $ \() ->
        alloca $ \slot -> do
          poke slot nullPtr
          bracket
            (pure ())
            (const (peek slot >>= \pointer -> unless (pointer == nullPtr) (void (unrefSlot api pointer))))
            $ \() ->
              runExceptT $ do
                allowance <- remaining BusRequest deadline
                checked BusRequest (callAsync api bus slot request callback nullPtr allowance)
                response <- awaitReply reply
                methodError <- lift (isMethodError api response nullPtr)
                when (methodError < 0) (throwE BusMalformedReply)
                when (methodError > 0) $ do
                  cause <- lift (messageErrno api response)
                  throwE (BusMethodRefused (fromIntegral cause))
                value <- decode (BusMessage api response deadline)
                _ <- remaining BusDecode deadline
                pure value
  awaitReply reply = do
    _ <- remaining BusReply deadline
    response <- lift (readIORef reply)
    if response /= nullPtr
      then pure response
      else pump api bus deadline BusReply >> awaitReply reply

validObjectPath :: String -> Bool
validObjectPath path =
  not (null path)
    && lengthWithin 1024 path
    && all (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("/_" :: String)) path
    && case path of
      '/' : _ -> True
      _ -> False

code :: Char -> CChar
code = fromIntegral . fromEnum

lengthWithin :: Int -> [value] -> Bool
lengthWithin limit = null . drop limit

appendString :: BusMessage -> String -> BusAction ()
appendString (BusMessage api message deadline) value = do
  _ <- remaining BusRequest deadline
  when (not (lengthWithin 4096 value) || '\0' `elem` value) (throwE BusInputRefused)
  checked BusRequest (withCString value (appendBasic api message (code 's') . castPtr))

appendWord64 :: BusMessage -> Word64 -> BusAction ()
appendWord64 (BusMessage api message deadline) value = do
  _ <- remaining BusRequest deadline
  checked BusRequest (with value (appendBasic api message (code 't') . castPtr))

appendWord32 :: BusMessage -> Word32 -> BusAction ()
appendWord32 (BusMessage api message deadline) value = do
  _ <- remaining BusRequest deadline
  checked BusRequest (with value (appendBasic api message (code 'u') . castPtr))

appendInt32 :: BusMessage -> CInt -> BusAction ()
appendInt32 (BusMessage api message deadline) value = do
  _ <- remaining BusRequest deadline
  checked BusRequest (with value (appendBasic api message (code 'i') . castPtr))

appendBoolean :: BusMessage -> Bool -> BusAction ()
appendBoolean (BusMessage api message deadline) value = do
  _ <- remaining BusRequest deadline
  checked
    BusRequest
    (with (if value then 1 else 0 :: CInt) (appendBasic api message (code 'b') . castPtr))

appendDescriptor :: BusMessage -> CInt -> BusAction ()
appendDescriptor (BusMessage api message deadline) descriptor = do
  _ <- remaining BusRequest deadline
  when (descriptor < 0) (throwE BusInputRefused)
  checked BusRequest (with descriptor (appendBasic api message (code 'h') . castPtr))

withContainer :: BusMessage -> Char -> String -> BusAction value -> BusAction value
withContainer (BusMessage api message deadline) kind signature action = do
  _ <- remaining BusRequest deadline
  when
    ( kind `notElem` ("arv" :: String)
        || null signature
        || not (lengthWithin 255 signature)
        || '\0' `elem` signature
    )
    (throwE BusInputRefused)
  checked BusRequest (withCString signature (openContainer api message (code kind)))
  result <- action
  checked BusRequest (closeContainer api message)
  pure result

readString :: BusMessage -> Char -> BusAction String
readString (BusMessage api message deadline) kind = do
  _ <- remaining BusDecode deadline
  unless (kind `elem` ("so" :: String)) (throwE BusInputRefused)
  result <- lift $ alloca $ \output -> do
    poke output nullPtr
    status <- readBasic api message (code kind) (castPtr output)
    pointer <- peek output
    if status <= 0 || pointer == nullPtr
      then pure Nothing
      else do
        size <- boundedStringLength pointer 4097
        if size > 4096 then pure Nothing else Just <$> peekCStringLen (pointer, fromIntegral size)
  case result of
    Nothing -> throwE BusMalformedReply
    Just value
      | length value <= 4096 -> pure value
      | otherwise -> throwE BusMalformedReply

-- Typed identity operations carry their own wire arguments. A raw builder cannot
-- replace the identifier with systemd's null/default-caller form.
appendMethodArguments :: ManagerMethod -> BusMessage -> BusAction ()
appendMethodArguments method message = case method of
  StartTransientUnit -> pure ()
  StopUnit -> pure ()
  GetUnit -> pure ()
  ReadUnitProperty _ -> pure ()
  GetUnitByPIDFD descriptor -> appendDescriptor message descriptor
  GetUnitByInvocationID identifier -> appendInvocationId message identifier
  RefUnit name -> appendString message name
  UnrefUnit name -> appendString message name
  StopInvocationUnit _ -> appendString message "replace"
  TerminateInvocationUnit _ -> appendString message "all" >> appendInt32 message (fromIntegral sigTERM)

appendInvocationId :: BusMessage -> InvocationId -> BusAction ()
appendInvocationId (BusMessage api message deadline) identifier = do
  _ <- remaining BusRequest deadline
  checked BusRequest $ Bytes.useAsCStringLen (invocationIdBytes identifier) $ \(pointer, size) ->
    appendArray api message (code 'y') (castPtr pointer) (fromIntegral size)

readInvocationId :: BusMessage -> BusAction InvocationId
readInvocationId message = do
  observed <- readInvocationObservation message
  case observed of
    InvocationAbsent -> throwE BusMalformedReply
    InvocationPresent identifier -> pure identifier

readInvocationObservation :: BusMessage -> BusAction InvocationObservation
readInvocationObservation = readInvocationObservationWith False

readInvocationObservationWith :: Bool -> BusMessage -> BusAction InvocationObservation
readInvocationObservationWith allowEmpty (BusMessage api message deadline) = do
  _ <- remaining BusDecode deadline
  value <- lift $ alloca $ \output -> alloca $ \size -> do
    poke output nullPtr
    poke size 0
    status <- readArray api message (code 'y') output size
    pointer <- peek output
    count <- peek size
    if status <= 0
      then pure Nothing
      else
        if allowEmpty && count == 0
          then pure (Just InvocationAbsent)
          else
            if pointer == nullPtr || count /= 16
              then pure Nothing
              else invocationObservationFromBytes <$> Bytes.packCStringLen (castPtr pointer, fromIntegral count)
  maybe (throwE BusMalformedReply) pure value

readInvocationPath :: InvocationId -> BusMessage -> BusAction InvocationPath
readInvocationPath expected message = do
  path <- readString message 'o'
  maybe (throwE BusMalformedReply) pure (invocationPathFromReply expected path)

readVariantString :: BusMessage -> BusAction String
readVariantString context = readVariant context "s" (readString context 's')

-- The managed workspace is exactly one directory. Exiting the array refuses
-- any extra element rather than silently accepting a prefix of the property.
readVariantSingleString :: BusMessage -> BusAction String
readVariantSingleString context@(BusMessage api native deadline) =
  readVariant context "as" $ do
    _ <- remaining BusDecode deadline
    entered <- lift (withCString "s" (enterContainer api native (code 'a')))
    unless (entered > 0) (throwE BusMalformedReply)
    value <- readString context 's'
    checked BusDecode (exitContainer api native)
    pure value

-- The caller supplies a finite schema ceiling, not an unbounded collection.
readVariantStrings :: Int -> BusMessage -> BusAction [String]
readVariantStrings limit context@(BusMessage api native deadline) = do
  unless (limit > 0 && limit <= 64) (throwE BusInputRefused)
  readVariant context "as" $ do
    entered <- lift (withCString "s" (enterContainer api native (code 'a')))
    unless (entered > 0) (throwE BusMalformedReply)
    collect 0 []
 where
  collect count values = do
    _ <- remaining BusDecode deadline
    next <- lift $ alloca $ \output -> do
      poke output nullPtr
      status <- readBasic api native (code 's') (castPtr output)
      pointer <- peek output
      if status == 0
        then pure (Right Nothing)
        else
          if status < 0 || pointer == nullPtr
            then pure (Left BusMalformedReply)
            else do
              size <- boundedStringLength pointer 4097
              if size > 4096
                then pure (Left BusMalformedReply)
                else Right . Just <$> peekCStringLen (pointer, fromIntegral size)
    case next of
      Left cause -> throwE cause
      Right Nothing -> checked BusDecode (exitContainer api native) >> pure (reverse values)
      Right (Just value)
        | count < limit -> collect (count + 1) (value : values)
        | otherwise -> throwE BusMalformedReply

-- The execution history is bounded metadata, not proof that the process lives.
-- Its command shape must be exactly the closed program selected by the owner.
readVariantExactCommand :: String -> [String] -> BusMessage -> BusAction ()
readVariantExactCommand expectedPath expectedArgs context@(BusMessage api native deadline) = do
  unless (not (null expectedArgs) && length (take 65 expectedArgs) <= 64) (throwE BusInputRefused)
  readVariant context "a(sasbttttuii)" $ do
    enter 'a' "(sasbttttuii)"
    enter 'r' "sasbttttuii"
    path <- readString context 's'
    enter 'a' "s"
    arguments <- traverse (const (readString context 's')) expectedArgs
    leave
    ignored <- readSigned32 context 'b'
    traverse_ (const (readWord64 context)) [1 .. (4 :: Int)]
    _ <- readWord32 context
    _ <- readSigned32 context 'i'
    _ <- readSigned32 context 'i'
    unless
      (path == expectedPath && arguments == expectedArgs && ignored == 0)
      (throwE BusMalformedReply)
    leave
    leave
 where
  enter kind signature = do
    _ <- remaining BusDecode deadline
    entered <- lift (withCString signature (enterContainer api native (code kind)))
    unless (entered > 0) (throwE BusMalformedReply)
  leave = checked BusDecode (exitContainer api native)

-- The manager reports timer names in microsecond form and both the original
-- value and next elapse. Refuse additional or differently based schedules.
readVariantOriginalBootTimer :: Word64 -> BusMessage -> BusAction ()
readVariantOriginalBootTimer expiry context@(BusMessage api native deadline) =
  readVariant context "a(stt)" $ do
    _ <- remaining BusDecode deadline
    checked BusDecode (withCString "(stt)" (enterContainer api native (code 'a')))
    checked BusDecode (withCString "stt" (enterContainer api native (code 'r')))
    base <- readString context 's'
    value <- readWord64 context
    next <- readWord64 context
    unless (base == "OnBootUSec" && value == expiry && next == expiry) (throwE BusMalformedReply)
    checked BusDecode (exitContainer api native)
    checked BusDecode (exitContainer api native)

readVariantNoCalendarTimers :: BusMessage -> BusAction ()
readVariantNoCalendarTimers context@(BusMessage api native deadline) =
  readVariant context "a(sst)" $ do
    _ <- remaining BusDecode deadline
    checked BusDecode (withCString "(sst)" (enterContainer api native (code 'a')))
    present <- lift (withCString "sst" (enterContainer api native (code 'r')))
    unless (present == 0) (throwE BusMalformedReply)
    checked BusDecode (exitContainer api native)

readVariantInvocationId :: BusMessage -> BusAction InvocationId
readVariantInvocationId context = readVariant context "ay" (readInvocationId context)

readVariantInvocationObservation :: BusMessage -> BusAction InvocationObservation
readVariantInvocationObservation context = readVariant context "ay" (readInvocationObservationWith True context)

readVariantWord64 :: BusMessage -> BusAction Word64
readVariantWord64 context = readVariant context "t" (readWord64 context)

readVariantWord32 :: BusMessage -> BusAction Word32
readVariantWord32 context = readVariant context "u" (readWord32 context)

readVariantInt32 :: BusMessage -> BusAction Int32
readVariantInt32 context = readVariant context "i" (readSigned32 context 'i')

readVariantBoolean :: BusMessage -> BusAction Bool
readVariantBoolean context = readVariant context "b" $ do
  value <- readSigned32 context 'b'
  case value of
    0 -> pure False
    1 -> pure True
    _ -> throwE BusMalformedReply

-- Parent termination may not acquire an unobserved sequence of ExecStop
-- allowances. Inspect only emptiness; command arguments are never decoded.
readVariantNoExecStop :: BusMessage -> BusAction ()
readVariantNoExecStop context@(BusMessage api native deadline) =
  readVariant context "a(sasbttttuii)" $ do
    _ <- remaining BusDecode deadline
    checked BusDecode (withCString "(sasbttttuii)" (enterContainer api native (code 'a')))
    present <- lift (withCString "sasbttttuii" (enterContainer api native (code 'r')))
    unless (present == 0) (throwE BusMalformedReply)
    checked BusDecode (exitContainer api native)

-- The expiry worker is one dormant /bin/true command. Read only that closed
-- shape, refusing extra arguments, commands or evidence of prior execution.
readVariantDormantNoOp :: BusMessage -> BusAction ()
readVariantDormantNoOp context@(BusMessage api native deadline) =
  readVariant context "a(sasbttttuii)" $ do
    enter 'a' "(sasbttttuii)"
    enter 'r' "sasbttttuii"
    executable <- readString context 's'
    enter 'a' "s"
    argument <- readString context 's'
    leave
    ignored <- readSigned32 context 'b'
    times <- traverse (const (readWord64 context)) [1 .. (4 :: Int)]
    pid <- readWord32 context
    reason <- readSigned32 context 'i'
    status <- readSigned32 context 'i'
    unless
      ( executable == "/bin/true"
          && argument == "/bin/true"
          && ignored == 0
          && all (== 0) times
          && pid == 0
          && reason == 0
          && status == 0
      )
      (throwE BusMalformedReply)
    leave
    leave
 where
  enter kind signature = do
    _ <- remaining BusDecode deadline
    entered <- lift (withCString signature (enterContainer api native (code kind)))
    unless (entered > 0) (throwE BusMalformedReply)
  leave = checked BusDecode (exitContainer api native)

readSigned32 :: BusMessage -> Char -> BusAction Int32
readSigned32 (BusMessage api message deadline) kind = do
  _ <- remaining BusDecode deadline
  value <- lift $ alloca $ \output -> do
    poke output 0
    status <- readBasic api message (code kind) (castPtr output)
    if status <= 0 then pure Nothing else Just <$> peek output
  maybe (throwE BusMalformedReply) pure value

data UnitJobObservation = UnitJobAbsent | UnitJobPresent !Word32
  deriving (Eq, Show)

readVariantJob :: BusMessage -> BusAction UnitJobObservation
readVariantJob context = readVariant context "(uo)" (readJob context)
 where
  readJob message@(BusMessage api native deadline) = do
    _ <- remaining BusDecode deadline
    checked BusDecode (withCString "uo" (enterContainer api native (code 'r')))
    identifier <- readWord32 message
    path <- readString message 'o'
    checked BusDecode (exitContainer api native)
    if identifier == 0 && path == "/"
      then pure UnitJobAbsent
      else
        if identifier > 0 && path == "/org/freedesktop/systemd1/job/" <> show identifier
          then pure (UnitJobPresent identifier)
          else throwE BusMalformedReply

readVariant :: BusMessage -> String -> BusAction value -> BusAction value
readVariant (BusMessage api message deadline) signature action = do
  _ <- remaining BusDecode deadline
  checked BusDecode (withCString signature (enterContainer api message (code 'v')))
  value <- action
  checked BusDecode (exitContainer api message)
  pure value

readWord64 :: BusMessage -> BusAction Word64
readWord64 (BusMessage api message deadline) = do
  _ <- remaining BusDecode deadline
  value <- lift $ alloca $ \output -> do
    poke output 0
    status <- readBasic api message (code 't') (castPtr output)
    if status <= 0 then pure Nothing else Just <$> peek output
  maybe (throwE BusMalformedReply) pure value

-- Bootstrap reads target the bus daemon; every manager request targets the one
-- latched unique connection name. A replacement well-known owner is no fallback.
requestRoute
  :: Maybe ManagerPeer -> NativeRequest -> Either BusError (String, String, String, String)
requestRoute peer requestKind = case requestKind of
  ResolveManagerOwner -> Right (daemon, daemonPath, daemon, "GetNameOwner")
  ResolveManagerUser _ -> Right (daemon, daemonPath, daemon, "GetConnectionUnixUser")
  ResolveBusId -> Right (daemon, daemonPath, daemon, "GetId")
  ResolveManagerProcess _ -> Right (daemon, daemonPath, daemon, "GetConnectionUnixProcessID")
  ResolveNamePresence _ -> Right (daemon, daemonPath, daemon, "NameHasOwner")
  ManagerRequest method -> do
    destination <- maybe (Left BusManagerIdentityRefused) (Right . peerName) peer
    let (path, interface, member) = managerRoute method
    Right (destination, path, interface, member)
 where
  daemon = "org.freedesktop.DBus"
  daemonPath = "/org/freedesktop/DBus"
  peerName (ManagerPeer name _) = name

managerRoute :: ManagerMethod -> (String, String, String)
managerRoute method = case method of
  StartTransientUnit -> root "StartTransientUnit"
  StopUnit -> root "StopUnit"
  GetUnit -> root "GetUnit"
  GetUnitByPIDFD _ -> root "GetUnitByPIDFD"
  GetUnitByInvocationID _ -> root "GetUnitByInvocationID"
  RefUnit _ -> root "RefUnit"
  UnrefUnit _ -> root "UnrefUnit"
  StopInvocationUnit target -> (invocationPathText target, "org.freedesktop.systemd1.Unit", "Stop")
  TerminateInvocationUnit target -> (invocationPathText target, "org.freedesktop.systemd1.Unit", "Kill")
  ReadUnitProperty path -> (path, "org.freedesktop.DBus.Properties", "Get")
 where
  root member = ("/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", member)

appendRequestArguments :: NativeRequest -> BusMessage -> BusAction ()
appendRequestArguments requestKind message = case requestKind of
  ResolveManagerOwner -> appendString message "org.freedesktop.systemd1"
  ResolveManagerUser name -> appendString message name
  ResolveBusId -> pure ()
  ResolveManagerProcess name -> appendString message name
  ResolveNamePresence name -> appendString message (hostBusUniqueNameText name)
  ManagerRequest method -> appendMethodArguments method message

pinManager :: BusConnection -> BusAction BusConnection
pinManager connection@(BusConnection api bus deadline _ active) = do
  name <- callNative connection ResolveManagerOwner (const (pure ())) (`readString` 's')
  unless (null (drop 255 name) && uniquePrefix name) (throwE BusManagerIdentityRefused)
  valid <- lift (withCString name (validServiceName api))
  unless (valid == 1) (throwE BusManagerIdentityRefused)
  user <- callNative connection (ResolveManagerUser name) (const (pure ())) readWord32
  expected <- lift getEffectiveUserID
  unless (toInteger user == toInteger expected) (throwE BusManagerIdentityRefused)
  pure (BusConnection api bus deadline (Just (ManagerPeer name user)) active)
 where
  uniquePrefix (':' : _) = True
  uniquePrefix _ = False

-- A bounded native snapshot of the already pinned peer, not a process lease.
-- Closing samples exclude owner/process replacement during these reads.
observeManagerDomain :: BusConnection -> BusAction HostManagerDomain
observeManagerDomain connection = do
  (name, user) <- maybe (throwE BusManagerIdentityRefused) pure (managerPeerIdentity connection)
  bus <- callNative connection ResolveBusId (const (pure ())) (`readString` 's')
  boot <- readBoot
  pid <- readPid name
  before <- readProcess pid
  closingBus <- callNative connection ResolveBusId (const (pure ())) (`readString` 's')
  closingBoot <- readBoot
  closingName <- callNative connection ResolveManagerOwner (const (pure ())) (`readString` 's')
  closingUser <- callNative connection (ResolveManagerUser name) (const (pure ())) readWord32
  closingPid <- readPid name
  after <- readProcess closingPid
  unless
    ( bus == closingBus
        && boot == closingBoot
        && name == closingName
        && user == closingUser
        && pid == closingPid
        && statStart before == statStart after
    )
    (throwE BusManagerIdentityRefused)
  value <-
    maybe
      (throwE BusManagerIdentityRefused)
      pure
      (hostManagerDomain boot bus name user pid (fromInteger (statStart before)))
  _ <- remaining BusDecode (systemdBusDeadline connection)
  pure value
 where
  readPid name = do
    pid <- callNative connection (ResolveManagerProcess name) (const (pure ())) readWord32
    unless (pid > 0 && pid <= 2147483647) (throwE BusManagerIdentityRefused)
    pure pid
  readBoot = do
    bytes <- readDomainFile "/proc/sys/kernel/random/boot_id" 64
    pure (ByteChars.unpack (case ByteChars.unsnoc bytes of Just (prefix, '\n') -> prefix; _ -> bytes))
  readProcess pid = do
    bytes <- readDomainFile ("/proc/" <> show pid <> "/stat") 8192
    text <- either (const (throwE BusManagerIdentityRefused)) pure (Encoding.decodeUtf8' bytes)
    status <- maybe (throwE BusManagerIdentityRefused) pure (parseProcessStat text)
    unless
      ( toInteger (statPid status) == toInteger pid
          && statStart status > 0
          && statStart status < toInteger (maxBound :: Word64)
          && statState status `notElem` map Text.pack ["Z", "X"]
      )
      (throwE BusManagerIdentityRefused)
    pure status
  readDomainFile path maximumBytes = do
    _ <- remaining BusDecode (systemdBusDeadline connection)
    attempted <-
      lift $
        tryIO $
          bracket
            ( Posix.openFd
                path
                Posix.ReadOnly
                Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
            )
            Posix.closeFd
            (\fd -> NativeIO.fdRead fd (fromIntegral maximumBytes + 1))
    bytes <- either (const (throwE BusIoRefused)) pure attempted
    unless (Bytes.length bytes <= maximumBytes) (throwE BusManagerIdentityRefused)
    _ <- remaining BusDecode (systemdBusDeadline connection)
    pure bytes

readWord32 :: BusMessage -> BusAction Word32
readWord32 (BusMessage api message deadline) = do
  _ <- remaining BusDecode deadline
  value <- lift $ alloca $ \output -> do
    poke output 0
    status <- readBasic api message (code 'u') (castPtr output)
    if status <= 0 then pure Nothing else Just <$> peek output
  maybe (throwE BusMalformedReply) pure value
