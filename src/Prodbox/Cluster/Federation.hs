{-# LANGUAGE OverloadedStrings #-}

-- | Typed cluster-federation custody foundation plus the pure pieces consumed
-- by the Sprint 4.32 live writer: parent-owned child init material and metadata
-- live under Vault KV paths, child-facing namespaces/transit-key names are
-- opaque, and parent/root mutations fail closed unless the root token is
-- available.
module Prodbox.Cluster.Federation
  ( ChildBootstrapCredential (..)
  , ChildIndex (..)
  , ChildInitCustody (..)
  , ChildMetadata (..)
  , ChildRegistrationPlan (..)
  , FederationWriteAuthority (..)
  , FederationWriteDecision (..)
  , childBootstrapKvPath
  , childBootstrapKvLogicalPath
  , childBootstrapVaultFields
  , childIndexVaultFields
  , childInitKvPath
  , childInitKvLogicalPath
  , childMetadataKvPath
  , childMetadataKvLogicalPath
  , childMetadataVaultFields
  , childRegistrationPlan
  , childTransitKeyName
  , childTransitSealPolicyDocument
  , childVaultNamespace
  , decodeChildBootstrapCredential
  , decodeChildIndex
  , decodeChildInitCustody
  , decodeChildMetadata
  , decodePayloadJsonField
  , encodeChildBootstrapCredential
  , encodeChildIndex
  , encodeChildInitCustody
  , encodeChildMetadata
  , federationWriteDecision
  , federationChildrenIndexKvPath
  , federationChildrenIndexKvLogicalPath
  , renderChildRegistrationPlan
  , renderFederationWriteBlock
  , upsertChildIndex
  )
where

import Crypto.Hash.SHA256 (hmac)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecodeStrict'
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString, word8HexFixed)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)

data ChildInitCustody = ChildInitCustody
  { childInitClusterId :: Text
  , childInitRecoveryKeysBase64 :: [Text]
  , childInitRootToken :: Text
  , childInitTransitKey :: Text
  }
  deriving (Eq)

instance Show ChildInitCustody where
  show custody =
    "ChildInitCustody {childInitClusterId = "
      ++ show (childInitClusterId custody)
      ++ ", childInitRecoveryKeysBase64 = <redacted>"
      ++ ", childInitRootToken = <redacted>"
      ++ ", childInitTransitKey = "
      ++ show (childInitTransitKey custody)
      ++ "}"

instance ToJSON ChildInitCustody where
  toJSON custody =
    object
      [ "cluster_id" .= childInitClusterId custody
      , "recovery_keys_base64" .= childInitRecoveryKeysBase64 custody
      , "initial_root_token" .= childInitRootToken custody
      , "transit_key" .= childInitTransitKey custody
      ]

instance FromJSON ChildInitCustody where
  parseJSON =
    withObject "ChildInitCustody" $ \o ->
      ChildInitCustody
        <$> o .: "cluster_id"
        <*> o .: "recovery_keys_base64"
        <*> o .: "initial_root_token"
        <*> o .: "transit_key"

data ChildMetadata = ChildMetadata
  { childMetadataClusterId :: Text
  , childMetadataVaultAddress :: Text
  , childMetadataTransitKey :: Text
  , childMetadataVaultNamespace :: Text
  , childMetadataParentClusterId :: Text
  , childMetadataEndpoints :: Map Text Text
  , childMetadataKubeconfigReference :: Maybe Text
  , childMetadataAccountId :: Maybe Text
  , childMetadataPulumiStacks :: Map Text Text
  }
  deriving (Eq, Show)

instance ToJSON ChildMetadata where
  toJSON metadata =
    object
      [ "cluster_id" .= childMetadataClusterId metadata
      , "vault_address" .= childMetadataVaultAddress metadata
      , "transit_key" .= childMetadataTransitKey metadata
      , "vault_namespace" .= childMetadataVaultNamespace metadata
      , "parent_cluster_id" .= childMetadataParentClusterId metadata
      , "endpoints" .= childMetadataEndpoints metadata
      , "kubeconfig_reference" .= childMetadataKubeconfigReference metadata
      , "account_id" .= childMetadataAccountId metadata
      , "pulumi_stacks" .= childMetadataPulumiStacks metadata
      ]

instance FromJSON ChildMetadata where
  parseJSON =
    withObject "ChildMetadata" $ \o ->
      ChildMetadata
        <$> o .: "cluster_id"
        <*> o .: "vault_address"
        <*> o .: "transit_key"
        <*> o .: "vault_namespace"
        <*> o .: "parent_cluster_id"
        <*> o .:? "endpoints" .!= Map.empty
        <*> o .:? "kubeconfig_reference"
        <*> o .:? "account_id"
        <*> o .:? "pulumi_stacks" .!= Map.empty

-- | Parent-custodied bootstrap credential. It is separate from metadata so
-- the child-listing endpoint can return inventory without returning the
-- transit-seal token.
data ChildBootstrapCredential = ChildBootstrapCredential
  { childBootstrapClusterId :: Text
  , childBootstrapParentVaultAddress :: Text
  , childBootstrapTransitKey :: Text
  , childBootstrapVaultNamespace :: Text
  , childBootstrapToken :: Text
  }
  deriving (Eq)

instance Show ChildBootstrapCredential where
  show credential =
    "ChildBootstrapCredential {childBootstrapClusterId = "
      ++ show (childBootstrapClusterId credential)
      ++ ", childBootstrapParentVaultAddress = "
      ++ show (childBootstrapParentVaultAddress credential)
      ++ ", childBootstrapTransitKey = "
      ++ show (childBootstrapTransitKey credential)
      ++ ", childBootstrapVaultNamespace = "
      ++ show (childBootstrapVaultNamespace credential)
      ++ ", childBootstrapToken = <redacted>}"

instance ToJSON ChildBootstrapCredential where
  toJSON credential =
    object
      [ "cluster_id" .= childBootstrapClusterId credential
      , "parent_vault_address" .= childBootstrapParentVaultAddress credential
      , "transit_key" .= childBootstrapTransitKey credential
      , "vault_namespace" .= childBootstrapVaultNamespace credential
      , "token" .= childBootstrapToken credential
      ]

instance FromJSON ChildBootstrapCredential where
  parseJSON =
    withObject "ChildBootstrapCredential" $ \o ->
      ChildBootstrapCredential
        <$> o .: "cluster_id"
        <*> o .: "parent_vault_address"
        <*> o .: "transit_key"
        <*> o .: "vault_namespace"
        <*> o .: "token"

newtype ChildIndex = ChildIndex
  { childIndexClusterIds :: [Text]
  }
  deriving (Eq, Show)

instance ToJSON ChildIndex where
  toJSON index =
    object ["children" .= childIndexClusterIds index]

instance FromJSON ChildIndex where
  parseJSON =
    withObject "ChildIndex" $ \o ->
      ChildIndex <$> o .: "children"

data ChildRegistrationPlan = ChildRegistrationPlan
  { childRegistrationChildId :: Text
  , childRegistrationMetadataPath :: Text
  , childRegistrationInitPath :: Text
  , childRegistrationTransitKey :: Text
  , childRegistrationVaultNamespace :: Text
  }
  deriving (Eq, Show)

-- | The HMAC key is root-owned material supplied by the future live writer.
-- Tests pass a deterministic key so the derivation stays pure.
childRegistrationPlan :: ByteString -> Text -> ChildRegistrationPlan
childRegistrationPlan hmacKey childId =
  ChildRegistrationPlan
    { childRegistrationChildId = childId
    , childRegistrationMetadataPath = childMetadataKvPath childId
    , childRegistrationInitPath = childInitKvPath childId
    , childRegistrationTransitKey = childTransitKeyName hmacKey childId
    , childRegistrationVaultNamespace = childVaultNamespace hmacKey childId
    }

childMetadataKvPath :: Text -> Text
childMetadataKvPath childId =
  "secret/data/" <> childMetadataKvLogicalPath childId

childInitKvPath :: Text -> Text
childInitKvPath childId =
  "secret/data/" <> childInitKvLogicalPath childId

childBootstrapKvPath :: Text -> Text
childBootstrapKvPath childId =
  "secret/data/" <> childBootstrapKvLogicalPath childId

federationChildrenIndexKvPath :: Text
federationChildrenIndexKvPath =
  "secret/data/" <> federationChildrenIndexKvLogicalPath

childMetadataKvLogicalPath :: Text -> Text
childMetadataKvLogicalPath childId =
  "clusters/" <> vaultPathSlug childId <> "/metadata"

childInitKvLogicalPath :: Text -> Text
childInitKvLogicalPath childId =
  "clusters/" <> vaultPathSlug childId <> "/init"

childBootstrapKvLogicalPath :: Text -> Text
childBootstrapKvLogicalPath childId =
  "clusters/" <> vaultPathSlug childId <> "/bootstrap"

federationChildrenIndexKvLogicalPath :: Text
federationChildrenIndexKvLogicalPath =
  "clusters/index"

childTransitKeyName :: ByteString -> Text -> Text
childTransitKeyName hmacKey childId =
  "prodbox-child-" <> opaqueChildToken hmacKey "transit-key" childId

childVaultNamespace :: ByteString -> Text -> Text
childVaultNamespace hmacKey childId =
  "ns-" <> opaqueChildToken hmacKey "vault-namespace" childId

encodeChildInitCustody :: ChildInitCustody -> ByteString
encodeChildInitCustody = BL.toStrict . Aeson.encode

decodeChildInitCustody :: ByteString -> Either String ChildInitCustody
decodeChildInitCustody = eitherDecodeStrict'

encodeChildMetadata :: ChildMetadata -> ByteString
encodeChildMetadata = BL.toStrict . Aeson.encode

decodeChildMetadata :: ByteString -> Either String ChildMetadata
decodeChildMetadata = eitherDecodeStrict'

encodeChildBootstrapCredential :: ChildBootstrapCredential -> ByteString
encodeChildBootstrapCredential = BL.toStrict . Aeson.encode

decodeChildBootstrapCredential :: ByteString -> Either String ChildBootstrapCredential
decodeChildBootstrapCredential = eitherDecodeStrict'

encodeChildIndex :: ChildIndex -> ByteString
encodeChildIndex = BL.toStrict . Aeson.encode

decodeChildIndex :: ByteString -> Either String ChildIndex
decodeChildIndex = eitherDecodeStrict'

childMetadataVaultFields :: ChildMetadata -> Map Text Text
childMetadataVaultFields metadata =
  payloadJsonField (encodeChildMetadata metadata)

childBootstrapVaultFields :: ChildBootstrapCredential -> Map Text Text
childBootstrapVaultFields credential =
  payloadJsonField (encodeChildBootstrapCredential credential)

childIndexVaultFields :: ChildIndex -> Map Text Text
childIndexVaultFields index =
  payloadJsonField (encodeChildIndex index)

decodePayloadJsonField :: (ByteString -> Either String a) -> Map Text Text -> Either String a
decodePayloadJsonField decoder fields =
  case Map.lookup "payload_json" fields of
    Nothing -> Left "Vault KV object missing field `payload_json`"
    Just payload
      | Text.null (Text.strip payload) -> Left "Vault KV object field `payload_json` is empty"
      | otherwise -> decoder (TextEncoding.encodeUtf8 payload)

upsertChildIndex :: Text -> ChildIndex -> ChildIndex
upsertChildIndex childId (ChildIndex existing) =
  ChildIndex (Set.toAscList (Set.fromList (childId : existing)))

payloadJsonField :: ByteString -> Map Text Text
payloadJsonField payload =
  Map.singleton "payload_json" (TextEncoding.decodeUtf8 payload)

childTransitSealPolicyDocument :: Text -> Text -> Text
childTransitSealPolicyDocument childId keyName =
  Text.unlines
    [ "path \"transit/encrypt/" <> keyName <> "\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"transit/decrypt/" <> keyName <> "\" {"
    , "  capabilities = [\"update\"]"
    , "}"
    , ""
    , "path \"" <> childInitKvPath childId <> "\" {"
    , "  capabilities = [\"create\", \"read\", \"update\", \"patch\"]"
    , "}"
    ]

data FederationWriteAuthority = FederationWriteAuthority
  { federationWriteIsRootCluster :: Bool
  , federationWriteRootTokenPresent :: Bool
  }
  deriving (Eq, Show)

data FederationWriteDecision
  = FederationWriteAllow
  | FederationWriteBlockNoRootToken
  deriving (Eq, Show)

-- | Registering or updating child custody is a root-cluster mutation. It is
-- allowed only when the root Vault is unsealed and the root token is available.
federationWriteDecision :: FederationWriteAuthority -> FederationWriteDecision
federationWriteDecision authority
  | federationWriteIsRootCluster authority && not (federationWriteRootTokenPresent authority) =
      FederationWriteBlockNoRootToken
  | otherwise = FederationWriteAllow

renderFederationWriteBlock :: FederationWriteDecision -> Maybe String
renderFederationWriteBlock decision = case decision of
  FederationWriteAllow -> Nothing
  FederationWriteBlockNoRootToken ->
    Just
      ( "Blocked: registering downstream cluster custody requires the root"
          ++ " Vault token on the root cluster. No child metadata, init keys,"
          ++ " Transit key, or namespace write was started. Run: prodbox vault unseal"
      )

renderChildRegistrationPlan :: ChildRegistrationPlan -> String
renderChildRegistrationPlan plan =
  unlines
    [ "CLUSTER_FEDERATION_REGISTER_PLAN"
    , "child_cluster_id=" ++ Text.unpack (childRegistrationChildId plan)
    , "metadata_kv_path=" ++ Text.unpack (childRegistrationMetadataPath plan)
    , "init_kv_path=" ++ Text.unpack (childRegistrationInitPath plan)
    , "bootstrap_kv_path=" ++ Text.unpack (childBootstrapKvPath (childRegistrationChildId plan))
    , "children_index_kv_path=" ++ Text.unpack federationChildrenIndexKvPath
    , "transit_key=" ++ Text.unpack (childRegistrationTransitKey plan)
    , "vault_namespace=" ++ Text.unpack (childRegistrationVaultNamespace plan)
    , "apply_status=ready_when_child_vault_address_and_child_kubeconfig_are_supplied"
    ]

opaqueChildToken :: ByteString -> ByteString -> Text -> Text
opaqueChildToken hmacKey purpose childId =
  Text.take 24 (hexBytes (hmac hmacKey (purpose <> ":" <> TextEncoding.encodeUtf8 childId)))

hexBytes :: ByteString -> Text
hexBytes bytes =
  TextEncoding.decodeUtf8
    ( LBS.toStrict
        ( toLazyByteString
            (foldMap word8HexFixed (BS.unpack bytes :: [Word8]))
        )
    )

vaultPathSlug :: Text -> Text
vaultPathSlug =
  Text.map sanitizePathChar . Text.toLower . Text.strip
 where
  sanitizePathChar ch
    | ch >= 'a' && ch <= 'z' = ch
    | ch >= '0' && ch <= '9' = ch
    | ch == '-' = ch
    | otherwise = '-'
