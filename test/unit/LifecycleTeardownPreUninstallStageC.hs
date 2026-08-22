{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownPreUninstallStageC
  ( lifecycleTeardownPreUninstallStageCSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.PreUninstallStageC
import TestSupport

lifecycleTeardownPreUninstallStageCSuite :: SuiteBuilder ()
lifecycleTeardownPreUninstallStageCSuite =
  describe "Sprint 4.86 Stage C composed from a converged run to readiness" $ do
    it "reaches readiness when the whole chain lands" $ do
      -- Render, commit, replicate, read back, permit, compose. Before this
      -- composition every one of those surfaces existed and none of them met.
      regression <- requireRegression
      stageCRegressionReadyFromConvergedRun regression `shouldBe` True

    it "signs the permit over the identity of the report it rendered" $ do
      -- No caller names a report identity: it is the digest of the bytes this
      -- run rendered from its own convergence proofs.
      regression <- requireRegression
      stageCRegressionReadinessCarriesTheRenderedIdentity regression `shouldBe` True

    it "reads durability back from the independent domain before the permit" $ do
      -- The Authority records the identity, the independent domain takes the
      -- copy and answers the read-back that decides durability, and only then
      -- is the permit signed -- so the licence to uninstall is never issued
      -- ahead of the observation that justifies it.
      regression <- requireRegression
      stageCRegressionReadBackIsAnsweredByTheIndependentDomain regression `shouldBe` True

    it "refuses a report described by another run's proofs" $ do
      regression <- requireRegression
      stageCRegressionForeignEvidenceRefused regression `shouldBe` True

    it "reaches no client at all when the proofs describe another run" $ do
      -- A report is a durable statement that this run converged, so a run that
      -- cannot make the statement must not reach the surface that records it.
      regression <- requireRegression
      stageCRegressionForeignEvidenceWritesNothing regression `shouldBe` True

    it "is not ready when the independent domain holds nothing" $ do
      -- A commit that reported success and left nothing durable is not ready.
      regression <- requireRegression
      stageCRegressionMissingCopyIsNotReady regression `shouldBe` True

    it "is not ready when the independent domain answers nothing" $ do
      -- An unreachable adapter decides nothing, and reading that as clean is
      -- the fail-open shape an independent read-back exists to exclude.
      regression <- requireRegression
      stageCRegressionUnobservableDomainIsNotReady regression `shouldBe` True

    it "re-renders one identity when the same converged run runs twice" $ do
      -- The bytes are canonical, so a resumed cascade finds the Authority
      -- already holding exactly its own identity.
      regression <- requireRegression
      stageCRegressionRerunCommitsOneIdentity regression `shouldBe` True

requireRegression :: IO PreUninstallStageCRegression
requireRegression = do
  result <- fixedPreUninstallStageCRegression
  case result of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
