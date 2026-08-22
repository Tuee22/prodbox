{-# LANGUAGE DataKinds #-}

-- | Public facade for the host-side cascade retained-slot adapter.  The wire
-- constructors and the response mapping stay package-private.
module Prodbox.ControlPlane.CascadeRetainedSlotClient
  ( cascadeRetainedSlotModelBAdapter
  , CascadeRetainedSlotClientRegression
  , fixedCascadeRetainedSlotClientRegression
  , cascadeRetainedSlotClientRefusesForeignNameUnissued
  , cascadeRetainedSlotClientRefusesReplaceUnissued
  , cascadeRetainedSlotClientRefusesGuardedUnissued
  , cascadeRetainedSlotClientAppliedEchoesRequestedValue
  , cascadeRetainedSlotClientLostResponseUnobservable
  , cascadeRetainedSlotClientStatusMismatchUnobservable
  , cascadeRetainedSlotClientObservationRoundTrips
  )
where

import Data.ByteString (ByteString)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.CascadeRetainedSlotClient.Internal
  ( CascadeRetainedSlotClientRegression
  , cascadeRetainedSlotClientAppliedEchoesRequestedValue
  , cascadeRetainedSlotClientLostResponseUnobservable
  , cascadeRetainedSlotClientObservationRoundTrips
  , cascadeRetainedSlotClientRefusesForeignNameUnissued
  , cascadeRetainedSlotClientRefusesGuardedUnissued
  , cascadeRetainedSlotClientRefusesReplaceUnissued
  , cascadeRetainedSlotClientStatusMismatchUnobservable
  , cascadeRetainedSlotModelBAdapterInternal
  , fixedCascadeRetainedSlotClientRegression
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

-- | The host's Model-B adapter over the cascade's closed retained-slot route.
--
-- This is the constructor the two cascade repositories are given in
-- production; every other production Model-B adapter in the repository is
-- in-cluster and therefore out of a cascading host's reach.
cascadeRetainedSlotModelBAdapter
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ModelBCasAdapter 'ClusterRetained IO ByteString
cascadeRetainedSlotModelBAdapter = cascadeRetainedSlotModelBAdapterInternal
