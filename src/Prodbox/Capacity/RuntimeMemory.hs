-- | Pure runtime-memory planning for Haskell processes.
--
-- A Kubernetes memory limit is an admission and containment boundary.  It is
-- not, by itself, a bound on a process's working set.  This module validates
-- the two nested budgets used to derive a GHC heap cap:
--
-- @
-- application state + pending persistence + heap scratch + heap reserve
--     <= heap cap
--
-- heap cap + native reserve + admitted child peak + cgroup reserve + margin
--     <= container limit
-- @
--
-- The validated plan is opaque.  In particular, the outer sum is derived from
-- the heap cap rather than from its resident terms, so heap memory cannot be
-- counted twice by a caller.
module Prodbox.Capacity.RuntimeMemory
  ( -- * Unit-safe positive byte values
    PositiveBytes
  , MemoryTerm (..)
  , mkPositiveBytes
  , positiveBytesValue

    -- * Child-process schedule
  , RawChildSchedule (..)
  , ChildProcessBudget
  , validateChildSchedule
  , childProcessPermitCount
  , childProcessDeadlineMicros
  , childProcessReservedPeakBytes

    -- * Runtime-memory plan
  , RuntimeMemoryInputs (..)
  , RuntimeMemoryPlan
  , validateRuntimeMemoryPlan
  , runtimeMemoryRetainedHeapBytes
  , runtimeMemoryScratchBytes
  , runtimeMemoryHeapRequiredBytes
  , runtimeMemoryHeapCapBytes
  , runtimeMemoryChildBudget
  , runtimeMemoryOuterRequiredBytes
  , runtimeMemoryContainerLimitBytes
  , runtimeMemorySafetyMarginBytes
  , runtimeMemoryHighWaterBytes

    -- * Generated GHC RTS policy
  , runtimeMemoryRtsArguments
  , renderRuntimeMemoryRtsPolicy

    -- * Validation errors
  , RuntimeMemoryError (..)
  )
where

import Numeric.Natural (Natural)

-- | The semantic role of a positive byte input.  The role is carried by a
-- validation error so configuration failures identify the exact invalid term.
data MemoryTerm
  = BoundedApplicationState
  | BoundedPendingPersistenceState
  | InHeapTransportDecodeScratch
  | OtherHeapReserve
  | HeapCap
  | NativeNonHeapReserve
  | ChildProcessPeak
  | KernelCgroupReserve
  | SafetyMargin
  | ContainerMemoryLimit
  deriving (Bounded, Enum, Eq, Show)

-- | A strictly positive byte count.  Its constructor is intentionally hidden;
-- callers must use 'mkPositiveBytes'.
newtype PositiveBytes = PositiveBytes Natural
  deriving (Eq, Ord, Show)

-- | Validate a raw byte count and retain its semantic role in any error.
mkPositiveBytes :: MemoryTerm -> Natural -> Either RuntimeMemoryError PositiveBytes
mkPositiveBytes term value
  | value > 0 = Right (PositiveBytes value)
  | otherwise = Left (MemoryTermMustBePositive term)

-- | Project a validated byte count for rendering or boundary conversion.
positiveBytesValue :: PositiveBytes -> Natural
positiveBytesValue (PositiveBytes value) = value

-- | The raw child-process scheduling claim.
--
-- 'UnboundedChildSchedule' is representable only at the decode/planning
-- boundary so validation can refuse it explicitly.  A bounded schedule names
-- a finite positive permit count, a finite positive deadline in microseconds,
-- and positive peak byte observations:
--
-- * with one permit, the entries are possible serialized child actions and
--   the admitted reserve is their maximum;
-- * with more than one permit, the entries are the simultaneous peak slots,
--   so their count must equal the permit count and the admitted reserve is
--   their sum.
data RawChildSchedule
  = UnboundedChildSchedule
  | BoundedChildSchedule
      { rawChildPermitCount :: Natural
      , rawChildDeadlineMicros :: Maybe Natural
      , rawChildPeakBytes :: [Natural]
      }
  deriving (Eq, Show)

-- | A validated finite child-process budget.  The constructor is hidden so a
-- runtime-memory plan cannot be built from an unbounded or mismatched schedule.
data ChildProcessBudget = ChildProcessBudget
  { validatedChildPermitCount :: Natural
  , validatedChildDeadlineMicros :: Natural
  , validatedChildReservedPeakBytes :: PositiveBytes
  }
  deriving (Eq, Show)

-- | Validate the bounded-concurrency witness and derive its admitted peak.
validateChildSchedule :: RawChildSchedule -> Either RuntimeMemoryError ChildProcessBudget
validateChildSchedule rawSchedule =
  case rawSchedule of
    UnboundedChildSchedule -> Left ChildScheduleMustBeBounded
    BoundedChildSchedule permitCount maybeDeadline peaks -> do
      validatePermitCount permitCount
      deadline <- validateDeadline maybeDeadline
      validatedPeaks <- validateChildPeaks peaks
      reservedPeak <- deriveReservedChildPeak permitCount validatedPeaks
      Right
        ChildProcessBudget
          { validatedChildPermitCount = permitCount
          , validatedChildDeadlineMicros = deadline
          , validatedChildReservedPeakBytes = reservedPeak
          }

-- | The maximum number of children admitted simultaneously.
childProcessPermitCount :: ChildProcessBudget -> Natural
childProcessPermitCount = validatedChildPermitCount

-- | The positive finite deadline attached to every admitted child action.
childProcessDeadlineMicros :: ChildProcessBudget -> Natural
childProcessDeadlineMicros = validatedChildDeadlineMicros

-- | The maximum child memory reserved by the validated schedule.
childProcessReservedPeakBytes :: ChildProcessBudget -> PositiveBytes
childProcessReservedPeakBytes = validatedChildReservedPeakBytes

-- | Raw positive inputs to the nested runtime-memory proof.  The child
-- schedule deliberately remains raw here: 'validateRuntimeMemoryPlan' is the
-- only path that combines its validated reserve with the outer inequality.
data RuntimeMemoryInputs = RuntimeMemoryInputs
  { runtimeBoundedApplicationState :: PositiveBytes
  , runtimeBoundedPendingPersistenceState :: PositiveBytes
  , runtimeInHeapTransportDecodeScratch :: PositiveBytes
  , runtimeOtherHeapReserve :: PositiveBytes
  , runtimeHeapCap :: PositiveBytes
  , runtimeNativeNonHeapReserve :: PositiveBytes
  , runtimeRawChildSchedule :: RawChildSchedule
  , runtimeKernelCgroupReserve :: PositiveBytes
  , runtimeSafetyMargin :: PositiveBytes
  , runtimeContainerMemoryLimit :: PositiveBytes
  }
  deriving (Eq, Show)

-- | An opaque proof that both runtime-memory inequalities hold.
data RuntimeMemoryPlan = RuntimeMemoryPlan
  { validatedRuntimeInputs :: RuntimeMemoryInputs
  , validatedRuntimeChildBudget :: ChildProcessBudget
  , validatedRuntimeRetainedHeapBytes :: PositiveBytes
  , validatedRuntimeHeapRequiredBytes :: PositiveBytes
  , validatedRuntimeOuterRequiredBytes :: PositiveBytes
  , validatedRuntimeHighWaterBytes :: PositiveBytes
  }
  deriving (Eq, Show)

-- | Validate both nested inequalities and derive the plan's observation and
-- RTS-policy inputs.
validateRuntimeMemoryPlan
  :: RuntimeMemoryInputs
  -> Either RuntimeMemoryError RuntimeMemoryPlan
validateRuntimeMemoryPlan inputs = do
  childBudget <- validateChildSchedule (runtimeRawChildSchedule inputs)
  let retainedHeap =
        addPositiveBytes
          (runtimeBoundedApplicationState inputs)
          (runtimeBoundedPendingPersistenceState inputs)
      heapRequired =
        sumPositiveBytes
          retainedHeap
          [ runtimeInHeapTransportDecodeScratch inputs
          , runtimeOtherHeapReserve inputs
          ]
      heapCap = runtimeHeapCap inputs
  if heapRequired > heapCap
    then
      Left
        HeapBudgetExceedsCap
          { requiredHeapBytes = positiveBytesValue heapRequired
          , configuredHeapCapBytes = positiveBytesValue heapCap
          }
    else do
      let outerRequired =
            sumPositiveBytes
              heapCap
              [ runtimeNativeNonHeapReserve inputs
              , childProcessReservedPeakBytes childBudget
              , runtimeKernelCgroupReserve inputs
              , runtimeSafetyMargin inputs
              ]
          containerLimit = runtimeContainerMemoryLimit inputs
      if outerRequired > containerLimit
        then
          Left
            RuntimeBudgetExceedsContainerLimit
              { requiredContainerBytes = positiveBytesValue outerRequired
              , configuredContainerLimitBytes = positiveBytesValue containerLimit
              }
        else case subtractPositiveBytes containerLimit (runtimeSafetyMargin inputs) of
          Nothing ->
            Left
              RuntimeBudgetExceedsContainerLimit
                { requiredContainerBytes = positiveBytesValue outerRequired
                , configuredContainerLimitBytes = positiveBytesValue containerLimit
                }
          Just highWater ->
            Right
              RuntimeMemoryPlan
                { validatedRuntimeInputs = inputs
                , validatedRuntimeChildBudget = childBudget
                , validatedRuntimeRetainedHeapBytes = retainedHeap
                , validatedRuntimeHeapRequiredBytes = heapRequired
                , validatedRuntimeOuterRequiredBytes = outerRequired
                , validatedRuntimeHighWaterBytes = highWater
                }

-- | Bounded application state plus bounded pending-persistence state.
runtimeMemoryRetainedHeapBytes :: RuntimeMemoryPlan -> PositiveBytes
runtimeMemoryRetainedHeapBytes = validatedRuntimeRetainedHeapBytes

-- | Maximum in-heap transport and decode scratch available to later runtime
-- consumers without importing their behavior into this planner.
runtimeMemoryScratchBytes :: RuntimeMemoryPlan -> PositiveBytes
runtimeMemoryScratchBytes =
  runtimeInHeapTransportDecodeScratch . validatedRuntimeInputs

-- | The complete inner sum checked against the heap cap.
runtimeMemoryHeapRequiredBytes :: RuntimeMemoryPlan -> PositiveBytes
runtimeMemoryHeapRequiredBytes = validatedRuntimeHeapRequiredBytes

-- | The derived maximum heap value used by the generated GHC RTS policy.
runtimeMemoryHeapCapBytes :: RuntimeMemoryPlan -> PositiveBytes
runtimeMemoryHeapCapBytes = runtimeHeapCap . validatedRuntimeInputs

-- | The validated child-process concurrency and peak witness.
runtimeMemoryChildBudget :: RuntimeMemoryPlan -> ChildProcessBudget
runtimeMemoryChildBudget = validatedRuntimeChildBudget

-- | The complete outer sum checked against the container limit.
runtimeMemoryOuterRequiredBytes :: RuntimeMemoryPlan -> PositiveBytes
runtimeMemoryOuterRequiredBytes = validatedRuntimeOuterRequiredBytes

-- | The authored container/cgroup ceiling used by the outer proof.
runtimeMemoryContainerLimitBytes :: RuntimeMemoryPlan -> PositiveBytes
runtimeMemoryContainerLimitBytes =
  runtimeContainerMemoryLimit . validatedRuntimeInputs

-- | The explicit safety margin left inside the container limit.
runtimeMemorySafetyMarginBytes :: RuntimeMemoryPlan -> PositiveBytes
runtimeMemorySafetyMarginBytes = runtimeSafetyMargin . validatedRuntimeInputs

-- | The cgroup high-water observation threshold: container limit minus the
-- explicit safety margin.  The outer inequality and positive heap/reserve
-- terms prove this subtraction remains strictly positive.
runtimeMemoryHighWaterBytes :: RuntimeMemoryPlan -> PositiveBytes
runtimeMemoryHighWaterBytes = validatedRuntimeHighWaterBytes

-- | Deterministic argv suffix for a process launched with the validated plan.
-- The heap cap is rendered as an exact byte count; no machine- or chart-local
-- value participates in this function.
runtimeMemoryRtsArguments :: RuntimeMemoryPlan -> [String]
runtimeMemoryRtsArguments plan =
  [ "+RTS"
  , "-M" ++ show (positiveBytesValue (runtimeMemoryHeapCapBytes plan))
  , "-RTS"
  ]

-- | Render the generated GHC RTS argv for plan goldens and diagnostics.
renderRuntimeMemoryRtsPolicy :: RuntimeMemoryPlan -> String
renderRuntimeMemoryRtsPolicy = unwords . runtimeMemoryRtsArguments

-- | Structured failures from the positive-value, child-schedule, and nested
-- memory-plan validators.
data RuntimeMemoryError
  = MemoryTermMustBePositive MemoryTerm
  | ChildScheduleMustBeBounded
  | ChildPermitCountMustBePositive
  | ChildDeadlineMissing
  | ChildDeadlineMustBePositive
  | ChildPeakListMustNotBeEmpty
  | ChildPeakMustBePositive
      { invalidChildPeakIndex :: Natural
      }
  | ConcurrentChildPeakCountMismatch
      { expectedChildPeakCount :: Natural
      , actualChildPeakCount :: Natural
      }
  | HeapBudgetExceedsCap
      { requiredHeapBytes :: Natural
      , configuredHeapCapBytes :: Natural
      }
  | RuntimeBudgetExceedsContainerLimit
      { requiredContainerBytes :: Natural
      , configuredContainerLimitBytes :: Natural
      }
  deriving (Eq, Show)

validatePermitCount :: Natural -> Either RuntimeMemoryError ()
validatePermitCount permitCount
  | permitCount > 0 = Right ()
  | otherwise = Left ChildPermitCountMustBePositive

validateDeadline :: Maybe Natural -> Either RuntimeMemoryError Natural
validateDeadline maybeDeadline =
  case maybeDeadline of
    Nothing -> Left ChildDeadlineMissing
    Just deadline
      | deadline > 0 -> Right deadline
      | otherwise -> Left ChildDeadlineMustBePositive

validateChildPeaks :: [Natural] -> Either RuntimeMemoryError [PositiveBytes]
validateChildPeaks peaks =
  case peaks of
    [] -> Left ChildPeakListMustNotBeEmpty
    _ -> traverse validatePeak (zip [0 ..] peaks)
 where
  validatePeak (index, peak) =
    case mkPositiveBytes ChildProcessPeak peak of
      Left _ -> Left (ChildPeakMustBePositive index)
      Right validatedPeak -> Right validatedPeak

deriveReservedChildPeak
  :: Natural
  -> [PositiveBytes]
  -> Either RuntimeMemoryError PositiveBytes
deriveReservedChildPeak permitCount validatedPeaks =
  case validatedPeaks of
    [] -> Left ChildPeakListMustNotBeEmpty
    firstPeak : remainingPeaks
      | permitCount == 1 ->
          Right (foldl' max firstPeak remainingPeaks)
      | permitCount == fromIntegral (length validatedPeaks) ->
          Right (sumPositiveBytes firstPeak remainingPeaks)
      | otherwise ->
          Left
            ConcurrentChildPeakCountMismatch
              { expectedChildPeakCount = permitCount
              , actualChildPeakCount = fromIntegral (length validatedPeaks)
              }

addPositiveBytes :: PositiveBytes -> PositiveBytes -> PositiveBytes
addPositiveBytes (PositiveBytes left) (PositiveBytes right) =
  PositiveBytes (left + right)

sumPositiveBytes :: PositiveBytes -> [PositiveBytes] -> PositiveBytes
sumPositiveBytes = foldl' addPositiveBytes

subtractPositiveBytes :: PositiveBytes -> PositiveBytes -> Maybe PositiveBytes
subtractPositiveBytes (PositiveBytes outer) (PositiveBytes inner) =
  if inner < outer
    then Just (PositiveBytes (outer - inner))
    else Nothing
