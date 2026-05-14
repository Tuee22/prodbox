{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Service
  ( AsServiceError (..)
  , HasMinIO (..)
  , HasPg (..)
  , HasRedis (..)
  , MinIOError (..)
  , PgError (..)
  , RedisError (..)
  , ServiceError (..)
  , retryServiceAction
  )
where

import Control.Concurrent (threadDelay)
import Data.Text (Text)
import Prodbox.Retry
  ( RetryPolicy (..)
  , retryDelayMicros
  )

data ServiceError = ServiceError
  { serviceErrorMessage :: Text
  , serviceErrorRetryable :: Bool
  }
  deriving (Eq, Show)

newtype MinIOError = MinIOError {unMinIOError :: ServiceError}
  deriving (Eq, Show)

newtype RedisError = RedisError {unRedisError :: ServiceError}
  deriving (Eq, Show)

newtype PgError = PgError {unPgError :: ServiceError}
  deriving (Eq, Show)

class AsServiceError errorType where
  toServiceError :: errorType -> ServiceError
  fromServiceError :: ServiceError -> errorType

instance AsServiceError MinIOError where
  toServiceError = unMinIOError
  fromServiceError = MinIOError

instance AsServiceError RedisError where
  toServiceError = unRedisError
  fromServiceError = RedisError

instance AsServiceError PgError where
  toServiceError = unPgError
  fromServiceError = PgError

instance AsServiceError ServiceError where
  toServiceError = id
  fromServiceError = id

class (Monad m) => HasMinIO m where
  runMinIO :: String -> m (Either MinIOError String)

class (Monad m) => HasRedis m where
  runRedis :: [String] -> m (Either RedisError String)

class (Monad m) => HasPg m where
  runPg :: [String] -> m (Either PgError String)

retryServiceAction
  :: (AsServiceError errorType)
  => RetryPolicy
  -> IO (Either errorType valueType)
  -> IO (Either errorType valueType)
retryServiceAction policy action = go 0
 where
  go attemptIndex = do
    result <- action
    case result of
      Left err
        | serviceErrorRetryable (toServiceError err)
            && attemptIndex + 1 < retryPolicyMaxAttempts policy -> do
            threadDelay (retryDelayMicros policy attemptIndex)
            go (attemptIndex + 1)
      _ -> pure result
