{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Descriptor preparation for a dedicated mutation worker immediately before
-- exec. This is not a filesystem sandbox, a network boundary, or authorization
-- to execute untrusted code.
module Prodbox.Subprocess.ExecDescriptors
  ( MutationDescriptorError (..)
  , prepareMutationExecDescriptors
  )
where

import Control.Concurrent (isCurrentThreadBound)
import Control.Exception (IOException, try)
import Data.Bits ((.|.))
import Foreign.C.Error (Errno (..), getErrno)
import Foreign.C.Types (CLong (..), CUInt (..))
import System.Info (arch, os)
import System.Posix.Files (getFdStatus, isNamedPipe, isRegularFile)
import System.Posix.Types (Fd (..))

foreign import capi "sys/syscall.h value SYS_close_range" closeRangeNumber :: CLong
foreign import capi "linux/close_range.h value CLOSE_RANGE_UNSHARE" closeRangeUnshare :: CUInt
foreign import capi "linux/close_range.h value CLOSE_RANGE_CLOEXEC" closeRangeCloexec :: CUInt
foreign import ccall unsafe "syscall"
  mutationCloseRange :: CLong -> CUInt -> CUInt -> CUInt -> IO CLong

data MutationDescriptorError
  = MutationDescriptorUnsupportedHost
  | MutationDescriptorThreadUnbound
  | MutationDescriptorCloseRangeFailed !Int
  | MutationDescriptorStandardUnobservable !Int
  | MutationDescriptorStandardUnsafe !Int
  deriving (Eq, Show)

-- | Unshare the calling OS thread's descriptor table and set close-on-exec on
-- every descriptor above stderr. Call only in a disposable process on a bound
-- OS thread, immediately before exec on that same thread. Success does not
-- mean descriptors are closed yet, does not authenticate the standard streams,
-- and does not permit untrusted execution. A failure after unshare is also
-- irreversible for that thread; the worker must terminate rather than resume.
prepareMutationExecDescriptors :: IO (Either MutationDescriptorError ())
prepareMutationExecDescriptors
  | os /= "linux" || arch /= "x86_64" = pure (Left MutationDescriptorUnsupportedHost)
  | otherwise = do
      bound <- isCurrentThreadBound
      if not bound
        then pure (Left MutationDescriptorThreadUnbound)
        else do
          result <- mutationCloseRange closeRangeNumber 3 maxBound (closeRangeUnshare .|. closeRangeCloexec)
          if result /= 0
            then Left . MutationDescriptorCloseRangeFailed <$> errnoNumber
            else checkStandardDescriptors [0, 1, 2]

checkStandardDescriptors :: [Int] -> IO (Either MutationDescriptorError ())
checkStandardDescriptors descriptors = case descriptors of
  [] -> pure (Right ())
  descriptor : remaining -> do
    observed <- try (getFdStatus (Fd (fromIntegral descriptor)))
    case observed of
      Left (_ :: IOException) -> pure (Left (MutationDescriptorStandardUnobservable descriptor))
      Right status
        | isNamedPipe status || isRegularFile status -> checkStandardDescriptors remaining
        | otherwise -> pure (Left (MutationDescriptorStandardUnsafe descriptor))

errnoNumber :: IO Int
errnoNumber = do
  Errno value <- getErrno
  pure (fromIntegral value)
