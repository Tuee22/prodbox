{-# LANGUAGE OverloadedStrings #-}

-- | Typed HTTP client for the in-cluster prodbox gateway daemon. Replaces
-- the legacy curl subprocess at 'Prodbox.Gateway.queryGatewayState' per
-- Sprint 2.17.
module Prodbox.Gateway.Client
  ( GatewayError (..)
  , GatewayReadyzProbe (..)
  , queryReadyz
  , readyzUrl
  , daemonRestartBridgeRetryPolicy
  , gatewayErrorIsTransient
  , retryGatewayTransient
  , queryState
  , statusUrl
  , renderGatewayError
  , defaultGatewayNodePort
  , hostLoopbackGatewayEndpoint
  , hostLoopbackGatewayEndpointFromEnv

    -- * Write-shaped backend evidence (Sprint 1.76)
  , GatewayBackendRoundTrip (..)
  , decodeBackendRoundTrip
  , queryBackendRoundTrip
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Scientific (floatingOrInteger)
import Prodbox.ControlPlane.Observation (RoundTripWitness)
import Prodbox.ControlPlane.Observation.Internal (mintRoundTripWitness)
import Prodbox.Gateway.Routes
  ( GatewayRoute (..)
  , routePattern
  )
import Prodbox.Gateway.Types (PeerEndpoint (..), peerRestUrl)
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError (..)
  , defaultHttpConfig
  , httpGetJson
  , httpGetText
  , renderHttpError
  )
import Prodbox.Lifecycle.CheckpointAuthority (mkModelBObjectVersion)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Retry
  ( RetryPolicy
  , daemonRestartBridgeRetryPolicy
  , drawRetryDelayMicros
  , retryPolicyMaxAttempts
  )
import System.Environment (lookupEnv)

-- | Errors that surface from a gateway-client call.
data GatewayError
  = GatewayTransport HttpError
  | GatewayPayload String
  deriving (Eq, Show)

renderGatewayError :: GatewayError -> String
renderGatewayError err = case err of
  GatewayTransport httpErr -> renderHttpError httpErr
  GatewayPayload msg -> "gateway response payload error: " ++ msg

-- | A gateway error that is a bridgeable daemon-restart transient: the daemon
-- was briefly unreachable (connection dropped / refused, e.g.
-- @NoResponseDataReceived@ or @Connection refused@) or slow (timeout) while it
-- rolls, as opposed to answering with a definite rejection. Host-side callers
-- that talk to a daemon which may be mid-restart use this with
-- 'retryGatewayTransient' to wait
-- the restart window out instead of failing the whole reconcile.
gatewayErrorIsTransient :: GatewayError -> Bool
gatewayErrorIsTransient err = case err of
  GatewayTransport (HttpConnectionFailure _) -> True
  GatewayTransport (HttpTimeout _) -> True
  GatewayTransport (HttpStatus _ _) -> False
  GatewayTransport (HttpDecode _) -> False
  GatewayPayload _ -> False

-- | Retry a daemon call on TRANSIENT transport failures only, with the given
-- backoff schedule. A definite HTTP status / decode / payload error is the
-- daemon answering with a real rejection and returns immediately (retrying
-- would only mask it).
retryGatewayTransient
  :: RetryPolicy -> IO (Either GatewayError a) -> IO (Either GatewayError a)
retryGatewayTransient policy action = go 0
 where
  go attemptIndex = do
    result <- action
    case result of
      Right _ -> pure result
      Left err
        | gatewayErrorIsTransient err
        , attemptIndex + 1 < retryPolicyMaxAttempts policy -> do
            delay <- drawRetryDelayMicros policy attemptIndex
            threadDelay delay
            go (attemptIndex + 1)
        | otherwise -> pure result

-- | Single compiled NodePort used by the host firewall, chart, and typed
-- loopback clients.
defaultGatewayNodePort :: Int
defaultGatewayNodePort = 30443

-- | Host-side view of the in-cluster gateway daemon through the
-- loopback-restricted NodePort. The @gatewayNodePort@ argument is the daemon
-- NodePort the host iptables rule restricts to loopback. Socket fields are
-- populated for type completeness.
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

-- | Canonical host-loopback endpoint with the integration fixture's bounded
-- NodePort override.  Invalid overrides fail closed to the compiled port.
hostLoopbackGatewayEndpointFromEnv :: IO PeerEndpoint
hostLoopbackGatewayEndpointFromEnv = do
  override <- lookupEnv "PRODBOX_TEST_GATEWAY_NODEPORT"
  pure (hostLoopbackGatewayEndpoint (maybe defaultGatewayNodePort parsePort override))
 where
  parsePort raw = case reads raw of
    [(port, "")] | port > 0 && port <= 65535 -> port
    _ -> defaultGatewayNodePort

-- | Canonical URL for the gateway daemon's @/v1/state@ observability
-- endpoint.
-- Sprint 2.34: every gateway client URL is a projection of the compiled route
-- registry ("Prodbox.Gateway.Routes"), so the client cannot drift from the
-- daemon dispatcher.
statusUrl :: PeerEndpoint -> String
statusUrl endpoint = peerRestUrl endpoint ++ routePattern RouteState

-- | Canonical URL for the daemon's kubelet @/readyz@ readiness endpoint,
-- projected from the same compiled route registry the daemon dispatcher uses.
readyzUrl :: PeerEndpoint -> String
readyzUrl endpoint = peerRestUrl endpoint ++ routePattern RouteReadyz

-- | Sprint 2.34: the kubelet readiness a host-side observer sees when it GETs
-- the daemon's @/readyz@ — a 200 (ready), a definite HTTP status such as 503
-- (@draining@/@starting@; not yet ready) with the body detail, or a transport
-- failure (unreachable). This lets the lifecycle gate add a @/readyz@ precheck
-- so lifecycle-ready implies kubelet-ready by construction.
data GatewayReadyzProbe
  = GatewayReadyzReady
  | GatewayReadyzNotReady Int String
  | GatewayReadyzUnreachable String
  deriving (Eq, Show)

-- | Probe the daemon's @/readyz@ once. 'httpGetText' returns @Right body@ only
-- for a 2xx, so a 200 maps to ready; a definite non-2xx status (503) maps to
-- not-ready-yet with the body; a transport error maps to unreachable.
queryReadyz :: PeerEndpoint -> IO GatewayReadyzProbe
queryReadyz endpoint = do
  let config = defaultHttpConfig {httpRequestTimeoutMicros = 5 * 1000 * 1000}
  result <- httpGetText config (readyzUrl endpoint)
  pure $ case result of
    Right _body -> GatewayReadyzReady
    Left (HttpStatus code body) -> GatewayReadyzNotReady code body
    Left httpErr -> GatewayReadyzUnreachable (renderHttpError httpErr)

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

-- | Sprint 1.76: what the daemon reports about the gateway->object-store write
-- edge. Three states, kept distinct on purpose: the daemon has landed a
-- conditional write and reports its receipt; the daemon is up but has landed
-- none yet; or the field is unreadable, which is a decode failure and never an
-- absence.
data GatewayBackendRoundTrip
  = -- | The store accepted a conditional continuity write; the witness carries
    -- the version it returned and the instant it landed.
    GatewayBackendRoundTripWitnessed !RoundTripWitness
  | -- | The daemon answered, and reports no landed write yet.
    GatewayBackendRoundTripAbsent
  deriving (Eq, Show)

-- | Decode the @last_backend_round_trip@ field of a @\/v1\/state@ body.
--
-- This is one of the two places allowed to mint a 'RoundTripWitness', and the
-- reason is worth stating: the daemon performed the write, so the receipt is
-- evidence rather than an assertion, and this function is the authoritative
-- decoder of that receipt. It fails closed on every malformed shape — a missing
-- field, a non-object value, a version the store coordinate validator rejects,
-- or a non-integral instant — because a witness that cannot be decoded is not a
-- witness.
decodeBackendRoundTrip :: Value -> Either String GatewayBackendRoundTrip
decodeBackendRoundTrip body =
  case body of
    Object root ->
      case KeyMap.lookup (Key.fromString "last_backend_round_trip") root of
        Nothing ->
          Left "gateway /v1/state carries no last_backend_round_trip field"
        Just Null -> Right GatewayBackendRoundTripAbsent
        Just (Object receipt) -> witnessFrom receipt
        Just _ ->
          Left "gateway last_backend_round_trip is neither null nor an object"
    _ -> Left "gateway /v1/state body is not a JSON object"
 where
  witnessFrom receipt = do
    versionText <- textField receipt "object_version"
    landedMicros <- naturalField receipt "landed_at_micros"
    version <-
      case mkModelBObjectVersion versionText of
        Left err ->
          Left ("gateway reported an unusable round-trip object version: " ++ show err)
        Right value -> Right value
    Right
      ( GatewayBackendRoundTripWitnessed
          (mintRoundTripWitness version (authorityTimeFromMicros landedMicros))
      )

  textField receipt name =
    case KeyMap.lookup (Key.fromString name) receipt of
      Just (String value) -> Right value
      _ -> Left ("gateway round-trip receipt field `" ++ name ++ "` is not a string")

  naturalField receipt name =
    case KeyMap.lookup (Key.fromString name) receipt of
      Just (Number value) ->
        case floatingOrInteger value :: Either Double Integer of
          Right integral | integral >= 0 -> Right (fromInteger integral)
          _ ->
            Left
              ("gateway round-trip receipt field `" ++ name ++ "` is not a non-negative integer")
      _ -> Left ("gateway round-trip receipt field `" ++ name ++ "` is not a number")

-- | Read the daemon's write-shaped backend evidence off @\/v1\/state@.
queryBackendRoundTrip :: PeerEndpoint -> IO (Either GatewayError GatewayBackendRoundTrip)
queryBackendRoundTrip endpoint = do
  stateResult <- queryState endpoint
  pure $ case stateResult of
    Left err -> Left err
    Right value ->
      case decodeBackendRoundTrip value of
        Left detail -> Left (GatewayPayload detail)
        Right observed -> Right observed
