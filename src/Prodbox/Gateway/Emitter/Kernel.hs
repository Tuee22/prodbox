{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure single-writer emitter transition kernel.
--
-- One actor owns an emitter and serializes every heartbeat, ownership change,
-- and epoch invalidation through @stage -> fsync -> publish -> commit ->
-- fsync@.  The kernel retains the exact signed bytes and derived continuity
-- anchor after the sign boundary, so a retry can never substitute a different
-- payload.  A bounded per-peer acknowledgement suffix is compacted only after
-- a signed checkpoint has been installed.
module Prodbox.Gateway.Emitter.Kernel
  ( -- * Fencing identities
    Incarnation
  , incarnationZero
  , incarnationValue
  , mkIncarnation
  , TransitionAdmission
  , transitionAdmissionValue
  , EmitterPeer
  , mkEmitterPeer
  , emitterPeerText

    -- * Phases and transition kinds
  , EmitterPhase (..)
  , DurableKind (..)
  , durableStagedTransition
  , StagePlan
  , stagePlanKind
  , stagePlanTransition
  , stagePlanPreviousAnchor
  , stagePlanIncarnation
  , StagedRecord
  , stagedRecordKind
  , stagedRecordTransition
  , stagedRecordSignedBytes
  , stagedRecordPreviousAnchor
  , stagedRecordNextAnchor
  , stagedRecordIncarnation

    -- * In-flight transition
  , InFlight
  , inFlightKind
  , inFlightPhase
  , inFlightAdmission
  , inFlightDeadline
  , inFlightIncarnation
  , inFlightPreviousAnchor
  , inFlightStagedRecord
  , inFlightPublished

    -- * Pending (parked) work
  , PendingRequest (..)
  , Pending (..)

    -- * Per-peer acknowledgement and repair
  , AckPoint
  , mkAckPoint
  , ackPointIncarnation
  , ackPointAnchor
  , UnackedAssertion
  , unackedAssertionRecord
  , unackedAssertionWaitingPeers
  , CheckpointCandidate
  , checkpointCandidatePreviousFloor
  , checkpointCandidateAssertions
  , checkpointCandidateThrough
  , RepairFloor
  , repairFloorSequence
  , repairFloorAnchor
  , repairFloorIncarnation
  , repairFloorSignedBytes
  , emptyRepairFloor

    -- * State
  , EmitterState
  , mkEmitterState
  , mkEmitterStateForPeers
  , mkEmitterStateRestored
  , emitterCommittedAnchor
  , emitterGenesisAnchor
  , emitterIncarnation
  , emitterPreviousOrdersDigest
  , emitterInFlight
  , emitterPending
  , emitterMailbox
  , emitterPeers
  , emitterPeerAcknowledgements
  , emitterUnacked
  , emitterLatestCommitted
  , emitterRepairFloor
  , emitterCheckpointPending
  , emitterUnackedThreshold
  , advanceIncarnation
  , rebaseEmitterIncarnation
  , migrateEmitterOrders

    -- * Bounded durable projection
  , DurableProjectionBoundField (..)
  , DurableProjectionBounds
  , mkDurableProjectionBounds
  , DurableEmitterProjection
  , projectDurableEmitterState
  , encodeDurableEmitterProjection
  , decodeDurableEmitterProjection
  , restoreDurableEmitterState
  , durableProjectionCommittedAnchor
  , durableProjectionGenesisAnchor
  , durableProjectionIncarnation
  , durableProjectionPreviousOrdersDigest
  , durableProjectionNextAdmission
  , durableProjectionLatestCommitted
  , durableProjectionStagedRecord
  , durableProjectionPeerAcknowledgements
  , durableProjectionUnackedCount
  , DurableProjectionError (..)

    -- * Sign-boundary anchor planning
  , plannedSemanticAnchor
  , plannedEpochAnchor

    -- * Intents, effects, outcomes
  , BoundedSignedPayload
  , mkBoundedSignedPayload
  , boundedSignedPayloadBytes
  , SignedPayloadError (..)
  , StageOutcome (..)
  , PhaseCompletion (..)
  , CheckpointOutcome (..)
  , RecoveryReplay
  , recoveryReplayGenesisAnchor
  , recoveryReplayPreviousOrdersDigest
  , recoveryReplayCheckpoint
  , recoveryReplayAssertions
  , recoveryReplayPendingPublications
  , recoveryReplayAssertionCount
  , recoveryReplaySignedBytes
  , EmitterIntent (..)
  , EmitterEffect (..)
  , RejectReason (..)
  , StepOutcome (..)
  , EmitterStep (..)

    -- * The transition kernel
  , step
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Generics (Generic)
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
  , continuityAnchorEpoch
  , continuityAnchorPreviousDigest
  , continuityAnchorSequence
  , continuityDigestBytes
  , mkContinuityDigest
  , nextAnchorFor
  )
import Prodbox.Gateway.Emitter.Mailbox
  ( EmitterRequest (..)
  , HeartbeatPayload
  , Mailbox
  , OwnershipTransition (..)
  , dequeue
  , dequeueRecovery
  , enqueue
  )
import Prodbox.Gateway.Emitter.Mailbox qualified as Mailbox
import Prodbox.Gateway.State
  ( EmitterIncarnation
  , emitterIncarnationValue
  , emitterIncarnationZero
  , mkEmitterIncarnation
  )

-- | The canonical emitter-incarnation type is shared with signed peer state.
type Incarnation = EmitterIncarnation

incarnationZero :: Incarnation
incarnationZero = emitterIncarnationZero

incarnationValue :: Incarnation -> Word64
incarnationValue = emitterIncarnationValue

mkIncarnation :: Word64 -> Incarnation
mkIncarnation = mkEmitterIncarnation

-- | Opaque, monotonically increasing admission for one logical transition.
newtype TransitionAdmission = TransitionAdmission Word64
  deriving stock (Eq, Generic, Ord, Show)

instance Serialise TransitionAdmission

transitionAdmissionValue :: TransitionAdmission -> Word64
transitionAdmissionValue (TransitionAdmission value) = value

-- | Stable identity of one current peer whose acknowledgement is required.
newtype EmitterPeer = EmitterPeer Text
  deriving stock (Eq, Generic, Ord, Show)

instance Serialise EmitterPeer

mkEmitterPeer :: Text -> Maybe EmitterPeer
mkEmitterPeer raw =
  let normalized = Text.strip raw
   in if Text.null normalized then Nothing else Just (EmitterPeer normalized)

emitterPeerText :: EmitterPeer -> Text
emitterPeerText (EmitterPeer value) = value

data EmitterPhase
  = PhaseStaging
  | PhaseFsyncingStage
  | PhasePublishing
  | PhaseCommitting
  | PhaseFsyncingCommit
  deriving stock (Bounded, Enum, Eq, Generic, Ord, Show)

instance Serialise EmitterPhase

-- | Every externally visible assertion is durable.  In particular, a
-- heartbeat carries its exact observed timestamp through the same protocol as
-- ownership evidence.
data DurableKind
  = KindHeartbeat !HeartbeatPayload
  | KindOwnership !OwnershipTransition
  | KindEpochRotation
  | KindOrdersMigration !ContinuityDigest
  deriving stock (Eq, Generic, Show)

instance Serialise DurableKind

durableStagedTransition :: DurableKind -> StagedTransition
durableStagedTransition kind = case kind of
  KindHeartbeat _ -> SemanticAdvance
  KindOwnership _ -> SemanticAdvance
  KindEpochRotation -> EpochInvalidation
  KindOrdersMigration _ -> OrdersScopeInvalidation

-- | Exact input to the signing/staging boundary.
data StagePlan = StagePlan
  { stagePlanKind :: !DurableKind
  , stagePlanTransition :: !StagedTransition
  , stagePlanPreviousAnchor :: !ContinuityAnchor
  , stagePlanIncarnation :: !Incarnation
  }
  deriving stock (Eq, Show)

-- | Exact immutable output of the signing boundary.  Every subsequent effect
-- carries this value unchanged.
data StagedRecord = StagedRecord
  { stagedRecordKind :: !DurableKind
  , stagedRecordTransition :: !StagedTransition
  , stagedRecordSignedBytes :: !ByteString
  , stagedRecordPreviousAnchor :: !ContinuityAnchor
  , stagedRecordNextAnchor :: !ContinuityAnchor
  , stagedRecordIncarnation :: !Incarnation
  }
  deriving stock (Eq, Generic, Show)

instance Serialise StagedRecord

data InFlight = InFlight
  { inFlightKind :: !DurableKind
  , inFlightPhase :: !EmitterPhase
  , inFlightAdmission :: !TransitionAdmission
  , inFlightDeadline :: !Deadline
  , inFlightIncarnation :: !Incarnation
  -- ^ Mount incarnation allowed to complete effects.  A recovered staged
  -- assertion may itself have been signed by an older incarnation.
  , inFlightPreviousAnchor :: !ContinuityAnchor
  , inFlightStagedRecord :: !(Maybe StagedRecord)
  , inFlightPublished :: !Bool
  }
  deriving stock (Eq, Show)

data PendingRequest
  = PendingHeartbeat !HeartbeatPayload
  | PendingOwnership !OwnershipTransition
  deriving stock (Eq, Generic, Show)

instance Serialise PendingRequest

data Pending
  = PendingRotationThenAdvance !PendingRequest
  | PendingAdvance !PendingRequest
  | PendingOrdersMigration !ContinuityDigest
  deriving stock (Eq, Generic, Show)

instance Serialise Pending

data AckPoint = AckPoint
  { ackPointIncarnation :: !Incarnation
  , ackPointAnchor :: !ContinuityAnchor
  }
  deriving stock (Eq, Generic, Ord, Show)

instance Serialise AckPoint

mkAckPoint :: Incarnation -> ContinuityAnchor -> AckPoint
mkAckPoint = AckPoint

data UnackedAssertion = UnackedAssertion
  { unackedAssertionRecord :: !StagedRecord
  , unackedAssertionWaitingPeers :: !(Set EmitterPeer)
  }
  deriving stock (Eq, Generic, Show)

instance Serialise UnackedAssertion

data RepairFloor
  = EmptyRepairFloor
  | InstalledRepairFloor
      { internalRepairFloorPoint :: !AckPoint
      , internalRepairFloorSignedBytes :: !ByteString
      }
  deriving stock (Eq, Generic, Show)

instance Serialise RepairFloor

emptyRepairFloor :: RepairFloor
emptyRepairFloor = EmptyRepairFloor

repairFloorSequence :: RepairFloor -> Maybe Word64
repairFloorSequence floor0 = continuityAnchorSequence <$> repairFloorAnchor floor0

repairFloorAnchor :: RepairFloor -> Maybe ContinuityAnchor
repairFloorAnchor floor0 = case floor0 of
  EmptyRepairFloor -> Nothing
  InstalledRepairFloor point _ -> Just (ackPointAnchor point)

repairFloorIncarnation :: RepairFloor -> Maybe Incarnation
repairFloorIncarnation floor0 = case floor0 of
  EmptyRepairFloor -> Nothing
  InstalledRepairFloor point _ -> Just (ackPointIncarnation point)

repairFloorSignedBytes :: RepairFloor -> Maybe ByteString
repairFloorSignedBytes floor0 = case floor0 of
  EmptyRepairFloor -> Nothing
  InstalledRepairFloor _ bytes -> Just bytes

-- | A proposed signed compaction.  Its prefix remains in 'emitterUnacked'
-- until 'CheckpointInstalled' is observed, so a failed signer cannot discard
-- repair evidence.
data CheckpointCandidate = CheckpointCandidate
  { checkpointCandidatePreviousFloor :: !RepairFloor
  , checkpointCandidateAssertions :: ![UnackedAssertion]
  , checkpointCandidateThrough :: !AckPoint
  }
  deriving stock (Eq, Generic, Show)

instance Serialise CheckpointCandidate

data EmitterState = EmitterState
  { emitterGenesisAnchor :: !ContinuityAnchor
  , emitterCommittedAnchor :: !ContinuityAnchor
  , emitterIncarnation :: !Incarnation
  , emitterPreviousOrdersDigest :: !(Maybe ContinuityDigest)
  , emitterInFlight :: !(Maybe InFlight)
  , emitterPending :: !(Maybe Pending)
  , emitterMailbox :: !Mailbox
  , emitterPeers :: !(Set EmitterPeer)
  , emitterPeerAcknowledgements :: !(Map EmitterPeer (Maybe AckPoint))
  , emitterUnacked :: ![UnackedAssertion]
  , emitterLatestCommitted :: !(Maybe StagedRecord)
  , emitterRepairFloor :: !RepairFloor
  , emitterCheckpointPending :: !(Maybe CheckpointCandidate)
  , emitterUnackedThreshold :: !Natural
  , emitterAdmissionCounter :: !(Maybe Word64)
  -- ^ 'Nothing' means the fixed-width admission space is exhausted.
  }
  deriving stock (Eq, Show)

-- | Compatibility constructor for an emitter with no remote peers and a fresh
-- admission counter.
mkEmitterState :: ContinuityAnchor -> Incarnation -> Mailbox -> Natural -> EmitterState
mkEmitterState anchor incarnation mailbox threshold =
  mkEmitterStateForPeers anchor incarnation mailbox threshold []

mkEmitterStateForPeers
  :: ContinuityAnchor
  -> Incarnation
  -> Mailbox
  -> Natural
  -> [EmitterPeer]
  -> EmitterState
mkEmitterStateForPeers anchor incarnation mailbox threshold peers =
  mkEmitterStateRestored anchor incarnation mailbox threshold peers (Just 0)

-- | Restore the pure projection, including the next admission.  Passing
-- 'Nothing' represents a journal whose admission counter is exhausted.
mkEmitterStateRestored
  :: ContinuityAnchor
  -> Incarnation
  -> Mailbox
  -> Natural
  -> [EmitterPeer]
  -> Maybe Word64
  -> EmitterState
mkEmitterStateRestored anchor incarnation mailbox threshold peers nextAdmission =
  let peerSet = Set.fromList peers
   in EmitterState
        { emitterGenesisAnchor = anchor
        , emitterCommittedAnchor = anchor
        , emitterIncarnation = incarnation
        , emitterPreviousOrdersDigest = Nothing
        , emitterInFlight = Nothing
        , emitterPending = Nothing
        , emitterMailbox = mailbox
        , emitterPeers = peerSet
        , emitterPeerAcknowledgements = Map.fromSet (const Nothing) peerSet
        , emitterUnacked = []
        , emitterLatestCommitted = Nothing
        , emitterRepairFloor = emptyRepairFloor
        , emitterCheckpointPending = Nothing
        , emitterUnackedThreshold = threshold
        , emitterAdmissionCounter = nextAdmission
        }

-- | Take a new durable mount incarnation without modular wrap.
advanceIncarnation :: EmitterState -> Either RejectReason EmitterState
advanceIncarnation st
  | incarnationValue (emitterIncarnation st) == maxBound =
      Left RejectIncarnationExhausted
  | otherwise =
      rebaseEmitterIncarnation
        (mkIncarnation (incarnationValue (emitterIncarnation st) + 1))
        st

-- | Re-fence restored state to the exact non-zero incarnation already made
-- durable by the outer journal.  Equality is idempotent, skipped mount values
-- are allowed (a process may crash after the journal bump but before rewriting
-- its inner projection), and a backward or wrapped-to-zero target is rejected.
-- Exact staged work keeps its immutable signed identity and admission; only
-- the live mount fence changes.  Unsigned work is parked for a separately
-- ticketed transition with a fresh admission.
rebaseEmitterIncarnation
  :: Incarnation
  -> EmitterState
  -> Either RejectReason EmitterState
rebaseEmitterIncarnation target st
  | target == incarnationZero = Left RejectZeroIncarnation
  | target < current = Left (RejectIncarnationRegression current target)
  | target == current = Right st
  | otherwise =
      let (recoveredInFlight, recoveredPending) =
            rebaseInFlight target (emitterInFlight st) (emitterPending st)
       in Right
            st
              { emitterIncarnation = target
              , emitterInFlight = recoveredInFlight
              , emitterPending = recoveredPending
              }
 where
  current = emitterIncarnation st

-- | Enter a new authenticated Orders scope without carrying signatures from
-- the old scope across that boundary. The last committed continuity anchor is
-- retained as the new trusted base, while all old-Orders acknowledgements,
-- repair evidence, and callbacks are discarded. A newly fenced, separately
-- admitted epoch invalidation must complete before semantic work can resume.
migrateEmitterOrders
  :: ContinuityDigest
  -> Incarnation
  -> Mailbox
  -> Natural
  -> [EmitterPeer]
  -> EmitterState
  -> Either RejectReason EmitterState
migrateEmitterOrders previousOrdersDigest target mailbox threshold peers st
  | incarnationValue (emitterIncarnation st) == maxBound =
      Left RejectIncarnationExhausted
  | continuityAnchorEpoch (emitterCommittedAnchor st) == maxBound =
      Left RejectOrdersMigrationEpochExhausted
  | target == incarnationZero = Left RejectZeroIncarnation
  | target <= emitterIncarnation st =
      Left (RejectIncarnationRegression (emitterIncarnation st) target)
  | otherwise =
      let base = emitterCommittedAnchor st
          peerSet = Set.fromList peers
       in Right
            EmitterState
              { emitterGenesisAnchor = base
              , emitterCommittedAnchor = base
              , emitterIncarnation = target
              , emitterPreviousOrdersDigest = Just previousOrdersDigest
              , emitterInFlight = Nothing
              , emitterPending = Just (PendingOrdersMigration previousOrdersDigest)
              , emitterMailbox = mailbox
              , emitterPeers = peerSet
              , emitterPeerAcknowledgements = Map.fromSet (const Nothing) peerSet
              , emitterUnacked = []
              , emitterLatestCommitted = Nothing
              , emitterRepairFloor = emptyRepairFloor
              , emitterCheckpointPending = Nothing
              , emitterUnackedThreshold = threshold
              , emitterAdmissionCounter = Just 0
              }

rebaseInFlight
  :: Incarnation
  -> Maybe InFlight
  -> Maybe Pending
  -> (Maybe InFlight, Maybe Pending)
rebaseInFlight target maybeInFlight pending =
  case maybeInFlight of
    Nothing -> (Nothing, pending)
    Just inflight@InFlight {inFlightStagedRecord = Just _} ->
      (Just inflight {inFlightIncarnation = target}, pending)
    Just inflight ->
      (Nothing, parkUnsignedKind (inFlightKind inflight) pending)

parkUnsignedKind :: DurableKind -> Maybe Pending -> Maybe Pending
parkUnsignedKind kind pending =
  case pendingRequestFor kind of
    Nothing -> pending
    Just request -> case pending of
      Nothing -> Just (PendingAdvance request)
      Just existing -> Just existing

-- Durable projection ---------------------------------------------------------

data DurableProjectionBoundField
  = ProjectionMaximumEncodedBytes
  | ProjectionMaximumAssertionBytes
  | ProjectionMaximumCheckpointBytes
  | ProjectionMaximumPeers
  | ProjectionMaximumRetainedAssertions
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data DurableProjectionBounds = DurableProjectionBounds
  { projectionMaximumEncodedBytes :: !Natural
  , projectionMaximumAssertionBytes :: !Natural
  , projectionMaximumCheckpointBytes :: !Natural
  , projectionMaximumPeers :: !Natural
  , projectionMaximumRetainedAssertions :: !Natural
  }
  deriving stock (Eq, Show)

mkDurableProjectionBounds
  :: Natural
  -- ^ Maximum encoded projection bytes.
  -> Natural
  -- ^ Maximum bytes in any exact signed assertion.
  -> Natural
  -- ^ Maximum bytes in an exact signed repair checkpoint.
  -> Natural
  -- ^ Maximum current peers.
  -> Natural
  -- ^ Maximum total unacked plus pending-checkpoint assertion entries.
  -> Either DurableProjectionError DurableProjectionBounds
mkDurableProjectionBounds encodedBytes assertionBytes checkpointBytes peers assertions = do
  requireProjectionBound ProjectionMaximumEncodedBytes encodedBytes
  requireProjectionBound ProjectionMaximumAssertionBytes assertionBytes
  requireProjectionBound ProjectionMaximumCheckpointBytes checkpointBytes
  requireProjectionBound ProjectionMaximumPeers peers
  requireProjectionBound ProjectionMaximumRetainedAssertions assertions
  Right
    DurableProjectionBounds
      { projectionMaximumEncodedBytes = encodedBytes
      , projectionMaximumAssertionBytes = assertionBytes
      , projectionMaximumCheckpointBytes = checkpointBytes
      , projectionMaximumPeers = peers
      , projectionMaximumRetainedAssertions = assertions
      }

requireProjectionBound
  :: DurableProjectionBoundField
  -> Natural
  -> Either DurableProjectionError ()
requireProjectionBound field value =
  when (value == 0) (Left (DurableProjectionBoundMustBePositive field))

-- | Durable in-flight shape.  Deadline is deliberately absent: recovery gets
-- a fresh absolute deadline from the actor that mounts the projection.
data DurableInFlight = DurableInFlight
  { durableInFlightKind :: !DurableKind
  , durableInFlightPhase :: !EmitterPhase
  , durableInFlightAdmission :: !TransitionAdmission
  , durableInFlightMountIncarnation :: !Incarnation
  , durableInFlightPreviousAnchor :: !ContinuityAnchor
  , durableInFlightPublished :: !Bool
  , durableInFlightRecord :: !(Maybe StagedRecord)
  }
  deriving stock (Eq, Generic, Show)

instance Serialise DurableInFlight

-- | Opaque, versioned durable state.  It contains no mailbox and no clock or
-- deadline value, so decoding it cannot revive stale volatile scheduling
-- state.
data DurableEmitterProjection = DurableEmitterProjection
  { durableProjectionGenesisAnchor :: !ContinuityAnchor
  , durableProjectionCommittedAnchor :: !ContinuityAnchor
  , durableProjectionIncarnation :: !Incarnation
  , durableProjectionPreviousOrdersDigest :: !(Maybe ContinuityDigest)
  , durableProjectionPending :: !(Maybe Pending)
  , durableProjectionPeers :: !(Set EmitterPeer)
  , durableProjectionPeerAcknowledgements :: !(Map EmitterPeer (Maybe AckPoint))
  , durableProjectionUnacked :: ![UnackedAssertion]
  , durableProjectionLatestCommitted :: !(Maybe StagedRecord)
  , durableProjectionRepairFloor :: !RepairFloor
  , durableProjectionCheckpointPending :: !(Maybe CheckpointCandidate)
  , durableProjectionUnackedThreshold :: !Natural
  , durableProjectionNextAdmission :: !(Maybe Word64)
  , durableProjectionInFlight :: !(Maybe DurableInFlight)
  }
  deriving stock (Eq, Generic, Show)

instance Serialise DurableEmitterProjection

data VersionedDurableEmitterProjection = VersionedDurableEmitterProjection
  { versionedProjectionVersion :: !Word64
  , versionedProjectionValue :: !DurableEmitterProjection
  }
  deriving stock (Eq, Generic, Show)

instance Serialise VersionedDurableEmitterProjection

durableProjectionFormatVersion :: Word64
durableProjectionFormatVersion = 3

data DurableProjectionError
  = DurableProjectionBoundMustBePositive !DurableProjectionBoundField
  | DurableProjectionEncodedBytesExceeded !Natural !Natural
  | DurableProjectionSignedBytesMustNotBeEmpty !Text
  | DurableProjectionSignedBytesExceeded !Text !Natural !Natural
  | DurableProjectionPeerCountExceeded !Natural !Natural
  | DurableProjectionRetainedAssertionCountExceeded !Natural !Natural
  | DurableProjectionThresholdExceeded !Natural !Natural
  | DurableProjectionDecodeFailed !Text
  | DurableProjectionNonCanonical
  | DurableProjectionVersionMismatch !Word64 !Word64
  | DurableProjectionContinuityInvalid !ContinuityError
  | DurableProjectionInvariantViolation !Text
  | DurableProjectionChainDiscontinuity !Natural
  | DurableProjectionLatestSuffixMismatch
  | DurableProjectionUnknownAckPoint !EmitterPeer !AckPoint
  | DurableProjectionWaitingPeersMismatch
      !AckPoint
      !(Set EmitterPeer)
      !(Set EmitterPeer)
  | DurableProjectionCheckpointPrefixMismatch
  deriving stock (Eq, Show)

-- | Capture only state that must survive a process mount.  An unsigned staging
-- attempt retains its bounded typed request and admission; once signing has
-- completed, the same slot additionally retains the exact immutable record.
projectDurableEmitterState :: EmitterState -> DurableEmitterProjection
projectDurableEmitterState st =
  DurableEmitterProjection
    { durableProjectionGenesisAnchor = emitterGenesisAnchor st
    , durableProjectionCommittedAnchor = emitterCommittedAnchor st
    , durableProjectionIncarnation = emitterIncarnation st
    , durableProjectionPreviousOrdersDigest = emitterPreviousOrdersDigest st
    , durableProjectionPending = emitterPending st
    , durableProjectionPeers = emitterPeers st
    , durableProjectionPeerAcknowledgements = emitterPeerAcknowledgements st
    , durableProjectionUnacked = emitterUnacked st
    , durableProjectionLatestCommitted = emitterLatestCommitted st
    , durableProjectionRepairFloor = emitterRepairFloor st
    , durableProjectionCheckpointPending = emitterCheckpointPending st
    , durableProjectionUnackedThreshold = emitterUnackedThreshold st
    , durableProjectionNextAdmission = emitterAdmissionCounter st
    , durableProjectionInFlight = durableInFlightFromState <$> emitterInFlight st
    }

durableInFlightFromState :: InFlight -> DurableInFlight
durableInFlightFromState inflight =
  DurableInFlight
    { durableInFlightKind = inFlightKind inflight
    , durableInFlightPhase = inFlightPhase inflight
    , durableInFlightAdmission = inFlightAdmission inflight
    , durableInFlightMountIncarnation = inFlightIncarnation inflight
    , durableInFlightPreviousAnchor = inFlightPreviousAnchor inflight
    , durableInFlightPublished = inFlightPublished inflight
    , durableInFlightRecord = inFlightStagedRecord inflight
    }

durableProjectionStagedRecord :: DurableEmitterProjection -> Maybe StagedRecord
durableProjectionStagedRecord projection =
  durableInFlightRecord =<< durableProjectionInFlight projection

durableProjectionUnackedCount :: DurableEmitterProjection -> Natural
durableProjectionUnackedCount = fromIntegral . length . durableProjectionUnacked

encodeDurableEmitterProjection
  :: DurableProjectionBounds
  -> DurableEmitterProjection
  -> Either DurableProjectionError ByteString
encodeDurableEmitterProjection bounds projection = do
  validateDurableProjection bounds projection
  let encoded =
        BL.toStrict
          ( serialise
              VersionedDurableEmitterProjection
                { versionedProjectionVersion = durableProjectionFormatVersion
                , versionedProjectionValue = projection
                }
          )
  validateProjectionEncodedBytes bounds encoded
  Right encoded

decodeDurableEmitterProjection
  :: DurableProjectionBounds
  -> ByteString
  -> Either DurableProjectionError DurableEmitterProjection
decodeDurableEmitterProjection bounds encoded = do
  validateProjectionEncodedBytes bounds encoded
  versioned <-
    first
      (DurableProjectionDecodeFailed . Text.pack . show)
      (deserialiseOrFail (BL.fromStrict encoded))
  unless
    (BL.toStrict (serialise versioned) == encoded)
    (Left DurableProjectionNonCanonical)
  unless
    (versionedProjectionVersion versioned == durableProjectionFormatVersion)
    ( Left
        ( DurableProjectionVersionMismatch
            durableProjectionFormatVersion
            (versionedProjectionVersion versioned)
        )
    )
  let projection = versionedProjectionValue versioned
  validateDurableProjection bounds projection
  Right projection

validateProjectionEncodedBytes
  :: DurableProjectionBounds
  -> ByteString
  -> Either DurableProjectionError ()
validateProjectionEncodedBytes bounds encoded =
  let actual = fromIntegral (BS.length encoded)
      allowed = projectionMaximumEncodedBytes bounds
   in when
        (actual > allowed)
        (Left (DurableProjectionEncodedBytesExceeded actual allowed))

-- | Rehydrate the pure kernel with caller-owned volatile scheduling values.
-- Exact staged work resumes at its recorded phase under the supplied fresh
-- deadline. An unsigned pre-sign attempt retains only its typed durable intent
-- and old admission until recovery aborts it and admits a separately-ticketed
-- retry.
restoreDurableEmitterState
  :: Mailbox
  -> Deadline
  -> DurableEmitterProjection
  -> Either DurableProjectionError EmitterState
restoreDurableEmitterState mailbox recoveryDeadline projection =
  Right
    EmitterState
      { emitterGenesisAnchor = durableProjectionGenesisAnchor projection
      , emitterCommittedAnchor = durableProjectionCommittedAnchor projection
      , emitterIncarnation = durableProjectionIncarnation projection
      , emitterPreviousOrdersDigest = durableProjectionPreviousOrdersDigest projection
      , emitterInFlight =
          restoreDurableInFlight recoveryDeadline
            <$> durableProjectionInFlight projection
      , emitterPending = durableProjectionPending projection
      , emitterMailbox = mailbox
      , emitterPeers = durableProjectionPeers projection
      , emitterPeerAcknowledgements =
          durableProjectionPeerAcknowledgements projection
      , emitterUnacked = durableProjectionUnacked projection
      , emitterLatestCommitted = durableProjectionLatestCommitted projection
      , emitterRepairFloor = durableProjectionRepairFloor projection
      , emitterCheckpointPending =
          durableProjectionCheckpointPending projection
      , emitterUnackedThreshold = durableProjectionUnackedThreshold projection
      , emitterAdmissionCounter = durableProjectionNextAdmission projection
      }

restoreDurableInFlight :: Deadline -> DurableInFlight -> InFlight
restoreDurableInFlight recoveryDeadline durable =
  InFlight
    { inFlightKind = durableInFlightKind durable
    , inFlightPhase = durableInFlightPhase durable
    , inFlightAdmission = durableInFlightAdmission durable
    , inFlightDeadline = recoveryDeadline
    , inFlightIncarnation = durableInFlightMountIncarnation durable
    , inFlightPreviousAnchor = durableInFlightPreviousAnchor durable
    , inFlightStagedRecord = durableInFlightRecord durable
    , inFlightPublished = durableInFlightPublished durable
    }

validateDurableProjection
  :: DurableProjectionBounds
  -> DurableEmitterProjection
  -> Either DurableProjectionError ()
validateDurableProjection bounds projection = do
  let peerCount = fromIntegral (Set.size (durableProjectionPeers projection))
      candidateAssertions =
        maybe [] checkpointCandidateAssertions (durableProjectionCheckpointPending projection)
      retainedCount =
        fromIntegral
          (length (durableProjectionUnacked projection) + length candidateAssertions)
  when
    (peerCount > projectionMaximumPeers bounds)
    (Left (DurableProjectionPeerCountExceeded peerCount (projectionMaximumPeers bounds)))
  when
    (retainedCount > projectionMaximumRetainedAssertions bounds)
    ( Left
        ( DurableProjectionRetainedAssertionCountExceeded
            retainedCount
            (projectionMaximumRetainedAssertions bounds)
        )
    )
  when
    (durableProjectionUnackedThreshold projection > projectionMaximumRetainedAssertions bounds)
    ( Left
        ( DurableProjectionThresholdExceeded
            (durableProjectionUnackedThreshold projection)
            (projectionMaximumRetainedAssertions bounds)
        )
    )
  unless
    ( Map.keysSet (durableProjectionPeerAcknowledgements projection)
        == durableProjectionPeers projection
    )
    (Left (DurableProjectionInvariantViolation "peer acknowledgement membership mismatch"))
  traverse_ validatePending (durableProjectionPending projection)
  traverse_
    (validateUnacked bounds (durableProjectionPeers projection))
    (durableProjectionUnacked projection)
  traverse_
    (validateUnacked bounds (durableProjectionPeers projection))
    candidateAssertions
  traverse_ (validateCommittedUnacked projection) (durableProjectionUnacked projection)
  traverse_ (validateCommittedUnacked projection) candidateAssertions
  validateStrictRecordOrder (durableProjectionUnacked projection)
  validateProjectionChain projection
  traverse_
    (validateStagedRecord bounds "latest committed assertion")
    (durableProjectionLatestCommitted projection)
  validateLatestAnchor projection
  validateRepairFloor bounds (durableProjectionRepairFloor projection)
  traverse_
    (validateCheckpointCandidate bounds projection)
    (durableProjectionCheckpointPending projection)
  traverse_ (validateDurableInFlight bounds projection) (durableProjectionInFlight projection)
  validateAckProjection projection
  validateWaitingPeers projection
  validateOrdersMigrationProjection projection
  when
    ( durableProjectionCheckpointPending projection /= Nothing
        && durableProjectionInFlight projection /= Nothing
    )
    (Left (DurableProjectionInvariantViolation "checkpoint and transition both in flight"))

validateOrdersMigrationProjection
  :: DurableEmitterProjection
  -> Either DurableProjectionError ()
validateOrdersMigrationProjection projection = do
  traverse_
    validateMigrationDigest
    (durableProjectionPreviousOrdersDigest projection)
  traverse_
    ( validateOrdersMigrationRecord projection "retained assertion"
        . unackedAssertionRecord
    )
    (durableProjectionUnacked projection)
  traverse_
    (validateOrdersMigrationRecord projection "pending-checkpoint assertion")
    ( maybe
        []
        (map unackedAssertionRecord . checkpointCandidateAssertions)
        (durableProjectionCheckpointPending projection)
    )
  traverse_
    (validateOrdersMigrationRecord projection "latest committed assertion")
    (durableProjectionLatestCommitted projection)
  traverse_
    (validateOrdersMigrationInFlight projection)
    (durableProjectionInFlight projection)
  case durableProjectionPending projection of
    Just (PendingOrdersMigration digest) -> do
      validateOrdersDigestEvidence projection "pending Orders migration" digest
      unless
        (durableProjectionGenesisAnchor projection == durableProjectionCommittedAnchor projection)
        (Left (DurableProjectionInvariantViolation "Orders migration base is not the committed anchor"))
      unless
        ( null (durableProjectionUnacked projection)
            && durableProjectionLatestCommitted projection == Nothing
            && durableProjectionRepairFloor projection == EmptyRepairFloor
            && durableProjectionCheckpointPending projection == Nothing
            && all (== Nothing) (Map.elems (durableProjectionPeerAcknowledgements projection))
        )
        (Left (DurableProjectionInvariantViolation "Orders migration retained old-scope evidence"))
      case durableProjectionInFlight projection of
        Nothing -> Right ()
        Just inflight ->
          unless
            (durableInFlightKind inflight == KindOrdersMigration digest)
            (Left (DurableProjectionInvariantViolation "Orders migration in-flight kind mismatch"))
    _ -> Right ()

validateOrdersMigrationRecord
  :: DurableEmitterProjection
  -> Text
  -> StagedRecord
  -> Either DurableProjectionError ()
validateOrdersMigrationRecord projection label record =
  case stagedRecordKind record of
    KindOrdersMigration digest ->
      validateOrdersDigestEvidence projection (label <> " Orders migration") digest
    _ -> Right ()

validateOrdersMigrationInFlight
  :: DurableEmitterProjection
  -> DurableInFlight
  -> Either DurableProjectionError ()
validateOrdersMigrationInFlight projection inflight =
  case durableInFlightKind inflight of
    KindOrdersMigration digest -> do
      validateOrdersDigestEvidence projection "in-flight Orders migration" digest
      unless
        (durableProjectionPending projection == Just (PendingOrdersMigration digest))
        ( Left
            ( DurableProjectionInvariantViolation
                "in-flight Orders migration is missing its matching pending state"
            )
        )
    _ -> Right ()

validateOrdersDigestEvidence
  :: DurableEmitterProjection
  -> Text
  -> ContinuityDigest
  -> Either DurableProjectionError ()
validateOrdersDigestEvidence projection label digest =
  unless
    (durableProjectionPreviousOrdersDigest projection == Just digest)
    ( Left
        ( DurableProjectionInvariantViolation
            (label <> " does not match the retained previous-Orders digest")
        )
    )

validateUnacked
  :: DurableProjectionBounds
  -> Set EmitterPeer
  -> UnackedAssertion
  -> Either DurableProjectionError ()
validateUnacked bounds peers unacked = do
  validateStagedRecord bounds "unacked assertion" (unackedAssertionRecord unacked)
  unless
    (unackedAssertionWaitingPeers unacked `Set.isSubsetOf` peers)
    (Left (DurableProjectionInvariantViolation "unacked assertion names an unknown peer"))

validateCommittedUnacked
  :: DurableEmitterProjection
  -> UnackedAssertion
  -> Either DurableProjectionError ()
validateCommittedUnacked projection unacked = do
  let point = recordAckPoint (unackedAssertionRecord unacked)
      committedPosition =
        ( continuityAnchorEpoch (durableProjectionCommittedAnchor projection)
        , continuityAnchorSequence (durableProjectionCommittedAnchor projection)
        )
  when
    (ackPosition point > committedPosition)
    (Left (DurableProjectionInvariantViolation "unacked assertion is ahead of committed anchor"))
  when
    (ackPointIncarnation point > durableProjectionIncarnation projection)
    (Left (DurableProjectionInvariantViolation "unacked assertion has a future incarnation"))

validateStagedRecord
  :: DurableProjectionBounds
  -> Text
  -> StagedRecord
  -> Either DurableProjectionError ()
validateStagedRecord bounds label record = do
  validateDurableKind (stagedRecordKind record)
  let bytes = stagedRecordSignedBytes record
      actual = fromIntegral (BS.length bytes)
      allowed = projectionMaximumAssertionBytes bounds
  when (BS.null bytes) (Left (DurableProjectionSignedBytesMustNotBeEmpty label))
  when
    (actual > allowed)
    (Left (DurableProjectionSignedBytesExceeded label actual allowed))
  unless
    (stagedRecordTransition record == durableStagedTransition (stagedRecordKind record))
    (Left (DurableProjectionInvariantViolation (label <> " transition/kind mismatch")))
  digest <-
    first DurableProjectionContinuityInvalid (mkContinuityDigest (SHA256.hash bytes))
  expected <-
    first
      DurableProjectionContinuityInvalid
      (nextAnchorFor (stagedRecordTransition record) (stagedRecordPreviousAnchor record) digest)
  unless
    (expected == stagedRecordNextAnchor record)
    (Left (DurableProjectionInvariantViolation (label <> " derived anchor mismatch")))

validatePending :: Pending -> Either DurableProjectionError ()
validatePending pending =
  case pending of
    PendingRotationThenAdvance _ -> Right ()
    PendingAdvance _ -> Right ()
    PendingOrdersMigration digest -> validateMigrationDigest digest

validateDurableKind :: DurableKind -> Either DurableProjectionError ()
validateDurableKind kind =
  case kind of
    KindHeartbeat _ -> Right ()
    KindOwnership _ -> Right ()
    KindEpochRotation -> Right ()
    KindOrdersMigration digest -> validateMigrationDigest digest

validateMigrationDigest :: ContinuityDigest -> Either DurableProjectionError ()
validateMigrationDigest digest = do
  _ <-
    first
      DurableProjectionContinuityInvalid
      (mkContinuityDigest (continuityDigestBytes digest))
  pure ()

validateStrictRecordOrder
  :: [UnackedAssertion]
  -> Either DurableProjectionError ()
validateStrictRecordOrder records =
  unless
    (and (zipWith (<) points (drop 1 points)))
    (Left (DurableProjectionInvariantViolation "unacked suffix is not strictly ordered"))
 where
  points = map (ackPosition . recordAckPoint . unackedAssertionRecord) records

validateProjectionChain
  :: DurableEmitterProjection
  -> Either DurableProjectionError ()
validateProjectionChain projection = do
  let records = map unackedAssertionRecord (durableProjectionUnacked projection)
      baseAnchor =
        case repairFloorAnchor (durableProjectionRepairFloor projection) of
          Nothing -> durableProjectionGenesisAnchor projection
          Just floorAnchor -> floorAnchor
  validateAnchorDigest "genesis anchor" (durableProjectionGenesisAnchor projection)
  validateAnchorDigest "committed anchor" (durableProjectionCommittedAnchor projection)
  traverse_
    validateLink
    (zip [1 ..] (zip records (drop 1 records)))
  case records of
    [] ->
      unless
        (durableProjectionCommittedAnchor projection == baseAnchor)
        (Left (DurableProjectionChainDiscontinuity 0))
    firstRecordInSuffix : _ -> do
      unless
        (stagedRecordPreviousAnchor firstRecordInSuffix == baseAnchor)
        (Left (DurableProjectionChainDiscontinuity 0))
      case repairFloorIncarnation (durableProjectionRepairFloor projection) of
        Nothing -> Right ()
        Just floorIncarnation ->
          when
            (stagedRecordIncarnation firstRecordInSuffix < floorIncarnation)
            (Left (DurableProjectionChainDiscontinuity 0))
  case reverse records of
    [] -> Right ()
    latestInSuffix : _ -> do
      unless
        (stagedRecordNextAnchor latestInSuffix == durableProjectionCommittedAnchor projection)
        (Left (DurableProjectionChainDiscontinuity (fromIntegral (length records))))
      unless
        (durableProjectionLatestCommitted projection == Just latestInSuffix)
        (Left DurableProjectionLatestSuffixMismatch)
  case (durableProjectionRepairFloor projection, records) of
    (EmptyRepairFloor, []) ->
      unless
        (durableProjectionLatestCommitted projection == Nothing)
        (Left DurableProjectionLatestSuffixMismatch)
    _ -> Right ()
 where
  validateLink (index, (previous, next)) =
    unless
      ( stagedRecordNextAnchor previous == stagedRecordPreviousAnchor next
          && stagedRecordIncarnation previous <= stagedRecordIncarnation next
      )
      (Left (DurableProjectionChainDiscontinuity index))

validateAnchorDigest
  :: Text
  -> ContinuityAnchor
  -> Either DurableProjectionError ()
validateAnchorDigest _label anchor = do
  _ <-
    first
      DurableProjectionContinuityInvalid
      (mkContinuityDigest (continuityDigestBytes (continuityAnchorPreviousDigest anchor)))
  pure ()

validateLatestAnchor
  :: DurableEmitterProjection
  -> Either DurableProjectionError ()
validateLatestAnchor projection =
  case durableProjectionLatestCommitted projection of
    Nothing -> Right ()
    Just latest -> do
      unless
        (stagedRecordNextAnchor latest == durableProjectionCommittedAnchor projection)
        (Left (DurableProjectionInvariantViolation "latest assertion is not the committed anchor"))
      unless
        (stagedRecordIncarnation latest <= durableProjectionIncarnation projection)
        (Left (DurableProjectionInvariantViolation "latest assertion has a future incarnation"))

validateRepairFloor
  :: DurableProjectionBounds
  -> RepairFloor
  -> Either DurableProjectionError ()
validateRepairFloor bounds floor0 = case floor0 of
  EmptyRepairFloor -> Right ()
  InstalledRepairFloor point bytes -> do
    validateAnchorDigest "repair-floor anchor" (ackPointAnchor point)
    validateSignedPayload bounds "repair-floor checkpoint" bytes

validateSignedPayload
  :: DurableProjectionBounds
  -> Text
  -> ByteString
  -> Either DurableProjectionError ()
validateSignedPayload bounds label bytes = do
  let actual = fromIntegral (BS.length bytes)
      allowed = projectionMaximumCheckpointBytes bounds
  when (BS.null bytes) (Left (DurableProjectionSignedBytesMustNotBeEmpty label))
  when
    (actual > allowed)
    (Left (DurableProjectionSignedBytesExceeded label actual allowed))

validateCheckpointCandidate
  :: DurableProjectionBounds
  -> DurableEmitterProjection
  -> CheckpointCandidate
  -> Either DurableProjectionError ()
validateCheckpointCandidate _bounds projection candidate = do
  let assertions = checkpointCandidateAssertions candidate
      expectedPrefix = take (length assertions) (durableProjectionUnacked projection)
  when
    (null assertions)
    (Left (DurableProjectionInvariantViolation "checkpoint candidate is empty"))
  unless
    (assertions == expectedPrefix)
    (Left DurableProjectionCheckpointPrefixMismatch)
  unless
    (checkpointCandidatePreviousFloor candidate == durableProjectionRepairFloor projection)
    (Left (DurableProjectionInvariantViolation "checkpoint candidate repair floor mismatch"))
  case reverse assertions of
    [] -> Left (DurableProjectionInvariantViolation "checkpoint candidate is empty")
    latest : _ ->
      unless
        ( checkpointCandidateThrough candidate
            == recordAckPoint (unackedAssertionRecord latest)
        )
        (Left (DurableProjectionInvariantViolation "checkpoint candidate through-point mismatch"))

validateDurableInFlight
  :: DurableProjectionBounds
  -> DurableEmitterProjection
  -> DurableInFlight
  -> Either DurableProjectionError ()
validateDurableInFlight bounds projection durable = do
  validateDurableKind (durableInFlightKind durable)
  let phase = durableInFlightPhase durable
      shouldBePublished = phase >= PhaseCommitting
      admissionValue = transitionAdmissionValue (durableInFlightAdmission durable)
      expectedNextAdmission =
        if admissionValue == maxBound then Nothing else Just (admissionValue + 1)
  unless
    (durableInFlightPreviousAnchor durable == durableProjectionCommittedAnchor projection)
    (Left (DurableProjectionInvariantViolation "in-flight transition does not follow committed anchor"))
  unless
    (durableInFlightPublished durable == shouldBePublished)
    (Left (DurableProjectionInvariantViolation "published marker disagrees with phase"))
  unless
    (durableInFlightMountIncarnation durable == durableProjectionIncarnation projection)
    (Left (DurableProjectionInvariantViolation "in-flight completion fence is stale"))
  unless
    (durableProjectionNextAdmission projection == expectedNextAdmission)
    (Left (DurableProjectionInvariantViolation "next admission does not follow in-flight admission"))
  case (phase, durableInFlightRecord durable) of
    (PhaseStaging, Nothing) -> Right ()
    (PhaseStaging, Just _) ->
      Left (DurableProjectionInvariantViolation "staging phase already has a staged record")
    (_, Nothing) ->
      Left (DurableProjectionInvariantViolation "post-sign phase is missing its exact staged record")
    (_, Just record) -> do
      validateStagedRecord bounds "staged in-flight assertion" record
      unless
        (stagedRecordKind record == durableInFlightKind durable)
        (Left (DurableProjectionInvariantViolation "staged assertion kind mismatch"))
      unless
        (stagedRecordPreviousAnchor record == durableInFlightPreviousAnchor durable)
        (Left (DurableProjectionInvariantViolation "staged assertion previous-anchor mismatch"))
      unless
        (stagedRecordIncarnation record <= durableProjectionIncarnation projection)
        (Left (DurableProjectionInvariantViolation "staged assertion has a future incarnation"))

validateAckProjection
  :: DurableEmitterProjection
  -> Either DurableProjectionError ()
validateAckProjection projection = do
  let committedPosition =
        ( continuityAnchorEpoch (durableProjectionCommittedAnchor projection)
        , continuityAnchorSequence (durableProjectionCommittedAnchor projection)
        )
      currentIncarnation = durableProjectionIncarnation projection
      points =
        [ point
        | Just point <- Map.elems (durableProjectionPeerAcknowledgements projection)
        ]
      floorPoints = maybe [] pure (repairFloorPoint (durableProjectionRepairFloor projection))
      knownPoints =
        Set.fromList
          ( floorPoints
              ++ map
                (recordAckPoint . unackedAssertionRecord)
                (durableProjectionUnacked projection)
              ++ maybe [] (pure . recordAckPoint) (durableProjectionLatestCommitted projection)
          )
  traverse_ (validatePoint committedPosition currentIncarnation) (points ++ floorPoints)
  _ <-
    Map.traverseWithKey
      (validateKnownPoint knownPoints)
      (durableProjectionPeerAcknowledgements projection)
  pure ()
 where
  validatePoint committedPosition currentIncarnation point = do
    when
      (ackPosition point > committedPosition)
      (Left (DurableProjectionInvariantViolation "acknowledgement is ahead of committed anchor"))
    when
      (ackPointIncarnation point > currentIncarnation)
      (Left (DurableProjectionInvariantViolation "acknowledgement has a future incarnation"))

  validateKnownPoint _ _ Nothing = Right ()
  validateKnownPoint knownPoints peer (Just point) =
    unless
      (Set.member point knownPoints)
      (Left (DurableProjectionUnknownAckPoint peer point))

validateWaitingPeers
  :: DurableEmitterProjection
  -> Either DurableProjectionError ()
validateWaitingPeers projection =
  traverse_ validateOne (durableProjectionUnacked projection)
 where
  acknowledgements = durableProjectionPeerAcknowledgements projection
  validateOne unacked = do
    let point = recordAckPoint (unackedAssertionRecord unacked)
        expected =
          Map.keysSet
            ( Map.filter
                (\acknowledged -> maybe True ((< ackPosition point) . ackPosition) acknowledged)
                acknowledgements
            )
        actual = unackedAssertionWaitingPeers unacked
    unless
      (actual == expected)
      (Left (DurableProjectionWaitingPeersMismatch point expected actual))

plannedSemanticAnchor
  :: EmitterState
  -> ContinuityDigest
  -> Either ContinuityError ContinuityAnchor
plannedSemanticAnchor st = nextAnchorFor SemanticAdvance (emitterCommittedAnchor st)

plannedEpochAnchor
  :: EmitterState
  -> ContinuityDigest
  -> Either ContinuityError ContinuityAnchor
plannedEpochAnchor st = nextAnchorFor EpochInvalidation (emitterCommittedAnchor st)

newtype BoundedSignedPayload = BoundedSignedPayload ByteString
  deriving stock (Eq, Show)

data SignedPayloadError
  = SignedPayloadMaximumMustBePositive
  | SignedPayloadMustNotBeEmpty
  | SignedPayloadBytesExceeded !Natural !Natural
  deriving stock (Eq, Show)

mkBoundedSignedPayload
  :: Natural
  -> ByteString
  -> Either SignedPayloadError BoundedSignedPayload
mkBoundedSignedPayload maximumBytes bytes
  | maximumBytes == 0 = Left SignedPayloadMaximumMustBePositive
  | BS.null bytes = Left SignedPayloadMustNotBeEmpty
  | actual > maximumBytes = Left (SignedPayloadBytesExceeded actual maximumBytes)
  | otherwise = Right (BoundedSignedPayload bytes)
 where
  actual = fromIntegral (BS.length bytes)

boundedSignedPayloadBytes :: BoundedSignedPayload -> ByteString
boundedSignedPayloadBytes (BoundedSignedPayload bytes) = bytes

data StageOutcome
  = StageStaged !BoundedSignedPayload
  | StageNeedsRotation
  deriving stock (Eq, Show)

data PhaseCompletion
  = DidFsyncStage
  | DidPublish
  | DidCommit
  | DidFsyncCommit
  deriving stock (Eq, Show)

completionPhase :: PhaseCompletion -> EmitterPhase
completionPhase completion = case completion of
  DidFsyncStage -> PhaseFsyncingStage
  DidPublish -> PhasePublishing
  DidCommit -> PhaseCommitting
  DidFsyncCommit -> PhaseFsyncingCommit

data CheckpointOutcome
  = CheckpointInstalled !BoundedSignedPayload
  | CheckpointFailed
  deriving stock (Eq, Show)

-- | Exact bounded evidence needed to rebuild the daemon's volatile semantic
-- and peer-replay caches after a journal mount. The optional checkpoint is the
-- authenticated repair floor; assertions are the strictly ordered retained
-- suffix from that floor (or the immutable genesis anchor) through the current
-- committed anchor. An active Orders migration may deliberately carry only its
-- retained prior-Orders digest and genesis anchor so local-journal recovery can
-- reset and re-arm that one emitter before exact republication. Historical
-- prior-Orders evidence is not exposed after the migration commits.
-- Constructors stay private so callers cannot inject bytes that bypassed the
-- durable projection bounds.
data RecoveryReplay = RecoveryReplay
  { recoveryReplayGenesisAnchor :: !ContinuityAnchor
  , recoveryReplayPreviousOrdersDigest :: !(Maybe ContinuityDigest)
  , recoveryReplayCheckpoint :: !(Maybe BoundedSignedPayload)
  , recoveryReplayAssertions :: ![StagedRecord]
  , recoveryReplayPendingPublications :: ![UnackedAssertion]
  , recoveryReplayAssertionCount :: !Natural
  , recoveryReplaySignedBytes :: !Natural
  }
  deriving stock (Eq, Show)

data EmitterIntent
  = SubmitRequest !EmitterRequest
  | Pump !MonotonicInstant !Deadline
  | StageResolved !Incarnation !TransitionAdmission !StageOutcome
  | PhaseAdvanced !Incarnation !TransitionAdmission !StagedRecord !PhaseCompletion
  | Recover !MonotonicInstant !Deadline
  | RecoveryRestored !Incarnation !RecoveryReplay
  | AckPeerThrough !EmitterPeer !AckPoint
  | -- | Kept as an explicit rejected compatibility shape: a scalar ack has no
    -- peer identity and therefore may not retire any durable evidence.
    AckThrough !Word64
  | CheckpointResolved !Incarnation !Deadline !CheckpointCandidate !CheckpointOutcome
  deriving stock (Eq, Show)

data EmitterEffect
  = EffStage !TransitionAdmission !Deadline !StagePlan
  | EffFsyncStage !TransitionAdmission !Deadline !StagedRecord
  | EffPublish !TransitionAdmission !Deadline !StagedRecord
  | EffCommit !TransitionAdmission !Deadline !StagedRecord
  | EffFsyncCommit !TransitionAdmission !Deadline !StagedRecord
  | EffCheckpointCompaction !Incarnation !Deadline !CheckpointCandidate
  | EffRestoreRetained !Incarnation !Deadline !RecoveryReplay
  deriving stock (Eq, Show)

data RejectReason
  = RejectMailboxFull !RetryAfter
  | RejectBusy
  | RejectStaleIncarnation !Incarnation !Incarnation
  | RejectStaleAdmission !TransitionAdmission !TransitionAdmission
  | RejectUnexpectedCompletion
  | RejectDeadlineExpired
  | RejectAdmissionExhausted
  | RejectIncarnationExhausted
  | RejectZeroIncarnation
  | RejectIncarnationRegression !Incarnation !Incarnation
  | RejectEmptySignedAssertion
  | RejectInvalidStagedRecord !ContinuityError
  | RejectUnknownPeer !EmitterPeer
  | RejectPeerIdentityRequired
  | RejectUnknownAcknowledgement !EmitterPeer !AckPoint
  | RejectAcknowledgementConflict !EmitterPeer !AckPoint !AckPoint
  | RejectCheckpointPending
  | RejectCheckpointFailed
  | RejectEmptySignedCheckpoint
  | RejectOrdersMigrationEpochExhausted
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

step :: EmitterState -> EmitterIntent -> EmitterStep
step st intent = case intent of
  SubmitRequest request -> stepSubmit st request
  Pump now deadline -> stepPump st now deadline
  StageResolved incarnation admission outcome ->
    stepStageResolved st incarnation admission outcome
  PhaseAdvanced incarnation admission record completion ->
    stepPhaseAdvanced st incarnation admission record completion
  Recover now deadline -> stepRecover st now deadline
  RecoveryRestored incarnation replay -> stepRecoveryRestored st incarnation replay
  AckPeerThrough peer point -> stepAckPeer st peer point
  AckThrough _ -> noEffect st (OutcomeRejected RejectPeerIdentityRequired)
  CheckpointResolved incarnation deadline candidate outcome ->
    stepCheckpointResolved st incarnation deadline candidate outcome

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
    Just inflight -> pumpInFlight st inflight now deadline
    Nothing -> pumpIdle st now deadline

pumpInFlight :: EmitterState -> InFlight -> MonotonicInstant -> Deadline -> EmitterStep
pumpInFlight st inflight now recoveryDeadline =
  case dequeueRecovery (emitterMailbox st) of
    Just mailbox' ->
      stepRecover st {emitterMailbox = mailbox'} now recoveryDeadline
    Nothing
      | deadlineExpired now (inFlightDeadline inflight) ->
          case inFlightStagedRecord inflight of
            Nothing ->
              noEffect st {emitterInFlight = Nothing} (OutcomeRejected RejectDeadlineExpired)
            Just _ -> noEffect st (OutcomeRejected RejectDeadlineExpired)
      | otherwise -> noEffect st OutcomeNoOp

pumpIdle :: EmitterState -> MonotonicInstant -> Deadline -> EmitterStep
pumpIdle st now deadline =
  case emitterCheckpointPending st of
    Just _ ->
      case dequeueRecovery (emitterMailbox st) of
        Nothing -> noEffect st (OutcomeRejected RejectCheckpointPending)
        Just mailbox' -> stepRecover st {emitterMailbox = mailbox'} now deadline
    Nothing ->
      case emitterPending st of
        Just (PendingRotationThenAdvance _) ->
          beginTransition st KindEpochRotation deadline
        Just (PendingAdvance request) ->
          beginPendingAdvance st request deadline
        Just (PendingOrdersMigration previousOrdersDigest) ->
          beginTransition st (KindOrdersMigration previousOrdersDigest) deadline
        Nothing -> pumpMailbox st now deadline

beginPendingAdvance :: EmitterState -> PendingRequest -> Deadline -> EmitterStep
beginPendingAdvance st request deadline =
  case emitterAdmissionCounter st of
    Nothing -> noEffect st (OutcomeRejected RejectAdmissionExhausted)
    Just _ -> beginTransition st {emitterPending = Nothing} (pendingRequestKind request) deadline

pumpMailbox :: EmitterState -> MonotonicInstant -> Deadline -> EmitterStep
pumpMailbox st now deadline =
  case dequeue (emitterMailbox st) of
    Nothing -> noEffect st OutcomeNoOp
    Just (request, mailbox') ->
      let drained = st {emitterMailbox = mailbox'}
       in case request of
            ReqHeartbeat payload -> beginTransition drained (KindHeartbeat payload) deadline
            ReqOwnership transition -> beginTransition drained (KindOwnership transition) deadline
            ReqEpochRotation -> noEffect drained OutcomeNoOp
            ReqRecover -> stepRecover drained now deadline

beginTransition :: EmitterState -> DurableKind -> Deadline -> EmitterStep
beginTransition st kind deadline =
  case emitterAdmissionCounter st of
    Nothing -> noEffect st (OutcomeRejected RejectAdmissionExhausted)
    Just admissionValue ->
      let admission = TransitionAdmission admissionValue
          previous = emitterCommittedAnchor st
          inflight =
            InFlight
              { inFlightKind = kind
              , inFlightPhase = PhaseStaging
              , inFlightAdmission = admission
              , inFlightDeadline = deadline
              , inFlightIncarnation = emitterIncarnation st
              , inFlightPreviousAnchor = previous
              , inFlightStagedRecord = Nothing
              , inFlightPublished = False
              }
          nextAdmission =
            if admissionValue == maxBound then Nothing else Just (admissionValue + 1)
          plan = stagePlanFor inflight
          st' =
            st
              { emitterInFlight = Just inflight
              , emitterAdmissionCounter = nextAdmission
              }
       in EmitterStep st' [EffStage admission deadline plan] OutcomeAccepted

stagePlanFor :: InFlight -> StagePlan
stagePlanFor inflight =
  StagePlan
    { stagePlanKind = inFlightKind inflight
    , stagePlanTransition = durableStagedTransition (inFlightKind inflight)
    , stagePlanPreviousAnchor = inFlightPreviousAnchor inflight
    , stagePlanIncarnation = inFlightIncarnation inflight
    }

stepStageResolved
  :: EmitterState
  -> Incarnation
  -> TransitionAdmission
  -> StageOutcome
  -> EmitterStep
stepStageResolved st incarnation admission outcome =
  withFencedAdmission st incarnation admission (resolveStage st outcome)

resolveStage :: EmitterState -> StageOutcome -> InFlight -> EmitterStep
resolveStage st outcome inflight =
  case inFlightPhase inflight of
    PhaseStaging -> resolveStagingPhase st outcome inflight
    _ -> resolveReplayedStage st outcome inflight

resolveReplayedStage :: EmitterState -> StageOutcome -> InFlight -> EmitterStep
resolveReplayedStage st outcome inflight =
  case (outcome, inFlightStagedRecord inflight) of
    (StageStaged payload, Just record)
      | boundedSignedPayloadBytes payload == stagedRecordSignedBytes record ->
          noEffect st OutcomeNoOp
    _ -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)

resolveStagingPhase :: EmitterState -> StageOutcome -> InFlight -> EmitterStep
resolveStagingPhase st outcome inflight = case outcome of
  StageStaged payload ->
    case mkStagedRecord inflight (boundedSignedPayloadBytes payload) of
      Left err -> noEffect st (OutcomeRejected (RejectInvalidStagedRecord err))
      Right record ->
        let staged =
              inflight
                { inFlightPhase = PhaseFsyncingStage
                , inFlightStagedRecord = Just record
                }
         in EmitterStep
              st {emitterInFlight = Just staged}
              [ EffFsyncStage
                  (inFlightAdmission inflight)
                  (inFlightDeadline inflight)
                  record
              ]
              OutcomeAccepted
  StageNeedsRotation ->
    case pendingRequestFor (inFlightKind inflight) of
      Nothing -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)
      Just request ->
        noEffect
          st
            { emitterInFlight = Nothing
            , emitterPending = Just (PendingRotationThenAdvance request)
            }
          OutcomeAccepted

mkStagedRecord :: InFlight -> ByteString -> Either ContinuityError StagedRecord
mkStagedRecord inflight bytes = do
  digest <- mkContinuityDigest (SHA256.hash bytes)
  let transition = durableStagedTransition (inFlightKind inflight)
      previous = inFlightPreviousAnchor inflight
  next <- nextAnchorFor transition previous digest
  Right
    StagedRecord
      { stagedRecordKind = inFlightKind inflight
      , stagedRecordTransition = transition
      , stagedRecordSignedBytes = bytes
      , stagedRecordPreviousAnchor = previous
      , stagedRecordNextAnchor = next
      , stagedRecordIncarnation = inFlightIncarnation inflight
      }

pendingRequestFor :: DurableKind -> Maybe PendingRequest
pendingRequestFor kind = case kind of
  KindHeartbeat payload -> Just (PendingHeartbeat payload)
  KindOwnership transition -> Just (PendingOwnership transition)
  KindEpochRotation -> Nothing
  KindOrdersMigration _ -> Nothing

pendingRequestKind :: PendingRequest -> DurableKind
pendingRequestKind request = case request of
  PendingHeartbeat payload -> KindHeartbeat payload
  PendingOwnership transition -> KindOwnership transition

stepPhaseAdvanced
  :: EmitterState
  -> Incarnation
  -> TransitionAdmission
  -> StagedRecord
  -> PhaseCompletion
  -> EmitterStep
stepPhaseAdvanced st incarnation admission record completion =
  withFencedAdmission st incarnation admission (completeExpectedPhase st record completion)

completeExpectedPhase
  :: EmitterState
  -> StagedRecord
  -> PhaseCompletion
  -> InFlight
  -> EmitterStep
completeExpectedPhase st record completion inflight =
  case inFlightStagedRecord inflight of
    Just expected
      | expected == record -> advanceOnCompletion st completion inflight
    _ -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)

advanceOnCompletion :: EmitterState -> PhaseCompletion -> InFlight -> EmitterStep
advanceOnCompletion st completion inflight =
  let owningPhase = completionPhase completion
      current = inFlightPhase inflight
   in case compare owningPhase current of
        LT -> noEffect st OutcomeNoOp
        GT -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)
        EQ -> applyCompletion st inflight completion

applyCompletion :: EmitterState -> InFlight -> PhaseCompletion -> EmitterStep
applyCompletion st inflight completion =
  case inFlightStagedRecord inflight of
    Nothing -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)
    Just record -> case completion of
      DidFsyncStage ->
        advancePhase st inflight PhasePublishing $
          EffPublish (inFlightAdmission inflight) (inFlightDeadline inflight) record
      DidPublish ->
        advancePhasePublished st inflight PhaseCommitting $
          EffCommit (inFlightAdmission inflight) (inFlightDeadline inflight) record
      DidCommit ->
        advancePhase st inflight PhaseFsyncingCommit $
          EffFsyncCommit (inFlightAdmission inflight) (inFlightDeadline inflight) record
      DidFsyncCommit -> finalize st inflight record

advancePhase :: EmitterState -> InFlight -> EmitterPhase -> EmitterEffect -> EmitterStep
advancePhase st inflight nextPhase effect =
  EmitterStep
    st {emitterInFlight = Just inflight {inFlightPhase = nextPhase}}
    [effect]
    OutcomeAccepted

advancePhasePublished
  :: EmitterState
  -> InFlight
  -> EmitterPhase
  -> EmitterEffect
  -> EmitterStep
advancePhasePublished st inflight nextPhase effect =
  EmitterStep
    st
      { emitterInFlight =
          Just inflight {inFlightPhase = nextPhase, inFlightPublished = True}
      }
    [effect]
    OutcomeAccepted

finalize :: EmitterState -> InFlight -> StagedRecord -> EmitterStep
finalize st inflight record =
  let waiting = emitterPeers st
      unacked = emitterUnacked st ++ [UnackedAssertion record waiting]
      pending' = promotePending (inFlightKind inflight) (emitterPending st)
      committed =
        normalizeAcknowledgements
          st
            { emitterCommittedAnchor = stagedRecordNextAnchor record
            , emitterInFlight = Nothing
            , emitterPending = pending'
            , emitterUnacked = unacked
            , emitterLatestCommitted = Just record
            }
      (bounded, checkpointEffects) = scheduleCheckpoint (inFlightDeadline inflight) committed
   in EmitterStep bounded checkpointEffects OutcomeAccepted

promotePending :: DurableKind -> Maybe Pending -> Maybe Pending
promotePending KindEpochRotation (Just (PendingRotationThenAdvance request)) =
  Just (PendingAdvance request)
promotePending (KindOrdersMigration _) (Just (PendingOrdersMigration _)) = Nothing
promotePending _ pending = pending

scheduleCheckpoint :: Deadline -> EmitterState -> (EmitterState, [EmitterEffect])
scheduleCheckpoint deadline st
  | emitterCheckpointPending st /= Nothing = (st, [])
  | fromIntegral (length (emitterUnacked st)) <= emitterUnackedThreshold st = (st, [])
  | otherwise =
      let keep = fromIntegral (emitterUnackedThreshold st)
          prefixLength = length (emitterUnacked st) - keep
          prefix = take prefixLength (emitterUnacked st)
       in case reverse prefix of
            [] -> (st, [])
            latest : _ ->
              let candidate =
                    CheckpointCandidate
                      { checkpointCandidatePreviousFloor = emitterRepairFloor st
                      , checkpointCandidateAssertions = prefix
                      , checkpointCandidateThrough = recordAckPoint (unackedAssertionRecord latest)
                      }
                  st' = st {emitterCheckpointPending = Just candidate}
               in ( st'
                  , [EffCheckpointCompaction (emitterIncarnation st) deadline candidate]
                  )

stepCheckpointResolved
  :: EmitterState
  -> Incarnation
  -> Deadline
  -> CheckpointCandidate
  -> CheckpointOutcome
  -> EmitterStep
stepCheckpointResolved st incarnation deadline candidate outcome
  | incarnation /= emitterIncarnation st =
      noEffect
        st
        (OutcomeRejected (RejectStaleIncarnation (emitterIncarnation st) incarnation))
  | emitterCheckpointPending st /= Just candidate =
      noEffect st (OutcomeRejected RejectUnexpectedCompletion)
  | otherwise = case outcome of
      CheckpointFailed -> noEffect st (OutcomeRejected RejectCheckpointFailed)
      CheckpointInstalled signedPayload ->
        let signedBytes = boundedSignedPayloadBytes signedPayload
         in let prefixLength = length (checkpointCandidateAssertions candidate)
                retained = drop prefixLength (emitterUnacked st)
                floor' =
                  InstalledRepairFloor
                    (checkpointCandidateThrough candidate)
                    signedBytes
                st' =
                  normalizeAcknowledgements
                    st
                      { emitterUnacked = retained
                      , emitterRepairFloor = floor'
                      , emitterCheckpointPending = Nothing
                      }
                (bounded, effects) = scheduleCheckpoint deadline st'
             in EmitterStep bounded effects OutcomeAccepted

stepRecover :: EmitterState -> MonotonicInstant -> Deadline -> EmitterStep
stepRecover st now recoveryDeadline =
  if deadlineExpired now recoveryDeadline
    then noEffect st (OutcomeRejected RejectDeadlineExpired)
    else prependRecoveryReplay st recoveryDeadline recovered
 where
  recovered =
    case emitterInFlight st of
      Just inflight
        | inFlightStagedRecord inflight == Nothing ->
            beginTransition
              st {emitterInFlight = Nothing}
              (inFlightKind inflight)
              recoveryDeadline
        | otherwise ->
            let rewound =
                  inflight
                    { inFlightPhase = PhaseFsyncingStage
                    , inFlightDeadline = recoveryDeadline
                    , inFlightPublished = False
                    }
                rewoundState = st {emitterInFlight = Just rewound}
             in case recoverEffect rewound of
                  Nothing -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)
                  Just effect -> EmitterStep rewoundState [effect] OutcomeAccepted
      Nothing ->
        case emitterCheckpointPending st of
          Just candidate ->
            EmitterStep
              st
              [EffCheckpointCompaction (emitterIncarnation st) recoveryDeadline candidate]
              OutcomeAccepted
          Nothing -> recoverPendingOrIdle st recoveryDeadline

recoverPendingOrIdle :: EmitterState -> Deadline -> EmitterStep
recoverPendingOrIdle st deadline =
  case emitterPending st of
    Just (PendingRotationThenAdvance _) -> beginTransition st KindEpochRotation deadline
    Just (PendingAdvance request) -> beginPendingAdvance st request deadline
    Just (PendingOrdersMigration previousOrdersDigest) ->
      beginTransition st (KindOrdersMigration previousOrdersDigest) deadline
    Nothing -> noEffect st OutcomeNoOp

prependRecoveryReplay :: EmitterState -> Deadline -> EmitterStep -> EmitterStep
prependRecoveryReplay source deadline recovered =
  case recoveryReplayFor source of
    Nothing -> recovered
    Just replay ->
      recovered
        { stepEffects =
            EffRestoreRetained (emitterIncarnation source) deadline replay
              : stepEffects recovered
        , stepOutcome =
            case stepOutcome recovered of
              OutcomeNoOp -> OutcomeAccepted
              outcome -> outcome
        }

recoveryReplayFor :: EmitterState -> Maybe RecoveryReplay
recoveryReplayFor st =
  let checkpoint = BoundedSignedPayload <$> repairFloorSignedBytes (emitterRepairFloor st)
      activeMigrationDigest = activeOrdersMigrationDigest st
      retained = emitterUnacked st
      assertions = map unackedAssertionRecord retained
      pending = filter (not . Set.null . unackedAssertionWaitingPeers) retained
      byteCount =
        maybe 0 (fromIntegral . BS.length . boundedSignedPayloadBytes) checkpoint
          + sum
            ( map
                (fromIntegral . BS.length . stagedRecordSignedBytes)
                assertions
            )
   in case (checkpoint, assertions, activeMigrationDigest) of
        (Nothing, [], Nothing) -> Nothing
        _ ->
          Just
            RecoveryReplay
              { recoveryReplayGenesisAnchor = emitterGenesisAnchor st
              , recoveryReplayPreviousOrdersDigest = activeMigrationDigest
              , recoveryReplayCheckpoint = checkpoint
              , recoveryReplayAssertions = assertions
              , recoveryReplayPendingPublications = pending
              , recoveryReplayAssertionCount = fromIntegral (length assertions)
              , recoveryReplaySignedBytes = byteCount
              }

activeOrdersMigrationDigest :: EmitterState -> Maybe ContinuityDigest
activeOrdersMigrationDigest st =
  case emitterPending st of
    Just (PendingOrdersMigration pendingDigest)
      | emitterPreviousOrdersDigest st == Just pendingDigest ->
          case emitterInFlight st of
            Nothing -> Just pendingDigest
            Just inflight -> case inFlightKind inflight of
              KindOrdersMigration inFlightDigest
                | inFlightDigest == pendingDigest -> Just pendingDigest
              _ -> Nothing
    _ -> Nothing

stepRecoveryRestored :: EmitterState -> Incarnation -> RecoveryReplay -> EmitterStep
stepRecoveryRestored st incarnation replay
  | incarnation /= emitterIncarnation st =
      noEffect
        st
        (OutcomeRejected (RejectStaleIncarnation (emitterIncarnation st) incarnation))
  | recoveryReplayFor st /= Just replay =
      noEffect st (OutcomeRejected RejectUnexpectedCompletion)
  | otherwise = noEffect st OutcomeAccepted

recoverEffect :: InFlight -> Maybe EmitterEffect
recoverEffect inflight =
  let admission = inFlightAdmission inflight
      deadline = inFlightDeadline inflight
   in case inFlightPhase inflight of
        PhaseStaging -> Just (EffStage admission deadline (stagePlanFor inflight))
        phase -> do
          record <- inFlightStagedRecord inflight
          case phase of
            PhaseFsyncingStage -> Just (EffFsyncStage admission deadline record)
            PhasePublishing -> Just (EffPublish admission deadline record)
            PhaseCommitting -> Just (EffCommit admission deadline record)
            PhaseFsyncingCommit -> Just (EffFsyncCommit admission deadline record)

stepAckPeer :: EmitterState -> EmitterPeer -> AckPoint -> EmitterStep
stepAckPeer st peer point
  | emitterInFlight st /= Nothing = noEffect st (OutcomeRejected RejectBusy)
  | emitterCheckpointPending st /= Nothing =
      noEffect st (OutcomeRejected RejectCheckpointPending)
  | otherwise = case Map.lookup peer (emitterPeerAcknowledgements st) of
      Nothing -> noEffect st (OutcomeRejected (RejectUnknownPeer peer))
      Just previous ->
        case validateAcknowledgement st peer previous point of
          Left rejection -> noEffect st (OutcomeRejected rejection)
          Right AckDuplicate -> noEffect st OutcomeNoOp
          Right AckAdvance ->
            let acknowledged = map (acknowledgeOne peer point) (emitterUnacked st)
                st' =
                  st
                    { emitterPeerAcknowledgements =
                        Map.insert peer (Just point) (emitterPeerAcknowledgements st)
                    , emitterUnacked = acknowledged
                    }
             in noEffect st' OutcomeAccepted

data AckDisposition = AckDuplicate | AckAdvance

validateAcknowledgement
  :: EmitterState
  -> EmitterPeer
  -> Maybe AckPoint
  -> AckPoint
  -> Either RejectReason AckDisposition
validateAcknowledgement st peer previous supplied
  | not (knownAckPoint st peer supplied) =
      Left (RejectUnknownAcknowledgement peer supplied)
  | otherwise = case previous of
      Nothing -> Right AckAdvance
      Just current ->
        case compare (ackPosition supplied) (ackPosition current) of
          LT -> Right AckDuplicate
          EQ
            | supplied == current -> Right AckDuplicate
            | otherwise -> Left (RejectAcknowledgementConflict peer current supplied)
          GT
            | ackPointIncarnation supplied < ackPointIncarnation current ->
                Left (RejectAcknowledgementConflict peer current supplied)
            | otherwise -> Right AckAdvance

knownAckPoint :: EmitterState -> EmitterPeer -> AckPoint -> Bool
knownAckPoint st peer point =
  any ((== point) . recordAckPoint . unackedAssertionRecord) (emitterUnacked st)
    || repairFloorPoint (emitterRepairFloor st) == Just point
    || fmap recordAckPoint (emitterLatestCommitted st) == Just point
    || Map.lookup peer (emitterPeerAcknowledgements st) == Just (Just point)

repairFloorPoint :: RepairFloor -> Maybe AckPoint
repairFloorPoint floor0 = case floor0 of
  EmptyRepairFloor -> Nothing
  InstalledRepairFloor point _ -> Just point

acknowledgeOne :: EmitterPeer -> AckPoint -> UnackedAssertion -> UnackedAssertion
acknowledgeOne peer point unacked
  | ackPosition (recordAckPoint (unackedAssertionRecord unacked)) <= ackPosition point =
      unacked
        { unackedAssertionWaitingPeers =
            Set.delete peer (unackedAssertionWaitingPeers unacked)
        }
  | otherwise = unacked

normalizeAcknowledgements :: EmitterState -> EmitterState
normalizeAcknowledgements st =
  st
    { emitterPeerAcknowledgements =
        Map.map normalize (emitterPeerAcknowledgements st)
    }
 where
  floorPoint = repairFloorPoint (emitterRepairFloor st)
  knownPoints =
    Set.fromList
      ( maybe [] pure floorPoint
          ++ map (recordAckPoint . unackedAssertionRecord) (emitterUnacked st)
          ++ maybe [] (pure . recordAckPoint) (emitterLatestCommitted st)
      )
  normalize Nothing = Nothing
  normalize acknowledged@(Just point)
    | Set.member point knownPoints = acknowledged
    | otherwise = floorPoint

recordAckPoint :: StagedRecord -> AckPoint
recordAckPoint record =
  AckPoint
    { ackPointIncarnation = stagedRecordIncarnation record
    , ackPointAnchor = stagedRecordNextAnchor record
    }

ackPosition :: AckPoint -> (Word64, Word64)
ackPosition point =
  ( continuityAnchorEpoch (ackPointAnchor point)
  , continuityAnchorSequence (ackPointAnchor point)
  )

withFencedAdmission
  :: EmitterState
  -> Incarnation
  -> TransitionAdmission
  -> (InFlight -> EmitterStep)
  -> EmitterStep
withFencedAdmission st incarnation admission body =
  case emitterInFlight st of
    Nothing -> noEffect st (OutcomeRejected RejectUnexpectedCompletion)
    Just inflight
      | inFlightIncarnation inflight /= incarnation ->
          noEffect
            st
            (OutcomeRejected (RejectStaleIncarnation (inFlightIncarnation inflight) incarnation))
      | inFlightAdmission inflight /= admission ->
          noEffect
            st
            (OutcomeRejected (RejectStaleAdmission (inFlightAdmission inflight) admission))
      | otherwise -> body inflight
