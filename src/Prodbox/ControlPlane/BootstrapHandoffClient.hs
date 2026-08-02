{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Bootstrap Broker client for consumer-owned post-unseal
-- handoff acceptance and observation.
module Prodbox.ControlPlane.BootstrapHandoffClient
  ( BootstrapHandoffClient
  , BootstrapHandoffClientError (..)
  , bootstrapHandoffClient
  , acceptBootstrapHandoff
  , observeBootstrapHandoff
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.Bootstrap.Broker.Types
  ( PostUnsealConsumer
  , PostUnsealHandoffReceipt
  , RootInitBinding
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.BootstrapHandoffEndpoint
  ( BootstrapHandoffRequest (..)
  , BootstrapHandoffResponse (..)
  , bootstrapHandoffMaximumBytes
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( LifecycleBootstrapHandoffAcceptRoute
    , LifecycleBootstrapHandoffObserveRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype BootstrapHandoffClient m = BootstrapHandoffClient
  { callBootstrapHandoff
      :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
      -> BootstrapHandoffRequest
      -> m (Either BootstrapHandoffClientError BootstrapHandoffResponse)
  }

data BootstrapHandoffClientError
  = BootstrapHandoffTransportFailed !AuthenticatedClientError
  | BootstrapHandoffResponseInvalid !ControlPlaneResponseCodecError
  | BootstrapHandoffHttpStatus !Int
  | BootstrapHandoffClientRefused !Text
  | BootstrapHandoffClientUnavailable !Text
  deriving stock (Eq, Show)

bootstrapHandoffClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> BootstrapHandoffClient IO
bootstrapHandoffClient transport = BootstrapHandoffClient call
 where
  call route request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        route
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first BootstrapHandoffTransportFailed attempted
      response <-
        first
          BootstrapHandoffResponseInvalid
          ( decodeControlPlaneResponse
              bootstrapHandoffMaximumBytes
              (LazyByteString.fromStrict body)
          )
      case response of
        BootstrapHandoffAccepted {}
          | status == 200 -> Right response
          | otherwise -> Left (BootstrapHandoffHttpStatus status)
        BootstrapHandoffObserved {}
          | status == 200 -> Right response
          | otherwise -> Left (BootstrapHandoffHttpStatus status)
        BootstrapHandoffRefused detail -> Left (BootstrapHandoffClientRefused detail)
        BootstrapHandoffUnavailable detail -> Left (BootstrapHandoffClientUnavailable detail)

acceptBootstrapHandoff
  :: BootstrapHandoffClient IO
  -> RootInitBinding
  -> PostUnsealConsumer
  -> IO (Either BootstrapHandoffClientError PostUnsealHandoffReceipt)
acceptBootstrapHandoff client binding consumer = do
  attempted <-
    callBootstrapHandoff
      client
      LifecycleBootstrapHandoffAcceptRoute
      (BootstrapHandoffRequest binding consumer)
  pure $ do
    response <- attempted
    case response of
      BootstrapHandoffAccepted receipt -> Right receipt
      _ -> Left (BootstrapHandoffHttpStatus 500)

observeBootstrapHandoff
  :: BootstrapHandoffClient IO
  -> RootInitBinding
  -> PostUnsealConsumer
  -> IO (Either BootstrapHandoffClientError (Maybe PostUnsealHandoffReceipt))
observeBootstrapHandoff client binding consumer = do
  attempted <-
    callBootstrapHandoff
      client
      LifecycleBootstrapHandoffObserveRoute
      (BootstrapHandoffRequest binding consumer)
  pure $ do
    response <- attempted
    case response of
      BootstrapHandoffObserved receipt -> Right receipt
      _ -> Left (BootstrapHandoffHttpStatus 500)
