{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 6.5: the ledger that makes "two consecutive qualifying cycles" a fact
-- about every attempt rather than about the files that happen to survive.
--
-- The judge cases are the table the design was judged on: each is an ordered
-- history of attempts and the verdict it must earn, because the interesting
-- inputs are the ones where a failure sits between two successes.
module CascadeCycleLedgerTests
  ( cascadeCycleLedgerSuite
  )
where

import CycleIdentityFixtures
import CycleLedgerFixtures
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.Qualification.CascadeCycleArtifact
import Prodbox.Test.Qualification.CascadeCycleIdentity
import Prodbox.Test.Qualification.CascadeCycleLedger
import Prodbox.Test.Qualification.CascadeCycleLedgerStore
import Prodbox.Test.Qualification.Evidence (hashPublicEvidence, publicEvidenceDigestText)
import System.Directory (removeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createNamedPipe, createSymbolicLink, setFileMode)
import System.Timeout (timeout)
import TestSupport

cascadeCycleLedgerSuite :: SuiteBuilder ()
cascadeCycleLedgerSuite =
  describe "Sprint 6.5 cascade cycle ledger" $ do
    resumeSnapshotCases
    appendCases
    readCases
    resolutionCases
    judgeCases
    artifactCases
    markCases

resumeSnapshotCases :: SuiteBuilder ()
resumeSnapshotCases = describe "pre-uninstall named image capture" $ do
  it "keeps the exact Begin and observed inventory through immutable replay" $
    withSystemTempDirectory "qualification-resume" $ \root -> do
      let begun = beganFor "pre-1" DeploymentA 1
          snapshot = acceptedSnapshot begun (inventoryFor (partsComponentImages (partsOfVariant DeploymentA)))
      observeQualificationResumeSnapshot root (labelOf "pre-1") `shouldReturn` Right Nothing
      persistQualificationResumeSnapshot root snapshot `shouldReturn` Right snapshot
      persistQualificationResumeSnapshot root snapshot `shouldReturn` Right snapshot
      observeQualificationResumeSnapshot root (labelOf "pre-1") `shouldReturn` Right (Just snapshot)
      qualificationResumeBegun snapshot `shouldBe` begun
      qualificationResumeImages snapshot
        `shouldBe` inventoryFor (partsComponentImages (partsOfVariant DeploymentA))
      let changed =
            acceptedSnapshot
              (beganFor "pre-1" DeploymentB 1)
              (inventoryFor (partsComponentImages (partsOfVariant DeploymentB)))
      persistQualificationResumeSnapshot root changed >>= (`shouldSatisfy` snapshotRefused)
      observeQualificationResumeSnapshot root (labelOf "pre-1") `shouldReturn` Right (Just snapshot)
  it "refuses an invented inventory and a snapshot that claims a later ledger attempt" $ do
    mkQualificationResumeSnapshot
      (beganFor "pre-1" DeploymentA 1)
      (inventoryFor (partsComponentImages (partsOfVariant DeploymentAfterDeletion)))
      `shouldSatisfy` snapshotRefused
    mkQualificationResumeSnapshot
      (beganFor "pre-1" DeploymentA 2)
      (inventoryFor (partsComponentImages (partsOfVariant DeploymentA)))
      `shouldSatisfy` snapshotRefused
    mkQualificationResumeSnapshot (beganFor "pre-1" DeploymentA 1) []
      `shouldSatisfy` snapshotRefused
  it "refuses malformed, oversized, non-private, symlink and FIFO storage" $
    withSystemTempDirectory "qualification-resume-hostile" $ \root -> do
      let label = labelOf "pre-1"
          path = qualificationResumeSnapshotPath root label
          other = qualificationResumeSnapshotPath root (labelOf "pre-2")
          snapshot =
            acceptedSnapshot
              (beganFor "pre-1" DeploymentA 1)
              (inventoryFor (partsComponentImages (partsOfVariant DeploymentA)))
      persistQualificationResumeSnapshot root snapshot `shouldReturn` Right snapshot
      bytes <- ByteString.readFile path
      let malformed = [ByteString.init bytes, ByteString.snoc bytes 10, ByteString.replicate (512 * 1024 + 1) 65]
      mapM_
        ( \value -> do
            ByteString.writeFile path value
            observeQualificationResumeSnapshot root label >>= (`shouldSatisfy` snapshotRefused)
        )
        malformed
      ByteString.writeFile path bytes
      setFileMode path 0o644
      observeQualificationResumeSnapshot root label >>= (`shouldSatisfy` snapshotRefused)
      setFileMode path 0o600
      createSymbolicLink path other
      observeQualificationResumeSnapshot root (labelOf "pre-2") >>= (`shouldSatisfy` snapshotRefused)
      removeFile other
      createNamedPipe other 0o600
      bounded <- timeout 1000000 (observeQualificationResumeSnapshot root (labelOf "pre-2"))
      bounded `shouldSatisfy` maybe False snapshotRefused
 where
  acceptedSnapshot begun images = either error id (mkQualificationResumeSnapshot begun images)
  snapshotRefused result = case result of Left _ -> True; Right _ -> False

-- Cases -------------------------------------------------------------------------------

appendCases :: SuiteBuilder ()
appendCases = do
  it "chains each entry to the one before it, from a fixed genesis" $ do
    let (ledger, _) = ledgerOf [Pass "pre-1" DeploymentA]
        entries = ledgerEntries ledger
    map entrySequence entries `shouldBe` [0, 1]
    map entryPrevious entries
      `shouldBe` [hashPublicEvidence "prodbox-cascade-cycle-ledger/v1", entryDigest (head' entries)]
    ledgerTip ledger `shouldBe` entryDigest (last entries)
    ledgerTip emptyCycleLedger `shouldBe` hashPublicEvidence "prodbox-cascade-cycle-ledger/v1"

  it "refuses an attempt number out of order, and a label that has already passed" $ do
    let (ledger, _) = ledgerOf [Pass "pre-1" DeploymentA]
    appendRecord ledger (beginRecord "pre-1" DeploymentA 2)
      `shouldBe` Left (LabelAlreadyPassed (labelOf "pre-1"))
    labelDisposition ledger (labelOf "pre-1") `shouldBe` Left (LabelAlreadyPassed (labelOf "pre-1"))
    labelDisposition ledger (labelOf "pre-2") `shouldBe` Right 1
    -- A label that failed may run again, and is then attempt 2.
    let (failed, _) = ledgerOf [Fail "pre-1" DeploymentA]
    labelDisposition failed (labelOf "pre-1") `shouldBe` Right 2
    appendRecord failed (beginRecord "pre-1" DeploymentA 3)
      `shouldSatisfy` isOutOfOrder
    appendRecord emptyCycleLedger (beginRecord "pre-1" DeploymentA 0)
      `shouldSatisfy` isOutOfOrder

  it "refuses a close that does not close the open attempt" $ do
    appendRecord emptyCycleLedger (closeRecord "pre-1" DeploymentA 1 CyclePassed (Just "d"))
      `shouldSatisfy` isOutOfOrder
    let (open, _) = ledgerOf [Interrupt "pre-1" DeploymentA]
    appendRecord open (closeRecord "pre-2" DeploymentA 1 CyclePassed (Just "d"))
      `shouldSatisfy` isOutOfOrder
    appendRecord open (closeRecord "pre-1" DeploymentA 2 CyclePassed (Just "d"))
      `shouldSatisfy` isOutOfOrder

  it "refuses a close whose outcome contradicts its keys or its artifact" $ do
    let (open, _) = ledgerOf [Interrupt "pre-1" DeploymentA]
        passedOnAnotherKey =
          RecordCycleClosed
            (closedFor "pre-1" DeploymentA 1 CyclePassed (Just "d"))
              { closedEndKey = identityKeyOfParts (partsOfVariant DeploymentB)
              }
        driftedOnSameKey =
          RecordCycleClosed
            (closedFor "pre-1" DeploymentA 1 CycleSourceDrifted (Just "d"))
              { closedEndKey = begunKey (beganFor "pre-1" DeploymentA 1)
              }
    appendRecord open passedOnAnotherKey `shouldSatisfy` isInconsistent
    appendRecord open (closeRecord "pre-1" DeploymentA 1 CyclePassed Nothing)
      `shouldSatisfy` isInconsistent
    appendRecord open driftedOnSameKey `shouldSatisfy` isInconsistent

  it "refuses a begun record whose key is not the key of its parts, and a value it cannot write" $ do
    let wrongKey =
          RecordCycleBegun
            (beganFor "pre-1" DeploymentA 1) {begunKey = identityKeyOfParts (partsOfVariant DeploymentB)}
        unwritable =
          RecordCycleBegun (beganFor "pre-1" DeploymentA 1) {begunStartedAt = "has a space"}
    appendRecord emptyCycleLedger wrongKey `shouldSatisfy` isInconsistent
    appendRecord emptyCycleLedger unwritable
      `shouldBe` Left (LedgerRecordUnrenderable "started_at")

readCases :: SuiteBuilder ()
readCases = do
  it "reads back exactly what it wrote, line for line" $ do
    let (ledger, _) = ledgerOf [Fail "pre-1" DeploymentA, Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA]
        text = Text.unlines (map renderLedgerEntry (ledgerEntries ledger))
    parseCycleLedger text `shouldBe` Right ledger
    parseCycleLedger "" `shouldBe` Right emptyCycleLedger

  it "refuses an edited, reordered, dropped, extended or reshaped line" $ do
    let (ledger, _) = ledgerOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA]
        ls = map renderLedgerEntry (ledgerEntries ledger)
        text = Text.unlines ls
        broken index = Left (LedgerChainBroken index)
    -- A changed value.
    parseCycleLedger (Text.replace "label=pre-1" "label=pre-9" text) `shouldSatisfy` isRefused
    -- Two lines swapped, a middle line dropped, the sequence made sparse.
    case ls of
      first : second : third : fourth : _ -> do
        parseCycleLedger (Text.unlines [second, first, third, fourth]) `shouldSatisfy` isRefused
        parseCycleLedger (Text.unlines [first, third, fourth]) `shouldSatisfy` isRefused
      _ -> expectationFailure "a two-cycle history has four entries"
    parseCycleLedger (Text.unlines (ls ++ ["seq=9\tprev=x"])) `shouldSatisfy` isRefused
    -- Fields out of their canonical order are a different line, even with the right digest.
    let swapped = case Text.splitOn "\t" (head' ls) of
          a : b : c : d : rest -> Text.intercalate "\t" (a : b : d : c : rest)
          other -> Text.intercalate "\t" other
    parseCycleLedger (Text.unlines (swapped : drop 1 ls)) `shouldBe` broken 0

  it "tolerates blank lines but not a missing digest or an unknown record" $ do
    let (ledger, _) = ledgerOf [Pass "pre-1" DeploymentA]
        ls = map renderLedgerEntry (ledgerEntries ledger)
    parseCycleLedger (Text.unlines (head' ls : "" : drop 1 ls)) `shouldBe` Right ledger
    parseCycleLedger (Text.unlines [Text.replace "\tdigest=" "\tdigested=" (head' ls)])
      `shouldSatisfy` isRefused
    parseCycleLedger (Text.unlines [Text.replace "type=begun" "type=mystery" (head' ls)])
      `shouldSatisfy` isRefused

  it "finds an anchor only among the digests of its own chain" $ do
    let (ledger, _) = ledgerOf [Pass "pre-1" DeploymentA]
        entries = ledgerEntries ledger
    ledgerContainsDigest ledger (entryDigest (last entries)) `shouldBe` Just 1
    ledgerContainsDigest ledger (entryDigest (head' entries)) `shouldBe` Just 0
    ledgerContainsDigest ledger (hashPublicEvidence "elsewhere") `shouldBe` Nothing

resolutionCases :: SuiteBuilder ()
resolutionCases =
  it "reads an attempt with no close as interrupted, whether it is the last or not" $ do
    let (ledger, _) = ledgerOf [Interrupt "pre-1" DeploymentA, Pass "pre-2" DeploymentA, Interrupt "pre-3" DeploymentA]
    map resolvedResolution (resolveAttempts ledger)
      `shouldBe` [AttemptInterrupted, AttemptPassed, AttemptInterrupted]
    map resolvedLabel (resolveAttempts ledger) `shouldBe` map labelOf ["pre-1", "pre-2", "pre-3"]
    map
      resolvedResolution
      (resolveAttempts (fst (ledgerOf [Drift "d-1" DeploymentA, Fail "d-2" DeploymentB])))
      `shouldBe` [AttemptSourceDrifted, AttemptFailed FailedCandidateRefused]

judgeCases :: SuiteBuilder ()
judgeCases = do
  it "qualifies two passes in a row on one deployment, and names the proof" $ do
    case verdictOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA] of
      Left refusal -> expectationFailure ("expected a proof, got " ++ show refusal)
      Right proof -> do
        proofLabels proof `shouldBe` map labelOf ["pre-1", "pre-2"]
        proofAttempts proof `shouldBe` [1, 1]
        proofKey proof `shouldBe` identityKeyOfParts fixtureParts
        proofParts proof `shouldBe` fixtureParts
        proofAwsScope proof `shouldBe` ("111122223333", fixtureRegionText)
        length (proofArtifactDigests proof) `shouldBe` 2
        length (proofAnnotations proof) `shouldBe` 2

  it "does not let an earlier failure matter, or a later one go unseen" $ do
    -- F S S qualifies; S F S counts one; S S F counts none.
    verdictOf [Fail "pre-0" DeploymentA, Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA]
      `shouldSatisfy` isProof
    insufficient
      (verdictOf [Pass "pre-1" DeploymentA, Fail "pre-9" DeploymentA, Pass "pre-2" DeploymentA])
      `shouldBe` Just (1, Just (AttemptFailed FailedCandidateRefused))
    insufficient
      (verdictOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA, Fail "pre-3" DeploymentA])
      `shouldBe` Just (0, Just (AttemptFailed FailedCandidateRefused))
    insufficient
      (verdictOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA, Interrupt "pre-3" DeploymentA])
      `shouldBe` Just (0, Just AttemptInterrupted)
    insufficient
      (verdictOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA, Drift "pre-3" DeploymentA])
      `shouldBe` Just (0, Just AttemptSourceDrifted)

  it "counts one when only one cycle has run, and none when none has" $ do
    insufficient (verdictOf [Pass "pre-1" DeploymentA]) `shouldBe` Just (1, Nothing)
    verdictOf [] `shouldBe` Left LedgerEmptyOfCycles

  it "names the components that differ when the cycles ran on different deployments" $ do
    -- A B A: the newest pair is not on one deployment.
    verdictOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentB, Pass "pre-3" DeploymentA]
      `shouldBe` Left (CycleIdentityDiffersFromTarget [ComponentGeneratedConfig])
    verdictOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentB]
      `shouldBe` Left (CycleIdentityDiffersFromTarget [ComponentGeneratedConfig])

  it "lets a resumed label count once, and only once" $ do
    -- pre-1 failed, then passed on its second attempt; pre-2 passed.
    case verdictOf [Fail "pre-1" DeploymentA, Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA] of
      Right proof -> proofAttempts proof `shouldBe` [2, 1]
      Left refusal -> expectationFailure (show refusal)
    -- An interruption between a pass and a resumed pass leaves one.
    insufficient
      (verdictOf [Pass "pre-1" DeploymentA, Interrupt "pre-2" DeploymentA, Pass "pre-2" DeploymentA])
      `shouldBe` Just (1, Just AttemptInterrupted)

artifactCases :: SuiteBuilder ()
artifactCases = do
  it "refuses a counted attempt whose artifact is missing or defective" $ do
    let (ledger, artifacts) = ledgerOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA]
    judgeConsecutiveCycles ledger (Map.delete (labelOf "pre-2") artifacts)
      `shouldBe` Left (ArtifactMissing (labelOf "pre-2"))
    judgeConsecutiveCycles
      ledger
      (Map.insert (labelOf "pre-2") (Left ArtifactDigestLineMismatch) artifacts)
      `shouldBe` Left (ArtifactDefective (labelOf "pre-2") ArtifactDigestLineMismatch)

  it "refuses an artifact that says something other than the ledger does" $ do
    let (ledger, artifacts) = ledgerOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA]
        pre1 = labelOf "pre-1"
        replaceFact change =
          Map.adjust (fmap change) pre1 artifacts
        disagrees = ArtifactDisagreesWithLedger pre1
        refusalWith change = judgeConsecutiveCycles ledger (replaceFact change)
    refusalWith
      (\fact -> fact {factEvidenceDigest = publicEvidenceDigestText (hashPublicEvidence "other")})
      `shouldBe` Left (disagrees "the artifact's evidence digest is not the one the ledger recorded")
    refusalWith (\fact -> fact {factAttempt = 7})
      `shouldBe` Left (disagrees "the artifact names another cycle or attempt")
    refusalWith (\fact -> fact {factCleanupRunId = "cascade-qualification-elsewhere"})
      `shouldBe` Left (disagrees "the artifact's cleanup run is not the one the ledger recorded")
    refusalWith (\fact -> fact {factParts = (factParts fact) {partsLoadFault = digestOf 'Q'}})
      `shouldBe` Left (disagrees "the artifact's identity differs from the ledger's in load-fault")
    refusalWith (\fact -> fact {factSucceeded = False})
      `shouldBe` Left (ArtifactNotSuccessful pre1)

  it "refuses two cycles that ran in different accounts or regions" $ do
    let (ledger, artifacts) = ledgerOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA]
    judgeConsecutiveCycles
      ledger
      (Map.adjust (fmap (\fact -> fact {factAwsAccount = "999999999999"})) (labelOf "pre-1") artifacts)
      `shouldBe` Left CycleEnvironmentDiffers

-- Helpers --------------------------------------------------------------------------------

markCases :: SuiteBuilder ()
markCases = do
  let pre = [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA]
      activate = Activate ["pre-1", "pre-2"] DeploymentA
      postPair = [Pass "post-1" DeploymentAfterDeletion, Pass "post-2" DeploymentAfterDeletion]
      afterDeletionLocal = localKeyOfParts (partsOfVariant DeploymentAfterDeletion)
      afterDeletion = pre ++ [activate, DeleteRoute DeploymentAfterDeletion]

  it "records an activation after a qualifying pair, and counts no cycle until the deletion" $ do
    let (activated, artifacts) = ledgerOf (pre ++ [activate])
    epochOfLedger activated `shouldBe` EpochAwaitingDeletion (localKeyOfParts fixtureParts)
    judgeConsecutiveCycles activated artifacts `shouldSatisfy` isEpochRefusal
    -- Cycles run while the tree is mid-edit count nothing, whatever they do.
    let (during, duringArtifacts) = ledgerOf (pre ++ [activate, Pass "mid-1" DeploymentA, Pass "mid-2" DeploymentA])
    judgeConsecutiveCycles during duringArtifacts `shouldSatisfy` isEpochRefusal

  it "refuses an activation that does not follow a qualifying pair, or that cites the wrong one" $ do
    let (pair, _) = ledgerOf pre
        good = markFor MarkActivated ["pre-1", "pre-2"] DeploymentA pair
        activation mark = appendRecord pair (RecordCutoverMark mark)
    activation good `shouldSatisfy` isRight'
    activation good {markWitnessKey = identityKeyOfParts (partsOfVariant DeploymentB)}
      `shouldSatisfy` isMarkRefusal
    activation good {markLocalKey = localKeyOfParts (partsOfVariant DeploymentB)}
      `shouldSatisfy` isMarkRefusal
    activation good {markWitnessLabels = reverse (markWitnessLabels good)} `shouldSatisfy` isMarkRefusal
    activation good {markWitnessArtifacts = take 1 (markWitnessArtifacts good)}
      `shouldSatisfy` isMarkRefusal
    -- One cycle is not a pair.
    let (one, _) = ledgerOf [Pass "pre-1" DeploymentA]
    appendRecord one (RecordCutoverMark (markFor MarkActivated ["pre-1"] DeploymentA one))
      `shouldSatisfy` isMarkRefusal
    -- A failure after the pair is the newest thing that happened.
    let (failed, _) = ledgerOf (pre ++ [Fail "pre-3" DeploymentA])
    appendRecord failed (RecordCutoverMark good) `shouldSatisfy` isMarkRefusal
    -- Nothing is recorded over an attempt that is still open.
    let (open, _) = ledgerOf (pre ++ [Interrupt "pre-3" DeploymentA])
    appendRecord open (RecordCutoverMark good) `shouldSatisfy` isMarkRefusal
    -- An activation is recorded once.
    let (activated, _) = ledgerOf (pre ++ [activate])
    appendRecord activated (RecordCutoverMark good) `shouldSatisfy` isMarkRefusal

  it
    "records the deletion only on a tree whose executable identity moved, naming the witness it consumed"
    $ do
      let (activated, _) = ledgerOf (pre ++ [activate])
          deletion = deletionMarkFor DeploymentAfterDeletion activated
          record mark = appendRecord activated (RecordCutoverMark mark)
      record deletion `shouldSatisfy` isRight'
      -- A deletion that changed nothing is not a deletion.
      record (deletionMarkFor DeploymentA activated) `shouldSatisfy` isMarkRefusal
      -- It consumes the witness that licensed the activation, and no other.
      record deletion {markWitnessKey = identityKeyOfParts (partsOfVariant DeploymentB)}
        `shouldSatisfy` isMarkRefusal
      record deletion {markWitnessLabels = take 1 (markWitnessLabels deletion)}
        `shouldSatisfy` isMarkRefusal
      record deletion {markWitnessArtifacts = take 1 (markWitnessArtifacts deletion)}
        `shouldSatisfy` isMarkRefusal
      -- It follows an activation.
      let (pair, _) = ledgerOf pre
      appendRecord pair (RecordCutoverMark deletion) `shouldSatisfy` isMarkRefusal

  it "counts only cycles on the tree the deletion was recorded on, and not the ones behind the mark" $ do
    let (afterDeletionLedger, _) = ledgerOf afterDeletion
    epochOfLedger afterDeletionLedger `shouldBe` EpochPostActivation afterDeletionLocal
    -- The pair that licensed the activation is behind a mark and counts nothing now.
    insufficient (verdictOf (afterDeletion ++ [Pass "post-1" DeploymentAfterDeletion]))
      `shouldBe` Just (1, Nothing)
    case verdictOf (afterDeletion ++ postPair) of
      Right proof -> do
        proofKey proof `shouldBe` identityKeyOfParts (partsOfVariant DeploymentAfterDeletion)
        proofLabels proof `shouldBe` map labelOf ["post-1", "post-2"]
      Left refusal -> expectationFailure ("expected a post-activation proof, got " ++ show refusal)
    -- A tree that moved again after the deletion was recorded is named, not counted.
    verdictOf
      (afterDeletion ++ [Pass "post-1" DeploymentAfterDeletion, Pass "post-2" DeploymentMovedAgain])
      `shouldBe` Left
        ( PostActivationIdentityMoved
            afterDeletionLocal
            (localKeyOfParts (partsOfVariant DeploymentMovedAgain))
        )

  it
    "records the post-activation qualification after two cycles on that tree, and then the cutover is complete"
    $ do
      let (twoPost, _) = ledgerOf (afterDeletion ++ postPair)
          qualification = markFor MarkPostActivationQualified ["post-1", "post-2"] DeploymentAfterDeletion twoPost
      appendRecord twoPost (RecordCutoverMark qualification) `shouldSatisfy` isRight'
      -- Not before the second cycle, and not for cycles on another tree.
      let (onePost, _) = ledgerOf (afterDeletion ++ [Pass "post-1" DeploymentAfterDeletion])
      appendRecord
        onePost
        (RecordCutoverMark (markFor MarkPostActivationQualified ["post-1"] DeploymentAfterDeletion onePost))
        `shouldSatisfy` isMarkRefusal
      appendRecord twoPost (RecordCutoverMark qualification {markLocalKey = localKeyOfParts fixtureParts})
        `shouldSatisfy` isMarkRefusal
      let (complete, artifacts) =
            ledgerOf (afterDeletion ++ postPair ++ [QualifyPost ["post-1", "post-2"] DeploymentAfterDeletion])
      epochOfLedger complete `shouldBe` EpochComplete afterDeletionLocal
      judgeConsecutiveCycles complete artifacts `shouldSatisfy` isEpochRefusal
      -- Nothing more is recorded once the cutover is complete.
      appendRecord complete (RecordCutoverMark qualification) `shouldSatisfy` isMarkRefusal

  it "reads every mark back, and a mark is a boundary a walk does not cross" $ do
    let (complete, _) =
          ledgerOf (afterDeletion ++ postPair ++ [QualifyPost ["post-1", "post-2"] DeploymentAfterDeletion])
        text = Text.unlines (map renderLedgerEntry (ledgerEntries complete))
    parseCycleLedger text `shouldBe` Right complete
    map (fmap markKind . recordMark . entryRecord) (ledgerEntries complete)
      `shouldSatisfy` ((== 3) . length . filter (/= Nothing))
    -- Five passes and two marks: the run after the last mark is only what follows it.
    let (afterMarks, _) = ledgerOf (afterDeletion ++ [Pass "post-1" DeploymentAfterDeletion])
    length (fst (qualifyingRun afterMarks)) `shouldBe` 1
    renderCutoverMarkKind MarkActivated `shouldBe` "activated"

fixtureRegionText :: Text
fixtureRegionText = fieldsAwsRegion fixtureArtifactFields

head' :: [a] -> a
head' values = case values of
  value : _ -> value
  [] -> error "an empty list where the fixture has entries"

isProof :: Either LedgerRefusal ConsecutiveCycleProof -> Bool
isProof = either (const False) (const True)

-- | The count and the blocking resolution of an insufficient verdict.
insufficient :: Either LedgerRefusal ConsecutiveCycleProof -> Maybe (Int, Maybe AttemptResolution)
insufficient verdict = case verdict of
  Left (InsufficientConsecutiveCycles have _ blocker) -> Just (have, blockerResolution <$> blocker)
  _ -> Nothing

isOutOfOrder :: Either LedgerRefusal a -> Bool
isOutOfOrder result = case result of
  Left (LedgerRecordOutOfOrder _) -> True
  Left (LabelAlreadyPassed _) -> True
  _ -> False

isInconsistent :: Either LedgerRefusal a -> Bool
isInconsistent result = case result of
  Left (LedgerRecordInconsistent _) -> True
  _ -> False

recordMark :: LedgerRecord -> Maybe MarkRecord
recordMark record = case record of
  RecordCutoverMark mark -> Just mark
  _ -> Nothing

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

isMarkRefusal :: Either LedgerRefusal a -> Bool
isMarkRefusal result = case result of
  Left (CutoverMarkInvalid _ _) -> True
  _ -> False

isEpochRefusal :: Either LedgerRefusal a -> Bool
isEpochRefusal result = case result of
  Left (EpochDoesNotCount _) -> True
  _ -> False

isRefused :: Either LedgerRefusal a -> Bool
isRefused = either (const True) (const False)
