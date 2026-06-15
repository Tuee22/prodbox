{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.38: the in-force cluster configuration as a Vault-Transit-enveloped
-- MinIO object — the configuration source of truth (config_doctrine.md §1a).
-- The filesystem @prodbox-config.dhall@ is a seed/propose input only; the
-- authoritative in-force config lives encrypted in MinIO and is opaque when
-- Vault is sealed.
--
-- This module holds the pure, offline-testable framing: the object identity and
-- AAD binding, the envelope seal/open over the in-force payload (parameterized
-- on a "Prodbox.Crypto.Envelope" 'DekCipher' so tests use the local cipher and
-- production binds Vault Transit), the seed-vs-propose decision over the two
-- config sources, and the root-token-required write precondition. The MinIO
-- read/write IO edges and the Vault-Transit @DekCipher@ are the live edges that
-- land with a deployed in-cluster Vault (Sprint 3.17 / 4.29).
module Prodbox.Config.InForce
  ( InForceObject (..)
  , ConfigSource (..)
  , SeedProposeDecision (..)
  , RootWriteAuthority (..)
  , RootConfigWriteDecision (..)
  , inForceObjectName
  , inForceAad
  , renderInForcePayload
  , sealInForcePayload
  , openInForcePayload
  , seedProposeDecision
  , rootConfigWriteDecision
  , renderRootConfigWriteBlock
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Crypto.Envelope (DekCipher, EnvelopeError, openEnvelope, sealEnvelope)
import Prodbox.Settings (ConfigFile, renderConfigDhall)

-- | The prodbox-owned MinIO objects whose plaintext is in-force cluster state.
-- Only 'InForceConfig' exists today; the type is extensible to the
-- Pulumi-backend object and others.
data InForceObject = InForceConfig
  deriving (Eq, Show)

inForceObjectName :: InForceObject -> Text
inForceObjectName InForceConfig = "in-force-config"

-- | The additional authenticated data binds the cluster id and object name so
-- an in-force envelope cannot be opened under a different cluster's identity.
inForceAad :: Text -> InForceObject -> ByteString
inForceAad clusterId object =
  TextEncoding.encodeUtf8 (clusterId <> "|" <> inForceObjectName object)

-- | Serialize a 'ConfigFile' to the in-force payload bytes (its Dhall text).
-- The reverse decode goes through the Dhall import resolver and is a live edge,
-- so this is intentionally one-way at the pure layer.
renderInForcePayload :: ConfigFile -> ByteString
renderInForcePayload = TextEncoding.encodeUtf8 . Text.pack . renderConfigDhall

-- | Seal in-force payload bytes into a @prodbox-envelope-v1@ envelope bound to
-- this cluster + object. Production passes a Vault-Transit 'DekCipher'; offline
-- tests pass @insecureLocalDekCipher@.
sealInForcePayload
  :: DekCipher -> Text -> ByteString -> IO (Either EnvelopeError ByteString)
sealInForcePayload cipher clusterId payload =
  sealEnvelope cipher (inForceAad clusterId InForceConfig) payload

-- | Open an in-force envelope back to its payload bytes, verifying the cluster
-- + object AAD (a mismatched cluster id fails closed).
openInForcePayload
  :: DekCipher -> Text -> ByteString -> IO (Either EnvelopeError ByteString)
openInForcePayload cipher clusterId envelope =
  openEnvelope cipher (inForceAad clusterId InForceConfig) envelope

-- | Whether a filesystem config and/or an in-force MinIO envelope are present.
data ConfigSource = ConfigSource
  { configSourceFilePresent :: Bool
  , configSourceInForcePresent :: Bool
  }
  deriving (Eq, Show)

-- | What to do with the two config sources. The filesystem file seeds the
-- encrypted SSoT on first-ever bring-up and is a proposed update thereafter;
-- the in-force MinIO object is the source of truth once it exists.
data SeedProposeDecision
  = -- | No in-force object yet, file present: seed the SSoT from the file.
    SeedInForce
  | -- | In-force object and file both present: the file is a proposed update.
    ProposeUpdate
  | -- | In-force object present, no file: read the SSoT, the file is irrelevant.
    UseInForceAsIs
  | -- | Neither present: nothing to bring the cluster up with.
    NoConfigAvailable
  deriving (Eq, Show)

seedProposeDecision :: ConfigSource -> SeedProposeDecision
seedProposeDecision source =
  case (configSourceInForcePresent source, configSourceFilePresent source) of
    (False, True) -> SeedInForce
    (True, True) -> ProposeUpdate
    (True, False) -> UseInForceAsIs
    (False, False) -> NoConfigAvailable

-- | Whether the caller acts on the root cluster and whether a root Vault token
-- was presented. The root-cluster flag is derived from the unencrypted basics
-- ('Prodbox.Config.Basics.isRootCluster').
data RootWriteAuthority = RootWriteAuthority
  { rootWriteIsRootCluster :: Bool
  , rootWriteTokenPresent :: Bool
  }
  deriving (Eq, Show)

data RootConfigWriteDecision
  = RootWriteAllow
  | RootWriteBlockNoRootToken
  deriving (Eq, Show)

-- | Updating the root cluster's in-force config — which transitively governs
-- every downstream cluster — requires the root Vault token (an unsealed root
-- Vault). A child cluster's write authority is its parent's concern, so it is
-- not gated here.
rootConfigWriteDecision :: RootWriteAuthority -> RootConfigWriteDecision
rootConfigWriteDecision authority
  | rootWriteIsRootCluster authority && not (rootWriteTokenPresent authority) =
      RootWriteBlockNoRootToken
  | otherwise = RootWriteAllow

-- | The fail-closed operator message for a blocked root-config write. 'Nothing'
-- when the write is allowed.
renderRootConfigWriteBlock :: RootConfigWriteDecision -> Maybe String
renderRootConfigWriteBlock decision = case decision of
  RootWriteAllow -> Nothing
  RootWriteBlockNoRootToken ->
    Just
      ( "Blocked: writing the root cluster's in-force config requires the root"
          ++ " Vault token (an unsealed root Vault); it is the keys to every"
          ++ " downstream cluster. No write was started. Run: prodbox vault unseal"
      )
