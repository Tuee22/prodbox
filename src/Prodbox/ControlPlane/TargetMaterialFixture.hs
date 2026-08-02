{-# LANGUAGE OverloadedStrings #-}

-- | Test-harness material parsing for the Authority external-ingress lane.
--
-- The optional @test-secrets.dhall@ EAB fixture is plaintext operator input.
-- It must enter through a committed Authority permit/outbox and its attested
-- one-shot ingress Job; this module deliberately has no direct Target Agent or
-- Vault client.
module Prodbox.ControlPlane.TargetMaterialFixture
  ( seedAcmeEabFromTestSecrets
  )
where

import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( encodeExternalAcmeEabIngressFrame
  )
import Prodbox.Vault.Host
  ( AcmeEabFixture (AcmeEabFixture)
  , TestSecrets (acme_eab)
  , loadTestSecrets
  )

-- | The callback receives
-- only the canonical bounded worker-stdin frame; its type cannot be confused
-- with the long-lived Target Agent payload API. Production supplies the
-- committed Authority/attested-Job coordinator at this callback.
seedAcmeEabFromTestSecrets
  :: (ByteString -> IO (Either String ()))
  -> FilePath
  -> IO ()
seedAcmeEabFromTestSecrets writeTarget repoRoot = do
  testSecretsResult <- loadTestSecrets repoRoot
  case testSecretsResult of
    Just (Right testSecrets) ->
      case acme_eab testSecrets of
        Just (AcmeEabFixture keyId hmacKey)
          | not (Text.null (Text.strip keyId))
          , not (Text.null (Text.strip hmacKey)) -> do
              case encodeExternalAcmeEabIngressFrame keyId hmacKey of
                Left err -> ioError (userError (show err))
                Right ingressFrame -> do
                  result <- writeTarget ingressFrame
                  case result of
                    Left err -> ioError (userError err)
                    Right () -> pure ()
        _ -> pure ()
    _ -> pure ()
