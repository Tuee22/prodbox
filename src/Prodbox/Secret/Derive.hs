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
  , DeriveContext (..)
  , encodeDeriveContext
  , decodeDeriveContext
  , patroniRoleContext
  , keycloakAdminContext
  , keycloakDemoUserContext
  , oidcClientSecretContext
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

patroniRoleFromSlug :: Text -> Maybe PatroniRole
patroniRoleFromSlug slug = case slug of
  "app" -> Just PatroniRoleApp
  "superuser" -> Just PatroniRoleSuperuser
  "standby" -> Just PatroniRoleStandby
  _ -> Nothing

-- | A typed, structured derivation context. Every secret derived from the
-- master seed names its purpose through one of these constructors rather than
-- an ad-hoc colon-joined string, and the wire string is produced solely by
-- 'encodeDeriveContext'. 'decodeDeriveContext' is its exact inverse:
-- @decodeDeriveContext . encodeDeriveContext == Just@ for every well-formed
-- 'DeriveContext' (proved by a round-trip property test), so the
-- @/v1/secret/derive@ context wire shape is provably stable.
data DeriveContext
  = -- | @patroni:<namespace>:<release>:<role>@
    PatroniRoleContext Text Text PatroniRole
  | -- | @keycloak:<namespace>:admin@
    KeycloakAdminContext Text
  | -- | @keycloak:<namespace>:demo-user@
    KeycloakDemoUserContext Text
  | -- | @oidc:<namespace>:<clientId>@
    OidcClientSecretContext Text Text
  | -- | @gateway:<namespace>:<node-id>:event-key@
    GatewayEventKeyContext Text Text
  deriving (Eq, Show)

-- | Encode a typed context to its canonical colon-joined wire string. This is
-- the single authoritative encoder; the legacy @*Context@ helpers below are
-- thin wrappers over it so every call site shares one representation.
encodeDeriveContext :: DeriveContext -> Text
encodeDeriveContext ctx = case ctx of
  PatroniRoleContext namespace release role ->
    Text.intercalate ":" ["patroni", namespace, release, patroniRoleSlug role]
  KeycloakAdminContext namespace ->
    Text.intercalate ":" ["keycloak", namespace, "admin"]
  KeycloakDemoUserContext namespace ->
    Text.intercalate ":" ["keycloak", namespace, "demo-user"]
  OidcClientSecretContext namespace clientId ->
    Text.intercalate ":" ["oidc", namespace, clientId]
  GatewayEventKeyContext namespace nodeId ->
    Text.intercalate ":" ["gateway", namespace, nodeId, "event-key"]

-- | Decode a canonical wire string back to its typed 'DeriveContext'. The
-- exact inverse of 'encodeDeriveContext'. Returns 'Nothing' for any string
-- that does not match a known canonical shape (wrong prefix, wrong arity,
-- unknown trailing literal, or an unknown Patroni role slug), so the
-- @/v1/secret/derive@ handler can reject malformed or unknown contexts.
--
-- Round-trip caveat: the encoder joins segments with @:@, so a segment that
-- itself contains @:@ (e.g. a namespace literal with an embedded colon) would
-- not survive the split. Every canonical caller passes colon-free segments
-- (Kubernetes namespace / release / node-id / client-id tokens), so the
-- round-trip is total over the canonical input domain the property test
-- exercises.
decodeDeriveContext :: Text -> Maybe DeriveContext
decodeDeriveContext wire =
  case Text.splitOn ":" wire of
    ["patroni", namespace, release, roleSlug] ->
      PatroniRoleContext namespace release <$> patroniRoleFromSlug roleSlug
    ["keycloak", namespace, "admin"] ->
      Just (KeycloakAdminContext namespace)
    ["keycloak", namespace, "demo-user"] ->
      Just (KeycloakDemoUserContext namespace)
    ["oidc", namespace, clientId] ->
      Just (OidcClientSecretContext namespace clientId)
    ["gateway", namespace, nodeId, "event-key"] ->
      Just (GatewayEventKeyContext namespace nodeId)
    _ -> Nothing

-- | Canonical context string for a Patroni role secret.
-- Shape: @patroni:<namespace>:<release>:<role>@
patroniRoleContext :: Text -> Text -> PatroniRole -> Text
patroniRoleContext namespace release role =
  encodeDeriveContext (PatroniRoleContext namespace release role)

-- | Canonical context string for the Keycloak admin-user secret.
-- Shape: @keycloak:<namespace>:admin@
keycloakAdminContext :: Text -> Text
keycloakAdminContext namespace =
  encodeDeriveContext (KeycloakAdminContext namespace)

-- | Canonical context string for the Keycloak demo-user password (Sprint 3.13
-- chunk 11). Shape: @keycloak:<namespace>:demo-user@. The demo user is seeded
-- in the realm import (used by the canonical-suite OIDC validations); its
-- password is not data-bound (Keycloak re-imports the realm on each fresh
-- install) but is derived from the master seed so the chart's @configmap.yaml@
-- realm-import JSON can reference the same value the daemon's pre-install Job
-- materializes into the @keycloak-oidc-clients@ Secret.
keycloakDemoUserContext :: Text -> Text
keycloakDemoUserContext namespace =
  encodeDeriveContext (KeycloakDemoUserContext namespace)

-- | Canonical context string for an OIDC client's @client_secret@ (Sprint 3.13
-- chunk 11). Shape: @oidc:<namespace>:<clientId>@. Same rationale as
-- 'keycloakDemoUserContext': the OIDC clients are seeded in the realm import,
-- so their secrets are not strictly data-bound but deriving them from the
-- master seed gives both the @configmap.yaml@ render and the cross-namespace
-- workload chart lookups a deterministic value source without any inter-chart
-- coordination.
oidcClientSecretContext :: Text -> Text -> Text
oidcClientSecretContext namespace clientId =
  encodeDeriveContext (OidcClientSecretContext namespace clientId)

-- | Canonical context string for a gateway peer-event signing key.
-- Shape: @gateway:<namespace>:<node-id>:event-key@
gatewayEventKeyContext :: Text -> Text -> Text
gatewayEventKeyContext namespace nodeId =
  encodeDeriveContext (GatewayEventKeyContext namespace nodeId)

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
