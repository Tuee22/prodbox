{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTargetSecretAgentExecution
  ( controlPlaneTargetSecretAgentExecutionSuite
  )
where

import Data.Bits (xor)
import Data.ByteString qualified as ByteString
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
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetAcmeEab, TargetSesSmtp)
  , TargetSecretPayload (..)
  , compiledTargetSecretSink
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
import Prodbox.ControlPlane.TrustedTargetSink
  ( TrustedTargetSink
  , mkTrustedTargetSink
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  , mkTargetClusterSecretSink
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencingToken
  , OwnerNonce
  , authorityTimeFromMicros
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetSinkObservation (..)
  , TargetSinkRecord (..)
  , TargetSinkVersion
  , TargetValueDigest
  , mkCredentialGeneration
  , mkTargetSinkVersion
  , sha256TargetValueDigest
  , targetValueDigestText
  )
import TestSupport

controlPlaneTargetSecretAgentExecutionSuite :: SuiteBuilder ()
controlPlaneTargetSecretAgentExecutionSuite =
  describe "Sprint 4.50 isolated Target Secret Agent execution boundary" $ do
    it "round-trips bounded canonical Agent trust without a global Authority coordinate" $ do
      let encoded = encodeAcceptedTargetAuthority acceptedAuthority
      decodeAcceptedTargetAuthority acceptedTargetAuthorityMaximumEncodedBytes encoded
        `shouldBe` Right acceptedAuthority
      decodeAcceptedTargetAuthority (ByteString.length encoded - 1) encoded
        `shouldSatisfy` isAcceptedAuthorityTooLarge
      decodeAcceptedTargetAuthority
        (acceptedTargetAuthorityMaximumEncodedBytes * 2)
        (ByteString.replicate (acceptedTargetAuthorityMaximumEncodedBytes + 1) 0)
        `shouldSatisfy` isAcceptedAuthorityTooLarge
      decodeAcceptedTargetAuthority acceptedTargetAuthorityMaximumEncodedBytes (encoded <> "\NUL")
        `shouldSatisfy` isLeft

    it "rejects invalid local trust values before they can become accepted authority" $ do
      mkAcceptedTargetAuthority
        issuerGenerationOne
        ""
        signingPublicKey
        (AuthorityEpoch 3)
        fenceFive
        agentIdentity
        targetSink
        `shouldBe` Left AcceptedTargetAuthorityIssuerIdentityInvalid
      mkAcceptedTargetAuthority
        issuerGenerationOne
        issuerIdentity
        signingPublicKey
        (AuthorityEpoch 0)
        fenceFive
        agentIdentity
        targetSink
        `shouldBe` Left AcceptedTargetAuthorityEpochMustBePositive
      mkTargetIntentSigningKey "short" `shouldSatisfy` isLeft
      mkTargetIntentPublicKey "short" `shouldBe` Left TargetIntentSigningKeyInvalid

    it "round-trips a bounded canonical signed intent with no plaintext or unkeyed payload digest" $ do
      let signed = signedIntentFor signingKey defaultIntentSpec
          encoded = encodeSignedTargetCommittedIntent signed
      decodeSignedTargetCommittedIntent targetCommittedIntentMaximumEncodedBytes encoded
        `shouldBe` Right signed
      ByteString.isInfixOf "smtp-secret" encoded `shouldBe` False
      ByteString.isInfixOf "smtp-user" encoded `shouldBe` False
      decodeSignedTargetCommittedIntent (ByteString.length encoded - 1) encoded
        `shouldSatisfy` isCommittedIntentTooLarge
      decodeSignedTargetCommittedIntent
        (targetCommittedIntentMaximumEncodedBytes * 2)
        (ByteString.replicate (targetCommittedIntentMaximumEncodedBytes + 1) 0)
        `shouldSatisfy` isCommittedIntentTooLarge
      decodeSignedTargetCommittedIntent targetCommittedIntentMaximumEncodedBytes (encoded <> "\NUL")
        `shouldSatisfy` isLeft

    it "rejects invalid intent identities, epochs, issuer generations, and action bounds" $ do
      mkTargetIssuerKeyGeneration 0
        `shouldBe` Left TargetIntentIssuerKeyGenerationMustBePositive
      mkUnsignedTargetCommittedIntent
        defaultIntentSpec {targetIntentAuthorityEpoch = AuthorityEpoch 0}
        `shouldSatisfy` isLeft
      mkUnsignedTargetCommittedIntent
        defaultIntentSpec {targetIntentIssuerIdentity = ""}
        `shouldSatisfy` isLeft
      mkUnsignedTargetCommittedIntent
        defaultIntentSpec {targetIntentOperationId = ""}
        `shouldSatisfy` isLeft
      mkUnsignedTargetCommittedIntent
        defaultIntentSpec {targetIntentActionIndex = 65536}
        `shouldSatisfy` isLeft
      mkUnsignedTargetCommittedIntent
        defaultIntentSpec {targetIntentIdempotencyKey = "contains space"}
        `shouldSatisfy` isLeft

    it "rejects an internally substituted action digest before signature verification" $ do
      let signed = signedIntentFor signingKey defaultIntentSpec
          encoded = encodeSignedTargetCommittedIntent signed
          actionDigest = mustRight (targetCommitActionDigest defaultIntentSpec)
          tampered =
            replaceOnce
              (TextEncoding.encodeUtf8 (targetValueDigestText actionDigest))
              (TextEncoding.encodeUtf8 (targetValueDigestText otherReceiptDigest))
              encoded
      decodeSignedTargetCommittedIntent targetCommittedIntentMaximumEncodedBytes tampered
        `shouldBe` Left TargetCommittedIntentActionDigestInvalid

    it "rejects a byte-tampered canonical Ed25519 signature" $ do
      fixture <- freshExecutionFixture
      let encoded =
            encodeSignedTargetCommittedIntent
              (signedIntentFor signingKey defaultIntentSpec)
          tampered =
            ByteString.init encoded
              <> ByteString.singleton (ByteString.last encoded `xor` 1)
      result <-
        admitTargetCommittedIntent
          targetCommittedIntentMaximumEncodedBytes
          (fixtureBoundary fixture)
          tampered
      case result of
        Left (TargetIntentAdmissionRefused TargetIntentAuthenticationFailed) -> pure ()
        Left other -> expectationFailure ("expected authentication refusal, got " <> show other)
        Right _ -> expectationFailure "expected the tampered signature to be refused"
      assertEffectCounts fixture (1, 1, 0, 0, 0)

    it "rejects malformed wire bytes before trust, clock, material, or target effects" $ do
      fixture <- freshExecutionFixture
      result <-
        admitTargetCommittedIntent
          targetCommittedIntentMaximumEncodedBytes
          (fixtureBoundary fixture)
          "not-cbor"
      case result of
        Left (TargetIntentAdmissionCodecFailed _) -> pure ()
        _ -> expectationFailure "expected malformed intent bytes to fail in the codec"
      assertEffectCounts fixture (0, 0, 0, 0, 0)

    it "authenticates only the pinned Ed25519 issuer generation" $ do
      fixture <- freshExecutionFixture
      let wrongSignature = signedIntentFor alternateSigningKey defaultIntentSpec
      expectAdmissionRefusal
        fixture
        wrongSignature
        TargetIntentAuthenticationFailed
      assertEffectCounts fixture (1, 1, 0, 0, 0)

      second <- freshExecutionFixture
      expectAdmissionRefusal
        second
        ( signedIntentFor
            signingKey
            defaultIntentSpec
              { targetIntentIssuerGeneration = issuerGenerationTwo
              }
        )
        ( TargetIntentIssuerGenerationMismatch
            issuerGenerationOne
            issuerGenerationTwo
        )
      assertEffectCounts second (1, 1, 0, 0, 0)

      identityFixture <- freshExecutionFixture
      expectAdmissionRefusal
        identityFixture
        ( signedIntentFor
            signingKey
            defaultIntentSpec
              { targetIntentIssuerIdentity = "substitute-authority"
              }
        )
        (TargetIntentIssuerIdentityMismatch issuerIdentity "substitute-authority")
      assertEffectCounts identityFixture (1, 1, 0, 0, 0)

    it "rejects stale authority epoch and fence before any target effect" $ do
      epochFixture <- freshExecutionFixture
      expectAdmissionRefusal
        epochFixture
        ( signedIntentFor
            signingKey
            defaultIntentSpec
              { targetIntentAuthorityEpoch = AuthorityEpoch 2
              }
        )
        (TargetIntentAuthorityEpochMismatch (AuthorityEpoch 3) (AuthorityEpoch 2))
      assertEffectCounts epochFixture (1, 1, 0, 0, 0)

      fenceFixture <- freshExecutionFixture
      expectAdmissionRefusal
        fenceFixture
        ( signedIntentFor
            signingKey
            defaultIntentSpec
              { targetIntentFencingToken = fenceFour
              }
        )
        (TargetIntentFenceBelowFloor fenceFive fenceFour)
      assertEffectCounts fenceFixture (1, 1, 0, 0, 0)

    it "rejects an intent and trust record for a different selected Agent" $ do
      fixture <- freshExecutionFixture
      let wrongAccepted =
            mustRight
              ( mkAcceptedTargetAuthority
                  issuerGenerationOne
                  issuerIdentity
                  signingPublicKey
                  (AuthorityEpoch 3)
                  fenceFive
                  otherAgentIdentity
                  targetSink
              )
      writeIORef (fixtureTrust fixture) (Right wrongAccepted)
      expectAdmissionRefusal
        fixture
        ( signedIntentFor
            signingKey
            defaultIntentSpec
              { targetIntentAgentIdentity = otherAgentIdentity
              }
        )
        ( TargetIntentAgentIdentityMismatch
            (targetAgentIdentityText agentIdentity)
            (targetAgentIdentityText otherAgentIdentity)
        )
      assertEffectCounts fixture (1, 1, 0, 0, 0)

    it "rejects target identity and unregistered binding substitution before any target effect" $ do
      identityFixture <- freshExecutionFixture
      expectAdmissionRefusal
        identityFixture
        ( signedIntentFor
            signingKey
            defaultIntentSpec
              { targetIntentSink = otherIdentitySink
              }
        )
        (TargetIntentTargetIdentityMismatch "ses-smtp" "acme-eab")
      assertEffectCounts identityFixture (1, 1, 0, 0, 0)

      mkUnsignedTargetCommittedIntent
        defaultIntentSpec {targetIntentSink = otherBindingSink}
        `shouldBe` Left TargetIntentTargetUnregistered

    it "rejects a reached absolute deadline before any target effect" $ do
      fixture <- freshExecutionFixture
      writeIORef (fixtureNow fixture) (Right intentDeadline)
      expectAdmissionRefusal
        fixture
        (signedIntentFor signingKey defaultIntentSpec)
        (TargetIntentDeadlineReached intentDeadline intentDeadline)
      assertEffectCounts fixture (1, 1, 0, 0, 0)

    it "fails closed when Agent-local trust or clock cannot be read" $ do
      trustFixture <- freshExecutionFixture
      writeIORef (fixtureTrust trustFixture) (Left "trust unavailable")
      trustResult <- admitDefault trustFixture
      case trustResult of
        Left (TargetIntentAdmissionTrustUnavailable "trust unavailable") -> pure ()
        _ -> expectationFailure "expected unavailable local trust to refuse admission"
      assertEffectCounts trustFixture (1, 0, 0, 0, 0)

      clockFixture <- freshExecutionFixture
      writeIORef (fixtureNow clockFixture) (Left "clock unavailable")
      clockResult <- admitDefault clockFixture
      case clockResult of
        Left (TargetIntentAdmissionClockUnavailable "clock unavailable") -> pure ()
        _ -> expectationFailure "expected unavailable authority time to refuse admission"
      assertEffectCounts clockFixture (1, 1, 0, 0, 0)

    it "revalidates local trust between admission and execution" $ do
      fixture <- freshExecutionFixture
      verified <- mustAdmitDefault fixture
      writeIORef
        (fixtureTrust fixture)
        ( Right
            ( mustRight
                ( mkAcceptedTargetAuthority
                    issuerGenerationOne
                    issuerIdentity
                    signingPublicKey
                    (AuthorityEpoch 4)
                    fenceFive
                    agentIdentity
                    targetSink
                )
            )
        )
      executeVerifiedTargetIntent (fixtureBoundary fixture) verified
        `shouldReturn` Left TargetIntentExecutionTrustChanged
      assertEffectCounts fixture (2, 1, 0, 0, 0)

      unavailableFixture <- freshExecutionFixture
      unavailableVerified <- mustAdmitDefault unavailableFixture
      writeIORef (fixtureTrust unavailableFixture) (Left "trust unavailable")
      executeVerifiedTargetIntent (fixtureBoundary unavailableFixture) unavailableVerified
        `shouldReturn` Left (TargetIntentExecutionTrustUnavailable "trust unavailable")
      assertEffectCounts unavailableFixture (2, 1, 0, 0, 0)

    it "rechecks deadline and clock between admission and execution" $ do
      deadlineFixture <- freshExecutionFixture
      deadlineVerified <- mustAdmitDefault deadlineFixture
      writeIORef (fixtureNow deadlineFixture) (Right intentDeadline)
      executeVerifiedTargetIntent (fixtureBoundary deadlineFixture) deadlineVerified
        `shouldReturn` Left (TargetIntentExecutionDeadlineReached intentDeadline intentDeadline)
      assertEffectCounts deadlineFixture (2, 2, 0, 0, 0)

      clockFixture <- freshExecutionFixture
      clockVerified <- mustAdmitDefault clockFixture
      writeIORef (fixtureNow clockFixture) (Left "clock unavailable")
      executeVerifiedTargetIntent (fixtureBoundary clockFixture) clockVerified
        `shouldReturn` Left (TargetIntentExecutionClockUnavailable "clock unavailable")
      assertEffectCounts clockFixture (2, 2, 0, 0, 0)

    it "binds plaintext recovery to the exact signed receipt before mutation" $ do
      unavailableFixture <- freshExecutionFixture
      unavailableVerified <- mustAdmitDefault unavailableFixture
      writeIORef
        (fixtureMaterial unavailableFixture)
        (Left "sealed receipt unavailable")
      executeVerifiedTargetIntent (fixtureBoundary unavailableFixture) unavailableVerified
        `shouldReturn` Left (TargetIntentExecutionMaterialUnavailable "sealed receipt unavailable")
      assertEffectCounts unavailableFixture (2, 2, 1, 1, 0)

      mismatchFixture <- freshExecutionFixture
      mismatchVerified <- mustAdmitDefault mismatchFixture
      writeIORef
        (fixtureMaterial mismatchFixture)
        (Right (TargetSecretMaterial otherReceiptDigest targetPayload))
      executeVerifiedTargetIntent (fixtureBoundary mismatchFixture) mismatchVerified
        `shouldReturn` Left
          ( TargetIntentExecutionMaterialReceiptMismatch
              receiptDigest
              otherReceiptDigest
          )
      assertEffectCounts mismatchFixture (2, 2, 1, 1, 0)

      schemaFixture <- freshExecutionFixture
      schemaVerified <- mustAdmitDefault schemaFixture
      writeIORef
        (fixtureMaterial schemaFixture)
        (Right (TargetSecretMaterial receiptDigest mismatchedTargetPayload))
      executeVerifiedTargetIntent (fixtureBoundary schemaFixture) schemaVerified
        `shouldReturn` Left
          ( TargetIntentExecutionMaterialTargetMismatch
              TargetSesSmtp
              TargetAcmeEab
          )
      assertEffectCounts schemaFixture (2, 2, 1, 1, 0)

    it "refuses retired, unavailable, unbounded, and changing sinks without materialization" $ do
      let cases =
            [ (TargetSinkRetired, TargetIntentExecutionTargetRetired)
            ,
              ( TargetSinkUnobservable "Vault unavailable"
              , TargetIntentExecutionTargetUnavailable "Vault unavailable"
              )
            ,
              ( TargetSinkUnbounded 5 4
              , TargetIntentExecutionTargetUnbounded 5 4
              )
            ,
              ( TargetSinkChanging "concurrent writer"
              , TargetIntentExecutionTargetChanging "concurrent writer"
              )
            ]
      mapM_ assertSinkRefusal cases

    it "rejects newer and same-generation conflicting target records without mutation" $ do
      newerFixture <- freshExecutionFixture
      newerVerified <- mustAdmitDefault newerFixture
      writeIORef
        (fixtureSinkState newerFixture)
        (TargetSinkObserved sinkVersion (targetRecord generationTwo otherReceiptDigest))
      executeVerifiedTargetIntent (fixtureBoundary newerFixture) newerVerified
        `shouldReturn` Left
          (TargetIntentExecutionGenerationNewer generationTwo generationOne)
      assertEffectCounts newerFixture (2, 2, 0, 1, 0)

      collisionFixture <- freshExecutionFixture
      collisionVerified <- mustAdmitDefault collisionFixture
      writeIORef
        (fixtureSinkState collisionFixture)
        (TargetSinkObserved sinkVersion (targetRecord generationOne otherReceiptDigest))
      executeVerifiedTargetIntent (fixtureBoundary collisionFixture) collisionVerified
        `shouldReturn` Left (TargetIntentExecutionGenerationCollision generationOne)
      assertEffectCounts collisionFixture (2, 2, 0, 1, 0)

    it "never treats an unconfirmed target mutation as success" $ do
      fixture <- freshExecutionFixture
      verified <- mustAdmitDefault fixture
      writeIORef (fixtureApplyMutation fixture) False
      executeVerifiedTargetIntent (fixtureBoundary fixture) verified
        `shouldReturn` Left (TargetIntentExecutionMutationNotConfirmed "missing")
      readIORef (fixtureSinkWrites fixture) `shouldReturn` 1
      finalObservation <- readIORef (fixtureSinkState fixture)
      case finalObservation of
        TargetSinkMissing -> pure ()
        _ -> expectationFailure "expected the refused mutation to leave the sink missing"

    it "confirms an applied-but-response-lost CAS and replays without a second write or plaintext read" $ do
      fixture <- freshExecutionFixture
      verified <- mustAdmitDefault fixture
      executeVerifiedTargetIntent (fixtureBoundary fixture) verified
        `shouldReturn` Right (TargetIntentExecutionApplied generationOne)
      readIORef (fixtureSinkWrites fixture) `shouldReturn` 1
      readIORef (fixtureMaterialReads fixture) `shouldReturn` 1

      executeVerifiedTargetIntent (fixtureBoundary fixture) verified
        `shouldReturn` Right (TargetIntentExecutionAlreadyApplied generationOne)
      readIORef (fixtureSinkWrites fixture) `shouldReturn` 1
      readIORef (fixtureMaterialReads fixture) `shouldReturn` 1

    it "makes same-generation operation and idempotency substitution a collision" $ do
      fixture <- freshExecutionFixture
      firstVerified <- mustAdmitDefault fixture
      executeVerifiedTargetIntent (fixtureBoundary fixture) firstVerified
        `shouldReturn` Right (TargetIntentExecutionApplied generationOne)

      let substituteSpec =
            defaultIntentSpec
              { targetIntentOperationId = "operation-2"
              , targetIntentIdempotencyKey = "target-home-generation-1-substitute"
              }
      targetCommitActionDigest substituteSpec
        `shouldNotBe` targetCommitActionDigest defaultIntentSpec
      substituteVerified <-
        mustAdmit
          fixture
          (encodeSignedTargetCommittedIntent (signedIntentFor signingKey substituteSpec))
      executeVerifiedTargetIntent (fixtureBoundary fixture) substituteVerified
        `shouldReturn` Left (TargetIntentExecutionGenerationCollision generationOne)
      readIORef (fixtureSinkWrites fixture) `shouldReturn` 1
      readIORef (fixtureMaterialReads fixture) `shouldReturn` 1

data ExecutionFixture = ExecutionFixture
  { fixtureTrust :: !(IORef (Either Text AcceptedTargetAuthority))
  , fixtureNow :: !(IORef (Either Text AuthorityTime))
  , fixtureMaterial :: !(IORef (Either Text TargetSecretMaterial))
  , fixtureSinkState :: !(IORef (TargetSinkObservation TargetSecretPayload))
  , fixtureApplyMutation :: !(IORef Bool)
  , fixtureTrustReads :: !(IORef Int)
  , fixtureClockReads :: !(IORef Int)
  , fixtureMaterialReads :: !(IORef Int)
  , fixtureSinkObserves :: !(IORef Int)
  , fixtureSinkWrites :: !(IORef Int)
  }

freshExecutionFixture :: IO ExecutionFixture
freshExecutionFixture =
  ExecutionFixture
    <$> newIORef (Right acceptedAuthority)
    <*> newIORef (Right admissionTime)
    <*> newIORef (Right (TargetSecretMaterial receiptDigest targetPayload))
    <*> newIORef TargetSinkMissing
    <*> newIORef True
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef 0

fixtureBoundary :: ExecutionFixture -> TargetSecretAgentExecutionBoundary IO
fixtureBoundary fixture =
  mkTargetSecretAgentExecutionBoundary
    agentIdentity
    ( TargetAgentTrustRepository $ do
        modifyIORef' (fixtureTrustReads fixture) (+ 1)
        readIORef (fixtureTrust fixture)
    )
    ( do
        modifyIORef' (fixtureClockReads fixture) (+ 1)
        readIORef (fixtureNow fixture)
    )
    ( TrustedTargetSecretMaterialSource $ \_ -> do
        modifyIORef' (fixtureMaterialReads fixture) (+ 1)
        readIORef (fixtureMaterial fixture)
    )
    (fixtureTrustedSink fixture)

fixtureTrustedSink
  :: ExecutionFixture
  -> TrustedTargetSink IO TargetSecretPayload
fixtureTrustedSink fixture =
  mkTrustedTargetSink
    targetSink
    ( do
        modifyIORef' (fixtureSinkObserves fixture) (+ 1)
        readIORef (fixtureSinkState fixture)
    )
    ( \expected record -> do
        modifyIORef' (fixtureSinkWrites fixture) (+ 1)
        apply <- readIORef (fixtureApplyMutation fixture)
        current <- readIORef (fixtureSinkState fixture)
        if apply && expectedVersionMatches expected current
          then do
            writeIORef
              (fixtureSinkState fixture)
              (TargetSinkObserved sinkVersion record)
            pure (Left "target Vault CAS response lost after apply")
          else pure (Left "target Vault CAS conflict")
    )

expectedVersionMatches
  :: Maybe TargetSinkVersion
  -> TargetSinkObservation payload
  -> Bool
expectedVersionMatches expected observation = case (expected, observation) of
  (Nothing, TargetSinkMissing) -> True
  (Just expectedVersion, TargetSinkObserved actualVersion _) ->
    expectedVersion == actualVersion
  _ -> False

assertSinkRefusal
  :: (TargetSinkObservation TargetSecretPayload, TargetIntentExecutionError)
  -> IO ()
assertSinkRefusal (observation, expectedError) = do
  fixture <- freshExecutionFixture
  verified <- mustAdmitDefault fixture
  writeIORef (fixtureSinkState fixture) observation
  executeVerifiedTargetIntent (fixtureBoundary fixture) verified
    `shouldReturn` Left expectedError
  assertEffectCounts fixture (2, 2, 0, 1, 0)

assertEffectCounts
  :: ExecutionFixture
  -> (Int, Int, Int, Int, Int)
  -> IO ()
assertEffectCounts fixture expected = do
  actual <-
    (,,,,)
      <$> readIORef (fixtureTrustReads fixture)
      <*> readIORef (fixtureClockReads fixture)
      <*> readIORef (fixtureMaterialReads fixture)
      <*> readIORef (fixtureSinkObserves fixture)
      <*> readIORef (fixtureSinkWrites fixture)
  actual `shouldBe` expected

admitDefault
  :: ExecutionFixture
  -> IO (Either TargetIntentAdmissionError VerifiedTargetCommittedIntent)
admitDefault fixture =
  admitTargetCommittedIntent
    targetCommittedIntentMaximumEncodedBytes
    (fixtureBoundary fixture)
    ( encodeSignedTargetCommittedIntent
        (signedIntentFor signingKey defaultIntentSpec)
    )

mustAdmitDefault :: ExecutionFixture -> IO VerifiedTargetCommittedIntent
mustAdmitDefault fixture = admitDefault fixture >>= mustAdmission

mustAdmit
  :: ExecutionFixture
  -> ByteString.ByteString
  -> IO VerifiedTargetCommittedIntent
mustAdmit fixture bytes =
  admitTargetCommittedIntent
    targetCommittedIntentMaximumEncodedBytes
    (fixtureBoundary fixture)
    bytes
    >>= mustAdmission

mustAdmission
  :: Either TargetIntentAdmissionError VerifiedTargetCommittedIntent
  -> IO VerifiedTargetCommittedIntent
mustAdmission result = case result of
  Left err -> error ("expected admitted target intent, got " <> show err)
  Right verified -> pure verified

expectAdmissionRefusal
  :: ExecutionFixture
  -> SignedTargetCommittedIntent
  -> TargetIntentVerificationError
  -> IO ()
expectAdmissionRefusal fixture signed expected = do
  result <-
    admitTargetCommittedIntent
      targetCommittedIntentMaximumEncodedBytes
      (fixtureBoundary fixture)
      (encodeSignedTargetCommittedIntent signed)
  case result of
    Left (TargetIntentAdmissionRefused actual) -> actual `shouldBe` expected
    Left other -> expectationFailure ("expected verification refusal, got " <> show other)
    Right _ -> expectationFailure "expected signed target intent to be refused"

signedIntentFor
  :: TargetIntentSigningKey
  -> TargetCommittedIntentSpec
  -> SignedTargetCommittedIntent
signedIntentFor key = signTargetCommittedIntent key . mustRight . mkUnsignedTargetCommittedIntent

targetRecord
  :: CredentialGeneration
  -> TargetValueDigest
  -> TargetSinkRecord TargetSecretPayload
targetRecord generation digest =
  TargetSinkRecord
    { targetSinkRecordOwnerNonce = ownerNonce
    , targetSinkRecordFencingToken = fenceSix
    , targetSinkRecordGeneration = generation
    , targetSinkRecordDigest = digest
    , targetSinkRecordPayload = targetPayload
    }

isAcceptedAuthorityTooLarge
  :: Either AcceptedTargetAuthorityCodecError value
  -> Bool
isAcceptedAuthorityTooLarge result = case result of
  Left (AcceptedTargetAuthorityTooLarge _ _) -> True
  _ -> False

isCommittedIntentTooLarge
  :: Either TargetCommittedIntentCodecError value
  -> Bool
isCommittedIntentTooLarge result = case result of
  Left (TargetCommittedIntentTooLarge _ _) -> True
  _ -> False

replaceOnce
  :: ByteString.ByteString
  -> ByteString.ByteString
  -> ByteString.ByteString
  -> ByteString.ByteString
replaceOnce needle replacement haystack =
  let (prefix, suffix) = ByteString.breakSubstring needle haystack
   in if ByteString.null suffix
        then error "expected canonical intent bytes to contain the action digest"
        else prefix <> replacement <> ByteString.drop (ByteString.length needle) suffix

defaultIntentSpec :: TargetCommittedIntentSpec
defaultIntentSpec =
  TargetCommittedIntentSpec
    { targetIntentIssuerGeneration = issuerGenerationOne
    , targetIntentIssuerIdentity = issuerIdentity
    , targetIntentAuthorityEpoch = AuthorityEpoch 3
    , targetIntentOperationId = "operation-1"
    , targetIntentActionIndex = 0
    , targetIntentCommitReceiptDigest = receiptDigest
    , targetIntentOwnerNonce = ownerNonce
    , targetIntentFencingToken = fenceSix
    , targetIntentAgentIdentity = agentIdentity
    , targetIntentSink = targetSink
    , targetIntentGeneration = generationOne
    , targetIntentDeadline = intentDeadline
    , targetIntentIdempotencyKey = "target-home-generation-1"
    }

acceptedAuthority :: AcceptedTargetAuthority
acceptedAuthority =
  mustRight
    ( mkAcceptedTargetAuthority
        issuerGenerationOne
        issuerIdentity
        signingPublicKey
        (AuthorityEpoch 3)
        fenceFive
        agentIdentity
        targetSink
    )

signingKey :: TargetIntentSigningKey
signingKey =
  mustRight (mkTargetIntentSigningKey (ByteString.pack [0 .. 31]))

alternateSigningKey :: TargetIntentSigningKey
alternateSigningKey =
  mustRight (mkTargetIntentSigningKey (ByteString.pack [1 .. 32]))

signingPublicKey :: TargetIntentPublicKey
signingPublicKey = targetIntentSigningPublicKey signingKey

issuerIdentity :: Text
issuerIdentity = "lifecycle-authority"

agentIdentity :: TargetAgentIdentity
agentIdentity =
  mustRight
    (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "a"))

otherAgentIdentity :: TargetAgentIdentity
otherAgentIdentity =
  mustRight
    (mkTargetAgentIdentity ("aws@sha256:" <> Text.replicate 64 "b"))

issuerGenerationOne :: TargetIssuerKeyGeneration
issuerGenerationOne = mustRight (mkTargetIssuerKeyGeneration 1)

issuerGenerationTwo :: TargetIssuerKeyGeneration
issuerGenerationTwo = mustRight (mkTargetIssuerKeyGeneration 2)

ownerNonce :: OwnerNonce
ownerNonce = mustRight (mkOwnerNonce "authority-owner")

fenceFour :: FencingToken
fenceFour = mustRight (mkFencingToken 4)

fenceFive :: FencingToken
fenceFive = mustRight (mkFencingToken 5)

fenceSix :: FencingToken
fenceSix = mustRight (mkFencingToken 6)

generationOne :: CredentialGeneration
generationOne = mustRight (mkCredentialGeneration 1)

generationTwo :: CredentialGeneration
generationTwo = mustRight (mkCredentialGeneration 2)

admissionTime :: AuthorityTime
admissionTime = authorityTimeFromMicros 100

intentDeadline :: AuthorityTime
intentDeadline = authorityTimeFromMicros 1000

receiptDigest :: TargetValueDigest
receiptDigest = sha256TargetValueDigest "sealed-receipt-1"

otherReceiptDigest :: TargetValueDigest
otherReceiptDigest = sha256TargetValueDigest "sealed-receipt-2"

sinkVersion :: TargetSinkVersion
sinkVersion = mustRight (mkTargetSinkVersion "1")

targetPayload :: TargetSecretPayload
targetPayload =
  SesSmtpMaterial
    { sesSmtpHost = "email-smtp.ca-central-1.amazonaws.com"
    , sesSmtpPort = "587"
    , sesSmtpFrom = "noreply@example.com"
    , sesSmtpFromDisplayName = "Prodbox"
    , sesSmtpReplyTo = "support@example.com"
    , sesSmtpUsername = "smtp-user"
    , sesSmtpPassword = "smtp-secret"
    }

mismatchedTargetPayload :: TargetSecretPayload
mismatchedTargetPayload =
  AcmeEabMaterial
    { acmeEabKeyId = "eab-key-id"
    , acmeEabHmacKey = "eab-hmac-key"
    }

targetSink :: TargetClusterSecretSink
targetSink =
  mustRight (compiledTargetSecretSink TargetSesSmtp)

otherIdentitySink :: TargetClusterSecretSink
otherIdentitySink =
  mustRight (compiledTargetSecretSink TargetAcmeEab)

otherBindingSink :: TargetClusterSecretSink
otherBindingSink =
  mustRight
    ( mkTargetClusterSecretSink
        "home"
        "secret"
        "acme/eab"
    )

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight result = case result of
  Left err -> error ("expected Right, got " <> show err)
  Right value -> value
