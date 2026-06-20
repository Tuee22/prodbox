{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 7.19 (staged): the Tier-1 bootstrap-secret object path for the root
-- cluster's Vault unlock bundle, relocated alongside host disk into the durable
-- MinIO bucket (config_doctrine.md §0 Tier 1; vault_doctrine.md §6, §6.1, §9).
--
-- This module owns the additive, locally-validatable half of the sprint:
--
--   * the FIXED, well-known bootstrap object key
--     ('bootstrapUnlockBundleKey') under which the password-AEAD-sealed bundle
--     body is stored. Unlike the Tier-2 operational objects (opaque
--     @objects\/\<hmac\>.enc@ names a sealed Vault cannot compute), this key is
--     deliberately discoverable pre-unseal so the §6.1 bootstrap credential can
--     find it. It is NOT a Vault-Transit envelope — its body is exactly the
--     bytes 'Prodbox.Vault.UnlockBundle.encryptUnlockBundle' produces.
--
--   * the PASSWORD-DERIVED bootstrap MinIO read credential
--     ('deriveBootstrapMinioCredential'): a pure, deterministic Argon2id
--     derivation from @(operator password, public per-cluster salt)@ under a
--     DISTINCT derivation context/salt from the bundle-body AEAD key, so the
--     same memorized password yields two cryptographically independent
--     secrets. By construction it must work while Vault is sealed: it resolves
--     no Vault path and is not a Vault-Transit handle (§6.1).
--
--   * 'putBundleObject' \/ 'getBundleObject' over a 'ObjectStoreConfig' built
--     from the derived credential, the durable bucket, and a local MinIO
--     endpoint (the caller supplies the port-forwarded local port via
--     'Prodbox.Infra.MinioBackend.withMinioPortForward').
--
-- The DELIBERATELY DEFERRED half — the MinIO-before-Vault bootstrap reorder and
-- the MinIO-root-decoupling reorder that make this object the PRIMARY,
-- host-disk-free unseal source — is the 🧪 Live-proof-pending axis and is NOT
-- attempted here. The host-disk bundle remains the load-bearing unseal source
-- this stage; this module is written-to and preferred-on-read with a disk
-- fallback. See the @Sprint 7.19 (live-proof)@ markers in
-- "Prodbox.CLI.Vault" and "Prodbox.Vault.Host".
--
-- The public per-cluster salt is derived deterministically from the public
-- Tier-0 cluster id ('bootstrapSaltForClusterId'). The cluster id already lives
-- in the non-secret Tier-0 basics (config_doctrine.md §0 Tier 0), so the salt
-- needs no new schema field and stays a public, per-cluster value.
-- -- Sprint 7.19 (live-proof): promoting the salt to an explicit
-- @bootstrap_minio_salt@ field on the Tier-0 context (rather than deriving it
-- from the cluster id) lands with the reorder, once the Dhall schema +
-- generated-artifact drift can be regenerated as part of that step.
module Prodbox.Vault.BootstrapBundle
  ( -- * The fixed, well-known bootstrap object key (§6.1, §9)
    bootstrapUnlockBundleKey

    -- * The password-derived bootstrap MinIO read credential (§6.1)
  , BootstrapMinioCredential (..)
  , bootstrapSaltForClusterId
  , deriveBootstrapMinioCredential
  , bootstrapObjectStoreConfig

    -- * Bundle-object put/get over the durable bucket
  , putBundleObject
  , getBundleObject
  )
where

import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64URL
import Data.ByteString.Char8 qualified as BSC
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , defaultObjectStoreBucket
  , getObject
  , putObject
  )
import Prodbox.Vault.UnlockBundle
  ( UnlockBundleError
  , bootstrapKdfOptions
  , deriveKey
  )

-- | The FIXED, well-known bootstrap object key under which the
-- password-AEAD-sealed unlock-bundle body is stored in the durable bucket. It
-- is deliberately NOT HMAC-opaque (it must be findable while Vault is sealed;
-- §6.1, §9) and NOT a Vault-Transit envelope. The @.v1@ suffix versions the
-- on-bucket layout so a future format can land at a new key without colliding.
bootstrapUnlockBundleKey :: Text
bootstrapUnlockBundleKey = "bootstrap/vault-unlock-bundle.v1"

-- | The password-derived bootstrap MinIO read credential (§6.1). Carries an
-- @(accessKey, secretKey)@ pair derived from the operator password; both are
-- printable ASCII (URL-safe base64) so they survive the @aws s3api@ env-var
-- transport unchanged.
data BootstrapMinioCredential = BootstrapMinioCredential
  { bootstrapMinioAccessKey :: String
  , bootstrapMinioSecretKey :: String
  }
  deriving (Eq, Show)

-- | The DISTINCT derivation context applied to the operator password before the
-- KDF, so the bootstrap-credential key is independent of the bundle-body AEAD
-- key even though both reuse the same Argon2id parameters. The bundle body uses
-- the bare password (see 'Prodbox.Vault.UnlockBundle.encryptUnlockBundle');
-- this prefixes a fixed, non-secret domain-separation tag.
bootstrapCredentialContext :: Text
bootstrapCredentialContext = "prodbox-bootstrap-minio-credential-v1:"

-- | The public per-cluster salt, derived deterministically from the public
-- Tier-0 cluster id. It is a salt, not a secret: it only domain-separates the
-- derivation per cluster so two clusters sharing an operator password do not
-- share a bootstrap credential. A fixed, non-secret tag is prefixed so the salt
-- bytes never collide with any other use of the cluster id.
bootstrapSaltForClusterId :: Text -> ByteString
bootstrapSaltForClusterId clusterId =
  TextEncoding.encodeUtf8 ("prodbox-bootstrap-minio-salt-v1:" <> clusterId)

-- | Derive the bootstrap MinIO read credential from the operator password and
-- the public per-cluster salt. PURE and DETERMINISTIC: identical
-- @(password, salt)@ inputs always yield the identical credential, and a wrong
-- password yields a different credential (which MinIO rejects — fail-closed).
--
-- Independence from the bundle-body AEAD key (§6.1) comes from two distinct
-- inputs to the same Argon2id KDF: the password is prefixed with
-- 'bootstrapCredentialContext', and the salt is the per-cluster
-- 'bootstrapSaltForClusterId' rather than the bundle's fresh random salt. The
-- derived 32-byte key is split into a 16-byte access-key half and a 16-byte
-- secret-key half, each URL-safe-base64-encoded into a printable credential.
deriveBootstrapMinioCredential
  :: Text -> ByteString -> Either UnlockBundleError BootstrapMinioCredential
deriveBootstrapMinioCredential password salt = do
  key <- deriveKey bootstrapKdfOptions (bootstrapCredentialContext <> password) salt
  let keyBytes = ByteArray.convert key :: ByteString
      (accessHalf, secretHalf) = BS.splitAt 16 keyBytes
  pure
    BootstrapMinioCredential
      { bootstrapMinioAccessKey = encodeCredentialHalf accessHalf
      , bootstrapMinioSecretKey = encodeCredentialHalf secretHalf
      }

-- | URL-safe base64 with no padding, decoded to an ASCII 'String'. The result
-- is printable and contains no @+@, @/@, or @=@, so it is safe to pass through
-- the @AWS_ACCESS_KEY_ID@ \/ @AWS_SECRET_ACCESS_KEY@ env-var transport.
encodeCredentialHalf :: ByteString -> String
encodeCredentialHalf = BSC.unpack . B64URL.encodeUnpadded

-- | Build the 'ObjectStoreConfig' the bundle put/get helpers run against, from
-- the derived bootstrap credential, the durable bucket, and a local MinIO
-- endpoint. The caller supplies the local port-forward port (e.g. from
-- 'Prodbox.Infra.MinioBackend.withMinioPortForward').
bootstrapObjectStoreConfig :: Int -> BootstrapMinioCredential -> ObjectStoreConfig
bootstrapObjectStoreConfig localPort credential =
  ObjectStoreConfig
    { objectStoreEndpoint = "http://127.0.0.1:" ++ show localPort
    , objectStoreBucket = defaultObjectStoreBucket
    , objectStoreAccessKey = bootstrapMinioAccessKey credential
    , objectStoreSecretKey = bootstrapMinioSecretKey credential
    }

-- | Write the password-AEAD-sealed bundle bytes (exactly the
-- 'Prodbox.Vault.UnlockBundle.encryptUnlockBundle' output) to the fixed
-- bootstrap key in the durable bucket.
putBundleObject :: ObjectStoreConfig -> ByteString -> IO (Either String ())
putBundleObject config envelopeBytes =
  putObject config bootstrapUnlockBundleKey envelopeBytes

-- | Read the password-AEAD-sealed bundle bytes from the fixed bootstrap key.
-- @Right Nothing@ means the object is absent (the bucket has no bundle yet);
-- @Right (Just bytes)@ is the ciphertext envelope to hand to
-- 'Prodbox.Vault.UnlockBundle.decryptUnlockBundle'.
getBundleObject :: ObjectStoreConfig -> IO (Either String (Maybe ByteString))
getBundleObject config =
  getObject config bootstrapUnlockBundleKey
