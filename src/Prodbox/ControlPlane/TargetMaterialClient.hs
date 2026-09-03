{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Metadata-only authenticated Target Secret Agent client. Secret payloads
-- are accepted only by attested one-shot workers and are not representable on
-- this standing-role transport.
module Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClient (..)
  , TargetMaterialClientError (..)
  , TargetMaterialHttpStatusCause (..)
  , TargetMaterialClientCause (..)
  , allTargetMaterialClientCauses
  , classifyTargetMaterialClientError
  , renderTargetMaterialClientCause
  , decodeTargetMaterialClientResponse
  , targetMaterialClient
  , targetWorkerReceiptFromMaterialObservation
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseObservation
  , allAuthenticatedRolePlainResponseObservations
  , classifyAuthenticatedRolePlainResponse
  , renderAuthenticatedRolePlainResponseObservation
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError (..)
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClientError (..)
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor (TargetMaterialObserveRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( TargetMaterialObservation (..)
  , TargetMaterialObserveRequest (..)
  , TargetMaterialObserveResponse (..)
  , targetMaterialResponseMaximumBytes
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , mkTargetWorkerReceiptProjection
  )
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Lifecycle.TargetCommitIntent
  ( mkCredentialGeneration
  , mkTargetValueDigest
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

newtype TargetMaterialClient m = TargetMaterialClient
  { observeRegisteredTargetMaterial
      :: TargetSecretId
      -> m
           ( Either
               TargetMaterialClientError
               (Maybe TargetMaterialObservation)
           )
  }

data TargetMaterialClientError
  = TargetMaterialClientTransportFailed !AuthenticatedClientError
  | TargetMaterialClientResponseInvalid !ControlPlaneResponseCodecError
  | TargetMaterialClientResponseInvalidAtStatus !Int !ControlPlaneResponseCodecError
  | TargetMaterialClientServerResponseInvalid
      !AuthenticatedRolePlainResponseObservation
      !ControlPlaneResponseCodecError
  | TargetMaterialClientHttpStatus !Int
  | TargetMaterialClientRemoteRefused !Text
  deriving stock (Eq, Show)

-- | Closed status classes shared by the authenticated transport and the
-- semantic Target-material response. The original status code and response
-- body cannot cross this boundary.
data TargetMaterialHttpStatusCause
  = TargetMaterialStatusBadRequest
  | TargetMaterialStatusUnauthorized
  | TargetMaterialStatusForbidden
  | TargetMaterialStatusNotFound
  | TargetMaterialStatusConflict
  | TargetMaterialStatusTooManyRequests
  | TargetMaterialStatusOtherClient
  | TargetMaterialStatusServer
  | TargetMaterialStatusOther
  deriving stock (Eq, Show, Enum, Bounded)

-- | Exhaustive, payload-free diagnosis for the standing Target observation
-- client. Every payload-bearing transport error is reduced at its source;
-- only a closed constructor may enter the credential worker terminal receipt.
data TargetMaterialClientCause
  = TargetMaterialClientSignerUnavailable
  | TargetMaterialClientScopeUnavailable
  | TargetMaterialClientEpochUnavailable
  | TargetMaterialClientDeadlineUnavailable
  | TargetMaterialClientNonceUnavailable
  | TargetMaterialClientBindingFailed
  | TargetMaterialClientSigningFailed
  | TargetMaterialClientFrameFailed
  | TargetMaterialClientEndpointEmpty
  | TargetMaterialClientEndpointWhitespace
  | TargetMaterialClientEndpointControl
  | TargetMaterialClientEndpointTooLong
  | TargetMaterialClientEndpointSchemeUnsupported
  | TargetMaterialClientEndpointAuthorityInvalid
  | TargetMaterialClientResponseLimitInvalid
  | TargetMaterialClientTransportConnectionFailed
  | TargetMaterialClientTransportTimeout
  | TargetMaterialClientTransportStatus !TargetMaterialHttpStatusCause
  | TargetMaterialClientTransportDecodeFailed
  | TargetMaterialClientTransportResponseTooLarge
  | TargetMaterialClientResponseCodecTooLarge
  | TargetMaterialClientResponseCodecInvalid
  | TargetMaterialClientResponseCodecInvalidAtStatus !TargetMaterialHttpStatusCause
  | TargetMaterialClientResponseCodecInvalidServer
      !AuthenticatedRolePlainResponseObservation
  | TargetMaterialClientResponseCodecUnsupportedVersion
  | TargetMaterialClientResponseCodecNonCanonical
  | TargetMaterialClientResponseStatus !TargetMaterialHttpStatusCause
  | TargetMaterialClientRemoteRequestCodecRejected
  | TargetMaterialClientRemoteMetadataUnavailable
  | TargetMaterialClientRemoteOther
  deriving stock (Eq, Show)

allTargetMaterialClientCauses :: [TargetMaterialClientCause]
allTargetMaterialClientCauses =
  [ TargetMaterialClientSignerUnavailable
  , TargetMaterialClientScopeUnavailable
  , TargetMaterialClientEpochUnavailable
  , TargetMaterialClientDeadlineUnavailable
  , TargetMaterialClientNonceUnavailable
  , TargetMaterialClientBindingFailed
  , TargetMaterialClientSigningFailed
  , TargetMaterialClientFrameFailed
  , TargetMaterialClientEndpointEmpty
  , TargetMaterialClientEndpointWhitespace
  , TargetMaterialClientEndpointControl
  , TargetMaterialClientEndpointTooLong
  , TargetMaterialClientEndpointSchemeUnsupported
  , TargetMaterialClientEndpointAuthorityInvalid
  , TargetMaterialClientResponseLimitInvalid
  , TargetMaterialClientTransportConnectionFailed
  , TargetMaterialClientTransportTimeout
  ]
    <> fmap TargetMaterialClientTransportStatus allStatusCauses
    <> [ TargetMaterialClientTransportDecodeFailed
       , TargetMaterialClientTransportResponseTooLarge
       , TargetMaterialClientResponseCodecTooLarge
       , TargetMaterialClientResponseCodecInvalid
       ]
    <> fmap
      TargetMaterialClientResponseCodecInvalidAtStatus
      ([minBound .. maxBound] :: [TargetMaterialHttpStatusCause])
    <> fmap
      TargetMaterialClientResponseCodecInvalidServer
      allAuthenticatedRolePlainResponseObservations
    <> [ TargetMaterialClientResponseCodecUnsupportedVersion
       , TargetMaterialClientResponseCodecNonCanonical
       ]
    <> fmap TargetMaterialClientResponseStatus allStatusCauses
    <> [ TargetMaterialClientRemoteRequestCodecRejected
       , TargetMaterialClientRemoteMetadataUnavailable
       , TargetMaterialClientRemoteOther
       ]
 where
  allStatusCauses = [minBound .. maxBound]

classifyTargetMaterialClientError
  :: TargetMaterialClientError -> TargetMaterialClientCause
classifyTargetMaterialClientError err = case err of
  TargetMaterialClientTransportFailed authenticated ->
    classifyAuthenticatedClientError authenticated
  TargetMaterialClientResponseInvalid codec -> classifyCodecError codec
  TargetMaterialClientResponseInvalidAtStatus status codec ->
    classifyCodecErrorAtStatus status codec
  TargetMaterialClientServerResponseInvalid observation codec ->
    classifyServerCodecError observation codec
  TargetMaterialClientHttpStatus status ->
    TargetMaterialClientResponseStatus (classifyHttpStatus status)
  TargetMaterialClientRemoteRefused detail -> case detail of
    "request-codec-rejected" -> TargetMaterialClientRemoteRequestCodecRejected
    "target-metadata-unavailable" -> TargetMaterialClientRemoteMetadataUnavailable
    _ -> TargetMaterialClientRemoteOther

renderTargetMaterialClientCause :: TargetMaterialClientCause -> Text
renderTargetMaterialClientCause cause = case cause of
  TargetMaterialClientSignerUnavailable -> "authenticated/signer-unavailable"
  TargetMaterialClientScopeUnavailable -> "authenticated/scope-unavailable"
  TargetMaterialClientEpochUnavailable -> "authenticated/epoch-unavailable"
  TargetMaterialClientDeadlineUnavailable -> "authenticated/deadline-unavailable"
  TargetMaterialClientNonceUnavailable -> "authenticated/nonce-unavailable"
  TargetMaterialClientBindingFailed -> "authenticated/binding-failed"
  TargetMaterialClientSigningFailed -> "authenticated/signing-failed"
  TargetMaterialClientFrameFailed -> "authenticated/frame-failed"
  TargetMaterialClientEndpointEmpty -> "authenticated/transport/endpoint-empty"
  TargetMaterialClientEndpointWhitespace -> "authenticated/transport/endpoint-whitespace"
  TargetMaterialClientEndpointControl -> "authenticated/transport/endpoint-control"
  TargetMaterialClientEndpointTooLong -> "authenticated/transport/endpoint-too-long"
  TargetMaterialClientEndpointSchemeUnsupported ->
    "authenticated/transport/endpoint-scheme-unsupported"
  TargetMaterialClientEndpointAuthorityInvalid ->
    "authenticated/transport/endpoint-authority-invalid"
  TargetMaterialClientResponseLimitInvalid ->
    "authenticated/transport/response-limit-invalid"
  TargetMaterialClientTransportConnectionFailed ->
    "authenticated/transport/http/connection-failed"
  TargetMaterialClientTransportTimeout -> "authenticated/transport/http/timeout"
  TargetMaterialClientTransportStatus status ->
    "authenticated/transport/http/status/" <> renderHttpStatusCause status
  TargetMaterialClientTransportDecodeFailed ->
    "authenticated/transport/http/decode-failed"
  TargetMaterialClientTransportResponseTooLarge ->
    "authenticated/transport/response-too-large"
  TargetMaterialClientResponseCodecTooLarge -> "response-codec/too-large"
  TargetMaterialClientResponseCodecInvalid -> "response-codec/invalid"
  TargetMaterialClientResponseCodecInvalidAtStatus status ->
    "response-codec/invalid/status/" <> renderHttpStatusCause status
  TargetMaterialClientResponseCodecInvalidServer observation ->
    "response-codec/invalid/status/server/"
      <> renderAuthenticatedRolePlainResponseObservation observation
  TargetMaterialClientResponseCodecUnsupportedVersion ->
    "response-codec/unsupported-version"
  TargetMaterialClientResponseCodecNonCanonical -> "response-codec/non-canonical"
  TargetMaterialClientResponseStatus status ->
    "response-status/" <> renderHttpStatusCause status
  TargetMaterialClientRemoteRequestCodecRejected ->
    "remote-refusal/request-codec-rejected"
  TargetMaterialClientRemoteMetadataUnavailable ->
    "remote-refusal/target-metadata-unavailable"
  TargetMaterialClientRemoteOther -> "remote-refusal/other"

classifyAuthenticatedClientError
  :: AuthenticatedClientError -> TargetMaterialClientCause
classifyAuthenticatedClientError err = case err of
  AuthenticatedClientSignerUnavailable _ -> TargetMaterialClientSignerUnavailable
  AuthenticatedClientScopeUnavailable _ -> TargetMaterialClientScopeUnavailable
  AuthenticatedClientEpochUnavailable _ -> TargetMaterialClientEpochUnavailable
  AuthenticatedClientDeadlineUnavailable _ -> TargetMaterialClientDeadlineUnavailable
  AuthenticatedClientNonceUnavailable _ -> TargetMaterialClientNonceUnavailable
  AuthenticatedClientBindingFailed _ -> TargetMaterialClientBindingFailed
  AuthenticatedClientSigningFailed _ -> TargetMaterialClientSigningFailed
  AuthenticatedClientFrameFailed _ -> TargetMaterialClientFrameFailed
  AuthenticatedClientTransportFailed transport -> classifyTransportError transport

classifyTransportError :: ControlPlaneClientError -> TargetMaterialClientCause
classifyTransportError err = case err of
  ControlPlaneEndpointEmpty -> TargetMaterialClientEndpointEmpty
  ControlPlaneEndpointContainsWhitespace -> TargetMaterialClientEndpointWhitespace
  ControlPlaneEndpointContainsControl -> TargetMaterialClientEndpointControl
  ControlPlaneEndpointTooLong _ _ -> TargetMaterialClientEndpointTooLong
  ControlPlaneEndpointSchemeUnsupported -> TargetMaterialClientEndpointSchemeUnsupported
  ControlPlaneEndpointAuthorityInvalid -> TargetMaterialClientEndpointAuthorityInvalid
  ControlPlaneResponseLimitMustBePositive -> TargetMaterialClientResponseLimitInvalid
  ControlPlaneTransportFailed httpError -> classifyTransportHttpError httpError
  ControlPlaneResponseTooLarge _ _ -> TargetMaterialClientTransportResponseTooLarge

classifyTransportHttpError :: HttpError -> TargetMaterialClientCause
classifyTransportHttpError err = case err of
  HttpConnectionFailure _ -> TargetMaterialClientTransportConnectionFailed
  HttpTimeout _ -> TargetMaterialClientTransportTimeout
  HttpStatus status _ ->
    TargetMaterialClientTransportStatus (classifyHttpStatus status)
  HttpDecode _ -> TargetMaterialClientTransportDecodeFailed

classifyCodecError :: ControlPlaneResponseCodecError -> TargetMaterialClientCause
classifyCodecError err = case err of
  ControlPlaneRequestTooLarge -> TargetMaterialClientResponseCodecTooLarge
  ControlPlaneRequestInvalid -> TargetMaterialClientResponseCodecInvalid
  ControlPlaneRequestUnsupportedVersion ->
    TargetMaterialClientResponseCodecUnsupportedVersion
  ControlPlaneRequestNonCanonical -> TargetMaterialClientResponseCodecNonCanonical

classifyCodecErrorAtStatus
  :: Int -> ControlPlaneResponseCodecError -> TargetMaterialClientCause
classifyCodecErrorAtStatus status err = case err of
  ControlPlaneRequestInvalid ->
    TargetMaterialClientResponseCodecInvalidAtStatus (classifyHttpStatus status)
  _ -> classifyCodecError err

classifyServerCodecError
  :: AuthenticatedRolePlainResponseObservation
  -> ControlPlaneResponseCodecError
  -> TargetMaterialClientCause
classifyServerCodecError observation err = case err of
  ControlPlaneRequestInvalid ->
    TargetMaterialClientResponseCodecInvalidServer observation
  _ -> classifyCodecError err

classifyHttpStatus :: Int -> TargetMaterialHttpStatusCause
classifyHttpStatus status = case status of
  400 -> TargetMaterialStatusBadRequest
  401 -> TargetMaterialStatusUnauthorized
  403 -> TargetMaterialStatusForbidden
  404 -> TargetMaterialStatusNotFound
  409 -> TargetMaterialStatusConflict
  429 -> TargetMaterialStatusTooManyRequests
  _
    | status >= 400 && status < 500 -> TargetMaterialStatusOtherClient
    | status >= 500 && status < 600 -> TargetMaterialStatusServer
    | otherwise -> TargetMaterialStatusOther

renderHttpStatusCause :: TargetMaterialHttpStatusCause -> Text
renderHttpStatusCause cause = case cause of
  TargetMaterialStatusBadRequest -> "bad-request"
  TargetMaterialStatusUnauthorized -> "unauthorized"
  TargetMaterialStatusForbidden -> "forbidden"
  TargetMaterialStatusNotFound -> "not-found"
  TargetMaterialStatusConflict -> "conflict"
  TargetMaterialStatusTooManyRequests -> "too-many-requests"
  TargetMaterialStatusOtherClient -> "other-client"
  TargetMaterialStatusServer -> "server"
  TargetMaterialStatusOther -> "other"

targetMaterialClient
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TargetMaterialClient IO
targetMaterialClient transport = TargetMaterialClient observe
 where
  observe target = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        TargetMaterialObserveRoute
        ( requestBody
            TargetMaterialObserveRequest
              { targetMaterialObserveTarget = target
              }
        )
    pure $ do
      response <- first TargetMaterialClientTransportFailed attempted
      decodeTargetMaterialClientResponse response

  requestBody :: (Serialise value) => value -> ByteString
  requestBody = LazyByteString.toStrict . encodeControlPlaneRequest

decodeTargetMaterialClientResponse
  :: ControlPlaneResponse
  -> Either TargetMaterialClientError (Maybe TargetMaterialObservation)
decodeTargetMaterialClientResponse (ControlPlaneResponse status body) = do
  response <-
    first
      (invalidResponse status body)
      ( decodeControlPlaneResponse
          targetMaterialResponseMaximumBytes
          (LazyByteString.fromStrict body)
      )
  case response of
    TargetMaterialMissing
      | status == 404 -> Right Nothing
      | otherwise -> Left (TargetMaterialClientHttpStatus status)
    TargetMaterialObserved metadata
      | status == 200 -> Right (Just metadata)
      | otherwise -> Left (TargetMaterialClientHttpStatus status)
    TargetMaterialObserveRefused detail ->
      Left (TargetMaterialClientRemoteRefused detail)

invalidResponse
  :: Int
  -> ByteString
  -> ControlPlaneResponseCodecError
  -> TargetMaterialClientError
invalidResponse status body codec
  | status >= 500 && status < 600 =
      TargetMaterialClientServerResponseInvalid
        (classifyAuthenticatedRolePlainResponse status body)
        codec
  | otherwise = TargetMaterialClientResponseInvalidAtStatus status codec

targetWorkerReceiptFromMaterialObservation
  :: TargetSecretId
  -> TargetMaterialObservation
  -> Either Text TargetWorkerReceipt
targetWorkerReceiptFromMaterialObservation target observation = do
  generation <-
    first (Text.pack . show) (mkCredentialGeneration (targetMaterialObservedGeneration observation))
  requestDigest <-
    first (Text.pack . show) (mkTargetValueDigest (targetMaterialObservedRequestDigest observation))
  actionDigest <-
    first (Text.pack . show) (mkTargetValueDigest (targetMaterialObservedActionDigest observation))
  first
    (Text.pack . show)
    ( mkTargetWorkerReceiptProjection
        target
        generation
        (targetMaterialObservedVaultVersion observation)
        (targetMaterialObservedCommitment observation)
        requestDigest
        actionDigest
        (targetMaterialObservedPodUid observation)
        (targetMaterialObservedImageDigest observation)
    )
