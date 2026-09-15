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
import Prodbox.Lifecycle.DnsRecord (mkHostedZoneId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderNativeStackFamilyRef
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackConfigError (..)
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  , providerIntentCoordinate
  , providerNativeStackFamilyHostedZoneId
  , providerStackConfigRef
  , providerStackRefText
  , registeredStackAbsenceEvidence
  , validateProviderIntentEvidence
  )
import Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
  ( AwsNativeStackFamilyAdapterError (AwsNativeStackFamilyZoneMissing)
  , encodeAwsNativeStackFamilyEvidence
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

    it "decodes only its own coordinate's absence arm or a strict lower-hex SHA-256 identity" $ do
      forM_ stackRows $ \(key, rawRef, _) -> do
        let request = observeRequest key
            absent = decodeEvidence request (absenceEvidenceFor rawRef)
            present = decodeEvidence request exactPresentIdentity
        case absent of
          AwsStackObservationDecoded verified -> do
            let observation = verifiedAwsStackExactObservation verified
            assertExactBinding request observation
            exactObservationResult observation
              `shouldBe` ExactResourceAbsent (providerWorkerAbsence (absenceEvidenceFor rawRef))
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

    it "refuses an absence arm that names a different registered stack" $ do
      -- Sprint 4.98.  The superseded wire carried the bare sentence
      -- "registered stack is absent", authored independently on each side, so
      -- an absence observed for one stack satisfied a request for any other and
      -- nothing in the type system or the decoder could tell.  The arm now
      -- carries its coordinate, and this is the case that would have caught it.
      let request = observeRequest AwsEksKey
      case decodeEvidence request testAbsenceEvidence of
        AwsStackObservationRejected refusal observation -> do
          refusal `shouldBe` AwsStackObservationEvidenceNotRecognized testAbsenceEvidence
          assertExactBinding request observation
          exactObservationResult observation `shouldSatisfy` isNotAbsent
        AwsStackObservationDecoded _ ->
          expectationFailure "an aws-test absence answered an aws-eks request"
      -- ...and the matching coordinate still decodes, so the refusal above is
      -- the coordinate check rather than a broken parse.
      case decodeEvidence request eksAbsenceEvidence of
        AwsStackObservationDecoded _ -> pure ()
        AwsStackObservationRejected refusal _ ->
          expectationFailure ("own-coordinate absence refused: " <> show refusal)

    it "renders an absence arm the Provider Worker's own validator admits" $ do
      -- The superseded shape could not have failed this, being an English
      -- sentence.  The replacement could: a coordinate-carrying rendering is
      -- exactly where a separator or a bound gets chosen badly, and the
      -- validator that would refuse it lives nowhere near the encoder.  This
      -- asserts the two agree, for each stack's own intent rather than in
      -- general.
      forM_ stackRows $ \(key, rawRef, _) -> do
        let intent = awsStackObservationRequestIntent (observeRequest key)
            evidence = absenceEvidenceFor rawRef
        validateProviderIntentEvidence intent evidence `shouldBe` Right evidence

    it "turns every malformed or other evidence value into typed unobservable truth" $ do
      let request = observeRequest AwsEksKey
          checkMalformedEvidence evidence = case decodeEvidence request evidence of
            AwsStackObservationRejected refusal observation -> do
              refusal `shouldBe` AwsStackObservationEvidenceNotRecognized evidence
              assertExactBinding request observation
              exactObservationResult observation `shouldSatisfy` isUnobservable
              exactObservationResult observation `shouldSatisfy` isNotAbsent
            AwsStackObservationDecoded _ ->
              expectationFailure ("malformed evidence decoded: " <> Text.unpack evidence)
      forM_ malformedEvidence checkMalformedEvidence

    it "refuses wrong-key, cross-purpose, Applied, and AlreadySatisfied results" $ do
      let request = observeRequest AwsEksKey
          otherRequest = observeRequest AwsEksSubzoneKey
          expectedCoordinate = awsStackObservationRequestCoordinate request
          otherCoordinate = awsStackObservationRequestCoordinate otherRequest
      assertRejected
        request
        (ProviderIntentExecutionObserved otherCoordinate eksAbsenceEvidence)
        (AwsStackObservationCoordinateMismatch expectedCoordinate otherCoordinate)
      assertRejected
        request
        (ProviderIntentExecutionApplied expectedCoordinate eksAbsenceEvidence)
        (AwsStackObservationResultKindMismatch AwsStackExecutionApplied)
      assertRejected
        request
        ( ProviderIntentExecutionAlreadySatisfied
            expectedCoordinate
            eksAbsenceEvidence
        )
        (AwsStackObservationResultKindMismatch AwsStackExecutionAlreadySatisfied)
      let destroy = destroyRequestFor AwsTestKey testConfig providerRevision
          readBack = mkAwsStackDestroyReadBackRequest destroy readBackRevision
          readBackCoordinate = awsStackObservationRequestCoordinate readBack
      assertRejected
        request
        (ProviderIntentExecutionObserved readBackCoordinate eksAbsenceEvidence)
        (AwsStackObservationCoordinateMismatch expectedCoordinate readBackCoordinate)

    it "mints private destroy authority only from primary or complete-manifest decisions" $ do
      let verifiedPresent = decodedVerified (observeRequest AwsTestKey) exactPresentIdentity
          primaryDecision =
            StackDestroyFromVerifiedPrimary AwsTestKey decisionInventory primaryAuthority
          manifestDecision =
            StackDestroyFromVerifiedManifest AwsTestKey decisionInventory manifestAuthority
      forM_
        [ (primaryDecision, AwsStackDestroyFromPrimaryCheckpoint)
        ,
          ( manifestDecision
          , AwsStackDestroyFromCompleteManifest ["vpc/vpc-1", exactPresentIdentity]
          )
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
        (StackAlreadyAbsent AwsTestKey (providerWorkerAbsence testAbsenceEvidence))
        `shouldBe` Left AwsStackDestroyDecisionAlreadyAbsent
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        (StackRestoreBackupThenDestroy AwsTestKey decisionInventory backupAuthority)
        `shouldBe` Left AwsStackDestroyCheckpointRestoreRequired
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        refusedDecision
        `shouldBe` Left (AwsStackDestroyDecisionRefused decisionFailures)
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        (StackDestroyFromVerifiedPrimary AwsEksSubzoneKey decisionInventory primaryAuthority)
        `shouldBe` Left
          (AwsStackDestroyDecisionKeyMismatch AwsTestKey AwsEksSubzoneKey)
      authorizeAwsStackDestroy
        providerRevision
        verifiedPresent
        (StackDestroyFromVerifiedPrimary AwsTestKey decisionInventory manifestAuthority)
        `shouldBe` Left (AwsStackDestroyDecisionAuthorityMismatch manifestAuthority)
      let verifiedAbsent = decodedVerified (observeRequest AwsTestKey) testAbsenceEvidence
      authorizeAwsStackDestroy
        providerRevision
        verifiedAbsent
        primaryDecision
        `shouldBe` Left AwsStackDestroyObservationAlreadyAbsent
      let eksVerified = decodedVerified (observeRequest AwsEksKey) exactPresentIdentity
      authorizeAwsStackDestroy
        providerRevision
        eksVerified
        (StackDestroyFromVerifiedPrimary AwsEksKey decisionInventory primaryAuthority)
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
      mkAwsTestProviderStackConfig "0.0.0.0/0"
        `shouldBe` Left (ProviderStackConfigFieldInvalid "operator-cidr")

    it "selects the provider-native reaper only for complete-manifest authority" $ do
      let nativeObserve =
            mustRight
              ( mkAwsNativeStackObserveRequest
                  AwsTestKey
                  exactScope
                  initialRevision
                  testConfig
              )
          nativeRef = case awsStackObservationRequestIntent nativeObserve of
            ObserveNativeStackFamily ref _ -> ref
            _ -> error "expected native stack-family observation"
          presentEvidence =
            mustRight (encodeAwsNativeStackFamilyEvidence nativeRef ["vpc/vpc-1"])
          verified = decodedVerified nativeObserve presentEvidence
          authorization =
            mustRight
              ( authorizeAwsStackDestroy
                  providerRevision
                  verified
                  (StackDestroyFromVerifiedManifest AwsTestKey decisionInventory manifestAuthority)
              )
          request =
            mustRight
              (mkAwsStackDestroyRequest authorization providerRevision testConfig)
      awsStackDestroyRequestIntent request
        `shouldBe` ReapNativeStackFamily
          nativeRef
          testConfig
          ["vpc/vpc-1", exactPresentIdentity]
      awsStackObservationRequestIntent
        (mkAwsStackDestroyReadBackRequest request readBackRevision)
        `shouldBe` ObserveNativeStackFamily nativeRef testConfig

    it "projects the shared DNS coordinate only into the subzone native family" $ do
      mkAwsNativeStackObserveRequest
        AwsEksSubzoneKey
        exactScope
        initialRevision
        subzoneConfig
        `shouldBe` Left
          (AwsStackNativeFamilyInvalid AwsNativeStackFamilyZoneMissing)
      let subzoneRequest =
            mustRight
              ( mkAwsNativeStackObserveRequest
                  AwsEksSubzoneKey
                  exactScopeWithDnsZone
                  initialRevision
                  subzoneConfig
              )
          eksRequest =
            mustRight
              ( mkAwsNativeStackObserveRequest
                  AwsEksKey
                  exactScopeWithDnsZone
                  initialRevision
                  eksConfig
              )
          testRequest =
            mustRight
              ( mkAwsNativeStackObserveRequest
                  AwsTestKey
                  exactScopeWithDnsZone
                  initialRevision
                  testConfig
              )
      providerNativeStackFamilyHostedZoneId (nativeRequestRef subzoneRequest)
        `shouldBe` Just "ZSUBZONE123"
      providerNativeStackFamilyHostedZoneId (nativeRequestRef eksRequest) `shouldBe` Nothing
      providerNativeStackFamilyHostedZoneId (nativeRequestRef testRequest) `shouldBe` Nothing

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
              testAbsenceEvidence
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
      let absentReadBack = decodedVerified readBack testAbsenceEvidence
          completed = mustRight (completeAwsStackDestroyReadBack destroy absentReadBack)
      completeAwsStackDestroyKey completed `shouldBe` AwsTestKey
      completeAwsStackDestroyScope completed `shouldBe` exactScope
      completeAwsStackDestroyObservationRevision completed `shouldBe` readBackRevision
      completeAwsStackDestroyAbsenceEvidence completed
        `shouldBe` providerWorkerAbsence testAbsenceEvidence
      let otherDestroy = destroyRequestFor AwsTestKey testConfig otherProviderRevision
          otherReadBack =
            mkAwsStackDestroyReadBackRequest otherDestroy readBackRevision
          otherVerified = decodedVerified otherReadBack testAbsenceEvidence
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

exactScopeWithDnsZone :: ObservationEvidenceScope
exactScopeWithDnsZone =
  mkObservationEvidenceScopeWithDnsZone
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "aws-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    validAwsScope
    (mustRight (mkHostedZoneId "ZSUBZONE123"))
    ReconcileDesiredAbsent

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
    (Just (AwsScope (AwsAccountId "123") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
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
  Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1)))

staleRegistryRevision :: RegistryRevision
staleRegistryRevision = RegistryRevision "lifecycle-registry/stale"

initialRevision :: ObservationRevision
initialRevision = ObservationRevision 41

readBackRevision :: ObservationRevision
readBackRevision = ObservationRevision 42

-- | Sprint @4.98@: the absence arm carries the coordinate it is about, so a
-- fixture is a function of the stack it answers for rather than one sentence
-- that answered for all three.  It is rendered by the production encoder, so a
-- test can no longer drift from the wire the way the two authored copies of the
-- old literal did.
absenceEvidenceFor :: Text -> Text
absenceEvidenceFor raw =
  registeredStackAbsenceEvidence (mustRight (mkProviderStackRef raw))

eksAbsenceEvidence :: Text
eksAbsenceEvidence = absenceEvidenceFor "aws-eks"

testAbsenceEvidence :: Text
testAbsenceEvidence = absenceEvidenceFor "aws-test"

exactPresentIdentity :: Text
exactPresentIdentity = "sha256:" <> Text.replicate 64 "a"

malformedEvidence :: [Text]
malformedEvidence =
  [ eksAbsenceEvidence <> " "
  , "prodbox-registered-stack/v1:absent:"
  , "prodbox-registered-stack/v2:absent:aws-eks"
  , "PRODBOX-REGISTERED-STACK/v1:absent:aws-eks"
  , "registered stack is absent"
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

nativeRequestRef :: AwsStackObservationRequest purpose -> ProviderNativeStackFamilyRef
nativeRequestRef request = case awsStackObservationRequestIntent request of
  ObserveNativeStackFamily ref _ -> ref
  other -> error ("expected native stack-family observation, got " <> show other)

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
    [ ObservedResourceIdentity "vpc/vpc-1"
    , ObservedResourceIdentity exactPresentIdentity
    ]

decisionFailures :: NonEmpty StackDecisionRefusal
decisionFailures = StackOwnershipManifestAbsent :| []

refusedDecision :: StackDesiredAbsenceDecision surface
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
        (StackDestroyFromVerifiedPrimary key decisionInventory primaryAuthority)
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
  -> StackDesiredAbsenceDecision surface
  -> Either AwsStackDestroyRefusal AwsStackDestroyAuthorization
destroyAuthorizationSignature = authorizeAwsStackDestroy

readBackSignature
  :: AwsStackDestroyRequest
  -> ObservationRevision
  -> AwsStackObservationRequest 'ReadBackDestroyedStack
readBackSignature = mkAwsStackDestroyReadBackRequest

-- | Sprint 4.97: the inventory the decision was taken over.
--
-- The destroy arms carry it now, so the manifest-identity comparison inside
-- `authorizeAwsStackDestroy` tests the manifest against the list the decision
-- saw rather than against a second, separately derived reading of the same
-- observation.
decisionInventory :: ExactResourceInventory
decisionInventory =
  ExactResourceInventory (ObservedResourceIdentity exactPresentIdentity :| [])
