module HostCleanupRunner
  ( hostCleanupRunnerSuite
  )
where

import Prodbox.Lifecycle.HostCleanupRunner
import TestSupport

hostCleanupRunnerSuite :: SuiteBuilder ()
hostCleanupRunnerSuite =
  describe "lifecycle-owned terminal host runner" $ do
    it
      "keeps exact success, response-loss replay, no-repeat, and lease fencing behind a fixed regression"
      $ do
        regression <- expectIoRight fixedHostCleanupRunnerRegression
        hostCleanupRunnerRegressionUnboundRefused regression `shouldBe` True
        hostCleanupRunnerRegressionFullTopology regression `shouldBe` True
        hostCleanupRunnerRegressionResponseLossRecovered regression `shouldBe` True
        hostCleanupRunnerRegressionConfirmedAbsenceNotRepeated regression
          `shouldBe` True
        hostCleanupRunnerRegressionWrongReadyRefused regression `shouldBe` True
        hostCleanupRunnerRegressionMissingCompletionRefused regression `shouldBe` True
        hostCleanupRunnerRegressionConcurrentLeaseFenced regression `shouldBe` True

    it "exports no completion-readback constructor or raw evidence remint input" $ do
      source <- readFile "src/Prodbox/Lifecycle/HostCleanupRunner.hs"
      facade <- exportedHeader source
      facade `shouldContain` "HostCleanupCompletionReadBack"
      facade `shouldNotContain` "HostCleanupCompletionReadBack (..)"
      facade `shouldNotContain` "CascadeCompletionReceiptObservation"
      facade `shouldNotContain` "mkLocalUninstallEvidence"
      facade `shouldNotContain` "mkCascadeCompleteEvidence"
      source `shouldNotContain` "DurableReadyToUninstallBinding"
      source `shouldNotContain` "decodeDurableReadyToUninstallBinding"
      source `shouldContain` "restoreObservedHostCleanupReady"
      source `shouldContain` "withHostCleanupExecutionLease"

expectIoRight :: (Show err) => IO (Either err value) -> IO value
expectIoRight action = do
  result <- action
  case result of
    Left err -> do
      expectationFailure (show err)
      error "unreachable"
    Right value -> pure value

exportedHeader :: String -> IO String
exportedHeader source = case break (== "where") (lines source) of
  (_, []) -> do
    expectationFailure "HostCleanupRunner export list has no where"
    pure ""
  (header, _) -> pure (unlines header)
