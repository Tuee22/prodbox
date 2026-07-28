{-# LANGUAGE OverloadedStrings #-}

module DecommissionPermit (decommissionPermitSuite) where

import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitExpired, PermitFresh)
  , RunnerRole (AdminActionRunner, DecommissionRunner)
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest (FrameDigest))
import Prodbox.Lifecycle.Decommission.Permit
import TestSupport

decommissionPermitSuite :: SuiteBuilder ()
decommissionPermitSuite =
  describe "Sprint 4.50 decommission runner permit" $ do
    it "accepts a fresh matching permit under a frozen admission and ready verifier" $ do
      decide AdmissionFrozen VerifierArtifactReady PermitFresh DecommissionAwaitingPermit permit
        `shouldBe` DecommissionPermitAccepted "nonce-1"
      stepDecommissionPermit
        expectedPlan
        AdmissionFrozen
        VerifierArtifactReady
        PermitFresh
        DecommissionAwaitingPermit
        permit
        `shouldBe` (DecommissionPermitAccepted "nonce-1", DecommissionPermitConsumed "nonce-1")
    it "refuses a cross-role permit regardless of state" $ do
      let crossRole = permit {decommissionPermitAudience = AdminActionRunner}
      decide AdmissionFrozen VerifierArtifactReady PermitFresh DecommissionAwaitingPermit crossRole
        `shouldBe` DecommissionPermitRefused DecommissionWrongAudience
      decide
        AdmissionFrozen
        VerifierArtifactReady
        PermitFresh
        (DecommissionPermitConsumed "nonce-1")
        crossRole
        `shouldBe` DecommissionPermitRefused DecommissionWrongAudience
    it "refuses a permit bound to a different plan" $
      decide
        AdmissionFrozen
        VerifierArtifactReady
        PermitFresh
        DecommissionAwaitingPermit
        (permit {decommissionPermitPlanDigest = FrameDigest "plan-b"})
        `shouldBe` DecommissionPermitRefused DecommissionWrongPlan
    it "refuses until admission is frozen" $
      decide AdmissionOpen VerifierArtifactReady PermitFresh DecommissionAwaitingPermit permit
        `shouldBe` DecommissionPermitRefused DecommissionAdmissionNotFrozen
    it "refuses until the verifier artifact preflight succeeds" $
      decide AdmissionFrozen VerifierArtifactMissing PermitFresh DecommissionAwaitingPermit permit
        `shouldBe` DecommissionPermitRefused DecommissionVerifierNotReady
    it "refuses an expired permit" $
      decide AdmissionFrozen VerifierArtifactReady PermitExpired DecommissionAwaitingPermit permit
        `shouldBe` DecommissionPermitRefused DecommissionPermitExpired
    it "is idempotent on replay and conflicts on a divergent nonce" $ do
      decide
        AdmissionFrozen
        VerifierArtifactReady
        PermitFresh
        (DecommissionPermitConsumed "nonce-1")
        permit
        `shouldBe` DecommissionPermitAlreadyConsumed "nonce-1"
      decide
        AdmissionFrozen
        VerifierArtifactReady
        PermitFresh
        (DecommissionPermitConsumed "nonce-1")
        (permit {decommissionPermitNonce = "nonce-2"})
        `shouldBe` DecommissionPermitRefused DecommissionNonceConflict
 where
  expectedPlan = FrameDigest "plan-a"
  permit =
    DecommissionPermit
      { decommissionPermitAudience = DecommissionRunner
      , decommissionPermitPlanDigest = FrameDigest "plan-a"
      , decommissionPermitNonce = "nonce-1"
      }
  decide = decideDecommissionPermit expectedPlan
