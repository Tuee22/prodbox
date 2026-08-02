{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Authenticated client for the Lifecycle Authority's closed control fold.
-- The request is a typed genesis/repair/migration command; callers must
-- re-observe the retained admission projection after success or response loss.
module Prodbox.ControlPlane.AuthorityControlClient
  ( AuthorityControlClient (..)
  , AuthorityControlClientError (..)
  , authorityControlClientWithTransport
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
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityControlPayload
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAuthorityControlRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype AuthorityControlClient m = AuthorityControlClient
  { submitAuthorityControl
      :: AuthorityControlPayload
      -> m (Either AuthorityControlClientError Text)
  }

data AuthorityControlClientError
  = AuthorityControlTransportFailed !AuthenticatedClientError
  | AuthorityControlRefused !Text
  | AuthorityControlHttpStatus !Int !Text
  | AuthorityControlResponseInvalid !ControlPlaneResponseCodecError
  deriving stock (Eq, Show)

authorityControlClientWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AuthorityControlClient IO
authorityControlClientWithTransport transport =
  AuthorityControlClient
    { submitAuthorityControl = \payload -> do
        attempted <-
          callAuthenticatedClientTransport
            transport
            LifecycleAuthorityControlRoute
            (LazyByteString.toStrict (encodeControlPlaneRequest payload))
        pure $ do
          ControlPlaneResponse status body <-
            first AuthorityControlTransportFailed attempted
          summary <-
            first
              AuthorityControlResponseInvalid
              ( decodeControlPlaneResponse
                  authorityControlMaximumResponseBytes
                  (LazyByteString.fromStrict body)
              )
          case status of
            200 -> Right summary
            409 -> Left (AuthorityControlRefused summary)
            _ -> Left (AuthorityControlHttpStatus status summary)
    }

authorityControlMaximumResponseBytes :: Int
authorityControlMaximumResponseBytes = 64 * 1024
