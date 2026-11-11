{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The AWS stack lifecycle's drill ledger and read-only receipt (Sprint 6.7).
--
-- Each drill appends @Begun@ before it runs and @Closed@ after, so an attempt
-- without a @Closed@ is an interrupted one. Entries are hash-chained: that
-- detects an edit, a reorder, a dropped middle entry and a truncated tail, and
-- is not authentication.
--
-- The receipt judges the claim's exit criteria over the /current run/: the
-- maximal suffix of attempts that are all clean and share one scoped source
-- digest. A drill that needed a hand action, failed, was interrupted, or ran on
-- a different scoped digest ends the run, so earlier clean drills stop counting.
-- A change of Provider image digest under an unchanged scoped digest is reported
-- and does not end the run. Nothing here reads the repository or AWS: the
-- receipt says what it recomputed (the chain, the fold) and what it could only
-- compare (the digests the drills recorded).
module Prodbox.Test.Qualification.AwsLifecycleDrillLedger
  ( DrillKind (..)
  , DrillOutcome (..)
  , DrillBegun (..)
  , DrillClosed (..)
  , DrillRecord (..)
  , DrillLedger
  , emptyDrillLedger
  , drillLedgerTip
  , appendDrillRecord
  , verifyDrillChain
  , drillRecordWellFormed
  , renderDrillLedger
  , parseDrillLedger
  , DrillAttempt (..)
  , resolveDrillAttempts
  , currentRun
  , Criterion (..)
  , criterionName
  , RunReceipt (..)
  , ReceiptVerdict (..)
  , judgeReceipt
  , failureRateBoundPercent
  , uncoveredStatement
  , maximumDestroyMinutes
  )
where

import Data.Char (isControl)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Prodbox.Test.Qualification.Evidence (hashPublicEvidence, publicEvidenceDigestText)

data DrillKind
  = DrillCanary
  | DrillLeakInjectedDestroy
  | DrillKilledMidRunConverge
  | DrillEksCycle
  | DrillSoakRun
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data DrillOutcome
  = DrillClean
  | DrillNeededHandAction
  | DrillFailed
  deriving stock (Eq, Show)

data DrillBegun = DrillBegun
  { begunId :: !Int
  , begunKind :: !DrillKind
  , begunScopedDigest :: !Text
  , begunImageDigest :: !Text
  , begunDay :: !Int
  -- ^ Calendar day ordinal the drill began on.
  }
  deriving stock (Eq, Show)

data DrillClosed = DrillClosed
  { closedId :: !Int
  , closedOutcome :: !DrillOutcome
  , closedDestroyMinutes :: !(Maybe Int)
  , closedScopedDiffEmpty :: !Bool
  , closedAfterUnchangedScopeMerge :: !Bool
  -- ^ A soak run that followed a merge leaving the scoped list unchanged.
  }
  deriving stock (Eq, Show)

data DrillRecord
  = RecordBegun !DrillBegun
  | RecordClosed !DrillClosed
  deriving stock (Eq, Show)

data DrillEntry = DrillEntry
  { entryRecord :: !DrillRecord
  , entryPrevious :: !Text
  , entryDigest :: !Text
  }
  deriving stock (Eq, Show)

newtype DrillLedger = DrillLedger [DrillEntry] -- newest first
  deriving stock (Eq, Show)

emptyDrillLedger :: DrillLedger
emptyDrillLedger = DrillLedger []

genesisDigest :: Text
genesisDigest = publicEvidenceDigestText (hashPublicEvidence "prodbox-aws-lifecycle-drill-ledger/v1")

drillLedgerTip :: DrillLedger -> Text
drillLedgerTip (DrillLedger entries) = case entries of
  [] -> genesisDigest
  entry : _ -> entryDigest entry

renderRecord :: DrillRecord -> Text
renderRecord record = case record of
  RecordBegun b ->
    Text.intercalate
      "|"
      [ "begun"
      , Text.pack (show (begunId b))
      , Text.pack (show (begunKind b))
      , begunScopedDigest b
      , begunImageDigest b
      , Text.pack (show (begunDay b))
      ]
  RecordClosed c ->
    Text.intercalate
      "|"
      [ "closed"
      , Text.pack (show (closedId c))
      , Text.pack (show (closedOutcome c))
      , Text.pack (show (closedDestroyMinutes c))
      , Text.pack (show (closedScopedDiffEmpty c))
      , Text.pack (show (closedAfterUnchangedScopeMerge c))
      ]

chainDigest :: Text -> DrillRecord -> Text
chainDigest previous record =
  publicEvidenceDigestText (hashPublicEvidence (previous <> "\n" <> renderRecord record))

appendDrillRecord :: DrillRecord -> DrillLedger -> DrillLedger
appendDrillRecord record ledger@(DrillLedger entries) =
  let previous = drillLedgerTip ledger
   in DrillLedger (DrillEntry record previous (chainDigest previous record) : entries)

-- | Recompute every link from the genesis digest. 'False' means an entry was
-- edited, reordered or dropped from the middle.
verifyDrillChain :: DrillLedger -> Bool
verifyDrillChain (DrillLedger entries) = go genesisDigest (reverse entries)
 where
  go _ [] = True
  go previous (entry : rest) =
    entryPrevious entry == previous
      && entryDigest entry == chainDigest previous (entryRecord entry)
      && go (entryDigest entry) rest

data DrillAttempt = DrillAttempt
  { attemptBegun :: !DrillBegun
  , attemptClosed :: !(Maybe DrillClosed)
  -- ^ 'Nothing' is an interrupted attempt.
  }
  deriving stock (Eq, Show)

-- | Attempts in ledger order. A @Begun@ is closed only by the next record when
-- it carries the same id; anything else leaves it interrupted.
resolveDrillAttempts :: DrillLedger -> [DrillAttempt]
resolveDrillAttempts (DrillLedger entries) = go (map entryRecord (reverse entries))
 where
  go records = case records of
    RecordBegun b : RecordClosed c : rest
      | closedId c == begunId b -> DrillAttempt b (Just c) : go rest
    RecordBegun b : rest -> DrillAttempt b Nothing : go rest
    RecordClosed _ : rest -> go rest
    [] -> []

attemptClean :: DrillAttempt -> Bool
attemptClean attempt = case attemptClosed attempt of
  Just closed -> closedOutcome closed == DrillClean
  Nothing -> False

-- | The maximal suffix of attempts that are all clean on the newest attempt's
-- scoped digest. Empty when the newest attempt is not clean.
currentRun :: [DrillAttempt] -> [DrillAttempt]
currentRun attempts = case reverse attempts of
  [] -> []
  newest : older ->
    let digest = begunScopedDigest (attemptBegun newest)
        sameCleanRun a = attemptClean a && begunScopedDigest (attemptBegun a) == digest
     in if sameCleanRun newest
          then reverse (newest : takeWhile sameCleanRun older)
          else []

data Criterion
  = CanaryPassedTwice
  | LeakInjectedDestroyClean
  | KilledDestroyConverges
  | TwoConsecutiveEksCycles
  | TenRunSoakOverFiveDays
  | SoakAfterUnchangedScopeMerges
  deriving stock (Bounded, Enum, Eq, Show)

criterionName :: Criterion -> Text
criterionName criterion = case criterion of
  CanaryPassedTwice -> "the canary passes twice"
  LeakInjectedDestroyClean -> "a leak-injected EKS destroy ends Clean"
  KilledDestroyConverges -> "a destroy killed mid-run converges on rerun"
  TwoConsecutiveEksCycles -> "two consecutive EKS cycles, empty scoped diff, destroy within the bound"
  TenRunSoakOverFiveDays -> "a soak of ten runs over at least five calendar days"
  SoakAfterUnchangedScopeMerges -> "two soak runs after merges that leave the scoped list unchanged"

-- | The destroy-time bound, in minutes, an EKS cycle must finish inside.
maximumDestroyMinutes :: Int
maximumDestroyMinutes = 25

data ReceiptVerdict
  = NotQualified ![Criterion]
  | Qualified
  deriving stock (Eq, Show)

data RunReceipt = RunReceipt
  { receiptVerdict :: !ReceiptVerdict
  , receiptRunLength :: !Int
  , receiptBoundPercent :: !Int
  -- ^ Upper bound on the failure rate, at 95% confidence, from the EKS cycles.
  , receiptImageDigestChanges :: !Int
  -- ^ Reported, never resetting.
  , receiptChainIntact :: !Bool
  , receiptRecomputed :: !Text
  , receiptCompared :: !Text
  , receiptUncovered :: !Text
  }
  deriving stock (Eq, Show)

-- | Upper bound, in whole percent rounded up, on the failure probability after
-- @n@ trials without a failure at 95% confidence: @1 - 0.05^(1/n)@. Two clean
-- cycles give 78%. No trial bounds nothing (100%).
failureRateBoundPercent :: Int -> Int
failureRateBoundPercent n
  | n <= 0 = 100
  | otherwise = min 100 (ceiling (100 * (1 - 0.05 ** (1 / fromIntegral n) :: Double)))

uncoveredStatement :: Text
uncoveredStatement =
  "not covered: the retained TLS lane, the credential and EAB chain, SES, Keycloak, every chart, \
  \and the home cascade cutover; depended on and not qualified: the retained Authority, Vault, \
  \the Authority Backup Adapter, and the credential reconcile that provisions the Provider"

judgeReceipt :: DrillLedger -> RunReceipt
judgeReceipt ledger =
  RunReceipt
    { receiptVerdict = verdict
    , receiptRunLength = length run
    , receiptBoundPercent = failureRateBoundPercent (length eksCycles)
    , receiptImageDigestChanges = length (drop 1 (nubInOrder (map (begunImageDigest . attemptBegun) run)))
    , receiptChainIntact = intact
    , receiptRecomputed = "hash chain and the consecutive-run fold"
    , receiptCompared = "the scoped source digest and Provider image digest each drill recorded"
    , receiptUncovered = uncoveredStatement
    }
 where
  intact = verifyDrillChain ledger
  run = if intact then currentRun (resolveDrillAttempts ledger) else []
  ofKind kind = filter ((== kind) . begunKind . attemptBegun) run
  closedOf attempt = attemptClosed attempt
  eksCycles =
    [ a
    | a <- ofKind DrillEksCycle
    , Just c <- [closedOf a]
    , closedScopedDiffEmpty c
    , maybe False (<= maximumDestroyMinutes) (closedDestroyMinutes c)
    ]
  soak = ofKind DrillSoakRun
  soakDays = map (begunDay . attemptBegun) soak
  soakSpan = if null soakDays then 0 else maximum soakDays - minimum soakDays
  mergeSoaks = length [() | a <- soak, Just c <- [closedOf a], closedAfterUnchangedScopeMerge c]
  met criterion = case criterion of
    CanaryPassedTwice -> length (ofKind DrillCanary) >= 2
    LeakInjectedDestroyClean -> not (null (ofKind DrillLeakInjectedDestroy))
    KilledDestroyConverges -> not (null (ofKind DrillKilledMidRunConverge))
    TwoConsecutiveEksCycles -> length eksCycles >= 2 && length eksCycles == length (ofKind DrillEksCycle)
    TenRunSoakOverFiveDays -> length soak >= 10 && soakSpan >= 5
    SoakAfterUnchangedScopeMerges -> mergeSoaks >= 2
  missing = filter (not . met) [minBound .. maxBound]
  verdict = if null missing then Qualified else NotQualified missing

nubInOrder :: (Eq a) => [a] -> [a]
nubInOrder = nub

-- | A record the line format can carry: every text field non-empty and free of
-- the field separator and of control characters. The store refuses anything else
-- rather than writing a line that would parse as a different record.
drillRecordWellFormed :: DrillRecord -> Bool
drillRecordWellFormed record = case record of
  RecordBegun b ->
    all cleanField [begunScopedDigest b, begunImageDigest b]
      && begunId b >= 0
      && begunDay b >= 0
  RecordClosed c -> closedId c >= 0 && maybe True (>= 0) (closedDestroyMinutes c)
 where
  cleanField field = not (Text.null field) && Text.all (\c -> c /= '|' && not (isControl c)) field

-- | The ledger as lines, oldest first: @previous|digest|record@.
renderDrillLedger :: DrillLedger -> Text
renderDrillLedger (DrillLedger entries) =
  Text.unlines
    [ Text.intercalate "|" [entryPrevious e, entryDigest e, renderRecord (entryRecord e)]
    | e <- reverse entries
    ]

-- | Parse and verify. Every line's recorded previous digest and own digest must
-- be what recomputation gives, so an edit, reorder or dropped middle entry is
-- refused with the line number; a truncated tail is indistinguishable from an
-- earlier ledger, as with any hash chain without an external tip.
parseDrillLedger :: Text -> Either Text DrillLedger
parseDrillLedger raw = go emptyDrillLedger (zip [1 :: Int ..] (filter (not . Text.null) (Text.lines raw)))
 where
  go ledger [] = Right ledger
  go ledger ((n, line) : rest) = case Text.splitOn "|" line of
    previous : digest : recordFields -> do
      record <- maybe (Left (refuse n "malformed record")) Right (parseRecord recordFields)
      if not (drillRecordWellFormed record)
        then Left (refuse n "record is not well formed")
        else do
          let next = appendDrillRecord record ledger
          if previous == drillLedgerTip ledger && digest == drillLedgerTip next
            then go next rest
            else Left (refuse n "hash chain does not match")
    _ -> Left (refuse n "malformed line")
  refuse n detail = "drill ledger line " <> Text.pack (show n) <> ": " <> detail

parseRecord :: [Text] -> Maybe DrillRecord
parseRecord fields = case fields of
  ["begun", i, kind, scoped, image, day] ->
    RecordBegun <$> (DrillBegun <$> int i <*> parseKind kind <*> pure scoped <*> pure image <*> int day)
  ["closed", i, outcome, minutes, diff, merged] ->
    RecordClosed
      <$> ( DrillClosed
              <$> int i
              <*> parseOutcome outcome
              <*> parseMinutes minutes
              <*> parseBool diff
              <*> parseBool merged
          )
  _ -> Nothing
 where
  int t = case TextRead.decimal t of
    Right (value, rest) | Text.null rest -> Just value
    _ -> Nothing
  parseKind t = lookup t [(Text.pack (show k), k) | k <- [minBound .. maxBound]]
  parseOutcome t = lookup t [(Text.pack (show o), o) | o <- [DrillClean, DrillNeededHandAction, DrillFailed]]
  parseBool t = lookup t [("True", True), ("False", False)]
  parseMinutes t
    | t == "Nothing" = Just Nothing
    | Just number <- Text.stripPrefix "Just " t = Just <$> int number
    | otherwise = Nothing
