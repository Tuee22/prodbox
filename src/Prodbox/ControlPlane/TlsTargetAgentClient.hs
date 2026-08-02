{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Authenticated client for the Target Secret Agent's exact TLS lane. The
-- five operations are closed constructors; no method accepts a namespace,
-- Secret name, Vault path, or plaintext.
module Prodbox.ControlPlane.TlsTargetAgentClient
  ( TlsTargetAgentClient (..)
  , TlsTargetAgentClientError (..)
  , tlsTargetAgentClientWithTransport
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( TargetTlsHomeRewrapRoute
    , TargetTlsHomeWrapRoute
    , TargetTlsPrepareExchangeRoute
    , TargetTlsRestoreRoute
    , TargetTlsRetainRoute
    , TargetTlsVerifySourceRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekEnvelope
  , TlsDekPrepared
  , TlsDekPublicKey
  , TlsWrappedDek
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsHomeRewrapRequest (..)
  , TlsHomeWrapRequest (..)
  , TlsTargetRestoreReceipt (..)
  , TlsTargetRestoreRequest (..)
  , TlsTargetRetainReceipt (..)
  , TlsTargetRetainRequest (..)
  , TlsTargetVerifyReceipt (..)
  , TlsTargetVerifyRequest (..)
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( RetainedTlsRef (..)
  , RetentionVersion
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

data TlsTargetAgentClient m = TlsTargetAgentClient
  { prepareTlsDekDestination
      :: m (Either TlsTargetAgentClientError TlsDekPrepared)
  , retainSelectedPublicEdgeTls
      :: RetentionVersion
      -> TlsDekPublicKey
      -> m (Either TlsTargetAgentClientError TlsTargetRetainReceipt)
  , wrapRetainedHomeTlsDek
      :: TlsDekPrepared
      -> TlsDekEnvelope
      -> m (Either TlsTargetAgentClientError TlsWrappedDek)
  , rewrapRetainedHomeTlsDek
      :: TlsWrappedDek
      -> TlsDekPublicKey
      -> m (Either TlsTargetAgentClientError TlsDekEnvelope)
  , restoreSelectedPublicEdgeTls
      :: RetainedTlsRef
      -> TlsDekPrepared
      -> TlsDekEnvelope
      -> ByteString
      -> m (Either TlsTargetAgentClientError TlsTargetRestoreReceipt)
  , verifySelectedPublicEdgeTlsSource
      :: RetainedTlsRef
      -> m (Either TlsTargetAgentClientError TlsTargetVerifyReceipt)
  }

data TlsTargetAgentClientError
  = TlsTargetAgentClientTransportFailed !AuthenticatedClientError
  | TlsTargetAgentClientHttpStatus !Int
  | TlsTargetAgentClientResponseInvalid !ControlPlaneResponseCodecError
  | TlsTargetAgentClientRetentionVersionMismatch
  | TlsTargetAgentClientRestoreReferenceMismatch
  deriving stock (Eq, Show)

tlsTargetAgentMaximumResponseBytes :: Int
tlsTargetAgentMaximumResponseBytes = 2 * 1024 * 1024

tlsTargetAgentClientWithTransport
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TlsTargetAgentClient IO
tlsTargetAgentClientWithTransport transport =
  TlsTargetAgentClient
    { prepareTlsDekDestination = prepare
    , retainSelectedPublicEdgeTls = retain
    , wrapRetainedHomeTlsDek = wrap
    , rewrapRetainedHomeTlsDek = rewrap
    , restoreSelectedPublicEdgeTls = restore
    , verifySelectedPublicEdgeTlsSource = verify
    }
 where
  prepare = callSuccess transport TargetTlsPrepareExchangeRoute ()

  retain version homePublicKey = do
    result <-
      callSuccess
        transport
        TargetTlsRetainRoute
        TlsTargetRetainRequest
          { tlsTargetRetainVersion = version
          , tlsTargetRetainHomePublicKey = homePublicKey
          }
    pure $ do
      receipt <- result
      if tlsTargetRetainedVersion receipt == version
        then Right receipt
        else Left TlsTargetAgentClientRetentionVersionMismatch

  wrap prepared envelope =
    callSuccess
      transport
      TargetTlsHomeWrapRoute
      TlsHomeWrapRequest
        { tlsHomeWrapPrepared = prepared
        , tlsHomeWrapEnvelope = envelope
        }

  rewrap wrapped targetPublicKey =
    callSuccess
      transport
      TargetTlsHomeRewrapRoute
      TlsHomeRewrapRequest
        { tlsHomeRewrapWrappedDek = wrapped
        , tlsHomeRewrapTargetPublicKey = targetPublicKey
        }

  restore reference prepared envelope ciphertext = do
    result <-
      callSuccess
        transport
        TargetTlsRestoreRoute
        TlsTargetRestoreRequest
          { tlsTargetRestoreReference = reference
          , tlsTargetRestorePrepared = prepared
          , tlsTargetRestoreDekEnvelope = envelope
          , tlsTargetRestoreCertificateCiphertext = ciphertext
          }
    pure $ do
      receipt <- result
      if tlsTargetRestoredReference receipt == reference
        then Right receipt
        else Left TlsTargetAgentClientRestoreReferenceMismatch

  verify reference = do
    result <-
      callSuccess
        transport
        TargetTlsVerifySourceRoute
        (TlsTargetVerifyRequest reference)
    pure $ do
      receipt <- result
      if tlsTargetVerifiedCertificate receipt == retainedCert reference
        && tlsTargetVerifiedSource receipt == retainedSourceSecret reference
        then Right receipt
        else Left TlsTargetAgentClientRestoreReferenceMismatch

callSuccess
  :: (Serialise request, Serialise response)
  => AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> ControlPlaneRouteFor 'TargetSecretAgentRuntime
  -> request
  -> IO (Either TlsTargetAgentClientError response)
callSuccess transport route request = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      route
      (LazyByteString.toStrict (encodeControlPlaneRequest request))
  pure $ do
    ControlPlaneResponse status responseBytes <-
      first TlsTargetAgentClientTransportFailed attempted
    if status /= 200
      then Left (TlsTargetAgentClientHttpStatus status)
      else
        first
          TlsTargetAgentClientResponseInvalid
          ( decodeControlPlaneResponse
              tlsTargetAgentMaximumResponseBytes
              (LazyByteString.fromStrict responseBytes)
          )
