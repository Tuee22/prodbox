-- | One finite relationship between a Target one-shot authorization, its
-- bounded worker, and the Lifecycle Authority HTTP client waiting for the
-- terminal response.
module Prodbox.Capacity.TargetWorkerBudget
  ( targetWorkerMaximumRuntimeSeconds
  , targetOneShotAuthorizationLifetimeMicros
  , targetOneShotResponseOverheadMicros
  , targetOneShotResponseTimeoutMicros
  )
where

import Numeric.Natural (Natural)

-- | The Kubernetes active deadline shared by ordinary Target one-shot Jobs.
targetWorkerMaximumRuntimeSeconds :: Natural
targetWorkerMaximumRuntimeSeconds = 180

-- | Authority-owned lifetime for one exact Target operation authorization.
targetOneShotAuthorizationLifetimeMicros :: Natural
targetOneShotAuthorizationLifetimeMicros = 15 * 60 * 1000000

-- | Bounded time outside the authorization interval for request admission,
-- authenticated framing, response encoding, and the socket write.
targetOneShotResponseOverheadMicros :: Natural
targetOneShotResponseOverheadMicros = 30 * 1000000

-- | Target-one-shot-only HTTP timeout. The arithmetic is exact and well
-- inside 'Int' on every supported architecture.
targetOneShotResponseTimeoutMicros :: Int
targetOneShotResponseTimeoutMicros =
  fromIntegral
    ( targetOneShotAuthorizationLifetimeMicros
        + targetOneShotResponseOverheadMicros
    )
