module LocalRke2RecoveryState
  ( localRke2RecoveryStateSuite
  )
where

import Control.Monad (filterM, forM_)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Prodbox.Config.LocalRke2RecoveryState
import Prodbox.Lifecycle.HostCleanupRke2
  ( LocalRke2InstallMarker (LocalRke2UninstallScriptMarker)
  )
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

localRke2RecoveryStateSuite :: SuiteBuilder ()
localRke2RecoveryStateSuite = do
  describe "local RKE2 recovery-state observation" $ do
    it "accepts only the exact healthy, stopped, and absent rows" $ do
      let regression = fixedLocalRke2RecoveryStateFixtureRegression
      localRke2RecoveryFixtureDefinitiveCombinationCount regression
        `shouldBe` 12
      localRke2RecoveryFixtureAcceptedViews regression
        `shouldBe` [LocalRke2RecoveryHealthy, LocalRke2RecoveryStopped, LocalRke2RecoveryAbsent]
      localRke2RecoveryFixtureContradictoryCombinationCount regression
        `shouldBe` 9

    it "refuses every combination containing an unknown observation" $ do
      localRke2RecoveryFixtureUnobservableCombinationCount
        fixedLocalRke2RecoveryStateFixtureRegression
        `shouldBe` 24

    it "keeps systemd, HTTP, TLS, timeout, and subprocess ambiguity fail-closed" $ do
      let regression = fixedLocalRke2RecoveryStateFixtureRegression
      localRke2RecoveryFixtureServiceParserClosed regression `shouldBe` True
      localRke2RecoveryFixtureApiParserClosed regression `shouldBe` True
      localRke2RecoveryFixtureHealthyEliminatorClosed regression `shouldBe` True

    it "refuses a mixed canonical marker set instead of hiding damaged installation state" $ do
      localRke2RecoveryFixtureMixedMarkersRefused
        fixedLocalRke2RecoveryStateFixtureRegression
        `shouldBe` True

    it "uses the canonical markers, service unit, loopback endpoint, and scrubbed process environment" $ do
      localRke2RecoveryFixtureProductionBoundaryCanonical
        fixedLocalRke2RecoveryStateFixtureRegression
        `shouldBe` True

    it "keeps every contradiction and observation surface closed and renderable" $ do
      let contradictions =
            [ LocalRke2InstallMarkersIncomplete
                (LocalRke2UninstallScriptMarker NonEmpty.:| [])
            , LocalRke2InstalledButSystemdUnitAbsent
            , LocalRke2InstallAbsentButSystemdUnitLoaded
            , LocalRke2ActiveServiceButApiUnreachable
            , LocalRke2InactiveServiceButApiReachable
            , LocalRke2InstallAbsentButApiReachable
            ]
      forM_ contradictions $ \contradiction ->
        renderLocalRke2RecoveryStateError
          (LocalRke2RecoveryStateContradictory contradiction)
          `shouldSatisfy` (not . Text.null)
      [minBound .. maxBound :: LocalRke2RecoveryObservationSurface]
        `shouldBe` [ LocalRke2RecoveryInstallSurface
                   , LocalRke2RecoveryServiceSurface
                   , LocalRke2RecoveryApiSurface
                   ]

    it "exposes no raw observation, injectable boundary, or caller-selected production minter" $ do
      facade <- readFile "src/Prodbox/Config/LocalRke2RecoveryState.hs"
      facade `shouldNotContain` "ObservedLocalRke2Recovery"
      facade `shouldNotContain` "LocalRke2RecoveryObservationBoundary"
      facade `shouldNotContain` "InstallFact"
      facade `shouldNotContain` "ServiceFact"
      facade `shouldNotContain` "ApiFact"
      facade `shouldNotContain` "classifyRecoveryState"
      facade `shouldNotContain` "Subprocess"
      facade `shouldNotContain` "LocalRke2RecoveryStateView -> LocalRke2RecoveryState"

      implementation <-
        readFile "src/Prodbox/Config/LocalRke2RecoveryState/Internal.hs"
      implementation
        `shouldContain` "observeLocalRke2RecoveryState\n  :: IO"
      implementation `shouldContain` "https://127.0.0.1:6443/readyz"
      implementation `shouldContain` "/usr/bin/systemctl"
      implementation `shouldContain` "/usr/bin/curl"

      importers <-
        sourceImporters
          "src"
          "import Prodbox.Config.LocalRke2RecoveryState.Internal"
      sort importers
        `shouldBe` sort
          [ "src/Prodbox/Config/LocalRke2RecoveryState.hs"
          , "src/Prodbox/Lifecycle/Teardown/LocalRke2HostObservation/Internal.hs"
          ]

      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) =
            break (== "    other-modules:") (lines cabal)
          libraryPrivate =
            takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          internalModule =
            "Prodbox.Config.LocalRke2RecoveryState.Internal"
      unlines libraryExposed `shouldNotContain` internalModule
      unlines libraryPrivate `shouldContain` internalModule

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- haskellFiles root
  filterM (fileContains importNeedle) paths

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then do
      children <- listDirectory path
      concat <$> traverse (haskellFiles . (path </>)) children
    else pure [path | takeExtension path == ".hs"]

fileContains :: String -> FilePath -> IO Bool
fileContains needle path = do
  contents <- readFile path
  pure (needle `isInfixOf` contents)
