{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.66 conformance suite: the native S3 client's request signing.
--
-- These are the code-owned checks that 'signS3Request' composes the
-- vector-tested SigV4 primitives correctly — the complete header set, the
-- payload hash bound to the in-memory body, the credential scope, and the sorted
-- signed-header list (including conditional headers). The live native-vs-
-- subprocess parity against a real MinIO endpoint is the Standard-O live-proof
-- axis.
module ObjectStoreNative
  ( objectStoreNativeSuite
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.List (find, isInfixOf)
import Prodbox.Aws.SigV4 (SigV4Credentials (..), hexSha256)
import Prodbox.Minio.ObjectStoreNative
import TestSupport

fixedTimestamp :: S3Timestamp
fixedTimestamp = S3Timestamp {s3AmzDate = "20240101T000000Z", s3DateStamp = "20240101"}

sampleCredentials :: SigV4Credentials
sampleCredentials =
  SigV4Credentials {sigV4AccessKeyId = "AKIAEXAMPLE", sigV4SecretAccessKey = "secret-key"}

headerValue :: ByteString -> [(ByteString, ByteString)] -> Maybe ByteString
headerValue name headers = snd <$> find ((== name) . fst) headers

emptySha256 :: ByteString
emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

objectStoreNativeSuite :: SuiteBuilder ()
objectStoreNativeSuite =
  describe "Sprint 1.66 native S3 request signing" $ do
    describe "a bodyless GET" $ do
      let signed =
            signS3Request
              sampleCredentials
              "127.0.0.1:39000"
              "GET"
              "/prodbox-state/objects/abc.enc"
              []
              ""
              []
              fixedTimestamp
      it "signs the exact host header value" $ do
        headerValue "host" signed `shouldBe` Just "127.0.0.1:39000"
      it "binds the empty-payload content hash" $ do
        headerValue "x-amz-content-sha256" signed `shouldBe` Just emptySha256
      it "carries the amz date" $ do
        headerValue "x-amz-date" signed `shouldBe` Just "20240101T000000Z"
      it "produces an Authorization with the s3 credential scope" $ do
        fmap BS8.unpack (headerValue "Authorization" signed)
          `shouldSatisfy` maybe False ("Credential=AKIAEXAMPLE/20240101/us-east-1/s3/aws4_request" `isInfixOf`)
      it "signs exactly host, content-sha256, and date (sorted)" $ do
        fmap BS8.unpack (headerValue "Authorization" signed)
          `shouldSatisfy` maybe False ("SignedHeaders=host;x-amz-content-sha256;x-amz-date" `isInfixOf`)

    describe "a conditional PUT with a body" $ do
      let body = "some-object-bytes"
          signed =
            signS3Request
              sampleCredentials
              "127.0.0.1:39000"
              "PUT"
              "/prodbox-state/objects/abc.enc"
              []
              body
              [("If-None-Match", "*")]
              fixedTimestamp
      it "binds the body's content hash, not the empty hash" $ do
        headerValue "x-amz-content-sha256" signed `shouldBe` Just (hexSha256 body)
      it "signs the conditional header in the sorted signed-header list" $ do
        fmap BS8.unpack (headerValue "Authorization" signed)
          `shouldSatisfy` maybe
            False
            ("SignedHeaders=host;if-none-match;x-amz-content-sha256;x-amz-date" `isInfixOf`)
      it "includes the conditional header itself in the signed set" $ do
        headerValue "If-None-Match" signed `shouldBe` Just "*"
