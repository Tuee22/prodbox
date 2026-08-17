-- | Read-only Lifecycle-Authority repository facade for durable recovery-plane
-- evidence.  The Model-B adapter, canonical wire, component observations,
-- binding constructors, and write operations remain package-private.  A write
-- response is never evidence; only these independent read-back operations can
-- return the opaque initial or final evidence values.
module Prodbox.ControlPlane.RecoveryPlaneRepository
  ( RecoveryPlaneRepositoryClient
  , RecoveryPlaneCommitResult (..)
  , RecoveryPlaneRepositoryError (..)
  , independentlyReadBackRecoveryPlaneInitial
  , independentlyReadBackRecoveryPlaneFinal
  , RecoveryPlaneRepositoryRegression
  , fixedRecoveryPlaneRepositoryRegression
  , recoveryPlaneRepositoryResponseLossRecovered
  , recoveryPlaneRepositoryExactReplayPreserved
  , recoveryPlaneRepositoryConflictPreserved
  , recoveryPlaneRepositoryRestartReadBack
  , recoveryPlaneRepositoryAttemptBindingEnforced
  , recoveryPlaneRepositoryCrossIdentityRefused
  , recoveryPlaneRepositoryComponentCompletenessEnforced
  , recoveryPlaneRepositoryEstablishedExact
  , recoveryPlaneRepositoryEstablishedAfterInitialFailure
  , recoveryPlaneRepositoryNotEstablishedExact
  , recoveryPlaneRepositoryLostExact
  , recoveryPlaneRepositoryCorruptionRefused
  , recoveryPlaneRepositoryBoundsEnforced
  , recoveryPlaneRepositoryProfileProgressionRecoverable
  , recoveryPlaneRepositoryObservationBindingExact
  , recoveryPlaneRepositoryObservationBindingPhaseRestricted
  , recoveryPlaneRepositoryOpacityClosed
  )
where

import Prodbox.ControlPlane.RecoveryPlaneRepository.Internal
