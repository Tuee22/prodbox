{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTestArtifactIntentJournal
  ( lifecycleTestArtifactIntentJournalSuite
  )
where

import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.Text qualified as Text
import LifecycleTestArtifactCleanup
  ( fixturePlan
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupRunId
  , cleanupRunIdText
  , mkCleanupDigest
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.TestArtifactCleanup
import Prodbox.Lifecycle.TestArtifactIntentJournal
import System.Directory
  ( createDirectory
  , createDirectoryLink
  , createFileLink
  , doesDirectoryExist
  , doesFileExist
  )
import System.FilePath (takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( FileStatus
  , accessModes
  , fileMode
  , getFileStatus
  , intersectFileModes
  , isRegularFile
  , ownerModes
  , ownerReadMode
  , ownerWriteMode
  , setFileMode
  , unionFileModes
  )
import System.Posix.Types (FileMode)
import TestSupport

lifecycleTestArtifactIntentJournalSuite :: SuiteBuilder ()
lifecycleTestArtifactIntentJournalSuite =
  describe "host-durable test artifact intent journal" $ do
    it "uses a bounded canonical CBOR roundtrip for the exact typed plan" $
      withFixture "codec" $ \_ plan -> do
        let encoded = expectRight (encodeTestArtifactIntentPlan plan)
        ByteString.length encoded
          `shouldSatisfy` (<= maximumTestArtifactIntentJournalBytes)
        decodeTestArtifactIntentPlan encoded `shouldBe` Right plan
        let pathSetDigest = expectRight (testArtifactIntentPathSetDigest plan)
            movedPlan =
              planForCoordinates
                (testArtifactCleanupPlanRepoRoot plan ++ "-moved")
                (testArtifactCleanupPlanRunId plan)
                (testArtifactCleanupPlanGraphDigest plan)
        Text.length (testArtifactPathSetDigestText pathSetDigest)
          `shouldBe` 64
        testArtifactIntentPathSetDigest movedPlan
          `shouldSatisfy` (/= Right pathSetDigest)
        decodeTestArtifactIntentPlan (ByteString.snoc encoded 0)
          `shouldSatisfy` isNonCanonicalOrInvalid
        decodeTestArtifactIntentPlan
          (ByteString.replicate (maximumTestArtifactIntentJournalBytes + 1) 0)
          `shouldBe` Left
            ( TestArtifactIntentJournalEncodedTooLarge
                (maximumTestArtifactIntentJournalBytes + 1)
                maximumTestArtifactIntentJournalBytes
            )
        let repoRoot = testArtifactCleanupPlanRepoRoot plan
            hugePlan =
              expectRight
                ( mkTestArtifactCleanupPlan
                    repoRoot
                    (testArtifactCleanupPlanRunId plan)
                    (testArtifactCleanupPlanGraphDigest plan)
                    (repoRoot </> ".build" </> "prodbox.dhall")
                    ( repoRoot
                        </> ".test-data"
                        </> replicate maximumTestArtifactIntentJournalBytes 'x'
                    )
                )
        encodeTestArtifactIntentPlan hugePlan
          `shouldSatisfy` isEncodedTooLarge

    it "derives stable secret-free filenames from a canonical run digest" $
      withFixture "coordinate" $ \store plan -> do
        let runId = testArtifactCleanupPlanRunId plan
            filename = takeFileName (testArtifactIntentJournalPath store runId)
            rawRunId = Text.unpack (cleanupRunIdText runId)
        filename
          `shouldSatisfy` (Text.isPrefixOf "active-" . Text.pack)
        filename
          `shouldSatisfy` (Text.isSuffixOf ".cbor" . Text.pack)
        filename `shouldNotContain` rawRunId
        length filename `shouldBe` length ("active-" ++ replicate 64 '0' ++ ".cbor")
        testArtifactIntentJournalPath store runId
          `shouldBe` testArtifactIntentJournalPath store runId
        testArtifactIntentJournalPath store runId
          `shouldNotBe` testArtifactIntentJournalPath
            store
            otherRunId
        testArtifactIntentJournalRetiredPath store plan
          `shouldSatisfy` isRight
        mkTestArtifactIntentJournalStore "relative/root"
          `shouldBe` Left
            ( TestArtifactIntentJournalStoreInvalid
                "retained root must be absolute"
            )
        mkTestArtifactIntentJournalStore "/"
          `shouldBe` Left
            ( TestArtifactIntentJournalStoreInvalid
                "retained root must not be the filesystem root"
            )

    it "commits through the cleanup adapter before any cluster or artifact path exists" $
      withFixture "adapter" $ \store plan -> do
        let journal = testArtifactIntentJournalAdapter store
            repoRoot = testArtifactCleanupPlanRepoRoot plan
            runId = testArtifactCleanupPlanRunId plan
        doesDirectoryExist repoRoot `shouldReturn` False
        commitTestArtifactIntents journal plan `shouldReturn` Right ()
        observeTestArtifactIntents journal runId
          `shouldReturn` Right (Just plan)
        doesDirectoryExist repoRoot `shouldReturn` False
        activeStatus <- getFileStatus (testArtifactIntentJournalPath store runId)
        isRegularFile activeStatus `shouldBe` True
        exactAccessMode activeStatus `shouldBe` ownerFileMode
        directoryStatus <- getFileStatus (testArtifactIntentJournalDirectory store)
        exactAccessMode directoryStatus `shouldBe` ownerModes

    it "admits exact replay but never replaces a stale same-run plan" $
      withFixture "replay" $ \store plan -> do
        commitTestArtifactIntentPlan store plan `shouldReturn` Right ()
        let activePath =
              testArtifactIntentJournalPath
                store
                (testArtifactCleanupPlanRunId plan)
        original <- ByteString.readFile activePath
        commitTestArtifactIntentPlan store plan `shouldReturn` Right ()
        ByteString.readFile activePath `shouldReturn` original
        let conflicting =
              planForCoordinates
                (fixtureRoot plan)
                (testArtifactCleanupPlanRunId plan)
                otherGraphDigest
        commitTestArtifactIntentPlan store conflicting
          `shouldReturn` Left TestArtifactIntentJournalActiveConflict
        ByteString.readFile activePath `shouldReturn` original
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Right (Just plan)
        let copiedPath = testArtifactIntentJournalPath store otherRunId
        ByteString.writeFile copiedPath original
        setFileMode copiedPath ownerFileMode
        observeTestArtifactIntentPlan store otherRunId
          `shouldReturn` Left
            ( TestArtifactIntentJournalRunCoordinateMismatch
                otherRunId
                (testArtifactCleanupPlanRunId plan)
            )

    it "recovers an exact pre-rename temporary but never truncates a foreign one" $ do
      withFixture "temporary-replay" $ \store plan -> do
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Right Nothing
        let temporaryPath =
              testArtifactIntentJournalTemporaryPath
                store
                (testArtifactCleanupPlanRunId plan)
        ByteString.writeFile
          temporaryPath
          (expectRight (encodeTestArtifactIntentPlan plan))
        setFileMode temporaryPath ownerFileMode
        commitTestArtifactIntentPlan store plan `shouldReturn` Right ()
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Right (Just plan)
      withFixture "temporary-conflict" $ \store plan -> do
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Right Nothing
        let temporaryPath =
              testArtifactIntentJournalTemporaryPath
                store
                (testArtifactCleanupPlanRunId plan)
            foreignBytes = "foreign-temporary-content"
        ByteString.writeFile temporaryPath foreignBytes
        setFileMode temporaryPath ownerFileMode
        commitTestArtifactIntentPlan store plan `shouldSatisfyIO` isLeft
        ByteString.readFile temporaryPath `shouldReturn` foreignBytes
        doesFileExist (activePathFor store plan) `shouldReturn` False

    it "fails closed on corrupt, oversized, permissive-mode, and nonregular active files" $ do
      withFixture "corrupt" $ \store plan -> do
        commitTestArtifactIntentPlan store plan `shouldReturn` Right ()
        let activePath = activePathFor store plan
            corrupt = "not-canonical-cbor"
        ByteString.writeFile activePath corrupt
        setFileMode activePath ownerFileMode
        commitTestArtifactIntentPlan store plan `shouldSatisfyIO` isLeft
        ByteString.readFile activePath `shouldReturn` corrupt
      withFixture "oversized" $ \store plan -> do
        commitTestArtifactIntentPlan store plan `shouldReturn` Right ()
        ByteString.writeFile
          (activePathFor store plan)
          (ByteString.replicate (maximumTestArtifactIntentJournalBytes + 1) 0)
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldSatisfyIO` isEncodedTooLarge
      withFixture "mode" $ \store plan -> do
        commitTestArtifactIntentPlan store plan `shouldReturn` Right ()
        let activePath = activePathFor store plan
        setFileMode activePath ownerModes
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Left
            (TestArtifactIntentJournalFileModeInvalid activePath)
      withFixture "nonregular" $ \store plan -> do
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Right Nothing
        let activePath = activePathFor store plan
        createDirectory activePath
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Left
            (TestArtifactIntentJournalFileNotRegular activePath)

    it "uses nofollow for active and atomic temporary paths" $ do
      withFixture "active-symlink" $ \store plan -> do
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Right Nothing
        let outside = testArtifactIntentJournalRetainedRoot store </> "outside"
        ByteString.writeFile outside "preserve-active-target"
        createFileLink outside (activePathFor store plan)
        commitTestArtifactIntentPlan store plan `shouldSatisfyIO` isIoFailure
        ByteString.readFile outside `shouldReturn` "preserve-active-target"
      withFixture "temporary-symlink" $ \store plan -> do
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId plan)
          `shouldReturn` Right Nothing
        let outside = testArtifactIntentJournalRetainedRoot store </> "outside"
            temporaryPath =
              testArtifactIntentJournalTemporaryPath
                store
                (testArtifactCleanupPlanRunId plan)
        ByteString.writeFile outside "preserve-temporary-target"
        createFileLink outside temporaryPath
        commitTestArtifactIntentPlan store plan `shouldSatisfyIO` isIoFailure
        ByteString.readFile outside `shouldReturn` "preserve-temporary-target"
        doesFileExist (activePathFor store plan) `shouldReturn` False

    it "rejects symlinked journal directories and roots resolving to slash" $ do
      withSystemTempDirectory "prodbox-artifact-journal-directory-link" $ \root -> do
        let store = expectRight (mkTestArtifactIntentJournalStore root)
            outside = root </> "outside-directory"
        createDirectory outside
        createDirectoryLink outside (testArtifactIntentJournalDirectory store)
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId fixturePlan)
          `shouldSatisfyIO` isStoreInvalid
      withSystemTempDirectory "prodbox-artifact-journal-root-link" $ \root -> do
        let rootAlias = root </> "root-alias"
        createDirectoryLink "/" rootAlias
        let store = expectRight (mkTestArtifactIntentJournalStore rootAlias)
        observeTestArtifactIntentPlan store (testArtifactCleanupPlanRunId fixturePlan)
          `shouldReturn` Left
            ( TestArtifactIntentJournalStoreInvalid
                "retained root resolves to the filesystem root"
            )

    it "keeps proof-bound retirement and exact response-loss replay behind a fixed regression" $ do
      regression <- expectIoRight fixedTestArtifactIntentJournalRegression
      testArtifactIntentJournalRegressionWrongRunRefused regression `shouldBe` True
      testArtifactIntentJournalRegressionWrongGraphRefused regression `shouldBe` True
      testArtifactIntentJournalRegressionPresentRefused regression `shouldBe` True
      testArtifactIntentJournalRegressionDurableRetirement regression `shouldBe` True
      testArtifactIntentJournalRegressionExactReplay regression `shouldBe` True

    it "exposes no phase or boolean retirement authority and owns no cluster effects" $ do
      source <-
        readFile "src/Prodbox/Lifecycle/TestArtifactIntentJournal.hs"
      source `shouldContain` "-> CascadeCompleteEvidence"
      source `shouldContain` "observeEveryArtifactAbsent expected"
      source `shouldNotContain` "HostCleanupIntentPhase"
      source `shouldNotContain` "kubectl"
      source `shouldNotContain` "KUBECONFIG"
      source `shouldNotContain` "removePathForcibly"

withFixture
  :: String
  -> (TestArtifactIntentJournalStore -> TestArtifactCleanupPlan -> IO ())
  -> IO ()
withFixture label action =
  withSystemTempDirectory ("prodbox-artifact-journal-" ++ label) $ \root -> do
    let store = expectRight (mkTestArtifactIntentJournalStore root)
        plan =
          planForCoordinates
            (root </> "repo")
            (testArtifactCleanupPlanRunId fixturePlan)
            (testArtifactCleanupPlanGraphDigest fixturePlan)
    action store plan

planForCoordinates
  :: FilePath
  -> CleanupRunId
  -> CleanupDigest
  -> TestArtifactCleanupPlan
planForCoordinates repoRoot runId graphDigest =
  expectRight
    ( mkTestArtifactCleanupPlan
        repoRoot
        runId
        graphDigest
        (repoRoot </> ".build" </> "prodbox.dhall")
        (repoRoot </> ".test-data" </> "suite" </> "variant-1")
    )

otherRunId :: CleanupRunId
otherRunId = expectRight (mkCleanupRunId "artifact-cleanup/run-two")

otherGraphDigest :: CleanupDigest
otherGraphDigest = expectRight (mkCleanupDigest (Text.replicate 64 "b"))

fixtureRoot :: TestArtifactCleanupPlan -> FilePath
fixtureRoot = testArtifactCleanupPlanRepoRoot

activePathFor
  :: TestArtifactIntentJournalStore
  -> TestArtifactCleanupPlan
  -> FilePath
activePathFor store plan =
  testArtifactIntentJournalPath store (testArtifactCleanupPlanRunId plan)

ownerFileMode :: FileMode
ownerFileMode = ownerReadMode `unionFileModes` ownerWriteMode

exactAccessMode :: FileStatus -> FileMode
exactAccessMode status = fileMode status `intersectFileModes` accessModes

isNonCanonicalOrInvalid
  :: Either TestArtifactIntentJournalError value -> Bool
isNonCanonicalOrInvalid result = case result of
  Left TestArtifactIntentJournalNonCanonical -> True
  Left TestArtifactIntentJournalDecodeInvalid {} -> True
  _ -> False

isEncodedTooLarge
  :: Either TestArtifactIntentJournalError value -> Bool
isEncodedTooLarge result = case result of
  Left TestArtifactIntentJournalEncodedTooLarge {} -> True
  _ -> False

isIoFailure :: Either TestArtifactIntentJournalError value -> Bool
isIoFailure result = case result of
  Left TestArtifactIntentJournalIoFailure {} -> True
  _ -> False

isStoreInvalid :: Either TestArtifactIntentJournalError value -> Bool
isStoreInvalid result = case result of
  Left TestArtifactIntentJournalStoreInvalid {} -> True
  _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

expectIoRight :: (Show err) => IO (Either err value) -> IO value
expectIoRight action = do
  result <- action
  pure (expectRight result)

shouldSatisfyIO :: (Show value) => IO value -> (value -> Bool) -> IO ()
shouldSatisfyIO action predicate = do
  value <- action
  value `shouldSatisfy` predicate

expectRight :: (Show err) => Either err value -> value
expectRight result = case result of
  Left err -> error (show err)
  Right value -> value
