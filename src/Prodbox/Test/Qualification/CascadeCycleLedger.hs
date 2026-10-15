{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The append-only record of qualification cycles, and the judgment that two
-- consecutive cycles ran on one deployment.
--
-- A cycle's artifact is written only when its candidate returns, so on its own
-- it makes a failure, an interruption or a source edit during a cycle invisible:
-- a failed attempt between two successes would leave "two consecutive
-- successes" standing. The ledger is the record that cannot be skipped. A cycle
-- appends @Begun@ immediately before its candidate runs and @Closed@ after, so
-- an attempt that has no @Closed@ is an interrupted one, and every attempt of
-- every label counts in the order the ledger gives them.
--
-- Each entry commits to the digest of the one before it. That detects an edit,
-- a reorder, a dropped middle entry and a truncated tail; it is not
-- authentication, and a local writer who rewrites every entry and every
-- artifact consistently is not stopped by it.
--
-- The judge is the only producer of 'ConsecutiveCycleProof'. A proof is
-- evidence that two attempts passed in a row on one identity and that their
-- artifacts say what the ledger says; whether the current tree is still that
-- identity is a separate question the observer asks after the proof exists.
module Prodbox.Test.Qualification.CascadeCycleLedger
  ( requiredConsecutiveCycles
  , CycleFailureClass (..)
  , CycleOutcome (..)
  , LedgerRecord (..)
  , BegunRecord (..)
  , ClosedRecord (..)
  , CutoverMarkKind (..)
  , renderCutoverMarkKind
  , MarkRecord (..)
  , LedgerEntry (..)
  , CycleLedger
  , emptyCycleLedger
  , ledgerEntries
  , ledgerTip
  , ledgerContainsDigest
  , labelDisposition
  , appendRecord
  , renderLedgerEntry
  , renderCycleOutcome
  , parseCycleLedger
  , AttemptResolution (..)
  , ResolvedAttempt (..)
  , resolveAttempts
  , ConsecutiveCycleProof
  , proofKey
  , proofParts
  , proofLabels
  , proofAttempts
  , proofArtifactDigests
  , proofAwsScope
  , proofTip
  , proofAnnotations
  , CutoverEpoch (..)
  , epochOfLedger
  , lastMarkOf
  , LedgerPhase
  , ledgerPhase
  , phaseEpoch
  , qualifyingRun
  , judgeConsecutiveCycles
  , BlockingAttempt (..)
  , LedgerRefusal (..)
  , renderLedgerRefusal
  )
where

import Data.Char (isAlphaNum, isDigit)
import Data.List (find, nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Prodbox.Test.Qualification.CascadeCycleArtifact
  ( ArtifactDefect
  , ArtifactFact (..)
  , CycleLabel
  , cycleLabelText
  , mkCycleLabel
  )
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( CycleAnnotations (..)
  , CycleIdentityParts (..)
  , IdentityComponent
  , IdentityKey
  , diffParts
  , identityComponentName
  , identityKeyOfParts
  , identityKeyText
  , localKeyOfParts
  , mkIdentityKey
  )
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , hashPublicEvidence
  , mkPublicEvidenceDigest
  , publicEvidenceDigestText
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceManifestPolicyIdentity (..)
  , WorktreeState (..)
  )

-- | How many consecutive qualifying attempts on one identity the plan requires.
requiredConsecutiveCycles :: Int
requiredConsecutiveCycles = 2

-- Records ------------------------------------------------------------------------

-- | Why an attempt that ran did not qualify. Each is a distinct fact about what
-- happened, and none of them is a refusal before anything was mutated: those
-- append nothing.
data CycleFailureClass
  = -- | The candidate returned a refusal or an error.
    FailedCandidateRefused
  | -- | The candidate returned, and its lifecycle result did not succeed.
    FailedLifecycleNotSucceeded
  | -- | The candidate succeeded and its artifact could not be written.
    FailedEvidenceWrite
  | -- | The executable source could not be captured again, so the cycle cannot
    -- say it ended on the source it began with.
    FailedSourceRecapture
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data CycleOutcome
  = CyclePassed
  | CycleFailed !CycleFailureClass
  | -- | The cycle succeeded, but the executable source was not the source it
    -- began with.
    CycleSourceDrifted
  deriving stock (Eq, Show)

-- | One thing the ledger records. Every field is public and secret-free.
data LedgerRecord
  = -- | Appended after every check that mutates nothing, and immediately before
    -- the candidate runs.
    RecordCycleBegun !BegunRecord
  | -- | Appended after the artifact write, for the attempt the last @Begun@ opened.
    RecordCycleClosed !ClosedRecord
  | -- | A step of the single-writer cutover, recorded by key. The typed cutover
    -- state is indexed by an identity that cannot be recomputed once the
    -- activating edit lands, so the ledger records the keys instead and replays
    -- them.
    RecordCutoverMark !MarkRecord
  deriving stock (Eq, Show)

data BegunRecord = BegunRecord
  { begunLabel :: !CycleLabel
  , begunAttempt :: !Int
  , begunKey :: !IdentityKey
  , begunParts :: !CycleIdentityParts
  , begunAnnotations :: !CycleAnnotations
  , begunStartedAt :: !Text
  }
  deriving stock (Eq, Show)

data CutoverMarkKind
  = MarkActivated
  | MarkLegacyRouteDeleted
  | MarkPostActivationQualified
  deriving stock (Bounded, Enum, Eq, Ord, Show)

renderCutoverMarkKind :: CutoverMarkKind -> Text
renderCutoverMarkKind kind = case kind of
  MarkActivated -> "activated"
  MarkLegacyRouteDeleted -> "legacy-route-deleted"
  MarkPostActivationQualified -> "post-activation-qualified"

-- | What a cutover step records.
--
-- The /local/ key covers what a process can recompute: the executable source
-- and the digests derived from it. It leaves out the images and the shape of
-- the compiled program, because those are unknowable until a cycle observes
-- them, and the images are rebuilt by the very edits a cutover makes. So a
-- mark can say which tree it was recorded on without predicting what the
-- cycles that follow will observe of it.
data MarkRecord = MarkRecord
  { markKind :: !CutoverMarkKind
  , markWitnessKey :: !IdentityKey
  -- ^ The full key of the pair of cycles that licensed the cutover.
  , markLocalKey :: !IdentityKey
  -- ^ The local key of the tree the mark was recorded on.
  , markWitnessLabels :: ![CycleLabel]
  , markWitnessArtifacts :: ![Text]
  , markRecordedAt :: !Text
  }
  deriving stock (Eq, Show)

data ClosedRecord = ClosedRecord
  { closedLabel :: !CycleLabel
  , closedAttempt :: !Int
  , closedEndKey :: !IdentityKey
  , closedOutcome :: !CycleOutcome
  , closedArtifactDigest :: !(Maybe Text)
  , closedCleanupRunId :: !Text
  , closedCompletedAt :: !Text
  }
  deriving stock (Eq, Show)

data LedgerEntry = LedgerEntry
  { entrySequence :: !Int
  , entryPrevious :: !PublicEvidenceDigest
  , entryRecord :: !LedgerRecord
  , entryDigest :: !PublicEvidenceDigest
  , entryLine :: !Text
  -- ^ The canonical line, digest included, exactly as it is written.
  }
  deriving stock (Eq, Show)

-- | A ledger exists only as the empty one, as the result of 'appendRecord', or
-- as the result of 'parseCycleLedger', which replays the same rules. Entries are
-- held newest first.
newtype CycleLedger = CycleLedger [LedgerEntry]
  deriving stock (Eq, Show)

emptyCycleLedger :: CycleLedger
emptyCycleLedger = CycleLedger []

-- | Oldest first.
ledgerEntries :: CycleLedger -> [LedgerEntry]
ledgerEntries (CycleLedger newestFirst) = reverse newestFirst

-- | The digest the next entry commits to.
ledgerTip :: CycleLedger -> PublicEvidenceDigest
ledgerTip (CycleLedger newestFirst) = case newestFirst of
  newest : _ -> entryDigest newest
  [] -> genesisDigest

genesisDigest :: PublicEvidenceDigest
genesisDigest = hashPublicEvidence "prodbox-cascade-cycle-ledger/v1"

-- | The sequence number of the entry with this digest, if the ledger has one.
ledgerContainsDigest :: CycleLedger -> PublicEvidenceDigest -> Maybe Int
ledgerContainsDigest ledger wanted =
  entrySequence <$> find ((== wanted) . entryDigest) (ledgerEntries ledger)

-- Refusals -------------------------------------------------------------------------

-- | The attempt that stopped a walk, named so the refusal says which one.
data BlockingAttempt = BlockingAttempt
  { blockerLabel :: !CycleLabel
  , blockerAttempt :: !Int
  , blockerResolution :: !AttemptResolution
  }
  deriving stock (Eq, Show)

data LedgerRefusal
  = LedgerEmptyOfCycles
  | LedgerChainBroken !Int
  | LedgerEntryMalformed !Int !Text
  | LedgerRecordUnrenderable !Text
  | LedgerRecordInconsistent !Text
  | LedgerRecordOutOfOrder !Text
  | LabelAlreadyPassed !CycleLabel
  | InsufficientConsecutiveCycles
      { refusalHave :: !Int
      , refusalNeed :: !Int
      , refusalBlocker :: !(Maybe BlockingAttempt)
      }
  | CycleIdentityDiffersFromTarget ![IdentityComponent]
  | CycleEnvironmentDiffers
  | ArtifactMissing !CycleLabel
  | ArtifactDefective !CycleLabel !ArtifactDefect
  | ArtifactDisagreesWithLedger !CycleLabel !Text
  | ArtifactNotSuccessful !CycleLabel
  | LedgerAnchorMissing
  | CutoverMarkInvalid !CutoverMarkKind !Text
  | -- | The epoch the ledger is in counts no cycle.
    EpochDoesNotCount !Text
  | -- | After the legacy route was deleted, the newest cycle ran on a tree whose
    -- local key is not the one the deletion was recorded on.
    PostActivationIdentityMoved !IdentityKey !IdentityKey
  | -- | The cycles ran on an identity the current tree no longer has.
    CurrentIdentityStale ![IdentityComponent]
  | -- | The current identity could not be recomputed here.
    CurrentIdentityUnavailable !IdentityComponent !Text
  | ArtifactDisagreesWithLocalFixture !CycleLabel !Text
  deriving stock (Eq, Show)

-- Appending ---------------------------------------------------------------------------

-- | The attempt number the next run of a label would be, or the refusal that a
-- label which already passed is never run again.
labelDisposition :: CycleLedger -> CycleLabel -> Either LedgerRefusal Int
labelDisposition ledger label
  | any passed (resolveAttempts ledger) = Left (LabelAlreadyPassed label)
  | otherwise =
      Right
        ( 1
            + length
              [() | RecordCycleBegun begun <- map entryRecord (ledgerEntries ledger), begunLabel begun == label]
        )
 where
  passed attempt = resolvedLabel attempt == label && resolvedResolution attempt == AttemptPassed

-- | Append one record. Every rule is checked here and replayed by
-- 'parseCycleLedger', so a hand-written violation is refused when it is read.
appendRecord :: CycleLedger -> LedgerRecord -> Either LedgerRefusal (CycleLedger, LedgerEntry)
appendRecord ledger record = do
  checkLegal ledger record
  body <- renderBody sequenceNumber previous record
  let digest = chainDigest previous body
      entry =
        LedgerEntry
          { entrySequence = sequenceNumber
          , entryPrevious = previous
          , entryRecord = record
          , entryDigest = digest
          , entryLine = body <> "\tdigest=" <> publicEvidenceDigestText digest
          }
      CycleLedger newestFirst = ledger
  Right (CycleLedger (entry : newestFirst), entry)
 where
  sequenceNumber = length (ledgerEntries ledger)
  previous = ledgerTip ledger

chainDigest :: PublicEvidenceDigest -> Text -> PublicEvidenceDigest
chainDigest previous body =
  hashPublicEvidence (publicEvidenceDigestText previous <> "\NUL" <> body)

-- | The rules a record must satisfy against the history it extends.
checkLegal :: CycleLedger -> LedgerRecord -> Either LedgerRefusal ()
checkLegal ledger record = case record of
  RecordCycleBegun begun -> do
    if begunKey begun == identityKeyOfParts (begunParts begun)
      then Right ()
      else Left (LedgerRecordInconsistent "a begun record's key is not the key of its parts")
    if begunAttempt begun >= 1
      then Right ()
      else Left (LedgerRecordOutOfOrder "an attempt number starts at 1")
    expected <- labelDisposition ledger (begunLabel begun)
    if begunAttempt begun == expected
      then Right ()
      else
        Left
          ( LedgerRecordOutOfOrder
              ( "attempt "
                  <> Text.pack (show (begunAttempt begun))
                  <> " of "
                  <> cycleLabelText (begunLabel begun)
                  <> " follows "
                  <> Text.pack (show (expected - 1))
                  <> " earlier attempts"
              )
          )
  RecordCycleClosed closed -> do
    opened <- case openAttempt ledger of
      Just begun -> Right begun
      Nothing -> Left (LedgerRecordOutOfOrder "a closed record needs an open attempt")
    if begunLabel opened == closedLabel closed && begunAttempt opened == closedAttempt closed
      then Right ()
      else Left (LedgerRecordOutOfOrder "a closed record must close the attempt that is open")
    case closedOutcome closed of
      CyclePassed -> do
        if closedEndKey closed == begunKey opened
          then Right ()
          else Left (LedgerRecordInconsistent "a passed attempt ends under the key it began with")
        if isNothing (closedArtifactDigest closed)
          then Left (LedgerRecordInconsistent "a passed attempt records its artifact digest")
          else Right ()
      CycleSourceDrifted ->
        if closedEndKey closed == begunKey opened
          then Left (LedgerRecordInconsistent "a drifted attempt ends under a different key")
          else Right ()
      CycleFailed _ -> Right ()
  RecordCutoverMark mark -> checkMark ledger mark

-- | The rules a cutover mark must satisfy against the history it extends. A
-- mark is evidence that a transition happened, so each is checked here against
-- the attempts that licensed it, and replayed when the ledger is read.
checkMark :: CycleLedger -> MarkRecord -> Either LedgerRefusal ()
checkMark ledger mark = do
  case openAttempt ledger of
    Just _ -> invalid "a mark cannot be recorded while an attempt is open"
    Nothing -> Right ()
  case (markKind mark, epochOfLedger ledger) of
    (MarkActivated, EpochPreActivation) -> licensedByCycles
    (MarkLegacyRouteDeleted, EpochAwaitingDeletion activatedLocal) -> do
      activated <- maybe (invalid "there is no activation to follow") Right (lastMarkOf ledger)
      require
        (markWitnessKey mark == markWitnessKey activated)
        "the deletion names the witness that licensed the activation"
      require
        (markWitnessLabels mark == markWitnessLabels activated)
        "the deletion names the cycles that licensed the activation"
      require
        (markWitnessArtifacts mark == markWitnessArtifacts activated)
        "the deletion names the artifacts that licensed the activation"
      require
        (markLocalKey mark /= activatedLocal)
        "the deletion changed the executable identity of the tree"
    (MarkPostActivationQualified, EpochPostActivation deletedLocal) -> do
      require
        (markLocalKey mark == deletedLocal)
        "the post-activation cycles ran on the tree the deletion was recorded on"
      licensedByCycles
    (kind, epoch) ->
      invalid ("a " <> renderCutoverMarkKind kind <> " mark does not follow " <> renderEpoch epoch)
 where
  invalid detail = Left (CutoverMarkInvalid (markKind mark) detail)
  require condition detail = if condition then Right () else invalid detail

  -- The two newest attempts of the current epoch passed in a row on one key,
  -- and the mark names exactly them.
  licensedByCycles = do
    let (run, _) = qualifyingRun ledger
    counted <-
      if length run >= requiredConsecutiveCycles
        then Right (reverse (take requiredConsecutiveCycles run))
        else invalid "fewer than two consecutive qualifying cycles precede the mark"
    newest <- case reverse counted of
      attempt : _ -> Right attempt
      [] -> invalid "no qualifying cycle precedes the mark"
    require
      (markWitnessKey mark == resolvedBeginKey newest)
      "the mark names the key the cycles qualified on"
    require
      (markLocalKey mark == localKeyOfParts (resolvedBeginParts newest))
      "the mark names the tree the cycles ran on"
    require
      (markWitnessLabels mark == map resolvedLabel counted)
      "the mark names the cycles that qualified"
    require
      (markWitnessArtifacts mark == mapMaybe resolvedArtifactDigest counted)
      "the mark names the artifacts that qualified"

-- | The latest @Begun@, when nothing has closed it.
openAttempt :: CycleLedger -> Maybe BegunRecord
openAttempt (CycleLedger newestFirst) = case newestFirst of
  LedgerEntry {entryRecord = RecordCycleBegun begun} : _ -> Just begun
  _ -> Nothing

-- Epochs ---------------------------------------------------------------------------------

-- | Where the cutover stands, by the last mark. There is no mark before
-- activation. After an activation no cycle counts until the legacy route is
-- deleted, because the tree is mid-edit; after the deletion only cycles on the
-- tree the deletion was recorded on count.
data CutoverEpoch
  = EpochPreActivation
  | EpochAwaitingDeletion !IdentityKey
  | EpochPostActivation !IdentityKey
  | EpochComplete !IdentityKey
  deriving stock (Eq, Show)

renderEpoch :: CutoverEpoch -> Text
renderEpoch epoch = case epoch of
  EpochPreActivation -> "the pre-activation epoch"
  EpochAwaitingDeletion _ -> "an activation awaiting deletion"
  EpochPostActivation _ -> "a deleted legacy route awaiting post-activation qualification"
  EpochComplete _ -> "a completed cutover"

-- | Marks, newest first, with the sequence number of the entry that holds each.
marksNewestFirst :: CycleLedger -> [(Int, MarkRecord)]
marksNewestFirst (CycleLedger newestFirst) =
  [(entrySequence entry, mark) | entry <- newestFirst, RecordCutoverMark mark <- [entryRecord entry]]

lastMarkOf :: CycleLedger -> Maybe MarkRecord
lastMarkOf ledger = snd <$> listToMaybe (marksNewestFirst ledger)

epochOfLedger :: CycleLedger -> CutoverEpoch
epochOfLedger ledger = case lastMarkOf ledger of
  Nothing -> EpochPreActivation
  Just mark -> case markKind mark of
    MarkActivated -> EpochAwaitingDeletion (markLocalKey mark)
    MarkLegacyRouteDeleted -> EpochPostActivation (markLocalKey mark)
    MarkPostActivationQualified -> EpochComplete (markLocalKey mark)

-- | The attempts since the last mark, oldest first. A mark is a boundary: what
-- ran before it was judged for it.
epochAttempts :: CycleLedger -> [ResolvedAttempt]
epochAttempts ledger = filter ((> boundary) . resolvedSequence) (resolveAttempts ledger)
 where
  boundary = case marksNewestFirst ledger of
    (sequenceNumber, _) : _ -> sequenceNumber
    [] -> -1

-- | The phase a ledger replays to. It can be produced only from a ledger, and a
-- ledger can exist only if every mark in it passed 'checkMark', so holding one is
-- holding a phase the evidence supports.
newtype LedgerPhase = LedgerPhase CutoverEpoch
  deriving stock (Eq, Show)

ledgerPhase :: CycleLedger -> LedgerPhase
ledgerPhase = LedgerPhase . epochOfLedger

phaseEpoch :: LedgerPhase -> CutoverEpoch
phaseEpoch (LedgerPhase epoch) = epoch

-- Rendering and parsing -----------------------------------------------------------------

-- | One tab-separated line of @name=value@ fields in a fixed order. Values are
-- restricted to a character set that needs no escaping, so a line is never
-- ambiguous.
renderLedgerEntry :: LedgerEntry -> Text
renderLedgerEntry = entryLine

renderBody :: Int -> PublicEvidenceDigest -> LedgerRecord -> Either LedgerRefusal Text
renderBody sequenceNumber previous record = do
  let fields =
        [ ("seq", Text.pack (show sequenceNumber))
        , ("prev", publicEvidenceDigestText previous)
        ]
          ++ recordFields record
  case [name | (name, value) <- fields, not (validValue value)] of
    name : _ -> Left (LedgerRecordUnrenderable name)
    [] -> Right (Text.intercalate "\t" [name <> "=" <> value | (name, value) <- fields])

recordFields :: LedgerRecord -> [(Text, Text)]
recordFields record = case record of
  RecordCycleBegun begun ->
    let parts = begunParts begun
        policy = partsSourcePolicy parts
        annotations = begunAnnotations begun
     in [ ("type", "begun")
        , ("label", cycleLabelText (begunLabel begun))
        , ("attempt", Text.pack (show (begunAttempt begun)))
        , ("key", identityKeyText (begunKey begun))
        , ("key_policy", partsKeyPolicyDigest parts)
        , ("source_manifest", partsSourceManifestDigest parts)
        , ("source_policy_id", sourcePolicyIdentifier policy)
        , ("source_policy_version", Text.pack (show (sourcePolicyVersion policy)))
        , ("source_policy_digest", sourcePolicyDigest policy)
        , ("source_entries", Text.pack (show (partsSourceEntryCount parts)))
        , ("git", maybe "unkeyed" renderProvenance (partsGitProvenance parts))
        , ("config", digestField (partsGeneratedConfig parts))
        , ("images", Text.intercalate "," (map digestField (partsComponentImages parts)))
        , ("topology_wiring", digestField (partsTopologyWiring parts))
        , ("envelope", digestField (partsResourceEnvelope parts))
        , ("load_fault", digestField (partsLoadFault parts))
        , ("interpreter", digestField (partsInterpreter parts))
        , ("persistence", digestField (partsPersistence parts))
        , ("cleanup_schema", digestField (partsCleanupSchema parts))
        , ("annot_head", annotationGitHead annotations)
        , ("annot_worktree", renderWorktree (annotationWorktree annotations))
        , ("annot_full_manifest", annotationFullManifestDigest annotations)
        , ("annot_full_entries", Text.pack (show (annotationFullEntryCount annotations)))
        , ("annot_binary", fromMaybe "unknown" (annotationBinaryDigest annotations))
        , ("started_at", begunStartedAt begun)
        ]
  RecordCycleClosed closed ->
    [ ("type", "closed")
    , ("label", cycleLabelText (closedLabel closed))
    , ("attempt", Text.pack (show (closedAttempt closed)))
    , ("end_key", identityKeyText (closedEndKey closed))
    , ("outcome", renderCycleOutcome (closedOutcome closed))
    , ("artifact", fromMaybe "none" (closedArtifactDigest closed))
    , ("cleanup_run_id", closedCleanupRunId closed)
    , ("completed_at", closedCompletedAt closed)
    ]
  RecordCutoverMark mark ->
    [ ("type", "mark")
    , ("kind", renderCutoverMarkKind (markKind mark))
    , ("witness_key", identityKeyText (markWitnessKey mark))
    , ("local_key", identityKeyText (markLocalKey mark))
    , ("labels", Text.intercalate "," (map cycleLabelText (markWitnessLabels mark)))
    , ("artifacts", Text.intercalate "," (markWitnessArtifacts mark))
    , ("recorded_at", markRecordedAt mark)
    ]
 where
  digestField = publicEvidenceDigestText

validValue :: Text -> Bool
validValue value = not (Text.null value) && Text.all validCharacter value
 where
  validCharacter character =
    isAlphaNum character && character < '\x80' || character `elem` ("._:/+,-" :: String)

renderCycleOutcome :: CycleOutcome -> Text
renderCycleOutcome outcome = case outcome of
  CyclePassed -> "passed"
  CycleFailed FailedCandidateRefused -> "failed-candidate-refused"
  CycleFailed FailedLifecycleNotSucceeded -> "failed-lifecycle-not-succeeded"
  CycleFailed FailedEvidenceWrite -> "failed-evidence-write"
  CycleFailed FailedSourceRecapture -> "failed-source-recapture"
  CycleSourceDrifted -> "source-drifted"

parseOutcome :: Text -> Maybe CycleOutcome
parseOutcome raw = find ((== raw) . renderCycleOutcome) outcomes
 where
  outcomes =
    [CyclePassed, CycleSourceDrifted] ++ [CycleFailed failure | failure <- [minBound .. maxBound]]

renderWorktree :: WorktreeState -> Text
renderWorktree worktree = case worktree of
  WorktreeClean -> "clean"
  WorktreeDirty -> "dirty"

renderProvenance :: (Text, WorktreeState) -> Text
renderProvenance (gitHead, worktree) = gitHead <> ":" <> renderWorktree worktree

-- | Read a whole ledger, verifying density, the chain, every recomputed digest
-- and every append rule. A malformed or broken ledger is refused and is never
-- repaired in place.
parseCycleLedger :: Text -> Either LedgerRefusal CycleLedger
parseCycleLedger text = go emptyCycleLedger (zip [0 ..] (filter (not . Text.null) (Text.lines text)))
 where
  go ledger [] = Right ledger
  go ledger ((index, line) : rest) = do
    parsed <- parseLine index line
    let (recordedSequence, recordedPrevious, record, recordedDigest, canonicalLine) = parsed
    if recordedSequence == index
      then Right ()
      else Left (LedgerEntryMalformed index "the sequence number is not dense")
    if recordedPrevious == ledgerTip ledger
      then Right ()
      else Left (LedgerChainBroken index)
    (next, entry) <-
      either (Left . relabel index) Right (appendRecord ledger record)
    if entryDigest entry == recordedDigest && canonicalLine == line && entryLine entry == line
      then Right ()
      else Left (LedgerChainBroken index)
    go next rest

  relabel index refusal = case refusal of
    LedgerRecordUnrenderable name -> LedgerEntryMalformed index ("unrenderable field " <> name)
    other -> other

type ParsedLine = (Int, PublicEvidenceDigest, LedgerRecord, PublicEvidenceDigest, Text)

parseLine :: Int -> Text -> Either LedgerRefusal ParsedLine
parseLine index line = do
  let malformed = LedgerEntryMalformed index
      rawFields = Text.splitOn "\t" line
  pairs <- traverse (splitField malformed) rawFields
  let lookupField name = maybe (Left (malformed ("missing " <> name))) Right (lookup name pairs)
      digestField name =
        lookupField name
          >>= maybe (Left (malformed ("not a digest: " <> name))) Right . mkPublicEvidenceDigest
      numberField name = lookupField name >>= maybe (Left (malformed ("not a number: " <> name))) Right . readNumber
  sequenceNumber <- numberField "seq"
  previous <- digestField "prev"
  recordedDigest <- digestField "digest"
  recordType <- lookupField "type"
  record <- case recordType of
    "begun" -> parseBegun malformed lookupField digestField numberField
    "closed" -> parseClosed malformed lookupField numberField
    "mark" -> parseMark malformed lookupField
    other -> Left (malformed ("unknown record type " <> other))
  -- The canonical rendering of what was parsed must be the line that was read,
  -- so a field out of order, repeated or extra cannot hide in a valid prefix.
  body <-
    either
      (const (Left (malformed "the record cannot be rendered")))
      Right
      (renderBody sequenceNumber previous record)
  Right
    ( sequenceNumber
    , previous
    , record
    , recordedDigest
    , body <> "\tdigest=" <> publicEvidenceDigestText recordedDigest
    )

splitField :: (Text -> LedgerRefusal) -> Text -> Either LedgerRefusal (Text, Text)
splitField malformed field = case Text.breakOn "=" field of
  (name, rest)
    | Text.null name || Text.null rest -> Left (malformed "a field has no name or no value")
    | otherwise -> Right (name, Text.drop 1 rest)

parseBegun
  :: (Text -> LedgerRefusal)
  -> (Text -> Either LedgerRefusal Text)
  -> (Text -> Either LedgerRefusal PublicEvidenceDigest)
  -> (Text -> Either LedgerRefusal Int)
  -> Either LedgerRefusal LedgerRecord
parseBegun malformed lookupField digestField numberField = do
  label <- lookupField "label" >>= either (const (Left (malformed "label"))) Right . mkCycleLabel
  attempt <- numberField "attempt"
  key <- lookupField "key" >>= maybe (Left (malformed "key")) Right . mkIdentityKey
  keyPolicy <- lookupField "key_policy"
  sourceManifest <- lookupField "source_manifest"
  policyIdentifier <- lookupField "source_policy_id"
  policyVersion <- numberField "source_policy_version"
  policyDigest <- lookupField "source_policy_digest"
  entries <- numberField "source_entries"
  provenance <- lookupField "git" >>= parseProvenance malformed
  config <- digestField "config"
  images <-
    lookupField "images"
      >>= traverse (maybe (Left (malformed "images")) Right . mkPublicEvidenceDigest) . Text.splitOn ","
  topologyWiring <- digestField "topology_wiring"
  envelope <- digestField "envelope"
  loadFault <- digestField "load_fault"
  interpreter <- digestField "interpreter"
  persistence <- digestField "persistence"
  cleanupSchema <- digestField "cleanup_schema"
  annotHead <- lookupField "annot_head"
  annotWorktree <- lookupField "annot_worktree" >>= parseWorktree malformed
  annotManifest <- lookupField "annot_full_manifest"
  annotEntries <- numberField "annot_full_entries"
  annotBinary <- lookupField "annot_binary"
  startedAt <- lookupField "started_at"
  Right
    ( RecordCycleBegun
        BegunRecord
          { begunLabel = label
          , begunAttempt = attempt
          , begunKey = key
          , begunParts =
              CycleIdentityParts
                { partsKeyPolicyDigest = keyPolicy
                , partsSourceManifestDigest = sourceManifest
                , partsSourcePolicy =
                    SourceManifestPolicyIdentity
                      { sourcePolicyIdentifier = policyIdentifier
                      , sourcePolicyVersion = fromIntegral policyVersion
                      , sourcePolicyDigest = policyDigest
                      }
                , partsSourceEntryCount = entries
                , partsGitProvenance = provenance
                , partsGeneratedConfig = config
                , partsComponentImages = images
                , partsTopologyWiring = topologyWiring
                , partsResourceEnvelope = envelope
                , partsLoadFault = loadFault
                , partsInterpreter = interpreter
                , partsPersistence = persistence
                , partsCleanupSchema = cleanupSchema
                }
          , begunAnnotations =
              CycleAnnotations
                { annotationGitHead = annotHead
                , annotationWorktree = annotWorktree
                , annotationFullManifestDigest = annotManifest
                , annotationFullEntryCount = annotEntries
                , annotationBinaryDigest = if annotBinary == "unknown" then Nothing else Just annotBinary
                }
          , begunStartedAt = startedAt
          }
    )

parseClosed
  :: (Text -> LedgerRefusal)
  -> (Text -> Either LedgerRefusal Text)
  -> (Text -> Either LedgerRefusal Int)
  -> Either LedgerRefusal LedgerRecord
parseClosed malformed lookupField numberField = do
  label <- lookupField "label" >>= either (const (Left (malformed "label"))) Right . mkCycleLabel
  attempt <- numberField "attempt"
  endKey <- lookupField "end_key" >>= maybe (Left (malformed "end_key")) Right . mkIdentityKey
  outcome <- lookupField "outcome" >>= maybe (Left (malformed "outcome")) Right . parseOutcome
  artifact <- lookupField "artifact"
  runId <- lookupField "cleanup_run_id"
  completedAt <- lookupField "completed_at"
  Right
    ( RecordCycleClosed
        ClosedRecord
          { closedLabel = label
          , closedAttempt = attempt
          , closedEndKey = endKey
          , closedOutcome = outcome
          , closedArtifactDigest = if artifact == "none" then Nothing else Just artifact
          , closedCleanupRunId = runId
          , closedCompletedAt = completedAt
          }
    )

parseMark
  :: (Text -> LedgerRefusal)
  -> (Text -> Either LedgerRefusal Text)
  -> Either LedgerRefusal LedgerRecord
parseMark malformed lookupField = do
  kind <- lookupField "kind" >>= maybe (Left (malformed "kind")) Right . parseMarkKind
  witnessKey <-
    lookupField "witness_key" >>= maybe (Left (malformed "witness_key")) Right . mkIdentityKey
  localKey <- lookupField "local_key" >>= maybe (Left (malformed "local_key")) Right . mkIdentityKey
  labels <-
    lookupField "labels"
      >>= traverse (either (const (Left (malformed "labels"))) Right . mkCycleLabel) . Text.splitOn ","
  artifacts <- Text.splitOn "," <$> lookupField "artifacts"
  recordedAt <- lookupField "recorded_at"
  Right
    ( RecordCutoverMark
        MarkRecord
          { markKind = kind
          , markWitnessKey = witnessKey
          , markLocalKey = localKey
          , markWitnessLabels = labels
          , markWitnessArtifacts = artifacts
          , markRecordedAt = recordedAt
          }
    )
 where
  parseMarkKind raw = find ((== raw) . renderCutoverMarkKind) [minBound .. maxBound]

parseProvenance
  :: (Text -> LedgerRefusal) -> Text -> Either LedgerRefusal (Maybe (Text, WorktreeState))
parseProvenance malformed raw
  | raw == "unkeyed" = Right Nothing
  | otherwise = case Text.splitOn ":" raw of
      [gitHead, worktreeRaw] -> do
        worktree <- parseWorktree malformed worktreeRaw
        Right (Just (gitHead, worktree))
      _ -> Left (malformed "git")

parseWorktree :: (Text -> LedgerRefusal) -> Text -> Either LedgerRefusal WorktreeState
parseWorktree malformed raw = case raw of
  "clean" -> Right WorktreeClean
  "dirty" -> Right WorktreeDirty
  _ -> Left (malformed "worktree")

readNumber :: Text -> Maybe Int
readNumber raw = case TextRead.decimal raw of
  Right (value, rest) | Text.null rest && Text.length raw <= 9 && Text.all isDigit raw -> Just value
  _ -> Nothing

-- Attempts -----------------------------------------------------------------------------

data AttemptResolution
  = AttemptPassed
  | AttemptFailed !CycleFailureClass
  | AttemptSourceDrifted
  | -- | No @Closed@ followed its @Begun@ before another @Begun@ or the end of the
    -- ledger. A cycle still running and a cycle that crashed look the same.
    AttemptInterrupted
  deriving stock (Eq, Show)

data ResolvedAttempt = ResolvedAttempt
  { resolvedLabel :: !CycleLabel
  , resolvedAttempt :: !Int
  , resolvedSequence :: !Int
  , resolvedBeginKey :: !IdentityKey
  , resolvedBeginParts :: !CycleIdentityParts
  , resolvedAnnotations :: !CycleAnnotations
  , resolvedResolution :: !AttemptResolution
  , resolvedArtifactDigest :: !(Maybe Text)
  , resolvedCleanupRunId :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Every attempt, oldest first, with what became of it.
resolveAttempts :: CycleLedger -> [ResolvedAttempt]
resolveAttempts ledger = go Nothing (ledgerEntries ledger)
 where
  go open [] = maybe [] (\attempt -> [interrupted attempt]) open
  go open (entry : rest) = case entryRecord entry of
    RecordCycleBegun begun ->
      maybe [] (\attempt -> [interrupted attempt]) open ++ go (Just (entrySequence entry, begun)) rest
    RecordCycleClosed closed -> case open of
      Just (sequenceNumber, begun) -> closedAttemptOf sequenceNumber begun closed : go Nothing rest
      Nothing -> go Nothing rest
    RecordCutoverMark _ -> go open rest

  interrupted (sequenceNumber, begun) =
    attemptFrom sequenceNumber begun AttemptInterrupted Nothing Nothing

  closedAttemptOf sequenceNumber begun closed =
    attemptFrom
      sequenceNumber
      begun
      (resolutionOf (closedOutcome closed))
      (closedArtifactDigest closed)
      (Just (closedCleanupRunId closed))

  attemptFrom sequenceNumber begun resolution artifact runId =
    ResolvedAttempt
      { resolvedLabel = begunLabel begun
      , resolvedAttempt = begunAttempt begun
      , resolvedSequence = sequenceNumber
      , resolvedBeginKey = begunKey begun
      , resolvedBeginParts = begunParts begun
      , resolvedAnnotations = begunAnnotations begun
      , resolvedResolution = resolution
      , resolvedArtifactDigest = artifact
      , resolvedCleanupRunId = runId
      }

  resolutionOf outcome = case outcome of
    CyclePassed -> AttemptPassed
    CycleFailed failure -> AttemptFailed failure
    CycleSourceDrifted -> AttemptSourceDrifted

-- The judge --------------------------------------------------------------------------------

-- | Evidence that the last 'requiredConsecutiveCycles' attempts passed in a row
-- on one identity, and that their artifacts say what the ledger says. The
-- constructor is private and 'judgeConsecutiveCycles' is the only producer.
data ConsecutiveCycleProof = ConsecutiveCycleProof
  { proofKey :: !IdentityKey
  , proofParts :: !CycleIdentityParts
  , proofLabels :: ![CycleLabel]
  , proofAttempts :: ![Int]
  , proofArtifactDigests :: ![Text]
  , proofAwsScope :: !(Text, Text)
  , proofTip :: !PublicEvidenceDigest
  , proofAnnotations :: ![CycleAnnotations]
  }
  deriving stock (Eq, Show)

-- | The run of qualifying attempts that ends at the newest attempt, newest
-- first, and the attempt that stopped it.
--
-- The walk goes from the end of the ledger backwards. The newest attempt must
-- have passed, and every attempt in the run must have passed on the newest
-- attempt's key under a label not yet seen. The first attempt that failed, was
-- interrupted, drifted, ran on another key or repeats a label ends the walk and
-- is the blocker.
qualifyingRun :: CycleLedger -> ([ResolvedAttempt], Maybe ResolvedAttempt)
qualifyingRun ledger = case reverse (epochAttempts ledger) of
  [] -> ([], Nothing)
  newestFirst@(newest : _) -> walk (resolvedBeginKey newest) [] newestFirst
 where
  -- After the legacy route was deleted only cycles on the tree that deletion
  -- was recorded on count.
  onRecordedTree attempt = case epochOfLedger ledger of
    EpochPostActivation local -> localKeyOfParts (resolvedBeginParts attempt) == local
    _ -> True

  walk _ collected [] = (reverse collected, Nothing)
  walk key collected (attempt : earlier)
    | qualifies key collected attempt = walk key (attempt : collected) earlier
    | otherwise = (reverse collected, Just attempt)

  qualifies key collected attempt =
    resolvedResolution attempt == AttemptPassed
      && resolvedBeginKey attempt == key
      && onRecordedTree attempt
      && resolvedLabel attempt `notElem` map resolvedLabel collected

-- | Judge a ledger against the artifacts its counted attempts name.
--
-- The walk goes from the end of the ledger backwards. The newest attempt must
-- have passed, and every attempt in the run must have passed on the newest
-- attempt's key under a label not yet seen. The first attempt that failed, was
-- interrupted, drifted, ran on another key or repeats a label ends the walk and
-- is the named blocker. A failed or interrupted attempt after a pair therefore
-- resets the count, because the newest attempt is what the plan observed last.
judgeConsecutiveCycles
  :: CycleLedger
  -> Map CycleLabel (Either ArtifactDefect ArtifactFact)
  -> Either LedgerRefusal ConsecutiveCycleProof
judgeConsecutiveCycles ledger artifacts = do
  case epochOfLedger ledger of
    EpochAwaitingDeletion _ ->
      Left
        ( EpochDoesNotCount
            "the replacement is activated and the legacy route is not yet deleted, so no cycle counts until the deletion is recorded"
        )
    EpochComplete _ ->
      Left (EpochDoesNotCount "post-activation qualification is recorded and the cutover is complete")
    _ -> Right ()
  trailing <- case reverse (epochAttempts ledger) of
    [] -> Left LedgerEmptyOfCycles
    newest : _ -> Right newest
  case epochOfLedger ledger of
    EpochPostActivation local
      | localKeyOfParts (resolvedBeginParts trailing) /= local ->
          Left (PostActivationIdentityMoved local (localKeyOfParts (resolvedBeginParts trailing)))
    _ -> Right ()
  let (run, blocker) = qualifyingRun ledger
  case blocker of
    Just stopped
      | length run < requiredConsecutiveCycles ->
          Left (insufficient run trailing stopped)
    Nothing
      | length run < requiredConsecutiveCycles ->
          Left (InsufficientConsecutiveCycles (length run) requiredConsecutiveCycles Nothing)
    _ -> Right ()
  -- The attempts that count are the newest 'requiredConsecutiveCycles', oldest first.
  let counted = reverse (take requiredConsecutiveCycles run)
  facts <- traverse verifyAttempt counted
  scopes <- case nub [factScope fact | fact <- facts] of
    [scope] -> Right scope
    _ -> Left CycleEnvironmentDiffers
  Right
    ConsecutiveCycleProof
      { proofKey = resolvedBeginKey trailing
      , proofParts = resolvedBeginParts trailing
      , proofLabels = map resolvedLabel counted
      , proofAttempts = map resolvedAttempt counted
      , proofArtifactDigests = map factEvidenceDigest facts
      , proofAwsScope = scopes
      , proofTip = ledgerTip ledger
      , proofAnnotations = map resolvedAnnotations counted
      }
 where
  factScope fact = (factAwsAccount fact, factAwsRegion fact)

  insufficient run trailing stopped
    | resolvedResolution stopped == AttemptPassed
    , resolvedBeginKey stopped /= resolvedBeginKey trailing =
        CycleIdentityDiffersFromTarget
          (diffParts (resolvedBeginParts stopped) (resolvedBeginParts trailing))
    | otherwise =
        InsufficientConsecutiveCycles
          (length run)
          requiredConsecutiveCycles
          ( Just
              BlockingAttempt
                { blockerLabel = resolvedLabel stopped
                , blockerAttempt = resolvedAttempt stopped
                , blockerResolution = resolvedResolution stopped
                }
          )

  verifyAttempt attempt = do
    let label = resolvedLabel attempt
    fact <- case Map.lookup label artifacts of
      Nothing -> Left (ArtifactMissing label)
      Just (Left defect) -> Left (ArtifactDefective label defect)
      Just (Right found) -> Right found
    let disagrees detail = Left (ArtifactDisagreesWithLedger label detail)
    if factLabel fact == label && factAttempt fact == resolvedAttempt attempt
      then Right ()
      else disagrees "the artifact names another cycle or attempt"
    if Just (factEvidenceDigest fact) == resolvedArtifactDigest attempt
      then Right ()
      else disagrees "the artifact's evidence digest is not the one the ledger recorded"
    case diffParts (factParts fact) (resolvedBeginParts attempt) of
      [] -> Right ()
      components ->
        disagrees
          ( "the artifact's identity differs from the ledger's in "
              <> Text.intercalate ", " (map identityComponentName components)
          )
    if Just (factCleanupRunId fact) == resolvedCleanupRunId attempt
      then Right ()
      else disagrees "the artifact's cleanup run is not the one the ledger recorded"
    if factSucceeded fact then Right () else Left (ArtifactNotSuccessful label)
    Right fact

-- Rendering a refusal -----------------------------------------------------------------------

-- | One line for a human or a receipt, naming the thing that stopped the verdict.
renderLedgerRefusal :: LedgerRefusal -> Text
renderLedgerRefusal refusal = case refusal of
  LedgerEmptyOfCycles -> "the ledger records no cycle"
  LedgerChainBroken index ->
    "the ledger's chain is broken at entry "
      <> Text.pack (show index)
      <> "; it is not repaired in place"
  LedgerEntryMalformed index detail ->
    "ledger entry " <> Text.pack (show index) <> " is malformed: " <> detail
  LedgerRecordUnrenderable name -> "a ledger field cannot be recorded: " <> name
  LedgerRecordInconsistent detail -> "an inconsistent ledger record: " <> detail
  LedgerRecordOutOfOrder detail -> "an out-of-order ledger record: " <> detail
  LabelAlreadyPassed label ->
    "cycle " <> cycleLabelText label <> " has already passed; use a new label for another cycle"
  InsufficientConsecutiveCycles have need blocker ->
    "only "
      <> Text.pack (show have)
      <> " of "
      <> Text.pack (show need)
      <> " consecutive qualifying cycles"
      <> maybe "" renderBlocker blocker
  CycleIdentityDiffersFromTarget components ->
    "the consecutive cycles ran on different deployments; differing: "
      <> Text.intercalate ", " (map identityComponentName components)
  CycleEnvironmentDiffers -> "the consecutive cycles ran in different AWS accounts or regions"
  ArtifactMissing label -> "the artifact for cycle " <> cycleLabelText label <> " is missing"
  ArtifactDefective label defect ->
    "the artifact for cycle " <> cycleLabelText label <> " is defective: " <> Text.pack (show defect)
  ArtifactDisagreesWithLedger label detail ->
    "the artifact for cycle " <> cycleLabelText label <> " disagrees with the ledger: " <> detail
  ArtifactNotSuccessful label ->
    "the artifact for cycle " <> cycleLabelText label <> " records an unsuccessful cascade"
  LedgerAnchorMissing -> "the anchor digest is not an entry of the verified ledger"
  CutoverMarkInvalid kind detail ->
    "the " <> renderCutoverMarkKind kind <> " mark is refused: " <> detail
  EpochDoesNotCount detail -> detail
  PostActivationIdentityMoved _ _ ->
    "the newest cycle ran on a tree that is not the one the legacy-route deletion was recorded on"
  CurrentIdentityStale components ->
    "the current tree is no longer the deployment the cycles ran on; changed: "
      <> Text.intercalate ", " (map identityComponentName components)
  CurrentIdentityUnavailable component detail ->
    "the current "
      <> identityComponentName component
      <> " could not be recomputed here: "
      <> detail
  ArtifactDisagreesWithLocalFixture label detail ->
    "the artifact for cycle "
      <> cycleLabelText label
      <> " disagrees with the fixture this tree recomputes: "
      <> detail
 where
  renderBlocker blocker =
    "; stopped by "
      <> cycleLabelText (blockerLabel blocker)
      <> "#"
      <> Text.pack (show (blockerAttempt blocker))
      <> " ("
      <> renderResolution (blockerResolution blocker)
      <> ")"

renderResolution :: AttemptResolution -> Text
renderResolution resolution = case resolution of
  AttemptPassed -> "passed"
  AttemptFailed failure -> renderCycleOutcome (CycleFailed failure)
  AttemptSourceDrifted -> "source-drifted"
  AttemptInterrupted -> "interrupted"
