module Prodbox.AwsEnvironment
  ( awsCliSubprocessEnvironment
  , sealedAwsEnvironment
  , overlayAwsCredentials
  )
where

import Data.Text qualified as Text
import Prodbox.Settings
  ( Credentials (..)
  )
import System.Environment (getEnvironment)

-- | The single canonical builder for an @aws@-CLI subprocess
-- environment. It overlays the repo-root credentials onto the *inherited
-- parent environment* so the child process keeps @PATH@ (to resolve the
-- @aws@ binary and its helpers), @HOME@ (to find credential/config
-- files), and @LANG@ (so the Dhall/JSON it emits decodes under the right
-- locale).
--
-- 'Subprocess.subprocessEnvironment' is applied with @typed-process@'s
-- @setEnv@, which *replaces* the child environment wholesale — it does
-- not merge with the parent's. So handing the child a from-scratch list
-- that omits @PATH@/@HOME@ leaves it unable to resolve its own binary or
-- credentials. Every bare-@aws@ isolated-env call site therefore routes
-- through this builder; there must be exactly one such builder per
-- @documents/engineering/haskell_code_guide.md@ ("Subprocess
-- environments must be PATH-preserving").
awsCliSubprocessEnvironment :: Credentials -> IO [(String, String)]
awsCliSubprocessEnvironment credentials = do
  base <- subprocessBaseEnvironment
  pure (overlayAwsCredentials base credentials)

-- | Seed only the path/locale-sensitive keys from the inherited parent
-- environment that an @aws@ CLI subprocess needs. Mirrors the home-grown
-- base used by 'Prodbox.Aws.adminAwsEnvironment'.
subprocessBaseEnvironment :: IO [(String, String)]
subprocessBaseEnvironment = do
  environment <- getEnvironment
  let keep key = maybe [] (\value -> [(key, value)]) (lookup key environment)
  pure (concatMap keep ["PATH", "HOME", "LANG", "TERM", "USER"])

-- | A genuinely-sealed @aws@-CLI environment: ONLY the @AWS_*@ overlay,
-- with no @PATH@/@HOME@/@LANG@ from any parent. This is *not* for
-- production subprocess spawning — a child given this env cannot resolve
-- the @aws@ binary off @PATH@. It exists only for contexts that truly
-- have no meaningful parent environment to inherit (pure unit-test
-- fixtures that assert the @AWS_*@ overlay shape in isolation). Live
-- subprocesses must use 'awsCliSubprocessEnvironment'.
sealedAwsEnvironment :: Credentials -> [(String, String)]
sealedAwsEnvironment = overlayAwsCredentials []

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
