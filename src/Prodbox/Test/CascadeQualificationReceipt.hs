{-# LANGUAGE OverloadedStrings #-}

-- | The verdict on the cycle ledger, and the only writer of its cutover marks.
--
-- The observer reads the ledger, attests the artifacts its counted attempts
-- name, judges whether the last two attempts passed in a row on one identity,
-- and then asks the question the judge cannot: is the tree that exists now the
-- deployment those cycles certified. Its report is a block of @NAME=value@
-- lines for a human and for the plan, and it exits zero only for a qualifying
-- verdict.
--
-- What is recomputed here and what is only compared is printed in every
-- report. The cluster is gone after a cascade, so the images that ran and the
-- shape of the program that ran cannot be recomputed; they are carried from the
-- artifacts and compared with the ledger. The ledger and the artifacts are
-- self-digested and not authenticated, which the report does not claim
-- otherwise.
--
-- Observing writes nothing. Recording a cutover step is a separate request, and
-- it re-runs the whole observation first: an activation, a deletion or a
-- post-activation qualification is appended as a mark only when the evidence
-- that licenses it holds at that moment, and only against an anchor the
-- operator copied from the plan.
module Prodbox.Test.CascadeQualificationReceipt
  ( ReceiptReport (..)
  , ReceiptFacts (..)
  , emptyReceiptFacts
  , renderReceiptReport
  , dryRunStageLines
  , cascadeQualificationAnchorVariable
  , cutoverRecordVariable
  , runCascadeQualificationReceipt
  , ledgerScanMode
  , ledgerSummaryLines
  )
where

import Data.Bifunctor (bimap, first)
import Data.ByteString qualified as ByteString
import Data.List (isPrefixOf, isSuffixOf, nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Prodbox.Test.CascadeQualification (frozenFactLines)
import Prodbox.Test.CascadeQualificationLocal
  ( LocalRecomputeError (..)
  , executableBinaryDigest
  , recomputeLocalParts
  )
import Prodbox.Test.CleanRoomHandoff
  ( LegacyScanMode (LegacyScanPostActivation)
  , QualificationPassed
  , activateReplacement
  , admitCutoverStage
  , canonicalCutoverPlan
  , cutoverPhaseOfLedger
  , cutoverStageRequiresWitness
  , cutoverStatePhase
  , initialCutoverState
  , legacyCutoverResidueViolations
  , legacyScanModeForPhase
  , qualifyReplacement
  , qualifyResumedPostActivation
  , resumeCutoverState
  )
import Prodbox.Test.CleanRoomScan (productionSources)
import Prodbox.Test.Qualification.CascadeCycleArtifact
  ( ArtifactDefect (..)
  , ArtifactFact (..)
  , CycleLabel
  , attestCascadeArtifact
  , cascadeArtifactFileName
  , cycleLabelText
  )
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( CompareOnlyParts (..)
  , CycleAnnotations (..)
  , CycleIdentityParts (..)
  , IdentityComponent (ComponentLoadFault, ComponentSource)
  , RecomputedLocalParts (..)
  , annotationsOf
  , assembleCurrentIdentity
  , canonicalKeyPolicy
  , diffParts
  , identityKeyText
  , localKeyOfLocal
  , localKeyOfParts
  , partsFromLocal
  )
import Prodbox.Test.Qualification.CascadeCycleLedger
  ( AttemptResolution (..)
  , ConsecutiveCycleProof
  , CutoverEpoch (..)
  , CutoverMarkKind (..)
  , CycleLedger
  , LedgerRecord (RecordCutoverMark)
  , LedgerRefusal (..)
  , MarkRecord (..)
  , ResolvedAttempt (..)
  , epochOfLedger
  , judgeConsecutiveCycles
  , lastMarkOf
  , ledgerContainsDigest
  , ledgerEntries
  , ledgerPhase
  , ledgerTip
  , proofAnnotations
  , proofArtifactDigests
  , proofKey
  , proofLabels
  , proofParts
  , qualifyingRun
  , renderCutoverMarkKind
  , renderLedgerRefusal
  , requiredConsecutiveCycles
  , resolveAttempts
  )
import Prodbox.Test.Qualification.CascadeCycleLedgerStore
  ( appendCycleRecord
  , cycleLedgerPath
  , readCycleLedger
  , renderLedgerStoreError
  )
import Prodbox.Test.Qualification.Evidence
  ( QualificationIdentity
  , mkPublicEvidenceDigest
  , publicEvidenceDigestText
  )
import Prodbox.Test.Qualification.SourceIdentity (WorktreeState (..))
import Prodbox.Test.Qualification.TeardownCounterexample
  ( TeardownTraceFixture (CanonicalTeardownTrace)
  , canonicalTeardownRecoveryInterpreter
  , loadTeardownCounterexampleFixture
  , runTeardownRecoveryOracle
  )
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError, tryIOError)

-- | A report is the lines to show and whether the verdict is a qualifying one.
data ReceiptReport = ReceiptReport
  { receiptLines :: ![Text]
  , receiptQualified :: !Bool
  }

-- | What an observation that qualifies yields: the proof, the identity the
-- current tree has, and the witness for it. The constructor is not exported, so
-- the only way to hold one is to have passed every check 'judgeAgainstTree' makes.
data ObservedQualification = ObservedQualification
  { observedProof :: !ConsecutiveCycleProof
  , observedIdentity :: !QualificationIdentity
  , observedPassed :: !QualificationPassed
  }

-- | The ledger entry digest a report should be anchored to. It must name an
-- entry of the verified chain; the operator copies it from a cycle's result
-- into the plan, so a ledger rewritten from scratch cannot silently replace
-- the one the plan recorded.
cascadeQualificationAnchorVariable :: String
cascadeQualificationAnchorVariable = "PRODBOX_TEST_CASCADE_QUALIFICATION_ANCHOR"

-- | Which cutover step to record, when the request is to record one.
cutoverRecordVariable :: String
cutoverRecordVariable = "PRODBOX_TEST_CUTOVER_RECORD"

-- Observing --------------------------------------------------------------------------------

-- | Everything one observation reads, so a report and a recording work from the
-- same facts.
data Observation = Observation
  { obsLedger :: !CycleLedger
  , obsLocal :: !(Either LocalRecomputeError RecomputedLocalParts)
  , obsVerdict :: !(Either LedgerRefusal ObservedQualification)
  , obsFacts :: !ReceiptFacts
  }

-- | Observe the repository's cycle ledger and report; with a cutover step
-- requested, record it first and report what happened.
runCascadeQualificationReceipt :: FilePath -> [(String, String)] -> IO ReceiptReport
runCascadeQualificationReceipt repoRoot environment =
  case lookup cutoverRecordVariable environment of
    Nothing -> reportOnly
    Just raw -> case parseRecordKind raw of
      Nothing ->
        refused
          ( "PRODBOX_TEST_CUTOVER_RECORD must be activated, legacy-route-deleted or post-activation-qualified, not `"
              <> Text.pack raw
              <> "`"
          )
      Just kind -> do
        recorded <- recordCutover repoRoot environment kind
        after <- reportOnly
        pure
          after
            { receiptLines = receiptLines after ++ [recordLine recorded]
            , receiptQualified = receiptQualified after && either (const False) (const True) recorded
            }
 where
  reportOnly = do
    observation <- observe repoRoot environment
    pure $ case observation of
      Left err -> renderReceiptReport (Left err) emptyReceiptFacts
      Right observed ->
        renderReceiptReport
          (first renderLedgerRefusal (observedProof <$> obsVerdict observed))
          (obsFacts observed)
  refused reason = pure (renderReceiptReport (Left reason) emptyReceiptFacts)
  recordLine recorded = case recorded of
    Right line -> "RECORDED=" <> line
    Left reason -> "RECORD_REFUSED=" <> reason

parseRecordKind :: String -> Maybe CutoverMarkKind
parseRecordKind raw =
  case [kind | kind <- [minBound .. maxBound], Text.unpack (renderCutoverMarkKind kind) == raw] of
    kind : _ -> Just kind
    [] -> Nothing

observe :: FilePath -> [(String, String)] -> IO (Either Text Observation)
observe repoRoot environment = do
  ledgerResult <- readCycleLedger (cycleLedgerPath repoRoot)
  case ledgerResult of
    Left err -> pure (Left (Text.pack (renderLedgerStoreError err)))
    Right ledger -> do
      artifacts <- loadArtifacts repoRoot ledger
      localResult <- recomputeLocalParts repoRoot
      binaryNow <- executableBinaryDigest
      unledgered <- countUnledgered repoRoot ledger
      verdict <- judgeAgainstTree repoRoot ledger artifacts (anchorProblem ledger) localResult
      let counted = case verdict of
            Right observed -> proofAnnotations (observedProof observed)
            Left _ -> []
          localView = either (const Nothing) Just localResult
          facts =
            ReceiptFacts
              { factsEpoch = renderEpochName (epochOfLedger ledger)
              , factsConsecutive = length (fst (qualifyingRun ledger))
              , factsEntries = length (ledgerEntries ledger)
              , factsTip = publicEvidenceDigestText (ledgerTip ledger)
              , factsAnchor = anchorStatus ledger
              , factsHeadNow = fmap (annotationGitHead . headNowOf) localView
              , factsWorktreeNow = fmap (worktreeText . annotationWorktree . headNowOf) localView
              , factsDocumentationDrift = documentationDrift counted localView
              , factsBinary = binaryComparison counted binaryNow
              , factsUnledgered = unledgered
              , factsDryRun =
                  dryRunStageLines
                    (either (const Nothing) (Just . (\o -> (observedIdentity o, observedPassed o))) verdict)
              , factsNextStep = nextStep (epochOfLedger ledger)
              }
      pure
        ( Right
            Observation
              { obsLedger = ledger
              , obsLocal = localResult
              , obsVerdict = verdict
              , obsFacts = facts
              }
        )
 where
  requestedAnchor = Text.pack <$> lookup cascadeQualificationAnchorVariable environment
  anchorProblem ledger = case requestedAnchor of
    Nothing -> Nothing
    Just raw -> case mkPublicEvidenceDigest raw >>= ledgerContainsDigest ledger of
      Just _ -> Nothing
      Nothing -> Just LedgerAnchorMissing
  anchorStatus ledger = case requestedAnchor of
    Nothing -> "absent"
    Just raw -> case mkPublicEvidenceDigest raw >>= ledgerContainsDigest ledger of
      Just sequenceNumber -> "present@" <> Text.pack (show sequenceNumber)
      Nothing -> "MISSING"
  headNowOf local = annotationsOf (localFullSource local) Nothing

renderEpochName :: CutoverEpoch -> Text
renderEpochName epoch = case epoch of
  EpochPreActivation -> "pre"
  EpochAwaitingDeletion _ -> "awaiting-deletion"
  EpochPostActivation _ -> "post"
  EpochComplete _ -> "complete"

-- | What the operator does next, when the ledger is past qualification.
nextStep :: CutoverEpoch -> Text
nextStep epoch = case epoch of
  EpochPreActivation ->
    "run cycles until QUALIFIED, copy LEDGER_TIP into the plan, then record `activated`"
  EpochAwaitingDeletion _ ->
    "land the legacy-route deletion, then record `legacy-route-deleted`"
  EpochPostActivation _ ->
    "run two post-activation cycles on this tree until QUALIFIED, then record `post-activation-qualified`"
  EpochComplete _ -> "none: the cutover is complete"

-- Judging ------------------------------------------------------------------------------

-- | The judge's verdict, then the three questions only a process with the tree
-- can ask: is the anchor in the chain, is the tree still the deployment the
-- cycles certified, and do the artifacts' fixture facts match this tree's.
judgeAgainstTree
  :: FilePath
  -> CycleLedger
  -> Map CycleLabel (Either ArtifactDefect ArtifactFact)
  -> Maybe LedgerRefusal
  -> Either LocalRecomputeError RecomputedLocalParts
  -> IO (Either LedgerRefusal ObservedQualification)
judgeAgainstTree repoRoot ledger artifacts anchorProblem localResult =
  case anchorProblem of
    Just refusal -> pure (Left refusal)
    Nothing -> case judgeConsecutiveCycles ledger artifacts of
      Left refusal -> pure (Left refusal)
      Right proof -> case localResult of
        Left (LocalRecomputeUnavailable component detail) ->
          pure (Left (CurrentIdentityUnavailable component detail))
        Right local -> case staleness proof local of
          [] -> do
            agreement <- fixtureAgreement repoRoot artifacts proof
            pure (agreement >>= const (witness proof local))
          components -> pure (Left (CurrentIdentityStale components))
 where
  compared proof =
    CompareOnlyParts
      { compareImages = partsComponentImages (proofParts proof)
      , compareTopologyWiring = partsTopologyWiring (proofParts proof)
      }

  staleness proof local =
    diffParts
      (proofParts proof)
      (partsFromLocal canonicalKeyPolicy local (compared proof))

  -- The witness is minted for the identity the current tree has. The proof's
  -- key equals that identity's key once the staleness check passes, so this
  -- cannot refuse; it is the single place a witness is made.
  witness proof local =
    let identity = assembleCurrentIdentity canonicalKeyPolicy local (compared proof)
     in case qualifyReplacement identity proof of
          Left refusal ->
            Left (CurrentIdentityUnavailable ComponentSource (Text.pack (show refusal)))
          Right passed ->
            Right
              ObservedQualification
                { observedProof = proof
                , observedIdentity = identity
                , observedPassed = passed
                }

-- | Rebuild the superseded-side and counterexample facts from this tree's
-- fixture and a local run of the teardown oracle, and require byte equality
-- with what each counted artifact recorded.
fixtureAgreement
  :: FilePath
  -> Map CycleLabel (Either ArtifactDefect ArtifactFact)
  -> ConsecutiveCycleProof
  -> IO (Either LedgerRefusal ())
fixtureAgreement repoRoot artifacts proof = do
  fixtureResult <- loadTeardownCounterexampleFixture repoRoot CanonicalTeardownTrace
  case fixtureResult of
    Left err ->
      pure (Left (CurrentIdentityUnavailable ComponentLoadFault (Text.pack (show err))))
    Right fixture -> do
      oracleResult <-
        runTeardownRecoveryOracle fixture (canonicalTeardownRecoveryInterpreter fixture)
      pure $ case oracleResult of
        Left err ->
          Left (CurrentIdentityUnavailable ComponentLoadFault (Text.pack (show err)))
        Right oracle -> firstDisagreement (frozenFactLines fixture oracle)
 where
  firstDisagreement expected =
    case [ ArtifactDisagreesWithLocalFixture label "the recorded fixture facts differ from this tree's"
         | label <- proofLabels proof
         , Just (Right fact) <- [Map.lookup label artifacts]
         , take (length expected) (factFrozenLines fact) /= expected
         ] of
      refusal : _ -> Left refusal
      [] -> Right ()

-- Recording ---------------------------------------------------------------------------------

-- | Record one cutover step, or say why it cannot be recorded.
--
-- Every step re-runs the observation; requires the anchor, so a ledger rewritten
-- from scratch cannot carry a mark the plan did not expect; checks the
-- precondition that step has beyond the ledger's own rules; and, where the typed
-- cutover machine can be driven with real identities, drives it, so a mark never
-- records a transition the types refused. The deletion cannot be driven that
-- way, because after the activating edit the pre-activation identity cannot be
-- recomputed; it is recorded by its keys, which the ledger replays.
recordCutover
  :: FilePath -> [(String, String)] -> CutoverMarkKind -> IO (Either Text Text)
recordCutover repoRoot environment kind = do
  observation <- observe repoRoot environment
  case observation of
    Left reason -> pure (Left reason)
    Right observed -> case anchorFailure observed of
      Just reason -> pure (Left reason)
      Nothing -> do
        markResult <- buildMark observed
        case markResult of
          Left reason -> pure (Left reason)
          Right mark -> do
            appended <- appendCycleRecord (cycleLedgerPath repoRoot) (RecordCutoverMark mark)
            pure $ case appended of
              Left err -> Left (Text.pack (renderLedgerStoreError err))
              Right _ -> Right (renderCutoverMarkKind kind)
 where
  anchorFailure observed = case lookup cascadeQualificationAnchorVariable environment of
    Nothing ->
      Just
        ( "recording a cutover step requires "
            <> Text.pack cascadeQualificationAnchorVariable
            <> " to name a ledger entry digest recorded in the plan"
        )
    Just raw
      | isNothing (mkPublicEvidenceDigest (Text.pack raw) >>= ledgerContainsDigest (obsLedger observed)) ->
          Just "the anchor digest is not an entry of the verified ledger"
      | otherwise -> Nothing

  buildMark observed = do
    recordedAt <- Text.pack . iso8601Show <$> getCurrentTime
    case kind of
      MarkActivated -> pure (activation observed recordedAt)
      MarkLegacyRouteDeleted -> deletion observed recordedAt
      MarkPostActivationQualified -> pure (qualification observed recordedAt)

  fromProof observed recordedAt =
    case obsVerdict observed of
      Left refusal -> Left (renderLedgerRefusal refusal)
      Right qualified ->
        let proof = observedProof qualified
         in Right
              ( qualified
              , MarkRecord
                  { markKind = kind
                  , markWitnessKey = proofKey proof
                  , markLocalKey = localKeyOfParts (proofParts proof)
                  , markWitnessLabels = proofLabels proof
                  , markWitnessArtifacts = proofArtifactDigests proof
                  , markRecordedAt = recordedAt
                  }
              )

  activation observed recordedAt = do
    (qualified, mark) <- fromProof observed recordedAt
    case activateReplacement (observedPassed qualified) (initialCutoverState (observedIdentity qualified)) of
      Left refusal -> Left ("the typed cutover machine refused the activation: " <> Text.pack (show refusal))
      Right _ -> Right mark

  qualification observed recordedAt = do
    (qualified, mark) <- fromProof observed recordedAt
    case resumeCutoverState (ledgerPhase (obsLedger observed)) (observedIdentity qualified) of
      Left refusal -> Left ("the ledger's phase does not resume on this tree: " <> Text.pack (show refusal))
      Right resumed -> case qualifyResumedPostActivation (observedPassed qualified) resumed of
        Left refusal -> Left ("the typed cutover machine refused the qualification: " <> Text.pack (show refusal))
        Right _ -> Right mark

  deletion observed recordedAt =
    case (epochOfLedger (obsLedger observed), lastMarkOf (obsLedger observed), obsLocal observed) of
      (EpochAwaitingDeletion activatedLocal, Just activated, Right local) -> do
        let currentLocal = localKeyOfLocal canonicalKeyPolicy local
        residue <- legacyRouteResidue repoRoot
        pure
          ( if currentLocal == activatedLocal
              then Left "the tree is still the one the activation was recorded on; land the deletion first"
              else case residue of
                [] ->
                  Right
                    MarkRecord
                      { markKind = MarkLegacyRouteDeleted
                      , markWitnessKey = markWitnessKey activated
                      , markLocalKey = currentLocal
                      , markWitnessLabels = markWitnessLabels activated
                      , markWitnessArtifacts = markWitnessArtifacts activated
                      , markRecordedAt = recordedAt
                      }
                first' : _ -> Left ("the legacy route still has registered sites: " <> Text.pack (show first'))
          )
      (EpochAwaitingDeletion _, _, Left (LocalRecomputeUnavailable component detail)) ->
        pure
          (Left ("the current tree could not be recomputed (" <> Text.pack (show component) <> "): " <> detail))
      (epoch, _, _) ->
        pure (Left ("a legacy-route-deletion cannot follow " <> renderEpochName epoch))

-- | The registered legacy sites that remain after activation. The deletion is
-- recorded only when there are none.
legacyRouteResidue :: FilePath -> IO [Text]
legacyRouteResidue repoRoot = do
  (_, sources) <- productionSources repoRoot
  pure (map (Text.pack . show) (legacyCutoverResidueViolations LegacyScanPostActivation sources))

-- The ledger, for the clean-room validation -------------------------------------------------

-- | The legacy scan mode the ledger's phase selects. No ledger is the
-- pre-activation phase, which is what the validation has always scanned for. A
-- ledger that cannot be read is an error, never a default.
ledgerScanMode :: FilePath -> IO (Either String LegacyScanMode)
ledgerScanMode repoRoot = do
  ledgerResult <- readCycleLedger (cycleLedgerPath repoRoot)
  pure
    ( bimap
        renderLedgerStoreError
        (legacyScanModeForPhase . cutoverPhaseOfLedger . ledgerPhase)
        ledgerResult
    )

-- | Informational lines about the ledger for the clean-room validation: the
-- epoch and the length of the run. An insufficient run is not a failure there.
ledgerSummaryLines :: FilePath -> IO [String]
ledgerSummaryLines repoRoot = do
  ledgerResult <- readCycleLedger (cycleLedgerPath repoRoot)
  pure $ case ledgerResult of
    Left err -> ["QUALIFICATION_LEDGER=unreadable: " ++ renderLedgerStoreError err]
    Right ledger ->
      [ "QUALIFICATION_LEDGER"
      , "EPOCH=" ++ Text.unpack (renderEpochName (epochOfLedger ledger))
      , "LEDGER_ENTRIES=" ++ show (length (ledgerEntries ledger))
      , "CONSECUTIVE="
          ++ show (length (fst (qualifyingRun ledger)))
          ++ " of "
          ++ show requiredConsecutiveCycles
      ]

-- Reading --------------------------------------------------------------------------------

-- | Attest the artifact of every label with a passed attempt. A missing file is
-- left out of the map, which the judge reports as a missing artifact.
loadArtifacts
  :: FilePath
  -> CycleLedger
  -> IO (Map CycleLabel (Either ArtifactDefect ArtifactFact))
loadArtifacts repoRoot ledger = do
  loaded <- traverse load (nub passedLabels)
  pure (Map.fromList [(label, attested) | (label, Just attested) <- loaded])
 where
  passedLabels =
    [ resolvedLabel attempt
    | attempt <- resolveAttempts ledger
    , resolvedResolution attempt == AttemptPassed
    ]
  load label = do
    bytes <-
      tryIOError (ByteString.readFile (qualificationDirectory repoRoot </> cascadeArtifactFileName label))
    pure $ case bytes of
      Left err
        | isDoesNotExistError err -> (label, Nothing)
        | otherwise -> (label, Just (Left artifactUnreadable))
      Right raw -> case TextEncoding.decodeUtf8' raw of
        Left _ -> (label, Just (Left artifactUnreadable))
        Right text -> (label, Just (attestCascadeArtifact text))
  artifactUnreadable = ArtifactLineMalformed "the artifact file could not be read as text"

-- | Artifact files nothing in the ledger names. They are never read for
-- qualification; they are counted so that stray evidence is visible.
countUnledgered :: FilePath -> CycleLedger -> IO Int
countUnledgered repoRoot ledger = do
  listed <- tryIOError (listDirectory (qualificationDirectory repoRoot))
  pure $ case listed of
    Left _ -> 0
    Right names -> length [name | name <- names, isArtifactName name, name `notElem` expected]
 where
  isArtifactName name = "cascade-" `isPrefixOf` name && ".evidence" `isSuffixOf` name
  expected = nub [cascadeArtifactFileName (resolvedLabel attempt) | attempt <- resolveAttempts ledger]

qualificationDirectory :: FilePath -> FilePath
qualificationDirectory repoRoot = repoRoot </> ".test-data" </> "qualification"

-- Rendering --------------------------------------------------------------------------------

data ReceiptFacts = ReceiptFacts
  { factsEpoch :: !Text
  , factsConsecutive :: !Int
  , factsEntries :: !Int
  , factsTip :: !Text
  , factsAnchor :: !Text
  , factsHeadNow :: !(Maybe Text)
  , factsWorktreeNow :: !(Maybe Text)
  , factsDocumentationDrift :: !Text
  , factsBinary :: !Text
  , factsUnledgered :: !Int
  , factsDryRun :: ![Text]
  -- ^ The cutover transitions run in memory against the witness, if there is one.
  , factsNextStep :: !Text
  }

emptyReceiptFacts :: ReceiptFacts
emptyReceiptFacts =
  ReceiptFacts
    { factsEpoch = "unknown"
    , factsConsecutive = 0
    , factsEntries = 0
    , factsTip = "unavailable"
    , factsAnchor = "absent"
    , factsHeadNow = Nothing
    , factsWorktreeNow = Nothing
    , factsDocumentationDrift = "unknown"
    , factsBinary = "unknown"
    , factsUnledgered = 0
    , factsDryRun = dryRunStageLines Nothing
    , factsNextStep = "none"
    }

renderReceiptReport :: Either Text ConsecutiveCycleProof -> ReceiptFacts -> ReceiptReport
renderReceiptReport verdict facts =
  ReceiptReport
    { receiptLines =
        [ "CASCADE_QUALIFICATION_RECEIPT"
        , "EPOCH=" <> factsEpoch facts
        , "REQUIRED=" <> Text.pack (show requiredConsecutiveCycles)
        , "CONSECUTIVE=" <> Text.pack (show (factsConsecutive facts))
        , "VERDICT=" <> either ("REFUSED:" <>) (const "QUALIFIED") verdict
        , "IDENTITY_KEY=" <> either (const "none") (identityKeyText . proofKey) verdict
        , "LABELS=" <> listOrNone (either (const []) (map cycleLabelText . proofLabels) verdict)
        , "LEDGER_ENTRIES=" <> Text.pack (show (factsEntries facts))
        , "LEDGER_TIP=" <> factsTip facts
        , "ANCHOR=" <> factsAnchor facts
        , "GIT_HEAD_AT_CYCLES="
            <> listOrNone (either (const []) (nub . map annotationGitHead . proofAnnotations) verdict)
        , "GIT_HEAD_NOW=" <> fromMaybe "unavailable" (factsHeadNow facts)
        , "WORKTREE_NOW=" <> fromMaybe "unavailable" (factsWorktreeNow facts)
        , "DOC_DRIFT=" <> factsDocumentationDrift facts
        , "BINARY=" <> factsBinary facts
        , "RECOMPUTED=executable-source,generated-config,resource-envelope,load-fault,interpreter,persistence,cleanup-schema,frozen-facts"
        , "COMPARE_ONLY=component-images,topology-wiring-shape,aws-scope"
        , "UNLEDGERED_ARTIFACTS=" <> Text.pack (show (factsUnledgered facts))
        ]
          ++ factsDryRun facts
          ++ ["NEXT_STEP=" <> factsNextStep facts]
    , receiptQualified = either (const False) (const True) verdict
    }
 where
  listOrNone values = if null values then "none" else Text.intercalate "," values

-- | The cutover transitions, run in memory against the witness. Nothing is
-- activated: this shows what the typed machine would admit, so a report cannot
-- say QUALIFIED while the machine would refuse. With no witness the two stages
-- that require one are refused as such, without consulting an identity.
dryRunStageLines :: Maybe (QualificationIdentity, QualificationPassed) -> [Text]
dryRunStageLines observed = phaseLine ++ map stageLine canonicalCutoverPlan
 where
  phaseLine = case observed of
    Nothing -> ["SIMULATED_PHASE=none"]
    Just (identity, passed) -> case activateReplacement passed (initialCutoverState identity) of
      Left refusal -> ["SIMULATED_PHASE=refused:" <> render refusal]
      Right active -> ["SIMULATED_PHASE=" <> render (cutoverStatePhase active)]
  stageLine stage = "STAGE=" <> render stage <> " ADMISSION=" <> admission stage
  admission stage = case observed of
    Nothing
      | cutoverStageRequiresWitness stage -> "refused:witness-missing"
      | otherwise -> "admitted"
    Just (identity, passed) ->
      either
        (("refused:" <>) . render)
        (const "admitted")
        (admitCutoverStage identity (Just passed) stage)
  render :: (Show value) => value -> Text
  render = Text.pack . show

worktreeText :: WorktreeState -> Text
worktreeText worktree = case worktree of
  WorktreeClean -> "clean"
  WorktreeDirty -> "dirty"

-- | Whether governed documentation has moved since the counted cycles. It never
-- resets a count and is never hidden.
documentationDrift :: [CycleAnnotations] -> Maybe RecomputedLocalParts -> Text
documentationDrift counted localView = case (counted, localView) of
  (recorded : _, Just local)
    | annotationFullManifestDigest recorded
        == annotationFullManifestDigest (annotationsOf (localFullSource local) Nothing) ->
        "none"
    | otherwise -> "moved"
  _ -> "unknown"

binaryComparison :: [CycleAnnotations] -> Maybe Text -> Text
binaryComparison counted binaryNow = case (counted, binaryNow) of
  (recorded : _, Just now) -> case annotationBinaryDigest recorded of
    Just then' | then' == now -> "same"
    Just _ -> "different"
    Nothing -> "unknown"
  _ -> "unknown"
