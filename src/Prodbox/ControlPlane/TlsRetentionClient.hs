{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated, role-indexed client for the ciphertext-only TLS Retention
-- Adapter. The client can address only the three compiled TLS routes: exact-
-- reference store/restore and exact-version legacy observation. It exposes no
-- bucket, caller-selected object key, plaintext Secret, list, or "latest
-- object" operation.
module Prodbox.ControlPlane.TlsRetentionClient
  ( TlsRetentionClient (..)
  , TlsRetentionClientError (..)
  , TlsRetentionHttpResponseObservation (..)
  , classifyTlsRetentionHttpStatus
  , renderTlsRetentionClientCause
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
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseObservation (..)
  , classifyAuthenticatedRolePlainResponse
  , renderAuthenticatedRolePlainResponseObservation
  )
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
  , ControlPlaneRouteFor
    ( TlsRetentionObserveVersionRoute
    , TlsRetentionRestoreRoute
    , TlsRetentionStoreRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsEnvelopeObservation (..)
  , TlsObserveVersionPayload (..)
  , TlsRestorePayload (..)
  , TlsRetentionPlainResponseCause
  , TlsRetentionPlainResponseObservation (..)
  , TlsRetentionReceipt (..)
  , TlsSealedEnvelope
  , TlsStorePayload (..)
  , TlsVersionEnvelopeObservation (..)
  , classifyTlsRetentionPlainResponse
  , renderTlsRetentionPlainResponseCause
  , tlsSealedEnvelopeDigest
  , validateTlsSealedEnvelope
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( RetainedTlsRef (..)
  , RetentionVersion
  )
import Prodbox.Runtime.Role (RuntimeRole (TlsRetentionRuntime))

data TlsRetentionClient m = TlsRetentionClient
  { storeTlsRetention
      :: RetainedTlsRef
      -> TlsSealedEnvelope
      -> m (Either TlsRetentionClientError TlsRetentionReceipt)
  , restoreTlsRetention
      :: RetainedTlsRef
      -> m (Either TlsRetentionClientError TlsEnvelopeObservation)
  , observeTlsRetentionVersion
      :: RetentionVersion
      -> m (Either TlsRetentionClientError TlsVersionEnvelopeObservation)
  }

data TlsRetentionHttpResponseObservation
  = TlsRetentionEndpointResponse !TlsRetentionPlainResponseCause
  | TlsRetentionAuthenticatedRoleResponse !AuthenticatedRolePlainResponseObservation
  | TlsRetentionHttpResponseOther
  deriving stock (Eq, Show)

data TlsRetentionClientError
  = TlsRetentionClientEnvelopeInvalid !Text
  | TlsRetentionClientCandidateDigestMismatch !Text !Text
  | TlsRetentionClientTransportFailed !AuthenticatedClientError
  | TlsRetentionClientHttpStatus !TlsRetentionHttpResponseObservation
  | TlsRetentionClientResponseInvalid !ControlPlaneResponseCodecError
  | TlsRetentionClientReceiptReferenceMismatch
  | TlsRetentionClientReceiptDigestMismatch !Text !Text
  | TlsRetentionClientReceiptVersionInvalid
  | TlsRetentionClientObservationReferenceMismatch
  | TlsRetentionClientObservationDigestMismatch !Text !Text
  | TlsRetentionClientObservedEnvelopeInvalid
  | TlsRetentionClientObservationVersionInvalid
  deriving stock (Eq, Show)

-- | Preserve only an exact endpoint or authenticated-role response pair.
-- Arbitrary Adapter response bytes and numeric status values never cross this
-- client boundary.
classifyTlsRetentionHttpStatus :: Int -> ByteString -> TlsRetentionClientError
classifyTlsRetentionHttpStatus status body =
  TlsRetentionClientHttpStatus $ case classifyTlsRetentionPlainResponse status body of
    TlsRetentionPlainResponseKnown cause -> TlsRetentionEndpointResponse cause
    TlsRetentionPlainResponseOther ->
      case classifyAuthenticatedRolePlainResponse status body of
        known@(AuthenticatedRolePlainResponseKnown _) ->
          TlsRetentionAuthenticatedRoleResponse known
        AuthenticatedRolePlainResponseOther -> TlsRetentionHttpResponseOther

-- | Closed, payload-free diagnosis for the TLS Retention client. Transport,
-- codec, response, and retained-reference details never enter the token.
renderTlsRetentionClientCause :: TlsRetentionClientError -> Text
renderTlsRetentionClientCause clientError = case clientError of
  TlsRetentionClientEnvelopeInvalid _ -> "envelope-invalid"
  TlsRetentionClientCandidateDigestMismatch _ _ -> "candidate-digest-mismatch"
  TlsRetentionClientTransportFailed _ -> "transport-failed"
  TlsRetentionClientHttpStatus observation ->
    "http-status/" <> case observation of
      TlsRetentionEndpointResponse cause -> renderTlsRetentionPlainResponseCause cause
      TlsRetentionAuthenticatedRoleResponse authenticated ->
        renderAuthenticatedRolePlainResponseObservation authenticated
      TlsRetentionHttpResponseOther -> "other"
  TlsRetentionClientResponseInvalid _ -> "response-invalid"
  TlsRetentionClientReceiptReferenceMismatch -> "receipt-reference-mismatch"
  TlsRetentionClientReceiptDigestMismatch _ _ -> "receipt-digest-mismatch"
  TlsRetentionClientReceiptVersionInvalid -> "receipt-version-invalid"
  TlsRetentionClientObservationReferenceMismatch -> "observation-reference-mismatch"
  TlsRetentionClientObservationDigestMismatch _ _ -> "observation-digest-mismatch"
  TlsRetentionClientObservedEnvelopeInvalid -> "observed-envelope-invalid"
  TlsRetentionClientObservationVersionInvalid -> "observation-version-invalid"

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
    , observeTlsRetentionVersion = observeVersion
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
              then Left (classifyTlsRetentionHttpStatus status body)
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
      observation <- case decodeResponse body of
        Left _
          | status /= 200 -> Left (classifyTlsRetentionHttpStatus status body)
        decoded -> decoded
      case observation of
        TlsEnvelopeMissing
          | status == 404 -> Right TlsEnvelopeMissing
          | otherwise -> Left (classifyTlsRetentionHttpStatus status body)
        corrupt@(TlsEnvelopeCorrupt _)
          | status == 500 -> Right corrupt
          | otherwise -> Left (classifyTlsRetentionHttpStatus status body)
        present@(TlsEnvelopePresent envelope receipt)
          | status /= 200 -> Left (classifyTlsRetentionHttpStatus status body)
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

  observeVersion version = do
    attempted <-
      call
        TlsRetentionObserveVersionRoute
        (strictRequest (TlsObserveVersionPayload version))
    pure $ do
      ControlPlaneResponse status body <-
        first TlsRetentionClientTransportFailed attempted
      observation <- case decodeResponse body of
        Left _
          | status /= 200 -> Left (classifyTlsRetentionHttpStatus status body)
        decoded -> decoded
      case observation of
        TlsVersionEnvelopeMissing
          | status == 404 -> Right TlsVersionEnvelopeMissing
          | otherwise -> Left (classifyTlsRetentionHttpStatus status body)
        TlsVersionEnvelopeCorrupt
          | status == 500 -> Right TlsVersionEnvelopeCorrupt
          | otherwise -> Left (classifyTlsRetentionHttpStatus status body)
        present@(TlsVersionEnvelopePresent envelope objectVersion)
          | status /= 200 -> Left (classifyTlsRetentionHttpStatus status body)
          | Left _ <- validateTlsSealedEnvelope envelope ->
              Left TlsRetentionClientObservedEnvelopeInvalid
          | Text.null objectVersion || Text.length objectVersion > 512 ->
              Left TlsRetentionClientObservationVersionInvalid
          | otherwise -> Right present

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
