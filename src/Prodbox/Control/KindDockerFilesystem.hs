{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Landlock filesystem preparation for a dedicated kind worker. This acts on
-- the current OS thread and descendants; it is not a complete sandbox.
module Prodbox.Control.KindDockerFilesystem
  ( KindDockerFilesystemError (..)
  , installKindDockerFilesystemRules
  ) where

import Control.Concurrent (isCurrentThreadBound)
import Control.Exception (IOException, bracket, try)
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Word (Word64)
import Foreign.C.Error (Errno (..), getErrno, throwErrnoIfMinus1)
import Foreign.C.Types (CInt (..), CLong (..), CSize (..), CUInt (..), CULong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (pokeByteOff, sizeOf)
import System.Info (arch, os)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , getFdStatus
  , isCharacterDevice
  , isDirectory
  , isNamedPipe
  , isRegularFile
  , specialDeviceID
  )
import System.Posix.IO (closeFd)
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)

foreign import capi "sys/syscall.h value SYS_landlock_create_ruleset" createRulesetNumber :: CLong
foreign import capi "sys/syscall.h value SYS_landlock_add_rule" addRuleNumber :: CLong
foreign import capi "sys/syscall.h value SYS_landlock_restrict_self" restrictNumber :: CLong
foreign import capi "sys/syscall.h value SYS_getdents64" getdentsNumber :: CLong
foreign import capi "linux/landlock.h value LANDLOCK_CREATE_RULESET_VERSION" versionFlag :: CUInt
foreign import capi "linux/landlock.h value LANDLOCK_RULE_PATH_BENEATH" pathBeneath :: CInt
foreign import capi "sys/prctl.h value PR_SET_NO_NEW_PRIVS" noNewPrivileges :: CInt
foreign import capi "sys/prctl.h prctl"
  filesystemPrctl :: CInt -> CULong -> CULong -> CULong -> CULong -> IO CInt
foreign import ccall unsafe "syscall"
  createRuleset :: CLong -> Ptr () -> CSize -> CUInt -> IO CLong
foreign import ccall unsafe "syscall"
  addRule :: CLong -> CInt -> CInt -> Ptr () -> CUInt -> IO CLong
foreign import ccall unsafe "syscall"
  restrictSelf :: CLong -> CInt -> CUInt -> IO CLong
foreign import ccall unsafe "syscall"
  getdents :: CLong -> CInt -> Ptr () -> CUInt -> IO CLong

data KindDockerFilesystemError
  = KindDockerFilesystemUnsupportedHost
  | KindDockerFilesystemThreadUnbound
  | KindDockerFilesystemInvalidRoots
  | KindDockerFilesystemScratchNotEmpty
  | KindDockerFilesystemRootUnobservable
  | KindDockerFilesystemAbiUnavailable !Int
  | KindDockerFilesystemAbiUnsupported !Integer
  | KindDockerFilesystemRulesetFailed !Int
  | KindDockerFilesystemRuleFailed !Int
  | KindDockerFilesystemNoNewPrivilegesFailed !Int
  | KindDockerFilesystemRestrictFailed !Int
  deriving (Eq, Show)

-- | The caller supplies O_PATH descriptors for a writable scratch directory,
-- read/execute roots, one lock file, two FIFOs and a verified /dev/null O_PATH
-- descriptor. Only those endpoint files receive write access; only the lock
-- receives truncate access. The null device receives read-only access. Scratch
-- must be an empty owner-only directory. Before use, callers must independently
-- exclude writers and prove that writable scratch cannot reach the
-- endpoints through an ancestor, bind mount or alias, and must close inherited
-- descriptors and install the network and metadata boundaries. Rules apply
-- only to this bound OS thread and future descendants. A failure after setting
-- no-new-privileges is irreversible; the disposable worker must terminate.
installKindDockerFilesystemRules
  :: Fd -> [Fd] -> Fd -> Fd -> Fd -> Fd -> IO (Either KindDockerFilesystemError ())
installKindDockerFilesystemRules scratch suppliedRoots lock request reply nullDevice
  | os /= "linux" || arch /= "x86_64" || sizeOf (0 :: CULong) /= 8 =
      pure (Left KindDockerFilesystemUnsupportedHost)
  | otherwise = do
      bound <- isCurrentThreadBound
      if not bound
        then pure (Left KindDockerFilesystemThreadUnbound)
        else do
          let roots = take 33 suppliedRoots
              descriptors = scratch : lock : request : reply : nullDevice : roots
          if length roots > 32 || any (\(Fd descriptor) -> descriptor < 3) descriptors
            then pure (Left KindDockerFilesystemInvalidRoots)
            else do
              observed <- try (traverse getFdStatus descriptors)
              case observed of
                Left (_ :: IOException) -> pure (Left KindDockerFilesystemRootUnobservable)
                Right statuses -> case statuses of
                  scratchStatus : lockStatus : requestStatus : replyStatus : nullStatus : readStatuses
                    | isDirectory scratchStatus
                    , isRegularFile lockStatus
                    , isNamedPipe requestStatus
                    , isNamedPipe replyStatus
                    , isCharacterDevice nullStatus
                    , -- Linux dev_t for the null character device, major 1 minor 3.
                      specialDeviceID nullStatus == 259
                    , all (\status -> isDirectory status || isRegularFile status) readStatuses
                    , let identities = map (\status -> (deviceID status, fileID status)) statuses
                    , length identities == length (nub identities) -> do
                        empty <- try (emptyScratch scratch scratchStatus)
                        case empty of
                          Left (_ :: IOException) -> pure (Left KindDockerFilesystemRootUnobservable)
                          Right False -> pure (Left KindDockerFilesystemScratchNotEmpty)
                          Right True -> install (zip roots (map isDirectory readStatuses))
                  _ -> pure (Left KindDockerFilesystemInvalidRoots)
 where
  install roots = do
    abi <- createRuleset createRulesetNumber nullPtr 0 versionFlag
    if abi < 0
      then Left . KindDockerFilesystemAbiUnavailable <$> errnoNumber
      else
        if abi < 5 || abi > 8
          then pure (Left (KindDockerFilesystemAbiUnsupported (toInteger abi)))
          else allocaBytes 8 $ \attributes -> do
            pokeByteOff attributes 0 handledAccess
            raw <- createRuleset createRulesetNumber (castPtr attributes) 8 0
            if raw < 0
              then Left . KindDockerFilesystemRulesetFailed <$> errnoNumber
              else bracket (pure (Fd (fromIntegral raw))) closeFd $ \ruleset -> do
                let rules =
                      (scratch, scratchAccess)
                        : (lock, lockAccess)
                        : (request, fifoAccess)
                        : (reply, fifoAccess)
                        : (nullDevice, nullDeviceAccess)
                        : [(root, if directory then directoryReadAccess else fileReadAccess) | (root, directory) <- roots]
                added <- addPaths ruleset rules
                case added of
                  Left failure -> pure (Left failure)
                  Right () -> do
                    noNew <- filesystemPrctl noNewPrivileges 1 0 0 0
                    if noNew /= 0
                      then Left . KindDockerFilesystemNoNewPrivilegesFailed <$> errnoNumber
                      else do
                        let Fd descriptor = ruleset
                        result <- restrictSelf restrictNumber descriptor 0
                        if result /= 0 then Left . KindDockerFilesystemRestrictFailed <$> errnoNumber else pure (Right ())

-- Inspect an independently opened directory stream, not a shared directory
-- offset. Reject malformed records and cap iterations even on an odd filesystem.
emptyScratch :: Fd -> FileStatus -> IO Bool
emptyScratch scratch original = do
  owner <- getEffectiveUserID
  let flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
      safe status =
        isDirectory status
          && fileOwner status == owner
          && fileMode status .&. 0o077 == 0
          && deviceID status == deviceID original
          && fileID status == fileID original
  if not (safe original)
    then pure False
    else bracket (Posix.openFdAt (Just scratch) "." Posix.ReadOnly flags) Posix.closeFd $ \directory -> do
      before <- getFdStatus directory
      scanned <- if safe before then scanScratch directory else pure False
      after <- getFdStatus directory
      pure (scanned && safe after)

scanScratch :: Fd -> IO Bool
scanScratch (Fd descriptor) = allocaBytes 4096 $ \buffer -> go buffer 0 (False, False)
 where
  go buffer iterations seen
    | iterations >= (4 :: Int) = pure False
    | otherwise = do
        count <-
          throwErrnoIfMinus1
            "read kind scratch directory"
            (getdents getdentsNumber descriptor (castPtr buffer) 4096)
        if count == 0
          then pure (seen == (True, True))
          else do
            bytes <- BS.packCStringLen (castPtr buffer, fromIntegral count)
            case scanScratchEntries seen bytes of
              Nothing -> pure False
              Just next -> go buffer (iterations + 1) next

scanScratchEntries :: (Bool, Bool) -> BS.ByteString -> Maybe (Bool, Bool)
scanScratchEntries seen bytes
  | BS.null bytes = Just seen
  | BS.length bytes < 20 = Nothing
  | recordLength < 20 || recordLength > BS.length bytes = Nothing
  | BS.null suffix = Nothing
  | name == BS.pack [46] && not (fst seen) = scanScratchEntries (True, snd seen) rest
  | name == BS.pack [46, 46] && not (snd seen) = scanScratchEntries (fst seen, True) rest
  | otherwise = Nothing
 where
  recordLength = fromIntegral (BS.index bytes 16) + 256 * fromIntegral (BS.index bytes 17)
  (record, rest) = BS.splitAt recordLength bytes
  (name, suffix) = BS.break (== 0) (BS.drop 19 record)

addPaths :: Fd -> [(Fd, Word64)] -> IO (Either KindDockerFilesystemError ())
addPaths ruleset rules = case rules of
  [] -> pure (Right ())
  (root, rights) : remaining -> do
    added <- addPath ruleset root rights
    case added of
      Left failure -> pure (Left failure)
      Right () -> addPaths ruleset remaining

addPath :: Fd -> Fd -> Word64 -> IO (Either KindDockerFilesystemError ())
addPath (Fd ruleset) (Fd root) rights = allocaBytes 16 $ \attribute -> do
  pokeByteOff attribute 0 rights
  pokeByteOff attribute 8 root
  result <- addRule addRuleNumber ruleset pathBeneath (castPtr attribute) 0
  if result /= 0 then Left . KindDockerFilesystemRuleFailed <$> errnoNumber else pure (Right ())

handledAccess
  , scratchAccess
  , directoryReadAccess
  , fileReadAccess
  , lockAccess
  , fifoAccess
  , nullDeviceAccess
    :: Word64
handledAccess = 0xffff
scratchAccess = 0x71bf
fileReadAccess = 0x0005
directoryReadAccess = fileReadAccess .|. 0x0008
lockAccess = 0x4006
fifoAccess = 0x0006
nullDeviceAccess = 0x0004

errnoNumber :: IO Int
errnoNumber = do
  Errno value <- getErrno
  pure (fromIntegral value)
