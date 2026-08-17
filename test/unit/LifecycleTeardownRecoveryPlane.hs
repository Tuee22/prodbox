module LifecycleTeardownRecoveryPlane
  ( lifecycleTeardownRecoveryPlaneSuite
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.Lifecycle.Teardown.RecoveryPlane
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

lifecycleTeardownRecoveryPlaneSuite :: SuiteBuilder ()
lifecycleTeardownRecoveryPlaneSuite =
  describe "durable recovery-plane evidence boundary" $ do
    it "derives a canonical profile and separates the Target-Agent topology" $ do
      let regression = mustRight fixedRecoveryPlaneFixtureRegression
      recoveryPlaneFixtureProfileCanonical regression `shouldBe` True
      recoveryPlaneFixtureProfileTargetAgentSeparated regression `shouldBe` True
      recoveryPlaneFixtureIdentityCanonical regression `shouldBe` True
      recoveryPlaneFixtureDynamicProfileRestored regression `shouldBe` True

    it "requires one exact normalized fact for every profile component" $ do
      let regression = mustRight fixedRecoveryPlaneFixtureRegression
      recoveryPlaneFixtureExactCompletenessEnforced regression `shouldBe` True
      recoveryPlaneFixtureEveryFailureRefused regression `shouldBe` True
      recoveryPlaneFixtureDiagnosticsNormalized regression `shouldBe` True

    it "mints initial readiness only from a complete exact observation" $ do
      let regression = mustRight fixedRecoveryPlaneFixtureRegression
      recoveryPlaneFixtureInitialReadyExact regression `shouldBe` True
      recoveryPlaneFixtureCrossBindingRefused regression `shouldBe` True

    it "classifies fresh final state as Established, NotEstablished, or Lost" $ do
      let regression = mustRight fixedRecoveryPlaneFixtureRegression
      recoveryPlaneFixtureEstablishedFromReady regression `shouldBe` True
      recoveryPlaneFixtureEstablishedAfterInitialFailure regression `shouldBe` True
      recoveryPlaneFixtureNotEstablishedExact regression `shouldBe` True
      recoveryPlaneFixtureLostExact regression `shouldBe` True
      recoveryPlaneFixtureLostHidesReady regression `shouldBe` True

    it "keeps every identity, observation, and evidence minter package-private" $ do
      facade <- readFile "src/Prodbox/Lifecycle/Teardown/RecoveryPlane.hs"
      let header = moduleHeader facade
      mapM_
        (header `shouldNotContain`)
        [ "RecoveryPlaneRawComponentResult"
        , "RecoveryPlaneRawComponentObservation"
        , "RecoveryPlaneComponentObservationSet"
        , "RecoveryPlaneAttemptBinding"
        , "recoveryPlaneAttemptBindingInternal"
        , "recoveryPlaneAttemptBindingAfterBeginInternal"
        , "deriveRecoveryPlaneProfileInternal"
        , "deriveRecoveryPlaneIdentityFromCompiledInternal"
        , "restoreRecoveryPlaneIdentityFromCompiledInternal"
        , "normalizeRecoveryPlaneComponentFactsInternal"
        , "mkRecoveryPlaneInitialReadBackInternal"
        , "mkRecoveryPlaneFinalEvidenceInternal"
        , "encodeRecoveryPlaneIdentityWireInternal"
        , "decodeRecoveryPlaneIdentityWireInternal"
        , "recoveryPlaneInitialReady"
        , "RecoveryPlaneIdentity (.."
        , "RecoveryPlaneInitialReadBack (.."
        , "RecoveryPlaneReady (.."
        , "RecoveryPlaneFinalEvidence (.."
        ]
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal"
      importers
        `shouldBe` [ "src/Prodbox/ControlPlane/LocalRke2HostObservationEndpoint/Internal.hs"
                   , "src/Prodbox/ControlPlane/LocalRke2HostObservationRepository/Internal.hs"
                   , "src/Prodbox/ControlPlane/RecoveryPlaneRepository/Internal.hs"
                   , "src/Prodbox/Lifecycle/Teardown/LocalRke2HostObservation/Internal.hs"
                   , "src/Prodbox/Lifecycle/Teardown/RecoveryPlane.hs"
                   , "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneComponentObserver/Internal.hs"
                   , "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneInterpreter/Internal.hs"
                   , "src/Prodbox/Lifecycle/Teardown/Report/Internal.hs"
                   ]
      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal
        `shouldContain` "Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal"

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

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
