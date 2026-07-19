{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}

-- | Sprint 1.62 deliverable 1 (durable half): the SERIALIZABLE authority clock,
-- kept deliberately distinct from the process-local monotonic
-- 'Prodbox.ControlPlane.Deadline.MonotonicInstant'. An 'AuthorityInstant' is a
-- durable, persisted authority-clock timestamp (reusing
-- 'Prodbox.Lifecycle.Lease.AuthorityTime'); a monotonic instant is comparable
-- only within one process run. This module supplies:
--
--   * a durable monotonic high-water mark that only ever advances;
--   * a fail-closed classifier that REFUSES a reading which regresses below the
--     high-water mark or whose uncertainty exceeds a skew bound; and
--   * a stored absolute 'OperationDeadline' that survives process restart
--     WITHOUT extension — re-loading it after downtime yields the SAME absolute
--     deadline, and downtime is charged against it, never reset.
--
-- All arithmetic is non-wrapping 'Natural' micros; the module performs NO clock
-- read (it is 100% pure). Serialization is through the 'Natural' projections
-- (matching the Lease wire pattern), never an orphan instance on 'AuthorityTime'.
module Prodbox.ControlPlane.AuthorityClock
  ( -- * Serializable authority instant (reuses Lease.AuthorityTime)
    AuthorityInstant

    -- * Reading precision (allows 0) and skew bound (strictly positive)
  , ClockUncertainty
  , clockUncertaintyFromMicros
  , clockUncertaintyMicros
  , ClockSkewBound
  , mkClockSkewBound
  , clockSkewBoundMicros
  , AuthorityClockError (..)

    -- * Durable monotonic high-water mark (only advances)
  , AuthorityClockHighWater
  , initialHighWater
  , highWaterInstant
  , highWaterMicros
  , highWaterFromMicros
  , recordTrustedInstant

    -- * Reading and fail-closed classification
  , RawClockReading (..)
  , ClockFailure (..)
  , AuthorityClockObservation (..)
  , classifyAuthorityClock

    -- * Stored operation deadline (survives restart WITHOUT extension)
  , OperationDeadline
  , deriveOperationDeadline
  , operationDeadlineInstant
  , operationDeadlineMicros
  , operationDeadlineFromMicros

    -- * Restart re-derivation into the process-local monotonic domain
  , AttemptDeadlineRefusal (..)
  , deriveAttemptDeadline
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RemainingDuration (RemainingDuration)
  , deadlineAtOffset
  , tightenDeadline
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , addAuthorityDuration
  , authorityTimeFromMicros
  , authorityTimeMicros
  )

-- | A durable, serializable authority-clock timestamp. Reuses the lease
-- authority clock so freshness reasoning stays on one durable time domain.
type AuthorityInstant = AuthorityTime

-- | The half-width uncertainty of a clock reading (micros). Unlike a lease
-- duration, @0@ is legal — a perfectly-synced reading has zero uncertainty.
-- Constructor unexported so it always originates from a reading.
newtype ClockUncertainty = ClockUncertainty Natural
  deriving stock (Eq, Ord, Show)

clockUncertaintyFromMicros :: Natural -> ClockUncertainty
clockUncertaintyFromMicros = ClockUncertainty

clockUncertaintyMicros :: ClockUncertainty -> Natural
clockUncertaintyMicros (ClockUncertainty micros) = micros

-- | The strictly-positive ceiling on a reading's uncertainty; a wider reading
-- is refused as unobservable. Constructor unexported: build via 'mkClockSkewBound'.
newtype ClockSkewBound = ClockSkewBound Natural
  deriving stock (Eq, Ord, Show)

data AuthorityClockError = ClockSkewBoundMustBePositive
  deriving stock (Eq, Show)

mkClockSkewBound :: Natural -> Either AuthorityClockError ClockSkewBound
mkClockSkewBound value
  | value == 0 = Left ClockSkewBoundMustBePositive
  | otherwise = Right (ClockSkewBound value)

clockSkewBoundMicros :: ClockSkewBound -> Natural
clockSkewBoundMicros (ClockSkewBound micros) = micros

-- | The durable monotonic high-water mark. Only ever advances (via a trusted
-- reading). Constructor unexported so it can only rise through
-- 'recordTrustedInstant' or be seeded/reloaded from storage.
newtype AuthorityClockHighWater = AuthorityClockHighWater AuthorityInstant
  deriving stock (Eq, Ord, Show)

-- | Seed the mark once, from an unsealed-epoch authority instant.
initialHighWater :: AuthorityInstant -> AuthorityClockHighWater
initialHighWater = AuthorityClockHighWater

highWaterInstant :: AuthorityClockHighWater -> AuthorityInstant
highWaterInstant (AuthorityClockHighWater instant) = instant

highWaterMicros :: AuthorityClockHighWater -> Natural
highWaterMicros = authorityTimeMicros . highWaterInstant

-- | Trusted reload of a persisted mark (identity round-trip with 'highWaterMicros').
highWaterFromMicros :: Natural -> AuthorityClockHighWater
highWaterFromMicros = AuthorityClockHighWater . authorityTimeFromMicros

-- | A raw authority-clock reading: either a sample with its uncertainty, or an
-- unavailability reason.
data RawClockReading
  = ClockSampled !AuthorityInstant !ClockUncertainty
  | ClockUnavailable !Text
  deriving stock (Eq, Show)

data ClockFailure
  = ClockUnreadable !Text
  | ClockUncertaintyTooWide !ClockUncertainty !ClockSkewBound
  deriving stock (Eq, Show)

-- | Fail-closed classification of a reading against the skew bound and the
-- high-water mark. Regression below the mark and over-wide uncertainty are both
-- refused; "cannot observe" is never treated as "fresh".
data AuthorityClockObservation
  = -- | Reading accepted at or after the high-water mark, within skew.
    AuthorityTimeTrusted !AuthorityInstant !ClockUncertainty
  | -- | Reading regressed below the high-water mark (observed, high-water).
    AuthorityTimeRegressed !AuthorityInstant !AuthorityInstant
  | -- | Reading unobservable (unavailable or too imprecise).
    AuthorityTimeUnobservable !ClockFailure
  deriving stock (Eq, Show)

classifyAuthorityClock
  :: ClockSkewBound
  -> AuthorityClockHighWater
  -> RawClockReading
  -> AuthorityClockObservation
classifyAuthorityClock (ClockSkewBound bound) hw = \case
  ClockUnavailable detail -> AuthorityTimeUnobservable (ClockUnreadable detail)
  ClockSampled instant uncertainty
    | clockUncertaintyMicros uncertainty > bound ->
        AuthorityTimeUnobservable (ClockUncertaintyTooWide uncertainty (ClockSkewBound bound))
    | instant < highWaterInstant hw ->
        AuthorityTimeRegressed instant (highWaterInstant hw)
    | otherwise -> AuthorityTimeTrusted instant uncertainty

-- | Advance the mark only on a trusted reading strictly later than the current
-- mark. Every refused (or equal/earlier) reading leaves the mark unchanged —
-- the mark is monotone by construction.
recordTrustedInstant
  :: AuthorityClockHighWater
  -> AuthorityClockObservation
  -> AuthorityClockHighWater
recordTrustedInstant hw = \case
  AuthorityTimeTrusted instant _
    | instant > highWaterInstant hw -> AuthorityClockHighWater instant
  _ -> hw

-- | An absolute authority-clock deadline persisted with an operation. Survives
-- restart: reload is the identity, and downtime is charged against the same
-- absolute instant. Constructor unexported.
newtype OperationDeadline = OperationDeadline AuthorityInstant
  deriving stock (Eq, Ord, Show)

-- | Derive the operation deadline once, when the operation is accepted:
-- @acceptedAt + budget@.
deriveOperationDeadline :: AuthorityInstant -> AuthorityDuration -> OperationDeadline
deriveOperationDeadline acceptedAt budget =
  OperationDeadline (addAuthorityDuration acceptedAt budget)

operationDeadlineInstant :: OperationDeadline -> AuthorityInstant
operationDeadlineInstant (OperationDeadline instant) = instant

operationDeadlineMicros :: OperationDeadline -> Natural
operationDeadlineMicros (OperationDeadline instant) = authorityTimeMicros instant

-- | Trusted reload of a persisted deadline (identity round-trip).
operationDeadlineFromMicros :: Natural -> OperationDeadline
operationDeadlineFromMicros = OperationDeadline . authorityTimeFromMicros

data AttemptDeadlineRefusal
  = -- | Clock regressed below the high-water mark (observed, high-water).
    AttemptClockRegressed !AuthorityInstant !AuthorityInstant
  | -- | Clock unobservable.
    AttemptClockUnobservable !ClockFailure
  | -- | The stored deadline is already at/before the conservative-now instant.
    AttemptDeadlineElapsed !OperationDeadline !AuthorityInstant
  deriving stock (Eq, Show)

-- | Re-derive a process-local attempt deadline from a durable stored deadline
-- after a (possibly restarted) attempt begins. The remaining authority budget
-- is @storedDeadline - (now + uncertainty)@ — it only ever shrinks as authority
-- time advances, so downtime is charged, never reset; the result is finally
-- clamped to no later than the process-local request deadline.
deriveAttemptDeadline
  :: MonotonicInstant
  -- ^ monotonic sample taken at the SAME moment as the authority reading
  -> Deadline
  -- ^ process-local request deadline (the attempt may not outlive it)
  -> AuthorityClockObservation
  -- ^ must be Trusted to succeed
  -> OperationDeadline
  -- ^ durable stored absolute deadline
  -> Either AttemptDeadlineRefusal Deadline
deriveAttemptDeadline monoSample requestDeadline obs op = case obs of
  AuthorityTimeUnobservable failure -> Left (AttemptClockUnobservable failure)
  AuthorityTimeRegressed observed hw -> Left (AttemptClockRegressed observed hw)
  AuthorityTimeTrusted nowAuth uncertainty ->
    let deadlineMicros = operationDeadlineMicros op
        conservativeNow = authorityTimeMicros nowAuth + clockUncertaintyMicros uncertainty
     in if deadlineMicros <= conservativeNow
          then Left (AttemptDeadlineElapsed op (authorityTimeFromMicros conservativeNow))
          else
            Right
              ( tightenDeadline
                  (deadlineAtOffset monoSample (RemainingDuration (deadlineMicros - conservativeNow)))
                  requestDeadline
              )
