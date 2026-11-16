{-# LANGUAGE DerivingStrategies #-}

-- | One uninterrupted pass of the staged coordinator only.
-- Physical interpreters, retries, concurrent attempts and whole-program
-- admission have separate costs and are not represented here.
module Prodbox.Lifecycle.Authority.EpochPromotionSchedule
  ( PromotionSchedule (..)
  , promotionSchedule
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Numeric.Natural (Natural)
import Prodbox.Capacity.RegisteredCallerTraffic
  ( RegisteredCallerTraffic
  , registeredCallerTraffic
  )
import Prodbox.Lifecycle.Authority.EpochPromotion (EpochPromotionPhase (..))
import Prodbox.Lifecycle.Authority.EpochPromotionCoordinator (PromotionIntent (..))
import Prodbox.Lifecycle.Authority.EpochTopology

data PromotionSchedule = PromotionSchedule
  { scheduleAuthorityObservations :: !Natural
  , scheduleAuthoritySubmissions :: !Natural
  , schedulePhysicalActions :: !Natural
  , scheduleTargetBindingReadbacks :: !(Map CutoverSubstrate Natural)
  , scheduleWithPeerRefresh :: !RegisteredCallerTraffic
  }
  deriving stock (Eq, Show)

promotionSchedule
  :: EpochTopology
  -> PromotionIntent
  -> EpochPromotionPhase
  -> Either EpochTopologyError PromotionSchedule
promotionSchedule topology intent phase = do
  validateEpochTopology topology
  let n = fromIntegral (Set.size (epochTopologyBindings topology))
      o = fromIntegral (Set.size (epochTopologyOldWriterBindings topology))
      (observations, submissions, physical) = case (intent, phase) of
        (CompletePromotion, EpochPrepared) -> (4 * n + 2 * o + 5, 2 * n + 2 * o + 2, 2 * n)
        (CompletePromotion, EpochFrozen) -> (2 * n + o + 3, n + o + 1, n)
        (CompletePromotion, EpochAdmissionOpen) -> (2, 0, 0)
        (CompletePromotion, EpochPreparedRollback) -> (1, 0, 0)
        (CompletePromotion, EpochPreparedBindingsRetired) -> (1, 0, 0)
        (RetirePreparation, EpochPrepared) -> (2 * n + 4, n + 2, n)
        (RetirePreparation, EpochPreparedRollback) -> (2 * n + 3, n + 1, n)
        (RetirePreparation, EpochPreparedBindingsRetired) -> (2, 0, 0)
        (RetirePreparation, EpochFrozen) -> (1, 0, 0)
        (RetirePreparation, EpochAdmissionOpen) -> (1, 0, 0)
      -- Each Authority call is preceded by one independently authenticated peer
      -- context read. One cached signer and one Authority channel are assumed.
      signedFrames = 2 * (observations + submissions)
      targetReadbacks =
        Map.fromList
          [ (substrate, count)
          | PendingAcceptedAuthorityBinding substrate <- Set.toAscList (epochTopologyBindings topology)
          , let old = Set.member (PendingAcceptedAuthorityBinding substrate) (epochTopologyOldWriterBindings topology)
                count = targetReadbackCount intent phase old
          , count > 0
          ]
  pure
    ( PromotionSchedule
        observations
        submissions
        physical
        targetReadbacks
        (registeredCallerTraffic signedFrames 1)
    )

-- Counts one successful coordinator pass; retries and physical actions remain
-- outside this projection. Old-writer observations are independent readbacks.
targetReadbackCount :: PromotionIntent -> EpochPromotionPhase -> Bool -> Natural
targetReadbackCount intent phase hasOldWriter = case (intent, phase) of
  (CompletePromotion, EpochPrepared) -> 2 + old 2
  (CompletePromotion, EpochFrozen) -> 1 + old 1
  (CompletePromotion, EpochAdmissionOpen) -> 0
  (CompletePromotion, EpochPreparedRollback) -> 0
  (CompletePromotion, EpochPreparedBindingsRetired) -> 0
  (RetirePreparation, EpochPrepared) -> 1
  (RetirePreparation, EpochPreparedRollback) -> 1
  (RetirePreparation, EpochPreparedBindingsRetired) -> 0
  (RetirePreparation, EpochFrozen) -> 0
  (RetirePreparation, EpochAdmissionOpen) -> 0
 where
  old count = if hasOldWriter then count else 0
