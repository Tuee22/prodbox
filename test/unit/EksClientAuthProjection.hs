{-# LANGUAGE OverloadedStrings #-}

module EksClientAuthProjection (eksClientAuthProjectionSuite) where

import Control.Monad (filterM)
import Data.Aeson (encode)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List (isInfixOf, isSuffixOf, sort)
import Data.Text qualified as Text
import EksClientAuthProjectionFixture
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.Infra.AwsEksTestStack (eksKubeconfig)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

eksClientAuthProjectionSuite :: SuiteBuilder ()
eksClientAuthProjectionSuite =
  describe "Sprint 4.50 encrypted EKS client-auth projection" $ do
    it "round-trips only at the ephemeral destination" $ do
      fixture <- sampleProjectionFixture "k8s-aws-v1.private-bearer"
      case fixture of
        Left err -> expectationFailure (show err)
        Right (destination, envelope, projection) -> do
          decodeEksClientAuthEnvelope (encodeEksClientAuthEnvelope envelope)
            `shouldBe` Right envelope
          openEksClientAuthProjection destination envelope `shouldBe` Right projection
    it "refuses a different ephemeral destination" $ do
      (wrongDestination, _) <- prepareEksClientAuthDestination
      fixture <- sampleProjectionFixture "private-bearer"
      case fixture of
        Left err -> expectationFailure (show err)
        Right (_, envelope, _) ->
          openEksClientAuthProjection wrongDestination envelope
            `shouldBe` Left EksClientAuthEnvelopeBindingMismatch
    it "does not disclose the bearer through Show or retained envelope bytes" $ do
      let bearer = "k8s-aws-v1.do-not-retain"
      fixture <- sampleProjectionFixture bearer
      case fixture of
        Left err -> expectationFailure (show err)
        Right (_, envelope, projection) -> do
          show projection `shouldNotContain` Text.unpack bearer
          show envelope `shouldNotContain` Text.unpack bearer
          encodeEksClientAuthEnvelope envelope
            `shouldSatisfy` (not . ByteString.isInfixOf "do-not-retain")
    it "rejects non-positive expiry and non-canonical envelope bytes" $ do
      testEksClientAuthProjection
        "123456789012"
        "ca-central-1"
        "aws-eks-test-cluster"
        "arn:aws:eks:ca-central-1:123456789012:cluster/aws-eks-test-cluster"
        "https://example.eks.amazonaws.com"
        "Y2E="
        "bearer"
        0
        `shouldBe` Left (EksClientAuthFieldInvalid "expires")
      decodeEksClientAuthEnvelope "not-canonical-cbor"
        `shouldBe` Left EksClientAuthEnvelopeInvalid
    it "binds the exact EKS ARN to account, region, and cluster" $ do
      testEksClientAuthProjection
        "123456789012"
        "ca-central-1"
        "aws-eks-test-cluster"
        "arn:aws:eks:us-east-1:123456789012:cluster/aws-eks-test-cluster"
        "https://example.eks.amazonaws.com"
        "Y2E="
        "bearer"
        2000000000
        `shouldBe` Left (EksClientAuthFieldInvalid "cluster-arn")
      eksClientAuthClusterArn (sampleProjection "bearer")
        `shouldBe` "arn:aws:eks:ca-central-1:123456789012:cluster/aws-eks-test-cluster"
    it "renders kubeconfig with only a FIFO token path, never the bearer" $ do
      let bearer = "k8s-aws-v1.never-in-kubeconfig"
          rendered = LazyByteString.unpack (encode (eksKubeconfig (sampleProjection bearer) "/tmp/token-fifo"))
      rendered `shouldContain` "tokenFile"
      rendered `shouldContain` "/tmp/token-fifo"
      rendered `shouldNotContain` Text.unpack bearer
    it "admits cleanup issuance only from an opaque durable execution context" $ do
      source <- readFile "src/Prodbox/ControlPlane/EksClientAuthClient.hs"
      source `shouldContain` "CleanupNodeExecutionContext"
      source `shouldContain` "eks-client-auth-execution/v2"
      source `shouldContain` "TeardownExecutionIdentity"
      source `shouldContain` "eks-client-auth-teardown-execution/v3"
      source `shouldContain` "teardownExecutionIdentityOperationId"
      source `shouldNotContain` "withEksClientAuthProjectionForAttempt"
      source `shouldNotContain` "eksClientAuthAttemptSubmissionKey"
    it "keeps raw projection minting and sealing Provider-owned and hidden" $ do
      facade <- readFile "src/Prodbox/ControlPlane/EksClientAuthProjection.hs"
      facade `shouldNotContain` "mkEksClientAuthProjection"
      facade `shouldNotContain` "mkEksClientAuthPublicKey"
      facade `shouldNotContain` "sealEksClientAuthProjection"
      cabal <- readFile "prodbox.cabal"
      cabal `shouldContain` "Prodbox.ControlPlane.EksClientAuthProjection.Internal"
      let exposedLibrary =
            unlines
              ( takeWhile
                  (/= "    hs-source-dirs:   src")
                  (lines cabal)
              )
      exposedLibrary
        `shouldNotContain` "Prodbox.ControlPlane.EksClientAuthProjection.Internal"
      importers <- sourceImporters "src"
      importers
        `shouldBe` [ "src/Prodbox/ControlPlane/EksClientAuthProjection.hs"
                   , "src/Prodbox/ControlPlane/ProviderProduction.hs"
                   ]
      executionIdentityImporters <-
        sourceImportersFor
          "src"
          "import Prodbox.Lifecycle.Teardown.ExecutionIdentity.Internal"
      executionIdentityImporters
        `shouldBe` [ "src/Prodbox/Lifecycle/Teardown/Execution.hs"
                   , "src/Prodbox/Lifecycle/Teardown/ExecutionIdentity.hs"
                   ]

sampleProjection :: Text.Text -> EksClientAuthProjection
sampleProjection bearer =
  either
    (error . show)
    id
    ( testEksClientAuthProjection
        "123456789012"
        "ca-central-1"
        "aws-eks-test-cluster"
        "arn:aws:eks:ca-central-1:123456789012:cluster/aws-eks-test-cluster"
        "https://example.eks.amazonaws.com"
        "Y2VydGlmaWNhdGUtYXV0aG9yaXR5"
        bearer
        2000000000
    )

sampleProjectionFixture
  :: Text.Text
  -> IO
       ( Either
           EksClientAuthProjectionError
           (EksClientAuthDestination, EksClientAuthEnvelope, EksClientAuthProjection)
       )
sampleProjectionFixture bearer =
  testEksClientAuthProjectionFixture
    "123456789012"
    "ca-central-1"
    "aws-eks-test-cluster"
    "arn:aws:eks:ca-central-1:123456789012:cluster/aws-eks-test-cluster"
    "https://example.eks.amazonaws.com"
    "Y2VydGlmaWNhdGUtYXV0aG9yaXR5"
    bearer
    2000000000

sourceImporters :: FilePath -> IO [FilePath]
sourceImporters root =
  sourceImportersFor
    root
    "import Prodbox.ControlPlane.EksClientAuthProjection.Internal"

sourceImportersFor :: FilePath -> String -> IO [FilePath]
sourceImportersFor root importNeedle = do
  paths <- sourceFiles root
  sort <$> filterM containsInternalImport paths
 where
  containsInternalImport path = do
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
