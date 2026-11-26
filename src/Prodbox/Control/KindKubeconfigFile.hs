{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded descriptor-relative acquisition of the selected kind kubeconfig.
-- This observes local bytes; it does not authenticate the Kubernetes peer.
module Prodbox.Control.KindKubeconfigFile
  ( KindKubeconfigFileError (..)
  , readKindKubeconfig
  , withKindKubeconfigSnapshot
  , withKindKubeconfigSnapshotBound
  )
where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Foreign.C.Error (throwErrnoIfMinus1, throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
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
import Prodbox.Control.KindKubeconfig
  ( KindKubeconfig
  , kindKubeconfigContext
  , kindKubeconfigServer
  , withKindKubeconfigMaterial
  )
import Prodbox.Control.KindKubeconfigYaml (KindKubeconfigDecodeError, decodeKindKubeconfig)
import System.IO (SeekMode (AbsoluteSeek))
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
  , setFdMode
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd (..), UserID)
import System.Posix.User (getEffectiveUserID)
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

-- | Reconstruct the validated self-contained kubeconfig in a sealed anonymous
-- file. The callback receives only a process-local descriptor path, never the
-- secret bytes. This binds consumers to the selected snapshot, but does not
-- authenticate the cluster or prevent the descriptor owner from reading it.
withKindKubeconfigSnapshot
  :: BootstrapProjection -> (FilePath -> IO a) -> IO (Either KindKubeconfigFileError a)
withKindKubeconfigSnapshot bootstrap action =
  withKindKubeconfigSnapshotBound bootstrap (\_ -> action)

-- The projection and sealed file are created from the same validated bytes.
-- The callback must keep their lifetime bounded and must not render secrets.
withKindKubeconfigSnapshotBound
  :: BootstrapProjection -> (KindKubeconfig -> FilePath -> IO a) -> IO (Either KindKubeconfigFileError a)
withKindKubeconfigSnapshotBound bootstrap action = do
  result <- readKindKubeconfig bootstrap
  case result of
    Left failure -> pure (Left failure)
    Right config -> do
      created <- try $ withCString "prodbox-kubeconfig" $ \name ->
        Fd
          <$> throwErrnoIfMinus1 "memfd_create" (createMemoryFile name (memoryCloseOnExec .|. memoryAllowSealing))
      case created of
        Left (_ :: IOException) -> pure (Left KindKubeconfigFileUnobservable)
        Right descriptor -> bracket (pure descriptor) Posix.closeFd $ \file@(Fd raw) -> do
          prepared <- try $ withKindKubeconfigMaterial config $ \ca cert key -> do
            let context = kindKubeconfigContext config
                encoded = TextEncoding.decodeUtf8 . Base64.encode
                bytes =
                  LazyByteString.toStrict $
                    Aeson.encode $
                      Aeson.object
                        [ "apiVersion" Aeson..= ("v1" :: String)
                        , "kind" Aeson..= ("Config" :: String)
                        , "current-context" Aeson..= context
                        , "clusters"
                            Aeson..= [ Aeson.object
                                         [ "name" Aeson..= context
                                         , "cluster"
                                             Aeson..= Aeson.object
                                               ["server" Aeson..= kindKubeconfigServer config, "certificate-authority-data" Aeson..= encoded ca]
                                         ]
                                     ]
                        , "contexts"
                            Aeson..= [ Aeson.object
                                         [ "name" Aeson..= context
                                         , "context" Aeson..= Aeson.object ["cluster" Aeson..= context, "user" Aeson..= context]
                                         ]
                                     ]
                        , "users"
                            Aeson..= [ Aeson.object
                                         [ "name" Aeson..= context
                                         , "user"
                                             Aeson..= Aeson.object
                                               ["client-certificate-data" Aeson..= encoded cert, "client-key-data" Aeson..= encoded key]
                                         ]
                                     ]
                        ]
                writeAll remaining
                  | ByteString.null remaining = pure ()
                  | otherwise = do
                      count <- PosixBytes.fdWrite file remaining
                      unless (count > 0) (ioError (userError "short kubeconfig snapshot write"))
                      writeAll (ByteString.drop (fromIntegral count) remaining)
                seals = sealSeal .|. sealShrink .|. sealGrow .|. sealWrite
            writeAll bytes
            setFdMode file 0o400
            throwErrnoIfMinus1_ "F_ADD_SEALS" (memoryControl raw addSeals seals)
            actual <- throwErrnoIfMinus1 "F_GET_SEALS" (memoryControl raw getSeals 0)
            unless (actual .&. seals == seals) (ioError (userError "kubeconfig seals unavailable"))
            _ <- Posix.fdSeek file AbsoluteSeek 0
            checked <- readBounded file [] 0
            unless (checked == Just bytes) (ioError (userError "kubeconfig snapshot read-back failed"))
          case prepared of
            Left (_ :: IOException) -> pure (Left KindKubeconfigFileUnobservable)
            Right () -> do
              pid <- getProcessID
              Right <$> action config ("/proc/" ++ show pid ++ "/fd/" ++ show raw)

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
