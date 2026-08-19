{-# LANGUAGE OverloadedStrings #-}

module LifecycleHostCleanupLocalAbsence
  ( lifecycleHostCleanupLocalAbsenceSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.HostCleanupLocalAbsence
import TestSupport

lifecycleHostCleanupLocalAbsenceSuite :: SuiteBuilder ()
lifecycleHostCleanupLocalAbsenceSuite =
  describe "Sprint 4.86 host cleanup local absence read-back" $ do
    it "turns an exact absent marker set into local uninstall evidence" $ do
      regression <- requireRegression
      localAbsenceRegressionAbsentBecomesEvidence regression `shouldBe` True

    it "reports a present marker set as still installed rather than as a failure" $ do
      regression <- requireRegression
      localAbsenceRegressionPresentIsNotAbsence regression `shouldBe` True

    it "refuses an unread marker set instead of treating it as absence" $ do
      regression <- requireRegression
      localAbsenceRegressionUnconfirmedIsNotAbsence regression `shouldBe` True

    it "keeps presence winning over an unrelated marker read failure" $ do
      regression <- requireRegression
      localAbsenceRegressionPresenceOutranksReadFailure regression `shouldBe` True

    it "refuses when the durable record's scope and the readiness disagree" $ do
      regression <- requireRegression
      localAbsenceRegressionForeignScopeRefused regression `shouldBe` True

    it "maps the three read-back answers onto the runner's three effect answers" $ do
      regression <- requireRegression
      localAbsenceRegressionEffectMapping regression `shouldBe` True

requireRegression :: IO LocalAbsenceReadBackRegression
requireRegression =
  case fixedLocalAbsenceReadBackRegression of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
