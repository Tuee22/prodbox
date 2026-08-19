-- | Non-authorizing diagnostics for the closed cascade host runtime.  The
-- descriptor-bound action, the durable host-cleanup store, the production
-- effects record, and the phase classifier remain package-private, so holding
-- one of these booleans authorizes nothing.
module Prodbox.ControlPlane.CascadeHostRuntime
  ( CascadeHostRuntimeRegression
  , fixedCascadeHostRuntimeRegression
  , cascadeHostRuntimeClosedOperationsExact
  , cascadeHostRuntimePhasesDistinct
  , cascadeHostRuntimeObservationUnconfirmed
  , cascadeHostRuntimeDefiniteRefusalFailed
  , cascadeHostRuntimeOpacityClosed
  )
where

import Prodbox.ControlPlane.CascadeHostRuntime.Internal
