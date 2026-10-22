{-# LANGUAGE OverloadedStrings #-}

-- | The order in which one qualification cycle asks the world for things.
--
-- A cycle appends @Begun@ before the destructive candidate runs and @Closed@
-- after, and everything that makes a cycle count or not depends on that order:
-- a @Begun@ that is not on disk before the candidate runs is an attempt nobody
-- can see, and a @Closed@ appended before the source is recaptured certifies a
-- tree nobody looked at. The driver is generic in its monad and takes every
-- effect as an argument, so a test can run it over a recording monad and
-- observe the order the production composition will use.
module Prodbox.Test.CascadeQualificationCycle
  ( CycleEffects (..)
  , CyclePurpose (..)
  , CycleReport (..)
  , driveQualificationCycle
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Prodbox.Test.Qualification.CascadeCycleArtifact (CycleLabel)
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( CycleAnnotations
  , CycleIdentityParts
  , IdentityKey
  , identityKeyOfParts
  )
import Prodbox.Test.Qualification.CascadeCycleLedger
  ( BegunRecord (..)
  , ClosedRecord (..)
  , CycleFailureClass (..)
  , CycleOutcome (..)
  , LedgerEntry
  , LedgerRecord (..)
  )

-- | Everything a cycle needs from outside itself, as the driver asks for it.
data CyclePurpose = QualifyNewRun | RecoverExistingRun
  deriving (Eq, Show)

data CycleEffects m candidate = CycleEffects
  { effectAttemptNumber :: m (Either String Int)
  -- ^ Read the ledger and say which attempt of the label this would be, or
  -- refuse. Nothing has been mutated and nothing has been appended.
  , effectNow :: m Text
  , effectAppend :: LedgerRecord -> m (Either String LedgerEntry)
  , effectRunCandidate :: m (Either String candidate)
  -- ^ The destructive part. Reached only after @Begun@ is on disk.
  , effectWriteArtifact :: Int -> candidate -> m (Either String Text)
  -- ^ Write the artifact for the attempt; the result is its evidence digest.
  , effectRecaptureKey :: m (Either String IdentityKey)
  -- ^ The key the executable source has now.
  , effectCandidateSucceeded :: candidate -> Bool
  , effectCyclePurpose :: !CyclePurpose
  , effectCleanupRunId :: Text
  }

data CycleReport candidate = CycleReport
  { reportAttempt :: !Int
  , reportBeginKey :: !IdentityKey
  , reportOutcome :: !CycleOutcome
  , reportCandidate :: !candidate
  , reportArtifactDigest :: !(Maybe Text)
  , reportLastEntry :: !LedgerEntry
  -- ^ The @Closed@ entry, whose digest is the ledger tip to record.
  }

-- | Drive one cycle: disposition, @Begun@, candidate, artifact, recapture,
-- @Closed@. A refusal before @Begun@ leaves no trace, because nothing ran; once
-- @Begun@ is appended every path out appends @Closed@ or leaves the attempt
-- open, which the ledger reads as interrupted.
driveQualificationCycle
  :: (Monad m)
  => CycleEffects m candidate
  -> CycleLabel
  -> CycleIdentityParts
  -> CycleAnnotations
  -> m (Either String (CycleReport candidate))
driveQualificationCycle effects label parts annotations = do
  attemptResult <- effectAttemptNumber effects
  case attemptResult of
    Left refusal -> pure (Left refusal)
    Right attempt -> do
      startedAt <- effectNow effects
      begun <-
        effectAppend effects $
          RecordCycleBegun
            BegunRecord
              { begunLabel = label
              , begunAttempt = attempt
              , begunKey = beginKey
              , begunParts = parts
              , begunAnnotations = annotations
              , begunStartedAt = startedAt
              }
      case begun of
        Left err ->
          pure (Left ("the cycle was not begun, so the candidate did not run: " ++ err))
        Right _ -> do
          candidateResult <- effectRunCandidate effects
          case candidateResult of
            Left err -> do
              closed <- closeWith attempt (CycleFailed FailedCandidateRefused) Nothing Nothing
              pure (Left (err ++ closeNote closed))
            Right candidate -> afterCandidate attempt candidate
 where
  beginKey = identityKeyOfParts parts

  afterCandidate attempt candidate = do
    written <- effectWriteArtifact effects attempt candidate
    recaptured <- effectRecaptureKey effects
    let artifactDigest = either (const Nothing) Just written
        endKey = either (const beginKey) id recaptured
        outcome = classify attempt (effectCandidateSucceeded effects candidate) written recaptured
    closed <- closeWith attempt outcome (Just endKey) artifactDigest
    pure $ case closed of
      Left err ->
        Left ("the cycle ran but could not be closed in the ledger, so it reads as interrupted: " ++ err)
      Right closedEntry ->
        Right
          CycleReport
            { reportAttempt = attempt
            , reportBeginKey = beginKey
            , reportOutcome = outcome
            , reportCandidate = candidate
            , reportArtifactDigest = artifactDigest
            , reportLastEntry = closedEntry
            }

  classify attempt succeeded written recaptured
    | not succeeded = CycleFailed FailedLifecycleNotSucceeded
    | Left _ <- written = CycleFailed FailedEvidenceWrite
    | Left _ <- recaptured = CycleFailed FailedSourceRecapture
    | Right endKey <- recaptured, endKey /= beginKey = CycleSourceDrifted
    | effectCyclePurpose effects == RecoverExistingRun || attempt /= 1 =
        CycleFailed FailedHistoricalRecovery
    | otherwise = CyclePassed

  closeWith attempt outcome endKey artifactDigest = do
    completedAt <- effectNow effects
    effectAppend effects $
      RecordCycleClosed
        ClosedRecord
          { closedLabel = label
          , closedAttempt = attempt
          , closedEndKey = fromMaybe beginKey endKey
          , closedOutcome = outcome
          , closedArtifactDigest = artifactDigest
          , closedCleanupRunId = effectCleanupRunId effects
          , closedCompletedAt = completedAt
          }

  closeNote closed = case closed of
    Left err -> "; and the cycle could not be closed in the ledger, so it reads as interrupted: " ++ err
    Right _ -> ""
