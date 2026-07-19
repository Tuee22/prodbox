{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.61 conformance suite: the operation-indexed capability algebra.
-- Pure tables prove the five illegal states are killed — wrong-operation
-- authority (phantom index + nominal role), a GET satisfying a write/CAS
-- (evidence value axis + ticket type axis), a duplicate coordinate (single
-- ownership), a raw mutation (opaque permit/intent), and a stale admission
-- (fail-closed) — plus the type↔value consistency of the permit tiers.
module ControlPlaneCapability
  ( controlPlaneCapabilitySuite
  )
where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane
import Prodbox.ControlPlane.CapabilityRequirement
  ( CapabilityProvisionSpec (..)
  , CapabilityRequirementSpec (..)
  , RequirementError (..)
  , matchesProvision
  , requirementOp
  , resolveProvision
  , resolveRequirement
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , RemainingDuration (RemainingDuration)
  , RetryAfter (RetryAfter)
  , deadlineAtOffset
  , deadlineFromInstant
  , monotonicInstantFromMicros
  )
import Prodbox.ControlPlane.Interpreter
  ( CapabilityClient (..)
  , CapabilityFailure
    ( FailureAmbiguous
    , FailureDeadlineExpired
    , FailureRefused
    , FailureSaturated
    , FailureUnavailable
    , FailureUnobservable
    )
  , CasRequest (casCoordinateDigest)
  , LaneFault (LaneAmbiguous, LaneUnavailable)
  , ObservedReading (..)
  , QueueAdmission (Admitted, Saturated)
  , runCapability
  )
import Prodbox.ControlPlane.SCapability
  ( SomeSCapability (SomeSCapability)
  , opToSCapability
  , sCapabilityOp
  , sCapabilityTier
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBObjectVersion, mkModelBObjectVersion)
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , mkCredentialGeneration
  , sha256TargetValueDigest
  )
import TestSupport

expectRight :: (Show err) => Either err value -> value
expectRight = either (error . show) id

field :: (Show err) => (Text -> Either err value) -> Text -> value
field make = expectRight . make

gen :: Natural -> CredentialGeneration
gen = expectRight . mkCredentialGeneration

ver :: Text -> ModelBObjectVersion
ver = expectRight . mkModelBObjectVersion

sampleCoordinate :: CapabilityCoordinate
sampleCoordinate =
  mkCoordinate
    (field mkServiceIdentity "lifecycle-authority")
    (field mkAuthorityScope "home/prodbox")
    (field mkCapabilityEndpoint "127.0.0.1:30443")
    (field mkLogicalName "leases/aws-ses")
    (gen 1)

-- | A DIFFERENT coordinate (different logical name) — a distinct digest.
otherCoordinate :: CapabilityCoordinate
otherCoordinate =
  mkCoordinate
    (field mkServiceIdentity "lifecycle-authority")
    (field mkAuthorityScope "home/prodbox")
    (field mkCapabilityEndpoint "127.0.0.1:30443")
    (field mkLogicalName "leases/aws-eks")
    (gen 1)

casRef :: CapabilityRef 'LifecycleCas
casRef = mkCapabilityRef sampleCoordinate

observeRef :: CapabilityRef 'LifecycleObserve
observeRef = mkCapabilityRef sampleCoordinate

sealRef :: CapabilityRef 'TargetSeal
sealRef = mkCapabilityRef sampleCoordinate

t0 :: AuthorityTime
t0 = authorityTimeFromMicros 1_000_000_000_000

freshNow :: AuthorityTime
freshNow = authorityTimeFromMicros (1_000_000_000_000 + 100_000_000) -- 100s after t0

staleNow :: AuthorityTime
staleNow = authorityTimeFromMicros (1_000_000_000_000 + 400_000_000) -- 400s after t0 (> 300s window)

readingWith :: ExternalEvidence -> ObservationReading
readingWith evidence =
  ObservationReading
    { readingService = field mkServiceIdentity "lifecycle-authority"
    , readingAuthority = field mkAuthorityScope "home/prodbox"
    , readingGeneration = gen 1
    , readingObservedAt = t0
    , readingFreshnessBound = FreshnessWindow 300
    , readingEvidence = evidence
    }

roundTripEvidence :: ExternalEvidence
roundTripEvidence = EvidenceRoundTripConfirmed (RoundTripWitness (ver "cas-etag-1"))

verdictTag :: ReadinessVerdict k -> String
verdictTag verdict = case verdict of
  VerdictReady _ -> "Ready"
  VerdictPending _ -> "Pending"
  VerdictFailed _ -> "Failed"
  VerdictUnobservable _ -> "Unobservable"

statusTag :: ObservationStatus -> String
statusTag status = case status of
  Ready -> "Ready"
  Pending _ -> "Pending"
  Failed _ -> "Failed"
  Unobservable _ -> "Unobservable"

controlPlaneCapabilitySuite :: SuiteBuilder ()
controlPlaneCapabilitySuite =
  describe "Sprint 1.61 operation-indexed capability algebra" $ do
    describe "T1: coordinate / reference construction" $ do
      it "accepts well-formed fields and rejects empty ones" $ do
        (mkServiceIdentity "" :: Either CoordinateError ServiceIdentity)
          `shouldSatisfy` isLeft
        (mkCapabilityEndpoint "  " :: Either CoordinateError CapabilityEndpoint)
          `shouldSatisfy` isLeft
        (mkLogicalName "leases/aws-ses" :: Either CoordinateError LogicalName)
          `shouldSatisfy` isRight

      it "stamps the runtime operation tag from the static kind" $ do
        refCapabilityOp casRef `shouldBe` OpLifecycleCas
        refCapabilityOp observeRef `shouldBe` OpLifecycleObserve

      it "gives distinct digests to distinct coordinates" $
        (coordinateDigest sampleCoordinate == coordinateDigest otherCoordinate)
          `shouldBe` False

    describe "T2: permit-tier type↔value consistency" $ do
      it "classifies every operation into exactly one tier over the whole universe" $
        mapM_
          ( \op ->
              (permitTier op `elem` [TierObserveOnly, TierInternalCas, TierExternalIntent])
                `shouldBe` True
          )
          [minBound .. maxBound]

      it "keeps isMutating in agreement with the non-observe tiers" $
        mapM_
          (\op -> isMutating op `shouldBe` (permitTier op /= TierObserveOnly))
          [minBound .. maxBound]

      it "only requires round-trip evidence for mutating operations" $
        mapM_
          ( \op ->
              (not (requiresRoundTripEvidence op) || isMutating op) `shouldBe` True
          )
          [minBound .. maxBound]

    describe "T3: classifyEvidence — the GET-vs-write core" $ do
      it "lets a present-object GET satisfy an observe-only operation" $
        statusTag (classifyEvidence OpLifecycleObserve EvidencePresentReady) `shouldBe` "Ready"

      it "refuses a present-object GET as proof of a CAS operation" $
        statusTag (classifyEvidence OpLifecycleCas EvidencePresentReady) `shouldBe` "Pending"

      it "refuses a present-object GET as proof of an external apply" $
        statusTag (classifyEvidence OpProviderApply EvidencePresentReady) `shouldBe` "Pending"

      it "accepts a proven round trip for any operation" $ do
        statusTag (classifyEvidence OpLifecycleCas roundTripEvidence) `shouldBe` "Ready"
        statusTag (classifyEvidence OpProviderApply roundTripEvidence) `shouldBe` "Ready"

      it "never treats absent as ready and fails closed on unobservable/corrupt" $ do
        statusTag (classifyEvidence OpLifecycleObserve EvidenceAbsent) `shouldBe` "Pending"
        statusTag (classifyEvidence OpLifecycleObserve (EvidenceUnreachable "x")) `shouldBe` "Unobservable"
        statusTag (classifyEvidence OpLifecycleObserve (EvidenceCorrupt "x")) `shouldBe` "Unobservable"
        statusTag (classifyEvidence OpLifecycleObserve (EvidenceConflict "x")) `shouldBe` "Pending"

    describe "T4: classifyObservation — admission, fail-closed" $ do
      let expected = expectedAuthorityFromRef casRef
          readyObs = observationFromRef casRef (readingWith roundTripEvidence)
      it "admits a same-reference, fresh, round-trip-confirmed observation" $
        case classifyObservation freshNow expected readyObs of
          VerdictReady ticket ->
            admissionCoordinateDigest ticket `shouldBe` refCoordinateDigest casRef
          other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

      it "fails a coordinate-digest mismatch (a different authority's reading)" $
        verdictTag
          (classifyObservation freshNow (expected {expectDigest = coordinateDigest otherCoordinate}) readyObs)
          `shouldBe` "Failed"

      it "fails a service-identity mismatch" $
        verdictTag
          ( classifyObservation
              freshNow
              (expected {expectService = field mkServiceIdentity "impostor"})
              readyObs
          )
          `shouldBe` "Failed"

      it "fails closed (Unobservable) on a stale observation" $
        verdictTag (classifyObservation staleNow expected readyObs) `shouldBe` "Unobservable"

      it "holds Pending on a stale generation" $
        verdictTag (classifyObservation freshNow (expected {expectGeneration = gen 5}) readyObs)
          `shouldBe` "Pending"

      it "holds Pending when only a present-object GET (not a round trip) is observed for a CAS kind" $
        verdictTag
          (classifyObservation freshNow expected (observationFromRef casRef (readingWith EvidencePresentReady)))
          `shouldBe` "Pending"

    describe "T5/T6: the observe → admit → permit chain threads one coordinate" $ do
      let expected = expectedAuthorityFromRef casRef
          readyObs = observationFromRef casRef (readingWith roundTripEvidence)
          matchingFence =
            FenceEvidence
              { fenceOwner = expectRight (mkOwnerNonce "owner-1")
              , fenceToken = expectRight (mkFencingToken 7)
              , fenceVersion = ver "lease-etag"
              , fenceDigest = refCoordinateDigest casRef
              }
      it "authorizes a writer permit bound to the same coordinate as the reference" $
        case classifyObservation freshNow expected readyObs of
          VerdictReady ticket ->
            case authorizeInternalCas (gen 1) ticket matchingFence of
              Right permit -> permitCoordinateDigest permit `shouldBe` refCoordinateDigest casRef
              Left refusal -> expectationFailure ("unexpected permit refusal: " ++ show refusal)
          other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

      it "refuses a permit whose fence is for a different coordinate" $
        case classifyObservation freshNow expected readyObs of
          VerdictReady ticket ->
            case authorizeInternalCas (gen 1) ticket (matchingFence {fenceDigest = coordinateDigest otherCoordinate}) of
              Left (PermitCoordinateMismatch _ _) -> pure ()
              Left refusal -> expectationFailure ("expected PermitCoordinateMismatch, got " ++ show refusal)
              Right _ -> expectationFailure "expected PermitCoordinateMismatch, got a permit"
          other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

      it "refuses a permit when the ticket generation is stale" $
        case classifyObservation freshNow expected readyObs of
          VerdictReady ticket ->
            case authorizeInternalCas (gen 9) ticket matchingFence of
              Left (PermitGenerationStale _ _) -> pure ()
              Left refusal -> expectationFailure ("expected PermitGenerationStale, got " ++ show refusal)
              Right _ -> expectationFailure "expected PermitGenerationStale, got a permit"
          other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

    describe "T7: external intent sign / verify" $ do
      let expected = expectedAuthorityFromRef sealRef
          readyObs = observationFromRef sealRef (readingWith roundTripEvidence)
          fence =
            FenceEvidence
              { fenceOwner = expectRight (mkOwnerNonce "owner-1")
              , fenceToken = expectRight (mkFencingToken 7)
              , fenceVersion = ver "lease-etag"
              , fenceDigest = refCoordinateDigest sealRef
              }
          binding =
            IntentBinding
              { bindEpoch = AuthorityEpoch 4
              , bindFence = fence
              , bindAction = ActionDigest (sha256TargetValueDigest "seal-action")
              , bindGen = gen 1
              , bindDeadline = authorityTimeFromMicros 2_000_000_000_000
              }
          key = IntentSigningKey "intent-signing-key"
      it "prepares, signs, and verifies an intent bound to the reference coordinate" $
        case classifyObservation freshNow expected readyObs of
          VerdictReady ticket ->
            case prepareIntent freshNow (gen 1) ticket binding of
              Left refusal -> expectationFailure ("unexpected intent refusal: " ++ show refusal)
              Right unsigned ->
                case verifyIntent key (signIntent key unsigned) of
                  Right verified -> verifiedCoordinateDigest verified `shouldBe` refCoordinateDigest sealRef
                  Left refusal -> expectationFailure ("unexpected verify refusal: " ++ show refusal)
          other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

      it "rejects a signature verified under the wrong key" $
        case classifyObservation freshNow expected readyObs of
          VerdictReady ticket ->
            case prepareIntent freshNow (gen 1) ticket binding of
              Right unsigned ->
                verifyIntent (IntentSigningKey "wrong-key") (signIntent key unsigned)
                  `shouldSatisfy` isLeft
              Left refusal -> expectationFailure ("unexpected intent refusal: " ++ show refusal)
          other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

      it "refuses to prepare an intent past its deadline" $
        case classifyObservation freshNow expected readyObs of
          VerdictReady ticket ->
            prepareIntent
              (authorityTimeFromMicros 3_000_000_000_000)
              (gen 1)
              ticket
              binding
              `shouldSatisfy` isLeft
          other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

    describe "T8: SCapability singleton and requirement resolution" $ do
      it "round-trips every operation through its singleton (39-kind consistency)" $
        mapM_ singletonRoundTripsOp [minBound .. maxBound]

      it "keeps the singleton tier in agreement with permitTier over the whole universe" $
        mapM_ singletonTierAgreesWithPermitTier [minBound .. maxBound]

      it "resolves a well-formed requirement spec to its operation" $
        case resolveRequirement (requireSpec OpLifecycleCas "leases/aws-ses" 1) of
          Right requirement -> requirementOp requirement `shouldBe` OpLifecycleCas
          Left err -> expectationFailure ("unexpected requirement error: " ++ show err)

      it "rejects a requirement whose coordinate field is empty (before any effect)" $
        resolveRequirement (requireSpec OpLifecycleObserve "" 1) `shouldSatisfy` isCoordinateError

      it "rejects a requirement whose generation is zero (before any effect)" $
        resolveRequirement (requireSpec OpLifecycleObserve "leases/aws-ses" 0)
          `shouldSatisfy` isGenerationError

      it "matches a provision iff it answers the same operation at the same coordinate" $ do
        let requirement = expectRight (resolveRequirement (requireSpec OpLifecycleCas "leases/aws-ses" 1))
            sameProvision = expectRight (resolveProvision (provideSpec OpLifecycleCas "leases/aws-ses" 1))
            otherLogical = expectRight (resolveProvision (provideSpec OpLifecycleCas "leases/aws-eks" 1))
            otherOperation = expectRight (resolveProvision (provideSpec OpLifecycleObserve "leases/aws-ses" 1))
        matchesProvision requirement sameProvision `shouldBe` True
        matchesProvision requirement otherLogical `shouldBe` False
        matchesProvision requirement otherOperation `shouldBe` False

    describe "T9 (Validation #2): observe -> admit -> execute threads ONE reference" $ do
      it "admitted execution uses the same opaque reference that produced the evidence" $ do
        seen <- newIORef []
        let client = fakeClient seen
            expected = expectedAuthorityFromRef casRef
            matchingFence =
              FenceEvidence
                { fenceOwner = expectRight (mkOwnerNonce "owner-1")
                , fenceToken = expectRight (mkFencingToken 7)
                , fenceVersion = ver "lease-etag"
                , fenceDigest = refCoordinateDigest casRef
                }
        observeResult <-
          runCapability client casRef openDeadline (Observe (FreshnessWindow 300))
        case observeResult of
          Left failure -> expectationFailure ("observe failed: " ++ show failure)
          Right obs -> do
            obsCoordinateDigest obs `shouldBe` refCoordinateDigest casRef
            case classifyObservation freshNow expected obs of
              VerdictReady ticket -> do
                admissionCoordinateDigest ticket `shouldBe` refCoordinateDigest casRef
                case authorizeInternalCas (gen 1) ticket matchingFence of
                  Left refusal -> expectationFailure ("permit refused: " ++ show refusal)
                  Right permit -> do
                    permitCoordinateDigest permit `shouldBe` refCoordinateDigest casRef
                    execResult <-
                      runCapability
                        client
                        casRef
                        openDeadline
                        ( InternalCas
                            permit
                            (ExpectedVersion (ver "prev-etag"))
                            (PayloadDigest (sha256TargetValueDigest "payload"))
                        )
                    case execResult of
                      Left failure -> expectationFailure ("execute failed: " ++ show failure)
                      Right outcome -> outcome `shouldBe` CasApplied (ver "cas-applied-1")
                    laneDigests <- readIORef seen
                    laneDigests
                      `shouldBe` [refCoordinateDigest casRef, refCoordinateDigest casRef]
              other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

      it "refuses to execute a permit not bound to the execution reference" $ do
        seen <- newIORef []
        let client = fakeClient seen
            otherRef = mkCapabilityRef otherCoordinate :: CapabilityRef 'LifecycleCas
            expectedOther = expectedAuthorityFromRef otherRef
            otherFence =
              FenceEvidence
                { fenceOwner = expectRight (mkOwnerNonce "owner-1")
                , fenceToken = expectRight (mkFencingToken 7)
                , fenceVersion = ver "lease-etag"
                , fenceDigest = refCoordinateDigest otherRef
                }
        observeResult <-
          runCapability client otherRef openDeadline (Observe (FreshnessWindow 300))
        case observeResult of
          Left failure -> expectationFailure ("observe failed: " ++ show failure)
          Right obs ->
            case classifyObservation freshNow expectedOther obs of
              VerdictReady ticket ->
                case authorizeInternalCas (gen 1) ticket otherFence of
                  Left refusal -> expectationFailure ("permit refused: " ++ show refusal)
                  Right permit -> do
                    execResult <-
                      runCapability
                        client
                        casRef
                        openDeadline
                        ( InternalCas
                            permit
                            (ExpectedVersion (ver "prev-etag"))
                            (PayloadDigest (sha256TargetValueDigest "payload"))
                        )
                    case execResult of
                      Left (FailureRefused _) -> pure ()
                      Left other -> expectationFailure ("expected FailureRefused, got " ++ show other)
                      Right outcome -> expectationFailure ("expected FailureRefused, got " ++ show outcome)
              other -> expectationFailure ("expected Ready, got " ++ verdictTag other)

      it "fails closed on an expired monotonic deadline before touching any lane" $ do
        seen <- newIORef []
        let client = fakeClient seen
            expiredDeadline = deadlineFromInstant (monotonicInstantFromMicros 0)
        expiredResult <-
          runCapability client casRef expiredDeadline (Observe (FreshnessWindow 300))
        case expiredResult of
          Left FailureDeadlineExpired -> do
            laneDigests <- readIORef seen
            laneDigests `shouldBe` []
          Left other -> expectationFailure ("expected FailureDeadlineExpired, got " ++ show other)
          Right obs ->
            expectationFailure
              ("expected FailureDeadlineExpired, got observation " ++ show (obsCoordinateDigest obs))

    describe "T10: interpreter failure-arm mapping (regression guard for ambiguous-vs-did-not-run)" $ do
      it "refuses admission fast with FailureSaturated" $ do
        result <-
          runCapability
            (faultClient (Saturated (RetryAfter 1000)) (Right observedFixture) unusedCas)
            casRef
            openDeadline
            (Observe (FreshnessWindow 300))
        case result of
          Left (FailureSaturated _) -> pure ()
          Left other -> expectationFailure ("expected FailureSaturated, got " ++ show other)
          Right _ -> expectationFailure "expected FailureSaturated, got an observation"

      it "folds an observe lane fault to FailureUnobservable (fail-closed), both variants" $ do
        unavailable <-
          runCapability
            (faultClient Admitted (Left (LaneUnavailable "down")) unusedCas)
            casRef
            openDeadline
            (Observe (FreshnessWindow 300))
        ambiguous <-
          runCapability
            (faultClient Admitted (Left (LaneAmbiguous "lost")) unusedCas)
            casRef
            openDeadline
            (Observe (FreshnessWindow 300))
        assertUnobservable unavailable
        assertUnobservable ambiguous

      it "maps a CAS lane 'never left' to FailureUnavailable (safe to retry)" $ do
        result <-
          runCapability
            (faultClient Admitted (Right observedFixture) (Left (LaneUnavailable "connection refused")))
            casRef
            openDeadline
            ( InternalCas
                mintedCasPermit
                (ExpectedVersion (ver "prev-etag"))
                (PayloadDigest (sha256TargetValueDigest "payload"))
            )
        case result of
          Left (FailureUnavailable _) -> pure ()
          other -> expectationFailure ("expected FailureUnavailable, got " ++ show other)

      it "maps a CAS lost response to FailureAmbiguous (indeterminate, never retryable-as-did-not-run)" $ do
        result <-
          runCapability
            (faultClient Admitted (Right observedFixture) (Left (LaneAmbiguous "response lost")))
            casRef
            openDeadline
            ( InternalCas
                mintedCasPermit
                (ExpectedVersion (ver "prev-etag"))
                (PayloadDigest (sha256TargetValueDigest "payload"))
            )
        case result of
          Left (FailureAmbiguous _) -> pure ()
          other -> expectationFailure ("expected FailureAmbiguous, got " ++ show other)

observedFixture :: ObservedReading
observedFixture =
  ObservedReading
    { observedService = field mkServiceIdentity "lifecycle-authority"
    , observedAuthority = field mkAuthorityScope "home/prodbox"
    , observedGeneration = gen 1
    , observedAt = t0
    , observedEvidence = roundTripEvidence
    }

fakeClient :: IORef [CoordinateDigest] -> CapabilityClient
fakeClient seen =
  CapabilityClient
    { clientCurrentGeneration = gen 1
    , clientMonotonicNow = pure (monotonicInstantFromMicros 0)
    , clientAdmit = const (pure Admitted)
    , clientObserve = \_op coordinate _freshness _remaining -> do
        modifyIORef' seen (coordinateDigest coordinate :)
        pure (Right observedFixture)
    , clientInternalCas = \_op _coordinate request -> do
        modifyIORef' seen (casCoordinateDigest request :)
        pure (Right (CasApplied (ver "cas-applied-1")))
    , clientExternalCommit = \_op _coordinate _request ->
        pure (Right (CommitApplied "unused"))
    }

openDeadline :: Deadline
openDeadline = deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 5_000_000)

-- | A fault-injecting client for the failure-arm regression tests: fixed
-- monotonic clock at 0, injected admission + observe/CAS lane results.
faultClient
  :: QueueAdmission
  -> Either LaneFault ObservedReading
  -> Either LaneFault CasOutcome
  -> CapabilityClient
faultClient admission observeResult casResult =
  CapabilityClient
    { clientCurrentGeneration = gen 1
    , clientMonotonicNow = pure (monotonicInstantFromMicros 0)
    , clientAdmit = const (pure admission)
    , clientObserve = \_op _coordinate _freshness _remaining -> pure observeResult
    , clientInternalCas = \_op _coordinate _request -> pure casResult
    , clientExternalCommit = \_op _coordinate _request -> pure (Right (CommitApplied "unused"))
    }

-- | A CAS lane result used where the observe path is the subject (never reached).
unusedCas :: Either LaneFault CasOutcome
unusedCas = Right (CasApplied (ver "unused"))

assertUnobservable :: Either CapabilityFailure a -> Expectation
assertUnobservable (Left (FailureUnobservable _)) = pure ()
assertUnobservable (Left other) = expectationFailure ("expected FailureUnobservable, got " ++ show other)
assertUnobservable (Right _) = expectationFailure "expected FailureUnobservable, got a success"

-- | A writer permit validly minted for 'casRef' (via the real observe -> admit ->
-- authorize chain), so the CAS failure-arm tests exercise the LANE mapping, not
-- the same-reference guard.
mintedCasPermit :: WriterPermit 'LifecycleCas
mintedCasPermit =
  case classifyObservation
    freshNow
    (expectedAuthorityFromRef casRef)
    (observationFromRef casRef readingForCasRef) of
    VerdictReady ticket ->
      case authorizeInternalCas (gen 1) ticket casFenceForCasRef of
        Right permit -> permit
        Left refusal -> error ("mintedCasPermit: unexpected refusal " ++ show refusal)
    other -> error ("mintedCasPermit: expected Ready, got " ++ verdictTag other)

casFenceForCasRef :: FenceEvidence
casFenceForCasRef =
  FenceEvidence
    { fenceOwner = expectRight (mkOwnerNonce "owner-1")
    , fenceToken = expectRight (mkFencingToken 7)
    , fenceVersion = ver "lease-etag"
    , fenceDigest = refCoordinateDigest casRef
    }

readingForCasRef :: ObservationReading
readingForCasRef =
  ObservationReading
    { readingService = field mkServiceIdentity "lifecycle-authority"
    , readingAuthority = field mkAuthorityScope "home/prodbox"
    , readingGeneration = gen 1
    , readingObservedAt = t0
    , readingFreshnessBound = FreshnessWindow 300
    , readingEvidence = roundTripEvidence
    }

singletonRoundTripsOp :: CapabilityOp -> Expectation
singletonRoundTripsOp op = case opToSCapability op of
  SomeSCapability singleton -> sCapabilityOp singleton `shouldBe` op

singletonTierAgreesWithPermitTier :: CapabilityOp -> Expectation
singletonTierAgreesWithPermitTier op = case opToSCapability op of
  SomeSCapability singleton -> sCapabilityTier singleton `shouldBe` permitTier op

requireSpec :: CapabilityOp -> Text -> Natural -> CapabilityRequirementSpec
requireSpec op logical generation =
  CapabilityRequirementSpec
    { specRequireCapability = op
    , specRequireService = "lifecycle-authority"
    , specRequireScope = "home/prodbox"
    , specRequireEndpoint = "127.0.0.1:30443"
    , specRequireLogical = logical
    , specRequireGeneration = generation
    , specRequireLatencyMicros = 5_000_000
    }

provideSpec :: CapabilityOp -> Text -> Natural -> CapabilityProvisionSpec
provideSpec op logical generation =
  CapabilityProvisionSpec
    { specProvideCapability = op
    , specProvideService = "lifecycle-authority"
    , specProvideScope = "home/prodbox"
    , specProvideEndpoint = "127.0.0.1:30443"
    , specProvideLogical = logical
    , specProvideGeneration = generation
    }

isCoordinateError :: Either RequirementError a -> Bool
isCoordinateError (Left (RequirementCoordinateInvalid _)) = True
isCoordinateError _ = False

isGenerationError :: Either RequirementError a -> Bool
isGenerationError (Left (RequirementGenerationInvalid _)) = True
isGenerationError _ = False

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
