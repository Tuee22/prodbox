-- | Sprint 4.48: a deterministic, pure crash/restart reference interpreter for
-- the durable operation outbox.
--
-- This is the fake-capability interpreter the Sprint 4.48 Independent Validation
-- calls for: it composes the durable operation journal
-- (@Prodbox.Lifecycle.Authority.Operation@) and its at-most-once recovery
-- (@decideOperationRecovery@) over an in-memory fake substrate — a durable
-- journal plus a keyed effect target — so every journal boundary can be exercised
-- with no object store, Vault, clock, AWS, Kubernetes, or later phase.
--
-- The substrate is the part that survives a crash: the committed journal records
-- and the effect target. A crash is modelled by simply NOT running the completion
-- step (the volatile "response" is lost); on restart, 'recoverOperation'
-- re-observes the target and decides whether to (re-)execute the armed intent,
-- recover an already-applied result, or fail closed — it NEVER blindly repeats a
-- non-idempotent effect. The target cell carries an apply-counter so tests can
-- prove at-most-once: a crash after the effect but before completion recovers the
-- observed result WITHOUT re-applying (the counter stays at 1).
module Prodbox.Lifecycle.Authority.OutboxSim
  ( -- * Fake substrate
    TargetKey (..)
  , TargetValue (..)
  , TargetCell (..)
  , OutboxKey (..)
  , SetTargetIntent (..)
  , DurableOutbox (..)
  , emptyDurableOutbox
  , targetApplyCount

    -- * Capability projections
  , effectMatches
  , outboxObservation

    -- * Interpreter steps
  , armOperation
  , runEffect
  , armAndApply
  , recoverOperation
  , lookupResult
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.Operation
  ( OperationEffectObservation (..)
  , OperationPhase (..)
  , OperationRecord (..)
  , OperationRecovery (..)
  , OperationRecoveryRefusal
  , completeOperation
  , decideOperationRecovery
  , newArmedOperation
  , operationResult
  )

-- | A key into the fake effect target (a stand-in for an object-store\/Vault
-- coordinate).
newtype TargetKey = TargetKey Text
  deriving (Eq, Ord, Show)

-- | The value an effect writes at a target key.
newtype TargetValue = TargetValue Text
  deriving (Eq, Show)

-- | The idempotency-keyed journal binding for one operation.
newtype OutboxKey = OutboxKey Text
  deriving (Eq, Ord, Show)

-- | The operation intent: set @intentKey@ to @intentValue@.
data SetTargetIntent = SetTargetIntent
  { intentKey :: !TargetKey
  , intentValue :: !TargetValue
  }
  deriving (Eq, Show)

-- | A target cell: its current value and how many times the effect has been
-- applied to it (to prove at-most-once execution).
data TargetCell = TargetCell
  { cellValue :: !TargetValue
  , cellApplyCount :: !Natural
  }
  deriving (Eq, Show)

-- | The durable substrate that survives a crash: the committed operation journal
-- and the effect target.
data DurableOutbox = DurableOutbox
  { durableJournal :: !(Map OutboxKey (OperationRecord OutboxKey SetTargetIntent TargetValue))
  , durableTarget :: !(Map TargetKey TargetCell)
  }
  deriving (Eq, Show)

emptyDurableOutbox :: DurableOutbox
emptyDurableOutbox = DurableOutbox Map.empty Map.empty

-- | How many times the effect has been applied at a key (0 if unset).
targetApplyCount :: TargetKey -> DurableOutbox -> Natural
targetApplyCount key durable = maybe 0 cellApplyCount (Map.lookup key (durableTarget durable))

-- | The @matches@ predicate for 'decideOperationRecovery': the effect succeeded
-- iff the target holds the intended value.
effectMatches :: SetTargetIntent -> TargetValue -> Bool
effectMatches intent result = intentValue intent == result

-- | Observe an armed operation's effect target for recovery: unset means the
-- effect has not been applied (source still current); the intended value means it
-- was applied; any other value means the target diverged.
outboxObservation :: SetTargetIntent -> DurableOutbox -> OperationEffectObservation TargetValue
outboxObservation intent durable = case Map.lookup (intentKey intent) (durableTarget durable) of
  Nothing -> OperationSourceStillCurrent
  Just cell
    | cellValue cell == intentValue intent -> OperationTargetReached (cellValue cell)
    | otherwise -> OperationTargetDiverged

-- | Apply the effect: write the intended value and increment the apply-counter.
applyEffect :: SetTargetIntent -> DurableOutbox -> DurableOutbox
applyEffect intent durable =
  durable
    { durableTarget =
        Map.insertWith
          (\_fresh existing -> TargetCell (intentValue intent) (cellApplyCount existing + 1))
          (intentKey intent)
          (TargetCell (intentValue intent) 1)
          (durableTarget durable)
    }

-- | Write the completed record back into the journal. The record is armed at every
-- call site, so the append-only completion never fails; a defensive refusal leaves
-- the substrate unchanged.
completeInJournal
  :: OutboxKey
  -> TargetValue
  -> OperationRecord OutboxKey SetTargetIntent TargetValue
  -> DurableOutbox
  -> DurableOutbox
completeInJournal key result record durable =
  case completeOperation key result record of
    Left _ -> durable
    Right completed ->
      durable {durableJournal = Map.insert key completed (durableJournal durable)}

-- | Journal an operation's intent BEFORE any effect. Idempotent: an existing
-- record for the key is left untouched (arming replays are safe).
armOperation :: OutboxKey -> SetTargetIntent -> DurableOutbox -> DurableOutbox
armOperation key intent durable = case Map.lookup key (durableJournal durable) of
  Just _ -> durable
  Nothing ->
    durable {durableJournal = Map.insert key (newArmedOperation key intent) (durableJournal durable)}

-- | Run the effect for an armed operation and complete it (the crash-free path).
-- An unknown or already-completed key is a no-op.
runEffect :: OutboxKey -> DurableOutbox -> DurableOutbox
runEffect key durable = case Map.lookup key (durableJournal durable) of
  Nothing -> durable
  Just record -> case operationPhase record of
    OperationCompleted _ -> durable
    OperationArmed intent ->
      completeInJournal key (intentValue intent) record (applyEffect intent durable)

-- | Arm and apply the effect but do NOT complete — the "crash after effect, before
-- completion (response lost)" substrate. The journal record stays armed while the
-- target is already written.
armAndApply :: OutboxKey -> SetTargetIntent -> DurableOutbox -> DurableOutbox
armAndApply key intent durable = applyEffect intent (armOperation key intent durable)

-- | Recover an armed operation after a restart. Re-observe the target and decide
-- via 'decideOperationRecovery': execute the armed intent only if the effect was
-- provably not applied, recover the observed result if it was applied (WITHOUT
-- re-applying), and fail closed (leaving the record armed) on a diverged or
-- unobservable target. An unknown or already-terminal key is a no-op.
recoverOperation
  :: OutboxKey
  -> DurableOutbox
  -> Either OperationRecoveryRefusal DurableOutbox
recoverOperation key durable = case Map.lookup key (durableJournal durable) of
  Nothing -> Right durable
  Just record -> case operationPhase record of
    OperationCompleted _ -> Right durable
    OperationArmed intent ->
      case decideOperationRecovery effectMatches intent (outboxObservation intent durable) of
        Left refusal -> Left refusal
        Right recovery ->
          let (applied, result) = case recovery of
                ExecuteArmedOperation exeIntent -> (applyEffect exeIntent durable, intentValue exeIntent)
                RecoverObservedOperation observed -> (durable, observed)
           in Right (completeInJournal key result record applied)

-- | Look up a completed operation's terminal result (its result lookup), or
-- @Nothing@ while still armed or unknown.
lookupResult :: OutboxKey -> DurableOutbox -> Maybe TargetValue
lookupResult key durable = Map.lookup key (durableJournal durable) >>= operationResult
