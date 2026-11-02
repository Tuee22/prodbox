-- | Joined, original-bound use of an observed operation parent or transport.
-- The owner closes admission before joining uses. Nested uses hold no mutex
-- across effects; an escaped owner cannot admit work after its scope closes.
module Prodbox.ControlPlane.OperationUse
  ( OperationUses
  , OperationUseError (..)
  , withOperationParentUses
  , withOperationTransportUses
  , withOperationUse
  ) where

import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception (evaluate, finally, mask, uninterruptibleMask_)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Numeric.Natural (Natural)
import Prodbox.Subprocess
  ( OperationSubprocessError
  , OperationSubprocesses
  , OperationTransport
  , operationSubprocessWindow
  , operationTransportWorkEnd
  , verifyOperationSubprocessesBeforeEffect
  , verifyOperationTransportBeforeEffect
  )
import Prodbox.Subprocess.SystemdIdentity (hostExecutionWorkEnd)
import System.Timeout (timeout)

data OperationUseSource
  = ParentUses !OperationSubprocesses
  | TransportUses !OperationTransport

data OperationUseState = UsesOpen !Natural | UsesClosing !Natural

data OperationUses = OperationUses !OperationUseSource !(TVar OperationUseState)

data OperationUseError
  = OperationUseClosed
  | OperationUseDeadlineReached
  | OperationUseProcessRefused !OperationSubprocessError
  deriving (Eq, Show)

withOperationParentUses :: OperationSubprocesses -> (OperationUses -> IO value) -> IO value
withOperationParentUses processes = withUses (ParentUses processes)

withOperationTransportUses :: OperationTransport -> (OperationUses -> IO value) -> IO value
withOperationTransportUses lease = withUses (TransportUses lease)

withUses :: OperationUseSource -> (OperationUses -> IO value) -> IO value
withUses source action = do
  uses <- OperationUses source <$> newTVarIO (UsesOpen 0)
  action uses `finally` closeUses uses

withOperationUse :: OperationUses -> IO value -> IO (Either OperationUseError value)
withOperationUse (OperationUses source uses) action = mask $ \restore -> do
  admitted <- atomically $ do
    state <- readTVar uses
    case state of
      UsesOpen count -> writeTVar uses (UsesOpen (count + 1)) >> pure True
      UsesClosing _ -> pure False
  if admitted
    then restore run `finally` atomically (modifyTVar' uses release)
    else pure (Left OperationUseClosed)
 where
  ending = workEnd source
  run = do
    now <- getMonotonicTimeNSec
    if now >= ending || ending - now < 1000
      then pure (Left OperationUseDeadlineReached)
      else do
        let micros = fromInteger (min (toInteger (maxBound :: Int)) (toInteger ((ending - now) `div` 1000)))
        attempted <- timeout micros $ do
          before <- verifySource source
          case before of
            Left cause -> pure (Left (OperationUseProcessRefused cause))
            Right () -> do
              value <- action >>= evaluate
              closing <- verifySource source
              pure (value <$ either (Left . OperationUseProcessRefused) Right closing)
        after <- getMonotonicTimeNSec
        pure $
          if after >= ending
            then Left OperationUseDeadlineReached
            else maybe (Left OperationUseDeadlineReached) id attempted
  release state = case state of
    UsesOpen count -> UsesOpen (count - 1)
    UsesClosing count -> UsesClosing (count - 1)

closeUses :: OperationUses -> IO ()
closeUses (OperationUses _ uses) = uninterruptibleMask_ $ do
  atomically (modifyTVar' uses beginClosing)
  atomically $ do
    state <- readTVar uses
    check $ case state of
      UsesOpen _ -> False
      UsesClosing count -> count == 0
 where
  beginClosing state = case state of
    UsesOpen count -> UsesClosing count
    UsesClosing count -> UsesClosing count

workEnd :: OperationUseSource -> Word64
workEnd source = case source of
  ParentUses processes -> hostExecutionWorkEnd (operationSubprocessWindow processes)
  TransportUses lease -> operationTransportWorkEnd lease

verifySource :: OperationUseSource -> IO (Either OperationSubprocessError ())
verifySource source = case source of
  ParentUses processes -> verifyOperationSubprocessesBeforeEffect processes
  TransportUses lease -> verifyOperationTransportBeforeEffect lease
