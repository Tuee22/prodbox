{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure adapter between exact lifecycle stack observations and the closed,
-- signed Provider Worker intent surface.  A provider return value is never
-- trusted as absence unless its operation coordinate, result constructor, and
-- exact evidence literal all match the request that produced it.
module Prodbox.Lifecycle.Teardown.AwsStackAdapter
  ( AwsStackObservationPurpose (..)
  , AwsStackObservationRequest
  , awsStackObservationRequestKey
  , awsStackObservationRequestRef
  , awsStackObservationRequestScope
  , awsStackObservationRequestRevision
  , awsStackObservationRequestIntent
  , awsStackObservationRequestCoordinate
  , mkAwsStackObserveRequest
  , mkAwsStackDesiredAbsenceReadBackRequest
  , VerifiedAwsStackObservation
  , verifiedAwsStackExactObservation
  , AwsStackExecutionResultKind (..)
  , AwsStackObservationRefusal (..)
  , AwsStackObservationDecode (..)
  , awsStackObservationDecodeObservation
  , decodeAwsStackExecutionResult
  , AwsStackBindingError (..)
  , AwsStackDestroyAuthorityKind (..)
  , AwsStackDestroyAuthorization
  , awsStackDestroyAuthorizationKey
  , awsStackDestroyAuthorizationScope
  , awsStackDestroyAuthorizationProviderRevision
  , awsStackDestroyAuthorizationKind
  , authorizeAwsStackDestroy
  , AwsStackDestroyRequest
  , awsStackDestroyRequestKey
  , awsStackDestroyRequestScope
  , awsStackDestroyRequestIntent
  , awsStackDestroyRequestCoordinate
  , mkAwsStackDestroyRequest
  , mkAwsStackDestroyReadBackRequest
  , CompleteAwsStackDestroy
  , completeAwsStackDestroyKey
  , completeAwsStackDestroyScope
  , completeAwsStackDestroyObservationRevision
  , completeAwsStackDestroyAbsenceEvidence
  , completeAwsStackDestroyReadBack
  , AwsStackDestroyRefusal (..)
  )
where

import Data.Char (isAsciiLower)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderRefError
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackConfigError
  , ProviderStackRef
  , mkProviderStackRef
  , providerIntentCoordinate
  , validateProviderStackConfig
  )
import Prodbox.Lifecycle.Teardown.Decision
  ( StackCleanupAuthority (..)
  , StackDecisionRefusal
  , StackDesiredAbsenceDecision (..)
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

data AwsStackObservationPurpose
  = ObserveStackForDecision
  | ReadBackDestroyedStack
  | ReadBackDesiredAbsentStack

data AwsStackBinding = AwsStackBinding
  { awsStackBindingIdentity :: !RegisteredIdentity
  , awsStackBindingRef :: !ProviderStackRef
  , awsStackBindingScope :: !ObservationEvidenceScope
  , awsStackBindingRevision :: !ObservationRevision
  }
  deriving (Eq, Show)

-- | The constructor is private.  The phantom purpose prevents an initial
-- observation from being confused with the mandatory post-destroy read-back.
data AwsStackObservationRequest (purpose :: AwsStackObservationPurpose)
  = AwsStackObservationRequest
      !AwsStackBinding
      !ProviderIntent
      !ProviderIntentCoordinate
      !(Maybe ProviderIntentCoordinate)
  deriving (Eq, Show)

awsStackObservationRequestKey
  :: AwsStackObservationRequest purpose -> RegisteredResourceKey
awsStackObservationRequestKey =
  registeredIdentityKey . awsStackBindingIdentity . observationRequestBinding

awsStackObservationRequestRef
  :: AwsStackObservationRequest purpose -> ProviderStackRef
awsStackObservationRequestRef = awsStackBindingRef . observationRequestBinding

awsStackObservationRequestScope
  :: AwsStackObservationRequest purpose -> ObservationEvidenceScope
awsStackObservationRequestScope = awsStackBindingScope . observationRequestBinding

awsStackObservationRequestRevision
  :: AwsStackObservationRequest purpose -> ObservationRevision
awsStackObservationRequestRevision = awsStackBindingRevision . observationRequestBinding

awsStackObservationRequestIntent
  :: AwsStackObservationRequest purpose -> ProviderIntent
awsStackObservationRequestIntent (AwsStackObservationRequest _ intent _ _) = intent

awsStackObservationRequestCoordinate
  :: AwsStackObservationRequest purpose -> ProviderIntentCoordinate
awsStackObservationRequestCoordinate
  (AwsStackObservationRequest _ _ coordinate _) = coordinate

mkAwsStackObserveRequest
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ObservationRevision
  -> Either
       AwsStackBindingError
       (AwsStackObservationRequest 'ObserveStackForDecision)
mkAwsStackObserveRequest key scope revision = do
  binding <- mkAwsStackBinding key scope revision
  let intent = ObserveRegisteredStack (awsStackBindingRef binding)
  Right
    ( AwsStackObservationRequest
        binding
        intent
        (providerIntentCoordinate intent)
        Nothing
    )

-- | Build the independent desired-absence read-back used by the durable
-- graph.  It is deliberately not a destroy-completion witness: an already
-- absent target needs the same final observation, and the graph's stable
-- read-back operation is authoritative for scheduling.  Callers that need to
-- prove one particular destroy request must continue to use
-- 'mkAwsStackDestroyReadBackRequest' plus
-- 'completeAwsStackDestroyReadBack'.
mkAwsStackDesiredAbsenceReadBackRequest
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ObservationRevision
  -> Either
       AwsStackBindingError
       (AwsStackObservationRequest 'ReadBackDesiredAbsentStack)
mkAwsStackDesiredAbsenceReadBackRequest key scope revision = do
  binding <- mkAwsStackBinding key scope revision
  let intent = ReadBackRegisteredStack (awsStackBindingRef binding)
  Right
    ( AwsStackObservationRequest
        binding
        intent
        (providerIntentCoordinate intent)
        Nothing
    )

-- | Opaque proof that the Provider Worker returned a coordinate- and
-- constructor-matched observation whose evidence belongs to the closed wire
-- vocabulary below.
data VerifiedAwsStackObservation (purpose :: AwsStackObservationPurpose)
  = VerifiedAwsStackObservation
      !(AwsStackObservationRequest purpose)
      !ExactResourceObservation
  deriving (Eq, Show)

verifiedAwsStackExactObservation
  :: VerifiedAwsStackObservation purpose -> ExactResourceObservation
verifiedAwsStackExactObservation (VerifiedAwsStackObservation _ observation) = observation

data AwsStackExecutionResultKind
  = AwsStackExecutionApplied
  | AwsStackExecutionAlreadySatisfied
  | AwsStackExecutionObserved
  deriving (Eq, Show)

data AwsStackObservationRefusal
  = AwsStackObservationCoordinateMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsStackObservationResultKindMismatch
      !AwsStackExecutionResultKind
  | AwsStackObservationEvidenceNotRecognized !Text
  deriving (Eq, Show)

-- | Refusal still carries an exact, request-bound unobservable observation so
-- callers can retain structural completeness without turning malformed output
-- into absence.
data AwsStackObservationDecode (purpose :: AwsStackObservationPurpose)
  = AwsStackObservationDecoded !(VerifiedAwsStackObservation purpose)
  | AwsStackObservationRejected
      !AwsStackObservationRefusal
      !ExactResourceObservation
  deriving (Eq, Show)

awsStackObservationDecodeObservation
  :: AwsStackObservationDecode purpose -> ExactResourceObservation
awsStackObservationDecodeObservation decoded = case decoded of
  AwsStackObservationDecoded verified -> verifiedAwsStackExactObservation verified
  AwsStackObservationRejected _ observation -> observation

decodeAwsStackExecutionResult
  :: AwsStackObservationRequest purpose
  -> ProviderIntentExecutionResult
  -> AwsStackObservationDecode purpose
decodeAwsStackExecutionResult request executionResult
  | actualCoordinate /= expectedCoordinate =
      rejected
        ( AwsStackObservationCoordinateMismatch
            expectedCoordinate
            actualCoordinate
        )
  | otherwise = case executionResult of
      ProviderIntentExecutionObserved _ evidence ->
        case decodeObservationEvidence evidence of
          Just result ->
            AwsStackObservationDecoded
              (VerifiedAwsStackObservation request (exactObservation result))
          Nothing -> rejected (AwsStackObservationEvidenceNotRecognized evidence)
      ProviderIntentExecutionApplied {} ->
        rejected
          (AwsStackObservationResultKindMismatch AwsStackExecutionApplied)
      ProviderIntentExecutionAlreadySatisfied {} ->
        rejected
          ( AwsStackObservationResultKindMismatch
              AwsStackExecutionAlreadySatisfied
          )
 where
  expectedCoordinate = awsStackObservationRequestCoordinate request
  actualCoordinate = executionResultCoordinate executionResult
  exactObservation = exactObservationForRequest request
  rejected refusal =
    AwsStackObservationRejected
      refusal
      ( exactObservation
          ( ExactResourceUnobservable
              (ObservationFailure (renderObservationRefusal refusal) :| [])
          )
      )

data AwsStackBindingError
  = AwsStackKeyUnsupported !RegisteredResourceKey
  | AwsStackRegistryIdentityMissing !RegisteredResourceKey
  | AwsStackRegistryKindMismatch !RegisteredResourceKey !ResourceKind
  | AwsStackRegistryCoordinateMismatch
      !RegisteredResourceKey
      !ManagedResourceCoordinate
      !ManagedResourceCoordinate
  | AwsStackProviderRefInvalid !RegisteredResourceKey !ProviderRefError
  | AwsStackCleanupSurfaceInvalid !RegisteredResourceKey !CleanupSurface
  | AwsStackRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsStackLifecycleOperationMismatch !LifecycleOperation !LifecycleOperation
  | AwsStackAwsScopeMissing
  | AwsStackAwsAccountInvalid !AwsAccountId
  | AwsStackAwsRegionInvalid !AwsRegion
  deriving (Eq, Show)

data AwsStackDestroyAuthorityKind
  = AwsStackDestroyFromPrimaryCheckpoint
  | AwsStackDestroyFromCompleteManifest
  deriving (Eq, Show)

-- | Opaque destroy capability.  It binds the successful initial provider
-- observation, decision source, and exact Provider generation revision.
data AwsStackDestroyAuthorization = AwsStackDestroyAuthorization
  { internalDestroyAuthorizationObservation
      :: !(VerifiedAwsStackObservation 'ObserveStackForDecision)
  , internalDestroyAuthorizationProviderRevision :: !ProviderRevision
  , internalDestroyAuthorizationKind :: !AwsStackDestroyAuthorityKind
  }
  deriving (Eq, Show)

awsStackDestroyAuthorizationKey
  :: AwsStackDestroyAuthorization -> RegisteredResourceKey
awsStackDestroyAuthorizationKey =
  exactObservationResourceKey
    . verifiedAwsStackExactObservation
    . internalDestroyAuthorizationObservation

awsStackDestroyAuthorizationScope
  :: AwsStackDestroyAuthorization -> ObservationEvidenceScope
awsStackDestroyAuthorizationScope =
  exactObservationEvidenceScope
    . verifiedAwsStackExactObservation
    . internalDestroyAuthorizationObservation

awsStackDestroyAuthorizationProviderRevision
  :: AwsStackDestroyAuthorization -> ProviderRevision
awsStackDestroyAuthorizationProviderRevision =
  internalDestroyAuthorizationProviderRevision

awsStackDestroyAuthorizationKind
  :: AwsStackDestroyAuthorization -> AwsStackDestroyAuthorityKind
awsStackDestroyAuthorizationKind = internalDestroyAuthorizationKind

authorizeAwsStackDestroy
  :: ProviderRevision
  -> VerifiedAwsStackObservation 'ObserveStackForDecision
  -> StackDesiredAbsenceDecision
  -> Either AwsStackDestroyRefusal AwsStackDestroyAuthorization
authorizeAwsStackDestroy providerRevision verified decision = do
  case exactObservationResult observation of
    ExactResourcePresent _ -> Right ()
    ExactResourceAbsent _ -> Left AwsStackDestroyObservationAlreadyAbsent
    ExactResourcePartial _ _ -> Left AwsStackDestroyObservationNotExact
    ExactResourceUnobservable _ -> Left AwsStackDestroyObservationNotExact
  if observationKey == AwsEksKey
    then Left AwsStackDestroyEksDrainAuthorizationRequired
    else Right ()
  (decisionKey, authorityKind) <- case decision of
    StackDestroyFromVerifiedPrimary key authority -> case authority of
      VerifiedPrimaryCheckpoint {} ->
        Right (key, AwsStackDestroyFromPrimaryCheckpoint)
      _ -> Left (AwsStackDestroyDecisionAuthorityMismatch authority)
    StackDestroyFromVerifiedManifest key authority -> case authority of
      VerifiedOwnershipManifest {} ->
        Right (key, AwsStackDestroyFromCompleteManifest)
      _ -> Left (AwsStackDestroyDecisionAuthorityMismatch authority)
    StackAlreadyAbsent {} -> Left AwsStackDestroyDecisionAlreadyAbsent
    StackRestoreBackupThenDestroy {} ->
      Left AwsStackDestroyCheckpointRestoreRequired
    StackDesiredAbsenceRefused _ refusals ->
      Left (AwsStackDestroyDecisionRefused refusals)
  if decisionKey == observationKey
    then
      Right
        AwsStackDestroyAuthorization
          { internalDestroyAuthorizationObservation = verified
          , internalDestroyAuthorizationProviderRevision = providerRevision
          , internalDestroyAuthorizationKind = authorityKind
          }
    else Left (AwsStackDestroyDecisionKeyMismatch observationKey decisionKey)
 where
  observation = verifiedAwsStackExactObservation verified
  observationKey = exactObservationResourceKey observation

data AwsStackDestroyRequest = AwsStackDestroyRequest
  { internalDestroyRequestAuthorization :: !AwsStackDestroyAuthorization
  , internalDestroyRequestIntent :: !ProviderIntent
  , internalDestroyRequestCoordinate :: !ProviderIntentCoordinate
  }
  deriving (Eq, Show)

awsStackDestroyRequestKey :: AwsStackDestroyRequest -> RegisteredResourceKey
awsStackDestroyRequestKey =
  awsStackDestroyAuthorizationKey . internalDestroyRequestAuthorization

awsStackDestroyRequestScope
  :: AwsStackDestroyRequest -> ObservationEvidenceScope
awsStackDestroyRequestScope =
  awsStackDestroyAuthorizationScope . internalDestroyRequestAuthorization

awsStackDestroyRequestIntent :: AwsStackDestroyRequest -> ProviderIntent
awsStackDestroyRequestIntent = internalDestroyRequestIntent

awsStackDestroyRequestCoordinate
  :: AwsStackDestroyRequest -> ProviderIntentCoordinate
awsStackDestroyRequestCoordinate = internalDestroyRequestCoordinate

mkAwsStackDestroyRequest
  :: AwsStackDestroyAuthorization
  -> ProviderRevision
  -> ProviderStackConfig
  -> Either AwsStackDestroyRefusal AwsStackDestroyRequest
mkAwsStackDestroyRequest authorization requestedRevision config = do
  if awsStackDestroyAuthorizationKey authorization == AwsEksKey
    then Left AwsStackDestroyEksDrainAuthorizationRequired
    else Right ()
  let expectedRevision = awsStackDestroyAuthorizationProviderRevision authorization
  if requestedRevision == expectedRevision
    then Right ()
    else
      Left
        ( AwsStackDestroyProviderRevisionMismatch
            expectedRevision
            requestedRevision
        )
  let ref =
        awsStackObservationRequestRef
          (destroyAuthorizationObservationRequest authorization)
  case validateProviderStackConfig ref config of
    Left err -> Left (AwsStackDestroyConfigInvalid err)
    Right () -> Right ()
  let intent = DestroyRegisteredStack ref requestedRevision config
  Right
    AwsStackDestroyRequest
      { internalDestroyRequestAuthorization = authorization
      , internalDestroyRequestIntent = intent
      , internalDestroyRequestCoordinate = providerIntentCoordinate intent
      }

-- | Derive the mandatory read-back from the already-authorized destroy.  The
-- parent destroy coordinate is retained privately and checked again at close.
mkAwsStackDestroyReadBackRequest
  :: AwsStackDestroyRequest
  -> ObservationRevision
  -> AwsStackObservationRequest 'ReadBackDestroyedStack
mkAwsStackDestroyReadBackRequest destroyRequest revision =
  AwsStackObservationRequest
    binding
    intent
    (providerIntentCoordinate intent)
    (Just (awsStackDestroyRequestCoordinate destroyRequest))
 where
  authorization = internalDestroyRequestAuthorization destroyRequest
  initialRequest = destroyAuthorizationObservationRequest authorization
  initialBinding = observationRequestBinding initialRequest
  binding = initialBinding {awsStackBindingRevision = revision}
  intent = ReadBackRegisteredStack (awsStackBindingRef binding)

data CompleteAwsStackDestroy = CompleteAwsStackDestroy
  { internalCompleteAwsStackDestroyKey :: !RegisteredResourceKey
  , internalCompleteAwsStackDestroyScope :: !ObservationEvidenceScope
  , internalCompleteAwsStackDestroyObservationRevision :: !ObservationRevision
  , internalCompleteAwsStackDestroyAbsenceEvidence :: !AbsenceEvidence
  }
  deriving (Eq, Show)

completeAwsStackDestroyKey :: CompleteAwsStackDestroy -> RegisteredResourceKey
completeAwsStackDestroyKey = internalCompleteAwsStackDestroyKey

completeAwsStackDestroyScope
  :: CompleteAwsStackDestroy -> ObservationEvidenceScope
completeAwsStackDestroyScope = internalCompleteAwsStackDestroyScope

completeAwsStackDestroyObservationRevision
  :: CompleteAwsStackDestroy -> ObservationRevision
completeAwsStackDestroyObservationRevision =
  internalCompleteAwsStackDestroyObservationRevision

completeAwsStackDestroyAbsenceEvidence
  :: CompleteAwsStackDestroy -> AbsenceEvidence
completeAwsStackDestroyAbsenceEvidence =
  internalCompleteAwsStackDestroyAbsenceEvidence

completeAwsStackDestroyReadBack
  :: AwsStackDestroyRequest
  -> VerifiedAwsStackObservation 'ReadBackDestroyedStack
  -> Either AwsStackDestroyRefusal CompleteAwsStackDestroy
completeAwsStackDestroyReadBack destroyRequest verified = do
  let readBackRequest = verifiedObservationRequest verified
      expectedDestroyCoordinate = awsStackDestroyRequestCoordinate destroyRequest
  case observationRequestParentDestroyCoordinate readBackRequest of
    Just actualDestroyCoordinate
      | actualDestroyCoordinate == expectedDestroyCoordinate -> Right ()
      | otherwise ->
          Left
            ( AwsStackDestroyReadBackParentMismatch
                expectedDestroyCoordinate
                actualDestroyCoordinate
            )
    Nothing -> Left AwsStackDestroyReadBackParentMissing
  if awsStackObservationRequestKey readBackRequest == awsStackDestroyRequestKey destroyRequest
    then Right ()
    else
      Left
        ( AwsStackDestroyReadBackKeyMismatch
            (awsStackDestroyRequestKey destroyRequest)
            (awsStackObservationRequestKey readBackRequest)
        )
  if awsStackObservationRequestScope readBackRequest == awsStackDestroyRequestScope destroyRequest
    then Right ()
    else
      Left
        ( AwsStackDestroyReadBackScopeMismatch
            (awsStackDestroyRequestScope destroyRequest)
            (awsStackObservationRequestScope readBackRequest)
        )
  case exactObservationResult observation of
    ExactResourceAbsent absence ->
      Right
        CompleteAwsStackDestroy
          { internalCompleteAwsStackDestroyKey = exactObservationResourceKey observation
          , internalCompleteAwsStackDestroyScope =
              exactObservationEvidenceScope observation
          , internalCompleteAwsStackDestroyObservationRevision =
              exactObservationRevision observation
          , internalCompleteAwsStackDestroyAbsenceEvidence = absence
          }
    ExactResourcePresent inventory ->
      Left (AwsStackDestroyReadBackStillPresent inventory)
    ExactResourcePartial _ _ -> Left AwsStackDestroyReadBackNotExact
    ExactResourceUnobservable _ -> Left AwsStackDestroyReadBackNotExact
 where
  observation = verifiedAwsStackExactObservation verified

data AwsStackDestroyRefusal
  = AwsStackDestroyObservationAlreadyAbsent
  | AwsStackDestroyObservationNotExact
  | AwsStackDestroyEksDrainAuthorizationRequired
  | AwsStackDestroyDecisionAlreadyAbsent
  | AwsStackDestroyCheckpointRestoreRequired
  | AwsStackDestroyDecisionRefused !(NonEmpty StackDecisionRefusal)
  | AwsStackDestroyDecisionAuthorityMismatch !StackCleanupAuthority
  | AwsStackDestroyDecisionKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsStackDestroyProviderRevisionMismatch
      !ProviderRevision
      !ProviderRevision
  | AwsStackDestroyConfigInvalid !ProviderStackConfigError
  | AwsStackDestroyReadBackParentMissing
  | AwsStackDestroyReadBackParentMismatch
      !ProviderIntentCoordinate
      !ProviderIntentCoordinate
  | AwsStackDestroyReadBackKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsStackDestroyReadBackScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | AwsStackDestroyReadBackStillPresent !ExactResourceInventory
  | AwsStackDestroyReadBackNotExact
  deriving (Eq, Show)

observationRequestBinding
  :: AwsStackObservationRequest purpose -> AwsStackBinding
observationRequestBinding (AwsStackObservationRequest binding _ _ _) = binding

observationRequestParentDestroyCoordinate
  :: AwsStackObservationRequest purpose -> Maybe ProviderIntentCoordinate
observationRequestParentDestroyCoordinate
  (AwsStackObservationRequest _ _ _ parentCoordinate) = parentCoordinate

verifiedObservationRequest
  :: VerifiedAwsStackObservation purpose -> AwsStackObservationRequest purpose
verifiedObservationRequest (VerifiedAwsStackObservation request _) = request

destroyAuthorizationObservationRequest
  :: AwsStackDestroyAuthorization
  -> AwsStackObservationRequest 'ObserveStackForDecision
destroyAuthorizationObservationRequest =
  verifiedObservationRequest . internalDestroyAuthorizationObservation

mkAwsStackBinding
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ObservationRevision
  -> Either AwsStackBindingError AwsStackBinding
mkAwsStackBinding key scope revision = do
  (rawRef, expectedCoordinate) <- case key of
    AwsEksKey ->
      Right
        ( "aws-eks"
        , AwsPulumiStackCoordinate "prodbox-aws-eks-test" "aws-eks-test"
        )
    AwsEksSubzoneKey ->
      Right
        ( "aws-eks-subzone"
        , AwsPulumiStackCoordinate
            "prodbox-aws-eks-subzone"
            "aws-eks-subzone"
        )
    AwsTestKey ->
      Right
        ( "aws-test"
        , AwsPulumiStackCoordinate "prodbox-aws-test" "aws-test"
        )
    _ -> Left (AwsStackKeyUnsupported key)
  identity <- case lookupRegisteredIdentity key of
    Nothing -> Left (AwsStackRegistryIdentityMissing key)
    Just found -> Right found
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        ( AwsStackRegistryKindMismatch
            key
            (registeredIdentityKind identity)
        )
  if registeredIdentityCoordinate identity == expectedCoordinate
    then Right ()
    else
      Left
        ( AwsStackRegistryCoordinateMismatch
            key
            expectedCoordinate
            (registeredIdentityCoordinate identity)
        )
  ref <- case mkProviderStackRef rawRef of
    Left err -> Left (AwsStackProviderRefInvalid key err)
    Right value -> Right value
  validateAwsStackScope key identity scope
  Right
    AwsStackBinding
      { awsStackBindingIdentity = identity
      , awsStackBindingRef = ref
      , awsStackBindingScope = scope
      , awsStackBindingRevision = revision
      }

validateAwsStackScope
  :: RegisteredResourceKey
  -> RegisteredIdentity
  -> ObservationEvidenceScope
  -> Either AwsStackBindingError ()
validateAwsStackScope key identity scope = do
  if cleanupSurfaceAllows (evidenceCleanupSurface scope) identity
    then Right ()
    else
      Left
        ( AwsStackCleanupSurfaceInvalid
            key
            (evidenceCleanupSurface scope)
        )
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( AwsStackRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else
      Left
        ( AwsStackLifecycleOperationMismatch
            ReconcileDesiredAbsent
            (evidenceLifecycleOperation scope)
        )
  awsScope <- case evidenceAwsScope scope of
    Nothing -> Left AwsStackAwsScopeMissing
    Just value -> Right value
  if validAwsAccountId (awsScopeAccountId awsScope)
    then Right ()
    else Left (AwsStackAwsAccountInvalid (awsScopeAccountId awsScope))
  if validAwsRegion (awsScopeRegion awsScope)
    then Right ()
    else Left (AwsStackAwsRegionInvalid (awsScopeRegion awsScope))

validAwsAccountId :: AwsAccountId -> Bool
validAwsAccountId (AwsAccountId accountId) =
  Text.length accountId == 12 && Text.all isAsciiDigit accountId

validAwsRegion :: AwsRegion -> Bool
validAwsRegion (AwsRegion region) =
  Text.length region >= 6
    && Text.length region <= 64
    && Text.head region /= '-'
    && Text.last region /= '-'
    && Text.all validRegionCharacter region
    && length regionSegments >= 3
    && all (not . Text.null) regionSegments
 where
  regionSegments = Text.splitOn "-" region
  validRegionCharacter character =
    isAsciiLower character || isAsciiDigit character || character == '-'

exactObservationForRequest
  :: AwsStackObservationRequest purpose
  -> ExactObservationResult
  -> ExactResourceObservation
exactObservationForRequest request =
  exactResourceObservationFor
    (awsStackBindingIdentity binding)
    (awsStackBindingRevision binding)
    (awsStackBindingScope binding)
 where
  binding = observationRequestBinding request

registeredStackAbsentEvidence :: Text
registeredStackAbsentEvidence = "registered stack is absent"

decodeObservationEvidence :: Text -> Maybe ExactObservationResult
decodeObservationEvidence evidence
  | evidence == registeredStackAbsentEvidence =
      Just (ExactResourceAbsent (AbsenceEvidence evidence))
  | validSha256Identity evidence =
      Just
        ( ExactResourcePresent
            ( ExactResourceInventory
                (ObservedResourceIdentity evidence :| [])
            )
        )
  | otherwise = Nothing

validSha256Identity :: Text -> Bool
validSha256Identity evidence = case Text.stripPrefix "sha256:" evidence of
  Just digest ->
    Text.length digest == 64
      && Text.all
        (\character -> isAsciiDigit character || character >= 'a' && character <= 'f')
        digest
  Nothing -> False

isAsciiDigit :: Char -> Bool
isAsciiDigit character = character >= '0' && character <= '9'

executionResultCoordinate
  :: ProviderIntentExecutionResult -> ProviderIntentCoordinate
executionResultCoordinate executionResult = case executionResult of
  ProviderIntentExecutionApplied coordinate _ -> coordinate
  ProviderIntentExecutionAlreadySatisfied coordinate _ -> coordinate
  ProviderIntentExecutionObserved coordinate _ -> coordinate

renderObservationRefusal :: AwsStackObservationRefusal -> Text
renderObservationRefusal refusal = case refusal of
  AwsStackObservationCoordinateMismatch {} ->
    "aws stack observation coordinate mismatch"
  AwsStackObservationResultKindMismatch kind ->
    "aws stack observation result kind mismatch: " <> Text.pack (show kind)
  AwsStackObservationEvidenceNotRecognized _ ->
    "aws stack observation evidence is not recognized"
