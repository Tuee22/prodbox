{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.109: a wait is a loop of short polls, not one long child.
--
-- Every @aws@ child the Provider starts is killed at thirty seconds, so
-- @aws eks wait cluster-deleted@, which polls for minutes, could never finish,
-- and the security-group delete's ten one-second retries covered ten seconds of
-- a release the load balancer reports over minutes. 'awaitFact' is the
-- replacement: it runs a poll the caller supplies, pauses between polls, and
-- gives up at the budget 'Prodbox.ControlPlane.OperationBudget' names for the
-- fact -- the nearer of the wait's ceiling and the session window -- with a
-- failure that names the fact rather than a killed child.
--
-- The clock and the pause are arguments, as the native-family runner's command
-- already is, so a scripted world with a virtual clock drives a poll to its
-- answer or to its timeout in no real time.
module Prodbox.Lifecycle.AwsWait
  ( AwsWaitEnvironment (..)
  , WaitStep (..)
  , WaitFailure (..)
  , awaitFact
  , awaitFactFrom
  , renderWaitFailure
  , transientPollFailure
  , wallClockWaitEnvironment
  , reserveWaitWindow
  )
where

import Control.Concurrent (threadDelay)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.OperationBudget
  ( WaitFact
  , renderSessionWindowRefusal
  , renderWaitFact
  , sessionWindowMicros
  , waitBudgetFor
  , waitBudgetPollIntervalMicros
  , waitDeadlineMicros
  )
import Prodbox.Subprocess (ProcessOutput (..), boundedSubprocessTimeoutDetail)

-- | What a wait needs from its world: a clock, a pause, the session it must not
-- outlive, and the lifetime its budget's share is a share of.
data AwsWaitEnvironment m = AwsWaitEnvironment
  { awsWaitNowMicros :: m (Either Text Natural)
  -- ^ The operation's clock, in microseconds. A clock that cannot be read is a
  -- refusal to poll, never a poll with no deadline.
  , awsWaitPauseMicros :: Natural -> m ()
  -- ^ Pause for this many microseconds.
  , awsWaitSessionExpiresAtMicros :: Natural
  -- ^ When the session the polls run under stops being honoured, on the same
  -- clock.
  , awsWaitIntentLifetimeMicros :: Natural
  -- ^ The intent's lifetime, which a budget's share is a share of.
  }

-- | What one poll found. The state is threaded through the polls, so a wait on
-- several members (the security groups a load balancer held) polls only those
-- still outstanding.
data WaitStep state
  = -- | The awaited fact holds.
    WaitDone
  | -- | Not yet: the state to poll next and what the poll observed, which a
    -- timeout reports.
    WaitMore !state !Text
  | -- | The poll cannot become true by waiting (a refused call, a terminal
    -- status): stop and say why.
    WaitAbort !Text

-- | Why a wait ended without the fact holding.
data WaitFailure
  = -- | The budget ran out with the fact still false.
    WaitTimedOut
      !WaitFact
      !Natural
      -- ^ polls made
      !Natural
      -- ^ microseconds elapsed
      !Natural
      -- ^ microseconds of budget
      !Text
      -- ^ what the last poll observed
  | -- | A poll reported that waiting cannot help.
    WaitAborted !WaitFact !Text
  | -- | The wait could not start or continue: the clock was unreadable or the
    -- session had no usable window left.
    WaitUnavailable !WaitFact !Text
  deriving stock (Eq, Show)

-- | Poll until the fact holds or its budget is spent.
awaitFact
  :: (Monad m)
  => AwsWaitEnvironment m
  -> WaitFact
  -> m (WaitStep ())
  -> m (Either WaitFailure ())
awaitFact environment fact poll =
  awaitFactFrom environment fact () (const poll)

-- | 'awaitFact' with state threaded through the polls.
--
-- The first poll runs at once. After a poll that is not yet true the loop
-- pauses for the budget's interval, or for what remains of it, and polls again;
-- the last poll therefore happens at the deadline, so a timeout means the fact
-- was still false then. A poll started before the deadline can overrun it by the
-- children it issues, one child bound for each, which the session window's
-- read-back grace absorbs only when the wait ends at the session's own end.
awaitFactFrom
  :: (Monad m)
  => AwsWaitEnvironment m
  -> WaitFact
  -> state
  -> (state -> m (WaitStep state))
  -> m (Either WaitFailure ())
awaitFactFrom environment fact initial poll = do
  started <- awsWaitNowMicros environment
  case started of
    Left detail -> pure (Left (WaitUnavailable fact detail))
    Right start ->
      case sessionWindowMicros (awsWaitSessionExpiresAtMicros environment) start of
        Left refusal ->
          pure (Left (WaitUnavailable fact (renderSessionWindowRefusal refusal)))
        Right window -> do
          let deadline =
                waitDeadlineMicros (awsWaitIntentLifetimeMicros environment) budget start window
          loop start deadline 1 initial
 where
  budget = waitBudgetFor fact
  loop start deadline polls state = do
    step <- poll state
    case step of
      WaitDone -> pure (Right ())
      WaitAbort detail -> pure (Left (WaitAborted fact detail))
      WaitMore next observation -> do
        clock <- awsWaitNowMicros environment
        case clock of
          Left detail -> pure (Left (WaitUnavailable fact detail))
          Right now
            | now >= deadline ->
                pure
                  ( Left
                      ( WaitTimedOut
                          fact
                          polls
                          (now - start)
                          (deadline - start)
                          observation
                      )
                  )
            | otherwise -> do
                awsWaitPauseMicros
                  environment
                  (min (waitBudgetPollIntervalMicros budget) (deadline - now))
                loop start deadline (polls + 1) next

-- | The failure as an operator reads it; the fact is always named.
renderWaitFailure :: WaitFailure -> Text
renderWaitFailure failure = case failure of
  WaitTimedOut fact polls elapsed budget observation ->
    "WaitTimedOut: gave up waiting for "
      <> renderWaitFact fact
      <> " after "
      <> number polls
      <> " polls over "
      <> seconds elapsed
      <> " seconds (budget "
      <> seconds budget
      <> " seconds); the last poll observed: "
      <> bounded observation
  WaitAborted fact detail ->
    "WaitAborted: waiting for " <> renderWaitFact fact <> " cannot succeed: " <> bounded detail
  WaitUnavailable fact detail ->
    "WaitUnavailable: did not poll for " <> renderWaitFact fact <> ": " <> bounded detail
 where
  number = Text.pack . show
  seconds micros = number (micros `div` 1000000)
  -- A poll's own words, kept within the room a failure detail has downstream.
  bounded = Text.take 1024

-- | Whether a failed poll says only that no answer is available yet: the call
-- was throttled, the service was unavailable, or the child was stopped at its
-- bound. Such a poll is repeated inside the budget; any other failure ends the
-- wait, because waiting cannot change it.
transientPollFailure :: ProcessOutput -> Bool
transientPollFailure output = any (`Text.isInfixOf` transcript) markers
 where
  transcript =
    Text.toLower (Text.pack (processStderr output <> " " <> processStdout output))
  markers =
    [ "throttl"
    , "requestlimitexceeded"
    , "rate exceeded"
    , "serviceunavailable"
    , -- EC2 spells its own as @Unavailable@ and the CLI reports a connection it
      -- could not make or finish in words of its own.
      "unavailable"
    , "could not connect to the endpoint"
    , "timeout on endpoint"
    , "connection was closed before"
    , "internalerror"
    , "internalfailure"
    , "requesttimeout"
    , Text.toLower (Text.pack boundedSubprocessTimeoutDetail)
    ]

-- | The wall clock and a real pause, for a caller that holds no session (a
-- host-direct invocation). With no session there is no window to stop at, so
-- only the budget's ceiling bounds the wait.
wallClockWaitEnvironment :: Natural -> AwsWaitEnvironment IO
wallClockWaitEnvironment lifetimeMicros =
  AwsWaitEnvironment
    { awsWaitNowMicros = Right . floor . (* 1000000) <$> getPOSIXTime
    , awsWaitPauseMicros = threadDelay . fromIntegral
    , awsWaitSessionExpiresAtMicros = 10 ^ (18 :: Int)
    , awsWaitIntentLifetimeMicros = lifetimeMicros
    }

-- | The same environment, ending earlier: a wait that must leave the last
-- stretch of the session to the work after it. A wait's deadline is the nearer of
-- its ceiling and the window the session has left, so moving the session's end
-- back by the reserve is all it takes to keep the reserve whole.
reserveWaitWindow :: Natural -> AwsWaitEnvironment m -> AwsWaitEnvironment m
reserveWaitWindow reserveMicros environment =
  environment
    { awsWaitSessionExpiresAtMicros =
        if awsWaitSessionExpiresAtMicros environment > reserveMicros
          then awsWaitSessionExpiresAtMicros environment - reserveMicros
          else 0
    }
