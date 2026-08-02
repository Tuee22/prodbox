{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneOperationEndpoint (controlPlaneOperationEndpointSuite) where

import Data.IORef
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , decodeControlPlaneRequest
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.OperationEndpoint
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochGenesis
  , nextAuthorityEpoch
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (ClientId)
  , ClientSequence (ClientSequence)
  , RequestDigest (RequestDigest)
  , SubmissionLedger
  , SubmissionStatus (StatusExpired, StatusInFlight, StatusSettled, StatusUnknown)
  , SubmitDecision
    ( SubmissionAccepted
    , SubmissionDuplicate
    , SubmissionRefusedExpired
    , SubmissionRefusedFull
    , SubmissionRefusedSequenceReused
    )
  , TerminalOutcome (OperationCancelledOutcome, OperationCompletedOutcome)
  , cancelSubmission
  , compactClientTerminalsBelow
  , completeSubmission
  , emptySubmissionLedger
  , stepSubmit
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import TestSupport

controlPlaneOperationEndpointSuite :: SuiteBuilder ()
controlPlaneOperationEndpointSuite =
  describe "Sprint 4.50 Lifecycle Authority operation endpoint" $ do
    describe "operations/submit" $ do
      it "accepts a fresh submission and commits the evolved ledger" $ do
        (repository, ledgerRef) <- freshRepository (emptySubmissionLedger 4)
        result <- serveOperationSubmit repository client1 seq1 digestA
        assertAccepted result
        operationSubmitHttpStatus result `shouldBe` 200
        operationSubmitSummary result `shouldBe` "operation-accepted"
        -- The commit landed: the same identity now observes as in-flight.
        state <- readIORef ledgerRef
        serveOperationObserve (readOnlyState state) client1 seq1
          `shouldReturn` OperationObserveFound StatusInFlight
      it "treats an exact resubmission as an idempotent duplicate without committing" $ do
        -- A fail-writes repository proves no commit is attempted: a duplicate that
        -- reached the compare-and-swap would surface as a write failure.
        let repository = failWritesRepository inFlightLedger
        result <- serveOperationSubmit repository client1 seq1 digestA
        case result of
          OperationSubmitDecided (SubmissionDuplicate _) -> pure ()
          other -> expectationFailure ("expected an idempotent duplicate, got " <> show other)
        operationSubmitHttpStatus result `shouldBe` 200
        operationSubmitSummary result `shouldBe` "operation-duplicate"
      it "refuses a reused sequence with a different digest without committing" $ do
        let repository = failWritesRepository inFlightLedger
        result <- serveOperationSubmit repository client1 seq1 digestB
        result `shouldBe` OperationSubmitDecided SubmissionRefusedSequenceReused
        operationSubmitHttpStatus result `shouldBe` 409
        operationSubmitSummary result `shouldBe` "operation-refused-sequence-reused"
      it "refuses a sequence at or below the compacted floor as expired" $ do
        let repository = failWritesRepository (emptySubmissionLedger 4)
        result <- serveOperationSubmit repository client1 seq0 digestA
        result `shouldBe` OperationSubmitDecided SubmissionRefusedExpired
        operationSubmitHttpStatus result `shouldBe` 409
        operationSubmitSummary result `shouldBe` "operation-refused-expired"
      it "refuses a fresh submission at capacity as retryable back-pressure" $ do
        let repository = failWritesRepository (emptySubmissionLedger 0)
        result <- serveOperationSubmit repository client1 seq1 digestA
        result `shouldBe` OperationSubmitDecided SubmissionRefusedFull
        operationSubmitHttpStatus result `shouldBe` 503
        operationSubmitSummary result `shouldBe` "operation-refused-full"
      it "reports a failed durable commit of an accepted submission as retryable" $ do
        let repository = failWritesRepository (emptySubmissionLedger 4)
        result <- serveOperationSubmit repository client1 seq1 digestA
        operationSubmitHttpStatus result `shouldBe` 503
        operationSubmitSummary result `shouldBe` "operation-submit-write-failed"
      it "confirms an applied write after its CAS response is lost" $ do
        stateRef <- newIORef (initialOperationSubmissionState epoch 4)
        revisionRef <- newIORef (0 :: Natural)
        let repository = responseLostRepository stateRef revisionRef
        result <- serveOperationSubmit repository client1 seq1 digestA
        assertAccepted result
        readIORef revisionRef `shouldReturn` 1
        serveOperationObserve repository client1 seq1
          `shouldReturn` OperationObserveFound StatusInFlight
      it "fails retryably when an exact-revision CAS is lost and readback does not confirm" $ do
        let repository = failWritesRepository (emptySubmissionLedger 4)
        result <- serveOperationSubmit repository client1 seq1 digestA
        result `shouldSatisfy` isWriteFailure
        serveOperationObserve repository client1 seq1
          `shouldReturn` OperationObserveFound StatusUnknown
      it "restarts over retained state and returns the same operation without another CAS" $ do
        stateRef <- newIORef (initialOperationSubmissionState epoch 4)
        revisionRef <- newIORef (0 :: Natural)
        casCount <- newIORef (0 :: Natural)
        let firstRepository = countedRepository stateRef revisionRef casCount
        first <- serveOperationSubmit firstRepository client1 seq1 digestA
        assertAccepted first
        -- A fresh repository value simulates a restarted process. It has no
        -- process-local revision/state cache and must converge from readback.
        let restartedRepository = countedRepository stateRef revisionRef casCount
        replay <- serveOperationSubmit restartedRepository client1 seq1 digestA
        case replay of
          OperationSubmitDecided (SubmissionDuplicate duplicate) ->
            case first of
              OperationSubmitDecided (SubmissionAccepted accepted) -> duplicate `shouldBe` accepted
              _ -> expectationFailure "first submission was not accepted"
          other -> expectationFailure ("expected restart duplicate, got " <> show other)
        readIORef casCount `shouldReturn` 1
      it "round-trips a submit payload through the shared request codec" $ do
        let payload = OperationSubmitPayload "c1" 1 "dA"
        decodeControlPlaneRequest 4096 (encodeControlPlaneRequest payload)
          `shouldBe` Right payload
      it "serveOperationSubmitRequest decodes a well-formed body and applies it" $ do
        (repository, ledgerRef) <- freshRepository (emptySubmissionLedger 4)
        let body = encodeControlPlaneRequest (OperationSubmitPayload "c1" 1 "dA")
        result <- serveOperationSubmitRequest 4096 repository body
        assertAccepted result
        operationSubmitHttpStatus result `shouldBe` 200
        state <- readIORef ledgerRef
        serveOperationObserve (readOnlyState state) client1 seq1
          `shouldReturn` OperationObserveFound StatusInFlight
      it "serveOperationSubmitRequest refuses a malformed body before reading state" $ do
        (repository, ledgerRef) <- freshRepository (emptySubmissionLedger 4)
        result <- serveOperationSubmitRequest 4096 repository "not-a-cbor-envelope"
        result `shouldBe` OperationSubmitBadRequest ControlPlaneRequestInvalid
        operationSubmitHttpStatus result `shouldBe` 400
        operationSubmitSummary result `shouldBe` "operation-submit-bad-request:invalid"
        -- Nothing was read or written: the ledger is still the empty fixture.
        state <- readIORef ledgerRef
        serveOperationObserve (readOnlyState state) client1 seq1
          `shouldReturn` OperationObserveFound StatusUnknown
      it "serveOperationSubmitRequest refuses an oversized body before reading state" $ do
        (repository, _) <- freshRepository (emptySubmissionLedger 4)
        let body = encodeControlPlaneRequest (OperationSubmitPayload "c1" 1 "dA")
        result <- serveOperationSubmitRequest 2 repository body
        result `shouldBe` OperationSubmitBadRequest ControlPlaneRequestTooLarge
        operationSubmitHttpStatus result `shouldBe` 400
        operationSubmitSummary result `shouldBe` "operation-submit-bad-request:too-large"
    describe "operations/observe" $ do
      it "observes an in-flight submission as 200 in-flight" $ do
        result <- serveOperationObserve (readOnly inFlightLedger) client1 seq1
        result `shouldBe` OperationObserveFound StatusInFlight
        operationObserveResultHttpStatus result `shouldBe` 200
        operationObserveResultSummary result `shouldBe` "operation-in-flight"
      it "observes a never-seen submission as 404 unknown" $ do
        result <- serveOperationObserve (readOnly (emptySubmissionLedger 4)) client1 seq1
        result `shouldBe` OperationObserveFound StatusUnknown
        operationObserveResultHttpStatus result `shouldBe` 404
        operationObserveResultSummary result `shouldBe` "operation-unknown"
      it "observes a completed submission as 200 settled-completed" $ do
        result <- serveOperationObserve (readOnly (settledLedger completeSubmission)) client1 seq1
        result `shouldBe` OperationObserveFound (StatusSettled OperationCompletedOutcome)
        operationObserveResultHttpStatus result `shouldBe` 200
        operationObserveResultSummary result `shouldBe` "operation-settled-completed"
      it "observes a cancelled submission as 200 settled-cancelled" $ do
        result <- serveOperationObserve (readOnly (settledLedger cancelSubmission)) client1 seq1
        result `shouldBe` OperationObserveFound (StatusSettled OperationCancelledOutcome)
        operationObserveResultSummary result `shouldBe` "operation-settled-cancelled"
      it "observes a compacted-away submission as 200 expired" $ do
        result <- serveOperationObserve (readOnly expiredLedger) client1 seq1
        result `shouldBe` OperationObserveFound StatusExpired
        operationObserveResultHttpStatus result `shouldBe` 200
        operationObserveResultSummary result `shouldBe` "operation-expired"
      it "serveOperationObserveRequest decodes a well-formed body and looks it up" $ do
        let body = encodeControlPlaneRequest (OperationObservePayload "c1" 1)
        serveOperationObserveRequest 4096 (readOnly inFlightLedger) body
          `shouldReturn` OperationObserveFound StatusInFlight
      it "serveOperationObserveRequest refuses a malformed body" $ do
        serveOperationObserveRequest 4096 (readOnly inFlightLedger) "not-a-cbor-envelope"
          `shouldReturn` OperationObserveBadRequest ControlPlaneRequestInvalid
    describe "retained exact-revision repository" $ do
      it "round-trips only the configured epoch/capacity under the bounded canonical codec" $ do
        let state = OperationSubmissionState epoch inFlightLedger
            codec = operationSubmissionStateCodec 4096 epoch 4
            bytes = mustRight (encodeModelBValue codec state)
        decodeModelBValue codec bytes `shouldBe` Right state
        decodeModelBValue (operationSubmissionStateCodec 1 epoch 4) bytes
          `shouldSatisfy` isCodecFailure "OperationSubmissionStateTooLarge"
        decodeModelBValue (operationSubmissionStateCodec 4096 (nextAuthorityEpoch epoch) 4) bytes
          `shouldSatisfy` isCodecFailure "OperationSubmissionStateEpochMismatch"
        encodeModelBValue (operationSubmissionStateCodec 4096 epoch 5) state
          `shouldSatisfy` isCodecFailure "OperationSubmissionStateCapacityMismatch"
      it "initializes missing state then replaces only the exact observed revision" $ do
        observationRef <- newIORef ModelBMissing
        requestsRef <- newIORef []
        versionRef <- newIORef (1 :: Natural)
        let adapter = retainedAdapter observationRef requestsRef versionRef
            repository =
              modelBOperationSubmissionRepository
                (initialOperationSubmissionState epoch 4)
                adapter
                retainedSubmissionCoordinate
        first <- serveOperationSubmit repository client1 seq1 digestA
        assertAccepted first
        second <- serveOperationSubmit repository client1 seq2 digestB
        assertAccepted second
        requests <- reverse <$> readIORef requestsRef
        case requests of
          [ ModelBInitialize initializedCoordinate _
            , ModelBReplace replacedCoordinate expectedRevision _
            ] -> do
              initializedCoordinate `shouldBe` retainedSubmissionCoordinate
              replacedCoordinate `shouldBe` retainedSubmissionCoordinate
              expectedRevision `shouldBe` mustRight (mkModelBObjectVersion "submission-v1")
          other -> expectationFailure ("expected initialize then exact replace, got " <> show other)
 where
  client1 = ClientId "c1"
  seq0 = ClientSequence 0
  seq1 = ClientSequence 1
  seq2 = ClientSequence 2
  digestA = RequestDigest "dA"
  digestB = RequestDigest "dB"
  -- A ledger carrying one in-flight (c1, 1, dA) submission.
  inFlightLedger = snd (stepSubmit authorityEpochGenesis (emptySubmissionLedger 4) client1 seq1 digestA)
  -- The in-flight ledger settled by the given terminal transition.
  settledLedger settle = mustRight (settle client1 seq1 inFlightLedger)
  -- The completed ledger with the floor advanced past (c1, 1) so it reads expired.
  expiredLedger = mustRight (compactClientTerminalsBelow client1 seq1 (settledLedger completeSubmission))
  freshRepository initial = do
    stateRef <- newIORef (OperationSubmissionState epoch initial)
    revisionRef <- newIORef (0 :: Natural)
    casCount <- newIORef (0 :: Natural)
    pure (countedRepository stateRef revisionRef casCount, stateRef)

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id

assertAccepted :: OperationSubmitResult -> IO ()
assertAccepted result = case result of
  OperationSubmitDecided (SubmissionAccepted _) -> pure ()
  other -> expectationFailure ("expected an accepted submission, got " <> show other)

isWriteFailure :: OperationSubmitResult -> Bool
isWriteFailure result = case result of
  OperationSubmitWriteFailed _ -> True
  _ -> False

isCodecFailure :: String -> Either String value -> Bool
isCodecFailure expected result = case result of
  Left detail -> expected `isInfixOf` detail
  Right _ -> False

epoch :: AuthorityEpoch
epoch = authorityEpochGenesis

-- | A repository over mutable retained state with an exact numeric revision.
countedRepository
  :: IORef OperationSubmissionState
  -> IORef Natural
  -> IORef Natural
  -> OperationSubmissionRepository IO Natural
countedRepository stateRef revisionRef casCount =
  OperationSubmissionRepository
    { readSubmissionState = do
        state <- readIORef stateRef
        revision <- readIORef revisionRef
        pure
          ( Right
              OperationSubmissionSnapshot
                { operationSubmissionRevision = revision
                , operationSubmissionSnapshotState = state
                }
          )
    , compareAndSwapSubmissionState = \expected state -> do
        current <- readIORef revisionRef
        if current /= expected
          then pure (Left "retained-store CAS conflict")
          else do
            writeIORef stateRef state
            writeIORef revisionRef (current + 1)
            modifyIORef' casCount (+ 1)
            pure (Right ())
    }

responseLostRepository
  :: IORef OperationSubmissionState
  -> IORef Natural
  -> OperationSubmissionRepository IO Natural
responseLostRepository stateRef revisionRef =
  OperationSubmissionRepository
    { readSubmissionState = do
        state <- readIORef stateRef
        revision <- readIORef revisionRef
        pure (Right (OperationSubmissionSnapshot revision state))
    , compareAndSwapSubmissionState = \expected state -> do
        current <- readIORef revisionRef
        if current /= expected
          then pure (Left "retained-store CAS conflict")
          else do
            writeIORef stateRef state
            writeIORef revisionRef (current + 1)
            pure (Left "CAS response lost after apply")
    }

-- | A repository over a fixed ledger whose compare-and-swap always fails; proves
-- that duplicates and refusals never reach the commit path.
failWritesRepository :: SubmissionLedger -> OperationSubmissionRepository IO Natural
failWritesRepository ledger =
  OperationSubmissionRepository
    { readSubmissionState =
        pure
          ( Right
              ( OperationSubmissionSnapshot
                  0
                  (OperationSubmissionState epoch ledger)
              )
          )
    , compareAndSwapSubmissionState = \_ _ -> pure (Left "retained-store commit failed")
    }

-- | A read-only repository over a fixed ledger for the observe path.
readOnly :: SubmissionLedger -> OperationSubmissionRepository IO Natural
readOnly ledger = readOnlyState (OperationSubmissionState epoch ledger)

readOnlyState :: OperationSubmissionState -> OperationSubmissionRepository IO Natural
readOnlyState state =
  OperationSubmissionRepository
    { readSubmissionState = pure (Right (OperationSubmissionSnapshot 0 state))
    , compareAndSwapSubmissionState = \_ _ -> pure (Left "read-only repository")
    }

retainedAdapter
  :: IORef (ModelBObservation OperationSubmissionState)
  -> IORef [ModelBCasRequest 'ClusterRetained OperationSubmissionState]
  -> IORef Natural
  -> ModelBCasAdapter 'ClusterRetained IO OperationSubmissionState
retainedAdapter observationRef requestsRef versionRef =
  ModelBCasAdapter
    { modelBObserve = \_ -> readIORef observationRef
    , modelBCompareAndSwap = \request -> do
        modifyIORef' requestsRef (request :)
        versionNumber <- readIORef versionRef
        let version =
              mustRight
                (mkModelBObjectVersion ("submission-v" <> Text.pack (show versionNumber)))
            state = requestState request
        writeIORef observationRef (ModelBObserved version state)
        writeIORef versionRef (versionNumber + 1)
        pure (ModelBCasApplied version state)
    }

requestState :: ModelBCasRequest lifetime OperationSubmissionState -> OperationSubmissionState
requestState request = case request of
  ModelBInitialize _ state -> state
  ModelBReplace _ _ state -> state
  ModelBInitializeGuarded _ _ state -> state
  ModelBReplaceGuarded _ _ _ state -> state

retainedSubmissionCoordinate :: ModelBObjectCoordinate 'ClusterRetained
retainedSubmissionCoordinate =
  mustRight
    (mkClusterRetainedCoordinate retainedAuthority "authority/operation-submissions")

retainedAuthority :: LongLivedCheckpointAuthority
retainedAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home"
        "prodbox-state"
        "authority"
        "secret/lifecycle"
    )
