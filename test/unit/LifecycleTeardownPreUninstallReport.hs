{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownPreUninstallReport
  ( lifecycleTeardownPreUninstallReportSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.PreUninstallReport
import TestSupport

lifecycleTeardownPreUninstallReportSuite :: SuiteBuilder ()
lifecycleTeardownPreUninstallReportSuite =
  describe "Sprint 4.86 the rendered pre-uninstall report" $ do
    it "renders one converged run to the same bytes and the same identity twice" $ do
      -- A rerun after a lost response re-renders its own report and finds the
      -- Authority already holding exactly it, rather than committing a second
      -- identity for the same facts.
      regression <- requireRegression
      reportRegressionRendersDeterministically regression `shouldBe` True

    it "takes its identity from the digest of its own bytes" $ do
      regression <- requireRegression
      reportRegressionIdentityIsTheDigestOfTheBytes regression `shouldBe` True

    it "names exactly the exact-absence targets the program compiled" $ do
      -- The enumeration is derived from the program, which is the same set the
      -- absence evidence's constructor required the observation set to equal,
      -- so the report cannot name more than was proven.
      regression <- requireRegression
      reportRegressionEnumeratesTheCompiledAbsenceTargets regression `shouldBe` True

    it "refuses to describe a program with another run's proofs" $ do
      regression <- requireRegression
      reportRegressionForeignEvidenceRefused regression `shouldBe` True

    it "gives two distinct converged runs two distinct identities" $ do
      regression <- requireRegression
      reportRegressionDistinctRunsRenderDistinctReports regression `shouldBe` True

    it "derives the identity the commit boundary derives from the same bytes" $ do
      -- The join the rest of Stage C rests on: neither side is told the
      -- other's answer.
      regression <- requireRegression
      reportRegressionCommitAcceptsItsOwnRendering regression `shouldBe` True

requireRegression :: IO PreUninstallReportRegression
requireRegression =
  case fixedPreUninstallReportRegression of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
