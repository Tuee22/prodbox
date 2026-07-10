{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
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
  , TransientFailureClass (..)
  , classifyServiceError
  , isRetryableTransientFailure
  , serviceErrorMessage
  , serviceErrorRetryable
  , retryServiceAction
  )
where

import Control.Concurrent (threadDelay)
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Error (AppError, errorMsg)
import Prodbox.Retry
  ( RetryPolicy (..)
  , retryDelayMicros
  )
import Prodbox.Subprocess
  ( ProcessOutput
  , Subprocess (..)
  , capture
  )

-- | The unified service-error type, classified by constructor. Each
-- constructor carries the human-readable failure message; the
-- constructor itself — not a hand-set @Bool@ — decides whether the
-- failure is retryable (see 'serviceErrorRetryable'). A 'ServiceError'
-- value is born exactly once, at the subprocess boundary, via
-- 'classifyServiceError'; downstream code reads the classification and
-- never re-decides retryability.
data ServiceError
  = -- | Could not reach the subsystem (process spawn failed, socket
    -- refused, transport dropped). Transient; retry may succeed.
    SEConnectionFailed Text
  | -- | The operation timed out / the resource was temporarily
    -- exhausted. Transient; retry may succeed.
    SETimeout Text
  | -- | A conflicting concurrent change (optimistic-lock / 409-shaped
    -- failure). Transient; retry after backoff may succeed.
    SEConflict Text
  | -- | The named target does not exist (e.g. the vendor CLI binary is
    -- not on @PATH@). Permanent; retrying cannot help.
    SENotFound Text
  | -- | The caller is not authorized. Permanent; retrying cannot help.
    SEPermissionDenied Text
  | -- | An otherwise-unclassified failure. Treated as retryable — the
    -- conservative default that preserves the prior behavior where the
    -- single subprocess wrapper hardcoded @retryable = True@.
    SEInternalError Text
  deriving (Eq, Show)

-- | Shared retry-classification groups for failures observed after a
-- subprocess has started. The constructor, rather than each caller, owns the
-- common fragments for its transient class. Callers may extend the shared
-- base with operation-specific fragments through
-- 'isRetryableTransientFailure'.
data TransientFailureClass
  = TransientNameResolutionFailure
  | TransientConnectionFailure
  | TransientHttpFailure
  | TransientTimeoutFailure
  deriving (Bounded, Enum, Eq, Show)

-- | Classify a rendered tool failure against the shared transient base plus
-- operation-specific fragments. Both the observed detail and extensions are
-- normalized here so callers cannot accidentally make retry behavior depend
-- on output casing.
isRetryableTransientFailure :: [String] -> String -> Bool
isRetryableTransientFailure operationSpecificFragments detail =
  any (`isInfixOf` loweredDetail) normalizedFragments
 where
  loweredDetail = map toLower detail
  normalizedFragments =
    map
      (map toLower)
      ( concatMap transientFailureFragments [minBound .. maxBound]
          ++ operationSpecificFragments
      )

-- | Exhaustive constructor-owned fragment table. The four groups form the
-- common base shared by AWS validation, Helm, registry publication, and EKS
-- image-mirror retry classifiers.
transientFailureFragments :: TransientFailureClass -> [String]
transientFailureFragments = \case
  TransientNameResolutionFailure ->
    [ "no such host"
    , "dial tcp"
    , "lookup"
    , "name resolution"
    ]
  TransientConnectionFailure ->
    [ "connection reset by peer"
    , "connection refused"
    , "unexpected eof"
    , "temporary failure"
    ]
  TransientHttpFailure ->
    [ "502 bad gateway"
    , "503 service unavailable"
    , "504 gateway timeout"
    , "429 too many requests"
    ]
  TransientTimeoutFailure ->
    [ "tls handshake timeout"
    , "i/o timeout"
    , "context deadline exceeded"
    ]

-- | The human-readable message carried by a 'ServiceError', regardless
-- of constructor. Total accessor used by error-rendering call sites.
serviceErrorMessage :: ServiceError -> Text
serviceErrorMessage = \case
  SEConnectionFailed message -> message
  SETimeout message -> message
  SEConflict message -> message
  SENotFound message -> message
  SEPermissionDenied message -> message
  SEInternalError message -> message

-- | Whether a 'ServiceError' is retryable. A total function of the
-- constructor — never a stored field, never asserted by a caller.
serviceErrorRetryable :: ServiceError -> Bool
serviceErrorRetryable = \case
  SEConnectionFailed _ -> True
  SETimeout _ -> True
  SEConflict _ -> True
  SEInternalError _ -> True
  SENotFound _ -> False
  SEPermissionDenied _ -> False

-- | The single classification boundary. Given the spawn-failure
-- 'AppError' observed when 'capture' could not run (or could not finish)
-- the subprocess, decide which 'ServiceError' constructor the failure
-- becomes by inspecting the failure text. This is the only place that
-- decides retryability for a service subprocess failure; everything
-- downstream reads the classification via 'serviceErrorRetryable'.
--
-- @capture@ returns @Right ProcessOutput@ for any process that actually
-- ran (zero or non-zero exit) and @Left AppError@ only when the process
-- could not be spawned or its IO transport failed, so this classifier
-- is keyed on that spawn/transport failure text.
classifyServiceError :: AppError -> ServiceError
classifyServiceError appError =
  let message = errorMsg appError
      lowered = map toLower (Text.unpack message)
      mentions = (`isInfixOf` lowered)
   in if
        | mentions "does not exist"
            || mentions "no such file"
            || mentions "not found"
            || mentions "cannot find" ->
            SENotFound message
        | mentions "permission denied"
            || mentions "not permitted"
            || mentions "access denied" ->
            SEPermissionDenied message
        | mentions "timed out" || mentions "timeout" ->
            SETimeout message
        | mentions "connection refused"
            || mentions "connection reset"
            || mentions "could not connect"
            || mentions "resource exhausted"
            || mentions "resource vanished" ->
            SEConnectionFailed message
        | otherwise -> SEInternalError message

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
      -- The single classification boundary: a spawn/transport failure is
      -- turned into a classified ServiceError here, never with a literal
      -- retryable Bool at a call site.
      Left err -> Left (wrap (classifyServiceError err))
      Right output -> Right output
