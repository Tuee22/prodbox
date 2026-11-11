-- | A strict atomic one-shot claim. It retains no blocking waiter queue.
-- The Bool is installed directly; cancellation cannot retain an update selector.
-- Executing claims and caller threads remain separate costs.
module Prodbox.Subprocess.OneShotAttempt
  ( OneShotAttempt
  , newOneShotAttempt
  , claimOneShotAttempt
  , oneShotAttemptNormalFormBytes
  ) where

import Data.IORef (IORef, newIORef)
import GHC.IORef (atomicSwapIORef)
import Numeric.Natural (Natural)

newtype OneShotAttempt = OneShotAttempt (IORef Bool)

newOneShotAttempt :: IO OneShotAttempt
newOneShotAttempt = OneShotAttempt <$> newIORef False

claimOneShotAttempt :: OneShotAttempt -> IO Bool
claimOneShotAttempt (OneShotAttempt attempted) =
  not <$> atomicSwapIORef attempted True

-- The pinned unprofiled 64-bit ABI has an erased IORef newtype, a two-word
-- STRef constructor, a two-word StgMutVar and a two-word Bool. This is the
-- quiescent field term before or after completed claims, not an update peak.
oneShotAttemptNormalFormBytes :: OneShotAttempt -> Natural
oneShotAttemptNormalFormBytes (OneShotAttempt attempted) = attempted `seq` 48
