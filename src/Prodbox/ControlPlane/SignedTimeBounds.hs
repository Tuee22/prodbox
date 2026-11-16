{-# LANGUAGE DerivingStrategies #-}

-- | Arithmetic for a nonce-bound signed time claim. This module verifies no
-- signature and establishes no clock trust: callers must independently prove
-- the claim, nonce freshness, server accuracy and the elapsed-clock contract.
module Prodbox.ControlPlane.SignedTimeBounds
  ( ElapsedClockSample
  , elapsedClockSampleFromMicros
  , TimeScaleMovementBound (..)
  , SignedTimeInterval (..)
  , SignedTimeBoundError (..)
  , boundSignedTimeClaim
  , ageSignedTimeInterval
  )
where

import Numeric.Natural (Natural)

-- | An elapsed-clock sample in a single clock domain. It is deliberately
-- distinct from the process-monotonic instants used by request deadlines: an
-- elapsed clock that includes suspend need not share their epoch or rate.
-- Constructing a sample does not validate that clock's rate or continuity.
newtype ElapsedClockSample = ElapsedClockSample Natural
  deriving stock (Eq, Ord, Show)

elapsedClockSampleFromMicros :: Natural -> ElapsedClockSample
elapsedClockSampleFromMicros = ElapsedClockSample

-- | Bounds on authority time-scale movement across the sample interval. The
-- caller must justify the maximum forward rate excess and cumulative forward
-- step, and the maximum net backward movement, independently of the server.
data TimeScaleMovementBound = TimeScaleMovementBound
  { timeScaleFastPartsPerMillion :: !Natural
  , timeScaleForwardStepMicros :: !Natural
  , timeScaleBackwardMovementMicros :: !Natural
  }
  deriving stock (Eq, Show)

-- | Closed conservative bounds on authority time at the final sample, in
-- microseconds. A later consumer must independently age the interval.
data SignedTimeInterval = SignedTimeInterval
  { signedTimeLowerMicros :: !Natural
  , signedTimeUpperMicros :: !Natural
  }
  deriving stock (Eq, Show)

data SignedTimeBoundError
  = SignedTimeZeroRadius
  | SignedTimeClockRateInvalid
  | SignedTimeBracketInverted
  | SignedTimeIntervalInverted
  deriving stock (Eq, Show)

-- | Bound the time at the final sample, given a server midpoint and radius in
-- whole seconds. The signed claim must describe an instant between the first
-- and last samples. The elapsed clock must advance through suspend, and its
-- rate must be at least @(1 - slowPartsPerMillion / 1000000)@ times real time
-- throughout that interval. Those are caller obligations, not checked here.
-- Samples are floored to whole microseconds, so one extra tick is charged.
-- The time scale's forward movement must not exceed real elapsed time plus
-- the supplied rate and cumulative-step allowances. This is an independent
-- obligation: a signed radius at one instant does not bound later time-scale
-- steps or leap-smear rates. A net decrease must not exceed the separately
-- supplied backward-movement allowance.
--
-- An authenticated claim is still only as accurate as the server's stated
-- radius. This function intentionally returns an interval, not a trusted clock
-- observation or permission to use it.
boundSignedTimeClaim
  :: Natural
  -> Natural
  -> Natural
  -> TimeScaleMovementBound
  -> ElapsedClockSample
  -> ElapsedClockSample
  -> Either SignedTimeBoundError SignedTimeInterval
boundSignedTimeClaim midpointSeconds radiusSeconds slowPartsPerMillion timeScaleBound before after
  | radiusSeconds == 0 = Left SignedTimeZeroRadius
  | otherwise =
      ageSignedTimeInterval
        slowPartsPerMillion
        timeScaleBound
        before
        after
        (SignedTimeInterval (midpoint - min midpoint radius) (midpoint + radius))
 where
  midpoint = midpointSeconds * 1000000
  radius = radiusSeconds * 1000000

-- | Widen an interval from its original elapsed sample to a later one. Both
-- samples must come from the same continuous, suspend-aware clock, whose rate
-- and time-scale movement satisfy the supplied bounds over this entire span.
-- The input is an untrusted interval; this function does not authenticate it.
ageSignedTimeInterval
  :: Natural
  -> TimeScaleMovementBound
  -> ElapsedClockSample
  -> ElapsedClockSample
  -> SignedTimeInterval
  -> Either SignedTimeBoundError SignedTimeInterval
ageSignedTimeInterval slowPartsPerMillion timeScaleBound (ElapsedClockSample beforeMicros) (ElapsedClockSample afterMicros) interval
  | slowPartsPerMillion >= partsPerMillion = Left SignedTimeClockRateInvalid
  | afterMicros < beforeMicros = Left SignedTimeBracketInverted
  | signedTimeLowerMicros interval > signedTimeUpperMicros interval = Left SignedTimeIntervalInverted
  | otherwise =
      Right
        SignedTimeInterval
          { signedTimeLowerMicros = lower - min lower (timeScaleBackwardMovementMicros timeScaleBound)
          , signedTimeUpperMicros = signedTimeUpperMicros interval + maxElapsed + maxScaleExcess
          }
 where
  partsPerMillion = 1000000
  lower = signedTimeLowerMicros interval
  ticks = afterMicros - beforeMicros + 1
  rate = partsPerMillion - slowPartsPerMillion
  maxElapsed = (ticks * partsPerMillion + rate - 1) `div` rate
  scaleRateNumerator = maxElapsed * timeScaleFastPartsPerMillion timeScaleBound
  maxScaleExcess =
    (scaleRateNumerator + partsPerMillion - 1) `div` partsPerMillion
      + timeScaleForwardStepMicros timeScaleBound
