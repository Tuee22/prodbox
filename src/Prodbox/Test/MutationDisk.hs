{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Kernel-bounded writable storage shared across one mutation case's
-- separately retired workers. The keeper mounts it read-only for the
-- outer observer. Mutated code never receives the runtime socket.
module Prodbox.Test.MutationDisk
  ( MutationDisk (..)
  , MutationDiskFailure (..)
  , MutationDiskReceipt (..)
  , mutationDiskVolume
  , mutationDiskBytes
  , withMutationDisk
  , retireUnusedMutationDisk
  ) where

import Control.Exception (IOException, bracket, mask, onException, try)
import Control.Monad (guard)
import Data.Bits ((.&.))
import Data.ByteString qualified as Bytes
import Data.Map.Strict qualified as Map
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoResult (..)
  , DockerMutationVolume (..)
  , DockerMutationVolumeObservation (..)
  , DockerNodeContainerRemoveResult (..)
  , DockerNodeVarRemoveResult (..)
  , DockerSession
  , createDockerSessionMutationVolume
  , inspectDockerSessionMutationVolume
  , readDockerSessionBridgeMtu
  , readDockerSessionContainerNotFound
  , readDockerSessionMutationHolder
  , removeDockerSessionKindNode
  , removeDockerSessionMutationVolume
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (DockerDaemonObserved))
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..))
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Posix.Files (deviceID, fileID, fileMode, fileOwner, getFdStatus, isDirectory)
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID)
import Text.Read (readMaybe)

data MutationDisk = MutationDisk
  { mutationDiskName :: !String
  , mutationDiskRoot :: !Fd
  , mutationDiskStable :: IO Bool
  }

data MutationDiskFailure
  = MutationDiskReservationRefused
  | MutationDiskCreateUnconfirmed
  | MutationDiskCreateReceiptUnconfirmed
  | MutationDiskKeeperUnconfirmed
  | MutationDiskKeeperReceiptUnconfirmed
  | MutationDiskMountUnconfirmed
  deriving (Eq, Show)

data MutationDiskReceipt
  = MutationDiskIntent !DockerMutationVolume
  | MutationDiskCreated !String
  | MutationDiskKeeper !String !Int
  | MutationDiskRemovalIntent !String !String
  | MutationDiskRemoved !String !String
  deriving (Eq, Show)

mutationDiskBytes :: Integer
mutationDiskBytes = 3 * 1024 * 1024 * 1024

maximumInodes :: Integer
maximumInodes = 32768

mutationDiskVolume :: String -> String -> IO DockerMutationVolume
mutationDiskVolume name owner = do
  uid <- getEffectiveUserID
  gid <- getEffectiveGroupID
  let options =
        "size="
          ++ show mutationDiskBytes
          ++ ",nr_inodes="
          ++ show maximumInodes
          ++ ",uid="
          ++ show uid
          ++ ",gid="
          ++ show gid
          ++ ",mode=0700,nosuid,nodev"
  pure $
    DockerMutationVolume
      name
      owner
      (Map.fromList [("type", "tmpfs"), ("device", "tmpfs"), ("o", options)])

-- The keeper launcher must persist its separate container launch intent and
-- exact returned ID. An unknown effect retains its evidence and prevents a
-- case from qualifying. Removal runs on the originally bound daemon.
withMutationDisk
  :: FilePath
  -> DockerDaemonObservation
  -> String
  -> String
  -> DockerMutationVolume
  -> IO Bool
  -> (MutationDiskReceipt -> IO Bool)
  -> IO (Maybe String)
  -> (MutationDisk -> IO value)
  -> IO (Either MutationDiskFailure (value, Bool))
withMutationDisk socket daemon image user volume campaignStable record launch action = mask $ \restore -> do
  prepared <- record (MutationDiskIntent volume)
  if not prepared
    then pure (Left MutationDiskReservationRefused)
    else do
      created <- onDaemon $ \session stable -> do
        control <- readDockerSessionBridgeMtu session
        prior <- inspectDockerSessionMutationVolume session volume
        case control of
          Right (Just _) | prior == Right DockerMutationVolumeMissing -> do
            result <- createDockerSessionMutationVolume session volume stable
            known <- inspectDockerSessionMutationVolume session volume
            closing <- stable
            pure $ case result of
              Right (DockerMutationVolumeObserved timestamp) | result == known && closing -> Just timestamp
              _ -> Nothing
          _ -> pure Nothing
      case created of
        Just (Just timestamp) -> do
          stored <- record (MutationDiskCreated timestamp)
          if not stored
            then pure (Left MutationDiskCreateReceiptUnconfirmed)
            else do
              keeper <- launch
              case keeper of
                Nothing -> pure (Left MutationDiskKeeperUnconfirmed)
                Just identifier -> do
                  seen <- inspectKeeper timestamp identifier
                  case seen of
                    Nothing -> pure (Left MutationDiskKeeperUnconfirmed)
                    Just pid -> do
                      keeperStored <- record (MutationDiskKeeper identifier pid)
                      if not keeperStored
                        then pure (Left MutationDiskKeeperReceiptUnconfirmed)
                        else do
                          attempted <-
                            try (withMountedDisk pid timestamp identifier (restore . action))
                              `onException` retire timestamp identifier
                          cleaned <- retire timestamp identifier
                          pure $ case attempted of
                            Left (_ :: IOException) -> Left MutationDiskMountUnconfirmed
                            Right result -> Right (result, cleaned)
        _ -> pure (Left MutationDiskCreateUnconfirmed)
 where
  onDaemon :: (DockerSession -> IO Bool -> IO a) -> IO (Maybe a)
  onDaemon use = do
    observed <- withConnectedDockerInfo 45000000 socket $ \session (DockerConnectedInfo current (DockerPeer _ _ _ peer)) stable -> do
      let bound = (&&) <$> campaignStable <*> stable
      ready <- bound
      let admitted = session <$ guard (ready && daemon == DockerDaemonObserved current peer)
      traverse (`use` bound) admitted
    pure $ case observed of
      DockerPeerCompleted (DockerConnectedInfoCompleted result) -> result
      _ -> Nothing
  inspectKeeper timestamp identifier = do
    found <- onDaemon $ \session stable -> do
      exactVolume <- inspectDockerSessionMutationVolume session volume
      process <- readDockerSessionMutationHolder session identifier image user volume
      held <- stable
      pure $ case process of
        Right pid | exactVolume == Right (DockerMutationVolumeObserved timestamp) && held -> Just pid
        _ -> Nothing
    pure (found >>= id)
  withMountedDisk pid timestamp identifier use = do
    let path = "/proc" </> show pid </> "root" </> "quota"
        flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True}
        open = Posix.openFd path Posix.ReadOnly flags
    bracket open Posix.closeFd $ \root -> do
      owner <- getEffectiveUserID
      initial <- getFdStatus root
      let equivalent status =
            isDirectory status
              && deviceID initial == deviceID status
              && fileID initial == fileID status
              && fileOwner status == owner
              && fileMode status .&. 0o077 == 0
          stable = do
            held <- getFdStatus root
            named <- try (bracket open Posix.closeFd getFdStatus)
            campaign <- campaignStable
            pure $ case named of
              Right status -> equivalent held && equivalent status && campaign
              Left (_ :: IOException) -> False
      before <- stable
      capacity <- observeCapacity path
      holder <- inspectKeeper timestamp identifier
      closing <- stable
      if before && capacity && holder == Just pid && closing
        then use (MutationDisk (dockerMutationVolumeName volume) root stable)
        else ioError (userError "mutation quota or holder identity changed")
  retire timestamp identifier = do
    recorded <- record (MutationDiskRemovalIntent timestamp identifier)
    if not recorded
      then pure False
      else do
        outcome <- onDaemon $ \session stable -> do
          known <- inspectDockerSessionMutationVolume session volume
          holder <- readDockerSessionMutationHolder session identifier image user volume
          case holder of
            Right _ | known == Right (DockerMutationVolumeObserved timestamp) -> do
              removed <- removeDockerSessionKindNode session identifier stable stable
              retired <- readDockerSessionContainerNotFound session identifier
              case removed of
                DockerNodeContainerRemoveReply 204 | retired -> do
                  result <- removeDockerSessionMutationVolume session volume stable
                  after <- inspectDockerSessionMutationVolume session volume
                  control <- readDockerSessionBridgeMtu session
                  held <- stable
                  pure $ case control of
                    Right (Just _) -> result == DockerNodeVarRemoveReply 204 && after == Right DockerMutationVolumeMissing && held
                    _ -> False
                _ -> pure False
            _ -> pure False
        if outcome == Just True
          then record (MutationDiskRemoved timestamp identifier)
          else pure False

observeCapacity :: FilePath -> IO Bool
observeCapacity path = do
  result <-
    captureSubprocessWithInputBounded
      (BoundedSubprocessLimits 1 4096 4096 5000000)
      Bytes.empty
      ( Subprocess
          "/usr/bin/stat"
          ["-f", "--format=%T %b %S %c", path]
          (Just [("PATH", "/usr/bin:/bin"), ("LC_ALL", "C")])
          Nothing
      )
  pure $ case result of
    Right output | processExitCode output == ExitSuccess ->
      case words (processStdout output) of
        ["tmpfs", blocks, blockSize, inodes] ->
          ((*) <$> readMaybe blocks <*> readMaybe blockSize) == Just mutationDiskBytes
            && readMaybe inodes == Just maximumInodes
        _ -> False
    _ -> False

-- | Recover a durably created volume whose terminal case records prove the
-- keeper was never launched. The caller retains and rechecks that proof.
retireUnusedMutationDisk
  :: FilePath -> DockerDaemonObservation -> DockerMutationVolume -> String -> IO Bool -> IO Bool
retireUnusedMutationDisk socket daemon volume createdAt admitted = do
  observed <- withConnectedDockerInfo 45000000 socket $ \session (DockerConnectedInfo current (DockerPeer _ _ _ peer)) peerCheck -> do
    let held = (&&) <$> admitted <*> peerCheck
    before <- held
    bridge <- readDockerSessionBridgeMtu session
    currentVolume <- inspectDockerSessionMutationVolume session volume
    if before && daemon == DockerDaemonObserved current peer
      then case bridge of
        Right (Just _) -> case currentVolume of
          Right DockerMutationVolumeMissing -> held
          Right (DockerMutationVolumeObserved timestamp) | timestamp == createdAt -> do
            removed <- removeDockerSessionMutationVolume session volume held
            absent <- inspectDockerSessionMutationVolume session volume
            after <- held
            pure
              (removed == DockerNodeVarRemoveReply 204 && absent == Right DockerMutationVolumeMissing && after)
          _ -> pure False
        _ -> pure False
      else pure False
  pure (observed == DockerPeerCompleted (DockerConnectedInfoCompleted True))
