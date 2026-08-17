{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact Provider-Worker adapter for the registered EKS control plane.
-- Generic Pulumi stack evidence is deliberately insufficient here: the EKS
-- drain path must be bound to the exact account, region, cluster name, and ARN
-- that the Provider observed immediately before it issued client authority.
module Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( AwsEksObservationPurpose (..)
  , ExactAwsEksObservationRequest
  , mkAwsEksDecisionObservationRequest
  , mkAwsEksDesiredAbsenceReadBackRequest
  , awsEksObservationRequestKey
  , awsEksObservationRequestScope
  , awsEksObservationRequestRevision
  , awsEksObservationRequestClusterName
  , awsEksObservationRequestProviderIntent
  , awsEksObservationRequestProviderCoordinate
  , VerifiedAwsEksObservation
  , verifiedAwsEksExactObservation
  , verifiedAwsEksClusterArn
  , AwsEksObservationDecode (..)
  , awsEksObservationDecodeObservation
  , decodeAwsEksObservation
  , AwsEksAdapterError (..)
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjectionError
  , validateEksClusterArnBinding
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Infra.AwsEksTestStack (awsEksCanonicalClusterName)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderRefError
  , mkEksClusterIdentityRequest
  , mkProviderStackRef
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

data AwsEksObservationPurpose
  = ObserveEksForDecision
  | ReadBackEksDesiredAbsent

data ExactAwsEksObservationRequest (purpose :: AwsEksObservationPurpose)
  = ExactAwsEksObservationRequest
      !RegisteredIdentity
      !ObservationEvidenceScope
      !ObservationRevision
      !Text
      !ProviderIntent
      !ProviderIntentCoordinate
  deriving (Eq, Show)

awsEksObservationRequestKey
  :: ExactAwsEksObservationRequest purpose -> RegisteredResourceKey
awsEksObservationRequestKey request =
  registeredIdentityKey (requestIdentity request)

awsEksObservationRequestScope
  :: ExactAwsEksObservationRequest purpose -> ObservationEvidenceScope
awsEksObservationRequestScope (ExactAwsEksObservationRequest _ scope _ _ _ _) = scope

awsEksObservationRequestRevision
  :: ExactAwsEksObservationRequest purpose -> ObservationRevision
awsEksObservationRequestRevision
  (ExactAwsEksObservationRequest _ _ revision _ _ _) = revision

awsEksObservationRequestClusterName
  :: ExactAwsEksObservationRequest purpose -> Text
awsEksObservationRequestClusterName
  (ExactAwsEksObservationRequest _ _ _ clusterName _ _) = clusterName

awsEksObservationRequestProviderIntent
  :: ExactAwsEksObservationRequest purpose -> ProviderIntent
awsEksObservationRequestProviderIntent
  (ExactAwsEksObservationRequest _ _ _ _ intent _) = intent

awsEksObservationRequestProviderCoordinate
  :: ExactAwsEksObservationRequest purpose -> ProviderIntentCoordinate
awsEksObservationRequestProviderCoordinate
  (ExactAwsEksObservationRequest _ _ _ _ _ coordinate) = coordinate

data AwsEksAdapterError
  = AwsEksRegistryIdentityMissing
  | AwsEksRegistryIdentityWrongKind !ResourceKind
  | AwsEksRegistryCoordinateInvalid !ManagedResourceCoordinate
  | AwsEksSurfaceNotAllowed !CleanupSelectionError
  | AwsEksRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsEksOperationInvalid !LifecycleOperation
  | AwsEksAwsScopeMissing
  | AwsEksProviderRefInvalid !ProviderRefError
  | AwsEksRequestInvalid !ProviderRefError
  | AwsEksProviderCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsEksProviderResultKindMismatch
  | AwsEksEvidenceNotRecognized !Text
  | AwsEksClusterArnInvalid !EksClientAuthProjectionError
  deriving (Eq, Show)

mkAwsEksDecisionObservationRequest
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> Either
       AwsEksAdapterError
       (ExactAwsEksObservationRequest 'ObserveEksForDecision)
mkAwsEksDecisionObservationRequest = mkAwsEksObservationRequest

mkAwsEksDesiredAbsenceReadBackRequest
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> Either
       AwsEksAdapterError
       (ExactAwsEksObservationRequest 'ReadBackEksDesiredAbsent)
mkAwsEksDesiredAbsenceReadBackRequest = mkAwsEksObservationRequest

mkAwsEksObservationRequest
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> Either AwsEksAdapterError (ExactAwsEksObservationRequest purpose)
mkAwsEksObservationRequest revision scope = do
  identity <-
    maybe
      (Left AwsEksRegistryIdentityMissing)
      Right
      (lookupRegisteredIdentity AwsEksKey)
  if registeredIdentityKind identity == Stack
    then Right ()
    else Left (AwsEksRegistryIdentityWrongKind (registeredIdentityKind identity))
  validateRegistryCoordinate (registeredIdentityCoordinate identity)
  validateSurface scope identity
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( AwsEksRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (AwsEksOperationInvalid (evidenceLifecycleOperation scope))
  AwsScope (AwsAccountId accountId) (AwsRegion region) <-
    maybe (Left AwsEksAwsScopeMissing) Right (evidenceAwsScope scope)
  stackRef <-
    either
      (Left . AwsEksProviderRefInvalid)
      Right
      (mkProviderStackRef "aws-eks")
  let clusterName = Text.pack awsEksCanonicalClusterName
  request <-
    either
      (Left . AwsEksRequestInvalid)
      Right
      (mkEksClusterIdentityRequest stackRef accountId region clusterName)
  let intent = ObserveEksClusterIdentity request
  Right
    ( ExactAwsEksObservationRequest
        identity
        scope
        revision
        clusterName
        intent
        (providerIntentCoordinate intent)
    )

-- | Opaque evidence that the Provider result matched the exact request and
-- used the closed absence/ARN grammar.  A present value therefore carries the
-- exact ARN that later client-auth projection and drain evidence must match.
data VerifiedAwsEksObservation (purpose :: AwsEksObservationPurpose)
  = VerifiedAwsEksObservation
      !(ExactAwsEksObservationRequest purpose)
      !ExactResourceObservation
      !(Maybe Text)
  deriving (Eq, Show)

verifiedAwsEksExactObservation
  :: VerifiedAwsEksObservation purpose -> ExactResourceObservation
verifiedAwsEksExactObservation (VerifiedAwsEksObservation _ observation _) = observation

verifiedAwsEksClusterArn :: VerifiedAwsEksObservation purpose -> Maybe Text
verifiedAwsEksClusterArn (VerifiedAwsEksObservation _ _ clusterArn) = clusterArn

data AwsEksObservationDecode (purpose :: AwsEksObservationPurpose)
  = AwsEksObservationDecoded !(VerifiedAwsEksObservation purpose)
  | AwsEksObservationRejected !AwsEksAdapterError !ExactResourceObservation
  deriving (Eq, Show)

awsEksObservationDecodeObservation
  :: AwsEksObservationDecode purpose -> ExactResourceObservation
awsEksObservationDecodeObservation decoded = case decoded of
  AwsEksObservationDecoded verified -> verifiedAwsEksExactObservation verified
  AwsEksObservationRejected _ observation -> observation

decodeAwsEksObservation
  :: ExactAwsEksObservationRequest purpose
  -> Either Text ProviderIntentExecutionResult
  -> AwsEksObservationDecode purpose
decodeAwsEksObservation request providerResult = case providerResult of
  Left detail -> rejected (AwsEksEvidenceNotRecognized detail)
  Right result
    | executionCoordinate result /= expectedCoordinate ->
        rejected
          ( AwsEksProviderCoordinateMismatch
              expectedCoordinate
              (executionCoordinate result)
          )
  Right (ProviderIntentExecutionObserved _ evidence)
    | evidence == absentEvidence ->
        decoded
          ( ExactResourceAbsent
              (AbsenceEvidence "Provider EKS DescribeCluster returned exact not-found evidence")
          )
          Nothing
    | Just clusterArn <- Text.stripPrefix arnPrefix evidence ->
        case validateArn clusterArn of
          Left err -> rejected err
          Right () ->
            decoded
              ( ExactResourcePresent
                  (ExactResourceInventory (ObservedResourceIdentity clusterArn :| []))
              )
              (Just clusterArn)
    | otherwise -> rejected (AwsEksEvidenceNotRecognized evidence)
  Right _ -> rejected AwsEksProviderResultKindMismatch
 where
  expectedCoordinate = awsEksObservationRequestProviderCoordinate request
  exactObservation = observationForRequest request
  decoded result clusterArn =
    AwsEksObservationDecoded
      (VerifiedAwsEksObservation request (exactObservation result) clusterArn)
  rejected err =
    AwsEksObservationRejected
      err
      ( exactObservation
          ( ExactResourceUnobservable
              (ObservationFailure (renderAdapterError err) :| [])
          )
      )
  validateArn clusterArn = do
    AwsScope (AwsAccountId accountId) (AwsRegion region) <-
      maybe (Left AwsEksAwsScopeMissing) Right (evidenceAwsScope (awsEksObservationRequestScope request))
    either
      (Left . AwsEksClusterArnInvalid)
      Right
      ( validateEksClusterArnBinding
          accountId
          region
          (awsEksObservationRequestClusterName request)
          clusterArn
      )

absentEvidence :: Text
absentEvidence = "registered EKS cluster is absent"

arnPrefix :: Text
arnPrefix = "eks-cluster-arn:"

executionCoordinate :: ProviderIntentExecutionResult -> ProviderIntentCoordinate
executionCoordinate executionResult = case executionResult of
  ProviderIntentExecutionApplied coordinate _ -> coordinate
  ProviderIntentExecutionAlreadySatisfied coordinate _ -> coordinate
  ProviderIntentExecutionObserved coordinate _ -> coordinate

observationForRequest
  :: ExactAwsEksObservationRequest purpose
  -> ExactObservationResult
  -> ExactResourceObservation
observationForRequest request =
  exactResourceObservationFor
    (requestIdentity request)
    (awsEksObservationRequestRevision request)
    (awsEksObservationRequestScope request)

requestIdentity
  :: ExactAwsEksObservationRequest purpose -> RegisteredIdentity
requestIdentity (ExactAwsEksObservationRequest identity _ _ _ _ _) = identity

validateRegistryCoordinate
  :: ManagedResourceCoordinate -> Either AwsEksAdapterError ()
validateRegistryCoordinate coordinate = case coordinate of
  AwsPulumiStackCoordinate "prodbox-aws-eks-test" "aws-eks-test" -> Right ()
  _ -> Left (AwsEksRegistryCoordinateInvalid coordinate)

validateSurface
  :: ObservationEvidenceScope
  -> RegisteredIdentity
  -> Either AwsEksAdapterError ()
validateSurface scope identity = case evidenceCleanupSurface scope of
  LocalOnly -> ignoreCleanupProjection (projectCleanupTarget LocalOnlySurface identity)
  Cascade -> ignoreCleanupProjection (projectCleanupTarget CascadeSurface identity)
  ExplicitPerRun ->
    ignoreCleanupProjection (projectCleanupTarget ExplicitPerRunSurface identity)
  OperationalTeardown ->
    ignoreCleanupProjection (projectCleanupTarget OperationalTeardownSurface identity)
  ExplicitLongLived ->
    ignoreCleanupProjection (projectCleanupTarget ExplicitLongLivedSurface identity)
  TotalDecommission ->
    ignoreCleanupProjection (projectCleanupTarget TotalDecommissionSurface identity)

ignoreCleanupProjection
  :: Either CleanupSelectionError target
  -> Either AwsEksAdapterError ()
ignoreCleanupProjection =
  either
    (Left . AwsEksSurfaceNotAllowed)
    (const (Right ()))

renderAdapterError :: AwsEksAdapterError -> Text
renderAdapterError = Text.take 512 . Text.pack . show
