-- | One finite relationship between a retained-material delivery operation
-- and the two route-specific HTTP clients that wait for its terminal receipt.
module Prodbox.Capacity.RetainedMaterialDeliveryBudget
  ( retainedMaterialDeliveryOperationLifetimeMicros
  , retainedMaterialDeliveryResponseOverheadMicros
  , retainedMaterialDeliveryResponseTimeoutMicros
  )
where

import Numeric.Natural (Natural)

-- | Authority-owned lifetime for one persisted delivery attempt.
retainedMaterialDeliveryOperationLifetimeMicros :: Natural
retainedMaterialDeliveryOperationLifetimeMicros = 5 * 60 * 1000000

-- | Bounded time after the operation deadline for authenticated framing,
-- response encoding, and the socket write.
retainedMaterialDeliveryResponseOverheadMicros :: Natural
retainedMaterialDeliveryResponseOverheadMicros = 30 * 1000000

-- | Retained-delivery-only HTTP timeout. The arithmetic is exact and well
-- inside 'Int' on every supported architecture.
retainedMaterialDeliveryResponseTimeoutMicros :: Int
retainedMaterialDeliveryResponseTimeoutMicros =
  fromIntegral
    ( retainedMaterialDeliveryOperationLifetimeMicros
        + retainedMaterialDeliveryResponseOverheadMicros
    )
