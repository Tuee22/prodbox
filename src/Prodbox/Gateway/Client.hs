{-# LANGUAGE OverloadedStrings #-}

-- | Typed HTTP client for the in-cluster prodbox gateway daemon. Replaces
-- the legacy curl subprocess at 'Prodbox.Gateway.queryGatewayState' per
-- Sprint 2.17. Extended in Sprint 2.19 with derive / ensure-namespace
-- secret-derivation endpoints per the secret_derivation_doctrine.md SSoT.
module Prodbox.Gateway.Client
  ( GatewayError (..)
  , queryState
  , statusUrl
  , renderGatewayError
  , derive
  , ensureNamespace
  , deriveUrl
  , ensureNamespaceUrl
  , hostLoopbackGatewayEndpoint
  )
where

import Data.Aeson (Value)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types.URI (urlEncode)
import Prodbox.Gateway.Types (PeerEndpoint (..), peerRestUrl)
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError
  , defaultHttpConfig
  , httpGetJson
  , httpPostJsonResponseJson
  , renderHttpError
  )
import Prodbox.Secret.Wire
  ( DeriveResponse (..)
  , EnsureNamespaceRequest (..)
  , EnsureNamespaceResponse (..)
  )

-- | Errors that surface from a gateway-client call.
data GatewayError
  = GatewayTransport HttpError
  | GatewayPayload String
  deriving (Eq, Show)

renderGatewayError :: GatewayError -> String
renderGatewayError err = case err of
  GatewayTransport httpErr -> renderHttpError httpErr
  GatewayPayload msg -> "gateway response payload error: " ++ msg

-- | Sprint 3.16: the host-CLI's view of the in-cluster gateway daemon —
-- the loopback-restricted NodePort the @secret_derivation_doctrine.md §5@
-- host↔cluster boundary pins to @127.0.0.1@. Host-side derived-secret
-- callers (@charts deploy@ pre-apply, @rke2 reconcile@ public-edge client
-- secret) dial this endpoint to request *derived* values; they never read
-- the raw master seed. The @gatewayNodePort@ argument is the daemon
-- NodePort the host iptables rule restricts to loopback
-- (@Prodbox.Host.defaultGatewayNodePort@). The socket fields are unused by
-- the @/v1/secret/*@ REST calls but populated for type completeness.
hostLoopbackGatewayEndpoint :: Int -> PeerEndpoint
hostLoopbackGatewayEndpoint gatewayNodePort =
  PeerEndpoint
    { peerNodeId = "host-cli"
    , peerStableDnsName = "127.0.0.1"
    , peerRestHost = "127.0.0.1"
    , peerRestPort = gatewayNodePort
    , peerSocketHost = "127.0.0.1"
    , peerSocketPort = gatewayNodePort
    }

-- | Canonical URL for the gateway daemon's @/v1/state@ observability
-- endpoint.
statusUrl :: PeerEndpoint -> String
statusUrl endpoint = peerRestUrl endpoint ++ "/v1/state"

-- | Query the gateway daemon's @/v1/state@ endpoint over HTTP. Mirrors the
-- 5-second timeout used by the legacy curl call site.
queryState :: PeerEndpoint -> IO (Either GatewayError Value)
queryState endpoint = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 5 * 1000 * 1000}
  result <- httpGetJson config (statusUrl endpoint)
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right value -> Right value

-- | Canonical URL for the gateway daemon's @GET /v1/secret/derive@
-- endpoint with the given context string URL-encoded as the @context@
-- query parameter.
deriveUrl :: PeerEndpoint -> Text -> String
deriveUrl endpoint context =
  peerRestUrl endpoint
    ++ "/v1/secret/derive?context="
    ++ BS8.unpack (urlEncode True (TE.encodeUtf8 context))

-- | Request a derived secret value from the gateway daemon. The context
-- string must match one of the canonical entries in
-- @documents/engineering/secret_derivation_doctrine.md@ §3; the daemon
-- returns @400@ for malformed or unknown contexts and @500 / 503@ for
-- master-seed availability failures (both surfaced as 'GatewayTransport'
-- with the status code preserved).
derive :: PeerEndpoint -> Text -> IO (Either GatewayError DeriveResponse)
derive endpoint context = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 10 * 1000 * 1000}
  result <- httpGetJson config (deriveUrl endpoint context)
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right response -> Right response

-- | Canonical URL for the gateway daemon's
-- @POST /v1/secret/ensure-namespace@ endpoint.
ensureNamespaceUrl :: PeerEndpoint -> String
ensureNamespaceUrl endpoint =
  peerRestUrl endpoint ++ "/v1/secret/ensure-namespace"

-- | Idempotently materialize every data-bound Kubernetes Secret for a
-- release through the gateway daemon. Used by chart pre-install Jobs and
-- by the host CLI before chart deploy. Returns the Secret names + SHA-256
-- of each derived value (never plaintext, per doctrine §4).
ensureNamespace
  :: PeerEndpoint
  -> Text
  -- ^ Kubernetes namespace.
  -> Text
  -- ^ Helm release name within the namespace.
  -> IO (Either GatewayError EnsureNamespaceResponse)
ensureNamespace endpoint namespace release = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
      payload =
        EnsureNamespaceRequest
          { ensureNamespaceRequestNamespace = namespace
          , ensureNamespaceRequestRelease = release
          }
  result <- httpPostJsonResponseJson config (ensureNamespaceUrl endpoint) payload
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right response -> Right response
