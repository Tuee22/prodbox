{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 1.61 Increment B: a process-local MONOTONIC absolute deadline, kept
-- deliberately distinct from durable 'Prodbox.Lifecycle.Lease.AuthorityTime'.
-- AuthorityTime is persisted and drives freshness/staleness of authority
-- evidence; a 'MonotonicInstant' is comparable only within one process run, is
-- never serialized, never compared to AuthorityTime, and is sourced from the
-- boundary's monotonic clock (never wall time). All arithmetic is non-wrapping
-- 'Natural' micros; this module performs NO clock read (it is 100% pure).
module Prodbox.ControlPlane.Deadline
  ( -- * Monotonic instant (opaque)
    MonotonicInstant
  , monotonicInstantFromMicros
  , monotonicInstantMicros

    -- * Deadline (opaque)
  , Deadline
  , deadlineFromInstant
  , deadlineAtOffset
  , deadlineInstant

    -- * Durations (transparent value carriers)
  , RemainingDuration (..)
  , RetryAfter (..)

    -- * Observation
  , DeadlineObservation (..)
  , deadlineObservation
  , deadlineExpired

    -- * Work estimate (transparent value carrier)
  , WorkEstimate (..)

    -- * Deadline-feasibility fold (deliverable-1 admission feasibility)
  , DeadlineAdmission (..)
  , deadlineAdmission

    -- * Cancellation propagation: tighten-only combinator
  , tightenDeadline

    -- * Cancellation propagation: proof-shaped scope (extension unrepresentable)
  , DeadlineScope
  , rootScope
  , scopeDeadline
  , narrowScope
  , narrowScopeToBudget
  )
where

import Numeric.Natural (Natural)

-- | A monotonic-clock reading in micros since an arbitrary process-local epoch.
-- Only differences between two instants are meaningful; ctor unexported so an
-- instant always originates from the clock.
newtype MonotonicInstant = MonotonicInstant Natural
  deriving stock (Eq, Ord, Show)

monotonicInstantFromMicros :: Natural -> MonotonicInstant
monotonicInstantFromMicros = MonotonicInstant

monotonicInstantMicros :: MonotonicInstant -> Natural
monotonicInstantMicros (MonotonicInstant micros) = micros

-- | The one absolute monotonic instant past which admission, queue wait, I/O,
-- read-back, and serialization must all have completed. Ctor unexported so a
-- deadline is always built from a real instant or a budget.
newtype Deadline = Deadline MonotonicInstant
  deriving stock (Eq, Ord, Show)

deadlineFromInstant :: MonotonicInstant -> Deadline
deadlineFromInstant = Deadline

-- | @start + budget@ as an absolute deadline — the only sanctioned way to derive
-- one from a latency budget. Non-wrapping 'Natural' addition.
deadlineAtOffset :: MonotonicInstant -> RemainingDuration -> Deadline
deadlineAtOffset start (RemainingDuration budget) =
  Deadline (MonotonicInstant (monotonicInstantMicros start + budget))

deadlineInstant :: Deadline -> MonotonicInstant
deadlineInstant (Deadline instant) = instant

-- | Non-negative remaining budget (micros). Every child receives this, never a
-- fresh relative timeout that restarts the clock.
newtype RemainingDuration = RemainingDuration Natural
  deriving stock (Eq, Ord, Show)

-- | A retry-no-sooner-than hint (micros) surfaced when a lane is saturated.
newtype RetryAfter = RetryAfter Natural
  deriving stock (Eq, Ord, Show)

data DeadlineObservation
  = DeadlineOpen !RemainingDuration
  | DeadlineExpired
  deriving stock (Eq, Show)

-- | Fold a monotonic reading against a deadline. At-or-past the instant is
-- Expired (fail-closed); strictly-before yields the remaining budget. Guarded
-- subtraction, so 'Natural' cannot underflow.
deadlineObservation :: MonotonicInstant -> Deadline -> DeadlineObservation
deadlineObservation now (Deadline limit)
  | nowMicros >= limitMicros = DeadlineExpired
  | otherwise = DeadlineOpen (RemainingDuration (limitMicros - nowMicros))
 where
  nowMicros = monotonicInstantMicros now
  limitMicros = monotonicInstantMicros limit

deadlineExpired :: MonotonicInstant -> Deadline -> Bool
deadlineExpired now deadline =
  case deadlineObservation now deadline of
    DeadlineExpired -> True
    DeadlineOpen _ -> False

-- | An estimated total cost for a unit of work (queue wait plus own service,
-- micros). Transparent carrier, mirroring 'RemainingDuration'/'RetryAfter'.
newtype WorkEstimate = WorkEstimate Natural
  deriving stock (Eq, Ord, Show)

-- | The fold of "does this estimate fit in the remaining budget". Clock-free:
-- the caller has already folded the monotonic clock via 'deadlineObservation'
-- to obtain the 'RemainingDuration'. Strict @<@ so a cost equal to the budget
-- MISSES, keeping the boundary aligned with 'deadlineObservation' (which is
-- 'DeadlineExpired' at @>=@).
data DeadlineAdmission
  = -- | Slack left after the estimate (non-negative).
    AdmissionWithinDeadline !RemainingDuration
  | -- | Deficit by which the estimate overshoots (non-negative).
    AdmissionMissesDeadline !RemainingDuration
  deriving stock (Eq, Show)

deadlineAdmission :: RemainingDuration -> WorkEstimate -> DeadlineAdmission
deadlineAdmission (RemainingDuration budget) (WorkEstimate estimate)
  | estimate < budget = AdmissionWithinDeadline (RemainingDuration (budget - estimate))
  | otherwise = AdmissionMissesDeadline (RemainingDuration (estimate - budget))

-- | The earlier (tighter) of two deadlines. 'Deadline' derives 'Ord' over its
-- one 'MonotonicInstant', so this is 'min': it can never produce a later
-- deadline than either input.
tightenDeadline :: Deadline -> Deadline -> Deadline
tightenDeadline = min

-- | An opaque authority-to-run-no-later-than. The data constructor is NOT
-- exported, so the only way to derive a child scope is 'narrowScope' /
-- 'narrowScopeToBudget', both of which clamp against the parent with 'min'.
-- Hence a child scope can never outlive its parent, transitively — deadline
-- extension is unrepresentable.
newtype DeadlineScope = DeadlineScope Deadline
  deriving stock (Eq, Ord, Show)

-- | The one boundary mint of a root scope from a freshly-observed deadline.
rootScope :: Deadline -> DeadlineScope
rootScope = DeadlineScope

scopeDeadline :: DeadlineScope -> Deadline
scopeDeadline (DeadlineScope d) = d

-- | Narrow a scope against a candidate deadline, clamping to no later than the
-- parent (a later candidate is discarded).
narrowScope :: DeadlineScope -> Deadline -> DeadlineScope
narrowScope (DeadlineScope parent) candidate =
  DeadlineScope (tightenDeadline parent candidate)

-- | Narrow a scope to @start + budget@, clamped to no later than the parent.
narrowScopeToBudget :: DeadlineScope -> MonotonicInstant -> RemainingDuration -> DeadlineScope
narrowScopeToBudget (DeadlineScope parent) start budget =
  DeadlineScope (tightenDeadline parent (deadlineAtOffset start budget))
