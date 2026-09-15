{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Provider-native observation boundary for pre-manifest registered stacks.
-- The request is built only from the registry identity and the exact AWS
-- account/region/zone carried by the cleanup scope.  Evidence is a bounded,
-- canonical list of provider identities; checkpoint bytes and Pulumi outputs
-- cannot enter this codec.
module Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
  ( AwsNativeStackFamilyObservationRequest
  , awsNativeStackFamilyObservationRequestKey
  , awsNativeStackFamilyObservationRequestScope
  , awsNativeStackFamilyObservationRequestIntent
  , awsNativeStackFamilyObservationRequestCoordinate
  , awsNativeStackFamilyObservationRequestRef
  , awsNativeStackFamilyObservationRequestConfig
  , mkAwsNativeStackFamilyObservationRequest
  , decodeAwsNativeStackFamilyObservation
  , decodeAwsNativeStackFamilyEvidence
  , encodeAwsNativeStackFamilyEvidence
  , AwsNativeStackFamilyAdapterError (..)
  )
where

import Data.Bifunctor (first)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.DnsRecord (hostedZoneIdText)
import Prodbox.Lifecycle.ProviderWorker.Evidence
  ( decodeProviderEvidenceText
  , encodeProviderEvidence
  , providerEvidenceFamilyOwnBound
  , providerEvidenceText
  , renderProviderEvidenceRefusal
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

data AwsNativeStackFamilyObservationRequest = AwsNativeStackFamilyObservationRequest
  { internalNativeStackFamilyIdentity :: !RegisteredIdentity
  , internalNativeStackFamilyScope :: !ObservationEvidenceScope
  , internalNativeStackFamilyRevision :: !ObservationRevision
  , internalNativeStackFamilyRef :: !ProviderNativeStackFamilyRef
  , internalNativeStackFamilyConfig :: !ProviderStackConfig
  , internalNativeStackFamilyIntent :: !ProviderIntent
  , internalNativeStackFamilyCoordinate :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsNativeStackFamilyObservationRequestKey
  :: AwsNativeStackFamilyObservationRequest -> RegisteredResourceKey
awsNativeStackFamilyObservationRequestKey =
  registeredIdentityKey . internalNativeStackFamilyIdentity

awsNativeStackFamilyObservationRequestScope
  :: AwsNativeStackFamilyObservationRequest -> ObservationEvidenceScope
awsNativeStackFamilyObservationRequestScope = internalNativeStackFamilyScope

awsNativeStackFamilyObservationRequestIntent
  :: AwsNativeStackFamilyObservationRequest -> ProviderIntent
awsNativeStackFamilyObservationRequestIntent = internalNativeStackFamilyIntent

awsNativeStackFamilyObservationRequestCoordinate
  :: AwsNativeStackFamilyObservationRequest -> ProviderIntentCoordinate
awsNativeStackFamilyObservationRequestCoordinate = internalNativeStackFamilyCoordinate

awsNativeStackFamilyObservationRequestRef
  :: AwsNativeStackFamilyObservationRequest -> ProviderNativeStackFamilyRef
awsNativeStackFamilyObservationRequestRef = internalNativeStackFamilyRef

awsNativeStackFamilyObservationRequestConfig
  :: AwsNativeStackFamilyObservationRequest -> ProviderStackConfig
awsNativeStackFamilyObservationRequestConfig = internalNativeStackFamilyConfig

data AwsNativeStackFamilyAdapterError
  = AwsNativeStackFamilyKeyUnsupported !RegisteredResourceKey
  | AwsNativeStackFamilyIdentityMissing !RegisteredResourceKey
  | AwsNativeStackFamilyKindMismatch !ResourceKind
  | AwsNativeStackFamilySurfaceInvalid !CleanupSurface
  | AwsNativeStackFamilyRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsNativeStackFamilyOperationInvalid !LifecycleOperation
  | AwsNativeStackFamilyAwsScopeMissing
  | AwsNativeStackFamilyZoneMissing
  | AwsNativeStackFamilyRefInvalid !ProviderRefError
  | AwsNativeStackFamilyConfigInvalid !ProviderStackConfigError
  | AwsNativeStackFamilyCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsNativeStackFamilyResultKindMismatch
  | AwsNativeStackFamilyEvidenceTooLarge !Int !Int
  | AwsNativeStackFamilyEvidenceHeaderInvalid
  | AwsNativeStackFamilyEvidenceBindingMismatch
  | AwsNativeStackFamilyEvidenceRowMalformed !Text
  | AwsNativeStackFamilyEvidenceIdentityInvalid !Text
  | AwsNativeStackFamilyEvidenceDuplicate !Text
  | AwsNativeStackFamilyEvidenceRefused !Text
  deriving (Eq, Show)

mkAwsNativeStackFamilyObservationRequest
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ObservationRevision
  -> ProviderStackConfig
  -> Either AwsNativeStackFamilyAdapterError AwsNativeStackFamilyObservationRequest
mkAwsNativeStackFamilyObservationRequest key scope revision config = do
  stackName <- case key of
    AwsEksKey -> Right "aws-eks"
    AwsEksSubzoneKey -> Right "aws-eks-subzone"
    AwsTestKey -> Right "aws-test"
    _ -> Left (AwsNativeStackFamilyKeyUnsupported key)
  identity <-
    maybe (Left (AwsNativeStackFamilyIdentityMissing key)) Right (lookupRegisteredIdentity key)
  if registeredIdentityKind identity == Stack
    then Right ()
    else Left (AwsNativeStackFamilyKindMismatch (registeredIdentityKind identity))
  if cleanupSurfaceAllows (evidenceCleanupSurface scope) identity
    then Right ()
    else Left (AwsNativeStackFamilySurfaceInvalid (evidenceCleanupSurface scope))
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( AwsNativeStackFamilyRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (AwsNativeStackFamilyOperationInvalid (evidenceLifecycleOperation scope))
  awsScope <- maybe (Left AwsNativeStackFamilyAwsScopeMissing) Right (evidenceAwsScope scope)
  stackRef <- either (Left . AwsNativeStackFamilyRefInvalid) Right (mkProviderStackRef stackName)
  let AwsAccountId account = awsScopeAccountId awsScope
      AwsRegion region = awsScopeRegion awsScope
      scopedZone = hostedZoneIdText <$> evidenceAwsDnsZone scope
  zone <- case key of
    AwsEksSubzoneKey -> maybe (Left AwsNativeStackFamilyZoneMissing) (Right . Just) scopedZone
    _ -> Right Nothing
  familyRef <-
    either
      (Left . AwsNativeStackFamilyRefInvalid)
      Right
      (mkProviderNativeStackFamilyRef stackRef account region zone)
  either
    (Left . AwsNativeStackFamilyConfigInvalid)
    Right
    (validateProviderStackConfig stackRef config)
  let intent = ObserveNativeStackFamily familyRef config
  Right
    AwsNativeStackFamilyObservationRequest
      { internalNativeStackFamilyIdentity = identity
      , internalNativeStackFamilyScope = scope
      , internalNativeStackFamilyRevision = revision
      , internalNativeStackFamilyRef = familyRef
      , internalNativeStackFamilyConfig = config
      , internalNativeStackFamilyIntent = intent
      , internalNativeStackFamilyCoordinate = providerIntentCoordinate intent
      }

decodeAwsNativeStackFamilyObservation
  :: AwsNativeStackFamilyObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsNativeStackFamilyAdapterError ExactResourceObservation
decodeAwsNativeStackFamilyObservation request dispatched = do
  executed <- either (const (Left AwsNativeStackFamilyResultKindMismatch)) Right dispatched
  (actualCoordinate, evidence) <- case executed of
    ProviderIntentExecutionObserved coordinate value -> Right (coordinate, value)
    _ -> Left AwsNativeStackFamilyResultKindMismatch
  let expectedCoordinate = awsNativeStackFamilyObservationRequestCoordinate request
  if actualCoordinate == expectedCoordinate
    then Right ()
    else Left (AwsNativeStackFamilyCoordinateMismatch expectedCoordinate actualCoordinate)
  identities <- decodeEvidence (awsNativeStackFamilyObservationRequestRef request) evidence
  let result = case identities of
        [] -> ExactResourceAbsent (providerWorkerAbsence evidence)
        firstIdentity : remaining ->
          ExactResourcePresent
            ( ExactResourceInventory
                (ObservedResourceIdentity firstIdentity :| map ObservedResourceIdentity remaining)
            )
  Right
    ( exactResourceObservationFor
        (internalNativeStackFamilyIdentity request)
        (internalNativeStackFamilyRevision request)
        (internalNativeStackFamilyScope request)
        result
    )

decodeAwsNativeStackFamilyEvidence
  :: ProviderNativeStackFamilyRef
  -> Text
  -> Either AwsNativeStackFamilyAdapterError [Text]
decodeAwsNativeStackFamilyEvidence = decodeEvidence

encodeAwsNativeStackFamilyEvidence
  :: ProviderNativeStackFamilyRef
  -> [Text]
  -> Either AwsNativeStackFamilyAdapterError Text
encodeAwsNativeStackFamilyEvidence ref rawIdentities = do
  identities <- validateIdentities rawIdentities
  first
    (AwsNativeStackFamilyEvidenceRefused . renderProviderEvidenceRefusal)
    ( fmap
        providerEvidenceText
        ( encodeProviderEvidence
            (providerEvidenceFamilyOwnBound nativeStackFamilyEvidenceFamily)
            nativeStackFamilyEvidenceFamily
            (bindingRow ref : map (\identity -> ["resource", identity]) identities)
        )
    )

decodeEvidence
  :: ProviderNativeStackFamilyRef
  -> Text
  -> Either AwsNativeStackFamilyAdapterError [Text]
decodeEvidence ref evidence = do
  rows <-
    first
      AwsNativeStackFamilyEvidenceRefused
      (decodeProviderEvidenceText nativeStackFamilyEvidenceFamily evidence)
  case rows of
    binding : resourceRows
      | binding /= bindingRow ref -> Left AwsNativeStackFamilyEvidenceBindingMismatch
      | otherwise -> mapM decodeRow resourceRows >>= validateIdentities
    _ -> Left AwsNativeStackFamilyEvidenceHeaderInvalid
 where
  decodeRow row = case row of
    ["resource", identity] -> Right identity
    _ -> Left (AwsNativeStackFamilyEvidenceRowMalformed (Text.intercalate "|" row))

validateIdentities :: [Text] -> Either AwsNativeStackFamilyAdapterError [Text]
validateIdentities raw = do
  mapM_ validate raw
  let ordered = sort raw
  case duplicates ordered of
    duplicate : _ -> Left (AwsNativeStackFamilyEvidenceDuplicate duplicate)
    [] -> Right ordered
 where
  validate identity
    | Text.null identity
        || Text.length identity > 2048
        || Text.any (\character -> character == '|' || character == '\n' || character == '\r') identity =
        Left (AwsNativeStackFamilyEvidenceIdentityInvalid identity)
    | otherwise = Right ()
  duplicates values =
    Set.toList
      ( Set.fromList
          [ left
          | (left, right) <- zip values (drop 1 values)
          , left == right
          ]
      )

-- | The binding the evidence echoes: which family this observation is about.
--
-- It sorts first among the rows because @binding@ precedes @resource@, so the
-- canonical ordering the codec imposes puts it where a reader expects without
-- the grammar having to reserve a position for it.
bindingRow :: ProviderNativeStackFamilyRef -> [Text]
bindingRow ref =
  [ "binding"
  , providerStackRefText (providerNativeStackFamilyStackRef ref)
  , providerNativeStackFamilyAccountId ref
  , providerNativeStackFamilyRegion ref
  , maybe "none" id (providerNativeStackFamilyHostedZoneId ref)
  ]
