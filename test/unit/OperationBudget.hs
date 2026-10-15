{-# LANGUAGE OverloadedStrings #-}

-- | The Provider operation budget.
--
-- Before it, every Provider operation asked STS for a 900 second session, so a
-- destroy that kept retrying one dependency error past the fifteenth minute
-- failed on an expired session. The cases run the arithmetic that replaced the
-- constant, keep the old constant as a negative control, and check the
-- invariants that make it safe: the request stays inside the role maximum, never
-- under the STS floor, and a child can never be given more time than the session
-- has left.
module OperationBudget
  ( operationBudgetSuite
  )
where

import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.OperationBudget
import Prodbox.ControlPlane.ProviderAssumedRoleSession
  ( lifecycleProviderSessionDurationSeconds
  )
import Test.Tasty.QuickCheck (Gen, choose, forAll)
import TestSupport

seconds :: Natural -> Natural
seconds count = count * 1000000

genRoleMaximum :: Gen Natural
genRoleMaximum = fromIntegral <$> (choose (900, 7200) :: Gen Int)

genMicros :: Gen Natural
genMicros = fromIntegral <$> (choose (0, 10000 * 1000000) :: Gen Int)

operationBudgetSuite :: SuiteBuilder ()
operationBudgetSuite =
  describe "provider operation budget" $ do
    it "requests the remaining time plus the grace for an operation that runs to its deadline" $
      -- Red on 0268f5d: a 1800 second operation was given 900 seconds.
      planSessionDuration declaredRoleMaximumSeconds 0 (seconds 1800) `shouldBe` 2100

    it "negative control: the pre-fix request ignored the deadline and was the floor" $ do
      lifecycleProviderSessionDurationSeconds `shouldBe` 900
      planSessionDuration declaredRoleMaximumSeconds 0 (seconds 1800)
        `shouldSatisfy` (> lifecycleProviderSessionDurationSeconds)

    it "never requests less than the STS floor" $ do
      planSessionDuration declaredRoleMaximumSeconds 0 (seconds 100) `shouldBe` 900
      planSessionDuration declaredRoleMaximumSeconds 0 0 `shouldBe` 900
      -- A deadline already in the past leaves nothing remaining.
      planSessionDuration declaredRoleMaximumSeconds (seconds 10) (seconds 5) `shouldBe` 900

    it "never requests more than the role maximum" $
      planSessionDuration declaredRoleMaximumSeconds 0 (seconds 4000)
        `shouldBe` declaredRoleMaximumSeconds

    it "rounds a part-second of remaining time up" $
      planSessionDuration declaredRoleMaximumSeconds 0 (seconds 1800 + 1) `shouldBe` 2101

    propertyTest "the request is always between the STS floor and the role maximum" $
      forAll genRoleMaximum $ \roleMaximum ->
        forAll genMicros $ \now ->
          forAll genMicros $ \deadline ->
            let requested = planSessionDuration roleMaximum now deadline
             in requested >= sessionMinimumSeconds && requested <= roleMaximum

    propertyTest "the request covers the remaining time plus the grace whenever the role allows it" $
      forAll genRoleMaximum $ \roleMaximum ->
        forAll genMicros $ \now ->
          forAll genMicros $ \deadline ->
            let remaining = (max deadline now - now + 999999) `div` 1000000
                needed = remaining + sessionGraceSeconds
             in needed > roleMaximum
                  || planSessionDuration roleMaximum now deadline >= needed

    propertyTest "a later deadline never shortens the request" $
      forAll genRoleMaximum $ \roleMaximum ->
        forAll genMicros $ \now ->
          forAll genMicros $ \deadline ->
            forAll genMicros $ \extra ->
              planSessionDuration roleMaximum now deadline
                <= planSessionDuration roleMaximum now (deadline + extra)

    it "reports the usable window once the read-back grace is reserved" $ do
      let now = seconds 1000
      sessionWindowMicros (now + seconds 301) now `shouldBe` Right (seconds 1)
      sessionWindowMicros (now + seconds 2100) now `shouldBe` Right (seconds 1800)

    it "refuses to start work in a session with nothing usable left" $ do
      let now = seconds 1000
      sessionWindowMicros (now + seconds 300) now
        `shouldBe` Left (SessionWindowExceeded (now + seconds 300) now)
      sessionWindowMicros (now + seconds 10) now
        `shouldBe` Left (SessionWindowExceeded (now + seconds 10) now)
      sessionWindowMicros (now - 1) now `shouldBe` Left (SessionWindowExceeded (now - 1) now)

    it "names the refusal with a stable token" $
      renderSessionWindowRefusal (SessionWindowExceeded 5 9)
        `shouldSatisfy` Text.isPrefixOf "SessionWindowExceeded:"

    propertyTest "a child is never given more time than the session has left" $
      forAll genMicros $ \childMaximum ->
        forAll genMicros $ \window ->
          let limit = childLimitMicros childMaximum window
           in limit <= childMaximum && limit <= window && (limit == childMaximum || limit == window)
