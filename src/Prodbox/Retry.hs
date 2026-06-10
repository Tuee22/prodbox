{-# LANGUAGE LambdaCase #-}

module Prodbox.Retry
  ( RetryPolicy (..)
  , PollOutcome (..)
  , retryDelayMicros
  , pollUntilReady
  )
where

import Control.Concurrent (threadDelay)
import Data.Text (Text)

data RetryPolicy = RetryPolicy
  { retryPolicyMaxAttempts :: Int
  , retryPolicyBaseDelayMicros :: Int
  , retryPolicyMultiplier :: Int
  , retryPolicyMaxDelayMicros :: Int
  }
  deriving (Eq, Show)

-- | Shared pure backoff calculation. Both the error retrier
-- ('Prodbox.Service.retryServiceAction') and the readiness poller
-- ('pollUntilReady') derive their inter-attempt delay from this single
-- schedule.
retryDelayMicros :: RetryPolicy -> Int -> Int
retryDelayMicros policy attemptIndex =
  min
    (retryPolicyMaxDelayMicros policy)
    (retryPolicyBaseDelayMicros policy * retryPolicyMultiplier policy ^ max 0 attemptIndex)

-- | The outcome of one readiness observation. A 'PollPending' reading is
-- a *successful* observation that reports "not ready yet" — it is NOT an
-- error, and must never be modelled as a retryable 'ServiceError' (see
-- @documents/engineering/haskell_code_guide.md@ → "Two distinct retry
-- shapes — keep them separate"). 'PollFailed' is a genuine error
-- observing the condition at all.
data PollOutcome value
  = PollReady value
  | PollPending Text
  | PollFailed Text
  deriving (Eq, Show)

-- | The readiness poller: repeatedly observe a steady-state predicate
-- until it reports ready, a hard failure occurs, or the attempt budget
-- is exhausted. This is the opposite control-flow shape from the error
-- retrier — it loops on a *successful* "still pending" reading rather
-- than on a *failed* action, so it deliberately does not share the
-- retrier's loop.
--
-- The 'RetryPolicy' backoff schedule is reused for the inter-poll delay,
-- but the two combinators stay distinct: folding "poll until ready" into
-- the error retrier would conflate a pending observation with a failure.
--
-- On timeout the last 'PollPending' detail is surfaced as the @Left@.
pollUntilReady :: RetryPolicy -> IO (PollOutcome value) -> IO (Either Text value)
pollUntilReady policy observe = go 0
 where
  go attemptIndex = do
    outcome <- observe
    case outcome of
      PollReady value -> pure (Right value)
      PollFailed detail -> pure (Left detail)
      PollPending detail
        | attemptIndex + 1 < retryPolicyMaxAttempts policy -> do
            threadDelay (retryDelayMicros policy attemptIndex)
            go (attemptIndex + 1)
        | otherwise -> pure (Left detail)
