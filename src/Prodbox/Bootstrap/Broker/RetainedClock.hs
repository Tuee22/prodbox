{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Retained-clock admission for the Bootstrap Broker. This transaction is
-- separate from the unvalidated runtime clock and MinIO store. Its store must
-- bind one established clock identity to a linearizable, rollback-protected
-- revision; neither creation nor migration is supplied here.
module Prodbox.Bootstrap.Broker.RetainedClock
  ( RetainedClockSnapshot (..)
  , RetainedClockCasResult (..)
  , RetainedClockStore (..)
  , RetainedElapsedClock (..)
  , RetainedClockReading
  , rawClockReadingFromSignedInterval
  , observeRetainedClock
  , readRetainedClockReading
  )
where

import Control.Exception (IOException, evaluate, try)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , AuthorityInstant
  , ClockFailure (ClockUnreadable)
  , ClockSkewBound
  , RawClockReading (ClockSampled)
  , classifyAuthorityClock
  , clockUncertaintyFromMicros
  , clockUncertaintyMicros
  , highWaterFromMicros
  , highWaterMicros
  , initialHighWater
  , recordTrustedInstant
  )
import Prodbox.ControlPlane.Deadline (Deadline, MonotonicInstant, deadlineExpired)
import Prodbox.ControlPlane.Interpreter
  ( DeadlineEffectResult (..)
  , observeDeadlineEffectWithin
  , realMonotonicNow
  )
import Prodbox.ControlPlane.SignedTimeBounds
  ( ElapsedClockSample
  , SignedTimeBoundError (SignedTimeIntervalInverted)
  , SignedTimeInterval (..)
  , TimeScaleMovementBound
  , ageSignedTimeInterval
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)

-- | The revision must be durable, strictly increasing and never reused for
-- this already-established identity, including across recovery and restart.
data RetainedClockSnapshot = RetainedClockSnapshot
  { retainedClockRevision :: !Natural
  , retainedClockHighWaterMicros :: !Natural
  }
  deriving stock (Eq, Show)

data RetainedClockCasResult
  = RetainedClockCasApplied
  | RetainedClockCasConflict
  | RetainedClockCasUnobservable
  deriving stock (Eq, Show)

-- | The CAS must compare the exact snapshot and atomically write the proposed
-- snapshot; failures after dispatch are unobservable, not evidence of absence.
-- Both calls must respect the supplied deadline at their interpreter boundary.
data RetainedClockStore = RetainedClockStore
  { readRetainedClock :: Deadline -> IO (Maybe RetainedClockSnapshot)
  , casRetainedClock
      :: Deadline -> RetainedClockSnapshot -> RetainedClockSnapshot -> IO RetainedClockCasResult
  }

-- | The reader must continuously sample one suspend-aware elapsed-clock domain.
-- The rate and time-scale movement bounds must hold throughout every use of an
-- admitted reading. Constructing this record proves none of those assumptions.
data RetainedElapsedClock = RetainedElapsedClock
  { retainedElapsedNow :: IO ElapsedClockSample
  , retainedElapsedSlowPartsPerMillion :: !Natural
  , retainedElapsedTimeScaleMovement :: !TimeScaleMovementBound
  }

-- The constructor is private. An admitted sample retains its elapsed-clock
-- action and must be re-sampled before each use.
data RetainedClockReading
  = RetainedClockRefused !AuthorityClockObservation
  | RetainedClockAdmitted
      !Deadline
      !ClockSkewBound
      !AuthorityInstant
      !Natural
      !RetainedElapsedClock
      !ElapsedClockSample
      !ElapsedClockSample
      !MonotonicInstant

unavailable :: AuthorityClockObservation
unavailable = AuthorityTimeUnobservable (ClockUnreadable "retained clock admission unavailable")

-- | Convert a closed interval to a symmetric raw sample, rounding outward.
-- This does not authenticate the interval or make it a trusted clock reading.
rawClockReadingFromSignedInterval
  :: SignedTimeInterval -> Either SignedTimeBoundError RawClockReading
rawClockReadingFromSignedInterval interval
  | lower > upper = Left SignedTimeIntervalInverted
  | otherwise =
      Right (ClockSampled (authorityTimeFromMicros midpoint) (clockUncertaintyFromMicros uncertainty))
 where
  lower = signedTimeLowerMicros interval
  upper = signedTimeUpperMicros interval
  midpoint = lower + (upper - lower) `div` 2
  uncertainty = upper - midpoint

-- | The returned observation is valid only at the new elapsed sample and must
-- not be reused. A later concurrent watermark advance does not revoke this
-- reading: production still requires an ordering or revocation protocol.
readRetainedClockReading :: RetainedClockReading -> IO AuthorityClockObservation
readRetainedClockReading reading = case reading of
  RetainedClockRefused refusal -> pure refusal
  RetainedClockAdmitted deadline _ _ _ elapsed _ _ _ -> do
    result <-
      observeDeadlineEffectWithin
        deadline
        (try transaction :: IO (Either IOException AuthorityClockObservation))
    pure $ case result of
      Just (DeadlineEffectCompleted _ (Right observation)) -> observation
      _ -> unavailable
   where
    transaction = do
      elapsedNow <- retainedElapsedNow elapsed
      monotonicNow <- realMonotonicNow
      evaluate (retainedClockAt monotonicNow elapsedNow reading)

retainedClockAt
  :: MonotonicInstant -> ElapsedClockSample -> RetainedClockReading -> AuthorityClockObservation
retainedClockAt monotonicNow elapsedNow reading = case reading of
  RetainedClockRefused refusal -> refusal
  RetainedClockAdmitted deadline skew instant uncertainty elapsed sampleStart validAfter readyAt
    | deadlineExpired monotonicNow deadline -> unavailable
    | monotonicNow < readyAt -> unavailable
    | elapsedNow < validAfter -> unavailable
    | otherwise ->
        case ageSignedTimeInterval
          (retainedElapsedSlowPartsPerMillion elapsed)
          (retainedElapsedTimeScaleMovement elapsed)
          sampleStart
          elapsedNow
          originalInterval of
          Left _ -> unavailable
          Right aged ->
            let lower = signedTimeLowerMicros aged
                upper = signedTimeUpperMicros aged
                widened = max (instantMicros - min instantMicros lower) (upper - min upper instantMicros)
             in classifyAuthorityClock
                  skew
                  (initialHighWater instant)
                  (ClockSampled instant (clockUncertaintyFromMicros widened))
   where
    instantMicros = authorityTimeMicros instant
    originalInterval =
      SignedTimeInterval
        (instantMicros - min instantMicros uncertainty)
        (instantMicros + uncertainty)

-- | Admit a sample only after a CAS and exact read-back of its high-water mark.
-- Even an equal sample advances the revision. Timeout is not a settlement
-- receipt. The source must refer to an instant within its call; the separately
-- supplied elapsed clock and the store must satisfy their documented contracts.
observeRetainedClock
  :: Deadline
  -> ClockSkewBound
  -> RetainedElapsedClock
  -> IO RawClockReading
  -> RetainedClockStore
  -> IO RetainedClockReading
observeRetainedClock deadline skew elapsed readClock store
  | retainedElapsedSlowPartsPerMillion elapsed >= 1000000 = pure (RetainedClockRefused unavailable)
  | otherwise = observe
 where
  observe = do
    result <-
      observeDeadlineEffectWithin
        deadline
        (try (transaction >>= evaluate) :: IO (Either IOException RetainedClockReading))
    pure $ case result of
      Just (DeadlineEffectCompleted completed (Right observation)) -> anchorCompletion completed observation
      _ -> RetainedClockRefused unavailable
  anchorCompletion completed observation = case observation of
    RetainedClockRefused _ -> observation
    RetainedClockAdmitted
      originalDeadline
      originalSkew
      instant
      uncertainty
      clock
      sampleStart
      validAfter
      _ ->
        RetainedClockAdmitted
          originalDeadline
          originalSkew
          instant
          uncertainty
          clock
          sampleStart
          validAfter
          completed
  transaction = do
    existing <- readRetainedClock store deadline
    case existing of
      Nothing -> pure (RetainedClockRefused unavailable)
      Just snapshot -> do
        beforeClock <- retainedElapsedNow elapsed
        reading <- readClock
        let oldHighWater = highWaterFromMicros (retainedClockHighWaterMicros snapshot)
            observation = classifyAuthorityClock skew oldHighWater reading
        case observation of
          AuthorityTimeTrusted instant uncertainty -> do
            let proposed =
                  RetainedClockSnapshot
                    { retainedClockRevision = retainedClockRevision snapshot + 1
                    , retainedClockHighWaterMicros = highWaterMicros (recordTrustedInstant oldHighWater observation)
                    }
            applied <- casRetainedClock store deadline snapshot proposed
            case applied of
              RetainedClockCasApplied -> do
                readBack <- readRetainedClock store deadline
                elapsedAfter <- retainedElapsedNow elapsed
                monotonicAfter <- realMonotonicNow
                let candidate =
                      RetainedClockAdmitted
                        deadline
                        skew
                        instant
                        (clockUncertaintyMicros uncertainty)
                        elapsed
                        beforeClock
                        elapsedAfter
                        monotonicAfter
                pure $
                  if readBack /= Just proposed
                    then RetainedClockRefused unavailable
                    else case retainedClockAt monotonicAfter elapsedAfter candidate of
                      AuthorityTimeTrusted {} -> candidate
                      refusal -> RetainedClockRefused refusal
              RetainedClockCasConflict -> pure (RetainedClockRefused unavailable)
              RetainedClockCasUnobservable -> pure (RetainedClockRefused unavailable)
          _ -> pure (RetainedClockRefused observation)
