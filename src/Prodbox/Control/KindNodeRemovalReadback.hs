{-# LANGUAGE ScopedTypeVariables #-}

-- | Repeated independent Docker CLI inventory after a retained node-removal
-- attempt. A sample is not proof of daemon authenticity, ownership, worker
-- settlement or exact absence.
module Prodbox.Control.KindNodeRemovalReadback
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , parseNodeRemovalInventory
  , classifyNodeRemovalReadback
  , observeIndependentNodeRemoval
  , observeRecordedNodeAbsent
  , observeProposedNodeNameAbsent
  , observeNodeRemovalPositiveControl
  , confirmRecordedRemovalReadback
  , nodeRemovalPositive
  , priorNodeRemovalRecorded
  ) where

import Control.Exception (IOException, try)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoResult (..)
  , DockerNodeContainerCreateResult (DockerNodeContainerCreateReply)
  , DockerNodeContainerRemoveResult (DockerNodeContainerRemoveReply)
  , readDockerSessionContainerNotFound
  , readDockerSessionKindContainers
  , readDockerSessionKindNodeNameNotFound
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , observeDockerDaemon
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..))
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateIntent
  , KindNodeCreateRecoveryObservation (NodeCreateRecoveryRecorded)
  , KindNodeCreateResultObservation (NodeCreateResultObserved)
  , KindNodeRemoveAttemptObservation (NodeRemoveAttemptMatches, NodeRemoveAttemptMissing)
  , KindNodeRemoveControlObservation (NodeRemoveControlMatches)
  , KindNodeRemovePass (..)
  , KindNodeRemoveResultObservation (..)
  , kindNodeCreateDaemon
  , observeKindNodeCreateResult
  , observeKindNodeRemoveAttempt
  , observeKindNodeRemoveAttemptFor
  , observeKindNodeRemoveControl
  , observeKindNodeRemoveResultFor
  , observeRecordedKindNodeCreateIntent
  )
import Prodbox.Control.KindNodeRemovalSampling
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , classifyNodeRemovalReadback
  , nodeRemovalInventoryEmpty
  , nodeRemovalPositive
  , observeNodeRemovalPositiveControl
  , parseNodeRemovalInventory
  , sampleNodeRemoval
  )
import System.Timeout (timeout)

priorNodeRemovalRecorded :: KindNodeRemoveResultObservation -> Bool
priorNodeRemovalRecorded receipt = case receipt of
  NodeRemoveResultObserved (DockerNodeContainerRemoveReply 204) -> True
  _ -> False

-- | Inspect the deterministic name and the selected cluster label on the
-- daemon bound to the proposal. The caller retains the operation, retirement
-- owner and evidence that no create attempt was sent.
observeProposedNodeNameAbsent :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO Bool
observeProposedNodeNameAbsent bootstrap intent held = do
  observed <-
    withConnectedDockerInfo 15000000 (bootstrapRuntimeSocket bootstrap) $
      \session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) peerStable -> do
        before <- held
        if before && DockerDaemonObserved daemon identity == kindNodeCreateDaemon intent
          then do
            let scope = bootstrapScope bootstrap
            byLabel <- readDockerSessionKindContainers session scope
            byName <- readDockerSessionKindNodeNameNotFound session scope
            peer <- peerStable
            closing <- held
            pure (byLabel == Right [] && byName && peer && closing)
          else pure False
  pure (observed == DockerPeerCompleted (DockerConnectedInfoCompleted True))

-- | The caller holds the exact operation lease and retirement owner. The
-- prior positive control and one admitted successful removal bind the ID.
-- Independently require empty scoped inventories and the exact-ID response.
observeRecordedNodeAbsent
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO Bool
observeRecordedNodeAbsent bootstrap intent identifier held = do
  let expectedDaemon = kindNodeCreateDaemon intent
  control <- observeKindNodeRemoveControl bootstrap intent identifier held
  initial <- observeKindNodeRemoveResultFor InitialNodeRemoval bootstrap intent identifier held
  confirmed <-
    if priorNodeRemovalRecorded initial
      then
        (== NodeRemoveAttemptMissing)
          <$> observeKindNodeRemoveAttemptFor RetryNodeRemoval bootstrap intent identifier held
      else case initial of
        NodeRemoveResultMissing ->
          priorNodeRemovalRecorded
            <$> observeKindNodeRemoveResultFor RetryNodeRemoval bootstrap intent identifier held
        _ -> pure False
  before <- held
  if not (before && control == NodeRemoveControlMatches && confirmed)
    then pure False
    else do
      inventory <- observeNodeRemovalPositiveControl bootstrap expectedDaemon identifier held
      confirmRecordedRemovalReadback inventory $ do
        exact <- withConnectedDockerInfo 15000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) peerStable -> do
          missing <- readDockerSessionContainerNotFound session identifier
          peer <- peerStable
          closing <- held
          pure (DockerDaemonObserved daemon identity == expectedDaemon && missing && peer && closing)
        pure (exact == DockerPeerCompleted (DockerConnectedInfoCompleted True))

-- After a bound receipt, require both independent absence observations.
confirmRecordedRemovalReadback :: NodeRemovalReadback -> IO Bool -> IO Bool
confirmRecordedRemovalReadback inventory exactAbsence =
  if nodeRemovalInventoryEmpty inventory then exactAbsence else pure False

-- The recovered proposal, successful create ID and removal marker bind the
-- query. A missing create result or marker does not imply resource absence.
observeIndependentNodeRemoval
  :: BootstrapProjection -> String -> IO (KindOperationOutcome NodeRemovalReadback)
observeIndependentNodeRemoval bootstrap operation =
  withRecoveredKindOperation bootstrap operation $ \operationStable -> do
    observed <- timeout 30000000 $ do
      before <- observeDockerDaemon socket
      proposal <- observeRecordedKindNodeCreateIntent bootstrap operation operationStable
      case proposal of
        NodeCreateRecoveryRecorded intent
          | before == kindNodeCreateDaemon intent -> do
              created <- observeKindNodeCreateResult bootstrap intent operationStable
              case created of
                NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just identifier)) -> do
                  let stable = do
                        lease <- operationStable
                        marker <- observeKindNodeRemoveAttempt bootstrap intent identifier operationStable
                        final <- operationStable
                        pure (lease && marker == NodeRemoveAttemptMatches && final)
                  ready <- try stable
                  case (ready :: Either IOException Bool) of
                    Left _ -> pure NodeRemovalReadbackUnobservable
                    Right False -> pure NodeRemovalReadbackRecordUnavailable
                    Right True -> do
                      first <- sampleNodeRemoval bootstrap identifier
                      second <- sampleNodeRemoval bootstrap identifier
                      after <- observeDockerDaemon socket
                      final <- try stable
                      pure
                        ( classifyNodeRemovalReadback
                            before
                            after
                            (either (const Nothing) Just (final :: Either IOException Bool))
                            first
                            second
                        )
                _ -> pure NodeRemovalReadbackRecordUnavailable
        NodeCreateRecoveryRecorded intent -> case before of
          DockerDaemonObserved _ _ | before /= kindNodeCreateDaemon intent -> pure NodeRemovalReadbackChanged
          DockerDaemonChanged -> pure NodeRemovalReadbackChanged
          _ -> pure NodeRemovalReadbackUnobservable
        _ -> pure NodeRemovalReadbackRecordUnavailable
    pure (maybe NodeRemovalReadbackUnobservable id observed)
 where
  socket = bootstrapRuntimeSocket bootstrap
