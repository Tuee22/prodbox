-- | One finite relationship between the Provider Worker's child schedule and
-- the Lifecycle Authority HTTP client that waits for its response.
module Prodbox.Capacity.ProviderWorkerBudget
  ( ProviderWorkerBudgetError (..)
  , providerWorkerMaximumChildDeadlineMilliseconds
  , providerWorkerResponseOverheadMilliseconds
  , providerWorkerResponseTimeoutMicros
  , validateProviderWorkerChildDeadlineMilliseconds
  )
where

import Numeric.Natural (Natural)

data ProviderWorkerBudgetError
  = ProviderWorkerChildDeadlineMustBePositive
  | ProviderWorkerChildDeadlineExceedsTransportMaximum !Natural !Natural
  deriving (Eq, Show)

-- | Maximum admitted child-action deadline. Capacity configuration may select
-- a shorter deadline, but never one the fixed Provider transport cannot wait
-- out.
providerWorkerMaximumChildDeadlineMilliseconds :: Natural
providerWorkerMaximumChildDeadlineMilliseconds = 5 * 60 * 1000

-- | Bounded time after the child deadline for authenticated framing, authority
-- projection, response encoding, and the socket write.
providerWorkerResponseOverheadMilliseconds :: Natural
providerWorkerResponseOverheadMilliseconds = 30 * 1000

-- | Provider-only HTTP timeout. The arithmetic is exact and well inside 'Int'
-- on every supported architecture.
providerWorkerResponseTimeoutMicros :: Int
providerWorkerResponseTimeoutMicros =
  fromIntegral
    ( ( providerWorkerMaximumChildDeadlineMilliseconds
          + providerWorkerResponseOverheadMilliseconds
      )
        * 1000
    )

validateProviderWorkerChildDeadlineMilliseconds
  :: Natural -> Either ProviderWorkerBudgetError ()
validateProviderWorkerChildDeadlineMilliseconds deadline
  | deadline == 0 = Left ProviderWorkerChildDeadlineMustBePositive
  | deadline > providerWorkerMaximumChildDeadlineMilliseconds =
      Left
        ( ProviderWorkerChildDeadlineExceedsTransportMaximum
            deadline
            providerWorkerMaximumChildDeadlineMilliseconds
        )
  | otherwise = Right ()
