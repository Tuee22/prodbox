module GeneratedArtifactSections (generatedArtifactSectionsSuite) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import Prodbox.CheckCode
  ( GeneratedSectionRule (..)
  , generatedSectionRules
  , processGeneratedArtifacts
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

generatedArtifactSectionsSuite :: SuiteBuilder ()
generatedArtifactSectionsSuite =
  describe "generated artifact sections sharing a file" $ do
    it "plans one combined write, preserves prose and passes its next check" $
      withFixture $ \root path original expected -> do
        writeFile (root </> path) original
        results <- processGeneratedArtifacts root True
        let updates = [update | Right update@(target, _, _) <- results, target == root </> path]
        updates `shouldBe` [(root </> path, expected, True)]
        forM_ updates $ \(target, contents, _) -> writeFile target contents
        readFile (root </> path) `shouldReturn` expected
        checked <- processGeneratedArtifacts root False
        [update | Right update@(target, _, _) <- checked, target == root </> path]
          `shouldBe` [(root </> path, expected, False)]

    it "refuses the entire file update when a later section has no end marker" $
      withFixture $ \root path original _ -> do
        writeFile
          (root </> path)
          (unlines (filter (/= "<!-- prodbox:command-surface-matrix:end -->") (lines original)))
        results <- processGeneratedArtifacts root True
        [target | Right (target, _, _) <- results, target == root </> path]
          `shouldBe` []
        [err | Left err <- results, "command-surface-matrix:end" `isInfixOf` err]
          `shouldSatisfy` (not . null)

withFixture :: (FilePath -> FilePath -> String -> String -> IO ()) -> IO ()
withFixture action =
  withSystemTempDirectory "prodbox-generated-sections" $ \root -> do
    let path = "documents/engineering/cli_command_surface.md"
        rules = [rule | rule <- generatedSectionRules, generatedSectionPath rule == path]
        document render = unlines ("Introduction." : concatMap (section render) rules ++ ["Conclusion."])
        section render rule =
          [generatedSectionStartMarker rule]
            ++ lines (render rule)
            ++ [generatedSectionEndMarker rule, "Retained prose after " ++ generatedSectionKey rule ++ "."]
    length rules `shouldBe` 2
    createDirectoryIfMissing True (takeDirectory (root </> path))
    action
      root
      path
      (document (const "stale generated content"))
      (document (\rule -> generatedSectionRender rule ()))
