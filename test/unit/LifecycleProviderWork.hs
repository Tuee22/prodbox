{-# LANGUAGE OverloadedStrings #-}

module LifecycleProviderWork (lifecycleProviderWorkSuite) where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import TestSupport

lifecycleProviderWorkSuite :: SuiteBuilder ()
lifecycleProviderWorkSuite =
  describe "Sprint 4.50 Provider Worker decision algebra" $ do
    it "admits a registered stack reconcile from idle and marks it in flight" $ do
      let (decision, next) = step ProviderIdle (SubmitProviderIntent reconcileProd)
      decision `shouldBe` ProviderWorkAdmitted coordReconcileProd
      next `shouldBe` ProviderInFlight coordReconcileProd
    it "treats an identical resubmission as an idempotent already-in-flight (no second admission)" $ do
      let (decision, next) =
            step (ProviderInFlight coordReconcileProd) (SubmitProviderIntent reconcileProd)
      decision `shouldBe` ProviderWorkAlreadyInFlight coordReconcileProd
      next `shouldBe` ProviderInFlight coordReconcileProd
    it "refuses a different intent while one is already in flight" $ do
      decide (ProviderInFlight coordReconcileProd) (SubmitProviderIntent observeProd)
        `shouldBe` ProviderWorkRefused (ProviderWorkOutstandingIntent coordReconcileProd)
    it "refuses an intent naming an unregistered resource before any effect" $ do
      decide
        ProviderIdle
        (SubmitProviderIntent (ReconcileRegisteredStack (stackRef "staging") (revision 2)))
        `shouldBe` ProviderWorkRefused (ProviderWorkUnregisteredResource "stack:staging")
    it "refuses a stack reconcile requesting a revision older than the bound revision" $ do
      decide ProviderIdle (SubmitProviderIntent (ReconcileRegisteredStack (stackRef "prod") (revision 1)))
        `shouldBe` ProviderWorkRefused (ProviderWorkRevisionStale 1 2)
    it "refuses any submit once the session deadline has passed" $ do
      decideAt (authorityTimeFromMicros 6000) ProviderIdle (SubmitProviderIntent reconcileProd)
        `shouldBe` ProviderWorkRefused ProviderWorkDeadlineReached
    it "admits a fenced aws-ses sending-identity reconcile" $ do
      decide ProviderIdle (SubmitProviderIntent reconcileSesIdentity)
        `shouldBe` ProviderWorkAdmitted coordSesIdentity
    it "cleanly closes the in-flight intent back to idle" $ do
      let (decision, next) =
            step (ProviderInFlight coordReconcileProd) (CloseProviderWork coordReconcileProd)
      decision `shouldBe` ProviderWorkClosed coordReconcileProd
      next `shouldBe` ProviderIdle
    it "refuses a close naming a coordinate other than the active one" $ do
      decide (ProviderInFlight coordReconcileProd) (CloseProviderWork coordObserveProd)
        `shouldBe` ProviderWorkRefused (ProviderWorkCoordinateMismatch coordReconcileProd)
    it "refuses a close when nothing is in flight" $ do
      decide ProviderIdle (CloseProviderWork coordReconcileProd)
        `shouldBe` ProviderWorkRefused ProviderWorkNotInFlight
    it "moves canceled/expired work into recovery" $ do
      let (decision, next) =
            step (ProviderInFlight coordReconcileProd) (RecoverProviderWork coordReconcileProd)
      decision `shouldBe` ProviderWorkRecovering coordReconcileProd
      next `shouldBe` ProviderRecovering coordReconcileProd
    it "refuses a new submit while the session is recovering" $ do
      decide (ProviderRecovering coordReconcileProd) (SubmitProviderIntent observeProd)
        `shouldBe` ProviderWorkRefused (ProviderWorkInRecovery coordReconcileProd)
    it "resolves recovery into a grace state" $ do
      let (decision, next) =
            step (ProviderRecovering coordReconcileProd) (ResolveProviderRecovery coordReconcileProd)
      decision `shouldBe` ProviderWorkResolved coordReconcileProd
      next `shouldBe` ProviderGrace coordReconcileProd
    it "admits a successor intent from the grace state" $ do
      let (decision, next) =
            step (ProviderGrace coordReconcileProd) (SubmitProviderIntent observeProd)
      decision `shouldBe` ProviderWorkAdmitted coordObserveProd
      next `shouldBe` ProviderInFlight coordObserveProd
    it "refuses a resolve when the session is not recovering" $ do
      decide ProviderIdle (ResolveProviderRecovery coordReconcileProd)
        `shouldBe` ProviderWorkRefused ProviderWorkNotInRecovery
 where
  reconcileProd = ReconcileRegisteredStack (stackRef "prod") (revision 3)
  observeProd = ObserveRegisteredStack (stackRef "prod")
  reconcileSesIdentity = ReconcileSesSendingIdentity (sesIdentity "mail")
  coordReconcileProd = providerIntentCoordinate reconcileProd
  coordObserveProd = providerIntentCoordinate observeProd
  coordSesIdentity = providerIntentCoordinate reconcileSesIdentity
  decide = decideAt (authorityTimeFromMicros 1000)
  decideAt now state command =
    decideProviderWork registered (revision 2) now (authorityTimeFromMicros 5000) state command
  step state command =
    stepProviderWork
      registered
      (revision 2)
      (authorityTimeFromMicros 1000)
      (authorityTimeFromMicros 5000)
      state
      command
  registered =
    mkRegisteredProviderResources
      ["stack:prod", "ses-identity:mail", "ses-rules:inbound", "checkpoint:scratch1"]

stackRef :: Text -> ProviderStackRef
stackRef = either (error . show) id . mkProviderStackRef

sesIdentity :: Text -> SesIdentityRef
sesIdentity = either (error . show) id . mkSesIdentityRef

revision :: Natural -> ProviderRevision
revision = either (error . show) id . mkProviderRevision
