module Main (main) where

import Prodbox.CLI.Spec
  ( findCommandSpec
  )
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

    it "keeps the Pulumi CLI surface in the registry-backed parser" $ do
      findCommandSpec ["pulumi", "eks-resources"] `shouldSatisfy` isJust
      findCommandSpec ["pulumi", "test-resources"] `shouldSatisfy` isJust

isJust :: Maybe a -> Bool
isJust maybeValue =
  case maybeValue of
    Just _ -> True
    Nothing -> False
