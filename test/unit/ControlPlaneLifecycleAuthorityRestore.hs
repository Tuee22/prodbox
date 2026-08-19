{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneLifecycleAuthorityRestore
  ( controlPlaneLifecycleAuthorityRestoreSuite
  )
where

import Data.Text qualified as Text
import Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction
import Prodbox.Lifecycle.Authority.BackupRepair (BackupHealth (..))
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (GenesisFrozen)
  , BackupReceipt (..)
  , authorityEpochGenesis
  )
import TestSupport

controlPlaneLifecycleAuthorityRestoreSuite :: SuiteBuilder ()
controlPlaneLifecycleAuthorityRestoreSuite =
  describe "Sprint 4.86 production Lifecycle-Authority restore boundary" $ do
    describe "restoring the aggregate" $ do
      it "restores only from an established aggregate the backup domain confirms" $ do
        regression <- requireRegression
        authorityRestoreRegressionEstablishedAndHealthyRestores regression
          `shouldBe` True

      it "never advances genesis on behalf of a cascade" $ do
        -- A cascade that ran genesis would produce an Authority that admits
        -- requests and has forgotten the run.
        regression <- requireRegression
        authorityRestoreRegressionGenesisNeverRestores regression `shouldBe` True

      it "keeps a repair-frozen aggregate distinct from a genesis-frozen one" $ do
        regression <- requireRegression
        authorityRestoreRegressionRepairFrozenNeverRestores regression
          `shouldBe` True

      it "refuses when the independent backup domain is not healthy" $ do
        regression <- requireRegression
        authorityRestoreRegressionUnhealthyBackupRefused regression `shouldBe` True

      it "asks the backup domain about the receipt the projection itself named" $ do
        regression <- requireRegression
        authorityRestoreRegressionBackupAskedForTheNamedReceipt regression
          `shouldBe` True

    describe "what the bounded wait is for" $ do
      it "waits on a control plane that is not yet routable" $ do
        regression <- requireRegression
        authorityRestoreRegressionTransientStateWaited regression `shouldBe` True

      it "does not wait on a decided refusal" $ do
        -- Retrying an answer would report a timeout where the run should
        -- report the refusal.
        regression <- requireRegression
        authorityRestoreRegressionDecidedStateNotWaited regression `shouldBe` True

      it "does not wait on a terminal observation failure" $ do
        regression <- requireRegression
        authorityRestoreRegressionTerminalFailureNotWaited regression
          `shouldBe` True

      it "refuses a wait that would take no observation at all" $ do
        mkLifecycleAuthorityAdmissionWait 0 10 `shouldSatisfy` isLeft

      it "admits a wait that takes exactly one observation" $ do
        fmap
          lifecycleAuthorityAdmissionAttempts
          (mkLifecycleAuthorityAdmissionWait 1 10)
          `shouldBe` Right 1

      it "carries the delay it was given" $ do
        fmap
          lifecycleAuthorityAdmissionDelayMicros
          (mkLifecycleAuthorityAdmissionWait 1 250)
          `shouldBe` Right 250

    describe "awaiting admission" $ do
      it "waits for a starting control plane and then admits" $ do
        regression <- requireRegression
        authorityRestoreRegressionAdmissionWaitsThenAdmits regression
          `shouldBe` True

      it "reports the last decided state when the bound runs out" $ do
        regression <- requireRegression
        authorityRestoreRegressionAdmissionExhausts regression `shouldBe` True

    describe "the composed boundary" $ do
      it "never awaits admission when the aggregate was not restored" $ do
        regression <- requireRegression
        authorityRestoreRegressionRestoreDoesNotAwait regression `shouldBe` True

      it "renders every restore observation as an operator-readable line" $ do
        mapM_
          ( \observation ->
              renderAuthorityAggregateRestoreObservation observation
                `shouldSatisfy` (not . Text.null)
          )
          [ AuthorityAggregateRestored authorityEpochGenesis fixedReceipt
          , AuthorityAggregateNotEstablished GenesisFrozen
          , AuthorityAggregateBackupUnhealthy BackupPolicyDrift
          , AuthorityAggregateStateUnobservable "no reply"
          , AuthorityAggregateBackupUnobservable "no reply"
          ]

      it "renders every admission outcome as an operator-readable line" $ do
        mapM_
          ( \outcome ->
              renderLifecycleAuthorityAdmissionOutcome outcome
                `shouldSatisfy` (not . Text.null)
          )
          [ LifecycleAuthorityAdmits authorityEpochGenesis
          , LifecycleAuthorityDoesNotAdmit GenesisFrozen
          , LifecycleAuthorityAdmissionUnobservable "no reply"
          ]

      it "answers only a restored aggregate with success" $ do
        authorityAggregateRestoreResult
          (AuthorityAggregateRestored authorityEpochGenesis fixedReceipt)
          `shouldBe` Right ()
        authorityAggregateRestoreResult
          (AuthorityAggregateNotEstablished GenesisFrozen)
          `shouldSatisfy` isLeft

      it "answers only an admitting authority with success" $ do
        lifecycleAuthorityAdmissionResult
          (LifecycleAuthorityAdmits authorityEpochGenesis)
          `shouldBe` Right ()
        lifecycleAuthorityAdmissionResult
          (LifecycleAuthorityDoesNotAdmit GenesisFrozen)
          `shouldSatisfy` isLeft

requireRegression :: IO LifecycleAuthorityRestoreRegression
requireRegression = do
  attempted <- fixedLifecycleAuthorityRestoreRegression
  case attempted of
    Left detail ->
      expectationFailure (Text.unpack detail) >> fail "unreachable"
    Right regression -> pure regression

fixedReceipt :: BackupReceipt
fixedReceipt = BackupReceipt "fixed-authority-aggregate-receipt"

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
