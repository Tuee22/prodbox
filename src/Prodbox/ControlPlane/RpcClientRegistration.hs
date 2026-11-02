{-# LANGUAGE OverloadedStrings #-}

-- | Server-owned admission projection from retained RPC history. Origin
-- attestation and publication are interpreter responsibilities.
module Prodbox.ControlPlane.RpcClientRegistration
  ( RpcClientRegistrationError (..)
  , rpcClientRegistryIsCompleteSeed
  , projectRpcRegisteredClients
  , validateRpcRegisteredClients
  )
where

import Control.Monad (foldM, unless)
import Data.Bifunctor (first)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyPrincipal
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal
  , allCallerPrincipals
  , callerPrincipalCode
  )
import Prodbox.ControlPlane.RequestAuthentication (signingKeyGenerationValue)
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleOperationSubmit))
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.Lifecycle.Authority.ClientRegistry

data RpcClientRegistrationError
  = RpcClientTableInvalid !RegisteredClientTableError
  | RpcClientPrincipalInvalid !ClientPrincipalError
  | RpcClientGenerationInvalid !RegisteredClientGenerationError
  | RpcClientSlotInvalid !RegisteredClientSlotError
  | RpcClientSpecInvalid !RegisteredClientSpecError
  | RpcClientSlotExhausted
  | RpcClientProjectionMismatch
  deriving (Eq, Show)

rpcClientRegistryIsCompleteSeed :: RpcKeyRegistry -> Bool
rpcClientRegistryIsCompleteSeed registry =
  length bindings == length allCallerPrincipals
    && all ((== RpcKeyActive) . rpcKeyBindingStatus) bindings
 where
  bindings = rpcKeyRegistryBindings registry

-- | Allocate slots only for new origins. Every previous generation, slot,
-- reservation and retirement remains charged to the same fixed capacity.
projectRpcRegisteredClients
  :: Natural
  -> RpcKeyRegistry
  -> RegisteredClientTable
  -> Either RpcClientRegistrationError RegisteredClientTable
projectRpcRegisteredClients maximumReservations registry previous = do
  described <- traverse describe bindings
  slots <- foldM allocate existingSlots (Set.toAscList (Set.fromList (map (fst . fst) described)))
  specs <- traverse (makeSpec slots . fst) described
  let retired = Set.fromList [identity | (identity, RpcKeyRetired) <- described]
  desired <-
    first
      RpcClientTableInvalid
      (mkVersionedRegisteredClientTable (registeredClientTableCapacity previous) specs retired)
  first RpcClientTableInvalid (reconcileRegisteredClientTable desired previous)
 where
  allBindings = sortOn rpcKeyBindingGeneration (rpcKeyRegistryBindings registry)
  bindings = filter ((`elem` trustedCallersForRoute LifecycleOperationSubmit) . principalFor) allBindings
  existingSlots =
    Map.fromList
      [ (registeredClientPrincipal spec, registeredClientSlot spec)
      | spec <- registeredClientTableSpecifications previous
      ]
  homeSlots = Set.fromList (map (fromIntegral . callerPrincipalCode) allCallerPrincipals)
  describe binding = do
    let source = rpcObservedOrigin (rpcKeyBindingObserved binding)
        caller = principalFor binding
        originHistory = filter ((== source) . rpcObservedOrigin . rpcKeyBindingObserved) allBindings
        callerHistory = filter ((== caller) . principalFor) allBindings
    firstOrigin <- case originHistory of
      [] -> Left RpcClientProjectionMismatch
      entry : _ -> Right entry
    firstCaller <- case callerHistory of
      [] -> Left RpcClientProjectionMismatch
      entry : _ -> Right entry
    generation <- clientGeneration binding
    principal <-
      if rpcObservedOrigin (rpcKeyBindingObserved firstCaller) == source
        then Right (clientPrincipalForCaller caller)
        else do
          initial <- clientGeneration firstOrigin
          first RpcClientPrincipalInvalid (clientPrincipalForRpcOrigin caller initial)
    pure ((principal, generation), rpcKeyBindingStatus binding)
  allocate slots principal
    | Just slot <- Map.lookup principal slots = do
        case [caller | caller <- allCallerPrincipals, clientPrincipalForCaller caller == principal] of
          [caller] ->
            unless
              (registeredClientSlotValue slot == fromIntegral (callerPrincipalCode caller))
              (Left RpcClientProjectionMismatch)
          _ ->
            unless
              (registeredClientSlotValue slot `Set.notMember` homeSlots)
              (Left RpcClientProjectionMismatch)
        Right slots
    | otherwise = do
        let occupied = Set.fromList (map registeredClientSlotValue (Map.elems slots))
            free =
              [ value
              | value <- [1 .. registeredClientMaximumSlots]
              , value `Set.notMember` homeSlots
              , value `Set.notMember` occupied
              ]
            legacyCaller = [caller | caller <- allCallerPrincipals, clientPrincipalForCaller caller == principal]
        value <- case legacyCaller of
          [caller] -> Right (fromIntegral (callerPrincipalCode caller))
          _ -> case free of
            [] -> Left RpcClientSlotExhausted
            firstFree : _ -> Right firstFree
        slot <- first RpcClientSlotInvalid (mkRegisteredClientSlot value)
        pure (Map.insert principal slot slots)
  makeSpec slots (principal, generation) = do
    slot <- maybe (Left RpcClientProjectionMismatch) Right (Map.lookup principal slots)
    first RpcClientSpecInvalid (mkRegisteredClientSpec principal slot generation maximumReservations)

validateRpcRegisteredClients
  :: RpcKeyRegistry -> RegisteredClientTable -> Either RpcClientRegistrationError ()
validateRpcRegisteredClients registry table = do
  maximumReservations <- case registeredClientTableSpecifications table of
    [] -> Left RpcClientProjectionMismatch
    spec : _ -> Right (registeredClientMaximumReservations spec)
  expected <- projectRpcRegisteredClients maximumReservations registry table
  unless (registeredClientTableConfigurationMatches expected table) (Left RpcClientProjectionMismatch)

principalFor :: RpcKeyBinding -> CallerPrincipal
principalFor = controlPlaneSigningKeyPrincipal . rpcKeyOriginRef . rpcObservedOrigin . rpcKeyBindingObserved

clientGeneration :: RpcKeyBinding -> Either RpcClientRegistrationError RegisteredClientGeneration
clientGeneration =
  first RpcClientGenerationInvalid
    . mkRegisteredClientGeneration
    . signingKeyGenerationValue
    . rpcKeyBindingGeneration
