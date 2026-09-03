{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority client for public Target trust
-- installation and exact read-back.
module Prodbox.ControlPlane.TargetAuthorityTrustClient
  ( TargetAuthorityTrustClient
  , TargetAuthorityTrustClientError (..)
  , classifyTargetAuthorityTrustClientError
  , decodeTargetAuthorityTrustClientResponse
  , targetAuthorityTrustClient
  , installAcceptedTargetAuthority
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseObservation
  , classifyAuthenticatedRolePlainResponse
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (TargetSecretTrustInstallRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TargetAuthorityTrust
  ( TargetAuthorityTrustBoundaryCause (..)
  , TargetAuthorityTrustObservationCause (TargetAuthorityTrustObservationOther)
  , parseTargetAuthorityTrustObservationCause
  )
import Prodbox.ControlPlane.TargetAuthorityTrustEndpoint
  ( TargetAuthorityTrustRequest (..)
  , TargetAuthorityTrustResponse (..)
  , targetAuthorityTrustResponseMaximumBytes
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClientError (..)
  , classifyTargetMaterialClientError
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , acceptedTargetAuthorityMaximumEncodedBytes
  , decodeAcceptedTargetAuthority
  , encodeAcceptedTargetAuthority
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

newtype TargetAuthorityTrustClient m = TargetAuthorityTrustClient
  { callTargetAuthorityTrust
      :: TargetAuthorityTrustRequest
      -> m (Either TargetAuthorityTrustClientError AcceptedTargetAuthority)
  }

data TargetAuthorityTrustClientError
  = TargetAuthorityTrustClientTransportFailed !AuthenticatedClientError
  | TargetAuthorityTrustClientResponseInvalid !ControlPlaneResponseCodecError
  | TargetAuthorityTrustClientResponseInvalidAtStatus !Int !ControlPlaneResponseCodecError
  | TargetAuthorityTrustClientServerResponseInvalid
      !AuthenticatedRolePlainResponseObservation
      !ControlPlaneResponseCodecError
  | TargetAuthorityTrustClientHttpStatus !Int
  | TargetAuthorityTrustClientRefused !Text
  | TargetAuthorityTrustClientUnavailable !Text
  | TargetAuthorityTrustClientReadBackInvalid
  | TargetAuthorityTrustClientReadBackMismatch
  deriving stock (Eq, Show)

classifyTargetAuthorityTrustClientError
  :: TargetAuthorityTrustClientError -> TargetAuthorityTrustBoundaryCause
classifyTargetAuthorityTrustClientError err = case err of
  TargetAuthorityTrustClientTransportFailed authenticated ->
    TargetAuthorityTrustBoundaryClient
      ( classifyTargetMaterialClientError
          (TargetMaterialClientTransportFailed authenticated)
      )
  TargetAuthorityTrustClientResponseInvalid codec ->
    TargetAuthorityTrustBoundaryClient
      ( classifyTargetMaterialClientError
          (TargetMaterialClientResponseInvalid codec)
      )
  TargetAuthorityTrustClientResponseInvalidAtStatus status codec ->
    TargetAuthorityTrustBoundaryClient
      ( classifyTargetMaterialClientError
          (TargetMaterialClientResponseInvalidAtStatus status codec)
      )
  TargetAuthorityTrustClientServerResponseInvalid observation codec ->
    TargetAuthorityTrustBoundaryClient
      ( classifyTargetMaterialClientError
          (TargetMaterialClientServerResponseInvalid observation codec)
      )
  TargetAuthorityTrustClientHttpStatus status ->
    TargetAuthorityTrustBoundaryClient
      (classifyTargetMaterialClientError (TargetMaterialClientHttpStatus status))
  TargetAuthorityTrustClientRefused detail -> case detail of
    "request-codec-rejected" -> TargetAuthorityTrustBoundaryRefusedRequestCodec
    "accepted-authority-invalid" -> TargetAuthorityTrustBoundaryRefusedAcceptedAuthority
    "trust-target-mismatch" -> TargetAuthorityTrustBoundaryRefusedTargetMismatch
    "trust-agent-identity-changed" -> TargetAuthorityTrustBoundaryRefusedAgentIdentityChanged
    "trust-issuer-identity-changed" -> TargetAuthorityTrustBoundaryRefusedIssuerIdentityChanged
    "trust-issuer-generation-regressed" ->
      TargetAuthorityTrustBoundaryRefusedIssuerGenerationRegressed
    "trust-issuer-key-conflict" -> TargetAuthorityTrustBoundaryRefusedIssuerKeyConflict
    "trust-epoch-regressed" -> TargetAuthorityTrustBoundaryRefusedEpochRegressed
    "trust-fence-regressed" -> TargetAuthorityTrustBoundaryRefusedFenceRegressed
    "trust-readback-mismatch" -> TargetAuthorityTrustBoundaryRefusedReadBackMismatch
    _ -> TargetAuthorityTrustBoundaryRefusedOther
  TargetAuthorityTrustClientUnavailable detail
    | detail == "trust-observation-unavailable" ->
        TargetAuthorityTrustBoundaryUnavailableObservation
          TargetAuthorityTrustObservationOther
    | Just observationToken <-
        Text.stripPrefix "trust-observation-unavailable/" detail ->
        TargetAuthorityTrustBoundaryUnavailableObservation
          ( maybe
              TargetAuthorityTrustObservationOther
              id
              (parseTargetAuthorityTrustObservationCause observationToken)
          )
    | detail == "trust-cas-unavailable" -> TargetAuthorityTrustBoundaryUnavailableCas
    | otherwise -> TargetAuthorityTrustBoundaryUnavailableOther
  TargetAuthorityTrustClientReadBackInvalid -> TargetAuthorityTrustBoundaryReadBackInvalid
  TargetAuthorityTrustClientReadBackMismatch -> TargetAuthorityTrustBoundaryReadBackMismatch

targetAuthorityTrustClient
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TargetAuthorityTrustClient IO
targetAuthorityTrustClient transport = TargetAuthorityTrustClient call
 where
  call request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        TargetSecretTrustInstallRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      response <- first TargetAuthorityTrustClientTransportFailed attempted
      decodeTargetAuthorityTrustClientResponse response

decodeTargetAuthorityTrustClientResponse
  :: ControlPlaneResponse
  -> Either TargetAuthorityTrustClientError AcceptedTargetAuthority
decodeTargetAuthorityTrustClientResponse (ControlPlaneResponse status body) = do
  response <-
    first
      (invalidResponse status body)
      ( decodeControlPlaneResponse
          targetAuthorityTrustResponseMaximumBytes
          (LazyByteString.fromStrict body)
      )
  case response of
    TargetAuthorityTrustInstalledResponse bytes -> success bytes
    TargetAuthorityTrustAlreadyInstalledResponse bytes -> success bytes
    TargetAuthorityTrustRecoveredResponse bytes -> success bytes
    TargetAuthorityTrustRefusedResponse detail ->
      Left (TargetAuthorityTrustClientRefused detail)
    TargetAuthorityTrustUnavailableResponse detail ->
      Left (TargetAuthorityTrustClientUnavailable detail)
 where
  success bytes
    | status /= 200 = Left (TargetAuthorityTrustClientHttpStatus status)
    | otherwise =
        first
          (const TargetAuthorityTrustClientReadBackInvalid)
          ( decodeAcceptedTargetAuthority
              acceptedTargetAuthorityMaximumEncodedBytes
              bytes
          )

invalidResponse
  :: Int
  -> ByteString
  -> ControlPlaneResponseCodecError
  -> TargetAuthorityTrustClientError
invalidResponse status body codec
  | status >= 500 && status < 600 =
      TargetAuthorityTrustClientServerResponseInvalid
        (classifyAuthenticatedRolePlainResponse status body)
        codec
  | otherwise = TargetAuthorityTrustClientResponseInvalidAtStatus status codec

installAcceptedTargetAuthority
  :: (Monad m)
  => TargetAuthorityTrustClient m
  -> AcceptedTargetAuthority
  -> m (Either TargetAuthorityTrustClientError AcceptedTargetAuthority)
installAcceptedTargetAuthority client desired = do
  result <-
    callTargetAuthorityTrust
      client
      (TargetAuthorityTrustRequest (encodeAcceptedTargetAuthority desired))
  pure $ do
    readBack <- result
    if readBack == desired
      then Right readBack
      else Left TargetAuthorityTrustClientReadBackMismatch
