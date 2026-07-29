{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.72: drift guard for the Ring-1 over-commit shim that
-- 'renderProjectConfigDhall' bakes into a generated @prodbox.dhall@
-- (resource_scaling_doctrine.md §2C). The renderer emits the guarded body only
-- for a plan that itself compiles, so the threat the shim actually defends
-- against is a hand-edit of an already-generated, valid file — exactly what the
-- negative case below models. Three facts are pinned:
--
--   1. the guarded rendering of the valid default still round-trips through
--      @'Dhall.input' 'Dhall.auto'@ (the embedded @assert@ and lemma bindings
--      normalize away, so extraction sees exactly the @cfg@ record);
--   2. a host-shrinking hand-edit of that same rendering fails to load at the
--      Dhall @assert@ (Ring 1), not merely later at the Haskell gate; and
--   3. the Haskell decode gate ('compileResourcePlanUncertified', Ring 2)
--      rejects the identical shrink — so the two rings cannot silently disagree.
module Tier0PlanAssert (tier0PlanAssertSuite) where

import Control.Exception (SomeException, try)
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Dhall qualified
import Prodbox.Capacity.Allocation (compileResourcePlanUncertified)
import Prodbox.Capacity.Config
  ( CapacitySection (..)
  , ResourcePlan (..)
  , ResourceVector (..)
  )
import Prodbox.Config.Tier0
  ( ProdboxParameters (..)
  , ProdboxProjectConfig (..)
  , defaultProjectConfig
  , renderProjectConfigDhall
  )
import TestSupport

tier0PlanAssertSuite :: SuiteBuilder ()
tier0PlanAssertSuite =
  describe "Sprint 1.72 Ring-1 over-commit shim (assertPlanValid)" $ do
    it "round-trips the guarded default rendering back to the same config" $
      Dhall.input Dhall.auto (renderProjectConfigDhall defaultProjectConfig)
        `shouldReturn` defaultProjectConfig
    it "rejects a host-shrinking hand-edit at the Dhall assert (Ring 1)" $ do
      let corrupted =
            Text.replace
              "durable_storage_mib = 180000"
              "durable_storage_mib = 1000"
              (renderProjectConfigDhall defaultProjectConfig)
      decoded <-
        try (Dhall.input Dhall.auto corrupted)
          :: IO (Either SomeException ProdboxProjectConfig)
      case decoded of
        Right _ -> expectationFailure "over-committed prodbox.dhall unexpectedly loaded"
        Left err -> ("Assertion failed" `isInfixOf` show err) `shouldBe` True
    it "rejects the identical shrink at the Haskell decode gate (Ring 2)" $
      compileResourcePlanUncertified overCommittedPlan `shouldSatisfy` isLeft

-- | The valid default plan with @host_capacity.durable_storage_mib@ shrunk below
-- the reservation — the same edit the Ring-1 negative applies textually.
overCommittedPlan :: ResourcePlan
overCommittedPlan =
  plan {host_capacity = (host_capacity plan) {durable_storage_mib = 1000}}
 where
  plan = resource_plan (capacity (parameters defaultProjectConfig))
