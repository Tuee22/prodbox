{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed ciphertext-copy protocol served by the Authority Backup Adapter.
-- The Adapter does not decode Authority state or make admission decisions: it
-- accepts a bounded opaque blob, derives its content address, performs an
-- immutable put/read-back, and returns a typed receipt.  Observe names only a
-- digest in one of the two registered backup blob classes.
module Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (..)
  , AuthorityBackupDigest
  , AuthorityBackupCiphertext
  , AuthorityBackupCopyRequest (..)
  , AuthorityBackupObserveRequest (..)
  , AuthorityBackupReceipt (..)
  , AuthorityBackupBlobObservation (..)
  , AuthorityBackupRepository (..)
  , AuthorityBackupCopyResult (..)
  , AuthorityBackupObserveResult (..)
  , authorityBackupMaximumCiphertextBytes
  , authorityBackupMaximumAggregateCiphertextBytes
  , mkAuthorityBackupCiphertext
  , authorityBackupCiphertextBytes
  , authorityBackupCiphertextDigest
  , mkAuthorityBackupDigest
  , authorityBackupDigestText
  , validateAuthorityBackupCiphertext
  , validateAuthorityBackupCiphertextForClass
  , serveBackupCopyRequest
  , serveBackupObserveRequest
  , authorityBackupHttpStatus
  , authorityBackupSummary
  , authorityBackupObserveStatus
  , authorityBackupObserveSummary
  , authorityBackupCopyResponseBody
  , authorityBackupObserveResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))

data AuthorityBackupBlobClass
  = AuthorityAggregateEnvelope
  | AuthorityCheckpointBlob
  | AuthorityConfigBlob
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype AuthorityBackupDigest = AuthorityBackupDigest Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

newtype AuthorityBackupCiphertext = AuthorityBackupCiphertext ByteString
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show AuthorityBackupCiphertext where
  show value =
    "<authority-backup-ciphertext:"
      <> show (ByteString.length (authorityBackupCiphertextBytes value))
      <> " bytes>"

data AuthorityBackupCopyRequest = AuthorityBackupCopyRequest
  { authorityBackupCopyClass :: !AuthorityBackupBlobClass
  , authorityBackupCopyCiphertext :: !AuthorityBackupCiphertext
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityBackupObserveRequest = AuthorityBackupObserveRequest
  { authorityBackupObserveClass :: !AuthorityBackupBlobClass
  , authorityBackupObserveDigest :: !AuthorityBackupDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityBackupReceipt = AuthorityBackupReceipt
  { authorityBackupReceiptClass :: !AuthorityBackupBlobClass
  , authorityBackupReceiptDigest :: !AuthorityBackupDigest
  , authorityBackupReceiptObjectVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityBackupBlobObservation
  = AuthorityBackupBlobMissing
  | AuthorityBackupBlobPresent !AuthorityBackupCiphertext !AuthorityBackupReceipt
  | AuthorityBackupBlobCorrupt !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityBackupRepository m = AuthorityBackupRepository
  { copyAuthorityBackupBlob
      :: AuthorityBackupBlobClass
      -> AuthorityBackupCiphertext
      -> m (Either Text AuthorityBackupReceipt)
  , observeAuthorityBackupBlob
      :: AuthorityBackupBlobClass
      -> AuthorityBackupDigest
      -> m (Either Text AuthorityBackupBlobObservation)
  }

data AuthorityBackupCopyResult
  = AuthorityBackupCopySucceeded !AuthorityBackupReceipt
  | AuthorityBackupCopyFailed !Text
  | AuthorityBackupCopyBadRequest !ControlPlaneRequestCodecError
  | AuthorityBackupCopyInvalidCiphertext
  deriving stock (Eq, Show)

data AuthorityBackupObserveResult
  = AuthorityBackupObserved !AuthorityBackupBlobObservation
  | AuthorityBackupObserveReadFailed !Text
  | AuthorityBackupObserveBadRequest !ControlPlaneRequestCodecError
  | AuthorityBackupObserveInvalidDigest
  deriving stock (Eq, Show)

-- | Hard ceiling for the encrypted checkpoint class.  A canonical checkpoint
-- is bounded at 64 MiB before sealing; base64-bearing envelope JSON is bounded
-- independently below 96 MiB.  The smaller aggregate class retains its
-- original sub-MiB limit.
authorityBackupMaximumCiphertextBytes :: Int
authorityBackupMaximumCiphertextBytes = 96 * 1024 * 1024

authorityBackupMaximumAggregateCiphertextBytes :: Int
authorityBackupMaximumAggregateCiphertextBytes = 768 * 1024

mkAuthorityBackupCiphertext :: ByteString -> Either Text AuthorityBackupCiphertext
mkAuthorityBackupCiphertext bytes = do
  validateCiphertextBytes authorityBackupMaximumCiphertextBytes bytes
  Right (AuthorityBackupCiphertext bytes)

authorityBackupCiphertextBytes :: AuthorityBackupCiphertext -> ByteString
authorityBackupCiphertextBytes (AuthorityBackupCiphertext bytes) = bytes

authorityBackupCiphertextDigest :: AuthorityBackupCiphertext -> AuthorityBackupDigest
authorityBackupCiphertextDigest =
  AuthorityBackupDigest
    . TextEncoding.decodeUtf8
    . hexSha256
    . authorityBackupCiphertextBytes

mkAuthorityBackupDigest :: Text -> Either Text AuthorityBackupDigest
mkAuthorityBackupDigest raw =
  let value = Text.strip raw
      valid character = isDigit character || character >= 'a' && character <= 'f'
   in if Text.length value == 64 && Text.all valid value
        then Right (AuthorityBackupDigest value)
        else Left "invalid Authority backup SHA-256 digest"

authorityBackupDigestText :: AuthorityBackupDigest -> Text
authorityBackupDigestText (AuthorityBackupDigest value) = value

validateAuthorityBackupCiphertext :: AuthorityBackupCiphertext -> Either Text ()
validateAuthorityBackupCiphertext =
  validateCiphertextBytes
    authorityBackupMaximumCiphertextBytes
    . authorityBackupCiphertextBytes

validateAuthorityBackupCiphertextForClass
  :: AuthorityBackupBlobClass
  -> AuthorityBackupCiphertext
  -> Either Text ()
validateAuthorityBackupCiphertextForClass blobClass =
  validateCiphertextBytes maximumBytes . authorityBackupCiphertextBytes
 where
  maximumBytes = case blobClass of
    AuthorityAggregateEnvelope -> authorityBackupMaximumAggregateCiphertextBytes
    AuthorityCheckpointBlob -> authorityBackupMaximumCiphertextBytes
    AuthorityConfigBlob -> 8 * 1024 * 1024

validateCiphertextBytes :: Int -> ByteString -> Either Text ()
validateCiphertextBytes maximumBytes bytes
  | ByteString.null bytes = Left "Authority backup ciphertext must not be empty"
  | ByteString.length bytes > maximumBytes =
      Left "Authority backup ciphertext exceeds the compiled bound"
  | otherwise = Right ()

serveBackupCopyRequest
  :: (Monad m)
  => Int
  -> AuthorityBackupRepository m
  -> LazyByteString.ByteString
  -> m AuthorityBackupCopyResult
serveBackupCopyRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityBackupCopyBadRequest err)
    Right request ->
      case validateAuthorityBackupCiphertextForClass
        (authorityBackupCopyClass request)
        (authorityBackupCopyCiphertext request) of
        Left _ -> pure AuthorityBackupCopyInvalidCiphertext
        Right () -> do
          copied <-
            copyAuthorityBackupBlob
              repository
              (authorityBackupCopyClass request)
              (authorityBackupCopyCiphertext request)
          pure $ case copied of
            Left detail -> AuthorityBackupCopyFailed detail
            Right receipt -> AuthorityBackupCopySucceeded receipt

serveBackupObserveRequest
  :: (Monad m)
  => Int
  -> AuthorityBackupRepository m
  -> LazyByteString.ByteString
  -> m AuthorityBackupObserveResult
serveBackupObserveRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityBackupObserveBadRequest err)
    Right request ->
      case mkAuthorityBackupDigest (authorityBackupDigestText (authorityBackupObserveDigest request)) of
        Left _ -> pure AuthorityBackupObserveInvalidDigest
        Right digest -> do
          observed <-
            observeAuthorityBackupBlob
              repository
              (authorityBackupObserveClass request)
              digest
          pure $ case observed of
            Left detail -> AuthorityBackupObserveReadFailed detail
            Right observation -> AuthorityBackupObserved observation

authorityBackupHttpStatus :: AuthorityBackupCopyResult -> ReplyStatus
authorityBackupHttpStatus result = case result of
  AuthorityBackupCopySucceeded _ -> ReplyOk
  AuthorityBackupCopyFailed _ -> ReplyServiceUnavailable
  AuthorityBackupCopyBadRequest _ -> ReplyBadRequest
  AuthorityBackupCopyInvalidCiphertext -> ReplyBadRequest

authorityBackupSummary :: AuthorityBackupCopyResult -> Text
authorityBackupSummary result = case result of
  AuthorityBackupCopySucceeded _ -> "backup-copy:read-back-confirmed"
  AuthorityBackupCopyFailed _ -> "backup-copy:failed"
  AuthorityBackupCopyBadRequest err ->
    "backup-copy:bad-request:" <> controlPlaneRequestCodecToken err
  AuthorityBackupCopyInvalidCiphertext -> "backup-copy:invalid-ciphertext"

authorityBackupObserveStatus :: AuthorityBackupObserveResult -> ReplyStatus
authorityBackupObserveStatus result = case result of
  AuthorityBackupObserved AuthorityBackupBlobMissing -> ReplyNotFound
  AuthorityBackupObserved (AuthorityBackupBlobPresent _ _) -> ReplyOk
  AuthorityBackupObserved (AuthorityBackupBlobCorrupt _) -> ReplyInternalError
  AuthorityBackupObserveReadFailed _ -> ReplyServiceUnavailable
  AuthorityBackupObserveBadRequest _ -> ReplyBadRequest
  AuthorityBackupObserveInvalidDigest -> ReplyBadRequest

authorityBackupObserveSummary :: AuthorityBackupObserveResult -> Text
authorityBackupObserveSummary result = case result of
  AuthorityBackupObserved AuthorityBackupBlobMissing -> "backup-observe:missing"
  AuthorityBackupObserved (AuthorityBackupBlobPresent _ _) -> "backup-observe:present"
  AuthorityBackupObserved (AuthorityBackupBlobCorrupt _) -> "backup-observe:corrupt"
  AuthorityBackupObserveReadFailed _ -> "backup-observe:read-failed"
  AuthorityBackupObserveBadRequest err ->
    "backup-observe:bad-request:" <> controlPlaneRequestCodecToken err
  AuthorityBackupObserveInvalidDigest -> "backup-observe:invalid-digest"

authorityBackupCopyResponseBody :: AuthorityBackupCopyResult -> ByteString
authorityBackupCopyResponseBody result = case result of
  AuthorityBackupCopySucceeded receipt ->
    LazyByteString.toStrict (encodeControlPlaneResponse receipt)
  _ -> TextEncoding.encodeUtf8 (authorityBackupSummary result)

authorityBackupObserveResponseBody :: AuthorityBackupObserveResult -> ByteString
authorityBackupObserveResponseBody result = case result of
  AuthorityBackupObserved observation ->
    LazyByteString.toStrict (encodeControlPlaneResponse observation)
  _ -> TextEncoding.encodeUtf8 (authorityBackupObserveSummary result)
