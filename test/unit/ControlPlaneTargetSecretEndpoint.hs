{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTargetSecretEndpoint (controlPlaneTargetSecretEndpointSuite) where

import Data.Text qualified as Text
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TargetSecretEndpoint
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasRequest (ModelBInitialize)
  , ModelBObservation (ModelBMissing, ModelBObserved)
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , mkTargetClusterSecretSink
  )
import Prodbox.Lifecycle.Lease
  ( FencedCommitPermit
  , LeaseAcquireDecision (LeaseAcquireCompareAndSwap)
  , LeaseCommitDecision (LeaseCommitAuthorized)
  , LeaseKey
  , authorityTimeFromMicros
  , beginLeaseAcquire
  , decideFencedCommit
  , decideLeaseAcquire
  , defaultSesLeasePolicy
  , leaseProjectionActiveGrant
  , mkLeaseKey
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetCommitCompleteDecision (TargetCommitCompleteAlreadyApplied, TargetCommitCompleteRefused)
  , TargetCommitPrepareDecision (TargetCommitPrepareCompareAndSwap, TargetCommitPrepareRefused)
  , TargetCommitRefusal
    ( TargetCommitGlobalCorrupt
    , TargetCommitGlobalMissingAfterPrepare
    , TargetCommitGlobalUnobservable
    , TargetCommitUnregisteredTarget
    )
  , mkRegisteredTargetSet
  , mkTargetIntentCoordinate
  )
import TestSupport

controlPlaneTargetSecretEndpointSuite :: SuiteBuilder ()
controlPlaneTargetSecretEndpointSuite =
  describe "Sprint 4.50 Target Secret Agent role endpoint" $ do
    describe "response projection" $ do
      it "classifies an unobservable projection as 503 and a corrupt/missing one as 500" $ do
        targetCommitRefusalStatus (TargetCommitGlobalUnobservable "backend down") `shouldBe` 503
        targetCommitRefusalStatus (TargetCommitGlobalCorrupt "bad bytes") `shouldBe` 500
        targetCommitRefusalStatus TargetCommitGlobalMissingAfterPrepare `shouldBe` 500
      it "classifies every other refusal as a 409 conflict" $
        targetCommitRefusalStatus (TargetCommitUnregisteredTarget "vscode") `shouldBe` 409
      it "projects a refused prepare onto its status and stable token" $ do
        let refused = TargetCommitPrepareRefused (TargetCommitUnregisteredTarget "vscode")
        targetPrepareHttpStatus refused `shouldBe` 409
        targetPrepareSummary refused `shouldBe` "target-prepare-refused:unregistered-target"
        let unobservable = TargetCommitPrepareRefused (TargetCommitGlobalUnobservable "down")
        targetPrepareHttpStatus unobservable `shouldBe` 503
      it "projects a refused complete and an idempotent already-applied complete" $ do
        let refused = TargetCommitCompleteRefused (TargetCommitGlobalCorrupt "bad")
        targetCompleteHttpStatus refused `shouldBe` 500
        targetCompleteSummary refused `shouldBe` "target-complete-refused:global-corrupt"
        targetCompleteHttpStatus TargetCommitCompleteAlreadyApplied `shouldBe` 200
        targetCompleteSummary TargetCommitCompleteAlreadyApplied
          `shouldBe` "target-complete-already-applied"
      it "gives every refusal token a nonempty stable label" $
        all
          (\refusal -> targetCommitRefusalToken refusal /= "")
          [ TargetCommitGlobalMissingAfterPrepare
          , TargetCommitGlobalCorrupt "x"
          , TargetCommitGlobalUnobservable "x"
          , TargetCommitUnregisteredTarget "x"
          ]
          `shouldBe` True

    describe "prepare request handler (Sprint 4.50)" $ do
      it "refuses a malformed body before reading any authority input" $ do
        result <- servePrepareTargetCommitRequest 4096 repository "not-a-cbor-envelope"
        result `shouldBe` TargetPrepareCodecRejected ControlPlaneRequestInvalid
        targetPrepareEndpointStatus result `shouldBe` 400
        targetPrepareEndpointSummary result `shouldBe` "target-prepare-bad-request:invalid"
      it "refuses an oversized body before reading any authority input" $ do
        result <- servePrepareTargetCommitRequest 2 repository (encodeControlPlaneRequest validPayload)
        result `shouldBe` TargetPrepareCodecRejected ControlPlaneRequestTooLarge
        targetPrepareEndpointStatus result `shouldBe` 400
        targetPrepareEndpointSummary result `shouldBe` "target-prepare-bad-request:too-large"
      it "refuses a zero generation as an invalid field before deciding" $ do
        let body = encodeControlPlaneRequest validPayload {prepareGeneration = 0}
        result <- servePrepareTargetCommitRequest 4096 repository body
        targetPrepareEndpointStatus result `shouldBe` 400
        Text.isPrefixOf "target-prepare-invalid-field:generation:" (targetPrepareEndpointSummary result)
          `shouldBe` True
      it "refuses an empty digest as an invalid field before deciding" $ do
        let body = encodeControlPlaneRequest validPayload {prepareDigest = ""}
        result <- servePrepareTargetCommitRequest 4096 repository body
        targetPrepareEndpointStatus result `shouldBe` 400
        Text.isPrefixOf "target-prepare-invalid-field:digest:" (targetPrepareEndpointSummary result)
          `shouldBe` True
      it "decodes a well-formed prepare and drives the proven algebra to a guarded CAS" $ do
        result <- servePrepareTargetCommitRequest 4096 repository (encodeControlPlaneRequest validPayload)
        case result of
          TargetPrepareDecided (TargetCommitPrepareCompareAndSwap _ _) -> pure ()
          other -> expectationFailure ("expected a prepare compare-and-swap, got " <> show other)
        targetPrepareEndpointStatus result `shouldBe` 200
        targetPrepareEndpointSummary result `shouldBe` "target-prepare-cas"
      it "refuses a prepare whose sink is not a registered target" $ do
        let body = encodeControlPlaneRequest validPayload {prepareSinkIdentity = "unregistered"}
        result <- servePrepareTargetCommitRequest 4096 repository body
        result
          `shouldBe` TargetPrepareDecided
            (TargetCommitPrepareRefused (TargetCommitUnregisteredTarget "unregistered"))
        targetPrepareEndpointStatus result `shouldBe` 409
        targetPrepareEndpointSummary result `shouldBe` "target-prepare-refused:unregistered-target"
 where
  repository =
    TargetSecretPrepareRepository
      { readRegisteredTargets = pure registered
      , readTargetCoordinate = pure coordinate
      , readFencedCommitPermit = pure permit
      , readProjectionObservation = pure ModelBMissing
      , readAuthorityNow = pure (authorityTimeFromMicros 100)
      }
  validPayload =
    PrepareTargetCommitPayload
      { prepareSinkIdentity = "vscode"
      , prepareSinkGatewayEndpoint = "https://gateway.example"
      , prepareSinkVaultMount = "secret/target"
      , prepareSinkKvPath = "kv/target/vscode"
      , prepareGeneration = 1
      , prepareDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      , prepareDeadlineMicros = 100000
      }
  registered = expectRight (mkRegisteredTargetSet 4 [sampleSink "vscode"])
  coordinate = expectRight (mkTargetIntentCoordinate authority leaseKey)
  sampleSink identity =
    expectRight
      (mkTargetClusterSecretSink identity "https://gateway.example" "secret/target" "kv/target/vscode")

authority :: LongLivedCheckpointAuthority
authority =
  expectRight
    ( mkLongLivedCheckpointAuthority
        "prodbox-home"
        "http://127.0.0.1:30443"
        "prodbox-state"
        "lifecycle"
        "secret/lifecycle"
    )

leaseKey :: LeaseKey
leaseKey = expectRight (mkLeaseKey "123456789012" "ca-central-1" "target-secret")

-- | Mint a fenced commit permit exactly as the authority does — acquire a lease,
-- take its active grant, and fence a commit against the freshly initialized lease
-- projection. This mirrors the retained-authority flow; the permit is never
-- reconstructed from request bytes.
permit :: FencedCommitPermit
permit =
  case decideLeaseAcquire defaultSesLeasePolicy startedAt acquireRequest Nothing ModelBMissing of
    LeaseAcquireCompareAndSwap (ModelBInitialize _ projection) ->
      case leaseProjectionActiveGrant projection of
        Just grant ->
          case decideFencedCommit (authorityTimeFromMicros 2) grant (ModelBObserved leaseVersion projection) of
            LeaseCommitAuthorized authorized -> authorized
            other -> error ("expected a commit permit, got " ++ show other)
        Nothing -> error "expected an active lease grant"
    other -> error ("expected a lease initialization, got " ++ show other)
 where
  startedAt = authorityTimeFromMicros 1
  owner = expectRight (mkOwnerNonce "owner-1")
  acquireRequest = expectRight (beginLeaseAcquire defaultSesLeasePolicy authority leaseKey owner startedAt)
  leaseVersion = expectRight (mkModelBObjectVersion "lease-etag")

expectRight :: (Show err) => Either err value -> value
expectRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " ++ show err)
