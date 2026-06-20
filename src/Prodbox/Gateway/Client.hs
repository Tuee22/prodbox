{-# LANGUAGE OverloadedStrings #-}

-- | Typed HTTP client for the in-cluster prodbox gateway daemon. Replaces
-- the legacy curl subprocess at 'Prodbox.Gateway.queryGatewayState' per
-- Sprint 2.17.
module Prodbox.Gateway.Client
  ( GatewayError (..)
  , childBootstrapUrl
  , childrenUrl
  , queryChildBootstrap
  , queryFederationChildren
  , queryState
  , statusUrl
  , renderGatewayError
  , hostLoopbackGatewayEndpoint

    -- * Sprint 1.44: operator-write secret endpoint
  , operatorSecretUrl
  , writeOperatorSecret
  )
where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types.Header (Header)
import Prodbox.Gateway.Types (PeerEndpoint (..), peerRestUrl)
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError
  , defaultHttpConfig
  , httpGetJson
  , httpPostJsonNoResponse
  , renderHttpError
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

-- | Host-side view of the in-cluster gateway daemon through the
-- loopback-restricted NodePort. The @gatewayNodePort@ argument is the daemon
-- NodePort the host iptables rule restricts to loopback
-- (@Prodbox.Host.defaultGatewayNodePort@). Socket fields are populated for
-- type completeness.
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

childrenUrl :: PeerEndpoint -> String
childrenUrl endpoint = peerRestUrl endpoint ++ "/v1/federation/children"

childBootstrapUrl :: PeerEndpoint -> String -> String
childBootstrapUrl endpoint childId =
  peerRestUrl endpoint ++ "/v1/federation/children/" ++ childId ++ "/bootstrap"

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

queryFederationChildren :: PeerEndpoint -> IO (Either GatewayError Value)
queryFederationChildren endpoint = queryGatewayJson (childrenUrl endpoint)

queryChildBootstrap :: PeerEndpoint -> String -> IO (Either GatewayError Value)
queryChildBootstrap endpoint childId = queryGatewayJson (childBootstrapUrl endpoint childId)

queryGatewayJson :: String -> IO (Either GatewayError Value)
queryGatewayJson url = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 5 * 1000 * 1000}
  result <- httpGetJson config url
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right value -> Right value

-- | Sprint 1.44: the gateway daemon's operator-write endpoint for a given KV
-- logical path (e.g. @acme/eab@ or @gateway/gateway/aws@).
operatorSecretUrl :: PeerEndpoint -> String -> String
operatorSecretUrl endpoint logical = peerRestUrl endpoint ++ "/v1/secret/" ++ logical

-- | Write an operator-minted secret through the in-cluster gateway daemon,
-- presenting an operator-injected Kubernetes JWT (the daemon exchanges it for a
-- Vault token under the narrow @prodbox-operator-write@ role and persists the
-- KV object). Replaces the host root-token direct Vault write for the two
-- secrets that route through the daemon (Sprint 1.44).
writeOperatorSecret
  :: PeerEndpoint -> Text -> String -> Map Text Text -> IO (Either GatewayError ())
writeOperatorSecret endpoint operatorJwt logical fields = do
  let config = defaultHttpConfig {httpRequestTimeoutMicros = 5 * 1000 * 1000}
  result <-
    httpPostJsonNoResponse
      config
      [operatorJwtHeader operatorJwt]
      (operatorSecretUrl endpoint logical)
      fields
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right () -> Right ()

operatorJwtHeader :: Text -> Header
operatorJwtHeader operatorJwt =
  ("X-Prodbox-Operator-Jwt", TextEncoding.encodeUtf8 operatorJwt)
