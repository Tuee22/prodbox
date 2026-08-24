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
  , maximumAwsNativeStackFamilyEvidenceBytes
  , maximumAwsNativeStackFamilyIdentities
  )
where

import Data.ByteString qualified as ByteString
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.DnsRecord (hostedZoneIdText)
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
  | AwsNativeStackFamilyEvidenceTooMany !Int !Int
  deriving (Eq, Show)

maximumAwsNativeStackFamilyEvidenceBytes :: Int
maximumAwsNativeStackFamilyEvidenceBytes = 128 * 1024

maximumAwsNativeStackFamilyIdentities :: Int
maximumAwsNativeStackFamilyIdentities = 4096

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
      zone = hostedZoneIdText <$> evidenceAwsDnsZone scope
  if key == AwsEksSubzoneKey && zone == Nothing
    then Left AwsNativeStackFamilyZoneMissing
    else Right ()
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
        [] -> ExactResourceAbsent (AbsenceEvidence evidence)
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
  let evidence =
        Text.unlines
          ( [ "prodbox-native-stack-family/v1"
            , renderBinding ref
            ]
              <> map ("resource|" <>) identities
          )
  if length identities > maximumAwsNativeStackFamilyIdentities
    then
      Left
        ( AwsNativeStackFamilyEvidenceTooMany
            maximumAwsNativeStackFamilyIdentities
            (length identities)
        )
    else Right ()
  let actualBytes = ByteString.length (TextEncoding.encodeUtf8 evidence)
  if actualBytes > maximumAwsNativeStackFamilyEvidenceBytes
    then
      Left
        ( AwsNativeStackFamilyEvidenceTooLarge
            maximumAwsNativeStackFamilyEvidenceBytes
            actualBytes
        )
    else Right evidence

decodeEvidence
  :: ProviderNativeStackFamilyRef
  -> Text
  -> Either AwsNativeStackFamilyAdapterError [Text]
decodeEvidence ref evidence = do
  let actualBytes = ByteString.length (TextEncoding.encodeUtf8 evidence)
  if actualBytes > maximumAwsNativeStackFamilyEvidenceBytes
    then
      Left (AwsNativeStackFamilyEvidenceTooLarge maximumAwsNativeStackFamilyEvidenceBytes actualBytes)
    else Right ()
  case Text.lines evidence of
    header : binding : rows
      | header /= "prodbox-native-stack-family/v1" ->
          Left AwsNativeStackFamilyEvidenceHeaderInvalid
      | binding /= renderBinding ref ->
          Left AwsNativeStackFamilyEvidenceBindingMismatch
      | otherwise -> do
          identities <- mapM decodeRow rows >>= validateIdentities
          if length identities > maximumAwsNativeStackFamilyIdentities
            then
              Left (AwsNativeStackFamilyEvidenceTooMany maximumAwsNativeStackFamilyIdentities (length identities))
            else Right identities
    _ -> Left AwsNativeStackFamilyEvidenceHeaderInvalid
 where
  decodeRow row = case Text.stripPrefix "resource|" row of
    Just identity -> Right identity
    Nothing -> Left (AwsNativeStackFamilyEvidenceRowMalformed row)

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

renderBinding :: ProviderNativeStackFamilyRef -> Text
renderBinding ref =
  Text.intercalate
    "|"
    [ "binding"
    , providerStackRefText (providerNativeStackFamilyStackRef ref)
    , providerNativeStackFamilyAccountId ref
    , providerNativeStackFamilyRegion ref
    , maybe "none" id (providerNativeStackFamilyHostedZoneId ref)
    ]
