{-# LANGUAGE DerivingStrategies #-}

-- | A single fresh RFC 10049 exchange. A verified signed interval is not a
-- trusted clock observation: callers must independently establish server
-- accuracy, elapsed-clock and time-scale bounds, retained history, and aging.
-- The exchange callback must be interruptible for the local timeout to bound it.
module Prodbox.ControlPlane.Roughtime
  ( RoughtimeError (..)
  , RoughtimeReading
  , queryRoughtimeOnce
  , readRoughtimeReading
  )
where

import Control.Exception (IOException, evaluate, try)
import Data.ByteString (ByteString)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline (Deadline, deadlineExpired)
import Prodbox.ControlPlane.Interpreter
  ( DeadlineEffectResult (..)
  , observeDeadlineEffectWithin
  , realMonotonicNow
  )
import Prodbox.ControlPlane.Roughtime.Protocol
import Prodbox.ControlPlane.SignedTimeBounds
  ( ElapsedClockSample
  , SignedTimeInterval
  , TimeScaleMovementBound
  , ageSignedTimeInterval
  , boundSignedTimeClaim
  )

data RoughtimeError
  = RoughtimeExpired
  | RoughtimeUnavailable
  | RoughtimeInvalidRoot
  | RoughtimeInvalidResponse
  | RoughtimeInvalidInterval
  deriving stock (Eq, Show)

-- | A process-local, untrusted signed interval with its original elapsed
-- sample and deadline. It must be re-sampled before each use. Server accuracy,
-- clock continuity, time-scale bounds and retained admission remain external
-- obligations; the constructor is deliberately private.
data RoughtimeReading
  = RoughtimeReading
      !Deadline
      !Natural
      !TimeScaleMovementBound
      !(IO ElapsedClockSample)
      !ElapsedClockSample
      !SignedTimeInterval

instance Show RoughtimeReading where
  show _ = "RoughtimeReading"

queryRoughtimeOnce
  :: IO ElapsedClockSample
  -> Deadline
  -> ByteString
  -> Natural
  -> TimeScaleMovementBound
  -> (ByteString -> IO ByteString)
  -> IO (Either RoughtimeError RoughtimeReading)
queryRoughtimeOnce elapsedNow deadline root slowdown movement exchange = do
  outcome <-
    observeDeadlineEffectWithin
      deadline
      (try transaction :: IO (Either IOException (Either RoughtimeError RoughtimeReading)))
  pure $ case outcome of
    Nothing -> Left RoughtimeExpired
    Just DeadlineEffectNotStarted -> Left RoughtimeExpired
    Just (DeadlineEffectCompletedLate _) -> Left RoughtimeExpired
    Just (DeadlineEffectCompleted _ (Left _)) -> Left RoughtimeUnavailable
    Just (DeadlineEffectCompleted _ (Right result)) -> result
 where
  transaction = do
    before <- elapsedNow
    generated <- newRequest root
    case generated of
      Left _ -> pure (Left RoughtimeInvalidRoot)
      Right request -> do
        beforeDispatch <- realMonotonicNow
        if deadlineExpired beforeDispatch deadline
          then pure (Left RoughtimeExpired)
          else do
            reply <- exchange (requestBytes request)
            claim <- evaluate (verifyResponse request reply)
            after <- elapsedNow
            finished <- realMonotonicNow
            if deadlineExpired finished deadline
              then pure (Left RoughtimeExpired)
              else pure $ case claim of
                Left _ -> Left RoughtimeInvalidResponse
                Right signed -> case boundSignedTimeClaim
                  (fromIntegral (midpointSeconds signed))
                  (fromIntegral (radiusSeconds signed))
                  slowdown
                  movement
                  before
                  after of
                  Left _ -> Left RoughtimeInvalidInterval
                  Right interval -> Right (RoughtimeReading deadline slowdown movement elapsedNow after interval)

-- | Re-sample and age the interval within the original query deadline. The
-- original sample action is retained for each use; it must continue to read
-- the same continuous clock domain. The returned interval is still untrusted
-- and refers to this new sample, so a later consumer must sample again.
readRoughtimeReading
  :: RoughtimeReading -> IO (Either RoughtimeError SignedTimeInterval)
readRoughtimeReading (RoughtimeReading deadline slowdown movement elapsedNow anchor interval) = do
  outcome <-
    observeDeadlineEffectWithin
      deadline
      (try transaction :: IO (Either IOException (Either RoughtimeError SignedTimeInterval)))
  pure $ case outcome of
    Nothing -> Left RoughtimeExpired
    Just DeadlineEffectNotStarted -> Left RoughtimeExpired
    Just (DeadlineEffectCompletedLate _) -> Left RoughtimeExpired
    Just (DeadlineEffectCompleted _ (Left _)) -> Left RoughtimeUnavailable
    Just (DeadlineEffectCompleted _ (Right result)) -> result
 where
  transaction = do
    now <- elapsedNow
    pure $ case ageSignedTimeInterval slowdown movement anchor now interval of
      Left _ -> Left RoughtimeInvalidInterval
      Right aged -> Right aged
