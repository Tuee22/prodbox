{-# LANGUAGE OverloadedStrings #-}

module ScenarioEvidenceTests (scenarioEvidenceSuite) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Either (isRight)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Prodbox.Config.DeploymentScope (DeploymentEnvironment (Test), deploymentScope)
import Prodbox.Test.MutationOutcome
import Prodbox.Test.MutationSnapshot
import Prodbox.Test.MutationSnapshotObserve
import Prodbox.Test.MutationSnapshotWrite
import Prodbox.Test.MutationWorkerSettlement
import Prodbox.Test.MutationWorkspace
import Prodbox.Test.MutationWorkspaceIntent
import Prodbox.Test.Qualification.Evidence (hashPublicEvidence, publicEvidenceDigestText)
import Prodbox.Test.Qualification.SourceIdentity
  ( ManifestFileType (ManifestRegularFile, ManifestSymbolicLink)
  , SourceCandidate (..)
  , SourceIdentity
  , WorktreeState (WorktreeDirty)
  , mkGitHead
  , mkSourceIdentity
  )
import Prodbox.Test.Qualification.SourceManifest
  ( SourceCaptureLimits (..)
  , SourceManifestCaptureError (..)
  , captureSourceCandidate
  , captureWorktreeInputsBounded
  )
import Prodbox.Test.ReviewedMutation
import Prodbox.Test.ScenarioEvidence
import Prodbox.Test.ScenarioEvidenceStore
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , listDirectory
  , removeFile
  , renameDirectory
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( createLink
  , createSymbolicLink
  , fileMode
  , getFileStatus
  , linkCount
  , setFileMode
  )
import System.Posix.IO qualified as Posix
import TestSupport
  ( SuiteBuilder
  , assertMutationInvariant
  , describe
  , it
  , shouldBe
  , shouldReturn
  , shouldSatisfy
  )

scenarioEvidenceSuite :: SuiteBuilder ()
scenarioEvidenceSuite = describe "scenario evidence comparison" $ do
  it "keeps the canonical mutation bindings aligned with the reviewed candidates" $ do
    manifest <- TextIO.readFile "DEVELOPMENT_PLAN/mutation_cases.md"
    let phase1 = case Text.splitOn "### Phase 1 preliminary assertion binding" manifest of
          [_, remainder] -> case Text.splitOn "### Phase 0 assertion bindings" remainder of
            [body, _] -> body
            _ -> ""
          _ -> ""
        sections = Text.splitOn "The reviewed M01 overlapping-root variant" phase1
    case sections of
      [m02, m01] -> forM_ [(M01OverlappingRoots, m01), (M02MissingReport, m02)] $ \(mutation, section) -> do
        source <- captureSourceCandidate "." [] (reviewedSourcePath mutation) >>= either (fail . show) pure
        prepared <-
          either (fail . show) pure (prepareReviewedMutation mutation (sourceCandidateBytes source))
        forM_
          [ reviewedSourceDigest mutation
          , publicEvidenceDigestText (reviewedPatchDigest mutation)
          , publicEvidenceDigestText (preparedMutantDigest prepared)
          ]
          (\digest -> section `shouldSatisfy` Text.isInfixOf digest)
      _ -> fail "missing or repeated Phase 1 mutation binding sections"

  it "keeps the Phase 2 mutation bindings aligned with the reviewed candidates" $ do
    manifest <- TextIO.readFile "DEVELOPMENT_PLAN/mutation_cases.md"
    let section = case Text.splitOn "### Phase 2 assertion bindings" manifest of
          [_, remainder] -> case Text.splitOn "### Phase 0 assertion bindings" remainder of
            (body : _) -> body
            _ -> ""
          _ -> ""
    forM_ [M03ProductionUnlock, M03VaultIncarnation] $ \mutation -> do
      source <- captureSourceCandidate "." [] (reviewedSourcePath mutation) >>= either (fail . show) pure
      prepared <-
        either (fail . show) pure (prepareReviewedMutation mutation (sourceCandidateBytes source))
      forM_
        [ reviewedSourceDigest mutation
        , publicEvidenceDigestText (reviewedPatchDigest mutation)
        , publicEvidenceDigestText (preparedMutantDigest prepared)
        ]
        (\digest -> section `shouldSatisfy` Text.isInfixOf digest)

  it "keeps the Phase 3 mutation bindings aligned with the reviewed candidates" $ do
    manifest <- TextIO.readFile "DEVELOPMENT_PLAN/mutation_cases.md"
    let section = case Text.splitOn "### Phase 3 assertion bindings" manifest of
          [_, remainder] -> case Text.splitOn "### Phase 2 assertion bindings" remainder of
            (body : _) -> body
            _ -> ""
          _ -> ""
    forM_ [M04UnknownAsFresh, M04MissingAsFresh, M05PendingNoChange, M04MirrorGenesisAsFresh] $ \mutation -> do
      source <- captureSourceCandidate "." [] (reviewedSourcePath mutation) >>= either (fail . show) pure
      prepared <-
        either (fail . show) pure (prepareReviewedMutation mutation (sourceCandidateBytes source))
      forM_
        [ reviewedSourceDigest mutation
        , publicEvidenceDigestText (reviewedPatchDigest mutation)
        , publicEvidenceDigestText (preparedMutantDigest prepared)
        ]
        (\digest -> section `shouldSatisfy` Text.isInfixOf digest)

  it "prepares the one reviewed M02 source change only from its pinned preimage" $ do
    source <-
      captureSourceCandidate "." [] (reviewedSourcePath M02MissingReport) >>= either (fail . show) pure
    prepared <-
      either (fail . show) pure (prepareReviewedMutation M02MissingReport (sourceCandidateBytes source))
    reviewedAssertion M02MissingReport `shouldBe` "evidence.rejects_unbound_result"
    reviewedTestPath M02MissingReport
      `shouldBe` "prodbox-unit.scenario evidence comparison.rejects an unbound report for the mutation catalog"
    publicEvidenceDigestText (preparedMutantDigest prepared)
      `shouldSatisfy` (/= reviewedSourceDigest M02MissingReport)
    preparedMutantBytes prepared `shouldSatisfy` ByteString.isInfixOf "  report <- maybe\n"
    prepareReviewedMutation M02MissingReport (sourceCandidateBytes source <> " ")
      `shouldBe` Left MutationSourceDigestChanged
    prepareReviewedMutation M02MissingReport (ByteString.pack [255])
      `shouldBe` Left MutationSourceInvalidUtf8
    prepareReviewedMutation M02MissingReport (ByteString.replicate 1048577 97)
      `shouldBe` Left MutationSourceTooLarge

  it "prepares the reviewed M01 root overlap mutation only from its pinned preimage" $ do
    source <-
      captureSourceCandidate "." [] (reviewedSourcePath M01OverlappingRoots) >>= either (fail . show) pure
    prepared <-
      either
        (fail . show)
        pure
        (prepareReviewedMutation M01OverlappingRoots (sourceCandidateBytes source))
    reviewedAssertion M01OverlappingRoots `shouldBe` "context.rejects_root_alias"
    reviewedTestPath M01OverlappingRoots
      `shouldBe` "prodbox-unit.deployment scope coordinates.rejects overlapping roots for the mutation catalog"
    publicEvidenceDigestText (preparedMutantDigest prepared)
      `shouldSatisfy` (/= reviewedSourceDigest M01OverlappingRoots)
    preparedMutantBytes prepared
      `shouldSatisfy` ( not
                          . ByteString.isInfixOf
                            "  | rootsOverlap (scopeRoot left) (scopeRoot right) = Left OverlappingDeploymentRoots\n"
                      )
    prepareReviewedMutation M01OverlappingRoots (sourceCandidateBytes source <> " ")
      `shouldBe` Left MutationSourceDigestChanged

  it "applies one reviewed source mutation without changing snapshot tests or aliases" $ do
    headId <- either (fail . show) pure (mkGitHead (Text.replicate 40 "a"))
    source <-
      captureSourceCandidate "." [] (reviewedSourcePath M01OverlappingRoots) >>= either (fail . show) pure
    testSource <-
      captureSourceCandidate "." [] "test/unit/DeploymentScopeTests.hs" >>= either (fail . show) pure
    baseline <-
      either (fail . show) pure (makeMutationSnapshot headId WorktreeDirty [] [source, testSource])
    mutated <- either (fail . show) pure (applyReviewedMutationToSnapshot M01OverlappingRoots baseline)
    mutationSnapshotSource mutated `shouldBe` mutationSnapshotSource baseline
    let operation = replicate 32 'a'
        rootIdentity = MutationSnapshotRootIdentity 7 19
        baselineKey = mutationWorkspaceWorkerKey operation baseline rootIdentity
    baselineKey `shouldSatisfy` isJust
    mutationWorkspaceWorkerKey operation baseline rootIdentity `shouldBe` baselineKey
    mutationWorkspaceWorkerKey operation mutated rootIdentity `shouldSatisfy` (/= baselineKey)
    mutationWorkspaceWorkerKey (replicate 32 'b') baseline rootIdentity `shouldSatisfy` (/= baselineKey)
    mutationWorkspaceWorkerKey operation baseline (MutationSnapshotRootIdentity 7 20)
      `shouldSatisfy` (/= baselineKey)
    mutationWorkspaceWorkerKey "invalid" baseline rootIdentity `shouldBe` Nothing
    withMutationHostRetirementObservation
      1
      (error "unused host owner")
      (error "unused host record")
      "invalid"
      baseline
      rootIdentity
      (const (pure ()))
      `shouldReturn` MutationHostObservationRefused MutationHostObservationInvalidBinding
    mutationWorkspaceWorkerKey operation baseline (MutationSnapshotRootIdentity 7 0) `shouldBe` Nothing
    mutationSnapshotMutation baseline `shouldBe` Nothing
    fmap snapshotReviewedMutation (mutationSnapshotMutation mutated) `shouldBe` Just M01OverlappingRoots
    fmap snapshotMutationPatch (mutationSnapshotMutation mutated)
      `shouldBe` Just (reviewedPatchDigest M01OverlappingRoots)
    let original = mutationSnapshotFiles baseline
        changed = mutationSnapshotFiles mutated
        selected entries = filter ((== "src/Prodbox/Config/DeploymentScope.hs") . snapshotFilePath) entries
        tests entries = filter ((== "test/unit/DeploymentScopeTests.hs") . snapshotFilePath) entries
    selected changed `shouldSatisfy` (/= selected original)
    tests changed `shouldBe` tests original
    applyReviewedMutationToSnapshot M01OverlappingRoots mutated
      `shouldBe` Left MutationSnapshotAlreadyMutated
    applyReviewedMutationToSnapshot M02MissingReport baseline
      `shouldBe` Left MutationSnapshotMutationTargetMissing
    let alias =
          SourceCandidate
            "test/alias.hs"
            ManifestSymbolicLink
            0o777
            "../src/Prodbox/Config/DeploymentScope.hs"
    aliased <-
      either (fail . show) pure (makeMutationSnapshot headId WorktreeDirty [] [source, testSource, alias])
    applyReviewedMutationToSnapshot M01OverlappingRoots aliased
      `shouldBe` Left MutationSnapshotMutationTargetAliased
    let renamed = source {sourceCandidatePath = "src/backup.hs"}
        targetLink =
          SourceCandidate "src/Prodbox/Config/DeploymentScope.hs" ManifestSymbolicLink 0o777 "../../backup.hs"
    linked <-
      either (fail . show) pure (makeMutationSnapshot headId WorktreeDirty [] [renamed, targetLink])
    applyReviewedMutationToSnapshot M01OverlappingRoots linked
      `shouldBe` Left MutationSnapshotMutationTargetIsLink
    let stale = source {sourceCandidateBytes = sourceCandidateBytes source <> " "}
    staleSnapshot <-
      either (fail . show) pure (makeMutationSnapshot headId WorktreeDirty [] [stale, testSource])
    applyReviewedMutationToSnapshot M01OverlappingRoots staleSnapshot
      `shouldBe` Left (MutationSnapshotMutationRejected MutationSourceDigestChanged)

  it "resolves snapshot symlinks only to admitted regular source bytes" $ do
    headId <- either (fail . show) pure (mkGitHead (Text.replicate 40 "a"))
    let target = SourceCandidate "src/X.hs" ManifestRegularFile 0o644 "source"
        link bytes = SourceCandidate "test/X.hs" ManifestSymbolicLink 0o777 bytes
        snapshot = makeMutationSnapshot headId WorktreeDirty []
    prepared <- either (fail . show) pure (snapshot [target, link "../src/X.hs"])
    mutationSnapshotFiles prepared
      `shouldBe` [MutationSnapshotFile "src/X.hs" 0o644 "source", MutationSnapshotFile "test/X.hs" 0o644 "source"]
    snapshot [target, link "../../outside"] `shouldBe` Left (MutationSnapshotInvalidLink "test/X.hs")
    snapshot [target, link "/src/X.hs"] `shouldBe` Left (MutationSnapshotInvalidLink "test/X.hs")
    snapshot [target, link "../src/missing.hs"]
      `shouldBe` Left (MutationSnapshotMissingLinkTarget "test/X.hs")
    snapshot [target, link (ByteString.pack [255])]
      `shouldBe` Left (MutationSnapshotInvalidLink "test/X.hs")
    let parent = SourceCandidate "src/X.hs/child.hs" ManifestRegularFile 0o644 "child"
    snapshot [target, parent] `shouldBe` Left (MutationSnapshotPathCollision "src/X.hs/child.hs")
    let chained = SourceCandidate "src/alias.hs" ManifestSymbolicLink 0o777 "X.hs"
    snapshot [target, chained, link "../src/alias.hs"]
      `shouldBe` Left (MutationSnapshotNonRegularLinkTarget "test/X.hs")

  it "writes fresh snapshot files without hardlinks or replacing an existing root" $
    withSystemTempDirectory "prodbox-mutation-snapshot" $ \directory -> do
      headId <- either (fail . show) pure (mkGitHead (Text.replicate 40 "a"))
      let source = SourceCandidate "src/X.hs" ManifestRegularFile 0o644 "source"
          alias = SourceCandidate "test/X.hs" ManifestSymbolicLink 0o777 "../src/X.hs"
          operation = replicate 32 'a'
          output = directory </> operation
          flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True}
      snapshot <- either (fail . show) pure (makeMutationSnapshot headId WorktreeDirty [] [source, alias])
      writeFile (directory </> "foreign") "unchanged"
      bracket (Posix.openFd directory Posix.ReadOnly flags) Posix.closeFd $ \parent -> do
        written <- writeMutationSnapshot parent operation snapshot
        written `shouldSatisfy` isSnapshotWritten
        observeMutationSnapshot parent operation snapshot `shouldReturn` MutationSnapshotMatches
        writeFile (output </> "unexpected") "foreign"
        observeMutationSnapshot parent operation snapshot `shouldReturn` MutationSnapshotDiffers
        removeFile (output </> "unexpected")
        ByteString.writeFile (output </> "src/X.hs") "change"
        observeMutationSnapshot parent operation snapshot `shouldReturn` MutationSnapshotDiffers
        ByteString.writeFile (output </> "src/X.hs") "source"
        removeFile (output </> "src/X.hs")
        createSymbolicLink (directory </> "foreign") (output </> "src/X.hs")
        observeMutationSnapshot parent operation snapshot >>= (`shouldSatisfy` (/= MutationSnapshotMatches))
        removeFile (output </> "src/X.hs")
        createLink (directory </> "foreign") (output </> "src/X.hs")
        observeMutationSnapshot parent operation snapshot >>= (`shouldSatisfy` (/= MutationSnapshotMatches))
        removeFile (output </> "src/X.hs")
        ByteString.writeFile (output </> "src/X.hs") "source"
        setFileMode (output </> "src/X.hs") 0o600
        observeMutationSnapshot parent operation snapshot `shouldReturn` MutationSnapshotMatches
        ByteString.readFile (output </> "src/X.hs") `shouldReturn` "source"
        ByteString.readFile (output </> "test/X.hs") `shouldReturn` "source"
        original <- getFileStatus (output </> "src/X.hs")
        copied <- getFileStatus (output </> "test/X.hs")
        linkCount original `shouldBe` 1
        linkCount copied `shouldBe` 1
        (fileMode original .&. 0o777) `shouldBe` 0o600
        writeMutationSnapshot parent operation snapshot `shouldReturn` MutationSnapshotWriteExists
        writeMutationSnapshot parent "../foreign" snapshot `shouldReturn` MutationSnapshotWriteInvalid
        setFileMode directory 0o777
        writeMutationSnapshot parent (replicate 32 'b') snapshot
          `shouldReturn` MutationSnapshotWriteUnobservable
        setFileMode directory 0o700
      readFile (directory </> "foreign") `shouldReturn` "unchanged"

  it "binds a new mutation workspace to the selected project and preserves changed results" $
    withSystemTempDirectory "prodbox-mutation-workspace" $ \directory -> do
      headId <- either (fail . show) pure (mkGitHead (Text.replicate 40 "a"))
      let source = SourceCandidate "src/X.hs" ManifestRegularFile 0o644 "source"
          operation = replicate 32 'a'
          nextOperation = replicate 32 'b'
          workspaceParent = directory </> ".build/mutation-workspaces"
      snapshot <- either (fail . show) pure (makeMutationSnapshot headId WorktreeDirty [] [source])
      writeFile (directory </> "foreign") "unchanged"
      setFileMode (directory </> "foreign") 0o600
      withNewMutationWorkspace
        directory
        operation
        snapshot
        ( \_ stable -> do
            withRecoveredMutationWorkspace directory operation snapshot (\_ _ -> pure True)
              `shouldReturn` MutationWorkspaceBusy
            stable
        )
        `shouldReturn` MutationWorkspaceCallbackReturned True
      withRecoveredMutationWorkspace directory operation snapshot (\_ stable -> stable)
        `shouldReturn` MutationWorkspaceCallbackReturned True
      ByteString.writeFile (workspaceParent </> operation </> "src/X.hs") "change"
      withRecoveredMutationWorkspace directory operation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceObservationRefused MutationSnapshotDiffers
      ByteString.writeFile (workspaceParent </> operation </> "src/X.hs") "source"
      withNewMutationWorkspace directory operation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceIntentWriteRefused MutationWorkspaceIntentExists
      let thirdOperation = replicate 32 'c'
          flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True}
          different = source {sourceCandidateBytes = "different"}
      otherSnapshot <-
        either (fail . show) pure (makeMutationSnapshot headId WorktreeDirty [] [different])
      withRecoveredMutationWorkspace directory operation otherSnapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceIntentObservationRefused MutationWorkspaceIntentConflict
      bracket (Posix.openFd workspaceParent Posix.ReadOnly flags) Posix.closeFd $ \parent -> do
        observeMutationWorkspaceIntent parent operation snapshot (pure True)
          `shouldReturn` MutationWorkspaceIntentMatches
        observeMutationWorkspaceIntent parent operation otherSnapshot (pure True)
          `shouldReturn` MutationWorkspaceIntentConflict
        observeMutationWorkspaceIntent parent thirdOperation snapshot (pure True)
          `shouldReturn` MutationWorkspaceIntentMissing
        rootStatus <- getFileStatus (workspaceParent </> operation)
        let rootIdentity = mutationSnapshotRootIdentity rootStatus
        readMutationWorkspaceBirth parent operation snapshot (pure True)
          `shouldReturn` MutationWorkspaceBirthFound rootIdentity
        readMutationWorkspaceBirth parent operation otherSnapshot (pure True)
          `shouldReturn` MutationWorkspaceBirthConflict
        readMutationWorkspaceBirth parent thirdOperation snapshot (pure True)
          `shouldReturn` MutationWorkspaceBirthMissing
        readMutationWorkspaceBirth parent operation snapshot (pure False)
          `shouldReturn` MutationWorkspaceBirthUnobservable
        observeMutationWorkspaceBirth parent operation snapshot rootIdentity (pure True)
          `shouldReturn` MutationWorkspaceIntentMatches
        observeMutationWorkspaceBirth
          parent
          operation
          snapshot
          (MutationSnapshotRootIdentity 0 0)
          (pure True)
          `shouldReturn` MutationWorkspaceIntentConflict
        observeMutationWorkspaceBirth parent thirdOperation snapshot rootIdentity (pure True)
          `shouldReturn` MutationWorkspaceIntentMissing
      withNewMutationWorkspace
        directory
        thirdOperation
        snapshot
        ( \_ stable -> do
            stable `shouldReturn` True
            writeFile (workspaceParent </> thirdOperation ++ ".intent") "tampered"
            stable `shouldReturn` False
            pure ("intent changed" :: String)
        )
        `shouldReturn` MutationWorkspaceChangedAfter "intent changed"
      let changedIntent = workspaceParent </> thirdOperation ++ ".intent"
      removeFile changedIntent
      createSymbolicLink (directory </> "foreign") changedIntent
      bracket (Posix.openFd workspaceParent Posix.ReadOnly flags) Posix.closeFd $ \parent ->
        observeMutationWorkspaceIntent parent thirdOperation snapshot (pure True)
          `shouldReturn` MutationWorkspaceIntentUnobservable
      removeFile changedIntent
      createLink (directory </> "foreign") changedIntent
      bracket (Posix.openFd workspaceParent Posix.ReadOnly flags) Posix.closeFd $ \parent ->
        observeMutationWorkspaceIntent parent thirdOperation snapshot (pure True)
          `shouldReturn` MutationWorkspaceIntentObservationInvalid
      readFile (directory </> "foreign") `shouldReturn` "unchanged"
      let fifthOperation = replicate 32 'e'
      withNewMutationWorkspace
        directory
        fifthOperation
        snapshot
        ( \_ stable -> do
            stable `shouldReturn` True
            writeFile (workspaceParent </> fifthOperation ++ ".birth") "tampered"
            stable `shouldReturn` False
            pure ("birth changed" :: String)
        )
        `shouldReturn` MutationWorkspaceChangedAfter "birth changed"
      withRecoveredMutationWorkspace directory fifthOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceBirthReadRefused MutationWorkspaceBirthInvalid
      let fourthOperation = replicate 32 'd'
      createDirectory (workspaceParent </> fourthOperation)
      setFileMode (workspaceParent </> fourthOperation) 0o700
      writeFile (workspaceParent </> fourthOperation </> "foreign") "untouched"
      withNewMutationWorkspace directory fourthOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceWriteRefused MutationSnapshotWriteExists
      bracket (Posix.openFd workspaceParent Posix.ReadOnly flags) Posix.closeFd $ \parent ->
        observeMutationWorkspaceIntent parent fourthOperation snapshot (pure True)
          `shouldReturn` MutationWorkspaceIntentMatches
      readFile (workspaceParent </> fourthOperation </> "foreign") `shouldReturn` "untouched"
      withRecoveredMutationWorkspace directory fourthOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceBirthReadRefused MutationWorkspaceBirthMissing
      bracket (Posix.openFd workspaceParent Posix.ReadOnly flags) Posix.closeFd $ \parent ->
        observeMutationWorkspaceBirth
          parent
          fourthOperation
          snapshot
          (MutationSnapshotRootIdentity 0 0)
          (pure True)
          `shouldReturn` MutationWorkspaceIntentMissing
      let retireOperation = replicate 32 'f'
          conflictOperation = replicate 32 '1'
      withNewMutationWorkspace
        directory
        retireOperation
        snapshot
        ( \_ stable -> do
            beginMutationWorkspaceRetirement directory retireOperation snapshot
              `shouldReturn` MutationWorkspaceBusy
            withRetiringMutationWorkspace directory retireOperation snapshot (\_ _ -> pure True)
              `shouldReturn` MutationWorkspaceBusy
            stable
        )
        `shouldReturn` MutationWorkspaceCallbackReturned True
      withRetiringMutationWorkspace directory retireOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceRetirementRefused MutationWorkspaceIntentMissing
      beginMutationWorkspaceRetirement directory retireOperation snapshot
        `shouldReturn` MutationWorkspaceRetirementRecorded
      withRecoveredMutationWorkspace directory retireOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceRetirementRefused MutationWorkspaceIntentMatches
      beginMutationWorkspaceRetirement directory retireOperation snapshot
        `shouldReturn` MutationWorkspaceRetirementAlreadyRecorded
      withRetiringMutationWorkspace directory retireOperation snapshot (\_ stable -> stable)
        `shouldReturn` MutationWorkspaceCallbackReturned True
      ByteString.writeFile (workspaceParent </> retireOperation </> "src/X.hs") "change"
      withRetiringMutationWorkspace directory retireOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceObservationRefused MutationSnapshotDiffers
      ByteString.writeFile (workspaceParent </> retireOperation </> "src/X.hs") "source"
      let retiredName = workspaceParent </> retireOperation ++ ".retire"
          activeName = workspaceParent </> retireOperation ++ ".active"
      marker <- ByteString.readFile retiredName
      ByteString.writeFile activeName marker
      setFileMode activeName 0o600
      withRetiringMutationWorkspace directory retireOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceAdmissionRefused MutationWorkspaceIntentMatches
      removeFile activeName
      ByteString.readFile (workspaceParent </> retireOperation </> "src/X.hs") `shouldReturn` "source"
      removeFile (workspaceParent </> retireOperation ++ ".retire")
      withRetiringMutationWorkspace directory retireOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceRetirementRefused MutationWorkspaceIntentMissing
      withRecoveredMutationWorkspace directory retireOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceAdmissionRefused MutationWorkspaceIntentMissing
      beginMutationWorkspaceRetirement directory retireOperation snapshot
        `shouldReturn` MutationWorkspaceAdmissionRefused MutationWorkspaceIntentMissing
      ByteString.readFile (workspaceParent </> retireOperation </> "src/X.hs") `shouldReturn` "source"
      withNewMutationWorkspace directory conflictOperation snapshot (\_ stable -> stable)
        `shouldReturn` MutationWorkspaceCallbackReturned True
      writeFile (workspaceParent </> conflictOperation ++ ".retire") "foreign"
      setFileMode (workspaceParent </> conflictOperation ++ ".retire") 0o600
      withRecoveredMutationWorkspace directory conflictOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceRetirementRefused MutationWorkspaceIntentConflict
      beginMutationWorkspaceRetirement directory conflictOperation snapshot
        `shouldReturn` MutationWorkspaceRetirementRefused MutationWorkspaceIntentConflict
      let rootPath = workspaceParent </> operation
          savedRoot = workspaceParent </> "saved-root"
          replacementRoot = workspaceParent </> "replacement-root"
      originalStatus <- getFileStatus rootPath
      renameDirectory rootPath savedRoot
      bracket (Posix.openFd workspaceParent Posix.ReadOnly flags) Posix.closeFd $ \parent ->
        readMutationWorkspaceBirth parent operation snapshot (pure True)
          `shouldReturn` MutationWorkspaceBirthFound (mutationSnapshotRootIdentity originalStatus)
      withRecoveredMutationWorkspace directory operation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceUnobservable
      createDirectory rootPath
      setFileMode rootPath 0o700
      createDirectory (rootPath </> "src")
      setFileMode (rootPath </> "src") 0o700
      ByteString.writeFile (rootPath </> "src/X.hs") "source"
      setFileMode (rootPath </> "src/X.hs") 0o600
      withRecoveredMutationWorkspace directory operation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceBirthObservationRefused MutationWorkspaceIntentConflict
      renameDirectory rootPath replacementRoot
      renameDirectory savedRoot rootPath
      withRecoveredMutationWorkspace directory operation snapshot (\_ stable -> stable)
        `shouldReturn` MutationWorkspaceCallbackReturned True
      withNewMutationWorkspace (directory </> ".data") nextOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceInvalid
      createSymbolicLink directory (directory </> "link")
      withNewMutationWorkspace (directory </> "link") nextOperation snapshot (\_ _ -> pure True)
        `shouldReturn` MutationWorkspaceUnobservable
      withNewMutationWorkspace
        directory
        nextOperation
        snapshot
        ( \_ stable -> do
            stable `shouldReturn` True
            renameDirectory workspaceParent (directory </> ".build/old-workspaces")
            createDirectory workspaceParent
            setFileMode workspaceParent 0o700
            pure ("preserved" :: String)
        )
        `shouldReturn` MutationWorkspaceChangedAfter "preserved"

  it "bounds mutation source inventory and file bytes before snapshot preparation" $ do
    let limits = SourceCaptureLimits 100000 (512 * 1024 * 1024) (16 * 1024 * 1024) 120000000
    captureWorktreeInputsBounded limits {sourceCaptureMaximumFiles = 1} "." []
      `shouldReturn` Left SourceManifestBudgetExceeded
    captureWorktreeInputsBounded limits {sourceCaptureMaximumBytes = 1} "." []
      `shouldReturn` Left SourceManifestBudgetExceeded
    captureWorktreeInputsBounded limits {sourceCaptureMaximumGitBytes = 1} "." []
      `shouldReturn` Left (SourceManifestGitFailed "bounded git observation failed")
    captureWorktreeInputsBounded limits {sourceCaptureTimeoutMicros = 0} "." []
      `shouldReturn` Left SourceManifestBudgetExceeded

  it "requires one exact test listing from the intended binary observation" $ do
    let path = "prodbox-unit.scope.rejects foreign scope"
        binary = hashPublicEvidence "binary"
        validate = validateMutationSelection path binary
    validate ExitSuccess "prodbox-unit.scope.rejects foreign scope\n" "" `shouldSatisfy` isRight
    validate ExitSuccess "" "" `shouldBe` Left MutationSelectionMismatch
    validate ExitSuccess "prodbox-unit.scope.rejects foreign scope\nother\n" ""
      `shouldBe` Left MutationSelectionMismatch
    validate ExitSuccess "prodbox-unit.scope.rejects foreign scope" ""
      `shouldBe` Left MutationSelectionMismatch
    validate ExitSuccess "prodbox-unit.scope.rejects foreign scope\n" "warning"
      `shouldBe` Left MutationSelectionContaminated
    validate (ExitFailure 1) "prodbox-unit.scope.rejects foreign scope\n" ""
      `shouldBe` Left MutationSelectionCommandFailed
    validateMutationSelection "bad\npath" binary ExitSuccess "" ""
      `shouldBe` Left MutationSelectionInvalidExpected

  it "rejects ambiguous or contaminated single-test result transport" $ do
    let decode = decodeSingleMutationTest "evidence.rejects_unbound_result"
    decode ExitSuccess "" "prodbox-mutation-test-v1:passed\n" `shouldBe` TestPassed 1
    decode (ExitFailure 1) "" "prodbox-mutation-test-v1:assertion-failed\n"
      `shouldBe` TestAssertionFailures 1 ["evidence.rejects_unbound_result"]
    decode (ExitFailure 1) "" "prodbox-mutation-test-v1:other-failure\n"
      `shouldBe` TestAssertionFailures 1 []
    decode (ExitFailure 1) "" "prodbox-mutation-test-v1:timeout\n" `shouldBe` TestTimedOut
    decode (ExitFailure 1) "" "prodbox-mutation-test-v1:exception\n" `shouldBe` TestCrashed
    decode ExitSuccess "unexpected output" "prodbox-mutation-test-v1:passed\n"
      `shouldBe` TestUnobservable
    decode
      (ExitFailure 1)
      ""
      "prodbox-mutation-test-v1:assertion-failed\nprodbox-mutation-test-v1:assertion-failed\n"
      `shouldBe` TestUnobservable
    decode ExitSuccess "" "prodbox-mutation-test-v1:assertion-failed\n" `shouldBe` TestUnobservable
    decode (ExitFailure 1) "" "prodbox-mutation-test-v1:invalid-selection\n" `shouldBe` TestUnobservable

  it "rejects an unbound report for the mutation catalog" $ do
    (binding, required, _, independent) <- fixture
    assertMutationInvariant
      "evidence.rejects_unbound_result"
      (compareScenarioEvidence binding required Nothing (Just independent) == Left EvidenceReportMissing)

  it "classifies only the designated isolated compiled mutation as killed" $ do
    (scenario, _, _, _) <- fixture
    let expected =
          MutationBinding
            (scenarioSource scenario)
            (hashPublicEvidence "baseline")
            (hashPublicEvidence "patch")
            (hashPublicEvidence "selection")
            "prodbox-unit.scope.rejects foreign scope"
            "context.rejects_foreign_scope"
        listing = "prodbox-unit.scope.rejects foreign scope\n"
        mutant = hashPublicEvidence "mutant"
    baselineSelection <-
      either
        (fail . show)
        pure
        ( validateMutationSelection
            (mutationExpectedTestPath expected)
            (mutationBaselineBinary expected)
            ExitSuccess
            listing
            ""
        )
    mutantSelection <-
      either
        (fail . show)
        pure
        (validateMutationSelection (mutationExpectedTestPath expected) mutant ExitSuccess listing "")
    let
      attempt =
        MutationAttempt
          expected
          BoundaryConfirmed
          BoundaryConfirmed
          (BaselinePassed 1)
          (Just baselineSelection)
          PatchApplied
          (BuildSucceeded mutant)
          (Just mutantSelection)
          (TestAssertionFailures 1 ["context.rejects_foreign_scope"])
      classify = classifyMutationAttempt expected
    classify attempt `shouldBe` MutationKilled
    classify attempt {observedTest = TestPassed 1} `shouldBe` MutationSurvived
    classify attempt {observedTest = TestPassed 0} `shouldBe` MutationInconclusive
    classify attempt {observedTest = TestPassed 2} `shouldBe` MutationInconclusive
    classify attempt {observedTest = TestAssertionFailures 0 ["context.rejects_foreign_scope"]}
      `shouldBe` MutationInconclusive
    classify attempt {observedTest = TestAssertionFailures 1 ["unrelated"]}
      `shouldBe` MutationInconclusive
    classify
      attempt {observedTest = TestAssertionFailures 2 ["context.rejects_foreign_scope", "unrelated"]}
      `shouldBe` MutationInconclusive
    classify attempt {observedTest = TestTimedOut} `shouldBe` MutationInconclusive
    classify attempt {observedTest = TestCrashed} `shouldBe` MutationInconclusive
    classify
      attempt
        { observedBuild = BuildRejected
        , observedMutantSelection = Nothing
        , observedTest = TestNotRun
        }
      `shouldBe` MutationInvalid
    classify attempt {observedBuild = BuildRejected} `shouldBe` MutationInconclusive
    classify attempt {observedBuild = BuildSucceeded (mutationBaselineBinary expected)}
      `shouldBe` MutationInconclusive
    classify
      attempt
        { observedPatch = PatchPreconditionFailed
        , observedBuild = BuildNotRun
        , observedMutantSelection = Nothing
        , observedTest = TestNotRun
        }
      `shouldBe` MutationInvalid
    classify attempt {observedBaseline = BaselineFailed} `shouldBe` MutationInconclusive
    classify attempt {observedBaseline = BaselinePassed 0} `shouldBe` MutationInconclusive
    classify attempt {observedBaseline = BaselinePassed 2} `shouldBe` MutationInconclusive
    classify attempt {observedBaselineSelection = Nothing} `shouldBe` MutationInconclusive
    classify attempt {observedMutantSelection = Just baselineSelection} `shouldBe` MutationInconclusive
    classify attempt {observedIsolation = BoundaryUnobservable} `shouldBe` MutationInconclusive
    classify attempt {observedCleanup = BoundaryFailed} `shouldBe` MutationInconclusive
    classify
      attempt
        { observedMutationBinding = expected {mutationPatchDigest = hashPublicEvidence "other patch"}
        }
      `shouldBe` MutationInconclusive

  it "rejects noncanonical and private project roots before publication" $
    withSystemTempDirectory "prodbox-scenario-store-roots" $ \root -> do
      createDirectoryIfMissing True (root </> ".build")
      createDirectoryIfMissing True (root </> ".data" </> ".build")
      writeFile (root </> ".data" </> "marker") "unchanged"
      (_, _, report, _) <- fixtureAt root
      writeScenarioReport (root </> ".." </> takeFileName root) report
        `shouldReturn` Left ScenarioStoreUnsafe
      writeScenarioReport (root </> ".data") report `shouldReturn` Left ScenarioStoreUnsafe
      doesDirectoryExist (root </> ".build" </> "scenario-evidence") `shouldReturn` False
      doesDirectoryExist (root </> ".data" </> ".build" </> "scenario-evidence") `shouldReturn` False
      readFile (root </> ".data" </> "marker") `shouldReturn` "unchanged"

  it "publishes and reads one immutable scoped report" $
    withSystemTempDirectory "prodbox-scenario-store" $ \root -> do
      createDirectoryIfMissing True (root </> ".build")
      (binding, required, report, independent) <- fixtureAt root
      writeScenarioReport root report `shouldReturn` Right ()
      readScenarioReport root binding `shouldReturn` Right report
      writeScenarioReport root report `shouldReturn` Left ScenarioStoreExists
      validateStoredScenarioReport root binding required (pure (Just independent))
        `shouldReturn` Right EvidenceChecksSatisfied
      validateStoredScenarioReport root binding required (pure Nothing)
        `shouldReturn` Left (ScenarioStoreComparisonFailure EvidenceIndependentObservationMissing)
      validateStoredScenarioReport
        root
        binding
        required
        (pure (Just independent {independentCleanup = CleanupUnobservable}))
        `shouldReturn` Left (ScenarioStoreComparisonFailure EvidenceOutcomeMismatch)
      stored <- readScenarioReport root binding
      case stored of
        Left failure -> fail (show failure)
        Right actual ->
          compareScenarioEvidence binding required (Just actual) (Just independent)
            `shouldBe` Right EvidenceChecksSatisfied
      stale <- sourceIdentity "stale source"
      readScenarioReport root binding {scenarioSource = stale}
        `shouldReturn` Left (ScenarioStoreCodec ScenarioReportBindingMismatch)
      foreignScope <- either (fail . show) pure (deploymentScope "/foreign" Test "run" 26443)
      readScenarioReport root binding {scenarioScope = foreignScope}
        `shouldReturn` Left ScenarioStoreUnsafe

  it "refuses a report changed while independent observations run" $
    withSystemTempDirectory "prodbox-scenario-store-changed" $ \root -> do
      createDirectoryIfMissing True (root </> ".build")
      (binding, required, report, independent) <- fixtureAt root
      writeScenarioReport root report `shouldReturn` Right ()
      let directory = root </> ".build" </> "scenario-evidence" </> scenarioRunId binding
          path = directory </> ("phase-1-case-1-operation-" ++ scenarioOperationId binding ++ ".json")
      changed <- either (fail . show) pure (encodeScenarioReport report {reportPrimary = PrimaryFailed})
      validateStoredScenarioReport
        root
        binding
        required
        (ByteString.writeFile path changed >> pure (Just independent))
        `shouldReturn` Left (ScenarioStoreReadFailure ScenarioStoreChanged)
      readScenarioReport root binding `shouldReturn` Right report {reportPrimary = PrimaryFailed}

  it "refuses a report bound to a different project before touching either store" $
    withSystemTempDirectory "prodbox-scenario-store-project" $ \root ->
      withSystemTempDirectory "prodbox-scenario-store-other" $ \foreignRoot -> do
        createDirectoryIfMissing True (root </> ".build")
        createDirectoryIfMissing True (foreignRoot </> ".build")
        (binding, _, report, _) <- fixtureAt foreignRoot
        writeScenarioReport root report `shouldReturn` Left ScenarioStoreUnsafe
        readScenarioReport root binding `shouldReturn` Left ScenarioStoreUnsafe
        doesDirectoryExist (root </> ".build" </> "scenario-evidence") `shouldReturn` False
        doesDirectoryExist (foreignRoot </> ".build" </> "scenario-evidence") `shouldReturn` False

  it "refuses foreign store links and leaves the foreign marker unchanged" $
    withSystemTempDirectory "prodbox-scenario-store-link" $ \root ->
      withSystemTempDirectory "prodbox-scenario-store-foreign" $ \foreignRoot -> do
        createDirectoryIfMissing True (root </> ".build")
        writeFile (foreignRoot </> "marker") "unchanged"
        createSymbolicLink foreignRoot (root </> ".build" </> "scenario-evidence")
        (_, _, report, _) <- fixtureAt root
        result <- writeScenarioReport root report
        result `shouldBe` Left ScenarioStoreUnobservable
        readFile (foreignRoot </> "marker") `shouldReturn` "unchanged"

  it "allows only one concurrent publication for the same report" $
    withSystemTempDirectory "prodbox-scenario-store-race" $ \root -> do
      createDirectoryIfMissing True (root </> ".build")
      (binding, _, report, _) <- fixtureAt root
      (first, second) <- concurrently (writeScenarioReport root report) (writeScenarioReport root report)
      length (filter (== Right ()) [first, second]) `shouldBe` 1
      let refused = filter (/= Right ()) [first, second]
      refused
        `shouldSatisfy` (`elem` [[Left ScenarioStorePending], [Left ScenarioStoreExists], [Left ScenarioStoreIncomplete]])
      readScenarioReport root binding `shouldReturn` Right report

  it "preserves an incomplete pending report instead of replacing it" $
    withSystemTempDirectory "prodbox-scenario-store-pending" $ \root -> do
      (binding, _, report, _) <- fixtureAt root
      let directory = root </> ".build" </> "scenario-evidence" </> scenarioRunId binding
          pending = directory </> ("phase-1-case-1-operation-" ++ scenarioOperationId binding ++ ".json.pending")
      createDirectoryIfMissing True directory
      writeFile pending "incomplete"
      setFileMode pending 0o600
      writeScenarioReport root report `shouldReturn` Left ScenarioStorePending
      readFile pending `shouldReturn` "incomplete"

  it "refuses changed permissions and hard-linked report files" $
    withSystemTempDirectory "prodbox-scenario-store-file" $ \root -> do
      createDirectoryIfMissing True (root </> ".build")
      (binding, _, report, _) <- fixtureAt root
      writeScenarioReport root report `shouldReturn` Right ()
      let directory = root </> ".build" </> "scenario-evidence" </> scenarioRunId binding
      entries <- listDirectory directory
      file <- case entries of
        [entry] -> pure (directory </> entry)
        _ -> fail "expected one report"
      setFileMode file 0o666
      readScenarioReport root binding `shouldReturn` Left ScenarioStoreUnsafe
      setFileMode file 0o600
      createLink file (directory </> "alias")
      readScenarioReport root binding `shouldReturn` Left ScenarioStoreUnsafe

  it "compares decoded bytes with a separately supplied observation" $ do
    (binding, required, report, independent) <- fixture
    encoded <- either (fail . show) pure (encodeScenarioReport report)
    validateScenarioReportBytes binding required (Just encoded) (Just independent)
      `shouldBe` Right EvidenceChecksSatisfied
    validateScenarioReportBytes binding required Nothing (Just independent)
      `shouldBe` Left (ScenarioValidationComparison EvidenceReportMissing)
    validateScenarioReportBytes binding required (Just encoded) Nothing
      `shouldBe` Left (ScenarioValidationComparison EvidenceIndependentObservationMissing)
    let noObservations = report {reportPrimary = PrimaryIncomplete, reportObservations = []}
    incompleteBytes <- either (fail . show) pure (encodeScenarioReport noObservations)
    decodeScenarioReport binding incompleteBytes `shouldBe` Right noObservations
    validateScenarioReportBytes
      binding
      required
      (Just incompleteBytes)
      (Just independent {independentPrimary = PrimaryIncomplete})
      `shouldBe` Left (ScenarioValidationComparison EvidenceObservationNamesInvalid)
    validateScenarioReportBytes
      binding
      required
      (Just encoded)
      (Just independent {independentCleanup = CleanupUnobservable})
      `shouldBe` Left (ScenarioValidationComparison EvidenceOutcomeMismatch)
    stale <-
      either
        (fail . show)
        pure
        (encodeScenarioReport report {reportBinding = binding {scenarioRunId = replicate 32 'd'}})
    validateScenarioReportBytes binding required (Just stale) (Just independent)
      `shouldBe` Left (ScenarioValidationCodec ScenarioReportBindingMismatch)

  it "round-trips bounded canonical reports without accepting a foreign binding" $ do
    (binding, _, report, _) <- fixture
    encoded <- either (fail . show) pure (encodeScenarioReport report)
    decodeScenarioReport binding encoded `shouldBe` Right report
    let failed = report {reportPrimary = PrimaryFailed, reportCleanup = CleanupUnobservable}
    failedBytes <- either (fail . show) pure (encodeScenarioReport failed)
    decodeScenarioReport binding failedBytes `shouldBe` Right failed
    foreignScope <- either (fail . show) pure (deploymentScope "/foreign" Test "run" 26443)
    foreignBytes <-
      either
        (fail . show)
        pure
        (encodeScenarioReport report {reportBinding = binding {scenarioScope = foreignScope}})
    decodeScenarioReport binding foreignBytes `shouldBe` Left ScenarioReportBindingMismatch
    staleBytes <-
      either
        (fail . show)
        pure
        (encodeScenarioReport report {reportBinding = binding {scenarioRunId = replicate 32 'd'}})
    decodeScenarioReport binding staleBytes `shouldBe` Left ScenarioReportBindingMismatch

  it "rejects missing, duplicate, noncanonical and oversized report bytes" $ do
    (binding, _, report, _) <- fixture
    encoded <- either (fail . show) pure (encodeScenarioReport report)
    decodeScenarioReport binding "" `shouldBe` Left ScenarioReportMalformed
    decodeScenarioReport binding (ByteString.take 20 encoded) `shouldBe` Left ScenarioReportMalformed
    decodeScenarioReport binding (encoded <> "\n") `shouldBe` Left ScenarioReportMalformed
    let duplicateSchema = "{\"schema\":1," <> ByteString.drop 1 encoded
    decodeScenarioReport binding duplicateSchema `shouldBe` Left ScenarioReportMalformed
    decodeScenarioReport binding (ByteString8.replicate 65537 'x')
      `shouldBe` Left ScenarioReportTooLarge
    encodeScenarioReport
      report {reportObservations = reportObservations report ++ take 1 (reportObservations report)}
      `shouldBe` Left ScenarioReportInvalidObservations

  it "requires a report and a separate outer observation" $ do
    (binding, required, report, independent) <- fixture
    compareScenarioEvidence binding required Nothing (Just independent)
      `shouldBe` Left EvidenceReportMissing
    compareScenarioEvidence binding required (Just report) Nothing
      `shouldBe` Left EvidenceIndependentObservationMissing
    compareScenarioEvidence binding required (Just report) (Just independent)
      `shouldBe` Right EvidenceChecksSatisfied
    compareScenarioEvidence
      binding
      required
      (Just report {reportTiming = ScenarioTiming 11 19 29})
      (Just independent)
      `shouldBe` Right EvidenceChecksSatisfied

  it "rejects stale source, binary, generation, run and operation bindings" $ do
    (binding, required, report, independent) <- fixture
    staleSource <- sourceIdentity "different source"
    foreignScope <- either (fail . show) pure (deploymentScope "/foreign" Test "run" 26443)
    let staleBindings =
          [ binding {scenarioSource = staleSource}
          , binding {scenarioBinary = hashPublicEvidence "different binary"}
          , binding {scenarioArtifacts = [("kind.node", hashPublicEvidence "different image")]}
          , binding {scenarioPublicConfig = hashPublicEvidence "different public configuration"}
          , binding {scenarioPublicCommand = hashPublicEvidence "different public command"}
          , binding {scenarioBudget = (scenarioBudget binding) {maximumMemoryBytes = 2}}
          , binding {scenarioScope = foreignScope}
          , binding {scenarioGeneration = replicate 32 'b'}
          , binding {scenarioRunId = replicate 32 'c'}
          , binding {scenarioOperationId = replicate 32 'd'}
          , binding {scenarioClockEpoch = replicate 32 'e'}
          , binding {scenarioCase = 2}
          ]
    mapM_
      ( \stale -> do
          compareScenarioEvidence binding required (Just report {reportBinding = stale}) (Just independent)
            `shouldBe` Left EvidenceReportBindingMismatch
          compareScenarioEvidence
            binding
            required
            (Just report)
            (Just independent {independentBinding = stale})
            `shouldBe` Left EvidenceIndependentBindingMismatch
      )
      staleBindings

  it "rejects a fabricated success and preserves failed or unobservable outcomes" $ do
    (binding, required, report, independent) <- fixture
    compareScenarioEvidence
      binding
      required
      (Just report)
      (Just independent {independentPrimary = PrimaryFailed})
      `shouldBe` Left EvidenceOutcomeMismatch
    compareScenarioEvidence
      binding
      required
      (Just report)
      (Just independent {independentCleanup = CleanupUnobservable})
      `shouldBe` Left EvidenceOutcomeMismatch
    let failedReport = report {reportPrimary = PrimaryFailed}
        failedObserver = independent {independentPrimary = PrimaryFailed}
    compareScenarioEvidence binding required (Just failedReport) (Just failedObserver)
      `shouldBe` Right EvidenceChecksUnmet
    let missingCleanup = report {reportCleanup = CleanupUnobservable}
        unobservedCleanup = independent {independentCleanup = CleanupUnobservable}
    compareScenarioEvidence binding required (Just missingCleanup) (Just unobservedCleanup)
      `shouldBe` Right EvidenceChecksUnmet

  it "requires every distinct observation and rejects a fabricated observation" $ do
    (binding, required, report, independent) <- fixture
    let one = take 1 (reportObservations report)
        duplicate = reportObservations report ++ one
        violated =
          [ ScenarioObservation "context.scope" ObservationViolated
          , ScenarioObservation "cleanup.absence" ObservationSatisfied
          ]
    compareScenarioEvidence binding required (Just report {reportObservations = one}) (Just independent)
      `shouldBe` Left EvidenceObservationSetMismatch
    compareScenarioEvidence
      binding
      required
      (Just report {reportObservations = duplicate})
      (Just independent)
      `shouldBe` Left EvidenceObservationNamesInvalid
    compareScenarioEvidence
      binding
      required
      (Just report)
      (Just independent {independentObservations = duplicate})
      `shouldBe` Left EvidenceObservationNamesInvalid
    compareScenarioEvidence
      binding
      required
      (Just report)
      (Just independent {independentObservations = violated})
      `shouldBe` Left EvidenceObservationMismatch
    let unavailable =
          [ ScenarioObservation "context.scope" ObservationUnavailable
          , ScenarioObservation "cleanup.absence" ObservationSatisfied
          ]
    compareScenarioEvidence
      binding
      required
      (Just report {reportObservations = unavailable})
      (Just independent {independentObservations = unavailable})
      `shouldBe` Right EvidenceChecksUnmet

  it "rejects invalid requirements, timing and operation identities" $ do
    (binding, required, report, independent) <- fixture
    compareScenarioEvidence binding [] (Just report) (Just independent)
      `shouldBe` Left EvidenceInvalidRequirements
    compareScenarioEvidence binding (required ++ required) (Just report) (Just independent)
      `shouldBe` Left EvidenceInvalidRequirements
    compareScenarioEvidence
      binding
      (map (Text.pack . show) ([1 .. 257] :: [Int]))
      (Just report)
      (Just independent)
      `shouldBe` Left EvidenceInvalidRequirements
    compareScenarioEvidence binding {scenarioRunId = "bad"} required (Just report) (Just independent)
      `shouldBe` Left EvidenceInvalidExpectedBinding
    compareScenarioEvidence
      binding {scenarioBudget = (scenarioBudget binding) {cleanupDeadlineNanos = 100}}
      required
      (Just report)
      (Just independent)
      `shouldBe` Left EvidenceInvalidExpectedBinding
    let late = ScenarioTiming 10 20 401
    compareScenarioEvidence
      binding
      required
      (Just report {reportTiming = late})
      (Just independent {independentTiming = late})
      `shouldBe` Right EvidenceChecksUnmet
    let latePrimary = ScenarioTiming 10 201 250
        timedOut = report {reportTiming = latePrimary, reportPrimary = PrimaryIncomplete}
        observedTimeout = independent {independentTiming = latePrimary, independentPrimary = PrimaryIncomplete}
    compareScenarioEvidence binding required (Just timedOut) (Just observedTimeout)
      `shouldBe` Right EvidenceChecksUnmet
    compareScenarioEvidence
      binding
      required
      (Just report)
      (Just independent {independentTiming = late})
      `shouldBe` Right EvidenceChecksUnmet
    let atDeadline = ScenarioTiming 10 200 400
    compareScenarioEvidence
      binding
      required
      (Just report {reportTiming = atDeadline})
      (Just independent {independentTiming = atDeadline})
      `shouldBe` Right EvidenceChecksSatisfied
    compareScenarioEvidence
      binding
      required
      (Just report {reportTiming = ScenarioTiming 10 21 20})
      (Just independent)
      `shouldBe` Left EvidenceTimingInvalid
    compareScenarioEvidence
      binding
      required
      (Just report {reportTiming = ScenarioTiming 9 20 30})
      (Just independent)
      `shouldBe` Left EvidenceTimingMismatch

fixture :: IO (ScenarioBinding, [Text], ScenarioReport, IndependentScenarioObservation)
fixture = fixtureAt "/fixture"

fixtureAt
  :: FilePath -> IO (ScenarioBinding, [Text], ScenarioReport, IndependentScenarioObservation)
fixtureAt project = do
  scope <- either (fail . show) pure (deploymentScope project Test "run" 26443)
  source <- sourceIdentity "public source"
  let binding =
        ScenarioBinding
          1
          1
          scope
          (replicate 32 'a')
          (replicate 32 'b')
          (replicate 32 'c')
          (replicate 32 'd')
          source
          (hashPublicEvidence "public binary")
          [("kind.node", hashPublicEvidence "public node image")]
          (hashPublicEvidence "public config")
          (hashPublicEvidence "public command")
          (ScenarioBudget 200 400 1048576 1000 0)
      timing = ScenarioTiming 10 20 30
      required = ["context.scope", "cleanup.absence"]
      values = map (`ScenarioObservation` ObservationSatisfied) required
      report = ScenarioReport binding timing PrimarySucceeded CleanupConfirmed values
      independent = IndependentScenarioObservation binding timing PrimarySucceeded CleanupConfirmed values
  pure (binding, required, report, independent)

sourceIdentity :: Text -> IO SourceIdentity
sourceIdentity source = do
  headId <- either (fail . show) pure (mkGitHead "0123456789012345678901234567890123456789")
  either (fail . show) pure $
    mkSourceIdentity
      headId
      WorktreeDirty
      []
      [SourceCandidate "src/Fixture.hs" ManifestRegularFile 0o644 (TextEncoding.encodeUtf8 source)]

isSnapshotWritten :: MutationSnapshotWriteResult -> Bool
isSnapshotWritten result = case result of
  MutationSnapshotWritten _ -> True
  _ -> False
