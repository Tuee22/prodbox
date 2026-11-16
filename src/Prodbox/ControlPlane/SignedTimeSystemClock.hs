-- | Linux suspend-aware elapsed samples for signed-time intervals. Reading the
-- clock does not establish its rate, continuity, namespace identity or trust.
module Prodbox.ControlPlane.SignedTimeSystemClock (sampleBoottime) where

import Prodbox.ControlPlane.SignedTimeBounds (ElapsedClockSample, elapsedClockSampleFromMicros)
import System.Clock (Clock (Boottime), TimeSpec (..), getTime)

-- | Read CLOCK_BOOTTIME, rejecting an invalid or negative timespec. This is a
-- separate time domain from process-monotonic request deadlines; callers must
-- establish the clock and time-scale bounds before admitting its readings.
sampleBoottime :: IO ElapsedClockSample
sampleBoottime = do
  TimeSpec seconds nanoseconds <- getTime Boottime
  if seconds < 0 || nanoseconds < 0 || nanoseconds >= 1000000000
    then ioError (userError "invalid CLOCK_BOOTTIME sample")
    else
      pure $
        elapsedClockSampleFromMicros $
          fromInteger (toInteger seconds * 1000000 + toInteger nanoseconds `div` 1000)
