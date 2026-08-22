module ControlPlaneDescriptorBoundLifecycleRuntime
  ( controlPlaneDescriptorBoundLifecycleRuntimeSuite
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

controlPlaneDescriptorBoundLifecycleRuntimeSuite :: SuiteBuilder ()
controlPlaneDescriptorBoundLifecycleRuntimeSuite =
  describe "closed descriptor-bound lifecycle runtime" $ do
    it "routes the exact released cloud and recovery operation inventories" $ do
      regression <- fixedDescriptorBoundLifecycleRuntimeRegression
      descriptorBoundLifecycleRuntimeCloudOperationsExact regression
        `shouldBe` True
      descriptorBoundLifecycleRuntimeRecoveryOperationsExact regression
        `shouldBe` True

    it "routes the four cascade host nodes to the closed cascade host runtime" $ do
      -- One node per durable phase: a phase that discharged two nodes would
      -- leave a resume with nothing to attribute a failure to.
      regression <- fixedDescriptorBoundLifecycleRuntimeRegression
      descriptorBoundLifecycleRuntimeCascadeHostOperationsExact regression
        `shouldBe` True

    it "classifies every currently unsupported operation as a refusal" $ do
      regression <- fixedDescriptorBoundLifecycleRuntimeRegression
      descriptorBoundLifecycleRuntimeUnsupportedOperationsExact regression
        `shouldBe` True
      descriptorBoundLifecycleRuntimeUnsupportedIsRefusal regression
        `shouldBe` True

    it "has no caller continuation and enters only through descriptor admission" $ do
      regression <- fixedDescriptorBoundLifecycleRuntimeRegression
      descriptorBoundLifecycleRuntimeNoCallerContinuation regression
        `shouldBe` True
      descriptorBoundLifecycleRuntimeDescriptorBoundOnly regression
        `shouldBe` True
      descriptorBoundLifecycleRuntimeOpacityClosed regression
        `shouldBe` True

      implementation <-
        readFile
          "src/Prodbox/ControlPlane/DescriptorBoundLifecycleRuntime/Internal.hs"
      implementation `shouldContain` "descriptorBoundCleanupNodeAction"
      implementation
        `shouldContain` "runCompiledTeardownNodeWithDescriptorContext"
      implementation
        `shouldContain` "recoveryPlaneHostDescriptorBoundNodeActionInternal"
      implementation `shouldContain` "executeCloudOperation"
      implementation
        `shouldContain` "DescriptorBoundLifecycleUnsupportedRoute"
      implementation
        `shouldNotContain` "DescriptorBoundCleanupNodeExecutionAction\n  -> DescriptorBoundCleanupNodeExecutionAction"

    it "keeps construction, handles, runtimes, and typed routes private" $ do
      facade <-
        readFile
          "src/Prodbox/ControlPlane/DescriptorBoundLifecycleRuntime.hs"
      let header = moduleHeader facade
      mapM_
        (header `shouldNotContain`)
        [ "descriptorBoundLifecycleNodeActionInternal"
        , "DescriptorBoundLifecycleRuntimeError"
        , "DescriptorBoundLifecycleUnsupported"
        , "DescriptorBoundCleanupRun"
        , "DescriptorBoundCleanupNodeExecutionAction"
        , "AuthenticatedClientTransport"
        , "CloudRuntime"
        , "TeardownOperation"
        ]

      importers <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal"
      -- Sprint 4.86: the non-public cascade candidate entrypoint is the
      -- dispatcher's first caller, recorded here deliberately.  Driving the
      -- total dispatcher over a durable run is precisely what that entrypoint
      -- is, and it is itself package-private, so the action still cannot
      -- escape the library.
      importers
        `shouldBe` [ "src/Prodbox/ControlPlane/DescriptorBoundLifecycleRuntime.hs"
                   , "src/Prodbox/Lifecycle/Teardown/CascadeCandidate/Internal.hs"
                   ]

      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal
        `shouldContain` "Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal"

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
