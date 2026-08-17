module ControlPlaneRecoveryPlaneRepository
  ( controlPlaneRecoveryPlaneRepositorySuite
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.ControlPlane.RecoveryPlaneRepository
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

controlPlaneRecoveryPlaneRepositorySuite :: SuiteBuilder ()
controlPlaneRecoveryPlaneRepositorySuite =
  describe "Authority recovery-plane repository" $ do
    it "recovers response loss only through exact independent read-back" $ do
      regression <- fixedRegression
      recoveryPlaneRepositoryResponseLossRecovered regression `shouldBe` True
      recoveryPlaneRepositoryExactReplayPreserved regression `shouldBe` True
      recoveryPlaneRepositoryRestartReadBack regression `shouldBe` True

    it "preserves conflicts and exact binding mismatches" $ do
      regression <- fixedRegression
      recoveryPlaneRepositoryConflictPreserved regression `shouldBe` True
      recoveryPlaneRepositoryAttemptBindingEnforced regression `shouldBe` True
      recoveryPlaneRepositoryCrossIdentityRefused regression `shouldBe` True

    it "requires one canonical fact for every derived profile component" $ do
      regression <- fixedRegression
      recoveryPlaneRepositoryComponentCompletenessEnforced regression `shouldBe` True
      recoveryPlaneRepositoryCorruptionRefused regression `shouldBe` True
      recoveryPlaneRepositoryBoundsEnforced regression `shouldBe` True
      recoveryPlaneRepositoryProfileProgressionRecoverable regression `shouldBe` True

    it "retains the authoritative Establish attempt in an opaque phase binding" $ do
      regression <- fixedRegression
      recoveryPlaneRepositoryObservationBindingExact regression `shouldBe` True
      recoveryPlaneRepositoryObservationBindingPhaseRestricted regression
        `shouldBe` True

    it "persists the exact fresh-state final disposition" $ do
      regression <- fixedRegression
      recoveryPlaneRepositoryEstablishedExact regression `shouldBe` True
      recoveryPlaneRepositoryEstablishedAfterInitialFailure regression `shouldBe` True
      recoveryPlaneRepositoryNotEstablishedExact regression `shouldBe` True
      recoveryPlaneRepositoryLostExact regression `shouldBe` True

    it "keeps Model-B, wire, write, observation, and proof minters hidden" $ do
      regression <- fixedRegression
      recoveryPlaneRepositoryOpacityClosed regression `shouldBe` True
      facade <- readFile "src/Prodbox/ControlPlane/RecoveryPlaneRepository.hs"
      let header = moduleHeader facade
      mapM_
        (header `shouldNotContain`)
        [ "RecoveryPlaneRepositoryClient (.."
        , "modelBRecoveryPlaneRepository"
        , "recoveryPlaneModelBCodecInternal"
        , "recoveryPlaneRepositoryLogicalName"
        , "withDescriptorBoundRecoveryPlaneIdentityInternal"
        , "withDescriptorBoundRecoveryPlaneEstablishBindingInternal"
        , "RecoveryPlaneObservationBinding"
        , "withRecoveryPlaneObservationEstablishBindingInternal"
        , "withDescriptorBoundRecoveryPlaneInitialContextInternal"
        , "withDescriptorBoundRecoveryPlaneInitialBindingsInternal"
        , "withDescriptorBoundRecoveryPlaneDispositionBindingsInternal"
        , "withDescriptorBoundRecoveryPlaneStaticFinalBindingsInternal"
        , "withRecoveredRecoveryPlaneInitialInternal"
        , "commitRecoveryPlaneInitialInternal"
        , "commitRecoveryPlaneFinalInternal"
        , "RecoveryPlaneAggregateWire"
        , "RecoveryPlaneRawComponent"
        , "encodeAggregate"
        , "decodeAggregate"
        ]
      importers <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.RecoveryPlaneRepository.Internal"
      importers
        `shouldBe` [ "src/Prodbox/ControlPlane/LocalRke2HostObservationEndpoint/Internal.hs"
                   , "src/Prodbox/ControlPlane/LocalRke2HostObservationRepository/Internal.hs"
                   , "src/Prodbox/ControlPlane/RecoveryPlaneRepository.hs"
                   , "src/Prodbox/ControlPlane/Runtime.hs"
                   , "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneComponentObserver/Internal.hs"
                   , "src/Prodbox/Lifecycle/Teardown/RecoveryPlaneInterpreter/Internal.hs"
                   ]
      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal
        `shouldContain` "Prodbox.ControlPlane.RecoveryPlaneRepository.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.ControlPlane.RecoveryPlaneRepository.Internal"

fixedRegression :: IO RecoveryPlaneRepositoryRegression
fixedRegression = do
  result <- fixedRecoveryPlaneRepositoryRegression
  case result of
    Left err -> do
      expectationFailure (show err)
      fail "invalid recovery-plane repository regression"
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
