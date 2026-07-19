{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.32 (increment 1): pure proofs for the single-writer emitter kernel
-- and its bounded mailbox. Everything here is a pure state-machine exercise — no
-- Kubernetes, no AWS, no journal I/O — so it validates single-writer ordering,
-- monotonic fencing, idempotent replay, crash-resume, deadline propagation, the
-- park-and-resign rotation, heartbeat coalescing, and the size-triggered
-- checkpoint entirely pre-cluster.
module GatewayEmitterKernel
  ( gatewayEmitterKernelSuite
  )
where

import Data.ByteString qualified as BS
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
  , StagedTransition (..)
  , authorityRecordCommittedAnchor
  , continuityAnchorEpoch
  , continuityAnchorSequence
  , mkContinuityBounds
  , mkContinuityDigest
  , mkContinuityScope
  , mkInitialAuthorityRecord
  )
import Prodbox.Gateway.Emitter.Kernel
import Prodbox.Gateway.Emitter.Mailbox
import Test.Tasty.QuickCheck (Gen, elements, forAll, listOf)
import TestSupport

-- Fixtures ------------------------------------------------------------------

zeroDigest :: ContinuityDigest
zeroDigest = either (error . show) id (mkContinuityDigest (BS.replicate 32 0))

anchorAt :: Word64 -> Word64 -> ContinuityAnchor
anchorAt epoch sequenceNumber =
  let bounds = either (error . show) id (mkContinuityBounds 256 256 4096)
      scope = either (error . show) id (mkContinuityScope bounds "emitter-a" (BS.pack [1, 2, 3]))
   in authorityRecordCommittedAnchor
        (mkInitialAuthorityRecord scope epoch sequenceNumber zeroDigest)

deadlineAfter :: Word64 -> Deadline
deadlineAfter budget =
  deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration (fromIntegral budget))

capacity3 :: MailboxCapacity
capacity3 = maybe (error "capacity") id (mkMailboxCapacity 3)

freshMailbox :: MailboxCapacity -> Mailbox
freshMailbox cap = emptyMailbox cap (RetryAfter 1000)

initialState :: Natural -> EmitterState
initialState threshold =
  mkEmitterState (anchorAt 0 0) incarnationZero (freshMailbox capacity3) threshold

-- | Fold a run of intents, collecting each step's effects and outcome.
runIntents :: EmitterState -> [EmitterIntent] -> (EmitterState, [[EmitterEffect]], [StepOutcome])
runIntents st0 = foldl go (st0, [], [])
 where
  go (st, effs, outs) intent =
    let stepResult = step st intent
     in (stepState stepResult, effs ++ [stepEffects stepResult], outs ++ [stepOutcome stepResult])

-- | Drive one ownership transition all the way to commit, returning the
-- accumulated effects in order and the resulting state.
driveOwnershipToCommit :: EmitterState -> Deadline -> (EmitterState, [EmitterEffect])
driveOwnershipToCommit st0 deadline =
  let now = monotonicInstantFromMicros 0
      committedAnchor = either (error . show) id (plannedSemanticAnchor st0 zeroDigest)
      inc = emitterIncarnation st0
      intents =
        [ SubmitRequest (ReqOwnership OwnershipClaim)
        , Pump now deadline
        , StageResolved inc StageStaged
        , PhaseAdvanced inc DidFsyncStage
        , PhaseAdvanced inc DidPublish
        , PhaseAdvanced inc DidCommit
        , PhaseAdvanced inc (DidFsyncCommit committedAnchor)
        ]
      (st', effs, _) = runIntents st0 intents
   in (st', concat effs)

-- Generators ----------------------------------------------------------------

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

-- | Fold a sequence of submits into an empty mailbox of the given capacity.
foldSubmits :: MailboxCapacity -> [EmitterRequest] -> Mailbox
foldSubmits cap = foldl step1 (freshMailbox cap)
 where
  step1 mbox req = case enqueue mbox req of
    EnqueueAccepted mbox' -> mbox'
    EnqueueCoalesced mbox' -> mbox'
    EnqueueRejected _ -> mbox

heartbeatCount :: Mailbox -> Int
heartbeatCount mbox = length [() | ReqHeartbeat _ <- mailboxRequests mbox]

-- Suite ---------------------------------------------------------------------

gatewayEmitterKernelSuite :: SuiteBuilder ()
gatewayEmitterKernelSuite =
  describe "Sprint 2.32 single-writer emitter kernel" $ do
    describe "bounded mailbox" $ do
      it "rejects a non-coalescible request when full" $ do
        let full = foldSubmits capacity3 (replicate 3 (ReqOwnership OwnershipClaim))
        enqueue full (ReqOwnership OwnershipYield)
          `shouldBe` EnqueueRejected (RetryAfter 1000)
      it "coalesces heartbeats to the latest, keeping depth at one" $ do
        let mbox =
              foldSubmits
                capacity3
                [ ReqHeartbeat (HeartbeatPayload 1)
                , ReqHeartbeat (HeartbeatPayload 2)
                , ReqHeartbeat (HeartbeatPayload 3)
                ]
        mailboxDepth mbox `shouldBe` 1
        mailboxPendingHeartbeat mbox `shouldBe` Just (HeartbeatPayload 3)
      it "never drops an ownership request while coalescing heartbeats" $ do
        let mbox =
              foldSubmits
                capacity3
                [ReqHeartbeat (HeartbeatPayload 1), ReqOwnership OwnershipClaim, ReqHeartbeat (HeartbeatPayload 2)]
        [t | ReqOwnership t <- mailboxRequests mbox] `shouldBe` [OwnershipClaim]
        heartbeatCount mbox `shouldBe` 1
      it "dequeues FIFO" $ do
        let mbox = foldSubmits capacity3 [ReqOwnership OwnershipClaim, ReqOwnership OwnershipYield]
        fmap fst (dequeue mbox) `shouldBe` Just (ReqOwnership OwnershipClaim)
      propertyTest "depth stays within capacity and at most one heartbeat pends" $
        forAll (listOf genRequest) $ \requests ->
          let mbox = foldSubmits capacity3 requests
           in mailboxDepth mbox <= mailboxCapacityValue capacity3 && heartbeatCount mbox <= 1

    describe "happy-path transition" $ do
      it "advances the committed sequence exactly once through stage/fsync/publish/commit/fsync" $ do
        let st0 = initialState 8
            (st', effects) = driveOwnershipToCommit st0 (deadlineAfter 1000)
        continuityAnchorSequence (emitterCommittedAnchor st') `shouldBe` 1
        continuityAnchorEpoch (emitterCommittedAnchor st') `shouldBe` 0
        emitterInFlight st' `shouldBe` Nothing
        emitterUnacked st' `shouldBe` [1]
        map effectTag effects
          `shouldBe` ["stage", "fsync-stage", "publish", "commit", "fsync-commit"]
      it "threads one admission and one deadline through every phase effect" $ do
        let st0 = initialState 8
            (_, effects) = driveOwnershipToCommit st0 (deadlineAfter 1000)
            admissions = [a | Just a <- map effectAdmission effects]
        length admissions `shouldBe` 5
        allEqual admissions `shouldBe` True

    describe "single writer" $ do
      it "a pump while a transition is in flight starts no new work" $ do
        let st0 = initialState 8
            now = monotonicInstantFromMicros 0
            deadline = deadlineAfter 1000
            (st1, _, _) =
              runIntents
                st0
                [SubmitRequest (ReqOwnership OwnershipClaim), Pump now deadline]
            -- second ownership is queued but a pump cannot begin it: in flight
            (_, effs, outs) =
              runIntents st1 [SubmitRequest (ReqOwnership OwnershipYield), Pump now deadline]
        concat effs `shouldBe` []
        last outs `shouldBe` OutcomeNoOp

    describe "idempotent replay" $ do
      it "a completion for an already-passed phase is a no-op" $ do
        let st0 = initialState 8
            now = monotonicInstantFromMicros 0
            inc = emitterIncarnation st0
            (st1, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump now (deadlineAfter 1000)
                , StageResolved inc StageStaged
                , PhaseAdvanced inc DidFsyncStage
                , PhaseAdvanced inc DidPublish
                ]
            replay = step st1 (PhaseAdvanced inc DidPublish)
        stepOutcome replay `shouldBe` OutcomeNoOp
        stepEffects replay `shouldBe` []

    describe "crash resume" $ do
      it "recover re-drives the current phase idempotently" $ do
        let st0 = initialState 8
            now = monotonicInstantFromMicros 0
            inc = emitterIncarnation st0
            (st1, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump now (deadlineAfter 1000)
                , StageResolved inc StageStaged
                , PhaseAdvanced inc DidFsyncStage
                ]
            -- now in PhasePublishing; recover should re-emit publish
            recovered = step st1 (Recover now)
        map effectTag (stepEffects recovered) `shouldBe` ["publish"]
      it "recover on an idle emitter is a no-op" $ do
        let st0 = initialState 8
            recovered = step st0 (Recover (monotonicInstantFromMicros 0))
        stepOutcome recovered `shouldBe` OutcomeNoOp

    describe "stale incarnation fencing" $ do
      it "rejects a completion from a superseded mount" $ do
        let st0 = initialState 8
            now = monotonicInstantFromMicros 0
            oldInc = emitterIncarnation st0
            (st1, _, _) =
              runIntents
                st0
                [SubmitRequest (ReqOwnership OwnershipClaim), Pump now (deadlineAfter 1000)]
            -- A new mount fences the old incarnation and recovers its own work;
            -- the old mount's completion must not advance the new transition.
            st2 = advanceIncarnation st1
            (st3, _, _) =
              runIntents
                st2
                [SubmitRequest (ReqOwnership OwnershipYield), Pump now (deadlineAfter 1000)]
            newInc = emitterIncarnation st3
            stale = step st3 (StageResolved oldInc StageStaged)
        stepOutcome stale
          `shouldBe` OutcomeRejected (RejectStaleIncarnation newInc oldInc)

    describe "deadline propagation" $ do
      it "aborts a pre-publish transition whose deadline expired" $ do
        let st0 = initialState 8
            begin = monotonicInstantFromMicros 0
            deadline = deadlineAfter 100
            (st1, _, _) =
              runIntents st0 [SubmitRequest (ReqOwnership OwnershipClaim), Pump begin deadline]
            expired = monotonicInstantFromMicros 200
            aborted = step st1 (Pump expired deadline)
        stepOutcome aborted `shouldBe` OutcomeRejected RejectDeadlineExpired
        emitterInFlight (stepState aborted) `shouldBe` Nothing
      it "keeps a published transition alive past its deadline for re-drive" $ do
        let st0 = initialState 8
            begin = monotonicInstantFromMicros 0
            deadline = deadlineAfter 100
            inc = emitterIncarnation st0
            (st1, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump begin deadline
                , StageResolved inc StageStaged
                , PhaseAdvanced inc DidFsyncStage
                , PhaseAdvanced inc DidPublish
                ]
            expired = monotonicInstantFromMicros 200
            held = step st1 (Pump expired deadline)
        stepOutcome held `shouldBe` OutcomeRejected RejectDeadlineExpired
        emitterInFlight (stepState held) `shouldNotBe` Nothing

    describe "park-and-resign rotation (corrections 1/2/4)" $ do
      it "external rotation requests are a no-op" $ do
        let st0 = initialState 8
            (_, effs, outs) =
              runIntents
                st0
                [SubmitRequest ReqEpochRotation, Pump (monotonicInstantFromMicros 0) (deadlineAfter 1000)]
        concat effs `shouldBe` []
        last outs `shouldBe` OutcomeNoOp
      it "parks the unsigned advance, rotates the epoch, then re-drives it with a fresh ticket" $ do
        -- Start with the sequence exhausted so the sign boundary needs rotation.
        let st0 = mkEmitterState (anchorAt 0 maxBound) incarnationZero (freshMailbox capacity3) 8
            now = monotonicInstantFromMicros 0
            deadline = deadlineAfter 1000
            inc = emitterIncarnation st0
            rotationAnchor = either (error . show) id (plannedEpochAnchor st0 zeroDigest)
            -- 1) submit + pump begins the ownership staging; the sign boundary
            --    reports it needs rotation, so the advance parks (unsigned).
            (parkedState, _, _) =
              runIntents
                st0
                [ SubmitRequest (ReqOwnership OwnershipClaim)
                , Pump now deadline
                , StageResolved inc StageNeedsRotation
                ]
        emitterInFlight parkedState `shouldBe` Nothing
        emitterPending parkedState `shouldBe` Just (PendingRotationThenAdvance OwnershipClaim)
        -- 2) the next pump begins a SEPARATE rotation transition.
        let rotationBegin = step parkedState (Pump now deadline)
        map effectTag (stepEffects rotationBegin) `shouldBe` ["stage"]
        map effectStagedTag (stepEffects rotationBegin) `shouldBe` ["epoch-invalidation"]
        -- 3) drive the rotation to commit; the epoch advances and the advance
        --    becomes ready.
        let (rotatedState, _, _) =
              runIntents
                (stepState rotationBegin)
                [ StageResolved inc StageStaged
                , PhaseAdvanced inc DidFsyncStage
                , PhaseAdvanced inc DidPublish
                , PhaseAdvanced inc DidCommit
                , PhaseAdvanced inc (DidFsyncCommit rotationAnchor)
                ]
        continuityAnchorEpoch (emitterCommittedAnchor rotatedState) `shouldBe` 1
        continuityAnchorSequence (emitterCommittedAnchor rotatedState) `shouldBe` 0
        emitterPending rotatedState `shouldBe` Just (PendingAdvance OwnershipClaim)
        -- 4) the next pump begins the parked advance as its own ticketed
        --    transition against the fresh post-rotation cursor.
        let advanceBegin = step rotatedState (Pump now deadline)
        map effectTag (stepEffects advanceBegin) `shouldBe` ["stage"]
        map effectStagedTag (stepEffects advanceBegin) `shouldBe` ["semantic-advance"]
        emitterPending (stepState advanceBegin) `shouldBe` Nothing

    describe "size-triggered checkpoint (correction 3)" $ do
      it "compacts the unacked set once it exceeds the threshold and never grows unbounded" $ do
        -- Threshold 2: after committing three advances with no acks, the unacked
        -- suffix stays bounded and the checkpoint floor rises.
        let st0 = initialState 2
            st1 = commitN st0 3
        emitterUnacked st1 `shouldSatisfy` (\u -> length u <= 2)
        repairFloorSequence (emitterRepairFloor st1) `shouldBe` Just 1
      it "acknowledgement drops the acked prefix" $ do
        let st0 = initialState 8
            st1 = commitN st0 3
            acked = step st1 (AckThrough 2)
        emitterUnacked (stepState acked) `shouldBe` [3]

-- Helpers -------------------------------------------------------------------

-- | Commit @n@ successive ownership advances, threading each one's fresh
-- committed anchor. Used to exercise the unacked/checkpoint fold.
commitN :: EmitterState -> Int -> EmitterState
commitN st0 n = iterate commitOne st0 !! n
 where
  commitOne st =
    let deadline = deadlineAfter 1000
        (st', _) = driveOwnershipToCommit st deadline
     in st'

effectTag :: EmitterEffect -> String
effectTag eff = case eff of
  EffEmitHeartbeat _ -> "heartbeat"
  EffStage {} -> "stage"
  EffFsyncStage {} -> "fsync-stage"
  EffPublish {} -> "publish"
  EffCommit {} -> "commit"
  EffFsyncCommit {} -> "fsync-commit"
  EffCheckpointCompaction _ -> "checkpoint"

effectStagedTag :: EmitterEffect -> String
effectStagedTag eff = case eff of
  EffStage _ _ SemanticAdvance -> "semantic-advance"
  EffStage _ _ EpochInvalidation -> "epoch-invalidation"
  _ -> "not-a-stage"

effectAdmission :: EmitterEffect -> Maybe TransitionAdmission
effectAdmission eff = case eff of
  EffStage admission _ _ -> Just admission
  EffFsyncStage admission _ -> Just admission
  EffPublish admission _ -> Just admission
  EffCommit admission _ -> Just admission
  EffFsyncCommit admission _ -> Just admission
  _ -> Nothing

allEqual :: (Eq a) => [a] -> Bool
allEqual [] = True
allEqual (x : rest) = all (== x) rest
