{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: exact Provider-Worker adapter for the registered @dns-aws@
-- validation hosted-zone family.
--
-- Until this adapter existed, no compiled desired-absence program could reach a
-- Route 53 hosted zone at all — no @RegisteredResourceKey@ named one and no
-- @ProviderIntent@ listed or deleted one — so the only thing removing a leaked
-- billable zone was the harness's own always-run sweep. That gap is what Sprint
-- @5.36@ declared as its `**Backward dependency**` on this sprint.
--
-- The family is the registered zone-name prefix and nothing else. The rest of a
-- validation zone's name is a per-run nonce, so no exact name is knowable before
-- the zone exists, and the prefix is stated once in
-- "Prodbox.Lifecycle.OwnedResourceTags" where the creator, the sweep, and the
-- registry all read it.
module Prodbox.Lifecycle.Teardown.AwsRoute53ZoneAdapter
  ( ExactAwsValidationZoneObservationRequest
  , mkExactAwsValidationZoneObservationRequest
  , awsValidationZoneObservationRequestScope
  , awsValidationZoneObservationRequestRevision
  , awsValidationZoneObservationRequestProviderIntent
  , decodeExactAwsValidationZoneObservation
  , ExactAwsValidationZoneReapAuthorization
  , authorizeExactAwsValidationZoneReap
  , awsValidationZoneReapScope
  , awsValidationZoneReapProviderIntent
  , confirmExactAwsValidationZoneAbsence
  , parseValidationZoneObservation
  , AwsValidationZoneAdapterError (..)
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

data ExactAwsValidationZoneObservationRequest
  = ExactAwsValidationZoneObservationRequest
  { internalAwsValidationZoneRequestIdentity :: !RegisteredIdentity
  , internalAwsValidationZoneRequestScope :: !ObservationEvidenceScope
  , internalAwsValidationZoneRequestRevision :: !ObservationRevision
  , internalAwsValidationZoneRequestNamePrefix :: !Text
  , internalAwsValidationZoneRequestProviderIntent :: !ProviderIntent
  , internalAwsValidationZoneRequestProviderCoordinate
      :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsValidationZoneObservationRequestScope
  :: ExactAwsValidationZoneObservationRequest -> ObservationEvidenceScope
awsValidationZoneObservationRequestScope =
  internalAwsValidationZoneRequestScope

awsValidationZoneObservationRequestRevision
  :: ExactAwsValidationZoneObservationRequest -> ObservationRevision
awsValidationZoneObservationRequestRevision =
  internalAwsValidationZoneRequestRevision

awsValidationZoneObservationRequestProviderIntent
  :: ExactAwsValidationZoneObservationRequest -> ProviderIntent
awsValidationZoneObservationRequestProviderIntent =
  internalAwsValidationZoneRequestProviderIntent

data AwsValidationZoneAdapterError
  = AwsValidationZoneRegistryIdentityMissing
  | AwsValidationZoneRegistryIdentityWrongKind !ResourceKind
  | AwsValidationZoneRegistryCoordinateInvalid !ManagedResourceCoordinate
  | AwsValidationZoneSurfaceMismatch !CleanupSurface !CleanupSurface
  | AwsValidationZoneSurfaceNotAllowed !CleanupSelectionError
  | AwsValidationZoneRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsValidationZoneOperationInvalid !LifecycleOperation
  | AwsValidationZoneAwsScopeMissing
  | AwsValidationZoneProviderCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsValidationZoneProviderResultKindMismatch
  | AwsValidationZoneObservationBindingInvalid !CompleteObservationSetError
  | AwsValidationZoneObservationRefused !(NonEmpty ObservationDecisionRefusal)
  | AwsValidationZoneStillPresent !(NonEmpty RegisteredResourceKey)
  deriving (Eq, Show)

mkExactAwsValidationZoneObservationRequest
  :: CleanupSurfaceWitness surface
  -> ObservationRevision
  -> ObservationEvidenceScope
  -> Either
       AwsValidationZoneAdapterError
       ExactAwsValidationZoneObservationRequest
mkExactAwsValidationZoneObservationRequest surface revision scope = do
  identity <-
    maybe (Left AwsValidationZoneRegistryIdentityMissing) Right identityMaybe
  if registeredIdentityKind identity == DnsZoneFamily
    then Right ()
    else
      Left
        ( AwsValidationZoneRegistryIdentityWrongKind
            (registeredIdentityKind identity)
        )
  let expectedSurface = cleanupSurfaceFromWitness surface
      actualSurface = evidenceCleanupSurface scope
  if actualSurface == expectedSurface
    then Right ()
    else Left (AwsValidationZoneSurfaceMismatch expectedSurface actualSurface)
  case projectCleanupTarget surface identity of
    Left err -> Left (AwsValidationZoneSurfaceNotAllowed err)
    Right _ -> Right ()
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( AwsValidationZoneRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (AwsValidationZoneOperationInvalid (evidenceLifecycleOperation scope))
  case evidenceAwsScope scope of
    Nothing -> Left AwsValidationZoneAwsScopeMissing
    Just _ -> Right ()
  namePrefix <- namePrefixFromCoordinate (registeredIdentityCoordinate identity)
  let intent = ObserveValidationHostedZones namePrefix
  Right
    ExactAwsValidationZoneObservationRequest
      { internalAwsValidationZoneRequestIdentity = identity
      , internalAwsValidationZoneRequestScope = scope
      , internalAwsValidationZoneRequestRevision = revision
      , internalAwsValidationZoneRequestNamePrefix = namePrefix
      , internalAwsValidationZoneRequestProviderIntent = intent
      , internalAwsValidationZoneRequestProviderCoordinate =
          providerIntentCoordinate intent
      }
 where
  identityMaybe = lookupRegisteredIdentity AwsDnsValidationZoneKey

namePrefixFromCoordinate
  :: ManagedResourceCoordinate -> Either AwsValidationZoneAdapterError Text
namePrefixFromCoordinate coordinate = case coordinate of
  AwsRoute53ValidationZoneFamilyCoordinate namePrefix
    | not (Text.null namePrefix) -> Right namePrefix
  _ -> Left (AwsValidationZoneRegistryCoordinateInvalid coordinate)

-- | The Provider evidence shape: the echoed family prefix on the first line,
-- then one @\<zone-id\> \<zone-name\>@ line per zone still present.
--
-- Pure and exposed so the decode is exercised without a Provider Worker.
parseValidationZoneObservation :: Text -> Either Text (Text, [Text])
parseValidationZoneObservation evidence = case Text.lines evidence of
  [] -> Left "validation hosted-zone observation carried no family line"
  familyLine : zoneLines ->
    let identities =
          [ zoneIdentity
          | zoneLine <- zoneLines
          , let zoneIdentity = Text.strip zoneLine
          , not (Text.null zoneIdentity)
          ]
     in if Text.null (Text.strip familyLine)
          then Left "validation hosted-zone observation named no family"
          else Right (Text.strip familyLine, identities)

-- | Convert one independently signed Provider observation into the flat exact
-- observation algebra.
--
-- Transport or parse inability stays 'ExactResourceUnobservable'; a response
-- for another intent, of a mutation result kind, or naming another family is a
-- binding error and cannot inhabit this request. A listing this run could not
-- obtain is never an absence.
decodeExactAwsValidationZoneObservation
  :: ExactAwsValidationZoneObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsValidationZoneAdapterError ExactResourceObservation
decodeExactAwsValidationZoneObservation request providerResult =
  case providerResult of
    Left detail -> Right (unobservable detail)
    Right (ProviderIntentExecutionObserved actualCoordinate evidence)
      | actualCoordinate /= expectedCoordinate ->
          Left
            ( AwsValidationZoneProviderCoordinateMismatch
                expectedCoordinate
                actualCoordinate
            )
      | otherwise -> case parseValidationZoneObservation evidence of
          Left detail -> Right (unobservable detail)
          Right (family, _)
            | family /= expectedPrefix ->
                Right
                  ( unobservable
                      ( "validation hosted-zone observation answered for family "
                          <> family
                          <> " rather than "
                          <> expectedPrefix
                      )
                  )
          Right (_, zones) -> Right (exactObservation zones)
    Right _ -> Left AwsValidationZoneProviderResultKindMismatch
 where
  expectedCoordinate = internalAwsValidationZoneRequestProviderCoordinate request
  expectedPrefix = internalAwsValidationZoneRequestNamePrefix request
  identity = internalAwsValidationZoneRequestIdentity request
  observation result =
    exactResourceObservationFor
      identity
      (internalAwsValidationZoneRequestRevision request)
      (internalAwsValidationZoneRequestScope request)
      result
  unobservable detail =
    observation (ExactResourceUnobservable (ObservationFailure detail :| []))
  exactObservation zones = case zones of
    [] ->
      observation
        ( ExactResourceAbsent
            ( AbsenceEvidence
                "provider-worker exact validation hosted-zone family returned its canonical empty set"
            )
        )
    zoneIdentity : remaining ->
      observation
        ( ExactResourcePresent
            ( ExactResourceInventory
                ( ObservedResourceIdentity zoneIdentity
                    :| map ObservedResourceIdentity remaining
                )
            )
        )

data ExactAwsValidationZoneReapAuthorization
  = ExactAwsValidationZoneReapAuthorization
  { internalAwsValidationZoneReapScope :: !ObservationEvidenceScope
  , internalAwsValidationZoneReapNamePrefix :: !Text
  }
  deriving (Eq, Show)

awsValidationZoneReapScope
  :: ExactAwsValidationZoneReapAuthorization -> ObservationEvidenceScope
awsValidationZoneReapScope = internalAwsValidationZoneReapScope

-- | Absence needs no mutation. Presence mints the sole exact reaper
-- authorization. Partial or unobservable evidence refuses and preserves the
-- Provider credential for retry.
authorizeExactAwsValidationZoneReap
  :: ExactAwsValidationZoneObservationRequest
  -> ExactResourceObservation
  -> Either
       AwsValidationZoneAdapterError
       (Maybe ExactAwsValidationZoneReapAuthorization)
authorizeExactAwsValidationZoneReap request exact = do
  complete <-
    either
      (Left . AwsValidationZoneObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalAwsValidationZoneRequestScope request)
          [AwsDnsValidationZoneKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> Right Nothing
    SelectedResourcesRequireCleanup _ ->
      Right
        ( Just
            ExactAwsValidationZoneReapAuthorization
              { internalAwsValidationZoneReapScope =
                  internalAwsValidationZoneRequestScope request
              , internalAwsValidationZoneReapNamePrefix =
                  internalAwsValidationZoneRequestNamePrefix request
              }
        )
    CompleteObservationsRefused failures ->
      Left (AwsValidationZoneObservationRefused failures)

awsValidationZoneReapProviderIntent
  :: ExactAwsValidationZoneReapAuthorization -> ProviderIntent
awsValidationZoneReapProviderIntent authorization =
  ReapValidationHostedZones
    (internalAwsValidationZoneReapNamePrefix authorization)

-- | A successful reaper return value is not absence. Only a separate exact
-- read-back for the same request closes the family.
confirmExactAwsValidationZoneAbsence
  :: ExactAwsValidationZoneObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsValidationZoneAdapterError AbsenceEvidence
confirmExactAwsValidationZoneAbsence request result = do
  exact <- decodeExactAwsValidationZoneObservation request result
  complete <-
    either
      (Left . AwsValidationZoneObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalAwsValidationZoneRequestScope request)
          [AwsDnsValidationZoneKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> case exactObservationResult exact of
      ExactResourceAbsent evidence -> Right evidence
      _ -> Left (AwsValidationZoneStillPresent (AwsDnsValidationZoneKey :| []))
    SelectedResourcesRequireCleanup keys ->
      Left (AwsValidationZoneStillPresent keys)
    CompleteObservationsRefused failures ->
      Left (AwsValidationZoneObservationRefused failures)
