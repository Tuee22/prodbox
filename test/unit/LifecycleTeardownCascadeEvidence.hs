module LifecycleTeardownCascadeEvidence
  ( lifecycleTeardownCascadeEvidenceSuite
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.Lifecycle.Teardown.CascadeEvidence
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

lifecycleTeardownCascadeEvidenceSuite :: SuiteBuilder ()
lifecycleTeardownCascadeEvidenceSuite =
  describe "Sprint 4.85 cascade uninstall and completion evidence" $ do
    it "keeps the complete proof chain behind one nullary non-authorizing regression" $ do
      regression <- expectRight fixedCascadeEvidenceRegression
      cascadeEvidenceRegressionCompleteChain regression `shouldBe` True
      cascadeEvidenceRegressionAbsenceRefused regression `shouldBe` True
      cascadeEvidenceRegressionCredentialRefused regression `shouldBe` True
      cascadeEvidenceRegressionAuditRefused regression `shouldBe` True
      cascadeEvidenceRegressionPreUninstallRefused regression `shouldBe` True
      cascadeEvidenceRegressionPermitRefused regression `shouldBe` True
      cascadeEvidenceRegressionMixedBindingRefused regression `shouldBe` True
      cascadeEvidenceRegressionLocalAbsenceRefused regression `shouldBe` True
      cascadeEvidenceRegressionCompletionRefused regression `shouldBe` True
      cascadeEvidenceRegressionDurableReadyCanonical regression `shouldBe` True
      cascadeEvidenceRegressionDurableReadyCorruptionRefused regression `shouldBe` True

    it "exports only opaque proofs and read-only views" $ do
      facade <- readFile "src/Prodbox/Lifecycle/Teardown/CascadeEvidence.hs"
      let header = unlines (takeWhile (/= "where") (lines facade))
      mapM_
        (header `shouldNotContain`)
        [ "mkCascadeReportDigest"
        , "mkLocalCompletionPermitId"
        , "CascadeCredentialDispositionResult"
        , "CascadeCredentialDispositionObservation"
        , "CascadePreUninstallReportObservation"
        , "CascadeCompletionReceiptObservation"
        , "LocalCompletionPermitGrant"
        , "CascadeAbsenceEvidence"
        , "CascadeCredentialDispositionEvidence"
        , "CascadeTerminalAuditEvidence"
        , "CascadePreUninstallReportEvidence"
        , "LocalCompletionPermit (.."
        , "mkCascadeAbsenceEvidence"
        , "mkCascadeCredentialDispositionEvidence"
        , "mkCascadeTerminalAuditEvidence"
        , "mkCascadePreUninstallReportEvidence"
        , "bindLocalCompletionPermit"
        , "mkReadyToUninstallEvidence"
        , "mkLocalUninstallEvidence"
        , "mkCascadeCompleteEvidence"
        , "ReadyToUninstallEvidence (.."
        , "LocalUninstallEvidence (.."
        , "CascadeCompleteEvidence (.."
        ]
      header `shouldContain` "ReadyToUninstallEvidence"
      header `shouldContain` "CascadeCompleteEvidence"
      header `shouldContain` "fixedCascadeEvidenceRegression"

    it "keeps raw restoration and proof construction in one Cabal-hidden ownership set" $ do
      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal
        `shouldContain` "Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal"
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal"
      importers
        `shouldBe` sort
          [ "src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs"
          , "src/Prodbox/Lifecycle/HostCleanupRunner.hs"
          , "src/Prodbox/Lifecycle/Teardown/CascadeEvidence.hs"
          , "src/Prodbox/Lifecycle/TestArtifactCleanup.hs"
          , "src/Prodbox/Lifecycle/TestArtifactIntentJournal.hs"
          ]
      hostRke2 <- readFile "src/Prodbox/Lifecycle/HostCleanupRke2.hs"
      hostRke2 `shouldNotContain` "mkLocalUninstallEvidence"
      hostRke2 `shouldNotContain` "LocalUninstallEvidence"
      hostRunner <- readFile "src/Prodbox/Lifecycle/HostCleanupRunner.hs"
      moduleHeader hostRunner
        `shouldNotContain` "HostCleanupCompletionReadBack (.."

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

expectRight :: (Show err) => Either err value -> IO value
expectRight result = case result of
  Left err -> expectationFailure (show err) >> error "unreachable"
  Right value -> pure value
