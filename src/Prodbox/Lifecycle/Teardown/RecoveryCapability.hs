-- | Opaque, read-only recovery capability metadata for compiled lifecycle
-- teardown programs.  Catalog/set construction remains package-internal.
module Prodbox.Lifecycle.Teardown.RecoveryCapability
  ( RecoveryCapability
  , RecoveryCapabilitySet
  , RecoveryCapabilityCatalog
  , noAdditionalRecoveryCapabilities
  , resumeOrdinaryCleanupCapabilities
  , mergeRecoveryCapabilitySets
  , recoveryCapabilityName
  , recoveryCapabilitySetCapabilities
  , recoveryCapabilitySetNames
  , recoveryCapabilitySetDigest
  , recoveryCapabilitySetRequiresTargetAgent
  , recoveryCapabilityCatalogEntries
  , recoveryCapabilityCatalogNodes
  , recoveryCapabilityCatalogCapabilitiesForNode
  , recoveryCapabilityCatalogOperationForNode
  , recoveryCapabilityCatalogDigest
  , recoveryCapabilityCatalogVersion
  )
where

import Prodbox.Lifecycle.Teardown.RecoveryCapability.Internal
