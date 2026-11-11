{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTargetAuthorityEpoch
  ( controlPlaneTargetAuthorityEpochSuite
  , AuthenticatedEpochFixture (..)
  , EpochFixture (..)
  , newAuthenticatedEpochFixtureWithSignedResponses
  , newEpochFixture
  ) where

import Control.Concurrent.MVar (newEmptyMVar, readMVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Control.Monad (forM_, void, when)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter qualified as Role
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Transport
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyRefFor
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint (AuthorityAdmissionSnapshot (..))
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Codec qualified as Codec
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.RequestAuthentication qualified as Authentication
import Prodbox.ControlPlane.RequestReplay qualified as Replay
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleOperationSubmit, TargetMaterialObserve, TargetSecretTrustInstall)
  , routesForRole
  )
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.ControlPlane.TargetAuthenticatedResponse qualified as TargetResponse
import Prodbox.ControlPlane.TargetAuthorityEpoch
import Prodbox.ControlPlane.TargetAuthorityEpochBinding
  ( TargetEpochBindingEffect (..)
  , TargetEpochBindingFailure (..)
  , TargetEpochBindingInterpreter (..)
  )
import Prodbox.ControlPlane.TargetAuthorityEpochClient
import Prodbox.ControlPlane.TargetAuthorityEpochCodec
import Prodbox.ControlPlane.TargetAuthorityEpochEndpoint
import Prodbox.ControlPlane.TargetAuthorityEpochExecution
import Prodbox.ControlPlane.TargetAuthorityEpochProtocol
import Prodbox.ControlPlane.TargetAuthorityTrust
import Prodbox.ControlPlane.TargetAuthorityTrustClient
  ( TargetAuthorityTrustClientError (TargetAuthorityTrustClientReadBackInvalid)
  , decodeTargetAuthorityTrustClientResponse
  , installAcceptedTargetAuthority
  , targetAuthorityTrustClient
  )
import Prodbox.ControlPlane.TargetAuthorityTrustEndpoint
  ( TargetAuthorityTrustRequest (..)
  , TargetAuthorityTrustResponse (..)
  , targetAuthorityTrustAuthenticatedHandler
  , targetAuthorityTrustRepositoryWithEpochRows
  , targetAuthorityTrustResponseMaximumBytes
  )
import Prodbox.ControlPlane.TargetAuthorityTrustStore
import Prodbox.ControlPlane.TargetMaterialRegistry
import Prodbox.ControlPlane.TargetSecretAgentExecution
import Prodbox.ControlPlane.TargetSecretWorkerRuntime
  ( TargetSecretWorkerRuntimeError (TargetSecretWorkerTrustUnavailable)
  , decodeTargetWorkerAcceptedAuthority
  )
import Prodbox.ControlPlane.TargetSignedEpochBinding
import Prodbox.ControlPlane.TargetSnapshotObservation
import Prodbox.Http.Client
  ( HttpBoundedError (HttpBoundedTransport)
  , HttpError (HttpConnectionFailure)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (ReplyOk, ReplyServiceUnavailable), replyStatusCode)
import Prodbox.Lifecycle.Authority.Admission
  ( initialCleanInstallAuthorityWithRegisteredClients
  , retireAuthorityRpcKey
  , seedAuthorityRpcKeyRegistry
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( clientPrincipalForCaller
  , mkRegisteredClientGeneration
  , mkRegisteredClientSlot
  , mkRegisteredClientSpec
  , mkRegisteredClientTable
  )
import Prodbox.Lifecycle.Authority.EpochTopology
  ( CutoverSubstrate (CutoverAws, CutoverHome)
  , mkCutoverDigest
  )
import Prodbox.Lifecycle.Authority.Genesis qualified as Genesis
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime, TargetSecretAgentRuntime)
  )
import Prodbox.Vault.Client
  ( VaultAddress (VaultAddress)
  , VaultCasOutcome (VaultCasConflict, VaultCasUnobservable)
  )
import Prodbox.Vault.Session
  ( SessionClock (SessionClock)
  , VaultSessionError (VaultSessionUnavailable)
  , newVaultSession
  )
import TestSupport

controlPlaneTargetAuthorityEpochSuite :: SuiteBuilder ()
controlPlaneTargetAuthorityEpochSuite =
  describe "Sprint 6.5 staged Target authority trust" $ do
    it "binds a Target response to the authenticated request and pinned signer" $ do
      let generation = mustRight (Authentication.mkSigningKeyGeneration 1)
          authoritySigner =
            mustRight
              ( Authentication.mkRequestSigner
                  (Authentication.CallerService LifecycleAuthorityRuntime)
                  generation
                  (ByteString.pack [0 .. 31])
              )
          targetSigner =
            mustRight
              ( Authentication.mkRequestSigner
                  (Authentication.CallerService TargetSecretAgentRuntime)
                  generation
                  (ByteString.pack [32 .. 63])
              )
          otherSigner =
            mustRight
              ( Authentication.mkRequestSigner
                  (Authentication.CallerService TargetSecretAgentRuntime)
                  generation
                  (ByteString.pack [33 .. 64])
              )
          scope = mustRight (Coordinate.mkAuthorityScope "home")
          epoch = fromJust (Genesis.authorityEpochFromValue 1)
          requestEnd = authorityTimeFromMicros 2000
          nonce = mustRight (Authentication.mkRequestNonce (ByteString.replicate 16 1))
          otherNonce = mustRight (Authentication.mkRequestNonce (ByteString.replicate 16 2))
          requestFor value =
            mustRight
              ( Authentication.signControlPlaneRequest
                  authoritySigner
                  TargetSecretTrustInstall
                  TargetSecretAgentRuntime
                  scope
                  epoch
                  requestEnd
                  value
                  "staging-control"
              )
          verified = verifiedEpochRequest LifecycleAuthorityRuntime "home" TargetSecretTrustInstall 1 2000
          capability = Authentication.localRequestSigningCapability targetSigner
          trusted = Authentication.trustedRequestKeyFromSigner targetSigner
      signed <-
        TargetResponse.signTargetAuthenticatedResponse 128 localAgent capability verified 200 "prepared"
      let encoded = mustRight signed
          verify key request = TargetResponse.verifyTargetAuthenticatedResponse 128 localAgent key request encoded
      verify trusted (requestFor nonce) `shouldBe` Right (200, "prepared")
      let otherRollout = mustRight (mkTargetAgentRolloutIdentity "home" ("sha256:" <> Text.replicate 64 "b"))
          otherCluster = mustRight (mkTargetAgentRolloutIdentity "aws" ("sha256:" <> Text.replicate 64 "a"))
      TargetResponse.verifyTargetAuthenticatedResponse 128 otherRollout trusted (requestFor nonce) encoded
        `shouldBe` Left TargetResponse.TargetResponseClaimsMismatch
      TargetResponse.signTargetAuthenticatedResponse 128 otherCluster capability verified 200 "prepared"
        `shouldReturn` Left TargetResponse.TargetResponseRequestRefused
      verify trusted (requestFor otherNonce) `shouldSatisfy` isLeft
      verify (Authentication.trustedRequestKeyFromSigner otherSigner) (requestFor nonce)
        `shouldSatisfy` isLeft
      TargetResponse.verifyTargetAuthenticatedResponse
        128
        localAgent
        trusted
        (requestFor nonce)
        "prepared"
        `shouldSatisfy` isLeft
      let altered = ByteString.init encoded <> ByteString.singleton (ByteString.last encoded + 1)
      TargetResponse.verifyTargetAuthenticatedResponse 128 localAgent trusted (requestFor nonce) altered
        `shouldSatisfy` isLeft
      TargetResponse.signTargetAuthenticatedResponse
        128
        localAgent
        (Authentication.localRequestSigningCapability authoritySigner)
        verified
        200
        "prepared"
        `shouldReturn` Left TargetResponse.TargetResponseSignerRefused
      TargetResponse.verifyTargetAuthenticatedResponse
        maxBound
        localAgent
        trusted
        (requestFor nonce)
        encoded
        `shouldBe` Left TargetResponse.TargetResponseInvalidLimit
      TargetResponse.signTargetAuthenticatedResponse 128 localAgent capability verified 600 "prepared"
        `shouldReturn` Left TargetResponse.TargetResponseStatusInvalid
      TargetResponse.signTargetAuthenticatedResponse 2 localAgent capability verified 200 "prepared"
        `shouldReturn` Left TargetResponse.TargetResponseBodyTooLarge

    it "signs an actual Target observation only for the verified request" $ do
      fixture <- newEpochFixture prepared
      let generation = mustRight (Authentication.mkSigningKeyGeneration 1)
          authoritySigner =
            mustRight
              ( Authentication.mkRequestSigner
                  (Authentication.CallerService LifecycleAuthorityRuntime)
                  generation
                  (ByteString.pack [0 .. 31])
              )
          targetSigner =
            mustRight
              ( Authentication.mkRequestSigner
                  (Authentication.CallerService TargetSecretAgentRuntime)
                  generation
                  (ByteString.pack [32 .. 63])
              )
          scope = mustRight (Coordinate.mkAuthorityScope "home")
          epoch = fromJust (Genesis.authorityEpochFromValue 1)
          requestEnd = authorityTimeFromMicros 2000
          nonce = mustRight (Authentication.mkRequestNonce (ByteString.replicate 16 1))
          otherNonce = mustRight (Authentication.mkRequestNonce (ByteString.replicate 16 2))
          inner = mustRight (encodeTargetEpochRequest (TargetEpochObserve TargetAcmeEab))
          body = LazyByteString.toStrict (Codec.encodeControlPlaneRequest (TargetAuthorityTrustRequest inner))
          signedFor value =
            mustRight
              ( Authentication.signControlPlaneRequest
                  authoritySigner
                  TargetSecretTrustInstall
                  TargetSecretAgentRuntime
                  scope
                  epoch
                  requestEnd
                  value
                  body
              )
          verification =
            mustRight
              ( Authentication.mkRequestVerificationContext
                  (Authentication.trustedRequestKeyFromSigner authoritySigner)
                  TargetSecretTrustInstall
                  TargetSecretAgentRuntime
                  scope
                  epoch
                  requestEnd
                  nonce
                  now
                  (mustRight (authorityDurationFromMicros 3000))
              )
          verified =
            mustRight
              ( Authentication.decodeAndVerifyControlPlaneRequest
                  65536
                  verification
                  (Authentication.encodeSignedControlPlaneRequest (signedFor nonce))
              )
          capability = Authentication.localRequestSigningCapability targetSigner
          trusted = Authentication.trustedRequestKeyFromSigner targetSigner
      handled <-
        targetEpochSignedObservationHandler
          65536
          65536
          localAgent
          (epochInterpreter fixture)
          capability
          verified
      let envelope = mustRight (fromJust handled)
          (status, response) =
            mustRight
              (TargetResponse.verifyTargetAuthenticatedResponse 65536 localAgent trusted (signedFor nonce) envelope)
      decodeTargetEpochClientResponse
        (TargetEpochObserve TargetAcmeEab)
        (Client.ControlPlaneResponse (fromIntegral status) response)
        `shouldBe` Right (TargetEpochObserved TargetAcmeEab (Just (1, prepared)))
      TargetResponse.verifyTargetAuthenticatedResponse
        65536
        localAgent
        trusted
        (signedFor otherNonce)
        envelope
        `shouldSatisfy` isLeft
      rejected <-
        targetEpochSignedObservationHandler
          65536
          65536
          localAgent
          (epochInterpreter fixture)
          (Authentication.localRequestSigningCapability authoritySigner)
          verified
      rejected `shouldBe` Just (Left TargetResponse.TargetResponseSignerRefused)
      fixtureRecord (epochRows fixture) `shouldReturn` prepared
      readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

    it "retains the predecessor without admitting old or pending workers during preparation" $ do
      targetEpochRecordActive prepared `shouldBe` Just (authorityAt 1 1)
      targetEpochRecordTransition prepared `shouldBe` TargetEpochPrepared preparation
      let fields = mustRight (encodeTargetAuthorityEpochFields prepared)
      Map.lookup "accepted_authority" fields `shouldBe` Nothing
      decodeTargetAuthorityEpochFields TargetAcmeEab fields `shouldBe` Right prepared
      decodeTargetWorkerAcceptedAuthority TargetAcmeEab fields
        `shouldBe` Left TargetSecretWorkerTrustUnavailable

    it "does not promote before the independently published epoch commits" $ do
      stepTargetAuthorityEpoch (AuthorityEpoch 1) now (PromoteTargetAuthorityEpoch preparation) prepared
        `shouldBe` Left TargetEpochPublishedEpochMismatch
      targetEpochRecordActive promoted `shouldBe` Just (authorityAt 2 1)
      decodeTargetWorkerAcceptedAuthority
        TargetAcmeEab
        (mustRight (encodeTargetAuthorityEpochFields promoted))
        `shouldBe` Right (authorityAt 2 1)

    it "retains an epoch tombstone after pre-commit retirement" $ do
      targetEpochRecordActive retired `shouldBe` Just (authorityAt 1 1)
      decodeTargetWorkerAcceptedAuthority
        TargetAcmeEab
        (mustRight (encodeTargetAuthorityEpochFields retired))
        `shouldBe` Left TargetSecretWorkerTrustUnavailable
      targetEpochRecordRetiredThrough retired `shouldBe` 2
      stepTargetAuthorityEpoch (AuthorityEpoch 1) now (PrepareTargetAuthorityEpoch preparation) retired
        `shouldBe` Left TargetEpochAlreadyRetired
      stepTargetAuthorityEpoch (AuthorityEpoch 1) now (RetireTargetAuthorityEpoch preparation) retired
        `shouldBe` Right retired

    it "retires an uncreated binding without publishing active authority" $ do
      let missing = mustRight (initialTargetAuthorityEpochRecord TargetAcmeEab Nothing)
          result =
            mustRight
              (stepTargetAuthorityEpoch (AuthorityEpoch 1) now (RetireTargetAuthorityEpoch preparation) missing)
      targetEpochRecordActive result `shouldBe` Nothing
      targetEpochRecordRetiredThrough result `shouldBe` 2
      Map.lookup "accepted_authority" (mustRight (encodeTargetAuthorityEpochFields result))
        `shouldBe` Nothing

    it "requires greater-epoch recovery after commitment" $ do
      stepTargetAuthorityEpoch (AuthorityEpoch 2) now (RetireTargetAuthorityEpoch preparation) promoted
        `shouldBe` Left TargetEpochPublishedEpochMismatch
      stepTargetAuthorityEpoch (AuthorityEpoch 2) now (RetireTargetAuthorityEpoch preparation) prepared
        `shouldBe` Left TargetEpochPublishedEpochMismatch

    it "recovers an unpromoted committed predecessor through a greater epoch" $ do
      let next = preparationAt 2 3 1000 'b'
          nextPrepared =
            mustRight
              (stepTargetAuthorityEpoch (AuthorityEpoch 2) now (PrepareTargetAuthorityEpoch next) prepared)
          nextPromoted =
            mustRight
              (stepTargetAuthorityEpoch (AuthorityEpoch 3) now (PromoteTargetAuthorityEpoch next) nextPrepared)
      targetEpochRecordActive nextPrepared `shouldBe` Just (authorityAt 1 1)
      targetEpochRecordRetiredThrough nextPrepared `shouldBe` 2
      targetEpochRecordActive nextPromoted `shouldBe` Just (authorityAt 3 1)
      stepTargetAuthorityEpoch
        (AuthorityEpoch 3)
        now
        (PromoteTargetAuthorityEpoch preparation)
        nextPromoted
        `shouldSatisfy` isLeft

    it "starts a fresh greater target after rollback while retaining the old active epoch" $ do
      let next = preparationAt 1 3 1000 'b'
          record =
            mustRight
              (stepTargetAuthorityEpoch (AuthorityEpoch 1) now (PrepareTargetAuthorityEpoch next) retired)
      targetEpochRecordActive record `shouldBe` Just (authorityAt 1 1)
      targetEpochRecordRetiredThrough record `shouldBe` 2

    forM_ [("preparation", prepared), ("retirement", retired)] $ \(label, record) ->
      it ("refuses ordinary installation across " ++ label) $
        advanceOrdinaryTargetAuthority (authorityAt 2 9) record
          `shouldBe` Left TargetEpochOrdinaryInstallFrozen

    it "preserves promotion metadata when the normal same-epoch fence advances" $ do
      let advanced = mustRight (advanceOrdinaryTargetAuthority (authorityAt 2 9) promoted)
      targetEpochRecordTransition advanced `shouldBe` TargetEpochPromoted preparation
      targetEpochRecordActive advanced `shouldBe` Just (authorityAt 2 9)
      advanceOrdinaryTargetAuthority (authorityAt 3 9) advanced
        `shouldBe` Left TargetEpochAuthorityEpochMismatch
      decodeTargetAuthorityEpochFields
        TargetAcmeEab
        (mustRight (encodeTargetAuthorityEpochFields advanced))
        `shouldBe` Right advanced

    forM_
      [ ("prepare", PrepareTargetAuthorityEpoch, initial, AuthorityEpoch 1)
      , ("promote", PromoteTargetAuthorityEpoch, prepared, AuthorityEpoch 2)
      ]
      $ \(label, action, record, published) ->
        it ("does not extend an expired " ++ label ++ " deadline") $ do
          stepTargetAuthorityEpoch published deadline (action preparation) record
            `shouldBe` Left TargetEpochDeadlineReached

    it "allows cleanup after expiry without granting the expired authority" $ do
      stepTargetAuthorityEpoch
        (AuthorityEpoch 1)
        deadline
        (RetireTargetAuthorityEpoch preparation)
        prepared
        `shouldBe` Right retired
      targetEpochRecordActive retired `shouldBe` Just (authorityAt 1 1)

    forM_ [("deadline", preparationAt 1 2 2000 'a'), ("topology", preparationAt 1 2 1000 'b')] $ \(label, changed) ->
      it ("rejects a changed " ++ label ++ " within one pending epoch") $
        stepTargetAuthorityEpoch (AuthorityEpoch 1) now (PrepareTargetAuthorityEpoch changed) prepared
          `shouldBe` Left TargetEpochPreparationConflict

    forM_ [("initial", initial), ("prepared", prepared), ("promoted", promoted), ("retired", retired)] $ \(label, record) ->
      it ("round-trips bounded " ++ label ++ " state") $ do
        let bytes = mustRight (encodeTargetAuthorityEpochRecord record)
            fields = mustRight (encodeTargetAuthorityEpochFields record)
        ByteString.length bytes `shouldSatisfy` (<= targetAuthorityEpochStateMaximumBytes)
        decodeTargetAuthorityEpochRecord bytes `shouldBe` Right record
        decodeTargetAuthorityEpochFields TargetAcmeEab fields `shouldBe` Right record

    forM_ [("prepared", prepared), ("promoted", promoted), ("retired", retired)] $ \(label, record) ->
      it ("refuses a different active projection beside " ++ label ++ " state") $ do
        let fields = mustRight (encodeTargetAuthorityEpochFields record)
            forged = Map.insert "accepted_authority" (publicField (authorityAt 9 9)) fields
        decodeTargetAuthorityEpochFields TargetAcmeEab forged
          `shouldBe` Left TargetEpochCodecProjectionMismatch
        decodeTargetWorkerAcceptedAuthority TargetAcmeEab forged
          `shouldBe` Left TargetSecretWorkerTrustUnavailable

    it "never falls back to a valid legacy field when epoch state is corrupt" $ do
      let fields =
            Map.fromList
              [("accepted_authority", publicField (authorityAt 1 1)), (targetAuthorityEpochStateField, "!")]
      decodeTargetAuthorityEpochFields TargetAcmeEab fields `shouldBe` Left TargetEpochCodecInvalid
      decodeTargetWorkerAcceptedAuthority TargetAcmeEab fields
        `shouldBe` Left TargetSecretWorkerTrustUnavailable

    it "adopts the existing active-only schema without inventing preparation" $ do
      decodeTargetAuthorityEpochFields
        TargetAcmeEab
        (Map.singleton "accepted_authority" (publicField (authorityAt 1 1)))
        `shouldBe` Right initial

    it "rejects a row at a different exact Target coordinate" $ do
      decodeTargetAuthorityEpochFields
        TargetSesSmtp
        (mustRight (encodeTargetAuthorityEpochFields prepared))
        `shouldBe` Left (TargetEpochCodecStateInvalid TargetEpochTargetMismatch)

    it "bounds state and the complete field map before decoding" $ do
      decodeTargetAuthorityEpochRecord
        (ByteString.replicate (targetAuthorityEpochStateMaximumBytes + 1) 0)
        `shouldBe` Left TargetEpochCodecTooLarge
      decodeTargetAuthorityEpochFields
        TargetAcmeEab
        (Map.singleton "padding" (Text.replicate (targetAuthorityEpochFieldsMaximumBytes + 1) "a"))
        `shouldBe` Left TargetEpochCodecTooLarge

    it "rejects appended noncanonical bytes" $
      decodeTargetAuthorityEpochRecord
        (mustRight (encodeTargetAuthorityEpochRecord prepared) <> ByteString.singleton 0)
        `shouldSatisfy` isLeft

    forM_ [("prepared", prepared), ("retired", retired)] $ \(label, record) ->
      it ("the production row program refuses an ordinary writer while " ++ label) $ do
        fixture <- newRowFixture record
        result <- installTargetAuthorityTrust (rowRepository fixture) (authorityAt 2 9)
        result
          `shouldBe` Left
            (TargetAuthorityTrustObservationUnavailable TargetAuthorityTrustObservationEpochTransitionFrozen)
        readIORef (rowWrites fixture) `shouldReturn` 0

    it "the production row program retains metadata across an active fence advance" $ do
      fixture <- newRowFixture promoted
      installTargetAuthorityTrust (rowRepository fixture) (authorityAt 2 9)
        `shouldReturn` Right (TargetAuthorityTrustInstalled (authorityAt 2 9))
      record <- fixtureRecord fixture
      targetEpochRecordTransition record `shouldBe` TargetEpochPromoted preparation
      targetEpochRecordActive record `shouldBe` Just (authorityAt 2 9)

    it "creates the first canonical active row from positive absence" $ do
      fixture <- newRowFixture initial
      writeIORef (rowState fixture) Nothing
      installTargetAuthorityTrust (rowRepository fixture) (authorityAt 1 1)
        `shouldReturn` Right (TargetAuthorityTrustInstalled (authorityAt 1 1))
      fixtureRecord fixture `shouldReturn` initial

    it "preserves preparation that wins the CAS after the writer's final read" $ do
      fixture <- newRowFixture initial
      writeIORef (rowWriteMode fixture) RowPreparationWins
      result <- installTargetAuthorityTrust (rowRepository fixture) (authorityAt 1 9)
      result `shouldSatisfy` isLeft
      fixtureRecord fixture `shouldReturn` prepared

    it "does not erase preparation published after the initial active observation" $ do
      fixture <- newRowFixture initial
      writeIORef (rowReadHook fixture) (publishPreparation fixture)
      result <- installTargetAuthorityTrust (rowRepository fixture) (authorityAt 1 9)
      result `shouldSatisfy` isLeft
      readIORef (rowWrites fixture) `shouldReturn` 0
      fixtureRecord fixture `shouldReturn` prepared

    it "recovers a lost CAS reply only from the actual canonical row" $ do
      fixture <- newRowFixture initial
      writeIORef (rowWriteMode fixture) RowReplyLost
      installTargetAuthorityTrust (rowRepository fixture) (authorityAt 2 1)
        `shouldReturn` Right (TargetAuthorityTrustRecovered (authorityAt 2 1))
      record <- fixtureRecord fixture
      targetEpochRecordActive record `shouldBe` Just (authorityAt 2 1)

    it "refuses an unobservable closing read after an accepted CAS" $ do
      fixture <- newRowFixture initial
      writeIORef (rowReadHook fixture) (loseClosingRead fixture)
      result <- installTargetAuthorityTrust (rowRepository fixture) (authorityAt 2 1)
      result
        `shouldBe` Left
          (TargetAuthorityTrustObservationUnavailable TargetAuthorityTrustObservationRequestConnectionFailure)
      readIORef (rowWrites fixture) `shouldReturn` 1

    it "does not turn a failed row observation into missing trust" $ do
      fixture <- newRowFixture initial
      writeIORef (rowReadFailure fixture) (Just TargetAuthorityTrustObservationRequestTimeout)
      observeTargetAuthorityTrust (rowRepository fixture) TargetAcmeEab
        `shouldReturn` TargetAuthorityTrustUnobservable TargetAuthorityTrustObservationRequestTimeout
      readIORef (rowWrites fixture) `shouldReturn` 0

    forM_
      [ (Just (authorityAt 2 1), 0, TargetEpochPrepared preparation)
      , (Just (authorityAt 1 1), 2, TargetEpochPrepared preparation)
      , (Just (authorityAt 1 1), 0, TargetEpochPromoted preparation)
      , (Just (authorityAt 1 1), 1, TargetEpochRetired preparation)
      , (Just (authorityAt 1 1), 2, TargetEpochNoTransition)
      ]
      $ \(active, floorEpoch, transition) ->
        it "rejects inconsistent retained phase/epoch combinations" $
          restoreTargetAuthorityEpochRecord TargetAcmeEab active floorEpoch transition `shouldSatisfy` isLeft

    describe "verified request bounded execution" epochExecutionSuite
    describe "bounded staging protocol and clients" epochProtocolSuite
    describe "authenticated Agent staging composition" epochAuthenticatedSuite
    describe "production epoch effect deadline boundary" epochEffectDeadlineSuite

epochExecutionSuite :: SuiteBuilder ()
epochExecutionSuite = do
  it "prepares through one CAS and exact closing observation without admitting workers" $ do
    fixture <- newEpochFixture initial
    result <- execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
    let applied = mustRight result
    targetEpochMutationDisposition applied `shouldBe` TargetEpochMutationApplied
    targetEpochMutationVersion applied `shouldBe` 2
    targetEpochMutationRecord applied `shouldBe` prepared
    targetEpochWorkerAuthority (targetEpochMutationRecord applied) `shouldBe` Nothing
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 1
    readIORef (epochEffectDeadlines fixture)
      `shouldReturn` map authorityTimeFromMicros [1000, 1000, 1000, 1000, 1000, 1000, 2000, 2000, 2000]

  it "does not renew the deadline on an already prepared row" $ do
    fixture <- newEpochFixture prepared
    result <- execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
    targetEpochMutationDisposition (mustRight result) `shouldBe` TargetEpochMutationAlreadyObserved
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "creates pending trust only after positive exact-row absence" $ do
    fixture <- newEpochFixture initial
    writeIORef (rowState (epochRows fixture)) Nothing
    result <- execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
    targetEpochMutationVersion (mustRight result) `shouldBe` 1
    targetEpochRecordActive (targetEpochMutationRecord (mustRight result)) `shouldBe` Nothing
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 1

  forM_ [("lost reply", RowReplyLost), ("concurrent identical preparation", RowPreparationWins)] $ \(label, mode) ->
    it ("recovers " ++ label ++ " only through exact closing readback") $ do
      fixture <- newEpochFixture initial
      writeIORef (rowWriteMode (epochRows fixture)) mode
      result <- execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      targetEpochMutationDisposition (mustRight result) `shouldBe` TargetEpochMutationRecovered
      targetEpochMutationRecord (mustRight result) `shouldBe` prepared
      readIORef (rowWrites (epochRows fixture)) `shouldReturn` 1

  it "reports a lost closing observation as unresolved even after the write" $ do
    fixture <- newEpochFixture initial
    writeIORef (rowReadHook (epochRows fixture)) $ \count ->
      when (count == 2) $
        writeIORef (rowReadFailure (epochRows fixture)) (Just TargetAuthorityTrustObservationRequestTimeout)
    execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left
        ( TargetEpochStoreFailed
            (TargetTrustRowObservationFailed TargetAuthorityTrustObservationRequestTimeout)
        )
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 1

  it "refuses an epoch change during closing observation" $ do
    fixture <- newEpochFixture initial
    writeIORef (rowReadHook (epochRows fixture)) $ \count ->
      when (count == 2) (writeIORef (epochPublished fixture) (Right (AuthorityEpoch 2)))
    execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left TargetEpochRequestEpochChanged
    fixtureRecord (epochRows fixture) `shouldReturn` prepared

  it "does not grant a preparation that expired after its CAS" $ do
    fixture <- newEpochFixture initial
    writeIORef (rowReadHook (epochRows fixture)) $ \count ->
      when (count == 2) (writeIORef (epochClock fixture) (Right deadline))
    execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left (TargetEpochTransitionRefused TargetEpochDeadlineReached)
    fixtureRecord (epochRows fixture) `shouldReturn` prepared

  it "does not grant a request that expired after its CAS" $ do
    fixture <- newEpochFixture initial
    writeIORef (rowReadHook (epochRows fixture)) $ \count ->
      when (count == 2) (writeIORef (epochClock fixture) (Right (authorityTimeFromMicros 2000)))
    execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left TargetEpochExecutionDeadlineReached

  it "charges every effect to the earlier verified request deadline" $ do
    fixture <- newEpochFixture initial
    let verified = verifiedEpochRequest LifecycleAuthorityRuntime "home" TargetSecretTrustInstall 1 500
    result <-
      executeTargetAuthorityEpoch
        localAgent
        (epochInterpreter fixture)
        verified
        (PrepareTargetAuthorityEpoch preparation)
    targetEpochMutationDisposition (mustRight result) `shouldBe` TargetEpochMutationApplied
    deadlines <- readIORef (epochEffectDeadlines fixture)
    deadlines `shouldSatisfy` all (== authorityTimeFromMicros 500)

  it "refuses expired preparation before attempting a CAS" $ do
    fixture <- newEpochFixture initial
    writeIORef (epochClock fixture) (Right deadline)
    execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left TargetEpochExecutionDeadlineReached
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "promotes only after the published epoch and verified request both advance" $ do
    fixture <- newEpochFixture prepared
    execute fixture 1 (PromoteTargetAuthorityEpoch preparation)
      `shouldReturn` Left (TargetEpochTransitionRefused TargetEpochPublishedEpochMismatch)
    writeIORef (epochPublished fixture) (Right (AuthorityEpoch 2))
    execute fixture 1 (PromoteTargetAuthorityEpoch preparation)
      `shouldReturn` Left TargetEpochRequestEpochChanged
    result <- execute fixture 2 (PromoteTargetAuthorityEpoch preparation)
    targetEpochMutationRecord (mustRight result) `shouldBe` promoted
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 1

  it "retires an expired preparation under a fresh authenticated cleanup deadline" $ do
    fixture <- newEpochFixture prepared
    writeIORef (epochClock fixture) (Right (authorityTimeFromMicros 1200))
    result <- execute fixture 1 (RetireTargetAuthorityEpoch preparation)
    targetEpochMutationRecord (mustRight result) `shouldBe` retired
    deadlines <- readIORef (epochEffectDeadlines fixture)
    deadlines `shouldSatisfy` all (== authorityTimeFromMicros 2000)

  it "refuses retirement once the target epoch is publicly committed" $ do
    fixture <- newEpochFixture promoted
    writeIORef (epochPublished fixture) (Right (AuthorityEpoch 2))
    execute fixture 2 (RetireTargetAuthorityEpoch preparation)
      `shouldReturn` Left (TargetEpochTransitionRefused TargetEpochPublishedEpochMismatch)
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  forM_
    [ ("caller", ProviderWorkerRuntime, "home", TargetSecretTrustInstall)
    , ("scope", LifecycleAuthorityRuntime, "foreign", TargetSecretTrustInstall)
    , ("route", LifecycleAuthorityRuntime, "home", TargetMaterialObserve)
    ]
    $ \(label, caller, scope, route) ->
      it ("rejects an authenticated but wrong " ++ label ++ " before any effect") $ do
        fixture <- newEpochFixture initial
        let verified = verifiedEpochRequest caller scope route 1 2000
        executeTargetAuthorityEpoch
          localAgent
          (epochInterpreter fixture)
          verified
          (PrepareTargetAuthorityEpoch preparation)
          `shouldReturn` Left TargetEpochRequestBindingInvalid
        readIORef (epochEffectDeadlines fixture) `shouldReturn` []

  it "binds the pending authority to the exact local Agent rollout" $ do
    fixture <- newEpochFixture initial
    let foreignAgent = mustRight (mkTargetAgentRolloutIdentity "home" ("sha256:" <> Text.replicate 64 "b"))
        verified = verifiedEpochRequest LifecycleAuthorityRuntime "home" TargetSecretTrustInstall 1 2000
    executeTargetAuthorityEpoch
      foreignAgent
      (epochInterpreter fixture)
      verified
      (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left TargetEpochLocalAgentMismatch
    readIORef (epochEffectDeadlines fixture) `shouldReturn` []

  forM_
    [("clock", TargetEpochClockUnavailable), ("published epoch", TargetEpochPublishedEpochUnavailable)]
    $ \(label, failure) ->
      it ("refuses an unobservable " ++ label ++ " without writing") $ do
        fixture <- newEpochFixture initial
        case failure of
          TargetEpochClockUnavailable -> writeIORef (epochClock fixture) (Left failure)
          _ -> writeIORef (epochPublished fixture) (Left failure)
        execute fixture 1 (PrepareTargetAuthorityEpoch preparation) `shouldReturn` Left failure
        readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "rejects corrupt canonical state without falling back to active-only trust" $ do
    fixture <- newEpochFixture initial
    writeIORef (rowState (epochRows fixture)) $
      Just
        ( 1
        , Map.fromList
            [("accepted_authority", publicField (authorityAt 1 1)), (targetAuthorityEpochStateField, "!")]
        )
    execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left (TargetEpochRecordCodecFailed TargetEpochCodecInvalid)
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "observes exact phase metadata without changing the trust row" $ do
    fixture <- newEpochFixture prepared
    let verified = verifiedEpochRequest LifecycleAuthorityRuntime "home" TargetSecretTrustInstall 1 2000
    observeTargetAuthorityEpoch localAgent (epochInterpreter fixture) verified TargetAcmeEab
      `shouldReturn` Right (Just (1, prepared))
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "does not swallow asynchronous cancellation" $ do
    fixture <- newEpochFixture initial
    writeIORef (rowReadHook (epochRows fixture)) (const (throwIO ThreadKilled))
    result <- try (execute fixture 1 (PrepareTargetAuthorityEpoch preparation))
    (result :: Either AsyncException (Either TargetEpochExecutionError TargetEpochMutationResult))
      `shouldBe` Left ThreadKilled
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  forM_
    [
      ( "generation"
      , mustRight (mkTargetIssuerKeyGeneration 2)
      , acceptedTargetIssuerPublicKey (authorityAt 2 1)
      )
    ,
      ( "public key"
      , mustRight (mkTargetIssuerKeyGeneration 1)
      , targetIntentSigningPublicKey (mustRight (mkTargetIntentSigningKey (ByteString.pack [1 .. 32])))
      )
    ]
    $ \(label, generation, key) ->
      it ("refuses a proposed issuer that differs from independent " ++ label ++ " observation") $ do
        fixture <- newEpochFixture initial
        writeIORef (epochIssuer fixture) (Right (generation, key))
        execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
          `shouldReturn` Left TargetEpochIssuerMismatch
        readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "reports an unavailable independent issuer without writing" $ do
    fixture <- newEpochFixture initial
    writeIORef (epochIssuer fixture) (Left TargetEpochIssuerUnavailable)
    execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left TargetEpochIssuerUnavailable
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "refuses issuer rotation discovered after the CAS" $ do
    fixture <- newEpochFixture initial
    writeIORef (rowReadHook (epochRows fixture)) $ \count ->
      when (count == 2) $
        writeIORef
          (epochIssuer fixture)
          (Right (mustRight (mkTargetIssuerKeyGeneration 2), acceptedTargetIssuerPublicKey (authorityAt 2 1)))
    execute fixture 1 (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left TargetEpochIssuerMismatch
    fixtureRecord (epochRows fixture) `shouldReturn` prepared

  it "can retire an expired exact preparation after issuer rotation or loss" $ do
    fixture <- newEpochFixture prepared
    writeIORef (epochClock fixture) (Right (authorityTimeFromMicros 1200))
    writeIORef (epochIssuer fixture) (Left TargetEpochIssuerUnavailable)
    result <- execute fixture 1 (RetireTargetAuthorityEpoch preparation)
    targetEpochMutationRecord (mustRight result) `shouldBe` retired

epochProtocolSuite :: SuiteBuilder ()
epochProtocolSuite = do
  it "preserves the banked legacy trust request encoding" $
    Base64.encode
      (LazyByteString.toStrict (Codec.encodeControlPlaneRequest (TargetAuthorityTrustRequest "accepted")))
      `shouldBe` "gwABggBIYWNjZXB0ZWQ="

  forM_
    [ (TargetAuthorityTrustInstalledResponse "accepted", "gwABggBIYWNjZXB0ZWQ=")
    , (TargetAuthorityTrustAlreadyInstalledResponse "accepted", "gwABggFIYWNjZXB0ZWQ=")
    , (TargetAuthorityTrustRecoveredResponse "accepted", "gwABggJIYWNjZXB0ZWQ=")
    , (TargetAuthorityTrustRefusedResponse "refused", "gwABggNncmVmdXNlZA==")
    , (TargetAuthorityTrustUnavailableResponse "unavailable", "gwABggRrdW5hdmFpbGFibGU=")
    ]
    $ \(response, encoded) ->
      it "preserves a banked legacy trust response encoding" $
        Base64.encode (LazyByteString.toStrict (Codec.encodeControlPlaneResponse response))
          `shouldBe` encoded

  forM_
    [ TargetEpochMutate (PrepareTargetAuthorityEpoch preparation)
    , TargetEpochMutate (PromoteTargetAuthorityEpoch preparation)
    , TargetEpochMutate (RetireTargetAuthorityEpoch preparation)
    , TargetEpochObserve TargetAcmeEab
    ]
    $ \request ->
      it "round-trips a bounded canonical staging request" $ do
        let encoded = mustRight (encodeTargetEpochRequest request)
        ByteString.length encoded `shouldSatisfy` (<= targetEpochRequestMaximumBytes)
        decodeTargetEpochRequest encoded `shouldBe` Right request
        decodeTargetEpochRequest (encoded <> ByteString.singleton 0) `shouldSatisfy` isLeft

  it "keeps staging and legacy accepted-authority messages distinct" $ do
    let legacy = encodeAcceptedTargetAuthority (authorityAt 1 1)
    isTargetEpochRequest legacy `shouldBe` False
    decodeTargetEpochRequest legacy `shouldBe` Left TargetEpochProtocolPrefixMissing
    let encoded = mustRight (encodeTargetEpochRequest (TargetEpochObserve TargetAcmeEab))
    isTargetEpochRequest encoded `shouldBe` True
    decodeTargetEpochRequest (ByteString.take 21 encoded <> "!") `shouldSatisfy` isLeft

  it "bounds a staging request before attempting to decode it" $
    decodeTargetEpochRequest (ByteString.replicate (targetEpochRequestMaximumBytes + 1) 0)
      `shouldBe` Left TargetEpochProtocolTooLarge

  it "round-trips preparation with its immutable topology and deadline" $ do
    let encoded = mustRight (encodeTargetAuthorityEpochPreparation preparation)
    decodeTargetAuthorityEpochPreparation encoded `shouldBe` Right preparation
    decodeTargetAuthorityEpochPreparation (encoded <> ByteString.singleton 0) `shouldSatisfy` isLeft

  forM_
    [ TargetEpochObserved TargetAcmeEab Nothing
    , TargetEpochObserved TargetAcmeEab (Just (1, prepared))
    , TargetEpochMutated (TargetEpochMutationResult TargetEpochMutationAlreadyObserved 1 prepared)
    , TargetEpochMutated (TargetEpochMutationResult TargetEpochMutationApplied 2 promoted)
    , TargetEpochMutated (TargetEpochMutationResult TargetEpochMutationRecovered 2 retired)
    ]
    $ \response ->
      it "round-trips a canonical metadata-only staging response within the old outer bound" $ do
        let encoded = mustRight (encodeTargetEpochResponse response)
            outer = LazyByteString.toStrict (Codec.encodeControlPlaneResponse (TargetAuthorityEpochResponse encoded))
        ByteString.length outer `shouldSatisfy` (<= targetAuthorityTrustResponseMaximumBytes)
        decodeTargetEpochResponse encoded `shouldBe` Right response
        decodeTargetEpochResponse (encoded <> ByteString.singleton 0) `shouldSatisfy` isLeft

  it "refuses zero row versions and a foreign Target in observations" $ do
    encodeTargetEpochResponse (TargetEpochObserved TargetAcmeEab (Just (0, prepared)))
      `shouldBe` Left TargetEpochProtocolReadBackInvalid
    encodeTargetEpochResponse (TargetEpochObserved TargetSesSmtp (Just (1, prepared)))
      `shouldBe` Left TargetEpochProtocolReadBackInvalid

  it "makes an ordinary trust client explicitly refuse the appended response arm" $ do
    let response = TargetEpochObserved TargetAcmeEab (Just (1, prepared))
    decodeTargetAuthorityTrustClientResponse (epochResponse 200 response)
      `shouldBe` Left TargetAuthorityTrustClientReadBackInvalid

  it "binds a successful client readback to the exact phase and immutable context" $ do
    let request = TargetEpochMutate (PrepareTargetAuthorityEpoch preparation)
        response = TargetEpochMutated (TargetEpochMutationResult TargetEpochMutationApplied 2 prepared)
        different =
          mustRight
            ( stepTargetAuthorityEpoch
                (AuthorityEpoch 1)
                now
                (PrepareTargetAuthorityEpoch (preparationAt 1 2 1000 'b'))
                initial
            )
    decodeTargetEpochClientResponse request (epochResponse 200 response) `shouldBe` Right response
    decodeTargetEpochClientResponse request (epochResponse 503 response)
      `shouldBe` Left (TargetEpochClientHttpStatus 503)
    forM_ [promoted, retired, different] $ \record ->
      decodeTargetEpochClientResponse
        request
        ( epochResponse
            200
            (TargetEpochMutated (TargetEpochMutationResult TargetEpochMutationApplied 2 record))
        )
        `shouldBe` Left TargetEpochClientReadBackMismatch

  it "rejects a foreign observation, operation and old active-only success" $ do
    let request = TargetEpochObserve TargetAcmeEab
    decodeTargetEpochClientResponse
      request
      (epochResponse 200 (TargetEpochObserved TargetSesSmtp Nothing))
      `shouldBe` Left TargetEpochClientReadBackMismatch
    decodeTargetEpochClientResponse
      request
      ( epochResponse
          200
          (TargetEpochMutated (TargetEpochMutationResult TargetEpochMutationApplied 2 prepared))
      )
      `shouldBe` Left TargetEpochClientReadBackMismatch
    decodeTargetEpochClientResponse
      request
      ( Client.ControlPlaneResponse
          200
          ( LazyByteString.toStrict
              ( Codec.encodeControlPlaneResponse
                  (TargetAuthorityTrustInstalledResponse (encodeAcceptedTargetAuthority (authorityAt 1 1)))
              )
          )
      )
      `shouldBe` Left TargetEpochClientReadBackMismatch

epochResponse :: Int -> TargetEpochResponse -> Client.ControlPlaneResponse
epochResponse status response =
  Client.ControlPlaneResponse
    status
    ( LazyByteString.toStrict
        ( Codec.encodeControlPlaneResponse
            (TargetAuthorityEpochResponse (mustRight (encodeTargetEpochResponse response)))
        )
    )

epochAuthenticatedSuite :: SuiteBuilder ()
epochAuthenticatedSuite = do
  it
    "binds a verified Target observation to the Authority snapshot that selected its key"
    snapshotSignedControl

  it
    "authenticates Target observations and refuses substitution and fresh-nonce replay"
    supportedSignedControl

  it "prepares and promotes through the authenticated client and actual staging handler" $ do
    fixture <- newEpochFixture initial
    boundary <- newAuthenticatedEpochFixture fixture
    result <-
      mutateTargetAuthorityEpoch
        (authenticatedEpochClient boundary)
        (PrepareTargetAuthorityEpoch preparation)
    targetEpochMutationRecord (mustRight result) `shouldBe` prepared
    fixtureRecord (epochRows fixture)
      >>= (\record -> targetEpochWorkerAuthority record `shouldBe` Nothing)
    observeTargetAuthorityEpochWithClient (authenticatedEpochClient boundary) TargetAcmeEab
      `shouldReturn` Right (Just (2, prepared))
    writeIORef (epochPublished fixture) (Right (AuthorityEpoch 2))
    committed <-
      mutateTargetAuthorityEpoch
        (authenticatedEpochClient boundary)
        (PromoteTargetAuthorityEpoch preparation)
    targetEpochMutationRecord (mustRight committed) `shouldBe` promoted
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 2

  it "preserves the ordinary authenticated trust-install route" $ do
    fixture <- newEpochFixture initial
    boundary <- newAuthenticatedEpochFixture fixture
    installAcceptedTargetAuthority
      (targetAuthorityTrustClient (authenticatedEpochTransport boundary))
      (authorityAt 1 1)
      `shouldReturn` Right (authorityAt 1 1)
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "recovers an exact mutation replay without another trust CAS" $ do
    fixture <- newEpochFixture initial
    boundary <- newAuthenticatedEpochFixture fixture
    first <-
      mutateTargetAuthorityEpoch
        (authenticatedEpochClient boundary)
        (PrepareTargetAuthorityEpoch preparation)
    frame <- capturedEpochFrame boundary
    replayed <- authenticatedEpochSend boundary frame
    let (status, bytes) = mustRight replayed
    decodeTargetEpochClientResponse
      (TargetEpochMutate (PrepareTargetAuthorityEpoch preparation))
      (Client.ControlPlaneResponse status bytes)
      `shouldBe` fmap TargetEpochMutated first
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 1

  it "requires a fresh nonce to observe current phase metadata" $ do
    fixture <- newEpochFixture prepared
    boundary <- newAuthenticatedEpochFixture fixture
    observeTargetAuthorityEpochWithClient (authenticatedEpochClient boundary) TargetAcmeEab
      `shouldReturn` Right (Just (1, prepared))
    frame <- capturedEpochFrame boundary
    writeIORef
      (rowState (epochRows fixture))
      (Just (2, mustRight (encodeTargetAuthorityEpochFields retired)))
    authenticatedEpochSend boundary frame
      `shouldReturn` Right (409, "authenticated-read-replay-requires-fresh-nonce\n")
    observeTargetAuthorityEpochWithClient (authenticatedEpochClient boundary) TargetAcmeEab
      `shouldReturn` Right (Just (2, retired))
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "recovers a lost HTTP response through a fresh exact preparation observation" $ do
    fixture <- newEpochFixture initial
    boundary <- newAuthenticatedEpochFixture fixture
    writeIORef (authenticatedEpochLoseResponse boundary) True
    result <-
      mutateTargetAuthorityEpoch
        (authenticatedEpochClient boundary)
        (PrepareTargetAuthorityEpoch preparation)
    result `shouldSatisfy` isLeft
    fixtureRecord (epochRows fixture) `shouldReturn` prepared
    recovered <-
      mutateTargetAuthorityEpoch
        (authenticatedEpochClient boundary)
        (PrepareTargetAuthorityEpoch preparation)
    targetEpochMutationDisposition (mustRight recovered) `shouldBe` TargetEpochMutationAlreadyObserved
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 1

  it "refuses malformed authentication before any Target row effect" $ do
    fixture <- newEpochFixture initial
    boundary <- newAuthenticatedEpochFixture fixture
    result <- authenticatedEpochSend boundary (ByteString.singleton 0)
    fst (mustRight result) `shouldSatisfy` (/= 200)
    readIORef (epochEffectDeadlines fixture) `shouldReturn` []

  it "reports an independent issuer mismatch over the real staging response" $ do
    fixture <- newEpochFixture initial
    boundary <- newAuthenticatedEpochFixture fixture
    writeIORef
      (epochIssuer fixture)
      (Right (mustRight (mkTargetIssuerKeyGeneration 2), acceptedTargetIssuerPublicKey (authorityAt 2 1)))
    mutateTargetAuthorityEpoch
      (authenticatedEpochClient boundary)
      (PrepareTargetAuthorityEpoch preparation)
      `shouldReturn` Left (TargetEpochClientRefused "epoch-staging/issuer-mismatch")
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0

  it "keeps ordinary worker trust closed after authenticated preparation" $ do
    fixture <- newEpochFixture initial
    boundary <- newAuthenticatedEpochFixture fixture
    _ <-
      mutateTargetAuthorityEpoch
        (authenticatedEpochClient boundary)
        (PrepareTargetAuthorityEpoch preparation)
    normal <-
      installAcceptedTargetAuthority
        (targetAuthorityTrustClient (authenticatedEpochTransport boundary))
        (authorityAt 2 1)
    normal `shouldSatisfy` isLeft
    readIORef (rowWrites (epochRows fixture)) `shouldReturn` 1

  it "rejects malformed staging bytes without falling through to an active install" $ do
    fixture <- newEpochFixture initial
    boundary <- newAuthenticatedEpochFixture fixture
    let encoded = mustRight (encodeTargetEpochRequest (TargetEpochObserve TargetAcmeEab))
        malformed = ByteString.take 21 encoded <> "!"
    result <-
      Transport.callAuthenticatedClientTransport
        (authenticatedEpochTransport boundary)
        Client.TargetSecretTrustInstallRoute
        (LazyByteString.toStrict (Codec.encodeControlPlaneRequest (TargetAuthorityTrustRequest malformed)))
    let response = mustRight result
    decodeTargetEpochClientResponse (TargetEpochObserve TargetAcmeEab) response
      `shouldBe` Left (TargetEpochClientRefused "epoch-staging/request-codec-rejected")
    readIORef (epochEffectDeadlines fixture) `shouldReturn` []

epochEffectDeadlineSuite :: SuiteBuilder ()
epochEffectDeadlineSuite = do
  it "refuses expired epoch, issuer, row-read and row-write effects before session acquisition" $ do
    logins <- newIORef (0 :: Int)
    session <- newVaultSession (VaultAddress "http://unused.test") (SessionClock (pure 0)) $ do
      modifyIORef' logins (+ 1)
      pure (Left (VaultSessionUnavailable "unexpected expired-effect login"))
    let interpreter = vaultTargetEpochExecutionInterpreter session (pure (Right now))
        discard :: TargetEpochExecutionProgram result -> IO (Either TargetEpochExecutionError ())
        discard program = fmap void (runTargetEpochExecutionProgram interpreter program)
    discard (ReadPublishedTargetEpoch now) `shouldReturn` Left TargetEpochExecutionDeadlineReached
    discard (ReadTargetEpochIssuer now) `shouldReturn` Left TargetEpochExecutionDeadlineReached
    discard (RunTargetEpochStore now (ReadTargetTrustRow TargetAcmeEab))
      `shouldReturn` Left TargetEpochExecutionDeadlineReached
    discard (RunTargetEpochStore now (CompareAndSwapTargetTrustRow TargetAcmeEab 1 prepared))
      `shouldReturn` Left TargetEpochExecutionDeadlineReached
    readIORef logins `shouldReturn` 0

  it "bounds a blocked production issuer read by its original deadline" $ do
    blocked <- newEmptyMVar
    session <-
      newVaultSession (VaultAddress "http://unused.test") (SessionClock (pure 0)) (readMVar blocked)
    let interpreter = vaultTargetEpochExecutionInterpreter session (pure (Right now))
    runTargetEpochExecutionProgram interpreter (ReadTargetEpochIssuer (authorityTimeFromMicros 5100))
      `shouldReturn` Left TargetEpochEffectTimedOut

  it "preserves asynchronous cancellation through the actual Vault effect factory" $ do
    session <-
      newVaultSession (VaultAddress "http://unused.test") (SessionClock (pure 0)) (throwIO ThreadKilled)
    let interpreter = vaultTargetEpochExecutionInterpreter session (pure (Right now))
    result <-
      try
        (runTargetEpochExecutionProgram interpreter (ReadTargetEpochIssuer (authorityTimeFromMicros 1000100)))
    ( result
        :: Either
             AsyncException
             (Either TargetEpochExecutionError (TargetIssuerKeyGeneration, TargetIntentPublicKey))
      )
      `shouldBe` Left ThreadKilled

data AuthenticatedEpochFixture = AuthenticatedEpochFixture
  { authenticatedEpochClient :: TargetEpochClient IO
  , authenticatedEpochTransport :: Transport.AuthenticatedClientTransport 'TargetSecretAgentRuntime
  , authenticatedEpochFrames :: IORef [ByteString.ByteString]
  , authenticatedEpochSend
      :: ByteString.ByteString -> IO (Either HttpBoundedError (Int, ByteString.ByteString))
  , authenticatedEpochLoseResponse :: IORef Bool
  , fixtureTargetKey :: Authentication.TrustedRequestKey
  , fixtureTamper :: IORef Bool
  , fixtureReplay :: IORef Bool
  }

capturedEpochFrame :: AuthenticatedEpochFixture -> IO ByteString.ByteString
capturedEpochFrame boundary = do
  frames <- readIORef (authenticatedEpochFrames boundary)
  case frames of
    frame : _ -> pure frame
    [] -> expectationFailure "authenticated transport did not capture a frame" >> pure ByteString.empty

newAuthenticatedEpochFixture :: EpochFixture -> IO AuthenticatedEpochFixture
newAuthenticatedEpochFixture = newAuthenticatedEpochFixtureWithSignedResponses False

newAuthenticatedEpochFixtureWithSignedResponses
  :: Bool -> EpochFixture -> IO AuthenticatedEpochFixture
newAuthenticatedEpochFixtureWithSignedResponses signedMode =
  newAuthenticatedEpochFixtureForAgent signedMode localAgent

newAuthenticatedEpochFixtureForAgent
  :: Bool -> TargetAgentIdentity -> EpochFixture -> IO AuthenticatedEpochFixture
newAuthenticatedEpochFixtureForAgent signedMode respondingAgent fixture = do
  nonceCounter <- newIORef (0 :: Natural)
  frames <- newIORef []
  loseResponse <- newIORef False
  tamper <- newIORef False
  replayReply <- newIORef False
  saved <- newIORef Nothing
  let targetSigner =
        mustRight
          ( Authentication.mkRequestSigner
              (Authentication.CallerService TargetSecretAgentRuntime)
              (mustRight (Authentication.mkSigningKeyGeneration 1))
              (ByteString.pack [32 .. 63])
          )
      targetCapability = Authentication.localRequestSigningCapability targetSigner
      targetKey = Authentication.trustedRequestKeyFromSigner targetSigner
      duration = mustRight (authorityDurationFromMicros 3000)
      bounds = mustRight (Transport.mkAuthenticatedTransportBounds 65536 1024 64512)
      replayLimits = mustRight (Replay.mkRequestReplayLimits 64 targetAuthorityTrustResponseMaximumBytes duration)
      signer =
        mustRight
          ( Authentication.mkRequestSigner
              (Authentication.CallerService LifecycleAuthorityRuntime)
              (mustRight (Authentication.mkSigningKeyGeneration 1))
              (ByteString.pack [0 .. 31])
          )
      scope = mustRight (Coordinate.mkAuthorityScope "home")
      registry =
        mustRight
          ( Transport.mkRouteTrustRegistry
              TargetSecretAgentRuntime
              1
              [ (route, Authentication.trustedRequestKeyFromSigner signer)
              | route <- routesForRole TargetSecretAgentRuntime
              ]
          )
      readEpoch = do
        observed <- readIORef (epochPublished fixture)
        pure $ case observed of
          Left _ -> Left "epoch unavailable"
          Right (AuthorityEpoch value) -> maybe (Left "epoch invalid") Right (Genesis.authorityEpochFromValue value)
      readTime = either (const (Left "clock unavailable")) Right <$> readIORef (epochClock fixture)
      clientProviders =
        Transport.AuthenticatedClientProviders
          { Transport.provideAuthenticatedClientSigner =
              pure (Right (Authentication.localRequestSigningCapability signer))
          , Transport.provideAuthenticatedClientScope = pure (Right scope)
          , Transport.provideAuthenticatedClientEpoch = readEpoch
          , Transport.provideAuthenticatedClientDeadline = pure (Right (authorityTimeFromMicros 2000))
          , Transport.provideAuthenticatedClientNonce = do
              counter <- atomicModifyIORef' nonceCounter (\value -> (value + 1, value + 1))
              pure
                ( either
                    (const (Left "nonce invalid"))
                    Right
                    ( Authentication.mkRequestNonce
                        (ByteString.replicate 16 1 <> TextEncoding.encodeUtf8 (Text.pack (show counter)))
                    )
                )
          }
      serverProviders =
        Transport.AuthenticatedServerProviders
          { Transport.provideAuthenticatedServerScope = pure (Right scope)
          , Transport.provideAuthenticatedServerEpoch = readEpoch
          , Transport.provideAuthenticatedServerTime = readTime
          , Transport.provideAuthenticatedServerTrustRegistry = pure (Right registry)
          }
      inner =
        targetAuthorityTrustAuthenticatedHandler
          65536
          (rowRepository (epochRows fixture))
          (Role.contextFreeAuthenticatedRoleHandler Server.failClosedInterpreter)
  replayState <- newIORef (0 :: Int, Replay.initialRequestReplayProjection replayLimits)
  let repository =
        Replay.RequestReplayRepository
          { Replay.readRequestReplayProjection = do
              (version, projection) <- readIORef replayState
              pure (Right (Replay.RequestReplaySnapshot version projection))
          , Replay.compareAndSwapRequestReplayProjection = \expected projection ->
              atomicModifyIORef' replayState $ \observed@(version, _) ->
                if version == expected
                  then ((version + 1, projection), Replay.RequestReplayCasApplied)
                  else (observed, Replay.RequestReplayCasConflict)
          }
      interpreter =
        Role.authenticatedRoleInterpreterWithVerifiedHandler
          (isTargetEpochObservationForRole 65536)
          ( \verified ->
              if signedMode
                then do
                  outcome <-
                    targetEpochSignedObservationHandler
                      65536
                      targetAuthorityTrustResponseMaximumBytes
                      respondingAgent
                      (epochInterpreter fixture)
                      targetCapability
                      verified
                  pure $ case outcome of
                    Nothing -> Nothing
                    Just (Left _) -> Just (ReplyServiceUnavailable, "signed-observation-refused")
                    Just (Right envelope) -> Just (ReplyOk, envelope)
                else targetEpochVerifiedHandler 65536 respondingAgent (epochInterpreter fixture) verified
          )
          bounds
          duration
          ( Role.AuthenticatedRoleProviders
              serverProviders
              (pure (Right (mustRight (Replay.mkReplayAttemptId (ByteString.replicate 16 7)))))
          )
          TargetSecretAgentRuntime
          (mustRight (Replay.mkReplayCasAttempts 4))
          replayLimits
          repository
          inner
      send frame = do
        modifyIORef' frames (<> [frame])
        response <- Server.interpreterHandle interpreter TargetSecretTrustInstall frame
        lost <- atomicModifyIORef' loseResponse (False,)
        pure $
          if lost
            then Left (HttpBoundedTransport (HttpConnectionFailure "fixture HTTP reply lost"))
            else case response of
              Just (status, bytes) -> Right (replyStatusCode status, bytes)
              Nothing -> Right (500, "missing response")
      intercept frame = do
        reply <- send frame
        case reply of
          Left failure -> pure (Left failure)
          Right (status, bytes) -> do
            prior <- readIORef saved
            case prior of Nothing -> writeIORef saved (Just bytes); Just _ -> pure ()
            replace <- readIORef tamper
            replay <- readIORef replayReply
            let fake = case epochResponse 200 (TargetEpochObserved TargetAcmeEab (Just (1, prepared))) of
                  Client.ControlPlaneResponse _ forged -> forged
            pure (Right (status, if replace then fake else if replay then maybe bytes id prior else bytes))
      raw =
        mustRight
          ( Client.controlPlaneClientWithTransport
              ( if signedMode
                  then targetAuthorityTrustResponseMaximumBytes + 1024
                  else targetAuthorityTrustResponseMaximumBytes
              )
              (mustRight (Client.mkTargetSecretAgentEndpoint "http://target-agent.test"))
              (\_ _ _ -> intercept)
          )
      transport = Transport.mkAuthenticatedClientTransport bounds clientProviders raw
  pure
    ( AuthenticatedEpochFixture
        (targetEpochClient transport)
        transport
        frames
        send
        loseResponse
        targetKey
        tamper
        replayReply
    )

data EpochFixture = EpochFixture
  { epochRows :: RowFixture
  , epochClock :: IORef (Either TargetEpochExecutionError AuthorityTime)
  , epochPublished :: IORef (Either TargetEpochExecutionError AuthorityEpoch)
  , epochIssuer
      :: IORef (Either TargetEpochExecutionError (TargetIssuerKeyGeneration, TargetIntentPublicKey))
  , epochEffectDeadlines :: IORef [AuthorityTime]
  , epochInterpreter :: TargetEpochExecutionInterpreter IO
  }

newEpochFixture :: TargetAuthorityEpochRecord -> IO EpochFixture
newEpochFixture record = do
  rows <- newRowFixture record
  clock <- newIORef (Right now)
  published <- newIORef (Right (AuthorityEpoch 1))
  issuer <-
    newIORef
      ( Right
          (acceptedTargetIssuerGeneration (authorityAt 2 1), acceptedTargetIssuerPublicKey (authorityAt 2 1))
      )
  deadlines <- newIORef []
  let recordDeadline value = modifyIORef' deadlines (<> [value])
      interpret :: TargetEpochExecutionProgram result -> IO (Either TargetEpochExecutionError result)
      interpret program = case program of
        ReadTargetEpochTime -> readIORef clock
        ReadPublishedTargetEpoch bound -> recordDeadline bound >> readIORef published
        ReadTargetEpochIssuer bound -> recordDeadline bound >> readIORef issuer
        RunTargetEpochStore bound operation -> do
          recordDeadline bound
          result <- runTargetTrustRowProgram (rowInterpreter rows) operation
          pure (either (Left . TargetEpochStoreFailed) Right result)
  pure
    (EpochFixture rows clock published issuer deadlines (TargetEpochExecutionInterpreter interpret))

execute
  :: EpochFixture
  -> Natural
  -> TargetAuthorityEpochAction
  -> IO (Either TargetEpochExecutionError TargetEpochMutationResult)
execute fixture epoch =
  executeTargetAuthorityEpoch
    localAgent
    (epochInterpreter fixture)
    (verifiedEpochRequest LifecycleAuthorityRuntime "home" TargetSecretTrustInstall epoch 2000)

localAgent :: TargetAgentIdentity
localAgent = acceptedTargetAgentIdentity (authorityAt 1 1)

verifiedEpochRequest
  :: RuntimeRole
  -> Text.Text
  -> ControlPlaneRoute
  -> Natural
  -> Natural
  -> Authentication.VerifiedControlPlaneRequest
verifiedEpochRequest caller scopeText route epochValue requestMicros =
  mustRight
    ( Authentication.decodeAndVerifyControlPlaneRequest
        65536
        context
        (Authentication.encodeSignedControlPlaneRequest signed)
    )
 where
  signer =
    mustRight
      ( Authentication.mkRequestSigner
          (Authentication.CallerService caller)
          (mustRight (Authentication.mkSigningKeyGeneration 1))
          (ByteString.pack [0 .. 31])
      )
  scope = mustRight (Coordinate.mkAuthorityScope scopeText)
  epoch = fromJust (Genesis.authorityEpochFromValue epochValue)
  requestDeadline = authorityTimeFromMicros requestMicros
  nonce = mustRight (Authentication.mkRequestNonce (ByteString.replicate 16 1))
  signed =
    mustRight
      ( Authentication.signControlPlaneRequest
          signer
          route
          TargetSecretAgentRuntime
          scope
          epoch
          requestDeadline
          nonce
          "staging-control"
      )
  context =
    mustRight
      ( Authentication.mkRequestVerificationContext
          (Authentication.trustedRequestKeyFromSigner signer)
          route
          TargetSecretAgentRuntime
          scope
          epoch
          requestDeadline
          nonce
          now
          (mustRight (authorityDurationFromMicros 3000))
      )

data RowWriteMode = RowReplyReceived | RowReplyLost | RowPreparationWins

data RowFixture = RowFixture
  { rowRepository :: TargetAuthorityTrustRepository IO
  , rowInterpreter :: TargetTrustRowInterpreter IO
  , rowState :: IORef (Maybe (Natural, Map.Map Text.Text Text.Text))
  , rowWrites :: IORef Int
  , rowReadHook :: IORef (Int -> IO ())
  , rowReadFailure :: IORef (Maybe TargetAuthorityTrustObservationCause)
  , rowWriteMode :: IORef RowWriteMode
  }

newRowFixture :: TargetAuthorityEpochRecord -> IO RowFixture
newRowFixture record = do
  state <- newIORef (Just (1, mustRight (encodeTargetAuthorityEpochFields record)))
  writeCount <- newIORef 0
  readCount <- newIORef (0 :: Int)
  hook <- newIORef (const (pure ()))
  failure <- newIORef Nothing
  mode <- newIORef RowReplyReceived
  let interpret :: TargetTrustRowProgram result -> IO (Either TargetTrustRowError result)
      interpret program = case program of
        ReadTargetTrustRow _ -> do
          modifyIORef' readCount (+ 1)
          count <- readIORef readCount
          action <- readIORef hook
          action count
          failed <- readIORef failure
          case failed of
            Just cause -> pure (Left (TargetTrustRowObservationFailed cause))
            Nothing -> Right <$> readIORef state
        CompareAndSwapTargetTrustRow _ expected desired -> do
          observed <- readIORef state
          let version = maybe 0 fst observed
          modifyIORef' writeCount (+ 1)
          disposition <- readIORef mode
          if expected /= version
            then pure (Left (TargetTrustRowWriteFailed (VaultCasConflict "fixture CAS conflict")))
            else case disposition of
              RowPreparationWins -> do
                writeIORef state (Just (version + 1, mustRight (encodeTargetAuthorityEpochFields prepared)))
                pure (Left (TargetTrustRowWriteFailed (VaultCasConflict "fixture concurrent preparation")))
              RowReplyReceived ->
                writeIORef state (Just (version + 1, mustRight (encodeTargetAuthorityEpochFields desired)))
                  >> pure (Right ())
              RowReplyLost -> do
                writeIORef state (Just (version + 1, mustRight (encodeTargetAuthorityEpochFields desired)))
                pure (Left (TargetTrustRowWriteFailed (VaultCasUnobservable "fixture reply lost")))
      repository =
        targetAuthorityTrustRepositoryWithEpochRows
          (acceptedTargetAgentIdentity (authorityAt 1 1))
          (TargetTrustRowInterpreter interpret)
  pure
    (RowFixture repository (TargetTrustRowInterpreter interpret) state writeCount hook failure mode)

publishPreparation :: RowFixture -> Int -> IO ()
publishPreparation fixture count =
  when (count == 2) $
    writeIORef (rowState fixture) (Just (2, mustRight (encodeTargetAuthorityEpochFields prepared)))

loseClosingRead :: RowFixture -> Int -> IO ()
loseClosingRead fixture count =
  when (count == 3) $
    writeIORef (rowReadFailure fixture) (Just TargetAuthorityTrustObservationRequestConnectionFailure)

fixtureRecord :: RowFixture -> IO TargetAuthorityEpochRecord
fixtureRecord fixture = do
  observed <- readIORef (rowState fixture)
  let (_, fields) = fromJust observed
  pure (mustRight (decodeTargetAuthorityEpochFields TargetAcmeEab fields))

initial, prepared, promoted, retired :: TargetAuthorityEpochRecord
initial = mustRight (initialTargetAuthorityEpochRecord TargetAcmeEab (Just (authorityAt 1 1)))
prepared =
  mustRight
    (stepTargetAuthorityEpoch (AuthorityEpoch 1) now (PrepareTargetAuthorityEpoch preparation) initial)
promoted =
  mustRight
    (stepTargetAuthorityEpoch (AuthorityEpoch 2) now (PromoteTargetAuthorityEpoch preparation) prepared)
retired =
  mustRight
    (stepTargetAuthorityEpoch (AuthorityEpoch 1) now (RetireTargetAuthorityEpoch preparation) prepared)

preparation :: TargetAuthorityEpochPreparation
preparation = preparationAt 1 2 1000 'a'

preparationAt :: Word -> Word -> Natural -> Char -> TargetAuthorityEpochPreparation
preparationAt predecessor target micros character =
  mustRight (mkTargetAuthorityEpochPreparation context (authorityAt (fromIntegral target) 1))
 where
  context =
    mustRight
      ( mkTargetAuthorityEpochContext
          predecessor
          target
          (fromJust (mkCutoverDigest (Text.replicate 64 (Text.singleton character))))
          (authorityTimeFromMicros micros)
      )

authorityAt :: Natural -> Natural -> AcceptedTargetAuthority
authorityAt epoch fence =
  mustRight
    ( mkAcceptedTargetAuthority
        (mustRight (mkTargetIssuerKeyGeneration 1))
        "lifecycle-authority"
        (targetIntentSigningPublicKey (mustRight (mkTargetIntentSigningKey (ByteString.pack [0 .. 31]))))
        (AuthorityEpoch epoch)
        (mustRight (mkFencingToken fence))
        (mustRight (mkTargetAgentRolloutIdentity "home" ("sha256:" <> Text.replicate 64 "a")))
        (mustRight (compiledTargetSecretSink TargetAcmeEab))
    )

publicField :: AcceptedTargetAuthority -> Text.Text
publicField = TextEncoding.decodeUtf8 . Base64.encode . encodeAcceptedTargetAuthority

now, deadline :: AuthorityTime
now = authorityTimeFromMicros 100
deadline = authorityTimeFromMicros 1000

mustRight :: (Show failure) => Either failure value -> value
mustRight = either (error . show) id

supportedSignedControl :: IO ()
supportedSignedControl = do
  fixture <- newEpochFixture initial
  boundary <- newAuthenticatedEpochFixtureWithSignedResponses True fixture
  let observe =
        observeTargetAuthorityEpochWithVerifiedResponse
          (authenticatedEpochTransport boundary)
          localAgent
          (fixtureTargetKey boundary)
          TargetAcmeEab
  observe `shouldReturn` Right (Just (1, initial))
  let otherRollout = mustRight (mkTargetAgentRolloutIdentity "home" ("sha256:" <> Text.replicate 64 "b"))
  otherBoundary <- newAuthenticatedEpochFixtureForAgent True otherRollout fixture
  wrongRollout <-
    observeTargetAuthorityEpochWithVerifiedResponse
      (authenticatedEpochTransport otherBoundary)
      localAgent
      (fixtureTargetKey otherBoundary)
      TargetAcmeEab
  wrongRollout
    `shouldBe` Left (TargetEpochClientResponseAuthenticationFailed TargetResponse.TargetResponseClaimsMismatch)
  writeIORef (fixtureTamper boundary) True
  observe >>= (`shouldSatisfy` isLeft)
  writeIORef (fixtureTamper boundary) False
  writeIORef (fixtureReplay boundary) True
  observe >>= (`shouldSatisfy` isLeft)
  fixtureRecord (epochRows fixture) `shouldReturn` initial
  readIORef (rowWrites (epochRows fixture)) `shouldReturn` 0
  readIORef (authenticatedEpochFrames boundary) >>= ((`shouldBe` 3) . length)

-- The fixture deliberately supplies the registry and transport locally; the
-- supported runtime must independently authenticate both and CAS this snapshot.
snapshotSignedControl :: IO ()
snapshotSignedControl = do
  fixture <- newEpochFixture initial
  boundary <- newAuthenticatedEpochFixtureWithSignedResponses True fixture
  let scope = mustRight (Coordinate.mkAuthorityScope "home")
      vault = mustRight (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")
      agent = Authentication.CallerService TargetSecretAgentRuntime
      origin principal = mkRpcKeyOrigin scope vault (controlPlaneSigningKeyRefFor principal)
      seedKey principal =
        let source =
              mustRight
                ( Authentication.mkRequestSigner
                    principal
                    (mustRight (Authentication.mkSigningKeyGeneration 1))
                    (ByteString.replicate 32 (fromIntegral (Authentication.callerPrincipalCode principal) + 31))
                )
            public =
              if principal == agent
                then Authentication.trustedRequestPublicKeyBytes (fixtureTargetKey boundary)
                else Authentication.requestSignerPublicKeyBytes source
         in mustRight (mkRpcObservedKey (origin principal) 1 public)
      registry = mustRight (seedLegacyRpcKeyRegistry scope (map seedKey Authentication.allCallerPrincipals))
      clientSpec principal =
        mustRight
          ( mkRegisteredClientSpec
              (clientPrincipalForCaller principal)
              (mustRight (mkRegisteredClientSlot (fromIntegral (Authentication.callerPrincipalCode principal))))
              (mustRight (mkRegisteredClientGeneration 1))
              4
          )
      clients =
        mustRight
          (mkRegisteredClientTable 16 (map clientSpec (trustedCallersForRoute LifecycleOperationSubmit)))
      base = mustRight (initialCleanInstallAuthorityWithRegisteredClients 4 8 clients)
      aggregate = mustRight (seedAuthorityRpcKeyRegistry scope registry base)
      snapshot = AuthorityAdmissionSnapshot (11 :: Int) aggregate
      call snap targetOrigin =
        observeTargetFromSnapshot
          scope
          targetOrigin
          localAgent
          snap
          (authorityTimeFromMicros 2000)
          (authenticatedEpochTransport boundary)
          TargetAcmeEab
  selected <- call snapshot (origin agent)
  let observed = mustRight selected
  targetSnapshotObservationValue observed `shouldBe` Just (1, initial)
  authorityAdmissionRevision (targetSnapshotObservationAuthoritySnapshot observed) `shouldBe` 11
  before <- length <$> readIORef (authenticatedEpochFrames boundary)
  rejected <- call snapshot (origin (Authentication.CallerService ProviderWorkerRuntime))
  rejected `shouldSatisfy` isLeft
  let retiredAggregate =
        mustRight
          (retireAuthorityRpcKey agent (mustRight (Authentication.mkSigningKeyGeneration 1)) aggregate)
  retiredResult <- call (AuthorityAdmissionSnapshot 12 retiredAggregate) (origin agent)
  retiredResult `shouldSatisfy` isLeft
  readIORef (authenticatedEpochFrames boundary) >>= (`shouldBe` before) . length
  let entry = (CutoverHome, localAgent, origin agent, authenticatedEpochTransport boundary)
      signedAgents = mustRight (mkTargetSignedAgentRegistry [entry])
      fallback = TargetEpochBindingInterpreter (\_ -> pure (Left TargetBindingEpochUnavailable))
      signedInterpreter snap = targetSignedEpochBindingInterpreter scope snap signedAgents fallback
  mkTargetSignedAgentRegistry [] `shouldSatisfy` isLeft
  mkTargetSignedAgentRegistry [entry, entry] `shouldSatisfy` isLeft
  let transport = authenticatedEpochTransport boundary
      wrongRoleOrigin = origin (Authentication.CallerService ProviderWorkerRuntime)
      foreignScope = mustRight (Coordinate.mkAuthorityScope "aws")
      foreignOrigin = mkRpcKeyOrigin foreignScope vault (controlPlaneSigningKeyRefFor agent)
  mkTargetSignedAgentRegistry [(CutoverHome, localAgent, wrongRoleOrigin, transport)]
    `shouldSatisfy` isLeft
  mkTargetSignedAgentRegistry [(CutoverHome, localAgent, foreignOrigin, transport)]
    `shouldSatisfy` isLeft
  mkTargetSignedAgentRegistry [entry, (CutoverAws, localAgent, foreignOrigin, transport)]
    `shouldSatisfy` isLeft
  runTargetEpochBindingEffect (signedInterpreter snapshot) (ReadTargetBindingAgent CutoverHome)
    `shouldReturn` Right localAgent
  runTargetEpochBindingEffect
    (signedInterpreter snapshot)
    (ReadTargetBindingRow (authorityTimeFromMicros 2000) CutoverHome TargetAcmeEab)
    `shouldReturn` Right (Just (1, initial))
  writeIORef (fixtureTamper boundary) True
  runTargetEpochBindingEffect
    (signedInterpreter snapshot)
    (ReadTargetBindingRow (authorityTimeFromMicros 2000) CutoverHome TargetAcmeEab)
    `shouldReturn` Left (TargetBindingRowUnavailable TargetAcmeEab)
  writeIORef (fixtureTamper boundary) False
  signedBeforeRetirement <- length <$> readIORef (authenticatedEpochFrames boundary)
  runTargetEpochBindingEffect
    (signedInterpreter (AuthorityAdmissionSnapshot 12 retiredAggregate))
    (ReadTargetBindingRow (authorityTimeFromMicros 2000) CutoverHome TargetAcmeEab)
    `shouldReturn` Left (TargetBindingRowUnavailable TargetAcmeEab)
  readIORef (authenticatedEpochFrames boundary) >>= (`shouldBe` signedBeforeRetirement) . length
