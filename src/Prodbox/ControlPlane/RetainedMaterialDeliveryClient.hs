{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Closed authenticated client for Lifecycle Authority retained delivery.
module Prodbox.ControlPlane.RetainedMaterialDeliveryClient
  ( RetainedMaterialDeliveryClient
  , RetainedMaterialDeliveryClientError (..)
  , retainedMaterialDeliveryClient
  , retainedMaterialDeliveryClientWith
  , requestRetainedMaterialDelivery
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
  , ControlPlaneRouteFor (LifecycleRetainedMaterialDeliveryRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryEndpoint
  ( RetainedMaterialDeliveryWireRequest
  , RetainedMaterialDeliveryWireResponse (..)
  , retainedMaterialDeliveryMaximumBytes
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype RetainedMaterialDeliveryClient m = RetainedMaterialDeliveryClient
  { callRetainedMaterialDelivery
      :: RetainedMaterialDeliveryWireRequest
      -> m (Either RetainedMaterialDeliveryClientError RetainedMaterialDeliveryWireResponse)
  }

data RetainedMaterialDeliveryClientError
  = RetainedMaterialDeliveryTransportFailed !AuthenticatedClientError
  | RetainedMaterialDeliveryResponseInvalid !ControlPlaneResponseCodecError
  | RetainedMaterialDeliveryHttpStatus !Int
  | RetainedMaterialDeliveryRemoteRefused !Text
  deriving stock (Eq, Show)

retainedMaterialDeliveryClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RetainedMaterialDeliveryClient IO
retainedMaterialDeliveryClient transport = RetainedMaterialDeliveryClient $ \request -> do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleRetainedMaterialDeliveryRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest request))
  pure $ do
    ControlPlaneResponse status body <- first RetainedMaterialDeliveryTransportFailed attempted
    response <-
      first
        RetainedMaterialDeliveryResponseInvalid
        ( decodeControlPlaneResponse
            retainedMaterialDeliveryMaximumBytes
            (LazyByteString.fromStrict body)
        )
    case response of
      applied@RetainedMaterialDeliveryApplied {}
        | status == 200 -> Right applied
        | otherwise -> Left (RetainedMaterialDeliveryHttpStatus status)
      RetainedMaterialDeliveryRefused detail ->
        Left (RetainedMaterialDeliveryRemoteRefused detail)

retainedMaterialDeliveryClientWith
  :: ( RetainedMaterialDeliveryWireRequest
       -> m (Either RetainedMaterialDeliveryClientError RetainedMaterialDeliveryWireResponse)
     )
  -> RetainedMaterialDeliveryClient m
retainedMaterialDeliveryClientWith = RetainedMaterialDeliveryClient

requestRetainedMaterialDelivery
  :: (Monad m)
  => RetainedMaterialDeliveryClient m
  -> RetainedMaterialDeliveryWireRequest
  -> m (Either RetainedMaterialDeliveryClientError RetainedMaterialDeliveryWireResponse)
requestRetainedMaterialDelivery = callRetainedMaterialDelivery
