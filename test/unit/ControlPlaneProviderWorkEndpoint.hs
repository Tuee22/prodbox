{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneProviderWorkEndpoint (controlPlaneProviderWorkEndpointSuite) where

import Data.IORef
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , decodeControlPlaneRequest
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ProviderWorkEndpoint
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ReconcileRegisteredStack)
  , ProviderWorkState (ProviderIdle, ProviderInFlight)
  , initialProviderWorkState
  , mkProviderRevision
  , mkProviderStackRef
  , mkRegisteredProviderResources
  , providerIntentCoordinate
  )
import TestSupport

controlPlaneProviderWorkEndpointSuite :: SuiteBuilder ()
controlPlaneProviderWorkEndpointSuite =
  describe "Sprint 4.50 Provider Worker role endpoint" $ do
    it "round-trips an apply payload through the shared request codec" $ do
      decodeControlPlaneRequest 4096 (encodeControlPlaneRequest submitReconcile)
        `shouldBe` Right submitReconcile
    it "admits a well-formed stack reconcile and commits the in-flight state" $ do
      (repository, stateRef) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitReconcile)
      providerWorkApplyHttpStatus result `shouldBe` 200
      providerWorkApplySummary result `shouldBe` "provider-work-admitted"
      readIORef stateRef `shouldReturn` ProviderInFlight coordReconcile
    it "treats an identical resubmission as an idempotent already-in-flight" $ do
      (repository, _) <- freshRepository (ProviderInFlight coordReconcile) False
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitReconcile)
      providerWorkApplyHttpStatus result `shouldBe` 200
      providerWorkApplySummary result `shouldBe` "provider-work-already-in-flight"
    it "refuses an unregistered resource with a 409 conflict" $ do
      (repository, stateRef) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitStaging)
      providerWorkApplyHttpStatus result `shouldBe` 409
      providerWorkApplySummary result `shouldBe` "provider-work-refused:unregistered-resource"
      readIORef stateRef `shouldReturn` ProviderIdle
    it "refuses a malformed body before reading state" $ do
      (repository, stateRef) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 4096 repository "not-a-cbor-envelope"
      result `shouldBe` ProviderWorkBadRequest ControlPlaneRequestInvalid
      providerWorkApplyHttpStatus result `shouldBe` 400
      providerWorkApplySummary result `shouldBe` "provider-work-bad-request:invalid"
      readIORef stateRef `shouldReturn` ProviderIdle
    it "refuses an oversized body before reading state" $ do
      (repository, _) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 2 repository (encodeControlPlaneRequest submitReconcile)
      result `shouldBe` ProviderWorkBadRequest ControlPlaneRequestTooLarge
      providerWorkApplyHttpStatus result `shouldBe` 400
    it "refuses a well-formed body whose reference fails re-validation" $ do
      (repository, _) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitEmptyRef)
      providerWorkApplyHttpStatus result `shouldBe` 400
      providerWorkApplySummary result `shouldBe` "provider-work-invalid-field:stack:ProviderRefEmpty"
    it "reports a failed durable commit as a retryable write failure" $ do
      (repository, _) <- freshRepository ProviderIdle True
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitReconcile)
      providerWorkApplyHttpStatus result `shouldBe` 503
      providerWorkApplySummary result `shouldBe` "provider-work-write-failed"
    it "observes the current session state without mutating it" $ do
      (repository, _) <- freshRepository (ProviderInFlight coordReconcile) False
      observed <- serveProviderWorkObserve repository
      observed `shouldBe` ProviderInFlight coordReconcile
      providerWorkObserveStatus observed `shouldBe` 200
      providerWorkObserveSummary observed `shouldBe` "provider-work-observe:in-flight"
    it "observes an idle session" $ do
      (repository, _) <- freshRepository initialProviderWorkState False
      observed <- serveProviderWorkObserve repository
      providerWorkObserveSummary observed `shouldBe` "provider-work-observe:idle"
 where
  submitReconcile =
    ProviderWorkApplyPayload
      { applyCommandKind = SubmitCommand
      , applyIntentKind = ReconcileStackIntent
      , applyResourceRef = "prod"
      , applyRequestedRevision = 3
      , applyCoordinate = ""
      }
  submitStaging = submitReconcile {applyResourceRef = "staging"}
  submitEmptyRef = submitReconcile {applyResourceRef = ""}
  coordReconcile =
    providerIntentCoordinate
      (ReconcileRegisteredStack (unsafeRef (mkProviderStackRef "prod")) (unsafeRef (mkProviderRevision 3)))
  freshRepository initial failWrites = do
    stateRef <- newIORef initial
    pure (inMemoryRepository stateRef failWrites, stateRef)

inMemoryRepository :: IORef ProviderWorkState -> Bool -> ProviderWorkRepository IO
inMemoryRepository stateRef failWrites =
  ProviderWorkRepository
    { readProviderWorkState = readIORef stateRef
    , readRegisteredProviderResources =
        pure (mkRegisteredProviderResources ["stack:prod", "ses-identity:mail"])
    , readBoundProviderRevision = pure (unsafeRef (mkProviderRevision 2))
    , readProviderAuthorityNow = pure (authorityTimeFromMicros 1000)
    , readProviderSessionDeadline = pure (authorityTimeFromMicros 5000)
    , commitProviderWorkState = \state ->
        if failWrites
          then pure (Left "retained-store commit failed")
          else do
            writeIORef stateRef state
            pure (Right ())
    }

unsafeRef :: (Show e) => Either e a -> a
unsafeRef = either (error . show) id
