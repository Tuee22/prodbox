{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityOutboxSim
  ( lifecycleAuthorityOutboxSimSuite
  )
where

import Prodbox.Lifecycle.Authority.Operation (OperationRecoveryRefusal (..))
import Prodbox.Lifecycle.Authority.OutboxSim
import TestSupport

lifecycleAuthorityOutboxSimSuite :: SuiteBuilder ()
lifecycleAuthorityOutboxSimSuite =
  describe "Sprint 4.48 Lifecycle Authority durable-outbox crash/restart interpreter" $ do
    it "runs the crash-free path once and records the result" $ do
      let d = runEffect opA (armOperation opA intent emptyDurableOutbox)
      lookupResult opA d `shouldBe` Just val
      targetApplyCount tkey d `shouldBe` 1

    it "recovers a crash before the effect by executing the armed intent" $ do
      let armed = armOperation opA intent emptyDurableOutbox
      targetApplyCount tkey armed `shouldBe` 0
      let recovered = rightOutbox (recoverOperation opA armed)
      targetApplyCount tkey recovered `shouldBe` 1
      lookupResult opA recovered `shouldBe` Just val

    it "recovers a lost response without re-applying the effect (at-most-once)" $ do
      let staged = armAndApply opA intent emptyDurableOutbox
      targetApplyCount tkey staged `shouldBe` 1
      lookupResult opA staged `shouldBe` Nothing
      let recovered = rightOutbox (recoverOperation opA staged)
      targetApplyCount tkey recovered `shouldBe` 1
      lookupResult opA recovered `shouldBe` Just val

    it "fails closed and stays armed when the target has diverged" $ do
      let committed = runEffect opA (armOperation opA (SetTargetIntent tkey (TargetValue "other")) emptyDurableOutbox)
          conflicting = armOperation opB intent committed
      recoverOperation opB conflicting `shouldBe` Left OperationRecoveryTargetDiverged
      lookupResult opB conflicting `shouldBe` Nothing

    it "is idempotent on a repeated arm" $ do
      let once = armOperation opA intent emptyDurableOutbox
          twice = armOperation opA intent once
      twice `shouldBe` once

    it "treats recovery and re-run of a completed operation as no-ops" $ do
      let done = runEffect opA (armOperation opA intent emptyDurableOutbox)
      recoverOperation opA done `shouldBe` Right done
      runEffect opA done `shouldBe` done
      lookupResult opA done `shouldBe` Just val

    it "recovers an unknown operation as a no-op" $
      recoverOperation opA emptyDurableOutbox `shouldBe` Right emptyDurableOutbox
 where
  tkey = TargetKey "k"
  val = TargetValue "v"
  opA = OutboxKey "op-a"
  opB = OutboxKey "op-b"
  intent = SetTargetIntent tkey val
  rightOutbox = either (const (error "unexpected recovery refusal")) id
