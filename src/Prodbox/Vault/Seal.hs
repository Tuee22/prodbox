{-# LANGUAGE OverloadedStrings #-}

-- | Pure Vault seal-mode rendering. Child clusters use Vault Transit
-- auto-unseal pointed at the parent. Recovery custody and initialization are
-- owned by the typed Bootstrap Broker protocol, not by this chart-oriented
-- module; in particular this module has no initial-token or child-custody type.
module Prodbox.Vault.Seal
  ( ShamirSealConfig (..)
  , TransitSealConfig (..)
  , VaultSealMode (..)
  , defaultRootShamirSealConfig
  , defaultTransitSealConfig
  , initRequestForSealMode
  , renderVaultSealHcl
  , transitSealPolicyDocument
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Vault.Client
  ( InitRequest (..)
  , VaultAddress (..)
  )

data ShamirSealConfig = ShamirSealConfig
  { shamirSealSecretShares :: Natural
  , shamirSealSecretThreshold :: Natural
  }
  deriving (Eq, Show)

data TransitSealConfig = TransitSealConfig
  { transitSealParentAddress :: VaultAddress
  , transitSealKeyName :: Text
  , transitSealMountPath :: Text
  , transitSealRecoveryShares :: Natural
  , transitSealRecoveryThreshold :: Natural
  , transitSealTlsSkipVerify :: Bool
  , transitSealDisableRenewal :: Bool
  }
  deriving (Eq, Show)

data VaultSealMode
  = VaultSealRootShamir ShamirSealConfig
  | VaultSealChildTransit TransitSealConfig
  deriving (Eq, Show)

defaultRootShamirSealConfig :: ShamirSealConfig
defaultRootShamirSealConfig =
  ShamirSealConfig
    { shamirSealSecretShares = 5
    , shamirSealSecretThreshold = 3
    }

defaultTransitSealConfig :: VaultAddress -> Text -> TransitSealConfig
defaultTransitSealConfig parentAddress keyName =
  TransitSealConfig
    { transitSealParentAddress = parentAddress
    , transitSealKeyName = keyName
    , transitSealMountPath = "transit/"
    , transitSealRecoveryShares = 5
    , transitSealRecoveryThreshold = 3
    , transitSealTlsSkipVerify = False
    , transitSealDisableRenewal = False
    }

initRequestForSealMode :: VaultSealMode -> InitRequest
initRequestForSealMode sealMode = case sealMode of
  VaultSealRootShamir config ->
    InitRequest
      { initRequestSecretShares = Just (shamirSealSecretShares config)
      , initRequestSecretThreshold = Just (shamirSealSecretThreshold config)
      , initRequestRecoveryShares = Nothing
      , initRequestRecoveryThreshold = Nothing
      , initRequestPgpKeys = []
      , initRequestRootTokenPgpKey = Nothing
      }
  VaultSealChildTransit config ->
    InitRequest
      { initRequestSecretShares = Nothing
      , initRequestSecretThreshold = Nothing
      , initRequestRecoveryShares = Just (transitSealRecoveryShares config)
      , initRequestRecoveryThreshold = Just (transitSealRecoveryThreshold config)
      , initRequestPgpKeys = []
      , initRequestRootTokenPgpKey = Nothing
      }

renderVaultSealHcl :: VaultSealMode -> Text
renderVaultSealHcl sealMode = case sealMode of
  VaultSealRootShamir _ -> ""
  VaultSealChildTransit config ->
    Text.unlines
      [ "    seal \"transit\" {"
      , "      address = " <> hclString (unVaultAddress (transitSealParentAddress config))
      , "      disable_renewal = " <> hclString (hclBool (transitSealDisableRenewal config))
      , "      key_name = " <> hclString (transitSealKeyName config)
      , "      mount_path = " <> hclString (transitSealMountPath config)
      , "      tls_skip_verify = " <> hclString (hclBool (transitSealTlsSkipVerify config))
      , "    }"
      ]

transitSealPolicyDocument :: Text -> Text
transitSealPolicyDocument keyName =
  Text.unlines
    [ "path \"transit/encrypt/" <> keyName <> "\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/decrypt/" <> keyName <> "\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    ]

hclString :: Text -> Text
hclString value =
  "\"" <> Text.concatMap escapeHcl value <> "\""

escapeHcl :: Char -> Text
escapeHcl ch = case ch of
  '"' -> "\\\""
  '\\' -> "\\\\"
  _ -> Text.singleton ch

hclBool :: Bool -> Text
hclBool True = "true"
hclBool False = "false"
