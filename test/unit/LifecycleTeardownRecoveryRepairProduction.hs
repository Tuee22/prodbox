{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownRecoveryRepairProduction
  ( lifecycleTeardownRecoveryRepairProductionSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.RecoveryRepairProduction
import TestSupport

lifecycleTeardownRecoveryRepairProductionSuite :: SuiteBuilder ()
lifecycleTeardownRecoveryRepairProductionSuite =
  describe "Sprint 4.86 production recovery repair boundary" $ do
    it "stages the four substrate artifacts under the names the installer reads" $ do
      -- A retained artifact's location is the operator's store-relative path
      -- and the installer reads one directory of fixed, architecture-specific
      -- names, so the two are joined here rather than by convention.
      regression <- requireRegression
      repairProductionRegressionStagesTheFourExpectedNames regression `shouldBe` True

    it "runs the installer over the staged directory and discards it" $ do
      regression <- requireRegression
      repairProductionRegressionInstallRunsOverTheStagedDirectory regression `shouldBe` True

    it "refuses an incomplete install before staging or issuing anything" $ do
      -- A missing artifact must be named by the run, not discovered inside a
      -- root subprocess where it can no longer say which byte source was
      -- absent.
      regression <- requireRegression
      repairProductionRegressionIncompleteInstallIssuesNothing regression `shouldBe` True

    it "discards the staged directory when the install fails" $ do
      -- Custody measures store membership in both directions, so scratch left
      -- behind is residue rather than retention.
      regression <- requireRegression
      repairProductionRegressionStagingDiscardedOnFailure regression `shouldBe` True

    it "enables and starts the substrate unit in one act" $ do
      -- A resumed repair must not leave a started-but-not-enabled node.
      regression <- requireRegression
      repairProductionRegressionStartEnablesAndStarts regression `shouldBe` True

    it "stops awaiting at the first healthy observation" $ do
      regression <- requireRegression
      repairProductionRegressionAwaitStopsAtHealthy regression `shouldBe` True

    it "reports the last observation when the wait exhausts" $ do
      -- A bare timeout would lose the difference between a substrate that is
      -- stopped and one nothing could observe.
      regression <- requireRegression
      repairProductionRegressionAwaitExhaustsWithLastObservation regression `shouldBe` True

    it "imports a retained image by its store-resolved path" $ do
      regression <- requireRegression
      repairProductionRegressionImageImportAddressesRetainedBytes regression `shouldBe` True

    it "delegates the recovery chart reconcile and issues no command for it" $ do
      -- Chart delivery sits above the lifecycle surface; taking it as an
      -- argument states that dependency instead of inverting it.
      regression <- requireRegression
      repairProductionRegressionChartReconcileIsDelegated regression `shouldBe` True

requireRegression :: IO RecoveryRepairProductionRegression
requireRegression = do
  result <- fixedRecoveryRepairProductionRegression
  case result of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
