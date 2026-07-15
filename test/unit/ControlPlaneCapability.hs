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

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane
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

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
