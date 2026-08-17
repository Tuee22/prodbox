-- | Read-only facade for the Lifecycle-Authority host observation receipt.
-- Repository construction, writes, canonical bytes, and every positive
-- remint remain package-private.  A committed value can originate only from
-- the hidden independent Model-B read-back.
module Prodbox.ControlPlane.LocalRke2HostObservationRepository
  ( LocalRke2HostObservationCommitResult (..)
  , LocalRke2HostObservationRepositoryError (..)
  , CommittedLocalRke2HostObservation
  , committedLocalRke2HostObservationIdentity
  , committedLocalRke2HostObservationRunId
  , committedLocalRke2HostObservationDescriptorDigest
  , committedLocalRke2HostObservationGraphDigest
  , committedLocalRke2HostObservationScope
  , committedLocalRke2HostObservationFoundation
  , committedLocalRke2HostObservationEstablishOperationId
  , committedLocalRke2HostObservationEstablishAttemptId
  , committedLocalRke2HostObservationIdentityDigest
  , LocalRke2HostObservationRepositoryRegression
  , fixedLocalRke2HostObservationRepositoryRegression
  , localRke2HostObservationRegressionCanonicalBounded
  , localRke2HostObservationRegressionResponseLossRecovered
  , localRke2HostObservationRegressionExactReplayPreserved
  , localRke2HostObservationRegressionConflictPreserved
  , localRke2HostObservationRegressionTamperingRefused
  , localRke2HostObservationRegressionUnknownRefused
  , localRke2HostObservationRegressionAttemptKeySeparated
  , localRke2HostObservationRegressionDelayedAttemptRefused
  )
where

import Prodbox.ControlPlane.LocalRke2HostObservationRepository.Internal
