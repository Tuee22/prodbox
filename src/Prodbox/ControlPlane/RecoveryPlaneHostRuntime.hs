-- | Non-authorizing diagnostics for the closed host recovery-plane runtime.
-- The descriptor-bound action, authenticated transport, and phase classifier
-- remain package-private.
module Prodbox.ControlPlane.RecoveryPlaneHostRuntime
  ( RecoveryPlaneHostRuntimeRegression
  , fixedRecoveryPlaneHostRuntimeRegression
  , recoveryPlaneHostRuntimeClosedOperationsExact
  , recoveryPlaneHostRuntimeRemoteAmbiguityUnconfirmed
  , recoveryPlaneHostRuntimeDefiniteRefusalFailed
  , recoveryPlaneHostRuntimeOpacityClosed
  )
where

import Prodbox.ControlPlane.RecoveryPlaneHostRuntime.Internal
