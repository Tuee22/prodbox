{-# LANGUAGE DataKinds #-}

-- | Authenticated client for retained controller-owner transitions.
module Prodbox.ControlPlane.ControllerOwnerTransportClient
  ( ControllerOwnerClient
  , ControllerOwnerClientError (..)
  , lifecycleAuthorityControllerOwnerAuthenticatedClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleControllerOwnerRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ControllerOwnerEndpoint
  ( ControllerOwnerEndpointResponseError
  , confirmControllerOwnerEndpointResponse
  , controllerOwnerWireResponseStatus
  , decodeControllerOwnerEndpointResponse
  )
import Prodbox.ControlPlane.ControllerOwnerRepository
  ( ControllerOwnerTransition
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lib.AwsControlPlaneIsolation (ControllerOwnerState)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

type ControllerOwnerClient =
  ControllerOwnerTransition
  -> IO (Either ControllerOwnerClientError ControllerOwnerState)

data ControllerOwnerClientError
  = ControllerOwnerClientTransportFailed !Text
  | ControllerOwnerClientResponseInvalid !ControlPlaneResponseCodecError
  | ControllerOwnerClientHttpStatusMismatch !Int !Int
  | ControllerOwnerClientConfirmationFailed
      !ControllerOwnerEndpointResponseError
  deriving (Eq, Show)

lifecycleAuthorityControllerOwnerAuthenticatedClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ControllerOwnerClient
lifecycleAuthorityControllerOwnerAuthenticatedClient transport transition = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleControllerOwnerRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest transition))
  pure $ do
    ControlPlaneResponse status body <-
      first
        (ControllerOwnerClientTransportFailed . Text.pack . show)
        attempted
    response <-
      first
        ControllerOwnerClientResponseInvalid
        (decodeControllerOwnerEndpointResponse body)
    let expectedStatus = replyStatusCode (controllerOwnerWireResponseStatus response)
    if status == expectedStatus
      then
        first
          ControllerOwnerClientConfirmationFailed
          (confirmControllerOwnerEndpointResponse transition response)
      else Left (ControllerOwnerClientHttpStatusMismatch expectedStatus status)
