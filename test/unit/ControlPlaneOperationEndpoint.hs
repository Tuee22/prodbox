{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneOperationEndpoint (controlPlaneOperationEndpointSuite) where

import Data.IORef
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , decodeControlPlaneRequest
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.OperationEndpoint
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch, authorityEpochGenesis)
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
        ledger <- readIORef ledgerRef
        serveOperationObserve (readOnly ledger) client1 seq1 `shouldReturn` StatusInFlight
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
        ledger <- readIORef ledgerRef
        serveOperationObserve (readOnly ledger) client1 seq1 `shouldReturn` StatusInFlight
      it "serveOperationSubmitRequest refuses a malformed body before reading state" $ do
        (repository, ledgerRef) <- freshRepository (emptySubmissionLedger 4)
        result <- serveOperationSubmitRequest 4096 repository "not-a-cbor-envelope"
        result `shouldBe` OperationSubmitBadRequest ControlPlaneRequestInvalid
        operationSubmitHttpStatus result `shouldBe` 400
        operationSubmitSummary result `shouldBe` "operation-submit-bad-request:invalid"
        -- Nothing was read or written: the ledger is still the empty fixture.
        ledger <- readIORef ledgerRef
        serveOperationObserve (readOnly ledger) client1 seq1 `shouldReturn` StatusUnknown
      it "serveOperationSubmitRequest refuses an oversized body before reading state" $ do
        (repository, _) <- freshRepository (emptySubmissionLedger 4)
        let body = encodeControlPlaneRequest (OperationSubmitPayload "c1" 1 "dA")
        result <- serveOperationSubmitRequest 2 repository body
        result `shouldBe` OperationSubmitBadRequest ControlPlaneRequestTooLarge
        operationSubmitHttpStatus result `shouldBe` 400
        operationSubmitSummary result `shouldBe` "operation-submit-bad-request:too-large"
    describe "operations/observe" $ do
      it "observes an in-flight submission as 200 in-flight" $ do
        status <- serveOperationObserve (readOnly inFlightLedger) client1 seq1
        status `shouldBe` StatusInFlight
        operationObserveHttpStatus status `shouldBe` 200
        operationObserveSummary status `shouldBe` "operation-in-flight"
      it "observes a never-seen submission as 404 unknown" $ do
        status <- serveOperationObserve (readOnly (emptySubmissionLedger 4)) client1 seq1
        status `shouldBe` StatusUnknown
        operationObserveHttpStatus status `shouldBe` 404
        operationObserveSummary status `shouldBe` "operation-unknown"
      it "observes a completed submission as 200 settled-completed" $ do
        status <- serveOperationObserve (readOnly (settledLedger completeSubmission)) client1 seq1
        status `shouldBe` StatusSettled OperationCompletedOutcome
        operationObserveHttpStatus status `shouldBe` 200
        operationObserveSummary status `shouldBe` "operation-settled-completed"
      it "observes a cancelled submission as 200 settled-cancelled" $ do
        status <- serveOperationObserve (readOnly (settledLedger cancelSubmission)) client1 seq1
        status `shouldBe` StatusSettled OperationCancelledOutcome
        operationObserveSummary status `shouldBe` "operation-settled-cancelled"
      it "observes a compacted-away submission as 200 expired" $ do
        status <- serveOperationObserve (readOnly expiredLedger) client1 seq1
        status `shouldBe` StatusExpired
        operationObserveHttpStatus status `shouldBe` 200
        operationObserveSummary status `shouldBe` "operation-expired"
      it "serveOperationObserveRequest decodes a well-formed body and looks it up" $ do
        let body = encodeControlPlaneRequest (OperationObservePayload "c1" 1)
        serveOperationObserveRequest 4096 (readOnly inFlightLedger) body
          `shouldReturn` Right StatusInFlight
      it "serveOperationObserveRequest refuses a malformed body" $ do
        serveOperationObserveRequest 4096 (readOnly inFlightLedger) "not-a-cbor-envelope"
          `shouldReturn` Left ControlPlaneRequestInvalid
 where
  client1 = ClientId "c1"
  seq0 = ClientSequence 0
  seq1 = ClientSequence 1
  digestA = RequestDigest "dA"
  digestB = RequestDigest "dB"
  -- A ledger carrying one in-flight (c1, 1, dA) submission.
  inFlightLedger = snd (stepSubmit authorityEpochGenesis (emptySubmissionLedger 4) client1 seq1 digestA)
  -- The in-flight ledger settled by the given terminal transition.
  settledLedger settle = mustRight (settle client1 seq1 inFlightLedger)
  -- The completed ledger with the floor advanced past (c1, 1) so it reads expired.
  expiredLedger = mustRight (compactClientTerminalsBelow client1 seq1 (settledLedger completeSubmission))
  freshRepository initial = do
    ledgerRef <- newIORef initial
    pure (inMemoryRepository ledgerRef, ledgerRef)

mustRight :: (Show e) => Either e a -> a
mustRight = either (error . show) id

assertAccepted :: OperationSubmitResult -> IO ()
assertAccepted result = case result of
  OperationSubmitDecided (SubmissionAccepted _) -> pure ()
  other -> expectationFailure ("expected an accepted submission, got " <> show other)

epoch :: AuthorityEpoch
epoch = authorityEpochGenesis

-- | A repository over a mutable ledger whose compare-and-swap succeeds.
inMemoryRepository :: IORef SubmissionLedger -> OperationSubmissionRepository IO
inMemoryRepository ledgerRef =
  OperationSubmissionRepository
    { readSubmissionState = do
        ledger <- readIORef ledgerRef
        pure (epoch, ledger)
    , commitSubmissionLedger = \ledger -> do
        writeIORef ledgerRef ledger
        pure (Right ())
    }

-- | A repository over a fixed ledger whose compare-and-swap always fails; proves
-- that duplicates and refusals never reach the commit path.
failWritesRepository :: SubmissionLedger -> OperationSubmissionRepository IO
failWritesRepository ledger =
  OperationSubmissionRepository
    { readSubmissionState = pure (epoch, ledger)
    , commitSubmissionLedger = \_ -> pure (Left "retained-store commit failed")
    }

-- | A read-only repository over a fixed ledger for the observe path.
readOnly :: SubmissionLedger -> OperationSubmissionRepository IO
readOnly ledger =
  OperationSubmissionRepository
    { readSubmissionState = pure (epoch, ledger)
    , commitSubmissionLedger = \_ -> pure (Left "read-only repository")
    }
