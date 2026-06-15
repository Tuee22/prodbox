{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.38: the cluster's __unencrypted basics__ — the minimal,
-- non-revealing bootstrap a host needs to reach and unseal this cluster's
-- Vault when Vault is sealed (config_doctrine.md §1a). It carries only the
-- cluster id, this cluster's Vault address, the seal mode, and (for a child
-- cluster) the parent reference it auto-unseals against. It carries no
-- workloads, no downstream clusters, and no credentials, so it is the only
-- thing legible while Vault is sealed and the in-force config is opaque
-- ciphertext (see "Prodbox.Config.InForce").
module Prodbox.Config.Basics
  ( UnencryptedBasics (..)
  , SealMode (..)
  , ParentRef (..)
  , BasicsError (..)
  , basicsToJson
  , basicsFromJson
  , validateBasics
  , isRootCluster
  , renderBasicsError
  )
where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecodeStrict'
  , object
  , withObject
  , withText
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text

-- | How this cluster's Vault unseals. A host that cannot reach an unsealed
-- Vault must still know the seal mode to drive recovery.
data SealMode
  = -- | Root cluster: the operator unlock bundle drives a Shamir unseal.
    SealModeShamir
  | -- | Child cluster: auto-unseals against a parent's Transit key.
    SealModeTransit
  deriving (Eq, Show)

instance ToJSON SealMode where
  toJSON SealModeShamir = Aeson.String "shamir"
  toJSON SealModeTransit = Aeson.String "transit"

instance FromJSON SealMode where
  parseJSON = withText "SealMode" parseSealModeText

parseSealModeText :: Text -> Parser SealMode
parseSealModeText value = case value of
  "shamir" -> pure SealModeShamir
  "transit" -> pure SealModeTransit
  other -> fail ("unknown seal mode: " ++ Text.unpack other)

-- | For a child cluster only: the parent it contacts to auto-unseal. Carries
-- no credentials — just the parent's identity, Vault address, and the Transit
-- key name the child's seal is bound to.
data ParentRef = ParentRef
  { parentRefClusterId :: Text
  , parentRefVaultAddress :: Text
  , parentRefTransitKey :: Text
  }
  deriving (Eq, Show)

instance ToJSON ParentRef where
  toJSON ref =
    object
      [ "cluster_id" .= parentRefClusterId ref
      , "vault_address" .= parentRefVaultAddress ref
      , "transit_key" .= parentRefTransitKey ref
      ]

instance FromJSON ParentRef where
  parseJSON =
    withObject "ParentRef" $ \o ->
      ParentRef
        <$> o .: "cluster_id"
        <*> o .: "vault_address"
        <*> o .: "transit_key"

data UnencryptedBasics = UnencryptedBasics
  { basicsClusterId :: Text
  , basicsVaultAddress :: Text
  , basicsSealMode :: SealMode
  , basicsParentRef :: Maybe ParentRef
  , basicsFormatVersion :: Int
  }
  deriving (Eq, Show)

instance ToJSON UnencryptedBasics where
  toJSON basics =
    object
      [ "cluster_id" .= basicsClusterId basics
      , "vault_address" .= basicsVaultAddress basics
      , "seal_mode" .= basicsSealMode basics
      , "parent_ref" .= basicsParentRef basics
      , "format_version" .= basicsFormatVersion basics
      ]

instance FromJSON UnencryptedBasics where
  parseJSON =
    withObject "UnencryptedBasics" $ \o ->
      UnencryptedBasics
        <$> o .: "cluster_id"
        <*> o .: "vault_address"
        <*> o .: "seal_mode"
        <*> o .:? "parent_ref"
        <*> o .: "format_version"

data BasicsError
  = BasicsFieldEmpty Text
  | BasicsBadFormatVersion Int
  | BasicsParentRefMismatch Text
  | BasicsMalformed String
  deriving (Eq, Show)

renderBasicsError :: BasicsError -> String
renderBasicsError err = case err of
  BasicsFieldEmpty field ->
    "unencrypted basics field must not be empty: " ++ Text.unpack field
  BasicsBadFormatVersion version ->
    "unencrypted basics format_version must be 1, got " ++ show version
  BasicsParentRefMismatch detail ->
    "unencrypted basics seal-mode / parent-ref mismatch: " ++ Text.unpack detail
  BasicsMalformed detail ->
    "unencrypted basics could not be decoded: " ++ detail

-- | Canonical serialization of the basics (the only legible cluster state when
-- Vault is sealed).
basicsToJson :: UnencryptedBasics -> ByteString
basicsToJson = BL.toStrict . Aeson.encode

basicsFromJson :: ByteString -> Either BasicsError UnencryptedBasics
basicsFromJson bytes = case eitherDecodeStrict' bytes of
  Left err -> Left (BasicsMalformed err)
  Right basics -> Right basics

-- | Pure invariants: non-empty cluster id + Vault address, @format_version@ of
-- 1, and the seal-mode / parent-ref coherence rule — a Shamir (root) cluster
-- has no parent; a Transit (child) cluster must carry one.
validateBasics :: UnencryptedBasics -> Either BasicsError ()
validateBasics basics = do
  requireNonEmpty "cluster_id" (basicsClusterId basics)
  requireNonEmpty "vault_address" (basicsVaultAddress basics)
  if basicsFormatVersion basics /= 1
    then Left (BasicsBadFormatVersion (basicsFormatVersion basics))
    else Right ()
  case (basicsSealMode basics, basicsParentRef basics) of
    (SealModeShamir, Nothing) -> Right ()
    (SealModeShamir, Just _) ->
      Left (BasicsParentRefMismatch "a root (shamir) cluster must not carry a parent_ref")
    (SealModeTransit, Just _) -> Right ()
    (SealModeTransit, Nothing) ->
      Left (BasicsParentRefMismatch "a child (transit) cluster must carry a parent_ref")

requireNonEmpty :: Text -> Text -> Either BasicsError ()
requireNonEmpty field value
  | Text.null (Text.strip value) = Left (BasicsFieldEmpty field)
  | otherwise = Right ()

-- | A root cluster unseals via Shamir and has no parent. Child clusters
-- auto-unseal against a parent and are not the root of the trust tree.
isRootCluster :: UnencryptedBasics -> Bool
isRootCluster basics =
  basicsSealMode basics == SealModeShamir && isNothing (basicsParentRef basics)
