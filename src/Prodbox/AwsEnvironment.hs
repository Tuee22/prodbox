module Prodbox.AwsEnvironment
  ( isolatedAwsEnvironment
  , overlayAwsCredentials
  )
where

import Data.Text qualified as Text
import Prodbox.Settings
  ( Credentials (..)
  )

isolatedAwsEnvironment :: Credentials -> [(String, String)]
isolatedAwsEnvironment = overlayAwsCredentials []

-- Strip host-side AWS auth state so supported commands use only repo-root credentials.
overlayAwsCredentials :: [(String, String)] -> Credentials -> [(String, String)]
overlayAwsCredentials baseEnvironment credentials =
  maybe
    baseEntries
    (\token -> upsertEnv "AWS_SESSION_TOKEN" (Text.unpack token) baseEntries)
    (session_token credentials)
 where
  sanitizedBaseEnvironment =
    filter (not . (`elem` ambientAwsAuthKeys) . fst) baseEnvironment
  baseEntries =
    upsertEnv "AWS_ACCESS_KEY_ID" (Text.unpack (access_key_id credentials)) $
      upsertEnv "AWS_SECRET_ACCESS_KEY" (Text.unpack (secret_access_key credentials)) $
        upsertEnv "AWS_REGION" (Text.unpack (region credentials)) $
          upsertEnv "AWS_DEFAULT_REGION" (Text.unpack (region credentials)) $
            upsertEnv "AWS_EC2_METADATA_DISABLED" "true" $
              upsertEnv "AWS_PAGER" "" sanitizedBaseEnvironment

ambientAwsAuthKeys :: [String]
ambientAwsAuthKeys =
  [ "AWS_ACCESS_KEY_ID"
  , "AWS_SECRET_ACCESS_KEY"
  , "AWS_SESSION_TOKEN"
  , "AWS_SECURITY_TOKEN"
  , "AWS_REGION"
  , "AWS_DEFAULT_REGION"
  , "AWS_PROFILE"
  , "AWS_DEFAULT_PROFILE"
  , "AWS_SHARED_CREDENTIALS_FILE"
  , "AWS_CONFIG_FILE"
  , "AWS_WEB_IDENTITY_TOKEN_FILE"
  , "AWS_ROLE_ARN"
  , "AWS_ROLE_SESSION_NAME"
  , "AWS_CONTAINER_CREDENTIALS_FULL_URI"
  , "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"
  , "AWS_CONTAINER_AUTHORIZATION_TOKEN"
  , "AWS_EC2_METADATA_DISABLED"
  , "AWS_PAGER"
  ]

upsertEnv :: String -> String -> [(String, String)] -> [(String, String)]
upsertEnv key value environment = (key, value) : filter ((/= key) . fst) environment
