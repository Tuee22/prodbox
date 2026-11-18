{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Landlock file-access preparation for a dedicated mutation worker. This
-- restricts only the calling OS thread and its future descendants. It does not
-- authenticate descriptors, control inherited descriptors or all metadata
-- syscalls, settle a process family, or authorize execution of mutants.
module Prodbox.Subprocess.MutationFilesystem
  ( MutationFilesystemError (..)
  , installMutationFilesystemRules
  )
where

import Control.Concurrent (isCurrentThreadBound)
import Control.Exception (IOException, bracket, try)
import Data.Bits ((.|.))
import Data.List (nub)
import Data.Word (Word64)
import Foreign.C.Error (Errno (..), getErrno)
import Foreign.C.Types (CInt (..), CLong (..), CSize (..), CUInt (..), CULong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (pokeByteOff, sizeOf)
import System.Info (arch, os)
import System.Posix.Files (deviceID, fileID, getFdStatus, isDirectory, isRegularFile)
import System.Posix.IO (closeFd)
import System.Posix.Types (Fd (..))

foreign import capi "sys/syscall.h value SYS_landlock_create_ruleset" createRulesetNumber :: CLong
foreign import capi "sys/syscall.h value SYS_landlock_add_rule" addRuleNumber :: CLong
foreign import capi "sys/syscall.h value SYS_landlock_restrict_self" restrictNumber :: CLong
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

data MutationFilesystemError
  = MutationFilesystemUnsupportedHost
  | MutationFilesystemThreadUnbound
  | MutationFilesystemInvalidRoots
  | MutationFilesystemRootUnobservable
  | MutationFilesystemAbiUnavailable !Int
  | MutationFilesystemAbiUnsupported !Integer
  | MutationFilesystemRulesetFailed !Int
  | MutationFilesystemRuleFailed !Int
  | MutationFilesystemNoNewPrivilegesFailed !Int
  | MutationFilesystemRestrictFailed !Int
  deriving (Eq, Show)

-- | Install a deny-by-default Landlock filesystem ruleset for one already
-- verified writable directory and up to 32 caller-supplied read/execute roots.
-- Call in a disposable process on a bound OS thread immediately before exec.
-- Landlock does not revoke already open descriptors and does not mediate all
-- metadata syscalls. A successful return is not a safe mutation boundary;
-- root/stream provenance, aliases, metadata restrictions and settlement must
-- be established separately. A failed attempt after no-new-privileges is also
-- irreversible and the worker must terminate.
installMutationFilesystemRules :: Fd -> [Fd] -> IO (Either MutationFilesystemError ())
installMutationFilesystemRules workspace suppliedRoots
  | os /= "linux" || arch /= "x86_64" || sizeOf (0 :: CULong) /= 8 =
      pure (Left MutationFilesystemUnsupportedHost)
  | otherwise = do
      bound <- isCurrentThreadBound
      if not bound
        then pure (Left MutationFilesystemThreadUnbound)
        else do
          let roots = take 33 suppliedRoots
          if length roots > 32
            || any (\(Fd descriptor) -> descriptor < 3) (workspace : roots)
            || workspace `elem` roots
            then pure (Left MutationFilesystemInvalidRoots)
            else do
              observed <- try $ do
                writable <- getFdStatus workspace
                readable <- traverse getFdStatus roots
                let identities = map (\status -> (deviceID status, fileID status)) (writable : readable)
                pure
                  ( isDirectory writable
                  , map (\status -> (isDirectory status, isRegularFile status)) readable
                  , length identities == length (nub identities)
                  )
              case observed of
                Left (_ :: IOException) -> pure (Left MutationFilesystemRootUnobservable)
                Right (False, _, _) -> pure (Left MutationFilesystemInvalidRoots)
                Right (_, _, False) -> pure (Left MutationFilesystemInvalidRoots)
                Right (True, kinds, True)
                  | any (\(directory, regular) -> not (directory || regular)) kinds ->
                      pure (Left MutationFilesystemInvalidRoots)
                  | otherwise -> install roots kinds
 where
  install roots kinds = do
    abi <- createRuleset createRulesetNumber nullPtr 0 versionFlag
    if abi < 0
      then Left . MutationFilesystemAbiUnavailable <$> errnoNumber
      else
        if abi < 5 || abi > 8
          then pure (Left (MutationFilesystemAbiUnsupported (toInteger abi)))
          else allocaBytes 8 $ \attributes -> do
            pokeByteOff attributes 0 handledAccess
            raw <- createRuleset createRulesetNumber (castPtr attributes) 8 0
            if raw < 0
              then Left . MutationFilesystemRulesetFailed <$> errnoNumber
              else bracket (pure (Fd (fromIntegral raw))) closeFd $ \ruleset -> do
                writable <- addPath ruleset workspace workspaceAccess
                case writable of
                  Left failure -> pure (Left failure)
                  Right () -> do
                    readable <- addReadRoots ruleset (zip roots kinds)
                    case readable of
                      Left failure -> pure (Left failure)
                      Right () -> do
                        noNew <- filesystemPrctl noNewPrivileges 1 0 0 0
                        if noNew /= 0
                          then Left . MutationFilesystemNoNewPrivilegesFailed <$> errnoNumber
                          else do
                            let Fd descriptor = ruleset
                            result <- restrictSelf restrictNumber descriptor 0
                            if result /= 0 then Left . MutationFilesystemRestrictFailed <$> errnoNumber else pure (Right ())

addReadRoots :: Fd -> [(Fd, (Bool, Bool))] -> IO (Either MutationFilesystemError ())
addReadRoots ruleset roots = case roots of
  [] -> pure (Right ())
  (root, (directory, _)) : remaining -> do
    result <- addPath ruleset root (if directory then directoryReadAccess else fileReadAccess)
    case result of
      Left failure -> pure (Left failure)
      Right () -> addReadRoots ruleset remaining

addPath :: Fd -> Fd -> Word64 -> IO (Either MutationFilesystemError ())
addPath (Fd ruleset) (Fd root) rights = allocaBytes 16 $ \attribute -> do
  pokeByteOff attribute 0 rights
  pokeByteOff attribute 8 root
  result <- addRule addRuleNumber ruleset pathBeneath (castPtr attribute) 0
  if result /= 0 then Left . MutationFilesystemRuleFailed <$> errnoNumber else pure (Right ())

-- The reviewed Landlock ABI 5..8 filesystem rights are 0..15. Device, socket
-- and FIFO creation and device ioctls are handled but not granted to the
-- workspace. Unknown later ABIs are refused until their rights are reviewed.
handledAccess, workspaceAccess, directoryReadAccess, fileReadAccess :: Word64
handledAccess = 0xffff
workspaceAccess = 0x71bf
fileReadAccess = 0x0005
directoryReadAccess = fileReadAccess .|. 0x0008

errnoNumber :: IO Int
errnoNumber = do
  Errno value <- getErrno
  pure (fromIntegral value)
