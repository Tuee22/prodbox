-- | One shared nonce-generation allowance for the closed caller. This owns no
-- transport, lifetime or Authority permit; the operation owner supplies those.
module Prodbox.ControlPlane.RpcBirthSigningBudget
  ( RpcBirthNonceBudget
  , newRpcBirthNonceBudget
  , nextRpcBirthBudgetedNonce
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Prodbox.Capacity.RpcBirthTraffic

data RpcBirthNonceBudget nonce
  = RpcBirthNonceBudget !(IORef RpcBirthSigningAllowance) !(IO nonce)

newRpcBirthNonceBudget :: RpcBirthTrafficMode -> IO nonce -> IO (RpcBirthNonceBudget nonce)
newRpcBirthNonceBudget mode generate = do
  remaining <- newIORef (rpcBirthSigningAllowance mode)
  pure (RpcBirthNonceBudget remaining generate)

-- Debit before generation, so cancellation or a failed nonce source never
-- refunds an uncertain attempt. Copies of the opaque owner share that debit.
nextRpcBirthBudgetedNonce :: RpcBirthNonceBudget nonce -> IO (Either RpcBirthTrafficError nonce)
nextRpcBirthBudgetedNonce (RpcBirthNonceBudget remaining generate) = do
  admitted <- atomicModifyIORef' remaining consume
  case admitted of
    Left cause -> pure (Left cause)
    Right () -> Right <$> generate
 where
  consume allowance = case consumeRpcBirthSigningAllowance allowance of
    Left cause -> (allowance, Left cause)
    Right next -> (next, Right ())
