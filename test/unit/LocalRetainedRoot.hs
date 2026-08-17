{-# LANGUAGE OverloadedStrings #-}

module LocalRetainedRoot
  ( localRetainedRootSuite
  )
where

import Control.Monad (filterM, forM_)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.Text qualified as Text
import Prodbox.Config.LocalRetainedRoot
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

localRetainedRootSuite :: SuiteBuilder ()
localRetainedRootSuite =
  describe "local retained-root recovery boundary" $ do
    it "uses a canonical length-framed v1 marker and refuses ambiguous bindings" $ do
      let regression = fixedLocalRetainedRootFixtureRegression
      localRetainedRootFixtureMarkerRoundTrips regression `shouldBe` True
      localRetainedRootFixtureMarkerLengthFramed regression `shouldBe` True
      localRetainedRootFixtureMismatchRefused regression `shouldBe` True

    it "keeps an empty legacy marker non-authorizing without a live Authority observation" $ do
      localRetainedRootFixtureLegacyRequiresAuthority
        fixedLocalRetainedRootFixtureRegression
        `shouldBe` True
      renderLocalRetainedRootError LocalRetainedRootMarkerLegacyUntrusted
        `shouldContainText` "non-authorizing"

    it "closes the repository, Tier-0, retained layout, and marker universe" $ do
      localRetainedRootFixtureLayoutClosed
        fixedLocalRetainedRootFixtureRegression
        `shouldBe` True
      [minBound .. maxBound :: LocalRetainedRootEntry]
        `shouldBe` [ LocalRetainedRootRepository
                   , LocalRetainedRootCabalMarker
                   , LocalRetainedRootPlanMarker
                   , LocalRetainedRootTier0Config
                   , LocalRetainedRootDirectory
                   , LocalRetainedRootControlDirectory
                   , LocalRetainedRootMinioDirectory
                   , LocalRetainedRootVaultDirectory
                   , LocalRetainedRootEstablishmentMarker
                   ]

    it "renders every marker reconciliation outcome and representative refusal" $ do
      forM_
        [ RetainedRootMarkerCreated
        , RetainedRootMarkerAlreadyCurrent
        , RetainedRootLegacyMarkerReplaced
        ]
        ( (`shouldSatisfy` (not . Text.null))
            . renderRetainedRootMarkerReconcileOutcome
        )
      forM_
        [ LocalRetainedRootRepositoryInvalid "invalid"
        , LocalRetainedRootTier0Unobservable "unavailable"
        , LocalRetainedRootCoordinateInvalid "invalid"
        , LocalRetainedRootEntryMissing LocalRetainedRootMinioDirectory
        , LocalRetainedRootEntryUnsafe LocalRetainedRootVaultDirectory "symlink"
        , LocalRetainedRootMarkerInvalid "invalid"
        , LocalRetainedRootMarkerConflict
        , LocalRetainedRootMarkerBusy
        , LocalRetainedRootMarkerWriteFailed "lost"
        , LocalRetainedRootAuthorityUnavailable "lost"
        , LocalRetainedRootAuthorityConfigMissing
        , LocalRetainedRootAuthorityConfigCorrupt "corrupt"
        , LocalRetainedRootAuthorityConfigUnobservable "unknown"
        , LocalRetainedRootAuthorityConfigInvalid "invalid"
        , LocalRetainedRootAuthorityMismatch
        ]
        ( (`shouldSatisfy` (not . Text.null))
            . renderLocalRetainedRootError
        )

    it "keeps raw marker, filesystem, and config-client proof minting package-private" $ do
      facade <- readFile "src/Prodbox/Config/LocalRetainedRoot.hs"
      facade `shouldNotContain` "data BootstrapRetainedRootLocator"
      facade `shouldNotContain` "data AuthorityBoundRetainedRoot"
      facade `shouldNotContain` "RetainedRootMarker ("
      facade `shouldNotContain` "ConfigClient"
      facade `shouldNotContain` "ConfigObservation"
      facade `shouldNotContain` "LocalRetainedRootBoundary"
      facade `shouldNotContain` "AuthorityBoundRetainedRoot ->"

      importers <-
        sourceImporters
          "src"
          "import Prodbox.Config.LocalRetainedRoot.Internal"
      importers `shouldBe` ["src/Prodbox/Config/LocalRetainedRoot.hs"]

      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) =
            break (== "    other-modules:") (lines cabal)
          libraryPrivate =
            takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          internalModule = "Prodbox.Config.LocalRetainedRoot.Internal"
      unlines libraryExposed `shouldNotContain` internalModule
      unlines libraryPrivate `shouldContain` internalModule

    it "permits only authenticated re-observation to upgrade the bootstrap locator" $ do
      implementation <-
        readFile "src/Prodbox/Config/LocalRetainedRoot/Internal.hs"
      countOccurrences "AuthorityBoundRetainedRoot\n              (observedAuthorityRoot" implementation
        `shouldBe` 1
      implementation
        `shouldContain` "reobserveAuthorityBoundRetainedRoot\n  :: FilePath"
      implementation
        `shouldContain` "observedAuthorityIdentity authorityRoot"

      sourceFiles <- haskellFiles "src"
      locatorConsumers <-
        filterM (fileContains "BootstrapRetainedRootLocator") sourceFiles
      sort locatorConsumers
        `shouldBe` [ "src/Prodbox/Config/LocalRetainedRoot.hs"
                   , "src/Prodbox/Config/LocalRetainedRoot/Internal.hs"
                   ]

      forM_
        [ "src/Prodbox/Config/OrdinaryTeardownRecovery.hs"
        , "src/Prodbox/Config/ComponentGraph.hs"
        , "src/Prodbox/Lib/ChartPlatform.hs"
        ]
        $ \path -> do
          source <- readFile path
          source `shouldNotContain` "BootstrapRetainedRootLocator"
          source `shouldNotContain` "AuthorityBoundRetainedRoot"

    it "makes normal reconcile fail closed when marker reconciliation refuses" $ do
      rke2 <- readFile "src/Prodbox/CLI/Rke2.hs"
      rke2
        `shouldContain` "markerResult <- reconcileAuthorityBoundRetainedRootMarker repoRoot"
      rke2
        `shouldContain` "Left err -> failWith (Text.unpack (renderLocalRetainedRootError err))"

shouldContainText :: Text.Text -> Text.Text -> Expectation
shouldContainText actual expected =
  Text.unpack actual `shouldContain` Text.unpack expected

countOccurrences :: String -> String -> Int
countOccurrences needle = go
 where
  go remaining = case breakOn needle remaining of
    Nothing -> 0
    Just suffix -> 1 + go suffix

breakOn :: String -> String -> Maybe String
breakOn needle haystack
  | null needle = Nothing
  | otherwise = search haystack
 where
  search [] = Nothing
  search remaining@(_ : rest)
    | needle `isPrefixOf` remaining = Just (drop (length needle) remaining)
    | otherwise = search rest

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- haskellFiles root
  sort <$> filterM (fileContains importNeedle) paths

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
