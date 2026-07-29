{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 4.48: the retained Lifecycle Authority's post-genesis backup-repair
-- reopen fold.
--
-- @BackupRepairFrozen@ is the ONLY post-genesis, primary-only fold. Once genesis
-- has established the authority ('BackupEstablished'), a later reconcile assesses
-- backup health:
--
--   * a temporary or unobservable backup outage keeps admission FROZEN and merely
--     waits — no signed permit, no key rotation, no external effect — and reopens
--     (under a strictly greater epoch) only once the backup is observed healthy
--     again;
--   * a positively absent key\/bucket or proven policy drift primary-journals a
--     signed one-time repair permit. The mode-indexed Credential Provisioner
--     creates\/rotates the deterministic resources, the home Target Agent delivers
--     the next @LongLived@ generation, and the physically separate Authority
--     Backup Adapter full-copies\/reads-back every current envelope\/blob and
--     commits the first new backup receipt. Authority reopens ONLY under a
--     strictly greater epoch, and only after BOTH read-backs are present.
--
-- No normal external effect runs while admission is frozen. The permit is
-- consumed at most once (replay is idempotent, a divergent permit is a mismatch),
-- and a lost response recovers the same permit\/receipt by re-observation rather
-- than re-minting.
--
-- This module is pure. It mirrors the decide\/evolve\/step shape of
-- @Prodbox.Lifecycle.Authority.Genesis@ and operates on that module's
-- 'AuthorityAdmissionState' (the single admission-state SSoT), which carries the
-- 'BackupRepairFrozen' constructor. The interpreter supplies the health
-- observation and the deterministic permit; this fold owns the transitions.
module Prodbox.Lifecycle.Authority.BackupRepair
  ( -- * Health observation
    BackupHealth (..)

    -- * Commands / decisions / events
  , BackupRepairCommand (..)
  , BackupRepairRefusal (..)
  , BackupRepairDecision (..)
  , BackupRepairEvent (..)

    -- * Folds
  , decideBackupRepair
  , evolveBackupRepair
  , backupRepairDecisionEvents
  , stepBackupRepair
  )
where

import Codec.Serialise (Serialise)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , AuthorityEpoch
  , BackupReceipt
  , BackupRepairPermit
  , BackupRepairProgress (..)
  , TargetAgentGenerationReceipt
  , initialBackupRepairProgress
  , nextAuthorityEpoch
  )

-- | The assessed health of the retained authority backup. Temporary and
-- unobservable outages wait; positive absence and policy drift trigger repair.
data BackupHealth
  = -- | The backup is present and consistent; no repair is needed.
    BackupHealthy
  | -- | The backup is temporarily unreachable; keep frozen and wait.
    BackupTemporarilyUnavailable
  | -- | The backup could not be observed at all; fail closed — keep frozen and wait.
    BackupUnobservable
  | -- | The backup key\/bucket is positively absent; a signed repair permit is due.
    BackupPositivelyAbsent
  | -- | The backup policy has provably drifted; a signed repair permit is due.
    BackupPolicyDrift
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data BackupRepairCommand
  = -- | Assess backup health. From 'BackupEstablished' any non-healthy reading
    -- freezes admission; a healthy reading is a no-op. While frozen, a healthy
    -- reading reopens (only if no permit was minted — a pure outage), otherwise it
    -- is ignored (an in-flight repair must complete through its receipts).
    AssessBackupHealth !BackupHealth
  | -- | Primary-journal the deterministic one-time repair permit (from positive
    -- absence \/ policy drift). Legal only while frozen; idempotent against the
    -- exact bound permit and refused as a mismatch for any other.
    BeginBackupRepair !BackupRepairPermit
  | -- | Feed back the next @LongLived@ generation receipt from the Target Agent.
    ObserveRepairGeneration !TargetAgentGenerationReceipt
  | -- | Feed back the Authority Backup Adapter's first new backup receipt.
    ObserveRepairNewBackupReceipt !BackupReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data BackupRepairRefusal
  = -- | A repair command before genesis has established the authority.
    BackupRepairBeforeGenesis
  | -- | A permit or receipt command while admission is not frozen for repair.
    BackupRepairNotFrozen
  | -- | A repair receipt before the one-time permit has been minted.
    BackupRepairPermitAbsent
  | -- | 'BeginBackupRepair' carrying a permit that disagrees with the bound one.
    BackupRepairPermitMismatch
  deriving (Eq, Show)

data BackupRepairDecision
  = BackupRepairRefused !BackupRepairRefusal
  | -- | Backup is healthy and admission is already open; commit nothing.
    BackupRepairNotNeeded
  | -- | Freeze admission for repair (from 'BackupEstablished'); emit the event.
    BackupRepairFroze !BackupRepairEvent
  | -- | Already frozen and still not repairable\/healthy; wait, commit nothing.
    BackupRepairWait
  | -- | Primary-journal the one-time permit; emit 'BackupRepairPermitRecorded'.
    BackupRepairPermitMinted !BackupRepairEvent
  | -- | The exact permit is already minted (idempotent); commit nothing.
    BackupRepairPermitAlreadyMinted
  | -- | Record a repair read-back that does not yet complete the repair.
    BackupRepairRecordProgress !BackupRepairEvent
  | -- | The triggering read-back completes the repair: record it, then reopen
    -- admission under the strictly greater epoch.
    BackupRepairReopen ![BackupRepairEvent] !AuthorityEpoch
  deriving (Eq, Show)

data BackupRepairEvent
  = -- | 'BackupEstablished' epoch -> 'BackupRepairFrozen' epoch (waiting, no permit).
    BackupRepairAdmissionFrozen !AuthorityEpoch
  | -- | Record the one-time permit into the frozen progress.
    BackupRepairPermitRecorded !BackupRepairPermit
  | -- | Record the next-generation receipt into the frozen progress.
    BackupRepairGenerationRecorded !TargetAgentGenerationReceipt
  | -- | Record the adapter's first new backup receipt into the frozen progress.
    BackupRepairNewBackupReceiptRecorded !BackupReceipt
  | -- | 'BackupRepairFrozen' _ -> 'BackupEstablished' newEpoch (greater epoch).
    BackupRepairAdmissionReopened !AuthorityEpoch
  deriving (Eq, Show)

-- | Decide the next backup-repair transition. Pure; never mutates state. Repair
-- is post-genesis only. A non-healthy reading from 'BackupEstablished' freezes
-- admission; the deterministic permit is journaled by 'BeginBackupRepair' and
-- reopen happens only under 'nextAuthorityEpoch' after both read-backs are
-- present.
decideBackupRepair :: AuthorityAdmissionState -> BackupRepairCommand -> BackupRepairDecision
decideBackupRepair state command = case state of
  GenesisFrozen -> BackupRepairRefused BackupRepairBeforeGenesis
  EstablishingBackup _ -> BackupRepairRefused BackupRepairBeforeGenesis
  BackupEstablished epoch -> case command of
    AssessBackupHealth BackupHealthy -> BackupRepairNotNeeded
    AssessBackupHealth _ -> BackupRepairFroze (BackupRepairAdmissionFrozen epoch)
    BeginBackupRepair _ -> BackupRepairRefused BackupRepairNotFrozen
    ObserveRepairGeneration _ -> BackupRepairRefused BackupRepairNotFrozen
    ObserveRepairNewBackupReceipt _ -> BackupRepairRefused BackupRepairNotFrozen
  BackupRepairFrozen epoch progress -> case command of
    AssessBackupHealth BackupHealthy -> case backupRepairPermit progress of
      -- A pure temporary\/unobservable outage that resolved: nothing was lost, so
      -- reopen directly under the greater epoch.
      Nothing ->
        let reopened = nextAuthorityEpoch epoch
         in BackupRepairReopen [BackupRepairAdmissionReopened reopened] reopened
      -- A repair is under way; a stray healthy reading must not short-circuit it.
      Just _ -> BackupRepairWait
    AssessBackupHealth _ -> BackupRepairWait
    BeginBackupRepair permit -> case backupRepairPermit progress of
      Nothing -> BackupRepairPermitMinted (BackupRepairPermitRecorded permit)
      Just existing
        | existing == permit -> BackupRepairPermitAlreadyMinted
        | otherwise -> BackupRepairRefused BackupRepairPermitMismatch
    ObserveRepairGeneration receipt ->
      withMintedPermit progress $
        resolveRepairReceipt
          epoch
          (progress {backupRepairGeneration = Just receipt})
          (BackupRepairGenerationRecorded receipt)
    ObserveRepairNewBackupReceipt receipt ->
      withMintedPermit progress $
        resolveRepairReceipt
          epoch
          (progress {backupRepairNewReceipt = Just receipt})
          (BackupRepairNewBackupReceiptRecorded receipt)
 where
  withMintedPermit progress k = case backupRepairPermit progress of
    Nothing -> BackupRepairRefused BackupRepairPermitAbsent
    Just _ -> k
  resolveRepairReceipt epoch updated event
    | backupRepairComplete updated =
        let reopened = nextAuthorityEpoch epoch
         in BackupRepairReopen [event, BackupRepairAdmissionReopened reopened] reopened
    | otherwise = BackupRepairRecordProgress event

-- | Whether the minted permit and both repair read-backs are present.
backupRepairComplete :: BackupRepairProgress -> Bool
backupRepairComplete progress =
  case ( backupRepairPermit progress
       , backupRepairGeneration progress
       , backupRepairNewReceipt progress
       ) of
    (Just _, Just _, Just _) -> True
    _ -> False

-- | Fold one authoritative backup-repair event into the admission state. Total;
-- an event that does not apply to the current state leaves it unchanged
-- (idempotent replay).
evolveBackupRepair :: AuthorityAdmissionState -> BackupRepairEvent -> AuthorityAdmissionState
evolveBackupRepair state event = case event of
  BackupRepairAdmissionFrozen epoch -> case state of
    BackupEstablished e | e == epoch -> BackupRepairFrozen epoch initialBackupRepairProgress
    _ -> state
  BackupRepairPermitRecorded permit -> case state of
    BackupRepairFrozen epoch progress -> case backupRepairPermit progress of
      Nothing -> BackupRepairFrozen epoch progress {backupRepairPermit = Just permit}
      Just _ -> state
    _ -> state
  BackupRepairGenerationRecorded receipt -> case state of
    BackupRepairFrozen epoch progress ->
      BackupRepairFrozen epoch progress {backupRepairGeneration = Just receipt}
    _ -> state
  BackupRepairNewBackupReceiptRecorded receipt -> case state of
    BackupRepairFrozen epoch progress ->
      BackupRepairFrozen epoch progress {backupRepairNewReceipt = Just receipt}
    _ -> state
  BackupRepairAdmissionReopened reopened -> case state of
    BackupRepairFrozen _ _ -> BackupEstablished reopened
    _ -> state

-- | The authoritative event(s) a decision commits, in order (empty for refusals,
-- waits, and idempotent no-ops). Applying these via 'evolveBackupRepair'
-- reproduces 'stepBackupRepair', so the fold is fully event-sourced.
backupRepairDecisionEvents :: BackupRepairDecision -> [BackupRepairEvent]
backupRepairDecisionEvents decision = case decision of
  BackupRepairRefused _ -> []
  BackupRepairNotNeeded -> []
  BackupRepairFroze event -> [event]
  BackupRepairWait -> []
  BackupRepairPermitMinted event -> [event]
  BackupRepairPermitAlreadyMinted -> []
  BackupRepairRecordProgress event -> [event]
  BackupRepairReopen events _ -> events

-- | 'decideBackupRepair' then fold the committed events, returning the decision
-- and the evolved state (unchanged on refusals, waits, and idempotent no-ops).
stepBackupRepair
  :: AuthorityAdmissionState
  -> BackupRepairCommand
  -> (BackupRepairDecision, AuthorityAdmissionState)
stepBackupRepair state command =
  let decision = decideBackupRepair state command
   in (decision, foldl evolveBackupRepair state (backupRepairDecisionEvents decision))
