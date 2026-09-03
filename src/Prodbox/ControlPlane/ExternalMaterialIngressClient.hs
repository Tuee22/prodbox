{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed authenticated client for the Lifecycle Authority's ACME EAB
-- ingress state machine.  All methods are secret-free; plaintext is delivered
-- separately to the exact attested Job stdin.
module Prodbox.ControlPlane.ExternalMaterialIngressClient
  ( ExternalMaterialIngressClient
  , ExternalMaterialIngressClientError (..)
  , ExternalMaterialIngressPreparation (..)
  , mkExternalMaterialIngressClient
  , externalMaterialIngressClient
  , prepareExternalMaterialIngress
  , authorizeExternalMaterialIngress
  , completeExternalMaterialIngress
  , observeExternalMaterialIngress
  , observeCurrentExternalMaterialIngress
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleExternalMaterialIngressRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ExternalMaterialIngressEndpoint
  ( ExternalMaterialIngressAction
  , ExternalMaterialIngressChallenge
  , ExternalMaterialIngressObservation
  , ExternalMaterialIngressRequest (..)
  , ExternalMaterialIngressResponse (..)
  , ExternalMaterialPodObservation
  , externalMaterialIngressResponseMaximumBytes
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialTargetReceipt
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype ExternalMaterialIngressClient m = ExternalMaterialIngressClient
  { callExternalMaterialIngress
      :: ExternalMaterialIngressRequest
      -> m
           ( Either
               ExternalMaterialIngressClientError
               ExternalMaterialIngressResponse
           )
  }

mkExternalMaterialIngressClient
  :: ( ExternalMaterialIngressRequest
       -> m
            ( Either
                ExternalMaterialIngressClientError
                ExternalMaterialIngressResponse
            )
     )
  -> ExternalMaterialIngressClient m
mkExternalMaterialIngressClient = ExternalMaterialIngressClient

data ExternalMaterialIngressClientError
  = ExternalMaterialIngressClientTransportFailed !AuthenticatedClientError
  | ExternalMaterialIngressClientResponseInvalid !ControlPlaneResponseCodecError
  | ExternalMaterialIngressClientHttpStatus !Int
  | ExternalMaterialIngressClientRefused !Text
  | ExternalMaterialIngressClientUnavailable !Text
  | ExternalMaterialIngressClientUnexpectedResponse
  deriving stock (Eq, Show)

data ExternalMaterialIngressPreparation
  = ExternalMaterialIngressPreparedChallenge !ExternalMaterialIngressChallenge
  | ExternalMaterialIngressRecoveredReceipt
      !ExternalMaterialIngressChallenge
      !ExternalMaterialTargetReceipt
  deriving stock (Eq, Show)

externalMaterialIngressClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ExternalMaterialIngressClient IO
externalMaterialIngressClient transport =
  ExternalMaterialIngressClient $ \request -> do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleExternalMaterialIngressRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first ExternalMaterialIngressClientTransportFailed attempted
      response <-
        first
          ExternalMaterialIngressClientResponseInvalid
          ( decodeControlPlaneResponse
              externalMaterialIngressResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      case response of
        ExternalMaterialIngressRefused detail ->
          Left (ExternalMaterialIngressClientRefused detail)
        ExternalMaterialIngressUnavailable detail ->
          Left (ExternalMaterialIngressClientUnavailable detail)
        _
          | status == 200 -> Right response
          | otherwise -> Left (ExternalMaterialIngressClientHttpStatus status)

prepareExternalMaterialIngress
  :: (Monad m)
  => ExternalMaterialIngressClient m
  -> ExternalMaterialIngressAction
  -> Text
  -> Natural
  -> Text
  -> Natural
  -> m
       ( Either
           ExternalMaterialIngressClientError
           ExternalMaterialIngressPreparation
       )
prepareExternalMaterialIngress client action operationId generation imageDigest deadline = do
  response <-
    callExternalMaterialIngress
      client
      PrepareExternalMaterialIngress
        { externalMaterialPrepareAction = action
        , externalMaterialPrepareOperationId = operationId
        , externalMaterialPrepareGeneration = generation
        , externalMaterialPrepareImageDigest = imageDigest
        , externalMaterialPrepareDeadlineMicros = deadline
        }
  pure $ do
    result <- response
    case result of
      ExternalMaterialIngressPrepared challenge ->
        Right (ExternalMaterialIngressPreparedChallenge challenge)
      ExternalMaterialIngressRecovered challenge receipt ->
        Right (ExternalMaterialIngressRecoveredReceipt challenge receipt)
      _ -> Left ExternalMaterialIngressClientUnexpectedResponse

authorizeExternalMaterialIngress
  :: (Monad m)
  => ExternalMaterialIngressClient m
  -> Text
  -> ExternalMaterialPodObservation
  -> m (Either ExternalMaterialIngressClientError ByteString)
authorizeExternalMaterialIngress client operationId pod = do
  response <-
    callExternalMaterialIngress
      client
      AuthorizeExternalMaterialIngress
        { externalMaterialAuthorizeOperationId = operationId
        , externalMaterialAuthorizePod = pod
        }
  pure $ do
    result <- response
    case result of
      ExternalMaterialIngressAuthorized permit ->
        Right permit
      _ -> Left ExternalMaterialIngressClientUnexpectedResponse

completeExternalMaterialIngress
  :: (Monad m)
  => ExternalMaterialIngressClient m
  -> Text
  -> ExternalMaterialTargetReceipt
  -> m
       ( Either
           ExternalMaterialIngressClientError
           ExternalMaterialTargetReceipt
       )
completeExternalMaterialIngress client operationId receipt = do
  response <-
    callExternalMaterialIngress
      client
      CompleteExternalMaterialIngress
        { externalMaterialCompleteOperationId = operationId
        , externalMaterialCompleteReceipt = receipt
        }
  pure $ do
    result <- response
    case result of
      ExternalMaterialIngressCompleted confirmed -> Right confirmed
      _ -> Left ExternalMaterialIngressClientUnexpectedResponse

observeExternalMaterialIngress
  :: (Monad m)
  => ExternalMaterialIngressClient m
  -> Text
  -> m
       ( Either
           ExternalMaterialIngressClientError
           ExternalMaterialIngressObservation
       )
observeExternalMaterialIngress client operationId = do
  response <-
    callExternalMaterialIngress
      client
      ObserveExternalMaterialIngress
        { externalMaterialObserveOperationId = operationId
        }
  pure $ do
    result <- response
    case result of
      ExternalMaterialIngressObserved observation -> Right observation
      _ -> Left ExternalMaterialIngressClientUnexpectedResponse

observeCurrentExternalMaterialIngress
  :: (Monad m)
  => ExternalMaterialIngressClient m
  -> m
       ( Either
           ExternalMaterialIngressClientError
           (Maybe ExternalMaterialIngressObservation)
       )
observeCurrentExternalMaterialIngress client = do
  response <- callExternalMaterialIngress client ObserveCurrentExternalMaterialIngress
  pure $ do
    result <- response
    case result of
      ExternalMaterialIngressCurrentObserved observation -> Right observation
      _ -> Left ExternalMaterialIngressClientUnexpectedResponse
