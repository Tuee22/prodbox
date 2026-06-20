{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 1.35: the typed secret-reference contract. Sensitive configuration
-- fields carry a 'SecretRef' — a reference to where a secret lives — rather
-- than a plaintext value, so @prodbox.dhall@ never holds secret
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
-- production-plaintext-rejection validator, the resolver's local arm
-- (@TestPlaintext@ in the test harness only), and the Vault KV resolver seam
-- consumed by the future config-loader migration. The compatibility
-- 'resolveSecretRef' helper still fails loud for @Vault@ / @TransitKey@ unless
-- a Vault reader is explicitly supplied.
module Prodbox.Settings.SecretRef
  ( SecretRef (..)
  , VaultSecretRef (..)
  , PromptSpec (..)
  , SecretRefMode (..)
  , SecretRefError (..)
  , secretRefIsPlaintext
  , validateProductionSecretRef
  , resolveSecretRef
  , resolveSecretRefWithVault
  , resolveSecretRefFromVault
  , renderSecretRefError
  )
where

import Data.Char qualified as Char
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall
  ( FromDhall (..)
  , InterpretOptions (..)
  , ToDhall (..)
  , defaultInterpretOptions
  , genericAutoWith
  , genericToDhallWith
  )
import GHC.Generics (Generic)
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Vault.Client
  ( VaultAddress
  , VaultToken
  , vaultKvReadV2
  )

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

-- | Sprint 7.17: the dual encoder, used to render the @default@ value and the
-- committed @prodbox-config-types.dhall@ schema from the Haskell source of
-- truth. The 'InterpretOptions' MUST mirror the 'FromDhall' decoder above so
-- the emitted Dhall round-trips through the same decoder.
instance ToDhall SecretRef where
  injectWith _ =
    genericToDhallWith
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

instance ToDhall VaultSecretRef where
  injectWith _ =
    genericToDhallWith
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

instance ToDhall PromptSpec where
  injectWith _ =
    genericToDhallWith
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
  | -- | Vault was reachable but the referenced KV field was absent.
    SecretRefVaultFieldMissing
  | -- | Vault returned an HTTP/decode error while reading the referenced secret.
    SecretRefVaultReadFailed String
  | -- | A `Prompt` reference cannot be resolved non-interactively.
    SecretRefPromptUnsupported Text
  deriving (Eq, Show)

renderSecretRefError :: SecretRefError -> String
renderSecretRefError err = case err of
  SecretRefPlaintextInProduction ->
    "plaintext secret values are forbidden in production config; use a SecretRef.Vault reference"
  SecretRefVaultUnavailable ->
    "Vault-backed secret reference is not resolvable: Vault is unavailable or its read path is not yet wired"
  SecretRefVaultFieldMissing ->
    "Vault-backed secret reference is missing the requested field"
  SecretRefVaultReadFailed detail ->
    "Vault-backed secret reference failed to read: " ++ detail
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

-- | Resolve a 'SecretRef' to its plaintext value without a Vault reader.
-- 'SecretRefTestPlaintext' resolves only in 'TestHarnessMode'; Vault-backed
-- references fail loud on this compatibility path.
resolveSecretRef :: SecretRefMode -> SecretRef -> IO (Either SecretRefError Text)
resolveSecretRef mode =
  resolveSecretRefWithVault mode (\_ -> pure (Left SecretRefVaultUnavailable))

-- | Resolve a 'SecretRef' using the supplied Vault KV reader. This is the
-- unit-testable seam used by the production Vault-backed resolver and by the
-- future config loader that migrates sensitive fields from plaintext to
-- SecretRef references.
resolveSecretRefWithVault
  :: SecretRefMode
  -> (VaultSecretRef -> IO (Either SecretRefError Text))
  -> SecretRef
  -> IO (Either SecretRefError Text)
resolveSecretRefWithVault mode vaultReader ref = case ref of
  SecretRefTestPlaintext value -> case mode of
    TestHarnessMode -> pure (Right value)
    ProductionMode -> pure (Left SecretRefPlaintextInProduction)
  SecretRefVault vaultRef -> vaultReader vaultRef
  SecretRefTransitKey _ -> pure (Left SecretRefVaultUnavailable)
  SecretRefPrompt spec -> pure (Left (SecretRefPromptUnsupported (promptSpecName spec)))

-- | Resolve a 'SecretRef.Vault' through Vault KV v2 using a token-bearing
-- client. Transit keys are handles, not readable plaintext values, and remain
-- intentionally unresolved on this path.
resolveSecretRefFromVault
  :: SecretRefMode
  -> VaultAddress
  -> VaultToken
  -> SecretRef
  -> IO (Either SecretRefError Text)
resolveSecretRefFromVault mode address token =
  resolveSecretRefWithVault mode readVaultRef
 where
  readVaultRef vaultRef = do
    result <-
      vaultKvReadV2
        address
        token
        (vaultSecretMount vaultRef)
        (vaultSecretPath vaultRef)
    pure $ case result of
      Left err -> Left (SecretRefVaultReadFailed (renderHttpError err))
      Right fields ->
        maybe
          (Left SecretRefVaultFieldMissing)
          Right
          (Map.lookup (vaultSecretField vaultRef) fields)
