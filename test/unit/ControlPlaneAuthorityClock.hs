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

import Control.Concurrent (threadDelay)
import Data.Either (isLeft, isRight)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.RetainedClock
import Prodbox.ControlPlane.AuthorityClock
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineAtOffset
  , deadlineFromInstant
  , deadlineInstant
  , monotonicInstantFromMicros
  , monotonicInstantMicros
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.ControlPlane.SignedTimeBounds
import Prodbox.ControlPlane.SignedTimeSystemClock (sampleBoottime)
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

observeRetainedClockNow
  :: Deadline
  -> ClockSkewBound
  -> IO RawClockReading
  -> RetainedClockStore
  -> IO AuthorityClockObservation
observeRetainedClockNow limit bound source store = do
  reading <- observeRetainedClock limit bound testElapsedClock source store
  readRetainedClockReading reading

testElapsedClock :: RetainedElapsedClock
testElapsedClock = RetainedElapsedClock sampleBoottime 0 (TimeScaleMovementBound 0 0 0)

controlPlaneAuthorityClockSuite :: SuiteBuilder ()
controlPlaneAuthorityClockSuite =
  describe "Sprint 1.62 AuthorityClock" $ do
    describe "signed claim interval arithmetic" $ do
      it "reads advancing suspend-aware elapsed samples on the supported host" $ do
        before <- sampleBoottime
        threadDelay 20000
        after <- sampleBoottime
        case boundSignedTimeClaim 100 3 0 (TimeScaleMovementBound 0 0 0) before after of
          Right interval -> signedTimeUpperMicros interval `shouldSatisfy` (>= 103010000)
          Left failure -> expectationFailure (show failure)
      it "charges the entire rounded request bracket and clock-rate error" $
        boundSignedTimeClaim
          100
          3
          500
          (TimeScaleMovementBound 0 0 0)
          (elapsedClockSampleFromMicros 100)
          (elapsedClockSampleFromMicros 1000100)
          `shouldBe` Right (SignedTimeInterval 97000000 104000502)
      it "saturates the lower edge at the authority epoch" $
        boundSignedTimeClaim
          1
          3
          0
          (TimeScaleMovementBound 0 0 0)
          (elapsedClockSampleFromMicros 0)
          (elapsedClockSampleFromMicros 0)
          `shouldBe` Right (SignedTimeInterval 0 4000001)
      it "refuses a zero radius, invalid rate, and inverted samples" $ do
        boundSignedTimeClaim
          1
          0
          0
          (TimeScaleMovementBound 0 0 0)
          (elapsedClockSampleFromMicros 0)
          (elapsedClockSampleFromMicros 0)
          `shouldBe` Left SignedTimeZeroRadius
        boundSignedTimeClaim
          1
          1
          1000000
          (TimeScaleMovementBound 0 0 0)
          (elapsedClockSampleFromMicros 0)
          (elapsedClockSampleFromMicros 0)
          `shouldBe` Left SignedTimeClockRateInvalid
        boundSignedTimeClaim
          1
          1
          0
          (TimeScaleMovementBound 0 0 0)
          (elapsedClockSampleFromMicros 2)
          (elapsedClockSampleFromMicros 1)
          `shouldBe` Left SignedTimeBracketInverted
      it "accounts for a faster time scale and forward and backward movement" $
        boundSignedTimeClaim
          100
          3
          0
          (TimeScaleMovementBound 1000 1000000 2000000)
          (elapsedClockSampleFromMicros 0)
          (elapsedClockSampleFromMicros 1000000)
          `shouldBe` Right (SignedTimeInterval 95000000 105001002)
      it "ages an interval with rate and movement bounds and rejects inverted input" $ do
        let original = SignedTimeInterval 97000000 103000101
            policy = TimeScaleMovementBound 1000 1000000 2000000
            sample = elapsedClockSampleFromMicros
        ageSignedTimeInterval 500 policy (sample 100) (sample 1000100) original
          `shouldBe` Right (SignedTimeInterval 95000000 105001604)
        ageSignedTimeInterval 500 policy (sample 100) (sample 99) original
          `shouldBe` Left SignedTimeBracketInverted
        ageSignedTimeInterval 0 policy (sample 0) (sample 0) (SignedTimeInterval 2 1)
          `shouldBe` Left SignedTimeIntervalInverted
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

    describe "retained Broker clock admission" $ do
      it "refuses an invalid elapsed-clock rate before any store access" $ do
        operations <- newIORef (0 :: Int)
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> modifyIORef' operations (+ 1) >> pure (Just (RetainedClockSnapshot 1 1000))
                , casRetainedClock = \_ _ _ -> modifyIORef' operations (+ 1) >> pure RetainedClockCasApplied
                }
            elapsed =
              RetainedElapsedClock
                (pure (elapsedClockSampleFromMicros 100))
                1000000
                (TimeScaleMovementBound 0 0 0)
            unavailable = AuthorityTimeUnobservable (ClockUnreadable "retained clock admission unavailable")
        now <- realMonotonicNow
        let requestLimit = deadlineAtOffset now (RemainingDuration 5000000)
        reading <-
          observeRetainedClock requestLimit skew elapsed (pure (ClockSampled (at 1100) (unc 1))) store
        readRetainedClockReading reading `shouldReturn` unavailable
        readIORef operations `shouldReturn` 0
      it "converts signed intervals to raw samples without narrowing them" $ do
        rawClockReadingFromSignedInterval (SignedTimeInterval 10 13)
          `shouldBe` Right (ClockSampled (at 11) (unc 2))
        rawClockReadingFromSignedInterval (SignedTimeInterval 0 1)
          `shouldBe` Right (ClockSampled (at 0) (unc 1))
        rawClockReadingFromSignedInterval (SignedTimeInterval 2 1)
          `shouldBe` Left SignedTimeIntervalInverted
      it "exposes that a later watermark advance does not revoke an admitted reading" $ do
        state <- newIORef (RetainedClockSnapshot 1 1000)
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> Just <$> readIORef state
                , casRetainedClock = \_ expected proposed -> do
                    current <- readIORef state
                    if current /= expected
                      then pure RetainedClockCasConflict
                      else writeIORef state proposed >> pure RetainedClockCasApplied
                }
            broadSkew = either (error . show) id (mkClockSkewBound 2000000)
        now <- realMonotonicNow
        let limit = deadlineAtOffset now (RemainingDuration 5000000)
        first <-
          observeRetainedClock limit broadSkew testElapsedClock (pure (ClockSampled (at 1100) (unc 1))) store
        _ <-
          observeRetainedClock limit broadSkew testElapsedClock (pure (ClockSampled (at 1200) (unc 1))) store
        readIORef state `shouldReturn` RetainedClockSnapshot 3 1200
        observation <- readRetainedClockReading first
        case observation of
          AuthorityTimeTrusted actual _ -> actual `shouldBe` at 1100
          other -> expectationFailure (show other)

      it "commits before trusting and refuses regression after restart" $ do
        state <- newIORef (Just (RetainedClockSnapshot 1 1000))
        writes <- newIORef (0 :: Int)
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> readIORef state
                , casRetainedClock = \_ expected proposed -> do
                    current <- readIORef state
                    if current /= Just expected
                      then pure RetainedClockCasConflict
                      else do
                        modifyIORef' writes (+ 1)
                        writeIORef state (Just proposed)
                        pure RetainedClockCasApplied
                }
            sample micros = pure (ClockSampled (at micros) (unc 1))
            generousSkew = either (error . show) id (mkClockSkewBound 2000000)
            isTrustedAt micros observation = case observation of
              AuthorityTimeTrusted actual uncertainty -> actual == at micros && clockUncertaintyMicros uncertainty >= 2
              _ -> False
        now <- realMonotonicNow
        let requestLimit = deadlineAtOffset now (RemainingDuration 5000000)
        observeRetainedClockNow requestLimit generousSkew (sample 1100) store
          >>= (`shouldSatisfy` isTrustedAt 1100)
        readIORef state `shouldReturn` Just (RetainedClockSnapshot 2 1100)
        observeRetainedClockNow requestLimit generousSkew (sample 1000) store
          `shouldReturn` AuthorityTimeRegressed (at 1000) (at 1100)
        readIORef writes `shouldReturn` 1
        observeRetainedClockNow
          requestLimit
          generousSkew
          (pure (ClockSampled (at 1200) (unc 3000000)))
          store
          `shouldReturn` AuthorityTimeUnobservable (ClockUncertaintyTooWide (unc 3000000) generousSkew)
        observeRetainedClockNow
          requestLimit
          generousSkew
          (pure (ClockUnavailable "source unavailable"))
          store
          `shouldReturn` AuthorityTimeUnobservable (ClockUnreadable "source unavailable")
        readIORef writes `shouldReturn` 1
        observeRetainedClockNow requestLimit generousSkew (sample 1100) store
          >>= (`shouldSatisfy` isTrustedAt 1100)
        readIORef state `shouldReturn` Just (RetainedClockSnapshot 3 1100)

      it "refuses missing, conflicting and unconfirmed retained state" $ do
        state <- newIORef (Nothing :: Maybe RetainedClockSnapshot)
        writes <- newIORef (0 :: Int)
        let snapshot = RetainedClockSnapshot 1 1000
            unavailable = AuthorityTimeUnobservable (ClockUnreadable "retained clock admission unavailable")
            store =
              RetainedClockStore
                { readRetainedClock = \_ -> readIORef state
                , casRetainedClock = \_ _ _ -> do
                    modifyIORef' writes (+ 1)
                    writeIORef state (Just (RetainedClockSnapshot 2 1200))
                    pure RetainedClockCasConflict
                }
            sample = pure (ClockSampled (at 1100) (unc 1))
        now <- realMonotonicNow
        let requestLimit = deadlineAtOffset now (RemainingDuration 5000000)
        observeRetainedClockNow requestLimit skew sample store `shouldReturn` unavailable
        readIORef writes `shouldReturn` 0
        writeIORef state (Just snapshot)
        observeRetainedClockNow requestLimit skew sample store `shouldReturn` unavailable
        readIORef state `shouldReturn` Just (RetainedClockSnapshot 2 1200)
        let unconfirmed = store {casRetainedClock = \_ _ _ -> pure RetainedClockCasApplied}
        writeIORef state (Just snapshot)
        observeRetainedClockNow requestLimit skew sample unconfirmed `shouldReturn` unavailable
        readIORef state `shouldReturn` Just snapshot
        let ambiguous =
              store
                { casRetainedClock = \_ _ proposed -> do
                    writeIORef state (Just proposed)
                    pure RetainedClockCasUnobservable
                }
        observeRetainedClockNow requestLimit skew sample ambiguous `shouldReturn` unavailable
        readIORef state `shouldReturn` Just (RetainedClockSnapshot 2 1100)
        observeRetainedClockNow requestLimit skew (pure (ClockSampled (at 1000) (unc 1))) store
          `shouldReturn` AuthorityTimeRegressed (at 1000) (at 1100)

      it "refuses a sample that becomes too uncertain during read-back" $ do
        state <- newIORef (RetainedClockSnapshot 1 1000)
        readCount <- newIORef (0 :: Int)
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> do
                    modifyIORef' readCount (+ 1)
                    count <- readIORef readCount
                    if count > 1 then threadDelay 30000 else pure ()
                    Just <$> readIORef state
                , casRetainedClock = \_ _ proposed -> do
                    writeIORef state proposed
                    pure RetainedClockCasApplied
                }
            narrowSkew = either (error . show) id (mkClockSkewBound 5000)
        now <- realMonotonicNow
        let requestLimit = deadlineAtOffset now (RemainingDuration 5000000)
        result <-
          observeRetainedClockNow requestLimit narrowSkew (pure (ClockSampled (at 1100) (unc 1))) store
        case result of
          AuthorityTimeUnobservable (ClockUncertaintyTooWide actual _) ->
            clockUncertaintyMicros actual `shouldSatisfy` (> 5000)
          _ -> expectationFailure (show result)
        readIORef state `shouldReturn` RetainedClockSnapshot 2 1100

      it "ages admitted readings using the captured elapsed clock and refuses regression" $ do
        state <- newIORef (RetainedClockSnapshot 1 1000)
        elapsedRef <- newIORef (elapsedClockSampleFromMicros 100)
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> Just <$> readIORef state
                , casRetainedClock = \_ _ proposed -> do
                    threadDelay 2000
                    writeIORef state proposed
                    pure RetainedClockCasApplied
                }
            useSkew = either (error . show) id (mkClockSkewBound 100000)
            unavailable = AuthorityTimeUnobservable (ClockUnreadable "retained clock admission unavailable")
        now <- realMonotonicNow
        let requestLimit = deadlineAtOffset now (RemainingDuration 5000000)
            elapsed = RetainedElapsedClock (readIORef elapsedRef) 0 (TimeScaleMovementBound 0 0 0)
            source = pure (ClockSampled (at 1100) (unc 1))
        reading <- observeRetainedClock requestLimit useSkew elapsed source store
        current <- readRetainedClockReading reading
        case current of
          AuthorityTimeTrusted actual uncertainty -> do
            actual `shouldBe` at 1100
            clockUncertaintyMicros uncertainty `shouldSatisfy` (>= 2)
          observation -> expectationFailure (show observation)
        writeIORef elapsedRef (elapsedClockSampleFromMicros 99)
        readRetainedClockReading reading `shouldReturn` unavailable
        writeIORef elapsedRef (elapsedClockSampleFromMicros 200100)
        later <- readRetainedClockReading reading
        case later of
          AuthorityTimeUnobservable (ClockUncertaintyTooWide actual _) ->
            clockUncertaintyMicros actual `shouldSatisfy` (> 100000)
          observation -> expectationFailure (show observation)

      it "refuses an expired retained reading and an unavailable elapsed clock" $ do
        state <- newIORef (RetainedClockSnapshot 1 1000)
        elapsedRef <- newIORef (pure (elapsedClockSampleFromMicros 100))
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> Just <$> readIORef state
                , casRetainedClock = \_ _ proposed -> writeIORef state proposed >> pure RetainedClockCasApplied
                }
            elapsed = RetainedElapsedClock (readIORef elapsedRef >>= id) 0 (TimeScaleMovementBound 0 0 0)
            useSkew = either (error . show) id (mkClockSkewBound 100000)
            unavailable = AuthorityTimeUnobservable (ClockUnreadable "retained clock admission unavailable")
            source = pure (ClockSampled (at 1100) (unc 1))
        now <- realMonotonicNow
        let requestLimit = deadlineAtOffset now (RemainingDuration 300000)
        reading <- observeRetainedClock requestLimit useSkew elapsed source store
        writeIORef elapsedRef (ioError (userError "elapsed clock unavailable"))
        readRetainedClockReading reading `shouldReturn` unavailable
        threadDelay 400000
        readRetainedClockReading reading `shouldReturn` unavailable

      it "retains an applied watermark when elapsed-clock read-back fails" $ do
        state <- newIORef (RetainedClockSnapshot 1 1000)
        samples <- newIORef (0 :: Int)
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> Just <$> readIORef state
                , casRetainedClock = \_ _ proposed -> writeIORef state proposed >> pure RetainedClockCasApplied
                }
            elapsedNow = do
              modifyIORef' samples (+ 1)
              count <- readIORef samples
              if count == 1
                then pure (elapsedClockSampleFromMicros 100)
                else ioError (userError "elapsed clock unavailable")
            elapsed = RetainedElapsedClock elapsedNow 0 (TimeScaleMovementBound 0 0 0)
            useSkew = either (error . show) id (mkClockSkewBound 100000)
            unavailable = AuthorityTimeUnobservable (ClockUnreadable "retained clock admission unavailable")
        now <- realMonotonicNow
        let requestLimit = deadlineAtOffset now (RemainingDuration 5000000)
        reading <-
          observeRetainedClock requestLimit useSkew elapsed (pure (ClockSampled (at 1100) (unc 1))) store
        readRetainedClockReading reading `shouldReturn` unavailable
        readIORef state `shouldReturn` RetainedClockSnapshot 2 1100

      it "charges forward and backward time-scale movement to retained uncertainty" $ do
        state <- newIORef (RetainedClockSnapshot 1 0)
        let store =
              RetainedClockStore
                { readRetainedClock = \_ -> Just <$> readIORef state
                , casRetainedClock = \_ _ proposed -> writeIORef state proposed >> pure RetainedClockCasApplied
                }
            elapsed =
              RetainedElapsedClock
                (pure (elapsedClockSampleFromMicros 100))
                0
                (TimeScaleMovementBound 1000 1000000 2000000)
            useSkew = either (error . show) id (mkClockSkewBound 3000000)
        now <- realMonotonicNow
        let requestLimit = deadlineAtOffset now (RemainingDuration 5000000)
        reading <-
          observeRetainedClock requestLimit useSkew elapsed (pure (ClockSampled (at 10000000) (unc 1))) store
        observed <- readRetainedClockReading reading
        case observed of
          AuthorityTimeTrusted _ uncertainty -> clockUncertaintyMicros uncertainty `shouldSatisfy` (>= 2000001)
          other -> expectationFailure (show other)

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
