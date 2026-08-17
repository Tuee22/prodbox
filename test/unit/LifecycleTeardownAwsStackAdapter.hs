{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsStackAdapter
  ( lifecycleTeardownAwsStackAdapterSuite
  )
where

import Control.Monad (forM_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderRevision
  , ProviderStackConfig (..)
  , ProviderStackConfigError (..)
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  , providerIntentCoordinate
  , providerStackConfigRef
  , providerStackRefText
  )
import Prodbox.Lifecycle.Teardown.AwsStackAdapter
import Prodbox.Lifecycle.Teardown.Decision
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsStackAdapterSuite :: SuiteBuilder ()
lifecycleTeardownAwsStackAdapterSuite =
  describe "Sprint 4.85 exact AWS stack ProviderIntent adapter" $ do
    it "binds each registered AWS stack to its closed observe intent and exact scope" $ do
      forM_ stackRows $ \(key, rawRef, _) -> do
        let request = mustRight (mkAwsStackObserveRequest key exactScope initialRevision)
        awsStackObservationRequestKey request `shouldBe` key
        providerStackRefText (awsStackObservationRequestRef request) `shouldBe` rawRef
        awsStackObservationRequestScope request `shouldBe` exactScope
        awsStackObservationRequestRevision request `shouldBe` initialRevision
        awsStackObservationRequestIntent request
          `shouldBe` ObserveRegisteredStack (awsStackObservationRequestRef request)
        awsStackObservationRequestCoordinate request
          `shouldBe` providerIntentCoordinate (awsStackObservationRequestIntent request)

    it "refuses unsupported keys and non-exact desired-absence AWS scopes" $ do
      mkAwsStackObserveRequest AwsEbsPerRunTestKey exactScope initialRevision
        `shouldBe` Left (AwsStackKeyUnsupported AwsEbsPerRunTestKey)
      mkAwsStackObserveRequest AwsEksKey scopeWithoutAws initialRevision
        `shouldBe` Left AwsStackAwsScopeMissing
      mkAwsStackObserveRequest AwsEksKey staleRegistryScope initialRevision
        `shouldBe` Left
          ( AwsStackRegistryRevisionMismatch
              lifecycleRegistryRevision
              staleRegistryRevision
          )
      mkAwsStackObserveRequest AwsEksKey desiredPresentScope initialRevision
        `shouldBe` Left
          ( AwsStackLifecycleOperationMismatch
              ReconcileDesiredAbsent
              ReconcileDesiredPresent
          )
      mkAwsStackObserveRequest AwsEksKey localOnlyScope initialRevision
        `shouldBe` Left (AwsStackCleanupSurfaceInvalid AwsEksKey LocalOnly)
      mkAwsStackObserveRequest AwsEksKey invalidAccountScope initialRevision
        `shouldBe` Left (AwsStackAwsAccountInvalid (AwsAccountId "123"))
      mkAwsStackObserveRequest AwsEksKey invalidRegionScope initialRevision
        `shouldBe` Left (AwsStackAwsRegionInvalid (AwsRegion "US-East-1"))

    it "decodes only the exact absence literal or a strict lower-hex SHA-256 identity" $ do
      forM_ stackRows $ \(key, _, _) -> do
        let request = observeRequest key
            absent = decodeEvidence request exactAbsenceEvidence
            present = decodeEvidence request exactPresentIdentity
        case absent of
          AwsStackObservationDecoded verified -> do
            let observation = verifiedAwsStackExactObservation verified
            assertExactBinding request observation
            exactObservationResult observation
              `shouldBe` ExactResourceAbsent (AbsenceEvidence exactAbsenceEvidence)
          AwsStackObservationRejected refusal _ ->
            expectationFailure ("exact absence refused: " <> show refusal)
        case present of
          AwsStackObservationDecoded verified -> do
            let observation = verifiedAwsStackExactObservation verified
            assertExactBinding request observation
            exactObservationResult observation
              `shouldBe` ExactResourcePresent
                ( ExactResourceInventory
                    (ObservedResourceIdentity exactPresentIdentity :| [])
                )
          AwsStackObservationRejected refusal _ ->
            expectationFailure ("exact present identity refused: " <> show refusal)

    it "turns every malformed or other evidence value into typed unobservable truth" $ do
      let request = observeRequest AwsEksKey
      forM_ malformedEvidence $ \evidence ->
        case decodeEvidence request evidence of
          AwsStackObservationRejected refusal observation -> do
            refusal `shouldBe` AwsStackObservationEvidenceNotRecognized evidence
            assertExactBinding request observation
            exactObservationResult observation `shouldSatisfy` isUnobservable
            exactObservationResult observation `shouldSatisfy` isNotAbsent
          AwsStackObservationDecoded _ ->
            expectationFailure ("malformed evidence decoded: " <> Text.unpack evidence)

    it "refuses wrong-key, cross-purpose, Applied, and AlreadySatisfied results" $ do
      let request = observeRequest AwsEksKey
          otherRequest = observeRequest AwsEksSubzoneKey
          expectedCoordinate = awsStackObservationRequestCoordinate request
          otherCoordinate = awsStackObservationRequestCoordinate otherRequest
      assertRejected
        request
        (ProviderIntentExecutionObserved otherCoordinate exactAbsenceEvidence)
        (AwsStackObservationCoordinateMismatch expectedCoordinate otherCoordinate)
      assertRejected
        request
        (ProviderIntentExecutionApplied expectedCoordinate exactAbsenceEvidence)
        (AwsStackObservationResultKindMismatch AwsStackExecutionApplied)
      assertRejected
        request
        ( ProviderIntentExecutionAlreadySatisfied
            expectedCoordinate
            exactAbsenceEvidence
        )
        (AwsStackObservationResultKindMismatch AwsStackExecutionAlreadySatisfied)
      let destroy = destroyRequestFor AwsTestKey testConfig providerRevision
          readBack = mkAwsStackDestroyReadBackRequest destroy readBackRevision
          readBackCoordinate = awsStackObservationRequestCoordinate readBack
      assertRejected
        request
        (ProviderIntentExecutionObserved readBackCoordinate exactAbsenceEvidence)
        (AwsStackObservationCoordinateMismatch expectedCoordinate readBackCoordinate)

    it "mints private destroy authority only from primary or complete-manifest decisions" $ do
      let verifiedPresent = decodedVerified (observeRequest AwsTestKey) exactPresentIdentity
          primaryDecision =
            StackDestroyFromVerifiedPrimary AwsTestKey primaryAuthority
          manifestDecision =
            StackDestroyFromVerifiedManifest AwsTestKey manifestAuthority
      forM_
        [ (primaryDecision, AwsStackDestroyFromPrimaryCheckpoint)
        , (manifestDecision, AwsStackDestroyFromCompleteManifest)
        ]
        $ \(decision, expectedKind) -> do
          let authorization =
                mustRight
                  (authorizeAwsStackDestroy providerRevision verifiedPresent decision)
          awsStackDestroyAuthorizationKey authorization `shouldBe` AwsTestKey
          awsStackDestroyAuthorizationScope authorization `shouldBe` exactScope
          awsStackDestroyAuthorizationProviderRevision authorization
            `shouldBe` providerRevision
          awsStackDestroyAuthorizationKind authorization `shouldBe` expectedKind
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        (StackAlreadyAbsent AwsTestKey (AbsenceEvidence exactAbsenceEvidence))
        `shouldBe` Left AwsStackDestroyDecisionAlreadyAbsent
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        (StackRestoreBackupThenDestroy AwsTestKey backupAuthority)
        `shouldBe` Left AwsStackDestroyCheckpointRestoreRequired
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        refusedDecision
        `shouldBe` Left (AwsStackDestroyDecisionRefused decisionFailures)
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        (StackDestroyFromVerifiedPrimary AwsEksSubzoneKey primaryAuthority)
        `shouldBe` Left
          (AwsStackDestroyDecisionKeyMismatch AwsTestKey AwsEksSubzoneKey)
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        (StackDestroyFromVerifiedPrimary AwsTestKey manifestAuthority)
        `shouldBe` Left (AwsStackDestroyDecisionAuthorityMismatch manifestAuthority)
      let verifiedAbsent = decodedVerified (observeRequest AwsTestKey) exactAbsenceEvidence
      authorizeAwsStackDestroy
        providerRevision
        verifiedAbsent
        primaryDecision
        `shouldBe` Left AwsStackDestroyObservationAlreadyAbsent
      let eksVerified = decodedVerified (observeRequest AwsEksKey) exactPresentIdentity
      authorizeAwsStackDestroy
        providerRevision
        eksVerified
        (StackDestroyFromVerifiedPrimary AwsEksKey primaryAuthority)
        `shouldBe` Left AwsStackDestroyEksDrainAuthorizationRequired

    it "validates stack config and sealed revision before returning DestroyRegisteredStack" $ do
      forM_ genericDestroyRows $ \(key, _, config) -> do
        let destroy = destroyRequestFor key config providerRevision
        awsStackDestroyRequestKey destroy `shouldBe` key
        awsStackDestroyRequestScope destroy `shouldBe` exactScope
        awsStackDestroyRequestIntent destroy
          `shouldBe` DestroyRegisteredStack
            (providerStackConfigRef config)
            providerRevision
            config
        awsStackDestroyRequestCoordinate destroy
          `shouldBe` providerIntentCoordinate (awsStackDestroyRequestIntent destroy)
      let authorization = destroyAuthorizationFor AwsTestKey providerRevision
      mkAwsStackDestroyRequest authorization otherProviderRevision testConfig
        `shouldBe` Left
          ( AwsStackDestroyProviderRevisionMismatch
              providerRevision
              otherProviderRevision
          )
      mkAwsStackDestroyRequest authorization providerRevision eksConfig
        `shouldBe` Left
          ( AwsStackDestroyConfigInvalid
              ( ProviderStackConfigStackMismatch
                  (providerStackConfigRef testConfig)
                  (providerStackConfigRef eksConfig)
              )
          )
      let malformedConfig = AwsTestProviderStackConfig "0.0.0.0/0"
      mkAwsStackDestroyRequest authorization providerRevision malformedConfig
        `shouldBe` Left
          ( AwsStackDestroyConfigInvalid
              (ProviderStackConfigFieldInvalid "operator-cidr")
          )

    it "requires a separately coordinated exact-absence read-back to close destroy" $ do
      let destroy = destroyRequestFor AwsTestKey testConfig providerRevision
          readBack = mkAwsStackDestroyReadBackRequest destroy readBackRevision
      awsStackObservationRequestKey readBack `shouldBe` AwsTestKey
      awsStackObservationRequestScope readBack `shouldBe` exactScope
      awsStackObservationRequestRevision readBack `shouldBe` readBackRevision
      awsStackObservationRequestIntent readBack
        `shouldBe` ReadBackRegisteredStack (awsStackObservationRequestRef readBack)
      let directDestroyResult =
            ProviderIntentExecutionApplied
              (awsStackDestroyRequestCoordinate destroy)
              exactAbsenceEvidence
      case decodeAwsStackExecutionResult readBack directDestroyResult of
        AwsStackObservationRejected _ observation ->
          exactObservationResult observation `shouldSatisfy` isUnobservable
        AwsStackObservationDecoded _ ->
          expectationFailure "destroy apply result entered read-back proof"
      let stillPresent = decodedVerified readBack exactPresentIdentity
      completeAwsStackDestroyReadBack destroy stillPresent
        `shouldBe` Left
          ( AwsStackDestroyReadBackStillPresent
              ( ExactResourceInventory
                  (ObservedResourceIdentity exactPresentIdentity :| [])
              )
          )
      let absentReadBack = decodedVerified readBack exactAbsenceEvidence
          completed = mustRight (completeAwsStackDestroyReadBack destroy absentReadBack)
      completeAwsStackDestroyKey completed `shouldBe` AwsTestKey
      completeAwsStackDestroyScope completed `shouldBe` exactScope
      completeAwsStackDestroyObservationRevision completed `shouldBe` readBackRevision
      completeAwsStackDestroyAbsenceEvidence completed
        `shouldBe` AbsenceEvidence exactAbsenceEvidence
      let otherDestroy = destroyRequestFor AwsTestKey testConfig otherProviderRevision
          otherReadBack =
            mkAwsStackDestroyReadBackRequest otherDestroy readBackRevision
          otherVerified = decodedVerified otherReadBack exactAbsenceEvidence
      completeAwsStackDestroyReadBack destroy otherVerified
        `shouldBe` Left
          ( AwsStackDestroyReadBackParentMismatch
              (awsStackDestroyRequestCoordinate destroy)
              (awsStackDestroyRequestCoordinate otherDestroy)
          )

    it "keeps proof constructors private and the adapter free of runtime effects" $ do
      source <- readFile "src/Prodbox/Lifecycle/Teardown/AwsStackAdapter.hs"
      let moduleHeader = takeWhile (/= "where") (lines source)
      unlines moduleHeader `shouldNotContain` "AwsStackObservationRequest (..)"
      unlines moduleHeader `shouldNotContain` "VerifiedAwsStackObservation (..)"
      unlines moduleHeader `shouldNotContain` "AwsStackDestroyAuthorization (..)"
      unlines moduleHeader `shouldNotContain` "AwsStackDestroyRequest (..)"
      unlines moduleHeader `shouldNotContain` "CompleteAwsStackDestroy (..)"
      source `shouldNotContain` "Prodbox.ControlPlane.ProviderProduction"
      source `shouldNotContain` "Prodbox.CLI.Rke2"
      source `shouldNotContain` "Prodbox.TestRunner"
      source `shouldNotContain` "IO "
      source `shouldNotContain` "FilePath"
      observeSignature `shouldSatisfy` const True
      destroyAuthorizationSignature `shouldSatisfy` const True
      readBackSignature `shouldSatisfy` const True

stackRows :: [(RegisteredResourceKey, Text, ProviderStackConfig)]
stackRows =
  [ (AwsEksKey, "aws-eks", eksConfig)
  , (AwsEksSubzoneKey, "aws-eks-subzone", subzoneConfig)
  , (AwsTestKey, "aws-test", testConfig)
  ]

genericDestroyRows :: [(RegisteredResourceKey, Text, ProviderStackConfig)]
genericDestroyRows =
  [ (AwsEksSubzoneKey, "aws-eks-subzone", subzoneConfig)
  , (AwsTestKey, "aws-test", testConfig)
  ]

exactScope :: ObservationEvidenceScope
exactScope = scopeFor Cascade lifecycleRegistryRevision validAwsScope ReconcileDesiredAbsent

scopeWithoutAws :: ObservationEvidenceScope
scopeWithoutAws = scopeFor Cascade lifecycleRegistryRevision Nothing ReconcileDesiredAbsent

staleRegistryScope :: ObservationEvidenceScope
staleRegistryScope =
  scopeFor Cascade staleRegistryRevision validAwsScope ReconcileDesiredAbsent

desiredPresentScope :: ObservationEvidenceScope
desiredPresentScope =
  scopeFor Cascade lifecycleRegistryRevision validAwsScope ReconcileDesiredPresent

localOnlyScope :: ObservationEvidenceScope
localOnlyScope =
  scopeFor LocalOnly lifecycleRegistryRevision validAwsScope ReconcileDesiredAbsent

invalidAccountScope :: ObservationEvidenceScope
invalidAccountScope =
  scopeFor
    Cascade
    lifecycleRegistryRevision
    (Just (AwsScope (AwsAccountId "123") (AwsRegion "us-east-1")))
    ReconcileDesiredAbsent

invalidRegionScope :: ObservationEvidenceScope
invalidRegionScope =
  scopeFor
    Cascade
    lifecycleRegistryRevision
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "US-East-1")))
    ReconcileDesiredAbsent

scopeFor
  :: CleanupSurface
  -> RegistryRevision
  -> Maybe AwsScope
  -> LifecycleOperation
  -> ObservationEvidenceScope
scopeFor surface registryRevision awsScope operation =
  mkObservationEvidenceScope
    surface
    registryRevision
    (DurableObservationRunScope "aws-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    awsScope
    operation

validAwsScope :: Maybe AwsScope
validAwsScope =
  Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1"))

staleRegistryRevision :: RegistryRevision
staleRegistryRevision = RegistryRevision "lifecycle-registry/stale"

initialRevision :: ObservationRevision
initialRevision = ObservationRevision 41

readBackRevision :: ObservationRevision
readBackRevision = ObservationRevision 42

exactAbsenceEvidence :: Text
exactAbsenceEvidence = "registered stack is absent"

exactPresentIdentity :: Text
exactPresentIdentity = "sha256:" <> Text.replicate 64 "a"

malformedEvidence :: [Text]
malformedEvidence =
  [ "registered stack is absent "
  , "Registered stack is absent"
  , "stack is absent"
  , "sha256:" <> Text.replicate 63 "a"
  , "sha256:" <> Text.replicate 65 "a"
  , "sha256:" <> Text.replicate 63 "a" <> "A"
  , "SHA256:" <> Text.replicate 64 "a"
  , "sha256:" <> Text.replicate 63 "a" <> "\n"
  , "some stack output"
  ]

observeRequest
  :: RegisteredResourceKey
  -> AwsStackObservationRequest 'ObserveStackForDecision
observeRequest key = mustRight (mkAwsStackObserveRequest key exactScope initialRevision)

decodeEvidence
  :: AwsStackObservationRequest purpose
  -> Text
  -> AwsStackObservationDecode purpose
decodeEvidence request evidence =
  decodeAwsStackExecutionResult
    request
    ( ProviderIntentExecutionObserved
        (awsStackObservationRequestCoordinate request)
        evidence
    )

decodedVerified
  :: AwsStackObservationRequest purpose
  -> Text
  -> VerifiedAwsStackObservation purpose
decodedVerified request evidence = case decodeEvidence request evidence of
  AwsStackObservationDecoded verified -> verified
  AwsStackObservationRejected refusal _ ->
    error ("expected verified AWS stack observation, got " <> show refusal)

assertExactBinding
  :: AwsStackObservationRequest purpose
  -> ExactResourceObservation
  -> Expectation
assertExactBinding request observation = do
  exactObservationResourceKey observation
    `shouldBe` awsStackObservationRequestKey request
  exactObservationCoordinateDigest observation
    `shouldBe` registeredIdentityCoordinateDigest
      (mustIdentity (awsStackObservationRequestKey request))
  exactObservationAuthority observation `shouldBe` AwsResourceApiAuthority
  exactObservationRevision observation
    `shouldBe` awsStackObservationRequestRevision request
  exactObservationEvidenceScope observation
    `shouldBe` awsStackObservationRequestScope request

assertRejected
  :: AwsStackObservationRequest purpose
  -> ProviderIntentExecutionResult
  -> AwsStackObservationRefusal
  -> Expectation
assertRejected request executionResult expectedRefusal =
  case decodeAwsStackExecutionResult request executionResult of
    AwsStackObservationRejected refusal observation -> do
      refusal `shouldBe` expectedRefusal
      exactObservationResult observation `shouldSatisfy` isUnobservable
      exactObservationResult observation `shouldSatisfy` isNotAbsent
    AwsStackObservationDecoded _ ->
      expectationFailure "mismatched provider result decoded as exact truth"

isUnobservable :: ExactObservationResult -> Bool
isUnobservable result = case result of
  ExactResourceUnobservable _ -> True
  _ -> False

isNotAbsent :: ExactObservationResult -> Bool
isNotAbsent result = case result of
  ExactResourceAbsent _ -> False
  _ -> True

primaryAuthority :: StackCleanupAuthority
primaryAuthority =
  VerifiedPrimaryCheckpoint
    (CheckpointProvenance "primary://aws-eks")
    (CheckpointVersion "primary-v1")

backupAuthority :: StackCleanupAuthority
backupAuthority =
  VerifiedBackupCheckpoint
    (CheckpointProvenance "backup://aws-eks")
    (CheckpointVersion "backup-v1")

manifestAuthority :: StackCleanupAuthority
manifestAuthority =
  VerifiedOwnershipManifest
    (OwnershipManifestProvenance "manifest://aws-eks")
    (OwnershipManifestVersion "manifest-v1")

decisionFailures :: NonEmpty StackDecisionRefusal
decisionFailures = StackOwnershipManifestAbsent :| []

refusedDecision :: StackDesiredAbsenceDecision
refusedDecision = StackDesiredAbsenceRefused AwsEksKey decisionFailures

providerRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 7)

otherProviderRevision :: ProviderRevision
otherProviderRevision = mustRight (mkProviderRevision 8)

eksConfig :: ProviderStackConfig
eksConfig = mustRight (mkAwsEksProviderStackConfig "203.0.113.10/32")

subzoneConfig :: ProviderStackConfig
subzoneConfig =
  mustRight
    ( mkAwsEksSubzoneProviderStackConfig
        "Z0123456789"
        "test.example.com"
    )

testConfig :: ProviderStackConfig
testConfig = mustRight (mkAwsTestProviderStackConfig "203.0.113.10/32")

destroyAuthorizationFor
  :: RegisteredResourceKey
  -> ProviderRevision
  -> AwsStackDestroyAuthorization
destroyAuthorizationFor key revision =
  mustRight
    ( authorizeAwsStackDestroy
        revision
        (decodedVerified (observeRequest key) exactPresentIdentity)
        (StackDestroyFromVerifiedPrimary key primaryAuthority)
    )

destroyRequestFor
  :: RegisteredResourceKey
  -> ProviderStackConfig
  -> ProviderRevision
  -> AwsStackDestroyRequest
destroyRequestFor key config revision =
  mustRight
    ( mkAwsStackDestroyRequest
        (destroyAuthorizationFor key revision)
        revision
        config
    )

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Just identity -> identity
  Nothing -> error ("missing registered identity: " <> show key)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)

observeSignature
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ObservationRevision
  -> Either
       AwsStackBindingError
       (AwsStackObservationRequest 'ObserveStackForDecision)
observeSignature = mkAwsStackObserveRequest

destroyAuthorizationSignature
  :: ProviderRevision
  -> VerifiedAwsStackObservation 'ObserveStackForDecision
  -> StackDesiredAbsenceDecision
  -> Either AwsStackDestroyRefusal AwsStackDestroyAuthorization
destroyAuthorizationSignature = authorizeAwsStackDestroy

readBackSignature
  :: AwsStackDestroyRequest
  -> ObservationRevision
  -> AwsStackObservationRequest 'ReadBackDestroyedStack
readBackSignature = mkAwsStackDestroyReadBackRequest
