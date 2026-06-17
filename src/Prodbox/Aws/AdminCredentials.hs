{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 7.16: the single acquisition point for the EPHEMERAL elevated
-- admin AWS credential.
--
-- The doctrine keeps three AWS credential roles strictly distinct:
--
--   1. The EPHEMERAL elevated admin credential (this module). A human
--      operator's temporary admin key. It enters @prodbox@ ONLY via the
--      interactive prompt, is used once to mint the dedicated @prodbox@ IAM
--      identity, then discarded. It is never written to
--      @prodbox-config.dhall@, never written to Vault, never persisted on
--      disk.
--   2. The GENERATED OPERATIONAL @aws.*@ identity prodbox mints (lives in
--      Vault KV; @prodbox-config.dhall@ carries only a @SecretRef.Vault@
--      reference). Not handled here.
--   3. The TEST-SIMULATION admin credential
--      (@aws_admin_for_test_simulation@), a TEST-HARNESS-ONLY plaintext
--      fixture in @test-config.dhall@ whose sole job is to feed the same
--      interactive admin prompt so the suite-level IAM harness runs
--      non-interactively.
--
-- 'acquireAdminAwsCredentials' implements the unified cascade:
--
--   (a) if a @test-config.dhall@ with a populated
--       @aws_admin_for_test_simulation@ exists, use it (the harness
--       simulating the prompt); else
--   (b) if stdin is a TTY, prompt the operator (with AKIA/ASIA session-token
--       shape detection); else
--   (c) fail loud with guidance.
--
-- This module sits low in the import graph (it depends only on
-- 'Prodbox.Settings', 'Prodbox.Vault.Host', and 'Prodbox.CLI.Output') so the
-- canonical loader in 'Prodbox.Infra.LongLivedPulumiBackend' — and through it
-- every long-lived/teardown consumer — can call it without an import cycle
-- through the high-level 'Prodbox.Aws' surface.
module Prodbox.Aws.AdminCredentials
  ( SessionTokenPromptShape (..)
  , acquireAdminAwsCredentials
  , ensureAwsCliAvailable
  , promptAdminCredentials
  , sessionTokenPromptShape
  , showAdminCredentialsGuidance
  , validateAdminCredentials
  , validateAdminCredentialsInput
  )
where

import Control.Exception (IOException, bracket_, try)
import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.CLI.Output (writeOutput, writeOutputLine)
import Prodbox.Settings (Credentials (..))
import Prodbox.Vault.Host
  ( TestConfig (..)
  , TestConfigAdminCredentials
  , loadTestConfig
  )
import Prodbox.Vault.Host qualified as VaultHost
import System.Directory (findExecutable)
import System.IO
  ( hFlush
  , hGetEcho
  , hIsTerminalDevice
  , hSetEcho
  , stdin
  , stdout
  )
import System.IO.Error (isEOFError)

-- | Sprint 7.16: acquire the EPHEMERAL admin AWS credential. See the module
-- header for the (a) test-config / (b) TTY prompt / (c) fail-loud cascade.
-- Returns @Left@ with actionable guidance rather than throwing, so the
-- callers in 'Prodbox.Infra.LongLivedPulumiBackend' can wrap it in their
-- structured error rendering.
acquireAdminAwsCredentials :: FilePath -> IO (Either String Credentials)
acquireAdminAwsCredentials repoRoot = do
  testConfigResult <- loadTestConfig repoRoot
  case testConfigResult of
    Just (Left err) -> pure (Left err)
    Just (Right testConfig) ->
      pure (testConfigAdminCredentials (aws_admin_for_test_simulation testConfig))
    Nothing -> do
      isTty <- hIsTerminalDevice stdin
      if isTty
        then do
          credentials <- promptAdminCredentials ""
          pure (Right credentials)
        else
          pure
            ( Left
                "no admin AWS credential available: stdin is not a TTY and no \
                \test-config.dhall with a populated aws_admin_for_test_simulation \
                \block is present. Re-run interactively to enter a temporary admin \
                \credential at the prompt, or supply test-config.dhall (test \
                \harness / automation) so the admin prompt is simulated \
                \non-interactively. The ephemeral admin credential is never read \
                \from prodbox-config.dhall or Vault."
            )

-- | Project the cleartext test-config admin block onto 'Credentials',
-- enforcing the same all-or-nothing population rule the prompt validation
-- enforces. The test-config fixture is the harness simulating the operator
-- prompt, so an incompletely populated block is a misconfigured fixture.
testConfigAdminCredentials :: TestConfigAdminCredentials -> Either String Credentials
testConfigAdminCredentials block =
  validateAdminCredentials
    Credentials
      { access_key_id = VaultHost.access_key_id block
      , secret_access_key = VaultHost.secret_access_key block
      , session_token = VaultHost.session_token block
      , region = VaultHost.region block
      }

-- | Sprint 7.7 — how to prompt for the session token, derived from the
-- access-key prefix:
--
-- * @AKIA…@ (long-lived IAM user key) — no session token; skip the prompt.
-- * @ASIA…@ (STS-derived temporary key) — session token is required; prompt
--   as a hidden field.
-- * any other prefix (rare: @AGPA@, @AROA@, etc., or empty input) — fall back
--   to an optional prompt with an explanatory hint so the operator is never
--   silently forced into the wrong shape.
data SessionTokenPromptShape
  = SkipPrompt
  | PromptRequiredHidden
  | PromptOptionalWithHint
  deriving (Eq, Show)

-- | Auto-detect the prompt shape from the access-key prefix. Pure so unit
-- tests can cover the AKIA / ASIA / unknown branches without exercising IO.
sessionTokenPromptShape :: Text -> SessionTokenPromptShape
sessionTokenPromptShape accessKeyId
  | "AKIA" `Text.isPrefixOf` accessKeyId = SkipPrompt
  | "ASIA" `Text.isPrefixOf` accessKeyId = PromptRequiredHidden
  | otherwise = PromptOptionalWithHint

-- | Prompt the operator for a temporary admin AWS credential. Includes the
-- AKIA/ASIA session-token shape detection. The credential is never persisted.
promptAdminCredentials :: Text -> IO Credentials
promptAdminCredentials defaultRegion = do
  ensureAwsCliAvailable
  showAdminCredentialsGuidance
  accessKeyId <-
    Text.pack . trim
      <$> promptText "Temporary admin AWS access key ID (from the AWS console or IAM Identity Center)" Nothing
  secretAccessKey <-
    Text.pack . trim
      <$> promptSecret "Temporary admin AWS secret access key (hidden input)"
  sessionToken <- promptSessionTokenForKey accessKeyId
  regionRaw <-
    promptText
      "AWS region for admin operations (you can change it after regions are listed)"
      (Just (Text.unpack defaultRegion))
  validateAdminCredentialsInput
    Credentials
      { access_key_id = accessKeyId
      , secret_access_key = secretAccessKey
      , session_token = sessionToken
      , region = Text.pack (trim regionRaw)
      }

-- | IO wrapper around 'sessionTokenPromptShape'.
promptSessionTokenForKey :: Text -> IO (Maybe Text)
promptSessionTokenForKey accessKeyId =
  case sessionTokenPromptShape accessKeyId of
    SkipPrompt -> pure Nothing
    PromptRequiredHidden -> do
      raw <-
        promptSecret
          "AWS session token (required for STS-derived keys, hidden input)"
      pure (Just (Text.pack (trim raw)))
    PromptOptionalWithHint -> do
      writeOutputLine
        ( "  Access key prefix not recognized (AKIA/ASIA); if this came from "
            ++ "STS / Identity Center, paste the matching session token, "
            ++ "otherwise press Enter."
        )
      raw <- promptText "AWS session token (leave blank for long-lived IAM user keys)" Nothing
      pure (normalizeOptionalText (Text.pack raw))

ensureAwsCliAvailable :: IO ()
ensureAwsCliAvailable = do
  maybeAws <- findExecutable "aws"
  case maybeAws of
    Nothing -> fail "The AWS CLI is required for interactive setup flows"
    Just _ -> pure ()

showAdminCredentialsGuidance :: IO ()
showAdminCredentialsGuidance = do
  writeOutputLine "Temporary admin AWS credential guidance:"
  writeOutputLine
    "1. Sign in with an identity that can manage IAM users, access keys, Route 53"
  writeOutputLine "   hosted zones, and Service Quotas. Two credential shapes are supported:"
  writeOutputLine
    "   a. Long-lived IAM user key (AKIA…): IAM console -> Users -> <temporary admin user>"
  writeOutputLine "      -> Security credentials -> Create access key. No session token."
  writeOutputLine
    "   b. STS-derived temporary key (ASIA…): IAM Identity Center \"Access keys\" panel,"
  writeOutputLine
    "      or `aws sts get-session-token` / `aws sts assume-role`. Includes a session"
  writeOutputLine "      token; paste it when prompted."
  writeOutputLine
    "2. Paste the access key ID and secret below. `prodbox` auto-detects the shape from"
  writeOutputLine
    "   the access-key prefix and only asks for a session token when needed (ASIA…)."
  writeOutputLine "3. `prodbox` never persists this temporary admin key. Delete it after the"
  writeOutputLine "   command completes."
  writeOutputLine ""

validateAdminCredentials :: Credentials -> Either String Credentials
validateAdminCredentials credentials = do
  let normalized =
        Credentials
          { access_key_id = Text.strip (access_key_id credentials)
          , secret_access_key = Text.strip (secret_access_key credentials)
          , session_token = normalizeOptionalText =<< session_token credentials
          , region = Text.strip (region credentials)
          }
  if Text.null (access_key_id normalized)
    then Left "Admin AWS access key ID is required"
    else pure ()
  if Text.null (secret_access_key normalized)
    then Left "Admin AWS secret access key is required"
    else pure ()
  if Text.null (region normalized)
    then Left "Admin AWS region is required"
    else pure ()
  pure normalized

validateAdminCredentialsInput :: Credentials -> IO Credentials
validateAdminCredentialsInput credentials =
  either fail pure (validateAdminCredentials credentials)

promptText :: String -> Maybe String -> IO String
promptText message maybeDefault = do
  writeOutput (message ++ defaultSuffix maybeDefault ++ ": ")
  hFlush stdout
  input <- readPromptLine message
  pure $
    case (trim input, maybeDefault) of
      ("", Just defaultValue) -> defaultValue
      (value, _) -> value
 where
  defaultSuffix = maybe "" (\defaultValue -> " [" ++ defaultValue ++ "]")

promptSecret :: String -> IO String
promptSecret message = do
  terminal <- hIsTerminalDevice stdin
  writeOutput (message ++ ": ")
  hFlush stdout
  if terminal
    then do
      originalEcho <- hGetEcho stdin
      value <- bracket_ (hSetEcho stdin False) (hSetEcho stdin originalEcho) (readPromptLine message)
      writeOutputLine ""
      pure (trim value)
    else trim <$> readPromptLine message

readPromptLine :: String -> IO String
readPromptLine message = do
  lineResult <- try getLine :: IO (Either IOException String)
  case lineResult of
    Right line -> pure line
    Left err
      | isEOFError err ->
          fail
            ( "Input ended while reading `"
                ++ message
                ++ "`. Re-run the command interactively with a temporary admin AWS credential."
            )
      | otherwise ->
          fail
            ( "Failed to read input for `"
                ++ message
                ++ "`: "
                ++ show err
            )

normalizeOptionalText :: Text -> Maybe Text
normalizeOptionalText value =
  if Text.strip value == ""
    then Nothing
    else Just value

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
 where
  dropWhileEnd predicate = foldr (\x xs -> if predicate x && null xs then [] else x : xs) []
