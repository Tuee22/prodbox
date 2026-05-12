module Prodbox.Retry
  ( RetryPolicy (..)
  , defaultRetryPolicy
  , retryAppError
  , retryDelayMicros
  )
where

import Control.Concurrent (threadDelay)
import Prodbox.Error
  ( AppError (..)
  , ErrorKind (..)
  )

data RetryPolicy = RetryPolicy
  { retryPolicyMaxAttempts :: Int
  , retryPolicyBaseDelayMicros :: Int
  , retryPolicyMultiplier :: Int
  , retryPolicyMaxDelayMicros :: Int
  }
  deriving (Eq, Show)

defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 5
    , retryPolicyBaseDelayMicros = 500000
    , retryPolicyMultiplier = 2
    , retryPolicyMaxDelayMicros = 30000000
    }

retryDelayMicros :: RetryPolicy -> Int -> Int
retryDelayMicros policy attemptIndex =
  min
    (retryPolicyMaxDelayMicros policy)
    (retryPolicyBaseDelayMicros policy * retryPolicyMultiplier policy ^ max 0 attemptIndex)

retryAppError :: RetryPolicy -> IO (Either AppError a) -> IO (Either AppError a)
retryAppError policy action = go 0
 where
  go attemptIndex = do
    result <- action
    case result of
      Left err
        | errorKind err == Recoverable && attemptIndex + 1 < retryPolicyMaxAttempts policy -> do
            threadDelay (retryDelayMicros policy attemptIndex)
            go (attemptIndex + 1)
      _ -> pure result
