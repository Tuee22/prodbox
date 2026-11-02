-- | Clock observations translate original bounds; they grant no admission.
module Prodbox.ControlPlane.RpcAdmissionBirthClock
  ( RpcBirthHostClockReaders (..)
  , RpcBirthHostClockSample (..)
  , RpcBirthHostClockError (..)
  , observeRpcBirthHostWindow
  , observeRpcBirthHostWindowWith
  , checkRpcBirthHostClockSample
  ) where

import Control.Monad (unless, when)
import Data.Int (Int64)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)

data RpcBirthHostClockReaders = RpcBirthHostClockReaders
  { readRpcBirthHostMonotonic :: IO Word64
  , readRpcBirthHostAuthority :: IO AuthorityTime
  }

data RpcBirthHostClockSample = RpcBirthHostClockSample
  { rpcBirthClockMonotonicBefore :: !Word64
  , rpcBirthClockAuthority :: !AuthorityTime
  , rpcBirthClockMonotonicAfter :: !Word64
  }
  deriving (Eq, Show)

data RpcBirthHostClockError
  = RpcBirthHostClockExpired
  | RpcBirthHostClockOutsideAuthorityBound
  | RpcBirthHostClockSampleInvalid
  | RpcBirthHostClockRemainingOverflow
  deriving (Eq, Show)

observeRpcBirthHostWindow
  :: (Word64, Word64) -> AuthorityTime -> IO (Either RpcBirthHostClockError Word64)
observeRpcBirthHostWindow =
  observeRpcBirthHostWindowWith
    (RpcBirthHostClockReaders getMonotonicTimeNSec rpcBirthSystemTime)

observeRpcBirthHostWindowWith
  :: RpcBirthHostClockReaders
  -> (Word64, Word64)
  -> AuthorityTime
  -> IO (Either RpcBirthHostClockError Word64)
observeRpcBirthHostWindowWith readers window deadline = do
  before <- readRpcBirthHostMonotonic readers
  authority <- readRpcBirthHostAuthority readers
  after <- readRpcBirthHostMonotonic readers
  pure (checkRpcBirthHostClockSample window deadline (RpcBirthHostClockSample before authority after))

checkRpcBirthHostClockSample
  :: (Word64, Word64)
  -> AuthorityTime
  -> RpcBirthHostClockSample
  -> Either RpcBirthHostClockError Word64
checkRpcBirthHostClockSample (workEnd, outerEnd) deadline (RpcBirthHostClockSample before authority after) = do
  unless
    (before <= after && workEnd > 0 && workEnd < outerEnd && outerEnd < maxBound)
    (Left RpcBirthHostClockSampleInvalid)
  when (authority >= deadline || after >= workEnd) (Left RpcBirthHostClockExpired)
  -- Native UTC is floored to microseconds. Use its upper edge and the
  -- monotonic sample from before the read, including read/preemption time.
  let authorityRemaining = (toInteger (authorityTimeMicros deadline) - toInteger (authorityTimeMicros authority) - 1) * 1000
      hostRemaining = toInteger outerEnd - toInteger before
      work = workEnd - after
  unless
    (hostRemaining > 0 && hostRemaining <= authorityRemaining)
    (Left RpcBirthHostClockOutsideAuthorityBound)
  unless (toInteger work <= toInteger (maxBound :: Int64)) (Left RpcBirthHostClockRemainingOverflow)
  pure work
