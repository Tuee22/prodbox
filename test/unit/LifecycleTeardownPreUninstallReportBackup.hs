{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownPreUninstallReportBackup
  ( lifecycleTeardownPreUninstallReportBackupSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.PreUninstallReportBackup
import TestSupport

lifecycleTeardownPreUninstallReportBackupSuite :: SuiteBuilder ()
lifecycleTeardownPreUninstallReportBackupSuite =
  describe "Sprint 4.86 Stage C independent report read-back" $ do
    it "reports a present backup as an observed receipt" $ do
      regression <- requireRegression
      reportBackupRegressionPresentIsObserved regression `shouldBe` True

    it "reports the identity the adapter confirmed, not the one it was asked about" $ do
      -- Stage C's drift check compares the committed digest against this
      -- observation's, so answering with the caller's own question would make
      -- that comparison compare a value with itself.
      regression <- requireRegression
      reportBackupRegressionPresentCarriesReceiptIdentity regression `shouldBe` True

    it "keeps an absent backup distinct from one it could not observe" $ do
      -- A report the independent domain never received is a decided answer
      -- about the commit; a domain that answered nothing decides nothing.
      regression <- requireRegression
      reportBackupRegressionMissingIsNotUnobservable regression `shouldBe` True

    it "treats a corrupt backup as unobservable rather than absent" $ do
      regression <- requireRegression
      reportBackupRegressionCorruptIsUnobservable regression `shouldBe` True

    it "treats an unreachable backup domain as unobservable rather than absent" $ do
      -- The fail-open shape an independent read-back exists to exclude: an
      -- adapter nobody could reach must not read as "the commit never landed".
      regression <- requireRegression
      reportBackupRegressionTransportIsUnobservable regression `shouldBe` True

    it "produces an observation the run that asked for it accepts" $ do
      regression <- requireRegression
      reportBackupRegressionObservationSatisfiesItsOwnRun regression `shouldBe` True

    it "produces an observation another run refuses" $ do
      -- The receipt carries this compiled run's scope and graph digest, so a
      -- report durable under some other run cannot satisfy this one.
      regression <- requireRegression
      reportBackupRegressionObservationRefusedByAnotherRun regression `shouldBe` True

requireRegression :: IO PreUninstallReportBackupRegression
requireRegression =
  case fixedPreUninstallReportBackupRegression of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
