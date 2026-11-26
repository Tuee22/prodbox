{-# LANGUAGE ScopedTypeVariables #-}

-- | One non-forced removal attempt for a recorded residual control volume.
-- Presence, a transport reply and this journal do not establish absence.
module Prodbox.Control.KindAbsenceVolumeRemoval
  ( AbsenceVolumeRemovalOutcome (..)
  , AbsenceVolumeRecoveryObservation (..)
  , removeResidualAbsenceVolume
  , observeResidualAbsenceVolumeRecovery
  ) where

import Control.Exception (IOException, SomeException, mask, throwIO, try)
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapRuntimeSocket)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoResult (..)
  , DockerNodeVarRemoveResult (..)
  , removeDockerSessionAbsenceVolume
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..))
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult)
import Prodbox.Control.KindAbsenceVolumeReadback
  ( AbsenceVolumePhase (AbsenceVolumesAfterRemoval)
  , AbsenceVolumeReadback (..)
  , observeAbsenceControlVolumesUnderLease
  )
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindAbsenceFootprintObservation (..)
  , KindAbsenceIdObservation (..)
  , KindAbsenceObservation (..)
  , KindAbsencePlan
  , KindAbsenceStage (..)
  , KindAbsenceVolumeResultObservation
  , KindAbsenceWrite (..)
  , kindAbsenceDaemon
  , kindAbsenceOperation
  , observeKindAbsenceStage
  , recordKindAbsenceStage
  , recoverKindAbsenceControlId
  , recoverKindAbsenceFootprint
  , recoverKindAbsenceVolumeResult
  )

data AbsenceVolumeRemovalOutcome
  = AbsenceVolumeRemovalRecordsUnconfirmed
  | AbsenceVolumeRemovalNotResidual !AbsenceVolumeReadback
  | AbsenceVolumeRemovalDaemonMismatch
  | AbsenceVolumeRemovalAttempt !KindAbsenceWrite
  | AbsenceVolumeRemovalPriorResult !KindAbsenceObservation
  | AbsenceVolumeRemovalReturned !DockerNodeVarRemoveResult !KindAbsenceWrite !Bool
  deriving (Eq, Show)

data AbsenceVolumeRecoveryObservation
  = AbsenceVolumeRecoveryRecordsUnconfirmed
  | AbsenceVolumeRecoveryObserved !KindAbsenceVolumeResultObservation !AbsenceVolumeReadback !Bool
  deriving (Eq, Show)

-- A recovery observation does not settle a prior Docker request or permit
-- another removal. It retains the local result and inventory independently.
observeResidualAbsenceVolumeRecovery
  :: BootstrapProjection
  -> KindAbsencePlan
  -> String
  -> (IO Bool -> IO Bool)
  -> IO (KindOperationOutcome AbsenceVolumeRecoveryObservation)
observeResidualAbsenceVolumeRecovery bootstrap plan volume ownerStable =
  withRecoveredKindOperation bootstrap (kindAbsenceOperation plan) $ \lease -> do
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
          AbsenceFootprintObserved volumes | volume `elem` map snd volumes -> do
            result <- recoverKindAbsenceVolumeResult bootstrap plan identifier volumes volume stable
            readback <- observeAbsenceControlVolumesUnderLease bootstrap plan AbsenceVolumesAfterRemoval stable
            closing <- try stable
            pure
              ( AbsenceVolumeRecoveryObserved
                  result
                  readback
                  (either (const False) id (closing :: Either IOException Bool))
              )
          _ -> pure AbsenceVolumeRecoveryRecordsUnconfirmed
      _ -> pure AbsenceVolumeRecoveryRecordsUnconfirmed

-- The stable callback must hold the family-retirement owner throughout the
-- operation. The independent residual observation includes a positive node
-- volume and refuses attached or changing control volumes.
removeResidualAbsenceVolume
  :: BootstrapProjection
  -> KindAbsencePlan
  -> String
  -> (IO Bool -> IO Bool)
  -> IO
       ( KindOperationOutcome
           ( Either
               AbsenceVolumeRemovalOutcome
               (DockerPeerResult (DockerConnectedInfoResult AbsenceVolumeRemovalOutcome))
           )
       )
removeResidualAbsenceVolume bootstrap plan volume ownerStable =
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
          AbsenceFootprintObserved volumes | volume `elem` map snd volumes -> do
            observed <- observeAbsenceControlVolumesUnderLease bootstrap plan AbsenceVolumesAfterRemoval stable
            case observed of
              AbsenceVolumeResidual residual
                | volume `elem` residual ->
                    Right
                      <$> withConnectedDockerInfo
                        180000000
                        (bootstrapRuntimeSocket bootstrap)
                        (connected stable identifier volumes)
              _ -> pure (Left (AbsenceVolumeRemovalNotResidual observed))
          _ -> pure (Left AbsenceVolumeRemovalRecordsUnconfirmed)
      _ -> pure (Left AbsenceVolumeRemovalRecordsUnconfirmed)
 where
  operation = kindAbsenceOperation plan
  connected stable identifier volumes session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) peerStable = do
    let live = (&&) <$> stable <*> peerStable
        attempt = AbsenceVolumeRemoveAttempt identifier volumes volume
        result value = AbsenceVolumeRemoveResult identifier volumes volume value
    if DockerDaemonObserved daemon identity /= kindAbsenceDaemon plan
      then pure AbsenceVolumeRemovalDaemonMismatch
      else mask $ \restore -> do
        written <- recordKindAbsenceStage bootstrap plan attempt live
        case written of
          AbsenceRecorded -> do
            prior <- observeKindAbsenceStage bootstrap plan (result DockerNodeVarRemoveUnconfirmed) live
            if prior /= AbsenceMissing
              then pure (AbsenceVolumeRemovalPriorResult prior)
              else do
                let beforeEffect = do
                      marker <- observeKindAbsenceStage bootstrap plan attempt live
                      current <- observeAbsenceControlVolumesUnderLease bootstrap plan AbsenceVolumesAfterRemoval live
                      pure
                        ( marker == AbsenceMatches && case current of
                            AbsenceVolumeResidual residual -> volume `elem` residual
                            _ -> False
                        )
                    afterEffect = (== AbsenceMatches) <$> observeKindAbsenceStage bootstrap plan attempt live
                outcome <- try (restore (removeDockerSessionAbsenceVolume session volume beforeEffect afterEffect))
                let disposition =
                      either
                        (const DockerNodeVarRemoveUnconfirmed)
                        id
                        (outcome :: Either SomeException DockerNodeVarRemoveResult)
                receipt <- recordKindAbsenceStage bootstrap plan (result disposition) live
                closing <- try live
                let held = either (const False) id (closing :: Either IOException Bool)
                case outcome of
                  Left failure -> throwIO failure
                  Right _ -> pure (AbsenceVolumeRemovalReturned disposition receipt held)
          other -> pure (AbsenceVolumeRemovalAttempt other)
