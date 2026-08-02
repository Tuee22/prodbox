{-# LANGUAGE OverloadedStrings #-}

module EksClientAuthProjection (eksClientAuthProjectionSuite) where

import Data.Aeson (encode)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text qualified as Text
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.Infra.AwsEksTestStack (eksKubeconfig)
import TestSupport

eksClientAuthProjectionSuite :: SuiteBuilder ()
eksClientAuthProjectionSuite =
  describe "Sprint 4.50 encrypted EKS client-auth projection" $ do
    it "round-trips only at the ephemeral destination" $ do
      (destination, publicKey) <- prepareEksClientAuthDestination
      let projection = sampleProjection "k8s-aws-v1.private-bearer"
      sealed <- sealEksClientAuthProjection publicKey projection
      case sealed of
        Left err -> expectationFailure (show err)
        Right envelope -> do
          decodeEksClientAuthEnvelope (encodeEksClientAuthEnvelope envelope)
            `shouldBe` Right envelope
          openEksClientAuthProjection destination envelope `shouldBe` Right projection
    it "refuses a different ephemeral destination" $ do
      (_, publicKey) <- prepareEksClientAuthDestination
      (wrongDestination, _) <- prepareEksClientAuthDestination
      sealed <- sealEksClientAuthProjection publicKey (sampleProjection "private-bearer")
      case sealed of
        Left err -> expectationFailure (show err)
        Right envelope ->
          openEksClientAuthProjection wrongDestination envelope
            `shouldBe` Left EksClientAuthEnvelopeBindingMismatch
    it "does not disclose the bearer through Show or retained envelope bytes" $ do
      (_, publicKey) <- prepareEksClientAuthDestination
      let bearer = "k8s-aws-v1.do-not-retain"
          projection = sampleProjection bearer
      show projection `shouldNotContain` Text.unpack bearer
      sealed <- sealEksClientAuthProjection publicKey projection
      case sealed of
        Left err -> expectationFailure (show err)
        Right envelope -> do
          show envelope `shouldNotContain` Text.unpack bearer
          encodeEksClientAuthEnvelope envelope
            `shouldSatisfy` (not . ByteString.isInfixOf "do-not-retain")
    it "rejects non-positive expiry and non-canonical envelope bytes" $ do
      mkEksClientAuthProjection
        "123456789012"
        "ca-central-1"
        "aws-eks-test-cluster"
        "https://example.eks.amazonaws.com"
        "Y2E="
        "bearer"
        0
        `shouldBe` Left (EksClientAuthFieldInvalid "expires")
      decodeEksClientAuthEnvelope "not-canonical-cbor"
        `shouldBe` Left EksClientAuthEnvelopeInvalid
    it "renders kubeconfig with only a FIFO token path, never the bearer" $ do
      let bearer = "k8s-aws-v1.never-in-kubeconfig"
          rendered = LazyByteString.unpack (encode (eksKubeconfig (sampleProjection bearer) "/tmp/token-fifo"))
      rendered `shouldContain` "tokenFile"
      rendered `shouldContain` "/tmp/token-fifo"
      rendered `shouldNotContain` Text.unpack bearer

sampleProjection :: Text.Text -> EksClientAuthProjection
sampleProjection bearer =
  either
    (error . show)
    id
    ( mkEksClientAuthProjection
        "123456789012"
        "ca-central-1"
        "aws-eks-test-cluster"
        "https://example.eks.amazonaws.com"
        "Y2VydGlmaWNhdGUtYXV0aG9yaXR5"
        bearer
        2000000000
    )
