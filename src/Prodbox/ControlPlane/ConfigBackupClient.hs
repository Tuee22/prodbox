{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated client restricted to the Authority Backup Adapter's config
-- blob class.  It cannot select aggregate or checkpoint objects.
module Prodbox.ControlPlane.ConfigBackupClient
  ( ConfigBackupClient (..)
  , ConfigBackupClientError (..)
  , ConfigBackupObservation (..)
  , configBackupClient
  , decodeConfigBackupResponse
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseObservation
  , classifyAuthenticatedRolePlainResponse
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientProviders
  , AuthenticatedTransportBounds
  , callAuthenticatedControlPlane
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityConfigBlob)
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

data ConfigBackupClient m = ConfigBackupClient
  { copyConfigBackup
      :: ByteString
      -> m (Either ConfigBackupClientError AuthorityBackupReceipt)
  , observeConfigBackup
      :: Text
      -> m (Either ConfigBackupClientError ConfigBackupObservation)
  }

data ConfigBackupObservation
  = ConfigBackupMissing
  | ConfigBackupCurrent !AuthorityBackupCiphertext !AuthorityBackupReceipt
  | ConfigBackupCorrupt !Text
  deriving stock (Eq, Show)

data ConfigBackupClientError
  = ConfigBackupCiphertextInvalid !Text
  | ConfigBackupDigestInvalid !Text
  | ConfigBackupTransportFailed !AuthenticatedClientError
  | ConfigBackupHttpStatus !Int
  | ConfigBackupResponseInvalid
      !ControlPlaneResponseCodecError
      !AuthenticatedRolePlainResponseObservation
  | ConfigBackupReceiptMismatch
  deriving stock (Eq, Show)

configBackupClient
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'AuthorityBackupRuntime
  -> ConfigBackupClient IO
configBackupClient bounds providers client =
  ConfigBackupClient
    { copyConfigBackup = copyBlob
    , observeConfigBackup = observeBlob
    }
 where
  copyBlob bytes = case mkAuthorityBackupCiphertext bytes of
    Left detail -> pure (Left (ConfigBackupCiphertextInvalid detail))
    Right ciphertext -> do
      attempted <-
        callAuthenticatedControlPlane
          bounds
          providers
          client
          AuthorityBackupCopyRoute
          ( LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  AuthorityBackupCopyRequest
                    { authorityBackupCopyClass = AuthorityConfigBlob
                    , authorityBackupCopyCiphertext = ciphertext
                    }
              )
          )
      pure $ do
        response@(ControlPlaneResponse status _) <-
          first ConfigBackupTransportFailed attempted
        if status /= 200
          then Left (ConfigBackupHttpStatus status)
          else do
            receipt <- decodeConfigBackupResponse response
            validateReceipt ciphertext receipt
            Right receipt

  observeBlob rawDigest = case mkAuthorityBackupDigest rawDigest of
    Left detail -> pure (Left (ConfigBackupDigestInvalid detail))
    Right digest -> do
      attempted <-
        callAuthenticatedControlPlane
          bounds
          providers
          client
          AuthorityBackupObserveRoute
          ( LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  AuthorityBackupObserveRequest
                    { authorityBackupObserveClass = AuthorityConfigBlob
                    , authorityBackupObserveDigest = digest
                    }
              )
          )
      pure $ do
        response@(ControlPlaneResponse status _) <-
          first ConfigBackupTransportFailed attempted
        observation <- decodeConfigBackupResponse response
        case observation of
          AuthorityBackupBlobMissing
            | status == 404 -> Right ConfigBackupMissing
            | otherwise -> Left (ConfigBackupHttpStatus status)
          AuthorityBackupBlobCorrupt detail
            | status == 500 -> Right (ConfigBackupCorrupt detail)
            | otherwise -> Left (ConfigBackupHttpStatus status)
          AuthorityBackupBlobPresent ciphertext receipt
            | status /= 200 -> Left (ConfigBackupHttpStatus status)
            | authorityBackupCiphertextDigest ciphertext /= digest ->
                Left ConfigBackupReceiptMismatch
            | authorityBackupReceiptClass receipt /= AuthorityConfigBlob ->
                Left ConfigBackupReceiptMismatch
            | authorityBackupReceiptDigest receipt /= digest ->
                Left ConfigBackupReceiptMismatch
            | otherwise -> Right (ConfigBackupCurrent ciphertext receipt)

decodeConfigBackupResponse
  :: (Serialise response)
  => ControlPlaneResponse
  -> Either ConfigBackupClientError response
decodeConfigBackupResponse (ControlPlaneResponse status body) =
  first
    ( \err ->
        ConfigBackupResponseInvalid
          err
          (classifyAuthenticatedRolePlainResponse status body)
    )
    ( decodeControlPlaneResponse
        (8 * 1024 * 1024)
        (LazyByteString.fromStrict body)
    )

validateReceipt
  :: AuthorityBackupCiphertext
  -> AuthorityBackupReceipt
  -> Either ConfigBackupClientError ()
validateReceipt ciphertext receipt
  | authorityBackupReceiptClass receipt /= AuthorityConfigBlob =
      Left ConfigBackupReceiptMismatch
  | authorityBackupReceiptDigest receipt /= authorityBackupCiphertextDigest ciphertext =
      Left ConfigBackupReceiptMismatch
  | authorityBackupDigestText (authorityBackupReceiptDigest receipt)
      /= authorityBackupDigestText (authorityBackupCiphertextDigest ciphertext) =
      Left ConfigBackupReceiptMismatch
  | otherwise = Right ()
