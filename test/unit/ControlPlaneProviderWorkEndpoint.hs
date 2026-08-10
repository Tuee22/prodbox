{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneProviderWorkEndpoint (controlPlaneProviderWorkEndpointSuite) where

import Data.IORef
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , decodeControlPlaneRequest
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ProviderWorkEndpoint
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ReconcileRegisteredStack)
  , ProviderStackConfig
  , ProviderWorkState (ProviderIdle, ProviderInFlight)
  , initialProviderWorkState
  , mkAwsEksProviderStackConfig
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
    it "admits every closed Provider intent payload through the decision endpoint" $
      mapM_
        ( \payload -> do
            (repository, _) <- freshRepository ProviderIdle False
            result <-
              serveProviderWorkApplyRequest
                4096
                repository
                (encodeControlPlaneRequest payload)
            providerWorkApplyHttpStatus result `shouldBe` ReplyOk
        )
        allSubmitPayloads
    it "admits a well-formed stack reconcile and commits the in-flight state" $ do
      (repository, stateRef) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitReconcile)
      providerWorkApplyHttpStatus result `shouldBe` ReplyOk
      providerWorkApplySummary result `shouldBe` "provider-work-admitted"
      readIORef stateRef `shouldReturn` ProviderInFlight coordReconcile
    it "treats an identical resubmission as an idempotent already-in-flight" $ do
      (repository, _) <- freshRepository (ProviderInFlight coordReconcile) False
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitReconcile)
      providerWorkApplyHttpStatus result `shouldBe` ReplyOk
      providerWorkApplySummary result `shouldBe` "provider-work-already-in-flight"
    it "refuses an unregistered resource with a 409 conflict" $ do
      (repository, stateRef) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitStaging)
      providerWorkApplyHttpStatus result `shouldBe` ReplyConflict
      providerWorkApplySummary result `shouldBe` "provider-work-refused:unregistered-resource"
      readIORef stateRef `shouldReturn` ProviderIdle
    it "refuses a malformed body before reading state" $ do
      (repository, stateRef) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 4096 repository "not-a-cbor-envelope"
      result `shouldBe` ProviderWorkBadRequest ControlPlaneRequestInvalid
      providerWorkApplyHttpStatus result `shouldBe` ReplyBadRequest
      providerWorkApplySummary result `shouldBe` "provider-work-bad-request:invalid"
      readIORef stateRef `shouldReturn` ProviderIdle
    it "refuses an oversized body before reading state" $ do
      (repository, _) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 2 repository (encodeControlPlaneRequest submitReconcile)
      result `shouldBe` ProviderWorkBadRequest ControlPlaneRequestTooLarge
      providerWorkApplyHttpStatus result `shouldBe` ReplyBadRequest
    it "refuses a well-formed body whose reference fails re-validation" $ do
      (repository, _) <- freshRepository ProviderIdle False
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitEmptyRef)
      providerWorkApplyHttpStatus result `shouldBe` ReplyBadRequest
      providerWorkApplySummary result `shouldBe` "provider-work-invalid-field:stack:ProviderRefEmpty"
    it "reports a failed durable commit as a retryable write failure" $ do
      (repository, _) <- freshRepository ProviderIdle True
      result <- serveProviderWorkApplyRequest 4096 repository (encodeControlPlaneRequest submitReconcile)
      providerWorkApplyHttpStatus result `shouldBe` ReplyServiceUnavailable
      providerWorkApplySummary result `shouldBe` "provider-work-write-failed"
    it "observes the current session state without mutating it" $ do
      (repository, _) <- freshRepository (ProviderInFlight coordReconcile) False
      observed <- serveProviderWorkObserve repository
      observed `shouldBe` ProviderInFlight coordReconcile
      providerWorkObserveStatus observed `shouldBe` ReplyOk
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
      , applyResourceRef = "aws-eks"
      , applySecondaryRef = ""
      , applyTertiaryRef = ""
      , applyRequestedRevision = 3
      , applyStackConfig = Just awsEksConfig
      , applyCoordinate = ""
      }
  submitStaging = submitReconcile {applyResourceRef = "staging"}
  submitEmptyRef = submitReconcile {applyResourceRef = ""}
  allSubmitPayloads =
    [ submitReconcile
    , submitReconcile {applyIntentKind = DestroyStackIntent}
    , nonStack ObserveStackIntent "aws-eks" ""
    , nonStack ReadBackStackIntent "aws-eks" ""
    , nonStack ScratchCheckpointIntent "scratch" ""
    , nonStack SesSendingIdentityIntent "example.test" ""
    , nonStack SesDkimIntent "example.test" ""
    , (nonStack SesReceiptRulesIntent "prodbox-receive-rule-set" "inbox.example.test")
        { applyTertiaryRef = "capture-bucket"
        }
    , nonStack SesCaptureBucketIntent "capture-bucket" ""
    , (nonStack SesDnsIntent "Z123EXAMPLE" "example.test")
        { applyTertiaryRef = "inbox.example.test"
        }
    , nonStack ReapTestEbsVolumesIntent "prodbox-test" ""
    , nonStack ObserveSpotPriceIntent "t3.small" "Linux/UNIX"
    , nonStack ObserveOperationalIdentityIntent "" ""
    , nonStack ObserveReadinessStsIntent "" ""
    , nonStack ObserveReadinessRoute53Intent "Z123EXAMPLE" ""
    ]
  nonStack intentKind resource secondary =
    submitReconcile
      { applyIntentKind = intentKind
      , applyResourceRef = resource
      , applySecondaryRef = secondary
      , applyRequestedRevision = 0
      , applyStackConfig = Nothing
      }
  coordReconcile =
    providerIntentCoordinate
      ( ReconcileRegisteredStack
          (unsafeRef (mkProviderStackRef "aws-eks"))
          (unsafeRef (mkProviderRevision 3))
          awsEksConfig
      )
  freshRepository initial failWrites = do
    stateRef <- newIORef initial
    pure (inMemoryRepository stateRef failWrites, stateRef)

inMemoryRepository :: IORef ProviderWorkState -> Bool -> ProviderWorkRepository IO
inMemoryRepository stateRef failWrites =
  ProviderWorkRepository
    { readProviderWorkState = readIORef stateRef
    , readRegisteredProviderResources =
        pure
          ( mkRegisteredProviderResources
              [ "stack:aws-eks"
              , "checkpoint:pulumi-scratch:scratch"
              , "ses:sending-identity:example.test"
              , "ses:dkim:example.test"
              , "ses:receipt-rules:prodbox-receive-rule-set:inbox.example.test:capture-bucket"
              , "ses:capture-bucket:capture-bucket"
              , "ses:dns:Z123EXAMPLE:example.test:inbox.example.test"
              , "ebs-reaper:test-scoped:prodbox-test"
              , "spot-price:ec2:t3.small:Linux/UNIX"
              , "operational-identity"
              , "readiness:sts"
              , "readiness:route53:Z123EXAMPLE"
              ]
          )
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

awsEksConfig :: ProviderStackConfig
awsEksConfig = unsafeRef (mkAwsEksProviderStackConfig "127.0.0.1/32")

unsafeRef :: (Show e) => Either e a -> a
unsafeRef = either (error . show) id
