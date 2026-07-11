{-# LANGUAGE OverloadedStrings #-}

-- | Capacity-one gateway child-process scheduling.
--
-- This module does not spawn processes. It turns the Phase-1
-- 'RuntimeMemory.ChildProcessBudget' into a capacity-one state machine and
-- exposes only finite, budget-checked 'ScheduledChild' values for a later
-- interpreter.
module Prodbox.Gateway.ChildSchedule
  ( RawChildRequest (..)
  , CapacityOneChildScheduler
  , ScheduledChild
  , ChildScheduleError (..)
  , newCapacityOneChildScheduler
  , newCapacityOneChildSchedulerFromBounds
  , scheduleChild
  , completeChild
  , childSchedulerAvailable
  , scheduledChildName
  , scheduledChildTimeoutMicros
  , scheduledChildPeakBytes
  , scheduledChildLeaseId
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Gateway.Bounds
  ( GatewayBounds
  , gatewayChildDeadlineMicros
  , gatewayChildPeakBytes
  )

-- | Decode/planning-boundary request. Missing timeout or peak fields are
-- explicit invalid states; they never reach 'ScheduledChild'.
data RawChildRequest = RawChildRequest
  { rawChildRequestName :: Text
  , rawChildRequestTimeoutMicros :: Maybe Natural
  , rawChildRequestPeakBytes :: Maybe Natural
  }
  deriving (Eq, Show)

data CapacityOneChildScheduler = CapacityOneChildScheduler
  { schedulerDeadlineMicros :: Int
  , schedulerReservedPeakBytes :: Natural
  , schedulerNextLeaseId :: Natural
  , schedulerActiveLease :: Maybe ScheduledChild
  }
  deriving (Eq, Show)

data ScheduledChild = ScheduledChild
  { validatedScheduledChildName :: Text
  , validatedScheduledChildTimeoutMicros :: Int
  , validatedScheduledChildPeakBytes :: Natural
  , validatedScheduledChildLeaseId :: Natural
  }
  deriving (Eq, Show)

data ChildScheduleError
  = ChildBudgetPermitCountMustBeOne
      { configuredChildPermitCount :: Natural
      }
  | ChildBudgetDeadlineOutOfRange
      { configuredChildDeadlineMicros :: Natural
      }
  | ChildRequestNameMustNotBeEmpty
  | ChildRequestTimeoutMissing
  | ChildRequestTimeoutMustBePositive
  | ChildRequestTimeoutOutOfRange
      { requestedChildTimeoutMicros :: Natural
      }
  | ChildRequestTimeoutExceedsBudget
      { requestedChildTimeoutMicros :: Natural
      , allowedChildTimeoutMicros :: Natural
      }
  | ChildRequestPeakMissing
  | ChildRequestPeakMustBePositive
  | ChildRequestPeakExceedsBudget
      { requestedChildPeakBytes :: Natural
      , allowedChildPeakBytes :: Natural
      }
  | ChildPermitAlreadyHeld
      { activeChildName :: Text
      }
  | ChildPermitNotHeld
  | ChildLeaseDoesNotMatch
      { activeChildLeaseId :: Natural
      , completedChildLeaseId :: Natural
      }
  deriving (Eq, Show)

-- | Compile the Phase-1 witness into the only supported gateway permit shape.
-- The deadline is checked against the finite 'Int' accepted by timeout APIs.
newCapacityOneChildScheduler
  :: RuntimeMemory.ChildProcessBudget
  -> Either ChildScheduleError CapacityOneChildScheduler
newCapacityOneChildScheduler childBudget = do
  let permitCount = RuntimeMemory.childProcessPermitCount childBudget
      deadline = RuntimeMemory.childProcessDeadlineMicros childBudget
      maxIntNatural = fromIntegral (maxBound :: Int)
  if permitCount == 1
    then Right ()
    else Left (ChildBudgetPermitCountMustBeOne permitCount)
  if deadline <= maxIntNatural
    then Right ()
    else Left (ChildBudgetDeadlineOutOfRange deadline)
  Right
    CapacityOneChildScheduler
      { schedulerDeadlineMicros = fromIntegral deadline
      , schedulerReservedPeakBytes =
          RuntimeMemory.positiveBytesValue
            (RuntimeMemory.childProcessReservedPeakBytes childBudget)
      , schedulerNextLeaseId = 1
      , schedulerActiveLease = Nothing
      }

newCapacityOneChildSchedulerFromBounds
  :: GatewayBounds -> Either ChildScheduleError CapacityOneChildScheduler
newCapacityOneChildSchedulerFromBounds bounds =
  let deadline = gatewayChildDeadlineMicros bounds
   in if deadline > fromIntegral (maxBound :: Int)
        then Left (ChildBudgetDeadlineOutOfRange deadline)
        else
          Right
            CapacityOneChildScheduler
              { schedulerDeadlineMicros = fromIntegral deadline
              , schedulerReservedPeakBytes = gatewayChildPeakBytes bounds
              , schedulerNextLeaseId = 1
              , schedulerActiveLease = Nothing
              }

-- | Acquire the sole permit and compile a bounded interpreter input.
scheduleChild
  :: CapacityOneChildScheduler
  -> RawChildRequest
  -> Either ChildScheduleError (ScheduledChild, CapacityOneChildScheduler)
scheduleChild scheduler request = do
  case schedulerActiveLease scheduler of
    Just active -> Left (ChildPermitAlreadyHeld (scheduledChildName active))
    Nothing -> Right ()
  childName <- validateChildName (rawChildRequestName request)
  timeoutMicros <- validateChildTimeout scheduler (rawChildRequestTimeoutMicros request)
  peakBytes <- validateChildPeak scheduler (rawChildRequestPeakBytes request)
  let scheduled =
        ScheduledChild
          { validatedScheduledChildName = childName
          , validatedScheduledChildTimeoutMicros = timeoutMicros
          , validatedScheduledChildPeakBytes = peakBytes
          , validatedScheduledChildLeaseId = schedulerNextLeaseId scheduler
          }
      acquired =
        scheduler
          { schedulerNextLeaseId = schedulerNextLeaseId scheduler + 1
          , schedulerActiveLease = Just scheduled
          }
  Right (scheduled, acquired)

-- | Release only the currently-held lease. Stale or fabricated completions
-- cannot make another child slot available.
completeChild
  :: CapacityOneChildScheduler
  -> ScheduledChild
  -> Either ChildScheduleError CapacityOneChildScheduler
completeChild scheduler completed =
  case schedulerActiveLease scheduler of
    Nothing -> Left ChildPermitNotHeld
    Just active
      | scheduledChildLeaseId active == scheduledChildLeaseId completed ->
          Right scheduler {schedulerActiveLease = Nothing}
      | otherwise ->
          Left
            ChildLeaseDoesNotMatch
              { activeChildLeaseId = scheduledChildLeaseId active
              , completedChildLeaseId = scheduledChildLeaseId completed
              }

childSchedulerAvailable :: CapacityOneChildScheduler -> Bool
childSchedulerAvailable = maybe True (const False) . schedulerActiveLease

scheduledChildName :: ScheduledChild -> Text
scheduledChildName = validatedScheduledChildName

scheduledChildTimeoutMicros :: ScheduledChild -> Int
scheduledChildTimeoutMicros = validatedScheduledChildTimeoutMicros

scheduledChildPeakBytes :: ScheduledChild -> Natural
scheduledChildPeakBytes = validatedScheduledChildPeakBytes

scheduledChildLeaseId :: ScheduledChild -> Natural
scheduledChildLeaseId = validatedScheduledChildLeaseId

validateChildName :: Text -> Either ChildScheduleError Text
validateChildName childName
  | Text.null (Text.strip childName) = Left ChildRequestNameMustNotBeEmpty
  | otherwise = Right (Text.strip childName)

validateChildTimeout
  :: CapacityOneChildScheduler
  -> Maybe Natural
  -> Either ChildScheduleError Int
validateChildTimeout scheduler maybeTimeout =
  case maybeTimeout of
    Nothing -> Left ChildRequestTimeoutMissing
    Just timeoutMicros
      | timeoutMicros == 0 -> Left ChildRequestTimeoutMustBePositive
      | timeoutMicros > fromIntegral (maxBound :: Int) ->
          Left (ChildRequestTimeoutOutOfRange timeoutMicros)
      | timeoutMicros > fromIntegral (schedulerDeadlineMicros scheduler) ->
          Left
            ChildRequestTimeoutExceedsBudget
              { requestedChildTimeoutMicros = timeoutMicros
              , allowedChildTimeoutMicros =
                  fromIntegral (schedulerDeadlineMicros scheduler)
              }
      | otherwise -> Right (fromIntegral timeoutMicros)

validateChildPeak
  :: CapacityOneChildScheduler
  -> Maybe Natural
  -> Either ChildScheduleError Natural
validateChildPeak scheduler maybePeak =
  case maybePeak of
    Nothing -> Left ChildRequestPeakMissing
    Just peakBytes
      | peakBytes == 0 -> Left ChildRequestPeakMustBePositive
      | peakBytes > schedulerReservedPeakBytes scheduler ->
          Left
            ChildRequestPeakExceedsBudget
              { requestedChildPeakBytes = peakBytes
              , allowedChildPeakBytes = schedulerReservedPeakBytes scheduler
              }
      | otherwise -> Right peakBytes
