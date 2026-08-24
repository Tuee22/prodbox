{-# LANGUAGE OverloadedStrings #-}

module QualificationEvidence (qualificationEvidenceSuite, validInput) where

import Data.ByteString.Char8 qualified as ByteString8
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.Qualification.Evidence
import Prodbox.Test.Qualification.FrozenCounterexample
import Prodbox.Test.Qualification.Invite
import Prodbox.Test.Qualification.SourceIdentity
import Prodbox.Test.TemporalQualification
import Test.Tasty.HUnit (assertBool)
import TestSupport

qualificationEvidenceSuite :: SuiteBuilder ()
qualificationEvidenceSuite =
  describe "Sprint 5.19 qualification evidence" $ do
    it "constructs a complete secret-safe two-identity artifact" $ do
      input <- validInput
      assertBool
        "complete artifact must construct"
        (either (const False) (const True) (mkQualificationEvidence input))

    it "refuses identity reuse, missing results, failed aggregate, and residue" $ do
      input <- validInput
      let reused = input {evidenceReplacementIdentity = evidenceSupersededIdentity input}
      mkQualificationEvidence reused `shouldBe` Left QualificationIdentityReused
      assertBool
        "missing counterexample must refuse"
        (isLeft (mkQualificationEvidence input {evidenceReplacementCounterexampleResults = []}))
      mkQualificationEvidence input {evidenceAggregateSucceeded = False}
        `shouldBe` Left QualificationAggregateFailed
      mkQualificationEvidence input {evidenceCleanupResidueAbsent = False}
        `shouldBe` Left QualificationCleanupResiduePresent

    it "accepts only canonical public SHA-256 identities" $ do
      mkPublicEvidenceDigest "abc" `shouldBe` Nothing
      assertBool
        "canonical digest accepted"
        (maybe False (const True) (mkPublicEvidenceDigest (fromString digestA)))

validInput :: IO QualificationEvidenceInput
validInput = do
  oldIdentity <- sourceIdentity "src/Prodbox/Test/Old.hs" "old"
  newIdentity <- sourceIdentity "src/Prodbox/Test/New.hs" "new"
  digest <- acceptedDigest digestA
  digestBValue <- acceptedDigest digestB
  receipt <- accepted (mkAuthorityReceiptBinding "receipt-qualification-0001")
  invite <- accepted canonicalInviteQualificationFixture
  pure
    QualificationEvidenceInput
      { evidenceSubstrate = "home-local"
      , evidenceCanonicalCommands = ["prodbox test integration control-plane-counterexample"]
      , evidenceSupersededIdentity = identity oldIdentity digest digestBValue
      , evidenceReplacementIdentity = identity newIdentity digestBValue digest
      , evidenceNormalizedEnvelopeMappingDigest = digest
      , evidenceSupersededCounterexampleResults =
          [CounterexampleResult mechanism SupersededFailureObserved | mechanism <- [minBound .. maxBound]]
      , evidenceReplacementCounterexampleResults =
          [CounterexampleResult mechanism ReplacementMechanismClosed | mechanism <- [minBound .. maxBound]]
      , evidenceFaultResults = runDeterministicTemporalFaultSchedule
      , evidenceOpaqueBindings = [receipt]
      , evidenceInviteQualification = invite
      , evidenceAggregateSucceeded = True
      , evidenceCleanupResidueAbsent = True
      , evidenceStartedAt = "2026-08-02T00:00:00Z"
      , evidenceCompletedAt = "2026-08-02T00:01:00Z"
      }

identity :: SourceIdentity -> PublicEvidenceDigest -> PublicEvidenceDigest -> QualificationIdentity
identity source first second =
  QualificationIdentity
    { qualificationSourceIdentity = source
    , qualificationGeneratedConfigDigest = first
    , qualificationComponentImageDigests = [first, second]
    , qualificationTopologyWiringDigest = second
    , qualificationResourceEnvelopeDigest = first
    , qualificationLoadFaultDigest = second
    , qualificationInterpreterDigest = first
    , qualificationPersistenceDigest = second
    , qualificationCleanupSchemaDigest = first
    }

sourceIdentity :: String -> String -> IO SourceIdentity
sourceIdentity path contents = do
  headId <- accepted (mkGitHead "0123456789abcdef0123456789abcdef01234567")
  accepted
    ( mkSourceIdentity
        headId
        WorktreeDirty
        []
        [SourceCandidate (fromString path) ManifestRegularFile 0o644 (ByteString8.pack contents)]
    )

acceptedDigest :: String -> IO PublicEvidenceDigest
acceptedDigest value = maybe (fail "invalid digest fixture") pure (mkPublicEvidenceDigest (fromString value))

accepted :: (Show err) => Either err value -> IO value
accepted = either (fail . show) pure

fromString :: String -> Text
fromString = Text.pack

digestA :: String
digestA = replicate 64 'a'

digestB :: String
digestB = replicate 64 'b'
