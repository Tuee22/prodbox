{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 6.5: the order in which a qualification cycle asks for things.
--
-- The driver is generic in its monad, so these cases run it in 'IO' over a
-- recording ledger and assert the order the production composition will use.
-- The properties that matter are about order: the candidate never runs before
-- its beginning is on disk, and a close is appended only after the artifact has
-- been written and the source looked at again.
module CascadeQualificationCycleTests
  ( cascadeQualificationCycleSuite
  )
where

import CycleIdentityFixtures
import CycleLedgerFixtures
import Data.Either (fromLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import Data.Maybe (isJust)
import Data.Text (Text)
import Prodbox.Test.CascadeQualificationCycle
import Prodbox.Test.Qualification.CascadeCycleIdentity
import Prodbox.Test.Qualification.CascadeCycleLedger
import Prodbox.TestRunner
  ( CascadeQualificationResumeMode (..)
  , qualificationCyclePurpose
  , runCascadeQualificationPreparation
  )
import System.Exit (ExitCode (..))
import TestSupport

cascadeQualificationCycleSuite :: SuiteBuilder ()
cascadeQualificationCycleSuite =
  describe "Sprint 6.5 cascade qualification cycle driver" $ do
    mapM_
      ( \mode -> it ("QUALIFICATION-RESUME-FRESH-INSTALL-2026-10-20 selects the real I/O arm for " <> show mode) $ do
          calls <- newIORef ([] :: [String])
          let fresh = modifyIORef' calls (<> ["fresh-floor-and-install"]) >> pure ExitSuccess
              resume = modifyIORef' calls (<> ["resume-candidate"]) >> pure (ExitFailure 17)
              expected = case mode of
                QualificationFresh -> (["fresh-floor-and-install"], ExitSuccess)
                QualificationRegistered -> (["resume-candidate"], ExitFailure 17)
                QualificationNative -> (["resume-candidate"], ExitFailure 17)
          result <- runCascadeQualificationPreparation mode fresh resume
          observed <- readIORef calls
          (observed, result) `shouldBe` expected
          qualificationCyclePurpose mode `shouldBe` case mode of
            QualificationFresh -> QualifyNewRun
            QualificationRegistered -> RecoverExistingRun
            QualificationNative -> RecoverExistingRun
      )
      [QualificationFresh, QualificationRegistered, QualificationNative]
    orderCases
    refusalCases
    outcomeCases

-- A recording world ------------------------------------------------------------------

data Event
  = AskedAttemptNumber
  | AppendedBegun
  | RanCandidate
  | WroteArtifact Int
  | Recaptured
  | AppendedClosed CycleOutcome
  | AppendedMark
  deriving (Eq, Show)

-- | What the world answers, and which appends fail (by position).
data World = World
  { worldAttempt :: Either String Int
  , worldFailAppends :: [Int]
  , worldCandidate :: Either String Bool
  , worldArtifact :: Either String Text
  , worldRecapture :: Either String IdentityKey
  , worldPurpose :: CyclePurpose
  }

passingWorld :: World
passingWorld =
  World
    { worldAttempt = Right 1
    , worldFailAppends = []
    , worldCandidate = Right True
    , worldArtifact = Right "artifactdigest"
    , worldRecapture = Right (identityKeyOfParts fixtureParts)
    , worldPurpose = QualifyNewRun
    }

-- | Run the driver and return what it returned, the events in order, and the
-- ledger it left.
runWorld :: World -> IO (Either String (CycleReport Bool), [Event], CycleLedger)
runWorld = runWorldFrom emptyCycleLedger

-- | The same, over a ledger that already holds a history.
runWorldFrom
  :: CycleLedger -> World -> IO (Either String (CycleReport Bool), [Event], CycleLedger)
runWorldFrom initial world = do
  events <- newIORef []
  ledger <- newIORef initial
  appended <- newIORef (0 :: Int)
  let record event = modifyIORef' events (event :)
      effects =
        CycleEffects
          { effectAttemptNumber = record AskedAttemptNumber >> pure (worldAttempt world)
          , effectNow = pure "2026-10-07T20:00:00Z"
          , effectAppend = \entry -> appendTo events ledger appended world entry
          , effectRunCandidate = record RanCandidate >> pure (worldCandidate world)
          , effectWriteArtifact = \attempt _ -> record (WroteArtifact attempt) >> pure (worldArtifact world)
          , effectRecaptureKey = record Recaptured >> pure (worldRecapture world)
          , effectCandidateSucceeded = id
          , effectCyclePurpose = worldPurpose world
          , effectCleanupRunId = "cascade-qualification-pre-1"
          }
  result <- driveQualificationCycle effects fixtureLabel fixtureParts fixtureAnnotations
  seen <- readIORef events
  finalLedger <- readIORef ledger
  pure (result, reverse seen, finalLedger)

appendTo
  :: IORef [Event]
  -> IORef CycleLedger
  -> IORef Int
  -> World
  -> LedgerRecord
  -> IO (Either String LedgerEntry)
appendTo events ledger counter world record = do
  position <- readIORef counter
  modifyIORef' counter (+ 1)
  modifyIORef' events (eventOf record :)
  if position `elem` worldFailAppends world
    then pure (Left "the disk refused")
    else do
      current <- readIORef ledger
      case appendRecord current record of
        Left refusal -> pure (Left (show refusal))
        Right (next, entry) -> writeIORef ledger next >> pure (Right entry)
 where
  eventOf entry = case entry of
    RecordCycleBegun _ -> AppendedBegun
    RecordCycleClosed closed -> AppendedClosed (closedOutcome closed)
    RecordCutoverMark _ -> AppendedMark

-- Cases ----------------------------------------------------------------------------------

orderCases :: SuiteBuilder ()
orderCases = do
  it "begins before the candidate runs and closes after the artifact and the recapture" $ do
    (result, events, ledger) <- runWorld passingWorld
    events
      `shouldBe` [ AskedAttemptNumber
                 , AppendedBegun
                 , RanCandidate
                 , WroteArtifact 1
                 , Recaptured
                 , AppendedClosed CyclePassed
                 ]
    fmap reportOutcome result `shouldBe` Right CyclePassed
    fmap reportAttempt result `shouldBe` Right 1
    fmap reportArtifactDigest result `shouldBe` Right (Just "artifactdigest")
    map resolvedResolution (resolveAttempts ledger) `shouldBe` [AttemptPassed]
    fmap (entryDigest . reportLastEntry) result `shouldBe` Right (ledgerTip ledger)

  it "carries the attempt number it was given into the artifact" $ do
    -- Two earlier failed attempts of this label make this the third.
    let history = fst (ledgerOf [Fail "pre-1" DeploymentA, Fail "pre-1" DeploymentA])
    (_, events, ledger) <- runWorldFrom history passingWorld {worldAttempt = Right 3}
    elemIndex (WroteArtifact 3) events `shouldSatisfy` isJust
    map resolvedAttempt (resolveAttempts ledger) `shouldBe` [1, 2, 3]

refusalCases :: SuiteBuilder ()
refusalCases = do
  it "leaves no trace when the label is refused before anything ran" $ do
    (result, events, ledger) <- runWorld passingWorld {worldAttempt = Left "already passed"}
    result `shouldSatisfy` isLeft'
    events `shouldBe` [AskedAttemptNumber]
    ledgerEntries ledger `shouldBe` []

  it "does not run the candidate when the beginning cannot be recorded" $ do
    (result, events, ledger) <- runWorld passingWorld {worldFailAppends = [0]}
    fmap reportOutcome result `shouldSatisfy` isLeft'
    events `shouldBe` [AskedAttemptNumber, AppendedBegun]
    ledgerEntries ledger `shouldBe` []
    errorText result `shouldContain` "the candidate did not run"

  it "closes a refused candidate as failed, and still reports the refusal" $ do
    (result, events, ledger) <- runWorld passingWorld {worldCandidate = Left "refused at the effect"}
    result `shouldSatisfy` isLeft'
    events
      `shouldBe` [ AskedAttemptNumber
                 , AppendedBegun
                 , RanCandidate
                 , AppendedClosed (CycleFailed FailedCandidateRefused)
                 ]
    map resolvedResolution (resolveAttempts ledger)
      `shouldBe` [AttemptFailed FailedCandidateRefused]
    errorText result `shouldContain` "refused at the effect"

  it "reports a cycle that ran but could not be closed, and leaves it open" $ do
    (result, _, ledger) <- runWorld passingWorld {worldFailAppends = [1]}
    errorText result `shouldContain` "reads as interrupted"
    map resolvedResolution (resolveAttempts ledger) `shouldBe` [AttemptInterrupted]

outcomeCases :: SuiteBuilder ()
outcomeCases = do
  it
    "QUALIFICATION-FAILED-RUN-REPLAY-2026-10-21 finishes failed cleanup without qualifying the reused run"
    $ do
      let (prior, _) = ledgerOf [Fail "pre-1" DeploymentA]
      (result, events, ledger) <- runWorldFrom prior passingWorld {worldAttempt = Right 2}
      fmap reportOutcome result `shouldBe` Right (CycleFailed FailedHistoricalRecovery)
      events
        `shouldContain` [RanCandidate, WroteArtifact 2, Recaptured, AppendedClosed (CycleFailed FailedHistoricalRecovery)]
      map resolvedResolution (resolveAttempts ledger)
        `shouldBe` [AttemptFailed FailedCandidateRefused, AttemptFailed FailedHistoricalRecovery]
  it "keeps registered/native recovery unqualified even if it has no earlier ledger attempt" $ do
    (result, _, ledger) <- runWorld passingWorld {worldPurpose = RecoverExistingRun}
    fmap reportOutcome result `shouldBe` Right (CycleFailed FailedHistoricalRecovery)
    map resolvedResolution (resolveAttempts ledger) `shouldBe` [AttemptFailed FailedHistoricalRecovery]
  it "keeps interrupted cleanup recovery unqualified when retrying its stable run id" $ do
    let (prior, _) = ledgerOf [Interrupt "pre-1" DeploymentA]
    (result, _, ledger) <- runWorldFrom prior passingWorld {worldAttempt = Right 2}
    fmap reportOutcome result `shouldBe` Right (CycleFailed FailedHistoricalRecovery)
    map resolvedResolution (resolveAttempts ledger)
      `shouldBe` [AttemptInterrupted, AttemptFailed FailedHistoricalRecovery]
  it "preserves a failed cleanup result in the recovery lane" $ do
    (result, _, _) <-
      runWorld passingWorld {worldPurpose = RecoverExistingRun, worldCandidate = Right False}
    fmap reportOutcome result `shouldBe` Right (CycleFailed FailedLifecycleNotSucceeded)
  it "preserves source and artifact failures before classifying historical recovery" $ do
    let moved = identityKeyOfParts fixtureParts {partsGeneratedConfig = digestOf 'M'}
    (drifted, _, _) <-
      runWorld passingWorld {worldPurpose = RecoverExistingRun, worldRecapture = Right moved}
    fmap reportOutcome drifted `shouldBe` Right CycleSourceDrifted
    (unwritten, _, _) <-
      runWorld passingWorld {worldPurpose = RecoverExistingRun, worldArtifact = Left "disk full"}
    fmap reportOutcome unwritten `shouldBe` Right (CycleFailed FailedEvidenceWrite)
  it "records a candidate whose lifecycle did not succeed as failed, with its artifact" $ do
    (result, _, ledger) <- runWorld passingWorld {worldCandidate = Right False}
    fmap reportOutcome result `shouldBe` Right (CycleFailed FailedLifecycleNotSucceeded)
    fmap reportArtifactDigest result `shouldBe` Right (Just "artifactdigest")
    map resolvedResolution (resolveAttempts ledger)
      `shouldBe` [AttemptFailed FailedLifecycleNotSucceeded]

  it "records an artifact that could not be written as failed, with no digest" $ do
    (result, _, ledger) <- runWorld passingWorld {worldArtifact = Left "disk full"}
    fmap reportOutcome result `shouldBe` Right (CycleFailed FailedEvidenceWrite)
    fmap reportArtifactDigest result `shouldBe` Right Nothing
    map resolvedArtifactDigest (resolveAttempts ledger) `shouldBe` [Nothing]

  it "never lets a cycle pass when the source cannot be looked at again, or has moved" $ do
    let moved = identityKeyOfParts fixtureParts {partsGeneratedConfig = digestOf 'M'}
    (drifted, _, driftedLedger) <- runWorld passingWorld {worldRecapture = Right moved}
    fmap reportOutcome drifted `shouldBe` Right CycleSourceDrifted
    map resolvedResolution (resolveAttempts driftedLedger) `shouldBe` [AttemptSourceDrifted]
    (unverifiable, _, unverifiableLedger) <- runWorld passingWorld {worldRecapture = Left "git failed"}
    fmap reportOutcome unverifiable `shouldBe` Right (CycleFailed FailedSourceRecapture)
    map resolvedResolution (resolveAttempts unverifiableLedger)
      `shouldBe` [AttemptFailed FailedSourceRecapture]

-- Helpers ----------------------------------------------------------------------------------

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)

-- | The message of a refusal, empty for a success.
errorText :: Either String a -> String
errorText = fromLeft ""
