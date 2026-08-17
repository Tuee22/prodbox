-- | Read-only facade for the descriptor-bound cascade host-absence record.
--
-- The host store, filesystem observer, canonical bytes, binding constructor,
-- and evidence minter are package-private.  In particular, this module does
-- not provide a conversion from the legacy 'LocalUninstallEvidence'.
module Prodbox.Lifecycle.HostCascadeLocalAbsence
  ( DescriptorBoundCascadeReadyHostBinding
  , descriptorBoundCascadeHostRunId
  , descriptorBoundCascadeHostDescriptorDigest
  , descriptorBoundCascadeHostGraphDigest
  , descriptorBoundCascadeHostScope
  , descriptorBoundCascadeHostReadyDigest
  , descriptorBoundCascadeHostUninstallOperationId
  , descriptorBoundCascadeHostLocalReadBackOperationId
  , descriptorBoundCascadeHostCompletionCommitOperationId
  , descriptorBoundCascadeHostCompletionReadBackOperationId
  , descriptorBoundCascadeHostUninstallAttemptId
  , DescriptorBoundCascadeLocalAbsenceEvidence
  , descriptorBoundCascadeLocalAbsenceBinding
  , descriptorBoundCascadeLocalAbsenceReadBackAttemptId
  , descriptorBoundCascadeLocalAbsenceFact
  , HostCascadeLocalAbsenceError (..)
  , maximumHostCascadeLocalAbsenceBytes
  , HostCascadeLocalAbsenceRegression
  , fixedHostCascadeLocalAbsenceRegression
  , hostCascadeLocalAbsenceRegressionV2Bound
  , hostCascadeLocalAbsenceRegressionCanonical
  , hostCascadeLocalAbsenceRegressionExactReplay
  , hostCascadeLocalAbsenceRegressionFreshReadBack
  , hostCascadeLocalAbsenceRegressionPresentRefused
  , hostCascadeLocalAbsenceRegressionWrongAttemptRefused
  , hostCascadeLocalAbsenceRegressionOpacityClosed
  )
where

import Prodbox.Lifecycle.HostCascadeLocalAbsence.Internal
