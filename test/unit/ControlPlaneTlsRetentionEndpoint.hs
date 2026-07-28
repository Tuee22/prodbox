{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTlsRetentionEndpoint (controlPlaneTlsRetentionEndpointSuite) where

import Data.IORef
import Prodbox.ControlPlane.TlsRetentionEndpoint
import Prodbox.Lifecycle.Authority.TlsRetention
import TestSupport

controlPlaneTlsRetentionEndpointSuite :: SuiteBuilder ()
controlPlaneTlsRetentionEndpointSuite =
  describe "Sprint 4.50 TLS Retention role endpoint" $ do
    it "promotes and commits a first renewal store" $ do
      (repository, stateRef) <- freshRepository
      result <- serveTlsStore repository KeyRotationNotApproved goodEvidence ref1
      result `shouldBe` TlsStoreDecided (TlsPromoted ref1)
      tlsRetentionHttpStatus result `shouldBe` 200
      tlsRetentionSummary result `shouldBe` "tls-promoted"
      (currentRetainedRef <$> readIORef stateRef) `shouldReturn` Just ref1
    it "refuses a store without source re-observation and does not commit" $ do
      (repository, stateRef) <- freshRepository
      result <- serveTlsStore repository KeyRotationNotApproved (PromotionEvidence False True) ref1
      result `shouldBe` TlsStoreDecided (TlsPromotionRefused TlsSourceNotReobserved)
      tlsRetentionHttpStatus result `shouldBe` 409
      tlsRetentionSummary result `shouldBe` "tls-promotion-refused:source-not-reobserved"
      readIORef stateRef `shouldReturn` initialTlsRetentionState
    it "treats a re-store of the current reference as an idempotent no-op" $ do
      (repository, _) <- freshRepository
      _ <- serveTlsStore repository KeyRotationNotApproved goodEvidence ref1
      result <- serveTlsStore repository KeyRotationNotApproved goodEvidence ref1
      result `shouldBe` TlsStoreDecided (TlsPromotionNoop ref1)
      tlsRetentionHttpStatus result `shouldBe` 200
      tlsRetentionSummary result `shouldBe` "tls-promotion-noop"
    it "reports a failed durable commit as a retryable write failure" $ do
      stateRef <- newIORef initialTlsRetentionState
      let repository = inMemoryRepository stateRef True
      result <- serveTlsStore repository KeyRotationNotApproved goodEvidence ref1
      tlsRetentionHttpStatus result `shouldBe` 503
      tlsRetentionSummary result `shouldBe` "tls-store-write-failed"
    it "applies, issues, or fails a restore against the committed reference" $ do
      stateRef <- newIORef (TlsRetentionCurrent ref1)
      let repository = inMemoryRepository stateRef False
      apply <- serveTlsRestore repository (RestoreCommittedIntact ref1)
      apply `shouldBe` TlsRestoreDecided (TlsRestoreApply ref1)
      tlsRetentionSummary apply `shouldBe` "tls-restore-apply"
      issue <- serveTlsRestore repository RestoreCommittedAbsent
      tlsRetentionSummary issue `shouldBe` "tls-restore-issue"
      mismatch <- serveTlsRestore repository (RestoreCommittedIntact ref2)
      tlsRetentionHttpStatus mismatch `shouldBe` 409
      corrupt <- serveTlsRestore repository RestoreCommittedCorrupt
      tlsRetentionHttpStatus corrupt `shouldBe` 500
      tlsRetentionSummary corrupt `shouldBe` "tls-restore-refused:corrupt"
 where
  goodEvidence = PromotionEvidence True True
  src = SourceSecretRef "uid-1" "rv-1"
  ref1 = RetainedTlsRef (RetentionVersion 1) (CertIdentity "serial-1" "spki-A" 1000) "ct-1" src
  ref2 = RetainedTlsRef (RetentionVersion 2) (CertIdentity "serial-2" "spki-A" 2000) "ct-2" src
  freshRepository = do
    stateRef <- newIORef initialTlsRetentionState
    pure (inMemoryRepository stateRef False, stateRef)

inMemoryRepository :: IORef TlsRetentionState -> Bool -> TlsRetentionRepository IO
inMemoryRepository stateRef failWrites =
  TlsRetentionRepository
    { readRetentionState = readIORef stateRef
    , commitRetainedRef = \ref ->
        if failWrites
          then pure (Left "retained-store commit failed")
          else do
            writeIORef stateRef (TlsRetentionCurrent ref)
            pure (Right ())
    }
