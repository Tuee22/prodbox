{-# LANGUAGE ScopedTypeVariables #-}

-- | Read-only candidate discovery for a create whose reply is unavailable.
-- Candidate configuration is not ownership, admission or worker settlement.
module Prodbox.Control.KindNodeCreateReadback
  ( NodeCreateCandidate (..)
  , NodeCreateReadback (..)
  , parseNodeCreateCandidate
  , observeIndependentNodeCreateCandidate
  ) where

import Control.Exception (IOException, try)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoFailure
  , DockerConnectedInfoResult
  , DockerNodeContainerCreateResult (DockerNodeContainerCreateUnconfirmed)
  , DockerNodeContainerObservation
  , inspectDockerSessionKindNode
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , observeDockerDaemon
  , readDocker
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult)
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateAttemptObservation (NodeCreateAttemptMatches)
  , KindNodeCreateRecoveryObservation (NodeCreateRecoveryRecorded)
  , KindNodeCreateResultObservation (..)
  , kindNodeCreateDaemon
  , kindNodeCreateInput
  , observeKindNodeCreateAttempt
  , observeKindNodeCreateResult
  , observeRecordedKindNodeCreateIntent
  )
import Prodbox.Control.KindNodeRemovalSampling
  ( NodeRemovalInventory (..)
  , parseNodeRemovalInventory
  )
import System.Timeout (timeout)

data NodeCreateCandidate = NodeCandidateNone | NodeCandidateUnique !String | NodeCandidateConflict
  deriving (Eq, Show)

data NodeCreateReadback
  = NodeCreateReadbackRecordUnavailable
  | NodeCreateReadbackDaemonMismatch
  | NodeCreateReadbackUnobservable
  | NodeCreateReadbackChanged
  | NodeCreateReadbackSampled
      !NodeCreateCandidate
      !(Maybe (Either DockerConnectedInfoFailure DockerNodeContainerObservation))
  deriving (Eq, Show)

-- The inventory fields are sampled separately. Empty inventories and a
-- unique candidate do not prove absence, provenance or a completed create.
parseNodeCreateCandidate :: String -> String -> String -> Maybe NodeCreateCandidate
parseNodeCreateCandidate allOutput nameOutput clusterOutput = do
  initial <- parseNodeRemovalInventory (replicate 64 '0') allOutput nameOutput clusterOutput
  case (nodeRemovalNameIds initial, nodeRemovalClusterIds initial) of
    ([], []) -> pure NodeCandidateNone
    ([identifier], [labelled]) | identifier == labelled -> do
      candidate <- parseNodeRemovalInventory identifier allOutput nameOutput clusterOutput
      pure
        (if nodeRemovalTargetListed candidate then NodeCandidateUnique identifier else NodeCandidateConflict)
    _ -> pure NodeCandidateConflict

-- This observation is only available for an already recorded attempt with a
-- missing or unconfirmed result. It never records a recovered identity or
-- licenses a retry/removal; the caller must settle the prior request.
observeIndependentNodeCreateCandidate
  :: BootstrapProjection
  -> String
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult NodeCreateReadback)))
observeIndependentNodeCreateCandidate bootstrap operation =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 socket $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      result <- timeout 30000000 $ do
        let stable = (&&) <$> operationStable <*> peerStable
        proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
        case proposal of
          NodeCreateRecoveryRecorded intent
            | kindNodeCreateDaemon intent == DockerDaemonObserved identifier identity -> do
                attempt <- observeKindNodeCreateAttempt bootstrap intent stable
                resultBefore <- observeKindNodeCreateResult bootstrap intent stable
                if attempt /= NodeCreateAttemptMatches || not (uncertain resultBefore)
                  then pure NodeCreateReadbackRecordUnavailable
                  else do
                    daemonBefore <- observeDockerDaemon socket
                    first <- sample
                    second <- sample
                    inspection <- case (first, second) of
                      (Just (NodeCandidateUnique a), Just (NodeCandidateUnique b))
                        | a == b ->
                            Just <$> inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput intent) a
                      _ -> pure Nothing
                    daemonAfter <- observeDockerDaemon socket
                    resultAfter <- observeKindNodeCreateResult bootstrap intent stable
                    final <- try stable
                    pure $ case (final :: Either IOException Bool) of
                      Right True
                        | resultAfter == NodeCreateResultUnobservable -> NodeCreateReadbackUnobservable
                        | resultBefore /= resultAfter -> NodeCreateReadbackChanged
                        | otherwise -> case (daemonBefore, daemonAfter) of
                            (DockerDaemonChanged, _) -> NodeCreateReadbackChanged
                            (_, DockerDaemonChanged) -> NodeCreateReadbackChanged
                            (observed@DockerDaemonObserved {}, later@DockerDaemonObserved {})
                              | observed /= later || observed /= kindNodeCreateDaemon intent -> NodeCreateReadbackChanged
                              | otherwise -> case (first, second) of
                                  (Just a, Just b) | a == b -> NodeCreateReadbackSampled a inspection
                                  (Just _, Just _) -> NodeCreateReadbackChanged
                                  _ -> NodeCreateReadbackUnobservable
                            _ -> NodeCreateReadbackUnobservable
                      _ -> NodeCreateReadbackUnobservable
            | otherwise -> pure NodeCreateReadbackDaemonMismatch
          _ -> pure NodeCreateReadbackRecordUnavailable
      pure (maybe NodeCreateReadbackUnobservable id result)
 where
  socket = bootstrapRuntimeSocket bootstrap
  cluster = scopeKindName (bootstrapScope bootstrap)
  sample = do
    allIds <- readDocker socket ["ps", "--all", "--no-trunc", "--format", "{{.ID}}"]
    names <-
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
    labels <-
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
    pure (parseNodeCreateCandidate <$> allIds <*> names <*> labels >>= id)
  uncertain NodeCreateResultMissing = True
  uncertain (NodeCreateResultObserved DockerNodeContainerCreateUnconfirmed) = True
  uncertain _ = False
