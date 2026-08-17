{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneProviderWorkerExecution
  ( controlPlaneProviderWorkerExecutionSuite
  )
where

import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.Either (isLeft)
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ProviderCredentialSession
import Prodbox.ControlPlane.ProviderNarrowSession
import Prodbox.ControlPlane.ProviderWorkerExecution
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencingToken
  , OwnerNonce
  , authorityTimeFromMicros
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetValueDigest
  , sha256TargetValueDigest
  , targetValueDigestText
  )
import TestSupport

controlPlaneProviderWorkerExecutionSuite :: SuiteBuilder ()
controlPlaneProviderWorkerExecutionSuite =
  describe "Sprint 4.50 isolated Provider Worker execution boundary" $ do
    it "round-trips bounded canonical local trust with its exact resource set" $ do
      let encoded = encodeAcceptedProviderAuthority acceptedAuthority
      decodeAcceptedProviderAuthority acceptedProviderAuthorityMaximumEncodedBytes encoded
        `shouldBe` Right acceptedAuthority
      decodeAcceptedProviderAuthority (ByteString.length encoded - 1) encoded
        `shouldSatisfy` isAcceptedTooLarge
      decodeAcceptedProviderAuthority
        (acceptedProviderAuthorityMaximumEncodedBytes * 2)
        (ByteString.replicate (acceptedProviderAuthorityMaximumEncodedBytes + 1) 0)
        `shouldSatisfy` isAcceptedTooLarge
      decodeAcceptedProviderAuthority acceptedProviderAuthorityMaximumEncodedBytes (encoded <> "\NUL")
        `shouldSatisfy` isLeft

    it "rejects invalid issuer, epoch, and local resource trust" $ do
      mkAcceptedProviderAuthority
        issuerGenerationOne
        ""
        signingPublicKey
        (AuthorityEpoch 4)
        fenceFive
        providerRevision
        registeredResources
        `shouldBe` Left AcceptedProviderIssuerIdentityInvalid
      mkAcceptedProviderAuthority
        issuerGenerationOne
        issuerIdentity
        signingPublicKey
        (AuthorityEpoch 0)
        fenceFive
        providerRevision
        registeredResources
        `shouldBe` Left AcceptedProviderAuthorityEpochMustBePositive
      mkAcceptedProviderAuthority
        issuerGenerationOne
        issuerIdentity
        signingPublicKey
        (AuthorityEpoch 4)
        fenceFive
        providerRevision
        (mkRegisteredProviderResources [])
        `shouldBe` Left AcceptedProviderResourceSetEmpty
      let overBoundResources =
            mkRegisteredProviderResources
              ["stack:resource-" <> Text.pack (show number) | number <- [1 .. 257 :: Int]]
      mkAcceptedProviderAuthority
        issuerGenerationOne
        issuerIdentity
        signingPublicKey
        (AuthorityEpoch 4)
        fenceFive
        providerRevision
        overBoundResources
        `shouldBe` Left (AcceptedProviderResourceSetOverBound 257 256)
      mkAcceptedProviderAuthority
        issuerGenerationOne
        issuerIdentity
        signingPublicKey
        (AuthorityEpoch 4)
        fenceFive
        providerRevision
        (mkRegisteredProviderResources ["stack:bad\NULresource"])
        `shouldBe` Left (AcceptedProviderResourceKeyInvalid "stack:bad\NULresource")
      mkProviderIntentSigningKey "short" `shouldSatisfy` isLeft
      mkProviderIntentPublicKey "short" `shouldBe` Left ProviderIntentSigningKeyInvalid

    it "round-trips a bounded secret-free signed provider intent" $ do
      let signed = signedIntentFor signingKey (defaultSpec defaultIntent)
          encoded = encodeSignedProviderCommittedIntent signed
      decodeSignedProviderCommittedIntent providerCommittedIntentMaximumEncodedBytes encoded
        `shouldBe` Right signed
      mapM_
        (\forbidden -> ByteString.isInfixOf forbidden encoded `shouldBe` False)
        [ "AWS_SECRET_ACCESS_KEY"
        , "smtp-access-key"
        , "admin-prompt"
        , "vault-token"
        , "generic-aws"
        ]
      decodeSignedProviderCommittedIntent (ByteString.length encoded - 1) encoded
        `shouldSatisfy` isIntentTooLarge
      decodeSignedProviderCommittedIntent
        (providerCommittedIntentMaximumEncodedBytes * 2)
        (ByteString.replicate (providerCommittedIntentMaximumEncodedBytes + 1) 0)
        `shouldSatisfy` isIntentTooLarge

    it "preserves the frozen pre-v3 envelope and every historical action ordinal" $ do
      let signed = signedIntentFor signingKey (defaultSpec defaultIntent)
          encoded = encodeSignedProviderCommittedIntent signed
          frozen = mustRight (Base64.decode frozenProviderIntentV2Base64)
      encoded `shouldBe` frozen
      decodeSignedProviderCommittedIntent providerCommittedIntentMaximumEncodedBytes frozen
        `shouldBe` Right signed
      legacyV2EnvelopeSetDigest
        `shouldBe` frozenLegacyV2EnvelopeSetDigest

    it "strictly joins the Target receipt version while preserving exact legacy rollout readiness" $ do
      let regression = fixedProviderCredentialSessionRegression
      providerCredentialSessionRegressionExactJoinAccepted regression `shouldBe` True
      providerCredentialSessionRegressionMetadataRaceRefused regression `shouldBe` True
      providerCredentialSessionRegressionLegacyMetadataRefused regression `shouldBe` True
      providerCredentialSessionRegressionLegacyMetadataReadinessAccepted regression `shouldBe` True
      providerCredentialSessionRegressionWrongExactVersionRefused regression `shouldBe` True
      providerCredentialSessionRegressionDestroyedVersionRefused regression `shouldBe` True
      providerCredentialSessionRegressionMissingDataRefused regression `shouldBe` True
      providerCredentialSessionRegressionExtraSecretFieldRefused regression `shouldBe` True
      providerCredentialSessionRegressionBindingSecretOpaque regression `shouldBe` True
      providerCredentialSessionRegressionErrorSecretOpaque regression `shouldBe` True

    it "fails closed on missing or rotated opaque Provider credential bindings" $ do
      let regression = fixedProviderIntentCredentialBindingRegression
      providerIntentCredentialBindingRegressionUnboundAccepted regression `shouldBe` True
      providerIntentCredentialBindingRegressionExactAccepted regression `shouldBe` True
      providerIntentCredentialBindingRegressionMissingRefused regression `shouldBe` True
      providerIntentCredentialBindingRegressionMismatchRefused regression `shouldBe` True
      providerIntentCredentialBindingRegressionGenerationRotationRefused regression `shouldBe` True
      providerIntentCredentialBindingRegressionVersionRotationRefused regression `shouldBe` True
      providerIntentCredentialBindingRegressionReceiptRotationRefused regression `shouldBe` True
      providerIntentCredentialBindingRegressionRotationSkipsCapability regression `shouldBe` True

    it "rejects invalid intent identities, resource values, revision binding, and action bounds" $ do
      mkProviderIssuerKeyGeneration 0
        `shouldBe` Left ProviderIntentIssuerKeyGenerationMustBePositive
      mkUnsignedProviderCommittedIntent
        (defaultSpec defaultIntent) {providerIntentIssuerIdentity = ""}
        `shouldSatisfy` isLeft
      mkUnsignedProviderCommittedIntent
        (defaultSpec defaultIntent) {providerIntentAuthorityEpoch = AuthorityEpoch 0}
        `shouldSatisfy` isLeft
      mkUnsignedProviderCommittedIntent
        (defaultSpec defaultIntent) {providerIntentOperationId = ""}
        `shouldSatisfy` isLeft
      mkUnsignedProviderCommittedIntent
        (defaultSpec defaultIntent) {providerIntentActionIndex = 65536}
        `shouldSatisfy` isLeft
      mkUnsignedProviderCommittedIntent
        (defaultSpec defaultIntent) {providerIntentIdempotencyKey = "contains space"}
        `shouldSatisfy` isLeft
      mkUnsignedProviderCommittedIntent
        ( defaultSpec
            ( ReconcileRegisteredStack
                (stackRef "aws-eks")
                (revision 2)
                awsEksConfig
            )
        )
        `shouldBe` Left (ProviderIntentRevisionBindingMismatch providerRevision (revision 2))
      let controlRef = stackRef "bad\NULstack"
      mkUnsignedProviderCommittedIntent
        (defaultSpec (ObserveRegisteredStack controlRef))
        `shouldSatisfy` isLeft

    it "rejects an action-digest substitution before signature verification" $ do
      let spec = defaultSpec defaultIntent
          signed = signedIntentFor signingKey spec
          encoded = encodeSignedProviderCommittedIntent signed
          actionDigest = mustRight (providerCommitActionDigest spec)
          tampered =
            replaceOnce
              (TextEncoding.encodeUtf8 (targetValueDigestText actionDigest))
              (TextEncoding.encodeUtf8 (targetValueDigestText otherReceiptDigest))
              encoded
      decodeSignedProviderCommittedIntent providerCommittedIntentMaximumEncodedBytes tampered
        `shouldBe` Left ProviderCommittedIntentActionDigestInvalid

    it "rejects malformed and signature-tampered bytes before a narrow session" $ do
      malformedFixture <- freshFixture
      malformed <-
        admitProviderCommittedIntent
          providerCommittedIntentMaximumEncodedBytes
          (fixtureBoundary malformedFixture)
          "not-cbor"
      case malformed of
        Left (ProviderIntentAdmissionCodecFailed _) -> pure ()
        _ -> expectationFailure "expected malformed provider intent bytes to fail in the codec"
      assertBoundaryCounts malformedFixture (0, 0, 0)

      signatureFixture <- freshFixture
      let encoded =
            encodeSignedProviderCommittedIntent
              (signedIntentFor signingKey (defaultSpec defaultIntent))
          tampered =
            ByteString.init encoded
              <> ByteString.singleton (ByteString.last encoded `xor` 1)
      expectAdmissionRefusalBytes
        signatureFixture
        tampered
        ProviderIntentAuthenticationFailed
      assertBoundaryCounts signatureFixture (1, 1, 0)

    it "authenticates only the pinned issuer identity and key generation" $ do
      wrongKeyFixture <- freshFixture
      expectAdmissionRefusal
        wrongKeyFixture
        (signedIntentFor alternateSigningKey (defaultSpec defaultIntent))
        ProviderIntentAuthenticationFailed

      generationFixture <- freshFixture
      expectAdmissionRefusal
        generationFixture
        ( signedIntentFor
            signingKey
            (defaultSpec defaultIntent)
              { providerIntentIssuerGeneration = issuerGenerationTwo
              }
        )
        ( ProviderIntentIssuerGenerationMismatch
            issuerGenerationOne
            issuerGenerationTwo
        )

      identityFixture <- freshFixture
      expectAdmissionRefusal
        identityFixture
        ( signedIntentFor
            signingKey
            (defaultSpec defaultIntent)
              { providerIntentIssuerIdentity = "substitute-authority"
              }
        )
        (ProviderIntentIssuerIdentityMismatch issuerIdentity "substitute-authority")

    it "rejects stale epoch, fence, provider revision, and unregistered resources" $ do
      epochFixture <- freshFixture
      expectAdmissionRefusal
        epochFixture
        ( signedIntentFor
            signingKey
            (defaultSpec defaultIntent)
              { providerIntentAuthorityEpoch = AuthorityEpoch 3
              }
        )
        (ProviderIntentAuthorityEpochMismatch (AuthorityEpoch 4) (AuthorityEpoch 3))

      fenceFixture <- freshFixture
      expectAdmissionRefusal
        fenceFixture
        ( signedIntentFor
            signingKey
            (defaultSpec defaultIntent)
              { providerIntentFencingToken = fenceFour
              }
        )
        (ProviderIntentFenceBelowFloor fenceFive fenceFour)

      revisionFixture <- freshFixture
      let staleSpec =
            ( defaultSpec
                ( ReconcileRegisteredStack
                    (stackRef "aws-eks")
                    (revision 2)
                    awsEksConfig
                )
            )
              { providerIntentRevision = revision 2
              }
      expectAdmissionRefusal
        revisionFixture
        (signedIntentFor signingKey staleSpec)
        (ProviderIntentRevisionMismatch providerRevision (revision 2))

      resourceFixture <- freshFixture
      let unknownIntent = ReconcileSesCaptureBucket (bucketRef "not-registered")
      expectAdmissionRefusal
        resourceFixture
        (signedIntentFor signingKey (defaultSpec unknownIntent))
        (ProviderIntentUnregisteredResource (providerIntentResourceKey unknownIntent))

    it "rejects reached deadlines and unavailable admission trust/time" $ do
      deadlineFixture <- freshFixture
      writeIORef (fixtureNow deadlineFixture) (Right intentDeadline)
      expectAdmissionRefusal
        deadlineFixture
        (signedIntentFor signingKey (defaultSpec defaultIntent))
        (ProviderIntentDeadlineReached intentDeadline intentDeadline)

      trustFixture <- freshFixture
      writeIORef (fixtureTrust trustFixture) (Left "trust unavailable")
      trustResult <- admitDefault trustFixture defaultIntent
      case trustResult of
        Left (ProviderIntentAdmissionTrustUnavailable "trust unavailable") -> pure ()
        _ -> expectationFailure "expected unavailable provider trust to refuse admission"
      assertBoundaryCounts trustFixture (1, 0, 0)

      clockFixture <- freshFixture
      writeIORef (fixtureNow clockFixture) (Left "clock unavailable")
      clockResult <- admitDefault clockFixture defaultIntent
      case clockResult of
        Left (ProviderIntentAdmissionClockUnavailable "clock unavailable") -> pure ()
        _ -> expectationFailure "expected unavailable provider clock to refuse admission"
      assertBoundaryCounts clockFixture (1, 1, 0)

    it "revalidates local trust and deadline before opening a session" $ do
      changedFixture <- freshFixture
      changedVerified <- mustAdmitDefault changedFixture defaultIntent
      writeIORef
        (fixtureTrust changedFixture)
        ( Right
            ( mustRight
                ( mkAcceptedProviderAuthority
                    issuerGenerationOne
                    issuerIdentity
                    signingPublicKey
                    (AuthorityEpoch 5)
                    fenceFive
                    providerRevision
                    registeredResources
                )
            )
        )
      executeVerifiedProviderIntent (fixtureBoundary changedFixture) changedVerified
        `shouldReturn` Left ProviderIntentExecutionTrustChanged
      assertBoundaryCounts changedFixture (2, 1, 0)

      trustFixture <- freshFixture
      trustVerified <- mustAdmitDefault trustFixture defaultIntent
      writeIORef (fixtureTrust trustFixture) (Left "trust unavailable")
      executeVerifiedProviderIntent (fixtureBoundary trustFixture) trustVerified
        `shouldReturn` Left
          (ProviderIntentExecutionTrustUnavailable "trust unavailable")
      assertBoundaryCounts trustFixture (2, 1, 0)

      clockFixture <- freshFixture
      clockVerified <- mustAdmitDefault clockFixture defaultIntent
      writeIORef (fixtureNow clockFixture) (Left "clock unavailable")
      executeVerifiedProviderIntent (fixtureBoundary clockFixture) clockVerified
        `shouldReturn` Left
          (ProviderIntentExecutionClockUnavailable "clock unavailable")
      assertBoundaryCounts clockFixture (2, 2, 0)

      deadlineFixture <- freshFixture
      deadlineVerified <- mustAdmitDefault deadlineFixture defaultIntent
      writeIORef (fixtureNow deadlineFixture) (Right intentDeadline)
      executeVerifiedProviderIntent (fixtureBoundary deadlineFixture) deadlineVerified
        `shouldReturn` Left
          (ProviderIntentExecutionDeadlineReached intentDeadline intentDeadline)
      assertBoundaryCounts deadlineFixture (2, 2, 0)

    it
      "round-trips v3 authority binding and refuses a rotated accepted record before session acquisition"
      $ do
        sourceFixture <- freshFixture
        sourceVerified <- mustAdmitDefault sourceFixture defaultIntent
        sourceResult <-
          executeVerifiedProviderIntentBound (fixtureBoundary sourceFixture) sourceVerified
        sourceExecuted <- mustExecution sourceResult
        let acceptedDigest = executedProviderIntentAcceptedAuthorityDigest sourceExecuted
            boundSigned =
              signedIntentFor
                signingKey
                (defaultSpec defaultIntent)
                  { providerIntentExpectedAcceptedAuthority = Just acceptedDigest
                  }
            boundBytes = encodeSignedProviderCommittedIntent boundSigned
        decodeSignedProviderCommittedIntent providerCommittedIntentMaximumEncodedBytes boundBytes
          `shouldBe` Right boundSigned
        exactFixture <- freshFixture
        exactAdmission <-
          admitProviderCommittedIntent
            providerCommittedIntentMaximumEncodedBytes
            (fixtureBoundary exactFixture)
            boundBytes
        exactVerified <- mustAdmission exactAdmission
        exactResult <-
          executeVerifiedProviderIntentBound (fixtureBoundary exactFixture) exactVerified
        _ <- mustExecution exactResult

        alternateFixture <- freshFixture
        let alternateAuthority =
              mustRight
                ( mkAcceptedProviderAuthority
                    issuerGenerationOne
                    issuerIdentity
                    (providerIntentSigningPublicKey alternateSigningKey)
                    (AuthorityEpoch 4)
                    fenceFive
                    providerRevision
                    registeredResources
                )
        writeIORef (fixtureTrust alternateFixture) (Right alternateAuthority)
        alternateAdmission <-
          admitProviderCommittedIntent
            providerCommittedIntentMaximumEncodedBytes
            (fixtureBoundary alternateFixture)
            ( encodeSignedProviderCommittedIntent
                (signedIntentFor alternateSigningKey (defaultSpec defaultIntent))
            )
        alternateVerified <- mustAdmission alternateAdmission
        alternateResult <-
          executeVerifiedProviderIntentBound
            (fixtureBoundary alternateFixture)
            alternateVerified
        alternateExecuted <- mustExecution alternateResult
        mismatchFixture <- freshFixture
        let mismatched =
              signedIntentFor
                signingKey
                (defaultSpec defaultIntent)
                  { providerIntentExpectedAcceptedAuthority =
                      Just (executedProviderIntentAcceptedAuthorityDigest alternateExecuted)
                  }
        mismatchAdmission <-
          admitProviderCommittedIntent
            providerCommittedIntentMaximumEncodedBytes
            (fixtureBoundary mismatchFixture)
            (encodeSignedProviderCommittedIntent mismatched)
        mismatchVerified <- mustAdmission mismatchAdmission
        mismatchResult <-
          executeVerifiedProviderIntentBound
            (fixtureBoundary mismatchFixture)
            mismatchVerified
        case mismatchResult of
          Left err ->
            err `shouldBe` ProviderIntentExecutionAcceptedAuthorityBindingMismatch
          Right _ -> expectationFailure "expected rotated Provider authority to be refused"
        assertBoundaryCounts mismatchFixture (2, 1, 0)

    it "dispatches every closed action through only its exact rank-2 capability" $ do
      fixture <- freshFixture
      mapM_ (executeFresh fixture) allIntents
      calls <- reverse <$> readIORef (fixtureCalls fixture)
      calls `shouldBe` concatMap expectedCalls allIntents

    it "returns already-satisfied mutation evidence without applying" $ do
      fixture <- freshFixture
      let intent = ReconcileSesDkim (identityRef "mail")
          coordinate = providerIntentCoordinate intent
      writeIORef (fixtureApplied fixture) [coordinate]
      verified <- mustAdmitDefault fixture intent
      executeVerifiedProviderIntent (fixtureBoundary fixture) verified
        `shouldReturn` Right
          ( ProviderIntentExecutionAlreadySatisfied
              coordinate
              (evidenceFor intent)
          )
      applyCount fixture intent `shouldReturn` 0

    it "confirms applied-but-response-lost work and replays without a second mutation" $ do
      fixture <- freshFixture
      let intent = ReconcileSesSendingIdentity (identityRef "mail")
          coordinate = providerIntentCoordinate intent
      writeIORef (fixtureLoseApplyResponse fixture) [coordinate]
      verified <- mustAdmitDefault fixture intent
      executeVerifiedProviderIntent (fixtureBoundary fixture) verified
        `shouldReturn` Right
          (ProviderIntentExecutionApplied coordinate (evidenceFor intent))
      applyCount fixture intent `shouldReturn` 1

      replay <- mustAdmitDefault fixture intent
      executeVerifiedProviderIntent (fixtureBoundary fixture) replay
        `shouldReturn` Right
          ( ProviderIntentExecutionAlreadySatisfied
              coordinate
              (evidenceFor intent)
          )
      applyCount fixture intent `shouldReturn` 1

    it "never mutates an initially unobservable provider effect" $ do
      fixture <- freshFixture
      let intent = ReconcileSesReceiptRules (ruleSetRef "inbound")
          coordinate = providerIntentCoordinate intent
      writeIORef (fixtureUnobservable fixture) [coordinate]
      verified <- mustAdmitDefault fixture intent
      executeVerifiedProviderIntent (fixtureBoundary fixture) verified
        `shouldReturn` Left
          (ProviderIntentExecutionObservationUnavailable "injected observation outage")
      applyCount fixture intent `shouldReturn` 0

    it "does not infer success from an unavailable read-back and later replay only observes" $ do
      fixture <- freshFixture
      let intent = ReconcileSesCaptureBucket (bucketRef "capture")
          coordinate = providerIntentCoordinate intent
      writeIORef (fixturePostApplyUnobservable fixture) [coordinate]
      verified <- mustAdmitDefault fixture intent
      executeVerifiedProviderIntent (fixtureBoundary fixture) verified
        `shouldReturn` Left
          (ProviderIntentExecutionReadBackUnavailable "injected read-back outage")
      applyCount fixture intent `shouldReturn` 1

      writeIORef (fixturePostApplyUnobservable fixture) []
      replay <- mustAdmitDefault fixture intent
      executeVerifiedProviderIntent (fixtureBoundary fixture) replay
        `shouldReturn` Right
          ( ProviderIntentExecutionAlreadySatisfied
              coordinate
              (evidenceFor intent)
          )
      applyCount fixture intent `shouldReturn` 1

    it "requires positive postcondition evidence after the sole apply attempt" $ do
      fixture <- freshFixture
      let intent = BoundedScratchCheckpoint (checkpointRef "scratch")
          coordinate = providerIntentCoordinate intent
      writeIORef (fixtureNeverConfirm fixture) [coordinate]
      verified <- mustAdmitDefault fixture intent
      executeVerifiedProviderIntent (fixtureBoundary fixture) verified
        `shouldReturn` Left
          (ProviderIntentExecutionMutationNotConfirmed "still missing")
      applyCount fixture intent `shouldReturn` 1

    it "fails closed on session acquisition, read-only failure, or invalid evidence" $ do
      sessionFixture <- freshFixture
      writeIORef (fixtureSessionFailure sessionFixture) (Just "session unavailable")
      sessionVerified <- mustAdmitDefault sessionFixture defaultIntent
      executeVerifiedProviderIntent (fixtureBoundary sessionFixture) sessionVerified
        `shouldReturn` Left
          (ProviderIntentExecutionSessionUnavailable "session unavailable")

      readFixture <- freshFixture
      let readIntent = ObserveRegisteredStack (stackRef "aws-eks")
      writeIORef (fixtureReadOnlyFailure readFixture) [providerIntentCoordinate readIntent]
      readVerified <- mustAdmitDefault readFixture readIntent
      executeVerifiedProviderIntent (fixtureBoundary readFixture) readVerified
        `shouldReturn` Left
          (ProviderIntentExecutionReadOnlyUnavailable "injected read-only outage")

      evidenceFixture <- freshFixture
      let evidenceIntent = ReconcileSesDkim (identityRef "mail")
          coordinate = providerIntentCoordinate evidenceIntent
      writeIORef (fixtureApplied evidenceFixture) [coordinate]
      writeIORef (fixtureInvalidEvidence evidenceFixture) [coordinate]
      evidenceVerified <- mustAdmitDefault evidenceFixture evidenceIntent
      executeVerifiedProviderIntent (fixtureBoundary evidenceFixture) evidenceVerified
        `shouldReturn` Left
          (ProviderIntentExecutionEvidenceInvalid "provider evidence is invalid")

    it "binds operation and idempotency identity into the action digest" $ do
      let first = defaultSpec defaultIntent
          substitute =
            first
              { providerIntentOperationId = "provider-operation-2"
              , providerIntentIdempotencyKey = "provider-idempotency-2"
              }
      providerCommitActionDigest first
        `shouldNotBe` providerCommitActionDigest substitute

data Fixture = Fixture
  { fixtureTrust :: !(IORef (Either Text AcceptedProviderAuthority))
  , fixtureNow :: !(IORef (Either Text AuthorityTime))
  , fixtureTrustReads :: !(IORef Int)
  , fixtureClockReads :: !(IORef Int)
  , fixtureSessionAttempts :: !(IORef Int)
  , fixtureSessionFailure :: !(IORef (Maybe Text))
  , fixtureCalls :: !(IORef [(Text, ProviderIntentCoordinate)])
  , fixtureApplied :: !(IORef [ProviderIntentCoordinate])
  , fixtureLoseApplyResponse :: !(IORef [ProviderIntentCoordinate])
  , fixtureUnobservable :: !(IORef [ProviderIntentCoordinate])
  , fixturePostApplyUnobservable :: !(IORef [ProviderIntentCoordinate])
  , fixtureNeverConfirm :: !(IORef [ProviderIntentCoordinate])
  , fixtureReadOnlyFailure :: !(IORef [ProviderIntentCoordinate])
  , fixtureInvalidEvidence :: !(IORef [ProviderIntentCoordinate])
  }

freshFixture :: IO Fixture
freshFixture =
  Fixture
    <$> newIORef (Right acceptedAuthority)
    <*> newIORef (Right admissionTime)
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef Nothing
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []

fixtureBoundary :: Fixture -> ProviderWorkerExecutionBoundary IO Text
fixtureBoundary fixture =
  mkProviderWorkerExecutionBoundary
    ( ProviderWorkerTrustRepository $ do
        modifyIORef' (fixtureTrustReads fixture) (+ 1)
        readIORef (fixtureTrust fixture)
    )
    ( do
        modifyIORef' (fixtureClockReads fixture) (+ 1)
        readIORef (fixtureNow fixture)
    )
    (fixtureSessionRunner fixture)
    (fixtureCapabilities fixture)

fixtureSessionRunner :: Fixture -> ProviderNarrowSessionRunner IO Text
fixtureSessionRunner fixture =
  ProviderNarrowSessionRunner $ \intent _deadline action -> do
    modifyIORef' (fixtureSessionAttempts fixture) (+ 1)
    failure <- readIORef (fixtureSessionFailure fixture)
    case failure of
      Just detail -> pure (Left detail)
      Nothing -> do
        let coordinate = providerIntentCoordinate intent
        modifyIORef' (fixtureCalls fixture) (("session-open", coordinate) :)
        result <- action Nothing "narrow-provider-session"
        modifyIORef' (fixtureCalls fixture) (("session-close", coordinate) :)
        pure result

fixtureCapabilities :: Fixture -> ProviderIntentCapabilities IO Text
fixtureCapabilities fixture =
  ProviderIntentCapabilities
    { reconcileRegisteredStackCapability = \ref requested _config ->
        mutation
          fixture
          ("stack-reconcile:" <> providerStackRefText ref <> "@" <> revisionText requested)
    , destroyRegisteredStackCapability = \ref requested _config ->
        mutation
          fixture
          ("stack-destroy:" <> providerStackRefText ref <> "@" <> revisionText requested)
    , observeRegisteredStackCapability = \ref ->
        readOnly fixture ("stack-observe:" <> providerStackRefText ref)
    , readBackRegisteredStackCapability = \ref ->
        readOnly fixture ("stack-readback:" <> providerStackRefText ref)
    , boundedScratchCheckpointCapability = \ref ->
        mutation fixture ("checkpoint:" <> providerCheckpointRefText ref)
    , reconcileSesSendingIdentityCapability = \ref ->
        mutation fixture ("ses-identity:" <> sesIdentityRefText ref)
    , reconcileSesDkimCapability = \ref ->
        mutation fixture ("ses-dkim:" <> sesIdentityRefText ref)
    , reconcileSesReceiptRulesCapability = \ref ->
        mutation fixture ("ses-rules:" <> sesRuleSetRefText ref)
    , reconcileSesCaptureBucketCapability = \ref ->
        mutation fixture ("ses-bucket:" <> sesBucketRefText ref)
    , reconcileSesDnsCapability = \ref ->
        mutation fixture ("ses-dns:" <> sesDnsHostedZoneId ref)
    , observePublicARecordCapability = \_ -> readOnly fixture "public-a-observe"
    , reconcilePublicARecordCapability = \_ -> mutation fixture "public-a-reconcile"
    , reapTestEbsVolumesCapability = \clusterName ->
        mutation fixture ("ebs-reap:" <> clusterName)
    , observeTestEbsVolumesCapability = \clusterName ->
        readOnly fixture ("ebs-observe:" <> clusterName)
    , observeSpotPriceCapability = \query ->
        readOnly
          fixture
          ( "spot-price:"
              <> providerSpotPriceInstanceType query
              <> ":"
              <> providerSpotPriceProductDescription query
          )
    , observeOperationalIdentityCapability =
        readOnly fixture "operational-identity"
    , observeProviderAwsScopeCapability =
        readOnly fixture "provider-aws-scope"
    , observeProviderReadinessCapability = \probe ->
        readOnly fixture (readinessLabel probe)
    , issueEksClientAuthCapability = \_ -> readOnly fixture "eks-client-auth"
    , observeEksClusterIdentityCapability = \_ -> readOnly fixture "eks-cluster-identity"
    }

mutation :: Fixture -> Text -> ProviderMutation IO Text
mutation fixture label =
  ProviderMutation
    { observeProviderMutation = \_session coordinate -> do
        modifyIORef' (fixtureCalls fixture) (("observe:" <> label, coordinate) :)
        unavailable <- elem coordinate <$> readIORef (fixtureUnobservable fixture)
        applied <- elem coordinate <$> readIORef (fixtureApplied fixture)
        postUnavailable <- elem coordinate <$> readIORef (fixturePostApplyUnobservable fixture)
        neverConfirm <- elem coordinate <$> readIORef (fixtureNeverConfirm fixture)
        invalidEvidence <- elem coordinate <$> readIORef (fixtureInvalidEvidence fixture)
        pure $
          if unavailable || (applied && postUnavailable)
            then
              ProviderEffectUnobservable
                (if applied then "injected read-back outage" else "injected observation outage")
            else
              if applied && not neverConfirm
                then ProviderEffectSatisfied (if invalidEvidence then "" else "evidence:" <> label)
                else ProviderEffectNeedsApply "still missing"
    , applyProviderMutation = \_session coordinate -> do
        modifyIORef' (fixtureCalls fixture) (("apply:" <> label, coordinate) :)
        modifyIORef' (fixtureApplied fixture) (insertUnique coordinate)
        loseResponse <- elem coordinate <$> readIORef (fixtureLoseApplyResponse fixture)
        if loseResponse
          then pure (Left "injected response loss after apply")
          else pure (Right ())
    }

readOnly :: Fixture -> Text -> ProviderReadOnly IO Text
readOnly fixture label =
  ProviderReadOnly $ \_session coordinate -> do
    modifyIORef' (fixtureCalls fixture) (("read:" <> label, coordinate) :)
    unavailable <- elem coordinate <$> readIORef (fixtureReadOnlyFailure fixture)
    pure $
      if unavailable
        then Left "injected read-only outage"
        else Right ("evidence:" <> label)

executeFresh :: Fixture -> ProviderIntent -> IO ()
executeFresh fixture intent = do
  verified <- mustAdmitDefault fixture intent
  result <- executeVerifiedProviderIntent (fixtureBoundary fixture) verified
  result `shouldBe` Right (expectedExecutionResult intent)

expectedExecutionResult :: ProviderIntent -> ProviderIntentExecutionResult
expectedExecutionResult intent = case intent of
  ObserveRegisteredStack _ -> ProviderIntentExecutionObserved coordinate evidence
  ReadBackRegisteredStack _ -> ProviderIntentExecutionObserved coordinate evidence
  ObserveSpotPrice _ -> ProviderIntentExecutionObserved coordinate evidence
  ObserveOperationalIdentity -> ProviderIntentExecutionObserved coordinate evidence
  ObserveProviderAwsScope -> ProviderIntentExecutionObserved coordinate evidence
  ObserveProviderReadiness _ -> ProviderIntentExecutionObserved coordinate evidence
  ObservePublicARecord _ -> ProviderIntentExecutionObserved coordinate evidence
  IssueEksClientAuth _ -> ProviderIntentExecutionObserved coordinate evidence
  ObserveTestEbsVolumes _ -> ProviderIntentExecutionObserved coordinate evidence
  ObserveEksClusterIdentity _ -> ProviderIntentExecutionObserved coordinate evidence
  _ -> ProviderIntentExecutionApplied coordinate evidence
 where
  coordinate = providerIntentCoordinate intent
  evidence = evidenceFor intent

expectedCalls :: ProviderIntent -> [(Text, ProviderIntentCoordinate)]
expectedCalls intent =
  let coordinate = providerIntentCoordinate intent
      call label = (label, coordinate)
   in case intent of
        ObserveRegisteredStack _ ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        ReadBackRegisteredStack _ ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        ObserveSpotPrice _ ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        ObserveOperationalIdentity ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        ObserveProviderAwsScope ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        ObserveProviderReadiness _ ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        ObservePublicARecord _ ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        IssueEksClientAuth _ ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        ObserveTestEbsVolumes _ ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        ObserveEksClusterIdentity _ ->
          [call "session-open", call ("read:" <> labelFor intent), call "session-close"]
        _ ->
          [ call "session-open"
          , call ("observe:" <> labelFor intent)
          , call ("apply:" <> labelFor intent)
          , call ("observe:" <> labelFor intent)
          , call "session-close"
          ]

admitDefault
  :: Fixture
  -> ProviderIntent
  -> IO (Either ProviderIntentAdmissionError VerifiedProviderCommittedIntent)
admitDefault fixture intent =
  admitProviderCommittedIntent
    providerCommittedIntentMaximumEncodedBytes
    (fixtureBoundary fixture)
    ( encodeSignedProviderCommittedIntent
        (signedIntentFor signingKey (defaultSpec intent))
    )

mustAdmitDefault :: Fixture -> ProviderIntent -> IO VerifiedProviderCommittedIntent
mustAdmitDefault fixture intent = admitDefault fixture intent >>= mustAdmission

mustAdmission
  :: Either ProviderIntentAdmissionError VerifiedProviderCommittedIntent
  -> IO VerifiedProviderCommittedIntent
mustAdmission result = case result of
  Left err -> error ("expected admitted provider intent, got " <> show err)
  Right verified -> pure verified

mustExecution
  :: Either ProviderIntentExecutionError ExecutedProviderIntent
  -> IO ExecutedProviderIntent
mustExecution result = case result of
  Left err -> error ("expected executed provider intent, got " <> show err)
  Right executed -> pure executed

expectAdmissionRefusal
  :: Fixture
  -> SignedProviderCommittedIntent
  -> ProviderIntentVerificationError
  -> IO ()
expectAdmissionRefusal fixture signed =
  expectAdmissionRefusalBytes fixture (encodeSignedProviderCommittedIntent signed)

expectAdmissionRefusalBytes
  :: Fixture
  -> ByteString.ByteString
  -> ProviderIntentVerificationError
  -> IO ()
expectAdmissionRefusalBytes fixture bytes expected = do
  result <-
    admitProviderCommittedIntent
      providerCommittedIntentMaximumEncodedBytes
      (fixtureBoundary fixture)
      bytes
  case result of
    Left (ProviderIntentAdmissionRefused actual) -> actual `shouldBe` expected
    Left other -> expectationFailure ("expected provider verification refusal, got " <> show other)
    Right _ -> expectationFailure "expected provider intent to be refused"

assertBoundaryCounts :: Fixture -> (Int, Int, Int) -> IO ()
assertBoundaryCounts fixture expected = do
  actual <-
    (,,)
      <$> readIORef (fixtureTrustReads fixture)
      <*> readIORef (fixtureClockReads fixture)
      <*> readIORef (fixtureSessionAttempts fixture)
  actual `shouldBe` expected

applyCount :: Fixture -> ProviderIntent -> IO Int
applyCount fixture intent = do
  calls <- readIORef (fixtureCalls fixture)
  pure
    ( length
        ( filter
            (== ("apply:" <> labelFor intent, providerIntentCoordinate intent))
            calls
        )
    )

signedIntentFor
  :: ProviderIntentSigningKey
  -> ProviderCommittedIntentSpec
  -> SignedProviderCommittedIntent
signedIntentFor key =
  signProviderCommittedIntent key . mustRight . mkUnsignedProviderCommittedIntent

defaultSpec :: ProviderIntent -> ProviderCommittedIntentSpec
defaultSpec intent =
  ProviderCommittedIntentSpec
    { providerIntentIssuerGeneration = issuerGenerationOne
    , providerIntentIssuerIdentity = issuerIdentity
    , providerIntentAuthorityEpoch = AuthorityEpoch 4
    , providerIntentOperationId = "provider-operation-1"
    , providerIntentActionIndex = 0
    , providerIntentCommitReceiptDigest = receiptDigest
    , providerIntentOwnerNonce = ownerNonce
    , providerIntentFencingToken = fenceSix
    , providerIntentRevision = providerRevision
    , providerIntentAction = intent
    , providerIntentDeadline = intentDeadline
    , providerIntentIdempotencyKey = "provider-idempotency-1"
    , providerIntentExpectedCredentialSession = Nothing
    , providerIntentExpectedAcceptedAuthority = Nothing
    }

acceptedAuthority :: AcceptedProviderAuthority
acceptedAuthority =
  mustRight
    ( mkAcceptedProviderAuthority
        issuerGenerationOne
        issuerIdentity
        signingPublicKey
        (AuthorityEpoch 4)
        fenceFive
        providerRevision
        registeredResources
    )

registeredResources :: RegisteredProviderResources
registeredResources =
  mkRegisteredProviderResources (map providerIntentResourceKey allIntents)

allIntents :: [ProviderIntent]
allIntents =
  [ ReconcileRegisteredStack (stackRef "aws-eks") providerRevision awsEksConfig
  , DestroyRegisteredStack (stackRef "aws-eks") providerRevision awsEksConfig
  , ObserveRegisteredStack (stackRef "aws-eks")
  , ReadBackRegisteredStack (stackRef "aws-eks")
  , BoundedScratchCheckpoint (checkpointRef "scratch")
  , ReconcileSesSendingIdentity (identityRef "mail")
  , ReconcileSesDkim (identityRef "mail")
  , ReconcileSesReceiptRules (ruleSetRef "inbound")
  , ReconcileSesCaptureBucket (bucketRef "capture")
  , ReconcileSesDns dnsRef
  , ObservePublicARecord publicARef
  , ReconcilePublicARecord publicARef
  , ReapTestEbsVolumes "prodbox-test"
  , ObserveTestEbsVolumes "prodbox-test"
  , ObserveSpotPrice spotPriceQuery
  , ObserveOperationalIdentity
  , ObserveProviderAwsScope
  , ObserveProviderReadiness ProviderReadinessStsIdentity
  , IssueEksClientAuth
      ( mustRight
          ( mkEksClientAuthRequest
              "123456789012"
              "ca-central-1"
              "aws-eks-test-cluster"
              (ByteString.replicate 32 7)
          )
      )
  , ObserveEksClusterIdentity
      ( mustRight
          ( mkEksClusterIdentityRequest
              (stackRef "aws-eks")
              "123456789012"
              "ca-central-1"
              "aws-eks-test-cluster"
          )
      )
  ]

-- The v2 action vocabulary in wire-ordinal order. New actions append to the
-- wire vocabulary; this frozen digest makes reordering an existing tag fail.
legacyProviderIntentsByOrdinal :: [ProviderIntent]
legacyProviderIntentsByOrdinal =
  [ ReconcileRegisteredStack (stackRef "aws-eks") providerRevision awsEksConfig
  , ObserveRegisteredStack (stackRef "aws-eks")
  , ReadBackRegisteredStack (stackRef "aws-eks")
  , BoundedScratchCheckpoint (checkpointRef "scratch")
  , ReconcileSesSendingIdentity (identityRef "mail")
  , ReconcileSesDkim (identityRef "mail")
  , ReconcileSesReceiptRules (ruleSetRef "inbound")
  , ReconcileSesCaptureBucket (bucketRef "capture")
  , DestroyRegisteredStack (stackRef "aws-eks") providerRevision awsEksConfig
  , ReapTestEbsVolumes "prodbox-test"
  , ObserveSpotPrice spotPriceQuery
  , ObserveOperationalIdentity
  , ObserveProviderReadiness ProviderReadinessStsIdentity
  , ObserveProviderReadiness (ProviderReadinessRoute53Zone "Z123EXAMPLE")
  , ReconcileSesDns dnsRef
  , IssueEksClientAuth
      ( mustRight
          ( mkEksClientAuthRequest
              "123456789012"
              "ca-central-1"
              "aws-eks-test-cluster"
              (ByteString.replicate 32 7)
          )
      )
  , ObservePublicARecord publicARef
  , ReconcilePublicARecord publicARef
  , ObserveTestEbsVolumes "prodbox-test"
  , ObserveEksClusterIdentity
      ( mustRight
          ( mkEksClusterIdentityRequest
              (stackRef "aws-eks")
              "123456789012"
              "ca-central-1"
              "aws-eks-test-cluster"
          )
      )
  , ObserveProviderAwsScope
  ]

legacyV2EnvelopeSetDigest :: Text
legacyV2EnvelopeSetDigest =
  targetValueDigestText
    ( sha256TargetValueDigest
        ( ByteString.concat
            [ encodeSignedProviderCommittedIntent
                (signedIntentFor signingKey (defaultSpec intent))
            | intent <- legacyProviderIntentsByOrdinal
            ]
        )
    )

frozenProviderIntentV2Base64 :: ByteString.ByteString
frozenProviderIntentV2Base64 =
  "gwCPAAIBc2xpZmVjeWNsZS1hdXRob3JpdHkEdHByb3ZpZGVyLW9wZXJhdGlvbi0xAHhAM2JkMjNkMTg2NzBkNDU2OWQ4YzFiMjc4YjU3OTA3NDIzZjFlYzNmMjZjNmE3ODJjOGJmYjQwNzk4NjU0MmFiY25wcm92aWRlci1vd25lcgYDhwAEZG1haWyAgICAeEBmNWZhNTkyNTRiNzZjZWY5YTMwNTc4MmU1ODczMjlkODk5N2MzMzA5NjBiZDljOWM0ZmI1NTZkYWJjNmNhYjdmGQPodnByb3ZpZGVyLWlkZW1wb3RlbmN5LTFYQNSP+sx24hDBvuPrUsf3pRp0zdGoDV0KrT6vlYf/6+aDGSWRSGA3s1UVKJHAwxKQpMZspyj6hD8qoARbtcAojww="

frozenLegacyV2EnvelopeSetDigest :: Text
frozenLegacyV2EnvelopeSetDigest =
  "eb237dee7e0a45c935a847428633c60bcaae82b180dd4c4dd2b56dbf000c5b9a"

publicARef :: PublicARecordRef
publicARef = mustRight (mkPublicARecordRef "ZAWS" "edge.example.test" 60 ["192.0.2.10"])

defaultIntent :: ProviderIntent
defaultIntent = ReconcileSesSendingIdentity (identityRef "mail")

labelFor :: ProviderIntent -> Text
labelFor intent = case intent of
  ReconcileRegisteredStack ref requested _config ->
    "stack-reconcile:" <> providerStackRefText ref <> "@" <> revisionText requested
  DestroyRegisteredStack ref requested _config ->
    "stack-destroy:" <> providerStackRefText ref <> "@" <> revisionText requested
  ObserveRegisteredStack ref -> "stack-observe:" <> providerStackRefText ref
  ReadBackRegisteredStack ref -> "stack-readback:" <> providerStackRefText ref
  BoundedScratchCheckpoint ref -> "checkpoint:" <> providerCheckpointRefText ref
  ReconcileSesSendingIdentity ref -> "ses-identity:" <> sesIdentityRefText ref
  ReconcileSesDkim ref -> "ses-dkim:" <> sesIdentityRefText ref
  ReconcileSesReceiptRules ref -> "ses-rules:" <> sesRuleSetRefText ref
  ReconcileSesCaptureBucket ref -> "ses-bucket:" <> sesBucketRefText ref
  ReconcileSesDns ref -> "ses-dns:" <> sesDnsHostedZoneId ref
  ObservePublicARecord _ -> "public-a-observe"
  ReconcilePublicARecord _ -> "public-a-reconcile"
  ReapTestEbsVolumes clusterName -> "ebs-reap:" <> clusterName
  ObserveSpotPrice query ->
    "spot-price:"
      <> providerSpotPriceInstanceType query
      <> ":"
      <> providerSpotPriceProductDescription query
  ObserveOperationalIdentity -> "operational-identity"
  ObserveProviderAwsScope -> "provider-aws-scope"
  ObserveProviderReadiness probe -> readinessLabel probe
  IssueEksClientAuth _ -> "eks-client-auth"
  ObserveTestEbsVolumes clusterName -> "ebs-observe:" <> clusterName
  ObserveEksClusterIdentity _ -> "eks-cluster-identity"

readinessLabel :: ProviderReadinessProbe -> Text
readinessLabel probe = case probe of
  ProviderReadinessStsIdentity -> "readiness:sts"
  ProviderReadinessRoute53Zone zoneId -> "readiness:route53:" <> zoneId

evidenceFor :: ProviderIntent -> Text
evidenceFor = ("evidence:" <>) . labelFor

revisionText :: ProviderRevision -> Text
revisionText = Text.pack . show . providerRevisionNatural

signingKey :: ProviderIntentSigningKey
signingKey = mustRight (mkProviderIntentSigningKey (ByteString.pack [32 .. 63]))

alternateSigningKey :: ProviderIntentSigningKey
alternateSigningKey = mustRight (mkProviderIntentSigningKey (ByteString.pack [64 .. 95]))

signingPublicKey :: ProviderIntentPublicKey
signingPublicKey = providerIntentSigningPublicKey signingKey

issuerGenerationOne :: ProviderIssuerKeyGeneration
issuerGenerationOne = mustRight (mkProviderIssuerKeyGeneration 1)

issuerGenerationTwo :: ProviderIssuerKeyGeneration
issuerGenerationTwo = mustRight (mkProviderIssuerKeyGeneration 2)

issuerIdentity :: Text
issuerIdentity = "lifecycle-authority"

ownerNonce :: OwnerNonce
ownerNonce = mustRight (mkOwnerNonce "provider-owner")

fenceFour :: FencingToken
fenceFour = mustRight (mkFencingToken 4)

fenceFive :: FencingToken
fenceFive = mustRight (mkFencingToken 5)

fenceSix :: FencingToken
fenceSix = mustRight (mkFencingToken 6)

providerRevision :: ProviderRevision
providerRevision = revision 3

admissionTime :: AuthorityTime
admissionTime = authorityTimeFromMicros 100

intentDeadline :: AuthorityTime
intentDeadline = authorityTimeFromMicros 1000

receiptDigest :: TargetValueDigest
receiptDigest = sha256TargetValueDigest "provider-commit-receipt-1"

otherReceiptDigest :: TargetValueDigest
otherReceiptDigest = sha256TargetValueDigest "provider-commit-receipt-2"

stackRef :: Text -> ProviderStackRef
stackRef = mustRight . mkProviderStackRef

checkpointRef :: Text -> ProviderCheckpointRef
checkpointRef = mustRight . mkProviderCheckpointRef

identityRef :: Text -> SesIdentityRef
identityRef = mustRight . mkSesIdentityRef

ruleSetRef :: Text -> SesRuleSetRef
ruleSetRef name = mustRight (mkSesRuleSetRef name "inbox.example.test" "capture")

bucketRef :: Text -> SesBucketRef
bucketRef = mustRight . mkSesBucketRef

dnsRef :: SesDnsRef
dnsRef = mustRight (mkSesDnsRef "Z123EXAMPLE" "example.test" "inbox.example.test")

revision :: Natural -> ProviderRevision
revision = mustRight . mkProviderRevision

awsEksConfig :: ProviderStackConfig
awsEksConfig = mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")

spotPriceQuery :: ProviderSpotPriceQuery
spotPriceQuery = mustRight (mkProviderSpotPriceQuery "t3.small" "Linux/UNIX")

insertUnique :: (Eq value) => value -> [value] -> [value]
insertUnique value values
  | value `elem` values = values
  | otherwise = value : values

replaceOnce
  :: ByteString.ByteString
  -> ByteString.ByteString
  -> ByteString.ByteString
  -> ByteString.ByteString
replaceOnce needle replacement haystack =
  let (prefix, suffix) = ByteString.breakSubstring needle haystack
   in if ByteString.null suffix
        then error "expected canonical provider bytes to contain the action digest"
        else prefix <> replacement <> ByteString.drop (ByteString.length needle) suffix

isAcceptedTooLarge
  :: Either AcceptedProviderAuthorityCodecError value
  -> Bool
isAcceptedTooLarge result = case result of
  Left (AcceptedProviderAuthorityTooLarge _ _) -> True
  _ -> False

isIntentTooLarge
  :: Either ProviderCommittedIntentCodecError value
  -> Bool
isIntentTooLarge result = case result of
  Left (ProviderCommittedIntentTooLarge _ _) -> True
  _ -> False

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight result = case result of
  Left err -> error ("expected Right, got " <> show err)
  Right value -> value
