module Main (main) where

import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

main :: IO ()
main = mainWithSuite "prodbox-pulumi" $ do
  describe "pulumi suite scaffold" $ do
    it "keeps the AWS validation Pulumi stack programs in the repository" $ do
      repoRoot <- getCurrentDirectory
      eksProgram <- readFile (repoRoot </> "pulumi" </> "aws-eks" </> "Pulumi.yaml")
      testProgram <- readFile (repoRoot </> "pulumi" </> "aws-test" </> "Pulumi.yaml")
      eksProgram `shouldContain` "runtime: yaml"
      testProgram `shouldContain` "runtime: yaml"

    it "keeps the Pulumi CLI surface in the parser" $ do
      repoRoot <- getCurrentDirectory
      parserSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Parser.hs")
      parserSource `shouldContain` "\"pulumi\""
      parserSource `shouldContain` "\"eks-resources\""
