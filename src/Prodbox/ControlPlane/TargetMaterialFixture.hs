{-# LANGUAGE OverloadedStrings #-}

-- | Test-harness material parsing for the Authority external-ingress lane.
--
-- The optional @test-secrets.dhall@ EAB fixture is plaintext operator input.
-- It must enter through a committed Authority permit/outbox and its attested
-- one-shot ingress Job; this module deliberately has no direct Target Agent or
-- Vault client.
module Prodbox.ControlPlane.TargetMaterialFixture
  ( seedAcmeEabFromTestSecrets
  , acmeEabFixtureOperationId
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)
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

-- | The operation id the harness submits its ACME EAB fixture under (Sprint
-- 5.53): the cluster, then a digest of the frame that carries the credential.
-- The id was once the cluster alone, so every submission named the operation
-- the Authority already retained and the workflow replayed the retained
-- generation: a changed @acme_eab@ was never installed, and the rotate arm of
-- the request builder was unreachable from its one caller. A changed credential
-- now names a different operation, which a completed retained operation answers
-- with a rotation at the next generation; an unchanged one names the same
-- operation and replays. The digest is truncated and the credential is a
-- high-entropy HMAC key, so the id discloses nothing a reader could use.
acmeEabFixtureOperationId :: Text -> ByteString -> Text
acmeEabFixtureOperationId clusterId ingressFrame =
  "acme-eab-fixture-" <> clusterId <> "-" <> Text.take 16 (sha256Hex ingressFrame)

sha256Hex :: ByteString -> Text
sha256Hex = Text.pack . concatMap renderByte . ByteString.unpack . SHA256.hash
 where
  renderByte byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered
