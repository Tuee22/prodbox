{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact Provider-Worker adapter for the registered per-run EBS family.
-- Query scope and lifecycle class come from the static registry; provider
-- evidence may report identities, but it cannot select a family or authorize
-- a mutation without an exact positive observation under the same run scope.
module Prodbox.Lifecycle.Teardown.AwsEbsAdapter
  ( ExactAwsEbsObservationRequest
  , mkExactAwsEbsObservationRequest
  , awsEbsObservationRequestScope
  , awsEbsObservationRequestRevision
  , awsEbsObservationRequestProviderIntent
  , decodeExactAwsEbsObservation
  , ExactAwsEbsReapAuthorization
  , authorizeExactAwsEbsReap
  , awsEbsReapScope
  , awsEbsReapProviderIntent
  , confirmExactAwsEbsAbsence
  , AwsEbsAdapterError (..)
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.EbsVolume
  ( ebsVolumeResourceCoordinate
  , parseTestScopedEbsObservation
  , testEbsObservationVolumeIds
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

data ExactAwsEbsObservationRequest = ExactAwsEbsObservationRequest
  { internalAwsEbsRequestIdentity :: !RegisteredIdentity
  , internalAwsEbsRequestScope :: !ObservationEvidenceScope
  , internalAwsEbsRequestRevision :: !ObservationRevision
  , internalAwsEbsRequestClusterName :: !Text
  , internalAwsEbsRequestProviderIntent :: !ProviderIntent
  , internalAwsEbsRequestProviderCoordinate :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsEbsObservationRequestScope
  :: ExactAwsEbsObservationRequest -> ObservationEvidenceScope
awsEbsObservationRequestScope = internalAwsEbsRequestScope

awsEbsObservationRequestRevision
  :: ExactAwsEbsObservationRequest -> ObservationRevision
awsEbsObservationRequestRevision = internalAwsEbsRequestRevision

awsEbsObservationRequestProviderIntent
  :: ExactAwsEbsObservationRequest -> ProviderIntent
awsEbsObservationRequestProviderIntent = internalAwsEbsRequestProviderIntent

data AwsEbsAdapterError
  = AwsEbsRegistryIdentityMissing
  | AwsEbsRegistryIdentityWrongKind !ResourceKind
  | AwsEbsRegistryCoordinateInvalid !ManagedResourceCoordinate
  | AwsEbsSurfaceMismatch !CleanupSurface !CleanupSurface
  | AwsEbsSurfaceNotAllowed !CleanupSelectionError
  | AwsEbsRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsEbsOperationInvalid !LifecycleOperation
  | AwsEbsAwsScopeMissing
  | AwsEbsProviderCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsEbsProviderResultKindMismatch
  | AwsEbsObservationBindingInvalid !CompleteObservationSetError
  | AwsEbsObservationRefused !(NonEmpty ObservationDecisionRefusal)
  | AwsEbsStillPresent !(NonEmpty RegisteredResourceKey)
  deriving (Eq, Show)

mkExactAwsEbsObservationRequest
  :: CleanupSurfaceWitness surface
  -> ObservationRevision
  -> ObservationEvidenceScope
  -> Either AwsEbsAdapterError ExactAwsEbsObservationRequest
mkExactAwsEbsObservationRequest surface revision scope = do
  identity <- maybe (Left AwsEbsRegistryIdentityMissing) Right identityMaybe
  if registeredIdentityKind identity == VolumeFamily
    then Right ()
    else Left (AwsEbsRegistryIdentityWrongKind (registeredIdentityKind identity))
  let expectedSurface = cleanupSurfaceFromWitness surface
      actualSurface = evidenceCleanupSurface scope
  if actualSurface == expectedSurface
    then Right ()
    else Left (AwsEbsSurfaceMismatch expectedSurface actualSurface)
  case projectCleanupTarget surface identity of
    Left err -> Left (AwsEbsSurfaceNotAllowed err)
    Right _ -> Right ()
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( AwsEbsRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (AwsEbsOperationInvalid (evidenceLifecycleOperation scope))
  case evidenceAwsScope scope of
    Nothing -> Left AwsEbsAwsScopeMissing
    Just _ -> Right ()
  clusterName <- clusterNameFromCoordinate (registeredIdentityCoordinate identity)
  let intent = ObserveTestEbsVolumes clusterName
  Right
    ExactAwsEbsObservationRequest
      { internalAwsEbsRequestIdentity = identity
      , internalAwsEbsRequestScope = scope
      , internalAwsEbsRequestRevision = revision
      , internalAwsEbsRequestClusterName = clusterName
      , internalAwsEbsRequestProviderIntent = intent
      , internalAwsEbsRequestProviderCoordinate = providerIntentCoordinate intent
      }
 where
  identityMaybe = lookupRegisteredIdentity AwsEbsPerRunTestKey

clusterNameFromCoordinate
  :: ManagedResourceCoordinate -> Either AwsEbsAdapterError Text
clusterNameFromCoordinate coordinate = case coordinate of
  AwsEbsPerRunFamilyCoordinate
    "prodbox.io/lifecycle"
    "per-run-test"
    clusterTag
    "owned" ->
      case Text.stripPrefix "kubernetes.io/cluster/" clusterTag of
        Just clusterName | not (Text.null clusterName) -> Right clusterName
        _ -> Left (AwsEbsRegistryCoordinateInvalid coordinate)
  _ -> Left (AwsEbsRegistryCoordinateInvalid coordinate)

-- | Convert one independently signed Provider observation into the flat exact
-- observation algebra. Transport/parse inability is retained as Unobservable;
-- a response for another intent or of a mutation result kind is a binding
-- error and cannot inhabit this request.
decodeExactAwsEbsObservation
  :: ExactAwsEbsObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsEbsAdapterError ExactResourceObservation
decodeExactAwsEbsObservation request providerResult =
  case providerResult of
    Left detail -> Right (unobservable detail)
    Right (ProviderIntentExecutionObserved actualCoordinate evidence)
      | actualCoordinate /= expectedCoordinate ->
          Left
            ( AwsEbsProviderCoordinateMismatch
                expectedCoordinate
                actualCoordinate
            )
      | otherwise -> case parseTestScopedEbsObservation evidence of
          Left detail -> Right (unobservable (Text.pack detail))
          Right observed -> Right (exactObservation observed)
    Right _ -> Left AwsEbsProviderResultKindMismatch
 where
  expectedCoordinate = internalAwsEbsRequestProviderCoordinate request
  identity = internalAwsEbsRequestIdentity request
  observation result =
    exactResourceObservationFor
      identity
      (internalAwsEbsRequestRevision request)
      (internalAwsEbsRequestScope request)
      result
  unobservable detail =
    observation
      ( ExactResourceUnobservable
          (ObservationFailure detail :| [])
      )
  exactObservation observed =
    case testEbsObservationVolumeIds observed of
      [] ->
        observation
          ( ExactResourceAbsent
              ( AbsenceEvidence
                  "provider-worker exact test-scoped EBS family returned its canonical empty set"
              )
          )
      volumeId : remaining ->
        observation
          ( ExactResourcePresent
              ( ExactResourceInventory
                  ( observedIdentity volumeId
                      :| map observedIdentity remaining
                  )
              )
          )
  observedIdentity =
    ObservedResourceIdentity
      . Text.pack
      . ebsVolumeResourceCoordinate

data ExactAwsEbsReapAuthorization = ExactAwsEbsReapAuthorization
  { internalAwsEbsReapScope :: !ObservationEvidenceScope
  , internalAwsEbsReapClusterName :: !Text
  }
  deriving (Eq, Show)

awsEbsReapScope
  :: ExactAwsEbsReapAuthorization -> ObservationEvidenceScope
awsEbsReapScope = internalAwsEbsReapScope

-- | Absence needs no mutation. Presence mints the sole exact reaper
-- authorization. Partial/unobservable evidence refuses and preserves the
-- Provider credential for retry.
authorizeExactAwsEbsReap
  :: ExactAwsEbsObservationRequest
  -> ExactResourceObservation
  -> Either AwsEbsAdapterError (Maybe ExactAwsEbsReapAuthorization)
authorizeExactAwsEbsReap request exact = do
  complete <-
    either
      (Left . AwsEbsObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalAwsEbsRequestScope request)
          [AwsEbsPerRunTestKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> Right Nothing
    SelectedResourcesRequireCleanup _ ->
      Right
        ( Just
            ExactAwsEbsReapAuthorization
              { internalAwsEbsReapScope = internalAwsEbsRequestScope request
              , internalAwsEbsReapClusterName = internalAwsEbsRequestClusterName request
              }
        )
    CompleteObservationsRefused failures ->
      Left (AwsEbsObservationRefused failures)

awsEbsReapProviderIntent :: ExactAwsEbsReapAuthorization -> ProviderIntent
awsEbsReapProviderIntent authorization =
  ReapTestEbsVolumes (internalAwsEbsReapClusterName authorization)

-- | A successful reaper return value is not absence. Only a separate exact
-- read-back for the same request closes the family.
confirmExactAwsEbsAbsence
  :: ExactAwsEbsObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsEbsAdapterError AbsenceEvidence
confirmExactAwsEbsAbsence request result = do
  exact <- decodeExactAwsEbsObservation request result
  complete <-
    either
      (Left . AwsEbsObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalAwsEbsRequestScope request)
          [AwsEbsPerRunTestKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> case exactObservationResult exact of
      ExactResourceAbsent evidence -> Right evidence
      _ -> Left (AwsEbsStillPresent (AwsEbsPerRunTestKey :| []))
    SelectedResourcesRequireCleanup keys -> Left (AwsEbsStillPresent keys)
    CompleteObservationsRefused failures ->
      Left (AwsEbsObservationRefused failures)
