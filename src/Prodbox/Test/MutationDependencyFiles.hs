{-# LANGUAGE ImportQualifiedPost #-}

-- | Copy only selected dependency artifacts into a private campaign directory.
module Prodbox.Test.MutationDependencyFiles
  ( DependencyCopyBudget
  , newDependencyCopyBudget
  , copyDependencyEntry
  , readDependencyPlan
  , dependencyDirectoryFlags
  ) where

import Control.Exception (bracket)
import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.Char (toLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sort)
import Prodbox.Test.MutationOutputInventory (mutationWorkspaceSameMount)
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.Posix.Directory qualified as Directory
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)

newtype DependencyCopyBudget = DependencyCopyBudget (IORef (Int, Integer))

newDependencyCopyBudget :: IO DependencyCopyBudget
newDependencyCopyBudget = DependencyCopyBudget <$> newIORef (0, 0)

dependencyDirectoryFlags :: Posix.OpenFileFlags
dependencyDirectoryFlags = dependencyFileFlags {Posix.directory = True}

dependencyFileFlags :: Posix.OpenFileFlags
dependencyFileFlags =
  Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

readDependencyPlan :: UserID -> Fd -> IO ByteString.ByteString
readDependencyPlan owner parent =
  withSelectedFile owner parent "plan.json" $ \status file -> do
    unless (Files.fileSize status <= 4 * 1024 * 1024) (refuse "dependency plan too large")
    withHandle file $ \handle -> ByteString.hGet handle (4 * 1024 * 1024 + 1)

-- | Return only selected content hashes and relative names. The destination
-- is already held under the private campaign root.
copyDependencyEntry
  :: UserID
  -> DependencyCopyBudget
  -> Fd
  -> Fd
  -> FilePath
  -> IO [(FilePath, Digest SHA256)]
copyDependencyEntry owner budget = copy (0 :: Int) ""
 where
  copy depth prefix source target name = do
    unless (depth <= 40 && validEntry name) (refuse "unsafe dependency entry")
    let relative = if null prefix then name else prefix </> name
        sourceName = descriptorPath source </> name
    status <- Files.getSymbolicLinkStatus sourceName
    reserve budget (if Files.isRegularFile status then toInteger (Files.fileSize status) else 0)
    if Files.isDirectory status
      then bracket (Posix.openFdAt (Just source) name Posix.ReadOnly dependencyDirectoryFlags) Posix.closeFd $ \directory -> do
        before <- Files.getFdStatus directory
        sameMount <- mutationWorkspaceSameMount source directory
        unless
          (sameMount && Files.fileOwner before == owner && sameVersion status before)
          (refuse "dependency directory changed")
        Directory.createDirectory (descriptorPath target </> name) 0o700
        copied <-
          bracket (Posix.openFdAt (Just target) name Posix.ReadOnly dependencyDirectoryFlags) Posix.closeFd $ \destination -> do
            children <- directoryNames directory
            result <- concat <$> traverse (copy (depth + 1) relative directory destination) children
            fileSynchronise destination
            pure result
        after <- Files.getFdStatus directory
        named <- Files.getSymbolicLinkStatus sourceName
        unless (sameVersion before after && sameVersion after named) (refuse "dependency directory changed")
        pure copied
      else withSelectedFile owner source name $ \original input -> do
        unless (sameVersion status original) (refuse "dependency file changed before reading")
        let accessibleMode = 0o600 + (Files.fileMode original .&. 0o100)
            creation = dependencyFileFlags {Posix.creat = Just accessibleMode, Posix.exclusive = True}
        content <-
          bracket (Posix.openFdAt (Just target) name Posix.WriteOnly creation) Posix.closeFd $ \output -> do
            digest <- withHandle input $ \inputHandle -> withHandle output $ \outputHandle ->
              let stream remaining context
                    | remaining == 0 = do
                        extra <- ByteString.hGet inputHandle 1
                        unless (ByteString.null extra) (refuse "dependency file grew during read")
                        pure (hashFinalize context)
                    | otherwise = do
                        chunk <- ByteString.hGetSome inputHandle (fromIntegral (min remaining 131072))
                        when (ByteString.null chunk) (refuse "dependency file shrank during read")
                        ByteString.hPut outputHandle chunk
                        stream (remaining - fromIntegral (ByteString.length chunk)) (hashUpdate context chunk)
               in stream (Files.fileSize original) hashInit
            fileSynchronise output
            pure digest
        pure [(relative, content)]

withSelectedFile :: UserID -> Fd -> FilePath -> (Files.FileStatus -> Fd -> IO a) -> IO a
withSelectedFile owner directory name inspect = do
  unless (validEntry name) (refuse "unsafe dependency file name")
  let path = descriptorPath directory </> name
  named <- Files.getSymbolicLinkStatus path
  unless (safeFile owner named) (refuse "unsafe dependency file")
  bracket (Posix.openFdAt (Just directory) name Posix.ReadOnly dependencyFileFlags) Posix.closeFd $ \file -> do
    before <- Files.getFdStatus file
    sameMount <- mutationWorkspaceSameMount directory file
    unless (sameMount && sameVersion named before) (refuse "dependency file changed before reading")
    result <- inspect before file
    after <- Files.getFdStatus file
    current <- Files.getSymbolicLinkStatus path
    unless
      (sameVersion before after && sameVersion after current)
      (refuse "dependency file changed during read")
    pure result

withHandle :: Fd -> (Handle -> IO a) -> IO a
withHandle file = bracket (Posix.dup file >>= Posix.fdToHandle) hClose

reserve :: DependencyCopyBudget -> Integer -> IO ()
reserve (DependencyCopyBudget counter) bytes = do
  permitted <- atomicModifyIORef' counter $ \(count, size) ->
    let next = (count + 1, size + bytes)
     in (next, bytes >= 0 && bytes <= 2147483648 && fst next <= 100000 && snd next <= 8589934592)
  unless permitted (refuse "dependency copy exceeds its entry or size bound")

directoryNames :: Fd -> IO [FilePath]
directoryNames directory =
  bracket
    (Directory.openDirStream (descriptorPath directory))
    Directory.closeDirStream
    (go (0 :: Int) [])
 where
  go count names iter = do
    name <- Directory.readDirStream iter
    if null name
      then pure (sort names)
      else
        if name `elem` [".", ".."]
          then go count names iter
          else
            if count >= 4096
              then refuse "dependency directory exceeds its entry bound"
              else go (count + 1) (name : names) iter

validEntry :: FilePath -> Bool
validEntry name =
  not (null name)
    && length name <= 255
    && notElem '/' name
    && all (\c -> c >= ' ' && c /= '\DEL') name
    && map toLower name
      `notElem` [".", "..", ".aws", ".ssh", "credentials", "kubeconfig", "test-secrets.dhall"]

safeFile :: UserID -> Files.FileStatus -> Bool
safeFile owner status =
  Files.isRegularFile status
    && Files.fileOwner status == owner
    && Files.linkCount status == 1
    && Files.fileSize status >= 0
    && Files.fileMode status .&. 0o6022 == 0

sameVersion :: Files.FileStatus -> Files.FileStatus -> Bool
sameVersion a b =
  Files.deviceID a == Files.deviceID b
    && Files.fileID a == Files.fileID b
    && Files.fileOwner a == Files.fileOwner b
    && Files.fileMode a == Files.fileMode b
    && Files.fileSize a == Files.fileSize b
    && Files.linkCount a == Files.linkCount b
    && Files.modificationTimeHiRes a == Files.modificationTimeHiRes b
    && Files.statusChangeTimeHiRes a == Files.statusChangeTimeHiRes b

descriptorPath :: Fd -> FilePath
descriptorPath (Fd descriptor) = "/proc/self/fd/" ++ show descriptor

refuse :: String -> IO a
refuse = ioError . userError
