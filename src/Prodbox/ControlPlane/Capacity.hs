{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 1.62 deliverable 2: temporal service-capacity as validated data, plus
-- a bounded FIFO admission state machine.
--
-- A 'ServiceCapacityPlan' is opaque and smart-constructed: an over-committed
-- lane (utilization ρ ≥ 1, or ρ ≥ 1 − headroom) has NO representable plan, so
-- "memory containment alone is not a service-capacity proof" is structural — a
-- tiny bounded queue does not rescue an over-committed lane.
--
-- Admission is a pure @decide@ / @evolve@ state machine over one FIFO sequence:
-- the first @workers@ entries occupy a server, the rest wait. Admission rejects
-- immediately (with a structured reason) when the lane is saturated or the work
-- cannot finish before the caller's remaining deadline budget. Cancellation is a
-- pure transition that frees a queued OR in-service slot; the thread-level cancel
-- is a thin IO wrapper at the boundary (out of scope here). Keeping the machine
-- pure makes queue simulations — saturation, FIFO fairness, cancellation,
-- deadline expiry, recovery — deterministic.
module Prodbox.ControlPlane.Capacity
  ( -- * Opaque validated capacity plan (fields unexported)
    ServiceCapacityPlan
  , RawServiceCapacityPlan (..)
  , ServiceCapacityField (..)
  , ServiceCapacityPlanError (..)
  , mkServiceCapacityPlan

    -- * Read-only projections
  , serviceCapacityArrivalPerSecond
  , serviceCapacityServiceTimeMicros
  , serviceCapacityWorkerCount
  , serviceCapacityQueueCapacity
  , serviceCapacityRejectionThreshold
  , serviceCapacityHeadroomPpm
  , serviceCapacityUtilizationPpm
  , estimatedQueueWaitMicros

    -- * Admission value types
  , RequestId (..)
  , AdmissionRequest (..)
  , QueueTicket
  , ticketRequestId
  , ticketEstimatedCost
  , ticketQueuePosition
  , RejectionReason (..)
  , AdmissionDecision (..)

    -- * Bounded FIFO admission state machine (pure decide / evolve)
  , AdmissionQueue
  , emptyAdmissionQueue
  , queuePlan
  , queueDepth
  , queueOrder
  , queueInService
  , queueWaiting
  , decideAdmission
  , AdmissionEvent (..)
  , evolveAdmission
  , admit
  , replaceAdmission
  , completeService
  , cancelRequest
  )
where

import Data.Foldable (toList)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline
  ( DeadlineAdmission (AdmissionMissesDeadline, AdmissionWithinDeadline)
  , RemainingDuration
  , RetryAfter (RetryAfter)
  , WorkEstimate (WorkEstimate)
  , deadlineAdmission
  )

-- | The unvalidated inputs to a capacity plan. All six raw fields are exported
-- so callers (and tests) can build one; validation is 'mkServiceCapacityPlan'.
data RawServiceCapacityPlan = RawServiceCapacityPlan
  { rawArrivalPerSecond :: !Natural
  -- ^ max steady arrival rate, requests/sec
  , rawServiceTimeMicros :: !Natural
  -- ^ measured/attested per-request service time, micros (§2E/§2F)
  , rawWorkerCount :: !Natural
  -- ^ concurrent servers
  , rawQueueCapacity :: !Natural
  -- ^ hard memory-containment bound on the in-flight count
  , rawRejectionThreshold :: !Natural
  -- ^ admission ceiling (must be @<= queueCapacity@)
  , rawHeadroomPpm :: !Natural
  -- ^ utilization margin, ppm (must be in @(0, 1_000_000)@)
  }
  deriving stock (Eq, Show)

data ServiceCapacityField
  = ArrivalPerSecondField
  | ServiceTimeField
  | WorkerCountField
  | QueueCapacityField
  | RejectionThresholdField
  deriving stock (Bounded, Enum, Eq, Show)

data ServiceCapacityPlanError
  = ServiceCapacityFieldMustBePositive !ServiceCapacityField
  | -- | headroomPpm not in @(0, 1_000_000)@
    ServiceCapacityHeadroomOutOfRange !Natural
  | -- | threshold, capacity
    ServiceCapacityRejectionThresholdExceedsCapacity !Natural !Natural
  | -- | ρ_ppm (@>= 1_000_000@)
    ServiceCapacityOverCommitted !Natural
  | -- | have ρ_ppm, max ρ_ppm
    ServiceCapacityInsufficientHeadroom !Natural !Natural
  deriving stock (Eq, Show)

-- | The opaque validated plan. All fields unexported; read via the projections.
data ServiceCapacityPlan = ServiceCapacityPlan
  { planArrivalPerSecond :: !Natural
  , planServiceTimeMicros :: !Natural
  , planWorkerCount :: !Natural
  , planQueueCapacity :: !Natural
  , planRejectionThreshold :: !Natural
  , planHeadroomPpm :: !Natural
  }
  deriving stock (Eq, Show)

-- | Validate a raw plan. Positivity is checked field-by-field, then headroom
-- range, then the rejection-threshold\/capacity ordering, then the two ρ proofs
-- (over-commit ρ ≥ 1, then insufficient-headroom ρ ≥ 1 − headroom). All
-- arithmetic is exact 'Natural' cross-multiplication (no floats/truncation on
-- the gate; the reported ρ_ppm uses integer division as a diagnostic only).
mkServiceCapacityPlan
  :: RawServiceCapacityPlan -> Either ServiceCapacityPlanError ServiceCapacityPlan
mkServiceCapacityPlan raw
  | arrival == 0 = Left (ServiceCapacityFieldMustBePositive ArrivalPerSecondField)
  | service == 0 = Left (ServiceCapacityFieldMustBePositive ServiceTimeField)
  | workers == 0 = Left (ServiceCapacityFieldMustBePositive WorkerCountField)
  | capacity == 0 = Left (ServiceCapacityFieldMustBePositive QueueCapacityField)
  | threshold == 0 = Left (ServiceCapacityFieldMustBePositive RejectionThresholdField)
  | headroom == 0 || headroom >= 1_000_000 = Left (ServiceCapacityHeadroomOutOfRange headroom)
  | threshold > capacity =
      Left (ServiceCapacityRejectionThresholdExceedsCapacity threshold capacity)
  | offered >= workers * 1_000_000 = Left (ServiceCapacityOverCommitted rhoPpm)
  | offered >= workers * (1_000_000 - headroom) =
      Left (ServiceCapacityInsufficientHeadroom rhoPpm (1_000_000 - headroom))
  | otherwise =
      Right
        ServiceCapacityPlan
          { planArrivalPerSecond = arrival
          , planServiceTimeMicros = service
          , planWorkerCount = workers
          , planQueueCapacity = capacity
          , planRejectionThreshold = threshold
          , planHeadroomPpm = headroom
          }
 where
  arrival = rawArrivalPerSecond raw
  service = rawServiceTimeMicros raw
  workers = rawWorkerCount raw
  capacity = rawQueueCapacity raw
  threshold = rawRejectionThreshold raw
  headroom = rawHeadroomPpm raw
  offered = arrival * service
  rhoPpm = offered `div` workers

serviceCapacityArrivalPerSecond :: ServiceCapacityPlan -> Natural
serviceCapacityArrivalPerSecond = planArrivalPerSecond

serviceCapacityServiceTimeMicros :: ServiceCapacityPlan -> Natural
serviceCapacityServiceTimeMicros = planServiceTimeMicros

serviceCapacityWorkerCount :: ServiceCapacityPlan -> Natural
serviceCapacityWorkerCount = planWorkerCount

serviceCapacityQueueCapacity :: ServiceCapacityPlan -> Natural
serviceCapacityQueueCapacity = planQueueCapacity

serviceCapacityRejectionThreshold :: ServiceCapacityPlan -> Natural
serviceCapacityRejectionThreshold = planRejectionThreshold

serviceCapacityHeadroomPpm :: ServiceCapacityPlan -> Natural
serviceCapacityHeadroomPpm = planHeadroomPpm

-- | The certified utilization ρ, in ppm: @arrival * service `div` workers@.
serviceCapacityUtilizationPpm :: ServiceCapacityPlan -> Natural
serviceCapacityUtilizationPpm plan =
  (serviceCapacityArrivalPerSecond plan * serviceCapacityServiceTimeMicros plan)
    `div` serviceCapacityWorkerCount plan

-- | The estimated queue wait (micros) for a request with @ahead@ requests in
-- front of it: @(ahead `div` workers) * serviceTime@.
estimatedQueueWaitMicros :: ServiceCapacityPlan -> Natural -> Natural
estimatedQueueWaitMicros plan ahead =
  (ahead `div` serviceCapacityWorkerCount plan) * serviceCapacityServiceTimeMicros plan

newtype RequestId = RequestId Natural
  deriving stock (Eq, Ord, Show)

data AdmissionRequest = AdmissionRequest
  { admissionRequestId :: !RequestId
  , admissionRemainingBudget :: !RemainingDuration
  -- ^ already folded against the monotonic clock
  }
  deriving stock (Eq, Show)

-- | An admission ticket, produced ONLY by 'decideAdmission' on an accepted
-- request. Constructor unexported. (Named 'QueueTicket', not @AdmissionTicket@,
-- leaving the doctrine §4 kind-indexed name free.)
data QueueTicket = QueueTicket !RequestId !WorkEstimate !Natural
  deriving stock (Eq, Show)

ticketRequestId :: QueueTicket -> RequestId
ticketRequestId (QueueTicket rid _ _) = rid

ticketEstimatedCost :: QueueTicket -> WorkEstimate
ticketEstimatedCost (QueueTicket _ cost _) = cost

ticketQueuePosition :: QueueTicket -> Natural
ticketQueuePosition (QueueTicket _ _ position) = position

data RejectionReason
  = -- | depth @>= rejectionThreshold@; retry no sooner than the hint
    RejectedSaturated !RetryAfter
  | -- | cost, budget; NOT retryable (the deadline itself cannot be met)
    RejectedDeadlineUnmeetable !WorkEstimate !RemainingDuration
  deriving stock (Eq, Show)

data AdmissionDecision
  = AdmissionAdmit !QueueTicket
  | AdmissionRejected !RejectionReason
  deriving stock (Eq, Show)

-- | The opaque admission queue: its plan plus one FIFO sequence of in-flight
-- request ids. Fields unexported.
data AdmissionQueue = AdmissionQueue
  { admissionQueuePlan :: !ServiceCapacityPlan
  , admissionQueueInFlight :: !(Seq RequestId)
  }

emptyAdmissionQueue :: ServiceCapacityPlan -> AdmissionQueue
emptyAdmissionQueue plan = AdmissionQueue plan Seq.empty

queuePlan :: AdmissionQueue -> ServiceCapacityPlan
queuePlan = admissionQueuePlan

queueDepth :: AdmissionQueue -> Natural
queueDepth = fromIntegral . Seq.length . admissionQueueInFlight

-- | The full FIFO order of in-flight request ids (in-service then waiting).
queueOrder :: AdmissionQueue -> [RequestId]
queueOrder = toList . admissionQueueInFlight

-- | The first @workers@ in-flight ids — those occupying a server.
queueInService :: AdmissionQueue -> [RequestId]
queueInService q =
  take (fromIntegral (serviceCapacityWorkerCount (queuePlan q))) (queueOrder q)

-- | The in-flight ids beyond the first @workers@ — those still waiting.
queueWaiting :: AdmissionQueue -> [RequestId]
queueWaiting q =
  drop (fromIntegral (serviceCapacityWorkerCount (queuePlan q))) (queueOrder q)

-- | Decide whether to admit a request. Rejects immediately when the queue is at
-- its rejection threshold (saturated, retryable) or when the estimated cost
-- (queue wait for the current depth plus own service) does not fit the request's
-- remaining budget (deadline unmeetable, not retryable). Does NOT mutate the
-- queue; pair with 'evolveAdmission'/'admit' to enqueue an accepted request.
decideAdmission :: AdmissionQueue -> AdmissionRequest -> AdmissionDecision
decideAdmission q req
  | depth >= threshold = AdmissionRejected (RejectedSaturated (RetryAfter service))
  | otherwise =
      case deadlineAdmission budget (WorkEstimate cost) of
        AdmissionMissesDeadline _ ->
          AdmissionRejected (RejectedDeadlineUnmeetable (WorkEstimate cost) budget)
        AdmissionWithinDeadline _ ->
          AdmissionAdmit (QueueTicket (admissionRequestId req) (WorkEstimate cost) depth)
 where
  plan = queuePlan q
  depth = queueDepth q
  threshold = serviceCapacityRejectionThreshold plan
  service = serviceCapacityServiceTimeMicros plan
  budget = admissionRemainingBudget req
  cost = estimatedQueueWaitMicros plan depth + service

data AdmissionEvent
  = -- | Append to the FIFO tail (emit only after a decision of 'AdmissionAdmit').
    RequestAdmitted !RequestId
  | -- | Remove a request that finished service (frees a server).
    ServiceCompleted !RequestId
  | -- | Cooperatively cancel a queued OR in-service slot.
    RequestCancelled !RequestId
  deriving stock (Eq, Show)

evolveAdmission :: AdmissionQueue -> AdmissionEvent -> AdmissionQueue
evolveAdmission q event = case event of
  RequestAdmitted rid -> withInFlight (|> rid)
  ServiceCompleted rid -> withInFlight (deleteFirst rid)
  RequestCancelled rid -> withInFlight (deleteFirst rid)
 where
  withInFlight f = q {admissionQueueInFlight = f (admissionQueueInFlight q)}
  deleteFirst rid s = maybe s (`Seq.deleteAt` s) (Seq.findIndexL (== rid) s)

-- | @decide@ then @evolve@ in one step: admits (appending to the FIFO) on an
-- 'AdmissionAdmit', leaves the queue unchanged on any rejection.
admit :: AdmissionQueue -> AdmissionRequest -> (AdmissionDecision, AdmissionQueue)
admit q req = case decideAdmission q req of
  AdmissionAdmit t -> (AdmissionAdmit t, evolveAdmission q (RequestAdmitted (admissionRequestId req)))
  rejected -> (rejected, q)

-- | Re-admit a separately-ticketed continuation in the exact FIFO slot of an
-- existing request. This is the bounded replacement primitive needed by
-- coalescing and multi-transition state machines: queue depth and relative
-- order stay unchanged, while the replacement must independently fit its
-- caller's remaining absolute-deadline budget. A missing source request is a
-- caller invariant failure and is reported as 'Nothing'.
replaceAdmission
  :: RequestId
  -> AdmissionQueue
  -> AdmissionRequest
  -> Maybe (AdmissionDecision, AdmissionQueue)
replaceAdmission oldRequest q req = do
  position <- Seq.findIndexL (== oldRequest) (admissionQueueInFlight q)
  let plan = queuePlan q
      naturalPosition = fromIntegral position
      budget = admissionRemainingBudget req
      cost =
        estimatedQueueWaitMicros plan naturalPosition
          + serviceCapacityServiceTimeMicros plan
      decision = case deadlineAdmission budget (WorkEstimate cost) of
        AdmissionMissesDeadline _ ->
          AdmissionRejected (RejectedDeadlineUnmeetable (WorkEstimate cost) budget)
        AdmissionWithinDeadline _ ->
          AdmissionAdmit
            (QueueTicket (admissionRequestId req) (WorkEstimate cost) naturalPosition)
      replaced =
        q
          { admissionQueueInFlight =
              Seq.update position (admissionRequestId req) (admissionQueueInFlight q)
          }
  pure $ case decision of
    AdmissionAdmit ticket -> (AdmissionAdmit ticket, replaced)
    rejected -> (rejected, q)

completeService :: RequestId -> AdmissionQueue -> AdmissionQueue
completeService rid q = evolveAdmission q (ServiceCompleted rid)

cancelRequest :: RequestId -> AdmissionQueue -> AdmissionQueue
cancelRequest rid q = evolveAdmission q (RequestCancelled rid)
