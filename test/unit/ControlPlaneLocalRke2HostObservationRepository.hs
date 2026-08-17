module ControlPlaneLocalRke2HostObservationRepository
  ( controlPlaneLocalRke2HostObservationRepositorySuite
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isPrefixOf, sort)
import Prodbox.Config.LocalRke2RecoveryState
  ( fixedLocalRke2RecoveryStateFixtureRegression
  , localRke2RecoveryFixtureHealthyEliminatorClosed
  )
import Prodbox.ControlPlane.LocalRke2HostObservationRepository
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

controlPlaneLocalRke2HostObservationRepositorySuite :: SuiteBuilder ()
controlPlaneLocalRke2HostObservationRepositorySuite =
  describe "Authority local RKE2 host-observation repository" $ do
    it "persists only bounded canonical Healthy claims and recovers response loss by read-back" $ do
      result <- fixedLocalRke2HostObservationRepositoryRegression
      case result of
        Left detail -> expectationFailure (show detail)
        Right regression -> do
          localRke2HostObservationRegressionCanonicalBounded regression
            `shouldBe` True
          localRke2HostObservationRegressionResponseLossRecovered regression
            `shouldBe` True
          localRke2HostObservationRegressionExactReplayPreserved regression
            `shouldBe` True
          localRke2HostObservationRegressionConflictPreserved regression
            `shouldBe` True
          localRke2HostObservationRegressionTamperingRefused regression
            `shouldBe` True
          localRke2HostObservationRegressionUnknownRefused regression
            `shouldBe` True

    it "keys every receipt by the fenced Establish attempt and rejects delayed stale commits" $ do
      result <- fixedLocalRke2HostObservationRepositoryRegression
      case result of
        Left detail -> expectationFailure (show detail)
        Right regression -> do
          localRke2HostObservationRegressionAttemptKeySeparated regression
            `shouldBe` True
          localRke2HostObservationRegressionDelayedAttemptRefused regression
            `shouldBe` True

    it "admits only the opaque production-observed Healthy constructor" $ do
      localRke2RecoveryFixtureHealthyEliminatorClosed
        fixedLocalRke2RecoveryStateFixtureRegression
        `shouldBe` True

    it "validates Establish Begin before invoking the canonical production observer" $ do
      implementation <-
        readFile
          "src/Prodbox/ControlPlane/LocalRke2HostObservationRepository/Internal.hs"
      let body = dropAt "observeLocalRke2HealthyAfterEstablishBeginInternal bound" implementation
      body `shouldContain` "withDescriptorBoundRecoveryPlaneEstablishBindingInternal"
      body `shouldContain` "observed <- observeLocalRke2RecoveryState"
      indexOf "withDescriptorBoundRecoveryPlaneEstablishBindingInternal" body
        `shouldSatisfy` (< indexOf "observed <- observeLocalRke2RecoveryState" body)
      implementation
        `shouldContain` "local-rke2-host-observation-coordinate/v1"
      implementation
        `shouldContain` "encodeLocalRke2HostObservationIdentityInternal identity"

    it "keeps observation admission, Model-B construction, bytes, writes, and proof remint hidden" $ do
      observationFacade <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/LocalRke2HostObservation.hs"
      observationFacade `shouldNotContain` "LocalRke2HostObservationCandidate"
      observationFacade `shouldNotContain` "LocalRke2RecoveryStateView"
      observationFacade `shouldNotContain` "ObservedLocalRke2RecoveryHealthy"
      observationFacade `shouldNotContain` "admitObservedLocalRke2HealthyInternal"
      observationFacade `shouldNotContain` "ByteString"

      repositoryFacade <-
        readFile
          "src/Prodbox/ControlPlane/LocalRke2HostObservationRepository.hs"
      repositoryFacade `shouldNotContain` "ModelBCasAdapter"
      repositoryFacade `shouldNotContain` "RepositoryClient"
      repositoryFacade `shouldNotContain` "modelBLocalRke2"
      repositoryFacade `shouldNotContain` "commitLocalRke2"
      repositoryFacade `shouldNotContain` "independentlyReadBack"
      repositoryFacade
        `shouldNotContain` "CommittedLocalRke2HostObservation (..)"
      repositoryFacade `shouldNotContain` "ByteString"

      observationInternalImporters <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.LocalRke2HostObservation.Internal"
      sort observationInternalImporters
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/LocalRke2HostObservationEndpoint/Internal.hs"
          , "src/Prodbox/ControlPlane/LocalRke2HostObservationRepository/Internal.hs"
          , "src/Prodbox/Lifecycle/Teardown/LocalRke2HostObservation.hs"
          ]

      repositoryInternalImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.LocalRke2HostObservationRepository.Internal"
      sort repositoryInternalImporters
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/LocalRke2HostObservationEndpoint/Internal.hs"
          , "src/Prodbox/ControlPlane/LocalRke2HostObservationRepository.hs"
          , "src/Prodbox/ControlPlane/LocalRke2HostObservationTransport/Internal.hs"
          , "src/Prodbox/ControlPlane/Runtime.hs"
          , "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneComponentObserver/Internal.hs"
          ]

      localStateInternalImporters <-
        sourceImporters
          "src"
          "import Prodbox.Config.LocalRke2RecoveryState.Internal"
      sort localStateInternalImporters
        `shouldBe` sort
          [ "src/Prodbox/Config/LocalRke2RecoveryState.hs"
          , "src/Prodbox/Lifecycle/Teardown/LocalRke2HostObservation/Internal.hs"
          ]

      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) =
            break (== "    other-modules:") (lines cabal)
          libraryPrivate =
            takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          observationInternal =
            "Prodbox.Lifecycle.Teardown.LocalRke2HostObservation.Internal"
          repositoryInternal =
            "Prodbox.ControlPlane.LocalRke2HostObservationRepository.Internal"
      unlines libraryExposed `shouldNotContain` observationInternal
      unlines libraryExposed `shouldNotContain` repositoryInternal
      unlines libraryPrivate `shouldContain` observationInternal
      unlines libraryPrivate `shouldContain` repositoryInternal

dropAt :: String -> String -> String
dropAt needle value = case dropWhile (not . isPrefixOf needle) (tails value) of
  [] -> ""
  suffix : _ -> suffix

indexOf :: String -> String -> Int
indexOf needle value = case dropWhile (not . isPrefixOf needle . snd) indexed of
  [] -> maxBound
  (index, _) : _ -> index
 where
  indexed = zip [0 ..] (tails value)

tails :: [value] -> [[value]]
tails values = case values of
  [] -> [[]]
  _ : rest -> values : tails rest

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
