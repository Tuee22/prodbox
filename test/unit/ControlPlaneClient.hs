{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneClient (controlPlaneClientSuite) where

import Data.ByteString qualified as ByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Method (Method)
import Prodbox.ControlPlane.Client
import Prodbox.Http.Client
  ( HttpBoundedError (HttpBoundedTransport)
  , HttpError (HttpTimeout)
  )
import TestSupport

controlPlaneClientSuite :: SuiteBuilder ()
controlPlaneClientSuite =
  describe "Sprint 4.50 role-indexed control-plane client" $ do
    it "projects the Lifecycle Authority method/path and preserves canonical bytes" $ do
      endpoint <- accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority.prodbox.svc:8600/")
      observed <- newIORef Nothing
      client <-
        accepted
          ( controlPlaneClientWithTransport
              64
              endpoint
              (recordingTransport observed (Right (200, "operation-accepted")))
          )
      result <- callControlPlane client LifecycleOperationSubmitRoute "canonical-cbor"
      result `shouldBe` Right (ControlPlaneResponse 200 "operation-accepted")
      readIORef observed
        `shouldReturn` Just
          ( "POST"
          ,
            [ ("Content-Type", "application/cbor")
            , ("Accept", "application/octet-stream")
            ]
          , "http://lifecycle-authority.prodbox.svc:8600/v1/operations/submit"
          , "canonical-cbor"
          )

    it "projects GET-with-body only through the role-indexed observe constructor" $ do
      endpoint <- accepted (mkTargetSecretAgentEndpoint "https://target-agent.example:8600")
      observed <- newIORef Nothing
      client <-
        accepted
          ( controlPlaneClientWithTransport
              64
              endpoint
              (recordingTransport observed (Right (200, "target-secret-present")))
          )
      _ <- callControlPlane client TargetMaterialObserveRoute "observe-coordinate"
      ( fmap (\(method, _, url, body) -> (method, url, body))
          <$> readIORef observed
        )
        `shouldReturn` Just
          ( "GET"
          , "https://target-agent.example:8600/v1/target-material/observe"
          , "observe-coordinate"
          )
      priorPath <- fmap (\(_, _, url, _) -> url) <$> readIORef observed
      priorPath
        `shouldNotBe` Just "https://target-agent.example:8600/v1/target-secret/observe"

    it "retains non-success statuses for the typed protocol decoder" $ do
      endpoint <- accepted (mkProviderWorkerEndpoint "http://provider-worker:8600")
      client <-
        accepted
          ( controlPlaneClientWithTransport
              64
              endpoint
              (constantTransport (Right (409, "provider-work-refused")))
          )
      callControlPlane client ProviderWorkApplyRoute "request"
        `shouldReturn` Right (ControlPlaneResponse 409 "provider-work-refused")

    it "rejects oversized responses and transport failures" $ do
      endpoint <- accepted (mkAuthorityBackupEndpoint "http://authority-backup:8600")
      oversized <-
        accepted (controlPlaneClientWithTransport 3 endpoint (constantTransport (Right (200, "four"))))
      callControlPlane oversized AuthorityBackupObserveRoute ""
        `shouldReturn` Left (ControlPlaneResponseTooLarge 4 3)
      failed <-
        accepted
          ( controlPlaneClientWithTransport
              64
              endpoint
              (constantTransport (Left (HttpBoundedTransport (HttpTimeout "deadline"))))
          )
      callControlPlane failed AuthorityBackupCopyRoute "copy"
        `shouldReturn` Left (ControlPlaneTransportFailed (HttpTimeout "deadline"))

    it "rejects malformed endpoints and non-positive response bounds" $ do
      mkTlsRetentionEndpoint "tls-retention:8600"
        `shouldBe` Left ControlPlaneEndpointSchemeUnsupported
      mkTlsRetentionEndpoint "http://tls retention:8600"
        `shouldBe` Left ControlPlaneEndpointContainsWhitespace
      mkTlsRetentionEndpoint "http://"
        `shouldBe` Left ControlPlaneEndpointAuthorityInvalid
      mkTlsRetentionEndpoint "http://tls-retention:8600/base"
        `shouldBe` Left ControlPlaneEndpointAuthorityInvalid
      endpoint <- accepted (mkTlsRetentionEndpoint "http://tls-retention:8600")
      case controlPlaneClientWithTransport 0 endpoint (constantTransport (Right (200, ""))) of
        Left err -> err `shouldBe` ControlPlaneResponseLimitMustBePositive
        Right _ -> expectationFailure "expected a non-positive response limit refusal"

recordingTransport
  :: IORef (Maybe (Method, [Header], String, ByteString.ByteString))
  -> Either HttpBoundedError (Int, ByteString.ByteString)
  -> ControlPlaneTransport
recordingTransport observed result method headers url body = do
  writeIORef observed (Just (method, headers, url, body))
  pure result

constantTransport
  :: Either HttpBoundedError (Int, ByteString.ByteString)
  -> ControlPlaneTransport
constantTransport result _ _ _ _ = pure result

accepted :: (Show err) => Either err value -> IO value
accepted result = case result of
  Left err -> fail (show err)
  Right value -> pure value
