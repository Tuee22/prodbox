{-# LANGUAGE OverloadedStrings #-}

module LifecycleTestArtifactCleanup
  ( lifecycleTestArtifactCleanupSuite
  , fixturePlan
  )
where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupRunId
  , mkCleanupDigest
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.TestArtifactCleanup
import TestSupport

lifecycleTestArtifactCleanupSuite :: SuiteBuilder ()
lifecycleTestArtifactCleanupSuite =
  describe "lifecycle-owned typed test artifact cleanup" $ do
    it "refines exactly one generated config and this run's .test-data root" $ do
      testArtifactCleanupPlanRunId fixturePlan `shouldBe` fixtureRunId
      testArtifactCleanupPlanGraphDigest fixturePlan `shouldBe` fixtureGraphDigest
      testArtifactCleanupPlanRepoRoot fixturePlan `shouldBe` fixtureRepoRoot
      let intents = NonEmpty.toList (testArtifactCleanupPlanIntents fixturePlan)
      map testArtifactIntentKind intents
        `shouldBe` [TestArtifactGeneratedRunConfig, TestArtifactThisRunData]
      map testArtifactIntentPath intents
        `shouldBe` [fixtureConfigPath, fixtureDataPath]
      map testArtifactIntentRunId intents
        `shouldBe` replicate 2 fixtureRunId
      mkTestArtifactCleanupPlan
        fixtureRepoRoot
        fixtureRunId
        fixtureGraphDigest
        (fixtureRepoRoot <> "/.build/prodbox.test.dhall")
        fixtureDataPath
        `shouldBe` Left
          ( TestArtifactGeneratedConfigNameInvalid
              (fixtureRepoRoot <> "/.build/prodbox.test.dhall")
          )
      mkTestArtifactCleanupPlan
        fixtureRepoRoot
        fixtureRunId
        fixtureGraphDigest
        fixtureConfigPath
        (fixtureRepoRoot <> "/.data/qualification")
        `shouldBe` Left
          ( TestArtifactDataOutsideThisRunRoot
              (fixtureRepoRoot <> "/.data/qualification")
          )
      mkTestArtifactCleanupPlan
        fixtureRepoRoot
        fixtureRunId
        fixtureGraphDigest
        fixtureConfigPath
        (fixtureRepoRoot <> "/.test-data/../.data")
        `shouldBe` Left
          ( TestArtifactPathContainsParentTraversal
              TestArtifactThisRunData
              (fixtureRepoRoot <> "/.test-data/../.data")
          )

    it "keeps positive, response-loss, mismatch, and fail-closed behavior behind a fixed regression" $ do
      regression <- expectIoRight fixedTestArtifactCleanupRegression
      testArtifactCleanupRegressionResponseLossResolved regression `shouldBe` True
      testArtifactCleanupRegressionRegistrationRefused regression `shouldBe` True
      testArtifactCleanupRegressionPositiveComplete regression `shouldBe` True
      testArtifactCleanupRegressionAcceptedDeleteRefused regression `shouldBe` True
      testArtifactCleanupRegressionMissingProofRefused regression `shouldBe` True
      testArtifactCleanupRegressionWrongRunRefused regression `shouldBe` True
      testArtifactCleanupRegressionWrongGraphRefused regression `shouldBe` True
      testArtifactCleanupRegressionPrimaryFailurePreserved regression `shouldBe` True

    it "keeps proof constructors private and owns no generic graph or raw delete" $ do
      source <- readFile "src/Prodbox/Lifecycle/TestArtifactCleanup.hs"
      source `shouldNotContain` "LocalClusterAbsent (..)"
      source `shouldNotContain` "TestArtifactIntent (..)"
      source `shouldNotContain` "TestArtifactCleanupPlan (..)"
      source `shouldNotContain` "mkCleanupGraph"
      source `shouldNotContain` "mkCleanupRunId"
      source `shouldNotContain` "ManagedCleanupPlan"
      source `shouldNotContain` "removePathForcibly"
      source `shouldNotContain` "finally"
      source `shouldContain` "CascadeCompleteEvidence"

fixtureRepoRoot, fixtureConfigPath, fixtureDataPath :: FilePath
fixtureRepoRoot = "/tmp/prodbox-artifact-fixture"
fixtureConfigPath = fixtureRepoRoot <> "/.build/prodbox.dhall"
fixtureDataPath = fixtureRepoRoot <> "/.test-data/unit/variant-1"

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "artifact-cleanup/run-one")

fixtureGraphDigest :: CleanupDigest
fixtureGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "a"))

fixturePlan :: TestArtifactCleanupPlan
fixturePlan =
  mustRight
    ( mkTestArtifactCleanupPlan
        fixtureRepoRoot
        fixtureRunId
        fixtureGraphDigest
        fixtureConfigPath
        fixtureDataPath
    )

expectIoRight :: (Show err) => IO (Either err value) -> IO value
expectIoRight action = do
  result <- action
  pure (mustRight result)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
