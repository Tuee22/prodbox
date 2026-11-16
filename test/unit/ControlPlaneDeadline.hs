-- | Sprint 1.62 deliverable 1 (process-local half): the deadline-feasibility
-- fold and the tighten-only cancellation-propagation scope. Proves no child
-- deadline can outlive or extend its parent, and that the admission-feasibility
-- boundary is strict (a cost equal to the budget misses), consistent with the
-- landed @deadlineObservation@ @>=@-is-expired boundary.
module ControlPlaneDeadline
  ( controlPlaneDeadlineSuite
  )
where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..), async, cancel, waitCatch)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, throwIO, try)
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , OperationAcceptanceRefusal (..)
  , clockUncertaintyFromMicros
  , deriveOperationDeadline
  , observeOperationDeadline
  , operationDeadlineMicros
  )
import Prodbox.ControlPlane.Deadline
import Prodbox.ControlPlane.Interpreter
  ( DeadlineEffectResult (..)
  , observeDeadlineEffect
  , observeDeadlineEffectWithin
  , realMonotonicNow
  , trySynchronous
  )
import Prodbox.Lifecycle.Lease (authorityDurationFromMicros, authorityTimeFromMicros)
import System.Timeout (timeout)
import Test.Tasty.QuickCheck (NonNegative (..), Small (..))
import TestSupport

mi :: Natural -> MonotonicInstant
mi = monotonicInstantFromMicros

dl :: Natural -> Deadline
dl = deadlineFromInstant . mi

scopeMicros :: DeadlineScope -> Natural
scopeMicros = monotonicInstantMicros . deadlineInstant . scopeDeadline

tightenIsMinProperty :: NonNegative (Small Int) -> NonNegative (Small Int) -> Bool
tightenIsMinProperty (NonNegative (Small a)) (NonNegative (Small b)) =
  let da = dl (fromIntegral a)
      db = dl (fromIntegral b)
      t = tightenDeadline da db
   in t == min da db && t <= da && t <= db

grandchildBoundedProperty
  :: NonNegative (Small Int) -> NonNegative (Small Int) -> NonNegative (Small Int) -> Bool
grandchildBoundedProperty (NonNegative (Small p)) (NonNegative (Small c1)) (NonNegative (Small c2)) =
  let child = narrowScope (rootScope (dl (fromIntegral p))) (dl (fromIntegral c1))
      grandchild = narrowScope child (dl (fromIntegral c2))
   in scopeDeadline grandchild <= dl (fromIntegral p)

controlPlaneDeadlineSuite :: SuiteBuilder ()
controlPlaneDeadlineSuite =
  describe "Sprint 1.62 Deadline extensions" $ do
    it "limits a local wait without treating a timed-out effect as absent" $ do
      started <- newIORef False
      now <- realMonotonicNow
      let deadline = deadlineAtOffset now (RemainingDuration 100_000)
      result <-
        timeout 2_000_000 $
          observeDeadlineEffectWithin deadline $ do
            writeIORef started True
            threadDelay 3_000_000
            pure ()
      case result of
        Just Nothing -> pure ()
        _ -> expectationFailure "local wait did not time out"
      readIORef started `shouldReturn` True
      expiredAt <- realMonotonicNow
      expired <-
        observeDeadlineEffectWithin
          (deadlineFromInstant expiredAt)
          (writeIORef started False)
      expired `shouldBe` Just DeadlineEffectNotStarted
      readIORef started `shouldReturn` True
      aliveAt <- realMonotonicNow
      cancelled <-
        try
          ( observeDeadlineEffectWithin
              (deadlineAtOffset aliveAt (RemainingDuration 1_000_000))
              (throwIO ThreadKilled)
          )
          :: IO (Either AsyncException (Maybe (DeadlineEffectResult ())))
      case cancelled of
        Left ThreadKilled -> pure ()
        _ -> expectationFailure "external cancellation did not propagate"
      outerAt <- realMonotonicNow
      outer <-
        timeout 100_000 $
          observeDeadlineEffectWithin
            (deadlineAtOffset outerAt (RemainingDuration 1_000_000))
            (threadDelay 3_000_000)
      case outer of
        Nothing -> pure ()
        Just _ -> expectationFailure "outer timeout did not propagate"

    it "charges authority sampling delay and uncertainty to the persisted deadline" $ do
      monotonic <- newIORef (100 :: Natural)
      calls <- newIORef ([] :: [String])
      let clock = do
            modifyIORef' calls (++ ["clock"])
            writeIORef monotonic 300
            pure (AuthorityTimeTrusted (authorityTimeFromMicros 300) (clockUncertaintyFromMicros 10))
          now = do
            modifyIORef' calls (++ ["monotonic"])
            mi <$> readIORef monotonic
      accepted <- observeOperationDeadline clock now (dl 500)
      fmap operationDeadlineMicros accepted `shouldBe` Right 490
      let oldBudget = either (error . show) id (authorityDurationFromMicros 400)
      operationDeadlineMicros (deriveOperationDeadline (authorityTimeFromMicros 300) oldBudget)
        `shouldBe` 700
      readIORef calls `shouldReturn` ["monotonic", "clock", "monotonic"]
      expired <- observeOperationDeadline clock now (dl 300)
      expired `shouldBe` Left OperationAcceptanceRequestExpired
      readIORef calls `shouldReturn` ["monotonic", "clock", "monotonic", "monotonic"]
      writeIORef monotonic 100
      expiredDuring <-
        observeOperationDeadline
          ( writeIORef monotonic 500
              >> pure (AuthorityTimeTrusted (authorityTimeFromMicros 300) (clockUncertaintyFromMicros 10))
          )
          now
          (dl 500)
      expiredDuring `shouldBe` Left OperationAcceptanceRequestExpired
      untrusted <-
        observeOperationDeadline
          (pure (AuthorityTimeRegressed (authorityTimeFromMicros 200) (authorityTimeFromMicros 300)))
          (pure (mi 300))
          (dl 500)
      untrusted `shouldBe` Left OperationAcceptanceClockUntrusted

    it "preserves cancellation while translating synchronous observation failures" $ do
      normal <- trySynchronous (pure (7 :: Int))
      either (const False) (== 7) normal `shouldBe` True
      failure <- trySynchronous (ioError (userError "fixture") :: IO ())
      failure `shouldSatisfy` isLeft
      killed <-
        try (trySynchronous (throwIO ThreadKilled)) :: IO (Either AsyncException (Either SomeException ()))
      case killed of
        Left ThreadKilled -> pure ()
        _ -> expectationFailure "ThreadKilled did not propagate"
      started <- newEmptyMVar
      worker <- async (trySynchronous (putMVar started () >> threadDelay 1_000_000))
      takeMVar started
      cancel worker
      cancelled <- waitCatch worker
      case cancelled of
        Left exception -> case fromException exception of
          Just AsyncCancelled -> pure ()
          Nothing -> expectationFailure "wrong supervisor cancellation exception"
        Right _ -> expectationFailure "supervisor cancellation did not propagate"
      timed <- timeout 20_000 (trySynchronous (threadDelay 1_000_000))
      maybe True (const False) timed `shouldBe` True

    it "does not start late effects and distinguishes completion before and at the deadline" $ do
      let cases =
            [ ([100], DeadlineEffectNotStarted, 0 :: Int)
            , ([90, 99], DeadlineEffectCompleted (mi 99) "applied", 1)
            , ([90, 100], DeadlineEffectCompletedLate "applied", 1)
            , ([90, 101], DeadlineEffectCompletedLate "applied", 1)
            ]
      mapM_
        ( \(readings, expected, expectedCalls) -> do
            clock <- newIORef readings
            calls <- newIORef (0 :: Int)
            let now = do
                  values <- readIORef clock
                  case values of
                    [] -> fail "unexpected clock read"
                    value : rest -> modifyIORef' clock (const rest) >> pure (mi value)
                effect = modifyIORef' calls (+ 1) >> pure "applied"
            observeDeadlineEffect now (dl 100) effect `shouldReturn` expected
            readIORef calls `shouldReturn` expectedCalls
        )
        cases

    describe "tightenDeadline / cancellation propagation" $ do
      propertyTest "tightenDeadline is min and <= both inputs" tightenIsMinProperty

      it "narrowScope clamps an earlier candidate" $
        scopeMicros (narrowScope (rootScope (dl 1000)) (dl 900)) `shouldBe` 900
      it "narrowScope keeps an equal candidate" $
        scopeMicros (narrowScope (rootScope (dl 1000)) (dl 1000)) `shouldBe` 1000
      it "narrowScope discards a later candidate (no extension)" $
        scopeMicros (narrowScope (rootScope (dl 1000)) (dl 1100)) `shouldBe` 1000

      it "narrowScopeToBudget clamps start+budget under the parent" $
        scopeMicros (narrowScopeToBudget (rootScope (dl 1000)) (mi 200) (RemainingDuration 500))
          `shouldBe` 700
      it "narrowScopeToBudget discards an over-parent budget" $
        scopeMicros (narrowScopeToBudget (rootScope (dl 1000)) (mi 200) (RemainingDuration 900))
          `shouldBe` 1000

      propertyTest "a grandchild scope never outlives the grandparent" grandchildBoundedProperty

    describe "deadlineAdmission feasibility fold" $ do
      it "admits with slack when the estimate is under budget" $
        deadlineAdmission (RemainingDuration 1000) (WorkEstimate 0)
          `shouldBe` AdmissionWithinDeadline (RemainingDuration 1000)
      it "admits with one micro of slack at estimate = budget - 1" $
        deadlineAdmission (RemainingDuration 1000) (WorkEstimate 999)
          `shouldBe` AdmissionWithinDeadline (RemainingDuration 1)
      it "misses by zero at estimate = budget (strict boundary)" $
        deadlineAdmission (RemainingDuration 1000) (WorkEstimate 1000)
          `shouldBe` AdmissionMissesDeadline (RemainingDuration 0)
      it "reports the deficit when the estimate overshoots" $
        deadlineAdmission (RemainingDuration 1000) (WorkEstimate 1500)
          `shouldBe` AdmissionMissesDeadline (RemainingDuration 500)
      it "a zero budget misses for any positive estimate" $
        deadlineAdmission (RemainingDuration 0) (WorkEstimate 1)
          `shouldBe` AdmissionMissesDeadline (RemainingDuration 1)

    describe "landed deadlineObservation boundary (regression guard)" $
      it "is expired exactly at the deadline instant (>= boundary)" $
        deadlineObservation (mi 1000) (dl 1000) `shouldBe` DeadlineExpired
