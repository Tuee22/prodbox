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
  )
where

import Data.Aeson (Value)
import Prodbox.Gateway.Types (PeerEndpoint, peerRestUrl)
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError
  , defaultHttpConfig
  , httpGetJson
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
