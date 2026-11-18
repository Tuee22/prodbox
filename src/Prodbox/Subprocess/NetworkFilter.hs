{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- | A network syscall restriction for a dedicated mutation worker. This is
-- irreversible and applies to every thread in the calling process. It does
-- not close inherited descriptors, isolate filesystems, settle descendants,
-- or by itself make a process safe to run a mutant.
module Prodbox.Subprocess.NetworkFilter
  ( MutationNetworkFilterError (..)
  , installMutationNetworkFilter
  , installMutationMetadataFilter
  )
where

import Control.Monad (forM_)
import Data.Bits ((.|.))
import Data.Word (Word16, Word32, Word8)
import Foreign.C.Error (Errno (..), getErrno)
import Foreign.C.Types (CInt (..), CLong (..), CUInt (..), CULong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (pokeByteOff, sizeOf)
import System.Info (arch, os)

foreign import capi "sys/prctl.h prctl"
  mutationPrctl :: CInt -> CULong -> CULong -> CULong -> CULong -> IO CInt
foreign import capi "sys/prctl.h value PR_SET_NO_NEW_PRIVS" noNewPrivileges :: CInt
foreign import capi "sys/syscall.h value SYS_seccomp" seccompNumber :: CLong
foreign import ccall unsafe "syscall"
  mutationSeccomp :: CLong -> CUInt -> CUInt -> Ptr () -> IO CLong
foreign import capi "linux/seccomp.h value SECCOMP_SET_MODE_FILTER" setFilterMode :: CUInt
foreign import capi "linux/seccomp.h value SECCOMP_FILTER_FLAG_TSYNC" syncThreads :: CUInt

data MutationNetworkFilterError
  = MutationNetworkUnsupportedHost
  | MutationNetworkNoNewPrivilegesFailed !Int
  | MutationNetworkInstallFailed !Int
  | MutationNetworkThreadSyncFailed !Integer
  deriving (Eq, Show)

data FilterInstruction = FilterInstruction !Word16 !Word8 !Word8 !Word32

-- | Install the closed x86-64 Linux filter in an already isolated dedicated
-- worker before untrusted execution. Call only in a disposable process. Even
-- after success, inherited sockets can still be used through read/write, so a
-- separate descriptor-custody boundary is mandatory before executing mutants.
installMutationNetworkFilter :: IO (Either MutationNetworkFilterError ())
installMutationNetworkFilter = installFilter networkDeniedSyscalls

-- | Deny metadata and mount-namespace operations that Landlock does not
-- mediate. This deliberately also denies chmod inside the workspace; actual
-- build compatibility has not been established. As with the network filter,
-- descriptor custody, root provenance and settlement remain separate duties.
installMutationMetadataFilter :: IO (Either MutationNetworkFilterError ())
installMutationMetadataFilter = installFilter metadataDeniedSyscalls

installFilter :: [Word32] -> IO (Either MutationNetworkFilterError ())
installFilter deniedSyscalls
  | os /= "linux" || arch /= "x86_64" || sizeOf (0 :: CULong) /= 8 =
      pure (Left MutationNetworkUnsupportedHost)
  | otherwise = do
      noNew <- mutationPrctl noNewPrivileges 1 0 0 0
      if noNew /= 0
        then Left . MutationNetworkNoNewPrivilegesFailed <$> errnoNumber
        else withFilter deniedSyscalls $ \program -> do
          result <- mutationSeccomp seccompNumber setFilterMode syncThreads program
          if result == 0
            then pure (Right ())
            else
              if result < 0
                then Left . MutationNetworkInstallFailed <$> errnoNumber
                else pure (Left (MutationNetworkThreadSyncFailed (toInteger result)))

-- BPF loads the audit architecture and syscall number from struct seccomp_data.
-- Other ABIs and x32 syscall numbers are killed, then listed native calls are
-- denied with EPERM. io_uring and cross-process descriptor/memory routes are
-- denied because they can bypass a direct socket-call filter.
withFilter :: [Word32] -> (Ptr () -> IO value) -> IO value
withFilter deniedSyscalls action = allocaBytes (length program * 8) $ \filters ->
  allocaBytes 16 $ \header -> do
    forM_ (zip [0 ..] program) $ \(index, FilterInstruction code yes no value) -> do
      let offset = index * 8
      pokeByteOff filters offset code
      pokeByteOff filters (offset + 2) yes
      pokeByteOff filters (offset + 3) no
      pokeByteOff filters (offset + 4) value
    pokeByteOff header 0 (fromIntegral (length program) :: Word16)
    pokeByteOff header 8 (castPtr filters :: Ptr ())
    action (castPtr header)
 where
  program =
    [ FilterInstruction 0x20 0 0 4
    , FilterInstruction 0x15 1 0 0xc000003e
    , FilterInstruction 0x06 0 0 0x80000000
    , FilterInstruction 0x20 0 0 0
    , FilterInstruction 0x45 0 1 0x40000000
    , FilterInstruction 0x06 0 0 0x80000000
    ]
      ++ concatMap deny deniedSyscalls
      ++ [FilterInstruction 0x06 0 0 0x7fff0000]
  deny number = [FilterInstruction 0x15 0 1 number, FilterInstruction 0x06 0 0 (0x00050000 .|. 1)]
networkDeniedSyscalls :: [Word32]
networkDeniedSyscalls =
  [ 41
  , 42
  , 43
  , 44
  , 45
  , 46
  , 47
  , 48
  , 49
  , 50
  , 51
  , 52
  , 53
  , 54
  , 55
  , 101
  , 288
  , 299
  , 304
  , 307
  , 310
  , 311
  , 321
  , 425
  , 426
  , 427
  , 438
  ]

-- Native x86-64 syscall numbers from the Linux UAPI. Unknown architectures
-- are refused by the installer; alternative ABIs are killed by the filter.
metadataDeniedSyscalls :: [Word32]
metadataDeniedSyscalls =
  [ 90
  , 91
  , 92
  , 93
  , 94
  , 132
  , 133
  , 155
  , 161
  , 165
  , 166
  , 188
  , 189
  , 190
  , 197
  , 198
  , 199
  , 235
  , 259
  , 260
  , 261
  , 268
  , 272
  , 280
  , 303
  , 308
  , 323
  , 428
  , 429
  , 430
  , 431
  , 432
  , 433
  , 442
  , 452
  ]

errnoNumber :: IO Int
errnoNumber = do
  Errno value <- getErrno
  pure (fromIntegral value)
