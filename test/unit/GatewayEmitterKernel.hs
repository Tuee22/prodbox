{-# LANGUAGE OverloadedStrings #-}

module GatewayEmitterKernel
  ( gatewayEmitterKernelSuite
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , RemainingDuration (..)
  , RetryAfter (..)
  , deadlineAtOffset
  , monotonicInstantFromMicros
  )
import Prodbox.Gateway.Continuity
  ( ContinuityAnchor
  , ContinuityDigest
  , authorityRecordCommittedAnchor
  , continuityAnchorEpoch
  , continuityAnchorPreviousDigest
  , continuityAnchorSequence
  , continuityDigestBytes
  , mkContinuityBounds
  , mkContinuityDigest
  , mkContinuityScope
  , mkInitialAuthorityRecord
  )
import Prodbox.Gateway.Emitter.Kernel
import Prodbox.Gateway.Emitter.Mailbox
import Test.Tasty.QuickCheck (Gen, elements, forAll, listOf)
import TestSupport

zeroDigest :: ContinuityDigest
zeroDigest = either (error . show) id (mkContinuityDigest (BS.replicate 32 0))

ordersDigestA :: ContinuityDigest
ordersDigestA = either (error . show) id (mkContinuityDigest (BS.replicate 32 0xA1))

ordersDigestB :: ContinuityDigest
ordersDigestB = either (error . show) id (mkContinuityDigest (BS.replicate 32 0xB2))

anchorAt :: Word64 -> Word64 -> ContinuityAnchor
anchorAt epoch sequenceNumber =
  let bounds = either (error . show) id (mkContinuityBounds 256 256 4096)
      scope = either (error . show) id (mkContinuityScope bounds "emitter-a" (BS.pack [1, 2, 3]))
   in authorityRecordCommittedAnchor
        (mkInitialAuthorityRecord scope epoch sequenceNumber zeroDigest)

deadlineAfter :: Word64 -> Deadline
deadlineAfter budget =
  deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration (fromIntegral budget))

boundedPayload :: ByteString -> BoundedSignedPayload
boundedPayload bytes =
  either (error . show) id (mkBoundedSignedPayload 4096 bytes)

capacity3 :: MailboxCapacity
capacity3 = maybe (error "capacity") id (mkMailboxCapacity 3)

freshMailbox :: MailboxCapacity -> Mailbox
freshMailbox cap = emptyMailbox cap (RetryAfter 1000)

peerA :: EmitterPeer
peerA = maybe (error "peer-a") id (mkEmitterPeer "peer-a")

peerB :: EmitterPeer
peerB = maybe (error "peer-b") id (mkEmitterPeer "peer-b")

peerC :: EmitterPeer
peerC = maybe (error "peer-c") id (mkEmitterPeer "peer-c")

initialState :: Natural -> EmitterState
initialState threshold =
  mkEmitterStateForPeers
    (anchorAt 0 0)
    incarnationZero
    (freshMailbox capacity3)
    threshold
    [peerA, peerB]

runIntents :: EmitterState -> [EmitterIntent] -> (EmitterState, [[EmitterEffect]], [StepOutcome])
runIntents st0 = foldl go (st0, [], [])
 where
  go (st, effs, outs) intent =
    let result = step st intent
     in (stepState result, effs ++ [stepEffects result], outs ++ [stepOutcome result])

driveRequestToCommit
  :: EmitterState
  -> EmitterRequest
  -> ByteString
  -> (EmitterState, [EmitterEffect])
driveRequestToCommit st0 request signedBytes =
  let submitted = step st0 (SubmitRequest request)
      begun = step (stepState submitted) (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
      (finalized, transitionEffects) =
        driveCurrentToCommit (stepState begun) signedBytes
      effects = stepEffects submitted ++ stepEffects begun ++ transitionEffects
   in (finalized, effects)

driveCurrentToCommit :: EmitterState -> ByteString -> (EmitterState, [EmitterEffect])
driveCurrentToCommit begun signedBytes =
  let staged = resolveCurrentStage begun (StageStaged (boundedPayload signedBytes))
      published = advanceCurrentPhase (stepState staged) DidFsyncStage
      committed = advanceCurrentPhase (stepState published) DidPublish
      finalizing = advanceCurrentPhase (stepState committed) DidCommit
      finalized = advanceCurrentPhase (stepState finalizing) DidFsyncCommit
   in ( stepState finalized
      , concatMap stepEffects [staged, published, committed, finalizing, finalized]
      )

currentInFlight :: EmitterState -> InFlight
currentInFlight st = case emitterInFlight st of
  Nothing -> error "expected an in-flight transition"
  Just inflight -> inflight

currentStagedRecord :: EmitterState -> StagedRecord
currentStagedRecord st = case inFlightStagedRecord (currentInFlight st) of
  Nothing -> error "expected an exact staged record"
  Just record -> record

resolveCurrentStage :: EmitterState -> StageOutcome -> EmitterStep
resolveCurrentStage st outcome =
  let inflight = currentInFlight st
   in step
        st
        ( StageResolved
            (inFlightIncarnation inflight)
            (inFlightAdmission inflight)
            outcome
        )

advanceCurrentPhase :: EmitterState -> PhaseCompletion -> EmitterStep
advanceCurrentPhase st completion =
  let inflight = currentInFlight st
   in step
        st
        ( PhaseAdvanced
            (inFlightIncarnation inflight)
            (inFlightAdmission inflight)
            (currentStagedRecord st)
            completion
        )

driveOwnershipToCommit
  :: EmitterState
  -> ByteString
  -> (EmitterState, [EmitterEffect])
driveOwnershipToCommit st bytes =
  driveRequestToCommit st (ReqOwnership OwnershipClaim) bytes

genRequest :: Gen EmitterRequest
genRequest =
  elements
    [ ReqHeartbeat (HeartbeatPayload 1)
    , ReqHeartbeat (HeartbeatPayload 2)
    , ReqOwnership OwnershipClaim
    , ReqOwnership OwnershipYield
    , ReqEpochRotation
    , ReqRecover
    ]

foldSubmits :: MailboxCapacity -> [EmitterRequest] -> Mailbox
foldSubmits cap = foldl submitOne (freshMailbox cap)
 where
  submitOne mailbox request = case enqueue mailbox request of
    EnqueueAccepted mailbox' -> mailbox'
    EnqueueCoalesced mailbox' -> mailbox'
    EnqueueRejected _ -> mailbox

heartbeatCount :: Mailbox -> Int
heartbeatCount mailbox = length [() | ReqHeartbeat _ <- mailboxRequests mailbox]

gatewayEmitterKernelSuite :: SuiteBuilder ()
gatewayEmitterKernelSuite =
  describe "Sprint 2.32 single-writer emitter kernel" $ do
    describe "bounded mailbox" $ do
      it "rejects a non-coalescible request when full" $ do
        let full = foldSubmits capacity3 (replicate 3 (ReqOwnership OwnershipClaim))
        enqueue full (ReqOwnership OwnershipYield)
          `shouldBe` EnqueueRejected (RetryAfter 1000)
      it "coalesces heartbeats to the latest without losing ownership" $ do
        let mailbox =
              foldSubmits
                capacity3
                [ ReqHeartbeat (HeartbeatPayload 1)
                , ReqOwnership OwnershipClaim
                , ReqHeartbeat (HeartbeatPayload 3)
                ]
        mailboxDepth mailbox `shouldBe` 2
        mailboxPendingHeartbeat mailbox `shouldBe` Just (HeartbeatPayload 3)
        [transition | ReqOwnership transition <- mailboxRequests mailbox]
          `shouldBe` [OwnershipClaim]
      it "keeps the freshest heartbeat when observations arrive out of order" $ do
        let mailbox =
              foldSubmits
                capacity3
                [ ReqHeartbeat (HeartbeatPayload 9)
                , ReqOwnership OwnershipClaim
                , ReqHeartbeat (HeartbeatPayload 4)
                ]
        mailboxPendingHeartbeat mailbox `shouldBe` Just (HeartbeatPayload 9)
      propertyTest "depth stays bounded and at most one heartbeat pends" $
        forAll (listOf genRequest) $ \requests ->
          let mailbox = foldSubmits capacity3 requests
           in mailboxDepth mailbox <= mailboxCapacityValue capacity3
                && heartbeatCount mailbox <= 1

    describe "durable exact-payload pipeline" $ do
      it "routes a heartbeat through stage/fsync/publish/commit/fsync" $ do
        let payload = HeartbeatPayload 4242
            bytes = BS.pack [9, 8, 7, 6]
            st0 = initialState 8
            (st', effects) =
              driveRequestToCommit st0 (ReqHeartbeat payload) bytes
        continuityAnchorSequence (emitterCommittedAnchor st') `shouldBe` 1
        map effectTag effects
          `shouldBe` ["stage", "fsync-stage", "publish", "commit", "fsync-commit"]
        [stagePlanKind plan | EffStage _ _ plan <- effects]
          `shouldBe` [KindHeartbeat payload]
        postSignBytes effects `shouldBe` replicate 4 bytes
        fmap stagedRecordSignedBytes (emitterLatestCommitted st') `shouldBe` Just bytes
      it "threads one admission, deadline, staged record, and derived anchor unchanged" $ do
        let bytes = BS.pack [1 .. 32]
            st0 = initialState 8
            (st', effects) = driveOwnershipToCommit st0 bytes
            admissions = [admission | Just admission <- map effectAdmission effects]
            records = effectRecords effects
        length admissions `shouldBe` 5
        allEqual admissions `shouldBe` True
        length records `shouldBe` 4
        allEqual records `shouldBe` True
        fmap stagedRecordNextAnchor (firstRecord records)
          `shouldBe` Just (emitterCommittedAnchor st')
      it "rejects an empty signed result without advancing the phase" $ do
        let st0 = initialState 8
            (begun, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000)
                ]
        mkBoundedSignedPayload 4096 BS.empty `shouldBe` Left SignedPayloadMustNotBeEmpty
        mkBoundedSignedPayload 2 (BS.pack [1, 2, 3])
          `shouldBe` Left (SignedPayloadBytesExceeded 3 2)
        fmap inFlightPhase (emitterInFlight begun) `shouldBe` Just PhaseStaging

    describe "single writer and replay" $ do
      it "a pump while busy starts no second transition" $ do
        let st0 = initialState 8
            now = monotonicInstantFromMicros 0
            (st1, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump now (deadlineAfter 1000)
                ]
            (_, effects, outcomes) =
              runIntents
                st1
                [ SubmitRequest (ReqOwnership OwnershipYield)
                , Pump now (deadlineAfter 1000)
                ]
        concat effects `shouldBe` []
        lastElement "mailbox outcome" outcomes `shouldBe` OutcomeNoOp
      it "an identical stage callback and passed completion are idempotent" $ do
        let bytes = BS.pack [4, 5, 6]
            st0 = initialState 8
            inc = emitterIncarnation st0
            (begun, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000)
                ]
            admission = inFlightAdmission (currentInFlight begun)
            staged = resolveCurrentStage begun (StageStaged (boundedPayload bytes))
            record = currentStagedRecord (stepState staged)
            publishing = advanceCurrentPhase (stepState staged) DidFsyncStage
            stageReplay =
              step
                (stepState publishing)
                (StageResolved inc admission (StageStaged (boundedPayload bytes)))
            phaseReplay =
              step
                (stepState publishing)
                (PhaseAdvanced inc admission record DidFsyncStage)
        stepOutcome stageReplay `shouldBe` OutcomeNoOp
        stepOutcome phaseReplay `shouldBe` OutcomeNoOp
        stepEffects stageReplay `shouldBe` []
        stepEffects phaseReplay `shouldBe` []
      it "rejects a replay that substitutes different signed bytes" $ do
        let st0 = initialState 8
            inc = emitterIncarnation st0
            (begun, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000)
                ]
            admission = inFlightAdmission (currentInFlight begun)
            staged = resolveCurrentStage begun (StageStaged (boundedPayload (BS.pack [1])))
            conflict =
              step
                (stepState staged)
                (StageResolved inc admission (StageStaged (boundedPayload (BS.pack [2]))))
        stepOutcome conflict `shouldBe` OutcomeRejected RejectUnexpectedCompletion
      it "rejects delayed same-incarnation completions from an older admission" $ do
        let (firstCommitted, firstEffects) =
              driveOwnershipToCommit (initialState 8) (BS.pack [3])
            oldAdmission = firstAdmission firstEffects
            oldRecord = lastElement "first staged record" (effectRecords firstEffects)
            submitted = step firstCommitted (SubmitRequest (ReqOwnership OwnershipYield))
            begun =
              step
                (stepState submitted)
                (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
            secondState = stepState begun
            secondInFlight = currentInFlight secondState
            secondAdmission = inFlightAdmission secondInFlight
            incarnation = emitterIncarnation secondState
            staleStage =
              step
                secondState
                ( StageResolved
                    incarnation
                    oldAdmission
                    (StageStaged (boundedPayload (BS.pack [4])))
                )
            stagedSecond =
              resolveCurrentStage secondState (StageStaged (boundedPayload (BS.pack [4])))
            stalePhase =
              step
                (stepState stagedSecond)
                (PhaseAdvanced incarnation oldAdmission oldRecord DidFsyncStage)
            wrongRecord =
              step
                (stepState stagedSecond)
                (PhaseAdvanced incarnation secondAdmission oldRecord DidFsyncStage)
        stepOutcome staleStage
          `shouldBe` OutcomeRejected (RejectStaleAdmission secondAdmission oldAdmission)
        stepState staleStage `shouldBe` secondState
        stepEffects staleStage `shouldBe` []
        stepOutcome stalePhase
          `shouldBe` OutcomeRejected (RejectStaleAdmission secondAdmission oldAdmission)
        stepOutcome wrongRecord `shouldBe` OutcomeRejected RejectUnexpectedCompletion

    describe "recovery and deadlines" $ do
      it "a mailbox recovery request re-drives the exact current phase" $ do
        let bytes = BS.pack [11, 12]
            st0 = initialState 8
            (begun, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000)
                ]
            staged = resolveCurrentStage begun (StageStaged (boundedPayload bytes))
            withRecovery = step (stepState staged) (SubmitRequest ReqRecover)
            recovered =
              step
                (stepState withRecovery)
                (Pump (monotonicInstantFromMicros 1) (deadlineAfter 2000))
        map effectTag (stepEffects recovered) `shouldBe` ["fsync-stage"]
        postSignBytes (stepEffects recovered) `shouldBe` [bytes]
        mailboxDepth (emitterMailbox (stepState recovered)) `shouldBe` 0
        fmap inFlightDeadline (emitterInFlight (stepState recovered))
          `shouldBe` Just (deadlineAfter 2000)
      it "prioritizes recovery behind normal mailbox work" $ do
        let bytes = BS.pack [13, 14]
            st0 = initialState 8
            begun =
              stepState
                ( step
                    (stepState (step st0 (SubmitRequest (ReqOwnership OwnershipClaim))))
                    (Pump (monotonicInstantFromMicros 0) (deadlineAfter 100))
                )
            staged = stepState (resolveCurrentStage begun (StageStaged (boundedPayload bytes)))
            normalQueued = stepState (step staged (SubmitRequest (ReqOwnership OwnershipYield)))
            recoverQueued = stepState (step normalQueued (SubmitRequest ReqRecover))
            recovered =
              step
                recoverQueued
                (Pump (monotonicInstantFromMicros 200) (deadlineAfter 1000))
        map effectTag (stepEffects recovered) `shouldBe` ["fsync-stage"]
        postSignBytes (stepEffects recovered) `shouldBe` [bytes]
        mailboxRequests (emitterMailbox (stepState recovered))
          `shouldBe` [ReqOwnership OwnershipYield]
      it "aborts only an unsigned staging attempt at deadline" $ do
        let st0 = initialState 8
            (begun, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump (monotonicInstantFromMicros 0) (deadlineAfter 100)
                ]
            expired = step begun (Pump (monotonicInstantFromMicros 200) (deadlineAfter 100))
        stepOutcome expired `shouldBe` OutcomeRejected RejectDeadlineExpired
        emitterInFlight (stepState expired) `shouldBe` Nothing
      it "retries unsigned recovered work under a fresh admission" $ do
        let st0 = initialState 8
            begun =
              stepState
                ( step
                    (stepState (step st0 (SubmitRequest (ReqHeartbeat (HeartbeatPayload 88)))))
                    (Pump (monotonicInstantFromMicros 0) (deadlineAfter 100))
                )
            oldAdmission = inFlightAdmission (currentInFlight begun)
            recovered =
              step
                begun
                (Recover (monotonicInstantFromMicros 200) (deadlineAfter 1000))
            newAdmission = onlyAdmission (stepEffects recovered)
        transitionAdmissionValue newAdmission
          `shouldBe` (transitionAdmissionValue oldAdmission + 1)
        [stagePlanKind plan | EffStage _ _ plan <- stepEffects recovered]
          `shouldBe` [KindHeartbeat (HeartbeatPayload 88)]
      it "retains exact staged bytes across a pre-publish deadline and mount change" $ do
        let bytes = BS.pack [21, 22, 23]
            st0 = initialState 8
            oldInc = emitterIncarnation st0
            (begun, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump (monotonicInstantFromMicros 0) (deadlineAfter 100)
                ]
            staged = resolveCurrentStage begun (StageStaged (boundedPayload bytes))
            held = step (stepState staged) (Pump (monotonicInstantFromMicros 200) (deadlineAfter 100))
            remounted = either (error . show) id (advanceIncarnation (stepState held))
            newInc = emitterIncarnation remounted
            remountedInFlight = currentInFlight remounted
            record = currentStagedRecord remounted
            stale =
              step
                remounted
                ( PhaseAdvanced
                    oldInc
                    (inFlightAdmission remountedInFlight)
                    record
                    DidFsyncStage
                )
            recoveryDeadline = deadlineAfter 1000
            recovered =
              step remounted (Recover (monotonicInstantFromMicros 300) recoveryDeadline)
        emitterInFlight (stepState held) `shouldNotBe` Nothing
        stepOutcome stale
          `shouldBe` OutcomeRejected (RejectStaleIncarnation newInc oldInc)
        postSignBytes (stepEffects recovered) `shouldBe` [bytes]
        fmap inFlightDeadline (emitterInFlight (stepState recovered))
          `shouldBe` Just recoveryDeadline
      it "rewinds every signed recovery phase to the durable stage boundary" $ do
        let bytes = BS.pack [26, 27, 28]
            begun =
              stepState
                ( step
                    (stepState (step (initialState 8) (SubmitRequest (ReqOwnership OwnershipClaim))))
                    (Pump (monotonicInstantFromMicros 0) (deadlineAfter 100))
                )
            fsyncingStage =
              stepState (resolveCurrentStage begun (StageStaged (boundedPayload bytes)))
            publishing = stepState (advanceCurrentPhase fsyncingStage DidFsyncStage)
            committing = stepState (advanceCurrentPhase publishing DidPublish)
            fsyncingCommit = stepState (advanceCurrentPhase committing DidCommit)
            record = currentStagedRecord fsyncingStage
            admission = inFlightAdmission (currentInFlight fsyncingStage)
            recoveryDeadline = deadlineAfter 2000
            signedPhases = [fsyncingStage, publishing, committing, fsyncingCommit]
        map (inFlightPhase . currentInFlight) signedPhases
          `shouldBe` [PhaseFsyncingStage, PhasePublishing, PhaseCommitting, PhaseFsyncingCommit]
        mapM_
          ( \phaseState -> do
              let recovered =
                    step
                      phaseState
                      (Recover (monotonicInstantFromMicros 200) recoveryDeadline)
                  recoveredInFlight = currentInFlight (stepState recovered)
              inFlightPhase recoveredInFlight `shouldBe` PhaseFsyncingStage
              inFlightPublished recoveredInFlight `shouldBe` False
              inFlightDeadline recoveredInFlight `shouldBe` recoveryDeadline
              inFlightStagedRecord recoveredInFlight `shouldBe` Just record
              stepEffects recovered
                `shouldBe` [EffFsyncStage admission recoveryDeadline record]
          )
          signedPhases
      it "restores retained authority before re-fsyncing and republishing an ahead assertion" $ do
        let committedA = commitWith 29 (initialState 8)
            bytesA =
              maybe
                (error "missing committed A")
                stagedRecordSignedBytes
                (emitterLatestCommitted committedA)
            stagingB =
              stepState
                ( step
                    (stepState (step committedA (SubmitRequest (ReqOwnership OwnershipYield))))
                    (Pump (monotonicInstantFromMicros 0) (deadlineAfter 100))
                )
            fsyncingB =
              stepState
                (resolveCurrentStage stagingB (StageStaged (boundedPayload (BS.pack [30]))))
            publishingB = stepState (advanceCurrentPhase fsyncingB DidFsyncStage)
            committingB = stepState (advanceCurrentPhase publishingB DidPublish)
            recordB = currentStagedRecord committingB
            admissionB = inFlightAdmission (currentInFlight committingB)
            recoveryDeadline = deadlineAfter 3000
            recovered =
              step
                committingB
                (Recover (monotonicInstantFromMicros 200) recoveryDeadline)
        case stepEffects recovered of
          [ EffRestoreRetained _ replayDeadline replay
            , EffFsyncStage replayAdmission fsyncDeadline replayedB
            ] -> do
              replayDeadline `shouldBe` recoveryDeadline
              replayAdmission `shouldBe` admissionB
              fsyncDeadline `shouldBe` recoveryDeadline
              map stagedRecordSignedBytes (recoveryReplayAssertions replay)
                `shouldBe` [bytesA]
              replayedB `shouldBe` recordB
          effects ->
            expectationFailure
              ("unexpected retained-authority recovery order: " ++ show effects)
        let rewound = currentInFlight (stepState recovered)
        inFlightPhase rewound `shouldBe` PhaseFsyncingStage
        inFlightPublished rewound `shouldBe` False

    describe "counter overflow and rotation" $ do
      it "starts without retained previous-Orders evidence" $ do
        let fresh = initialState 8
            projection = projectDurableEmitterState fresh
        emitterPreviousOrdersDigest fresh `shouldBe` Nothing
        durableProjectionPreviousOrdersDigest projection `shouldBe` Nothing
      it "fences incarnation overflow instead of wrapping" $ do
        let st0 =
              mkEmitterState
                (anchorAt 0 0)
                (mkIncarnation maxBound)
                (freshMailbox capacity3)
                8
        advanceIncarnation st0 `shouldBe` Left RejectIncarnationExhausted
      it "rebases a stale inner projection across repeated journal mount crashes" $ do
        let st0 =
              mkEmitterStateForPeers
                (anchorAt 0 0)
                (mkIncarnation 1)
                (freshMailbox capacity3)
                8
                [peerA]
            begun =
              stepState
                ( step
                    (stepState (step st0 (SubmitRequest (ReqOwnership OwnershipClaim))))
                    (Pump (monotonicInstantFromMicros 0) (deadlineAfter 100))
                )
            staged =
              stepState
                (resolveCurrentStage begun (StageStaged (boundedPayload (BS.pack [24, 25]))))
            originalInFlight = currentInFlight staged
            originalRecord = currentStagedRecord staged
            firstMount =
              either (error . show) id (rebaseEmitterIncarnation (mkIncarnation 2) staged)
            -- Crash before the rebased projection is fsynced: the next mount
            -- sees the same incarnation-1 inner projection but journal mount 3.
            repeatedMount =
              either (error . show) id (rebaseEmitterIncarnation (mkIncarnation 3) staged)
            repeatedInFlight = currentInFlight repeatedMount
        emitterIncarnation firstMount `shouldBe` mkIncarnation 2
        emitterIncarnation repeatedMount `shouldBe` mkIncarnation 3
        inFlightIncarnation repeatedInFlight `shouldBe` mkIncarnation 3
        inFlightAdmission repeatedInFlight `shouldBe` inFlightAdmission originalInFlight
        inFlightStagedRecord repeatedInFlight `shouldBe` Just originalRecord
        stagedRecordIncarnation (currentStagedRecord repeatedMount) `shouldBe` mkIncarnation 1
        rebaseEmitterIncarnation (mkIncarnation 3) repeatedMount `shouldBe` Right repeatedMount
        rebaseEmitterIncarnation incarnationZero repeatedMount `shouldBe` Left RejectZeroIncarnation
        rebaseEmitterIncarnation (mkIncarnation 2) repeatedMount
          `shouldBe` Left (RejectIncarnationRegression (mkIncarnation 3) (mkIncarnation 2))
      it "uses the final admission once, then rejects further work" $ do
        let st0 =
              mkEmitterStateRestored
                (anchorAt 0 0)
                incarnationZero
                (freshMailbox capacity3)
                8
                []
                (Just maxBound)
            (st1, effects) = driveOwnershipToCommit st0 (BS.pack [31])
            submitted = step st1 (SubmitRequest (ReqOwnership OwnershipYield))
            rejected =
              step
                (stepState submitted)
                (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
        transitionAdmissionValue (firstAdmission effects) `shouldBe` maxBound
        stepOutcome rejected `shouldBe` OutcomeRejected RejectAdmissionExhausted
      it "parks an unsigned heartbeat, rotates, then re-signs it under a fresh ticket" $ do
        let payload = HeartbeatPayload 99
            st0 =
              mkEmitterStateForPeers
                (anchorAt 7 maxBound)
                incarnationZero
                (freshMailbox capacity3)
                8
                [peerA]
            inc = emitterIncarnation st0
            (begun, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqHeartbeat payload)
                , Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000)
                ]
            admission = inFlightAdmission (currentInFlight begun)
            parked =
              stepState (step begun (StageResolved inc admission StageNeedsRotation))
        emitterPending parked
          `shouldBe` Just (PendingRotationThenAdvance (PendingHeartbeat payload))
        let rotationBegin = step parked (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
            rotationAdmission = onlyAdmission (stepEffects rotationBegin)
            (rotated, _) =
              driveCurrentToCommit (stepState rotationBegin) (BS.pack [41])
            heartbeatBegin =
              step rotated (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
            heartbeatAdmission = onlyAdmission (stepEffects heartbeatBegin)
        continuityAnchorEpoch (emitterCommittedAnchor rotated) `shouldBe` 8
        continuityAnchorSequence (emitterCommittedAnchor rotated) `shouldBe` 0
        emitterPending rotated `shouldBe` Just (PendingAdvance (PendingHeartbeat payload))
        transitionAdmissionValue heartbeatAdmission
          `shouldBe` (transitionAdmissionValue rotationAdmission + 1)
        [stagePlanKind plan | EffStage _ _ plan <- stepEffects heartbeatBegin]
          `shouldBe` [KindHeartbeat payload]
      it "treats an externally requested rotation as a no-op" $ do
        let st0 = initialState 8
            (_, effects, outcomes) =
              runIntents
                st0
                [ SubmitRequest ReqEpochRotation
                , Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000)
                ]
        concat effects `shouldBe` []
        lastElement "rotation outcome" outcomes `shouldBe` OutcomeNoOp
      it "migrates Orders by clearing old signatures and forcing a newly fenced rotation" $ do
        let oldCommitted = commitWith 41 (initialState 8)
            oldBegun =
              stepState
                ( step
                    (stepState (step oldCommitted (SubmitRequest (ReqOwnership OwnershipYield))))
                    (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
                )
            oldInFlight = currentInFlight oldBegun
            target = mkIncarnation 2
            migrate =
              migrateEmitterOrders
                zeroDigest
                target
                (freshMailbox capacity3)
                4
                [peerA]
                oldBegun
            migrated = either (error . show) id migrate
            repeated =
              migrateEmitterOrders
                zeroDigest
                target
                (freshMailbox capacity3)
                4
                [peerA]
                oldBegun
            recovered =
              step migrated (Recover (monotonicInstantFromMicros 0) (deadlineAfter 1000))
            rotationState = stepState recovered
            stale =
              step
                rotationState
                ( StageResolved
                    (inFlightIncarnation oldInFlight)
                    (inFlightAdmission oldInFlight)
                    (StageStaged (boundedPayload (BS.pack [42])))
                )
            (rotated, _) = driveCurrentToCommit rotationState (BS.pack [43])
            postMigrationRecovery =
              step rotated (Recover (monotonicInstantFromMicros 0) (deadlineAfter 1000))
        repeated `shouldBe` migrate
        emitterGenesisAnchor migrated `shouldBe` emitterCommittedAnchor oldBegun
        emitterCommittedAnchor migrated `shouldBe` emitterCommittedAnchor oldBegun
        emitterIncarnation migrated `shouldBe` target
        emitterPreviousOrdersDigest migrated `shouldBe` Just zeroDigest
        emitterPeers migrated `shouldBe` Set.singleton peerA
        emitterUnacked migrated `shouldBe` []
        emitterRepairFloor migrated `shouldBe` emptyRepairFloor
        emitterLatestCommitted migrated `shouldBe` Nothing
        emitterInFlight migrated `shouldBe` Nothing
        emitterPending migrated `shouldBe` Just (PendingOrdersMigration zeroDigest)
        [stagePlanKind plan | EffStage _ _ plan <- stepEffects recovered]
          `shouldBe` [KindOrdersMigration zeroDigest]
        case [replay | EffRestoreRetained _ _ replay <- stepEffects recovered] of
          [replay] -> do
            recoveryReplayPreviousOrdersDigest replay `shouldBe` Just zeroDigest
            recoveryReplayCheckpoint replay `shouldBe` Nothing
            recoveryReplayAssertions replay `shouldBe` []
          values ->
            expectationFailure
              ("expected one active-migration restore replay, got " ++ show (length values))
        stepOutcome stale
          `shouldBe` OutcomeRejected
            ( RejectStaleIncarnation
                (inFlightIncarnation (currentInFlight rotationState))
                (inFlightIncarnation oldInFlight)
            )
        emitterPending rotated `shouldBe` Nothing
        emitterPreviousOrdersDigest rotated `shouldBe` Just zeroDigest
        case [replay | EffRestoreRetained _ _ replay <- stepEffects postMigrationRecovery] of
          [replay] -> recoveryReplayPreviousOrdersDigest replay `shouldBe` Nothing
          values ->
            expectationFailure
              ("expected one historical migration replay, got " ++ show (length values))
        continuityAnchorEpoch (emitterCommittedAnchor rotated)
          `shouldBe` (continuityAnchorEpoch (emitterCommittedAnchor oldBegun) + 1)
        continuityAnchorSequence (emitterCommittedAnchor rotated) `shouldBe` 0
      it "retains and replaces previous-Orders evidence through checkpointed restarts" $ do
        let old = commitWith 44 (initialState 8)
            migrated =
              either
                (error . show)
                id
                ( migrateEmitterOrders
                    ordersDigestA
                    (mkIncarnation 2)
                    (freshMailbox capacity3)
                    1
                    [peerA, peerB]
                    old
                )
            migrationBegin =
              step migrated (Recover (monotonicInstantFromMicros 0) (deadlineAfter 1000))
            (migrationCommitted, _) =
              driveCurrentToCommit (stepState migrationBegin) (BS.pack [45])
            futureCommitted = commitWith 46 migrationCommitted
            candidate = onlyCheckpoint futureCommitted
            checkpointed =
              stepState
                ( step
                    futureCommitted
                    ( CheckpointResolved
                        (emitterIncarnation futureCommitted)
                        (deadlineAfter 1000)
                        candidate
                        (CheckpointInstalled (boundedPayload (BS.pack [47, 48])))
                    )
                )
            projection = projectDurableEmitterState checkpointed
            bounds = projectionBounds 16384 4096 4 16
            encoded = either (error . show) id (encodeDurableEmitterProjection bounds projection)
            decoded = either (error . show) id (decodeDurableEmitterProjection bounds encoded)
            restored =
              either
                (error . show)
                id
                (restoreDurableEmitterState (freshMailbox capacity3) (deadlineAfter 9000) decoded)
            remigrated =
              either
                (error . show)
                id
                ( migrateEmitterOrders
                    ordersDigestB
                    (mkIncarnation 3)
                    (freshMailbox capacity3)
                    1
                    [peerA, peerB]
                    restored
                )
            replacementProjection = projectDurableEmitterState remigrated
            replacementEncoded =
              either
                (error . show)
                id
                (encodeDurableEmitterProjection bounds replacementProjection)
            replacementDecoded =
              either
                (error . show)
                id
                (decodeDurableEmitterProjection bounds replacementEncoded)
            replacementRestored =
              either
                (error . show)
                id
                ( restoreDurableEmitterState
                    (freshMailbox capacity3)
                    (deadlineAfter 10000)
                    replacementDecoded
                )
            replacementRecovery =
              step
                replacementRestored
                (Recover (monotonicInstantFromMicros 0) (deadlineAfter 10000))
        map
          emitterPreviousOrdersDigest
          [migrated, migrationCommitted, futureCommitted, checkpointed, restored]
          `shouldBe` replicate 5 (Just ordersDigestA)
        durableProjectionPreviousOrdersDigest decoded `shouldBe` Just ordersDigestA
        (stagedRecordKind <$> emitterLatestCommitted checkpointed)
          `shouldBe` Just (KindOwnership OwnershipClaim)
        map (stagedRecordKind . unackedAssertionRecord) (checkpointCandidateAssertions candidate)
          `shouldBe` [KindOrdersMigration ordersDigestA]
        repairFloorSignedBytes (emitterRepairFloor checkpointed)
          `shouldBe` Just (BS.pack [47, 48])
        emitterPreviousOrdersDigest replacementRestored `shouldBe` Just ordersDigestB
        durableProjectionPreviousOrdersDigest replacementDecoded `shouldBe` Just ordersDigestB
        emitterPending replacementRestored `shouldBe` Just (PendingOrdersMigration ordersDigestB)
        emitterUnacked replacementRestored `shouldBe` []
        emitterLatestCommitted replacementRestored `shouldBe` Nothing
        emitterRepairFloor replacementRestored `shouldBe` emptyRepairFloor
        case stepEffects replacementRecovery of
          [EffRestoreRetained _ _ replay, EffStage _ _ plan] -> do
            recoveryReplayPreviousOrdersDigest replay `shouldBe` Just ordersDigestB
            stagePlanKind plan `shouldBe` KindOrdersMigration ordersDigestB
          effects ->
            expectationFailure
              ("unexpected replacement migration recovery effects: " ++ show effects)
      it "rejects canonical projections whose previous-Orders evidence conflicts" $ do
        let migrated =
              either
                (error . show)
                id
                ( migrateEmitterOrders
                    ordersDigestA
                    (mkIncarnation 2)
                    (freshMailbox capacity3)
                    8
                    [peerA]
                    (initialState 8)
                )
            migrationBegin =
              step migrated (Recover (monotonicInstantFromMicros 0) (deadlineAfter 1000))
            (committed, _) =
              driveCurrentToCommit (stepState migrationBegin) (BS.pack [49])
            bounds = projectionBounds 16384 4096 4 16
            corrupt projection =
              let encoded =
                    either (error . show) id (encodeDurableEmitterProjection bounds projection)
               in replaceOccurrence
                    1
                    (continuityDigestBytes ordersDigestA)
                    (continuityDigestBytes ordersDigestB)
                    encoded
        decodeDurableEmitterProjection bounds (corrupt (projectDurableEmitterState migrated))
          `shouldSatisfy` isPreviousOrdersDigestMismatch
        decodeDurableEmitterProjection bounds (corrupt (projectDurableEmitterState committed))
          `shouldSatisfy` isPreviousOrdersDigestMismatch
      it "fails Orders migration when the incarnation space is exhausted" $ do
        let exhausted =
              mkEmitterState
                (anchorAt 0 0)
                (mkIncarnation maxBound)
                (freshMailbox capacity3)
                8
        migrateEmitterOrders
          zeroDigest
          (mkIncarnation maxBound)
          (freshMailbox capacity3)
          8
          [peerA]
          exhausted
          `shouldBe` Left RejectIncarnationExhausted
      it "fails Orders migration instead of wrapping an exhausted epoch" $ do
        let exhaustedEpoch =
              mkEmitterState
                (anchorAt maxBound 7)
                (mkIncarnation 1)
                (freshMailbox capacity3)
                8
        migrateEmitterOrders
          zeroDigest
          (mkIncarnation 2)
          (freshMailbox capacity3)
          8
          [peerA]
          exhaustedEpoch
          `shouldBe` Left RejectOrdersMigrationEpochExhausted

    describe "per-peer acknowledgement and signed checkpoint" $ do
      it "refuses acknowledgement snapshots throughout every in-flight phase" $ do
        let (committed, _) = driveOwnershipToCommit (initialState 8) (BS.pack [50])
            point = pointFor (unackedAssertionRecord (onlyUnacked committed))
            staging =
              stepState
                ( step
                    (stepState (step committed (SubmitRequest (ReqOwnership OwnershipYield))))
                    (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
                )
            fsyncingStage =
              stepState
                (resolveCurrentStage staging (StageStaged (boundedPayload (BS.pack [51]))))
            publishing = stepState (advanceCurrentPhase fsyncingStage DidFsyncStage)
            committing = stepState (advanceCurrentPhase publishing DidPublish)
            fsyncingCommit = stepState (advanceCurrentPhase committing DidCommit)
            phases = [staging, fsyncingStage, publishing, committing, fsyncingCommit]
        map (inFlightPhase . currentInFlight) phases
          `shouldBe` [PhaseStaging, PhaseFsyncingStage, PhasePublishing, PhaseCommitting, PhaseFsyncingCommit]
        mapM_
          ( \phaseState -> do
              let refused = step phaseState (AckPeerThrough peerA point)
              stepOutcome refused `shouldBe` OutcomeRejected RejectBusy
              stepState refused `shouldBe` phaseState
              stepEffects refused `shouldBe` []
          )
          phases
      it "retires an assertion only after every current peer acknowledges it" $ do
        let (committed, _) = driveOwnershipToCommit (initialState 8) (BS.pack [51])
            unacked = onlyUnacked committed
            point = pointFor (unackedAssertionRecord unacked)
            ackA = step committed (AckPeerThrough peerA point)
            afterA = emitterUnacked (stepState ackA)
            ackB = step (stepState ackA) (AckPeerThrough peerB point)
        length afterA `shouldBe` 1
        unackedAssertionWaitingPeers (onlyElement "unacked assertion" afterA)
          `shouldBe` Set.singleton peerB
        map unackedAssertionWaitingPeers (emitterUnacked (stepState ackB))
          `shouldBe` [Set.empty]
      it "retains an all-acknowledged predecessor through the next durable commit" $ do
        let (firstCommitted, _) = driveOwnershipToCommit (initialState 8) (BS.pack [53])
            firstPoint = pointFor (unackedAssertionRecord (onlyUnacked firstCommitted))
            fullyAcknowledged =
              stepState
                ( step
                    (stepState (step firstCommitted (AckPeerThrough peerA firstPoint)))
                    (AckPeerThrough peerB firstPoint)
                )
            secondCommitted = commitWith 54 fullyAcknowledged
            projection = projectDurableEmitterState secondCommitted
            bounds = projectionBounds 16384 4096 4 16
            encoded = either (error . show) id (encodeDurableEmitterProjection bounds projection)
            decoded = either (error . show) id (decodeDurableEmitterProjection bounds encoded)
        map unackedAssertionWaitingPeers (emitterUnacked secondCommitted)
          `shouldBe` [Set.empty, Set.fromList [peerA, peerB]]
        durableProjectionUnackedCount decoded `shouldBe` 2
        durableProjectionCommittedAnchor decoded `shouldBe` emitterCommittedAnchor secondCommitted
      it "rejects unknown and identity-free acknowledgements" $ do
        let (committed, _) = driveOwnershipToCommit (initialState 8) (BS.pack [52])
            point = pointFor (unackedAssertionRecord (onlyUnacked committed))
        stepOutcome (step committed (AckPeerThrough peerC point))
          `shouldBe` OutcomeRejected (RejectUnknownPeer peerC)
        stepOutcome (step committed (AckThrough 1))
          `shouldBe` OutcomeRejected RejectPeerIdentityRequired
      it "keeps the exact prefix until a signed checkpoint installs" $ do
        let st0 = initialState 2
            st1 = commitWith 61 st0
            st2 = commitWith 62 st1
            st3 = commitWith 63 st2
            candidate = onlyCheckpoint st3
            firstBytes =
              stagedRecordSignedBytes
                ( unackedAssertionRecord
                    ( onlyElement
                        "checkpoint assertion"
                        (checkpointCandidateAssertions candidate)
                    )
                )
            failed =
              step
                st3
                ( CheckpointResolved
                    (emitterIncarnation st3)
                    (deadlineAfter 1000)
                    candidate
                    CheckpointFailed
                )
            recovered =
              step
                (stepState failed)
                (Recover (monotonicInstantFromMicros 0) (deadlineAfter 1000))
            checkpointBytes = BS.pack [70, 71, 72]
            installed =
              step
                (stepState failed)
                ( CheckpointResolved
                    (emitterIncarnation st3)
                    (deadlineAfter 1000)
                    candidate
                    (CheckpointInstalled (boundedPayload checkpointBytes))
                )
        firstBytes `shouldBe` BS.pack [61]
        length (emitterUnacked st3) `shouldBe` 3
        emitterCheckpointPending (stepState failed) `shouldBe` Just candidate
        case stepEffects recovered of
          [ EffRestoreRetained incarnation deadline replay
            , EffCheckpointCompaction checkpointIncarnation checkpointDeadline replayedCandidate
            ] -> do
              incarnation `shouldBe` emitterIncarnation st3
              deadline `shouldBe` deadlineAfter 1000
              checkpointIncarnation `shouldBe` emitterIncarnation st3
              checkpointDeadline `shouldBe` deadlineAfter 1000
              replayedCandidate `shouldBe` candidate
              map stagedRecordSignedBytes (recoveryReplayAssertions replay)
                `shouldBe` map (stagedRecordSignedBytes . unackedAssertionRecord) (emitterUnacked st3)
          effects -> expectationFailure ("unexpected checkpoint recovery effects: " ++ show effects)
        length (emitterUnacked (stepState installed)) `shouldBe` 2
        repairFloorSignedBytes (emitterRepairFloor (stepState installed))
          `shouldBe` Just checkpointBytes
        repairFloorSequence (emitterRepairFloor (stepState installed)) `shouldBe` Just 1
      it "blocks further transitions while checkpoint signing is unresolved" $ do
        let st3 = commitWith 83 (commitWith 82 (commitWith 81 (initialState 2)))
            submitted = step st3 (SubmitRequest (ReqOwnership OwnershipYield))
            blocked =
              step
                (stepState submitted)
                (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
        stepOutcome blocked `shouldBe` OutcomeRejected RejectCheckpointPending
        length (emitterUnacked (stepState blocked)) `shouldBe` 3
      it "freezes checkpoint-prefix waiting semantics until installation" $ do
        let pending = commitWith 143 (commitWith 142 (commitWith 141 (initialState 2)))
            candidate = onlyCheckpoint pending
            prefixPoint =
              pointFor
                ( unackedAssertionRecord
                    (onlyElement "checkpoint prefix" (checkpointCandidateAssertions candidate))
                )
            rejected = step pending (AckPeerThrough peerA prefixPoint)
            bounds = projectionBounds 16384 4096 4 16
        stepOutcome rejected `shouldBe` OutcomeRejected RejectCheckpointPending
        stepState rejected `shouldBe` pending
        encodeDurableEmitterProjection bounds (projectDurableEmitterState (stepState rejected))
          `shouldSatisfy` isRight
      it "advances the signed floor and preserves the exact contiguous suffix" $ do
        let pending = commitWith 153 (commitWith 152 (commitWith 151 (initialState 2)))
            candidate = onlyCheckpoint pending
            prefix = checkpointCandidateAssertions candidate
            suffixBefore = drop (length prefix) (emitterUnacked pending)
            checkpointBytes = BS.replicate 8 99
            installed =
              stepState
                ( step
                    pending
                    ( CheckpointResolved
                        (emitterIncarnation pending)
                        (deadlineAfter 1000)
                        candidate
                        (CheckpointInstalled (boundedPayload checkpointBytes))
                    )
                )
            floorAnchor = repairFloorAnchor (emitterRepairFloor installed)
            firstSuffixPrevious =
              stagedRecordPreviousAnchor
                (unackedAssertionRecord (firstElement "retained suffix" (emitterUnacked installed)))
        emitterUnacked installed `shouldBe` suffixBefore
        floorAnchor `shouldBe` Just firstSuffixPrevious
        length (emitterUnacked installed) `shouldBe` 2
        encodeDurableEmitterProjection
          (projectionBoundsSplit 16384 1 8 4 16)
          (projectDurableEmitterState installed)
          `shouldSatisfy` isRight
        encodeDurableEmitterProjection
          (projectionBoundsSplit 16384 1 7 4 16)
          (projectDurableEmitterState installed)
          `shouldSatisfy` isProjectionSignedBoundFailure

    describe "bounded durable projection" $ do
      it "round-trips an unsigned admitted request with a fresh recovery deadline" $ do
        let st0 = initialState 8
            begun =
              stepState
                ( step
                    (stepState (step st0 (SubmitRequest (ReqHeartbeat (HeartbeatPayload 55)))))
                    (Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000))
                )
            projection = projectDurableEmitterState begun
            bounds = projectionBounds 16384 4096 4 16
            decoded =
              either
                (error . show)
                id
                ( decodeDurableEmitterProjection
                    bounds
                    (either (error . show) id (encodeDurableEmitterProjection bounds projection))
                )
            recoveryDeadline = deadlineAfter 7000
            restored =
              either
                (error . show)
                id
                (restoreDurableEmitterState (freshMailbox capacity3) recoveryDeadline decoded)
            recovered =
              step
                restored
                (Recover (monotonicInstantFromMicros 1) recoveryDeadline)
        durableProjectionStagedRecord decoded `shouldBe` Nothing
        fmap inFlightPhase (emitterInFlight restored) `shouldBe` Just PhaseStaging
        fmap inFlightDeadline (emitterInFlight restored) `shouldBe` Just recoveryDeadline
        [stagePlanKind plan | EffStage _ _ plan <- stepEffects recovered]
          `shouldBe` [KindHeartbeat (HeartbeatPayload 55)]
      it
        "round-trips ack state, repair floor, exact staged bytes, and next admission without mailbox/deadline"
        $ do
          let st3 = commitWith 93 (commitWith 92 (commitWith 91 (initialState 2)))
              candidate = onlyCheckpoint st3
              installed =
                stepState
                  ( step
                      st3
                      ( CheckpointResolved
                          (emitterIncarnation st3)
                          (deadlineAfter 1000)
                          candidate
                          (CheckpointInstalled (boundedPayload (BS.pack [101, 102])))
                      )
                  )
              latestPoint = pointFor (unackedAssertionRecord (lastElement "unacked assertion" (emitterUnacked installed)))
              partiallyAcked = stepState (step installed (AckPeerThrough peerA latestPoint))
              stagedBytes = BS.pack [111, 112, 113]
              (begun, _, _) =
                runIntents
                  partiallyAcked
                  [ SubmitRequest (ReqHeartbeat (HeartbeatPayload 777))
                  , Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000)
                  ]
              staged =
                stepState (resolveCurrentStage begun (StageStaged (boundedPayload stagedBytes)))
              projection = projectDurableEmitterState staged
              bounds = projectionBounds 16384 4096 4 16
              encoded = either (error . show) id (encodeDurableEmitterProjection bounds projection)
              decoded = either (error . show) id (decodeDurableEmitterProjection bounds encoded)
              recoveryDeadline = deadlineAfter 9000
              restored =
                either
                  (error . show)
                  id
                  (restoreDurableEmitterState (freshMailbox capacity3) recoveryDeadline decoded)
              recovered =
                step
                  restored
                  (Recover (monotonicInstantFromMicros 1) recoveryDeadline)
          projectDurableEmitterState restored `shouldBe` decoded
          durableProjectionCommittedAnchor decoded `shouldBe` emitterCommittedAnchor staged
          durableProjectionIncarnation decoded `shouldBe` emitterIncarnation staged
          durableProjectionNextAdmission decoded `shouldBe` durableProjectionNextAdmission projection
          fmap stagedRecordSignedBytes (durableProjectionStagedRecord decoded)
            `shouldBe` Just stagedBytes
          durableProjectionUnackedCount decoded `shouldBe` 2
          mailboxDepth (emitterMailbox restored) `shouldBe` 0
          fmap inFlightDeadline (emitterInFlight restored) `shouldBe` Just recoveryDeadline
          postSignBytes (stepEffects recovered) `shouldBe` [stagedBytes]
      it "round-trips an unresolved checkpoint candidate without dropping its exact prefix" $ do
        let pending = commitWith 123 (commitWith 122 (commitWith 121 (initialState 2)))
            projection = projectDurableEmitterState pending
            bounds = projectionBounds 16384 4096 4 16
            encoded = either (error . show) id (encodeDurableEmitterProjection bounds projection)
            decoded = either (error . show) id (decodeDurableEmitterProjection bounds encoded)
            restored =
              either
                (error . show)
                id
                (restoreDurableEmitterState (freshMailbox capacity3) (deadlineAfter 8000) decoded)
            candidate = onlyCheckpoint restored
            recoveryDeadline = deadlineAfter 8000
            recovered =
              step
                restored
                (Recover (monotonicInstantFromMicros 1) recoveryDeadline)
        emitterUnacked restored `shouldBe` emitterUnacked pending
        emitterCheckpointPending restored `shouldBe` emitterCheckpointPending pending
        case stepEffects recovered of
          [ EffRestoreRetained incarnation deadline replay
            , EffCheckpointCompaction checkpointIncarnation checkpointDeadline replayedCandidate
            ] -> do
              incarnation `shouldBe` emitterIncarnation restored
              deadline `shouldBe` recoveryDeadline
              checkpointIncarnation `shouldBe` emitterIncarnation restored
              checkpointDeadline `shouldBe` recoveryDeadline
              replayedCandidate `shouldBe` candidate
              recoveryReplayAssertionCount replay `shouldBe` 3
          effects -> expectationFailure ("unexpected unresolved-checkpoint recovery effects: " ++ show effects)
      it "replays exact checkpoint and suffix bytes after a durable round-trip without re-signing" $ do
        let pending = commitWith 163 (commitWith 162 (commitWith 161 (initialState 2)))
            candidate = onlyCheckpoint pending
            checkpointBytes = BS.pack [171, 172, 173, 174]
            installed =
              stepState
                ( step
                    pending
                    ( CheckpointResolved
                        (emitterIncarnation pending)
                        (deadlineAfter 1000)
                        candidate
                        (CheckpointInstalled (boundedPayload checkpointBytes))
                    )
                )
            latestPoint =
              pointFor
                (unackedAssertionRecord (lastElement "retained suffix" (emitterUnacked installed)))
            partiallyAcknowledged =
              stepState (step installed (AckPeerThrough peerA latestPoint))
            bounds = projectionBoundsSplit 16384 4096 8192 4 16
            projection = projectDurableEmitterState partiallyAcknowledged
            encoded = either (error . show) id (encodeDurableEmitterProjection bounds projection)
            decoded = either (error . show) id (decodeDurableEmitterProjection bounds encoded)
            recoveryDeadline = deadlineAfter 9000
            restored =
              either
                (error . show)
                id
                (restoreDurableEmitterState (freshMailbox capacity3) recoveryDeadline decoded)
            recovered =
              step restored (Recover (monotonicInstantFromMicros 1) recoveryDeadline)
        case stepEffects recovered of
          [EffRestoreRetained incarnation deadline replay] -> do
            incarnation `shouldBe` emitterIncarnation restored
            deadline `shouldBe` recoveryDeadline
            (boundedSignedPayloadBytes <$> recoveryReplayCheckpoint replay)
              `shouldBe` Just checkpointBytes
            recoveryReplayGenesisAnchor replay `shouldBe` emitterGenesisAnchor restored
            map stagedRecordSignedBytes (recoveryReplayAssertions replay)
              `shouldBe` map (stagedRecordSignedBytes . unackedAssertionRecord) (emitterUnacked restored)
            map unackedAssertionWaitingPeers (recoveryReplayPendingPublications replay)
              `shouldBe` [Set.singleton peerB, Set.singleton peerB]
            recoveryReplayAssertionCount replay `shouldBe` 2
            recoveryReplaySignedBytes replay
              `shouldBe` fromIntegral (BS.length checkpointBytes + 2)
            stepOutcome (step restored (RecoveryRestored incarnation replay))
              `shouldBe` OutcomeAccepted
          effects -> expectationFailure ("unexpected retained recovery effects: " ++ show effects)
        [() | EffStage {} <- stepEffects recovered] `shouldBe` []
      it "rejects encoded, signed-payload, peer-count, and retained-count bound violations" $ do
        let pending = commitWith 133 (commitWith 132 (commitWith 131 (initialState 2)))
            projection = projectDurableEmitterState pending
            wideProjection =
              projectDurableEmitterState
                (fst (driveOwnershipToCommit (initialState 8) (BS.pack [1, 2])))
            roomy = projectionBounds 16384 4096 4 16
            encoded = either (error . show) id (encodeDurableEmitterProjection roomy projection)
        encodeDurableEmitterProjection (projectionBounds 1 4096 4 16) projection
          `shouldSatisfy` isProjectionEncodedBoundFailure
        decodeDurableEmitterProjection (projectionBounds 1 4096 4 16) encoded
          `shouldSatisfy` isProjectionEncodedBoundFailure
        encodeDurableEmitterProjection (projectionBounds 16384 1 4 16) wideProjection
          `shouldSatisfy` isProjectionSignedBoundFailure
        encodeDurableEmitterProjection (projectionBounds 16384 4096 1 16) projection
          `shouldBe` Left (DurableProjectionPeerCountExceeded 2 1)
        encodeDurableEmitterProjection (projectionBounds 16384 4096 4 2) projection
          `shouldSatisfy` isProjectionRetainedBoundFailure
      it "rejects a canonically-shaped projection whose exact signed payload was substituted" $ do
        let originalBytes = BS.pack [201, 202, 203, 204]
            substitutedBytes = BS.pack [201, 202, 203, 205]
            projection =
              projectDurableEmitterState
                (fst (driveOwnershipToCommit (initialState 8) originalBytes))
            bounds = projectionBounds 16384 4096 4 16
            encoded = either (error . show) id (encodeDurableEmitterProjection bounds projection)
            corrupted = replaceFirst originalBytes substitutedBytes encoded
        case decodeDurableEmitterProjection bounds corrupted of
          Left (DurableProjectionInvariantViolation detail) ->
            show detail `shouldSatisfy` ("derived anchor mismatch" `isInfixOf`)
          other ->
            expectationFailure
              ("expected structured derived-anchor rejection, got " ++ show other)
      it "rejects an empty-floor suffix detached from its persisted genesis" $ do
        let projection = projectDurableEmitterState (commitWith 211 (initialState 8))
            bounds = projectionBounds 16384 4096 4 16
            encoded = either (error . show) id (encodeDurableEmitterProjection bounds projection)
            corrupted = replaceOccurrence 1 (BS.replicate 32 0) (BS.replicate 32 17) encoded
        decodeDurableEmitterProjection bounds corrupted
          `shouldBe` Left (DurableProjectionChainDiscontinuity 0)
      it "rejects a repair-floor anchor detached from its retained suffix" $ do
        let pending = commitWith 223 (commitWith 222 (commitWith 221 (initialState 2)))
            candidate = onlyCheckpoint pending
            installed =
              stepState
                ( step
                    pending
                    ( CheckpointResolved
                        (emitterIncarnation pending)
                        (deadlineAfter 1000)
                        candidate
                        (CheckpointInstalled (boundedPayload (BS.pack [231, 232])))
                    )
                )
            floorAnchor =
              maybe (error "missing repair floor") id (repairFloorAnchor (emitterRepairFloor installed))
            floorDigest = continuityDigestBytes (continuityAnchorPreviousDigest floorAnchor)
            projection = projectDurableEmitterState installed
            bounds = projectionBounds 16384 4096 4 16
            encoded = either (error . show) id (encodeDurableEmitterProjection bounds projection)
            corrupted = replaceOccurrence 2 floorDigest (BS.replicate 32 19) encoded
        decodeDurableEmitterProjection bounds corrupted
          `shouldBe` Left (DurableProjectionChainDiscontinuity 0)

commitWith :: Word64 -> EmitterState -> EmitterState
commitWith byte st = fst (driveOwnershipToCommit st (BS.pack [fromIntegral byte]))

onlyUnacked :: EmitterState -> UnackedAssertion
onlyUnacked st = case emitterUnacked st of
  [value] -> value
  values -> error ("expected one unacked assertion, got " ++ show (length values))

onlyCheckpoint :: EmitterState -> CheckpointCandidate
onlyCheckpoint st = case emitterCheckpointPending st of
  Nothing -> error "expected checkpoint candidate"
  Just value -> value

pointFor :: StagedRecord -> AckPoint
pointFor record =
  mkAckPoint (stagedRecordIncarnation record) (stagedRecordNextAnchor record)

effectTag :: EmitterEffect -> String
effectTag effect = case effect of
  EffStage {} -> "stage"
  EffFsyncStage {} -> "fsync-stage"
  EffPublish {} -> "publish"
  EffCommit {} -> "commit"
  EffFsyncCommit {} -> "fsync-commit"
  EffCheckpointCompaction {} -> "checkpoint"
  EffRestoreRetained {} -> "restore-retained"

effectAdmission :: EmitterEffect -> Maybe TransitionAdmission
effectAdmission effect = case effect of
  EffStage admission _ _ -> Just admission
  EffFsyncStage admission _ _ -> Just admission
  EffPublish admission _ _ -> Just admission
  EffCommit admission _ _ -> Just admission
  EffFsyncCommit admission _ _ -> Just admission
  EffCheckpointCompaction {} -> Nothing
  EffRestoreRetained {} -> Nothing

effectAdmissions :: [EmitterEffect] -> [TransitionAdmission]
effectAdmissions effects = [admission | Just admission <- map effectAdmission effects]

onlyAdmission :: [EmitterEffect] -> TransitionAdmission
onlyAdmission = onlyElement "transition admission" . effectAdmissions

firstAdmission :: [EmitterEffect] -> TransitionAdmission
firstAdmission effects = case effectAdmissions effects of
  [] -> error "expected at least one transition admission"
  admission : _ -> admission

effectRecords :: [EmitterEffect] -> [StagedRecord]
effectRecords effects = [record | Just record <- map effectRecord effects]

effectRecord :: EmitterEffect -> Maybe StagedRecord
effectRecord effect = case effect of
  EffFsyncStage _ _ record -> Just record
  EffPublish _ _ record -> Just record
  EffCommit _ _ record -> Just record
  EffFsyncCommit _ _ record -> Just record
  _ -> Nothing

postSignBytes :: [EmitterEffect] -> [ByteString]
postSignBytes = map stagedRecordSignedBytes . effectRecords

firstRecord :: [StagedRecord] -> Maybe StagedRecord
firstRecord records = case records of
  [] -> Nothing
  record : _ -> Just record

onlyElement :: String -> [value] -> value
onlyElement label values = case values of
  [value] -> value
  _ -> error ("expected exactly one " ++ label ++ ", got " ++ show (length values))

firstElement :: String -> [value] -> value
firstElement label values = case values of
  [] -> error ("expected at least one " ++ label)
  value : _ -> value

lastElement :: String -> [value] -> value
lastElement label values = case reverse values of
  [] -> error ("expected at least one " ++ label)
  value : _ -> value

projectionBounds
  :: Natural
  -> Natural
  -> Natural
  -> Natural
  -> DurableProjectionBounds
projectionBounds encoded signed peers assertions =
  either
    (error . show)
    id
    (mkDurableProjectionBounds encoded signed signed peers assertions)

projectionBoundsSplit
  :: Natural
  -> Natural
  -> Natural
  -> Natural
  -> Natural
  -> DurableProjectionBounds
projectionBoundsSplit encoded assertion checkpoint peers assertions =
  either
    (error . show)
    id
    (mkDurableProjectionBounds encoded assertion checkpoint peers assertions)

isProjectionEncodedBoundFailure
  :: Either DurableProjectionError value
  -> Bool
isProjectionEncodedBoundFailure result = case result of
  Left DurableProjectionEncodedBytesExceeded {} -> True
  _ -> False

isProjectionSignedBoundFailure
  :: Either DurableProjectionError value
  -> Bool
isProjectionSignedBoundFailure result = case result of
  Left DurableProjectionSignedBytesExceeded {} -> True
  _ -> False

isProjectionRetainedBoundFailure
  :: Either DurableProjectionError value
  -> Bool
isProjectionRetainedBoundFailure result = case result of
  Left DurableProjectionRetainedAssertionCountExceeded {} -> True
  Left DurableProjectionThresholdExceeded {} -> True
  _ -> False

isPreviousOrdersDigestMismatch
  :: Either DurableProjectionError value
  -> Bool
isPreviousOrdersDigestMismatch result = case result of
  Left (DurableProjectionInvariantViolation detail) ->
    "does not match the retained previous-Orders digest" `Text.isInfixOf` detail
  _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

replaceFirst :: ByteString -> ByteString -> ByteString -> ByteString
replaceFirst needle replacement haystack =
  let (before, suffix) = BS.breakSubstring needle haystack
   in if BS.null suffix
        then error "expected encoded payload occurrence"
        else before <> replacement <> BS.drop (BS.length needle) suffix

replaceOccurrence :: Natural -> ByteString -> ByteString -> ByteString -> ByteString
replaceOccurrence occurrence needle replacement haystack
  | occurrence == 0 = error "replacement occurrence must be positive"
  | otherwise = go occurrence BS.empty haystack
 where
  go remaining prefix input =
    let (before, suffix) = BS.breakSubstring needle input
     in if BS.null suffix
          then error "expected encoded payload occurrence"
          else
            let consumed = prefix <> before
                after = BS.drop (BS.length needle) suffix
             in if remaining == 1
                  then consumed <> replacement <> after
                  else go (remaining - 1) (consumed <> needle) after

allEqual :: (Eq value) => [value] -> Bool
allEqual [] = True
allEqual (value : remaining) = all (== value) remaining
