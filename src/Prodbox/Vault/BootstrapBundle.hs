{-# LANGUAGE OverloadedStrings #-}

-- | The Tier-1 bootstrap-secret object path for the root cluster's Vault unlock
-- bundle, stored alongside host disk in the durable MinIO bucket
-- (config_doctrine.md §0 Tier 1; vault_doctrine.md §6, §6.1, §9).
--
-- This module owns:
--
--   * the FIXED, well-known bootstrap object key ('bootstrapUnlockBundleKey')
--     under which the password-AEAD-sealed bundle body is stored. Unlike the
--     Tier-2 operational objects (opaque @objects\/\<hmac\>.enc@ names a sealed
--     Vault cannot compute), this key is deliberately discoverable pre-unseal so
--     it can be found while Vault is sealed (§6.1, §9). It is NOT a Vault-Transit
--     envelope — its body is exactly the bytes
--     'Prodbox.Vault.UnlockBundle.encryptUnlockBundle' produces.
--
--   * 'putBundleObject' \/ 'getBundleObject' over an 'ObjectStoreConfig' built
--     from the STATIC MinIO root credential ('bootstrapObjectStoreConfig'), the
--     durable bucket, and a local MinIO endpoint (the caller supplies the
--     port-forwarded local port via 'Prodbox.Infra.MinioBackend.withMinioPortForward').
--
-- The MinIO access credential is a static constant
-- ('Prodbox.Minio.RootCredential'), NOT password-derived: the security here is
-- the password-AEAD seal on the bundle body (you need the operator password to
-- decrypt it) and Vault Transit on every other object — the access credential
-- only gates ciphertext access over a localhost NodePort (operator decision
-- 2026-06-22; see "Prodbox.Minio.RootCredential"). Using the real (valid) root
-- credential is also what makes the bundle round-trip through MinIO actually
-- work (a derived made-up credential MinIO never accepted).
--
-- The host-disk bundle remains the load-bearing unseal fallback this stage; this
-- module is written-to and preferred-on-read with a disk fallback. Dropping the
-- host-disk write entirely (the disk-free unseal cutover) is a separate later
-- decision.
module Prodbox.Vault.BootstrapBundle
  ( -- * The fixed, well-known bootstrap object key (§6.1, §9)
    bootstrapUnlockBundleKey

    -- * The object-store config for the bundle (static MinIO root credential)
  , bootstrapObjectStoreConfig

    -- * Bundle-object put/get over the durable bucket
  , putBundleObject
  , getBundleObject
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , defaultObjectStoreBucket
  , getObject
  , putObject
  )
import Prodbox.Minio.RootCredential (minioRootPassword, minioRootUser)

-- | The FIXED, well-known bootstrap object key under which the
-- password-AEAD-sealed unlock-bundle body is stored in the durable bucket. It
-- is deliberately NOT HMAC-opaque (it must be findable while Vault is sealed;
-- §6.1, §9) and NOT a Vault-Transit envelope. The @.v1@ suffix versions the
-- on-bucket layout so a future format can land at a new key without colliding.
bootstrapUnlockBundleKey :: Text
bootstrapUnlockBundleKey = "bootstrap/vault-unlock-bundle.v1"

-- | Build the 'ObjectStoreConfig' the bundle put/get helpers run against, from
-- the STATIC MinIO root credential, the durable bucket, and a local MinIO
-- endpoint. The caller supplies the local port-forward port (e.g. from
-- 'Prodbox.Infra.MinioBackend.withMinioPortForward').
bootstrapObjectStoreConfig :: Int -> ObjectStoreConfig
bootstrapObjectStoreConfig localPort =
  ObjectStoreConfig
    { objectStoreEndpoint = "http://127.0.0.1:" ++ show localPort
    , objectStoreBucket = defaultObjectStoreBucket
    , objectStoreAccessKey = minioRootUser
    , objectStoreSecretKey = minioRootPassword
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
