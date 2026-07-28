{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 4.48: the retained Lifecycle Authority's durable operation record and
-- outbox recovery.
--
-- Each retained lifecycle operation is a durable record moving append-only
-- through @OperationArmed intent -> OperationCompleted result@: the authority
-- durably journals the committed outbox @intent@ BEFORE any external effect, and
-- records the terminal @result@ at most once. On restart a record is resumed
-- from its durable phase; an armed operation is recovered at-most-once — the
-- interpreter re-observes the effect target and NEVER converts unknown or
-- divergent target state into permission to repeat a non-idempotent effect.
--
-- This generalizes 'Prodbox.Bootstrap.Broker.RequestJournal' (its idempotency-
-- keyed Armed/Terminal phase and @decideBrokerEffectRecovery@) for the
-- authority's typed operation intents and results. The module is pure: the
-- interpreter supplies the effect and the recovery observation.
module Prodbox.Lifecycle.Authority.Operation
  ( -- * Durable record
    OperationPhase (..)
  , OperationRecord (..)
  , operationIntent
  , operationResult

    -- * Journal transitions
  , OperationResume (..)
  , OperationJournalRefusal (..)
  , newArmedOperation
  , resumeOperation
  , completeOperation

    -- * At-most-once recovery
  , OperationEffectObservation (..)
  , OperationRecovery (..)
  , OperationRecoveryRefusal (..)
  , decideOperationRecovery
  )
where

import Codec.Serialise (Serialise)
import GHC.Generics (Generic)

-- | The durable, append-only phase of one operation record.
data OperationPhase intent result
  = -- | The committed outbox intent, durably journaled before any external effect.
    OperationArmed !intent
  | -- | The terminal result, recorded at most once after the effect is applied.
    OperationCompleted !result
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | One durable operation: its idempotency-keyed binding plus its append-only
-- phase. @binding@ is the caller-owned operation identity (opaque here).
data OperationRecord binding intent result = OperationRecord
  { operationBinding :: !binding
  , operationPhase :: !(OperationPhase intent result)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The armed intent of a record, or @Nothing@ once terminal.
operationIntent :: OperationRecord binding intent result -> Maybe intent
operationIntent record = case operationPhase record of
  OperationArmed intent -> Just intent
  OperationCompleted _ -> Nothing

-- | The terminal result of a record, or @Nothing@ while still armed.
operationResult :: OperationRecord binding intent result -> Maybe result
operationResult record = case operationPhase record of
  OperationArmed _ -> Nothing
  OperationCompleted result -> Just result

data OperationResume intent result
  = ResumeArmedOperation !intent
  | ReplayCompletedOperation !result
  deriving (Eq, Show)

data OperationJournalRefusal
  = -- | The observed record's binding is not the exact expected idempotency identity.
    OperationBindingConflict
  | -- | Attempt to record a terminal result over an already-terminal record.
    OperationCompletedRewriteRefused
  deriving (Eq, Show)

-- | A fresh armed operation record. The interpreter persists this BEFORE it runs
-- the effect, so recovery always finds the committed intent.
newArmedOperation :: binding -> intent -> OperationRecord binding intent result
newArmedOperation binding intent =
  OperationRecord {operationBinding = binding, operationPhase = OperationArmed intent}

-- | Resume a durable record against the exact expected binding. An armed record
-- resumes its committed intent (recover it at-most-once via
-- 'decideOperationRecovery'); a terminal record replays its recorded result.
resumeOperation
  :: (Eq binding)
  => binding
  -> OperationRecord binding intent result
  -> Either OperationJournalRefusal (OperationResume intent result)
resumeOperation expected record
  | operationBinding record /= expected = Left OperationBindingConflict
  | otherwise = Right $ case operationPhase record of
      OperationArmed intent -> ResumeArmedOperation intent
      OperationCompleted result -> ReplayCompletedOperation result

-- | Record a terminal result append-only (rewriting an already-terminal record is
-- refused). Validates the exact expected binding.
completeOperation
  :: (Eq binding)
  => binding
  -> result
  -> OperationRecord binding intent result
  -> Either OperationJournalRefusal (OperationRecord binding intent result)
completeOperation expected result record
  | operationBinding record /= expected = Left OperationBindingConflict
  | otherwise = case operationPhase record of
      OperationArmed _ -> Right record {operationPhase = OperationCompleted result}
      OperationCompleted _ -> Left OperationCompletedRewriteRefused

-- | What re-observing an armed operation's effect target found on recovery.
data OperationEffectObservation result
  = -- | The effect has NOT been applied; the committed source is still current.
    OperationSourceStillCurrent
  | -- | The effect HAS been applied; this is the observed terminal result.
    OperationTargetReached !result
  | -- | The observed target state does not match the committed intent.
    OperationTargetDiverged
  | -- | The target could not be observed; fail closed.
    OperationTargetUnobservable
  deriving (Eq, Show)

data OperationRecovery intent result
  = -- | Safe to (re-)execute the armed intent; the effect had not been applied.
    ExecuteArmedOperation !intent
  | -- | The effect was already applied and matches; recover its result, do NOT repeat.
    RecoverObservedOperation !result
  deriving (Eq, Show)

data OperationRecoveryRefusal
  = -- | An applied effect whose observed result does not satisfy the armed intent.
    OperationRecoveryResultMismatch
  | -- | The target diverged from the committed intent.
    OperationRecoveryTargetDiverged
  | -- | The target could not be observed.
    OperationRecoveryObservationUnavailable
  deriving (Eq, Show)

-- | Decide recovery for an armed operation WITHOUT converting unknown or
-- divergent target state into permission to repeat a non-idempotent effect. The
-- caller supplies @matches@ — whether an observed result satisfies the committed
-- intent's expected outcome. Only 'OperationSourceStillCurrent' (effect provably
-- not applied) authorizes execution; a matching applied effect is recovered, not
-- repeated; every other observation fails closed.
decideOperationRecovery
  :: (intent -> result -> Bool)
  -> intent
  -> OperationEffectObservation result
  -> Either OperationRecoveryRefusal (OperationRecovery intent result)
decideOperationRecovery matches intent observation = case observation of
  OperationSourceStillCurrent -> Right (ExecuteArmedOperation intent)
  OperationTargetReached result
    | matches intent result -> Right (RecoverObservedOperation result)
    | otherwise -> Left OperationRecoveryResultMismatch
  OperationTargetDiverged -> Left OperationRecoveryTargetDiverged
  OperationTargetUnobservable -> Left OperationRecoveryObservationUnavailable
