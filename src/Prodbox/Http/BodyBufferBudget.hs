-- | Allocation cursor shared by bounded HTTP collection and payload planning.
module Prodbox.Http.BodyBufferBudget
  ( BodyBufferPlan
  , BodyBufferStep (..)
  , bodyBufferPlan
  , bodyBufferUsedBytes
  , bodyBufferCapacityBytes
  , bodyBufferLivePayloadMaximumBytes
  , bodyBufferTotalPayloadAllocationMaximumBytes
  , appendBodyBufferChunk
  ) where

import Numeric.Natural (Natural)

-- The cursor carries its original limit; a caller cannot supply a foreign
-- capacity or used count at the append boundary.
data BodyBufferPlan = BodyBufferPlan !Int !Int !Int
  deriving (Eq, Show)

data BodyBufferStep
  = BodyBufferExceeded !Natural
  | BodyBufferReuse !BodyBufferPlan
  | BodyBufferAllocate !BodyBufferPlan
  deriving (Eq, Show)

bodyBufferPlan :: Int -> Maybe BodyBufferPlan
bodyBufferPlan limit
  | limit < 0 = Nothing
  | otherwise = Just (BodyBufferPlan limit 0 0)

bodyBufferUsedBytes, bodyBufferCapacityBytes :: BodyBufferPlan -> Int
bodyBufferUsedBytes (BodyBufferPlan _ _ used) = used
bodyBufferCapacityBytes (BodyBufferPlan _ capacity _) = capacity

-- Payload buffers only: a resize may retain both the old and new buffer.
-- Incoming chunks, cursor/ForeignPtr objects, parser, decoded values, GC and
-- kernel state retain separate funding terms.
bodyBufferLivePayloadMaximumBytes :: BodyBufferPlan -> Natural
bodyBufferLivePayloadMaximumBytes (BodyBufferPlan limit _ _) = 2 * fromIntegral limit

-- Capacities at least double until the final clipped allocation. Its
-- geometric prefix and final allocation cost at most three limits. This is
-- cumulative allocation, not residency, independent of network fragmentation.
bodyBufferTotalPayloadAllocationMaximumBytes :: BodyBufferPlan -> Natural
bodyBufferTotalPayloadAllocationMaximumBytes (BodyBufferPlan limit _ _) = 3 * fromIntegral limit

appendBodyBufferChunk :: BodyBufferPlan -> Natural -> BodyBufferStep
appendBodyBufferChunk (BodyBufferPlan limit capacity used) incoming
  | incoming > fromIntegral (limit - used) = BodyBufferExceeded (fromIntegral used + incoming)
  | needed <= capacity = BodyBufferReuse next
  | otherwise = BodyBufferAllocate (BodyBufferPlan limit enlarged needed)
 where
  -- Conversion/addition follow the subtraction check, so both fit Int.
  needed = used + fromIntegral incoming
  next = BodyBufferPlan limit capacity needed
  doubled = capacity + min capacity (limit - capacity)
  enlarged = max needed (if capacity == 0 then min limit 32768 else doubled)
