{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The one place a Provider operation's AWS session lifetime is decided.
--
-- The session used to be a literal 900 seconds, chosen to satisfy the STS
-- floor, while the operation it served could run for thirty minutes. A destroy
-- that retried one dependency error past the fifteenth minute then failed on an
-- expired session, and the credential error hid the dependency error that
-- caused it. The lifetime is now derived from the signed intent deadline, kept
-- under the role's declared maximum, and carried as an expiry that every long
-- child is bounded by.
--
-- Times are microseconds of Authority time (UTC); durations are seconds, as
-- STS requires.
module Prodbox.ControlPlane.OperationBudget
  ( SessionWindowRefusal (..)
  , sessionMinimumSeconds
  , sessionGraceSeconds
  , declaredRoleMaximumSeconds
  , planSessionDuration
  , sessionWindowMicros
  , childLimitMicros
  , renderSessionWindowRefusal
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- | The floor STS enforces on @DurationSeconds@.
sessionMinimumSeconds :: Natural
sessionMinimumSeconds = 900

-- | How long past the intent deadline the session must still be valid, for the
-- read-back that follows the last mutation.
sessionGraceSeconds :: Natural
sessionGraceSeconds = 300

-- | The role's @MaxSessionDuration@ as this repository declares it: the AWS
-- default. Until the role is converged to a value prodbox owns, requests are
-- clamped here.
declaredRoleMaximumSeconds :: Natural
declaredRoleMaximumSeconds = 3600

microsPerSecond :: Natural
microsPerSecond = 1000000

-- | The @DurationSeconds@ to request for an operation that must finish by its
-- intent deadline: the time remaining plus the grace, never below the STS floor
-- and never above the role maximum (which must itself be at least the floor).
planSessionDuration
  :: Natural
  -- ^ the role maximum, in seconds
  -> Natural
  -- ^ now, in microseconds
  -> Natural
  -- ^ the intent deadline, in microseconds
  -> Natural
planSessionDuration roleMaximum nowMicros deadlineMicros =
  max sessionMinimumSeconds (min roleMaximum (remainingSeconds + sessionGraceSeconds))
 where
  remainingSeconds =
    (monus deadlineMicros nowMicros + microsPerSecond - 1) `div` microsPerSecond

-- | Why a session cannot start work.
data SessionWindowRefusal
  = -- | The session expires, in microseconds, no later than the read-back grace
    -- after now.
    SessionWindowExceeded !Natural !Natural
  deriving stock (Eq, Show)

-- | The microseconds a session can still be used for, once the read-back grace
-- is reserved. A session with nothing usable left must not start work.
sessionWindowMicros
  :: Natural
  -- ^ the session's expiry, in microseconds
  -> Natural
  -- ^ now, in microseconds
  -> Either SessionWindowRefusal Natural
sessionWindowMicros expiresAtMicros nowMicros
  | expiresAtMicros > nowMicros + graceMicros =
      Right (expiresAtMicros - nowMicros - graceMicros)
  | otherwise = Left (SessionWindowExceeded expiresAtMicros nowMicros)
 where
  graceMicros = sessionGraceSeconds * microsPerSecond

-- | A child's wall-clock bound: the child maximum, or the window left in the
-- session, whichever is smaller. The session can then never expire under a
-- running child.
childLimitMicros :: Natural -> Natural -> Natural
childLimitMicros = min

renderSessionWindowRefusal :: SessionWindowRefusal -> Text
renderSessionWindowRefusal (SessionWindowExceeded expiresAtMicros nowMicros) =
  "SessionWindowExceeded: the AWS session expires at "
    <> Text.pack (show expiresAtMicros)
    <> " microseconds and it is now "
    <> Text.pack (show nowMicros)
    <> ", inside the "
    <> Text.pack (show sessionGraceSeconds)
    <> " seconds reserved for read-back; no capability was started"

monus :: Natural -> Natural -> Natural
monus larger smaller
  | larger > smaller = larger - smaller
  | otherwise = 0
