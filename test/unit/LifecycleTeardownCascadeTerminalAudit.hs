{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCascadeTerminalAudit
  ( lifecycleTeardownCascadeTerminalAuditSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
import TestSupport

lifecycleTeardownCascadeTerminalAuditSuite :: SuiteBuilder ()
lifecycleTeardownCascadeTerminalAuditSuite =
  describe "Sprint 4.86 cascade terminal escape audit" $ do
    it "issues every catalog query separately rather than as one filtered call" $ do
      regression <- requireRegression
      cascadeTerminalAuditRegressionEveryQueryIssuedSeparately regression
        `shouldBe` True

    it "derives an audit scope the evidence constructor accepts" $ do
      regression <- requireRegression
      cascadeTerminalAuditRegressionScopeAcceptedByEvidence regression `shouldBe` True

    it "classifies the retained state bucket's two decoder rows as one retained resource" $ do
      regression <- requireRegression
      cascadeTerminalAuditRegressionRetainedIsNotAnEscapee regression `shouldBe` True

    it "reports a prodbox-tagged resource no matcher retains as an escapee" $ do
      regression <- requireRegression
      cascadeTerminalAuditRegressionEscapeeRefused regression `shouldBe` True

    it "refuses to call a surface clean when a query went unanswered" $ do
      regression <- requireRegression
      cascadeTerminalAuditRegressionBlindQueryIsNotClean regression `shouldBe` True

    it "keeps a discovered escapee outranking an unanswered query" $ do
      regression <- requireRegression
      cascadeTerminalAuditRegressionEscapeeOutranksBlindQuery regression `shouldBe` True

    it "refuses the audit outright when two rows disagree about one resource" $ do
      regression <- requireRegression
      cascadeTerminalAuditRegressionDecoderConflictRefused regression `shouldBe` True

    it "never reports clean from a region that answers for no global service" $ do
      regression <- requireRegression
      cascadeTerminalAuditRegressionForeignRegionIsNeverClean regression `shouldBe` True

requireRegression :: IO CascadeTerminalAuditRegression
requireRegression = do
  result <- fixedCascadeTerminalAuditRegression
  case result of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
