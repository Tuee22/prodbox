{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Wire types shared by the gateway daemon's @/v1/secret/*@ endpoints
-- and the host-side client in 'Prodbox.Gateway.Client'. Authoritative
-- shape: @documents/engineering/secret_derivation_doctrine.md@ §4.
--
-- Keeping the JSON contract in a separate module ensures the client and
-- daemon cannot drift: any change to a field name or encoding affects
-- both sides through one edit. The 'FromJSON' / 'ToJSON' instances are
-- derived where field names match Haskell's casing; the
-- 'EnsureNamespaceRequest' / 'EnsureNamespaceResponse' instances use
-- explicit derivations so the wire-level @snake_case@ stays stable
-- across record renames.
module Prodbox.Secret.Wire
  ( DeriveResponse (..)
  , EnsureNamespaceRequest (..)
  , EnsureNamespaceResponse (..)
  , SecretSha256Entry (..)
  , deriveEncodingBase64Url
  )
where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Response shape for @GET /v1/secret/derive?context=<context>@.
data DeriveResponse = DeriveResponse
  { deriveResponseContext :: Text
  -- ^ Echo of the @context@ query parameter that produced the
  -- derived value. Operators and callers cross-check this against
  -- the request to detect routing bugs.
  , deriveResponseDerived :: Text
  -- ^ Derived 32-byte value, encoded per 'deriveResponseEncoding'.
  , deriveResponseEncoding :: Text
  -- ^ Encoding name for 'deriveResponseDerived'. Today always
  -- 'deriveEncodingBase64Url' per the doctrine.
  }
  deriving (Eq, Show, Generic)

instance ToJSON DeriveResponse where
  toJSON r =
    object
      [ "context" .= deriveResponseContext r
      , "derived" .= deriveResponseDerived r
      , "encoding" .= deriveResponseEncoding r
      ]

instance FromJSON DeriveResponse where
  parseJSON = withObject "DeriveResponse" $ \o ->
    DeriveResponse
      <$> o .: "context"
      <*> o .: "derived"
      <*> o .: "encoding"

-- | Canonical encoding string for 'deriveResponseEncoding'. The doctrine
-- pins this to URL-safe base64 (no padding) so derived values can flow
-- through query strings and quoting-sensitive contexts unchanged.
deriveEncodingBase64Url :: Text
deriveEncodingBase64Url = "base64url"

-- | Request shape for @POST /v1/secret/ensure-namespace@.
data EnsureNamespaceRequest = EnsureNamespaceRequest
  { ensureNamespaceRequestNamespace :: Text
  -- ^ Kubernetes namespace whose chart's data-bound Secrets must be
  -- materialized.
  , ensureNamespaceRequestRelease :: Text
  -- ^ Helm release name within the namespace.
  }
  deriving (Eq, Show, Generic)

instance ToJSON EnsureNamespaceRequest where
  toJSON r =
    object
      [ "namespace" .= ensureNamespaceRequestNamespace r
      , "release" .= ensureNamespaceRequestRelease r
      ]

instance FromJSON EnsureNamespaceRequest where
  parseJSON = withObject "EnsureNamespaceRequest" $ \o ->
    EnsureNamespaceRequest
      <$> o .: "namespace"
      <*> o .: "release"

-- | One entry in 'ensureNamespaceResponseSecrets': a materialized Secret
-- name paired with the SHA-256 of its derived value. Never plaintext —
-- the doctrine §4 contract.
data SecretSha256Entry = SecretSha256Entry
  { secretSha256EntryName :: Text
  , secretSha256EntrySha256 :: Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON SecretSha256Entry where
  toJSON e =
    object
      [ "name" .= secretSha256EntryName e
      , "sha256" .= secretSha256EntrySha256 e
      ]

instance FromJSON SecretSha256Entry where
  parseJSON = withObject "SecretSha256Entry" $ \o ->
    SecretSha256Entry
      <$> o .: "name"
      <*> o .: "sha256"

-- | Response shape for @POST /v1/secret/ensure-namespace@.
data EnsureNamespaceResponse = EnsureNamespaceResponse
  { ensureNamespaceResponseNamespace :: Text
  , ensureNamespaceResponseRelease :: Text
  , ensureNamespaceResponseSecrets :: [SecretSha256Entry]
  }
  deriving (Eq, Show, Generic)

instance ToJSON EnsureNamespaceResponse where
  toJSON r =
    object
      [ "namespace" .= ensureNamespaceResponseNamespace r
      , "release" .= ensureNamespaceResponseRelease r
      , "secrets" .= ensureNamespaceResponseSecrets r
      ]

instance FromJSON EnsureNamespaceResponse where
  parseJSON = withObject "EnsureNamespaceResponse" $ \o ->
    EnsureNamespaceResponse
      <$> o .: "namespace"
      <*> o .: "release"
      <*> o .: "secrets"
