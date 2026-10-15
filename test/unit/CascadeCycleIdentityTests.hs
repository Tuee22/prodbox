{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 6.5: what two qualification cycles must share to be one deployment.
--
-- The point of the identity is what it leaves out. A cycle's own plan names its
-- run, so two cycles can never agree on it; the identity is built from what the
-- deployment is, and every case here varies one fact and expects the key and
-- the diff to answer for exactly that fact.
module CascadeCycleIdentityTests
  ( cascadeCycleIdentitySuite
  )
where

import CycleIdentityFixtures
import Data.Text qualified as Text
import Prodbox.Test.Qualification.CascadeCycleIdentity
import Prodbox.Test.Qualification.Evidence
  ( QualificationIdentity (..)
  , hashPublicEvidence
  , publicEvidenceDigestText
  )
import Prodbox.Test.Qualification.SourceIdentity
import TestSupport

cascadeCycleIdentitySuite :: SuiteBuilder ()
cascadeCycleIdentitySuite =
  describe "Sprint 6.5 cascade cycle identity" $ do
    sourceCases
    keyCases
    componentCases
    derivedCases

sourceCases :: SuiteBuilder ()
sourceCases = do
  it "keeps the version-1 full-surface policy byte for byte" $ do
    -- The superseded composition was captured under this digest, so a change to
    -- the full-surface policy bytes would orphan it.
    let fullPolicy = sourceManifestPolicyIdentity (localFullSource fixtureLocal)
    sourcePolicyDigest fullPolicy
      `shouldBe` "4e35f2ead11a0e645129c1d38787562aaf8a8daf622642470eb5d69cbde4d7ae"
    sourcePolicyIdentifier fullPolicy `shouldBe` canonicalSourceManifestPolicyId
    sourcePolicyVersion fullPolicy `shouldBe` canonicalSourceManifestPolicyVersion

  it "gives the executable surface its own policy identity and digest" $ do
    let fullPolicy = sourceManifestPolicyIdentity (localFullSource fixtureLocal)
        executablePolicy = sourceManifestPolicyIdentity (localExecutableSource fixtureLocal)
    sourcePolicyIdentifier executablePolicy `shouldBe` executableSourceManifestPolicyId
    sourcePolicyIdentifier executablePolicy `shouldNotBe` sourcePolicyIdentifier fullPolicy
    sourcePolicyDigest executablePolicy `shouldNotBe` sourcePolicyDigest fullPolicy

  it "drops documentation from the executable source and keeps it in the full source" $ do
    let documentation = ["DEVELOPMENT_PLAN/README.md", "documents/engineering/doctrine.md", "README.md"]
    sourceManifestEntryCount (localFullSource fixtureLocal)
      `shouldBe` length fixtureCandidates
    sourceManifestEntryCount (localExecutableSource fixtureLocal)
      `shouldBe` (length fixtureCandidates - length documentation)
    -- A chart's readme ships with the chart, so it is an executable input.
    isDocumentationPath "charts/gateway/README.md" `shouldBe` False
    mapM_ (\path -> isDocumentationPath path `shouldBe` True) documentation
    mapM_
      (\path -> isDocumentationPath path `shouldBe` False)
      ["src/Prodbox/A.hs", "test/unit/A.hs", "prodbox.cabal", "AGENTS-notes.md", "documents/x.txt"]

  it "refuses a tree that is nothing but documentation under the executable surface" $
    mkScopedSourceIdentity
      ExecutableSurface
      fixtureHead
      WorktreeClean
      []
      [candidate | candidate <- fixtureCandidates, isDocumentationPath (sourceCandidatePath candidate)]
      `shouldBe` Left SourceManifestEmpty

keyCases :: SuiteBuilder ()
keyCases = do
  it "is the same key for the same deployment, whatever order the images were observed in" $ do
    let reordered =
          partsFromLocal
            canonicalKeyPolicy
            fixtureLocal
            fixtureCompared {compareImages = reverse (compareImages fixtureCompared)}
    identityKeyOfParts reordered `shouldBe` identityKeyOfParts fixtureParts
    diffParts reordered fixtureParts `shouldBe` []

  it "ignores a documentation edit, because documentation is not an executable input" $ do
    let editedDocumentation =
          [ if sourceCandidatePath candidate == "DEVELOPMENT_PLAN/README.md"
              then candidate {sourceCandidateBytes = "# plan, with a cycle recorded in it"}
              else candidate
          | candidate <- fixtureCandidates
          ]
        local =
          fixtureLocal
            { localExecutableSource =
                sourceIdentityOf ExecutableSurface fixtureHead WorktreeDirty editedDocumentation
            , localFullSource = sourceIdentityOf FullSurface fixtureHead WorktreeDirty editedDocumentation
            }
        parts = partsFromLocal canonicalKeyPolicy local fixtureCompared
    identityKeyOfParts parts `shouldBe` identityKeyOfParts fixtureParts
    -- It is visible, never hidden: the whole-tree digest moved and is recorded.
    annotationFullManifestDigest (annotationsOf (localFullSource local) Nothing)
      `shouldNotBe` annotationFullManifestDigest fixtureAnnotations

  it "moves the source and the three digests derived from it on an executable edit" $ do
    let editedCode =
          [ if sourceCandidatePath candidate == "src/Prodbox/A.hs"
              then candidate {sourceCandidateBytes = "module Prodbox.A where\nx = 1"}
              else candidate
          | candidate <- fixtureCandidates
          ]
        local =
          fixtureLocal
            { localExecutableSource = sourceIdentityOf ExecutableSurface fixtureHead WorktreeDirty editedCode
            , localFullSource = sourceIdentityOf FullSurface fixtureHead WorktreeDirty editedCode
            }
        parts = partsFromLocal canonicalKeyPolicy local fixtureCompared
    identityKeyOfParts parts `shouldNotBe` identityKeyOfParts fixtureParts
    diffParts parts fixtureParts
      `shouldBe` [ComponentSource, ComponentInterpreter, ComponentPersistence, ComponentCleanupSchema]

  it "records git head and the dirty bit without keying them, unless the policy keys them" $ do
    let committed =
          fixtureLocal
            { localExecutableSource =
                sourceIdentityOf ExecutableSurface fixtureOtherHead WorktreeClean fixtureCandidates
            , localFullSource = sourceIdentityOf FullSurface fixtureOtherHead WorktreeClean fixtureCandidates
            }
        keyed = canonicalKeyPolicy {keyPolicyGitProvenance = True}
    -- An operator commit of byte-identical content does not reset the count.
    identityKeyOfParts (partsFromLocal canonicalKeyPolicy committed fixtureCompared)
      `shouldBe` identityKeyOfParts fixtureParts
    annotationGitHead (annotationsOf (localFullSource committed) Nothing)
      `shouldNotBe` annotationGitHead fixtureAnnotations
    -- Keyed, the same two trees are two deployments, and the diff says why.
    let keyedBefore = partsFromLocal keyed fixtureLocal fixtureCompared
        keyedAfter = partsFromLocal keyed committed fixtureCompared
    identityKeyOfParts keyedAfter `shouldNotBe` identityKeyOfParts keyedBefore
    diffParts keyedAfter keyedBefore `shouldBe` [ComponentGitProvenance]

  it "changes every key when the key policy changes, and says so" $ do
    let keyed = canonicalKeyPolicy {keyPolicyGitProvenance = True}
        fullSurface = canonicalKeyPolicy {keyPolicyScope = FullSurface}
    keyPolicyDigest canonicalKeyPolicy `shouldNotBe` keyPolicyDigest keyed
    keyPolicyDigest canonicalKeyPolicy `shouldNotBe` keyPolicyDigest fullSurface
    (ComponentKeyPolicy `elem` diffParts (partsFromLocal keyed fixtureLocal fixtureCompared) fixtureParts)
      `shouldBe` True
    identityKeyOfParts (partsFromLocal fullSurface fixtureLocal fixtureCompared)
      `shouldNotBe` identityKeyOfParts fixtureParts

  it "reads a key back only when it is sixty-four lowercase hex digits" $ do
    let key = identityKeyOfParts fixtureParts
    mkIdentityKey (identityKeyText key) `shouldBe` Just key
    mkIdentityKey "abc" `shouldBe` Nothing
    mkIdentityKey (Text.toUpper (identityKeyText key)) `shouldBe` Nothing

componentCases :: SuiteBuilder ()
componentCases =
  it "answers for exactly the component that moved, one at a time" $ do
    let moved component change = do
          let changed = change fixtureParts
          identityKeyOfParts changed `shouldNotBe` identityKeyOfParts fixtureParts
          diffParts changed fixtureParts `shouldBe` [component]
    moved ComponentGeneratedConfig (\parts -> parts {partsGeneratedConfig = digestOf 'C'})
    moved ComponentImages (\parts -> parts {partsComponentImages = [imageDigestOf 'a']})
    moved ComponentTopologyWiring (\parts -> parts {partsTopologyWiring = digestOf 'T'})
    moved ComponentResourceEnvelope (\parts -> parts {partsResourceEnvelope = digestOf 'E'})
    moved ComponentLoadFault (\parts -> parts {partsLoadFault = digestOf 'L'})
    moved ComponentInterpreter (\parts -> parts {partsInterpreter = digestOf 'I'})
    moved ComponentPersistence (\parts -> parts {partsPersistence = digestOf 'P'})
    moved ComponentCleanupSchema (\parts -> parts {partsCleanupSchema = digestOf 'S'})
    moved ComponentSource (\parts -> parts {partsSourceEntryCount = partsSourceEntryCount parts + 1})
    moved
      ComponentSourcePolicy
      ( \parts ->
          parts
            { partsSourcePolicy =
                (partsSourcePolicy parts) {sourcePolicyVersion = sourcePolicyVersion (partsSourcePolicy parts) + 1}
            }
      )
    -- Every component the diff can name is one a case above moves.
    length [minBound .. maxBound :: IdentityComponent] `shouldBe` 12

derivedCases :: SuiteBuilder ()
derivedCases = do
  it "derives the interpreter, persistence and cleanup-schema digests by the version-1 formulas" $ do
    -- Independent of the module under test: the formulas the writer used inline.
    let sourceDigest = sourceManifestDigest (localExecutableSource fixtureLocal)
        formula suffix = hashPublicEvidence (sourceDigest <> "\NUL" <> suffix)
        (interpreter, persistence, cleanupSchema) = replacementDerivedDigests sourceDigest
    interpreter `shouldBe` formula "descriptor-bound-cascade-dispatch/v2"
    persistence `shouldBe` formula "cleanup-program-descriptor/v2\NULauthority-aggregate/v1"
    cleanupSchema `shouldBe` formula "cleanup-run-report/v1\NULcascade-complete-evidence/v1"

  it "builds the qualification identity over the source the policy covers" $ do
    let identity = assembleCurrentIdentity canonicalKeyPolicy fixtureLocal fixtureCompared
        fullIdentity =
          assembleCurrentIdentity
            (canonicalKeyPolicy {keyPolicyScope = FullSurface})
            fixtureLocal
            fixtureCompared
    qualificationSourceIdentity identity `shouldBe` localExecutableSource fixtureLocal
    qualificationSourceIdentity fullIdentity `shouldBe` localFullSource fixtureLocal
    -- Three containers over two images are two image digests.
    length (qualificationComponentImageDigests identity) `shouldBe` 2
    partsOfIdentity canonicalKeyPolicy identity `shouldBe` fixtureParts

  it "refreshes the source-derived parts exactly as a recomputation would" $ do
    let editedCode =
          [ if sourceCandidatePath candidate == "src/Prodbox/B.hs"
              then candidate {sourceCandidateBytes = "module Prodbox.B where\ny = 2"}
              else candidate
          | candidate <- fixtureCandidates
          ]
        recaptured = sourceIdentityOf ExecutableSurface fixtureHead WorktreeDirty editedCode
        recomputed =
          partsFromLocal
            canonicalKeyPolicy
            fixtureLocal {localExecutableSource = recaptured}
            fixtureCompared
    refreshSourceParts canonicalKeyPolicy recaptured fixtureParts `shouldBe` recomputed
    -- An unchanged recapture changes nothing, which is what lets a cycle that
    -- was not disturbed close under the key it began with.
    refreshSourceParts canonicalKeyPolicy (localExecutableSource fixtureLocal) fixtureParts
      `shouldBe` fixtureParts

  it "digests the set of images and the program shape, not the order or the run" $ do
    imageSetDigest [imageDigestOf 'a', imageDigestOf 'b']
      `shouldBe` imageSetDigest [imageDigestOf 'b', imageDigestOf 'a', imageDigestOf 'b']
    imageSetDigest [imageDigestOf 'a']
      `shouldNotBe` imageSetDigest [imageDigestOf 'a', imageDigestOf 'b']
    topologyWiringDigest "topology" "wiring" `shouldBe` topologyWiringDigest "topology" "wiring"
    topologyWiringDigest "topology" "wiring" `shouldNotBe` topologyWiringDigest "wiring" "topology"
    topologyWiringDigest "topology" "wiring" `shouldNotBe` topologyWiringDigest "topology" "other"
    -- Length-prefixed, so moving a boundary between two fields is a different digest.
    topologyWiringDigest "ab" "c" `shouldNotBe` topologyWiringDigest "a" "bc"
    publicEvidenceDigestText (topologyWiringDigest "topology" "wiring")
      `shouldSatisfy` ((== 64) . Text.length)
