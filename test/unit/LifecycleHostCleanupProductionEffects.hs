{-# LANGUAGE OverloadedStrings #-}

module LifecycleHostCleanupProductionEffects
  ( lifecycleHostCleanupProductionEffectsSuite
  )
where

import Prodbox.Lifecycle.HostCleanupProductionEffects
import TestSupport

lifecycleHostCleanupProductionEffectsSuite :: SuiteBuilder ()
lifecycleHostCleanupProductionEffectsSuite =
  describe "Sprint 4.86 host cleanup production effects record" $ do
    it "resolves the completion read-back only when both observations answered" $ do
      -- The pair the journal is then addressed with is exactly what the two
      -- observations produced; the resolution routes and never inspects.
      productionEffectsRegressionBothObservedResolve regression `shouldBe` True

    it "refuses before the markers when the Authority holds no readiness" $ do
      -- Otherwise the run asks about a host on behalf of a readiness nobody
      -- holds.
      productionEffectsRegressionReadinessUnavailableRefused regression `shouldBe` True

    it "refuses a completion read-back while the install markers are present" $ do
      -- The receipt's meaning is that this run recorded its own local absence,
      -- so a still-installed host holds no proof to check one against.
      productionEffectsRegressionStillInstalledRefused regression `shouldBe` True

    it "keeps an unobservable host distinct from a present one" $ do
      -- A host that could not be observed decides neither presence nor
      -- absence, and collapsing it into either would invent a fact.
      productionEffectsRegressionUnobservableRefused regression `shouldBe` True

    it "renders the three refusals as three distinct answers" $ do
      productionEffectsRegressionRefusalsAreDistinct regression `shouldBe` True

regression :: HostCleanupProductionEffectsRegression
regression = fixedHostCleanupProductionEffectsRegression
