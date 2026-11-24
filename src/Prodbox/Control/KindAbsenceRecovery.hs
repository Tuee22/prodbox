{-# LANGUAGE ScopedTypeVariables #-}

-- | Clean up an already recorded absence control under a borrowed retirement
-- owner. This does not establish terminal node or control-container absence.
module Prodbox.Control.KindAbsenceRecovery
  ( ExistingAbsenceRecovery (..)
  , ExistingAbsenceInterrupted (..)
  , recoverExistingAbsenceControl
  ) where

import Control.Exception (Exception, SomeException, mask, throwIO, try)
import Prodbox.Config.BootstrapProjection (BootstrapProjection)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfoResult (..), DockerNodeContainerRemoveResult (..), DockerNodeVarRemoveResult (..) )
import Prodbox.Control.DockerPeer (DockerPeerResult (..))
import Prodbox.Control.KindAbsenceRemoval (AbsenceRemovalOutcome (..), removeRecordedAbsenceControl)
import Prodbox.Control.KindAbsenceSample (AbsenceSampleOutcome, recordObservedAbsenceSample)
import Prodbox.Control.KindAbsenceVolumeReadback
  ( AbsenceVolumePhase (AbsenceVolumesAfterRemoval), AbsenceVolumeReadback (..), observeAbsenceControlVolumes )
import Prodbox.Control.KindAbsenceVolumeRemoval (AbsenceVolumeRemovalOutcome (..), removeResidualAbsenceVolume)
import Prodbox.Control.KindLease (KindOperationOutcome (..), withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindAbsencePlan, KindAbsenceWrite (AbsenceRecorded), KindAbsenceIdObservation (..)
  , KindAbsenceFootprintObservation (..), KindAbsenceControlResultObservation (..)
  , kindAbsenceOperation, recoverKindAbsenceControlId, recoverKindAbsenceFootprint, recoverKindAbsenceControlResult )

type ControlRemoval = KindOperationOutcome (Either AbsenceRemovalOutcome (DockerPeerResult (DockerConnectedInfoResult AbsenceRemovalOutcome)))
type VolumeRemoval = KindOperationOutcome (Either AbsenceVolumeRemovalOutcome (DockerPeerResult (DockerConnectedInfoResult AbsenceVolumeRemovalOutcome)))

data ExistingAbsenceRecovery = ExistingAbsenceRecovery
  { existingAbsenceSample :: !(KindOperationOutcome AbsenceSampleOutcome)
  , existingAbsenceControlRemoval :: !ControlRemoval
  , existingAbsenceVolumeBefore :: !(Maybe (KindOperationOutcome AbsenceVolumeReadback))
  , existingAbsenceVolumeAttempts :: ![(String, VolumeRemoval)]
  , existingAbsenceVolumeAfter :: !(Maybe (KindOperationOutcome AbsenceVolumeReadback))
  }
  deriving (Show)

-- Keep the primary interruption and any cleanup result or exception together;
-- its rendered message deliberately excludes arbitrary exception contents.
data ExistingAbsenceInterrupted = ExistingAbsenceInterrupted
  !SomeException !(Either SomeException ControlRemoval)

instance Show ExistingAbsenceInterrupted where
  show _ = "absence-control recovery was interrupted; inspect retained cleanup records"

instance Exception ExistingAbsenceInterrupted

recoverExistingAbsenceControl
  :: BootstrapProjection -> KindAbsencePlan -> (IO Bool -> IO Bool) -> IO ExistingAbsenceRecovery
recoverExistingAbsenceControl bootstrap plan ownerStable = mask $ \restore -> do
  sampled <- try (restore (recordObservedAbsenceSample bootstrap plan ownerStable))
  removed <- try (restore (removeRecordedAbsenceControl bootstrap plan ownerStable))
  case (sampled, removed) of
    (Left primary, cleanup) -> throwIO (ExistingAbsenceInterrupted primary cleanup)
    (Right _, Left failure) -> throwIO failure
    (Right sample, Right removal) -> do
      settled <- if controlReplyRecorded removal then pure True else restore priorControlReply
      if not settled
        then pure (ExistingAbsenceRecovery sample removal Nothing [] Nothing)
        else do
          before <- restore (observeAbsenceControlVolumes bootstrap plan AbsenceVolumesAfterRemoval ownerStable)
          case before of
            KindOperationCallbackReturned (AbsenceVolumeResidual volumes) -> do
              attempts <- removeVolumes restore volumes
              after <- restore (observeAbsenceControlVolumes bootstrap plan AbsenceVolumesAfterRemoval ownerStable)
              pure (ExistingAbsenceRecovery sample removal (Just before) attempts (Just after))
            _ -> pure (ExistingAbsenceRecovery sample removal (Just before) [] Nothing)
 where
  priorControlReply = do
    outcome <- withRecoveredKindOperation bootstrap (kindAbsenceOperation plan) $ \lease -> do
      let stable = do
            before <- lease
            owner <- ownerStable lease
            after <- lease
            pure (before && owner && after)
      identifier <- recoverKindAbsenceControlId bootstrap plan stable
      case identifier of
        AbsenceIdObserved control -> do
          footprint <- recoverKindAbsenceFootprint bootstrap plan control stable
          case footprint of
            AbsenceFootprintObserved volumes -> do
              result <- recoverKindAbsenceControlResult bootstrap plan control volumes stable
              closing <- stable
              pure (result == AbsenceControlResultObserved (DockerNodeContainerRemoveReply 204) && closing)
            _ -> pure False
        _ -> pure False
    pure (case outcome of KindOperationCallbackReturned True -> True; _ -> False)
  removeVolumes _ [] = pure []
  removeVolumes restore (volume : rest) = do
    outcome <- restore (removeResidualAbsenceVolume bootstrap plan volume ownerStable)
    if volumeReplyRecorded outcome
      then ((volume, outcome) :) <$> removeVolumes restore rest
      else pure [(volume, outcome)]

controlReplyRecorded :: ControlRemoval -> Bool
controlReplyRecorded result = case result of
  KindOperationCallbackReturned (Right (DockerPeerCompleted (DockerConnectedInfoCompleted
    (AbsenceRemovalReturned (DockerNodeContainerRemoveReply 204) AbsenceRecorded True)))) -> True
  _ -> False

volumeReplyRecorded :: VolumeRemoval -> Bool
volumeReplyRecorded result = case result of
  KindOperationCallbackReturned (Right (DockerPeerCompleted (DockerConnectedInfoCompleted
    (AbsenceVolumeRemovalReturned (DockerNodeVarRemoveReply 204) AbsenceRecorded True)))) -> True
  _ -> False
