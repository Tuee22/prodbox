{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Authenticated client for the Lifecycle Authority's closed control fold.
-- The request is a typed genesis/repair/migration command; callers must
-- re-observe the retained admission projection after success or response loss.
module Prodbox.ControlPlane.AuthorityControlClient
  ( AuthorityControlClient (..)
  , AuthorityControlClientError (..)
  , authorityControlClientWithTransport
  , observeProviderAdmissionRecoveryWithTransport
  , decodeProviderAdmissionRecoveryResponse
  , observeProviderBootstrapPredecessorWithTransport
  , decodeProviderBootstrapPredecessorResponse
  , decodeAuthorityControlTextResponse
  )
where

import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityControlPayload
      ( AuthorityControlObserveProviderAdmissionRecovery
      , AuthorityControlObserveProviderBootstrapPredecessor
      )
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAuthorityControlRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeAuditFreezeBinding
  , ProviderAdmissionEpochError
  , ProviderAdmissionRecoveryObservation
  , ProviderAdmissionRecoveryRefusal
  , ProviderBootstrapPredecessor
  , cascadeAuditRecoveryRequestDigest
  , providerAdmissionRecoveryRequestDigest
  , validateProviderAdmissionRecoveryObservation
  , validateProviderBootstrapPredecessor
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype AuthorityControlClient m = AuthorityControlClient
  { submitAuthorityControl
      :: AuthorityControlPayload
      -> m (Either AuthorityControlClientError Text)
  }

data AuthorityControlClientError
  = AuthorityControlTransportFailed !AuthenticatedClientError
  | AuthorityControlRefused !Text
  | AuthorityControlHttpStatus !Int !Text
  | AuthorityControlResponseInvalid !ControlPlaneResponseCodecError
  | AuthorityControlTextResponseTooLarge !Int !Int
  | AuthorityControlTextResponseInvalidUtf8
  | AuthorityControlRecoveryResponseMismatch
  | AuthorityControlRecoveryObservationInvalid !ProviderAdmissionRecoveryRefusal
  | AuthorityControlBootstrapPredecessorInvalid !ProviderAdmissionEpochError
  deriving stock (Eq, Show)

authorityControlClientWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AuthorityControlClient IO
authorityControlClientWithTransport transport =
  AuthorityControlClient
    { submitAuthorityControl = \payload -> do
        attempted <-
          callAuthenticatedClientTransport
            transport
            LifecycleAuthorityControlRoute
            (LazyByteString.toStrict (encodeControlPlaneRequest payload))
        pure (first AuthorityControlTransportFailed attempted >>= decodeAuthorityControlTextResponse)
    }

-- | Established control outcomes are bounded raw UTF-8, including failures
-- of the new metadata request. Only its successful DTO uses the CBOR codec.
decodeAuthorityControlTextResponse
  :: ControlPlaneResponse -> Either AuthorityControlClientError Text
decodeAuthorityControlTextResponse (ControlPlaneResponse status body) = do
  summary <- decodeAuthorityControlTextBody body
  case status of
    200 -> Right summary
    409 -> Left (AuthorityControlRefused summary)
    _ -> Left (AuthorityControlHttpStatus status summary)

decodeAuthorityControlTextBody :: ByteString.ByteString -> Either AuthorityControlClientError Text
decodeAuthorityControlTextBody body
  | ByteString.length body > authorityControlMaximumResponseBytes =
      Left
        (AuthorityControlTextResponseTooLarge (ByteString.length body) authorityControlMaximumResponseBytes)
  | otherwise = first (const AuthorityControlTextResponseInvalidUtf8) (TextEncoding.decodeUtf8' body)

authorityControlMaximumResponseBytes :: Int
authorityControlMaximumResponseBytes = 64 * 1024

-- | Discover the retained reservation after the host retired its active
-- intent. The authenticated reply is a locator, not a successor permit.
observeProviderBootstrapPredecessorWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either AuthorityControlClientError (Maybe ProviderBootstrapPredecessor))
observeProviderBootstrapPredecessorWithTransport transport = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAuthorityControlRoute
      ( LazyByteString.toStrict
          (encodeControlPlaneRequest AuthorityControlObserveProviderBootstrapPredecessor)
      )
  pure
    (first AuthorityControlTransportFailed attempted >>= decodeProviderBootstrapPredecessorResponse)

decodeProviderBootstrapPredecessorResponse
  :: ControlPlaneResponse
  -> Either AuthorityControlClientError (Maybe ProviderBootstrapPredecessor)
decodeProviderBootstrapPredecessorResponse response@(ControlPlaneResponse status body)
  | status == 200 = do
      predecessor <-
        first
          AuthorityControlResponseInvalid
          (decodeControlPlaneResponse authorityControlMaximumResponseBytes (LazyByteString.fromStrict body))
      mapM_
        (first AuthorityControlBootstrapPredecessorInvalid . validateProviderBootstrapPredecessor)
        predecessor
      Right predecessor
  | otherwise = do
      _ <- decodeAuthorityControlTextResponse response
      Left AuthorityControlRecoveryResponseMismatch

-- | Observe through the existing authenticated control route. The response
-- echoes the entire reservation identity except its replaceable lease attempt.
observeProviderAdmissionRecoveryWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> CascadeAuditFreezeBinding
  -> IO (Either AuthorityControlClientError ProviderAdmissionRecoveryObservation)
observeProviderAdmissionRecoveryWithTransport transport binding = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAuthorityControlRoute
      ( LazyByteString.toStrict
          (encodeControlPlaneRequest (AuthorityControlObserveProviderAdmissionRecovery binding))
      )
  pure $ do
    response <- first AuthorityControlTransportFailed attempted
    decodeProviderAdmissionRecoveryResponse binding response

decodeProviderAdmissionRecoveryResponse
  :: CascadeAuditFreezeBinding
  -> ControlPlaneResponse
  -> Either AuthorityControlClientError ProviderAdmissionRecoveryObservation
decodeProviderAdmissionRecoveryResponse binding (ControlPlaneResponse status body)
  | status == 200 = do
      observation <-
        first
          AuthorityControlResponseInvalid
          (decodeControlPlaneResponse authorityControlMaximumResponseBytes (LazyByteString.fromStrict body))
      if providerAdmissionRecoveryRequestDigest observation == cascadeAuditRecoveryRequestDigest binding
        then do
          first
            AuthorityControlRecoveryObservationInvalid
            (validateProviderAdmissionRecoveryObservation binding observation)
          Right observation
        else Left AuthorityControlRecoveryResponseMismatch
  | otherwise = do
      summary <- decodeAuthorityControlTextBody body
      if status == 409
        then Left (AuthorityControlRefused summary)
        else Left (AuthorityControlHttpStatus status summary)
