{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Source-reviewed native processing contract. Recorded bindings are data;
-- only this scoped interpreter supplies a fresh, descriptor-held observation.
module Prodbox.Subprocess.SystemdProvider
  ( RecordedProviderBinding
  , encodeProviderBinding
  , decodeProviderBinding
  , QualifiedProvider
  , ProviderError (..)
  , ProviderProcess (..)
  , withQualifiedProvider
  , verifyQualifiedProvider
  , verifyQualifiedProviderBefore
  , qualifiedProviderBinding
  , qualifiedProviderDomain
  ) where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (IOException, finally, mask, try, uninterruptibleMask_)
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Chars
import Data.ByteString.Lazy qualified as Lazy
import Data.List (isSuffixOf)
import Data.Text.Encoding qualified as Text
import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CUInt (..), CULong (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Numeric (readHex)
import Prodbox.Subprocess.OwnedProcessTree (ProcessStat (..), parseProcessStat)
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProviderProfile
import System.FilePath (splitDirectories)
import System.IO.Error (isDoesNotExistError, isEOFError)
import System.Info qualified as Info
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileGroup
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , getFileStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , modificationTimeHiRes
  , readSymbolicLink
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as Native
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd)
import System.Posix.User (getEffectiveUserID)
import Text.Read (readMaybe)

foreign import capi "sys/sysmacros.h major" nativeMajor :: CULong -> IO CUInt
foreign import capi "sys/sysmacros.h minor" nativeMinor :: CULong -> IO CUInt

data ProviderProcess = ProviderCaller | ProviderManager | ProviderRouter
  deriving stock (Eq, Show)

data ProviderError
  = ProviderExpired
  | ProviderLeaseClosed
  | ProviderPlatformUnsupported
  | ProviderBindingMalformed
  | ProviderDomainChanged
  | ProviderProcessRefused !ProviderProcess
  | ProviderSecurityModeRefused
  | ProviderImageUnsafe !ProviderImage
  | ProviderImageChanged !ProviderImage
  | ProviderImageMismatch !ProviderImage
  | ProviderMappingRefused !ProviderImage
  | ProviderBusRefused !Bus.BusError
  | ProviderIoRefused !IOErrorType !(Maybe Int)
  deriving stock (Eq, Show)

-- No Show or record selectors. Decoding never supplies a native observation.
data RecordedProviderBinding
  = RecordedProviderBinding !ByteString !Word32 !Word64 !Word32 !Word64 !Word64
  deriving stock (Eq)

data BindingWire = BindingWire !Word8 !ByteString !Word32 !Word64 !Word32 !Word64 !Word64
  deriving stock (Generic)
  deriving anyclass (Serialise)

encodeProviderBinding :: RecordedProviderBinding -> ByteString
encodeProviderBinding (RecordedProviderBinding reference pid ticks uid dev ino) =
  "prodbox-native-provider-binding/v1\NUL"
    <> Lazy.toStrict (serialise (BindingWire 1 reference pid ticks uid dev ino))

decodeProviderBinding :: ByteString -> Either ProviderError RecordedProviderBinding
decodeProviderBinding bytes = do
  unless (BS.length bytes <= 1024) (Left ProviderBindingMalformed)
  payload <-
    maybe
      (Left ProviderBindingMalformed)
      Right
      (BS.stripPrefix "prodbox-native-provider-binding/v1\NUL" bytes)
  wire <-
    either (const (Left ProviderBindingMalformed)) Right (deserialiseOrFail (Lazy.fromStrict payload))
  case wire of
    BindingWire version reference pid ticks uid dev ino -> do
      unless
        ( version == 1
            && BS.length reference == 32
            && pid > 0
            && pid <= 2147483647
            && ticks > 0
            && ticks < maxBound
            && uid > 0
            && ino > 0
        )
        (Left ProviderBindingMalformed)
      let binding = RecordedProviderBinding reference pid ticks uid dev ino
      unless (encodeProviderBinding binding == bytes) (Left ProviderBindingMalformed)
      pure binding

data NativeContext = NativeContext !Identity.HostManagerDomain !RecordedProviderBinding
  deriving stock (Eq)

data ImageLease = ImageLease !ProviderImage !FilePath !Fd !FileStatus !(Word32, Word32)

data QualifiedProvider
  = QualifiedProvider !Bus.BusConnection !ProviderProfile !NativeContext ![ImageLease] !(MVar Bool)

qualifiedProviderBinding :: QualifiedProvider -> RecordedProviderBinding
qualifiedProviderBinding (QualifiedProvider _ _ (NativeContext _ binding) _ _) = binding

qualifiedProviderDomain :: QualifiedProvider -> Identity.HostManagerDomain
qualifiedProviderDomain (QualifiedProvider _ _ (NativeContext domain _) _ _) = domain

withQualifiedProvider
  :: Bus.BusConnection -> (QualifiedProvider -> IO value) -> IO (Either ProviderError value)
withQualifiedProvider connection action = do
  case selectProviderProfile Info.os Info.arch of
    Nothing -> pure (Left ProviderPlatformUnsupported)
    Just profile -> do
      observed <- runExceptT (readContext connection profile)
      case observed of
        Left cause -> pure (Left cause)
        Right context -> withImages profile (Bus.systemdBusDeadline connection) $ \images -> do
          live <- newMVar True
          let provider = QualifiedProvider connection profile context images live
          ( do
              confirmed <- verifyQualifiedProvider provider
              case confirmed of
                Left cause -> pure (Left cause)
                Right () -> Right <$> action provider
            )
            `finally` uninterruptibleMask_ (modifyMVar_ live (const (pure False)))

verifyQualifiedProvider :: QualifiedProvider -> IO (Either ProviderError ())
verifyQualifiedProvider = verifyQualifiedProviderBefore maxBound

verifyQualifiedProviderBefore :: Word64 -> QualifiedProvider -> IO (Either ProviderError ())
verifyQualifiedProviderBefore earlier (QualifiedProvider original profile expected images active) = withMVar active $ \live ->
  if not live
    then pure (Left ProviderLeaseClosed)
    else runExceptT $ do
      checkTime (Bus.systemdBusDeadline connection)
      current <- readContext connection profile
      unless (current == expected) (throwE ProviderDomainChanged)
      mapM_ (verifyImage connection current) images
      closing <- readContext connection profile
      unless (closing == expected) (throwE ProviderDomainChanged)
      checkTime (Bus.systemdBusDeadline connection)
 where
  connection = Bus.systemdBusWithin earlier original

withImages
  :: ProviderProfile
  -> Word64
  -> ([ImageLease] -> IO (Either ProviderError value))
  -> IO (Either ProviderError value)
withImages profile ending action = collect [minBound .. maxBound] []
 where
  collect [] images = action (reverse images)
  collect (role : rest) images = withImage profile ending role (\image -> collect rest (image : images))

safeFlags :: Posix.OpenFileFlags
safeFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

withDescriptor
  :: IO Fd -> (Fd -> IO (Either ProviderError value)) -> IO (Either ProviderError value)
withDescriptor acquire action = mask $ \restore -> do
  opened <- ownIO acquire
  case opened of
    Left cause -> pure (Left cause)
    Right fd -> restore (action fd) `finally` Posix.closeFd fd

withImage
  :: ProviderProfile
  -> Word64
  -> ProviderImage
  -> (ImageLease -> IO (Either ProviderError value))
  -> IO (Either ProviderError value)
withImage profile ending role action =
  withDescriptor (Posix.openFd "/" Posix.ReadOnly safeFlags {Posix.directory = True}) $ \root ->
    descend root (drop 1 (splitDirectories path))
 where
  (path, expectedHash) = providerImagePin profile role
  descend _ [] = pure (Left (ProviderImageUnsafe role))
  descend parent [leaf] = do
    trusted <- checkParent parent
    case trusted of
      Left cause -> pure (Left cause)
      Right () -> withDescriptor (Posix.openFdAt (Just parent) leaf Posix.ReadOnly safeFlags) $ \fd -> do
        verified <- runExceptT $ do
          checkTime ending
          status <- ExceptT (ownIO (getFdStatus fd))
          unless
            ( isRegularFile status
                && fileOwner status == 0
                && fileMode status .&. 0o022 == 0
                && fileSize status > 0
                && fileSize status <= 16777216
            )
            (throwE (ProviderImageUnsafe role))
          digest <- hashImage ending fd
          unless (hex digest == expectedHash) (throwE (ProviderImageMismatch role))
          closing <- ExceptT (ownIO (getFdStatus fd))
          linked <- ExceptT (ownIO (getSymbolicLinkStatus path))
          unless (sameFile status closing && sameFile status linked) (throwE (ProviderImageChanged role))
          major <- lift (nativeMajor (fromIntegral (deviceID status)))
          minor <- lift (nativeMinor (fromIntegral (deviceID status)))
          pure (ImageLease role path fd status (fromIntegral major, fromIntegral minor))
        either (pure . Left) action verified
  descend parent (part : rest) = do
    checked <- checkParent parent
    case checked of
      Left cause -> pure (Left cause)
      Right () -> withDescriptor (Posix.openFdAt (Just parent) part Posix.ReadOnly safeFlags {Posix.directory = True}) $ \next -> descend next rest
  checkParent parent = runExceptT $ do
    checkTime ending
    status <- ExceptT (ownIO (getFdStatus parent))
    unless
      (isDirectory status && fileOwner status == 0 && fileMode status .&. 0o022 == 0)
      (throwE (ProviderImageUnsafe role))

sameFile :: FileStatus -> FileStatus -> Bool
sameFile a b =
  and
    [ deviceID a == deviceID b
    , fileID a == fileID b
    , fileSize a == fileSize b
    , fileMode a == fileMode b
    , fileOwner a == fileOwner b
    , fileGroup a == fileGroup b
    , modificationTimeHiRes a == modificationTimeHiRes b
    , statusChangeTimeHiRes a == statusChangeTimeHiRes b
    ]

hashImage :: Word64 -> Fd -> ExceptT ProviderError IO ByteString
hashImage ending fd = loop SHA256.init 0
 where
  loop !state !total = do
    checkTime ending
    bytes <- ExceptT (readChunk fd 65536)
    let next = total + BS.length bytes
    when (next > 16777216) (throwE ProviderBindingMalformed)
    if BS.null bytes then pure (SHA256.finalize state) else loop (SHA256.update state bytes) next

hex :: ByteString -> ByteString
hex =
  Chars.pack
    . concatMap
      ( \byte ->
          [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
          , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
          ]
      )
    . BS.unpack

readChunk :: Fd -> Int -> IO (Either ProviderError ByteString)
readChunk fd maximumBytes = do
  value <- try (Native.fdRead fd (fromIntegral maximumBytes))
  pure $ case value of
    Left (cause :: IOException) | isEOFError cause -> Right BS.empty
    Left cause -> Left (ioRefusal cause)
    Right bytes -> Right bytes

readBounded :: Word64 -> FilePath -> Int -> ExceptT ProviderError IO ByteString
readBounded ending path maximumBytes = ExceptT $
  withDescriptor (Posix.openFd path Posix.ReadOnly safeFlags) $
    \fd -> runExceptT (loop fd [] 0)
 where
  loop fd chunks total = do
    checkTime ending
    bytes <- ExceptT (readChunk fd (min 8192 (maximumBytes + 1 - total)))
    let next = total + BS.length bytes
    when (next > maximumBytes) (throwE ProviderBindingMalformed)
    if BS.null bytes then pure (BS.concat (reverse chunks)) else loop fd (bytes : chunks) next

readContext :: Bus.BusConnection -> ProviderProfile -> ExceptT ProviderError IO NativeContext
readContext connection profile = do
  let ending = Bus.systemdBusDeadline connection
  checkTime ending
  domain <- bus (Bus.observeManagerDomain connection)
  (routerPid, routerUid) <- bus (Bus.observeBusRouter connection)
  uid <- lift getEffectiveUserID
  callerPid <- lift getProcessID
  unless
    ( uid > 0
        && toInteger uid == toInteger (Identity.hostManagerUserId domain)
        && toInteger uid == toInteger routerUid
    )
    (throwE (ProviderProcessRefused ProviderCaller))
  _ <- processFacts ending ProviderCaller (fromIntegral uid) (fromIntegral callerPid)
  managerStart <-
    processFacts ending ProviderManager (fromIntegral uid) (Identity.hostManagerProcessId domain)
  routerStart <- processFacts ending ProviderRouter (fromIntegral uid) routerPid
  unless (managerStart == Identity.hostManagerStartTicks domain) (throwE ProviderDomainChanged)
  callerNamespace <- namespace (fromIntegral callerPid)
  managerNamespace <- namespace (Identity.hostManagerProcessId domain)
  routerNamespace <- namespace routerPid
  unless
    (callerNamespace == managerNamespace && callerNamespace == routerNamespace)
    (throwE ProviderSecurityModeRefused)
  selinux <- lift (try (getSymbolicLinkStatus "/sys/fs/selinux/enforce"))
  case selinux of
    Left (cause :: IOException) | isDoesNotExistError cause -> pure ()
    Left cause -> throwE (ioRefusal cause)
    Right _ -> throwE ProviderSecurityModeRefused
  closing <- bus (Bus.observeManagerDomain connection)
  closingRouter <- bus (Bus.observeBusRouter connection)
  unless (closing == domain && closingRouter == (routerPid, routerUid)) (throwE ProviderDomainChanged)
  closingManagerStart <- processStart ending ProviderManager (Identity.hostManagerProcessId domain)
  closingRouterStart <- processStart ending ProviderRouter routerPid
  unless
    (closingManagerStart == managerStart && closingRouterStart == routerStart)
    (throwE ProviderDomainChanged)
  let (dev, ino) = callerNamespace
  checkTime ending
  pure
    ( NativeContext
        domain
        ( RecordedProviderBinding
            (providerContractReference profile)
            routerPid
            routerStart
            (fromIntegral uid)
            dev
            ino
        )
    )
 where
  bus = ExceptT . fmap (either (Left . ProviderBusRefused) Right) . runExceptT
  namespace :: Word32 -> ExceptT ProviderError IO (Word64, Word64)
  namespace pid = do
    status <- ExceptT (ownIO (getFileStatus ("/proc/" <> show pid <> "/ns/mnt")))
    pure (fromIntegral (deviceID status), fromIntegral (fileID status))

processFacts :: Word64 -> ProviderProcess -> Word32 -> Word32 -> ExceptT ProviderError IO Word64
processFacts ending role expectedUid pid = do
  started <- processStart ending role pid
  status <- readBounded ending ("/proc/" <> show pid <> "/status") 65536
  let entries = Chars.lines status
      field name = case [Chars.words rest | line <- entries, Just rest <- [BS.stripPrefix (name <> "\t") line]] of
        [value] -> Just value
        _ -> Nothing
      user = field "Uid:"
      zeroCapabilities name = case field name of
        Just [value] -> BS.length value == 16 && Chars.all (== '0') value
        _ -> False
  unless
    ( user == Just (replicate 4 (Chars.pack (show expectedUid)))
        && all zeroCapabilities ["CapPrm:", "CapEff:", "CapAmb:"]
    )
    (throwE (ProviderProcessRefused role))
  label <- readBounded ending ("/proc/" <> show pid <> "/attr/current") 4096
  unless (label == "unconfined\n" || label == "unconfined") (throwE ProviderSecurityModeRefused)
  pure started

processStart :: Word64 -> ProviderProcess -> Word32 -> ExceptT ProviderError IO Word64
processStart ending role pid = do
  bytes <- readBounded ending ("/proc/" <> show pid <> "/stat") 8192
  text <- either (const (throwE (ProviderProcessRefused role))) pure (Text.decodeUtf8' bytes)
  status <- maybe (throwE (ProviderProcessRefused role)) pure (parseProcessStat text)
  unless
    ( toInteger (statPid status) == toInteger pid
        && statStart status > 0
        && statStart status < toInteger (maxBound :: Word64)
        && statState status `notElem` ["Z", "X"]
    )
    (throwE (ProviderProcessRefused role))
  pure (fromInteger (statStart status))

verifyImage :: Bus.BusConnection -> NativeContext -> ImageLease -> ExceptT ProviderError IO ()
verifyImage connection (NativeContext domain (RecordedProviderBinding _ routerPid _ _ _ _)) (ImageLease role path fd expected device) = do
  let ending = Bus.systemdBusDeadline connection
      pid = case role of
        ManagerExecutable -> Identity.hostManagerProcessId domain
        ManagerCore -> Identity.hostManagerProcessId domain
        ManagerBus -> Identity.hostManagerProcessId domain
        RouterExecutable -> routerPid
        RouterBus -> routerPid
  checkTime ending
  held <- ExceptT (ownIO (getFdStatus fd))
  linked <- ExceptT (ownIO (getSymbolicLinkStatus path))
  unless (sameFile expected held && sameFile expected linked) (throwE (ProviderImageChanged role))
  maps <- readBounded ending ("/proc/" <> show pid <> "/maps") 262144
  let matching line = case words (Chars.unpack line) of
        (_ : permissions : _ : dev : ino : rest) ->
          permissions == "r-xp"
            && unwords rest == path
            && parsedDevice dev == Just device
            && readMaybe ino == Just (toInteger (fileID expected))
        _ -> False
  unless (any matching (Chars.lines maps)) (throwE (ProviderMappingRefused role))
  when (role == ManagerExecutable || role == RouterExecutable) $ do
    actual <- ExceptT (ownIO (readSymbolicLink ("/proc/" <> show pid <> "/exe")))
    unless
      (actual == path && not (" (deleted)" `isSuffixOf` actual))
      (throwE (ProviderMappingRefused role))
  checkTime ending

parsedDevice :: String -> Maybe (Word32, Word32)
parsedDevice text = case break (== ':') text of
  (major, ':' : minor) -> (,) <$> number major <*> number minor
  _ -> Nothing
 where
  number value = case readHex value of
    [(result, "")] | result >= (0 :: Integer) && result <= toInteger (maxBound :: Word32) -> Just (fromInteger result)
    _ -> Nothing

checkTime :: Word64 -> ExceptT ProviderError IO ()
checkTime ending = do
  now <- lift getMonotonicTimeNSec
  when (now >= ending) (throwE ProviderExpired)

ownIO :: IO value -> IO (Either ProviderError value)
ownIO action = do
  result <- try action
  pure (either (Left . ioRefusal) Right result)

ioRefusal :: IOException -> ProviderError
ioRefusal cause = ProviderIoRefused (ioe_type cause) (fromIntegral <$> ioe_errno cause)
