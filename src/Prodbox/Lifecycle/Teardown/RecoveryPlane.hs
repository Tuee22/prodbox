-- | Read-only recovery-plane evidence facade.  Profile construction, raw
-- component observations, identity codecs, and every proof constructor remain
-- package-private.  The public surface exposes only opaque values and
-- non-authorizing views/accessors.
module Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneProfileDigest
  , recoveryPlaneProfileDigestText
  , RecoveryPlaneComponentIdentity (..)
  , recoveryPlaneComponentIdentityText
  , RecoveryPlaneComponentFailureKind (..)
  , RecoveryPlaneComponentFailure
  , recoveryPlaneComponentFailureIdentity
  , recoveryPlaneComponentFailureKind
  , RecoveryPlaneIdentity
  , recoveryPlaneIdentitySurface
  , recoveryPlaneIdentityRunId
  , recoveryPlaneIdentityDescriptorDigest
  , recoveryPlaneIdentityGraphDigest
  , recoveryPlaneIdentityObservationScope
  , recoveryPlaneIdentityCapabilityCatalogDigest
  , recoveryPlaneIdentityRequirementDigest
  , recoveryPlaneIdentityTargetAgent
  , recoveryPlaneIdentityProfileDigest
  , recoveryPlaneIdentityComponents
  , recoveryPlaneIdentityEstablishOperationId
  , recoveryPlaneIdentityReadBackOperationId
  , recoveryPlaneIdentityDispositionOperationId
  , RecoveryPlaneInitialReadBack
  , recoveryPlaneInitialIdentity
  , recoveryPlaneInitialEstablishAttemptId
  , recoveryPlaneInitialReadBackAttemptId
  , recoveryPlaneInitialFailures
  , RecoveryPlaneInitialDisposition (..)
  , recoveryPlaneInitialDisposition
  , RecoveryPlaneReady
  , recoveryPlaneReadyIdentity
  , recoveryPlaneReadyEstablishAttemptId
  , recoveryPlaneReadyReadBackAttemptId
  , RecoveryPlaneFinalEvidence
  , RecoveryPlaneFinalDisposition (..)
  , recoveryPlaneFinalIdentity
  , recoveryPlaneFinalEstablishAttemptId
  , recoveryPlaneFinalInitialReadBackAttemptId
  , recoveryPlaneFinalDispositionAttemptId
  , recoveryPlaneFinalDisposition
  , recoveryPlaneFinalFailures
  , recoveryPlaneFinalEstablishedReady
  , RecoveryPlaneEvidenceError (..)
  , maximumRecoveryPlaneIdentityBytes
  , RecoveryPlaneFixtureRegression
  , fixedRecoveryPlaneFixtureRegression
  , recoveryPlaneFixtureProfileCanonical
  , recoveryPlaneFixtureProfileTargetAgentSeparated
  , recoveryPlaneFixtureIdentityCanonical
  , recoveryPlaneFixtureExactCompletenessEnforced
  , recoveryPlaneFixtureEveryFailureRefused
  , recoveryPlaneFixtureDiagnosticsNormalized
  , recoveryPlaneFixtureInitialReadyExact
  , recoveryPlaneFixtureEstablishedFromReady
  , recoveryPlaneFixtureEstablishedAfterInitialFailure
  , recoveryPlaneFixtureNotEstablishedExact
  , recoveryPlaneFixtureLostExact
  , recoveryPlaneFixtureLostHidesReady
  , recoveryPlaneFixtureCrossBindingRefused
  , recoveryPlaneFixtureDynamicProfileRestored
  )
where

import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal
