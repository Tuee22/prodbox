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
  , PrimaryPulumiCheckpointBlob
  , PrimaryPulumiCheckpointObservation (..)
  , observePrimaryPulumiCheckpointBlob
  , primaryPulumiCheckpointCiphertext
  , primaryPulumiCheckpointCiphertextDigest
  , primaryPulumiCheckpointVersion
  , publishPrimaryPulumiCheckpointBlob
  , restorePrimaryPulumiCheckpointBlob
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointCopyObservation (..)
  , PulumiCheckpointObservation (..)
  )
import Prodbox.ControlPlane.PulumiCheckpointRepository
  ( PulumiCheckpointBlobStore (..)
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( VerifiedPulumiCheckpointRef
  , mkVerifiedPulumiCheckpointRef
  , verifiedPulumiCheckpointBackupVersion
  , verifiedPulumiCheckpointCiphertextDigest
  , verifiedPulumiCheckpointDigest
  , verifiedPulumiCheckpointPrimaryVersion
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( CanonicalPulumiCheckpoint
  , canonicalPulumiCheckpointDigest
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
    , observePrimaryPulumiCheckpointCopy = observePrimaryCopy
    , observeBackupPulumiCheckpointCopy = observeBackupCopy
    , restorePulumiCheckpointPrimary = restorePrimary
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
    primary <- observePrimary registered reference
    backup <- observeBackup reference
    pure $ case (primary, backup) of
      (PrimaryPulumiCheckpointCurrent checkpoint primaryBlob, Right backupObservation) ->
        validateCompletePair reference checkpoint primaryBlob backupObservation
      (PrimaryPulumiCheckpointMissing, _) ->
        PulumiCheckpointCorrupt
          "authority aggregate references a missing primary checkpoint"
      (PrimaryPulumiCheckpointCorrupt detail, _) ->
        PulumiCheckpointCorrupt detail
      (PrimaryPulumiCheckpointUnobservable detail, _) ->
        PulumiCheckpointEndpointUnready detail
      (_, Left err) -> PulumiCheckpointEndpointUnready (renderClientError err)

  observePrimaryCopy registered reference =
    primaryCopyObservation reference <$> observePrimary registered reference

  observeBackupCopy _registered reference =
    fmap
      ( either
          (const (PulumiCheckpointCopyUnobservable "backup checkpoint request failed"))
          (backupCopyObservation reference)
      )
      (observeBackup reference)

  restorePrimary registered reference = do
    primary <- observePrimary registered reference
    backup <- observeBackup reference
    case (primary, backup) of
      (PrimaryPulumiCheckpointCurrent _ _, Right backupObservation) ->
        case backupCopyObservation reference backupObservation of
          PulumiCheckpointCopyCurrent _ -> pure (Right reference)
          other -> pure (Left (copyFailure "backup" other))
      (PrimaryPulumiCheckpointMissing, Right backupObservation) ->
        case backupObservation of
          AuthorityCheckpointBackupCurrent ciphertext receipt
            | authorityBackupReceiptObjectVersion receipt
                /= verifiedPulumiCheckpointBackupVersion reference ->
                pure (Left "checkpoint backup receipt version changed")
            | authorityBackupDigestText (authorityBackupReceiptDigest receipt)
                /= verifiedPulumiCheckpointCiphertextDigest reference ->
                pure (Left "checkpoint backup receipt digest changed")
            | otherwise -> do
                restored <-
                  restorePrimaryPulumiCheckpointBlob
                    primaryStore
                    registered
                    (pulumiCheckpointDigestText (verifiedPulumiCheckpointDigest reference))
                    (verifiedPulumiCheckpointCiphertextDigest reference)
                    (authorityBackupCiphertextBytes ciphertext)
                pure $ do
                  primaryBlob <- restored
                  first
                    (Text.pack . show)
                    ( mkVerifiedPulumiCheckpointRef
                        (verifiedPulumiCheckpointDigest reference)
                        (verifiedPulumiCheckpointCiphertextDigest reference)
                        (primaryPulumiCheckpointVersion primaryBlob)
                        (verifiedPulumiCheckpointCiphertextDigest reference)
                        (verifiedPulumiCheckpointBackupVersion reference)
                    )
          other ->
            pure
              ( Left
                  (copyFailure "backup" (backupCopyObservation reference other))
              )
      (PrimaryPulumiCheckpointCorrupt detail, _) ->
        pure (Left ("primary checkpoint is corrupt: " <> detail))
      (PrimaryPulumiCheckpointUnobservable detail, _) ->
        pure (Left ("primary checkpoint is unobservable: " <> detail))
      (_, Left err) ->
        pure (Left ("backup checkpoint is unobservable: " <> renderClientError err))

  observePrimary registered reference =
    observePrimaryPulumiCheckpointBlob
      primaryStore
      registered
      (pulumiCheckpointDigestText (verifiedPulumiCheckpointDigest reference))
      (verifiedPulumiCheckpointCiphertextDigest reference)
      (verifiedPulumiCheckpointPrimaryVersion reference)

  observeBackup reference =
    observeCheckpointBackup
      backupClient
      (verifiedPulumiCheckpointCiphertextDigest reference)

validateCompletePair
  :: VerifiedPulumiCheckpointRef
  -> CanonicalPulumiCheckpoint
  -> PrimaryPulumiCheckpointBlob
  -> AuthorityCheckpointBackupObservation
  -> PulumiCheckpointObservation
validateCompletePair reference checkpoint primaryBlob backup = case backup of
  AuthorityCheckpointBackupMissing ->
    PulumiCheckpointCorrupt
      "authority aggregate references a missing independent checkpoint backup"
  AuthorityCheckpointBackupCorrupt detail -> PulumiCheckpointCorrupt detail
  AuthorityCheckpointBackupCurrent ciphertext receipt
    | authorityBackupCiphertextBytes ciphertext
        /= primaryPulumiCheckpointCiphertext primaryBlob ->
        PulumiCheckpointCorrupt "primary and backup checkpoint ciphertext differ"
    | authorityBackupReceiptObjectVersion receipt
        /= verifiedPulumiCheckpointBackupVersion reference ->
        PulumiCheckpointCorrupt "checkpoint backup receipt version changed"
    | authorityBackupDigestText (authorityBackupReceiptDigest receipt)
        /= verifiedPulumiCheckpointCiphertextDigest reference ->
        PulumiCheckpointCorrupt "checkpoint backup receipt digest changed"
    | otherwise -> PulumiCheckpointCurrent checkpoint

primaryCopyObservation
  :: VerifiedPulumiCheckpointRef
  -> PrimaryPulumiCheckpointObservation
  -> PulumiCheckpointCopyObservation
primaryCopyObservation reference observation = case observation of
  PrimaryPulumiCheckpointMissing -> PulumiCheckpointCopyMissing
  PrimaryPulumiCheckpointCurrent _ blob
    | primaryPulumiCheckpointVersion blob
        == verifiedPulumiCheckpointPrimaryVersion reference ->
        PulumiCheckpointCopyCurrent (primaryPulumiCheckpointVersion blob)
    | otherwise -> PulumiCheckpointCopyCorrupt "primary checkpoint version changed"
  PrimaryPulumiCheckpointCorrupt detail -> PulumiCheckpointCopyCorrupt detail
  PrimaryPulumiCheckpointUnobservable detail ->
    PulumiCheckpointCopyUnobservable detail

backupCopyObservation
  :: VerifiedPulumiCheckpointRef
  -> AuthorityCheckpointBackupObservation
  -> PulumiCheckpointCopyObservation
backupCopyObservation reference observation = case observation of
  AuthorityCheckpointBackupMissing -> PulumiCheckpointCopyMissing
  AuthorityCheckpointBackupCorrupt detail ->
    PulumiCheckpointCopyCorrupt detail
  AuthorityCheckpointBackupCurrent _ receipt
    | authorityBackupReceiptObjectVersion receipt
        == verifiedPulumiCheckpointBackupVersion reference
        && authorityBackupDigestText (authorityBackupReceiptDigest receipt)
          == verifiedPulumiCheckpointCiphertextDigest reference ->
        PulumiCheckpointCopyCurrent (authorityBackupReceiptObjectVersion receipt)
    | otherwise -> PulumiCheckpointCopyCorrupt "backup checkpoint receipt changed"

copyFailure :: Text -> PulumiCheckpointCopyObservation -> Text
copyFailure label observation =
  label <> " checkpoint copy is not exact: " <> Text.pack (show observation)

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
