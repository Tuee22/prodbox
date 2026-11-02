{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE InterruptibleFFI #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Local capacity reads before an operation may admit its first child.
module Prodbox.Capacity.NativeHostProbe
  ( NativeHostProbeStage (..)
  , NativeHostProbeError (..)
  , observeNativeHostCapacityBefore
  , parseNativeHostMemoryMib
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bits (popCount)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Data.Text qualified as Text
import Data.Word (Word64, Word8)
import Foreign.C.Error (Errno (..), getErrno)
import Foreign.C.Types (CInt (..), CSize (..), CULong (..))
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (peekElemOff, sizeOf)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config (ResourceVector (..))
import Prodbox.Capacity.ObservedHost
  ( ObservedHostRoot
  , StorageDeviceId
  , mkObservedHostRoot
  , mkStorageDeviceId
  )
import System.Environment (lookupEnv)
import System.FilePath (isAbsolute, normalise, splitDirectories)
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Info (arch, os)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  )
import System.Posix.IO qualified as Posix
import System.Posix.Process (getProcessID)
import System.Posix.Types (CPid (..), Fd (..))
import System.Timeout (timeout)

data NativeHostProbeStage = ProbeCpu | ProbeMemory | ProbeEphemeral | ProbeRetained
  deriving (Eq, Show)

data NativeHostProbeError
  = NativeHostProbeExpired
  | NativeHostProbeOverrideRefused
  | NativeHostProbeUnsupportedAbi
  | NativeHostProbeRootInvalid
  | NativeHostProbeIoRefused !NativeHostProbeStage !IOErrorType !(Maybe Int)
  | NativeHostProbeSyscallRefused !NativeHostProbeStage !Int
  | NativeHostProbeMetadataInvalid !NativeHostProbeStage
  | NativeHostProbeRootChanged !NativeHostProbeStage
  | NativeHostProbeGeometryChanged !NativeHostProbeStage
  | NativeHostProbeCapacityInvalid
  deriving (Eq, Show)

foreign import ccall unsafe "sched_getaffinity"
  nativeAffinity :: CPid -> CSize -> Ptr Word8 -> IO CInt
foreign import capi interruptible "sys/statvfs.h fstatvfs"
  nativeFilesystem :: CInt -> Ptr () -> IO CInt

type Probe = ExceptT NativeHostProbeError IO

observeNativeHostCapacityBefore
  :: Word64 -> FilePath -> IO (Either NativeHostProbeError ObservedHostRoot)
observeNativeHostCapacityBefore ending retainedRoot
  | not supportedAbi = pure (Left NativeHostProbeUnsupportedAbi)
  | otherwise = do
      now <- getMonotonicTimeNSec
      if now >= ending || (ending - now) `div` 1000 == 0
        then pure (Left NativeHostProbeExpired)
        else do
          result <- timeout (fromIntegral ((ending - now) `div` 1000)) (runExceptT observe)
          closing <- getMonotonicTimeNSec
          pure $
            if closing >= ending
              then Left NativeHostProbeExpired
              else maybe (Left NativeHostProbeExpired) id result
 where
  observe = do
    check ending
    unless (validRoot retainedRoot) (throwE NativeHostProbeRootInvalid)
    override <- ioAt ProbeCpu (lookupEnv "PRODBOX_TEST_HOST_CAPACITY")
    case override of
      Just _ -> throwE NativeHostProbeOverrideRefused
      Nothing -> pure ()
    cpu <- cpuBefore ending
    memory <- memoryBefore ending
    (ephemeralDevice, ephemeral) <- filesystemBefore ending ProbeEphemeral "/"
    (durableDevice, durable) <- filesystemBefore ending ProbeRetained retainedRoot
    closingCpu <- cpuBefore ending
    closingMemory <- memoryBefore ending
    unless (cpu == closingCpu) (throwE (NativeHostProbeGeometryChanged ProbeCpu))
    unless (memory == closingMemory) (throwE (NativeHostProbeGeometryChanged ProbeMemory))
    check ending
    either
      (const (throwE NativeHostProbeCapacityInvalid))
      pure
      (mkObservedHostRoot (ResourceVector cpu memory ephemeral durable) ephemeralDevice durableDevice)

supportedAbi :: Bool
supportedAbi =
  os == "linux"
    && arch `elem` ["x86_64", "aarch64"]
    && sizeOf (0 :: CULong) == 8
    && sizeOf (0 :: CSize) == 8
    && sizeOf (0 :: CInt) == 4

validRoot :: FilePath -> Bool
validRoot root =
  length (take 4097 root) <= 4096
    && '\0' `notElem` root
    && isAbsolute root
    && normalise root == root
    && ".." `notElem` splitDirectories root

check :: Word64 -> Probe ()
check ending = do
  now <- lift getMonotonicTimeNSec
  when (now >= ending) (throwE NativeHostProbeExpired)

ioAt :: NativeHostProbeStage -> IO value -> Probe value
ioAt stage action = do
  result <- lift (try action)
  case result of
    Left (err :: IOException) -> throwE (NativeHostProbeIoRefused stage (ioe_type err) (fromIntegral <$> ioe_errno err))
    Right value -> pure value

cpuBefore :: Word64 -> Probe Natural
cpuBefore ending = do
  check ending
  result <- ioAt ProbeCpu $ allocaArray affinityBytes $ \buffer -> do
    fillBytes buffer 0 affinityBytes
    process <- getProcessID
    code <- nativeAffinity process (fromIntegral affinityBytes) buffer
    if code /= 0
      then Left . NativeHostProbeSyscallRefused ProbeCpu <$> errnoValue
      else do
        bytes <- peekArray affinityBytes buffer
        let count = sum (map (fromIntegral . popCount) bytes) :: Natural
        pure $ if count == 0 then Left (NativeHostProbeMetadataInvalid ProbeCpu) else Right (count * 1000)
  check ending
  either throwE pure result
 where
  affinityBytes = 16384

memoryBefore :: Word64 -> Probe Natural
memoryBefore ending = do
  check ending
  bytes <-
    ioAt ProbeMemory (withBinaryFile "/proc/meminfo" ReadMode (\handle -> BS.hGet handle 65537))
  when (BS.length bytes > 65536) (throwE (NativeHostProbeMetadataInvalid ProbeMemory))
  result <- either throwE pure (parseNativeHostMemoryMib bytes)
  check ending
  pure result

parseNativeHostMemoryMib :: ByteString -> Either NativeHostProbeError Natural
parseNativeHostMemoryMib bytes
  | BS.length bytes > 65536 = Left (NativeHostProbeMetadataInvalid ProbeMemory)
  | otherwise = case filter (BS.isPrefixOf "MemTotal:") (Bytes.lines bytes) of
      [line] -> case Bytes.words line of
        ["MemTotal:", digits, "kB"]
          | not (BS.null digits) && BS.length digits <= 20 && BS.all (\byte -> byte >= 48 && byte <= 57) digits ->
              let kib = BS.foldl' (\value byte -> value * 10 + fromIntegral (byte - 48)) 0 digits :: Natural
                  mib = kib `div` 1024
               in if kib <= fromIntegral (maxBound :: Word64) && mib > 0 then Right mib else invalid
        _ -> invalid
      _ -> invalid
 where
  invalid = Left (NativeHostProbeMetadataInvalid ProbeMemory)

filesystemBefore :: Word64 -> NativeHostProbeStage -> FilePath -> Probe (StorageDeviceId, Natural)
filesystemBefore ending stage path = do
  check ending
  result <-
    ioAt stage $
      bracket
        ( Posix.openFd
            path
            Posix.ReadOnly
            ( Posix.defaultFileFlags
                { Posix.directory = True
                , Posix.nofollow = True
                , Posix.cloexec = True
                , Posix.nonBlock = True
                }
            )
        )
        Posix.closeFd
        ( \fd -> runExceptT $ do
            check ending
            initial <- ioAt stage (getFdStatus fd)
            unless (isDirectory initial) (throwE (NativeHostProbeMetadataInvalid stage))
            capacity <- ExceptT (filesystemCapacity stage fd)
            check ending
            closingCapacity <- ExceptT (filesystemCapacity stage fd)
            unless (capacity == closingCapacity) (throwE (NativeHostProbeGeometryChanged stage))
            check ending
            closing <- ioAt stage (getFdStatus fd)
            linked <- ioAt stage (getSymbolicLinkStatus path)
            unless
              (sameDirectory initial closing && sameDirectory initial linked)
              (throwE (NativeHostProbeRootChanged stage))
            check ending
            device <-
              maybe
                (throwE (NativeHostProbeMetadataInvalid stage))
                pure
                (mkStorageDeviceId (Text.pack ("native-device-v1:" ++ show (toInteger (deviceID initial)))))
            pure (device, capacity)
        )
  either throwE pure result

sameDirectory :: FileStatus -> FileStatus -> Bool
sameDirectory initial other = isDirectory other && deviceID initial == deviceID other && fileID initial == fileID other

filesystemCapacity :: NativeHostProbeStage -> Fd -> IO (Either NativeHostProbeError Natural)
filesystemCapacity stage (Fd descriptor) = allocaArray 32 $ \(buffer :: Ptr CULong) -> do
  -- The supported Linux LP64 statvfs prefix is three unsigned 64-bit words.
  -- Its current 112-byte layout fits the 128-byte ABI area. The separate tail
  -- detects an incompatible expansion before any capacity is admitted.
  fillBytes buffer 0 128
  fillBytes (buffer `plusPtr` 128) 165 128
  code <- nativeFilesystem descriptor (castPtr buffer)
  if code /= 0
    then Left . NativeHostProbeSyscallRefused stage <$> errnoValue
    else do
      tailBytes <- BS.packCStringLen (castPtr (buffer `plusPtr` 128), 128)
      fragment <- peekElemOff buffer 1
      blocks <- peekElemOff buffer 2
      let mib = (fromIntegral fragment * fromIntegral blocks) `div` 1048576 :: Natural
      pure $
        if not (BS.all (== 165) tailBytes)
          then Left NativeHostProbeUnsupportedAbi
          else
            if fragment == 0 || blocks == 0 || mib == 0
              then Left (NativeHostProbeMetadataInvalid stage)
              else Right mib

errnoValue :: IO Int
errnoValue = do
  Errno value <- getErrno
  pure (fromIntegral value)
