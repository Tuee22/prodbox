{-# LANGUAGE ScopedTypeVariables #-}

-- | One journaled removal attempt for an exactly identified absence control.
-- A transport reply does not prove container or anonymous-volume absence.
module Prodbox.Control.KindAbsenceRemoval
  ( AbsenceRemovalOutcome (..)
  , removeRecordedAbsenceControl
  ) where

import Control.Exception (IOException, SomeException, mask, throwIO, try)
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapRuntimeSocket)
import Prodbox.Control.DockerConnectedInfo
  ( DockerAbsenceControlObservation (..), DockerConnectedInfo (..), DockerConnectedInfoResult (..)
  , DockerNodeContainerCreateResult (..), DockerNodeContainerRemoveResult (..)
  , inspectDockerSessionAbsenceControl, removeDockerSessionKindNode, withConnectedDockerInfo )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..))
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult)
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindAbsencePlan, KindAbsenceIdObservation (..), KindAbsenceFootprintObservation (..)
  , KindAbsenceObservation (..), KindAbsenceStage (..), KindAbsenceWrite (..)
  , kindAbsenceDaemon, kindAbsenceImage, kindAbsenceImageVolumes, kindAbsenceOperation, kindAbsenceTarget
  , observeKindAbsenceStage, recordKindAbsenceStage, recoverKindAbsenceControlId, recoverKindAbsenceFootprint )

data AbsenceRemovalOutcome
  = AbsenceRemovalRecordsUnconfirmed
  | AbsenceRemovalCreateUnconfirmed
  | AbsenceRemovalDaemonMismatch
  | AbsenceRemovalInspectionUnconfirmed
  | AbsenceRemovalAttempt !KindAbsenceWrite
  | AbsenceRemovalPriorResult !KindAbsenceObservation
  | AbsenceRemovalReturned !DockerNodeContainerRemoveResult !KindAbsenceWrite !Bool
  deriving (Eq, Show)

-- A 201 create reply for this exact ID is required here. A lost create reply
-- needs a separate ownership proof and is deliberately not adopted by name.
-- The owner check must cover the whole borrowed family-retirement lifetime.
removeRecordedAbsenceControl
  :: BootstrapProjection -> KindAbsencePlan -> (IO Bool -> IO Bool)
  -> IO (KindOperationOutcome (Either AbsenceRemovalOutcome (DockerPeerResult (DockerConnectedInfoResult AbsenceRemovalOutcome))))
removeRecordedAbsenceControl bootstrap plan ownerStable =
  withRecoveredKindOperation bootstrap operation $ \lease -> do
    let stable = do
          before <- lease
          owner <- ownerStable lease
          after <- lease
          pure (before && owner && after)
    control <- recoverKindAbsenceControlId bootstrap plan stable
    case control of
      AbsenceIdObserved identifier -> do
        footprint <- recoverKindAbsenceFootprint bootstrap plan identifier stable
        case footprint of
          AbsenceFootprintObserved volumes -> do
            created <- observeKindAbsenceStage bootstrap plan
              (AbsenceCreateResult (DockerNodeContainerCreateReply 201 (Just identifier))) stable
            if created /= AbsenceMatches then pure (Left AbsenceRemovalCreateUnconfirmed) else
              Right <$> withConnectedDockerInfo 120000000 (bootstrapRuntimeSocket bootstrap)
                (connected stable identifier volumes)
          _ -> pure (Left AbsenceRemovalRecordsUnconfirmed)
      _ -> pure (Left AbsenceRemovalRecordsUnconfirmed)
 where
  operation = kindAbsenceOperation plan
  connected stable identifier volumes session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) peerStable = do
    let live = (&&) <$> stable <*> peerStable
        inspect = do
          before <- live
          observed <- inspectDockerSessionAbsenceControl session bootstrap operation (kindAbsenceTarget plan)
            (kindAbsenceImage plan) (kindAbsenceImageVolumes plan) (Just identifier)
          after <- live
          pure (before && after && observed == Right (DockerAbsenceControlMatching identifier volumes))
        attempt = AbsenceRemoveAttempt identifier volumes
        result value = AbsenceRemoveResult identifier volumes value
    if DockerDaemonObserved daemon identity /= kindAbsenceDaemon plan
      then pure AbsenceRemovalDaemonMismatch else do
        valid <- try inspect
        case (valid :: Either IOException Bool) of
          Right True -> mask $ \restore -> do
            written <- recordKindAbsenceStage bootstrap plan attempt live
            case written of
              AbsenceRecorded -> do
                prior <- observeKindAbsenceStage bootstrap plan (result DockerNodeContainerRemoveUnconfirmed) live
                if prior /= AbsenceMissing then pure (AbsenceRemovalPriorResult prior) else do
                  let beforeEffect = do
                        marker <- observeKindAbsenceStage bootstrap plan attempt live
                        current <- inspect
                        pure (marker == AbsenceMatches && current)
                      afterEffect = (== AbsenceMatches) <$> observeKindAbsenceStage bootstrap plan attempt live
                  outcome <- try (restore (removeDockerSessionKindNode session identifier beforeEffect afterEffect))
                  let disposition = either (const DockerNodeContainerRemoveUnconfirmed) id
                        (outcome :: Either SomeException DockerNodeContainerRemoveResult)
                  receipt <- recordKindAbsenceStage bootstrap plan (result disposition) live
                  closing <- try live
                  let held = either (const False) id (closing :: Either IOException Bool)
                  case outcome of
                    Left failure -> throwIO failure
                    Right _ -> pure (AbsenceRemovalReturned disposition receipt held)
              other -> pure (AbsenceRemovalAttempt other)
          _ -> pure AbsenceRemovalInspectionUnconfirmed
