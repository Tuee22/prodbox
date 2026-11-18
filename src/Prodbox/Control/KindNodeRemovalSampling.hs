{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded Docker inventory samples. These observations do not authenticate
-- the daemon or establish ownership, settlement or absence.
module Prodbox.Control.KindNodeRemovalSampling
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , parseNodeRemovalInventory
  , classifyNodeRemovalReadback
  , observeNodeRemovalPositiveControl
  , nodeRemovalPositive
  , sampleNodeRemoval
  ) where

import Control.Exception (IOException, try)
import Data.List (nub, sort)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName)
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , observeDockerDaemon
  , readDocker
  )
import Prodbox.Control.ImageIdObservation (validImageId)
import System.Timeout (timeout)

data NodeRemovalInventory = NodeRemovalInventory
  { nodeRemovalTargetListed :: !Bool
  , nodeRemovalNameIds :: ![String]
  , nodeRemovalClusterIds :: ![String]
  }
  deriving (Eq, Show)

data NodeRemovalReadback
  = NodeRemovalReadbackRecordUnavailable
  | NodeRemovalReadbackUnobservable
  | NodeRemovalReadbackChanged
  | NodeRemovalReadbackSampled !NodeRemovalInventory
  deriving (Eq, Show)

-- The unfiltered inventory and the two filters are separate point samples.
-- Empty output can be a blind daemon response and is not an absence proof.
parseNodeRemovalInventory :: String -> String -> String -> String -> Maybe NodeRemovalInventory
parseNodeRemovalInventory target allOutput nameOutput clusterOutput = do
  allIds <- parseIds allOutput
  names <- parseIds nameOutput
  clusters <- parseIds clusterOutput
  if validImageId ("sha256:" ++ target)
    then Just (NodeRemovalInventory (target `elem` allIds) names clusters)
    else Nothing
 where
  parseIds output =
    let values = lines output
     in if length values > 4096
          || any (not . validImageId . ("sha256:" ++)) values
          || length values /= length (nub values)
          then Nothing
          else Just (sort values)

classifyNodeRemovalReadback
  :: DockerDaemonObservation
  -> DockerDaemonObservation
  -> Maybe Bool
  -> Maybe NodeRemovalInventory
  -> Maybe NodeRemovalInventory
  -> NodeRemovalReadback
classifyNodeRemovalReadback before after stable first second = case (before, after, stable) of
  (DockerDaemonObserved _ _, DockerDaemonChanged, _) -> NodeRemovalReadbackChanged
  (DockerDaemonObserved _ _, DockerDaemonObserved _ _, Just True)
    | before /= after -> NodeRemovalReadbackChanged
    | otherwise -> case (first, second) of
        (Just a, Just b) | a == b -> NodeRemovalReadbackSampled a
        (Just _, Just _) -> NodeRemovalReadbackChanged
        _ -> NodeRemovalReadbackUnobservable
  _ -> NodeRemovalReadbackUnobservable

-- | Sample independently while the recorded node is still present. This is
-- a control for the three query projections, not daemon authentication,
-- durable evidence, ownership, settlement or authorization to delete.
observeNodeRemovalPositiveControl
  :: BootstrapProjection -> DockerDaemonObservation -> String -> IO Bool -> IO NodeRemovalReadback
observeNodeRemovalPositiveControl bootstrap expectedDaemon identifier stable = do
  result <- timeout 30000000 $ do
    firstStable <- try stable
    before <- observeDockerDaemon (bootstrapRuntimeSocket bootstrap)
    case (firstStable :: Either IOException Bool, before) of
      (Right True, DockerDaemonObserved _ _) | before == expectedDaemon -> do
        first <- sampleNodeRemoval bootstrap identifier
        second <- sampleNodeRemoval bootstrap identifier
        after <- observeDockerDaemon (bootstrapRuntimeSocket bootstrap)
        final <- try stable
        pure
          ( classifyNodeRemovalReadback
              before
              after
              (either (const Nothing) Just (final :: Either IOException Bool))
              first
              second
          )
      (Right True, DockerDaemonObserved _ _) -> pure NodeRemovalReadbackChanged
      (Right True, DockerDaemonChanged) -> pure NodeRemovalReadbackChanged
      _ -> pure NodeRemovalReadbackUnobservable
  pure (maybe NodeRemovalReadbackUnobservable id result)

-- Presence in each projection is required; an extra exact-name match or a
-- blind, unavailable or changing response refuses the positive control.
nodeRemovalPositive :: String -> NodeRemovalReadback -> Bool
nodeRemovalPositive identifier observed = case observed of
  NodeRemovalReadbackSampled sample ->
    nodeRemovalTargetListed sample
      && nodeRemovalNameIds sample == [identifier]
      && identifier `elem` nodeRemovalClusterIds sample
  _ -> False

sampleNodeRemoval :: BootstrapProjection -> String -> IO (Maybe NodeRemovalInventory)
sampleNodeRemoval bootstrap identifier = do
  allIds <- readDocker socket ["ps", "--all", "--no-trunc", "--format", "{{.ID}}"]
  named <-
    readDocker
      socket
      [ "ps"
      , "--all"
      , "--no-trunc"
      , "--filter"
      , "name=^/" ++ cluster ++ "-control-plane$"
      , "--format"
      , "{{.ID}}"
      ]
  labelled <-
    readDocker
      socket
      [ "ps"
      , "--all"
      , "--no-trunc"
      , "--filter"
      , "label=io.x-k8s.kind.cluster=" ++ cluster
      , "--format"
      , "{{.ID}}"
      ]
  pure (parseNodeRemovalInventory identifier <$> allIds <*> named <*> labelled >>= id)
 where
  socket = bootstrapRuntimeSocket bootstrap
  cluster = scopeKindName (bootstrapScope bootstrap)
