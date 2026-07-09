{-# LANGUAGE OverloadedStrings #-}

-- | Host-direct read/write/delete of a per-run Pulumi checkpoint straight from
-- the in-cluster MinIO, bypassing the gateway daemon object-store API.
--
-- The supported production path for per-run Pulumi checkpoints routes through
-- the in-cluster gateway daemon's HTTP object-store API
-- ('Prodbox.Pulumi.EncryptedBackend.productionHooks' →
-- @127.0.0.1:30443@). When that daemon is degraded — it booted in the pre-Vault
-- bootstrap config with @daemonMinioCreds == Nothing@ (a @503 …@ from
-- 'Prodbox.Gateway.Daemon.daemonPulumiObjectStoreConfig'), or is mid-redeploy —
-- every host-side residue read and per-run destroy fails, and the @--cascade@
-- teardown then silently skips per-run Pulumi destroys (orphan risk). This
-- module is the host-direct fallback: it reaches the SAME shared MinIO bucket
-- via the host's root Vault token, exactly as the in-force-config read already
-- does ('Prodbox.Settings.loadRuntimeInForceConfigWithToken').
--
-- The material MUST be byte-compatible with the daemon's own ops
-- ('Prodbox.Gateway.Daemon.readDaemonPulumiObject' etc.): same transit key
-- @"prodbox-pulumi-state"@ (NOT the in-force config's @"prodbox-active-config"@),
-- same HMAC key (@secret/object-store/hmac@), same clusterId
-- ('basicsClusterId'), same bucket ('defaultObjectStoreBucket'), and the same
-- 'LogicalPulumiStack' logical name (AAD @clusterId|pulumi-stack/\<name>@). Only
-- then does a host-direct GET open an envelope a daemon PUT sealed, and
-- vice-versa.
--
-- Kept a leaf module (it depends on Vault + MinIO + the envelope layer, never on
-- 'Prodbox.Pulumi.EncryptedBackend') so the backend can import it without a
-- cycle and without coupling to the large 'Prodbox.Settings'. The two tiny
-- Vault-KV readers are local copies (the daemon keeps its own copy
-- 'Prodbox.Gateway.Daemon.readDaemonObjectStoreHmac', so a localized copy is the
-- established pattern).
module Prodbox.Pulumi.HostDirectObjectStore
  ( HostDirectPulumiMaterial (..)
  , HostDirectPulumiHandle (..)
  , resolveHostDirectPulumiMaterial
  , withHostDirectPulumiPortForward
  , hostDirectGetPulumiObject
  , hostDirectPutPulumiObject
  , hostDirectDeletePulumiObject
  )
where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.Basics
  ( basicsClusterId
  , basicsVaultAddress
  )
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Crypto.Envelope (DekCipher)
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Infra.MinioBackend (withMinioPortForward)
import Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError (EncryptedObjectMissing)
  , LogicalObject (LogicalPulumiStack)
  , getLogical
  , objectKeyForOpaqueId
  , opaqueObjectId
  , putLogical
  , renderEncryptedObjectError
  )
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , defaultObjectStoreBucket
  , deleteObject
  )
import Prodbox.Vault.Client
  ( VaultAddress (..)
  , VaultToken
  , vaultKvReadV2
  )
import Prodbox.Vault.Host (loadReadyVaultRootToken)
import Prodbox.Vault.TransitCipher (vaultTransitDekCipher)

-- | Everything needed to reach the per-run Pulumi object-store host-directly
-- EXCEPT the MinIO port-forward. Resolving this is the possibly-interactive
-- step (the root-token load may prompt for the unlock-bundle password), so it is
-- only ever run on the daemon-down fallback branch.
data HostDirectPulumiMaterial = HostDirectPulumiMaterial
  { hdCipher :: DekCipher
  , hdHmacKey :: ByteString
  , hdClusterId :: Text
  , hdAccessKey :: String
  , hdSecretKey :: String
  }

-- | 'HostDirectPulumiMaterial' bound to a live MinIO endpoint inside an open
-- port-forward bracket. Carries everything the get\/put\/delete ops need, so one
-- bracket serves an entire load → pulumi → store\/delete lifecycle.
data HostDirectPulumiHandle = HostDirectPulumiHandle
  { hdhStore :: ObjectStoreConfig
  , hdhCipher :: DekCipher
  , hdhHmacKey :: ByteString
  , hdhClusterId :: Text
  }

-- | Resolve the port-forward-independent host-direct material. Mirrors
-- 'Prodbox.Settings.loadRuntimeInForceConfigWithToken': unencrypted basics →
-- ready root Vault token → MinIO root credentials (@secret/minio/root@) → HMAC
-- key (@secret/object-store/hmac@) → Vault-Transit DEK cipher — but with the
-- per-run transit key @"prodbox-pulumi-state"@, matching
-- 'Prodbox.Gateway.Daemon.resolveDaemonPulumiObjectMaterialOnce'. The residue
-- Vault gate ('Prodbox.Lifecycle.LiveResidue.queryResidueVaultGate') proves
-- Vault unsealed before this runs, so the Vault steps here succeed; only the
-- subsequent port-forward (apiserver + MinIO pod) can still fail.
resolveHostDirectPulumiMaterial :: FilePath -> IO (Either String HostDirectPulumiMaterial)
resolveHostDirectPulumiMaterial repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  case basicsResult of
    Left err -> pure (Left ("host-direct Pulumi fallback: " ++ err))
    Right basics -> do
      let address = VaultAddress (basicsVaultAddress basics)
      tokenResult <- loadReadyVaultRootToken repoRoot address
      case tokenResult of
        Left err -> pure (Left ("host-direct Pulumi fallback: " ++ err))
        Right token -> do
          credsResult <- readMinioRootCredentials address token
          hmacResult <- readObjectStoreHmacKey address token
          pure $ do
            (accessKey, secretKey) <- credsResult
            hmacKey <- hmacResult
            Right
              HostDirectPulumiMaterial
                { hdCipher = vaultTransitDekCipher address token "prodbox-pulumi-state"
                , hdHmacKey = hmacKey
                , hdClusterId = basicsClusterId basics
                , hdAccessKey = Text.unpack accessKey
                , hdSecretKey = Text.unpack secretKey
                }

-- | Open ONE MinIO port-forward bracket and bind the material to a live
-- 'ObjectStoreConfig' at @http://127.0.0.1:\<localPort>@, so the handle passed to
-- @action@ reuses the same forward for every op. Returns @Left@ if the
-- port-forward itself could not be established.
withHostDirectPulumiPortForward
  :: HostDirectPulumiMaterial
  -> (HostDirectPulumiHandle -> IO a)
  -> IO (Either String a)
withHostDirectPulumiPortForward material action =
  withMinioPortForward $ \localPort ->
    action
      HostDirectPulumiHandle
        { hdhStore =
            ObjectStoreConfig
              { objectStoreEndpoint = "http://127.0.0.1:" ++ show localPort
              , objectStoreBucket = defaultObjectStoreBucket
              , objectStoreAccessKey = hdAccessKey material
              , objectStoreSecretKey = hdSecretKey material
              }
        , hdhCipher = hdCipher material
        , hdhHmacKey = hdHmacKey material
        , hdhClusterId = hdClusterId material
        }

-- | Host-direct GET of a per-run stack checkpoint. Mirrors
-- 'Prodbox.Gateway.Daemon.readDaemonPulumiObject': an absent object OR absent
-- bucket ('EncryptedObjectMissing') is @Right Nothing@ (positively absent);
-- every other failure stays @Left@ (failure-to-observe is not absence).
hostDirectGetPulumiObject :: HostDirectPulumiHandle -> Text -> IO (Either String (Maybe ByteString))
hostDirectGetPulumiObject handle stackName = do
  result <-
    getLogical
      (hdhStore handle)
      (hdhCipher handle)
      (hdhHmacKey handle)
      (hdhClusterId handle)
      (LogicalPulumiStack stackName)
  pure $ case result of
    Left (EncryptedObjectMissing _) -> Right Nothing
    Left err -> Left (renderEncryptedObjectError err)
    Right bytes -> Right (Just bytes)

-- | Host-direct PUT of a per-run stack checkpoint. Mirrors
-- 'Prodbox.Gateway.Daemon.writeDaemonPulumiObject'.
hostDirectPutPulumiObject :: HostDirectPulumiHandle -> Text -> ByteString -> IO (Either String ())
hostDirectPutPulumiObject handle stackName bytes = do
  result <-
    putLogical
      (hdhStore handle)
      (hdhCipher handle)
      (hdhHmacKey handle)
      (hdhClusterId handle)
      (LogicalPulumiStack stackName)
      bytes
  pure $ case result of
    Left err -> Left (renderEncryptedObjectError err)
    Right () -> Right ()

-- | Host-direct DELETE of a per-run stack checkpoint. Mirrors
-- 'Prodbox.Gateway.Daemon.deleteDaemonPulumiObject': deletes the opaque object
-- keyed by the HMAC of the logical name.
hostDirectDeletePulumiObject :: HostDirectPulumiHandle -> Text -> IO (Either String ())
hostDirectDeletePulumiObject handle stackName =
  deleteObject
    (hdhStore handle)
    (objectKeyForOpaqueId (opaqueObjectId (hdhHmacKey handle) (LogicalPulumiStack stackName)))

-- | Local copy of the @secret/minio/root@ reader (see module note). Mirrors
-- 'Prodbox.Settings.readMinioRootCredentials'.
readMinioRootCredentials :: VaultAddress -> VaultToken -> IO (Either String (Text, Text))
readMinioRootCredentials address token = do
  result <- vaultKvReadV2 address token "secret" "minio/root"
  pure $ case result of
    Left err -> Left ("failed to read secret/minio/root from Vault: " ++ renderHttpError err)
    Right fields -> do
      accessKey <- requireVaultField "secret/minio/root" "rootUser" fields
      secretKey <- requireVaultField "secret/minio/root" "rootPassword" fields
      Right (accessKey, secretKey)

-- | Local copy of the @secret/object-store/hmac@ reader (see module note).
-- Mirrors 'Prodbox.Settings.readObjectStoreHmacKey'.
readObjectStoreHmacKey :: VaultAddress -> VaultToken -> IO (Either String ByteString)
readObjectStoreHmacKey address token = do
  result <- vaultKvReadV2 address token "secret" "object-store/hmac"
  pure $ case result of
    Left err -> Left ("failed to read secret/object-store/hmac from Vault: " ++ renderHttpError err)
    Right fields -> TextEncoding.encodeUtf8 <$> requireVaultField "secret/object-store/hmac" "key" fields

requireVaultField :: Text -> Text -> Map Text Text -> Either String Text
requireVaultField path field fields =
  case Map.lookup field fields of
    Nothing -> Left ("Vault KV object " ++ Text.unpack path ++ " missing field `" ++ Text.unpack field ++ "`")
    Just value
      | Text.null (Text.strip value) ->
          Left ("Vault KV object " ++ Text.unpack path ++ " field `" ++ Text.unpack field ++ "` is empty")
      | otherwise -> Right value
