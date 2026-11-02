-- | Shared nonrefundable counters for the closed ordinary caller. These are
-- planning/enforcement values, not physical or Authority admission grants.
module Prodbox.ControlPlane.RegisteredCallerBudget
  ( CallerBudget
  , CallerBudgetKind (..)
  , CallerBudgetError (..)
  , newCallerBudget
  , consumeCallerBudget
  , nextCallerBudgetedNonce
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.Capacity.RegisteredCallerTraffic

-- Every counter is debited before its effect. Copies share one atomic owner.
data CallerBudgetKind
  = CallerOrdinaryFrame
  | CallerRegistryObservation
  | CallerSignedNonce
  | CallerHomeScope
  | CallerForward
  | CallerProtocolHttp
  | CallerStartupProbe
  | CallerTokenLogin
  deriving (Eq, Show, Enum, Bounded)

data CallerBudgetError
  = CallerBudgetInvalid
  | CallerBudgetExhausted !CallerBudgetKind
  deriving (Eq, Show)

data Remaining = Remaining !Natural !Natural !Natural !Natural !Natural !Natural !Natural !Natural

newtype CallerBudget = CallerBudget (IORef Remaining)

newCallerBudget
  :: RegisteredCallerTraffic
  -> Natural
  -> Word64
  -> IO (Either CallerBudgetError CallerBudget)
newCallerBudget traffic loginMaximum originalRemainingNs
  | homeScopeEntries traffic == 0
      || traffic /= registeredCallerTraffic (ordinaryFrames traffic) (homeScopeEntries traffic - 1) =
      pure (Left CallerBudgetInvalid)
  | otherwise = case registeredCallerCost
      (ordinaryFrames traffic)
      (homeScopeEntries traffic - 1)
      loginMaximum
      originalRemainingNs of
      Left _ -> pure (Left CallerBudgetInvalid)
      Right cost -> do
        let initial =
              Remaining
                (ordinaryFrames traffic)
                (registryObservations traffic)
                (totalSignedFrames traffic)
                (homeScopeEntries traffic)
                (perExchangeForwards traffic)
                (protocolHttpRequests traffic)
                (callerCostStartupProbes cost)
                (callerCostTokenLogins cost)
        remaining <- newIORef initial
        pure (Right (CallerBudget remaining))

consumeCallerBudget :: CallerBudget -> CallerBudgetKind -> IO (Either CallerBudgetError ())
consumeCallerBudget (CallerBudget state) kind = atomicModifyIORef' state transition
 where
  transition remaining = case consume kind remaining of
    Left cause -> (remaining, Left cause)
    Right next -> (next, Right ())

nextCallerBudgetedNonce :: CallerBudget -> IO nonce -> IO (Either CallerBudgetError nonce)
nextCallerBudgetedNonce budget generate = do
  consumed <- consumeCallerBudget budget CallerSignedNonce
  case consumed of
    Left cause -> pure (Left cause)
    Right () -> Right <$> generate

consume :: CallerBudgetKind -> Remaining -> Either CallerBudgetError Remaining
consume kind (Remaining ordinary registry nonce scopes forwards http probes logins) = case kind of
  CallerOrdinaryFrame -> (\next -> Remaining next registry nonce scopes forwards http probes logins) <$> debit ordinary
  CallerRegistryObservation -> (\next -> Remaining ordinary next nonce scopes forwards http probes logins) <$> debit registry
  CallerSignedNonce -> (\next -> Remaining ordinary registry next scopes forwards http probes logins) <$> debit nonce
  CallerHomeScope -> (\next -> Remaining ordinary registry nonce next forwards http probes logins) <$> debit scopes
  CallerForward -> (\next -> Remaining ordinary registry nonce scopes next http probes logins) <$> debit forwards
  CallerProtocolHttp -> (\next -> Remaining ordinary registry nonce scopes forwards next probes logins) <$> debit http
  CallerStartupProbe -> (\next -> Remaining ordinary registry nonce scopes forwards http next logins) <$> debit probes
  CallerTokenLogin -> (Remaining ordinary registry nonce scopes forwards http probes) <$> debit logins
 where
  debit value = if value == 0 then Left (CallerBudgetExhausted kind) else Right (value - 1)
