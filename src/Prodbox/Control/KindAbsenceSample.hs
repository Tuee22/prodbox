{-# LANGUAGE ScopedTypeVariables #-}

-- | Compose the independent absence-control observations while holding one
-- operation lease and a borrowed family-retirement owner. This is not a
-- terminal cleanup receipt or authorization to remove any resource.
module Prodbox.Control.KindAbsenceSample
  ( AbsenceSampleOutcome (..)
  , recordObservedAbsenceSample
  ) where

import Control.Exception (IOException, try)
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapRuntimeSocket)
import Prodbox.Control.DockerConnectedInfo
  ( DockerAbsenceControlObservation (..), DockerConnectedInfo (..), DockerConnectedInfoResult (..)
  , inspectDockerSessionAbsenceControl, withConnectedDockerInfo )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..))
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..))
import Prodbox.Control.KindAbsenceNodeReadback
  ( AbsenceNodeReadback (..), observeAbsenceNodeUnderLease )
import Prodbox.Control.KindAbsenceVolumeReadback
  ( AbsenceVolumePhase (AbsenceVolumesBeforeRemoval), AbsenceVolumeReadback (..)
  , observeAbsenceControlVolumesUnderLease )
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindAbsencePlan, KindAbsenceIdObservation (..), KindAbsenceFootprintObservation (..)
  , KindAbsenceStage (..), KindAbsenceWrite (..)
  , kindAbsenceDaemon, kindAbsenceImage, kindAbsenceImageVolumes, kindAbsenceOperation, kindAbsenceTarget
  , recoverKindAbsenceControlId, recoverKindAbsenceFootprint, recordKindAbsenceStage )

data AbsenceSampleOutcome
  = AbsenceSampleRecordsUnconfirmed
  | AbsenceSampleControlUnconfirmed
  | AbsenceSampleNodeUnconfirmed !AbsenceNodeReadback
  | AbsenceSampleVolumesUnconfirmed !AbsenceVolumeReadback
  | AbsenceSampleWrite !KindAbsenceWrite !Bool
  deriving (Eq, Show)

recordObservedAbsenceSample
  :: BootstrapProjection -> KindAbsencePlan -> (IO Bool -> IO Bool)
  -> IO (KindOperationOutcome AbsenceSampleOutcome)
recordObservedAbsenceSample bootstrap plan ownerStable =
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
          AbsenceFootprintObserved volumes -> capture stable identifier volumes
          _ -> pure AbsenceSampleRecordsUnconfirmed
      _ -> pure AbsenceSampleRecordsUnconfirmed
 where
  operation = kindAbsenceOperation plan
  capture stable identifier volumes = do
    firstControl <- inspect stable identifier volumes
    if not firstControl then pure AbsenceSampleControlUnconfirmed else do
      node <- observeAbsenceNodeUnderLease bootstrap plan stable
      case node of
        AbsenceNodeSampled firstNode -> do
          volume <- observeAbsenceControlVolumesUnderLease bootstrap plan AbsenceVolumesBeforeRemoval stable
          case volume of
            AbsenceVolumeSampled _ -> do
              finalNode <- observeAbsenceNodeUnderLease bootstrap plan stable
              if finalNode /= AbsenceNodeSampled firstNode then pure (AbsenceSampleNodeUnconfirmed finalNode) else do
                finalControl <- inspect stable identifier volumes
                if not finalControl then pure AbsenceSampleControlUnconfirmed else do
                  written <- recordKindAbsenceStage bootstrap plan (AbsenceControlSampled identifier volumes) stable
                  closing <- try stable
                  pure (AbsenceSampleWrite written (either (const False) id (closing :: Either IOException Bool)))
            other -> pure (AbsenceSampleVolumesUnconfirmed other)
        other -> pure (AbsenceSampleNodeUnconfirmed other)
  inspect stable identifier volumes = do
    result <- withConnectedDockerInfo 5000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) peerStable -> do
      before <- stable
      observed <- inspectDockerSessionAbsenceControl session bootstrap operation (kindAbsenceTarget plan)
        (kindAbsenceImage plan) (kindAbsenceImageVolumes plan) (Just identifier)
      after <- stable
      peer <- peerStable
      pure (before && after && peer && DockerDaemonObserved daemon identity == kindAbsenceDaemon plan
        && observed == Right (DockerAbsenceControlMatching identifier volumes))
    pure (result == DockerPeerCompleted (DockerConnectedInfoCompleted True))
