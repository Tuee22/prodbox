-- | Opaque Authority client for immutable cleanup-program descriptors.
-- Construction and raw positive read-back remain package-private, so a
-- library caller cannot turn a caller-supplied Model-B adapter into committed
-- lifecycle evidence.
module Prodbox.ControlPlane.CleanupProgramDescriptorRepository
  ( CleanupProgramDescriptorAuthorityClient
  , CleanupProgramDescriptorCommitResult (..)
  , CleanupProgramDescriptorRepositoryError (..)
  , CommittedCleanupProgramDescriptor
  , committedCleanupProgramDescriptorRunId
  , committedCleanupProgramDescriptorSurface
  , committedCleanupProgramDescriptorFoundation
  , committedCleanupProgramDescriptorAwsScope
  , committedCleanupProgramDescriptorAwsDnsZone
  , committedCleanupProgramDescriptorRegistryRevision
  , committedCleanupProgramDescriptorLifecycleOperation
  , committedCleanupProgramDescriptorGraphDigest
  , committedCleanupProgramDescriptorCapabilityCatalogDigest
  , committedCleanupProgramDescriptorDigest
  , commitCleanupProgramDescriptorAttempt
  , independentlyReadBackCommittedCleanupProgramDescriptor
  , CleanupProgramDescriptorRepositoryRegression
  , fixedCleanupProgramDescriptorRepositoryRegression
  , cleanupProgramDescriptorRegressionAllSurfacesCaptured
  , cleanupProgramDescriptorRegressionInitialStateRefused
  , cleanupProgramDescriptorRegressionResponseLossRecovered
  , cleanupProgramDescriptorRegressionExactReplayPreserved
  , cleanupProgramDescriptorRegressionConflictPreserved
  , cleanupProgramDescriptorRegressionTamperingRefused
  , cleanupProgramDescriptorRegressionUnknownStatesRefused
  , cleanupProgramDescriptorRegressionWrongRunRefused
  , cleanupProgramDescriptorRegressionRestartReconstructionValidated
  , cleanupProgramDescriptorRegressionLegacyV1RestartReadable
  )
where

import Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal
