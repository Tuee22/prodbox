{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.ControlPlane.AwsAdminTargetRevokeClient
  ( AwsAdminTargetRevokeClient (..)
  , AwsAdminTargetRevokeClientError (..)
  , awsAdminTargetRevokeClient
  , decodeAwsAdminTargetRevokeResponse
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AwsAdminTargetRevokeEndpoint
  ( AwsAdminTargetRevokeRefusal
  , AwsAdminTargetRevokeResponse (..)
  , awsAdminTargetRevokeMaximumBytes
  , awsAdminTargetRevokeRequest
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (TargetAwsAdminCredentialRevokeRoute)
  )
import Prodbox.ControlPlane.Codec (decodeControlPlaneResponse, encodeControlPlaneRequest)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentPermitId
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial (operatorMaterialPermitIdText)
import Prodbox.Lifecycle.TargetCommitIntent (credentialGenerationValue)
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

newtype AwsAdminTargetRevokeClient m = AwsAdminTargetRevokeClient
  { revokeAwsAdminTarget :: SignedAwsAdminPermit -> m (Either AwsAdminTargetRevokeClientError Text)
  }

data AwsAdminTargetRevokeClientError
  = AwsAdminTargetRevokeTransportUnavailable
  | AwsAdminTargetRevokeResponseInvalid
  | AwsAdminTargetRevokeRemoteRefused !AwsAdminTargetRevokeRefusal
  | AwsAdminTargetRevokeRemoteUnavailable
  deriving stock (Eq, Show)

awsAdminTargetRevokeClient
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime -> AwsAdminTargetRevokeClient IO
awsAdminTargetRevokeClient transport = AwsAdminTargetRevokeClient revoke
 where
  revoke permit = do
    result <-
      callAuthenticatedClientTransport
        transport
        TargetAwsAdminCredentialRevokeRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest (awsAdminTargetRevokeRequest permit)))
    pure $ do
      response <- first (const AwsAdminTargetRevokeTransportUnavailable) result
      decodeAwsAdminTargetRevokeResponse permit response

decodeAwsAdminTargetRevokeResponse
  :: SignedAwsAdminPermit
  -> ControlPlaneResponse
  -> Either AwsAdminTargetRevokeClientError Text
decodeAwsAdminTargetRevokeResponse permit (ControlPlaneResponse status body) = do
  response <-
    first
      (const AwsAdminTargetRevokeResponseInvalid)
      (decodeControlPlaneResponse awsAdminTargetRevokeMaximumBytes (LazyByteString.fromStrict body))
  case response of
    AwsAdminTargetGenerationAbsent generation permitId
      | status == 200
          && generation == credentialGenerationValue (awsAdminPermitIntentGeneration intent)
          && permitId == operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent) ->
          Right ("aws-admin:" <> permitId <> ":target-absent")
      | otherwise -> Left AwsAdminTargetRevokeResponseInvalid
    AwsAdminTargetRevokeRefused cause
      | status == 403 -> Left (AwsAdminTargetRevokeRemoteRefused cause)
      | otherwise -> Left AwsAdminTargetRevokeResponseInvalid
    AwsAdminTargetRevokeUnavailable
      | status == 503 -> Left AwsAdminTargetRevokeRemoteUnavailable
      | otherwise -> Left AwsAdminTargetRevokeResponseInvalid
 where
  intent = signedAwsAdminPermitIntent permit
