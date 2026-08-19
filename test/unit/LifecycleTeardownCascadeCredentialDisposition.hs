{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCascadeCredentialDisposition
  ( lifecycleTeardownCascadeCredentialDispositionSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.CascadeCredentialDisposition
import TestSupport

lifecycleTeardownCascadeCredentialDispositionSuite :: SuiteBuilder ()
lifecycleTeardownCascadeCredentialDispositionSuite =
  describe "Sprint 4.86 cascade credential disposition" $ do
    it "asks about every disposable class exactly once, in inventory order" $ do
      regression <- requireRegression
      credentialDispositionRegressionEveryDisposableClassAsked regression `shouldBe` True

    it "keeps the operational credential outside the disposal set" $ do
      regression <- requireRegression
      credentialDispositionRegressionOperationalClassRetained regression `shouldBe` True

    it "reports disposition only when every class was observed absent" $ do
      regression <- requireRegression
      credentialDispositionRegressionAbsentSetIsDisposed regression `shouldBe` True

    it "reports a still-present credential as outstanding" $ do
      regression <- requireRegression
      credentialDispositionRegressionPresentIsOutstanding regression `shouldBe` True

    it "refuses to read an unanswered class as disposition" $ do
      regression <- requireRegression
      credentialDispositionRegressionUnansweredIsNotDisposed regression `shouldBe` True

    it "lets a present credential outrank an unanswered one" $ do
      regression <- requireRegression
      credentialDispositionRegressionPresentOutranksUnanswered regression `shouldBe` True

    it "produces an observation the evidence constructor accepts" $ do
      regression <- requireRegression
      credentialDispositionRegressionDisposedAcceptedByEvidence regression `shouldBe` True

    it "produces an outstanding observation the evidence constructor refuses" $ do
      regression <- requireRegression
      credentialDispositionRegressionOutstandingRefusedByEvidence regression `shouldBe` True

    it "partitions the credential inventory without leaving a class unowned" $ do
      -- The retained set is the complement rather than a second authored list,
      -- so a class cannot be absent from both and become nobody's concern.
      let disposable = cascadeDisposableCredentialClasses
          retained = cascadeRetainedCredentialClasses
      disposable `shouldSatisfy` (not . null)
      filter (`elem` retained) disposable `shouldBe` []

    it "renders its one refusal" $ do
      Text.pack
        (show CascadeCredentialDispositionNothingToObserve)
        `shouldSatisfy` (not . Text.null)
      renderCascadeCredentialDispositionRefusal
        CascadeCredentialDispositionNothingToObserve
        `shouldSatisfy` Text.isInfixOf "run-scoped"

requireRegression :: IO CascadeCredentialDispositionRegression
requireRegression = do
  result <- fixedCascadeCredentialDispositionRegression
  case result of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
