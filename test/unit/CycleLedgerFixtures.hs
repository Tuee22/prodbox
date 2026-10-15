{-# LANGUAGE OverloadedStrings #-}

-- | Scripted cycle histories for the ledger, driver and receipt suites: an
-- ordered list of attempts, each on one of two deployments, and the ledger and
-- artifacts such a history would leave behind.
module CycleLedgerFixtures
  ( Step (..)
  , Variant (..)
  , partsOfVariant
  , labelOf
  , ledgerOf
  , verdictOf
  , appendAll
  , beginRecord
  , beganFor
  , closeRecord
  , closedFor
  , inventoryFor
  , proofForIdentity
  , markFor
  , deletionMarkFor
  , extendLedger
  )
where

import CycleIdentityFixtures
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.Qualification.CascadeCycleArtifact
import Prodbox.Test.Qualification.CascadeCycleIdentity
import Prodbox.Test.Qualification.CascadeCycleLedger
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , QualificationIdentity
  , publicEvidenceDigestText
  )

-- A scripted history ----------------------------------------------------------------

-- | What became of one attempt, on which identity.
data Step
  = Pass Text Variant
  | Fail Text Variant
  | Interrupt Text Variant
  | Drift Text Variant
  | -- | Record the activation, citing the labels of the qualifying pair.
    Activate [Text] Variant
  | -- | Record the deletion, on the tree of this variant.
    DeleteRoute Variant
  | -- | Record the post-activation qualification, citing the labels of the pair.
    QualifyPost [Text] Variant

-- | Two deployments, so a history can mix them.
data Variant
  = DeploymentA
  | DeploymentB
  | -- | The tree after the legacy route was deleted: another executable source,
    -- and other images, because the images are rebuilt from it.
    DeploymentAfterDeletion
  | -- | A tree that moved again after the deletion was recorded.
    DeploymentMovedAgain
  | DeploymentParts CycleIdentityParts

partsOfVariant :: Variant -> CycleIdentityParts
partsOfVariant variant = case variant of
  DeploymentA -> fixtureParts
  DeploymentB -> fixtureParts {partsGeneratedConfig = digestOf 'Z'}
  DeploymentAfterDeletion ->
    fixtureParts
      { partsSourceManifestDigest = Text.replicate 64 "d"
      , partsComponentImages = [imageDigestOf 'c']
      }
  DeploymentMovedAgain ->
    fixtureParts
      { partsSourceManifestDigest = Text.replicate 64 "e"
      , partsComponentImages = [imageDigestOf 'c']
      }
  DeploymentParts parts -> parts

labelOf :: Text -> CycleLabel
labelOf raw = either (error . show) id (mkCycleLabel raw)

-- | The artifact a passing attempt would have written.
artifactFor :: Text -> Variant -> Int -> (Text, Text)
artifactFor label variant attempt =
  case renderCascadeArtifact
    (sameCycleUnderLabel label fixtureArtifactFields)
      { fieldsParts = partsOfVariant variant
      , fieldsAttempt = attempt
      , fieldsComponentImages = inventoryFor (partsComponentImages (partsOfVariant variant))
      } of
    Right pair -> pair
    Left err -> error (show err)

beginRecord :: Text -> Variant -> Int -> LedgerRecord
beginRecord label variant attempt = RecordCycleBegun (beganFor label variant attempt)

beganFor :: Text -> Variant -> Int -> BegunRecord
beganFor label variant attempt =
  BegunRecord
    { begunLabel = labelOf label
    , begunAttempt = attempt
    , begunKey = identityKeyOfParts (partsOfVariant variant)
    , begunParts = partsOfVariant variant
    , begunAnnotations = fixtureAnnotations
    , begunStartedAt = "2026-10-07T20:00:00Z"
    }

closeRecord :: Text -> Variant -> Int -> CycleOutcome -> Maybe Text -> LedgerRecord
closeRecord label variant attempt outcome artifact =
  RecordCycleClosed (closedFor label variant attempt outcome artifact)

closedFor :: Text -> Variant -> Int -> CycleOutcome -> Maybe Text -> ClosedRecord
closedFor label variant attempt outcome artifact =
  ClosedRecord
    { closedLabel = labelOf label
    , closedAttempt = attempt
    , closedEndKey = case outcome of
        CycleSourceDrifted -> identityKeyOfParts (partsOfVariant (other variant))
        _ -> identityKeyOfParts (partsOfVariant variant)
    , closedOutcome = outcome
    , closedArtifactDigest = artifact
    , closedCleanupRunId = "cascade-qualification-" <> label
    , closedCompletedAt = "2026-10-07T21:00:00Z"
    }
 where
  -- A deployment the source of which moved while the cascade ran.
  other moved = DeploymentParts (partsOfVariant moved) {partsGeneratedConfig = digestOf 'Y'}

-- | Append a history, assigning attempt numbers the way the runner does.
ledgerOf :: [Step] -> (CycleLedger, Map CycleLabel (Either ArtifactDefect ArtifactFact))
ledgerOf = extendLedger (emptyCycleLedger, Map.empty)

-- | The same history, continued from a ledger and its artifacts.
extendLedger
  :: (CycleLedger, Map CycleLabel (Either ArtifactDefect ArtifactFact))
  -> [Step]
  -> (CycleLedger, Map CycleLabel (Either ArtifactDefect ArtifactFact))
extendLedger = foldl step
 where
  step (ledger, artifacts) scripted = case scripted of
    Pass label variant ->
      let attempt = attemptFor ledger label
          (text, digest) = artifactFor label variant attempt
       in ( appendAll
              ledger
              [beginRecord label variant attempt, closeRecord label variant attempt CyclePassed (Just digest)]
          , Map.insert (labelOf label) (attestCascadeArtifact text) artifacts
          )
    Fail label variant ->
      let attempt = attemptFor ledger label
       in ( appendAll
              ledger
              [ beginRecord label variant attempt
              , closeRecord label variant attempt (CycleFailed FailedCandidateRefused) Nothing
              ]
          , artifacts
          )
    Interrupt label variant ->
      let attempt = attemptFor ledger label
       in (appendAll ledger [beginRecord label variant attempt], artifacts)
    Drift label variant ->
      let attempt = attemptFor ledger label
          (_, digest) = artifactFor label variant attempt
       in ( appendAll
              ledger
              [ beginRecord label variant attempt
              , closeRecord label variant attempt CycleSourceDrifted (Just digest)
              ]
          , artifacts
          )
    Activate labels variant ->
      (appendAll ledger [RecordCutoverMark (markFor MarkActivated labels variant ledger)], artifacts)
    DeleteRoute variant ->
      (appendAll ledger [RecordCutoverMark (deletionMarkFor variant ledger)], artifacts)
    QualifyPost labels variant ->
      ( appendAll ledger [RecordCutoverMark (markFor MarkPostActivationQualified labels variant ledger)]
      , artifacts
      )
  attemptFor ledger label = either (error . show) id (labelDisposition ledger (labelOf label))

-- | The mark a legal step would record: the key and tree of the cycles that
-- licensed it, and the labels and artifacts of exactly those cycles.
markFor :: CutoverMarkKind -> [Text] -> Variant -> CycleLedger -> MarkRecord
markFor kind labels variant ledger =
  MarkRecord
    { markKind = kind
    , markWitnessKey = identityKeyOfParts parts
    , markLocalKey = localKeyOfParts parts
    , markWitnessLabels = map labelOf labels
    , markWitnessArtifacts = [digest | label <- labels, Just digest <- [passedDigest label]]
    , markRecordedAt = "2026-10-07T22:00:00Z"
    }
 where
  parts = partsOfVariant variant
  passedDigest label =
    listToMaybe
      [ digest
      | attempt <- resolveAttempts ledger
      , resolvedLabel attempt == labelOf label
      , resolvedResolution attempt == AttemptPassed
      , Just digest <- [resolvedArtifactDigest attempt]
      ]

-- | The deletion's mark: it consumes the witness the activation recorded, and
-- records the tree it was made on.
deletionMarkFor :: Variant -> CycleLedger -> MarkRecord
deletionMarkFor variant ledger = case lastMarkOf ledger of
  Just activated ->
    activated
      { markKind = MarkLegacyRouteDeleted
      , markLocalKey = localKeyOfParts (partsOfVariant variant)
      }
  -- With no mark to consume the ledger refuses the deletion by its epoch.
  Nothing -> markFor MarkLegacyRouteDeleted ["pre-1", "pre-2"] variant ledger

appendAll :: CycleLedger -> [LedgerRecord] -> CycleLedger
appendAll = foldl (\ledger record -> either (error . show) fst (appendRecord ledger record))

verdictOf :: [Step] -> Either LedgerRefusal ConsecutiveCycleProof
verdictOf steps = uncurry judgeConsecutiveCycles (ledgerOf steps)

-- | The inventory lines a set of images would have been observed as, one
-- container per image, so an artifact built over arbitrary parts is consistent
-- with itself.
inventoryFor :: [PublicEvidenceDigest] -> [Text]
inventoryFor images =
  [ "component-" <> Text.pack (show index) <> "=sha256:" <> publicEvidenceDigestText image
  | (index, image) <- zip [1 :: Int ..] images
  ]

-- | Two consecutive qualifying cycles on exactly this identity, as the judge
-- would mint the proof for them.
proofForIdentity :: QualificationIdentity -> ConsecutiveCycleProof
proofForIdentity identity =
  case verdictOf [Pass "pre-1" deployment, Pass "pre-2" deployment] of
    Right proof -> proof
    Left refusal -> error ("the identity's two cycles did not qualify: " ++ show refusal)
 where
  deployment = DeploymentParts (partsOfIdentity canonicalKeyPolicy identity)
