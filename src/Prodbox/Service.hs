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
import Prodbox.Error (errorMsg)
import Prodbox.Retry
  ( RetryPolicy (..)
  , retryDelayMicros
  )
import Prodbox.Subprocess
  ( ProcessOutput
  , Subprocess (..)
  , capture
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
  runMinIO :: [String] -> m (Either MinIOError ProcessOutput)
  runMinIOWithEnv :: Maybe [(String, String)] -> [String] -> m (Either MinIOError ProcessOutput)
  runMinIOWithEnv _ = runMinIO

class (Monad m) => HasRedis m where
  runRedis :: [String] -> m (Either RedisError ProcessOutput)

class (Monad m) => HasPg m where
  runPg :: [String] -> m (Either PgError ProcessOutput)

instance HasMinIO IO where
  runMinIO = runServiceSubprocess MinIOError "aws"
  runMinIOWithEnv environment = runServiceSubprocessWithEnv MinIOError "aws" environment

instance HasRedis IO where
  runRedis = runServiceSubprocess RedisError "redis-cli"

instance HasPg IO where
  runPg = runServiceSubprocess PgError "kubectl"

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

runServiceSubprocess
  :: (ServiceError -> errorType)
  -> FilePath
  -> [String]
  -> IO (Either errorType ProcessOutput)
runServiceSubprocess wrap commandPath arguments = do
  runServiceSubprocessWithEnv wrap commandPath Nothing arguments

runServiceSubprocessWithEnv
  :: (ServiceError -> errorType)
  -> FilePath
  -> Maybe [(String, String)]
  -> [String]
  -> IO (Either errorType ProcessOutput)
runServiceSubprocessWithEnv wrap commandPath environment arguments = do
  result <-
    capture
      Subprocess
        { subprocessPath = commandPath
        , subprocessArguments = arguments
        , subprocessEnvironment = environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $
    case result of
      Left err ->
        Left
          ( wrap
              ServiceError
                { serviceErrorMessage = errorMsg err
                , serviceErrorRetryable = True
                }
          )
      Right output -> Right output
