{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded descriptor-relative acquisition of the selected kind kubeconfig.
-- This observes local bytes; it does not authenticate the Kubernetes peer.
module Prodbox.Control.KindKubeconfigFile
  ( KindKubeconfigFileError (..)
  , readKindKubeconfig
  )
where

import Control.Exception (IOException, bracket, try)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Control.KindKubeconfig (KindKubeconfig)
import Prodbox.Control.KindKubeconfigYaml (KindKubeconfigDecodeError, decodeKindKubeconfig)
import System.IO.Error (isEOFError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , isDirectory
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd, UserID)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data KindKubeconfigFileError
  = KindKubeconfigGenerationUnavailable
  | KindKubeconfigFileUnsafe
  | KindKubeconfigFileTooLarge
  | KindKubeconfigFileChanged
  | KindKubeconfigFileUnobservable
  | KindKubeconfigFileTimedOut
  | KindKubeconfigFileInvalid !KindKubeconfigDecodeError
  deriving (Eq, Show)

-- | Read only `control/kubeconfig` beneath the selected, generation-checked
-- root. File and directory descriptors are held through decoding and compared
-- with a fresh no-follow walk. A returned projection is not a cluster identity
-- or permit, and can become stale after this observation.
readKindKubeconfig :: BootstrapProjection -> IO (Either KindKubeconfigFileError KindKubeconfig)
readKindKubeconfig bootstrap = do
  bounded <- timeout 5000000 (readWithinDeadline bootstrap)
  pure (maybe (Left KindKubeconfigFileTimedOut) id bounded)

readWithinDeadline :: BootstrapProjection -> IO (Either KindKubeconfigFileError KindKubeconfig)
readWithinDeadline bootstrap = do
  attempted <- try $ withScopeRootDescriptor scope $ \root sameRoot -> do
    generation <- observeScopeGeneration scope generationId
    if generation /= Right ScopeGenerationMatches
      then pure (Left KindKubeconfigGenerationUnavailable)
      else do
        owner <- getEffectiveUserID
        bracket (openDirectory root) Posix.closeFd $ \control -> do
          directoryBefore <- getFdStatus control
          if not (safeDirectory owner directoryBefore)
            then pure (Left KindKubeconfigFileUnsafe)
            else bracket (openFile control) Posix.closeFd $ \file -> do
              before <- getFdStatus file
              if not (safeFile owner before)
                then pure (Left KindKubeconfigFileUnsafe)
                else
                  if fileSize before > 524288
                    then pure (Left KindKubeconfigFileTooLarge)
                    else do
                      content <- readBounded file [] 0
                      case content of
                        Nothing -> pure (Left KindKubeconfigFileTooLarge)
                        Just bytes -> do
                          decoded <- decodeKindKubeconfig scope bytes
                          after <- getFdStatus file
                          named <-
                            ( try $ bracket (openDirectory root) Posix.closeFd $ \freshDirectory -> do
                                directoryNow <- getFdStatus freshDirectory
                                bracket (openFile freshDirectory) Posix.closeFd $ \freshFile -> do
                                  fileNow <- getFdStatus freshFile
                                  pure
                                    ( safeDirectory owner directoryNow
                                        && sameDirectory directoryBefore directoryNow
                                        && safeFile owner fileNow
                                        && sameFile after fileNow
                                    )
                            )
                              :: IO (Either IOException Bool)
                          stable <- sameRoot
                          finalGeneration <- observeScopeGeneration scope generationId
                          pure $
                            if not stable || finalGeneration /= Right ScopeGenerationMatches || not (sameFile before after)
                              then Left KindKubeconfigFileChanged
                              else case named of
                                Left _ -> Left KindKubeconfigFileUnobservable
                                Right False -> Left KindKubeconfigFileChanged
                                Right True -> either (Left . KindKubeconfigFileInvalid) Right decoded
  pure $ case attempted of
    Left (_ :: IOException) -> Left KindKubeconfigFileUnobservable
    Right (Left _) -> Left KindKubeconfigFileUnobservable
    Right (Right result) -> result
 where
  scope = bootstrapScope bootstrap
  generationId = Text.unpack (bootstrapRootGeneration bootstrap)
  directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
  fileFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  openDirectory parent = Posix.openFdAt (Just parent) "control" Posix.ReadOnly directoryFlags
  openFile parent = Posix.openFdAt (Just parent) "kubeconfig" Posix.ReadOnly fileFlags

safeDirectory :: UserID -> FileStatus -> Bool
safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o077 == 0

safeFile :: UserID -> FileStatus -> Bool
safeFile owner status =
  isRegularFile status
    && fileOwner status == owner
    && fileMode status .&. 0o077 == 0
    && linkCount status == 1

sameDirectory :: FileStatus -> FileStatus -> Bool
sameDirectory left right =
  deviceID left == deviceID right
    && fileID left == fileID right
    && fileOwner left == fileOwner right
    && fileMode left == fileMode right

sameFile :: FileStatus -> FileStatus -> Bool
sameFile left right =
  deviceID left == deviceID right
    && fileID left == fileID right
    && fileOwner left == fileOwner right
    && fileMode left == fileMode right
    && linkCount left == linkCount right
    && fileSize left == fileSize right
    && modificationTimeHiRes left == modificationTimeHiRes right
    && statusChangeTimeHiRes left == statusChangeTimeHiRes right

readBounded :: Fd -> [ByteString.ByteString] -> Int -> IO (Maybe ByteString.ByteString)
readBounded file chunks count = do
  result <- try (PosixBytes.fdRead file (fromIntegral (min 65536 (524289 - count))))
  case result of
    Left (failure :: IOException)
      | isEOFError failure -> pure (Just (ByteString.concat (reverse chunks)))
      | otherwise -> ioError failure
    Right bytes
      | ByteString.null bytes -> pure (Just (ByteString.concat (reverse chunks)))
      | count + ByteString.length bytes > 524288 -> pure Nothing
      | otherwise -> readBounded file (bytes : chunks) (count + ByteString.length bytes)
