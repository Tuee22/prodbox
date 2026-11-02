{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | One bounded, non-secret snapshot for restart-safe promotion clients. The
-- full declared topology is included, while transient prepared/promoted sets
-- remain in the aggregate; adapters re-observe exact rows before effects.
module Prodbox.Lifecycle.Authority.EpochPromotionObservation
  ( EpochPromotionObservation (..)
  , PreparedEpochObservation (..)
  , EpochPromotionObservationError (..)
  , observeEpochPromotion
  , validateEpochPromotionObservation
  , renderEpochPromotionObservationError
  )
where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochValue
  )

data EpochPromotionObservation = EpochPromotionObservation
  { observedRetainedEpoch :: !Word
  , observedNormalAdmissionEpoch :: !(Maybe Word)
  , observedPreparedEpoch :: !(Maybe PreparedEpochObservation)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PreparedEpochObservation = PreparedEpochObservation
  { observedPreparationPredecessor :: !Word
  , observedPreparationTarget :: !Word
  , observedPreparationPhase :: !EpochPromotionPhase
  , observedPreparationTopologyDigest :: !CutoverDigest
  , observedPreparationTopology :: !EpochTopology
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EpochPromotionObservationError
  = EpochObservationEpochOutOfRange
  | EpochObservationNormalAdmissionMismatch
  | EpochObservationPromotionStateInvalid
  | EpochObservationTopologyInvalid !EpochTopologyError
  | EpochObservationTopologyDigestMismatch
  deriving stock (Eq, Show)

observeEpochPromotion
  :: AuthorityEpoch
  -> Maybe AuthorityEpoch
  -> Maybe EpochPromotionState
  -> Either EpochPromotionObservationError EpochPromotionObservation
observeEpochPromotion retained normal promotion = do
  retainedWord <- boundedEpoch retained
  normalWord <- traverse boundedEpoch normal
  prepared <- traverse prepareObservation promotion
  let observation = EpochPromotionObservation retainedWord normalWord prepared
  validateEpochPromotionObservation observation
  pure observation
 where
  boundedEpoch epoch
    | authorityEpochValue epoch > fromIntegral (maxBound :: Word) = Left EpochObservationEpochOutOfRange
    | otherwise = Right (fromIntegral (authorityEpochValue epoch))
  prepareObservation state = case validateEpochPromotionState state of
    Left _ -> Left EpochObservationPromotionStateInvalid
    Right () ->
      Right
        PreparedEpochObservation
          { observedPreparationPredecessor = epochPromotionPredecessorEpoch state
          , observedPreparationTarget = epochPromotionTargetEpoch state
          , observedPreparationPhase = epochPromotionPhase state
          , observedPreparationTopologyDigest = epochTopologyDigest (epochPromotionTopology state)
          , observedPreparationTopology = epochPromotionTopology state
          }

validateEpochPromotionObservation
  :: EpochPromotionObservation -> Either EpochPromotionObservationError ()
validateEpochPromotionObservation observation
  | observedRetainedEpoch observation == 0 = Left EpochObservationEpochOutOfRange
  | Just epoch <- observedNormalAdmissionEpoch observation
  , epoch /= observedRetainedEpoch observation =
      Left EpochObservationNormalAdmissionMismatch
  | otherwise = case observedPreparedEpoch observation of
      Nothing -> Right ()
      Just prepared
        | observedPreparationPredecessor prepared == 0
            || observedPreparationTarget prepared <= observedPreparationPredecessor prepared ->
            Left EpochObservationEpochOutOfRange
        | Left err <- validateEpochTopology (observedPreparationTopology prepared) ->
            Left (EpochObservationTopologyInvalid err)
        | observedPreparationTopologyDigest prepared
            /= epochTopologyDigest (observedPreparationTopology prepared) ->
            Left EpochObservationTopologyDigestMismatch
        | Just normal <- observedNormalAdmissionEpoch observation
        , observedPreparationPhase prepared /= EpochAdmissionOpen
            || normal /= observedPreparationTarget prepared ->
            Left EpochObservationNormalAdmissionMismatch
        | otherwise -> Right ()

renderEpochPromotionObservationError :: EpochPromotionObservationError -> Text
renderEpochPromotionObservationError failure = case failure of
  EpochObservationEpochOutOfRange -> "epoch-out-of-range"
  EpochObservationNormalAdmissionMismatch -> "normal-admission-mismatch"
  EpochObservationPromotionStateInvalid -> "promotion-state-invalid"
  EpochObservationTopologyInvalid _ -> "topology-invalid"
  EpochObservationTopologyDigestMismatch -> "topology-digest-mismatch"
