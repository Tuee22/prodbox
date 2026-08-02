{-# LANGUAGE OverloadedStrings #-}

-- | Primary MinIO plus independent Adapter replication for Authority config
-- blobs.  The aggregate receives a reference only after exact ciphertext
-- read-back from both failure domains.
module Prodbox.ControlPlane.ConfigProductionStore
  ( productionConfigBlobStore
  )
where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( authorityBackupCiphertextBytes
  , authorityBackupDigestText
  , authorityBackupReceiptDigest
  )
import Prodbox.ControlPlane.ConfigBackupClient
  ( ConfigBackupClient (..)
  , ConfigBackupObservation (..)
  )
import Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigBlobObservation (..)
  , ConfigBlobStore (..)
  )
import Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStore
  , PrimaryConfigObservation (..)
  , observePrimaryConfigBlob
  , primaryConfigCiphertext
  , primaryConfigReference
  , publishPrimaryConfigBlob
  )
import Prodbox.Lifecycle.Authority.Config (ConfigReference (..))

productionConfigBlobStore
  :: InClusterAuthorityStore
  -> ConfigBackupClient IO
  -> ConfigBlobStore IO
productionConfigBlobStore primaryStore backupClient =
  ConfigBlobStore
    { replicateConfigBlob = replicateBlob
    , observeConfigBlob = observeBlob
    }
 where
  replicateBlob digest canonicalBytes = do
    primary <- publishPrimaryConfigBlob primaryStore digest canonicalBytes
    case primary of
      Left detail -> pure (Left detail)
      Right primaryBlob -> do
        let ciphertext = primaryConfigCiphertext primaryBlob
            reference = primaryConfigReference primaryBlob
            referenceDigest = referenceText reference
        _ <- copyConfigBackup backupClient ciphertext
        observed <- observeConfigBackup backupClient referenceDigest
        pure $ case observed of
          Left err -> Left (Text.pack (show err))
          Right ConfigBackupMissing ->
            Left "config backup copy is missing after publication"
          Right (ConfigBackupCorrupt detail) ->
            Left ("config backup copy is corrupt: " <> detail)
          Right (ConfigBackupCurrent backupCiphertext receipt)
            | authorityBackupCiphertextBytes backupCiphertext /= ciphertext ->
                Left "primary and backup config ciphertext differ"
            | authorityBackupDigestText (authorityBackupReceiptDigest receipt)
                /= referenceDigest ->
                Left "config backup receipt digest mismatch"
            | otherwise -> Right reference

  observeBlob digest reference = do
    primary <- observePrimaryConfigBlob primaryStore digest reference
    case primary of
      PrimaryConfigMissing -> pure ConfigBlobMissing
      PrimaryConfigCorrupt detail -> pure (ConfigBlobCorrupt detail)
      PrimaryConfigUnobservable detail -> pure (ConfigBlobUnobservable detail)
      PrimaryConfigCurrent plaintext primaryBlob -> do
        backup <- observeConfigBackup backupClient (referenceText reference)
        pure $ case backup of
          Left err -> ConfigBlobUnobservable (Text.pack (show err))
          Right ConfigBackupMissing ->
            ConfigBlobCorrupt "Authority aggregate references a missing config backup"
          Right (ConfigBackupCorrupt detail) -> ConfigBlobCorrupt detail
          Right (ConfigBackupCurrent backupCiphertext receipt)
            | authorityBackupCiphertextBytes backupCiphertext
                /= primaryConfigCiphertext primaryBlob ->
                ConfigBlobCorrupt "primary and backup config ciphertext differ"
            | authorityBackupDigestText (authorityBackupReceiptDigest receipt)
                /= referenceText reference ->
                ConfigBlobCorrupt "config backup receipt digest mismatch"
            | ByteString.null plaintext ->
                ConfigBlobCorrupt "decrypted config payload is empty"
            | otherwise -> ConfigBlobCurrent plaintext

referenceText :: ConfigReference -> Text.Text
referenceText (ConfigReference value) = value
