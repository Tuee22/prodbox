{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Anonymous, held staging for a verified node image projection. This module
-- neither admits nor performs a Docker effect.
module Prodbox.Control.NodeArchiveStage
  ( StagedNodeFailure (..)
  , StagedNodeResult (..)
  , withStagedNodeArchive
  , reserveStage
  ) where

import Control.Exception (IOException, bracket, mask, onException, throwIO, try)
import Crypto.Hash.SHA256 qualified as SHA
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Numeric (showHex)
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapScope)
import Prodbox.Config.DeploymentScope (withScopeRootDescriptor)
import Prodbox.Control.NodeArchive
  ( InspectedArchiveResult
  , VerifiedNodeArchive
  , withInspectedNodeArchive
  )
import Prodbox.Control.NodeArchiveExport
  ( DockerArchiveResult (..)
  , dockerArchiveRequiredBytes
  , maximumDockerArchiveBytes
  , writeUntaggedDockerArchive
  )
import System.IO (SeekMode (AbsoluteSeek), hClose, hSetBinaryMode)
import System.IO.Error (isEOFError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (CMode (..), COff (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

foreign import capi "fcntl.h value O_TMPFILE" anonymousFile :: CInt
foreign import capi "fcntl.h value O_RDWR" readWrite :: CInt
foreign import capi "fcntl.h value O_CLOEXEC" closeOnExec :: CInt
foreign import capi "fcntl.h openat" openAt :: CInt -> CString -> CInt -> CMode -> IO CInt
foreign import capi safe "fcntl.h posix_fallocate" reserveFile :: CInt -> COff -> COff -> IO CInt

data StagedNodeFailure
  = StagedNodeRootUnavailable
  | StagedNodeIoFailure
  | StagedNodeReservationFailed
  | StagedNodeConversionRefused !DockerArchiveResult
  | StagedNodeVerificationFailed
  deriving (Eq, Show)

data StagedNodeResult value
  = StagedNodeRefused !StagedNodeFailure
  | StagedNodeCompleted !value
  | StagedNodeChanged !value
  deriving (Eq, Show)

-- | Hold an unlinked temporary file for exactly the callback lifetime. The
-- callback must not retain the descriptor or perform effects without separate
-- admission, journal, resource bounds and recovery. The result is nested in
-- the original archive observation so interruption remains unconfirmed.
withStagedNodeArchive
  :: BootstrapProjection
  -> (VerifiedNodeArchive -> String -> Integer -> Fd -> IO Bool -> IO value)
  -> IO (InspectedArchiveResult (StagedNodeResult value))
withStagedNodeArchive bootstrap action =
  withInspectedNodeArchive bootstrap $ \verified source sourceStable -> do
    selected <-
      withScopeRootDescriptor (bootstrapScope bootstrap) (openStage verified source sourceStable)
    pure $ either (const (StagedNodeRefused StagedNodeRootUnavailable)) id selected
 where
  openStage verified source sourceStable root sameRoot = do
    created <- try (createAnonymous root)
    case created of
      Left (_ :: IOException) -> pure (StagedNodeRefused StagedNodeIoFailure)
      Right stage -> do
        returned <- newIORef Nothing
        attempted <- try $ bracket (pure stage) Posix.closeFd $ \held -> useStage returned held sameRoot sourceStable verified source
        case attempted of
          Right result -> pure result
          Left (failure :: IOException) -> do
            observed <- readIORef returned
            maybe (throwIO failure) (pure . StagedNodeChanged) observed
  useStage returned stage sameRoot sourceStable verified source = do
    ready <- (&&) <$> sameRoot <*> sourceStable
    if not ready
      then pure (StagedNodeRefused StagedNodeRootUnavailable)
      else case dockerArchiveRequiredBytes verified of
        Left failure -> pure (StagedNodeRefused (StagedNodeConversionRefused (DockerArchiveNotStarted failure)))
        Right size -> do
          reserved <- reserveStage stage size
          if not reserved
            then pure (StagedNodeRefused StagedNodeReservationFailed)
            else convertStage returned stage sameRoot sourceStable verified source
  convertStage returned stage sameRoot sourceStable verified source = do
    converted <- bracket
      ( do
          duplicate <- Posix.dup stage
          Posix.fdToHandle duplicate `onException` Posix.closeFd duplicate
      )
      hClose
      $ \output -> do
        hSetBinaryMode output True
        writeUntaggedDockerArchive verified source sourceStable output
    case converted of
      DockerArchiveWritten digest count -> do
        fileSynchronise stage
        initial <- Files.getFdStatus stage
        owner <- getEffectiveUserID
        checked <- hashStage stage count
        let stageStable = do
              current <- try (Files.getFdStatus stage)
              rootStable <- sameRoot
              originalStable <- sourceStable
              pure $ case current of
                Left (_ :: IOException) -> False
                Right status -> rootStable && originalStable && safeStage owner status && sameVersion initial status
        stable <- stageStable
        if not (safeStage owner initial && checked == Just (digest, count) && stable)
          then pure (StagedNodeRefused StagedNodeVerificationFailed)
          else do
            _ <- Posix.fdSeek stage AbsoluteSeek 0
            value <- mask $ \restore -> do
              result <- restore (action verified digest count stage stageStable)
              writeIORef returned (Just result)
              pure result
            final <- stageStable
            pure (if final then StagedNodeCompleted value else StagedNodeChanged value)
      other -> pure (StagedNodeRefused (StagedNodeConversionRefused other))

reserveStage :: Fd -> Integer -> IO Bool
reserveStage (Fd descriptor) size
  | size <= 0 || size > maximumDockerArchiveBytes = pure False
  | otherwise = (== 0) <$> reserveFile descriptor 0 (fromInteger size)

createAnonymous :: Fd -> IO Fd
createAnonymous (Fd root) = withCString "." $ \path ->
  Fd
    <$> throwErrnoIfMinus1Retry
      "anonymous node archive"
      (openAt root path (anonymousFile .|. readWrite .|. closeOnExec) 0o600)

safeStage :: UserID -> Files.FileStatus -> Bool
safeStage owner status =
  Files.isRegularFile status
    && Files.fileOwner status == owner
    && Files.linkCount status == 0
    && Files.fileMode status .&. 0o077 == 0
    && Files.fileSize status >= 0
    && toInteger (Files.fileSize status) <= maximumDockerArchiveBytes

sameVersion :: Files.FileStatus -> Files.FileStatus -> Bool
sameVersion first second =
  Files.deviceID first == Files.deviceID second
    && Files.fileID first == Files.fileID second
    && Files.fileSize first == Files.fileSize second
    && Files.modificationTimeHiRes first == Files.modificationTimeHiRes second
    && Files.statusChangeTimeHiRes first == Files.statusChangeTimeHiRes second

hashStage :: Fd -> Integer -> IO (Maybe (String, Integer))
hashStage descriptor expected = do
  _ <- Posix.fdSeek descriptor AbsoluteSeek 0
  go SHA.init 0
 where
  go !context !count = do
    result <- try (PosixBytes.fdRead descriptor 32768)
    bytes <- case result of
      Left failure | isEOFError failure -> pure BS.empty
      Left failure -> throwIO failure
      Right chunk -> pure chunk
    if BS.null bytes
      then pure (if count == expected then Just (renderDigest context, count) else Nothing)
      else do
        let !newCount = count + toInteger (BS.length bytes)
        if newCount > expected
          then pure Nothing
          else go (SHA.update context bytes) newCount
  renderDigest context = "sha256:" ++ concatMap hexByte (BS.unpack (SHA.finalize context))
  hexByte byte = let value = showHex byte "" in if length value == 1 then '0' : value else value
