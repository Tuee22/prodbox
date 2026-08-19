{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneCascadeHostRuntime
  ( controlPlaneCascadeHostRuntimeSuite
  )
where

import Prodbox.ControlPlane.CascadeHostRuntime
import TestSupport

controlPlaneCascadeHostRuntimeSuite :: SuiteBuilder ()
controlPlaneCascadeHostRuntimeSuite =
  describe "Sprint 4.86 closed cascade host runtime" $ do
    it "classifies exactly the four cascade host operations and refuses the rest" $ do
      cascadeHostRuntimeClosedOperationsExact fixedCascadeHostRuntimeRegression
        `shouldBe` True

    it "gives each cascade host node its own durable phase" $ do
      -- A phase that discharged two nodes would record one node as having
      -- performed the other's effect, and a resume would have nothing left to
      -- attribute a failure to.
      cascadeHostRuntimePhasesDistinct fixedCascadeHostRuntimeRegression
        `shouldBe` True

    it "reports an observation failure as unconfirmed rather than as a refusal" $ do
      -- The runner reports "the mutation was issued and its read-back failed"
      -- and "a read-back failed on its own" through one typed error, so from
      -- the node's side the effect may still have landed.
      cascadeHostRuntimeObservationUnconfirmed fixedCascadeHostRuntimeRegression
        `shouldBe` True

    it "reports a definite runner refusal as a failure" $ do
      cascadeHostRuntimeDefiniteRefusalFailed fixedCascadeHostRuntimeRegression
        `shouldBe` True

    it "exposes no store, effects record, operation, or action" $ do
      cascadeHostRuntimeOpacityClosed fixedCascadeHostRuntimeRegression
        `shouldBe` True
