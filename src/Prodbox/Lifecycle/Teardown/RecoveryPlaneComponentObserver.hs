-- | Read-only diagnostics for the production recovery-plane component
-- observer.  The in-cluster client, raw Kubernetes/Vault observations,
-- resource table, and the constructor that can satisfy the recovery-plane
-- interpreter remain package-private.
module Prodbox.Lifecycle.Teardown.RecoveryPlaneComponentObserver
  ( RecoveryPlaneComponentObserverError (..)
  , RecoveryPlaneComponentObserverRegression
  , fixedRecoveryPlaneComponentObserverRegression
  , recoveryPlaneComponentObserverClosedInventory
  , recoveryPlaneComponentObserverReadyRowsExact
  , recoveryPlaneComponentObserverMissingRefused
  , recoveryPlaneComponentObserverMalformedRefused
  , recoveryPlaneComponentObserverUnauthorizedRefused
  , recoveryPlaneComponentObserverPartialRolloutRefused
  , recoveryPlaneComponentObserverInvalidUidRefused
  , recoveryPlaneComponentObserverGenerationMismatchRefused
  , recoveryPlaneComponentObserverConditionMismatchRefused
  , recoveryPlaneComponentObserverVaultSealedRefused
  , recoveryPlaneComponentObserverNetworkUnknownRefused
  , recoveryPlaneComponentObserverExternalCallerExact
  , recoveryPlaneComponentObserverOpacityClosed
  )
where

import Prodbox.Lifecycle.Teardown.RecoveryPlaneComponentObserver.Internal
