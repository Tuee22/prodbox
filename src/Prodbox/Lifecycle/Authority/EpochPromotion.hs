{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Durable prepared/frozen/open cutover progress. Observations are flat data;
-- the physical interpreter owns their origin. No preparation or partial
-- promotion authorizes a normal effect.
module Prodbox.Lifecycle.Authority.EpochPromotion
  ( EpochPromotionState
  , EpochPromotionPhase (..)
  , EpochBindingReadback (..)
  , EpochPromotionAction (..)
  , EpochPromotionRequest (..)
  , EpochPromotionRefusal (..)
  , EpochPromotionDecision (..)
  , prepareEpochPromotion
  , stepEpochPromotion
  , validateEpochPromotionState
  , epochPromotionPhase
  , epochPromotionTargetEpoch
  , epochPromotionPredecessorEpoch
  , epochPromotionTopology
  , epochPromotionCommittedEpoch
  , renderEpochPromotionRefusal
  , validateEpochPromotionRequest
  )
where

import Codec.Serialise (Serialise)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Authority.EpochTopology

data EpochPromotionPhase
  = EpochPrepared
  | EpochFrozen
  | EpochAdmissionOpen
  | EpochPreparedRollback
  | EpochPreparedBindingsRetired
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EpochPromotionState = EpochPromotionState
  { epochPromotionPhase :: !EpochPromotionPhase
  , epochPromotionPredecessorEpoch :: !Word
  , epochPromotionTargetEpoch :: !Word
  , epochPromotionTopology :: !EpochTopology
  , preparedBindings :: !(Set EpochTopologyBinding)
  , precommitRejectedOldWriters :: !(Set EpochTopologyBinding)
  , promotedBindings :: !(Set EpochTopologyBinding)
  , postcommitRejectedOldWriters :: !(Set EpochTopologyBinding)
  , retiredPreparedBindings :: !(Set EpochTopologyBinding)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EpochBindingReadback = EpochBindingReadback
  { readbackBinding :: !EpochTopologyBinding
  , readbackBindingDigest :: !CutoverDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EpochPromotionAction
  = ObservePreparedEpochBinding !EpochBindingReadback
  | ObserveOldEpochRejected !EpochBindingReadback !Word
  | CommitFrozenEpoch
  | ObservePromotedEpochBinding !EpochBindingReadback
  | OpenEpochAdmission
  | BeginPreparedEpochRollback
  | ObservePreparedEpochBindingAbsent !EpochTopologyBinding
  | FinishPreparedEpochRollback
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EpochPromotionRequest = EpochPromotionRequest
  { promotionRequestEpoch :: !Word
  , promotionRequestTopology :: !CutoverDigest
  , promotionRequestAction :: !EpochPromotionAction
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EpochPromotionRefusal
  = PromotionEpochInvalid
  | PromotionEpochMustAdvance
  | PromotionTopologyInvalid !EpochTopologyError
  | PromotionEpochMismatch
  | PromotionTopologyMismatch
  | PromotionBindingMismatch !EpochTopologyBinding
  | PromotionWrongPhase !EpochPromotionPhase
  | PromotionPreparedBindingsMissing !(Set EpochTopologyBinding)
  | PromotionOldWriterRejectionReadbacksMissing !(Set EpochTopologyBinding)
  | PromotionReadbacksMissing !(Set EpochTopologyBinding)
  | PromotionPreparedBindingAbsenceReadbacksMissing !(Set EpochTopologyBinding)
  | PromotionRequiresGreaterEpochRecovery
  | PromotionStateInvalid
  deriving stock (Eq, Show)

data EpochPromotionDecision
  = EpochPromotionAccepted
  | EpochPromotionAlreadyApplied
  | EpochPromotionRefused !EpochPromotionRefusal
  deriving stock (Eq, Show)

renderEpochPromotionRefusal :: EpochPromotionRefusal -> Text
renderEpochPromotionRefusal refusal = case refusal of
  PromotionEpochInvalid -> "epoch-invalid"
  PromotionEpochMustAdvance -> "epoch-must-advance"
  PromotionTopologyInvalid topologyError -> case topologyError of
    EpochTopologyHomeMissing -> "topology-home-missing"
    EpochTopologyUndeclaredSubstrate -> "topology-undeclared-substrate"
    EpochTopologyInvalidDigest -> "topology-invalid-digest"
    EpochTopologyTooLarge -> "topology-too-large"
    EpochTopologyBindingsDiffer _ _ -> "topology-bindings-differ"
  PromotionEpochMismatch -> "epoch-mismatch"
  PromotionTopologyMismatch -> "topology-mismatch"
  PromotionBindingMismatch _ -> "binding-mismatch"
  PromotionWrongPhase _ -> "wrong-phase"
  PromotionPreparedBindingsMissing _ -> "prepared-bindings-missing"
  PromotionOldWriterRejectionReadbacksMissing _ -> "old-writer-rejection-readbacks-missing"
  PromotionReadbacksMissing _ -> "promotion-readbacks-missing"
  PromotionPreparedBindingAbsenceReadbacksMissing _ -> "prepared-binding-absence-readbacks-missing"
  PromotionRequiresGreaterEpochRecovery -> "greater-epoch-recovery-required"
  PromotionStateInvalid -> "retained-state-invalid"

prepareEpochPromotion
  :: Word
  -> Word
  -> EpochTopology
  -> Either EpochPromotionRefusal EpochPromotionState
prepareEpochPromotion predecessor target topology
  | predecessor == 0 || target == 0 = Left PromotionEpochInvalid
  | target <= predecessor = Left PromotionEpochMustAdvance
  | otherwise = case validateEpochTopology topology of
      Left refusal -> Left (PromotionTopologyInvalid refusal)
      Right () ->
        Right
          EpochPromotionState
            { epochPromotionPhase = EpochPrepared
            , epochPromotionPredecessorEpoch = predecessor
            , epochPromotionTargetEpoch = target
            , epochPromotionTopology = topology
            , preparedBindings = Set.empty
            , precommitRejectedOldWriters = Set.empty
            , promotedBindings = Set.empty
            , postcommitRejectedOldWriters = Set.empty
            , retiredPreparedBindings = Set.empty
            }

stepEpochPromotion
  :: EpochPromotionState
  -> EpochPromotionRequest
  -> (EpochPromotionState, EpochPromotionDecision)
stepEpochPromotion state request
  | Left refusal <- validateEpochPromotionState state = refuse refusal
  | Left refusal <- validateEpochPromotionRequest request = refuse refusal
  | promotionRequestEpoch request /= epochPromotionTargetEpoch state = refuse PromotionEpochMismatch
  | promotionRequestTopology request /= epochTopologyDigest topology =
      refuse PromotionTopologyMismatch
  | otherwise = apply (promotionRequestAction request)
 where
  topology = epochPromotionTopology state
  phase = epochPromotionPhase state
  required = epochTopologyBindings topology
  oldWriters = epochTopologyOldWriterBindings topology
  refuse refusal = (state, EpochPromotionRefused refusal)
  accepted next = (next, EpochPromotionAccepted)
  replay = (state, EpochPromotionAlreadyApplied)
  wrongPhase = refuse (PromotionWrongPhase phase)
  matches readback =
    epochTopologyBindingDigest topology (readbackBinding readback)
      == Just (readbackBindingDigest readback)
  observe readback present update
    | not (matches readback) = refuse (PromotionBindingMismatch (readbackBinding readback))
    | readbackBinding readback `Set.member` present = replay
    | otherwise = accepted (update (Set.insert (readbackBinding readback) present))
  apply action = case action of
    ObservePreparedEpochBinding readback -> case phase of
      EpochPrepared -> observe readback (preparedBindings state) (\rows -> state {preparedBindings = rows})
      EpochFrozen -> replayPrepared readback
      EpochAdmissionOpen -> replayPrepared readback
      EpochPreparedRollback -> wrongPhase
      EpochPreparedBindingsRetired -> wrongPhase
    ObserveOldEpochRejected readback rejectedEpoch
      | rejectedEpoch /= epochPromotionPredecessorEpoch state -> refuse PromotionEpochMismatch
      | readbackBinding readback `Set.notMember` oldWriters ->
          refuse (PromotionBindingMismatch (readbackBinding readback))
      | otherwise -> case phase of
          EpochPrepared ->
            observe
              readback
              (precommitRejectedOldWriters state)
              (\rows -> state {precommitRejectedOldWriters = rows})
          EpochFrozen ->
            observe
              readback
              (postcommitRejectedOldWriters state)
              (\rows -> state {postcommitRejectedOldWriters = rows})
          EpochAdmissionOpen ->
            observe
              readback
              (postcommitRejectedOldWriters state)
              (\rows -> state {postcommitRejectedOldWriters = rows})
          EpochPreparedRollback -> wrongPhase
          EpochPreparedBindingsRetired -> wrongPhase
    CommitFrozenEpoch -> case phase of
      EpochPrepared
        | preparedBindings state /= required ->
            refuse (PromotionPreparedBindingsMissing (required `Set.difference` preparedBindings state))
        | precommitRejectedOldWriters state /= oldWriters ->
            refuse
              ( PromotionOldWriterRejectionReadbacksMissing
                  (oldWriters `Set.difference` precommitRejectedOldWriters state)
              )
        | otherwise -> accepted (state {epochPromotionPhase = EpochFrozen})
      EpochFrozen -> replay
      EpochAdmissionOpen -> replay
      EpochPreparedRollback -> wrongPhase
      EpochPreparedBindingsRetired -> wrongPhase
    ObservePromotedEpochBinding readback -> case phase of
      EpochFrozen -> observe readback (promotedBindings state) (\rows -> state {promotedBindings = rows})
      EpochAdmissionOpen -> observe readback (promotedBindings state) (\rows -> state {promotedBindings = rows})
      EpochPrepared -> wrongPhase
      EpochPreparedRollback -> wrongPhase
      EpochPreparedBindingsRetired -> wrongPhase
    OpenEpochAdmission -> case phase of
      EpochFrozen
        | promotedBindings state /= required ->
            refuse (PromotionReadbacksMissing (required `Set.difference` promotedBindings state))
        | postcommitRejectedOldWriters state /= oldWriters ->
            refuse
              ( PromotionOldWriterRejectionReadbacksMissing
                  (oldWriters `Set.difference` postcommitRejectedOldWriters state)
              )
        | otherwise -> accepted (state {epochPromotionPhase = EpochAdmissionOpen})
      EpochAdmissionOpen -> replay
      EpochPrepared -> wrongPhase
      EpochPreparedRollback -> wrongPhase
      EpochPreparedBindingsRetired -> wrongPhase
    BeginPreparedEpochRollback -> case phase of
      EpochPrepared -> accepted (state {epochPromotionPhase = EpochPreparedRollback})
      EpochPreparedRollback -> replay
      EpochPreparedBindingsRetired -> replay
      EpochFrozen -> refuse PromotionRequiresGreaterEpochRecovery
      EpochAdmissionOpen -> refuse PromotionRequiresGreaterEpochRecovery
    ObservePreparedEpochBindingAbsent binding -> case phase of
      EpochPreparedRollback
        | binding `Set.notMember` required -> refuse (PromotionBindingMismatch binding)
        | binding `Set.member` retiredPreparedBindings state -> replay
        | otherwise ->
            accepted (state {retiredPreparedBindings = Set.insert binding (retiredPreparedBindings state)})
      EpochPreparedBindingsRetired
        | binding `Set.member` required -> replay
        | otherwise -> refuse (PromotionBindingMismatch binding)
      EpochPrepared -> wrongPhase
      EpochFrozen -> refuse PromotionRequiresGreaterEpochRecovery
      EpochAdmissionOpen -> refuse PromotionRequiresGreaterEpochRecovery
    FinishPreparedEpochRollback -> case phase of
      EpochPreparedRollback
        | retiredPreparedBindings state /= required ->
            refuse
              ( PromotionPreparedBindingAbsenceReadbacksMissing
                  (required `Set.difference` retiredPreparedBindings state)
              )
        | otherwise -> accepted (state {epochPromotionPhase = EpochPreparedBindingsRetired})
      EpochPreparedBindingsRetired -> replay
      EpochPrepared -> wrongPhase
      EpochFrozen -> refuse PromotionRequiresGreaterEpochRecovery
      EpochAdmissionOpen -> refuse PromotionRequiresGreaterEpochRecovery
  replayPrepared readback
    | matches readback && readbackBinding readback `Set.member` preparedBindings state = replay
    | otherwise = refuse (PromotionBindingMismatch (readbackBinding readback))

epochPromotionCommittedEpoch :: EpochPromotionState -> Maybe Word
epochPromotionCommittedEpoch state = case epochPromotionPhase state of
  EpochFrozen -> Just (epochPromotionTargetEpoch state)
  EpochAdmissionOpen -> Just (epochPromotionTargetEpoch state)
  EpochPrepared -> Nothing
  EpochPreparedRollback -> Nothing
  EpochPreparedBindingsRetired -> Nothing

validateEpochPromotionState :: EpochPromotionState -> Either EpochPromotionRefusal ()
validateEpochPromotionState state
  | epochPromotionPredecessorEpoch state == 0 || epochPromotionTargetEpoch state == 0 =
      Left PromotionEpochInvalid
  | epochPromotionTargetEpoch state <= epochPromotionPredecessorEpoch state =
      Left PromotionEpochMustAdvance
  | Left refusal <- validateEpochTopology topology = Left (PromotionTopologyInvalid refusal)
  | not
      ( all
          (`Set.isSubsetOf` required)
          [preparedBindings state, promotedBindings state, retiredPreparedBindings state]
      ) =
      invalid
  | not
      ( all
          (`Set.isSubsetOf` oldWriters)
          [precommitRejectedOldWriters state, postcommitRejectedOldWriters state]
      ) =
      invalid
  | otherwise = case epochPromotionPhase state of
      EpochPrepared -> require (noPromotions && Set.null (retiredPreparedBindings state))
      EpochFrozen -> require (fullyPrepared && Set.null (retiredPreparedBindings state))
      EpochAdmissionOpen ->
        require
          ( fullyPrepared
              && promotedBindings state == required
              && postcommitRejectedOldWriters state == oldWriters
              && Set.null (retiredPreparedBindings state)
          )
      EpochPreparedRollback -> require noPromotions
      EpochPreparedBindingsRetired -> require (noPromotions && retiredPreparedBindings state == required)
 where
  topology = epochPromotionTopology state
  required = epochTopologyBindings topology
  oldWriters = epochTopologyOldWriterBindings topology
  invalid = Left PromotionStateInvalid
  require condition = if condition then Right () else invalid
  noPromotions = Set.null (promotedBindings state) && Set.null (postcommitRejectedOldWriters state)
  fullyPrepared = preparedBindings state == required && precommitRejectedOldWriters state == oldWriters

validateEpochPromotionRequest :: EpochPromotionRequest -> Either EpochPromotionRefusal ()
validateEpochPromotionRequest request
  | promotionRequestEpoch request == 0 = Left PromotionEpochInvalid
  | not (validDigest (promotionRequestTopology request)) = Left PromotionTopologyMismatch
  | otherwise = case promotionRequestAction request of
      ObservePreparedEpochBinding readback -> validateReadback readback
      ObserveOldEpochRejected readback predecessor
        | predecessor == 0 -> Left PromotionEpochInvalid
        | otherwise -> validateReadback readback
      CommitFrozenEpoch -> Right ()
      ObservePromotedEpochBinding readback -> validateReadback readback
      OpenEpochAdmission -> Right ()
      BeginPreparedEpochRollback -> Right ()
      ObservePreparedEpochBindingAbsent binding -> validateBinding binding
      FinishPreparedEpochRollback -> Right ()
 where
  validDigest digest = mkCutoverDigest (cutoverDigestText digest) == Just digest
  validateReadback readback
    | not (validDigest (readbackBindingDigest readback)) =
        Left (PromotionBindingMismatch (readbackBinding readback))
    | otherwise = validateBinding (readbackBinding readback)
  validateBinding binding
    | validEpochTopologyBinding binding = Right ()
    | otherwise = Left (PromotionBindingMismatch binding)
