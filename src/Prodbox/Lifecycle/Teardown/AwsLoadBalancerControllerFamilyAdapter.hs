{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact adapter for the AWS Load Balancer Controller public-edge family.
-- The family is addressed by one deterministic load-balancer name plus the
-- complete tag set receipt-committed before the Kubernetes owner is enabled.
module Prodbox.Lifecycle.Teardown.AwsLoadBalancerControllerFamilyAdapter
  ( ExactAwsLoadBalancerControllerFamilyObservationRequest
  , mkExactAwsLoadBalancerControllerFamilyObservationRequest
  , awsLoadBalancerControllerFamilyObservationRequestScope
  , awsLoadBalancerControllerFamilyObservationRequestRevision
  , awsLoadBalancerControllerFamilyObservationRequestProviderIntent
  , decodeExactAwsLoadBalancerControllerFamilyObservation
  , ExactAwsLoadBalancerControllerFamilyReapAuthorization
  , authorizeExactAwsLoadBalancerControllerFamilyReap
  , awsLoadBalancerControllerFamilyReapScope
  , awsLoadBalancerControllerFamilyReapProviderIntent
  , confirmExactAwsLoadBalancerControllerFamilyAbsence
  , parseAwsLoadBalancerControllerFamilyObservation
  , awsLoadBalancerControllerObservationArns
  , AwsLoadBalancerControllerFamilyAdapterError (..)
  )
where

import Data.List (nub, sort)
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

data ExactAwsLoadBalancerControllerFamilyObservationRequest
  = ExactAwsLoadBalancerControllerFamilyObservationRequest
  { internalLbcRequestIdentity :: !RegisteredIdentity
  , internalLbcRequestScope :: !ObservationEvidenceScope
  , internalLbcRequestRevision :: !ObservationRevision
  , internalLbcRequestName :: !Text
  , internalLbcRequestTags :: ![(Text, Text)]
  , internalLbcRequestIntent :: !ProviderIntent
  , internalLbcRequestCoordinate :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsLoadBalancerControllerFamilyObservationRequestScope
  :: ExactAwsLoadBalancerControllerFamilyObservationRequest
  -> ObservationEvidenceScope
awsLoadBalancerControllerFamilyObservationRequestScope = internalLbcRequestScope

awsLoadBalancerControllerFamilyObservationRequestRevision
  :: ExactAwsLoadBalancerControllerFamilyObservationRequest
  -> ObservationRevision
awsLoadBalancerControllerFamilyObservationRequestRevision = internalLbcRequestRevision

awsLoadBalancerControllerFamilyObservationRequestProviderIntent
  :: ExactAwsLoadBalancerControllerFamilyObservationRequest -> ProviderIntent
awsLoadBalancerControllerFamilyObservationRequestProviderIntent = internalLbcRequestIntent

data AwsLoadBalancerControllerFamilyAdapterError
  = AwsLoadBalancerControllerFamilyRegistryIdentityMissing
  | AwsLoadBalancerControllerFamilyRegistryIdentityWrongKind !ResourceKind
  | AwsLoadBalancerControllerFamilyRegistryCoordinateInvalid !ManagedResourceCoordinate
  | AwsLoadBalancerControllerFamilySurfaceMismatch !CleanupSurface !CleanupSurface
  | AwsLoadBalancerControllerFamilySurfaceNotAllowed !CleanupSelectionError
  | AwsLoadBalancerControllerFamilyRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsLoadBalancerControllerFamilyOperationInvalid !LifecycleOperation
  | AwsLoadBalancerControllerFamilyAwsScopeMissing
  | AwsLoadBalancerControllerFamilyProviderCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsLoadBalancerControllerFamilyProviderResultKindMismatch
  | AwsLoadBalancerControllerFamilyObservationBindingInvalid !CompleteObservationSetError
  | AwsLoadBalancerControllerFamilyObservationRefused
      !(NonEmpty ObservationDecisionRefusal)
  | AwsLoadBalancerControllerFamilyStillPresent
      !(NonEmpty RegisteredResourceKey)
  deriving (Eq, Show)

mkExactAwsLoadBalancerControllerFamilyObservationRequest
  :: CleanupSurfaceWitness surface
  -> ObservationRevision
  -> ObservationEvidenceScope
  -> Either
       AwsLoadBalancerControllerFamilyAdapterError
       ExactAwsLoadBalancerControllerFamilyObservationRequest
mkExactAwsLoadBalancerControllerFamilyObservationRequest surface revision scope = do
  identity <-
    maybe
      (Left AwsLoadBalancerControllerFamilyRegistryIdentityMissing)
      Right
      (lookupRegisteredIdentity AwsEksLoadBalancerControllerFamilyKey)
  if registeredIdentityKind identity == ControllerFamily
    then Right ()
    else
      Left
        ( AwsLoadBalancerControllerFamilyRegistryIdentityWrongKind
            (registeredIdentityKind identity)
        )
  let expectedSurface = cleanupSurfaceFromWitness surface
      actualSurface = evidenceCleanupSurface scope
  if actualSurface == expectedSurface
    then Right ()
    else
      Left
        (AwsLoadBalancerControllerFamilySurfaceMismatch expectedSurface actualSurface)
  case projectCleanupTarget surface identity of
    Left err -> Left (AwsLoadBalancerControllerFamilySurfaceNotAllowed err)
    Right _ -> Right ()
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( AwsLoadBalancerControllerFamilyRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else
      Left
        ( AwsLoadBalancerControllerFamilyOperationInvalid
            (evidenceLifecycleOperation scope)
        )
  case evidenceAwsScope scope of
    Nothing -> Left AwsLoadBalancerControllerFamilyAwsScopeMissing
    Just _ -> Right ()
  (name, tags) <- familyFromCoordinate (registeredIdentityCoordinate identity)
  let intent = ObserveEksLoadBalancerControllerFamily name (renderTags tags)
  Right
    ExactAwsLoadBalancerControllerFamilyObservationRequest
      { internalLbcRequestIdentity = identity
      , internalLbcRequestScope = scope
      , internalLbcRequestRevision = revision
      , internalLbcRequestName = name
      , internalLbcRequestTags = tags
      , internalLbcRequestIntent = intent
      , internalLbcRequestCoordinate = providerIntentCoordinate intent
      }

familyFromCoordinate
  :: ManagedResourceCoordinate
  -> Either AwsLoadBalancerControllerFamilyAdapterError (Text, [(Text, Text)])
familyFromCoordinate coordinate = case coordinate of
  AwsLoadBalancerControllerFamilyCoordinate ownerCluster name tags
    | ownerCluster == awsEksProvisionedClusterName
    , name == awsEksLoadBalancerControllerName
    , tags == awsEksLoadBalancerControllerTags
    , not (Text.null name)
    , not (null tags)
    , tags == sort tags
    , length (map fst tags) == length (nub (map fst tags)) ->
        Right (name, tags)
  _ -> Left (AwsLoadBalancerControllerFamilyRegistryCoordinateInvalid coordinate)

renderTags :: [(Text, Text)] -> Text
renderTags = Text.intercalate "|" . map (\(key, value) -> key <> "=" <> value)

data LoadBalancerControllerMemberKind
  = LoadBalancerMember
  | ListenerMember
  | TargetGroupMember
  | SecurityGroupMember
  deriving (Eq, Ord, Show)

data LoadBalancerControllerMemberObservation
  = LoadBalancerControllerMemberObservation
      !LoadBalancerControllerMemberKind
      !Text
  deriving (Eq, Ord, Show)

parseAwsLoadBalancerControllerFamilyObservation
  :: Text -> Either Text [LoadBalancerControllerMemberObservation]
parseAwsLoadBalancerControllerFamilyObservation evidence = case Text.lines evidence of
  "prodbox-eks-lbc-family/v1" : rows -> do
    parsed <- traverse parseRow rows
    if length parsed == length (nub parsed)
      then Right parsed
      else Left "EKS load-balancer controller evidence duplicated a member"
  _ -> Left "EKS load-balancer controller evidence omitted its canonical header"
 where
  parseRow row = case Text.splitOn "|" row of
    [rawKind, arn]
      | not (Text.null arn) ->
          LoadBalancerControllerMemberObservation <$> parseKind rawKind <*> pure arn
    _ -> Left "EKS load-balancer controller evidence row was malformed"
  parseKind raw = case raw of
    "load-balancer" -> Right LoadBalancerMember
    "listener" -> Right ListenerMember
    "target-group" -> Right TargetGroupMember
    "security-group" -> Right SecurityGroupMember
    _ -> Left "EKS load-balancer controller evidence named an unknown member kind"

awsLoadBalancerControllerObservationArns :: Text -> Either Text [Text]
awsLoadBalancerControllerObservationArns evidence =
  sort . map memberArn <$> parseAwsLoadBalancerControllerFamilyObservation evidence
 where
  memberArn (LoadBalancerControllerMemberObservation _ arn) = arn

decodeExactAwsLoadBalancerControllerFamilyObservation
  :: ExactAwsLoadBalancerControllerFamilyObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsLoadBalancerControllerFamilyAdapterError ExactResourceObservation
decodeExactAwsLoadBalancerControllerFamilyObservation request providerResult =
  case providerResult of
    Left detail -> Right (unobservable detail)
    Right (ProviderIntentExecutionObserved actualCoordinate evidence)
      | actualCoordinate /= expectedCoordinate ->
          Left
            ( AwsLoadBalancerControllerFamilyProviderCoordinateMismatch
                expectedCoordinate
                actualCoordinate
            )
      | otherwise -> case parseAwsLoadBalancerControllerFamilyObservation evidence of
          Left detail -> Right (unobservable detail)
          Right members -> Right (exactObservation members)
    Right _ -> Left AwsLoadBalancerControllerFamilyProviderResultKindMismatch
 where
  expectedCoordinate = internalLbcRequestCoordinate request
  observation result =
    exactResourceObservationFor
      (internalLbcRequestIdentity request)
      (internalLbcRequestRevision request)
      (internalLbcRequestScope request)
      result
  unobservable detail =
    observation (ExactResourceUnobservable (ObservationFailure detail :| []))
  exactObservation members = case sort (map memberIdentity members) of
    [] ->
      observation
        ( ExactResourceAbsent
            ( AbsenceEvidence
                "provider-worker exact EKS load-balancer controller family returned its canonical empty set"
            )
        )
    first : remaining ->
      observation
        (ExactResourcePresent (ExactResourceInventory (first :| remaining)))
  memberIdentity (LoadBalancerControllerMemberObservation _ arn) =
    ObservedResourceIdentity arn

data ExactAwsLoadBalancerControllerFamilyReapAuthorization
  = ExactAwsLoadBalancerControllerFamilyReapAuthorization
  { internalLbcReapScope :: !ObservationEvidenceScope
  , internalLbcReapName :: !Text
  , internalLbcReapTags :: ![(Text, Text)]
  }
  deriving (Eq, Show)

awsLoadBalancerControllerFamilyReapScope
  :: ExactAwsLoadBalancerControllerFamilyReapAuthorization
  -> ObservationEvidenceScope
awsLoadBalancerControllerFamilyReapScope = internalLbcReapScope

authorizeExactAwsLoadBalancerControllerFamilyReap
  :: ExactAwsLoadBalancerControllerFamilyObservationRequest
  -> ExactResourceObservation
  -> Either
       AwsLoadBalancerControllerFamilyAdapterError
       (Maybe ExactAwsLoadBalancerControllerFamilyReapAuthorization)
authorizeExactAwsLoadBalancerControllerFamilyReap request exact = do
  complete <-
    either
      (Left . AwsLoadBalancerControllerFamilyObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalLbcRequestScope request)
          [AwsEksLoadBalancerControllerFamilyKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> Right Nothing
    SelectedResourcesRequireCleanup _ ->
      Right
        ( Just
            ExactAwsLoadBalancerControllerFamilyReapAuthorization
              { internalLbcReapScope = internalLbcRequestScope request
              , internalLbcReapName = internalLbcRequestName request
              , internalLbcReapTags = internalLbcRequestTags request
              }
        )
    CompleteObservationsRefused failures ->
      Left (AwsLoadBalancerControllerFamilyObservationRefused failures)

awsLoadBalancerControllerFamilyReapProviderIntent
  :: ExactAwsLoadBalancerControllerFamilyReapAuthorization -> ProviderIntent
awsLoadBalancerControllerFamilyReapProviderIntent authorization =
  ReapEksLoadBalancerControllerFamily
    (internalLbcReapName authorization)
    (renderTags (internalLbcReapTags authorization))

confirmExactAwsLoadBalancerControllerFamilyAbsence
  :: ExactAwsLoadBalancerControllerFamilyObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsLoadBalancerControllerFamilyAdapterError AbsenceEvidence
confirmExactAwsLoadBalancerControllerFamilyAbsence request result = do
  exact <- decodeExactAwsLoadBalancerControllerFamilyObservation request result
  complete <-
    either
      (Left . AwsLoadBalancerControllerFamilyObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalLbcRequestScope request)
          [AwsEksLoadBalancerControllerFamilyKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> case exactObservationResult exact of
      ExactResourceAbsent evidence -> Right evidence
      _ ->
        Left
          ( AwsLoadBalancerControllerFamilyStillPresent
              (AwsEksLoadBalancerControllerFamilyKey :| [])
          )
    SelectedResourcesRequireCleanup remaining ->
      Left (AwsLoadBalancerControllerFamilyStillPresent remaining)
    CompleteObservationsRefused failures ->
      Left (AwsLoadBalancerControllerFamilyObservationRefused failures)
