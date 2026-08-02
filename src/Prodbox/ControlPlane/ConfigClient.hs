{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Authenticated typed client for Lifecycle Authority config observation and
-- generation-CAS proposal.  Its projection scope is fixed at construction.
module Prodbox.ControlPlane.ConfigClient
  ( ConfigClient (..)
  , ConfigClientError (..)
  , lifecycleConfigClient
  , configClientWithTransport
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientProviders
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , callAuthenticatedClientTransport
  , callAuthenticatedControlPlane
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( LifecycleConfigObserveRoute
    , LifecycleConfigProposeCasRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigObservation
  , ConfigObserveRequest (..)
  , ConfigProjectionScope
  , ConfigProposeCasRequest
  , ConfigProposeCasResponse
  , configEndpointResponseMaximumBytes
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data ConfigClient m = ConfigClient
  { observeConfig :: m (Either ConfigClientError ConfigObservation)
  , proposeConfigCas
      :: ConfigProposeCasRequest
      -> m (Either ConfigClientError ConfigProposeCasResponse)
  }

data ConfigClientError
  = ConfigClientTransportFailed !AuthenticatedClientError
  | ConfigClientHttpStatus !Int
  | ConfigClientResponseInvalid !ControlPlaneResponseCodecError
  deriving stock (Eq, Show)

lifecycleConfigClient
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'LifecycleAuthorityRuntime
  -> ConfigProjectionScope
  -> ConfigClient IO
lifecycleConfigClient bounds providers client scope =
  configClientWith
    (callAuthenticatedControlPlane bounds providers client)
    scope

configClientWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ConfigProjectionScope
  -> ConfigClient IO
configClientWithTransport transport =
  configClientWith (callAuthenticatedClientTransport transport)

configClientWith
  :: ( ControlPlaneRouteFor 'LifecycleAuthorityRuntime
       -> ByteString
       -> IO (Either AuthenticatedClientError ControlPlaneResponse)
     )
  -> ConfigProjectionScope
  -> ConfigClient IO
configClientWith call scope =
  ConfigClient
    { observeConfig =
        request
          LifecycleConfigObserveRoute
          (ConfigObserveRequest scope)
    , proposeConfigCas =
        request LifecycleConfigProposeCasRoute
    }
 where
  request route payload = do
    attempted <-
      call
        route
        (LazyByteString.toStrict (encodeControlPlaneRequest payload))
    pure $ do
      ControlPlaneResponse status body <-
        first ConfigClientTransportFailed attempted
      if status /= 200
        then Left (ConfigClientHttpStatus status)
        else
          first
            ConfigClientResponseInvalid
            ( decodeControlPlaneResponse
                configEndpointResponseMaximumBytes
                (LazyByteString.fromStrict body)
            )
