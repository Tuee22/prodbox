{-# LANGUAGE DerivingStrategies #-}

-- | Exception-safe terminal protocol for an ephemeral capability session.
-- The user action is interruptible; synchronous failures and cancellation are
-- converted to a closed error only after both cleanup effects have run.  A
-- cleanup observation always dominates an action result, including success.
module Prodbox.ControlPlane.ClosedSession
  ( finishClosedSession
  )
where

import Control.Exception
  ( AsyncException
  , SomeException
  , fromException
  , mask
  , throwIO
  , try
  )
import Data.Maybe (isJust)

finishClosedSession
  :: errorValue
  -> errorValue
  -> IO (Either errorValue value)
  -> IO (Either errorValue ())
  -> IO (Either errorValue Bool)
  -> IO (Either errorValue value)
finishClosedSession actionExceptionError cleanupError action revoke observeAbsent =
  mask $ \restore -> do
    attempted <- tryAny (restore action)
    -- Direct revoke status is deliberately provisional: a transport/status
    -- error can be a lost successful response. Only the independent exact
    -- accessor-absence observation decides terminal cleanup.
    _revoked <- tryAny revoke
    absent <- tryAny observeAbsent
    case attempted of
      -- Cancellation is delayed only long enough to run both terminal cleanup
      -- observations.  Re-throw the original asynchronous exception even when
      -- cleanup itself refused, so this helper never turns cancellation into a
      -- successful or ordinary application-level result.
      Left exception
        | isAsyncException exception -> throwIO exception
      _ -> pure $ case absent of
        Right (Right True) -> case attempted of
          Left _ -> Left actionExceptionError
          Right outcome -> outcome
        Left _ -> Left cleanupError
        Right (Left _) -> Left cleanupError
        Right (Right False) -> Left cleanupError

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  isJust (fromException exception :: Maybe AsyncException)
