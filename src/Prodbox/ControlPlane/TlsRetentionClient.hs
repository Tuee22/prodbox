{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated, role-indexed client for the ciphertext-only TLS Retention
-- Adapter.  The client can address only the two compiled TLS routes and only
-- by an exact immutable 'RetainedTlsRef'; it exposes no bucket, object-key,
-- plaintext-Secret, or "latest object" operation.
module Prodbox.ControlPlane.TlsRetentionClient
  ( TlsRetentionClient (..)
  , TlsRetentionClientError (..)
  , tlsRetentionMaximumResponseBytes
  , tlsRetentionClient
  , tlsRetentionClientWithTransport
  )
where

import Codec.Serialise (Serialise)
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
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor (TlsRetentionRestoreRoute, TlsRetentionStoreRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsEnvelopeObservation (..)
  , TlsRestorePayload (..)
  , TlsRetentionReceipt (..)
  , TlsSealedEnvelope
  , TlsStorePayload (..)
  , tlsSealedEnvelopeDigest
  , validateTlsSealedEnvelope
  )
import Prodbox.Lifecycle.Authority.TlsRetention (RetainedTlsRef (..))
import Prodbox.Runtime.Role (RuntimeRole (TlsRetentionRuntime))

data TlsRetentionClient m = TlsRetentionClient
  { storeTlsRetention
      :: RetainedTlsRef
      -> TlsSealedEnvelope
      -> m (Either TlsRetentionClientError TlsRetentionReceipt)
  , restoreTlsRetention
      :: RetainedTlsRef
      -> m (Either TlsRetentionClientError TlsEnvelopeObservation)
  }

data TlsRetentionClientError
  = TlsRetentionClientEnvelopeInvalid !Text
  | TlsRetentionClientCandidateDigestMismatch !Text !Text
  | TlsRetentionClientTransportFailed !AuthenticatedClientError
  | TlsRetentionClientHttpStatus !Int
  | TlsRetentionClientResponseInvalid !ControlPlaneResponseCodecError
  | TlsRetentionClientReceiptReferenceMismatch
  | TlsRetentionClientReceiptDigestMismatch !Text !Text
  | TlsRetentionClientReceiptVersionInvalid
  | TlsRetentionClientObservationReferenceMismatch
  | TlsRetentionClientObservationDigestMismatch !Text !Text
  deriving stock (Eq, Show)

tlsRetentionMaximumResponseBytes :: Int
tlsRetentionMaximumResponseBytes = 2 * 1024 * 1024

tlsRetentionClient
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'TlsRetentionRuntime
  -> TlsRetentionClient IO
tlsRetentionClient bounds providers client =
  clientFromCall
    (\route body -> callAuthenticatedControlPlane bounds providers client route body)

-- | Narrow a production role-indexed authenticated transport to the exact TLS
-- Adapter protocol.  Caller identity, authority scope/epoch, nonce, deadline,
-- and response bounds have already been fixed before this value can exist.
tlsRetentionClientWithTransport
  :: AuthenticatedClientTransport 'TlsRetentionRuntime
  -> TlsRetentionClient IO
tlsRetentionClientWithTransport transport =
  clientFromCall (callAuthenticatedClientTransport transport)

clientFromCall
  :: ( ControlPlaneRouteFor 'TlsRetentionRuntime
       -> ByteString
       -> IO (Either AuthenticatedClientError ControlPlaneResponse)
     )
  -> TlsRetentionClient IO
clientFromCall call =
  TlsRetentionClient
    { storeTlsRetention = store
    , restoreTlsRetention = restore
    }
 where
  store reference envelope = case validateTlsSealedEnvelope envelope of
    Left detail -> pure (Left (TlsRetentionClientEnvelopeInvalid detail))
    Right ()
      | retainedCiphertextDigest reference /= tlsSealedEnvelopeDigest envelope ->
          pure
            ( Left
                ( TlsRetentionClientCandidateDigestMismatch
                    (retainedCiphertextDigest reference)
                    (tlsSealedEnvelopeDigest envelope)
                )
            )
      | otherwise -> do
          attempted <-
            call
              TlsRetentionStoreRoute
              (strictRequest (TlsStorePayload reference envelope))
          pure $ do
            ControlPlaneResponse status body <-
              first TlsRetentionClientTransportFailed attempted
            if status /= 200
              then Left (TlsRetentionClientHttpStatus status)
              else do
                receipt <- decodeResponse body
                validateReceipt reference envelope receipt
                Right receipt

  restore reference = do
    attempted <-
      call
        TlsRetentionRestoreRoute
        (strictRequest (TlsRestorePayload reference))
    pure $ do
      ControlPlaneResponse status body <-
        first TlsRetentionClientTransportFailed attempted
      observation <- decodeResponse body
      case observation of
        TlsEnvelopeMissing
          | status == 404 -> Right TlsEnvelopeMissing
          | otherwise -> Left (TlsRetentionClientHttpStatus status)
        corrupt@(TlsEnvelopeCorrupt _)
          | status == 500 -> Right corrupt
          | otherwise -> Left (TlsRetentionClientHttpStatus status)
        present@(TlsEnvelopePresent envelope receipt)
          | status /= 200 -> Left (TlsRetentionClientHttpStatus status)
          | tlsRetentionReceiptReference receipt /= reference ->
              Left TlsRetentionClientObservationReferenceMismatch
          | retainedCiphertextDigest reference /= tlsSealedEnvelopeDigest envelope ->
              Left
                ( TlsRetentionClientObservationDigestMismatch
                    (retainedCiphertextDigest reference)
                    (tlsSealedEnvelopeDigest envelope)
                )
          | otherwise -> do
              validateReceipt reference envelope receipt
              Right present

  decodeResponse body =
    first
      TlsRetentionClientResponseInvalid
      ( decodeControlPlaneResponse
          tlsRetentionMaximumResponseBytes
          (LazyByteString.fromStrict body)
      )

validateReceipt
  :: RetainedTlsRef
  -> TlsSealedEnvelope
  -> TlsRetentionReceipt
  -> Either TlsRetentionClientError ()
validateReceipt reference envelope receipt
  | tlsRetentionReceiptReference receipt /= reference =
      Left TlsRetentionClientReceiptReferenceMismatch
  | tlsRetentionReceiptEnvelopeDigest receipt /= expectedDigest =
      Left
        ( TlsRetentionClientReceiptDigestMismatch
            expectedDigest
            (tlsRetentionReceiptEnvelopeDigest receipt)
        )
  | nullVersion = Left TlsRetentionClientReceiptVersionInvalid
  | otherwise = Right ()
 where
  expectedDigest = tlsSealedEnvelopeDigest envelope
  version = tlsRetentionReceiptObjectVersion receipt
  nullVersion = Text.null version || Text.length version > 512

strictRequest :: (Serialise value) => value -> ByteString
strictRequest = LazyByteString.toStrict . encodeControlPlaneRequest
