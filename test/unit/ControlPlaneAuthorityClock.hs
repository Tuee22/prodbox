{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.62 deliverable 1 (durable half): the serializable authority clock.
-- Proves the fail-closed classifier (skew / regression / unobservability refusal),
-- the monotone high-water mark (downtime cannot lower it), and the crux property
-- that a stored 'OperationDeadline' survives restart WITHOUT extension — downtime
-- is charged against the same absolute authority instant, never reset.
module ControlPlaneAuthorityClock
  ( controlPlaneAuthorityClockSuite
  )
where

import Data.Either (isLeft, isRight)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityClock
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , deadlineFromInstant
  , deadlineInstant
  , monotonicInstantFromMicros
  , monotonicInstantMicros
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Test.Tasty.QuickCheck (NonNegative (..), Small (..))
import TestSupport

at :: Natural -> AuthorityTime
at = authorityTimeFromMicros

unc :: Natural -> ClockUncertainty
unc = clockUncertaintyFromMicros

mi :: Natural -> MonotonicInstant
mi = monotonicInstantFromMicros

dl :: Natural -> Deadline
dl = deadlineFromInstant . mi

dur :: Natural -> AuthorityDuration
dur n = either (error . show) id (authorityDurationFromMicros n)

skew :: ClockSkewBound
skew = either (error . show) id (mkClockSkewBound 500)

hw :: AuthorityClockHighWater
hw = highWaterFromMicros 1_000_000

-- | The crux driver: a fixed monotonic sample and request deadline, and a fixed
-- stored operation deadline of authority-micros 2_000_000. Only the observation
-- varies. Result is projected to the derived deadline's monotonic micros so the
-- authority-time arithmetic is isolated.
deriveMicros :: AuthorityClockObservation -> Either AttemptDeadlineRefusal Natural
deriveMicros obs =
  fmap
    (monotonicInstantMicros . deadlineInstant)
    (deriveAttemptDeadline (mi 5_000_000) (dl 9_000_000) obs (operationDeadlineFromMicros 2_000_000))

recordNeverLowersProperty :: NonNegative (Small Int) -> Bool
recordNeverLowersProperty (NonNegative (Small n)) =
  highWaterMicros (recordTrustedInstant hw (AuthorityTimeTrusted (at (fromIntegral n)) (unc 0)))
    >= highWaterMicros hw

reloadHighWaterIdentityProperty :: NonNegative (Small Int) -> Bool
reloadHighWaterIdentityProperty (NonNegative (Small n)) =
  highWaterMicros (highWaterFromMicros (fromIntegral n)) == fromIntegral n

reloadOperationDeadlineIdentityProperty :: NonNegative (Small Int) -> Bool
reloadOperationDeadlineIdentityProperty (NonNegative (Small n)) =
  operationDeadlineMicros (operationDeadlineFromMicros (fromIntegral n)) == fromIntegral n

-- | For any downtime Δ (kept under the 1_000_000-micro budget), the derived
-- deadline is @6_000_000 − Δ@: downtime is charged against the same absolute
-- authority deadline, never reset.
downtimeShrinksProperty :: NonNegative (Small Int) -> Bool
downtimeShrinksProperty (NonNegative (Small raw)) =
  let delta = fromIntegral (raw `mod` 900000) :: Natural
      obs = AuthorityTimeTrusted (at (1_000_000 + delta)) (unc 0)
   in deriveMicros obs == Right (6_000_000 - delta)

controlPlaneAuthorityClockSuite :: SuiteBuilder ()
controlPlaneAuthorityClockSuite =
  describe "Sprint 1.62 AuthorityClock" $ do
    describe "mkClockSkewBound" $ do
      it "rejects a zero skew bound" $
        mkClockSkewBound 0 `shouldSatisfy` isLeft
      it "accepts a positive skew bound" $
        mkClockSkewBound 500 `shouldSatisfy` isRight

    describe "classifyAuthorityClock (fail-closed)" $ do
      it "an unavailable clock is unobservable" $
        classifyAuthorityClock skew hw (ClockUnavailable "x")
          `shouldBe` AuthorityTimeUnobservable (ClockUnreadable "x")
      it "a fresh in-skew reading is trusted" $
        classifyAuthorityClock skew hw (ClockSampled (at 1_000_500) (unc 100))
          `shouldBe` AuthorityTimeTrusted (at 1_000_500) (unc 100)
      it "a reading exactly at the high-water mark is trusted" $
        classifyAuthorityClock skew hw (ClockSampled (at 1_000_000) (unc 0))
          `shouldBe` AuthorityTimeTrusted (at 1_000_000) (unc 0)
      it "a reading below the high-water mark is regressed" $
        classifyAuthorityClock skew hw (ClockSampled (at 999_999) (unc 100))
          `shouldBe` AuthorityTimeRegressed (at 999_999) (at 1_000_000)
      it "an over-wide reading is unobservable" $
        classifyAuthorityClock skew hw (ClockSampled (at 1_000_500) (unc 600))
          `shouldBe` AuthorityTimeUnobservable (ClockUncertaintyTooWide (unc 600) skew)

    describe "high-water mark monotonicity" $ do
      it "advances on a later trusted reading" $
        highWaterMicros (recordTrustedInstant hw (AuthorityTimeTrusted (at 1_000_500) (unc 0)))
          `shouldBe` 1_000_500
      it "does not move on a regressed reading" $
        highWaterMicros (recordTrustedInstant hw (AuthorityTimeRegressed (at 999_999) (at 1_000_000)))
          `shouldBe` 1_000_000
      it "does not move on an unobservable reading" $
        highWaterMicros (recordTrustedInstant hw (AuthorityTimeUnobservable (ClockUnreadable "x")))
          `shouldBe` 1_000_000
      it "does not move on an equal trusted reading" $
        highWaterMicros (recordTrustedInstant hw (AuthorityTimeTrusted (at 1_000_000) (unc 0)))
          `shouldBe` 1_000_000
      propertyTest "recording never lowers the mark" recordNeverLowersProperty
      propertyTest "reload round-trips the mark" reloadHighWaterIdentityProperty

    describe "OperationDeadline survives restart without extension" $ do
      propertyTest "reload is identity" reloadOperationDeadlineIdentityProperty
      it "derive is acceptedAt + budget" $
        operationDeadlineMicros (deriveOperationDeadline (at 1_000_000) (dur 1_000_000))
          `shouldBe` 2_000_000

    describe "deriveAttemptDeadline" $ do
      it "first attempt: remaining budget from a trusted reading" $
        deriveMicros (AuthorityTimeTrusted (at 1_000_000) (unc 0)) `shouldBe` Right 6_000_000
      it "restart after downtime charges the gap, does not reset" $
        deriveMicros (AuthorityTimeTrusted (at 1_300_000) (unc 0)) `shouldBe` Right 5_700_000
      it "uncertainty is subtracted as an upper bound on now" $
        deriveMicros (AuthorityTimeTrusted (at 1_000_000) (unc 200)) `shouldBe` Right 5_999_800
      it "downtime past the deadline is elapsed" $
        deriveMicros (AuthorityTimeTrusted (at 2_100_000) (unc 0))
          `shouldBe` Left (AttemptDeadlineElapsed (operationDeadlineFromMicros 2_000_000) (at 2_100_000))
      it "a reading exactly at the deadline is elapsed" $
        deriveMicros (AuthorityTimeTrusted (at 2_000_000) (unc 0))
          `shouldBe` Left (AttemptDeadlineElapsed (operationDeadlineFromMicros 2_000_000) (at 2_000_000))
      it "a regressed observation refuses" $
        deriveMicros (AuthorityTimeRegressed (at 999_999) (at 1_000_000))
          `shouldBe` Left (AttemptClockRegressed (at 999_999) (at 1_000_000))
      it "an unobservable observation refuses" $
        deriveMicros (AuthorityTimeUnobservable (ClockUnreadable "x"))
          `shouldBe` Left (AttemptClockUnobservable (ClockUnreadable "x"))
      it "the process-local request deadline clamps a looser derived deadline" $
        fmap
          (monotonicInstantMicros . deadlineInstant)
          ( deriveAttemptDeadline
              (mi 5_000_000)
              (dl 5_500_000)
              (AuthorityTimeTrusted (at 1_000_000) (unc 0))
              (operationDeadlineFromMicros 2_000_000)
          )
          `shouldBe` Right 5_500_000
      propertyTest "downtime monotonically shrinks remaining, never resets" downtimeShrinksProperty
