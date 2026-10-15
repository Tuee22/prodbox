{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The operator-facing reading of a failed provider command.
--
-- A Pulumi destroy can run for most of an hour, retry one AWS dependency error
-- hundreds of times, and then end on an unrelated credential-expiry error.
-- Keeping the first 4096 characters of the transcript named neither: the head
-- held the retried error's noise and the tail, which held the final error, was
-- dropped. This module reads the whole transcript, names the first AWS error
-- as the cause and the last differing one as the consequence, and keeps a
-- bounded head and tail of the transcript beside them.
--
-- It is pure. A classifier must read the whole transcript and only the display
-- text may be shortened, so the substring predicates that decide how a Pulumi
-- stack command ended live here beside the renderer.
module Prodbox.ControlPlane.ProviderFailureSummary
  ( FailureFinding (..)
  , FailureSummary (..)
  , failureDetailBound
  , childTimeoutMarker
  , childTimedOutCode
  , summarizeFailure
  , renderFailureSummary
  , boundedTranscript
  , renderCommandFailure
  , transcriptReportsMissingStack
  , transcriptReportsPreviewChanges
  )
where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isHexDigit)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text

-- | The longest rendered failure detail: the bound the head-only truncation
-- used, so no downstream size assumption changes.
failureDetailBound :: Int
failureDetailBound = 4096

transcriptHeadLength :: Int
transcriptHeadLength = 512

-- | Room kept for the omission marker so the bound holds exactly.
omissionMarkerReserve :: Int
omissionMarkerReserve = 48

-- | Written into a transcript by the runner that stopped the child at its
-- deadline. The summary reads it as the typed @ChildTimedOut@ finding, always
-- last, so a destroy that ran out of time reports that as the consequence of
-- whatever it had already reported.
childTimeoutMarker :: Text
childTimeoutMarker = "[child-timeout]"

childTimedOutCode :: Text
childTimedOutCode = "ChildTimedOut"

-- | One AWS error the transcript reported: the code AWS returned and, when
-- the same line names one, the resource it concerned.
data FailureFinding = FailureFinding
  { findingCode :: !Text
  , findingResource :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data FailureSummary = FailureSummary
  { summaryCause :: !(Maybe FailureFinding)
  , summaryCauseOccurrences :: !Int
  , summaryConsequence :: !(Maybe FailureFinding)
  }
  deriving stock (Eq, Show)

-- | Read the whole transcript. The cause is the first AWS error reported and
-- the consequence is the last one whose code differs from it.
summarizeFailure :: Text -> FailureSummary
summarizeFailure transcript =
  FailureSummary
    { summaryCause = cause
    , summaryCauseOccurrences = maybe 0 occurrences cause
    , summaryConsequence = cause >>= consequenceOf
    }
 where
  findings = errorFindings transcript
  cause = case findings of
    [] -> Nothing
    firstFinding : _ -> Just firstFinding
  occurrences found = length (filter ((== findingCode found) . findingCode) findings)
  consequenceOf found =
    find ((/= findingCode found) . findingCode) (reverse findings)

errorFindings :: Text -> [FailureFinding]
errorFindings transcript =
  [ FailureFinding code (firstResourceId (lineAround before rest))
  | (before, match) <- Text.breakOnAll errorMarker transcript
  , let rest = Text.drop (Text.length errorMarker) match
        code = Text.takeWhile isCodeCharacter rest
  , startsWithUpper code
  ]
    <> [ FailureFinding childTimedOutCode Nothing
       | childTimeoutMarker `Text.isInfixOf` transcript
       ]
 where
  errorMarker = "api error "
  lineAround before rest =
    Text.takeWhileEnd (/= '\n') before <> Text.takeWhile (/= '\n') rest
  startsWithUpper code = case Text.uncons code of
    Just (initial, _) -> isAsciiUpper initial
    Nothing -> False
  isCodeCharacter character =
    isAsciiUpper character
      || isAsciiLower character
      || isDigit character
      || character == '.'
      || character == '_'

firstResourceId :: Text -> Maybe Text
firstResourceId = find isResourceId . Text.split (not . isIdCharacter)
 where
  isIdCharacter character =
    isAsciiLower character || isDigit character || character == '-'

-- | An EC2-style identifier: a short lowercase prefix, a dash, and 8 to 17 hex
-- digits (@subnet-0123456789abcdef0@, @sg-0123456789abcdef0@).
isResourceId :: Text -> Bool
isResourceId word = case Text.splitOn "-" word of
  [prefix, identifier] ->
    Text.length prefix >= 1
      && Text.length prefix <= 9
      && Text.all isAsciiLower prefix
      && Text.length identifier >= 8
      && Text.length identifier <= 17
      && Text.all isHexDigit identifier
  _ -> False

-- | One line naming the cause and, when it differs, the consequence; empty
-- when the transcript carries no AWS error code.
renderFailureSummary :: FailureSummary -> Text
renderFailureSummary summary = case summaryCause summary of
  Nothing -> ""
  Just cause ->
    "cause: "
      <> renderFinding cause
      <> repeats
      <> maybe
        ""
        (\consequence -> "; consequence: " <> renderFinding consequence)
        (summaryConsequence summary)
 where
  repeats
    | summaryCauseOccurrences summary > 1 =
        " (reported " <> Text.pack (show (summaryCauseOccurrences summary)) <> " times)"
    | otherwise = ""
  renderFinding finding =
    findingCode finding <> maybe "" (" on " <>) (findingResource finding)

-- | Keep a bounded head and the tail of a transcript, naming how much was
-- left out. A transcript within the budget is returned whole.
boundedTranscript :: Int -> Text -> Text
boundedTranscript budget transcript
  | budget <= 0 = ""
  | Text.length transcript <= budget = transcript
  | tailLength <= 0 = Text.take budget transcript
  | otherwise =
      Text.take headLength transcript
        <> " [... "
        <> Text.pack (show omitted)
        <> " characters omitted ...] "
        <> Text.takeEnd tailLength transcript
 where
  headLength = min transcriptHeadLength (budget `div` 4)
  tailLength = budget - headLength - omissionMarkerReserve
  omitted = Text.length transcript - headLength - tailLength

-- | The display text for a failed command: the cause and consequence first,
-- then a bounded head and tail of the transcript, within 'failureDetailBound'.
-- The transcript is standard error then standard output, as before.
renderCommandFailure :: Text -> Text -> Text
renderCommandFailure standardError standardOutput =
  prefix <> boundedTranscript (failureDetailBound - Text.length prefix) transcript
 where
  transcript = standardError <> " " <> standardOutput
  header = renderFailureSummary (summarizeFailure transcript)
  prefix
    | Text.null header = ""
    | otherwise = header <> " | transcript: "

-- | Whether a stack command's whole transcript says the stack does not exist.
transcriptReportsMissingStack :: Text -> Bool
transcriptReportsMissingStack =
  containsAnyFolded ["no stack named", "could not find stack", "stack not found"]

-- | Whether a preview's whole transcript says it proposed changes it was told
-- not to expect. That error is printed after the resource listing, so it sits
-- at the end of a long transcript.
transcriptReportsPreviewChanges :: Text -> Bool
transcriptReportsPreviewChanges =
  containsAnyFolded
    [ "no changes were expected but changes were proposed"
    , "error: no changes were expected"
    ]

containsAnyFolded :: [Text] -> Text -> Bool
containsAnyFolded needles haystack = any (`Text.isInfixOf` lowered) needles
 where
  lowered = Text.toLower haystack
