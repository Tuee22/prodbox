{-# LANGUAGE OverloadedStrings #-}

-- | Fixtures shared by the cascade cycle identity and artifact suites: a source
-- tree with documentation and code in it, the identity parts built from it, and
-- the artifact fields a cycle of it would write.
module CycleIdentityFixtures
  ( fixtureHead
  , fixtureOtherHead
  , fixtureCandidates
  , sourceIdentityOf
  , digestOf
  , imageDigestOf
  , fixtureLocal
  , fixtureCompared
  , fixtureParts
  , fixtureAnnotations
  , fixtureLabel
  , fixtureArtifactFields
  , fixtureInventory
  , sameCycleUnderLabel
  )
where

import Data.ByteString.Char8 qualified as BS8
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.Qualification.CascadeCycleArtifact
  ( CascadeArtifactFields (..)
  , CycleLabel
  , mkCycleLabel
  )
import Prodbox.Test.Qualification.CascadeCycleIdentity
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , hashPublicEvidence
  , mkPublicEvidenceDigest
  )
import Prodbox.Test.Qualification.SourceIdentity
import TestSupport (FixtureAwsRegion (..), fixtureAwsRegion)

fixtureHead :: GitHead
fixtureHead = acceptedHead "0123456789abcdef0123456789abcdef01234567"

fixtureOtherHead :: GitHead
fixtureOtherHead = acceptedHead "fedcba9876543210fedcba9876543210fedcba98"

acceptedHead :: Text -> GitHead
acceptedHead raw = either (error . show) id (mkGitHead raw)

regular :: Text -> BS8.ByteString -> SourceCandidate
regular path bytes =
  SourceCandidate
    { sourceCandidatePath = path
    , sourceCandidateType = ManifestRegularFile
    , sourceCandidateMode = 0o644
    , sourceCandidateBytes = bytes
    }

-- | Two documentation files, a root documentation file, a chart readme (which
-- is not documentation for this purpose), a test file and two code files.
fixtureCandidates :: [SourceCandidate]
fixtureCandidates =
  [ regular "src/Prodbox/A.hs" "module Prodbox.A where"
  , regular "src/Prodbox/B.hs" "module Prodbox.B where"
  , regular "test/unit/A.hs" "module A where"
  , regular "charts/gateway/README.md" "# chart notes"
  , regular "DEVELOPMENT_PLAN/README.md" "# plan"
  , regular "documents/engineering/doctrine.md" "# doctrine"
  , regular "README.md" "# readme"
  ]

sourceIdentityOf :: SourceScope -> GitHead -> WorktreeState -> [SourceCandidate] -> SourceIdentity
sourceIdentityOf scope gitHead worktree candidates =
  either (error . show) id (mkScopedSourceIdentity scope gitHead worktree [] candidates)

-- | A digest that is easy to tell apart in a failure message.
digestOf :: Char -> PublicEvidenceDigest
digestOf character = hashPublicEvidence (Text.singleton character)

-- | The image digest that is sixty-four copies of one hex digit.
imageDigestOf :: Char -> PublicEvidenceDigest
imageDigestOf character =
  fromMaybe
    (error "fixture image digest")
    (mkPublicEvidenceDigest (Text.replicate 64 (Text.singleton character)))

fixtureLocal :: RecomputedLocalParts
fixtureLocal =
  RecomputedLocalParts
    { localExecutableSource =
        sourceIdentityOf ExecutableSurface fixtureHead WorktreeDirty fixtureCandidates
    , localFullSource = sourceIdentityOf FullSurface fixtureHead WorktreeDirty fixtureCandidates
    , localGeneratedConfig = digestOf 'c'
    , localResourceEnvelope = digestOf 'e'
    , localLoadFault = digestOf 'l'
    }

fixtureCompared :: CompareOnlyParts
fixtureCompared =
  CompareOnlyParts
    { compareImages = [imageDigestOf 'b', imageDigestOf 'a', imageDigestOf 'b']
    , compareTopologyWiring = digestOf 't'
    }

fixtureParts :: CycleIdentityParts
fixtureParts = partsFromLocal canonicalKeyPolicy fixtureLocal fixtureCompared

fixtureAnnotations :: CycleAnnotations
fixtureAnnotations = annotationsOf (localFullSource fixtureLocal) (Just "b1nary")

fixtureLabel :: CycleLabel
fixtureLabel = either (error . show) id (mkCycleLabel "pre-1")

-- | Three containers over two images, so a digest set and an inventory are
-- different things.
fixtureInventory :: [Text]
fixtureInventory =
  [ "gateway=sha256:" <> Text.replicate 64 "a"
  , "api=sha256:" <> Text.replicate 64 "b"
  , "websocket=sha256:" <> Text.replicate 64 "b"
  ]

-- | The fields a cycle of 'fixtureParts' would write.
fixtureArtifactFields :: CascadeArtifactFields
fixtureArtifactFields =
  CascadeArtifactFields
    { fieldsLabel = fixtureLabel
    , fieldsAttempt = 1
    , fieldsCanonicalCommand = canonicalCommandFor "pre-1"
    , fieldsStartedAt = "2026-10-07T20:00:00Z"
    , fieldsCompletedAt = "2026-10-07T21:05:00Z"
    , fieldsAwsAccount = "111122223333"
    , fieldsAwsRegion = fixtureAwsRegion FixtureCaCentral1
    , fieldsCleanupRunId = "cascade-qualification-pre-1"
    , fieldsParts = fixtureParts
    , fieldsAnnotations = fixtureAnnotations
    , fieldsComponentImages = fixtureInventory
    , fieldsRunScopedTopologyDigest = Text.replicate 64 "1"
    , fieldsRunScopedWiringDigest = Text.replicate 64 "2"
    , fieldsInForceConfigDigest = Text.replicate 64 "3"
    , fieldsFrozenLines =
        [ ("superseded_topology_digest", Text.replicate 64 "4")
        , ("fault_external_state", "first")
        , ("fault_external_state", "second")
        , ("intended_retained_set", "retained")
        ]
    , fieldsAggregateSucceeded = True
    , fieldsResidueAbsent = True
    , fieldsLifecycleSucceeded = True
    , fieldsLifecycleResult = "LifecycleCleanupSucceeded"
    }

canonicalCommandFor :: Text -> Text
canonicalCommandFor label =
  "PRODBOX_TEST_CASCADE_QUALIFICATION_CYCLE="
    <> label
    <> " prodbox test integration cascade-qualification --substrate aws"

-- | The same deployment's cycle under another label: everything that names a
-- run changes, and the identity parts do not.
sameCycleUnderLabel :: Text -> CascadeArtifactFields -> CascadeArtifactFields
sameCycleUnderLabel labelText fields =
  fields
    { fieldsLabel = either (error . show) id (mkCycleLabel labelText)
    , fieldsCleanupRunId = "cascade-qualification-" <> labelText
    , fieldsCanonicalCommand = canonicalCommandFor labelText
    , fieldsRunScopedTopologyDigest = Text.replicate 64 "5"
    , fieldsRunScopedWiringDigest = Text.replicate 64 "6"
    , fieldsStartedAt = "2026-10-07T22:00:00Z"
    , fieldsCompletedAt = "2026-10-07T23:05:00Z"
    }
