{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownPreUninstallReportCommit
  ( lifecycleTeardownPreUninstallReportCommitSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.PreUninstallReportCommit
import TestSupport

lifecycleTeardownPreUninstallReportCommitSuite :: SuiteBuilder ()
lifecycleTeardownPreUninstallReportCommitSuite =
  describe "Sprint 4.86 Stage C Authority commit and one-shot permit" $ do
    it "applies when the Authority records the identity and the copy lands" $ do
      regression <- requireRegression
      reportCommitRegressionAppliedWhenBothLand regression `shouldBe` True

    it "writes the Authority record before the independent copy" $ do
      -- An identity the Authority holds with no copy beside it is a run that
      -- can retry the copy; a copy with no Authority record is an object
      -- nothing refers to.
      regression <- requireRegression
      reportCommitRegressionReplicationFollowsTheAuthority regression `shouldBe` True

    it "refuses an identity that does not name the report bytes" $ do
      -- Otherwise the Authority records a name the replicated bytes do not
      -- have, and the independent read-back is set up to confirm a name
      -- nothing produces.
      regression <- requireRegression
      reportCommitRegressionForeignBytesRefused regression `shouldBe` True

    it "refuses a second and different report identity under one run" $ do
      regression <- requireRegression
      reportCommitRegressionConflictRefused regression `shouldBe` True

    it "reports a failed independent copy as a lost response, not a refusal" $ do
      -- The copy's outcome is not decidable here, and Stage C reads the report
      -- back after every commit outcome precisely so the observation decides.
      regression <- requireRegression
      reportCommitRegressionReplicationFailureIsResponseLost regression `shouldBe` True

    it "binds the granted permit to the committed report identity" $ do
      regression <- requireRegression
      reportCommitRegressionPermitIsBoundToTheReport regression `shouldBe` True

    it "hands a replaying run the permit the Authority durably holds" $ do
      regression <- requireRegression
      reportCommitRegressionPermitReplayIsTheDurableGrant regression `shouldBe` True

    it "refuses a second permit for a different report under one run" $ do
      -- Two permits under one run would be two licences to destroy the host.
      regression <- requireRegression
      reportCommitRegressionSecondReportRefusesThePermit regression `shouldBe` True

requireRegression :: IO PreUninstallReportCommitRegression
requireRegression = do
  result <- fixedPreUninstallReportCommitRegression
  case result of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
