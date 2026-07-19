{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE MultiWayIf #-}

-- | Sprint 2.32 (increment 1): the pure single-writer emitter transition kernel.
--
-- One actor owns each local emitter's continuity transition. This module is the
-- pure decide/evolve core of that actor: it holds the volatile state, and its
-- 'step' function is the ONLY thing that mutates it. The interpreter (deferred,
-- cluster-adjacent) turns the emitted 'EmitterEffect's into real journal fsyncs,
-- peer publications, and object-store CAS commits and feeds the results back as
-- intents.
--
-- The design refines the TLA @authorityPhase@/@volatile@ pair into an explicit
-- @stage → fsync → publish → commit → fsync@ 'EmitterPhase'. Because the whole
-- in-flight transition lives in a single @Maybe 'InFlight'@, AT MOST ONE
-- non-idle transition can exist — the single-writer property is structural, not
-- an asserted invariant. One 'TransitionAdmission' and one absolute 'Deadline'
-- are minted when a transition begins and threaded, unchanged, through every
-- phase: no phase releases and reacquires a permit (the overloaded global
-- child-process permit is gone).
--
-- Four adversarial corrections from the verified design are encoded here:
--
--   1. When the sign boundary reports that the committed sequence is exhausted,
--      the kernel parks the __unsigned__ ownership request (not a signed staged
--      record, which would fail re-validation after the epoch rotates) and
--      re-drives it after rotation.
--   2. Epoch rotation is decided only at the sign boundary ('StageNeedsRotation')
--      — an external 'ReqEpochRotation' message is a no-op, never a forced
--      decide-time branch.
--   3. The unacked repair set is compacted by a __size-triggered__ checkpoint
--      fold, so it cannot grow without bound behind a permanently-unreachable
--      peer; ack-gating governs only the bounded replay suffix.
--   4. The forced rotation and the parked advance are TWO separately-ticketed
--      transitions (each begun by its own 'Pump' with its own admission and
--      deadline), never one spanning ticket that could exhaust its deadline.
--
-- The monotonic sequence/epoch fence is delegated to
-- 'Prodbox.Gateway.Continuity.nextAnchorFor' via 'plannedSemanticAnchor' /
-- 'plannedEpochAnchor' — the kernel never re-implements the counter arithmetic,
-- so it cannot drift from the durable record.
module Prodbox.Gateway.Emitter.Kernel
  ( -- * Fencing identities
    Incarnation
  , incarnationZero
  , incarnationValue
  , mkIncarnation
  , TransitionAdmission
  , transitionAdmissionValue

    -- * Phases and transition kinds
  , EmitterPhase (..)
  , DurableKind (..)
  , durableStagedTransition

    -- * In-flight transition
  , InFlight
  , inFlightKind
  , inFlightPhase
  , inFlightAdmission
  , inFlightDeadline
  , inFlightIncarnation
  , inFlightPublished

    -- * Pending (parked) work
  , Pending (..)

    -- * Repair floor
  , RepairFloor
  , repairFloorSequence
  , emptyRepairFloor

    -- * State
  , EmitterState
  , mkEmitterState
  , emitterCommittedAnchor
  , emitterIncarnation
  , emitterInFlight
  , emitterPending
  , emitterMailbox
  , emitterUnacked
  , emitterRepairFloor
  , emitterUnackedThreshold
  , advanceIncarnation

    -- * Sign-boundary anchor planning (delegates to nextAnchorFor)
  , plannedSemanticAnchor
  , plannedEpochAnchor

    -- * Intents, effects, outcomes
  , StageOutcome (..)
  , PhaseCompletion (..)
  , EmitterIntent (..)
  , EmitterEffect (..)
  , RejectReason (..)
  , StepOutcome (..)
  , EmitterStep (..)

    -- * The transition kernel
  , step
  )
where

import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RetryAfter
  , deadlineExpired
  )
import Prodbox.Gateway.Continuity
  ( ContinuityAnchor
  , ContinuityDigest
  , ContinuityError
  , StagedTransition (..)
  , continuityAnchorSequence
  , nextAnchorFor
  )
import Prodbox.Gateway.Emitter.Mailbox
  ( EmitterRequest (..)
  , HeartbeatPayload
  , Mailbox
  , OwnershipTransition (..)
  , dequeue
  , enqueue
  )
import Prodbox.Gateway.Emitter.Mailbox qualified as Mailbox

-- | A monotonically-increasing emitter incarnation. A new process mount takes a
-- strictly-greater incarnation; completions carrying an older one are fenced.
newtype Incarnation = Incarnation Word64
  deriving stock (Eq, Ord, Show)

incarnationZero :: Incarnation
incarnationZero = Incarnation 0

incarnationValue :: Incarnation -> Word64
incarnationValue (Incarnation value) = value

mkIncarnation :: Word64 -> Incarnation
mkIncarnation = Incarnation

-- | An opaque per-transition admission. Minted once when a transition begins and
-- threaded through every phase; the ctor is unexported so no phase can forge a
-- fresh one mid-transition.
newtype TransitionAdmission = TransitionAdmission Word64
  deriving stock (Eq, Ord, Show)

transitionAdmissionValue :: TransitionAdmission -> Word64
transitionAdmissionValue (TransitionAdmission value) = value

-- | The durable transition phases, in order. @Idle@ is represented by the
-- absence of an 'InFlight', not by a constructor here, so an idle emitter cannot
-- be confused with a phase value.
data EmitterPhase
  = PhaseStaging
  | PhaseFsyncingStage
  | PhasePublishing
  | PhaseCommitting
  | PhaseFsyncingCommit
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The kind of durable transition in flight. Heartbeats are NOT durable
-- transitions (they resolve immediately, off the phase machine).
data DurableKind
  = KindOwnership !OwnershipTransition
  | KindEpochRotation
  deriving stock (Eq, Show)

-- | The continuity transition a durable kind stages.
durableStagedTransition :: DurableKind -> StagedTransition
durableStagedTransition kind = case kind of
  KindOwnership _ -> SemanticAdvance
  KindEpochRotation -> EpochInvalidation

data InFlight = InFlight
  { inFlightKind :: !DurableKind
  , inFlightPhase :: !EmitterPhase
  , inFlightAdmission :: !TransitionAdmission
  , inFlightDeadline :: !Deadline
  , inFlightIncarnation :: !Incarnation
  , inFlightPublished :: !Bool
  -- ^ Once the publish phase completes the transition MUST commit and can
  -- never be aborted on deadline expiry — only re-driven via 'Recover'.
  }
  deriving stock (Eq, Show)

-- | Work waiting behind the in-flight transition. A parked ownership advance
-- carries only its (unsigned) request, per adversarial correction 1.
data Pending
  = -- | The committed sequence was exhausted at the sign boundary: rotate the
    -- epoch first, then re-drive this ownership advance.
    PendingRotationThenAdvance !OwnershipTransition
  | -- | Rotation is done; resume this ownership advance as its own transition.
    PendingAdvance !OwnershipTransition
  deriving stock (Eq, Show)

-- | The compacted checkpoint floor: the highest sequence absorbed into a signed
-- checkpoint. A lagging peer repairs from here plus the bounded unacked suffix.
newtype RepairFloor = RepairFloor
  { repairFloorSequence :: Maybe Word64
  }
  deriving stock (Eq, Show)

emptyRepairFloor :: RepairFloor
emptyRepairFloor = RepairFloor Nothing

data EmitterState = EmitterState
  { emitterCommittedAnchor :: !ContinuityAnchor
  , emitterIncarnation :: !Incarnation
  , emitterInFlight :: !(Maybe InFlight)
  , emitterPending :: !(Maybe Pending)
  , emitterMailbox :: !Mailbox
  , emitterUnacked :: ![Word64]
  , emitterRepairFloor :: !RepairFloor
  , emitterUnackedThreshold :: !Natural
  , emitterAdmissionCounter :: !Word64
  }
  deriving stock (Eq, Show)

-- | Build an idle emitter state from its committed anchor, current incarnation,
-- an empty mailbox, and the unacked size threshold.
mkEmitterState :: ContinuityAnchor -> Incarnation -> Mailbox -> Natural -> EmitterState
mkEmitterState anchor incarnation mailbox threshold =
  EmitterState
    { emitterCommittedAnchor = anchor
    , emitterIncarnation = incarnation
    , emitterInFlight = Nothing
    , emitterPending = Nothing
    , emitterMailbox = mailbox
    , emitterUnacked = []
    , emitterRepairFloor = emptyRepairFloor
    , emitterUnackedThreshold = threshold
    , emitterAdmissionCounter = 0
    }

-- | Model a new process mount: the incarnation strictly increases and the
-- volatile in-flight transition is discarded (the new incarnation recovers from
-- the durable record). Completions tagged with the old incarnation are fenced
-- out afterwards.
advanceIncarnation :: EmitterState -> EmitterState
advanceIncarnation st =
  st
    { emitterIncarnation = Incarnation (incarnationValue (emitterIncarnation st) + 1)
    , emitterInFlight = Nothing
    }

-- | The next anchor a semantic advance would commit — delegated wholesale to
-- 'nextAnchorFor', so the exhaustion fence and the counter arithmetic live in
-- exactly one place. A 'Left' 'ContinuityError' (sequence requires rotation)
-- is what the interpreter turns into a 'StageNeedsRotation'.
plannedSemanticAnchor :: EmitterState -> ContinuityDigest -> Either ContinuityError ContinuityAnchor
plannedSemanticAnchor st = nextAnchorFor SemanticAdvance (emitterCommittedAnchor st)

-- | The next anchor an epoch rotation would commit, delegated to 'nextAnchorFor'.
plannedEpochAnchor :: EmitterState -> ContinuityDigest -> Either ContinuityError ContinuityAnchor
plannedEpochAnchor st = nextAnchorFor EpochInvalidation (emitterCommittedAnchor st)

-- | The sign-boundary result the interpreter feeds back for the staging phase.
data StageOutcome
  = -- | The advance was signed and staged against the current cursor.
    StageStaged
  | -- | The committed sequence is exhausted; the epoch must rotate first
    -- (correction 1/2). Only meaningful for an ownership advance.
    StageNeedsRotation
  deriving stock (Eq, Show)

-- | An effect completion the interpreter feeds back. 'DidFsyncCommit' carries
-- the new committed anchor the interpreter obtained from the staged next anchor,
-- which the kernel adopts wholesale.
data PhaseCompletion
  = DidFsyncStage
  | DidPublish
  | DidCommit
  | DidFsyncCommit !ContinuityAnchor
  deriving stock (Eq, Show)

-- | The phase a completion finishes (Staging is finished by 'StageResolved').
completionPhase :: PhaseCompletion -> EmitterPhase
completionPhase completion = case completion of
  DidFsyncStage -> PhaseFsyncingStage
  DidPublish -> PhasePublishing
  DidCommit -> PhaseCommitting
  DidFsyncCommit _ -> PhaseFsyncingCommit

data EmitterIntent
  = -- | Submit a request to the bounded mailbox (admission only; never starts
    -- work — a subsequent 'Pump' does).
    SubmitRequest !EmitterRequest
  | -- | Drive the actor at @now@: check the in-flight deadline, or (if idle)
    -- begin the next transition with the supplied absolute deadline.
    Pump !MonotonicInstant !Deadline
  | -- | Sign-boundary feedback for the staging phase, fenced by incarnation.
    StageResolved !Incarnation !StageOutcome
  | -- | A later-phase effect finished, fenced by incarnation.
    PhaseAdvanced !Incarnation !PhaseCompletion
  | -- | Crash-resume: re-drive the current phase's effect idempotently.
    Recover !MonotonicInstant
  | -- | A peer acknowledged every sequence up to and including this one.
    AckThrough !Word64
  deriving stock (Eq, Show)

data EmitterEffect
  = EffEmitHeartbeat !HeartbeatPayload
  | EffStage !TransitionAdmission !Deadline !StagedTransition
  | EffFsyncStage !TransitionAdmission !Deadline
  | EffPublish !TransitionAdmission !Deadline
  | EffCommit !TransitionAdmission !Deadline
  | EffFsyncCommit !TransitionAdmission !Deadline
  | EffCheckpointCompaction !RepairFloor
  deriving stock (Eq, Show)

data RejectReason
  = -- | Mailbox full and the request cannot coalesce.
    RejectMailboxFull !RetryAfter
  | -- | A pump tried to begin work while a transition was in flight.
    RejectBusy
  | -- | A completion carried a stale incarnation (expected, got).
    RejectStaleIncarnation !Incarnation !Incarnation
  | -- | A completion did not match the current phase and was not a replay.
    RejectUnexpectedCompletion
  | -- | The in-flight deadline expired before the transition reached publish.
    RejectDeadlineExpired
  deriving stock (Eq, Show)

data StepOutcome
  = OutcomeAccepted
  | OutcomeCoalesced
  | OutcomeNoOp
  | OutcomeRejected !RejectReason
  deriving stock (Eq, Show)

data EmitterStep = EmitterStep
  { stepState :: !EmitterState
  , stepEffects :: ![EmitterEffect]
  , stepOutcome :: !StepOutcome
  }
  deriving stock (Eq, Show)

noEffect :: EmitterState -> StepOutcome -> EmitterStep
noEffect st outcome = EmitterStep st [] outcome

-- | The one pure transition function. Every state mutation flows through here.
step :: EmitterState -> EmitterIntent -> EmitterStep
step st intent = case intent of
  SubmitRequest request -> stepSubmit st request
  Pump now deadline -> stepPump st now deadline
  StageResolved incarnation outcome -> stepStageResolved st incarnation outcome
  PhaseAdvanced incarnation completion -> stepPhaseAdvanced st incarnation completion
  Recover _now -> stepRecover st
  AckThrough sequenceNumber -> stepAck st sequenceNumber

stepSubmit :: EmitterState -> EmitterRequest -> EmitterStep
stepSubmit st request =
  case enqueue (emitterMailbox st) request of
    Mailbox.EnqueueAccepted mailbox' ->
      noEffect st {emitterMailbox = mailbox'} OutcomeAccepted
    Mailbox.EnqueueCoalesced mailbox' ->
      noEffect st {emitterMailbox = mailbox'} OutcomeCoalesced
    Mailbox.EnqueueRejected retry ->
      noEffect st (OutcomeRejected (RejectMailboxFull retry))

stepPump :: EmitterState -> MonotonicInstant -> Deadline -> EmitterStep
stepPump st now deadline =
  case emitterInFlight st of
    Just inflight -> pumpInFlight st inflight now
    Nothing -> pumpIdle st deadline

-- | With a transition in flight, a pump only enforces the absolute deadline.
-- Before publish the transition may be safely aborted; at or after publish it
-- must survive to be re-driven to commit via 'Recover'.
pumpInFlight :: EmitterState -> InFlight -> MonotonicInstant -> EmitterStep
pumpInFlight st inflight now
  | not (deadlineExpired now (inFlightDeadline inflight)) =
      noEffect st OutcomeNoOp
  | inFlightPublished inflight =
      noEffect st (OutcomeRejected RejectDeadlineExpired)
  | otherwise =
      noEffect st {emitterInFlight = Nothing} (OutcomeRejected RejectDeadlineExpired)

-- | Idle: pending rotation/advance takes priority over the mailbox, so a parked
-- advance is never starved by fresh heartbeats.
pumpIdle :: EmitterState -> Deadline -> EmitterStep
pumpIdle st deadline =
  case emitterPending st of
    Just (PendingRotationThenAdvance _) ->
      beginTransition st KindEpochRotation deadline
    Just (PendingAdvance transition) ->
      beginTransition st {emitterPending = Nothing} (KindOwnership transition) deadline
    Nothing -> pumpMailbox st deadline

pumpMailbox :: EmitterState -> Deadline -> EmitterStep
pumpMailbox st deadline =
  case dequeue (emitterMailbox st) of
    Nothing -> noEffect st OutcomeNoOp
    Just (request, mailbox') ->
      let drained = st {emitterMailbox = mailbox'}
       in case request of
            ReqHeartbeat payload ->
              EmitterStep drained [EffEmitHeartbeat payload] OutcomeAccepted
            ReqOwnership transition ->
              beginTransition drained (KindOwnership transition) deadline
            -- Correction 2: an external rotation message is a no-op; rotation is
            -- decided only at the sign boundary.
            ReqEpochRotation -> noEffect drained OutcomeNoOp
            ReqRecover -> noEffect drained OutcomeNoOp

beginTransition :: EmitterState -> DurableKind -> Deadline -> EmitterStep
beginTransition st kind deadline =
  let admission = TransitionAdmission (emitterAdmissionCounter st)
      inflight =
        InFlight
          { inFlightKind = kind
          , inFlightPhase = PhaseStaging
          , inFlightAdmission = admission
          , inFlightDeadline = deadline
          , inFlightIncarnation = emitterIncarnation st
          , inFlightPublished = False
          }
      st' =
        st
          { emitterInFlight = Just inflight
          , emitterAdmissionCounter = emitterAdmissionCounter st + 1
          }
   in EmitterStep
        st'
        [EffStage admission deadline (durableStagedTransition kind)]
        OutcomeAccepted

stepStageResolved :: EmitterState -> Incarnation -> StageOutcome -> EmitterStep
stepStageResolved st incarnation outcome =
  withFencedInFlight st incarnation (resolveStage st outcome)

resolveStage :: EmitterState -> StageOutcome -> InFlight -> EmitterStep
resolveStage st outcome inflight =
  case inFlightPhase inflight of
    PhaseStaging -> resolveStagingPhase st outcome inflight
    laterPhase
      | laterPhase > PhaseStaging -> noEffect st OutcomeNoOp
      | otherwise -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)

resolveStagingPhase :: EmitterState -> StageOutcome -> InFlight -> EmitterStep
resolveStagingPhase st outcome inflight = case outcome of
  StageStaged ->
    advancePhase st inflight PhaseFsyncingStage $
      EffFsyncStage (inFlightAdmission inflight) (inFlightDeadline inflight)
  StageNeedsRotation -> case inFlightKind inflight of
    KindOwnership transition ->
      -- Correction 1/4: park the UNSIGNED advance and clear the in-flight so the
      -- next pump begins a separately-ticketed rotation.
      noEffect
        st
          { emitterInFlight = Nothing
          , emitterPending = Just (PendingRotationThenAdvance transition)
          }
        OutcomeAccepted
    KindEpochRotation ->
      -- A rotation itself can never need a further rotation.
      noEffect st (OutcomeRejected RejectUnexpectedCompletion)

stepPhaseAdvanced :: EmitterState -> Incarnation -> PhaseCompletion -> EmitterStep
stepPhaseAdvanced st incarnation completion =
  withFencedInFlight st incarnation (advanceOnCompletion st completion)

advanceOnCompletion :: EmitterState -> PhaseCompletion -> InFlight -> EmitterStep
advanceOnCompletion st completion inflight =
  let owningPhase = completionPhase completion
      current = inFlightPhase inflight
   in if
        | owningPhase < current -> noEffect st OutcomeNoOp -- idempotent replay
        | owningPhase > current -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)
        | otherwise -> applyCompletion st inflight completion

applyCompletion :: EmitterState -> InFlight -> PhaseCompletion -> EmitterStep
applyCompletion st inflight completion = case completion of
  DidFsyncStage ->
    advancePhase st inflight PhasePublishing $
      EffPublish (inFlightAdmission inflight) (inFlightDeadline inflight)
  DidPublish ->
    advancePhasePublished st inflight PhaseCommitting $
      EffCommit (inFlightAdmission inflight) (inFlightDeadline inflight)
  DidCommit ->
    advancePhase st inflight PhaseFsyncingCommit $
      EffFsyncCommit (inFlightAdmission inflight) (inFlightDeadline inflight)
  DidFsyncCommit newAnchor -> finalize st inflight newAnchor

advancePhase :: EmitterState -> InFlight -> EmitterPhase -> EmitterEffect -> EmitterStep
advancePhase st inflight nextPhase effect =
  EmitterStep
    st {emitterInFlight = Just inflight {inFlightPhase = nextPhase}}
    [effect]
    OutcomeAccepted

advancePhasePublished :: EmitterState -> InFlight -> EmitterPhase -> EmitterEffect -> EmitterStep
advancePhasePublished st inflight nextPhase effect =
  EmitterStep
    st {emitterInFlight = Just inflight {inFlightPhase = nextPhase, inFlightPublished = True}}
    [effect]
    OutcomeAccepted

-- | Commit the finished transition: adopt the new committed anchor, record the
-- published sequence in the unacked repair set, run the size-triggered
-- checkpoint fold, and promote any parked advance behind a just-finished
-- rotation.
finalize :: EmitterState -> InFlight -> ContinuityAnchor -> EmitterStep
finalize st inflight newAnchor =
  let publishedSequence = continuityAnchorSequence newAnchor
      unacked = emitterUnacked st ++ [publishedSequence]
      (unacked', floor', compacted) =
        compactUnacked (emitterUnackedThreshold st) (emitterRepairFloor st) unacked
      pending' = promotePending (inFlightKind inflight) (emitterPending st)
      st' =
        st
          { emitterCommittedAnchor = newAnchor
          , emitterInFlight = Nothing
          , emitterPending = pending'
          , emitterUnacked = unacked'
          , emitterRepairFloor = floor'
          }
      effects = [EffCheckpointCompaction floor' | compacted]
   in EmitterStep st' effects OutcomeAccepted

-- | After a rotation finishes, a parked @PendingRotationThenAdvance@ becomes a
-- ready @PendingAdvance@. Any other finish leaves pending untouched.
promotePending :: DurableKind -> Maybe Pending -> Maybe Pending
promotePending KindEpochRotation (Just (PendingRotationThenAdvance transition)) =
  Just (PendingAdvance transition)
promotePending _ pending = pending

-- | Correction 3: keep at most @threshold@ individual unacked frames; fold the
-- older prefix into the signed checkpoint floor. Returns the retained suffix,
-- the (possibly raised) floor, and whether a compaction happened.
compactUnacked :: Natural -> RepairFloor -> [Word64] -> ([Word64], RepairFloor, Bool)
compactUnacked threshold floor0 unacked
  | fromIntegral (length unacked) <= threshold = (unacked, floor0, False)
  | otherwise =
      let keep = fromIntegral threshold
          dropCount = length unacked - keep
          (dropped, retained) = splitAt dropCount unacked
          floor' = case dropped of
            [] -> floor0
            _ -> RepairFloor (Just (maximum dropped))
       in (retained, floor', True)

stepRecover :: EmitterState -> EmitterStep
stepRecover st =
  case emitterInFlight st of
    Nothing -> noEffect st OutcomeNoOp
    Just inflight ->
      EmitterStep st [recoverEffect inflight] OutcomeAccepted

-- | The idempotent effect to re-drive the current phase after a crash. Staging
-- re-stages; every later phase re-issues its own effect. Re-driving is safe
-- because journal fsync, publish, and CAS commit are all idempotent.
recoverEffect :: InFlight -> EmitterEffect
recoverEffect inflight =
  let admission = inFlightAdmission inflight
      deadline = inFlightDeadline inflight
   in case inFlightPhase inflight of
        PhaseStaging -> EffStage admission deadline (durableStagedTransition (inFlightKind inflight))
        PhaseFsyncingStage -> EffFsyncStage admission deadline
        PhasePublishing -> EffPublish admission deadline
        PhaseCommitting -> EffCommit admission deadline
        PhaseFsyncingCommit -> EffFsyncCommit admission deadline

stepAck :: EmitterState -> Word64 -> EmitterStep
stepAck st sequenceNumber =
  noEffect st {emitterUnacked = filter (> sequenceNumber) (emitterUnacked st)} OutcomeAccepted

-- | Run @body@ only when the in-flight incarnation matches the given one, fencing
-- out completions from a superseded mount. With no in-flight transition the
-- completion is an out-of-order no-op reject.
withFencedInFlight
  :: EmitterState
  -> Incarnation
  -> (InFlight -> EmitterStep)
  -> EmitterStep
withFencedInFlight st incarnation body =
  case emitterInFlight st of
    Nothing -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)
    Just inflight
      | inFlightIncarnation inflight /= incarnation ->
          noEffect
            st
            (OutcomeRejected (RejectStaleIncarnation (inFlightIncarnation inflight) incarnation))
      | otherwise -> body inflight
