{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

-- | The one retry surface: the schedule, the jitter, and the two loop shapes.
--
-- Sprint 1.77 makes three things true that were not:
--
--   * __A policy cannot be authored ad hoc.__ 'RetryPolicy' is exported without
--     its constructor. Every schedule the repository actually uses is a named
--     value in this module, and a policy built from data goes through
--     'mkRetryPolicy', which rejects a non-positive attempt budget, a negative
--     delay, a multiplier below one, and a jitter fraction outside @(0, 1]@.
--     This is what Sprint `1.13` validation item 2 — "the retry surface is
--     consumed only through the @RetryPolicy@ API" — should have said: a rule
--     that fails, in the shape Sprint `2.10` item 4 established, rather than a
--     sentence nothing checks.
--   * __Delays are jittered.__ Before this sprint no jitter existed anywhere in
--     the tree, so N clients failing against one dependency retried in permanent
--     lockstep and re-collided on every attempt. Jitter only ever __reduces__ a
--     delay, so no existing attempt budget grows.
--   * __Repetition after an indeterminate outcome requires a witness.__ See
--     'IdempotentOperation'; the disposition axis itself lives in
--     "Prodbox.Service".
module Prodbox.Retry
  ( -- * The policy
    RetryPolicy
  , retryPolicyMaxAttempts
  , retryPolicyBaseDelayMicros
  , retryPolicyMultiplier
  , retryPolicyMaxDelayMicros
  , retryPolicyJitterFraction
  , RetryPolicyError (..)
  , renderRetryPolicyError
  , mkRetryPolicy

    -- * Jitter
  , JitterFraction
  , jitterFractionPartsPerMillion
  , mkJitterFraction
  , defaultJitterFraction
  , jitterSampleBound

    -- * Delays
  , retryDelayMicros
  , jitteredDelayMicros
  , drawRetryDelayMicros

    -- * Idempotence
  , IdempotentOperation
  , idempotentOperation
  , runIdempotentOperation

    -- * Polling
  , PollOutcome (..)
  , pollUntilReady

    -- * The compiled schedules
  , componentReadinessRetryPolicy
  , helmTransientRetryPolicy
  , customImagePushRetryPolicy
  , daemonRestartBridgeRetryPolicy
  , perconaPatroniClaimRetryPolicy
  , patroniClusterReadyRetryPolicy
  , daemonWorkerRetryPolicy
  , compiledRetryPolicies
  )
where

import Control.Concurrent (threadDelay)
import Crypto.Random (getRandomBytes)
import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Numeric.Natural (Natural)

-- | A jitter fraction, in parts per million, in @(0, 1_000_000]@. Held as an
-- integral part-per-million rather than a 'Double' for the same reason the
-- capacity algebra is integral: a schedule that depends on floating-point
-- rounding is a schedule nobody can reproduce.
newtype JitterFraction = JitterFraction
  { jitterFractionPartsPerMillion :: Natural
  }
  deriving (Eq, Ord, Show)

-- | The exclusive upper bound of a jitter sample, and the denominator of a
-- 'JitterFraction'.
jitterSampleBound :: Natural
jitterSampleBound = 1_000_000

-- | Reject zero (which is no jitter, the lockstep this sprint removes) and
-- anything above one whole (which would let a delay go negative).
mkJitterFraction :: Natural -> Either RetryPolicyError JitterFraction
mkJitterFraction partsPerMillion
  | partsPerMillion == 0 = Left RetryPolicyJitterZero
  | partsPerMillion > jitterSampleBound = Left (RetryPolicyJitterTooLarge partsPerMillion)
  | otherwise = Right (JitterFraction partsPerMillion)

-- | 20%. A delay therefore lands in @[0.8 * scheduled, scheduled]@: enough to
-- break lockstep between independent retriers, small enough that the schedule
-- is still recognisably the authored one.
defaultJitterFraction :: JitterFraction
defaultJitterFraction = JitterFraction 200_000

-- | Why a proposed policy is not one.
data RetryPolicyError
  = RetryPolicyAttemptsNotPositive Int
  | RetryPolicyNegativeBaseDelay Int
  | RetryPolicyMultiplierBelowOne Int
  | RetryPolicyMaxDelayBelowBase Int Int
  | RetryPolicyJitterZero
  | RetryPolicyJitterTooLarge Natural
  deriving (Eq, Show)

renderRetryPolicyError :: RetryPolicyError -> String
renderRetryPolicyError = \case
  RetryPolicyAttemptsNotPositive attempts ->
    "retry attempt budget must be at least 1, got " ++ show attempts
  RetryPolicyNegativeBaseDelay delay ->
    "retry base delay must not be negative, got " ++ show delay
  RetryPolicyMultiplierBelowOne multiplier ->
    "retry multiplier must be at least 1, got " ++ show multiplier
  RetryPolicyMaxDelayBelowBase maxDelay baseDelay ->
    "retry maximum delay "
      ++ show maxDelay
      ++ " is below the base delay "
      ++ show baseDelay
  RetryPolicyJitterZero ->
    "retry jitter fraction must be positive; zero is the lockstep schedule"
  RetryPolicyJitterTooLarge partsPerMillion ->
    "retry jitter fraction must be at most 1_000_000 ppm, got "
      ++ show partsPerMillion

-- | An attempt budget and its backoff schedule. The constructor is hidden: a
-- schedule is either one of the named compiled values below or the result of
-- 'mkRetryPolicy'.
data RetryPolicy = RetryPolicy
  { retryPolicyMaxAttempts :: Int
  , retryPolicyBaseDelayMicros :: Int
  , retryPolicyMultiplier :: Int
  , retryPolicyMaxDelayMicros :: Int
  , retryPolicyJitterFraction :: JitterFraction
  }
  deriving (Eq, Show)

-- | Build a policy from data, rejecting every schedule that cannot be honoured.
mkRetryPolicy
  :: Int
  -- ^ Attempt budget; at least one.
  -> Int
  -- ^ Base delay in microseconds; non-negative.
  -> Int
  -- ^ Backoff multiplier; at least one.
  -> Int
  -- ^ Delay ceiling in microseconds; not below the base delay.
  -> JitterFraction
  -> Either RetryPolicyError RetryPolicy
mkRetryPolicy maxAttempts baseDelay multiplier maxDelay jitter
  | maxAttempts < 1 = Left (RetryPolicyAttemptsNotPositive maxAttempts)
  | baseDelay < 0 = Left (RetryPolicyNegativeBaseDelay baseDelay)
  | multiplier < 1 = Left (RetryPolicyMultiplierBelowOne multiplier)
  | maxDelay < baseDelay = Left (RetryPolicyMaxDelayBelowBase maxDelay baseDelay)
  | otherwise =
      Right
        RetryPolicy
          { retryPolicyMaxAttempts = maxAttempts
          , retryPolicyBaseDelayMicros = baseDelay
          , retryPolicyMultiplier = multiplier
          , retryPolicyMaxDelayMicros = maxDelay
          , retryPolicyJitterFraction = jitter
          }

-- | The scheduled (un-jittered) delay for one attempt. Kept as the shared pure
-- backoff calculation; production callers draw through 'drawRetryDelayMicros'
-- so every retrier is jittered, and @prodbox dev check@ enforces that this
-- schedule is not reached from outside this module.
retryDelayMicros :: RetryPolicy -> Int -> Int
retryDelayMicros policy attemptIndex =
  min
    (retryPolicyMaxDelayMicros policy)
    (retryPolicyBaseDelayMicros policy * retryPolicyMultiplier policy ^ max 0 attemptIndex)

-- | Apply a uniform sample in @[0, 'jitterSampleBound')@ to a scheduled delay.
--
-- Jitter subtracts, never adds: the result lands in
-- @[scheduled * (1 - fraction), scheduled]@, so an attempt budget computed
-- against the authored schedule remains an upper bound. Pure, so the property
-- is testable without a clock or an entropy source.
jitteredDelayMicros :: RetryPolicy -> Int -> Natural -> Int
jitteredDelayMicros policy attemptIndex sample =
  scheduled - fromIntegral reduction
 where
  scheduled = retryDelayMicros policy attemptIndex
  boundedSample = min sample (jitterSampleBound - 1)
  fraction = jitterFractionPartsPerMillion (retryPolicyJitterFraction policy)
  reduction :: Natural
  reduction =
    (fromIntegral (max 0 scheduled) * fraction * boundedSample)
      `div` (jitterSampleBound * jitterSampleBound)

-- | Draw one jittered delay. The sample comes from the system CSPRNG, so two
-- retriers that started against the same dependency at the same instant do not
-- share a schedule — which is the whole point, and is not something a clock
-- read can promise.
drawRetryDelayMicros :: RetryPolicy -> Int -> IO Int
drawRetryDelayMicros policy attemptIndex = do
  sample <- drawJitterSample
  pure (jitteredDelayMicros policy attemptIndex sample)

drawJitterSample :: IO Natural
drawJitterSample = do
  bytes <- getRandomBytes 8
  let value = ByteString.foldl' (\acc byte -> (acc `shiftL` 8) .|. fromIntegral byte) (0 :: Natural) bytes
  pure (value `mod` jitterSampleBound)

-- | An operation whose repetition has the same effect as performing it once.
--
-- The constructor is hidden. Wrapping an action is therefore an explicit,
-- greppable claim about that operation, and it is the only way to reach
-- 'Prodbox.Service.retryIdempotentServiceAction' — the one retrier that repeats
-- after an __indeterminate__ outcome, where the effect may already have been
-- applied and only the response lost. Retrying a non-idempotent operation after
-- an indeterminate outcome is therefore not expressible: the plain retrier
-- repeats only outcomes that certainly did not apply, and the one that repeats
-- indeterminate outcomes demands this witness.
newtype IdempotentOperation errorType valueType
  = IdempotentOperation (IO (Either errorType valueType))

-- | Claim that repeating this operation is safe.
idempotentOperation :: IO (Either errorType valueType) -> IdempotentOperation errorType valueType
idempotentOperation = IdempotentOperation

-- | Run the claimed-idempotent operation once.
runIdempotentOperation :: IdempotentOperation errorType valueType -> IO (Either errorType valueType)
runIdempotentOperation (IdempotentOperation action) = action

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
            delay <- drawRetryDelayMicros policy attemptIndex
            threadDelay delay
            go (attemptIndex + 1)
        | otherwise -> pure (Left detail)

-- | Small shared budget for the final component-graph readiness barrier.
-- Install actions may own deeper convergence waits; this absorbs observation
-- jitter without ever treating an unreachable target as ready.
componentReadinessRetryPolicy :: RetryPolicy
componentReadinessRetryPolicy =
  RetryPolicy 3 1_000_000 1 1_000_000 defaultJitterFraction

-- | Helm's transient-failure budget.
helmTransientRetryPolicy :: RetryPolicy
helmTransientRetryPolicy =
  RetryPolicy 3 10_000_000 1 10_000_000 defaultJitterFraction

-- | The custom image-push budget.
customImagePushRetryPolicy :: RetryPolicy
customImagePushRetryPolicy =
  RetryPolicy 3 5_000_000 1 5_000_000 defaultJitterFraction

-- | Backoff for bridging a gateway-daemon restart window on the host side:
-- ~1+2+4+8+8s across five retries — enough to ride out a Deployment rollout
-- (widened by host memory pressure) without hanging forever on a genuinely-down
-- daemon.
daemonRestartBridgeRetryPolicy :: RetryPolicy
daemonRestartBridgeRetryPolicy =
  RetryPolicy 6 1_000_000 2 8_000_000 defaultJitterFraction

-- | Percona PVC-claim convergence.
perconaPatroniClaimRetryPolicy :: RetryPolicy
perconaPatroniClaimRetryPolicy =
  RetryPolicy 60 5_000_000 1 5_000_000 defaultJitterFraction

-- | Patroni cluster-ready convergence.
patroniClusterReadyRetryPolicy :: RetryPolicy
patroniClusterReadyRetryPolicy =
  RetryPolicy 180 10_000_000 1 10_000_000 defaultJitterFraction

-- | The gateway daemon's internal worker-restart budget.
daemonWorkerRetryPolicy :: RetryPolicy
daemonWorkerRetryPolicy =
  RetryPolicy 5 500_000 2 5_000_000 defaultJitterFraction

-- | Every schedule this repository ships. Closed, so a new compiled policy that
-- forgets its jitter fraction is a missing entry rather than a silent lockstep
-- retrier — the negative-space claim the Sprint 1.77 suite asserts over it.
compiledRetryPolicies :: [RetryPolicy]
compiledRetryPolicies =
  [ componentReadinessRetryPolicy
  , helmTransientRetryPolicy
  , customImagePushRetryPolicy
  , daemonRestartBridgeRetryPolicy
  , perconaPatroniClaimRetryPolicy
  , patroniClusterReadyRetryPolicy
  , daemonWorkerRetryPolicy
  ]
