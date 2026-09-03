{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated, role-indexed client for the immutable checkpoint blob class
-- served by the Authority Backup Adapter.  The capability cannot select the
-- aggregate class, an object key, a bucket, or an endpoint per request.
module Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityCheckpointBackupClient (..)
  , AuthorityCheckpointBackupClientError (..)
  , AuthorityCheckpointBackupObservation (..)
  , AuthorityAggregateBackupClient (..)
  , AuthorityAggregateBackupClientError (..)
  , AuthorityAggregateBackupObservation (..)
  , authorityCheckpointBackupMaximumResponseBytes
  , authorityCheckpointBackupClient
  , authorityCheckpointBackupClientWithTransport
  , authorityAggregateBackupClientWithTransport
  , decodeAuthorityAggregateBackupResponse
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseObservation
  , classifyAuthenticatedRolePlainResponse
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientProviders
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , callAuthenticatedClientTransport
  , callAuthenticatedControlPlane
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass
      ( AuthorityAggregateEnvelope
      , AuthorityCheckpointBlob
      )
  , AuthorityBackupBlobObservation (..)
  , AuthorityBackupCiphertext
  , AuthorityBackupCopyRequest (..)
  , AuthorityBackupDigest
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

data AuthorityCheckpointBackupClient m = AuthorityCheckpointBackupClient
  { copyCheckpointBackup
      :: ByteString
      -> m
           ( Either
               AuthorityCheckpointBackupClientError
               AuthorityBackupReceipt
           )
  , observeCheckpointBackup
      :: Text
      -> m
           ( Either
               AuthorityCheckpointBackupClientError
               AuthorityCheckpointBackupObservation
           )
  }

data AuthorityCheckpointBackupObservation
  = AuthorityCheckpointBackupMissing
  | AuthorityCheckpointBackupCurrent
      !AuthorityBackupCiphertext
      !AuthorityBackupReceipt
  | AuthorityCheckpointBackupCorrupt !Text
  deriving stock (Eq, Show)

data AuthorityCheckpointBackupClientError
  = AuthorityCheckpointBackupCiphertextInvalid !Text
  | AuthorityCheckpointBackupDigestInvalid !Text
  | AuthorityCheckpointBackupTransportFailed !AuthenticatedClientError
  | AuthorityCheckpointBackupHttpStatus !Int
  | AuthorityCheckpointBackupResponseInvalid !ControlPlaneResponseCodecError
  | AuthorityCheckpointBackupReceiptClassMismatch
  | AuthorityCheckpointBackupReceiptDigestMismatch !Text !Text
  | AuthorityCheckpointBackupReceiptVersionInvalid !Text
  | AuthorityCheckpointBackupObservationShapeMismatch
  deriving stock (Eq, Show)

-- | Aggregate-only capability used by the exceptional genesis/repair
-- coordinator. It cannot select checkpoint/config classes or physical keys.
data AuthorityAggregateBackupClient m = AuthorityAggregateBackupClient
  { copyAuthorityAggregateBackup
      :: ByteString
      -> m
           ( Either
               AuthorityAggregateBackupClientError
               AuthorityBackupReceipt
           )
  , observeAuthorityAggregateBackup
      :: Text
      -> m
           ( Either
               AuthorityAggregateBackupClientError
               AuthorityAggregateBackupObservation
           )
  }

data AuthorityAggregateBackupObservation
  = AuthorityAggregateBackupMissing
  | AuthorityAggregateBackupCurrent
      !AuthorityBackupCiphertext
      !AuthorityBackupReceipt
  | AuthorityAggregateBackupCorrupt !Text
  deriving stock (Eq, Show)

data AuthorityAggregateBackupClientError
  = AuthorityAggregateBackupCiphertextInvalid !Text
  | AuthorityAggregateBackupDigestInvalid !Text
  | AuthorityAggregateBackupTransportFailed !AuthenticatedClientError
  | AuthorityAggregateBackupHttpStatus !Int
  | AuthorityAggregateBackupResponseInvalid
      !ControlPlaneResponseCodecError
      !AuthenticatedRolePlainResponseObservation
  | AuthorityAggregateBackupReceiptClassMismatch
  | AuthorityAggregateBackupReceiptDigestMismatch !Text !Text
  | AuthorityAggregateBackupReceiptVersionInvalid !Text
  | AuthorityAggregateBackupObservationShapeMismatch
  deriving stock (Eq, Show)

authorityCheckpointBackupMaximumResponseBytes :: Int
authorityCheckpointBackupMaximumResponseBytes = 96 * 1024 * 1024

authorityCheckpointBackupClient
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'AuthorityBackupRuntime
  -> AuthorityCheckpointBackupClient IO
authorityCheckpointBackupClient bounds providers client =
  AuthorityCheckpointBackupClient
    { copyCheckpointBackup = copyCheckpoint
    , observeCheckpointBackup = observeCheckpoint
    }
 where
  copyCheckpoint bytes = case mkAuthorityBackupCiphertext bytes of
    Left detail -> pure (Left (AuthorityCheckpointBackupCiphertextInvalid detail))
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
                    { authorityBackupCopyClass = AuthorityCheckpointBlob
                    , authorityBackupCopyCiphertext = ciphertext
                    }
              )
          )
      pure $ do
        ControlPlaneResponse status body <-
          first AuthorityCheckpointBackupTransportFailed attempted
        if status /= 200
          then Left (AuthorityCheckpointBackupHttpStatus status)
          else do
            receipt <- decodeResponse body
            validateReceipt (authorityBackupCiphertextDigest ciphertext) receipt
            Right receipt

  observeCheckpoint rawDigest = case mkAuthorityBackupDigest rawDigest of
    Left detail -> pure (Left (AuthorityCheckpointBackupDigestInvalid detail))
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
                    { authorityBackupObserveClass = AuthorityCheckpointBlob
                    , authorityBackupObserveDigest = digest
                    }
              )
          )
      pure $ do
        ControlPlaneResponse status body <-
          first AuthorityCheckpointBackupTransportFailed attempted
        observation <- decodeResponse body
        case observation of
          AuthorityBackupBlobMissing
            | status == 404 -> Right AuthorityCheckpointBackupMissing
            | otherwise -> Left (AuthorityCheckpointBackupHttpStatus status)
          AuthorityBackupBlobCorrupt detail
            | status == 500 -> Right (AuthorityCheckpointBackupCorrupt detail)
            | otherwise -> Left (AuthorityCheckpointBackupHttpStatus status)
          AuthorityBackupBlobPresent ciphertext receipt
            | status /= 200 -> Left (AuthorityCheckpointBackupHttpStatus status)
            | authorityBackupCiphertextDigest ciphertext /= digest ->
                Left AuthorityCheckpointBackupObservationShapeMismatch
            | otherwise -> do
                validateReceipt digest receipt
                Right (AuthorityCheckpointBackupCurrent ciphertext receipt)

  decodeResponse body =
    first
      AuthorityCheckpointBackupResponseInvalid
      ( decodeControlPlaneResponse
          authorityCheckpointBackupMaximumResponseBytes
          (LazyByteString.fromStrict body)
      )

-- | Use an already role-indexed authenticated transport. This is the
-- production host/coordinator entry: caller identity, scope, epoch, nonce,
-- deadline, and response bounds are fixed before this narrower client exists.
authorityCheckpointBackupClientWithTransport
  :: AuthenticatedClientTransport 'AuthorityBackupRuntime
  -> AuthorityCheckpointBackupClient IO
authorityCheckpointBackupClientWithTransport transport =
  AuthorityCheckpointBackupClient
    { copyCheckpointBackup = copyCheckpoint
    , observeCheckpointBackup = observeCheckpoint
    }
 where
  copyCheckpoint bytes = case mkAuthorityBackupCiphertext bytes of
    Left detail -> pure (Left (AuthorityCheckpointBackupCiphertextInvalid detail))
    Right ciphertext -> do
      attempted <-
        callAuthenticatedClientTransport
          transport
          AuthorityBackupCopyRoute
          ( LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  AuthorityBackupCopyRequest
                    { authorityBackupCopyClass = AuthorityCheckpointBlob
                    , authorityBackupCopyCiphertext = ciphertext
                    }
              )
          )
      pure $ do
        ControlPlaneResponse status body <-
          first AuthorityCheckpointBackupTransportFailed attempted
        if status /= 200
          then Left (AuthorityCheckpointBackupHttpStatus status)
          else do
            receipt <- decodeResponse body
            validateReceipt (authorityBackupCiphertextDigest ciphertext) receipt
            Right receipt

  observeCheckpoint rawDigest = case mkAuthorityBackupDigest rawDigest of
    Left detail -> pure (Left (AuthorityCheckpointBackupDigestInvalid detail))
    Right digest -> do
      attempted <-
        callAuthenticatedClientTransport
          transport
          AuthorityBackupObserveRoute
          ( LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  AuthorityBackupObserveRequest
                    { authorityBackupObserveClass = AuthorityCheckpointBlob
                    , authorityBackupObserveDigest = digest
                    }
              )
          )
      pure $ do
        ControlPlaneResponse status body <-
          first AuthorityCheckpointBackupTransportFailed attempted
        observation <- decodeResponse body
        case observation of
          AuthorityBackupBlobMissing
            | status == 404 -> Right AuthorityCheckpointBackupMissing
            | otherwise -> Left (AuthorityCheckpointBackupHttpStatus status)
          AuthorityBackupBlobCorrupt detail
            | status == 500 -> Right (AuthorityCheckpointBackupCorrupt detail)
            | otherwise -> Left (AuthorityCheckpointBackupHttpStatus status)
          AuthorityBackupBlobPresent ciphertext receipt
            | status /= 200 -> Left (AuthorityCheckpointBackupHttpStatus status)
            | authorityBackupCiphertextDigest ciphertext /= digest ->
                Left AuthorityCheckpointBackupObservationShapeMismatch
            | otherwise -> do
                validateReceipt digest receipt
                Right (AuthorityCheckpointBackupCurrent ciphertext receipt)

  decodeResponse body =
    first
      AuthorityCheckpointBackupResponseInvalid
      ( decodeControlPlaneResponse
          authorityCheckpointBackupMaximumResponseBytes
          (LazyByteString.fromStrict body)
      )

authorityAggregateBackupClientWithTransport
  :: AuthenticatedClientTransport 'AuthorityBackupRuntime
  -> AuthorityAggregateBackupClient IO
authorityAggregateBackupClientWithTransport transport =
  AuthorityAggregateBackupClient
    { copyAuthorityAggregateBackup = copyAggregate
    , observeAuthorityAggregateBackup = observeAggregate
    }
 where
  copyAggregate bytes = case mkAuthorityBackupCiphertext bytes of
    Left detail -> pure (Left (AuthorityAggregateBackupCiphertextInvalid detail))
    Right ciphertext -> do
      attempted <-
        callAuthenticatedClientTransport
          transport
          AuthorityBackupCopyRoute
          ( LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  AuthorityBackupCopyRequest
                    { authorityBackupCopyClass = AuthorityAggregateEnvelope
                    , authorityBackupCopyCiphertext = ciphertext
                    }
              )
          )
      pure $ do
        response@(ControlPlaneResponse status _) <-
          first AuthorityAggregateBackupTransportFailed attempted
        if status /= 200
          then Left (AuthorityAggregateBackupHttpStatus status)
          else do
            receipt <- decodeAuthorityAggregateBackupResponse response
            validateAggregateReceipt
              (authorityBackupCiphertextDigest ciphertext)
              receipt
            Right receipt

  observeAggregate rawDigest = case mkAuthorityBackupDigest rawDigest of
    Left detail -> pure (Left (AuthorityAggregateBackupDigestInvalid detail))
    Right digest -> do
      attempted <-
        callAuthenticatedClientTransport
          transport
          AuthorityBackupObserveRoute
          ( LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  AuthorityBackupObserveRequest
                    { authorityBackupObserveClass = AuthorityAggregateEnvelope
                    , authorityBackupObserveDigest = digest
                    }
              )
          )
      pure $ do
        response@(ControlPlaneResponse status _) <-
          first AuthorityAggregateBackupTransportFailed attempted
        observation <- decodeAuthorityAggregateBackupResponse response
        case observation of
          AuthorityBackupBlobMissing
            | status == 404 -> Right AuthorityAggregateBackupMissing
            | otherwise -> Left (AuthorityAggregateBackupHttpStatus status)
          AuthorityBackupBlobCorrupt detail
            | status == 500 -> Right (AuthorityAggregateBackupCorrupt detail)
            | otherwise -> Left (AuthorityAggregateBackupHttpStatus status)
          AuthorityBackupBlobPresent ciphertext receipt
            | status /= 200 -> Left (AuthorityAggregateBackupHttpStatus status)
            | authorityBackupCiphertextDigest ciphertext /= digest ->
                Left AuthorityAggregateBackupObservationShapeMismatch
            | otherwise -> do
                validateAggregateReceipt digest receipt
                Right (AuthorityAggregateBackupCurrent ciphertext receipt)

decodeAuthorityAggregateBackupResponse
  :: (Serialise response)
  => ControlPlaneResponse
  -> Either AuthorityAggregateBackupClientError response
decodeAuthorityAggregateBackupResponse (ControlPlaneResponse status body) =
  first
    ( \err ->
        AuthorityAggregateBackupResponseInvalid
          err
          (classifyAuthenticatedRolePlainResponse status body)
    )
    ( decodeControlPlaneResponse
        authorityCheckpointBackupMaximumResponseBytes
        (LazyByteString.fromStrict body)
    )

validateAggregateReceipt
  :: AuthorityBackupDigest
  -> AuthorityBackupReceipt
  -> Either AuthorityAggregateBackupClientError ()
validateAggregateReceipt expected receipt
  | authorityBackupReceiptClass receipt /= AuthorityAggregateEnvelope =
      Left AuthorityAggregateBackupReceiptClassMismatch
  | authorityBackupReceiptDigest receipt /= expected =
      Left
        ( AuthorityAggregateBackupReceiptDigestMismatch
            (authorityBackupDigestText expected)
            (authorityBackupDigestText (authorityBackupReceiptDigest receipt))
        )
  | not (validVersion (authorityBackupReceiptObjectVersion receipt)) =
      Left
        ( AuthorityAggregateBackupReceiptVersionInvalid
            (authorityBackupReceiptObjectVersion receipt)
        )
  | otherwise = Right ()
 where
  validVersion version =
    not (Text.null version)
      && Text.length version <= 512
      && not (Text.any (\character -> isControl character || isSpace character) version)

validateReceipt
  :: AuthorityBackupDigest
  -> AuthorityBackupReceipt
  -> Either AuthorityCheckpointBackupClientError ()
validateReceipt expected receipt
  | authorityBackupReceiptClass receipt /= AuthorityCheckpointBlob =
      Left AuthorityCheckpointBackupReceiptClassMismatch
  | authorityBackupReceiptDigest receipt /= expected =
      Left
        ( AuthorityCheckpointBackupReceiptDigestMismatch
            (authorityBackupDigestText expected)
            (authorityBackupDigestText (authorityBackupReceiptDigest receipt))
        )
  | not (validVersion (authorityBackupReceiptObjectVersion receipt)) =
      Left
        ( AuthorityCheckpointBackupReceiptVersionInvalid
            (authorityBackupReceiptObjectVersion receipt)
        )
  | otherwise = Right ()
 where
  validVersion version =
    not (Text.null version)
      && Text.length version <= 512
      && not (Text.any (\character -> isControl character || isSpace character) version)
