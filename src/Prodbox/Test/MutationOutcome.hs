{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Classification of observations supplied by an outer mutation runner.
-- This module does not execute a mutant, establish isolation, or authenticate
-- the observations passed to it.
module Prodbox.Test.MutationOutcome
  ( MutationBinding (..)
  , MutationSelection
  , MutationSelectionError (..)
  , validateMutationSelection
  , MutationBoundary (..)
  , MutationBaseline (..)
  , MutationPatch (..)
  , MutationBuild (..)
  , MutationTest (..)
  , MutationAttempt (..)
  , MutationOutcome (..)
  , classifyMutationAttempt
  , decodeSingleMutationTest
  )
where

import Data.ByteString qualified as ByteString
import Data.Char (isAsciiLower, isControl, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32)
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest)
import Prodbox.Test.Qualification.SourceIdentity (SourceIdentity)
import System.Exit (ExitCode (..))

-- All digests are independently observed non-secret identities. Constructing
-- this record does not establish where any observation came from.
data MutationBinding = MutationBinding
  { mutationSource :: !SourceIdentity
  , mutationBaselineBinary :: !PublicEvidenceDigest
  , mutationPatchDigest :: !PublicEvidenceDigest
  , mutationTestSelection :: !PublicEvidenceDigest
  , mutationExpectedTestPath :: !Text
  , mutationExpectedAssertion :: !Text
  }
  deriving stock (Eq, Show)

data MutationBoundary = BoundaryConfirmed | BoundaryFailed | BoundaryUnobservable
  deriving stock (Eq, Show)

-- The producer and binary digest must still be independently verified.
data MutationSelection = MutationSelection !Text !PublicEvidenceDigest
  deriving stock (Eq, Show)

data MutationSelectionError
  = MutationSelectionInvalidExpected
  | MutationSelectionCommandFailed
  | MutationSelectionContaminated
  | MutationSelectionMismatch
  deriving stock (Eq, Show)

-- | Require exactly one reviewed full test path and no other output. A list
-- supplied by an untrusted binary does not authenticate its own producer.
validateMutationSelection
  :: Text
  -> PublicEvidenceDigest
  -> ExitCode
  -> ByteString.ByteString
  -> ByteString.ByteString
  -> Either MutationSelectionError MutationSelection
validateMutationSelection expected binary exitCode stdoutBytes stderrBytes
  | not (validTestPath expected) = Left MutationSelectionInvalidExpected
  | exitCode /= ExitSuccess = Left MutationSelectionCommandFailed
  | not (ByteString.null stderrBytes) = Left MutationSelectionContaminated
  | stdoutBytes /= TextEncoding.encodeUtf8 expected <> "\n" = Left MutationSelectionMismatch
  | otherwise = Right (MutationSelection expected binary)

data MutationBaseline = BaselinePassed !Word32 | BaselineFailed | BaselineUnobservable
  deriving stock (Eq, Show)

data MutationPatch = PatchApplied | PatchPreconditionFailed | PatchUnobservable
  deriving stock (Eq, Show)

data MutationBuild
  = BuildNotRun
  | BuildSucceeded !PublicEvidenceDigest
  | BuildRejected
  | BuildUnobservable
  deriving stock (Eq, Show)

data MutationTest
  = TestNotRun
  | TestPassed !Word32
  | TestAssertionFailures !Word32 ![Text]
  | TestTimedOut
  | TestCrashed
  | TestUnobservable
  deriving stock (Eq, Show)

data MutationAttempt = MutationAttempt
  { observedMutationBinding :: !MutationBinding
  , observedIsolation :: !MutationBoundary
  , observedCleanup :: !MutationBoundary
  , observedBaseline :: !MutationBaseline
  , observedBaselineSelection :: !(Maybe MutationSelection)
  , observedPatch :: !MutationPatch
  , observedBuild :: !MutationBuild
  , observedMutantSelection :: !(Maybe MutationSelection)
  , observedTest :: !MutationTest
  }
  deriving stock (Eq, Show)

data MutationOutcome = MutationKilled | MutationSurvived | MutationInvalid | MutationInconclusive
  deriving stock (Eq, Show)

-- | Decode only the fixed single-test transport produced by the opt-in test
-- reporter. The outer runner must independently bind the selected test and
-- protect the transport: this parser cannot authenticate a child process.
decodeSingleMutationTest
  :: Text -> ExitCode -> ByteString.ByteString -> ByteString.ByteString -> MutationTest
decodeSingleMutationTest assertion exitCode stdoutBytes stderrBytes
  | not (validAssertion assertion) || not (ByteString.null stdoutBytes) = TestUnobservable
  | otherwise = case (exitCode, stderrBytes) of
      (ExitSuccess, "prodbox-mutation-test-v1:passed\n") -> TestPassed 1
      (ExitFailure 1, "prodbox-mutation-test-v1:assertion-failed\n") -> TestAssertionFailures 1 [assertion]
      (ExitFailure 1, "prodbox-mutation-test-v1:other-failure\n") -> TestAssertionFailures 1 []
      (ExitFailure 1, "prodbox-mutation-test-v1:timeout\n") -> TestTimedOut
      (ExitFailure 1, "prodbox-mutation-test-v1:exception\n") -> TestCrashed
      _ -> TestUnobservable

-- | A kill requires the exact designated failure and no unrelated failure.
-- Failed/unobservable isolation or cleanup, stale binding, a failed baseline,
-- and missing observations take precedence over a test exit code. Equivalence
-- requires a separate documented review and is never inferred here.
classifyMutationAttempt :: MutationBinding -> MutationAttempt -> MutationOutcome
classifyMutationAttempt expected actual
  | not
      ( validAssertion (mutationExpectedAssertion expected)
          && validTestPath (mutationExpectedTestPath expected)
      ) =
      MutationInconclusive
  | observedMutationBinding actual /= expected = MutationInconclusive
  | observedIsolation actual /= BoundaryConfirmed = MutationInconclusive
  | observedCleanup actual /= BoundaryConfirmed = MutationInconclusive
  | not (baselinePassed (observedBaseline actual)) = MutationInconclusive
  | observedBaselineSelection actual
      /= Just (MutationSelection (mutationExpectedTestPath expected) (mutationBaselineBinary expected)) =
      MutationInconclusive
  | otherwise = case observedPatch actual of
      PatchPreconditionFailed ->
        if observedBuild actual == BuildNotRun
          && observedMutantSelection actual == Nothing
          && observedTest actual == TestNotRun
          then MutationInvalid
          else MutationInconclusive
      PatchUnobservable -> MutationInconclusive
      PatchApplied -> case observedBuild actual of
        BuildRejected ->
          if observedMutantSelection actual == Nothing && observedTest actual == TestNotRun
            then MutationInvalid
            else MutationInconclusive
        BuildNotRun -> MutationInconclusive
        BuildUnobservable -> MutationInconclusive
        BuildSucceeded mutant | mutant == mutationBaselineBinary expected -> MutationInconclusive
        BuildSucceeded mutant
          | observedMutantSelection actual
              /= Just (MutationSelection (mutationExpectedTestPath expected) mutant) ->
              MutationInconclusive
        BuildSucceeded _ -> case observedTest actual of
          TestPassed count -> if count == 1 then MutationSurvived else MutationInconclusive
          TestAssertionFailures count [assertion]
            | count == 1 && assertion == mutationExpectedAssertion expected -> MutationKilled
          TestAssertionFailures _ _ -> MutationInconclusive
          TestNotRun -> MutationInconclusive
          TestTimedOut -> MutationInconclusive
          TestCrashed -> MutationInconclusive
          TestUnobservable -> MutationInconclusive

baselinePassed :: MutationBaseline -> Bool
baselinePassed (BaselinePassed count) = count == 1
baselinePassed BaselineFailed = False
baselinePassed BaselineUnobservable = False

validAssertion :: Text -> Bool
validAssertion value =
  not (Text.null value)
    && Text.length value <= 128
    && Text.all
      ( \character ->
          isAsciiLower character
            || (isDigit character && character <= '9')
            || character `elem` ("._-" :: String)
      )
      value

validTestPath :: Text -> Bool
validTestPath value =
  not (Text.null (Text.strip value)) && Text.length value <= 512 && Text.all (not . isControl) value
