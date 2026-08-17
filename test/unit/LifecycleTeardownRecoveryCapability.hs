{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownRecoveryCapability
  ( lifecycleTeardownRecoveryCapabilitySuite
  )
where

import Control.Monad (filterM, forM_)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.Text qualified as Text
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownTargetAgent (..)
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.RecoveryCapability
import Prodbox.Lifecycle.Teardown.RecoveryRequirement
import Prodbox.Lifecycle.Teardown.Registry
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

lifecycleTeardownRecoveryCapabilitySuite :: SuiteBuilder ()
lifecycleTeardownRecoveryCapabilitySuite = do
  describe "lifecycle teardown recovery capability catalog" $ do
    it "keeps all six current registered identities free of Target-Agent ability" $ do
      length lifecycleRegistry `shouldBe` 6
      forM_ lifecycleRegistry $ \identity -> do
        recoveryCapabilitySetNames
          (registeredIdentityRecoveryCapabilities identity)
          `shouldBe` []
        recoveryCapabilitySetRequiresTargetAgent
          (registeredIdentityRecoveryCapabilities identity)
          `shouldBe` False

    it "binds every current operation to ResumeOrdinaryCleanup only" $ do
      forM_ surfaceCases $ \(SurfaceCase surface maybeAwsScope) ->
        case compileDesiredAbsenceGraph runId foundation maybeAwsScope surface of
          Left err -> expectationFailure (show err)
          Right compiled -> do
            let programNodes =
                  desiredAbsenceProgramNodes
                    (compiledDesiredAbsenceProgram compiled)
                graphNodes = cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
                catalog =
                  compiledDesiredAbsenceRecoveryCapabilityCatalog compiled
            forM_ programNodes $ \node -> do
              recoveryCapabilitySetNames (programNodeRecoveryCapabilities node)
                `shouldBe` ["resume-ordinary-cleanup"]
              recoveryCapabilitySetRequiresTargetAgent
                (programNodeRecoveryCapabilities node)
                `shouldBe` False
            recoveryCapabilityCatalogNodes catalog
              `shouldBe` sort (map cleanupNodeId graphNodes)
            forM_ graphNodes $ \node -> do
              recoveryCapabilityCatalogOperationForNode
                (cleanupNodeId node)
                catalog
                `shouldBe` Just (cleanupNodeOperationId node)
              fmap
                recoveryCapabilitySetNames
                ( recoveryCapabilityCatalogCapabilitiesForNode
                    (cleanupNodeId node)
                    catalog
                )
                `shouldBe` Just ["resume-ordinary-cleanup"]

    it "proves synthetic Target-Agent and adversarial joins through a fixed diagnostic vector" $ do
      case fixedRecoveryRequirementFixtureRegression of
        Left detail -> expectationFailure (Text.unpack detail)
        Right regression -> do
          recoveryFixtureCatalogConstructionRefused regression `shouldBe` True
          recoveryFixtureCurrentProgramTargetAgents regression
            `shouldBe` replicate 6 OrdinaryTeardownWithoutTargetAgent
          recoveryFixtureCapabilityIdentitySeparated regression `shouldBe` True
          recoveryFixtureFullCatalogIdentitySeparated regression `shouldBe` True
          recoveryFixturePendingTargetAgent regression
            `shouldBe` OrdinaryTeardownWithTargetAgent
          recoveryFixtureRunningTargetAgent regression
            `shouldBe` OrdinaryTeardownWithTargetAgent
          recoveryFixtureCompletedTargetAgent regression
            `shouldBe` OrdinaryTeardownWithoutTargetAgent
          recoveryFixtureBlockedTargetAgent regression
            `shouldBe` OrdinaryTeardownWithoutTargetAgent
          recoveryFixtureTerminalStatesPreserved regression `shouldBe` True
          recoveryFixtureBindingMismatchesRefused regression `shouldBe` True

    it "exposes no public caller-selected or raw-CleanupRun minting path" $ do
      facade <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/RecoveryRequirement.hs"
      facade `shouldNotContain` "deriveRecoveryRequirementInternal"
      facade
        `shouldNotContain` "deriveOrdinaryTeardownRecoveryRequirementInternal"
      facade `shouldNotContain` "deriveOrdinaryTeardownRecoveryRequirement"
      facade `shouldNotContain` "-> CleanupRun"
      facade `shouldNotContain` "OrdinaryTeardownTargetAgent ->"

      capabilityFacade <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/RecoveryCapability.hs"
      capabilityFacade `shouldNotContain` "targetGenerationRecoveryCapabilities"
      capabilityFacade `shouldNotContain` "mkRecoveryCapabilityCatalogDraft"
      capabilityFacade `shouldNotContain` "sealRecoveryCapabilityCatalog"

      capabilityImporters <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.RecoveryCapability.Internal"
      sort capabilityImporters
        `shouldBe` sort
          [ "src/Prodbox/Lifecycle/Teardown/Graph.hs"
          , "src/Prodbox/Lifecycle/Teardown/CleanupProgramDescriptor/Internal.hs"
          , "src/Prodbox/Lifecycle/Teardown/RecoveryCapability.hs"
          , "src/Prodbox/Lifecycle/Teardown/RecoveryRequirement/Internal.hs"
          ]

      requirementImporters <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.RecoveryRequirement.Internal"
      sort requirementImporters
        `shouldBe` sort
          [ "src/Prodbox/Lifecycle/Teardown/RecoveryRequirement.hs"
          , "src/Prodbox/ControlPlane/CleanupRunClient.hs"
          , "src/Prodbox/Lifecycle/Teardown/Report/Internal.hs"
          ]

      cleanupClient <- readFile "src/Prodbox/ControlPlane/CleanupRunClient.hs"
      let cleanupClientHeader = unlines (takeWhile (/= "where") (lines cleanupClient))
      cleanupClientHeader
        `shouldNotContain` "deriveOrdinaryTeardownRecoveryRequirementInternal"
      cleanupClientHeader `shouldNotContain` "DescriptorBoundCleanupRun (..)"
      cleanupClientHeader `shouldNotContain` "-> CleanupRun"

      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) =
            break (== "    other-modules:") (lines cabal)
          libraryPrivate =
            takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          capabilityInternal =
            "Prodbox.Lifecycle.Teardown.RecoveryCapability.Internal"
          requirementInternal =
            "Prodbox.Lifecycle.Teardown.RecoveryRequirement.Internal"
      unlines libraryExposed `shouldNotContain` capabilityInternal
      unlines libraryExposed `shouldNotContain` requirementInternal
      unlines libraryPrivate `shouldContain` capabilityInternal
      unlines libraryPrivate `shouldContain` requirementInternal

data SurfaceCase where
  SurfaceCase
    :: CleanupSurfaceWitness surface
    -> Maybe AwsScope
    -> SurfaceCase

surfaceCases :: [SurfaceCase]
surfaceCases =
  [ SurfaceCase LocalOnlySurface Nothing
  , SurfaceCase CascadeSurface (Just awsScope)
  , SurfaceCase ExplicitPerRunSurface (Just awsScope)
  , SurfaceCase OperationalTeardownSurface (Just awsScope)
  , SurfaceCase ExplicitLongLivedSurface (Just awsScope)
  , SurfaceCase TotalDecommissionSurface (Just awsScope)
  ]

runId :: CleanupRunId
runId = mustRight (mkCleanupRunId "recovery-capability-run")

foundation :: LinuxRke2FoundationId
foundation = LinuxRke2FoundationId "linux-rke2-foundation"

awsScope :: AwsScope
awsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- haskellFiles root
  filterMContains importNeedle paths

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then do
      children <- listDirectory path
      concat <$> traverse (haskellFiles . (path </>)) children
    else
      pure [path | takeExtension path == ".hs"]

filterMContains :: String -> [FilePath] -> IO [FilePath]
filterMContains needle =
  filterM $ \path -> isInfixOf needle <$> readFile path

mustRight :: (Show error) => Either error value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
