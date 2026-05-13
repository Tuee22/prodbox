module Main (main) where

import Control.Exception (SomeException, try)
import Data.IORef qualified as IORef
import Data.Map.Strict qualified as Map
import Prodbox.CLI.Pulumi
  ( ephemeralOutputsStackName
  , ephemeralOutputsValues
  , ephemeralPulumiOutputsPath
  , ephemeralPulumiStackName
  , ephemeralPulumiStackRoot
  , readEphemeralPulumiOutputs
  , withEphemeralPulumiStack
  , writeEphemeralPulumiOutputs
  )
import Prodbox.CLI.Spec
  ( findCommandSpec
  )
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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

  describe "ephemeral stack harness" $ do
    it "creates unique local stack state, round-trips typed outputs, and cleans up on success" $
      withSystemTempDirectory "prodbox-pulumi" $ \tmpDir -> do
        createdRootsRef <- newMutableList
        withEphemeralPulumiStack tmpDir "aws-test" $ \stack -> do
          appendMutableList createdRootsRef (ephemeralPulumiStackRoot stack)
          doesDirectoryExist (ephemeralPulumiStackRoot stack) `shouldReturn` True
          writeEphemeralPulumiOutputs
            stack
            (Map.fromList [("cluster_name", "test-cluster"), ("bucket_name", "test-bucket")])
          doesFileExist (ephemeralPulumiOutputsPath stack) `shouldReturn` True
          outputsResult <- readEphemeralPulumiOutputs stack
          case outputsResult of
            Left err -> expectationFailure err
            Right outputs -> do
              ephemeralOutputsStackName outputs `shouldBe` ephemeralPulumiStackName stack
              Map.lookup "cluster_name" (ephemeralOutputsValues outputs) `shouldBe` Just "test-cluster"
              Map.lookup "bucket_name" (ephemeralOutputsValues outputs) `shouldBe` Just "test-bucket"
        createdRoots <- readMutableList createdRootsRef
        mapM_ (\rootPath -> doesDirectoryExist rootPath `shouldReturn` False) createdRoots

    it "cleans up stack state after a forced failure" $
      withSystemTempDirectory "prodbox-pulumi" $ \tmpDir -> do
        createdRootsRef <- newMutableList
        result <-
          ( try $
              withEphemeralPulumiStack tmpDir "aws-eks" $ \stack -> do
                appendMutableList createdRootsRef (ephemeralPulumiStackRoot stack)
                writeEphemeralPulumiOutputs stack (Map.fromList [("cluster_name", "eks-test")])
                ioError (userError "forced pulumi validation failure")
          )
            :: IO (Either SomeException ())
        case result of
          Left _ -> pure ()
          Right _ -> expectationFailure "expected the ephemeral Pulumi stack harness to rethrow the forced failure"
        createdRoots <- readMutableList createdRootsRef
        mapM_ (\rootPath -> doesDirectoryExist rootPath `shouldReturn` False) createdRoots

isJust :: Maybe a -> Bool
isJust maybeValue =
  case maybeValue of
    Just _ -> True
    Nothing -> False

newtype MutableList a = MutableList (IORef.IORef [a])

newMutableList :: IO (MutableList a)
newMutableList = MutableList <$> IORef.newIORef []

appendMutableList :: MutableList a -> a -> IO ()
appendMutableList (MutableList ref) value =
  IORef.modifyIORef' ref (\items -> items ++ [value])

readMutableList :: MutableList a -> IO [a]
readMutableList (MutableList ref) = IORef.readIORef ref
