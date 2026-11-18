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
  , observeNodeRemovalPositiveControl
  , nodeRemovalPositive
  ) where

import Control.Exception (IOException, try)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  )
import Prodbox.Control.DockerConnectedInfo
  ( DockerNodeContainerCreateResult (DockerNodeContainerCreateReply)
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , observeDockerDaemon
  )
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateRecoveryObservation (NodeCreateRecoveryRecorded)
  , KindNodeCreateResultObservation (NodeCreateResultObserved)
  , KindNodeRemoveAttemptObservation (NodeRemoveAttemptMatches)
  , kindNodeCreateDaemon
  , observeKindNodeCreateResult
  , observeKindNodeRemoveAttempt
  , observeRecordedKindNodeCreateIntent
  )
import Prodbox.Control.KindNodeRemovalSampling
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , classifyNodeRemovalReadback
  , nodeRemovalPositive
  , observeNodeRemovalPositiveControl
  , parseNodeRemovalInventory
  , sampleNodeRemoval
  )
import System.Timeout (timeout)

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
