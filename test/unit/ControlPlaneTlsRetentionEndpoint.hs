{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module ControlPlaneTlsRetentionEndpoint (controlPlaneTlsRetentionEndpointSuite) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.DedicatedAdapterStore
  ( AdapterObjectObservation (..)
  , AdapterObjectVersion
  , AdapterPutResult (..)
  , DedicatedAdapterKind (TlsRetentionAdapter)
  , DedicatedAdapterTransport (..)
  , adapterObjectNameText
  , awsS3EndpointForRegion
  , mkAdapterObjectVersion
  , mkTlsRetentionStoreConfig
  , tlsRetentionEnvelopeObjectName
  , tlsRetentionStorePrefix
  , tlsRetentionStoreScopeKey
  , tlsRetentionStoreSubstrate
  )
import Prodbox.ControlPlane.TlsRetentionAdapter
  ( tlsRetentionRepositoryWithTransport
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsPublicEdgeSecret
  , TlsSecretObservation (..)
  , mkTlsPublicEdgeSecret
  )
import Prodbox.ControlPlane.TlsTargetAgentProduction
  ( TlsSecretApplyDecision (..)
  , decideTlsSecretApply
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (..)
  , RetainedTlsRef (..)
  , RetentionVersion (..)
  , SourceSecretRef (..)
  )
import TestSupport

controlPlaneTlsRetentionEndpointSuite :: SuiteBuilder ()
controlPlaneTlsRetentionEndpointSuite =
  describe "Sprint 4.50 TLS Retention opaque-envelope endpoint" $ do
    it "accepts only the exact canonical substrate/scope prefix" $ do
      let config =
            mustRight
              ( mkTlsRetentionStoreConfig
                  "home"
                  (awsS3EndpointForRegion "ca-central-1")
                  "ca-central-1"
                  "prodbox-retained"
                  "home-local"
                  "%2A.example.com%2Ctest.example.com"
                  "public-edge-tls/home-local/%2A.example.com%2Ctest.example.com"
              )
      tlsRetentionStoreSubstrate config `shouldBe` "home-local"
      tlsRetentionStoreScopeKey config `shouldBe` "%2A.example.com%2Ctest.example.com"
      tlsRetentionStorePrefix config
        `shouldBe` "public-edge-tls/home-local/%2A.example.com%2Ctest.example.com"
      mkTlsRetentionStoreConfig
        "home"
        (awsS3EndpointForRegion "ca-central-1")
        "ca-central-1"
        "prodbox-retained"
        "home-local"
        "test.example"
        "public-edge-tls/aws/test.example"
        `shouldSatisfy` isLeft
    it "creates only when the exact public-edge Secret is absent" $ do
      let desired = samplePublicEdgeSecret "source-a" "1" "certificate"
      decideTlsSecretApply desired (Right TlsSecretMissing)
        `shouldBe` TlsSecretApplyCreate
    it "treats exact retained content as idempotent despite a new Kubernetes identity" $ do
      let desired = samplePublicEdgeSecret "retained-source" "7" "certificate"
          existing = samplePublicEdgeSecret "restored-source" "12" "certificate"
      decideTlsSecretApply desired (Right (TlsSecretPresent existing))
        `shouldBe` TlsSecretApplyIdempotent existing
    it "refuses different or corrupt existing public-edge Secret content" $ do
      let desired = samplePublicEdgeSecret "source-a" "1" "certificate-a"
          different = samplePublicEdgeSecret "source-b" "2" "certificate-b"
      decideTlsSecretApply desired (Right (TlsSecretPresent different))
        `shouldBe` TlsSecretApplyFailed "public-edge TLS Secret already exists with different retained content"
      decideTlsSecretApply desired (Right (TlsSecretCorrupt "invalid certificate"))
        `shouldBe` TlsSecretApplyFailed "public-edge TLS Secret already exists but is corrupt: invalid certificate"
      mkTlsRetentionStoreConfig
        "home"
        (awsS3EndpointForRegion "ca-central-1")
        "ca-central-1"
        "prodbox-retained"
        "other"
        "test.example"
        "public-edge-tls/other/test.example"
        `shouldSatisfy` isLeft
    it "stores a sealed envelope and returns a canonical binary receipt" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "certificate-ciphertext" "wrapped-dek"
          reference = referenceFor 1 envelope
          request = TlsStorePayload reference envelope
      result <- serveTlsStoreRequest 4096 repository (encodeControlPlaneRequest request)
      tlsStoreHttpStatus result `shouldBe` 200
      tlsStoreSummary result `shouldBe` "tls-store:read-back-confirmed"
      case result of
        TlsStoreSucceeded receipt ->
          decodeControlPlaneResponse
            4096
            (LazyByteString.fromStrict (tlsStoreResponseBody result))
            `shouldBe` Right receipt
        other -> expectationFailure ("expected TLS receipt, got " <> show other)
    it "recovers an applied immutable PUT after its response is lost" $ do
      (transport, _, putCount) <- freshMemoryTransport True
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "response-loss-certificate" "wrapped-dek"
          reference = referenceFor 7 envelope
      stored <- storeTlsEnvelope repository reference envelope
      stored `shouldSatisfy` isRight
      readIORef putCount `shouldReturn` 1
      restored <- restoreTlsEnvelope repository reference
      case restored of
        Right (TlsEnvelopePresent readBack _) -> readBack `shouldBe` envelope
        other -> expectationFailure ("expected exact TLS read-back, got " <> show other)
    it "treats same-version same-envelope replay as idempotent" $ do
      (transport, _, putCount) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "same-certificate" "same-wrapped-dek"
          reference = referenceFor 2 envelope
      first <- storeTlsEnvelope repository reference envelope
      second <- storeTlsEnvelope repository reference envelope
      first `shouldSatisfy` isRight
      second `shouldSatisfy` isRight
      readIORef putCount `shouldReturn` 2
    it "rejects same-version substitution with different envelope bytes" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          firstEnvelope = sampleEnvelope "certificate-one" "wrapped-one"
          secondEnvelope = sampleEnvelope "certificate-two" "wrapped-two"
      first <- storeTlsEnvelope repository (referenceFor 3 firstEnvelope) firstEnvelope
      first `shouldSatisfy` isRight
      substituted <- storeTlsEnvelope repository (referenceFor 3 secondEnvelope) secondEnvelope
      substituted `shouldBe` Left "TLS retention read-back bytes did not match"
    it "distinguishes missing and corrupt immutable versions" $ do
      (transport, objectsRef, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "expected-certificate" "expected-wrapped"
          reference = referenceFor 4 envelope
      restoreTlsEnvelope repository reference `shouldReturn` Right TlsEnvelopeMissing
      let objectName = mustRight (tlsRetentionEnvelopeObjectName 4)
          version = mustRight (mkAdapterObjectVersion "corrupt-etag")
      writeIORef
        objectsRef
        (Map.singleton (adapterObjectNameText objectName) (version, "not-canonical-cbor"))
      restored <- restoreTlsEnvelope repository reference
      case restored of
        Right (TlsEnvelopeCorrupt detail) ->
          detail `shouldContainText` "encoded envelope is invalid"
        other -> expectationFailure ("expected corrupt envelope, got " <> show other)
    it "refuses malformed, oversized, invalid, and digest-mismatched requests" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "certificate" "wrapped-dek"
          reference = referenceFor 1 envelope
          request = TlsStorePayload reference envelope
      serveTlsStoreRequest 4096 repository "not-cbor"
        `shouldReturn` TlsStoreBadRequest ControlPlaneRequestInvalid
      serveTlsStoreRequest 2 repository (encodeControlPlaneRequest request)
        `shouldReturn` TlsStoreBadRequest ControlPlaneRequestTooLarge
      mkTlsSealedEnvelope ByteString.empty "wrapped" `shouldSatisfy` isLeft
      mkTlsSealedEnvelope
        (ByteString.replicate (tlsMaximumCertificateCiphertextBytes + 1) 0)
        "wrapped"
        `shouldSatisfy` isLeft
      let wrongReference = reference {retainedCiphertextDigest = Text.replicate 64 "0"}
      serveTlsStoreRequest
        4096
        repository
        (encodeControlPlaneRequest (TlsStorePayload wrongReference envelope))
        `shouldReturn` TlsStoreDigestMismatch
    it "returns the exact sealed envelope from the restore response codec" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = tlsRetentionRepositoryWithTransport transport
          envelope = sampleEnvelope "certificate-readback" "wrapped-readback"
          reference = referenceFor 9 envelope
      _ <- storeTlsEnvelope repository reference envelope
      result <-
        serveTlsRestoreRequest
          4096
          repository
          (encodeControlPlaneRequest (TlsRestorePayload reference))
      tlsRestoreHttpStatus result `shouldBe` 200
      decodeControlPlaneResponse
        (1024 * 1024)
        (LazyByteString.fromStrict (tlsRestoreResponseBody result))
        `shouldBe` Right (TlsEnvelopePresent envelope (receiptFromResult result))
    it "redacts certificate ciphertext and wrapped DEK from Show" $ do
      let envelope = sampleEnvelope "do-not-log-certificate" "do-not-log-dek"
      show envelope `shouldNotContain` "do-not-log-certificate"
      show envelope `shouldNotContain` "do-not-log-dek"

sampleEnvelope :: ByteString -> ByteString -> TlsSealedEnvelope
sampleEnvelope certificate wrapped = mustRight (mkTlsSealedEnvelope certificate wrapped)

samplePublicEdgeSecret :: Text -> Text -> Text -> TlsPublicEdgeSecret
samplePublicEdgeSecret uid resourceVersion certificate =
  mustRight
    ( mkTlsPublicEdgeSecret
        (SourceSecretRef uid resourceVersion)
        (CertIdentity certificate "spki-digest" 2000000000)
        "kubernetes.io/tls"
        ( Map.fromList
            [ ("tls.crt", encodeBase64Text certificate)
            , ("tls.key", encodeBase64Text "private-key")
            ]
        )
        (Map.singleton "cert-manager.io/certificate-name" "public-edge-tls")
    )
 where
  encodeBase64Text = TextEncoding.decodeUtf8 . Base64.encode . TextEncoding.encodeUtf8

referenceFor :: Integer -> TlsSealedEnvelope -> RetainedTlsRef
referenceFor version envelope =
  RetainedTlsRef
    { retainedVersion = RetentionVersion (fromInteger version)
    , retainedCert = CertIdentity "serial" "spki-digest" 2000000000
    , retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope
    , retainedSourceSecret = SourceSecretRef "secret-uid" "resource-version"
    }

receiptFromResult :: TlsRestoreResult -> TlsRetentionReceipt
receiptFromResult result = case result of
  TlsRestoreObserved (TlsEnvelopePresent _ receipt) -> receipt
  _ -> error "expected present TLS envelope"

freshMemoryTransport
  :: Bool
  -> IO
       ( DedicatedAdapterTransport 'TlsRetentionAdapter IO
       , IORef (Map Text (AdapterObjectVersion, ByteString))
       , IORef Int
       )
freshMemoryTransport loseFirstResponse = do
  objectsRef <- newIORef Map.empty
  loseResponseRef <- newIORef loseFirstResponse
  putCount <- newIORef 0
  let transport =
        DedicatedAdapterTransport
          { observeAdapterObject = \objectName -> do
              objects <- readIORef objectsRef
              pure $ case Map.lookup (adapterObjectNameText objectName) objects of
                Nothing -> Right AdapterObjectMissing
                Just (version, bytes) -> Right (AdapterObjectObserved version bytes)
          , putAdapterObjectIfAbsent = \objectName bytes -> do
              modifyIORef' putCount (+ 1)
              let key = adapterObjectNameText objectName
              objects <- readIORef objectsRef
              case Map.lookup key objects of
                Just _ -> pure (Right AdapterPutConflict)
                Nothing -> do
                  let version =
                        mustRight
                          (mkAdapterObjectVersion ("etag-" <> Text.pack (show (ByteString.length bytes))))
                  writeIORef objectsRef (Map.insert key (version, bytes) objects)
                  lose <- atomicModifyIORef' loseResponseRef (False,)
                  pure $ if lose then Left "PUT response lost" else Right AdapterPutApplied
          , adapterObjectStoreReady = pure True
          }
  pure (transport, objectsRef, putCount)

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False

isRight :: Either left right -> Bool
isRight value = case value of
  Left _ -> False
  Right _ -> True

shouldContainText :: Text -> Text -> Expectation
shouldContainText actual expected =
  Text.unpack actual `shouldContain` Text.unpack expected

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
