-- | Sprint 1.62 deliverable 2: the opaque 'ServiceCapacityPlan' smart constructor
-- and the bounded FIFO 'AdmissionQueue'. Proves that an over-committed lane has no
-- representable plan (memory containment ≠ capacity proof), and that admission is a
-- deterministic decide/evolve machine: saturation rejects, FIFO order is preserved,
-- cancellation frees a queued or in-service slot, deadline-unmeetable work is
-- rejected up front, and the lane recovers after a drain.
module ControlPlaneCapacity
  ( controlPlaneCapacitySuite
  )
where

import Data.Either (isRight)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Capacity
import Prodbox.ControlPlane.Deadline (RemainingDuration (..), RetryAfter (..), WorkEstimate (..))
import Test.Tasty.QuickCheck (NonNegative (..), Small (..))
import TestSupport

-- | A well-formed base plan: 100 req/s, 1000µs service, 2 workers, queue cap 4,
-- rejection threshold 3, 10% headroom. ρ = 100*1000/2 = 50000 ppm = 5%.
base :: RawServiceCapacityPlan
base =
  RawServiceCapacityPlan
    { rawArrivalPerSecond = 100
    , rawServiceTimeMicros = 1000
    , rawWorkerCount = 2
    , rawQueueCapacity = 4
    , rawRejectionThreshold = 3
    , rawHeadroomPpm = 100000
    }

p :: ServiceCapacityPlan
p = either (error . show) id (mkServiceCapacityPlan base)

bigBudget :: Natural
bigBudget = 100000

reqB :: Natural -> AdmissionRequest
reqB rid = AdmissionRequest (RequestId rid) (RemainingDuration bigBudget)

-- | Fold @admit@ over ids @1..n@ with a generous budget (admission caps at the
-- rejection threshold, so depth never exceeds it).
admitMany :: Natural -> AdmissionQueue
admitMany n = foldl step (emptyAdmissionQueue p) [1 .. n]
 where
  step q i = snd (admit q (reqB i))

queueAtDepth :: Natural -> AdmissionQueue
queueAtDepth = admitMany

admitInfo :: AdmissionDecision -> Maybe (RequestId, WorkEstimate, Natural)
admitInfo (AdmissionAdmit t) = Just (ticketRequestId t, ticketEstimatedCost t, ticketQueuePosition t)
admitInfo (AdmissionRejected _) = Nothing

isAdmit :: AdmissionDecision -> Bool
isAdmit (AdmissionAdmit _) = True
isAdmit (AdmissionRejected _) = False

depthBoundedProperty :: NonNegative (Small Int) -> Bool
depthBoundedProperty (NonNegative (Small k)) =
  queueDepth (admitMany (fromIntegral k)) <= serviceCapacityRejectionThreshold p

inServiceBoundedProperty :: NonNegative (Small Int) -> Bool
inServiceBoundedProperty (NonNegative (Small k)) =
  fromIntegral (length (queueInService (admitMany (fromIntegral k))))
    <= serviceCapacityWorkerCount p

controlPlaneCapacitySuite :: SuiteBuilder ()
controlPlaneCapacitySuite =
  describe "Sprint 1.62 Capacity" $ do
    describe "mkServiceCapacityPlan validation" $ do
      it "rejects zero arrival rate" $
        mkServiceCapacityPlan base {rawArrivalPerSecond = 0}
          `shouldBe` Left (ServiceCapacityFieldMustBePositive ArrivalPerSecondField)
      it "rejects zero service time" $
        mkServiceCapacityPlan base {rawServiceTimeMicros = 0}
          `shouldBe` Left (ServiceCapacityFieldMustBePositive ServiceTimeField)
      it "rejects zero worker count" $
        mkServiceCapacityPlan base {rawWorkerCount = 0}
          `shouldBe` Left (ServiceCapacityFieldMustBePositive WorkerCountField)
      it "rejects zero queue capacity" $
        mkServiceCapacityPlan base {rawQueueCapacity = 0}
          `shouldBe` Left (ServiceCapacityFieldMustBePositive QueueCapacityField)
      it "rejects zero rejection threshold" $
        mkServiceCapacityPlan base {rawRejectionThreshold = 0}
          `shouldBe` Left (ServiceCapacityFieldMustBePositive RejectionThresholdField)
      it "rejects zero headroom" $
        mkServiceCapacityPlan base {rawHeadroomPpm = 0}
          `shouldBe` Left (ServiceCapacityHeadroomOutOfRange 0)
      it "rejects a full (1e6 ppm) headroom" $
        mkServiceCapacityPlan base {rawHeadroomPpm = 1000000}
          `shouldBe` Left (ServiceCapacityHeadroomOutOfRange 1000000)
      it "rejects a rejection threshold above capacity" $
        mkServiceCapacityPlan base {rawRejectionThreshold = 5}
          `shouldBe` Left (ServiceCapacityRejectionThresholdExceedsCapacity 5 4)
      it "rejects an over-committed lane (ρ = 2.0)" $
        mkServiceCapacityPlan
          base {rawArrivalPerSecond = 2000, rawServiceTimeMicros = 1000, rawWorkerCount = 1}
          `shouldBe` Left (ServiceCapacityOverCommitted 2000000)
      it "rejects a fully-saturated lane (ρ = 1.0)" $
        mkServiceCapacityPlan
          base {rawArrivalPerSecond = 1000, rawServiceTimeMicros = 1000, rawWorkerCount = 1}
          `shouldBe` Left (ServiceCapacityOverCommitted 1000000)
      it "rejects insufficient headroom (ρ = 0.95 ≥ 0.9)" $
        mkServiceCapacityPlan
          base
            { rawArrivalPerSecond = 950
            , rawServiceTimeMicros = 1000
            , rawWorkerCount = 1
            , rawHeadroomPpm = 100000
            }
          `shouldBe` Left (ServiceCapacityInsufficientHeadroom 950000 900000)
      it "rejects headroom exactly at the boundary (ρ = 1 − headroom)" $
        mkServiceCapacityPlan
          base
            { rawArrivalPerSecond = 900
            , rawServiceTimeMicros = 1000
            , rawWorkerCount = 1
            , rawHeadroomPpm = 100000
            }
          `shouldBe` Left (ServiceCapacityInsufficientHeadroom 900000 900000)
      it "admits a lane just under the headroom boundary (ρ just under)" $
        mkServiceCapacityPlan
          base
            { rawArrivalPerSecond = 899
            , rawServiceTimeMicros = 1000
            , rawWorkerCount = 1
            , rawHeadroomPpm = 100000
            }
          `shouldSatisfy` isRight
      it "a tiny bounded queue does not rescue an over-committed lane" $
        mkServiceCapacityPlan
          base
            { rawQueueCapacity = 1
            , rawRejectionThreshold = 1
            , rawArrivalPerSecond = 2000
            , rawServiceTimeMicros = 1000
            , rawWorkerCount = 1
            }
          `shouldBe` Left (ServiceCapacityOverCommitted 2000000)
      it "accepts the base plan and certifies its utilization" $ do
        mkServiceCapacityPlan base `shouldSatisfy` isRight
        serviceCapacityUtilizationPpm p `shouldBe` 50000

    describe "estimatedQueueWaitMicros" $ do
      it "no wait below one full round of workers" $ do
        estimatedQueueWaitMicros p 0 `shouldBe` 0
        estimatedQueueWaitMicros p 1 `shouldBe` 0
      it "one service time once a full round is ahead" $ do
        estimatedQueueWaitMicros p 2 `shouldBe` 1000
        estimatedQueueWaitMicros p 3 `shouldBe` 1000
      it "two service times at two full rounds" $
        estimatedQueueWaitMicros p 4 `shouldBe` 2000

    describe "decideAdmission" $ do
      it "admits at depth 0 with cost = one service time, position 0" $
        admitInfo
          (decideAdmission (queueAtDepth 0) (AdmissionRequest (RequestId 99) (RemainingDuration 5000)))
          `shouldBe` Just (RequestId 99, WorkEstimate 1000, 0)
      it "admits at depth 2 with cost = queue wait + service, position 2" $
        admitInfo
          (decideAdmission (queueAtDepth 2) (AdmissionRequest (RequestId 99) (RemainingDuration 5000)))
          `shouldBe` Just (RequestId 99, WorkEstimate 2000, 2)
      it "rejects (saturated) at the rejection threshold" $
        decideAdmission (queueAtDepth 3) (AdmissionRequest (RequestId 99) (RemainingDuration 5000))
          `shouldBe` AdmissionRejected (RejectedSaturated (RetryAfter 1000))
      it "rejects (deadline-unmeetable) when the budget is under the cost" $
        decideAdmission (queueAtDepth 2) (AdmissionRequest (RequestId 99) (RemainingDuration 1200))
          `shouldBe` AdmissionRejected (RejectedDeadlineUnmeetable (WorkEstimate 2000) (RemainingDuration 1200))
      it "rejects a too-tight request up front at depth 0" $
        decideAdmission (queueAtDepth 0) (AdmissionRequest (RequestId 99) (RemainingDuration 500))
          `shouldBe` AdmissionRejected (RejectedDeadlineUnmeetable (WorkEstimate 1000) (RemainingDuration 500))
      it "rejects at the strict deadline boundary (budget == cost)" $
        decideAdmission (queueAtDepth 0) (AdmissionRequest (RequestId 99) (RemainingDuration 1000))
          `shouldBe` AdmissionRejected (RejectedDeadlineUnmeetable (WorkEstimate 1000) (RemainingDuration 1000))
      it "rejects a zero-budget request" $
        decideAdmission (queueAtDepth 0) (AdmissionRequest (RequestId 99) (RemainingDuration 0))
          `shouldBe` AdmissionRejected (RejectedDeadlineUnmeetable (WorkEstimate 1000) (RemainingDuration 0))
      it "a rejected admit leaves the queue unchanged" $
        queueDepth (snd (admit (queueAtDepth 2) (AdmissionRequest (RequestId 99) (RemainingDuration 1200))))
          `shouldBe` 2

    describe "AdmissionQueue simulation (deterministic)" $ do
      it "saturates at the rejection threshold" $ do
        let (d1, q1) = admit (emptyAdmissionQueue p) (reqB 1)
            (d2, q2) = admit q1 (reqB 2)
            (d3, q3) = admit q2 (reqB 3)
            (d4, _) = admit q3 (reqB 4)
        map isAdmit [d1, d2, d3] `shouldBe` [True, True, True]
        d4 `shouldBe` AdmissionRejected (RejectedSaturated (RetryAfter 1000))
        queueDepth q3 `shouldBe` 3
      it "preserves FIFO order across the in-service / waiting split" $ do
        let q3 = admitMany 3
        queueOrder q3 `shouldBe` [RequestId 1, RequestId 2, RequestId 3]
        queueInService q3 `shouldBe` [RequestId 1, RequestId 2]
        queueWaiting q3 `shouldBe` [RequestId 3]
      it "cancelling a queued slot frees capacity" $ do
        let q3 = admitMany 3
            q3' = cancelRequest (RequestId 3) q3
        queueDepth q3' `shouldBe` 2
        isAdmit (decideAdmission q3' (reqB 4)) `shouldBe` True
      it "cancelling an in-service slot promotes the next waiter" $ do
        let q3 = admitMany 3
            q3' = cancelRequest (RequestId 1) q3
        queueOrder q3' `shouldBe` [RequestId 2, RequestId 3]
        queueInService q3' `shouldBe` [RequestId 2, RequestId 3]
        queueDepth q3' `shouldBe` 2
      it "recovers admission after a full drain" $ do
        let q3 = admitMany 3
            drained =
              completeService
                (RequestId 3)
                (completeService (RequestId 2) (completeService (RequestId 1) q3))
        queueDepth drained `shouldBe` 0
        isAdmit (decideAdmission drained (reqB 5)) `shouldBe` True
      it "replaces a separately-ticketed continuation in its exact FIFO slot" $ do
        let q3 = admitMany 3
            replacement =
              replaceAdmission
                (RequestId 2)
                q3
                (AdmissionRequest (RequestId 9) (RemainingDuration 5000))
        case replacement of
          Nothing -> expectationFailure "expected replacement target" >> fail "unreachable"
          Just (decision, replaced) -> do
            admitInfo decision `shouldBe` Just (RequestId 9, WorkEstimate 1000, 1)
            queueOrder replaced `shouldBe` [RequestId 1, RequestId 9, RequestId 3]
      it "leaves the original FIFO slot intact when replacement misses its deadline" $ do
        let q3 = admitMany 3
            replacement =
              replaceAdmission
                (RequestId 3)
                q3
                (AdmissionRequest (RequestId 9) (RemainingDuration 1500))
        case replacement of
          Nothing -> expectationFailure "expected replacement target" >> fail "unreachable"
          Just (decision, unchanged) -> do
            decision
              `shouldBe` AdmissionRejected
                (RejectedDeadlineUnmeetable (WorkEstimate 2000) (RemainingDuration 1500))
            queueOrder unchanged `shouldBe` queueOrder q3
      it "is deterministic over a fixed admit/complete script" $ do
        let (a1, s1) = admit (emptyAdmissionQueue p) (reqB 1)
            (a2, s2) = admit s1 (reqB 2)
            (a3, s3) = admit s2 (reqB 3)
            (a4, s4) = admit s3 (reqB 4)
            s5 = completeService (RequestId 1) s4
            (a5, s6) = admit s5 (reqB 5)
        map isAdmit [a1, a2, a3, a4, a5] `shouldBe` [True, True, True, False, True]
        queueDepth s6 `shouldBe` 3
        queueOrder s6 `shouldBe` [RequestId 2, RequestId 3, RequestId 5]
      propertyTest "depth never exceeds the rejection threshold" depthBoundedProperty
      propertyTest "in-service count never exceeds the worker count" inServiceBoundedProperty
