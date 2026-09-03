{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Closed Lifecycle Authority boundary for the public-edge TLS custody
-- workflow. The host may select only retain versus restore and the already
-- compiled substrate/scope slot. Target-Agent DEK operations and adapter
-- traffic remain inside the retained Authority process.
module Prodbox.ControlPlane.TlsRetentionWorkflowAuthorityEndpoint
  ( TlsRetentionWorkflowAuthorityRequest (..)
  , TlsRetentionWorkflowAuthorityResponse (..)
  , TlsRetentionWorkflowAuthorityFailure (..)
  , TlsRetentionWorkflowAuthorityBoundary (..)
  , TlsRetentionWorkflowAuthorityClientError (..)
  , serveTlsRetentionWorkflowAuthorityRequest
  , requestTlsRetentionWorkflowAuthority
  , tlsRetentionWorkflowAuthorityResponseHttpStatus
  , tlsRetentionWorkflowAuthorityResponseBody
  , tlsRetentionWorkflowAuthorityMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleTlsRetentionWorkflowRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lifecycle.Authority.TlsRetention (KeyRotationApproval)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data TlsRetentionWorkflowAuthorityRequest
  = TlsRetentionWorkflowAuthorityRetain
      !Text
      !Text
      !KeyRotationApproval
  | TlsRetentionWorkflowAuthorityRestore
      !Text
      !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsRetentionWorkflowAuthorityResponse
  = TlsRetentionWorkflowAuthorityNothingToRetain
  | TlsRetentionWorkflowAuthorityRetained
  | TlsRetentionWorkflowAuthorityRestored
  | TlsRetentionWorkflowAuthorityIssuancePermitted
  | TlsRetentionWorkflowAuthorityRefused
      !TlsRetentionWorkflowAuthorityFailure
  | TlsRetentionWorkflowAuthorityRequestRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Payload-free failure projection. Nested transport, Vault, Secret,
-- ciphertext, and retained-reference details never cross back to the host.
data TlsRetentionWorkflowAuthorityFailure
  = TlsRetentionWorkflowAuthorityTargetUnsupported
  | TlsRetentionWorkflowAuthoritySlotInvalid
  | TlsRetentionWorkflowAuthorityStateUnavailable
  | TlsRetentionWorkflowAuthorityAdapterUnavailable
  | TlsRetentionWorkflowAuthorityHomeAgentUnavailable
  | TlsRetentionWorkflowAuthorityHomeAgentReplayCapacityExhausted
  | TlsRetentionWorkflowAuthoritySelectedAgentUnavailable
  | TlsRetentionWorkflowAuthoritySelectedAgentReplayCapacityExhausted
  | TlsRetentionWorkflowAuthorityEnvelopeInvalid
  | TlsRetentionWorkflowAuthorityAdapterReadBackMismatch
  | TlsRetentionWorkflowAuthoritySourceReadBackMismatch
  | TlsRetentionWorkflowAuthorityPromotionStateMismatch
  | TlsRetentionWorkflowAuthorityRestoreRefused
  | TlsRetentionWorkflowAuthorityWrappedDekInvalid
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype TlsRetentionWorkflowAuthorityBoundary m
  = TlsRetentionWorkflowAuthorityBoundary
  { runTlsRetentionWorkflowAuthorityBoundary
      :: TlsRetentionWorkflowAuthorityRequest
      -> m TlsRetentionWorkflowAuthorityResponse
  }

data TlsRetentionWorkflowAuthorityClientError
  = TlsRetentionWorkflowAuthorityClientTransportFailed !AuthenticatedClientError
  | TlsRetentionWorkflowAuthorityClientResponseInvalid !ControlPlaneResponseCodecError
  | TlsRetentionWorkflowAuthorityClientHttpStatus !Int
  deriving stock (Eq, Show)

tlsRetentionWorkflowAuthorityMaximumBytes :: Int
tlsRetentionWorkflowAuthorityMaximumBytes = 128 * 1024

serveTlsRetentionWorkflowAuthorityRequest
  :: (Monad m)
  => Int
  -> TlsRetentionWorkflowAuthorityBoundary m
  -> LazyByteString.ByteString
  -> m TlsRetentionWorkflowAuthorityResponse
serveTlsRetentionWorkflowAuthorityRequest maximumBytes boundary body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure TlsRetentionWorkflowAuthorityRequestRefused
    Right request -> runTlsRetentionWorkflowAuthorityBoundary boundary request

requestTlsRetentionWorkflowAuthority
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> TlsRetentionWorkflowAuthorityRequest
  -> IO
       ( Either
           TlsRetentionWorkflowAuthorityClientError
           TlsRetentionWorkflowAuthorityResponse
       )
requestTlsRetentionWorkflowAuthority transport request = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleTlsRetentionWorkflowRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest request))
  pure $ do
    ControlPlaneResponse status responseBytes <-
      first TlsRetentionWorkflowAuthorityClientTransportFailed attempted
    response <-
      first
        TlsRetentionWorkflowAuthorityClientResponseInvalid
        ( decodeControlPlaneResponse
            tlsRetentionWorkflowAuthorityMaximumBytes
            (LazyByteString.fromStrict responseBytes)
        )
    if status
      == replyStatusCode
        (tlsRetentionWorkflowAuthorityResponseHttpStatus response)
      then Right response
      else Left (TlsRetentionWorkflowAuthorityClientHttpStatus status)

tlsRetentionWorkflowAuthorityResponseHttpStatus
  :: TlsRetentionWorkflowAuthorityResponse -> ReplyStatus
tlsRetentionWorkflowAuthorityResponseHttpStatus response = case response of
  TlsRetentionWorkflowAuthorityNothingToRetain -> ReplyOk
  TlsRetentionWorkflowAuthorityRetained -> ReplyOk
  TlsRetentionWorkflowAuthorityRestored -> ReplyOk
  TlsRetentionWorkflowAuthorityIssuancePermitted -> ReplyOk
  TlsRetentionWorkflowAuthorityRefused _ -> ReplyServiceUnavailable
  TlsRetentionWorkflowAuthorityRequestRefused -> ReplyBadRequest

tlsRetentionWorkflowAuthorityResponseBody
  :: TlsRetentionWorkflowAuthorityResponse -> ByteString
tlsRetentionWorkflowAuthorityResponseBody =
  LazyByteString.toStrict . encodeControlPlaneResponse
