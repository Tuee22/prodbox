{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownPreUninstallReadiness
  ( lifecycleTeardownPreUninstallReadinessSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.PreUninstallReadiness
import TestSupport

lifecycleTeardownPreUninstallReadinessSuite :: SuiteBuilder ()
lifecycleTeardownPreUninstallReadinessSuite =
  describe "Sprint 4.86 Stage C pre-uninstall readiness" $ do
    it "reaches readiness from an applied commit whose report is independently durable" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionReadyFromAppliedCommit regression `shouldBe` True

    it "reaches readiness when the commit response was lost but the report is durable" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionReadyFromLostResponse regression `shouldBe` True

    it "reaches readiness when the commit reported a refusal that had already landed" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionReadyFromRefusedCommitThatLanded regression
        `shouldBe` True

    it "reads the report back even when the commit reported a refusal" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionReadBackAlwaysAttempted regression `shouldBe` True

    it "refuses an applied commit whose report is not independently observed" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionAppliedButNotDurableRefused regression `shouldBe` True

    it "refuses when the durable store cannot be observed at all" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionUnobservableRefused regression `shouldBe` True

    it "refuses before requesting a permit when the report identity drifted" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionDigestDriftRefused regression `shouldBe` True

    it "refuses when the Authority produces no permit" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionPermitUnavailableRefused regression `shouldBe` True

    it "refuses a permit that does not bind to this compiled run" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionForeignPermitRefused regression `shouldBe` True

    it "never requests a permit once the report identity has drifted" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionDriftNeverRequestsPermit regression `shouldBe` True

    it "carries the independently read-back report identity into readiness" $ do
      regression <- requireRegression
      preUninstallReadinessRegressionReadinessCarriesReadBackIdentity regression
        `shouldBe` True

    it "produces one inhabitant of every refusal arm from a real fault" $ do
      refusals <- requireRefusals
      length refusals `shouldBe` 5

    it "renders every refusal as an operator-readable line naming Stage C" $ do
      refusals <- requireRefusals
      mapM_
        ( \rendered ->
            rendered `shouldSatisfy` (Text.isInfixOf "Stage C refuses" . Text.pack)
        )
        (fmap renderPreUninstallReadinessRefusal refusals)

requireRefusals :: IO [PreUninstallReadinessRefusal]
requireRefusals =
  case fixedPreUninstallReadinessRefusals of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right refusals -> pure refusals

requireRegression :: IO PreUninstallReadinessRegression
requireRegression = do
  result <- fixedPreUninstallReadinessRegression
  case result of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
