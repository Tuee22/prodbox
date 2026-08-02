{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Closed authenticated client for one Lifecycle Authority Admin Action.
-- Secret credentials are deliberately absent; the coordinator attaches them
-- directly to the attested Job only after authorization succeeds.
module Prodbox.ControlPlane.AdminActionClient
  ( AdminActionClient
  , AdminActionClientError (..)
  , mkAdminActionClient
  , adminActionClient
  , prepareAdminActionClient
  , authorizeAdminActionClient
  , completeAdminActionClient
  , observeAdminActionClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AdminActionEndpoint
  ( AdminActionAuthorityRequest (..)
  , AdminActionAuthorityResponse (..)
  , adminActionEndpointResponseMaximumBytes
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAdminActionRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionPodObservation
  , AdminActionPrepareRequest
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionBackupReceipt
  , AdminActionExecutionState
  , AdminActionPermitCore
  , AdminActionReceipt
  , SignedAdminActionPermit
  , decodeSignedAdminActionPermit
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype AdminActionClient m = AdminActionClient
  { callAdminAction
      :: AdminActionAuthorityRequest
      -> m (Either AdminActionClientError AdminActionAuthorityResponse)
  }

mkAdminActionClient
  :: ( AdminActionAuthorityRequest
       -> m (Either AdminActionClientError AdminActionAuthorityResponse)
     )
  -> AdminActionClient m
mkAdminActionClient = AdminActionClient

data AdminActionClientError
  = AdminActionClientTransportFailed !AuthenticatedClientError
  | AdminActionClientResponseInvalid !ControlPlaneResponseCodecError
  | AdminActionClientPermitInvalid
  | AdminActionClientHttpStatus !Int
  | AdminActionClientRefused !Text
  | AdminActionClientUnavailable !Text
  | AdminActionClientUnexpectedResponse
  deriving stock (Eq, Show)

adminActionClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AdminActionClient IO
adminActionClient transport = AdminActionClient $ \request -> do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAdminActionRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest request))
  pure $ do
    ControlPlaneResponse status body <- first AdminActionClientTransportFailed attempted
    response <-
      first
        AdminActionClientResponseInvalid
        ( decodeControlPlaneResponse
            adminActionEndpointResponseMaximumBytes
            (LazyByteString.fromStrict body)
        )
    case response of
      AdminActionRefused detail -> Left (AdminActionClientRefused detail)
      AdminActionUnavailable detail -> Left (AdminActionClientUnavailable detail)
      _
        | status == 200 -> Right response
        | otherwise -> Left (AdminActionClientHttpStatus status)

prepareAdminActionClient
  :: (Monad m)
  => AdminActionClient m
  -> AdminActionPrepareRequest
  -> m
       ( Either
           AdminActionClientError
           (AdminActionPermitCore, AdminActionBackupReceipt)
       )
prepareAdminActionClient client request = do
  response <- callAdminAction client (PrepareAdminAction request)
  pure $ do
    value <- response
    case value of
      AdminActionPrepared core backup -> Right (core, backup)
      _ -> Left AdminActionClientUnexpectedResponse

authorizeAdminActionClient
  :: (Monad m)
  => AdminActionClient m
  -> Text
  -> AdminActionPodObservation
  -> m (Either AdminActionClientError SignedAdminActionPermit)
authorizeAdminActionClient client operationId observation = do
  response <- callAdminAction client (AuthorizeAdminAction operationId observation)
  pure $ do
    value <- response
    case value of
      AdminActionAuthorized permit ->
        first (const AdminActionClientPermitInvalid) (decodeSignedAdminActionPermit permit)
      _ -> Left AdminActionClientUnexpectedResponse

completeAdminActionClient
  :: (Monad m)
  => AdminActionClient m
  -> Text
  -> AdminActionReceipt
  -> m (Either AdminActionClientError AdminActionReceipt)
completeAdminActionClient client operationId receipt = do
  response <- callAdminAction client (CompleteAdminAction operationId receipt)
  pure $ do
    value <- response
    case value of
      AdminActionCompleted confirmed -> Right confirmed
      _ -> Left AdminActionClientUnexpectedResponse

observeAdminActionClient
  :: (Monad m)
  => AdminActionClient m
  -> Text
  -> m (Either AdminActionClientError AdminActionExecutionState)
observeAdminActionClient client operationId = do
  response <- callAdminAction client (ObserveAdminAction operationId)
  pure $ do
    value <- response
    case value of
      AdminActionObserved state -> Right state
      _ -> Left AdminActionClientUnexpectedResponse
