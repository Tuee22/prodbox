{-# LANGUAGE OverloadedStrings #-}

module EksClientAuthProjection (eksClientAuthProjectionSuite) where

import Control.Monad (filterM)
import Data.Aeson (encode)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List (isInfixOf, isSuffixOf, sort)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import EksClientAuthProjectionFixture
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.ControlPlane.ProviderWorkerClient (providerWorkerResponseMaximumBytes)
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
        (fixtureAwsRegion FixtureCaCentral1)
        "aws-eks-test-cluster"
        ( "arn:aws:eks:"
            <> (fixtureAwsRegion FixtureCaCentral1)
            <> ":123456789012:cluster/aws-eks-test-cluster"
        )
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
        (fixtureAwsRegion FixtureCaCentral1)
        "aws-eks-test-cluster"
        ("arn:aws:eks:" <> (fixtureAwsRegion FixtureUsEast1) <> ":123456789012:cluster/aws-eks-test-cluster")
        "https://example.eks.amazonaws.com"
        "Y2E="
        "bearer"
        2000000000
        `shouldBe` Left (EksClientAuthFieldInvalid "cluster-arn")
      eksClientAuthClusterArn (sampleProjection "bearer")
        `shouldBe` ( "arn:aws:eks:"
                       <> (fixtureAwsRegion FixtureCaCentral1)
                       <> ":123456789012:cluster/aws-eks-test-cluster"
                   )
    it "renders kubeconfig with only a FIFO token path, never the bearer" $ do
      let bearer = "k8s-aws-v1.never-in-kubeconfig"
          rendered = LazyByteString.unpack (encode (eksKubeconfig (sampleProjection bearer) "/tmp/token-fifo"))
      rendered `shouldContain` "tokenFile"
      rendered `shouldContain` "/tmp/token-fifo"
      rendered `shouldNotContain` Text.unpack bearer
    -- Sprint 6.5: a live Provider execution returned 4,649 characters of
    -- client-auth evidence against a generic 4,096-character bound, so this
    -- intent could never have succeeded.  The bound is now derived from the
    -- envelope the sealer may produce, and this case proves the whole chain:
    -- maximal projection fields seal within the envelope bound, that envelope's
    -- marker-prefixed Base64 evidence sits within the derived character bound,
    -- and that bound sits within the Provider response maximum.
    it "derives an evidence bound that admits every sealable envelope and fits the response" $ do
      let maximalCa = Text.replicate 8192 "Y"
          maximalBearer = "k8s-aws-v1." <> Text.replicate (8192 - 11) "b"
      maximalFixture <-
        testEksClientAuthProjectionFixture
          "123456789012"
          (fixtureAwsRegion FixtureCaCentral1)
          (Text.replicate 256 "c")
          ( "arn:aws:eks:"
              <> fixtureAwsRegion FixtureCaCentral1
              <> ":123456789012:cluster/"
              <> Text.replicate 256 "c"
          )
          ("https://" <> Text.replicate 2000 "e")
          maximalCa
          maximalBearer
          2000000000
      case maximalFixture of
        Left err -> expectationFailure (show err)
        Right (_, envelope, _) -> do
          let encoded = encodeEksClientAuthEnvelope envelope
              evidence =
                eksClientAuthEvidenceMarker
                  <> TextEncoding.decodeUtf8 (Base64.encode encoded)
          ByteString.length encoded `shouldSatisfy` (<= maximumEnvelopeBytes)
          Text.length evidence
            `shouldSatisfy` (<= maximumEksClientAuthEvidenceCharacters)
          maximumEksClientAuthEvidenceCharacters
            `shouldSatisfy` (< providerWorkerResponseMaximumBytes)
          maximumEksClientAuthEvidenceCharacters `shouldBe` 32793
          maximumEnvelopeBytes `shouldBe` (24 * 1024)

      -- The live measurement: a realistic cluster's evidence is well over the
      -- generic bound and well under the derived one.
      liveShapedFixture <-
        testEksClientAuthProjectionFixture
          "123456789012"
          (fixtureAwsRegion FixtureCaCentral1)
          "aws-eks-test-cluster"
          ( "arn:aws:eks:"
              <> fixtureAwsRegion FixtureCaCentral1
              <> ":123456789012:cluster/aws-eks-test-cluster"
          )
          "https://example.eks.amazonaws.com"
          (Text.replicate 1900 "Y")
          ("k8s-aws-v1." <> Text.replicate 1289 "b")
          2000000000
      case liveShapedFixture of
        Left err -> expectationFailure (show err)
        Right (_, envelope, _) -> do
          let evidence =
                eksClientAuthEvidenceMarker
                  <> TextEncoding.decodeUtf8
                    (Base64.encode (encodeEksClientAuthEnvelope envelope))
          Text.length evidence `shouldSatisfy` (> 4096)
          Text.length evidence
            `shouldSatisfy` (<= maximumEksClientAuthEvidenceCharacters)

      testEksClientAuthProjection
        "123456789012"
        (fixtureAwsRegion FixtureCaCentral1)
        "aws-eks-test-cluster"
        ( "arn:aws:eks:"
            <> fixtureAwsRegion FixtureCaCentral1
            <> ":123456789012:cluster/aws-eks-test-cluster"
        )
        "https://example.eks.amazonaws.com"
        (Text.replicate 8193 "Y")
        "bearer"
        2000000000
        `shouldBe` Left (EksClientAuthFieldInvalid "certificate-authority")
      testEksClientAuthProjection
        "123456789012"
        (fixtureAwsRegion FixtureCaCentral1)
        "aws-eks-test-cluster"
        ( "arn:aws:eks:"
            <> fixtureAwsRegion FixtureCaCentral1
            <> ":123456789012:cluster/aws-eks-test-cluster"
        )
        "https://example.eks.amazonaws.com"
        "Y2E="
        (Text.replicate 8193 "b")
        2000000000
        `shouldBe` Left (EksClientAuthFieldInvalid "bearer")

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
        (fixtureAwsRegion FixtureCaCentral1)
        "aws-eks-test-cluster"
        ( "arn:aws:eks:"
            <> (fixtureAwsRegion FixtureCaCentral1)
            <> ":123456789012:cluster/aws-eks-test-cluster"
        )
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
    (fixtureAwsRegion FixtureCaCentral1)
    "aws-eks-test-cluster"
    ( "arn:aws:eks:"
        <> (fixtureAwsRegion FixtureCaCentral1)
        <> ":123456789012:cluster/aws-eks-test-cluster"
    )
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
