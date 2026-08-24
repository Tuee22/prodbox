{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: authenticated client restricted to the Authority Backup
-- Adapter's cleanup-report blob class.  It cannot select the aggregate,
-- checkpoint, or config objects.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 7](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- requires the /independent/ Backup Adapter to read back the exact
-- pre-uninstall cleanup report the Authority committed.  Reaching that failure
-- domain needed a decision, because the adapter addresses objects only by
-- @(class, digest)@ and no class named a cleanup report: either the report
-- becomes a fourth blob class the Authority replicates, or the adapter grows a
-- second addressing scheme over a distinct retained namespace.
--
-- __The fourth class is the smaller change and the one taken.__  The adapter's
-- object names are @blobs\/\<class\>\/sha256-\<digest\>@ beneath a bucket prefix
-- of @authority-backup-store\/\<cluster_id\>@, and its least-privilege IAM grant
-- is written against that prefix, so a new class is a new path inside a
-- permission the adapter already holds — no policy widens, no second scheme
-- appears, and the report is content-addressed by exactly the identity node 7
-- asks the adapter to confirm.  A distinct retained namespace would have needed
-- its own registered prefix and its own grant for a value that is already a
-- digest.
--
-- __What this client is not.__  It is a reader and a replicator of one class,
-- not the Stage-C read-back boundary: turning an observation into
-- @CascadePreUninstallReportObservation@ is
-- "Prodbox.Lifecycle.Teardown.PreUninstallReportBackup", because that join needs
-- the compiled run's scope and graph digest, which are lifecycle values this
-- module deliberately does not see.
module Prodbox.ControlPlane.CleanupReportBackupClient
  ( CleanupReportBackupClient (..)
  , CleanupReportBackupClientError (..)
  , renderCleanupReportBackupClientError
  , CleanupReportBackupObservation (..)
  , cleanupReportBackupClient
  , cleanupReportBackupClientWithTransport
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientProviders
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , callAuthenticatedClientTransport
  , callAuthenticatedControlPlane
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityCleanupReportBlob)
  , AuthorityBackupBlobObservation (..)
  , AuthorityBackupCiphertext
  , AuthorityBackupCopyRequest (..)
  , AuthorityBackupObserveRequest (..)
  , AuthorityBackupReceipt (..)
  , authorityBackupCiphertextDigest
  , authorityBackupDigestText
  , mkAuthorityBackupCiphertext
  , mkAuthorityBackupDigest
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( AuthorityBackupCopyRoute
    , AuthorityBackupObserveRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Runtime.Role (RuntimeRole (AuthorityBackupRuntime))

data CleanupReportBackupClient m = CleanupReportBackupClient
  { copyCleanupReportBackup
      :: ByteString
      -> m (Either CleanupReportBackupClientError AuthorityBackupReceipt)
  , observeCleanupReportBackup
      :: Text
      -> m (Either CleanupReportBackupClientError CleanupReportBackupObservation)
  }

-- | What the independent domain holds for one report identity.
--
-- @Missing@ and @Corrupt@ are kept distinct because they license different
-- conclusions: a report the adapter has never seen is a commit that did not
-- reach the independent domain, while a report whose bytes no longer hash to
-- their name is a domain that reached it and lost it.
data CleanupReportBackupObservation
  = CleanupReportBackupMissing
  | CleanupReportBackupCurrent !AuthorityBackupCiphertext !AuthorityBackupReceipt
  | CleanupReportBackupCorrupt !Text
  deriving stock (Eq, Show)

data CleanupReportBackupClientError
  = CleanupReportBackupCiphertextInvalid !Text
  | CleanupReportBackupDigestInvalid !Text
  | CleanupReportBackupTransportFailed !AuthenticatedClientError
  | CleanupReportBackupHttpStatus !Int
  | CleanupReportBackupResponseInvalid !ControlPlaneResponseCodecError
  | CleanupReportBackupReceiptMismatch
  deriving stock (Eq, Show)

renderCleanupReportBackupClientError :: CleanupReportBackupClientError -> Text
renderCleanupReportBackupClientError err = case err of
  CleanupReportBackupCiphertextInvalid detail ->
    "cleanup-report backup ciphertext is invalid: " <> detail
  CleanupReportBackupDigestInvalid detail ->
    "cleanup-report backup digest is invalid: " <> detail
  CleanupReportBackupTransportFailed detail ->
    "cleanup-report backup transport failed: " <> Text.pack (show detail)
  CleanupReportBackupHttpStatus status ->
    "cleanup-report backup answered an unexpected status "
      <> Text.pack (show status)
  CleanupReportBackupResponseInvalid detail ->
    "cleanup-report backup response did not decode: " <> Text.pack (show detail)
  CleanupReportBackupReceiptMismatch ->
    "cleanup-report backup receipt names another class or digest"

cleanupReportBackupClient
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'AuthorityBackupRuntime
  -> CleanupReportBackupClient IO
cleanupReportBackupClient bounds providers client =
  cleanupReportBackupClientOver
    (callAuthenticatedControlPlane bounds providers client)

-- | Narrow an already authenticated, role-indexed Backup Adapter session to
-- the cleanup-report object class.  This is the production host-cascade entry:
-- it preserves the caller, nonce, deadline, and response bounds selected by
-- the surrounding composition instead of opening a second session.
cleanupReportBackupClientWithTransport
  :: AuthenticatedClientTransport 'AuthorityBackupRuntime
  -> CleanupReportBackupClient IO
cleanupReportBackupClientWithTransport transport =
  cleanupReportBackupClientOver (callAuthenticatedClientTransport transport)

cleanupReportBackupClientOver
  :: ( ControlPlaneRouteFor 'AuthorityBackupRuntime
       -> ByteString
       -> IO (Either AuthenticatedClientError ControlPlaneResponse)
     )
  -> CleanupReportBackupClient IO
cleanupReportBackupClientOver call =
  CleanupReportBackupClient
    { copyCleanupReportBackup = copyBlob
    , observeCleanupReportBackup = observeBlob
    }
 where
  copyBlob bytes = case mkAuthorityBackupCiphertext bytes of
    Left detail -> pure (Left (CleanupReportBackupCiphertextInvalid detail))
    Right ciphertext -> do
      attempted <-
        call
          AuthorityBackupCopyRoute
          ( LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  AuthorityBackupCopyRequest
                    { authorityBackupCopyClass = AuthorityCleanupReportBlob
                    , authorityBackupCopyCiphertext = ciphertext
                    }
              )
          )
      pure $ do
        ControlPlaneResponse status body <-
          first CleanupReportBackupTransportFailed attempted
        if status /= 200
          then Left (CleanupReportBackupHttpStatus status)
          else do
            receipt <- decodeResponse body
            validateReceipt ciphertext receipt
            Right receipt

  observeBlob rawDigest = case mkAuthorityBackupDigest rawDigest of
    Left detail -> pure (Left (CleanupReportBackupDigestInvalid detail))
    Right digest -> do
      attempted <-
        call
          AuthorityBackupObserveRoute
          ( LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  AuthorityBackupObserveRequest
                    { authorityBackupObserveClass = AuthorityCleanupReportBlob
                    , authorityBackupObserveDigest = digest
                    }
              )
          )
      pure $ do
        ControlPlaneResponse status body <-
          first CleanupReportBackupTransportFailed attempted
        observation <- decodeResponse body
        case observation of
          AuthorityBackupBlobMissing
            | status == 404 -> Right CleanupReportBackupMissing
            | otherwise -> Left (CleanupReportBackupHttpStatus status)
          AuthorityBackupBlobCorrupt detail
            | status == 500 -> Right (CleanupReportBackupCorrupt detail)
            | otherwise -> Left (CleanupReportBackupHttpStatus status)
          AuthorityBackupBlobPresent ciphertext receipt
            | status /= 200 -> Left (CleanupReportBackupHttpStatus status)
            | authorityBackupCiphertextDigest ciphertext /= digest ->
                Left CleanupReportBackupReceiptMismatch
            | authorityBackupReceiptClass receipt /= AuthorityCleanupReportBlob ->
                Left CleanupReportBackupReceiptMismatch
            | authorityBackupReceiptDigest receipt /= digest ->
                Left CleanupReportBackupReceiptMismatch
            | otherwise -> Right (CleanupReportBackupCurrent ciphertext receipt)

  decodeResponse body =
    first
      CleanupReportBackupResponseInvalid
      ( decodeControlPlaneResponse
          (2 * 1024 * 1024)
          (LazyByteString.fromStrict body)
      )

validateReceipt
  :: AuthorityBackupCiphertext
  -> AuthorityBackupReceipt
  -> Either CleanupReportBackupClientError ()
validateReceipt ciphertext receipt
  | authorityBackupReceiptClass receipt /= AuthorityCleanupReportBlob =
      Left CleanupReportBackupReceiptMismatch
  | authorityBackupReceiptDigest receipt /= authorityBackupCiphertextDigest ciphertext =
      Left CleanupReportBackupReceiptMismatch
  | authorityBackupDigestText (authorityBackupReceiptDigest receipt)
      /= authorityBackupDigestText (authorityBackupCiphertextDigest ciphertext) =
      Left CleanupReportBackupReceiptMismatch
  | otherwise = Right ()
