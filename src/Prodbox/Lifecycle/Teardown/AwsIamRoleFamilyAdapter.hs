{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Exact registered adapter for the deterministic EKS IAM role family.
-- Registration and this executor land together: a registered family compiles
-- a mandatory absence read-back, so either half without the other would make
-- completion unreachable.
module Prodbox.Lifecycle.Teardown.AwsIamRoleFamilyAdapter
  ( ExactAwsIamRoleFamilyObservationRequest
  , mkExactAwsIamRoleFamilyObservationRequest
  , awsIamRoleFamilyObservationRequestScope
  , awsIamRoleFamilyObservationRequestRevision
  , awsIamRoleFamilyObservationRequestProviderIntent
  , decodeExactAwsIamRoleFamilyObservation
  , ExactAwsIamRoleFamilyReapAuthorization
  , authorizeExactAwsIamRoleFamilyReap
  , awsIamRoleFamilyReapScope
  , awsIamRoleFamilyReapProviderIntent
  , confirmExactAwsIamRoleFamilyAbsence
  , parseAwsIamRoleFamilyObservation
  , AwsIamRoleFamilyAdapterError (..)
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

data ExactAwsIamRoleFamilyObservationRequest
  = ExactAwsIamRoleFamilyObservationRequest
  { internalIamFamilyRequestIdentity :: !RegisteredIdentity
  , internalIamFamilyRequestScope :: !ObservationEvidenceScope
  , internalIamFamilyRequestRevision :: !ObservationRevision
  , internalIamFamilyRequestRoles :: ![Text]
  , internalIamFamilyRequestPolicies :: ![Text]
  , internalIamFamilyRequestIntent :: !ProviderIntent
  , internalIamFamilyRequestCoordinate :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsIamRoleFamilyObservationRequestScope
  :: ExactAwsIamRoleFamilyObservationRequest -> ObservationEvidenceScope
awsIamRoleFamilyObservationRequestScope = internalIamFamilyRequestScope

awsIamRoleFamilyObservationRequestRevision
  :: ExactAwsIamRoleFamilyObservationRequest -> ObservationRevision
awsIamRoleFamilyObservationRequestRevision = internalIamFamilyRequestRevision

awsIamRoleFamilyObservationRequestProviderIntent
  :: ExactAwsIamRoleFamilyObservationRequest -> ProviderIntent
awsIamRoleFamilyObservationRequestProviderIntent = internalIamFamilyRequestIntent

data AwsIamRoleFamilyAdapterError
  = AwsIamRoleFamilyRegistryIdentityMissing
  | AwsIamRoleFamilyRegistryIdentityWrongKind !ResourceKind
  | AwsIamRoleFamilyRegistryCoordinateInvalid !ManagedResourceCoordinate
  | AwsIamRoleFamilySurfaceMismatch !CleanupSurface !CleanupSurface
  | AwsIamRoleFamilySurfaceNotAllowed !CleanupSelectionError
  | AwsIamRoleFamilyRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsIamRoleFamilyOperationInvalid !LifecycleOperation
  | AwsIamRoleFamilyAwsScopeMissing
  | AwsIamRoleFamilyProviderCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsIamRoleFamilyProviderResultKindMismatch
  | AwsIamRoleFamilyObservationBindingInvalid !CompleteObservationSetError
  | AwsIamRoleFamilyObservationRefused !(NonEmpty ObservationDecisionRefusal)
  | AwsIamRoleFamilyStillPresent !(NonEmpty RegisteredResourceKey)
  deriving (Eq, Show)

mkExactAwsIamRoleFamilyObservationRequest
  :: CleanupSurfaceWitness surface
  -> ObservationRevision
  -> ObservationEvidenceScope
  -> Either AwsIamRoleFamilyAdapterError ExactAwsIamRoleFamilyObservationRequest
mkExactAwsIamRoleFamilyObservationRequest surface revision scope = do
  identity <-
    maybe (Left AwsIamRoleFamilyRegistryIdentityMissing) Right identityMaybe
  if registeredIdentityKind identity == ControllerFamily
    then Right ()
    else
      Left
        (AwsIamRoleFamilyRegistryIdentityWrongKind (registeredIdentityKind identity))
  let expectedSurface = cleanupSurfaceFromWitness surface
      actualSurface = evidenceCleanupSurface scope
  if actualSurface == expectedSurface
    then Right ()
    else Left (AwsIamRoleFamilySurfaceMismatch expectedSurface actualSurface)
  case projectCleanupTarget surface identity of
    Left err -> Left (AwsIamRoleFamilySurfaceNotAllowed err)
    Right _ -> Right ()
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( AwsIamRoleFamilyRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (AwsIamRoleFamilyOperationInvalid (evidenceLifecycleOperation scope))
  case evidenceAwsScope scope of
    Nothing -> Left AwsIamRoleFamilyAwsScopeMissing
    Just _ -> Right ()
  (roles, policies) <- familyFromCoordinate (registeredIdentityCoordinate identity)
  let intent =
        ObserveEksIamRoleFamily
          (Text.intercalate "|" roles)
          (Text.intercalate "|" policies)
  Right
    ExactAwsIamRoleFamilyObservationRequest
      { internalIamFamilyRequestIdentity = identity
      , internalIamFamilyRequestScope = scope
      , internalIamFamilyRequestRevision = revision
      , internalIamFamilyRequestRoles = roles
      , internalIamFamilyRequestPolicies = policies
      , internalIamFamilyRequestIntent = intent
      , internalIamFamilyRequestCoordinate = providerIntentCoordinate intent
      }
 where
  identityMaybe = lookupRegisteredIdentity AwsEksIamRoleFamilyKey

familyFromCoordinate
  :: ManagedResourceCoordinate
  -> Either AwsIamRoleFamilyAdapterError ([Text], [Text])
familyFromCoordinate coordinate = case coordinate of
  AwsIamRoleFamilyCoordinate ownerCluster roles policies
    | ownerCluster == awsEksProvisionedClusterName
    , roles == awsEksIamRoleNames
    , policies == awsEksIamManagedPolicyNames
    , not (null roles)
    , not (null policies)
    , length roles == length (nub roles)
    , length policies == length (nub policies) ->
        Right (roles, policies)
  _ -> Left (AwsIamRoleFamilyRegistryCoordinateInvalid coordinate)

data IamFamilyMemberKind = IamFamilyRole | IamFamilyPolicy
  deriving (Eq, Ord, Show)

data IamFamilyMemberObservation = IamFamilyMemberObservation
  { iamFamilyMemberKind :: !IamFamilyMemberKind
  , iamFamilyMemberName :: !Text
  , iamFamilyMemberArn :: !(Maybe Text)
  }
  deriving (Eq, Ord, Show)

parseAwsIamRoleFamilyObservation
  :: Text -> Either Text [IamFamilyMemberObservation]
parseAwsIamRoleFamilyObservation evidence = case Text.lines evidence of
  "prodbox-eks-iam-family/v1" : rows -> do
    parsed <- traverse parseRow rows
    if length parsed == length (nub (map memberKey parsed))
      then Right parsed
      else Left "EKS IAM family evidence duplicated a member"
  _ -> Left "EKS IAM family evidence omitted its canonical header"
 where
  memberKey member = (iamFamilyMemberKind member, iamFamilyMemberName member)
  parseRow row = case Text.splitOn "|" row of
    [rawKind, name, "absent"] ->
      IamFamilyMemberObservation <$> parseKind rawKind <*> pure name <*> pure Nothing
    [rawKind, name, "present", arn]
      | not (Text.null arn) ->
          IamFamilyMemberObservation <$> parseKind rawKind <*> pure name <*> pure (Just arn)
    _ -> Left "EKS IAM family evidence row was malformed"
  parseKind raw = case raw of
    "role" -> Right IamFamilyRole
    "policy" -> Right IamFamilyPolicy
    _ -> Left "EKS IAM family evidence named an unknown member kind"

decodeExactAwsIamRoleFamilyObservation
  :: ExactAwsIamRoleFamilyObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsIamRoleFamilyAdapterError ExactResourceObservation
decodeExactAwsIamRoleFamilyObservation request providerResult =
  case providerResult of
    Left detail -> Right (unobservable detail)
    Right (ProviderIntentExecutionObserved actualCoordinate evidence)
      | actualCoordinate /= expectedCoordinate ->
          Left
            ( AwsIamRoleFamilyProviderCoordinateMismatch
                expectedCoordinate
                actualCoordinate
            )
      | otherwise -> case parseAwsIamRoleFamilyObservation evidence of
          Left detail -> Right (unobservable detail)
          Right members
            | memberShape members /= expectedShape ->
                Right (unobservable "EKS IAM family evidence did not cover the exact registry family")
            | otherwise -> Right (exactObservation members)
    Right _ -> Left AwsIamRoleFamilyProviderResultKindMismatch
 where
  expectedCoordinate = internalIamFamilyRequestCoordinate request
  expectedShape =
    sort
      ( map (IamFamilyRole,) (internalIamFamilyRequestRoles request)
          ++ map (IamFamilyPolicy,) (internalIamFamilyRequestPolicies request)
      )
  memberShape = sort . map (\member -> (iamFamilyMemberKind member, iamFamilyMemberName member))
  observation result =
    exactResourceObservationFor
      (internalIamFamilyRequestIdentity request)
      (internalIamFamilyRequestRevision request)
      (internalIamFamilyRequestScope request)
      result
  unobservable detail =
    observation (ExactResourceUnobservable (ObservationFailure detail :| []))
  exactObservation members = case presentIdentities members of
    [] ->
      observation
        ( ExactResourceAbsent
            (AbsenceEvidence "provider-worker exact EKS IAM family returned its canonical empty set")
        )
    first : remaining ->
      observation
        ( ExactResourcePresent
            (ExactResourceInventory (first :| remaining))
        )
  presentIdentities members =
    [ ObservedResourceIdentity arn
    | member <- members
    , Just arn <- [iamFamilyMemberArn member]
    ]

data ExactAwsIamRoleFamilyReapAuthorization
  = ExactAwsIamRoleFamilyReapAuthorization
  { internalIamFamilyReapScope :: !ObservationEvidenceScope
  , internalIamFamilyReapRoles :: ![Text]
  , internalIamFamilyReapPolicies :: ![Text]
  }
  deriving (Eq, Show)

awsIamRoleFamilyReapScope
  :: ExactAwsIamRoleFamilyReapAuthorization -> ObservationEvidenceScope
awsIamRoleFamilyReapScope = internalIamFamilyReapScope

authorizeExactAwsIamRoleFamilyReap
  :: ExactAwsIamRoleFamilyObservationRequest
  -> ExactResourceObservation
  -> Either
       AwsIamRoleFamilyAdapterError
       (Maybe ExactAwsIamRoleFamilyReapAuthorization)
authorizeExactAwsIamRoleFamilyReap request exact = do
  complete <-
    either
      (Left . AwsIamRoleFamilyObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalIamFamilyRequestScope request)
          [AwsEksIamRoleFamilyKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> Right Nothing
    SelectedResourcesRequireCleanup _ ->
      Right
        ( Just
            ExactAwsIamRoleFamilyReapAuthorization
              { internalIamFamilyReapScope = internalIamFamilyRequestScope request
              , internalIamFamilyReapRoles = internalIamFamilyRequestRoles request
              , internalIamFamilyReapPolicies = internalIamFamilyRequestPolicies request
              }
        )
    CompleteObservationsRefused failures ->
      Left (AwsIamRoleFamilyObservationRefused failures)

awsIamRoleFamilyReapProviderIntent
  :: ExactAwsIamRoleFamilyReapAuthorization -> ProviderIntent
awsIamRoleFamilyReapProviderIntent authorization =
  ReapEksIamRoleFamily
    (Text.intercalate "|" (internalIamFamilyReapRoles authorization))
    (Text.intercalate "|" (internalIamFamilyReapPolicies authorization))

confirmExactAwsIamRoleFamilyAbsence
  :: ExactAwsIamRoleFamilyObservationRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either AwsIamRoleFamilyAdapterError AbsenceEvidence
confirmExactAwsIamRoleFamilyAbsence request result = do
  exact <- decodeExactAwsIamRoleFamilyObservation request result
  complete <-
    either
      (Left . AwsIamRoleFamilyObservationBindingInvalid)
      Right
      ( mkCompleteObservationSet
          (internalIamFamilyRequestScope request)
          [AwsEksIamRoleFamilyKey]
          [exact]
      )
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> case exactObservationResult exact of
      ExactResourceAbsent evidence -> Right evidence
      _ -> Left (AwsIamRoleFamilyStillPresent (AwsEksIamRoleFamilyKey :| []))
    SelectedResourcesRequireCleanup remaining ->
      Left (AwsIamRoleFamilyStillPresent remaining)
    CompleteObservationsRefused failures ->
      Left (AwsIamRoleFamilyObservationRefused failures)
