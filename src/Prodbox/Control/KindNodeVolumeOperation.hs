{-# LANGUAGE ScopedTypeVariables #-}

-- | Connect one durable volume attempt to a bounded transport result. This
-- is not admission, daemon authentication, resource ownership, settlement,
-- cleanup, or permission to invoke a provider effect.
module Prodbox.Control.KindNodeVolumeOperation
  ( KindNodeVolumeAction (..)
  , withNewConnectedKindNodeVolumeAttempt
  , withNewConnectedKindNodeVolumeAttemptGuarded
  , KindNodeVolumeRemovalAction (..)
  , withNewConnectedKindNodeVolumeRemoval
  , withNewConnectedKindNodeVolumeRemovalGuarded
  ) where

import Control.Exception (IOException, try)
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapRuntimeSocket)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoResult
  , DockerNodeVarCreateResult
  , DockerNodeVarRemoveResult
  , DockerNodeVarVolumeObservation (..)
  , DockerSession
  , inspectDockerSessionNodeVarVolume
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (DockerDaemonObserved))
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult)
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeAttemptObservation (..)
  , KindNodeVolumeAttemptWrite (..)
  , KindNodeVolumeIntentObservation (..)
  , KindNodeVolumeReceiptObservation (..)
  , KindNodeVolumeReceiptWrite (..)
  , KindNodeVolumeRemovalObservation (..)
  , KindNodeVolumeRemovalReceiptObservation (..)
  , KindNodeVolumeRemovalReceiptWrite (..)
  , KindNodeVolumeRemovalWrite (..)
  , mkKindNodeVolumeIntent
  , observeKindNodeVolumeAttempt
  , observeKindNodeVolumeIntent
  , observeKindNodeVolumeReceipt
  , observeKindNodeVolumeRemoval
  , observeKindNodeVolumeRemovalReceipt
  , recordKindNodeVolumeAttempt
  , recordKindNodeVolumeReceipt
  , recordKindNodeVolumeRemoval
  , recordKindNodeVolumeRemovalReceipt
  )

data KindNodeVolumeAction
  = NodeVolumeActionInvalid
  | NodeVolumeActionProposalRefused !KindNodeVolumeIntentObservation
  | NodeVolumeActionAttemptRefused !KindNodeVolumeAttemptWrite
  | NodeVolumeActionReceiptRefused !KindNodeVolumeReceiptObservation
  | NodeVolumeActionChanged
  | NodeVolumeActionReturned !DockerNodeVarCreateResult !KindNodeVolumeReceiptWrite
  | NodeVolumeActionChangedAfter !DockerNodeVarCreateResult !KindNodeVolumeReceiptWrite
  deriving (Eq, Show)

-- An existing marker never reaches the callback. The caller still owes effect
-- admission, daemon authentication, worker settlement and cleanup.
withNewConnectedKindNodeVolumeAttempt
  :: BootstrapProjection
  -> String
  -> (DockerSession -> IO Bool -> IO DockerNodeVarCreateResult)
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNodeVolumeAction)))
withNewConnectedKindNodeVolumeAttempt bootstrap operation =
  withNewConnectedKindNodeVolumeAttemptGuarded bootstrap operation id

-- Admission is rechecked along with the lease and Docker peer before the
-- attempt marker, effect and receipt. The caller retains the family owner.
withNewConnectedKindNodeVolumeAttemptGuarded
  :: BootstrapProjection
  -> String
  -> (IO Bool -> IO Bool)
  -> (DockerSession -> IO Bool -> IO DockerNodeVarCreateResult)
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNodeVolumeAction)))
withNewConnectedKindNodeVolumeAttemptGuarded bootstrap operation admission action =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      let stable = (&&) <$> admission operationStable <*> peerStable
      case mkKindNodeVolumeIntent operation (DockerDaemonObserved identifier identity) of
        Nothing -> pure NodeVolumeActionInvalid
        Just intent -> do
          proposal <- observeKindNodeVolumeIntent bootstrap intent stable
          case proposal of
            NodeVolumeIntentMatches -> do
              written <- recordKindNodeVolumeAttempt bootstrap intent stable
              case written of
                NodeVolumeAttemptRecorded -> do
                  let markerStable = (== NodeVolumeAttemptMatches) <$> observeKindNodeVolumeAttempt bootstrap intent stable
                  prior <- observeKindNodeVolumeReceipt bootstrap intent markerStable
                  case prior of
                    NodeVolumeReceiptMissing -> do
                      ready <- markerStable
                      if not ready
                        then pure NodeVolumeActionChanged
                        else do
                          result <- action session markerStable
                          receipt <- recordKindNodeVolumeReceipt bootstrap intent result markerStable
                          after <- try markerStable
                          pure $ case (after :: Either IOException Bool) of
                            Right True -> NodeVolumeActionReturned result receipt
                            _ -> NodeVolumeActionChangedAfter result receipt
                    other -> pure (NodeVolumeActionReceiptRefused other)
                other -> pure (NodeVolumeActionAttemptRefused other)
            other -> pure (NodeVolumeActionProposalRefused other)

-- Matching labels or a response are not ownership proof. The supplied
-- admission must independently establish exact ownership, settled workers,
-- no remaining users and permission for this operation.
data KindNodeVolumeRemovalAction
  = NodeVolumeRemovalActionInvalid
  | NodeVolumeRemovalActionProposalRefused !KindNodeVolumeIntentObservation
  | NodeVolumeRemovalActionAttemptRefused !KindNodeVolumeAttemptObservation
  | NodeVolumeRemovalActionConfigurationRefused
  | NodeVolumeRemovalActionAdmissionRefused
  | NodeVolumeRemovalActionMarkerRefused !KindNodeVolumeRemovalWrite
  | NodeVolumeRemovalActionReceiptRefused !KindNodeVolumeRemovalReceiptObservation
  | NodeVolumeRemovalActionChanged
  | NodeVolumeRemovalActionReturned !DockerNodeVarRemoveResult !KindNodeVolumeRemovalReceiptWrite
  | NodeVolumeRemovalActionChangedAfter !DockerNodeVarRemoveResult !KindNodeVolumeRemovalReceiptWrite
  deriving (Eq, Show)

withNewConnectedKindNodeVolumeRemoval
  :: BootstrapProjection
  -> String
  -> (DockerSession -> IO Bool -> IO Bool)
  -> (DockerSession -> IO Bool -> IO DockerNodeVarRemoveResult)
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNodeVolumeRemovalAction)))
withNewConnectedKindNodeVolumeRemoval bootstrap operation =
  withNewConnectedKindNodeVolumeRemovalGuarded bootstrap operation id

withNewConnectedKindNodeVolumeRemovalGuarded
  :: BootstrapProjection
  -> String
  -> (IO Bool -> IO Bool)
  -> (DockerSession -> IO Bool -> IO Bool)
  -> (DockerSession -> IO Bool -> IO DockerNodeVarRemoveResult)
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNodeVolumeRemovalAction)))
withNewConnectedKindNodeVolumeRemovalGuarded bootstrap operation settlementStable admit action =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      let stable = settlementStable ((&&) <$> operationStable <*> peerStable)
      case mkKindNodeVolumeIntent operation (DockerDaemonObserved identifier identity) of
        Nothing -> pure NodeVolumeRemovalActionInvalid
        Just intent -> do
          proposal <- observeKindNodeVolumeIntent bootstrap intent stable
          case proposal of
            NodeVolumeIntentMatches -> do
              attempt <- observeKindNodeVolumeAttempt bootstrap intent stable
              case attempt of
                NodeVolumeAttemptMatches -> do
                  volume <- inspectDockerSessionNodeVarVolume session bootstrap operation
                  if volume /= Right DockerNodeVarVolumeMatching
                    then pure NodeVolumeRemovalActionConfigurationRefused
                    else do
                      admitted <- try (admit session stable)
                      case (admitted :: Either IOException Bool) of
                        Right True -> do
                          written <- recordKindNodeVolumeRemoval bootstrap intent stable
                          case written of
                            NodeVolumeRemovalRecorded -> do
                              let markerStable = do
                                    marker <- observeKindNodeVolumeRemoval bootstrap intent stable
                                    if marker /= NodeVolumeRemovalMatches
                                      then pure False
                                      else do
                                        allowed <- admit session stable
                                        afterAdmission <- stable
                                        pure (allowed && afterAdmission)
                              prior <- observeKindNodeVolumeRemovalReceipt bootstrap intent markerStable
                              case prior of
                                NodeVolumeRemovalReceiptMissing -> do
                                  ready <- markerStable
                                  if not ready
                                    then pure NodeVolumeRemovalActionChanged
                                    else do
                                      result <- action session markerStable
                                      receipt <- recordKindNodeVolumeRemovalReceipt bootstrap intent result markerStable
                                      after <- try markerStable
                                      pure $ case (after :: Either IOException Bool) of
                                        Right True -> NodeVolumeRemovalActionReturned result receipt
                                        _ -> NodeVolumeRemovalActionChangedAfter result receipt
                                other -> pure (NodeVolumeRemovalActionReceiptRefused other)
                            other -> pure (NodeVolumeRemovalActionMarkerRefused other)
                        _ -> pure NodeVolumeRemovalActionAdmissionRefused
                other -> pure (NodeVolumeRemovalActionAttemptRefused other)
            other -> pure (NodeVolumeRemovalActionProposalRefused other)
