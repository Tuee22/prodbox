{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.48: the retained Lifecycle Authority's genesis admission fold.
--
-- @GenesisFrozen -> EstablishAuthorityBackup -> BackupEstablished@ is the ONLY
-- pre-normal-admission fold. In genesis the authority durably journals its
-- deterministic backup-establishment intent, seals the initial credential, and
-- writes then reads back the complete initial envelope/blob set through the
-- physically separate Authority Backup Adapter. Normal lifecycle operations are
-- admitted ONLY after BOTH the home Target Agent generation receipt AND the
-- backup receipt are read back, which opens normal admission under the genesis
-- authority epoch. No provider, DNS, or suite effect is legal during genesis;
-- primary loss can leave only the registered deterministic backup resources,
-- removable and read-backable with a fresh admin prompt before retry.
--
-- This module is pure. 'decideGenesis' never mutates state and returns a
-- decision — including the deterministic establishment intent to durably journal
-- before any effect — while 'evolveGenesis' folds an authoritative event into the
-- state. It mirrors the decide/evolve shape of 'Prodbox.ControlPlane.Capacity'.
module Prodbox.Lifecycle.Authority.Genesis
  ( -- * Authority epoch
    AuthorityEpoch
  , authorityEpochGenesis
  , authorityEpochValue
  , nextAuthorityEpoch

    -- * Genesis identities
  , GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  , BackupReceipt (..)

    -- * State
  , AuthorityAdmissionState (..)
  , GenesisProgress (..)
  , initialGenesisState
  , admitsNormalOperations
  , establishedEpoch

    -- * Commands / decisions / events
  , AuthorityGenesisCommand (..)
  , GenesisRefusal (..)
  , GenesisDecision (..)
  , AuthorityGenesisEvent (..)

    -- * Folds
  , decideGenesis
  , evolveGenesis
  , stepGenesis
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)

-- | A monotone authority epoch. Genesis opens normal admission under
-- 'authorityEpochGenesis'; a later BackupRepair reopens under a strictly greater
-- epoch (owned by a subsequent Sprint 4.48 increment).
newtype AuthorityEpoch = AuthorityEpoch Natural
  deriving (Eq, Ord, Show)

-- | The epoch under which genesis first opens normal admission.
authorityEpochGenesis :: AuthorityEpoch
authorityEpochGenesis = AuthorityEpoch 1

authorityEpochValue :: AuthorityEpoch -> Natural
authorityEpochValue (AuthorityEpoch n) = n

-- | The next strictly-greater epoch (used by post-genesis repair reopen).
nextAuthorityEpoch :: AuthorityEpoch -> AuthorityEpoch
nextAuthorityEpoch (AuthorityEpoch n) = AuthorityEpoch (n + 1)

-- | The deterministic backup-establishment plan bound into genesis: a stable
-- digest over the exact ordered S3/IAM provisioning intent plus the backup-store
-- coordinate the Authority Backup Adapter writes and reads back. It carries no
-- secret material.
data GenesisPlan = GenesisPlan
  { genesisPlanDigest :: !Text
  -- ^ stable digest over the ordered deterministic establishment intent
  , genesisPlanBackupStoreCoordinate :: !Text
  -- ^ the registered backup-store coordinate (S3 prefix) the adapter owns
  }
  deriving (Eq, Show)

-- | The home Target Agent's sealed initial generation receipt, read back before
-- normal admission opens.
newtype TargetAgentGenerationReceipt = TargetAgentGenerationReceipt Text
  deriving (Eq, Show)

-- | The Authority Backup Adapter's receipt for the complete initial
-- envelope/blob set, read back before normal admission opens.
newtype BackupReceipt = BackupReceipt Text
  deriving (Eq, Show)

-- | Progress within 'EstablishingBackup': the bound plan plus the two read-back
-- receipts that gate normal admission. Both must be present to open admission.
data GenesisProgress = GenesisProgress
  { genesisProgressPlan :: !GenesisPlan
  , genesisProgressTargetAgentReceipt :: !(Maybe TargetAgentGenerationReceipt)
  , genesisProgressBackupReceipt :: !(Maybe BackupReceipt)
  }
  deriving (Eq, Show)

-- | The pre-normal-admission genesis lifecycle. Normal lifecycle operations are
-- admitted ONLY in 'BackupEstablished'.
data AuthorityAdmissionState
  = GenesisFrozen
  | EstablishingBackup !GenesisProgress
  | BackupEstablished !AuthorityEpoch
  deriving (Eq, Show)

initialGenesisState :: AuthorityAdmissionState
initialGenesisState = GenesisFrozen

-- | Whether the authority admits normal (post-genesis) lifecycle operations.
admitsNormalOperations :: AuthorityAdmissionState -> Bool
admitsNormalOperations state = case state of
  GenesisFrozen -> False
  EstablishingBackup _ -> False
  BackupEstablished _ -> True

-- | The epoch under which normal admission is open, or @Nothing@ before genesis
-- completes.
establishedEpoch :: AuthorityAdmissionState -> Maybe AuthorityEpoch
establishedEpoch state = case state of
  GenesisFrozen -> Nothing
  EstablishingBackup _ -> Nothing
  BackupEstablished epoch -> Just epoch

data AuthorityGenesisCommand
  = -- | Begin backup establishment from 'GenesisFrozen' with the deterministic plan.
    BeginGenesisEstablishment !GenesisPlan
  | -- | Feed back the home Target Agent's sealed generation receipt.
    ObserveTargetAgentGeneration !TargetAgentGenerationReceipt
  | -- | Feed back the Authority Backup Adapter's receipt.
    ObserveBackupReceipt !BackupReceipt
  deriving (Eq, Show)

data GenesisRefusal
  = -- | 'BeginGenesisEstablishment' when establishment with the same plan is underway.
    GenesisAlreadyEstablishing
  | -- | any genesis command after normal admission has opened.
    GenesisAlreadyEstablished
  | -- | a receipt observation before establishment has begun.
    GenesisNotEstablishing
  | -- | 'BeginGenesisEstablishment' carrying a plan that disagrees with the one
    -- already bound (genesis must remint the exact same plan on retry).
    GenesisPlanMismatch
  deriving (Eq, Show)

data GenesisDecision
  = GenesisRefused !GenesisRefusal
  | -- | Durably journal the deterministic establishment intent, then apply
    -- 'GenesisEstablishmentBegun'. No external effect precedes the journal.
    GenesisBeginEstablishment !GenesisPlan
  | -- | Record a read-back receipt that does not yet complete both read-backs.
    GenesisRecordReceipt !AuthorityGenesisEvent
  | -- | The triggering receipt completes BOTH read-backs: record it, then open
    -- normal admission under the epoch.
    GenesisOpenAdmission !AuthorityGenesisEvent !AuthorityEpoch
  deriving (Eq, Show)

data AuthorityGenesisEvent
  = GenesisEstablishmentBegun !GenesisPlan
  | TargetAgentGenerationRecorded !TargetAgentGenerationReceipt
  | BackupReceiptRecorded !BackupReceipt
  | NormalAdmissionOpened !AuthorityEpoch
  deriving (Eq, Show)

-- | Decide the next genesis transition. Pure; never mutates state. On a receipt
-- that completes BOTH read-backs it decides 'GenesisOpenAdmission' (carrying the
-- triggering receipt event so the interpreter durably records the read-back
-- before opening admission); otherwise it decides 'GenesisRecordReceipt'. A
-- 'BeginGenesisEstablishment' is idempotent against the exact bound plan and is
-- refused (as a mismatch) for any other plan.
decideGenesis :: AuthorityAdmissionState -> AuthorityGenesisCommand -> GenesisDecision
decideGenesis state command = case state of
  GenesisFrozen -> case command of
    BeginGenesisEstablishment plan -> GenesisBeginEstablishment plan
    ObserveTargetAgentGeneration _ -> GenesisRefused GenesisNotEstablishing
    ObserveBackupReceipt _ -> GenesisRefused GenesisNotEstablishing
  EstablishingBackup progress -> case command of
    BeginGenesisEstablishment plan
      | plan == genesisProgressPlan progress -> GenesisRefused GenesisAlreadyEstablishing
      | otherwise -> GenesisRefused GenesisPlanMismatch
    ObserveTargetAgentGeneration receipt ->
      resolveReceipt
        (progress {genesisProgressTargetAgentReceipt = Just receipt})
        (TargetAgentGenerationRecorded receipt)
    ObserveBackupReceipt receipt ->
      resolveReceipt
        (progress {genesisProgressBackupReceipt = Just receipt})
        (BackupReceiptRecorded receipt)
  BackupEstablished _ -> GenesisRefused GenesisAlreadyEstablished
 where
  resolveReceipt updated event
    | genesisProgressComplete updated = GenesisOpenAdmission event authorityEpochGenesis
    | otherwise = GenesisRecordReceipt event

-- | Whether both read-back receipts are present.
genesisProgressComplete :: GenesisProgress -> Bool
genesisProgressComplete progress =
  case (genesisProgressTargetAgentReceipt progress, genesisProgressBackupReceipt progress) of
    (Just _, Just _) -> True
    _ -> False

-- | Fold an authoritative event into the genesis state. Total; an event that
-- does not apply to the current state leaves it unchanged (idempotent replay).
evolveGenesis :: AuthorityAdmissionState -> AuthorityGenesisEvent -> AuthorityAdmissionState
evolveGenesis state event = case event of
  GenesisEstablishmentBegun plan -> case state of
    GenesisFrozen -> EstablishingBackup (GenesisProgress plan Nothing Nothing)
    _ -> state
  TargetAgentGenerationRecorded receipt -> case state of
    EstablishingBackup progress ->
      EstablishingBackup (progress {genesisProgressTargetAgentReceipt = Just receipt})
    _ -> state
  BackupReceiptRecorded receipt -> case state of
    EstablishingBackup progress ->
      EstablishingBackup (progress {genesisProgressBackupReceipt = Just receipt})
    _ -> state
  NormalAdmissionOpened epoch -> case state of
    EstablishingBackup _ -> BackupEstablished epoch
    _ -> state

-- | 'decideGenesis' then apply the resulting event(s) in one step, returning the
-- decision and the evolved state. On 'GenesisRefused' the state is unchanged.
stepGenesis
  :: AuthorityAdmissionState
  -> AuthorityGenesisCommand
  -> (GenesisDecision, AuthorityAdmissionState)
stepGenesis state command =
  let decision = decideGenesis state command
   in (decision, applyGenesisDecision state decision)

applyGenesisDecision :: AuthorityAdmissionState -> GenesisDecision -> AuthorityAdmissionState
applyGenesisDecision state decision = case decision of
  GenesisRefused _ -> state
  GenesisBeginEstablishment plan -> evolveGenesis state (GenesisEstablishmentBegun plan)
  GenesisRecordReceipt event -> evolveGenesis state event
  GenesisOpenAdmission event epoch ->
    evolveGenesis (evolveGenesis state event) (NormalAdmissionOpened epoch)
