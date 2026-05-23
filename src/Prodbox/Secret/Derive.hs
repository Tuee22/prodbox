{-# LANGUAGE OverloadedStrings #-}

-- | Pure HMAC-SHA-256 derivation of data-bound chart secrets from the
-- master seed. Authoritative algorithm + context-string table:
-- @documents/engineering/secret_derivation_doctrine.md@ §3.
--
-- This module is intentionally pure: it never touches MinIO or k8s. The
-- master-seed read/write lives in 'Prodbox.Secret.MasterSeed'; the
-- gateway daemon endpoint handlers in 'Prodbox.Gateway.Daemon' compose
-- the two.
module Prodbox.Secret.Derive
  ( MasterSeed
  , masterSeed
  , masterSeedBytes
  , PatroniRole (..)
  , patroniRoleContext
  , keycloakAdminContext
  , gatewayEventKeyContext
  , derive
  , deriveBase64Url
  , deriveHex
  )
where

import Crypto.Hash.SHA256 (hmac)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.ByteString.Builder (toLazyByteString, word8HexFixed)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE

-- | The master seed. 32 bytes (256 bits) random material, stored in MinIO
-- per [Secret Derivation Doctrine](docs §2). The constructor is exported
-- via 'masterSeed' so callers cannot accidentally derive against an
-- undersized buffer; the accessor 'masterSeedBytes' lets the gateway
-- daemon serialize the seed for read/write.
newtype MasterSeed = MasterSeed ByteString
  deriving (Eq)

instance Show MasterSeed where
  show _ = "MasterSeed <redacted>"

-- | Smart constructor. Rejects anything other than exactly 32 bytes; the
-- master seed is fixed-width per doctrine and an undersized seed would
-- silently weaken every derived secret.
masterSeed :: ByteString -> Either String MasterSeed
masterSeed bytes
  | BS.length bytes == 32 = Right (MasterSeed bytes)
  | otherwise =
      Left
        ( "master seed must be exactly 32 bytes; got "
            ++ show (BS.length bytes)
        )

masterSeedBytes :: MasterSeed -> ByteString
masterSeedBytes (MasterSeed bytes) = bytes

-- | Patroni roles whose passwords are derived from the master seed per
-- the contract in [Helm Chart Platform Doctrine §10] and the
-- @keycloak-postgres@ chart.
data PatroniRole
  = PatroniRoleApp
  | PatroniRoleSuperuser
  | PatroniRoleStandby
  deriving (Eq, Show)

patroniRoleSlug :: PatroniRole -> Text
patroniRoleSlug role = case role of
  PatroniRoleApp -> "app"
  PatroniRoleSuperuser -> "superuser"
  PatroniRoleStandby -> "standby"

-- | Canonical context string for a Patroni role secret.
-- Shape: @patroni:<namespace>:<release>:<role>@
patroniRoleContext :: Text -> Text -> PatroniRole -> Text
patroniRoleContext namespace release role =
  Text.intercalate
    ":"
    [ "patroni"
    , namespace
    , release
    , patroniRoleSlug role
    ]

-- | Canonical context string for the Keycloak admin-user secret.
-- Shape: @keycloak:<namespace>:admin@
keycloakAdminContext :: Text -> Text
keycloakAdminContext namespace =
  Text.intercalate ":" ["keycloak", namespace, "admin"]

-- | Canonical context string for a gateway peer-event signing key.
-- Shape: @gateway:<namespace>:<node-id>:event-key@
gatewayEventKeyContext :: Text -> Text -> Text
gatewayEventKeyContext namespace nodeId =
  Text.intercalate ":" ["gateway", namespace, nodeId, "event-key"]

-- | Derive a 32-byte secret from the master seed and a context string
-- via HMAC-SHA-256. The encoding is the caller's choice; use
-- 'deriveBase64Url' or 'deriveHex' for the canonical wire encodings.
derive :: MasterSeed -> Text -> ByteString
derive (MasterSeed seed) context =
  hmac seed (TE.encodeUtf8 context)

-- | Derive a 32-byte secret and base64url-encode it (no padding). This
-- is the wire encoding the @/v1/secret/derive@ endpoint returns per
-- [Secret Derivation Doctrine §4].
deriveBase64Url :: MasterSeed -> Text -> Text
deriveBase64Url seed context =
  TE.decodeUtf8 (Base64Url.encodeUnpadded (derive seed context))

-- | Derive a 32-byte secret and lowercase-hex-encode it. Useful for
-- callers that need a printable ASCII secret of fixed length 64.
deriveHex :: MasterSeed -> Text -> Text
deriveHex seed context =
  TE.decodeUtf8
    ( BL.toStrict
        (toLazyByteString (BS.foldr (\byte acc -> word8HexFixed byte <> acc) mempty (derive seed context)))
    )
