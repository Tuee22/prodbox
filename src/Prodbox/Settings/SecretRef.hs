{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 1.35: the typed secret-reference contract. Sensitive configuration
-- fields carry a 'SecretRef' — a reference to where a secret lives — rather
-- than a plaintext value, so @prodbox-config.dhall@ never holds secret
-- material (see @documents/engineering/vault_doctrine.md@ §3–§4).
--
-- This module lands the type, the production-plaintext-rejection validator,
-- and the resolver's local arms (`FileSecret`, and `TestPlaintext` in the test
-- harness only). The Dhall-schema field migration and the live
-- `SecretRef.Vault` resolution are wired once the Vault read path is in place;
-- 'resolveSecretRef' reports 'SecretRefVaultUnavailable' for `Vault` /
-- `TransitKey` until then, so a production config that references Vault fails
-- loud rather than silently.
module Prodbox.Settings.SecretRef
  ( SecretRef (..)
  , VaultSecretRef (..)
  , PromptSpec (..)
  , SecretRefMode (..)
  , SecretRefError (..)
  , secretRefIsPlaintext
  , validateProductionSecretRef
  , resolveSecretRef
  , renderSecretRefError
  )
where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO

-- | A reference to where a secret lives. Only 'SecretRefTestPlaintext' carries
-- a literal value, and it is rejected outside the test harness.
data SecretRef
  = -- | A Vault KV read: @kv/...#field@. The target of every production secret.
    SecretRefVault VaultSecretRef
  | -- | A Vault Transit key handle (encryption-as-a-service; not a readable
    -- value).
    SecretRefTransitKey Text
  | -- | One-off elevated material the CLI prompts for; never written to disk.
    SecretRefPrompt PromptSpec
  | -- | A file-mounted secret (the migration bridge for Secret-mounted Dhall).
    SecretRefFile FilePath
  | -- | A literal plaintext value. Test harness only — rejected in production.
    SecretRefTestPlaintext Text
  deriving (Eq, Show)

data VaultSecretRef = VaultSecretRef
  { vaultSecretMount :: Text
  , vaultSecretPath :: Text
  , vaultSecretField :: Text
  }
  deriving (Eq, Show)

data PromptSpec = PromptSpec
  { promptSpecName :: Text
  , promptSpecPurpose :: Text
  }
  deriving (Eq, Show)

-- | Whether secrets are being resolved for a production path or by the test
-- harness. 'TestHarnessMode' is the only mode that may resolve a
-- 'SecretRefTestPlaintext'.
data SecretRefMode
  = ProductionMode
  | TestHarnessMode
  deriving (Eq, Show)

data SecretRefError
  = -- | A plaintext value appeared on a production path.
    SecretRefPlaintextInProduction
  | -- | A `Vault` / `TransitKey` reference was resolved before the Vault read
    -- path is wired (or against a sealed/unreachable Vault).
    SecretRefVaultUnavailable
  | -- | A `Prompt` reference cannot be resolved non-interactively.
    SecretRefPromptUnsupported Text
  | -- | A `FileSecret` could not be read.
    SecretRefFileReadFailed FilePath String
  deriving (Eq, Show)

renderSecretRefError :: SecretRefError -> String
renderSecretRefError err = case err of
  SecretRefPlaintextInProduction ->
    "plaintext secret values are forbidden in production config; use a SecretRef.Vault reference"
  SecretRefVaultUnavailable ->
    "Vault-backed secret reference is not resolvable: Vault is unavailable or its read path is not yet wired"
  SecretRefPromptUnsupported name ->
    "prompted secret " ++ Text.unpack name ++ " cannot be resolved non-interactively"
  SecretRefFileReadFailed path detail ->
    "file-mounted secret " ++ path ++ " could not be read: " ++ detail

-- | True for a literal plaintext reference. Used by @prodbox config validate@
-- to reject plaintext in production config.
secretRefIsPlaintext :: SecretRef -> Bool
secretRefIsPlaintext ref = case ref of
  SecretRefTestPlaintext _ -> True
  _ -> False

-- | A production config field must not carry a plaintext secret value.
validateProductionSecretRef :: SecretRef -> Either SecretRefError ()
validateProductionSecretRef ref
  | secretRefIsPlaintext ref = Left SecretRefPlaintextInProduction
  | otherwise = Right ()

-- | Resolve a 'SecretRef' to its plaintext value. 'TestPlaintext' resolves
-- only in 'TestHarnessMode'; 'FileSecret' reads the file; 'Vault' /
-- 'TransitKey' / 'Prompt' are not resolvable on this path yet and fail loud.
resolveSecretRef :: SecretRefMode -> SecretRef -> IO (Either SecretRefError Text)
resolveSecretRef mode ref = case ref of
  SecretRefTestPlaintext value -> case mode of
    TestHarnessMode -> pure (Right value)
    ProductionMode -> pure (Left SecretRefPlaintextInProduction)
  SecretRefFile path -> do
    result <- try (TextIO.readFile path) :: IO (Either IOException Text)
    pure $ case result of
      Left ioErr -> Left (SecretRefFileReadFailed path (show ioErr))
      Right contents -> Right (Text.strip contents)
  SecretRefVault _ -> pure (Left SecretRefVaultUnavailable)
  SecretRefTransitKey _ -> pure (Left SecretRefVaultUnavailable)
  SecretRefPrompt spec -> pure (Left (SecretRefPromptUnsupported (promptSpecName spec)))
