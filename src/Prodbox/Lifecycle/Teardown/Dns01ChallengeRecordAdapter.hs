{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the exact adapter for the registered DNS01 challenge record
-- family.
--
-- It is the first registered family whose two halves take __different
-- authorities__. The observation and the mandatory absence read-back are Route
-- 53 reads issued through the Provider; the removal is not a Provider mutation
-- at all. cert-manager's DNS01 solver owns the @_acme-challenge@ TXT, and a
-- Provider delete would race the solver into rewriting it, so the record is
-- removed by deleting the Kubernetes object that owns it and is then proven
-- absent by an independent read-back. That split is why this module mints an
-- owner-delete authorization rather than a provider reap intent: there is no
-- @Reap@ constructor for it to name.
--
-- The family bound is the record-name prefix, stated once in
-- "Prodbox.Lifecycle.OwnedResourceTags", and the zone comes from the run's
-- 'ObservationEvidenceScope'. A scope that names no zone refuses here rather
-- than defaulting: a challenge record swept in the wrong zone is either a no-op
-- that reads as absence, or a deletion in an operator's parent zone.
module Prodbox.Lifecycle.Teardown.Dns01ChallengeRecordAdapter
  ( ExactDns01ChallengeObservationRequest
  , mkExactDns01ChallengeObservationRequest
  , dns01ChallengeObservationRequestScope
  , dns01ChallengeObservationRequestRevision
  , dns01ChallengeObservationRequestProviderIntent
  , decodeExactDns01ChallengeObservation
  , ExactDns01ChallengeOwnerDeleteAuthorization
  , authorizeExactDns01ChallengeOwnerDelete
  , dns01ChallengeOwnerDeleteScope
  , dns01ChallengeOwnerDeleteHostedZone
  , dns01ChallengeOwnerDeleteRecordNamePrefix
  , dns01ChallengeOwnerDeleteObservedRecords
  , confirmExactDns01ChallengeAbsence
  , parseDns01ChallengeObservation
  , Dns01ChallengeAdapterError (..)
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, hostedZoneIdText)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

data ExactDns01ChallengeObservationRequest
  = ExactDns01ChallengeObservationRequest
  { internalDns01ChallengeRequestIdentity :: !RegisteredIdentity
  , internalDns01ChallengeRequestScope :: !ObservationEvidenceScope
  , internalDns01ChallengeRequestRevision :: !ObservationRevision
  , internalDns01ChallengeRequestHostedZone :: !HostedZoneId
  , internalDns01ChallengeRequestRecordNamePrefix :: !Text
  , internalDns01ChallengeRequestProviderIntent :: !ProviderIntent
  , internalDns01ChallengeRequestProviderCoordinate :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

dns01ChallengeObservationRequestScope
  :: ExactDns01ChallengeObservationRequest -> ObservationEvidenceScope
dns01ChallengeObservationRequestScope = internalDns01ChallengeRequestScope

dns01ChallengeObservationRequestRevision
  :: ExactDns01ChallengeObservationRequest -> ObservationRevision
dns01ChallengeObservationRequestRevision = internalDns01ChallengeRequestRevision

dns01ChallengeObservationRequestProviderIntent
  :: ExactDns01ChallengeObservationRequest -> ProviderIntent
dns01ChallengeObservationRequestProviderIntent =
  internalDns01ChallengeRequestProviderIntent

data Dns01ChallengeAdapterError
  = Dns01ChallengeRegistryIdentityMissing
  | Dns01ChallengeRegistryIdentityWrongKind !ResourceKind
  | Dns01ChallengeRegistryCoordinateInvalid !ManagedResourceCoordinate
  | Dns01ChallengeSurfaceMismatch !CleanupSurface !CleanupSurface
  | Dns01ChallengeSurfaceNotAllowed !CleanupSelectionError
  | Dns01ChallengeRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | Dns01ChallengeOperationInvalid !LifecycleOperation
  | Dns01ChallengeAwsScopeMissing
  | -- | The run named no DNS hosted zone, so this family has no coordinate.
    -- Refusing is the whole point: the alternative is scanning or deleting in
    -- a zone nobody named.
    Dns01ChallengeHostedZoneMissing
  | Dns01ChallengeProviderCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | Dns01ChallengeProviderResultKindMismatch
  | Dns01ChallengeObservationBindingInvalid !CompleteObservationSetError
  | Dns01ChallengeObservationRefused !(NonEmpty ObservationDecisionRefusal)
  | Dns01ChallengeStillPresent !(NonEmpty RegisteredResourceKey)
  deriving (Eq, Show)

mkExactDns01ChallengeObservationRequest
  :: CleanupSurfaceWitness surface
  -> ObservationRevision
  -> ObservationEvidenceScope
  -> Either Dns01ChallengeAdapterError ExactDns01ChallengeObservationRequest
mkExactDns01ChallengeObservationRequest surface revision scope = do
  identity <-
    maybe (Left Dns01ChallengeRegistryIdentityMissing) Right identityMaybe
  if registeredIdentityKind identity == DnsRecordFamily
    then Right ()
    else
      Left
        ( Dns01ChallengeRegistryIdentityWrongKind
            (registeredIdentityKind identity)
        )
  let expectedSurface = cleanupSurfaceFromWitness surface
      actualSurface = evidenceCleanupSurface scope
  if actualSurface == expectedSurface
    then Right ()
    else Left (Dns01ChallengeSurfaceMismatch expectedSurface actualSurface)
  case projectCleanupTarget surface identity of
    Left err -> Left (Dns01ChallengeSurfaceNotAllowed err)
    Right _ -> Right ()
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( Dns01ChallengeRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (Dns01ChallengeOperationInvalid (evidenceLifecycleOperation scope))
  case evidenceAwsScope scope of
    Nothing -> Left Dns01ChallengeAwsScopeMissing
    Just _ -> Right ()
  hostedZone <- case evidenceAwsDnsZone scope of
    Nothing -> Left Dns01ChallengeHostedZoneMissing
    Just zone -> Right zone
  recordNamePrefix <-
    recordNamePrefixFromCoordinate (registeredIdentityCoordinate identity)
  let intent =
        ObserveDns01ChallengeRecords
          (hostedZoneIdText hostedZone)
          recordNamePrefix
  Right
    ExactDns01ChallengeObservationRequest
      { internalDns01ChallengeRequestIdentity = identity
      , internalDns01ChallengeRequestScope = scope
      , internalDns01ChallengeRequestRevision = revision
      , internalDns01ChallengeRequestHostedZone = hostedZone
      , internalDns01ChallengeRequestRecordNamePrefix = recordNamePrefix
      , internalDns01ChallengeRequestProviderIntent = intent
      , internalDns01ChallengeRequestProviderCoordinate =
          providerIntentCoordinate intent
      }
 where
  identityMaybe = lookupRegisteredIdentity AwsDns01ChallengeRecordKey

recordNamePrefixFromCoordinate
  :: ManagedResourceCoordinate -> Either Dns01ChallengeAdapterError Text
recordNamePrefixFromCoordinate coordinate = case coordinate of
  AwsRoute53Dns01ChallengeRecordFamilyCoordinate recordNamePrefix
    | not (Text.null recordNamePrefix) -> Right recordNamePrefix
  _ -> Left (Dns01ChallengeRegistryCoordinateInvalid coordinate)

-- | The Provider evidence shape: the echoed @\<zone-id\> \<record-prefix\>@
-- family line, then one record name per line for every challenge TXT still
-- present.
--
-- Pure and exposed so the decode is exercised without a Provider Worker.
parseDns01ChallengeObservation :: Text -> Either Text (Text, [Text])
parseDns01ChallengeObservation evidence = case Text.lines evidence of
  [] -> Left "DNS01 challenge observation carried no family line"
  familyLine : recordLines ->
    let records =
          [ recordName
          | recordLine <- recordLines
          , let recordName = Text.strip recordLine
          , not (Text.null recordName)
          ]
     in if Text.null (Text.strip familyLine)
          then Left "DNS01 challenge observation named no family"
          else Right (Text.strip familyLine, records)

-- | Convert one independently signed Provider observation into the flat exact
-- observation algebra.
--
-- Transport or parse inability stays 'ExactResourceUnobservable'; a response
-- for another intent or of a mutation result kind is a binding error and cannot
-- inhabit this request. A scan this run could not obtain is never an absence.
decodeExactDns01ChallengeObservation
  :: ExactDns01ChallengeObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either Dns01ChallengeAdapterError ExactResourceObservation
decodeExactDns01ChallengeObservation request providerResult =
  case providerResult of
    Left detail -> Right (unobservable detail)
    Right (ProviderIntentExecutionObserved actualCoordinate evidence)
      | actualCoordinate /= expectedCoordinate ->
          Left
            ( Dns01ChallengeProviderCoordinateMismatch
                expectedCoordinate
                actualCoordinate
            )
      | otherwise -> case parseDns01ChallengeObservation evidence of
          Left detail -> Right (unobservable detail)
          Right (family, _)
            | family /= expectedFamily ->
                Right
                  ( unobservable
                      ( "DNS01 challenge observation answered for family "
                          <> family
                          <> " rather than "
                          <> expectedFamily
                      )
                  )
          Right (_, records) -> Right (exactObservation records)
    Right _ -> Left Dns01ChallengeProviderResultKindMismatch
 where
  expectedCoordinate = internalDns01ChallengeRequestProviderCoordinate request
  expectedFamily =
    hostedZoneIdText (internalDns01ChallengeRequestHostedZone request)
      <> " "
      <> internalDns01ChallengeRequestRecordNamePrefix request
  identity = internalDns01ChallengeRequestIdentity request
  observation result =
    exactResourceObservationFor
      identity
      (internalDns01ChallengeRequestRevision request)
      (internalDns01ChallengeRequestScope request)
      result
  unobservable detail =
    observation (ExactResourceUnobservable (ObservationFailure detail :| []))
  exactObservation records = case records of
    [] ->
      observation
        ( ExactResourceAbsent
            ( AbsenceEvidence
                "provider-worker exact DNS01 challenge record family returned its canonical empty set"
            )
        )
    recordName : remaining ->
      observation
        ( ExactResourcePresent
            ( ExactResourceInventory
                ( ObservedResourceIdentity recordName
                    :| map ObservedResourceIdentity remaining
                )
            )
        )

-- | The sole authorization for the Kubernetes owner delete.
--
-- It carries the observed record names as well as the family bound, because the
-- owner-delete boundary needs to know /which/ certificates are in flight, and
-- deriving that from anything but the observation this authorization was minted
-- from would let a delete outrun the evidence that justified it.
data ExactDns01ChallengeOwnerDeleteAuthorization
  = ExactDns01ChallengeOwnerDeleteAuthorization
  { internalDns01ChallengeOwnerDeleteScope :: !ObservationEvidenceScope
  , internalDns01ChallengeOwnerDeleteHostedZone :: !HostedZoneId
  , internalDns01ChallengeOwnerDeleteRecordNamePrefix :: !Text
  , internalDns01ChallengeOwnerDeleteObservedRecords :: !(NonEmpty Text)
  }
  deriving (Eq, Show)

dns01ChallengeOwnerDeleteScope
  :: ExactDns01ChallengeOwnerDeleteAuthorization -> ObservationEvidenceScope
dns01ChallengeOwnerDeleteScope = internalDns01ChallengeOwnerDeleteScope

dns01ChallengeOwnerDeleteHostedZone
  :: ExactDns01ChallengeOwnerDeleteAuthorization -> HostedZoneId
dns01ChallengeOwnerDeleteHostedZone = internalDns01ChallengeOwnerDeleteHostedZone

dns01ChallengeOwnerDeleteRecordNamePrefix
  :: ExactDns01ChallengeOwnerDeleteAuthorization -> Text
dns01ChallengeOwnerDeleteRecordNamePrefix =
  internalDns01ChallengeOwnerDeleteRecordNamePrefix

dns01ChallengeOwnerDeleteObservedRecords
  :: ExactDns01ChallengeOwnerDeleteAuthorization -> NonEmpty Text
dns01ChallengeOwnerDeleteObservedRecords =
  internalDns01ChallengeOwnerDeleteObservedRecords

-- | Absence needs no owner delete. Presence mints the sole authorization.
-- Partial or unobservable evidence refuses, which preserves both the Provider
-- credential and the cert-manager objects for a retry.
authorizeExactDns01ChallengeOwnerDelete
  :: ExactDns01ChallengeObservationRequest
  -> ExactResourceObservation
  -> Either
       Dns01ChallengeAdapterError
       (Maybe ExactDns01ChallengeOwnerDeleteAuthorization)
authorizeExactDns01ChallengeOwnerDelete request exact = do
  complete <-
    either
      (Left . Dns01ChallengeObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalDns01ChallengeRequestScope request)
          [AwsDns01ChallengeRecordKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> Right Nothing
    SelectedResourcesRequireCleanup _ -> case exactObservationResult exact of
      ExactResourcePresent (ExactResourceInventory identities) ->
        Right
          ( Just
              ExactDns01ChallengeOwnerDeleteAuthorization
                { internalDns01ChallengeOwnerDeleteScope =
                    internalDns01ChallengeRequestScope request
                , internalDns01ChallengeOwnerDeleteHostedZone =
                    internalDns01ChallengeRequestHostedZone request
                , internalDns01ChallengeOwnerDeleteRecordNamePrefix =
                    internalDns01ChallengeRequestRecordNamePrefix request
                , internalDns01ChallengeOwnerDeleteObservedRecords =
                    fmap
                      (\(ObservedResourceIdentity value) -> value)
                      identities
                }
          )
      -- The decision said cleanup is required, so the observation is present.
      -- Anything else here would be the two disagreeing, which is a refusal
      -- rather than a delete over evidence nobody produced.
      _ -> Left (Dns01ChallengeStillPresent (AwsDns01ChallengeRecordKey :| []))
    CompleteObservationsRefused failures ->
      Left (Dns01ChallengeObservationRefused failures)

-- | A successful owner delete is not absence. Only a separate exact read-back
-- for the same request closes the family — and because cert-manager removes the
-- record asynchronously once its object is gone, that separation is load-bearing
-- rather than ceremonial.
confirmExactDns01ChallengeAbsence
  :: ExactDns01ChallengeObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either Dns01ChallengeAdapterError AbsenceEvidence
confirmExactDns01ChallengeAbsence request result = do
  exact <- decodeExactDns01ChallengeObservation request result
  complete <-
    either
      (Left . Dns01ChallengeObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalDns01ChallengeRequestScope request)
          [AwsDns01ChallengeRecordKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> case exactObservationResult exact of
      ExactResourceAbsent evidence -> Right evidence
      _ -> Left (Dns01ChallengeStillPresent (AwsDns01ChallengeRecordKey :| []))
    SelectedResourcesRequireCleanup keys ->
      Left (Dns01ChallengeStillPresent keys)
    CompleteObservationsRefused failures ->
      Left (Dns01ChallengeObservationRefused failures)
