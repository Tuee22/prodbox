{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.20: pure Vault seal-mode model. The root cluster uses Vault's
-- default Shamir seal and writes its init material to the host-side encrypted
-- unlock bundle. Child clusters use Vault's Transit auto-unseal pointed at
-- the parent's Vault; their recovery keys and initial root token are stored in
-- the parent's Vault KV, never on the child.
module Prodbox.Vault.Seal
  ( ChildSealCustody (..)
  , ShamirSealConfig (..)
  , TransitSealConfig (..)
  , VaultSealMode (..)
  , childInitCustodyFromInitResponse
  , childInitCustodyVaultFields
  , childSealCustodyFromInitResponse
  , defaultRootShamirSealConfig
  , defaultTransitSealConfig
  , initRequestForSealMode
  , renderVaultSealHcl
  , transitSealPolicyDocument
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Cluster.Federation
  ( ChildInitCustody (..)
  , ChildMetadata (..)
  , encodeChildInitCustody
  )
import Prodbox.Vault.Client
  ( InitRequest (..)
  , InitResponse (..)
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

data ChildSealCustody = ChildSealCustody
  { childSealCustodyMetadata :: ChildMetadata
  , childSealCustodyInit :: ChildInitCustody
  }
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

childSealCustodyFromInitResponse
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> InitResponse
  -> ChildSealCustody
childSealCustodyFromInitResponse parentClusterId childClusterId childVaultAddress childVaultNamespace transitKey response =
  ChildSealCustody
    { childSealCustodyMetadata =
        ChildMetadata
          { childMetadataClusterId = childClusterId
          , childMetadataVaultAddress = childVaultAddress
          , childMetadataTransitKey = transitKey
          , childMetadataVaultNamespace = childVaultNamespace
          , childMetadataParentClusterId = parentClusterId
          , childMetadataEndpoints = Map.empty
          , childMetadataKubeconfigReference = Nothing
          , childMetadataAccountId = Nothing
          , childMetadataPulumiStacks = Map.empty
          }
    , childSealCustodyInit =
        childInitCustodyFromInitResponse childClusterId transitKey response
    }

childInitCustodyFromInitResponse :: Text -> Text -> InitResponse -> ChildInitCustody
childInitCustodyFromInitResponse childClusterId transitKey response =
  ChildInitCustody
    { childInitClusterId = childClusterId
    , childInitRecoveryKeysBase64 = initResponseRecoveryKeysBase64 response
    , childInitRootToken = initResponseRootToken response
    , childInitTransitKey = transitKey
    }

childInitCustodyVaultFields :: ChildInitCustody -> Map Text Text
childInitCustodyVaultFields custody =
  Map.singleton
    "payload_json"
    (TextEncoding.decodeUtf8 (encodeChildInitCustody custody))

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
