{-# LANGUAGE OverloadedStrings #-}

-- | Production immutable-byte composition for Pulumi checkpoints.  The
-- Lifecycle Authority seals and reads its primary MinIO copy; the physically
-- separate authenticated Authority Backup client receives the exact same
-- ciphertext.  Only matching read-back receipts can construct the aggregate
-- reference.
module Prodbox.ControlPlane.PulumiCheckpointProductionStore
  ( productionPulumiCheckpointBlobStore
  , confirmCheckpointBackupReplication
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityCheckpointBackupClient (..)
  , AuthorityCheckpointBackupObservation (..)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupReceipt (..)
  , authorityBackupCiphertextBytes
  , authorityBackupDigestText
  )
import Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStore
  , PrimaryPulumiCheckpointObservation (..)
  , observePrimaryPulumiCheckpointBlob
  , primaryPulumiCheckpointCiphertext
  , primaryPulumiCheckpointCiphertextDigest
  , primaryPulumiCheckpointVersion
  , publishPrimaryPulumiCheckpointBlob
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointObservation (..)
  )
import Prodbox.ControlPlane.PulumiCheckpointRepository
  ( PulumiCheckpointBlobStore (..)
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( mkVerifiedPulumiCheckpointRef
  , verifiedPulumiCheckpointBackupVersion
  , verifiedPulumiCheckpointCiphertextDigest
  , verifiedPulumiCheckpointDigest
  , verifiedPulumiCheckpointPrimaryVersion
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( canonicalPulumiCheckpointDigest
  , pulumiCheckpointDigestText
  )

productionPulumiCheckpointBlobStore
  :: InClusterAuthorityStore
  -> AuthorityCheckpointBackupClient IO
  -> PulumiCheckpointBlobStore IO
productionPulumiCheckpointBlobStore primaryStore backupClient =
  PulumiCheckpointBlobStore
    { replicatePulumiCheckpointBlob = replicateBlob
    , observePulumiCheckpointBlob = observeBlob
    }
 where
  replicateBlob registered checkpoint = do
    primaryResult <-
      publishPrimaryPulumiCheckpointBlob primaryStore registered checkpoint
    case primaryResult of
      Left detail -> pure (Left detail)
      Right primary -> do
        copied <-
          copyCheckpointBackup
            backupClient
            (primaryPulumiCheckpointCiphertext primary)
        let ciphertextDigest =
              primaryPulumiCheckpointCiphertextDigest primary
        observed <- observeCheckpointBackup backupClient ciphertextDigest
        pure $ do
          readBackReceipt <-
            confirmCheckpointBackupReplication
              (primaryPulumiCheckpointCiphertext primary)
              copied
              observed
          first
            (Text.pack . show)
            ( mkVerifiedPulumiCheckpointRef
                (canonicalPulumiCheckpointDigest checkpoint)
                ciphertextDigest
                (primaryPulumiCheckpointVersion primary)
                ( authorityBackupDigestText
                    (authorityBackupReceiptDigest readBackReceipt)
                )
                (authorityBackupReceiptObjectVersion readBackReceipt)
            )

  observeBlob registered reference = do
    primary <-
      observePrimaryPulumiCheckpointBlob
        primaryStore
        registered
        (pulumiCheckpointDigestText (verifiedPulumiCheckpointDigest reference))
        (verifiedPulumiCheckpointCiphertextDigest reference)
        (verifiedPulumiCheckpointPrimaryVersion reference)
    case primary of
      PrimaryPulumiCheckpointMissing ->
        pure
          (PulumiCheckpointCorrupt "authority aggregate references a missing primary checkpoint")
      PrimaryPulumiCheckpointCorrupt detail ->
        pure (PulumiCheckpointCorrupt detail)
      PrimaryPulumiCheckpointUnobservable detail ->
        pure (PulumiCheckpointEndpointUnready detail)
      PrimaryPulumiCheckpointCurrent checkpoint primaryBlob -> do
        backup <-
          observeCheckpointBackup
            backupClient
            (verifiedPulumiCheckpointCiphertextDigest reference)
        pure $ case backup of
          Left err -> PulumiCheckpointEndpointUnready (renderClientError err)
          Right AuthorityCheckpointBackupMissing ->
            PulumiCheckpointCorrupt
              "authority aggregate references a missing independent checkpoint backup"
          Right (AuthorityCheckpointBackupCorrupt detail) ->
            PulumiCheckpointCorrupt detail
          Right (AuthorityCheckpointBackupCurrent ciphertext receipt)
            | authorityBackupCiphertextBytes ciphertext
                /= primaryPulumiCheckpointCiphertext primaryBlob ->
                PulumiCheckpointCorrupt
                  "primary and backup checkpoint ciphertext differ"
            | authorityBackupReceiptObjectVersion receipt
                /= verifiedPulumiCheckpointBackupVersion reference ->
                PulumiCheckpointCorrupt
                  "checkpoint backup receipt version changed"
            | authorityBackupDigestText (authorityBackupReceiptDigest receipt)
                /= verifiedPulumiCheckpointCiphertextDigest reference ->
                PulumiCheckpointCorrupt
                  "checkpoint backup receipt digest changed"
            | otherwise -> PulumiCheckpointCurrent checkpoint

renderClientError :: (Show err) => err -> Text
renderClientError = Text.pack . show

-- | Confirm an immutable backup by authoritative read-back.  A successful
-- copy response must agree with that observation, but a lost copy response is
-- not itself a failure when the exact ciphertext and receipt are observable.
-- This is the response-loss convergence point for the physically separate
-- backup boundary.
confirmCheckpointBackupReplication
  :: (Show clientError)
  => ByteString
  -> Either clientError AuthorityBackupReceipt
  -> Either clientError AuthorityCheckpointBackupObservation
  -> Either Text AuthorityBackupReceipt
confirmCheckpointBackupReplication expectedBytes copied observed = do
  observation <- first renderClientError observed
  (readBackBytes, readBackReceipt) <- case observation of
    AuthorityCheckpointBackupMissing ->
      Left "checkpoint backup copy was missing after publication"
    AuthorityCheckpointBackupCorrupt detail ->
      Left ("checkpoint backup copy was corrupt: " <> detail)
    AuthorityCheckpointBackupCurrent ciphertext receipt ->
      Right (authorityBackupCiphertextBytes ciphertext, receipt)
  if readBackBytes /= expectedBytes
    then Left "primary and backup checkpoint ciphertext differ"
    else pure ()
  case copied of
    Left _ -> Right readBackReceipt
    Right copyReceipt
      | copyReceipt == readBackReceipt -> Right readBackReceipt
      | otherwise -> Left "checkpoint backup receipt changed during read-back"
