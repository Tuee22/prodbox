-- | Pure desired-present planning plus the single effectful
-- observe -> plan -> enact -> re-observe interpreter. External resource
-- presence and checkpoint usability remain independent flat observations;
-- no in-process action constructor claims that either authority changed.
module Prodbox.Lifecycle.DesiredPresence
  ( DesiredPresenceAction (..)
  , DesiredPresenceRefusal (..)
  , DesiredPresencePlan (..)
  , DesiredPresenceHooks (..)
  , DesiredPresenceRun (..)
  , DesiredPresenceFailure (..)
  , planDesiredPresence
  , desiredPresenceConverged
  , reconcileDesiredPresence
  )
where

import Prodbox.Lifecycle.ResidueStatus
  ( CheckpointFailure
  , CheckpointObservation (..)
  , ObservationFailure
  , PresenceObservation (..)
  )

-- | Explicit mutation plan data for every positively observable
-- presence x checkpoint combination. The three absent cases retain the
-- checkpoint condition that made creation safe; the three present cases
-- distinguish ordinary reconcile from missing-state import and corrupt-state
-- repair.
data DesiredPresenceAction inventory snapshot
  = CreateFromAbsentMissingCheckpoint
  | CreateFromAbsentValidCheckpoint !snapshot
  | CreateFromAbsentCorruptCheckpoint !CheckpointFailure
  | ImportPresentMissingCheckpoint !inventory
  | ReconcilePresentValidCheckpoint !inventory !snapshot
  | RepairPresentCorruptCheckpoint !inventory !CheckpointFailure
  deriving (Eq, Show)

-- | Planning refusal. When both authorities are unobservable, both failures
-- are retained rather than allowing pattern-match order to discard evidence.
data DesiredPresenceRefusal
  = PresenceObservationRefused !ObservationFailure
  | CheckpointObservationRefused !ObservationFailure
  | PresenceAndCheckpointObservationsRefused !ObservationFailure !ObservationFailure
  deriving (Eq, Show)

data DesiredPresencePlan inventory snapshot
  = DesiredPresenceActionPlanned !(DesiredPresenceAction inventory snapshot)
  | DesiredPresencePlanningRefused !DesiredPresenceRefusal
  deriving (Eq, Show)

-- | Caller-injected authority observations and action interpreter. Tests can
-- supply deterministic fakes; production supplies real AWS/checkpoint
-- observers and the registered idempotent ensure action.
data DesiredPresenceHooks inventory snapshot = DesiredPresenceHooks
  { observeDesiredResourcePresence :: IO (PresenceObservation inventory)
  , observeDesiredResourceCheckpoint :: IO (CheckpointObservation snapshot)
  , enactDesiredPresenceAction
      :: DesiredPresenceAction inventory snapshot
      -> IO (Either String ())
  }

-- | Successful execution evidence. Success means enactment returned success
-- and mandatory re-observation positively saw both live inventory and a valid
-- checkpoint.
data DesiredPresenceRun inventory snapshot = DesiredPresenceRun
  { desiredPresenceInitialPresence :: !(PresenceObservation inventory)
  , desiredPresenceInitialCheckpoint :: !(CheckpointObservation snapshot)
  , desiredPresenceEnactedAction :: !(DesiredPresenceAction inventory snapshot)
  , desiredPresenceFinalPresence :: !(PresenceObservation inventory)
  , desiredPresenceFinalCheckpoint :: !(CheckpointObservation snapshot)
  }
  deriving (Eq, Show)

-- | Structured failure from planning, enactment, or mandatory post-enactment
-- observation. An enactment failure still carries both fresh observations so
-- partial external effects remain explicit recovery input.
data DesiredPresenceFailure inventory snapshot
  = DesiredPresencePlanFailed !DesiredPresenceRefusal
  | DesiredPresenceEnactFailed
      !(DesiredPresenceAction inventory snapshot)
      !String
      !(PresenceObservation inventory)
      !(CheckpointObservation snapshot)
  | DesiredPresencePostconditionFailed
      !(DesiredPresenceAction inventory snapshot)
      !(PresenceObservation inventory)
      !(CheckpointObservation snapshot)
  deriving (Eq, Show)

-- | Exhaustive pure decision table over all 12 combinations. Unobservable
-- input always refuses before mutation; corruption is never collapsed to
-- missing.
planDesiredPresence
  :: PresenceObservation inventory
  -> CheckpointObservation snapshot
  -> DesiredPresencePlan inventory snapshot
planDesiredPresence presence checkpoint =
  case (presence, checkpoint) of
    (PresenceUnobservable presenceFailure, CheckpointUnobservable checkpointFailure) ->
      DesiredPresencePlanningRefused
        (PresenceAndCheckpointObservationsRefused presenceFailure checkpointFailure)
    (PresenceUnobservable failure, _) ->
      DesiredPresencePlanningRefused (PresenceObservationRefused failure)
    (_, CheckpointUnobservable failure) ->
      DesiredPresencePlanningRefused (CheckpointObservationRefused failure)
    (PresenceAbsent, CheckpointMissing) ->
      DesiredPresenceActionPlanned CreateFromAbsentMissingCheckpoint
    (PresenceAbsent, CheckpointValid snapshot) ->
      DesiredPresenceActionPlanned (CreateFromAbsentValidCheckpoint snapshot)
    (PresenceAbsent, CheckpointCorrupt failure) ->
      DesiredPresenceActionPlanned (CreateFromAbsentCorruptCheckpoint failure)
    (PresencePresent inventory, CheckpointMissing) ->
      DesiredPresenceActionPlanned (ImportPresentMissingCheckpoint inventory)
    (PresencePresent inventory, CheckpointValid snapshot) ->
      DesiredPresenceActionPlanned (ReconcilePresentValidCheckpoint inventory snapshot)
    (PresencePresent inventory, CheckpointCorrupt failure) ->
      DesiredPresenceActionPlanned (RepairPresentCorruptCheckpoint inventory failure)

-- | Desired-present success is an externally observed fact, not the result of
-- running an action. Only a positive inventory plus a valid checkpoint closes
-- the postcondition.
desiredPresenceConverged
  :: PresenceObservation inventory -> CheckpointObservation snapshot -> Bool
desiredPresenceConverged presence checkpoint =
  case (presence, checkpoint) of
    (PresencePresent _, CheckpointValid _) -> True
    _ -> False

-- | The canonical effectful loop. Once enactment is attempted, both
-- authorities are always re-observed, even when the action reports failure.
-- This prevents partial AWS/checkpoint effects from disappearing behind an
-- exit code.
reconcileDesiredPresence
  :: DesiredPresenceHooks inventory snapshot
  -> IO (Either (DesiredPresenceFailure inventory snapshot) (DesiredPresenceRun inventory snapshot))
reconcileDesiredPresence hooks = do
  initialPresence <- observeDesiredResourcePresence hooks
  initialCheckpoint <- observeDesiredResourceCheckpoint hooks
  case planDesiredPresence initialPresence initialCheckpoint of
    DesiredPresencePlanningRefused refusal ->
      pure (Left (DesiredPresencePlanFailed refusal))
    DesiredPresenceActionPlanned action -> do
      enactResult <- enactDesiredPresenceAction hooks action
      finalPresence <- observeDesiredResourcePresence hooks
      finalCheckpoint <- observeDesiredResourceCheckpoint hooks
      pure $ case enactResult of
        Left detail ->
          Left (DesiredPresenceEnactFailed action detail finalPresence finalCheckpoint)
        Right ()
          | desiredPresenceConverged finalPresence finalCheckpoint ->
              Right
                DesiredPresenceRun
                  { desiredPresenceInitialPresence = initialPresence
                  , desiredPresenceInitialCheckpoint = initialCheckpoint
                  , desiredPresenceEnactedAction = action
                  , desiredPresenceFinalPresence = finalPresence
                  , desiredPresenceFinalCheckpoint = finalCheckpoint
                  }
          | otherwise ->
              Left (DesiredPresencePostconditionFailed action finalPresence finalCheckpoint)
