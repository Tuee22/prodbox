{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 1.35: the typed secret-reference contract. Sensitive configuration
-- fields carry a 'SecretRef' — a reference to where a secret lives — rather
-- than a plaintext value, so @prodbox-config.dhall@ never holds secret
-- material (see @documents/engineering/vault_doctrine.md@ §3–§4).
--
-- The union has __no @FileSecret@ arm__: Secret-mounted plaintext Dhall
-- fragments are removed, not bridged, and in-cluster consumers authenticate to
-- Vault directly via Vault Kubernetes auth. 'SecretRefVault' /
-- 'SecretRefTransitKey' are the production targets; 'SecretRefPrompt' is
-- CLI-only one-off elevated material; 'SecretRefTestPlaintext' is accepted only
-- by the test harness.
--
-- This module lands the type, its 'FromDhall' decoder, the
-- production-plaintext-rejection validator, and the resolver's local arm
-- (@TestPlaintext@ in the test harness only). Live @SecretRef.Vault@ resolution
-- is wired once the Vault read path is in place (Sprint @1.36@); until then
-- 'resolveSecretRef' reports 'SecretRefVaultUnavailable' for @Vault@ /
-- @TransitKey@ so a production config that references Vault fails loud rather
-- than silently.
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

import Data.Char qualified as Char
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall
  ( FromDhall (..)
  , InterpretOptions (..)
  , defaultInterpretOptions
  , genericAutoWith
  )
import GHC.Generics (Generic)

-- | A reference to where a secret lives. Only 'SecretRefTestPlaintext' carries
-- a literal value, and it is rejected outside the test harness. There is no
-- @FileSecret@ arm — Secret-mounted plaintext Dhall fragments are removed, not
-- bridged.
data SecretRef
  = -- | A Vault KV read: @kv/...#field@. The target of every production secret.
    SecretRefVault VaultSecretRef
  | -- | A Vault Transit key handle (encryption-as-a-service; not a readable
    -- value).
    SecretRefTransitKey Text
  | -- | One-off elevated material the CLI prompts for; never written to disk.
    SecretRefPrompt PromptSpec
  | -- | A literal plaintext value. Test harness only — rejected in production.
    SecretRefTestPlaintext Text
  deriving (Eq, Show, Generic)

-- | Decode the Dhall union
-- @\< Vault : { mount, path, field } | TransitKey : Text | Prompt : { name, purpose } | TestPlaintext : Text \>@.
-- The constructor-name prefix @SecretRef@ is stripped so the Haskell
-- 'SecretRefVault' maps to the Dhall alternative @Vault@.
instance FromDhall SecretRef where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {constructorModifier = dropPrefix "SecretRef"}

data VaultSecretRef = VaultSecretRef
  { vaultSecretMount :: Text
  , vaultSecretPath :: Text
  , vaultSecretField :: Text
  }
  deriving (Eq, Show, Generic)

instance FromDhall VaultSecretRef where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = dropPrefixLowerFirst "vaultSecret"}

data PromptSpec = PromptSpec
  { promptSpecName :: Text
  , promptSpecPurpose :: Text
  }
  deriving (Eq, Show, Generic)

instance FromDhall PromptSpec where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = dropPrefixLowerFirst "promptSpec"}

-- | Strip a Haskell field-name prefix and lower-case the first remaining
-- character so the Haskell field @vaultSecretMount@ decodes the Dhall record
-- field @mount@.
dropPrefixLowerFirst :: Text -> Text -> Text
dropPrefixLowerFirst prefix name =
  lowerFirst (fromMaybe name (Text.stripPrefix prefix name))

lowerFirst :: Text -> Text
lowerFirst value = case Text.uncons value of
  Just (firstChar, rest) -> Text.cons (Char.toLower firstChar) rest
  Nothing -> value

-- | Strip a Haskell constructor-name prefix so the Haskell constructor
-- @SecretRefVault@ decodes the Dhall union alternative @Vault@.
dropPrefix :: Text -> Text -> Text
dropPrefix prefix name = fromMaybe name (Text.stripPrefix prefix name)

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
  deriving (Eq, Show)

renderSecretRefError :: SecretRefError -> String
renderSecretRefError err = case err of
  SecretRefPlaintextInProduction ->
    "plaintext secret values are forbidden in production config; use a SecretRef.Vault reference"
  SecretRefVaultUnavailable ->
    "Vault-backed secret reference is not resolvable: Vault is unavailable or its read path is not yet wired"
  SecretRefPromptUnsupported name ->
    "prompted secret " ++ Text.unpack name ++ " cannot be resolved non-interactively"

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

-- | Resolve a 'SecretRef' to its plaintext value. 'SecretRefTestPlaintext'
-- resolves only in 'TestHarnessMode'; 'SecretRefVault' / 'SecretRefTransitKey' /
-- 'SecretRefPrompt' are not resolvable on this path yet and fail loud.
resolveSecretRef :: SecretRefMode -> SecretRef -> IO (Either SecretRefError Text)
resolveSecretRef mode ref = case ref of
  SecretRefTestPlaintext value -> case mode of
    TestHarnessMode -> pure (Right value)
    ProductionMode -> pure (Left SecretRefPlaintextInProduction)
  SecretRefVault _ -> pure (Left SecretRefVaultUnavailable)
  SecretRefTransitKey _ -> pure (Left SecretRefVaultUnavailable)
  SecretRefPrompt spec -> pure (Left (SecretRefPromptUnsupported (promptSpecName spec)))
