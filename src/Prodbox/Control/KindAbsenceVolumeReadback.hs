{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Independent observations of the absence-control's anonymous volumes.
-- These reads do not establish ownership, retirement or permission to delete.
module Prodbox.Control.KindAbsenceVolumeReadback
  ( AbsenceVolumePhase (..)
  , AbsenceVolumeSample (..)
  , AbsenceVolumeReadback (..)
  , parseAbsenceVolumeSample
  , classifyAbsenceVolumeReadback
  , observeAbsenceControlVolumes
  , observeAbsenceControlVolumesUnderLease
  ) where

import Control.Exception (IOException, try)
import Data.List (nub, sort)
import Data.Text qualified as Text
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapKindPlan
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  )
import Prodbox.Config.KindPlan (kindNodeVarVolumeName)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoResult (..)
  , DockerNodeVarCreateResult (..)
  , DockerNodeVarVolumeObservation (..)
  , inspectDockerSessionNodeVarVolume
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , observeDockerDaemon
  , readDocker
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..))
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindAbsenceFootprintObservation (..)
  , KindAbsenceIdObservation (..)
  , KindAbsenceObservation (..)
  , KindAbsencePlan
  , KindAbsenceStage (..)
  , kindAbsenceDaemon
  , kindAbsenceOperation
  , observeKindAbsenceStage
  , recoverKindAbsenceControlId
  , recoverKindAbsenceFootprint
  )
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeIntentObservation (..)
  , KindNodeVolumeReceiptObservation (..)
  , mkKindNodeVolumeIntent
  , observeKindNodeVolumeIntent
  , observeKindNodeVolumeReceipt
  )
import Prodbox.Control.KindNodeVolumeReadback (NodeVolumeInventory (..), parseNodeVolumeInventory)
import System.Timeout (timeout)

data AbsenceVolumePhase = AbsenceVolumesBeforeRemoval | AbsenceVolumesAfterRemoval
  deriving (Eq, Show)

data AbsenceVolumeSample = AbsenceVolumeSample
  { absencePositiveVolumeListed :: !Bool
  , absenceControlVolumeInventories :: ![(String, NodeVolumeInventory)]
  }
  deriving (Eq, Show)

data AbsenceVolumeReadback
  = AbsenceVolumeRecordsUnconfirmed
  | AbsenceVolumeUnobservable
  | AbsenceVolumeChanged
  | AbsenceVolumeSampled !AbsenceVolumeSample
  | AbsenceVolumeResidual ![String]
  deriving (Eq, Show)

-- All target filters use the same full-volume listing. The positive volume is
-- the separately recorded node volume, not one of the control's volumes.
parseAbsenceVolumeSample
  :: String -> [String] -> String -> [(String, String)] -> Maybe AbsenceVolumeSample
parseAbsenceVolumeSample positive targets volumeOutput filters = do
  if length targets > 64
    || targets /= sort targets
    || length targets /= length (nub targets)
    || any (not . validImageId . ("sha256:" ++)) targets
    || positive `elem` targets
    || map fst filters /= targets
    then Nothing
    else pure ()
  positiveInventory <- parseNodeVolumeInventory positive volumeOutput ""
  inventories <-
    traverse
      (\(identifier, output) -> (,) identifier <$> parseNodeVolumeInventory identifier volumeOutput output)
      filters
  pure (AbsenceVolumeSample (nodeVolumeListed positiveInventory) inventories)

classifyAbsenceVolumeReadback
  :: AbsenceVolumePhase
  -> String
  -> [String]
  -> DockerDaemonObservation
  -> DockerDaemonObservation
  -> Bool
  -> Maybe AbsenceVolumeSample
  -> Maybe AbsenceVolumeSample
  -> AbsenceVolumeReadback
classifyAbsenceVolumeReadback phase control targets before after stable first second =
  case (before, after, stable, first, second) of
    (DockerDaemonObserved _ _, DockerDaemonChanged, _, _, _) -> AbsenceVolumeChanged
    (DockerDaemonObserved _ _, DockerDaemonObserved _ _, True, Just a, Just b)
      | before /= after || a /= b -> AbsenceVolumeChanged
      | not (validImageId ("sha256:" ++ control)) -> AbsenceVolumeUnobservable
      | not (absencePositiveVolumeListed a) || map fst (absenceControlVolumeInventories a) /= targets ->
          AbsenceVolumeUnobservable
      | otherwise -> classify a
    _ -> AbsenceVolumeUnobservable
 where
  classify sample = case phase of
    AbsenceVolumesBeforeRemoval ->
      if all
        (\(_, inventory) -> nodeVolumeListed inventory && nodeVolumeContainerIds inventory == [control])
        inventories
        then AbsenceVolumeSampled sample
        else AbsenceVolumeUnobservable
    AbsenceVolumesAfterRemoval ->
      if any (not . null . nodeVolumeContainerIds . snd) inventories
        then AbsenceVolumeUnobservable
        else case [identifier | (identifier, inventory) <- inventories, nodeVolumeListed inventory] of
          [] -> AbsenceVolumeSampled sample
          residual -> AbsenceVolumeResidual residual
   where
    inventories = absenceControlVolumeInventories sample

-- The supplied wrapper combines the held family retirement owner with this
-- operation's lease. It must not retain the lease or establish new authority.
observeAbsenceControlVolumes
  :: BootstrapProjection
  -> KindAbsencePlan
  -> AbsenceVolumePhase
  -> (IO Bool -> IO Bool)
  -> IO (KindOperationOutcome AbsenceVolumeReadback)
observeAbsenceControlVolumes bootstrap plan phase ownerStable =
  withRecoveredKindOperation bootstrap operation $ \lease -> do
    let stable = do
          before <- lease
          owner <- ownerStable lease
          after <- lease
          pure (before && owner && after)
    observeAbsenceControlVolumesUnderLease bootstrap plan phase stable
 where
  operation = kindAbsenceOperation plan

-- The caller must hold the recovered operation lease. Effect admission also
-- requires the family owner; a status-only caller has no such settlement proof.
observeAbsenceControlVolumesUnderLease
  :: BootstrapProjection -> KindAbsencePlan -> AbsenceVolumePhase -> IO Bool -> IO AbsenceVolumeReadback
observeAbsenceControlVolumesUnderLease bootstrap plan phase heldStable = do
  result <- timeout 120000000 (run heldStable)
  pure (maybe AbsenceVolumeUnobservable id result)
 where
  operation = kindAbsenceOperation plan
  expectedDaemon = kindAbsenceDaemon plan
  socket = bootstrapRuntimeSocket bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  run stable = do
    control <- recoverKindAbsenceControlId bootstrap plan stable
    footprint <- case control of
      AbsenceIdObserved identifier -> recoverKindAbsenceFootprint bootstrap plan identifier stable
      _ -> pure AbsenceFootprintUnconfirmed
    case (control, footprint, kindNodeVarVolumeName (bootstrapKindPlan bootstrap) generation operation) of
      (AbsenceIdObserved identifier, AbsenceFootprintObserved volumes, Just positive) -> do
        let targets = sort (map snd volumes)
        required <- requiredRecords stable identifier volumes
        if not required
          then pure AbsenceVolumeRecordsUnconfirmed
          else do
            before <- observeDockerDaemon socket
            firstPositive <- observePositiveVolume stable
            first <- sample stable positive targets
            second <- sample stable positive targets
            secondPositive <- observePositiveVolume stable
            after <- observeDockerDaemon socket
            final <- try stable
            let trusted =
                  before == expectedDaemon
                    && after == expectedDaemon
                    && firstPositive
                    && secondPositive
                    && either (const False) id (final :: Either IOException Bool)
            pure (classifyAbsenceVolumeReadback phase identifier targets before after trusted first second)
      _ -> pure AbsenceVolumeRecordsUnconfirmed
  requiredRecords stable identifier volumes = do
    footprint <-
      observeKindAbsenceStage bootstrap plan (AbsenceFootprintRecorded identifier volumes) stable
    case phase of
      AbsenceVolumesBeforeRemoval -> pure (footprint == AbsenceMatches)
      AbsenceVolumesAfterRemoval -> do
        sampled <- observeKindAbsenceStage bootstrap plan (AbsenceControlSampled identifier volumes) stable
        attempted <- observeKindAbsenceStage bootstrap plan (AbsenceRemoveAttempt identifier volumes) stable
        pure (footprint == AbsenceMatches && sampled == AbsenceMatches && attempted == AbsenceMatches)
  observePositiveVolume stable = case mkKindNodeVolumeIntent operation expectedDaemon of
    Nothing -> pure False
    Just intent -> do
      proposal <- observeKindNodeVolumeIntent bootstrap intent stable
      receipt <- observeKindNodeVolumeReceipt bootstrap intent stable
      if proposal /= NodeVolumeIntentMatches
        || receipt
          /= NodeVolumeReceiptObserved (DockerNodeVarCreateReply 201 (Just DockerNodeVarVolumeMatching))
        then pure False
        else do
          result <- withConnectedDockerInfo 5000000 socket $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
            before <- stable
            observed <- inspectDockerSessionNodeVarVolume session bootstrap operation
            after <- stable
            peer <- peerStable
            pure
              ( before
                  && after
                  && peer
                  && DockerDaemonObserved identifier identity == expectedDaemon
                  && observed == Right DockerNodeVarVolumeMatching
              )
          pure (result == DockerPeerCompleted (DockerConnectedInfoCompleted True))
  sample stable positive targets = do
    listing <- readStable stable ["volume", "ls", "--quiet"]
    filters <-
      traverse
        ( \identifier ->
            fmap (identifier,)
              <$> readStable
                stable
                ["ps", "--all", "--no-trunc", "--filter", "volume=" ++ identifier, "--format", "{{.ID}}"]
        )
        targets
    pure $ do
      volumes <- listing
      observations <- sequence filters
      parseAbsenceVolumeSample positive targets volumes observations
  readStable stable arguments = do
    before <- try stable
    case (before :: Either IOException Bool) of
      Right True -> do
        observed <- readDocker socket arguments
        after <- try stable
        pure $ case (after :: Either IOException Bool) of Right True -> observed; _ -> Nothing
      _ -> pure Nothing
