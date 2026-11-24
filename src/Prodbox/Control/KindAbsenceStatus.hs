-- | Operator-visible local journal observations. They do not authorize an
-- effect or establish resource presence, cleanup, or worker settlement.
module Prodbox.Control.KindAbsenceStatus
  ( AbsenceJournalObservation (..)
  , AbsenceInventoryObservation (..)
  , observeAbsenceJournalStatus
  , observeAbsenceInventoryStatus
  , renderAbsenceJournalStatus
  , renderAbsenceInventoryStatus
  ) where

import Control.Exception (IOException, try)
import Prodbox.Config.BootstrapProjection (BootstrapProjection)
import Prodbox.Control.KindAbsenceVolumeReadback
  ( AbsenceVolumePhase (AbsenceVolumesAfterRemoval), AbsenceVolumeReadback
  , observeAbsenceControlVolumesUnderLease )
import Prodbox.Control.KindIntent (KindIntentObservation (..), observeKindIntent)
import Prodbox.Control.KindLease (KindOperationOutcome (..), withRecoveredKindOperation)
import Prodbox.Control.KindNodeCreateIntent
  ( KindAbsencePlanRecovery (..), KindAbsenceIdObservation (..), KindAbsenceFootprintObservation (..)
  , KindAbsenceControlResultObservation
  , KindAbsenceObservation, KindAbsenceStage (..), KindAbsenceVolumeResultObservation
  , observeKindAbsenceStage, recoverKindAbsenceControlId, recoverKindAbsenceFootprint
  , recoverKindAbsencePlan, recoverKindAbsenceVolumeResult, recoverKindAbsenceControlResult )
import System.Timeout (timeout)

data AbsenceJournalObservation
  = AbsenceJournalOperationUnconfirmed
  | AbsenceJournalAttemptMissing
  | AbsenceJournalPlanUnconfirmed
  | AbsenceJournalIdentityUnconfirmed
  | AbsenceJournalFootprintUnconfirmed !String
  | AbsenceJournalRecorded !String !KindAbsenceObservation !KindAbsenceControlResultObservation
      ![(FilePath, String, KindAbsenceVolumeResultObservation)] !Bool
  deriving (Eq, Show)

data AbsenceInventoryObservation
  = AbsenceInventoryUnconfirmed
  | AbsenceInventoryObserved !AbsenceVolumeReadback !Bool
  deriving (Eq, Show)

-- Read-only status does not hold the retirement owner. A bounded inventory
-- observation is reported separately and must not become cleanup evidence.
observeAbsenceInventoryStatus :: BootstrapProjection -> IO AbsenceInventoryObservation
observeAbsenceInventoryStatus bootstrap = do
  operation <- observeKindIntent bootstrap
  case operation of
    KindIntentMatches identifier -> do
      result <- timeout 15000000 $ withRecoveredKindOperation bootstrap identifier $ \stable -> do
        recovered <- recoverKindAbsencePlan bootstrap identifier stable
        case recovered of
          AbsencePlanObserved plan -> do
            inventory <- observeAbsenceControlVolumesUnderLease bootstrap plan AbsenceVolumesAfterRemoval stable
            closing <- try stable
            pure (AbsenceInventoryObserved inventory (either (const False) id (closing :: Either IOException Bool)))
          _ -> pure AbsenceInventoryUnconfirmed
      pure $ case result of
        Just (KindOperationCallbackReturned value) -> value
        _ -> AbsenceInventoryUnconfirmed
    _ -> pure AbsenceInventoryUnconfirmed

observeAbsenceJournalStatus :: BootstrapProjection -> IO AbsenceJournalObservation
observeAbsenceJournalStatus bootstrap = do
  operation <- observeKindIntent bootstrap
  case operation of
    KindIntentMatches identifier -> do
      result <- timeout 30000000 $ withRecoveredKindOperation bootstrap identifier $ \stable -> do
        recovered <- recoverKindAbsencePlan bootstrap identifier stable
        case recovered of
          AbsencePlanMissing -> pure AbsenceJournalAttemptMissing
          AbsencePlanUnconfirmed -> pure AbsenceJournalPlanUnconfirmed
          AbsencePlanObserved plan -> do
            control <- recoverKindAbsenceControlId bootstrap plan stable
            case control of
              AbsenceIdUnconfirmed -> pure AbsenceJournalIdentityUnconfirmed
              AbsenceIdObserved controlId -> do
                footprint <- recoverKindAbsenceFootprint bootstrap plan controlId stable
                case footprint of
                  AbsenceFootprintUnconfirmed -> pure (AbsenceJournalFootprintUnconfirmed controlId)
                  AbsenceFootprintObserved volumes -> do
                    sampled <- observeKindAbsenceStage bootstrap plan (AbsenceControlSampled controlId volumes) stable
                    removal <- recoverKindAbsenceControlResult bootstrap plan controlId volumes stable
                    results <- traverse (\(path, volume) -> do
                      observed <- recoverKindAbsenceVolumeResult bootstrap plan controlId volumes volume stable
                      pure (path, volume, observed)) volumes
                    closing <- try stable
                    pure (AbsenceJournalRecorded controlId sampled removal results
                      (either (const False) id (closing :: Either IOException Bool)))
      pure $ case result of
        Just (KindOperationCallbackReturned value) -> value
        _ -> AbsenceJournalOperationUnconfirmed
    _ -> pure AbsenceJournalOperationUnconfirmed

renderAbsenceJournalStatus :: AbsenceJournalObservation -> String
renderAbsenceJournalStatus observation =
  "Absence-control journal: " ++ show observation
    ++ "; local records only; resource presence, cleanup and worker settlement are not established.\n"

renderAbsenceInventoryStatus :: AbsenceInventoryObservation -> String
renderAbsenceInventoryStatus observation =
  "Absence-control volume inventory: " ++ show observation
    ++ "; unsettled observation only; cleanup and worker settlement are not established.\n"
