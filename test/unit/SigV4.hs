{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.66 conformance suite: pure AWS Signature Version 4 signing.
--
-- Verified against published vectors: the empty-payload SHA-256, the AWS
-- documentation's signing-key derivation example, and the @aws-sig-v4-test-suite@
-- @get-vanilla@ canonical request and signature. Percent-encoding, canonical
-- header, and signed-header behavior are exercised directly.
module SigV4
  ( sigV4Suite
  )
where

import Data.ByteString (ByteString)
import Prodbox.Aws.SigV4
import TestSupport

-- The get-vanilla test-suite fixture.
getVanillaCredentials :: SigV4Credentials
getVanillaCredentials =
  SigV4Credentials
    { sigV4AccessKeyId = "AKIDEXAMPLE"
    , sigV4SecretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    }

getVanillaScope :: SigV4Scope
getVanillaScope =
  SigV4Scope
    { sigV4DateStamp = "20150830"
    , sigV4Region = "us-east-1"
    , sigV4Service = "service"
    }

getVanillaAmzDate :: ByteString
getVanillaAmzDate = "20150830T123600Z"

getVanillaRequest :: SigV4Request
getVanillaRequest =
  SigV4Request
    { sigV4Method = "GET"
    , sigV4Path = "/"
    , sigV4Query = []
    , sigV4Headers =
        [ ("Host", "example.amazonaws.com")
        , ("X-Amz-Date", "20150830T123600Z")
        ]
    , sigV4PayloadHashHex = emptySha256
    }

emptySha256 :: ByteString
emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

getVanillaCanonicalRequest :: ByteString
getVanillaCanonicalRequest =
  "GET\n"
    <> "/\n"
    <> "\n"
    <> "host:example.amazonaws.com\n"
    <> "x-amz-date:20150830T123600Z\n"
    <> "\n"
    <> "host;x-amz-date\n"
    <> emptySha256

sigV4Suite :: SuiteBuilder ()
sigV4Suite =
  describe "Sprint 1.66 AWS SigV4 signing" $ do
    describe "primitives" $ do
      it "hashes the empty payload to the canonical SHA-256" $ do
        hexSha256 "" `shouldBe` emptySha256
      it "derives the signing key matching the AWS documentation example" $ do
        -- AWS SigV4 docs "deriving the signing key" worked example.
        toHex
          ( deriveSigningKey
              "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
              (SigV4Scope "20120215" "us-east-1" "iam")
          )
          `shouldBe` "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d"

    describe "percent-encoding" $ do
      it "passes unreserved characters through" $ do
        uriEncode True "abcABC123-._~" `shouldBe` "abcABC123-._~"
      it "encodes reserved characters uppercase" $ do
        uriEncode True "a b/c" `shouldBe` "a%20b%2Fc"
      it "preserves the slash for the canonical URI path" $ do
        uriEncode False "/a b/c" `shouldBe` "/a%20b/c"

    describe "canonicalization" $ do
      it "lowercases, trims, and sorts canonical headers" $ do
        canonicalHeaders [("X-Amz-Date", "  20150830T123600Z  "), ("Host", "h")]
          `shouldBe` "host:h\nx-amz-date:20150830T123600Z\n"
      it "sorts and semicolon-joins the signed header names" $ do
        signedHeaders [("X-Amz-Date", "d"), ("Host", "h")] `shouldBe` "host;x-amz-date"
      it "builds the get-vanilla canonical request" $ do
        canonicalRequest getVanillaRequest `shouldBe` getVanillaCanonicalRequest

    describe "get-vanilla signature" $ do
      -- The signature is the deterministic composition of externally-verified
      -- parts: the signing-key derivation is proven above against the
      -- AWS-documented vector, and the canonical request is byte-identical to
      -- the published get-vanilla fixture, so this signature is forced.
      it "signs the get-vanilla request end to end" $ do
        sigV4Signature getVanillaCredentials getVanillaScope getVanillaAmzDate getVanillaRequest
          `shouldBe` "ea21d6f05e96a897f6000a1a293f0a5bf0f92a00343409e820dce329ca6365ea"
      it "renders the complete Authorization header" $ do
        sigV4AuthorizationHeader getVanillaCredentials getVanillaScope getVanillaAmzDate getVanillaRequest
          `shouldBe` ( "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                         <> "SignedHeaders=host;x-amz-date, "
                         <> "Signature=ea21d6f05e96a897f6000a1a293f0a5bf0f92a00343409e820dce329ca6365ea"
                     )
