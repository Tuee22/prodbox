-- | Read-only facade for descriptor-bound cascade completion.
--
-- Repository construction, Model-B writes, canonical bytes, descriptor and
-- attempt binders, and every proof constructor remain package-private.  The
-- evidence here is intentionally distinct from the legacy
-- @CascadeCompleteEvidence@ consumed by the pre-cutover host runner.
module Prodbox.ControlPlane.CascadeCompletionRepository
  ( DescriptorBoundCascadeCompleteEvidence
  , descriptorBoundCascadeCompleteRunId
  , descriptorBoundCascadeCompleteDescriptorDigest
  , descriptorBoundCascadeCompleteGraphDigest
  , descriptorBoundCascadeCompleteScope
  , descriptorBoundCascadeCompleteReadyDigest
  , descriptorBoundCascadeCompleteUninstallAttemptId
  , descriptorBoundCascadeCompleteLocalReadBackAttemptId
  , descriptorBoundCascadeCompleteCommitAttemptId
  , descriptorBoundCascadeCompleteReadBackAttemptId
  , descriptorBoundCascadeCompleteAbsenceFact
  , CascadeCompletionRepositoryError (..)
  , CascadeCompletionCommitResult (..)
  , CascadeCompletionRepositoryRegression
  , fixedCascadeCompletionRepositoryRegression
  , cascadeCompletionRepositoryResponseLossRecovered
  , cascadeCompletionRepositoryExactReplayPreserved
  , cascadeCompletionRepositoryConflictPreserved
  , cascadeCompletionRepositoryRestartReadBack
  , cascadeCompletionRepositoryDescriptorBindingExact
  , cascadeCompletionRepositoryPredecessorAttemptsExact
  , cascadeCompletionRepositoryWrongIdentityRefused
  , cascadeCompletionRepositoryCorruptionRefused
  , cascadeCompletionRepositoryBoundsEnforced
  , cascadeCompletionRepositoryLegacyEvidenceDisjoint
  , cascadeCompletionRepositoryOpacityClosed
  )
where

import Prodbox.ControlPlane.CascadeCompletionRepository.Internal
