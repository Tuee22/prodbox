{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded, sealed snapshots for an already selected executable. A matching
-- digest identifies bytes only; it does not grant permission to execute them.
module Prodbox.Control.SealedTool
  ( SealedToolError (..)
  , SealedToolBudget
  , SealedToolBudgetError (..)
  , planSealedToolBudget
  , planSealedClientBudget
  , planSealedMutationTestBudget
  , planSealedToolBudgetWithInput
  , KindWorkerSnapshots
  , planKindWorkerSnapshots
  , kindWorkerKindBudget
  , kindWorkerClientBudget
  , sealedToolRuntimePlan
  , sealedToolKernelCharge
  , sealedToolInputMaximum
  , isSealedToolDescriptor
  , withSealedTool
  , withSealedToolBefore
  )
where

import Control.Exception (IOException, bracket, throwIO, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as ByteString
import Data.Word (Word64)
import Foreign.C.Error (throwErrnoIfMinus1, throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isEOFError)
import System.Posix.Files (getFdStatus, isRegularFile, setFdMode)
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

foreign import capi "sys/mman.h memfd_create" createMemoryFile :: CString -> CUInt -> IO CInt
foreign import capi "sys/mman.h value MFD_CLOEXEC" memoryCloseOnExec :: CUInt
foreign import capi "sys/mman.h value MFD_ALLOW_SEALING" memoryAllowSealing :: CUInt
foreign import capi "fcntl.h fcntl" memoryControl :: CInt -> CInt -> CInt -> IO CInt
foreign import capi "fcntl.h value F_ADD_SEALS" addSeals :: CInt
foreign import capi "fcntl.h value F_GET_SEALS" getSeals :: CInt
foreign import capi "fcntl.h value F_SEAL_SEAL" sealSeal :: CInt
foreign import capi "fcntl.h value F_SEAL_SHRINK" sealShrink :: CInt
foreign import capi "fcntl.h value F_SEAL_GROW" sealGrow :: CInt
foreign import capi "fcntl.h value F_SEAL_WRITE" sealWrite :: CInt

data SealedToolError
  = SealedToolInvalidDeclaration
  | SealedToolTooLarge
  | SealedToolDigestMismatch
  | SealedToolTimedOut
  | SealedToolUnobservable
  deriving (Eq, Show)

data SealedToolBudgetError
  = SealedToolBudgetInvalid
  | SealedToolBudgetRuntime !RuntimeMemory.RuntimeMemoryError
  deriving (Eq, Show)

data SealedToolBudget = SealedToolBudget !Integer !Natural !RuntimeMemory.RuntimeMemoryPlan !(Maybe Int)
  deriving (Eq, Show)

data KindWorkerSnapshots = KindWorkerSnapshots !SealedToolBudget !SealedToolBudget
  deriving (Eq, Show)

kindWorkerKindBudget :: KindWorkerSnapshots -> SealedToolBudget
kindWorkerKindBudget (KindWorkerSnapshots budget _) = budget

kindWorkerClientBudget :: KindWorkerSnapshots -> SealedToolBudget
kindWorkerClientBudget (KindWorkerSnapshots _ budget) = budget

-- | Reserve the declared maximum rounded to 2 MiB plus declared kernel
-- overhead, and separately reserve copy/hash heap scratch. The returned plan
-- must still be placed, enforced and measured; this pure value is not a
-- physical reservation or a concurrency permit.
planSealedToolBudget
  :: RuntimeMemory.RuntimeMemoryPlan
  -> Integer
  -> Natural
  -> Either SealedToolBudgetError SealedToolBudget
planSealedToolBudget = planSnapshotBudget (128 * 1024 * 1024)

-- | Fund the larger operator client snapshot used by the kind bridge. This
-- does not reserve physical memory, authorize the executable, or fund other
-- simultaneous workers. The normal tool limit remains unchanged.
planSealedClientBudget
  :: RuntimeMemory.RuntimeMemoryPlan
  -> Integer
  -> Natural
  -> Either SealedToolBudgetError SealedToolBudget
planSealedClientBudget = planSnapshotBudget (256 * 1024 * 1024)

-- | Fund a larger mutation-test executable snapshot. The exact requested
-- maximum is charged to the runtime plan; the caller still needs physical
-- placement, dependency authentication, measured capacity and execution
-- admission. Other sealed-tool limits are unchanged.
planSealedMutationTestBudget
  :: RuntimeMemory.RuntimeMemoryPlan
  -> Integer
  -> Natural
  -> Either SealedToolBudgetError SealedToolBudget
planSealedMutationTestBudget = planSnapshotBudget (512 * 1024 * 1024)

planSnapshotBudget
  :: Integer
  -> RuntimeMemory.RuntimeMemoryPlan
  -> Integer
  -> Natural
  -> Either SealedToolBudgetError SealedToolBudget
planSnapshotBudget limit runtime maximumBytes kernelOverhead
  | maximumBytes <= 0 || maximumBytes > limit || kernelOverhead == 0 =
      Left SealedToolBudgetInvalid
  | otherwise = do
      let alignment = 2 * 1024 * 1024
          rounded = ((fromInteger maximumBytes + alignment - 1) `div` alignment) * alignment
          kernelCharge = rounded + kernelOverhead
          heapScratch = 2 * 65536 + 32768
      planned <-
        either
          (Left . SealedToolBudgetRuntime)
          Right
          (RuntimeMemory.reserveRuntimeMemory heapScratch kernelCharge runtime)
      pure (SealedToolBudget maximumBytes kernelCharge planned Nothing)

-- | Fund a bounded input alongside the sealed executable before deriving the
-- placement plan. Two copies of the maximum input are reserved on the heap;
-- the caller supplies a separate positive kernel transport estimate. These
-- declared charges still need physical placement and measured validation.
planSealedToolBudgetWithInput
  :: RuntimeMemory.RuntimeMemoryPlan
  -> Integer
  -> Natural
  -> Int
  -> Natural
  -> Either SealedToolBudgetError SealedToolBudget
planSealedToolBudgetWithInput runtime maximumBytes kernelOverhead inputMaximum inputKernelReserve
  | inputMaximum <= 0 || inputMaximum > 65536 || inputKernelReserve == 0 =
      Left SealedToolBudgetInvalid
  | otherwise = do
      funded <-
        either
          (Left . SealedToolBudgetRuntime)
          Right
          (RuntimeMemory.reserveRuntimeMemory (2 * fromIntegral inputMaximum) inputKernelReserve runtime)
      SealedToolBudget toolMaximum charge planned _ <-
        planSealedToolBudget funded maximumBytes kernelOverhead
      pure (SealedToolBudget toolMaximum charge planned (Just inputMaximum))

-- | Fund both snapshots and the bounded kind input against one runtime plan.
-- Each returned budget carries the same combined plan, so either snapshot can
-- be prepared inside a placement checked against the whole declared charge.
-- The plan is not a physical reservation or a permit for concurrent workers.
planKindWorkerSnapshots
  :: RuntimeMemory.RuntimeMemoryPlan
  -> Integer
  -> Natural
  -> Integer
  -> Natural
  -> Int
  -> Natural
  -> Either SealedToolBudgetError KindWorkerSnapshots
planKindWorkerSnapshots runtime kindMaximum kindOverhead clientMaximum clientOverhead inputMaximum inputKernelReserve = do
  SealedToolBudget kindLimit kindCharge kindPlan inputLimit <-
    planSealedToolBudgetWithInput runtime kindMaximum kindOverhead inputMaximum inputKernelReserve
  SealedToolBudget clientLimit clientCharge combined _ <-
    planSealedClientBudget kindPlan clientMaximum clientOverhead
  pure
    ( KindWorkerSnapshots
        (SealedToolBudget kindLimit kindCharge combined inputLimit)
        (SealedToolBudget clientLimit clientCharge combined Nothing)
    )

sealedToolRuntimePlan :: SealedToolBudget -> RuntimeMemory.RuntimeMemoryPlan
sealedToolRuntimePlan (SealedToolBudget _ _ plan _) = plan

sealedToolKernelCharge :: SealedToolBudget -> Natural
sealedToolKernelCharge (SealedToolBudget _ charge _ _) = charge

sealedToolInputMaximum :: SealedToolBudget -> Maybe Int
sealedToolInputMaximum (SealedToolBudget _ _ _ maximumInput) = maximumInput

-- | Observe the descriptor's current seals; this checks neither its digest nor
-- its authority. Callers must hold the descriptor and exclude replacement.
isSealedToolDescriptor :: Fd -> IO Bool
isSealedToolDescriptor descriptor@(Fd raw)
  | raw < 3 = pure False
  | otherwise = do
      observed <- try $ do
        status <- getFdStatus descriptor
        actual <- throwErrnoIfMinus1 "F_GET_SEALS" (memoryControl raw getSeals 0)
        let required = sealSeal .|. sealShrink .|. sealGrow .|. sealWrite
        pure (isRegularFile status && actual .&. required == required)
      pure $ case observed of
        Right valid -> valid
        Left (_ :: IOException) -> False

-- | Copy at most the funded bound, seal the snapshot against writes and size
-- changes, then hash the sealed bytes before giving the descriptor to the callback.
-- The callback's I/O exceptions propagate after the descriptor is closed.
withSealedTool
  :: forall value
   . SealedToolBudget
  -> Fd
  -> String
  -> Integer
  -> (Fd -> IO value)
  -> IO (Either SealedToolError value)
withSealedTool = withSealedToolUntil Nothing

-- | Bound only snapshot preparation by the original monotonic deadline.
-- The callback retains its own execution and settlement obligations.
withSealedToolBefore
  :: Word64
  -> SealedToolBudget
  -> Fd
  -> String
  -> Integer
  -> (Fd -> IO value)
  -> IO (Either SealedToolError value)
withSealedToolBefore ending = withSealedToolUntil (Just ending)

withSealedToolUntil
  :: forall value
   . Maybe Word64
  -> SealedToolBudget
  -> Fd
  -> String
  -> Integer
  -> (Fd -> IO value)
  -> IO (Either SealedToolError value)
withSealedToolUntil ending (SealedToolBudget plannedMaximum _ _ _) source expected maximumBytes action
  | not (validDigest expected) || maximumBytes <= 0 || maximumBytes > plannedMaximum =
      pure (Left SealedToolInvalidDeclaration)
  | otherwise = do
      attempted <- try $ bracket create Posix.closeFd $ \target -> do
        now <- getMonotonicTimeNSec
        let remaining = case ending of
              Nothing -> 60000000
              Just deadline -> fromInteger (min 60000000 (max 0 ((toInteger deadline - toInteger now) `div` 1000)))
        prepared <- if remaining <= 0 then pure Nothing else timeout remaining (prepare target)
        after <- getMonotonicTimeNSec
        case prepared of
          Nothing -> pure (Left SealedToolTimedOut)
          Just (Left failure) -> pure (Left failure)
          Just (Right ()) | maybe False (after >=) ending -> pure (Left SealedToolTimedOut)
          Just (Right ()) -> do
            result <- try (action target) :: IO (Either IOException value)
            pure (Right result)
      case attempted of
        Left (_ :: IOException) -> pure (Left SealedToolUnobservable)
        Right (Left failure) -> pure (Left failure)
        Right (Right (Left failure)) -> throwIO failure
        Right (Right (Right value)) -> pure (Right value)
 where
  create = withCString "prodbox-kind-tool" $ \name ->
    Fd
      <$> throwErrnoIfMinus1 "memfd_create" (createMemoryFile name (memoryCloseOnExec .|. memoryAllowSealing))
  prepare target@(Fd raw) = do
    _ <- Posix.fdSeek source AbsoluteSeek 0
    copied <- copyBytes source target maximumBytes 0
    case copied of
      Left failure -> pure (Left failure)
      Right 0 -> pure (Left SealedToolDigestMismatch)
      Right _ -> do
        setFdMode target 0o500
        let required = sealSeal .|. sealShrink .|. sealGrow .|. sealWrite
        throwErrnoIfMinus1_ "F_ADD_SEALS" (memoryControl raw addSeals required)
        actual <- throwErrnoIfMinus1 "F_GET_SEALS" (memoryControl raw getSeals 0)
        if actual .&. required /= required
          then pure (Left SealedToolUnobservable)
          else do
            _ <- Posix.fdSeek target AbsoluteSeek 0
            digest <- hashBytes target SHA256.init
            pure $ if digest == expected then Right () else Left SealedToolDigestMismatch

copyBytes :: Fd -> Fd -> Integer -> Integer -> IO (Either SealedToolError Integer)
copyBytes source target limit total = do
  bytes <- readChunk source (min 65536 (limit - total + 1))
  if ByteString.null bytes
    then pure (Right total)
    else do
      let next = total + toInteger (ByteString.length bytes)
      if next > limit
        then pure (Left SealedToolTooLarge)
        else writeBytes target bytes >> copyBytes source target limit next

writeBytes :: Fd -> ByteString.ByteString -> IO ()
writeBytes fd bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      count <- PosixBytes.fdWrite fd bytes
      if count <= 0
        then ioError (userError "short sealed-tool write")
        else writeBytes fd (ByteString.drop (fromIntegral count) bytes)

hashBytes :: Fd -> SHA256.Ctx -> IO String
hashBytes fd context = do
  bytes <- readChunk fd 65536
  if ByteString.null bytes
    then pure ("sha256:" ++ concatMap hexByte (ByteString.unpack (SHA256.finalize context)))
    else let next = SHA256.update context bytes in next `seq` hashBytes fd next
 where
  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

readChunk :: Fd -> Integer -> IO ByteString.ByteString
readChunk fd size = do
  result <- try (PosixBytes.fdRead fd (fromIntegral size))
  case result of
    Left (failure :: IOException) | isEOFError failure -> pure ByteString.empty
    Left failure -> throwIO failure
    Right bytes -> pure bytes

validDigest :: String -> Bool
validDigest value = length value == 71 && take 7 value == "sha256:" && all hexadecimal (drop 7 value)
 where
  hexadecimal character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')
