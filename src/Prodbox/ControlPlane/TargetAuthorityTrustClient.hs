{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority client for public Target trust
-- installation and exact read-back.
module Prodbox.ControlPlane.TargetAuthorityTrustClient
  ( TargetAuthorityTrustClient
  , TargetAuthorityTrustClientError (..)
  , targetAuthorityTrustClient
  , installAcceptedTargetAuthority
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
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
import Prodbox.ControlPlane.TargetAuthorityTrustEndpoint
  ( TargetAuthorityTrustRequest (..)
  , TargetAuthorityTrustResponse (..)
  , targetAuthorityTrustResponseMaximumBytes
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
  | TargetAuthorityTrustClientHttpStatus !Int
  | TargetAuthorityTrustClientRefused !Text
  | TargetAuthorityTrustClientUnavailable !Text
  | TargetAuthorityTrustClientReadBackInvalid
  | TargetAuthorityTrustClientReadBackMismatch
  deriving stock (Eq, Show)

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
      ControlPlaneResponse status body <-
        first TargetAuthorityTrustClientTransportFailed attempted
      response <-
        first
          TargetAuthorityTrustClientResponseInvalid
          ( decodeControlPlaneResponse
              targetAuthorityTrustResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      case response of
        TargetAuthorityTrustInstalledResponse bytes -> success status bytes
        TargetAuthorityTrustAlreadyInstalledResponse bytes -> success status bytes
        TargetAuthorityTrustRecoveredResponse bytes -> success status bytes
        TargetAuthorityTrustRefusedResponse detail ->
          Left (TargetAuthorityTrustClientRefused detail)
        TargetAuthorityTrustUnavailableResponse detail ->
          Left (TargetAuthorityTrustClientUnavailable detail)

  success status bytes
    | status /= 200 = Left (TargetAuthorityTrustClientHttpStatus status)
    | otherwise =
        first
          (const TargetAuthorityTrustClientReadBackInvalid)
          ( decodeAcceptedTargetAuthority
              acceptedTargetAuthorityMaximumEncodedBytes
              bytes
          )

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
