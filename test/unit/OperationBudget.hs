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

import Control.Monad (unless)
import Data.List (nub, sort)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.ProviderWorkerBudget (providerWorkerIntentLifetimeMicros)
import Prodbox.ControlPlane.OperationBudget
import Prodbox.ControlPlane.ProviderAssumedRoleSession
  ( lifecycleProviderSessionDurationSeconds
  )
import Prodbox.ControlPlane.ProviderProduction (providerAwsCliLimits)
import Prodbox.Subprocess (BoundedSubprocessLimits (..))
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

    -- Sprint 4.109: a wait is a loop of short polls under a named budget, and
    -- the budgets of an operation that waits must fit inside its intent.
    describe "wait budgets" $ do
      it "names every awaited fact once, and each budget names its own fact" $
        mapM_
          (\fact -> waitBudgetFor fact `shouldSatisfy` ((== fact) . waitBudgetFact))
          allFacts

      it "polls at a positive interval and at least twice inside its ceiling" $
        mapM_
          ( \fact ->
              let budget = waitBudgetFor fact
               in ( waitBudgetPollIntervalMicros budget > 0
                      && waitBudgetSharePermille budget > 0
                      && waitCeilingMicros providerWorkerIntentLifetimeMicros budget
                        >= 2 * waitBudgetPollIntervalMicros budget
                  )
                    `shouldBe` True
          )
          allFacts

      it "never asks a poll to run longer than the bound the AWS runner enforces" $ do
        fromIntegral (boundedSubprocessTimeoutMicros providerAwsCliLimits)
          `shouldBe` awsCliChildBoundMicros
        mapM_
          ( \fact ->
              (waitBudgetChildMaximumMicros (waitBudgetFor fact) <= awsCliChildBoundMicros)
                `shouldBe` True
          )
          allFacts

      it "fits the serial sum of every operation's waits inside its intent, or declares itself windowed" $ do
        mapM_
          ( \operation -> do
              ( operationLeadPermille operation + serialWaitSharePermille operation + waitOperationReservePermille
                  <= 1000
                )
                `shouldBe` not (operationIsWindowed operation)
              unless (operationIsWindowed operation) $ do
                let ceilings =
                      [ waitCeilingMicros providerWorkerIntentLifetimeMicros (waitBudgetFor fact)
                      | fact <- operationWaitFacts operation
                      ]
                (sum ceilings + reserveMicros <= providerWorkerIntentLifetimeMicros) `shouldBe` True
          )
          allOperations

      it "names the operations whose waits cannot all be spent, and no others" $
        -- The destroy of a stack with a VPC spends up to 450 thousandths on its
        -- first pass before its waits begin, and the EKS reaper's six waits sum
        -- past the intent. Their later waits end at the window the session has
        -- left, in a typed timeout that names the fact; they are not fenced by
        -- the sum, so a new wait added to any other operation must still fit.
        filter operationIsWindowed allOperations `shouldBe` [ReapEksNativeFamily, DestroyAwsStack]

      it "registers the waits the manifest route's dependents step makes" $
        mapM_
          ( \operation ->
              operationWaitFacts operation
                `shouldSatisfy` (\facts -> InterfacesReleased `elem` facts && SecurityGroupDeletable `elem` facts)
          )
          [ReapEksNativeFamily, ReapAwsTestNativeFamily, DestroyAwsStack]

      it "keeps no budget that no registered operation waits on" $
        sort (nub (concatMap operationWaitFacts allOperations)) `shouldBe` sort allFacts

      it "gives the worst fenced operation its waits and still leaves its own work room" $ do
        let worst = maximum (map serialWaitSharePermille (filter (not . operationIsWindowed) allOperations))
        (worst + waitOperationReservePermille <= 1000) `shouldBe` True

      it "names the fact in the form an operator reads" $
        mapM_
          (\fact -> renderWaitFact fact `shouldSatisfy` (not . Text.null))
          allFacts

      it
        "registers the destroy of a stack with a VPC as an operation that waits for interfaces and groups"
        $ do
          operationWaitFacts DestroyAwsStack
            `shouldBe` [SecurityGroupDeletable, InterfacesReleased, SecurityGroupDeletable]
          -- The waits end at the nearer of their ceiling and the session window.
          waitBudgetPollIntervalMicros (waitBudgetFor InterfacesReleased) `shouldBe` seconds 15

      propertyTest "a wait never runs past its ceiling or past the session window" $
        forAll genMicros $ \now ->
          forAll genMicros $ \window ->
            forAll (choose (0, length allFacts - 1)) $ \index ->
              let budget = waitBudgetFor (allFacts !! index)
                  deadline = waitDeadlineMicros providerWorkerIntentLifetimeMicros budget now window
               in deadline >= now
                    && deadline - now <= window
                    && deadline - now <= waitCeilingMicros providerWorkerIntentLifetimeMicros budget
                    && ( deadline - now == window
                           || deadline - now == waitCeilingMicros providerWorkerIntentLifetimeMicros budget
                       )

    describe "the destroy's passes (Sprint 4.111)" $ do
      it "leaves the destroy room beyond the first pass and the final pass's reserve" $
        (firstPassSharePermille + finalPassReservePermille + destroyOverheadPermille <= 1000)
          `shouldBe` True

      it "holds the first pass to 450 thousandths of the intent, and reserves 300 for the rest" $ do
        firstPassCeilingMicros providerWorkerIntentLifetimeMicros `shouldBe` seconds 810
        finalPassReserveMicros providerWorkerIntentLifetimeMicros `shouldBe` seconds 540
        verdictReserveMicros `shouldBe` seconds 120
        readTailMicros `shouldBe` seconds 40
        shortCommandCeilingMicros `shouldBe` seconds 60

      it "bounds a pass by what the reserve leaves of the session window" $ do
        -- 1,800 seconds left, 360 reserved: the ceiling (810) is the nearer bound.
        passLimitMicros (seconds 810) (seconds 360) (seconds 1680) (seconds 1800)
          `shouldBe` Just (seconds 810)
        -- 900 left: only 540 remain once the reserve is kept.
        passLimitMicros (seconds 810) (seconds 360) (seconds 1680) (seconds 900)
          `shouldBe` Just (seconds 540)
        -- No room beyond the reserve starts no pass.
        passLimitMicros (seconds 810) (seconds 360) (seconds 1680) (seconds 360) `shouldBe` Nothing
        passLimitMicros (seconds 810) (seconds 360) (seconds 1680) 0 `shouldBe` Nothing

      it "keeps the verdict's reserve out of the final pass, and leaves the final pass room beyond it" $ do
        (verdictReserveMicros < finalPassReserveMicros providerWorkerIntentLifetimeMicros) `shouldBe` True
        -- What the repair's waits leave the final pass, less the reading after it
        -- and the kill grace, is still minutes and not seconds.
        ( finalPassReserveMicros providerWorkerIntentLifetimeMicros
            - verdictReserveMicros
            - seconds 30
            >= seconds 240
          )
          `shouldBe` True

      propertyTest
        "a pass is never bounded past its ceiling, the child maximum, or what the reserve leaves"
        $ forAll genMicros
        $ \ceilingMicros ->
          forAll genMicros $ \reserve ->
            forAll genMicros $ \childMaximum ->
              forAll genMicros $ \window ->
                passLimitIsSound ceilingMicros reserve childMaximum window

-- | A pass's bound holds under every limit it is given, and is refused only when
-- one of them leaves nothing.
passLimitIsSound :: Natural -> Natural -> Natural -> Natural -> Bool
passLimitIsSound ceilingMicros reserve childMaximum window =
  case passLimitMicros ceilingMicros reserve childMaximum window of
    Nothing -> window <= reserve || ceilingMicros == 0 || childMaximum == 0
    Just limit ->
      limit > 0
        && limit <= ceilingMicros
        && limit <= childMaximum
        && limit + reserve <= window

allFacts :: [WaitFact]
allFacts = [minBound .. maxBound]

allOperations :: [WaitingOperation]
allOperations = [minBound .. maxBound]

reserveMicros :: Natural
reserveMicros = providerWorkerIntentLifetimeMicros * waitOperationReservePermille `div` 1000
