{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure, exact EKS stack-destruction admission.  The generic stack adapter
-- cannot authorize @aws-eks@: this boundary additionally requires the
-- durable, attempt-bound proof that the exact Kubernetes targets selected
-- before mutation were independently read back as absent.
--
-- A fresh 'EksDrainSession' is consumed only to compare its safe current
-- identity projection with that proof.  The session, bearer, endpoint, CA
-- material, and client-auth projection are never retained by an authorization
-- or request.
module Prodbox.Lifecycle.Teardown.AwsEksDestroyAdapter
  ( AwsEksDestroyAuthorityKind (..)
  , AwsEksDestroyAuthorization
  , awsEksDestroyAuthorizationKey
  , awsEksDestroyAuthorizationCoordinateDigest
  , awsEksDestroyAuthorizationScope
  , awsEksDestroyAuthorizationProviderRevision
  , awsEksDestroyAuthorizationDecision
  , awsEksDestroyAuthorizationAuthorityKind
  , awsEksDestroyAuthorizationDrainBinding
  , awsEksDestroyAuthorizationDrainAttemptId
  , awsEksDestroyAuthorizationOperationId
  , awsEksDestroyAuthorizationClusterArn
  , awsEksDestroyAuthorizationClusterUid
  , awsEksDestroyAuthorizationEndpointDigest
  , awsEksDestroyAuthorizationCertificateAuthorityDigest
  , awsEksDestroyAuthorizationProviderObservationRevision
  , awsEksDestroyAuthorizationKubernetesObservationRevision
  , awsEksDestroyAuthorizationSessionExpiresAtEpochSeconds
  , authorizeAwsEksDestroy
  , AwsEksDestroyRequest
  , awsEksDestroyRequestAuthorization
  , awsEksDestroyRequestKey
  , awsEksDestroyRequestScope
  , awsEksDestroyRequestOperationId
  , awsEksDestroyRequestProviderIntent
  , awsEksDestroyRequestProviderCoordinate
  , mkAwsEksDestroyRequest
  , AwsEksDestroyReadBackRequest
  , awsEksDestroyReadBackDestroyCoordinate
  , awsEksDestroyReadBackObservationRequest
  , awsEksDestroyReadBackProviderIntent
  , awsEksDestroyReadBackProviderCoordinate
  , awsEksDestroyReadBackRevision
  , mkAwsEksDestroyReadBackRequest
  , CompleteAwsEksDestroy
  , completeAwsEksDestroyAuthorization
  , completeAwsEksDestroyKey
  , completeAwsEksDestroyCoordinateDigest
  , completeAwsEksDestroyScope
  , completeAwsEksDestroyOperationId
  , completeAwsEksDestroyDrainAttemptId
  , completeAwsEksDestroyObservationRevision
  , completeAwsEksDestroyAbsenceEvidence
  , completeAwsEksDestroyReadBack
  , AwsEksDestroyRefusal (..)
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderRefError
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackConfigError
  , mkProviderStackRef
  , providerIntentCoordinate
  , validateProviderStackConfig
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( AwsEksAdapterError
  , AwsEksObservationPurpose (..)
  , ExactAwsEksObservationRequest
  , VerifiedAwsEksObservation
  , awsEksObservationRequestProviderCoordinate
  , awsEksObservationRequestProviderIntent
  , awsEksObservationRequestRevision
  , mkAwsEksDesiredAbsenceReadBackRequest
  , verifiedAwsEksClusterArn
  , verifiedAwsEksExactObservation
  )
import Prodbox.Lifecycle.Teardown.Decision
  ( StackCleanupAuthority (..)
  , StackDecisionRefusal
  , StackDesiredAbsenceDecision (..)
  )
import Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( EksDrainIntentTarget (..)
  , EksDrainOperationBinding
  , EksDrainTargetsAbsentDisposition (..)
  , EksDrainTargetsAbsentEvidence
  , eksDrainBindingDrainReadBackOperationId
  , eksDrainBindingEffectOperationId
  , eksDrainBindingGraphDigest
  , eksDrainBindingIntentCommitOperationId
  , eksDrainBindingIntentReadBackOperationId
  , eksDrainBindingRunId
  , eksDrainBindingScope
  , eksDrainIntentCoordinateDigest
  , eksDrainIntentResourceKey
  , eksDrainIntentTarget
  , eksDrainTargetsAbsentDisposition
  , eksDrainTargetsAbsentDrainReadBackOperationId
  , eksDrainTargetsAbsentEffectAttemptId
  , eksDrainTargetsAbsentEffectOperationId
  , eksDrainTargetsAbsentGraphDigest
  , eksDrainTargetsAbsentIntent
  , eksDrainTargetsAbsentIntentCommitOperationId
  , eksDrainTargetsAbsentIntentReadBackOperationId
  , eksDrainTargetsAbsentRunId
  , eksDrainTargetsAbsentScope
  )
import Prodbox.Lifecycle.Teardown.EksDrainSession
  ( EksDrainSession
  , eksClusterArnText
  , eksClusterUidText
  , eksDrainSessionCertificateAuthorityDigest
  , eksDrainSessionClusterArn
  , eksDrainSessionClusterUid
  , eksDrainSessionEndpointDigest
  , eksDrainSessionEvidenceScope
  , eksDrainSessionExpiresAtEpochSeconds
  , eksDrainSessionKubernetesRevision
  , eksDrainSessionObservationRevision
  , eksDrainSessionOperationId
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
  ( awsEksResource
  )
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry

data AwsEksDestroyAuthorityKind
  = AwsEksDestroyFromPrimaryCheckpoint
  | AwsEksDestroyFromCompleteManifest
  deriving (Eq, Show)

-- | Opaque EKS-only destruction capability.  Every retained field is a safe
-- identifier, revision, or digest projected from the independently verified
-- inputs.  In particular, the short-lived client session is not retained.
data AwsEksDestroyAuthorization = AwsEksDestroyAuthorization
  { internalAwsEksDestroyKey :: !RegisteredResourceKey
  , internalAwsEksDestroyCoordinateDigest :: !ManagedResourceCoordinateDigest
  , internalAwsEksDestroyScope :: !ObservationEvidenceScope
  , internalAwsEksDestroyProviderRevision :: !ProviderRevision
  , internalAwsEksDestroyDecision :: !StackDesiredAbsenceDecision
  , internalAwsEksDestroyAuthorityKind :: !AwsEksDestroyAuthorityKind
  , internalAwsEksDestroyDrainBinding :: !EksDrainOperationBinding
  , internalAwsEksDestroyDrainAttemptId :: !CleanupAttemptId
  , internalAwsEksDestroyOperationId :: !CleanupOperationId
  , internalAwsEksDestroyClusterArn :: !Text
  , internalAwsEksDestroyClusterUid :: !Text
  , internalAwsEksDestroyEndpointDigest :: !Text
  , internalAwsEksDestroyCertificateAuthorityDigest :: !Text
  , internalAwsEksDestroyProviderObservationRevision :: !ObservationRevision
  , internalAwsEksDestroyKubernetesObservationRevision :: !ObservationRevision
  , internalAwsEksDestroySessionExpiresAtEpochSeconds :: !Integer
  }
  deriving (Eq, Show)

awsEksDestroyAuthorizationKey
  :: AwsEksDestroyAuthorization -> RegisteredResourceKey
awsEksDestroyAuthorizationKey = internalAwsEksDestroyKey

awsEksDestroyAuthorizationCoordinateDigest
  :: AwsEksDestroyAuthorization -> ManagedResourceCoordinateDigest
awsEksDestroyAuthorizationCoordinateDigest = internalAwsEksDestroyCoordinateDigest

awsEksDestroyAuthorizationScope
  :: AwsEksDestroyAuthorization -> ObservationEvidenceScope
awsEksDestroyAuthorizationScope = internalAwsEksDestroyScope

awsEksDestroyAuthorizationProviderRevision
  :: AwsEksDestroyAuthorization -> ProviderRevision
awsEksDestroyAuthorizationProviderRevision = internalAwsEksDestroyProviderRevision

awsEksDestroyAuthorizationDecision
  :: AwsEksDestroyAuthorization -> StackDesiredAbsenceDecision
awsEksDestroyAuthorizationDecision = internalAwsEksDestroyDecision

awsEksDestroyAuthorizationAuthorityKind
  :: AwsEksDestroyAuthorization -> AwsEksDestroyAuthorityKind
awsEksDestroyAuthorizationAuthorityKind = internalAwsEksDestroyAuthorityKind

awsEksDestroyAuthorizationDrainBinding
  :: AwsEksDestroyAuthorization -> EksDrainOperationBinding
awsEksDestroyAuthorizationDrainBinding = internalAwsEksDestroyDrainBinding

awsEksDestroyAuthorizationDrainAttemptId
  :: AwsEksDestroyAuthorization -> CleanupAttemptId
awsEksDestroyAuthorizationDrainAttemptId = internalAwsEksDestroyDrainAttemptId

awsEksDestroyAuthorizationOperationId
  :: AwsEksDestroyAuthorization -> CleanupOperationId
awsEksDestroyAuthorizationOperationId = internalAwsEksDestroyOperationId

awsEksDestroyAuthorizationClusterArn :: AwsEksDestroyAuthorization -> Text
awsEksDestroyAuthorizationClusterArn = internalAwsEksDestroyClusterArn

awsEksDestroyAuthorizationClusterUid :: AwsEksDestroyAuthorization -> Text
awsEksDestroyAuthorizationClusterUid = internalAwsEksDestroyClusterUid

awsEksDestroyAuthorizationEndpointDigest :: AwsEksDestroyAuthorization -> Text
awsEksDestroyAuthorizationEndpointDigest = internalAwsEksDestroyEndpointDigest

awsEksDestroyAuthorizationCertificateAuthorityDigest
  :: AwsEksDestroyAuthorization -> Text
awsEksDestroyAuthorizationCertificateAuthorityDigest =
  internalAwsEksDestroyCertificateAuthorityDigest

awsEksDestroyAuthorizationProviderObservationRevision
  :: AwsEksDestroyAuthorization -> ObservationRevision
awsEksDestroyAuthorizationProviderObservationRevision =
  internalAwsEksDestroyProviderObservationRevision

awsEksDestroyAuthorizationKubernetesObservationRevision
  :: AwsEksDestroyAuthorization -> ObservationRevision
awsEksDestroyAuthorizationKubernetesObservationRevision =
  internalAwsEksDestroyKubernetesObservationRevision

awsEksDestroyAuthorizationSessionExpiresAtEpochSeconds
  :: AwsEksDestroyAuthorization -> Integer
awsEksDestroyAuthorizationSessionExpiresAtEpochSeconds =
  internalAwsEksDestroySessionExpiresAtEpochSeconds

-- | Admit destruction only after comparing a fresh exact provider and
-- Kubernetes identity against the durable drain proof and the graph's
-- expected write-ahead/effect/read-back identities.
authorizeAwsEksDestroy
  :: Integer
  -> ProviderRevision
  -> EksDrainOperationBinding
  -> CleanupAttemptId
  -> CleanupOperationId
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> EksDrainSession
  -> StackDesiredAbsenceDecision
  -> EksDrainTargetsAbsentEvidence
  -> Either AwsEksDestroyRefusal AwsEksDestroyAuthorization
authorizeAwsEksDestroy now providerRevision expectedBinding expectedAttempt destroyOperation verified session decision drainEvidence = do
  authorityKind <- validateDestroyDecision decision
  validateDistinctDestroyOperation expectedBinding destroyOperation
  let expectedScope = eksDrainBindingScope expectedBinding
      observation = verifiedAwsEksExactObservation verified
      expectedCoordinate = Registry.managedResourceCoordinateDigest awsEksResource
      intent = eksDrainTargetsAbsentIntent drainEvidence
  requireEqual
    AwsEksDestroyObservationKeyMismatch
    AwsEksKey
    (exactObservationResourceKey observation)
  requireEqual
    AwsEksDestroyObservationCoordinateMismatch
    expectedCoordinate
    (exactObservationCoordinateDigest observation)
  requireEqual
    AwsEksDestroyObservationAuthorityMismatch
    AwsResourceApiAuthority
    (exactObservationAuthority observation)
  requireEqual
    AwsEksDestroyObservationScopeMismatch
    expectedScope
    (exactObservationEvidenceScope observation)
  observedArn <- case (exactObservationResult observation, verifiedAwsEksClusterArn verified) of
    (ExactResourcePresent _, Just arn) -> Right arn
    (ExactResourceAbsent _, _) -> Left AwsEksDestroyObservationAlreadyAbsent
    (ExactResourcePartial _ failures, _) ->
      Left (AwsEksDestroyObservationPartial failures)
    (ExactResourceUnobservable failures, _) ->
      Left (AwsEksDestroyObservationUnobservable failures)
    (ExactResourcePresent _, Nothing) ->
      Left AwsEksDestroyObservationPresentWithoutArn
  case eksDrainTargetsAbsentDisposition drainEvidence of
    ExactKubernetesDrainTargetsAbsent -> Right ()
    NoKubernetesDrainTargetRequired ->
      Left AwsEksDestroyNoKubernetesTargetCannotAuthorizeMutation
  target <- case eksDrainIntentTarget intent of
    exact@EksDrainExactKubernetesTarget {} -> Right exact
    EksDrainNoKubernetesTarget {} ->
      Left AwsEksDestroyNoKubernetesTargetCannotAuthorizeMutation
  requireEqual
    AwsEksDestroyDrainKeyMismatch
    AwsEksKey
    (eksDrainIntentResourceKey intent)
  requireEqual
    AwsEksDestroyDrainCoordinateMismatch
    expectedCoordinate
    (eksDrainIntentCoordinateDigest intent)
  validateDrainProofBinding expectedBinding expectedAttempt drainEvidence
  requireEqual
    AwsEksDestroySessionOperationMismatch
    destroyOperation
    (eksDrainSessionOperationId session)
  requireEqual
    AwsEksDestroySessionScopeMismatch
    expectedScope
    (eksDrainSessionEvidenceScope session)
  let providerObservationRevision = exactObservationRevision observation
      sessionProviderRevision = eksDrainSessionObservationRevision session
      kubernetesRevision = eksDrainSessionKubernetesRevision session
      selectionRevision = eksDrainTargetSelectionRevision target
      expiresAt = eksDrainSessionExpiresAtEpochSeconds session
  requireEqual
    AwsEksDestroySessionProviderObservationRevisionMismatch
    providerObservationRevision
    sessionProviderRevision
  -- Observation revisions are opaque dispatch identities, not monotonic
  -- counters. Freshness comes from the new session's binding to this distinct
  -- destroy operation; reusing the drain selection identity is the stale case.
  if providerObservationRevision /= selectionRevision
    then Right ()
    else
      Left
        ( AwsEksDestroyProviderObservationNotFresh
            selectionRevision
            providerObservationRevision
        )
  if kubernetesRevision /= selectionRevision
    then Right ()
    else
      Left
        ( AwsEksDestroyKubernetesObservationNotFresh
            selectionRevision
            kubernetesRevision
        )
  if expiresAt > now
    then Right ()
    else Left (AwsEksDestroySessionExpired now expiresAt)
  let sessionArn = eksClusterArnText (eksDrainSessionClusterArn session)
      sessionUid = eksClusterUidText (eksDrainSessionClusterUid session)
      sessionEndpointDigest = eksDrainSessionEndpointDigest session
      sessionCaDigest = eksDrainSessionCertificateAuthorityDigest session
  requireEqual AwsEksDestroyObservedArnMismatch observedArn sessionArn
  requireEqual
    AwsEksDestroyDrainedArnMismatch
    (eksDrainTargetProviderArn target)
    sessionArn
  requireEqual
    AwsEksDestroyDrainedUidMismatch
    (eksDrainTargetKubernetesUid target)
    sessionUid
  requireEqual
    AwsEksDestroyDrainedEndpointDigestMismatch
    (eksDrainTargetEndpointDigest target)
    sessionEndpointDigest
  requireEqual
    AwsEksDestroyDrainedCertificateAuthorityDigestMismatch
    (eksDrainTargetCertificateAuthorityDigest target)
    sessionCaDigest
  Right
    AwsEksDestroyAuthorization
      { internalAwsEksDestroyKey = AwsEksKey
      , internalAwsEksDestroyCoordinateDigest = expectedCoordinate
      , internalAwsEksDestroyScope = expectedScope
      , internalAwsEksDestroyProviderRevision = providerRevision
      , internalAwsEksDestroyDecision = decision
      , internalAwsEksDestroyAuthorityKind = authorityKind
      , internalAwsEksDestroyDrainBinding = expectedBinding
      , internalAwsEksDestroyDrainAttemptId = expectedAttempt
      , internalAwsEksDestroyOperationId = destroyOperation
      , internalAwsEksDestroyClusterArn = sessionArn
      , internalAwsEksDestroyClusterUid = sessionUid
      , internalAwsEksDestroyEndpointDigest = sessionEndpointDigest
      , internalAwsEksDestroyCertificateAuthorityDigest = sessionCaDigest
      , internalAwsEksDestroyProviderObservationRevision = providerObservationRevision
      , internalAwsEksDestroyKubernetesObservationRevision = kubernetesRevision
      , internalAwsEksDestroySessionExpiresAtEpochSeconds = expiresAt
      }

data AwsEksDestroyRequest = AwsEksDestroyRequest
  { internalAwsEksDestroyRequestAuthorization :: !AwsEksDestroyAuthorization
  , internalAwsEksDestroyRequestIntent :: !ProviderIntent
  , internalAwsEksDestroyRequestCoordinate :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsEksDestroyRequestAuthorization
  :: AwsEksDestroyRequest -> AwsEksDestroyAuthorization
awsEksDestroyRequestAuthorization = internalAwsEksDestroyRequestAuthorization

awsEksDestroyRequestKey :: AwsEksDestroyRequest -> RegisteredResourceKey
awsEksDestroyRequestKey =
  awsEksDestroyAuthorizationKey . awsEksDestroyRequestAuthorization

awsEksDestroyRequestScope :: AwsEksDestroyRequest -> ObservationEvidenceScope
awsEksDestroyRequestScope =
  awsEksDestroyAuthorizationScope . awsEksDestroyRequestAuthorization

awsEksDestroyRequestOperationId :: AwsEksDestroyRequest -> CleanupOperationId
awsEksDestroyRequestOperationId =
  awsEksDestroyAuthorizationOperationId . awsEksDestroyRequestAuthorization

awsEksDestroyRequestProviderIntent :: AwsEksDestroyRequest -> ProviderIntent
awsEksDestroyRequestProviderIntent = internalAwsEksDestroyRequestIntent

awsEksDestroyRequestProviderCoordinate
  :: AwsEksDestroyRequest -> ProviderIntentCoordinate
awsEksDestroyRequestProviderCoordinate = internalAwsEksDestroyRequestCoordinate

mkAwsEksDestroyRequest
  :: AwsEksDestroyAuthorization
  -> ProviderRevision
  -> ProviderStackConfig
  -> Either AwsEksDestroyRefusal AwsEksDestroyRequest
mkAwsEksDestroyRequest authorization requestedRevision config = do
  requireEqual
    AwsEksDestroyProviderRevisionMismatch
    (awsEksDestroyAuthorizationProviderRevision authorization)
    requestedRevision
  stackRef <-
    either
      (Left . AwsEksDestroyProviderRefInvalid)
      Right
      (mkProviderStackRef "aws-eks")
  either
    (Left . AwsEksDestroyConfigInvalid)
    Right
    (validateProviderStackConfig stackRef config)
  let intent = DestroyRegisteredStack stackRef requestedRevision config
  Right
    AwsEksDestroyRequest
      { internalAwsEksDestroyRequestAuthorization = authorization
      , internalAwsEksDestroyRequestIntent = intent
      , internalAwsEksDestroyRequestCoordinate = providerIntentCoordinate intent
      }

-- | Read-back is a separate exact EKS DescribeCluster operation.  It retains
-- the parent destroy coordinate so an apply response can never close the
-- request and a read-back for another destroy cannot be substituted.
data AwsEksDestroyReadBackRequest = AwsEksDestroyReadBackRequest
  { internalAwsEksDestroyReadBackDestroyRequest :: !AwsEksDestroyRequest
  , internalAwsEksDestroyReadBackObservationRequest
      :: !(ExactAwsEksObservationRequest 'ReadBackEksDesiredAbsent)
  , internalAwsEksDestroyReadBackDestroyCoordinate
      :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsEksDestroyReadBackDestroyCoordinate
  :: AwsEksDestroyReadBackRequest -> ProviderIntentCoordinate
awsEksDestroyReadBackDestroyCoordinate =
  internalAwsEksDestroyReadBackDestroyCoordinate

awsEksDestroyReadBackObservationRequest
  :: AwsEksDestroyReadBackRequest
  -> ExactAwsEksObservationRequest 'ReadBackEksDesiredAbsent
awsEksDestroyReadBackObservationRequest =
  internalAwsEksDestroyReadBackObservationRequest

awsEksDestroyReadBackProviderIntent
  :: AwsEksDestroyReadBackRequest -> ProviderIntent
awsEksDestroyReadBackProviderIntent =
  awsEksObservationRequestProviderIntent . awsEksDestroyReadBackObservationRequest

awsEksDestroyReadBackProviderCoordinate
  :: AwsEksDestroyReadBackRequest -> ProviderIntentCoordinate
awsEksDestroyReadBackProviderCoordinate =
  awsEksObservationRequestProviderCoordinate . awsEksDestroyReadBackObservationRequest

awsEksDestroyReadBackRevision
  :: AwsEksDestroyReadBackRequest -> ObservationRevision
awsEksDestroyReadBackRevision request =
  exactObservationRevisionForReadBack request

mkAwsEksDestroyReadBackRequest
  :: AwsEksDestroyRequest
  -> ObservationRevision
  -> Either AwsEksDestroyRefusal AwsEksDestroyReadBackRequest
mkAwsEksDestroyReadBackRequest destroyRequest readBackRevision = do
  let authorization = awsEksDestroyRequestAuthorization destroyRequest
      initialRevision =
        awsEksDestroyAuthorizationProviderObservationRevision authorization
  -- The revision is a dispatch identity, not a clock. The independently
  -- issued read-back request supplies the topology; it must be distinct from
  -- the pre-destroy observation without imposing numeric ordering on hashes.
  if readBackRevision /= initialRevision
    then Right ()
    else
      Left
        ( AwsEksDestroyReadBackRevisionNotFresh
            initialRevision
            readBackRevision
        )
  observationRequest <-
    either
      (Left . AwsEksDestroyReadBackRequestInvalid)
      Right
      ( mkAwsEksDesiredAbsenceReadBackRequest
          readBackRevision
          (awsEksDestroyAuthorizationScope authorization)
      )
  Right
    AwsEksDestroyReadBackRequest
      { internalAwsEksDestroyReadBackDestroyRequest = destroyRequest
      , internalAwsEksDestroyReadBackObservationRequest = observationRequest
      , internalAwsEksDestroyReadBackDestroyCoordinate =
          awsEksDestroyRequestProviderCoordinate destroyRequest
      }

data CompleteAwsEksDestroy = CompleteAwsEksDestroy
  { internalCompleteAwsEksDestroyAuthorization :: !AwsEksDestroyAuthorization
  , internalCompleteAwsEksDestroyObservationRevision :: !ObservationRevision
  , internalCompleteAwsEksDestroyAbsenceEvidence :: !AbsenceEvidence
  }
  deriving (Eq, Show)

completeAwsEksDestroyAuthorization
  :: CompleteAwsEksDestroy -> AwsEksDestroyAuthorization
completeAwsEksDestroyAuthorization = internalCompleteAwsEksDestroyAuthorization

completeAwsEksDestroyKey :: CompleteAwsEksDestroy -> RegisteredResourceKey
completeAwsEksDestroyKey =
  awsEksDestroyAuthorizationKey . completeAwsEksDestroyAuthorization

completeAwsEksDestroyCoordinateDigest
  :: CompleteAwsEksDestroy -> ManagedResourceCoordinateDigest
completeAwsEksDestroyCoordinateDigest =
  awsEksDestroyAuthorizationCoordinateDigest . completeAwsEksDestroyAuthorization

completeAwsEksDestroyScope
  :: CompleteAwsEksDestroy -> ObservationEvidenceScope
completeAwsEksDestroyScope =
  awsEksDestroyAuthorizationScope . completeAwsEksDestroyAuthorization

completeAwsEksDestroyOperationId
  :: CompleteAwsEksDestroy -> CleanupOperationId
completeAwsEksDestroyOperationId =
  awsEksDestroyAuthorizationOperationId . completeAwsEksDestroyAuthorization

completeAwsEksDestroyDrainAttemptId
  :: CompleteAwsEksDestroy -> CleanupAttemptId
completeAwsEksDestroyDrainAttemptId =
  awsEksDestroyAuthorizationDrainAttemptId . completeAwsEksDestroyAuthorization

completeAwsEksDestroyObservationRevision
  :: CompleteAwsEksDestroy -> ObservationRevision
completeAwsEksDestroyObservationRevision =
  internalCompleteAwsEksDestroyObservationRevision

completeAwsEksDestroyAbsenceEvidence
  :: CompleteAwsEksDestroy -> AbsenceEvidence
completeAwsEksDestroyAbsenceEvidence = internalCompleteAwsEksDestroyAbsenceEvidence

completeAwsEksDestroyReadBack
  :: AwsEksDestroyReadBackRequest
  -> VerifiedAwsEksObservation 'ReadBackEksDesiredAbsent
  -> Either AwsEksDestroyRefusal CompleteAwsEksDestroy
completeAwsEksDestroyReadBack request verified = do
  let destroyRequest = internalAwsEksDestroyReadBackDestroyRequest request
      authorization = awsEksDestroyRequestAuthorization destroyRequest
      observation = verifiedAwsEksExactObservation verified
      expectedRevision = awsEksDestroyReadBackRevision request
  requireEqual
    AwsEksDestroyReadBackParentMismatch
    (awsEksDestroyRequestProviderCoordinate destroyRequest)
    (awsEksDestroyReadBackDestroyCoordinate request)
  requireEqual
    AwsEksDestroyReadBackKeyMismatch
    (awsEksDestroyAuthorizationKey authorization)
    (exactObservationResourceKey observation)
  requireEqual
    AwsEksDestroyReadBackCoordinateMismatch
    (awsEksDestroyAuthorizationCoordinateDigest authorization)
    (exactObservationCoordinateDigest observation)
  requireEqual
    AwsEksDestroyReadBackScopeMismatch
    (awsEksDestroyAuthorizationScope authorization)
    (exactObservationEvidenceScope observation)
  requireEqual
    AwsEksDestroyReadBackRevisionMismatch
    expectedRevision
    (exactObservationRevision observation)
  absence <- case exactObservationResult observation of
    ExactResourceAbsent evidence -> Right evidence
    ExactResourcePresent inventory ->
      Left (AwsEksDestroyReadBackStillPresent inventory)
    ExactResourcePartial _ failures ->
      Left (AwsEksDestroyReadBackPartial failures)
    ExactResourceUnobservable failures ->
      Left (AwsEksDestroyReadBackUnobservable failures)
  Right
    CompleteAwsEksDestroy
      { internalCompleteAwsEksDestroyAuthorization = authorization
      , internalCompleteAwsEksDestroyObservationRevision = expectedRevision
      , internalCompleteAwsEksDestroyAbsenceEvidence = absence
      }

data AwsEksDestroyRefusal
  = AwsEksDestroyDecisionAlreadyAbsent
  | AwsEksDestroyCheckpointRestoreRequired
  | AwsEksDestroyDecisionRefused !(NonEmpty StackDecisionRefusal)
  | AwsEksDestroyDecisionAuthorityMismatch !StackCleanupAuthority
  | AwsEksDestroyDecisionKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsEksDestroyOperationIdentityReused !CleanupOperationId
  | AwsEksDestroyObservationKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsEksDestroyObservationCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | AwsEksDestroyObservationAuthorityMismatch
      !ObservationAuthority
      !ObservationAuthority
  | AwsEksDestroyObservationScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | AwsEksDestroyObservationAlreadyAbsent
  | AwsEksDestroyObservationPartial !(NonEmpty ObservationFailure)
  | AwsEksDestroyObservationUnobservable !(NonEmpty ObservationFailure)
  | AwsEksDestroyObservationPresentWithoutArn
  | AwsEksDestroyNoKubernetesTargetCannotAuthorizeMutation
  | AwsEksDestroyDrainKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsEksDestroyDrainCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | AwsEksDestroyDrainScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | AwsEksDestroyDrainRunMismatch !CleanupRunId !CleanupRunId
  | AwsEksDestroyDrainGraphMismatch !CleanupDigest !CleanupDigest
  | AwsEksDestroyDrainIntentCommitOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | AwsEksDestroyDrainIntentReadBackOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | AwsEksDestroyDrainEffectOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | AwsEksDestroyDrainReadBackOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | AwsEksDestroyDrainAttemptMismatch !CleanupAttemptId !CleanupAttemptId
  | AwsEksDestroySessionOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | AwsEksDestroySessionScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | AwsEksDestroySessionProviderObservationRevisionMismatch
      !ObservationRevision
      !ObservationRevision
  | AwsEksDestroyProviderObservationNotFresh
      !ObservationRevision
      !ObservationRevision
  | AwsEksDestroyKubernetesObservationNotFresh
      !ObservationRevision
      !ObservationRevision
  | AwsEksDestroySessionExpired !Integer !Integer
  | AwsEksDestroyObservedArnMismatch !Text !Text
  | AwsEksDestroyDrainedArnMismatch !Text !Text
  | AwsEksDestroyDrainedUidMismatch !Text !Text
  | AwsEksDestroyDrainedEndpointDigestMismatch !Text !Text
  | AwsEksDestroyDrainedCertificateAuthorityDigestMismatch !Text !Text
  | AwsEksDestroyProviderRevisionMismatch !ProviderRevision !ProviderRevision
  | AwsEksDestroyProviderRefInvalid !ProviderRefError
  | AwsEksDestroyConfigInvalid !ProviderStackConfigError
  | AwsEksDestroyReadBackRevisionNotFresh
      !ObservationRevision
      !ObservationRevision
  | AwsEksDestroyReadBackRequestInvalid !AwsEksAdapterError
  | AwsEksDestroyReadBackParentMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsEksDestroyReadBackKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsEksDestroyReadBackCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | AwsEksDestroyReadBackScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | AwsEksDestroyReadBackRevisionMismatch
      !ObservationRevision
      !ObservationRevision
  | AwsEksDestroyReadBackStillPresent !ExactResourceInventory
  | AwsEksDestroyReadBackPartial !(NonEmpty ObservationFailure)
  | AwsEksDestroyReadBackUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

validateDestroyDecision
  :: StackDesiredAbsenceDecision
  -> Either AwsEksDestroyRefusal AwsEksDestroyAuthorityKind
validateDestroyDecision decision = case decision of
  StackDestroyFromVerifiedPrimary key authority -> do
    validateDecisionKey key
    case authority of
      VerifiedPrimaryCheckpoint {} -> Right AwsEksDestroyFromPrimaryCheckpoint
      _ -> Left (AwsEksDestroyDecisionAuthorityMismatch authority)
  StackDestroyFromVerifiedManifest key authority -> do
    validateDecisionKey key
    case authority of
      VerifiedOwnershipManifest {} -> Right AwsEksDestroyFromCompleteManifest
      _ -> Left (AwsEksDestroyDecisionAuthorityMismatch authority)
  StackAlreadyAbsent {} -> Left AwsEksDestroyDecisionAlreadyAbsent
  StackRestoreBackupThenDestroy {} ->
    Left AwsEksDestroyCheckpointRestoreRequired
  StackDesiredAbsenceRefused _ refusals ->
    Left (AwsEksDestroyDecisionRefused refusals)

validateDecisionKey
  :: RegisteredResourceKey -> Either AwsEksDestroyRefusal ()
validateDecisionKey actual =
  requireEqual AwsEksDestroyDecisionKeyMismatch AwsEksKey actual

validateDistinctDestroyOperation
  :: EksDrainOperationBinding
  -> CleanupOperationId
  -> Either AwsEksDestroyRefusal ()
validateDistinctDestroyOperation binding destroyOperation =
  if destroyOperation `elem` drainOperations
    then Left (AwsEksDestroyOperationIdentityReused destroyOperation)
    else Right ()
 where
  drainOperations =
    [ eksDrainBindingIntentCommitOperationId binding
    , eksDrainBindingIntentReadBackOperationId binding
    , eksDrainBindingEffectOperationId binding
    , eksDrainBindingDrainReadBackOperationId binding
    ]

validateDrainProofBinding
  :: EksDrainOperationBinding
  -> CleanupAttemptId
  -> EksDrainTargetsAbsentEvidence
  -> Either AwsEksDestroyRefusal ()
validateDrainProofBinding expected expectedAttempt evidence = do
  requireEqual
    AwsEksDestroyDrainRunMismatch
    (eksDrainBindingRunId expected)
    (eksDrainTargetsAbsentRunId evidence)
  requireEqual
    AwsEksDestroyDrainScopeMismatch
    (eksDrainBindingScope expected)
    (eksDrainTargetsAbsentScope evidence)
  requireEqual
    AwsEksDestroyDrainGraphMismatch
    (eksDrainBindingGraphDigest expected)
    (eksDrainTargetsAbsentGraphDigest evidence)
  requireEqual
    AwsEksDestroyDrainIntentCommitOperationMismatch
    (eksDrainBindingIntentCommitOperationId expected)
    (eksDrainTargetsAbsentIntentCommitOperationId evidence)
  requireEqual
    AwsEksDestroyDrainIntentReadBackOperationMismatch
    (eksDrainBindingIntentReadBackOperationId expected)
    (eksDrainTargetsAbsentIntentReadBackOperationId evidence)
  requireEqual
    AwsEksDestroyDrainEffectOperationMismatch
    (eksDrainBindingEffectOperationId expected)
    (eksDrainTargetsAbsentEffectOperationId evidence)
  requireEqual
    AwsEksDestroyDrainReadBackOperationMismatch
    (eksDrainBindingDrainReadBackOperationId expected)
    (eksDrainTargetsAbsentDrainReadBackOperationId evidence)
  requireEqual
    AwsEksDestroyDrainAttemptMismatch
    expectedAttempt
    (eksDrainTargetsAbsentEffectAttemptId evidence)

exactObservationRevisionForReadBack
  :: AwsEksDestroyReadBackRequest -> ObservationRevision
exactObservationRevisionForReadBack =
  awsEksObservationRequestRevision . awsEksDestroyReadBackObservationRequest

requireEqual
  :: (Eq value)
  => (value -> value -> AwsEksDestroyRefusal)
  -> value
  -> value
  -> Either AwsEksDestroyRefusal ()
requireEqual mismatch expected actual
  | expected == actual = Right ()
  | otherwise = Left (mismatch expected actual)
