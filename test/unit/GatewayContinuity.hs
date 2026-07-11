{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module GatewayContinuity
  ( gatewayContinuitySuite
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import Prodbox.Gateway.Continuity
import Prodbox.Gateway.ContinuityStore
import Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError (..)
  , LogicalConditionalPutResult (..)
  , VersionedLogicalObject (..)
  )
import Prodbox.Minio.ObjectStore (ObjectVersion (..))
import TestSupport

gatewayContinuitySuite :: SuiteBuilder ()
gatewayContinuitySuite =
  describe "Sprint 2.31 retained gateway continuity" $ do
    it "rejects zero bounds and counts scoped text in UTF-8 bytes" $ do
      let zeroCases =
            [ (mkContinuityBounds 0 64 128, MaximumEmitterBytes)
            , (mkContinuityBounds 32 0 128, MaximumOrdersAnchorBytes)
            , (mkContinuityBounds 32 64 0, MaximumSignedAssertionBytes)
            ]
      forM_ zeroCases $ \(actual, field) ->
        actual `shouldBe` Left (ContinuityBoundMustBePositive field)
      mkContinuityScope
        (mustRight (mkContinuityBounds 1 64 128))
        "é"
        "orders"
        `shouldBe` Left (ContinuityEmitterTooLarge 2 1)

    it "rejects empty or oversized scope fields and non-fixed digests" $ do
      mkContinuityScope continuityBounds " " "orders"
        `shouldBe` Left ContinuityEmitterMustNotBeEmpty
      mkContinuityScope continuityBounds "node-a" BS.empty
        `shouldBe` Left ContinuityOrdersAnchorMustNotBeEmpty
      mkContinuityScope
        (mustRight (mkContinuityBounds 32 3 128))
        "node-a"
        "orders"
        `shouldBe` Left (ContinuityOrdersAnchorTooLarge 6 3)
      mkContinuityDigest (BS.replicate 31 0)
        `shouldBe` Left (ContinuityDigestWidthInvalid 32 31)

    it "bounds one committed anchor plus at most one exact staged assertion" $ do
      let record = initialRecord 3 7
      authorityRecordStagedAssertion record `shouldBe` Nothing
      authorityRecordRetainedBytes record
        `shouldSatisfy` (<= authorityRecordMaximumRetainedBytes continuityBounds)
      let pipeline = semanticPipeline
          stagedRecord = mustStoredRecord (pipelineStagedState pipeline)
      authorityRecordStagedAssertion stagedRecord `shouldSatisfy` isJust
      authorityRecordRetainedBytes stagedRecord
        `shouldSatisfy` (<= authorityRecordMaximumRetainedBytes continuityBounds)

    it "recovers a total-peer restart solely from the retained authority" $ do
      let state = readyState 9 41
          (result, observed) =
            runInMemoryAuthority
              (recoverContinuityAtStartup authority)
              state
      expectCurrentAt 9 41 result
      fakeAuthorityReadCount observed `shouldBe` 1
      fakeAuthorityCasCount observed `shouldBe` 0

    it "recovers every emitter in a total-peer restart fixture from retained authority only" $ do
      forM_ (zip [1 ..] ["node-a", "node-b", "node-c"]) $ \(sequenceNumber, emitter) -> do
        let scope = mustRight (mkContinuityScope continuityBounds emitter "orders-v1-sha256")
            retained =
              mkInitialAuthorityRecord
                scope
                4
                sequenceNumber
                genesisDigest
            emitterAuthority = inMemoryGatewayContinuityAuthority scope
            (recovered, finalState) =
              runInMemoryAuthority
                (recoverContinuityAtStartup emitterAuthority)
                (fakeAuthorityPresent (versionAuthorityRecord 9 retained))
        expectCurrentAt 4 sequenceNumber recovered
        fakeAuthorityReadCount finalState `shouldBe` 1
        fakeAuthorityCasCount finalState `shouldBe` 0

    it "fails closed with distinct missing, corrupt, and unobservable errors" $ do
      let cases =
            [ (fakeAuthorityMissing, ContinuityAuthorityMissing)
            , (fakeAuthorityCorrupt "bad authentication tag", ContinuityAuthorityCorrupt "bad authentication tag")
            ,
              ( fakeAuthorityUnobservable "object store timeout"
              , ContinuityAuthorityUnobservable "object store timeout"
              )
            ]
      forM_ cases $ \(state, expected) ->
        fst
          ( runInMemoryAuthority
              (recoverContinuityAtStartup authority)
              state
          )
          `shouldBe` Left expected

    it "maps production Model-B missing, corrupt, and unobservable observations" $ do
      let missingBackend = readOnlyBackend (Right Nothing)
          corruptBackend =
            readOnlyBackend (Left (EncryptedObjectIndexMalformed "bad-index"))
          unobservableBackend =
            readOnlyBackend (Left (EncryptedObjectFetchFailed "offline"))
      recoverContinuityAtStartup
        (modelBContinuityAuthorityWithBackend missingBackend continuityScope)
        `shouldReturn` Left ContinuityAuthorityMissing
      recoverContinuityAtStartup
        (modelBContinuityAuthorityWithBackend corruptBackend continuityScope)
        `shouldReturn` Left
          ( ContinuityAuthorityCorrupt
              "encrypted object index is malformed: bad-index"
          )
      recoverContinuityAtStartup
        (modelBContinuityAuthorityWithBackend unobservableBackend continuityScope)
        `shouldReturn` Left
          ( ContinuityAuthorityUnobservable
              "failed to fetch encrypted object: offline"
          )

    it "uses initialize-if-absent once and passes the observed ETag to CAS" $ do
      initializeCount <- newIORef (0 :: Int)
      let initializingBackend =
            ContinuityStoreBackend
              { continuityBackendGet = const (pure (Right Nothing))
              , continuityBackendPutIfAbsent = \_ _ -> do
                  writeIORef initializeCount 1
                  pure (Right LogicalConditionalPutApplied)
              , continuityBackendPutIfVersion = \_ _ _ ->
                  pure (Right LogicalConditionalPutConflict)
              }
          initializingAuthority =
            modelBContinuityAuthorityWithBackend initializingBackend continuityScope
          admission = mkFirstContinuityAdmission continuityScope genesisDigest
      initialized <- initializeContinuityAtFirstAdmission initializingAuthority admission
      case initialized of
        Right (StartupCurrent current) ->
          authorityVersionValue (currentContinuityVersion current) `shouldBe` 0
        other -> expectationFailure ("expected initialized continuity, got " ++ show other)
      readIORef initializeCount `shouldReturn` 1

      observedVersion <- newIORef Nothing
      let etag = ObjectVersion "etag-7"
          versioned = versionAuthorityRecord 0 (initialRecord 1 0)
          casBackend =
            ContinuityStoreBackend
              { continuityBackendGet =
                  const
                    ( pure
                        ( Right
                            ( Just
                                VersionedLogicalObject
                                  { versionedLogicalBytes =
                                      encodeVersionedAuthorityRecord versioned
                                  , versionedLogicalStoreVersion = etag
                                  }
                            )
                        )
                    )
              , continuityBackendPutIfAbsent = \_ _ ->
                  pure (Right LogicalConditionalPutConflict)
              , continuityBackendPutIfVersion = \_ suppliedVersion _ -> do
                  writeIORef observedVersion (Just suppliedVersion)
                  pure (Right LogicalConditionalPutConflict)
              }
          casAuthority =
            modelBContinuityAuthorityWithBackend casBackend continuityScope
      startup <- recoverContinuityAtStartup casAuthority
      current <-
        case startup of
          Right (StartupCurrent value) -> pure value
          other -> expectationFailure ("expected current continuity, got " ++ show other) >> fail "unreachable"
      staged <- stageSemanticAssertion casAuthority current semanticAssertion
      staged
        `shouldBe` Left (ContinuityAuthorityCasConflict (Just (versionOf 0)))
      readIORef observedVersion `shouldReturn` Just etag

    it "round-trips only bounded, scope-valid retained CBOR" $ do
      let versioned = versionAuthorityRecord 7 (initialRecord 3 9)
          encoded = encodeVersionedAuthorityRecord versioned
      decodeVersionedAuthorityRecord continuityScope encoded
        `shouldBe` Right versioned
      let allowed = authorityRecordMaximumEncodedBytes continuityBounds
          oversized = BS.replicate (fromIntegral allowed + 1) 0
      decodeVersionedAuthorityRecord continuityScope oversized
        `shouldBe` Left (ContinuityEncodedRecordTooLarge (allowed + 1) allowed)

    it "initializes a definitively missing authority exactly once" $ do
      let admission = mkFirstContinuityAdmission continuityScope genesisDigest
          (first, seeded) =
            runInMemoryAuthority
              (initializeContinuityAtFirstAdmission authority admission)
              fakeAuthorityMissing
          (second, observed) =
            runInMemoryAuthority
              (initializeContinuityAtFirstAdmission authority admission)
              seeded
      expectCurrentAt 1 0 first
      expectCurrentAt 1 0 second
      fakeAuthorityCasCount observed `shouldBe` 1
      fakeAuthorityReadCount observed `shouldBe` 2

    it "never seeds corrupt, unobservable, or mismatched first admission" $ do
      let admission = mkFirstContinuityAdmission continuityScope genesisDigest
          cases =
            [ (fakeAuthorityCorrupt "bad", ContinuityAuthorityCorrupt "bad")
            , (fakeAuthorityUnobservable "down", ContinuityAuthorityUnobservable "down")
            ]
      forM_ cases $ \(state, expected) -> do
        let (result, finalState) =
              runInMemoryAuthority
                (initializeContinuityAtFirstAdmission authority admission)
                state
        result `shouldBe` Left expected
        fakeAuthorityCasCount finalState `shouldBe` 0
      let otherScope =
            mustRight (mkContinuityScope continuityBounds "node-b" "orders-v1-sha256")
          mismatched = mkFirstContinuityAdmission otherScope genesisDigest
          (result, finalState) =
            runInMemoryAuthority
              (initializeContinuityAtFirstAdmission authority mismatched)
              fakeAuthorityMissing
      result `shouldBe` Left ContinuityFirstAdmissionScopeMismatch
      fakeAuthorityReadCount finalState `shouldBe` 0

    it "requires stage, durable CAS, exact re-observation, then publication" $ do
      let pipeline = semanticPipeline
          acknowledgement = pipelineAcknowledgement pipeline
          witness = pipelineWitness pipeline
          committed = pipelineCommitted pipeline
      authorityVersionValue (durableStageVersion acknowledgement) `shouldBe` 1
      fakeAuthorityCasCount (pipelineStagedState pipeline) `shouldBe` 1
      publicationSignedBytes witness `shouldBe` semanticBytes
      publicationTransition witness `shouldBe` SemanticAdvance
      publicationPreviousDigest witness `shouldBe` genesisDigest
      continuityAnchorEpoch (publicationNextAnchor witness) `shouldBe` 1
      continuityAnchorSequence (publicationNextAnchor witness) `shouldBe` 1
      authorityVersionValue (currentContinuityVersion committed) `shouldBe` 2
      continuityAnchorSequence (currentContinuityAnchor committed) `shouldBe` 1
      authorityRecordStagedAssertion
        (mustStoredRecord (pipelineCommittedState pipeline))
        `shouldBe` Nothing

    it "rejects a CAS acknowledgement that does not name the exact durable record" $ do
      let initial = versionAuthorityRecord 0 (initialRecord 1 0)
          wrong = versionAuthorityRecord 1 (initialRecord 1 0)
          lyingAuthority =
            gatewayContinuityAuthority
              continuityScope
              (pure (AuthorityObserved initial))
              (\_ _ -> pure (AuthorityCasApplied wrong))
      startup <- recoverContinuityAtStartup lyingAuthority
      let current = mustCurrent startup
      outcome <-
        stageSemanticAssertion lyingAuthority current semanticAssertion
      outcome `shouldSatisfy` isDurabilityMismatch

    it "refuses publication when the staged record cannot be observed exactly" $ do
      let pipeline = semanticPipeline
          acknowledgement = pipelineAcknowledgement pipeline
          wrongRecord = versionAuthorityRecord 1 (initialRecord 1 0)
          replaced =
            fakeAuthorityReplacePresent
              wrongRecord
              (pipelineStagedState pipeline)
          (mismatch, _) =
            runInMemoryAuthority
              (reobserveDurableStage authority acknowledgement)
              replaced
          (unobservable, _) =
            runInMemoryAuthority
              (reobserveDurableStage authority acknowledgement)
              (fakeAuthorityUnobservable "read failed")
      mismatch `shouldSatisfy` isReobservationMismatch
      unobservable
        `shouldBe` Left (ContinuityAuthorityUnobservable "read failed")

    it "serializes overlapping emitter incarnations with compare-and-swap" $ do
      let initial = readyState 1 0
          (firstStartup, afterFirstRead) =
            runInMemoryAuthority
              (recoverContinuityAtStartup authority)
              initial
          stale = mustCurrent firstStartup
          (firstStage, afterFirstStage) =
            runInMemoryAuthority
              (stageSemanticAssertion authority stale semanticAssertion)
              afterFirstRead
          (secondStage, finalState) =
            runInMemoryAuthority
              (stageSemanticAssertion authority stale anotherSemanticAssertion)
              afterFirstStage
      firstStage `shouldSatisfy` isRight
      secondStage
        `shouldBe` Left (ContinuityAuthorityCasConflict (Just (versionOf 1)))
      fakeAuthorityCasCount finalState `shouldBe` 2

    it "distinguishes missing, corrupt, and unobservable authority during CAS" $ do
      let current = mustCurrent (fst (runStartup (readyState 1 0)))
          cases =
            [ (fakeAuthorityMissing, ContinuityAuthorityMissing)
            , (fakeAuthorityCorrupt "corrupt", ContinuityAuthorityCorrupt "corrupt")
            , (fakeAuthorityUnobservable "down", ContinuityAuthorityUnobservable "down")
            ]
      forM_ cases $ \(state, expected) ->
        fst
          ( runInMemoryAuthority
              (stageSemanticAssertion authority current semanticAssertion)
              state
          )
          `shouldBe` Left expected

    it "recovers the exact staged bytes at every post-CAS crash point" $ do
      let pipeline = semanticPipeline
          crashStates =
            [ pipelineStagedState pipeline
            , pipelineReobservedState pipeline
            , pipelinePublishedState pipeline
            ]
      forM_ crashStates $ \state -> do
        let (recovery, _) = runStartup state
        expectRepublish semanticBytes recovery
      expectCurrentAt 1 0 (fst (runStartup (readyState 1 0)))
      expectCurrentAt
        1
        1
        (fst (runStartup (pipelineCommittedState pipeline)))

    it "allows the last Word64 sequence without wrapping" $ do
      let current = mustCurrent (fst (runStartup (readyState 5 (maxBound - 1))))
          (staged, stateAfterStage) =
            runInMemoryAuthority
              (stageSemanticAssertion authority current semanticAssertion)
              (readyState 5 (maxBound - 1))
          acknowledgement = mustRight staged
          (reobserved, stateAfterObserve) =
            runInMemoryAuthority
              (reobserveDurableStage authority acknowledgement)
              stateAfterStage
          witness = mustRight reobserved
          (committed, committedState) =
            runInMemoryAuthority
              (commitPublishedAssertion authority (acknowledgePublication witness))
              stateAfterObserve
          terminalCurrent = mustRight committed
          (nextAttempt, _) =
            runInMemoryAuthority
              (stageSemanticAssertion authority terminalCurrent anotherSemanticAssertion)
              committedState
      continuityAnchorSequence (currentContinuityAnchor terminalCurrent)
        `shouldBe` maxBound
      nextAttempt `shouldBe` Left (ContinuitySequenceRequiresRotation 5)

    it "rotates an exhausted sequence only through a signed invalidating checkpoint" $ do
      let current = mustCurrent (fst (runStartup (readyState 5 maxBound)))
          (semanticAttempt, _) =
            runInMemoryAuthority
              (stageSemanticAssertion authority current semanticAssertion)
              (readyState 5 maxBound)
          (rotationAttempt, stagedState) =
            runInMemoryAuthority
              (stageEpochInvalidation authority current epochInvalidation)
              (readyState 5 maxBound)
          acknowledgement = mustRight rotationAttempt
          (reobserved, _) =
            runInMemoryAuthority
              (reobserveDurableStage authority acknowledgement)
              stagedState
          witness = mustRight reobserved
      semanticAttempt `shouldBe` Left (ContinuitySequenceRequiresRotation 5)
      publicationTransition witness `shouldBe` EpochInvalidation
      publicationSignedBytes witness `shouldBe` invalidationBytes
      continuityAnchorEpoch (publicationNextAnchor witness) `shouldBe` 6
      continuityAnchorSequence (publicationNextAnchor witness) `shouldBe` 0

    it "rejects early rotation and terminates at the maximum epoch and sequence" $ do
      let early = mustCurrent (fst (runStartup (readyState 4 7)))
          terminal = mustCurrent (fst (runStartup (readyState maxBound maxBound)))
      fst
        ( runInMemoryAuthority
            (stageEpochInvalidation authority early epochInvalidation)
            (readyState 4 7)
        )
        `shouldBe` Left (ContinuityRotationBeforeSequenceExhaustion 7)
      fst
        ( runInMemoryAuthority
            (stageEpochInvalidation authority terminal epochInvalidation)
            (readyState maxBound maxBound)
        )
        `shouldBe` Left (ContinuityCountersExhausted maxBound maxBound)

    it "recovers and re-emits an epoch invalidation byte-for-byte" $ do
      let current = mustCurrent (fst (runStartup (readyState 12 maxBound)))
          (staged, stateAfterStage) =
            runInMemoryAuthority
              (stageEpochInvalidation authority current epochInvalidation)
              (readyState 12 maxBound)
          _acknowledgement = mustRight staged
          (recovery, _) = runStartup stateAfterStage
      expectRepublish invalidationBytes recovery

    it "fails before CAS when the storage version itself is exhausted" $ do
      let state =
            fakeAuthorityPresent
              (versionAuthorityRecord maxBound (initialRecord 1 0))
          (startup, afterRead) = runStartup state
          current = mustCurrent startup
          (attempt, finalState) =
            runInMemoryAuthority
              (stageSemanticAssertion authority current semanticAssertion)
              afterRead
      attempt
        `shouldBe` Left (ContinuityAuthorityVersionExhausted (versionOf maxBound))
      fakeAuthorityCasCount finalState `shouldBe` 0

data SemanticPipeline = SemanticPipeline
  { pipelineAcknowledgement :: DurableStageAcknowledgement
  , pipelineStagedState :: FakeAuthorityState
  , pipelineWitness :: PublicationWitness
  , pipelineReobservedState :: FakeAuthorityState
  , pipelinePublishedState :: FakeAuthorityState
  , pipelineCommitted :: CurrentContinuity
  , pipelineCommittedState :: FakeAuthorityState
  }

semanticPipeline :: SemanticPipeline
semanticPipeline =
  let (startup, afterStartup) = runStartup (readyState 1 0)
      current = mustCurrent startup
      (staged, afterStage) =
        runInMemoryAuthority
          (stageSemanticAssertion authority current semanticAssertion)
          afterStartup
      acknowledgement = mustRight staged
      (reobserved, afterReobserve) =
        runInMemoryAuthority
          (reobserveDurableStage authority acknowledgement)
          afterStage
      witness = mustRight reobserved
      published = acknowledgePublication witness
      stateAfterPublication = afterReobserve
      (committed, afterCommit) =
        runInMemoryAuthority
          (commitPublishedAssertion authority published)
          stateAfterPublication
   in SemanticPipeline
        { pipelineAcknowledgement = acknowledgement
        , pipelineStagedState = afterStage
        , pipelineWitness = witness
        , pipelineReobservedState = afterReobserve
        , pipelinePublishedState = stateAfterPublication
        , pipelineCommitted = mustRight committed
        , pipelineCommittedState = afterCommit
        }

continuityBounds :: ContinuityBounds
continuityBounds = mustRight (mkContinuityBounds 32 64 128)

continuityScope :: ContinuityScope
continuityScope =
  mustRight (mkContinuityScope continuityBounds "node-a" "orders-v1-sha256")

authority :: GatewayContinuityAuthority InMemoryAuthority
authority = inMemoryGatewayContinuityAuthority continuityScope

readOnlyBackend
  :: Either EncryptedObjectError (Maybe VersionedLogicalObject)
  -> ContinuityStoreBackend IO
readOnlyBackend observation =
  ContinuityStoreBackend
    { continuityBackendGet = const (pure observation)
    , continuityBackendPutIfAbsent = \_ _ ->
        pure (Left (EncryptedObjectStoreFailed "read-only fake"))
    , continuityBackendPutIfVersion = \_ _ _ ->
        pure (Left (EncryptedObjectStoreFailed "read-only fake"))
    }

genesisDigest :: ContinuityDigest
genesisDigest = mustRight (mkContinuityDigest (BS.replicate 32 7))

initialRecord :: Word64 -> Word64 -> AuthorityRecord
initialRecord epoch sequenceNumber =
  mkInitialAuthorityRecord continuityScope epoch sequenceNumber genesisDigest

readyState :: Word64 -> Word64 -> FakeAuthorityState
readyState epoch sequenceNumber =
  fakeAuthorityPresent (versionAuthorityRecord 0 (initialRecord epoch sequenceNumber))

semanticBytes :: ByteString
semanticBytes = "signed:heartbeat:node-a:1"

semanticAssertion :: SignedSemanticAssertion
semanticAssertion =
  mustRight (mkSignedSemanticAssertion continuityBounds semanticBytes)

anotherSemanticAssertion :: SignedSemanticAssertion
anotherSemanticAssertion =
  mustRight
    (mkSignedSemanticAssertion continuityBounds "signed:heartbeat:node-a:2")

invalidationBytes :: ByteString
invalidationBytes = "signed:invalidate-epoch:node-a"

epochInvalidation :: SignedEpochInvalidation
epochInvalidation =
  mustRight (mkSignedEpochInvalidation continuityBounds invalidationBytes)

runStartup
  :: FakeAuthorityState
  -> (Either ContinuityError StartupRecovery, FakeAuthorityState)
runStartup = runInMemoryAuthority (recoverContinuityAtStartup authority)

versionOf :: Word64 -> AuthorityVersion
versionOf value =
  versionedAuthorityVersion
    (versionAuthorityRecord value (initialRecord 0 0))

mustStoredRecord :: FakeAuthorityState -> AuthorityRecord
mustStoredRecord state =
  case fakeAuthorityStoredRecord state of
    Just versioned -> versionedAuthorityRecord versioned
    Nothing -> error "expected fake authority to contain a record"

mustCurrent :: Either ContinuityError StartupRecovery -> CurrentContinuity
mustCurrent result =
  case result of
    Right (StartupCurrent current) -> current
    other -> error ("expected current continuity, got " ++ show other)

expectCurrentAt
  :: Word64
  -> Word64
  -> Either ContinuityError StartupRecovery
  -> Expectation
expectCurrentAt expectedEpoch expectedSequence result =
  case result of
    Right (StartupCurrent current) -> do
      continuityAnchorEpoch (currentContinuityAnchor current)
        `shouldBe` expectedEpoch
      continuityAnchorSequence (currentContinuityAnchor current)
        `shouldBe` expectedSequence
    other -> expectationFailure ("expected current continuity, got " ++ show other)

expectRepublish
  :: ByteString
  -> Either ContinuityError StartupRecovery
  -> Expectation
expectRepublish expectedBytes result =
  case result of
    Right (StartupRepublish witness) ->
      publicationSignedBytes witness `shouldBe` expectedBytes
    other -> expectationFailure ("expected staged re-publication, got " ++ show other)

isRight :: Either left right -> Bool
isRight value =
  case value of
    Left _ -> False
    Right _ -> True

isJust :: Maybe value -> Bool
isJust value =
  case value of
    Nothing -> False
    Just _ -> True

isDurabilityMismatch
  :: Either ContinuityError DurableStageAcknowledgement
  -> Bool
isDurabilityMismatch result =
  case result of
    Left (ContinuityDurableAcknowledgementMismatch _ _) -> True
    _ -> False

isReobservationMismatch :: Either ContinuityError PublicationWitness -> Bool
isReobservationMismatch result =
  case result of
    Left (ContinuityReobservationMismatch _ _) -> True
    _ -> False

mustRight :: (Show left) => Either left right -> right
mustRight result =
  case result of
    Left err -> error ("expected Right, got " ++ show err)
    Right value -> value
