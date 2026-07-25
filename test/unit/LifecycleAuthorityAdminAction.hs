{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityAdminAction
  ( lifecycleAuthorityAdminActionSuite
  )
where

import Prodbox.Lifecycle.Authority.AdminAction
import TestSupport

lifecycleAuthorityAdminActionSuite :: SuiteBuilder ()
lifecycleAuthorityAdminActionSuite =
  describe "Sprint 4.48 Lifecycle Authority admin-action permit acceptance" $ do
    it "accepts a fresh permit for its own audience and instantiated action, consuming it once" $ do
      let (d, s) = stepAdminPermit DestroyAwsSes PermitFresh initialAdminRunnerState destroyPermit
      d `shouldBe` AdminPermitAccepted "nonce-1"
      s `shouldBe` AdminPermitConsumed "nonce-1"

    it "refuses a permit issued for any other runner role (cross-role)" $
      mapM_
        ( \role ->
            decideAdminPermit
              DestroyAwsSes
              PermitFresh
              initialAdminRunnerState
              (AdminActionPermit role DestroyAwsSes "nonce-1")
              `shouldBe` AdminPermitRefused AdminPermitWrongAudience
        )
        [CredentialProvisioner, ProviderWorker, DecommissionRunner]

    it "refuses a permit bound to a different action (cross-action)" $
      decideAdminPermit
        DestroyAwsSes
        PermitFresh
        initialAdminRunnerState
        (AdminActionPermit AdminActionRunner MigrateLegacyBackend "nonce-1")
        `shouldBe` AdminPermitRefused AdminPermitWrongAction

    it "refuses an expired permit while awaiting" $
      decideAdminPermit DestroyAwsSes PermitExpired initialAdminRunnerState destroyPermit
        `shouldBe` AdminPermitRefused AdminPermitExpired

    it "is idempotent on replay of the consumed permit, even once expired (response-loss safe)" $ do
      let (_, consumed) = stepAdminPermit DestroyAwsSes PermitFresh initialAdminRunnerState destroyPermit
      decideAdminPermit DestroyAwsSes PermitFresh consumed destroyPermit
        `shouldBe` AdminPermitAlreadyConsumed "nonce-1"
      decideAdminPermit DestroyAwsSes PermitExpired consumed destroyPermit
        `shouldBe` AdminPermitAlreadyConsumed "nonce-1"

    it "refuses a different nonce after a permit has been consumed" $ do
      let (_, consumed) = stepAdminPermit DestroyAwsSes PermitFresh initialAdminRunnerState destroyPermit
      decideAdminPermit
        DestroyAwsSes
        PermitFresh
        consumed
        (AdminActionPermit AdminActionRunner DestroyAwsSes "nonce-2")
        `shouldBe` AdminPermitRefused AdminPermitNonceConflict

    it "checks audience before state: a cross-role permit is refused even after consumption" $ do
      let (_, consumed) = stepAdminPermit DestroyAwsSes PermitFresh initialAdminRunnerState destroyPermit
      decideAdminPermit
        DestroyAwsSes
        PermitFresh
        consumed
        (AdminActionPermit ProviderWorker DestroyAwsSes "nonce-2")
        `shouldBe` AdminPermitRefused AdminPermitWrongAudience

    it "each disjoint admin action can be the runner's instantiated action" $ do
      fst
        ( stepAdminPermit
            ReconcileQuota
            PermitFresh
            initialAdminRunnerState
            (AdminActionPermit AdminActionRunner ReconcileQuota "nq")
        )
        `shouldBe` AdminPermitAccepted "nq"
      fst
        ( stepAdminPermit
            MigrateLegacyBackend
            PermitFresh
            initialAdminRunnerState
            (AdminActionPermit AdminActionRunner MigrateLegacyBackend "nm")
        )
        `shouldBe` AdminPermitAccepted "nm"
 where
  destroyPermit = AdminActionPermit AdminActionRunner DestroyAwsSes "nonce-1"
