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
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
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
  | -- | Sprint 4.60: the refused status AND the bounded reason the server sent
    -- with it. Carrying only the status was the last conversion in the chain
    -- this sprint removes — the server now answers a decode failure with a 500
    -- naming the field, and dropping the body here would put the reason back
    -- out of reach (chaos_hardening_doctrine.md section 23; a refusal retains
    -- its structured reason, bootstrap_readiness_doctrine.md section 0.5).
    ConfigClientHttpStatus !Int !Text
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
        then
          Left
            ( ConfigClientHttpStatus
                status
                (TextEncoding.decodeUtf8Lenient (ByteString.take configClientReasonMaximumBytes body))
            )
        else
          first
            ConfigClientResponseInvalid
            ( decodeControlPlaneResponse
                configEndpointResponseMaximumBytes
                (LazyByteString.fromStrict body)
            )

-- | How much of a refusal body reaches the operator. Bounded because the body
-- is attacker-influenced in principle and an error string is not a transport.
configClientReasonMaximumBytes :: Int
configClientReasonMaximumBytes = 512
