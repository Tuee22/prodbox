{-# LANGUAGE OverloadedStrings #-}

module TemporalQualification (temporalQualificationSuite) where

import Data.Set qualified as Set
import Numeric.Natural (Natural)
import Prodbox.Test.TemporalQualification
import TestSupport

temporalQualificationSuite :: SuiteBuilder ()
temporalQualificationSuite =
  describe "Sprint 5.19 temporal qualification oracle" $ do
    it "refuses zero queue and temporal bounds" $ do
      mkTemporalPolicy 20000 0 10 10 10 10 10 1 `shouldBe` Left TemporalQueueCapacityMustBePositive
      mkTemporalPolicy 20000 1 0 10 10 10 10 1
        `shouldBe` Left (TemporalBoundMustBePositive "queue_wait")

    it "requires the configured consecutive healthy window" $ do
      let policy = validPolicy 2
          state = foldTemporalObservation (classifyTemporalSample policy healthySample) initialTemporalState
      temporalReportQualified (temporalReport policy state) `shouldBe` False
      temporalReportQualified
        (temporalReport policy (foldTemporalObservation (classifyTemporalSample policy healthySample) state))
        `shouldBe` True

    it "classifies every threshold and zero-count boundary" $ do
      classifyTemporalSample (validPolicy 1) healthySample `shouldBe` TemporalHealthy healthySample
      let bad =
            healthySample
              { temporalSampleThrottlePpm = Just 20001
              , temporalSampleQueueOccupancy = Just 4
              , temporalSampleDeadlineMisses = Just 1
              , temporalSampleOomKilled = Just True
              }
      case classifyTemporalSample (validPolicy 1) bad of
        TemporalUnhealthy found _ ->
          Set.fromList found
            `shouldBe` Set.fromList
              [ TemporalThrottleExceeded 20001 20000
              , TemporalQueueSaturated 4 4
              , TemporalDeadlineMissed 1
              , TemporalOomObserved
              ]
        other -> expectationFailure ("expected unhealthy observation, got " ++ show other)

    it "treats missing telemetry as explicit non-qualification" $ do
      let sample = healthySample {temporalSampleP99Micros = Nothing}
          observation = classifyTemporalSample (validPolicy 1) sample
          report = temporalReport (validPolicy 1) (foldTemporalObservation observation initialTemporalState)
      observation `shouldBe` TemporalIncomplete TemporalP99Missing sample
      temporalReportQualified report `shouldBe` False
      temporalReportIncompleteReasons report `shouldBe` Set.singleton TemporalP99Missing

    it "keeps violations absorbing across Pod replacement and recovery windows" $ do
      let policy = validPolicy 1
          failed = healthySample {temporalSamplePodUid = "pod-a", temporalSampleRestartDelta = Just 1}
          afterFailure = foldTemporalObservation (classifyTemporalSample policy failed) initialTemporalState
          afterRecovery = beginTemporalRecoveryWindow afterFailure
          replacement = healthySample {temporalSamplePodUid = "pod-b"}
          final = foldTemporalObservation (classifyTemporalSample policy replacement) afterRecovery
          report = temporalReport policy final
      temporalReportQualified report `shouldBe` False
      temporalReportViolations report `shouldBe` Set.singleton (TemporalRestartObserved 1)
      temporalReportObservedPodUids report `shouldBe` Set.fromList ["pod-a", "pod-b"]
      temporalReportRecoveryGeneration report `shouldBe` 1

    it "requires one queryable, cleanup-attempted result for every fault point" $ do
      let complete =
            [ TemporalFaultResult point FaultResumedFromIntent True True
            | point <- [minBound .. maxBound]
            ]
      validateTemporalFaultSchedule complete `shouldBe` Right complete
      validateTemporalFaultSchedule (drop 1 complete)
        `shouldBe` Left (TemporalFaultPointMissing FaultLifecycleAuthorityBeforeCas)

    it "simulates the exact deterministic response-loss and fail-closed outcomes" $ do
      let schedule = runDeterministicTemporalFaultSchedule
      validateTemporalFaultSchedule schedule `shouldBe` Right schedule
      map temporalFaultResolution schedule
        `shouldBe` [ FaultResumedFromIntent
                   , FaultAlreadyAppliedAfterReadBack
                   , FaultAlreadyAppliedAfterReadBack
                   , FaultAlreadyAppliedAfterReadBack
                   , FaultAmbiguousBlocksSuccessor
                   , FaultClosedRefusal
                   , FaultAlreadyAppliedAfterReadBack
                   , FaultClosedRefusal
                   ]

    it "refuses skipped cleanup and duplicate fault identities" $ do
      let complete =
            [ TemporalFaultResult point FaultAlreadyAppliedAfterReadBack True True
            | point <- [minBound .. maxBound]
            ]
          skipped =
            TemporalFaultResult FaultCleanupNodeFailure FaultClosedRefusal True False
              : init complete
      validateTemporalFaultSchedule skipped
        `shouldBe` Left (TemporalFaultCleanupSkipped FaultCleanupNodeFailure)
      validateTemporalFaultSchedule
        ( TemporalFaultResult FaultLifecycleAuthorityBeforeCas FaultResumedFromIntent True True
            : complete
        )
        `shouldBe` Left (TemporalFaultPointDuplicate FaultLifecycleAuthorityBeforeCas)

    it "proves Authority and Target convergence while the gateway is unavailable" $ do
      let samples =
            [ convergence 1 0 DurableIntentCommitted False
            , convergence 2 1 DurableEffectApplied False
            , convergence 3 1 DurableReceiptCommitted True
            ]
      validateTemporalConvergence samples
        `shouldBe` Right (convergence 3 1 DurableReceiptCommitted True)

    it "refuses operation substitution and generation regression" $ do
      validateTemporalConvergence
        [ convergence 2 2 DurableEffectApplied False
        , (convergence 3 2 DurableReceiptCommitted False) {convergenceOperationId = "other"}
        ]
        `shouldBe` Left (TemporalConvergenceOperationChanged "operation-1" "other")
      validateTemporalConvergence
        [ convergence 2 2 DurableEffectApplied False
        , convergence 3 1 DurableReceiptCommitted False
        ]
        `shouldBe` Left (TemporalConvergenceTargetRegressed 2 1)

validPolicy :: Natural -> TemporalPolicy
validPolicy stable =
  case mkTemporalPolicy 20000 4 100 200 300 400 500 stable of
    Right policy -> policy
    Left err -> error (show err)

healthySample :: TemporalSample
healthySample =
  TemporalSample
    { temporalSampleService = "gateway"
    , temporalSamplePodUid = "pod-a"
    , temporalSampleThrottlePpm = Just 20000
    , temporalSampleQueueOccupancy = Just 3
    , temporalSampleQueueWaitMicros = Just 100
    , temporalSampleServiceMicros = Just 200
    , temporalSampleP95Micros = Just 300
    , temporalSampleP99Micros = Just 400
    , temporalSampleDeadlineMisses = Just 0
    , temporalSampleAdmissionRejections = Just 0
    , temporalSampleCancellationLagMicros = Just 500
    , temporalSampleSessionRefreshFailures = Just 0
    , temporalSampleRestartDelta = Just 0
    , temporalSampleOomKilled = Just False
    , temporalSampleObservedAt = "2026-08-02T00:00:00Z"
    }

convergence :: Natural -> Natural -> DurableProgress -> Bool -> TemporalConvergenceSample
convergence authorityRevision targetGeneration progress gatewayAvailable =
  TemporalConvergenceSample
    { convergenceOperationId = "operation-1"
    , convergenceAuthorityRevision = authorityRevision
    , convergenceTargetGeneration = targetGeneration
    , convergenceProgress = progress
    , convergenceGatewayAvailable = gatewayAvailable
    }
