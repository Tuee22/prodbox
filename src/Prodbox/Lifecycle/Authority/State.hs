-- | Sprint 4.48: the retained Lifecycle Authority aggregate.
--
-- 'AuthorityState' composes the genesis admission fold
-- (@Prodbox.Lifecycle.Authority.Genesis@) with the durable operation journal
-- (@Prodbox.Lifecycle.Authority.Operation@): it holds the current admission
-- state and one fenced operation record per operation binding. Normal lifecycle
-- operations are admitted ONLY after genesis opens admission, and each admitted
-- operation is fenced by the epoch under which it was admitted. Decisions are
-- idempotent: re-admitting the same binding with the same intent, or
-- re-completing with the same result, commits no event; a different intent or
-- result for an existing binding is a conflict.
--
-- Pure: 'decideAuthority' never mutates state, 'evolveAuthority' folds one
-- authoritative event, and 'stepAuthority' composes them, mirroring the
-- 'Prodbox.ControlPlane.Capacity' decide/evolve shape.
module Prodbox.Lifecycle.Authority.State
  ( AuthorityState (..)
  , FencedOperation (..)
  , initialAuthorityState
  , authorityAdmitsOperations
  , authorityOperationPhase
  , AuthorityCommand (..)
  , AuthorityOperationRefusal (..)
  , AuthorityDecision (..)
  , AuthorityEvent (..)
  , decideAuthority
  , evolveAuthority
  , authorityDecisionEvents
  , stepAuthority
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupRepairCommand
  , BackupRepairDecision
  , BackupRepairEvent
  , backupRepairDecisionEvents
  , decideBackupRepair
  , evolveBackupRepair
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState
  , AuthorityEpoch
  , AuthorityGenesisCommand
  , AuthorityGenesisEvent
  , GenesisDecision
  , admitsNormalOperations
  , decideGenesis
  , establishedEpoch
  , evolveGenesis
  , genesisDecisionEvents
  , initialGenesisState
  )
import Prodbox.Lifecycle.Authority.Operation (OperationPhase (..))

-- | One operation in the authority journal, fenced by the epoch under which it
-- was admitted. The append-only phase is reused from the operation journal.
data FencedOperation intent result = FencedOperation
  { fencedOperationEpoch :: !AuthorityEpoch
  , fencedOperationPhase :: !(OperationPhase intent result)
  }
  deriving (Eq, Show)

-- | The retained Lifecycle Authority aggregate: its genesis admission state plus
-- its durable operation journal keyed by operation binding.
data AuthorityState binding intent result = AuthorityState
  { authorityAdmission :: !AuthorityAdmissionState
  , authorityOperations :: !(Map binding (FencedOperation intent result))
  }
  deriving (Eq, Show)

-- | A fresh authority: frozen (pre-genesis) with no operations.
initialAuthorityState :: AuthorityState binding intent result
initialAuthorityState = AuthorityState initialGenesisState Map.empty

-- | Whether the authority currently admits normal lifecycle operations.
authorityAdmitsOperations :: AuthorityState binding intent result -> Bool
authorityAdmitsOperations = admitsNormalOperations . authorityAdmission

-- | The durable phase of one operation, or @Nothing@ if unknown.
authorityOperationPhase
  :: (Ord binding)
  => binding
  -> AuthorityState binding intent result
  -> Maybe (OperationPhase intent result)
authorityOperationPhase binding state =
  fencedOperationPhase <$> Map.lookup binding (authorityOperations state)

data AuthorityCommand binding intent result
  = -- | A genesis admission command (delegated to the genesis fold).
    AuthorityGenesis !AuthorityGenesisCommand
  | -- | A post-genesis backup-repair command (delegated to the repair fold).
    AuthorityBackupRepair !BackupRepairCommand
  | -- | Admit a new normal operation (admission-gated, epoch-fenced).
    AuthorityAdmitOperation !binding !intent
  | -- | Record the terminal result of an admitted operation.
    AuthorityCompleteOperation !binding !result
  deriving (Eq, Show)

data AuthorityOperationRefusal
  = -- | An operation command before genesis has opened normal admission.
    OperationRefusedAdmissionClosed
  | -- | Re-admitting an existing binding with a DIFFERENT armed intent.
    OperationRefusedBindingIntentConflict
  | -- | Completing an operation whose binding is unknown.
    OperationRefusedUnknownBinding
  | -- | Re-completing a terminal operation with a DIFFERENT result.
    OperationRefusedResultConflict
  deriving (Eq, Show)

data AuthorityDecision binding intent result
  = AuthorityGenesisDecision !GenesisDecision
  | AuthorityBackupRepairDecision !BackupRepairDecision
  | AuthorityOperationRefused !AuthorityOperationRefusal
  | -- | A new operation is admitted under the epoch; emit 'OperationArmedAt'.
    AuthorityOperationArmed !binding !AuthorityEpoch !intent
  | -- | The exact operation is already armed (idempotent); commit nothing.
    AuthorityOperationAlreadyArmed !binding !AuthorityEpoch !intent
  | -- | An armed operation completes; emit 'OperationCompletedWith'.
    AuthorityOperationCompleted !binding !result
  | -- | The exact operation is already complete (idempotent replay); commit nothing.
    AuthorityOperationAlreadyComplete !binding !result
  deriving (Eq, Show)

data AuthorityEvent binding intent result
  = AuthorityGenesisEvented !AuthorityGenesisEvent
  | AuthorityBackupRepairEvented !BackupRepairEvent
  | OperationArmedAt !binding !AuthorityEpoch !intent
  | OperationCompletedWith !binding !result
  deriving (Eq, Show)

-- | Decide the next authority transition. Pure; never mutates state.
decideAuthority
  :: (Ord binding, Eq intent, Eq result)
  => AuthorityState binding intent result
  -> AuthorityCommand binding intent result
  -> AuthorityDecision binding intent result
decideAuthority state command = case command of
  AuthorityGenesis gcmd ->
    AuthorityGenesisDecision (decideGenesis (authorityAdmission state) gcmd)
  AuthorityBackupRepair rcmd ->
    AuthorityBackupRepairDecision (decideBackupRepair (authorityAdmission state) rcmd)
  AuthorityAdmitOperation binding intent ->
    case establishedEpoch (authorityAdmission state) of
      Nothing -> AuthorityOperationRefused OperationRefusedAdmissionClosed
      Just epoch ->
        case Map.lookup binding (authorityOperations state) of
          Nothing -> AuthorityOperationArmed binding epoch intent
          Just fenced -> case fencedOperationPhase fenced of
            OperationArmed existing
              | existing == intent ->
                  AuthorityOperationAlreadyArmed binding (fencedOperationEpoch fenced) existing
              | otherwise -> AuthorityOperationRefused OperationRefusedBindingIntentConflict
            OperationCompleted result -> AuthorityOperationAlreadyComplete binding result
  AuthorityCompleteOperation binding result ->
    case Map.lookup binding (authorityOperations state) of
      Nothing -> AuthorityOperationRefused OperationRefusedUnknownBinding
      Just fenced -> case fencedOperationPhase fenced of
        OperationArmed _ -> AuthorityOperationCompleted binding result
        OperationCompleted existing
          | existing == result -> AuthorityOperationAlreadyComplete binding existing
          | otherwise -> AuthorityOperationRefused OperationRefusedResultConflict

-- | Fold one authoritative event into the aggregate. Total.
evolveAuthority
  :: (Ord binding)
  => AuthorityState binding intent result
  -> AuthorityEvent binding intent result
  -> AuthorityState binding intent result
evolveAuthority state event = case event of
  AuthorityGenesisEvented gev ->
    state {authorityAdmission = evolveGenesis (authorityAdmission state) gev}
  AuthorityBackupRepairEvented rev ->
    state {authorityAdmission = evolveBackupRepair (authorityAdmission state) rev}
  OperationArmedAt binding epoch intent ->
    state
      { authorityOperations =
          Map.insert binding (FencedOperation epoch (OperationArmed intent)) (authorityOperations state)
      }
  OperationCompletedWith binding result ->
    state
      { authorityOperations =
          Map.adjust
            (\fenced -> fenced {fencedOperationPhase = OperationCompleted result})
            binding
            (authorityOperations state)
      }

-- | The authoritative event(s) a decision commits, in order (empty for refusals
-- and idempotent no-ops).
authorityDecisionEvents
  :: AuthorityDecision binding intent result
  -> [AuthorityEvent binding intent result]
authorityDecisionEvents decision = case decision of
  AuthorityGenesisDecision gdec -> map AuthorityGenesisEvented (genesisDecisionEvents gdec)
  AuthorityBackupRepairDecision rdec ->
    map AuthorityBackupRepairEvented (backupRepairDecisionEvents rdec)
  AuthorityOperationRefused _ -> []
  AuthorityOperationArmed binding epoch intent -> [OperationArmedAt binding epoch intent]
  AuthorityOperationAlreadyArmed {} -> []
  AuthorityOperationCompleted binding result -> [OperationCompletedWith binding result]
  AuthorityOperationAlreadyComplete {} -> []

-- | 'decideAuthority' then fold the committed events, returning the decision and
-- the evolved state (unchanged on refusals and idempotent no-ops).
stepAuthority
  :: (Ord binding, Eq intent, Eq result)
  => AuthorityState binding intent result
  -> AuthorityCommand binding intent result
  -> (AuthorityDecision binding intent result, AuthorityState binding intent result)
stepAuthority state command =
  let decision = decideAuthority state command
   in (decision, foldl evolveAuthority state (authorityDecisionEvents decision))
