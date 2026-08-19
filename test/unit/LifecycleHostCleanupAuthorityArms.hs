{-# LANGUAGE OverloadedStrings #-}

module LifecycleHostCleanupAuthorityArms
  ( lifecycleHostCleanupAuthorityArmsSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.HostCleanupAuthorityArms
import Prodbox.Lifecycle.HostCleanupRunner (HostCleanupEffectOutcome (..))
import TestSupport

lifecycleHostCleanupAuthorityArmsSuite :: SuiteBuilder ()
lifecycleHostCleanupAuthorityArmsSuite =
  describe "Sprint 4.86 host cleanup Lifecycle-Authority arms" $ do
    describe "accepting the readiness and reading it back" $ do
      it "turns an accepted readiness into the exact proof the runner holds" $ do
        regression <- requireRegression
        authorityArmsRegressionAcceptedBecomesReadBack regression `shouldBe` True

      it "accepts the same readiness twice without minting a second slot" $ do
        regression <- requireRegression
        authorityArmsRegressionAcceptIsIdempotent regression `shouldBe` True

      it "refuses a second, different readiness under one run" $ do
        -- Two readiness proofs under one run id would be two permits.
        regression <- requireRegression
        authorityArmsRegressionConflictRefused regression `shouldBe` True

      it "refuses readiness that belongs to another run" $ do
        regression <- requireRegression
        authorityArmsRegressionForeignRunRefused regression `shouldBe` True

      it "keeps a slot that holds nothing distinct from one it could not read" $ do
        -- The two need different remedies, so the runner never sees them
        -- collapsed into one failure.
        regression <- requireRegression
        authorityArmsRegressionMissingIsNotUnobservable regression `shouldBe` True

      it "does not accept the acceptance response as evidence of durability" $ do
        regression <- requireRegression
        authorityArmsRegressionAcceptResponseNotEvidence regression `shouldBe` True

    describe "re-establishing the Authority" $ do
      it "never awaits admission when the aggregate was not restored" $ do
        -- Admission from an Authority whose bytes were not restored would be an
        -- empty control plane that has forgotten the run.
        regression <- requireRegression
        authorityArmsRegressionFailedRestoreNeverAwaits regression `shouldBe` True

      it "reports what the attempt did and never that readiness survived" $ do
        regression <- requireRegression
        authorityArmsRegressionRestoreIsNotReadiness regression `shouldBe` True

      it "renders every attempt as an operator-readable line" $ do
        mapM_
          ( \attempt ->
              renderLifecycleAuthorityReestablishment attempt
                `shouldSatisfy` Text.isInfixOf "lifecycle authority"
          )
          [ LifecycleAuthorityRestored
          , LifecycleAuthorityRestoreFailed "backup domain unreachable"
          , LifecycleAuthorityAdmissionUnavailable "no reply"
          ]

      it "refuses every attempt that is not a completed restore" $ do
        mapM_
          ( \attempt ->
              lifecycleAuthorityReestablishmentEffect attempt
                `shouldSatisfy` isRefused
          )
          [ LifecycleAuthorityRestoreFailed "backup domain unreachable"
          , LifecycleAuthorityAdmissionUnavailable "no reply"
          ]

    describe "reconciling the cleanup run" $ do
      it "re-issues its own attempt rather than a second one" $ do
        regression <- requireRegression
        authorityArmsRegressionRunReconcileIsIdempotent regression `shouldBe` True

      it "refuses when the Authority holds no run to reconcile" $ do
        regression <- requireRegression
        authorityArmsRegressionRunMissingRefused regression `shouldBe` True

      it "reports a transport failure as a lost response, not a refusal" $ do
        -- The transition may have landed; the run read-back decides.
        regression <- requireRegression
        authorityArmsRegressionRunTransportIsResponseLost regression `shouldBe` True

      it "names the node the destructive host boundary owns" $ do
        hostCleanupLocalUninstallNodeId `shouldBe` "lifecycle/cascade/uninstall-local"

      it "renders every reconciliation as an operator-readable line" $ do
        mapM_
          ( \reconciliation ->
              renderHostCleanupRunReconciliation reconciliation
                `shouldSatisfy` (not . Text.null)
          )
          [ HostCleanupRunReconciled
          , HostCleanupRunNodeUnknown hostCleanupLocalUninstallNodeId
          , HostCleanupRunAttemptInvalid "empty"
          , HostCleanupRunRefused "fenced"
          , HostCleanupRunMissing
          ]

requireRegression :: IO HostCleanupAuthorityArmsRegression
requireRegression = do
  attempted <- fixedHostCleanupAuthorityArmsRegression
  case attempted of
    Left detail ->
      expectationFailure (Text.unpack detail) >> fail "unreachable"
    Right regression -> pure regression

isRefused :: HostCleanupEffectOutcome -> Bool
isRefused outcome = case outcome of
  HostCleanupEffectRefused _ -> True
  _ -> False
