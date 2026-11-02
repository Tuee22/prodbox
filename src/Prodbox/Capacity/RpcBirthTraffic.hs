-- | Arithmetic for the closed caller. This value grants no Authority or
-- physical admission; its owning interpreter must enforce each consumption.
module Prodbox.Capacity.RpcBirthTraffic
  ( RpcBirthTrafficMode (..)
  , RpcBirthSigningAllowance
  , RpcBirthTrafficError (..)
  , rpcBirthSignedRequestMaximum
  , rpcBirthRegistryReadMaximum
  , rpcBirthMutationMaximum
  , rpcBirthSigningAllowance
  , rpcBirthSigningRemaining
  , consumeRpcBirthSigningAllowance
  ) where

import Numeric.Natural (Natural)

data RpcBirthTrafficMode = RpcBirthInitialTraffic | RpcBirthRegisteredTraffic
  deriving (Eq, Show, Enum, Bounded)

data RpcBirthSigningAllowance = RpcBirthSigningAllowance !RpcBirthTrafficMode !Natural
  deriving (Eq, Show)

data RpcBirthTrafficError = RpcBirthSigningAllowanceExhausted !RpcBirthTrafficMode
  deriving (Eq, Show)

rpcBirthSignedRequestMaximum :: RpcBirthTrafficMode -> Natural
rpcBirthSignedRequestMaximum mode = ordinarySignatures mode + 2 * rpcBirthRegistryReadMaximum mode

rpcBirthRegistryReadMaximum :: RpcBirthTrafficMode -> Natural
rpcBirthRegistryReadMaximum mode = case mode of
  RpcBirthInitialTraffic -> 0
  -- Discovery and checked-signer construction read once each; every ordinary
  -- signature validates its binding before and after signing. Each private
  -- read itself signs the fixed peer refresh and registry observation.
  RpcBirthRegisteredTraffic -> 2 + 2 * ordinarySignatures mode

ordinarySignatures :: RpcBirthTrafficMode -> Natural
ordinarySignatures mode = 2 * domainRequests
 where
  -- Each domain request refreshes its peer epoch. The longest fresh branch
  -- prepares and reads back; the registered prepared/armed branch skips it.
  domainRequests = case mode of
    RpcBirthInitialTraffic -> 6
    RpcBirthRegisteredTraffic -> 4

rpcBirthMutationMaximum :: RpcBirthTrafficMode -> Natural
rpcBirthMutationMaximum mode = case mode of
  RpcBirthInitialTraffic -> 2
  RpcBirthRegisteredTraffic -> 1

rpcBirthSigningAllowance :: RpcBirthTrafficMode -> RpcBirthSigningAllowance
rpcBirthSigningAllowance mode = RpcBirthSigningAllowance mode (rpcBirthSignedRequestMaximum mode)

rpcBirthSigningRemaining :: RpcBirthSigningAllowance -> Natural
rpcBirthSigningRemaining (RpcBirthSigningAllowance _ remaining) = remaining

consumeRpcBirthSigningAllowance
  :: RpcBirthSigningAllowance -> Either RpcBirthTrafficError RpcBirthSigningAllowance
consumeRpcBirthSigningAllowance (RpcBirthSigningAllowance mode remaining) = case remaining of
  0 -> Left (RpcBirthSigningAllowanceExhausted mode)
  _ -> Right (RpcBirthSigningAllowance mode (remaining - 1))
