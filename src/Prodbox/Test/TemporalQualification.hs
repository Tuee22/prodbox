{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure temporal qualification oracle for the canonical suite.
-- Required telemetry is three-valued and every violation is absorbing for the
-- complete run. Recovery windows may restart, but can never erase evidence.
module Prodbox.Test.TemporalQualification
  ( TemporalPolicy
  , TemporalPolicyError (..)
  , mkTemporalPolicy
  , TemporalSample (..)
  , TemporalIncompleteReason (..)
  , TemporalViolation (..)
  , TemporalObservation (..)
  , classifyTemporalSample
  , TemporalState
  , TemporalReport (..)
  , initialTemporalState
  , foldTemporalObservation
  , beginTemporalRecoveryWindow
  , temporalReport
  , TemporalFaultPoint (..)
  , TemporalFaultResolution (..)
  , TemporalFaultResult (..)
  , TemporalFaultScheduleError (..)
  , validateTemporalFaultSchedule
  , runDeterministicTemporalFaultSchedule
  , DurableProgress (..)
  , TemporalConvergenceSample (..)
  , TemporalConvergenceError (..)
  , validateTemporalConvergence
  )
where

import Data.List (nub)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Numeric.Natural (Natural)

data TemporalPolicy = TemporalPolicy
  { policyThrottlePpmMaximum :: !Natural
  , policyQueueCapacity :: !Natural
  , policyQueueWaitMicrosMaximum :: !Natural
  , policyServiceMicrosMaximum :: !Natural
  , policyP95MicrosMaximum :: !Natural
  , policyP99MicrosMaximum :: !Natural
  , policyCancellationLagMicrosMaximum :: !Natural
  , policyRequiredStableSamples :: !Natural
  }
  deriving stock (Eq, Show)

data TemporalPolicyError
  = TemporalQueueCapacityMustBePositive
  | TemporalBoundMustBePositive !Text
  deriving stock (Eq, Show)

mkTemporalPolicy
  :: Natural
  -> Natural
  -> Natural
  -> Natural
  -> Natural
  -> Natural
  -> Natural
  -> Natural
  -> Either TemporalPolicyError TemporalPolicy
mkTemporalPolicy throttle queueCapacity queueWait service p95 p99 cancellation stable
  | queueCapacity == 0 = Left TemporalQueueCapacityMustBePositive
  | queueWait == 0 = Left (TemporalBoundMustBePositive "queue_wait")
  | service == 0 = Left (TemporalBoundMustBePositive "service")
  | p95 == 0 = Left (TemporalBoundMustBePositive "p95")
  | p99 == 0 = Left (TemporalBoundMustBePositive "p99")
  | cancellation == 0 = Left (TemporalBoundMustBePositive "cancellation_lag")
  | stable == 0 = Left (TemporalBoundMustBePositive "stable_samples")
  | otherwise =
      Right
        TemporalPolicy
          { policyThrottlePpmMaximum = throttle
          , policyQueueCapacity = queueCapacity
          , policyQueueWaitMicrosMaximum = queueWait
          , policyServiceMicrosMaximum = service
          , policyP95MicrosMaximum = p95
          , policyP99MicrosMaximum = p99
          , policyCancellationLagMicrosMaximum = cancellation
          , policyRequiredStableSamples = stable
          }

data TemporalSample = TemporalSample
  { temporalSampleService :: !Text
  , temporalSamplePodUid :: !Text
  , temporalSampleThrottlePpm :: !(Maybe Natural)
  , temporalSampleQueueOccupancy :: !(Maybe Natural)
  , temporalSampleQueueWaitMicros :: !(Maybe Natural)
  , temporalSampleServiceMicros :: !(Maybe Natural)
  , temporalSampleP95Micros :: !(Maybe Natural)
  , temporalSampleP99Micros :: !(Maybe Natural)
  , temporalSampleDeadlineMisses :: !(Maybe Natural)
  , temporalSampleAdmissionRejections :: !(Maybe Natural)
  , temporalSampleCancellationLagMicros :: !(Maybe Natural)
  , temporalSampleSessionRefreshFailures :: !(Maybe Natural)
  , temporalSampleRestartDelta :: !(Maybe Natural)
  , temporalSampleOomKilled :: !(Maybe Bool)
  , temporalSampleObservedAt :: !Text
  }
  deriving stock (Eq, Show)

data TemporalIncompleteReason
  = TemporalThrottleMissing
  | TemporalQueueOccupancyMissing
  | TemporalQueueWaitMissing
  | TemporalServiceTimeMissing
  | TemporalP95Missing
  | TemporalP99Missing
  | TemporalDeadlineMissesMissing
  | TemporalAdmissionRejectionsMissing
  | TemporalCancellationLagMissing
  | TemporalSessionRefreshFailuresMissing
  | TemporalRestartDeltaMissing
  | TemporalOomEvidenceMissing
  deriving stock (Eq, Ord, Show)

data TemporalViolation
  = TemporalThrottleExceeded !Natural !Natural
  | TemporalQueueSaturated !Natural !Natural
  | TemporalQueueWaitExceeded !Natural !Natural
  | TemporalServiceTimeExceeded !Natural !Natural
  | TemporalP95Exceeded !Natural !Natural
  | TemporalP99Exceeded !Natural !Natural
  | TemporalDeadlineMissed !Natural
  | TemporalAdmissionRejected !Natural
  | TemporalCancellationLagExceeded !Natural !Natural
  | TemporalSessionRefreshFailed !Natural
  | TemporalRestartObserved !Natural
  | TemporalOomObserved
  deriving stock (Eq, Ord, Show)

data TemporalObservation
  = TemporalHealthy !TemporalSample
  | TemporalIncomplete !TemporalIncompleteReason !TemporalSample
  | TemporalUnhealthy ![TemporalViolation] !TemporalSample
  deriving stock (Eq, Show)

classifyTemporalSample :: TemporalPolicy -> TemporalSample -> TemporalObservation
classifyTemporalSample policy sample =
  case firstIncomplete sample of
    Just reason -> TemporalIncomplete reason sample
    Nothing ->
      case violations policy sample of
        [] -> TemporalHealthy sample
        found -> TemporalUnhealthy found sample

data TemporalState = TemporalState
  { stateStableSamples :: !Natural
  , stateRecoveryGeneration :: !Natural
  , stateObservedPodUids :: !(Set Text)
  , stateIncompleteReasons :: !(Set TemporalIncompleteReason)
  , stateViolations :: !(Set TemporalViolation)
  }
  deriving stock (Eq, Show)

data TemporalReport = TemporalReport
  { temporalReportQualified :: !Bool
  , temporalReportStableSamples :: !Natural
  , temporalReportRecoveryGeneration :: !Natural
  , temporalReportObservedPodUids :: !(Set Text)
  , temporalReportIncompleteReasons :: !(Set TemporalIncompleteReason)
  , temporalReportViolations :: !(Set TemporalViolation)
  }
  deriving stock (Eq, Show)

initialTemporalState :: TemporalState
initialTemporalState = TemporalState 0 0 Set.empty Set.empty Set.empty

foldTemporalObservation :: TemporalObservation -> TemporalState -> TemporalState
foldTemporalObservation observation state =
  case observation of
    TemporalHealthy sample -> remember sample state {stateStableSamples = stateStableSamples state + 1}
    TemporalIncomplete reason sample ->
      remember
        sample
        state
          { stateStableSamples = 0
          , stateIncompleteReasons = Set.insert reason (stateIncompleteReasons state)
          }
    TemporalUnhealthy found sample ->
      remember
        sample
        state
          { stateStableSamples = 0
          , stateViolations = Set.union (Set.fromList found) (stateViolations state)
          }

beginTemporalRecoveryWindow :: TemporalState -> TemporalState
beginTemporalRecoveryWindow state =
  state
    { stateStableSamples = 0
    , stateRecoveryGeneration = stateRecoveryGeneration state + 1
    }

temporalReport :: TemporalPolicy -> TemporalState -> TemporalReport
temporalReport policy state =
  TemporalReport
    { temporalReportQualified =
        Set.null (stateIncompleteReasons state)
          && Set.null (stateViolations state)
          && stateStableSamples state >= policyRequiredStableSamples policy
    , temporalReportStableSamples = stateStableSamples state
    , temporalReportRecoveryGeneration = stateRecoveryGeneration state
    , temporalReportObservedPodUids = stateObservedPodUids state
    , temporalReportIncompleteReasons = stateIncompleteReasons state
    , temporalReportViolations = stateViolations state
    }

data TemporalFaultPoint
  = FaultLifecycleAuthorityBeforeCas
  | FaultLifecycleAuthorityAfterCasResponseLost
  | FaultProviderAfterExternalAccept
  | FaultTargetAgentAfterVaultCas
  | FaultMinioDuringReadBack
  | FaultVaultDuringSessionRefresh
  | FaultClientBeforeResponse
  | FaultCleanupNodeFailure
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data TemporalFaultResolution
  = FaultResumedFromIntent
  | FaultAlreadyAppliedAfterReadBack
  | FaultClosedRefusal
  | FaultAmbiguousBlocksSuccessor
  deriving stock (Eq, Ord, Show)

data TemporalFaultResult = TemporalFaultResult
  { temporalFaultPoint :: !TemporalFaultPoint
  , temporalFaultResolution :: !TemporalFaultResolution
  , temporalFaultOperationQueryable :: !Bool
  , temporalFaultCleanupAttempted :: !Bool
  }
  deriving stock (Eq, Ord, Show)

data TemporalFaultScheduleError
  = TemporalFaultPointMissing !TemporalFaultPoint
  | TemporalFaultPointDuplicate !TemporalFaultPoint
  | TemporalFaultOperationNotQueryable !TemporalFaultPoint
  | TemporalFaultCleanupSkipped !TemporalFaultPoint
  deriving stock (Eq, Show)

validateTemporalFaultSchedule
  :: [TemporalFaultResult]
  -> Either TemporalFaultScheduleError [TemporalFaultResult]
validateTemporalFaultSchedule results = do
  mapM_ validatePoint [minBound .. maxBound]
  mapM_ validateResult results
  pure results
 where
  validatePoint point =
    case filter ((== point) . temporalFaultPoint) results of
      [] -> Left (TemporalFaultPointMissing point)
      [_] -> Right ()
      _ -> Left (TemporalFaultPointDuplicate point)
  validateResult result
    | not (temporalFaultOperationQueryable result) =
        Left (TemporalFaultOperationNotQueryable (temporalFaultPoint result))
    | not (temporalFaultCleanupAttempted result) =
        Left (TemporalFaultCleanupSkipped (temporalFaultPoint result))
    | otherwise = Right ()

runDeterministicTemporalFaultSchedule :: [TemporalFaultResult]
runDeterministicTemporalFaultSchedule = map simulate [minBound .. maxBound]
 where
  simulate point =
    TemporalFaultResult
      { temporalFaultPoint = point
      , temporalFaultResolution = resolution point
      , temporalFaultOperationQueryable = True
      , temporalFaultCleanupAttempted = True
      }
  resolution point = case point of
    FaultLifecycleAuthorityBeforeCas -> FaultResumedFromIntent
    FaultLifecycleAuthorityAfterCasResponseLost -> FaultAlreadyAppliedAfterReadBack
    FaultProviderAfterExternalAccept -> FaultAlreadyAppliedAfterReadBack
    FaultTargetAgentAfterVaultCas -> FaultAlreadyAppliedAfterReadBack
    FaultMinioDuringReadBack -> FaultAmbiguousBlocksSuccessor
    FaultVaultDuringSessionRefresh -> FaultClosedRefusal
    FaultClientBeforeResponse -> FaultAlreadyAppliedAfterReadBack
    FaultCleanupNodeFailure -> FaultClosedRefusal

data DurableProgress
  = DurableIntentCommitted
  | DurableEffectApplied
  | DurableReceiptCommitted
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data TemporalConvergenceSample = TemporalConvergenceSample
  { convergenceOperationId :: !Text
  , convergenceAuthorityRevision :: !Natural
  , convergenceTargetGeneration :: !Natural
  , convergenceProgress :: !DurableProgress
  , convergenceGatewayAvailable :: !Bool
  }
  deriving stock (Eq, Show)

data TemporalConvergenceError
  = TemporalConvergenceEmpty
  | TemporalConvergenceOperationChanged !Text !Text
  | TemporalConvergenceAuthorityRegressed !Natural !Natural
  | TemporalConvergenceTargetRegressed !Natural !Natural
  | TemporalConvergenceProgressRegressed !DurableProgress !DurableProgress
  | TemporalConvergenceReceiptMissing
  | TemporalConvergenceTargetMissing
  deriving stock (Eq, Show)

validateTemporalConvergence
  :: [TemporalConvergenceSample]
  -> Either TemporalConvergenceError TemporalConvergenceSample
validateTemporalConvergence samples =
  case samples of
    [] -> Left TemporalConvergenceEmpty
    first : rest -> do
      final <- foldConvergence first rest
      if convergenceProgress final == DurableReceiptCommitted
        then Right ()
        else Left TemporalConvergenceReceiptMissing
      if convergenceTargetGeneration final > 0
        then Right final
        else Left TemporalConvergenceTargetMissing
 where
  foldConvergence previous [] = Right previous
  foldConvergence previous (current : remaining) = do
    if convergenceOperationId current == convergenceOperationId previous
      then Right ()
      else
        Left
          ( TemporalConvergenceOperationChanged
              (convergenceOperationId previous)
              (convergenceOperationId current)
          )
    monotonic
      TemporalConvergenceAuthorityRegressed
      (convergenceAuthorityRevision previous)
      (convergenceAuthorityRevision current)
    monotonic
      TemporalConvergenceTargetRegressed
      (convergenceTargetGeneration previous)
      (convergenceTargetGeneration current)
    if convergenceProgress current >= convergenceProgress previous
      then Right ()
      else
        Left
          ( TemporalConvergenceProgressRegressed
              (convergenceProgress previous)
              (convergenceProgress current)
          )
    foldConvergence current remaining
  monotonic constructor previous current =
    if current >= previous then Right () else Left (constructor previous current)

remember :: TemporalSample -> TemporalState -> TemporalState
remember sample state =
  state {stateObservedPodUids = Set.insert (temporalSamplePodUid sample) (stateObservedPodUids state)}

firstIncomplete :: TemporalSample -> Maybe TemporalIncompleteReason
firstIncomplete sample =
  firstJust
    [ missing TemporalThrottleMissing (temporalSampleThrottlePpm sample)
    , missing TemporalQueueOccupancyMissing (temporalSampleQueueOccupancy sample)
    , missing TemporalQueueWaitMissing (temporalSampleQueueWaitMicros sample)
    , missing TemporalServiceTimeMissing (temporalSampleServiceMicros sample)
    , missing TemporalP95Missing (temporalSampleP95Micros sample)
    , missing TemporalP99Missing (temporalSampleP99Micros sample)
    , missing TemporalDeadlineMissesMissing (temporalSampleDeadlineMisses sample)
    , missing TemporalAdmissionRejectionsMissing (temporalSampleAdmissionRejections sample)
    , missing TemporalCancellationLagMissing (temporalSampleCancellationLagMicros sample)
    , missing TemporalSessionRefreshFailuresMissing (temporalSampleSessionRefreshFailures sample)
    , missing TemporalRestartDeltaMissing (temporalSampleRestartDelta sample)
    , missing TemporalOomEvidenceMissing (temporalSampleOomKilled sample)
    ]
 where
  missing reason = maybe (Just reason) (const Nothing)

firstJust :: [Maybe value] -> Maybe value
firstJust [] = Nothing
firstJust (Just value : _) = Just value
firstJust (Nothing : rest) = firstJust rest

violations :: TemporalPolicy -> TemporalSample -> [TemporalViolation]
violations policy sample = nub (concat checks)
 where
  checks =
    [ above TemporalThrottleExceeded (policyThrottlePpmMaximum policy) (temporalSampleThrottlePpm sample)
    , atLeast TemporalQueueSaturated (policyQueueCapacity policy) (temporalSampleQueueOccupancy sample)
    , above
        TemporalQueueWaitExceeded
        (policyQueueWaitMicrosMaximum policy)
        (temporalSampleQueueWaitMicros sample)
    , above
        TemporalServiceTimeExceeded
        (policyServiceMicrosMaximum policy)
        (temporalSampleServiceMicros sample)
    , above TemporalP95Exceeded (policyP95MicrosMaximum policy) (temporalSampleP95Micros sample)
    , above TemporalP99Exceeded (policyP99MicrosMaximum policy) (temporalSampleP99Micros sample)
    , positive TemporalDeadlineMissed (temporalSampleDeadlineMisses sample)
    , positive TemporalAdmissionRejected (temporalSampleAdmissionRejections sample)
    , above
        TemporalCancellationLagExceeded
        (policyCancellationLagMicrosMaximum policy)
        (temporalSampleCancellationLagMicros sample)
    , positive TemporalSessionRefreshFailed (temporalSampleSessionRefreshFailures sample)
    , positive TemporalRestartObserved (temporalSampleRestartDelta sample)
    , case temporalSampleOomKilled sample of Just True -> [TemporalOomObserved]; _ -> []
    ]
  above constructor bound observed = case observed of Just value | value > bound -> [constructor value bound]; _ -> []
  atLeast constructor bound observed = case observed of Just value | value >= bound -> [constructor value bound]; _ -> []
  positive constructor observed = case observed of Just value | value > 0 -> [constructor value]; _ -> []
