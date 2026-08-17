module LifecycleTeardownRecoveryPlaneInterpreter
  ( lifecycleTeardownRecoveryPlaneInterpreterSuite
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

lifecycleTeardownRecoveryPlaneInterpreterSuite :: SuiteBuilder ()
lifecycleTeardownRecoveryPlaneInterpreterSuite =
  describe "descriptor-bound recovery-plane interpreter" $ do
    it "binds Establish to the exact post-Begin descriptor context" $ do
      regression <- fixedRegression
      recoveryPlaneInterpreterEstablishExact regression `shouldBe` True

    it "commits then independently reads back the exact initial evidence" $ do
      regression <- fixedRegression
      recoveryPlaneInterpreterInitialReadBackExact regression `shouldBe` True
      recoveryPlaneInterpreterCompleteObservationSet regression `shouldBe` True

    it "restores the immutable initial binding before final disposition read-back" $ do
      regression <- fixedRegression
      recoveryPlaneInterpreterFinalReadBackExact regression `shouldBe` True

    it "refuses raw execution and a different durable predecessor attempt" $ do
      regression <- fixedRegression
      recoveryPlaneInterpreterRawExecutionRefused regression `shouldBe` True
      recoveryPlaneInterpreterWrongPredecessorRefused regression `shouldBe` True

    it "reconstructs two indexed surfaces after restart without a side map" $ do
      regression <- fixedRegression
      recoveryPlaneInterpreterTwoSurfaceRestartDispatch regression `shouldBe` True

    it "keeps constructors, observers, repository writes, and raw facts hidden" $ do
      regression <- fixedRegression
      recoveryPlaneInterpreterOpacityClosed regression `shouldBe` True
      facade <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneInterpreter.hs"
      let header = moduleHeader facade
      mapM_
        (header `shouldNotContain`)
        [ "RecoveryPlaneInterpreter (.."
        , "RecoveryPlaneEstablishBoundary"
        , "RecoveryPlaneEstablishResult"
        , "RecoveryPlaneComponentObserver"
        , "RecoveryPlaneRawComponent"
        , "RecoveryPlaneRepositoryClient"
        , "recoveryPlaneInterpreterInternal"
        , "newFixedRecoveryPlaneRepositoryClientInternal"
        ]
      execution <- readFile "src/Prodbox/Lifecycle/Teardown/Execution.hs"
      execution `shouldNotContain` "data RecoveryPlaneObservation"
      execution `shouldNotContain` "TeardownRecoveryPlaneObservation"
      execution `shouldContain` "TeardownRecoveryPlaneInitialReadBack"
      execution `shouldContain` "TeardownRecoveryPlaneFinalEvidence"
      execution
        `shouldContain` "runCompiledTeardownNodeWithDescriptorContext"

      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter.Internal"
      importers
        `shouldBe` [ "src/Prodbox/ControlPlane/LocalRke2HostObservationTransport/Internal.hs"
                   , "src/Prodbox/ControlPlane/RecoveryPlaneHostRuntime/Internal.hs"
                   , "src/Prodbox/ControlPlane/Runtime.hs"
                   , "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneComponentObserver/Internal.hs"
                   , "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneInterpreter.hs"
                   ]

      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal
        `shouldContain` "Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter.Internal"

fixedRegression :: IO RecoveryPlaneInterpreterRegression
fixedRegression = do
  result <- fixedRecoveryPlaneInterpreterRegression
  case result of
    Left err -> do
      expectationFailure (show err)
      fail "invalid recovery-plane interpreter regression"
    Right regression -> pure regression

moduleHeader :: String -> String
moduleHeader = unlines . takeWhile (/= "where") . lines

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- sourceFiles root
  sort <$> filterM containsImport paths
 where
  containsImport path = do
    contents <- readFile path
    pure (importNeedle `isInfixOf` contents)

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles path = do
  directory <- doesDirectoryExist path
  if directory
    then do
      children <- listDirectory path
      concat <$> mapM (sourceFiles . (path </>)) children
    else pure [path | ".hs" `isSuffixOf` path]
