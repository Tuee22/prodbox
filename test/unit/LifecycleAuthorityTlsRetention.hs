{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityTlsRetention
  ( lifecycleAuthorityTlsRetentionSuite
  )
where

import Prodbox.Lifecycle.Authority.TlsRetention
import TestSupport

lifecycleAuthorityTlsRetentionSuite :: SuiteBuilder ()
lifecycleAuthorityTlsRetentionSuite =
  describe "Sprint 4.48 Lifecycle Authority TLS-retention promotion/restore fold" $ do
    it "promotes the first candidate from empty and records it as current" $ do
      let (d, s) = stepTlsPromotion KeyRotationNotApproved goodEvidence initialTlsRetentionState ref1
      d `shouldBe` TlsPromoted ref1
      currentRetainedRef s `shouldBe` Just ref1

    it "fails closed without source re-observation or adapter read-back" $ do
      decideTlsPromotion
        KeyRotationNotApproved
        (PromotionEvidence False True)
        initialTlsRetentionState
        ref1
        `shouldBe` TlsPromotionRefused TlsSourceNotReobserved
      decideTlsPromotion
        KeyRotationNotApproved
        (PromotionEvidence True False)
        initialTlsRetentionState
        ref1
        `shouldBe` TlsPromotionRefused TlsAdapterReadBackMismatch

    it "promotes a strictly-newer, non-regressing, same-key candidate" $
      decideTlsPromotion KeyRotationNotApproved goodEvidence current1 ref2
        `shouldBe` TlsPromoted ref2

    it "refuses an out-of-order (lower-version) candidate as stale" $
      decideTlsPromotion KeyRotationNotApproved goodEvidence current2 ref1
        `shouldBe` TlsPromotionRefused TlsStaleVersion

    it
      "is an idempotent no-op on the exact current version and a stale conflict on same-version-different-content"
      $ do
        decideTlsPromotion KeyRotationNotApproved goodEvidence current1 ref1
          `shouldBe` TlsPromotionNoop ref1
        decideTlsPromotion
          KeyRotationNotApproved
          goodEvidence
          current1
          ref1 {retainedCiphertextDigest = "ct-divergent"}
          `shouldBe` TlsPromotionRefused TlsStaleVersion

    it "refuses a certificate validity regression" $
      decideTlsPromotion KeyRotationNotApproved goodEvidence current2 refRegress
        `shouldBe` TlsPromotionRefused TlsValidityRegression

    it "refuses an unapproved key change but promotes an approved one" $ do
      decideTlsPromotion KeyRotationNotApproved goodEvidence current1 refKeyChange
        `shouldBe` TlsPromotionRefused TlsUnapprovedKeyChange
      decideTlsPromotion KeyRotationApproved goodEvidence current1 refKeyChange
        `shouldBe` TlsPromoted refKeyChange

    it "restores the exact committed reference on an intact read-back, and rejects a mismatched one" $ do
      decideTlsRestore current1 (RestoreCommittedIntact ref1) `shouldBe` TlsRestoreApply ref1
      decideTlsRestore current1 (RestoreCommittedIntact ref2)
        `shouldBe` TlsRestoreRefused TlsRestoreReferenceMismatch
      decideTlsRestore initialTlsRetentionState (RestoreCommittedIntact ref1)
        `shouldBe` TlsRestoreRefused TlsRestoreReferenceMismatch

    it "permits issuance only on positive absence or trusted-time expiry" $ do
      decideTlsRestore current1 RestoreCommittedAbsent `shouldBe` TlsRestoreIssue
      decideTlsRestore current1 RestoreTrustedTimeExpired `shouldBe` TlsRestoreIssue

    it "fails closed on corrupt or unobservable committed state" $ do
      decideTlsRestore current1 RestoreCommittedCorrupt
        `shouldBe` TlsRestoreRefused TlsRestoreCorrupt
      decideTlsRestore current1 RestoreCommittedUnobservable
        `shouldBe` TlsRestoreRefused TlsRestoreUnobservable
 where
  goodEvidence = PromotionEvidence True True
  src = SourceSecretRef "uid-1" "rv-1"
  ref1 = RetainedTlsRef (RetentionVersion 1) (CertIdentity "serial-1" "spki-A" 1000) "ct-1" src
  ref2 = RetainedTlsRef (RetentionVersion 2) (CertIdentity "serial-2" "spki-A" 2000) "ct-2" src
  refRegress = RetainedTlsRef (RetentionVersion 3) (CertIdentity "serial-3" "spki-A" 500) "ct-3" src
  refKeyChange = RetainedTlsRef (RetentionVersion 2) (CertIdentity "serial-2" "spki-B" 2000) "ct-2" src
  current1 = TlsRetentionCurrent ref1
  current2 = TlsRetentionCurrent ref2
