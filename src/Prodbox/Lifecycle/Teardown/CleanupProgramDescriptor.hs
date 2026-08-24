-- | Read-only facade for the canonical desired-absence program descriptor.
-- Candidates can only be captured from a compiled program and its exact
-- initial durable run.  Decoding and committed-evidence construction remain
-- package-internal to the Lifecycle Authority repository.
module Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( CleanupProgramDescriptor
  , CleanupProgramDescriptorError (..)
  , captureCleanupProgramDescriptor
  , cleanupProgramDescriptorRunId
  , cleanupProgramDescriptorSurface
  , cleanupProgramDescriptorFoundation
  , cleanupProgramDescriptorAwsScope
  , cleanupProgramDescriptorAwsDnsZone
  , cleanupProgramDescriptorRegistryRevision
  , cleanupProgramDescriptorLifecycleOperation
  , cleanupProgramDescriptorGraphDigest
  , cleanupProgramDescriptorCapabilityCatalogDigest
  , cleanupProgramDescriptorDigest
  , cleanupProgramDescriptorBytes
  , cleanupProgramDescriptorFormatVersion
  , cleanupProgramDescriptorCompilerVersion
  , cleanupProgramDescriptorOperationIdentityVersion
  , cleanupProgramDescriptorCapabilityCatalogVersion
  , cleanupProgramDescriptorCapabilitySetVersion
  , maximumCleanupProgramDescriptorBytes
  )
where

import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor.Internal
