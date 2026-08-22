{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: exact Provider-Worker adapter for the registered
-- @aws-ebs-volumes-production-retained@ family.
--
-- Until this adapter existed, 'registeredTargetExecutorFor' answered
-- @NoProductionExecutor RetainedEbsFamilyAdapterUnbuilt@ for the retained key:
-- the registered-target interpreter's @VolumeFamily@ arm was guarded on the
-- __per-run__ key, so the retained family had no exact observe, destroy, or
-- absence read-back at all.  That gap is what kept @ExplicitLongLived@ from
-- minting completion evidence, because a surface that mints completion asserts
-- every mandatory absence read-back succeeded.
--
-- The family is bounded by its retention marker and nothing else — no cluster
-- tag — which is exactly what lets it outlive any cluster.  Narrowing it by
-- cluster would exclude the volume a mis-tagged retained family most needs to
-- report.
module Prodbox.Lifecycle.Teardown.AwsRetainedEbsAdapter
  ( ExactAwsRetainedEbsObservationRequest
  , mkExactAwsRetainedEbsObservationRequest
  , awsRetainedEbsObservationRequestScope
  , awsRetainedEbsObservationRequestRevision
  , awsRetainedEbsObservationRequestProviderIntent
  , decodeExactAwsRetainedEbsObservation
  , ExactAwsRetainedEbsReapAuthorization
  , authorizeExactAwsRetainedEbsReap
  , awsRetainedEbsReapScope
  , awsRetainedEbsReapProviderIntent
  , confirmExactAwsRetainedEbsAbsence
  , AwsRetainedEbsAdapterError (..)
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
  , parseRetainedEbsObservation
  , retainedEbsObservationVolumeIds
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

data ExactAwsRetainedEbsObservationRequest
  = ExactAwsRetainedEbsObservationRequest
  { internalRetainedEbsRequestIdentity :: !RegisteredIdentity
  , internalRetainedEbsRequestScope :: !ObservationEvidenceScope
  , internalRetainedEbsRequestRevision :: !ObservationRevision
  , internalRetainedEbsRequestLifecycleValue :: !Text
  , internalRetainedEbsRequestProviderIntent :: !ProviderIntent
  , internalRetainedEbsRequestProviderCoordinate :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsRetainedEbsObservationRequestScope
  :: ExactAwsRetainedEbsObservationRequest -> ObservationEvidenceScope
awsRetainedEbsObservationRequestScope = internalRetainedEbsRequestScope

awsRetainedEbsObservationRequestRevision
  :: ExactAwsRetainedEbsObservationRequest -> ObservationRevision
awsRetainedEbsObservationRequestRevision = internalRetainedEbsRequestRevision

awsRetainedEbsObservationRequestProviderIntent
  :: ExactAwsRetainedEbsObservationRequest -> ProviderIntent
awsRetainedEbsObservationRequestProviderIntent =
  internalRetainedEbsRequestProviderIntent

data AwsRetainedEbsAdapterError
  = AwsRetainedEbsRegistryIdentityMissing
  | AwsRetainedEbsRegistryIdentityWrongKind !ResourceKind
  | AwsRetainedEbsRegistryCoordinateInvalid !ManagedResourceCoordinate
  | AwsRetainedEbsSurfaceMismatch !CleanupSurface !CleanupSurface
  | AwsRetainedEbsSurfaceNotAllowed !CleanupSelectionError
  | AwsRetainedEbsRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsRetainedEbsOperationInvalid !LifecycleOperation
  | AwsRetainedEbsAwsScopeMissing
  | AwsRetainedEbsProviderCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsRetainedEbsProviderResultKindMismatch
  | AwsRetainedEbsObservationBindingInvalid !CompleteObservationSetError
  | AwsRetainedEbsObservationRefused !(NonEmpty ObservationDecisionRefusal)
  | AwsRetainedEbsStillPresent !(NonEmpty RegisteredResourceKey)
  deriving (Eq, Show)

-- | The retained family is @LongLived@, so 'projectCleanupTarget' admits it
-- only on @ExplicitLongLived@ and @TotalDecommission@.  That refusal is the
-- adapter's own bound: no cascade or per-run surface can construct a request
-- for storage those surfaces exist to preserve.
mkExactAwsRetainedEbsObservationRequest
  :: CleanupSurfaceWitness surface
  -> ObservationRevision
  -> ObservationEvidenceScope
  -> Either AwsRetainedEbsAdapterError ExactAwsRetainedEbsObservationRequest
mkExactAwsRetainedEbsObservationRequest surface revision scope = do
  identity <-
    maybe (Left AwsRetainedEbsRegistryIdentityMissing) Right identityMaybe
  if registeredIdentityKind identity == VolumeFamily
    then Right ()
    else
      Left
        ( AwsRetainedEbsRegistryIdentityWrongKind
            (registeredIdentityKind identity)
        )
  let expectedSurface = cleanupSurfaceFromWitness surface
      actualSurface = evidenceCleanupSurface scope
  if actualSurface == expectedSurface
    then Right ()
    else Left (AwsRetainedEbsSurfaceMismatch expectedSurface actualSurface)
  case projectCleanupTarget surface identity of
    Left err -> Left (AwsRetainedEbsSurfaceNotAllowed err)
    Right _ -> Right ()
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( AwsRetainedEbsRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (AwsRetainedEbsOperationInvalid (evidenceLifecycleOperation scope))
  case evidenceAwsScope scope of
    Nothing -> Left AwsRetainedEbsAwsScopeMissing
    Just _ -> Right ()
  lifecycleValue <-
    lifecycleValueFromCoordinate (registeredIdentityCoordinate identity)
  let intent = ObserveRetainedEbsVolumes lifecycleValue
  Right
    ExactAwsRetainedEbsObservationRequest
      { internalRetainedEbsRequestIdentity = identity
      , internalRetainedEbsRequestScope = scope
      , internalRetainedEbsRequestRevision = revision
      , internalRetainedEbsRequestLifecycleValue = lifecycleValue
      , internalRetainedEbsRequestProviderIntent = intent
      , internalRetainedEbsRequestProviderCoordinate =
          providerIntentCoordinate intent
      }
 where
  identityMaybe = lookupRegisteredIdentity AwsEbsProductionRetainedKey

-- | The family bound comes from the static registry coordinate, never from a
-- caller and never from provider evidence.
lifecycleValueFromCoordinate
  :: ManagedResourceCoordinate -> Either AwsRetainedEbsAdapterError Text
lifecycleValueFromCoordinate coordinate = case coordinate of
  AwsEbsRetainedFamilyCoordinate "prodbox.io/lifecycle" tagValue
    | not (Text.null tagValue) -> Right tagValue
  _ -> Left (AwsRetainedEbsRegistryCoordinateInvalid coordinate)

-- | Transport or parse inability stays @Unobservable@; a response bound to
-- another intent, or of a mutation result kind, is a binding error and cannot
-- inhabit this request.
decodeExactAwsRetainedEbsObservation
  :: ExactAwsRetainedEbsObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsRetainedEbsAdapterError ExactResourceObservation
decodeExactAwsRetainedEbsObservation request providerResult =
  case providerResult of
    Left detail -> Right (unobservable detail)
    Right (ProviderIntentExecutionObserved actualCoordinate evidence)
      | actualCoordinate /= expectedCoordinate ->
          Left
            ( AwsRetainedEbsProviderCoordinateMismatch
                expectedCoordinate
                actualCoordinate
            )
      | otherwise -> case parseRetainedEbsObservation evidence of
          Left detail -> Right (unobservable (Text.pack detail))
          Right observed -> Right (exactObservation observed)
    Right _ -> Left AwsRetainedEbsProviderResultKindMismatch
 where
  expectedCoordinate = internalRetainedEbsRequestProviderCoordinate request
  identity = internalRetainedEbsRequestIdentity request
  observation result =
    exactResourceObservationFor
      identity
      (internalRetainedEbsRequestRevision request)
      (internalRetainedEbsRequestScope request)
      result
  unobservable detail =
    observation (ExactResourceUnobservable (ObservationFailure detail :| []))
  exactObservation observed =
    case retainedEbsObservationVolumeIds observed of
      [] ->
        observation
          ( ExactResourceAbsent
              ( AbsenceEvidence
                  "provider-worker exact retained EBS family returned its canonical empty set"
              )
          )
      volumeId : remaining ->
        observation
          ( ExactResourcePresent
              ( ExactResourceInventory
                  (observedIdentity volumeId :| map observedIdentity remaining)
              )
          )
  observedIdentity =
    ObservedResourceIdentity . Text.pack . ebsVolumeResourceCoordinate

data ExactAwsRetainedEbsReapAuthorization = ExactAwsRetainedEbsReapAuthorization
  { internalRetainedEbsReapScope :: !ObservationEvidenceScope
  , internalRetainedEbsReapLifecycleValue :: !Text
  }
  deriving (Eq, Show)

awsRetainedEbsReapScope
  :: ExactAwsRetainedEbsReapAuthorization -> ObservationEvidenceScope
awsRetainedEbsReapScope = internalRetainedEbsReapScope

-- | Absence needs no mutation.  Presence mints the sole exact reaper
-- authorization.  Partial or unobservable evidence refuses and preserves the
-- Provider credential for retry rather than deleting retained storage on a
-- guess.
authorizeExactAwsRetainedEbsReap
  :: ExactAwsRetainedEbsObservationRequest
  -> ExactResourceObservation
  -> Either
       AwsRetainedEbsAdapterError
       (Maybe ExactAwsRetainedEbsReapAuthorization)
authorizeExactAwsRetainedEbsReap request exact = do
  complete <-
    either
      (Left . AwsRetainedEbsObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalRetainedEbsRequestScope request)
          [AwsEbsProductionRetainedKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> Right Nothing
    SelectedResourcesRequireCleanup _ ->
      Right
        ( Just
            ExactAwsRetainedEbsReapAuthorization
              { internalRetainedEbsReapScope =
                  internalRetainedEbsRequestScope request
              , internalRetainedEbsReapLifecycleValue =
                  internalRetainedEbsRequestLifecycleValue request
              }
        )
    CompleteObservationsRefused failures ->
      Left (AwsRetainedEbsObservationRefused failures)

awsRetainedEbsReapProviderIntent
  :: ExactAwsRetainedEbsReapAuthorization -> ProviderIntent
awsRetainedEbsReapProviderIntent authorization =
  ReapRetainedEbsVolumes (internalRetainedEbsReapLifecycleValue authorization)

-- | A successful reaper return value is not absence.  Only a separate exact
-- read-back for the same request closes the family.
confirmExactAwsRetainedEbsAbsence
  :: ExactAwsRetainedEbsObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsRetainedEbsAdapterError AbsenceEvidence
confirmExactAwsRetainedEbsAbsence request result = do
  exact <- decodeExactAwsRetainedEbsObservation request result
  complete <-
    either
      (Left . AwsRetainedEbsObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalRetainedEbsRequestScope request)
          [AwsEbsProductionRetainedKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> case exactObservationResult exact of
      ExactResourceAbsent evidence -> Right evidence
      _ ->
        Left (AwsRetainedEbsStillPresent (AwsEbsProductionRetainedKey :| []))
    SelectedResourcesRequireCleanup keys ->
      Left (AwsRetainedEbsStillPresent keys)
    CompleteObservationsRefused failures ->
      Left (AwsRetainedEbsObservationRefused failures)
