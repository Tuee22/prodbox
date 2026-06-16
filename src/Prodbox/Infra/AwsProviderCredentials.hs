{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.14: AWS provider credentials for Pulumi require Vault KV.
--
-- Pulumi provider credentials are Vault-only on the supported path. The raw
-- @aws.*@ / @aws_admin_for_test_simulation.*@ config fields remain for the IAM
-- harness and admin flows, but Pulumi does not fall back to them.
module Prodbox.Infra.AwsProviderCredentials
  ( credentialsConfigured
  , loadPulumiProviderCredentials
  , loadPulumiProviderCredentialsWith
  , loadVaultOperationalAwsCredentials
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.Basics (UnencryptedBasics (..))
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.Settings
  ( Credentials (..)
  , loadUnencryptedBasics
  )
import Prodbox.Vault.Client
  ( VaultAddress (..)
  , vaultKvReadV2
  )
import Prodbox.Vault.Host (loadReadyVaultRootToken)

loadPulumiProviderCredentials :: FilePath -> IO (Either String Credentials)
loadPulumiProviderCredentials repoRoot =
  loadPulumiProviderCredentialsWith (loadVaultOperationalAwsCredentials repoRoot)

loadPulumiProviderCredentialsWith
  :: IO (Either String Credentials)
  -> IO (Either String Credentials)
loadPulumiProviderCredentialsWith = id

loadVaultOperationalAwsCredentials :: FilePath -> IO (Either String Credentials)
loadVaultOperationalAwsCredentials repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  case basicsResult of
    Left err ->
      pure
        ( Left
            ( "AWS provider credentials require Vault bootstrap basics before Pulumi can run: "
                ++ err
            )
        )
    Right basics -> do
      let address = VaultAddress (basicsVaultAddress basics)
      tokenResult <- loadReadyVaultRootToken repoRoot address
      case tokenResult of
        Left err ->
          pure (Left ("failed to load Vault token for AWS provider credentials: " ++ err))
        Right token -> do
          result <- vaultKvReadV2 address token "secret" "gateway/gateway/aws"
          pure $ case result of
            Left (HttpStatus 404 _) ->
              Left
                ( "secret/gateway/gateway/aws is missing; Pulumi provider credentials "
                    ++ "must be stored in Vault before AWS stack operations can run"
                )
            Left err ->
              Left
                ( "failed to read secret/gateway/gateway/aws from Vault: "
                    ++ renderHttpError err
                )
            Right fields -> credentialsFromVaultFields fields

credentialsFromVaultFields :: Map Text Text -> Either String Credentials
credentialsFromVaultFields fields = do
  accessKeyId <- requireField "access_key_id"
  secretAccessKey <- requireField "secret_access_key"
  awsRegion <- requireField "region"
  let sessionToken = normalizeOptionalText =<< Map.lookup "session_token" fields
  pure
    Credentials
      { access_key_id = accessKeyId
      , secret_access_key = secretAccessKey
      , session_token = sessionToken
      , region = awsRegion
      }
 where
  requireField field =
    case normalizeOptionalText =<< Map.lookup field fields of
      Just value -> Right value
      Nothing -> Left ("secret/gateway/gateway/aws is missing non-empty field " ++ Text.unpack field)

credentialsConfigured :: Credentials -> Bool
credentialsConfigured credentials =
  not (Text.null (Text.strip (access_key_id credentials)))
    && not (Text.null (Text.strip (secret_access_key credentials)))
    && not (Text.null (Text.strip (region credentials)))

normalizeOptionalText :: Text -> Maybe Text
normalizeOptionalText value =
  let stripped = Text.strip value
   in if Text.null stripped
        then Nothing
        else Just stripped
