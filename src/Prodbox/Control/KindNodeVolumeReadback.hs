{-# LANGUAGE ScopedTypeVariables #-}

-- | Independent, bounded Docker CLI observations for a retained volume
-- removal. Neither an empty result nor matching daemon IDs prove absence,
-- ownership, daemon authenticity, admission or worker settlement.
module Prodbox.Control.KindNodeVolumeReadback
  ( NodeVolumeInventory (..)
  , NodeVolumeReadback (..)
  , parseNodeVolumeInventory
  , classifyNodeVolumeReadback
  , observeIndependentNodeVolume
  ) where

import Control.Exception (IOException, try)
import Data.Char (isAscii, isPrint)
import Data.List (nub, sort)
import Data.Text qualified as Text
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapKindPlan
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  )
import Prodbox.Config.KindPlan (kindNodeVarVolumeName)
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , observeDockerDaemon
  , readDocker
  )
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeIntentObservation (NodeVolumeIntentMatches)
  , KindNodeVolumeRemovalObservation (NodeVolumeRemovalMatches)
  , mkKindNodeVolumeIntent
  , observeKindNodeVolumeIntent
  , observeKindNodeVolumeRemoval
  )
import System.Timeout (timeout)

data NodeVolumeInventory = NodeVolumeInventory
  { nodeVolumeListed :: !Bool
  , nodeVolumeContainerIds :: ![String]
  }
  deriving (Eq, Show)

data NodeVolumeReadback
  = NodeVolumeReadbackRecordUnavailable
  | NodeVolumeReadbackUnobservable
  | NodeVolumeReadbackChanged
  | NodeVolumeReadbackSampled !NodeVolumeInventory
  deriving (Eq, Show)

-- Volume inventory is unfiltered and interpreted locally. A returned container
-- list is only a point observation of the daemon's volume filter.
parseNodeVolumeInventory :: String -> String -> String -> Maybe NodeVolumeInventory
parseNodeVolumeInventory expected volumeOutput containerOutput = do
  let names = lines volumeOutput
      identifiers = lines containerOutput
      safeName value = not (null value) && length value <= 1024 && all (\c -> isAscii c && isPrint c && c /= ' ') value
  if length names > 4096
    || any (not . safeName) names
    || length names /= length (nub names)
    || length identifiers > 4096
    || any (not . validImageId . ("sha256:" ++)) identifiers
    || length identifiers /= length (nub identifiers)
    then Nothing
    else Just (NodeVolumeInventory (expected `elem` names) (sort identifiers))

-- Failure to observe the daemon or retained record is not evidence that it
-- changed. Only a definite daemon or inventory difference is a change.
classifyNodeVolumeReadback
  :: DockerDaemonObservation
  -> DockerDaemonObservation
  -> Maybe Bool
  -> Maybe NodeVolumeInventory
  -> Maybe NodeVolumeInventory
  -> NodeVolumeReadback
classifyNodeVolumeReadback before after stable first second = case (before, after, stable) of
  (DockerDaemonObserved _ _, DockerDaemonChanged, _) -> NodeVolumeReadbackChanged
  (DockerDaemonObserved _ _, DockerDaemonObserved _ _, Just True)
    | before /= after -> NodeVolumeReadbackChanged
    | otherwise -> case (first, second) of
        (Just a, Just b) | a == b -> NodeVolumeReadbackSampled a
        (Just _, Just _) -> NodeVolumeReadbackChanged
        _ -> NodeVolumeReadbackUnobservable
  _ -> NodeVolumeReadbackUnobservable

-- Uses the explicit selected socket, a recovered operation lease and repeated
-- daemon identity and inventory reads. This has no mutation capability.
observeIndependentNodeVolume
  :: BootstrapProjection -> String -> IO (KindOperationOutcome NodeVolumeReadback)
observeIndependentNodeVolume bootstrap operation =
  withRecoveredKindOperation bootstrap operation $ \operationStable -> do
    result <- timeout 30000000 $ do
      before <- observeDockerDaemon socket
      case (before, kindNodeVarVolumeName (bootstrapKindPlan bootstrap) generation operation) of
        (observed@(DockerDaemonObserved _ _), Just name) -> case mkKindNodeVolumeIntent operation observed of
          Nothing -> pure NodeVolumeReadbackRecordUnavailable
          Just intent -> do
            let stable = do
                  lease <- operationStable
                  proposal <- observeKindNodeVolumeIntent bootstrap intent operationStable
                  removal <- observeKindNodeVolumeRemoval bootstrap intent operationStable
                  final <- operationStable
                  pure (lease && proposal == NodeVolumeIntentMatches && removal == NodeVolumeRemovalMatches && final)
            ready <- try stable
            case (ready :: Either IOException Bool) of
              Left _ -> pure NodeVolumeReadbackUnobservable
              Right False -> pure NodeVolumeReadbackRecordUnavailable
              Right True -> do
                first <- sample name
                second <- sample name
                after <- observeDockerDaemon socket
                final <- try stable
                pure
                  ( classifyNodeVolumeReadback
                      before
                      after
                      (either (const Nothing) Just (final :: Either IOException Bool))
                      first
                      second
                  )
        _ -> pure NodeVolumeReadbackUnobservable
    pure (maybe NodeVolumeReadbackUnobservable id result)
 where
  socket = bootstrapRuntimeSocket bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  sample name = do
    volumes <- readDocker socket ["volume", "ls", "--quiet"]
    containers <-
      readDocker
        socket
        ["ps", "--all", "--no-trunc", "--filter", "volume=" ++ name, "--format", "{{.ID}}"]
    pure $ do
      volumeOutput <- volumes
      containerOutput <- containers
      parseNodeVolumeInventory name volumeOutput containerOutput
