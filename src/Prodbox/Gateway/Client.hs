{-# LANGUAGE OverloadedStrings #-}

-- | Typed HTTP client for the in-cluster prodbox gateway daemon. Replaces
-- the legacy curl subprocess at 'Prodbox.Gateway.queryGatewayState' per
-- Sprint 2.17.
module Prodbox.Gateway.Client
  ( GatewayError (..)
  , daemonRestartBridgeRetryPolicy
  , gatewayErrorIsTransient
  , retryGatewayTransient
  , deletePulumiObject
  , bootstrapVaultUrl
  , childBootstrapUrl
  , childrenUrl
  , ensureVaultBootstrap
  , getPulumiObject
  , issueVaultPkiTestCert
  , pulumiObjectDeleteUrl
  , pulumiObjectGetUrl
  , pulumiObjectPutUrl
  , putPulumiObject
  , queryChildBootstrap
  , queryFederationChildren
  , queryState
  , queryVaultPkiStatus
  , queryVaultStatus
  , rotateVaultTransitKey
  , rotateVaultUnlockBundle
  , sealVault
  , statusUrl
  , renderGatewayError
  , hostLoopbackGatewayEndpoint

    -- * Sprint 1.44: operator-write secret endpoint
  , operatorSecretUrl
  , writeOperatorSecret
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types.Header (Header)
import Prodbox.Gateway.ObjectStore
  ( PulumiObjectGetResponse (..)
  , PulumiObjectPutRequest (..)
  , PulumiObjectRequest (..)
  , pulumiObjectDeletePath
  , pulumiObjectGetPath
  , pulumiObjectPutPath
  )
import Prodbox.Gateway.Types (PeerEndpoint (..), peerRestUrl)
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError (..)
  , defaultHttpConfig
  , httpGetJson
  , httpPostJsonNoResponse
  , httpPostJsonResponseJson
  , renderHttpError
  )
import Prodbox.Retry (RetryPolicy (..), retryDelayMicros)
import Prodbox.Vault.Client (SealStatus)

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
-- that talk to a daemon which may be mid-restart (the readiness probe, the
-- encrypted object-store reads) use this with 'retryGatewayTransient' to wait
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
            threadDelay (retryDelayMicros policy attemptIndex)
            go (attemptIndex + 1)
        | otherwise -> pure result

-- | Backoff for bridging a gateway-daemon restart window on the host side:
-- ~1+2+4+8+8s ≈ 23s across five retries — enough to ride out a Deployment
-- rollout (widened by host memory pressure) without hanging forever on a
-- genuinely-down daemon.
daemonRestartBridgeRetryPolicy :: RetryPolicy
daemonRestartBridgeRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 6
    , retryPolicyBaseDelayMicros = 1000000
    , retryPolicyMultiplier = 2
    , retryPolicyMaxDelayMicros = 8000000
    }

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

bootstrapVaultUrl :: PeerEndpoint -> String
bootstrapVaultUrl endpoint = peerRestUrl endpoint ++ "/v1/bootstrap/vault/ensure"

bootstrapVaultStatusUrl :: PeerEndpoint -> String
bootstrapVaultStatusUrl endpoint = peerRestUrl endpoint ++ "/v1/bootstrap/vault/status"

bootstrapVaultSealUrl :: PeerEndpoint -> String
bootstrapVaultSealUrl endpoint = peerRestUrl endpoint ++ "/v1/bootstrap/vault/seal"

bootstrapVaultRotateUnlockBundleUrl :: PeerEndpoint -> String
bootstrapVaultRotateUnlockBundleUrl endpoint =
  peerRestUrl endpoint ++ "/v1/bootstrap/vault/rotate-unlock-bundle"

bootstrapVaultRotateTransitKeyUrl :: PeerEndpoint -> String
bootstrapVaultRotateTransitKeyUrl endpoint =
  peerRestUrl endpoint ++ "/v1/bootstrap/vault/rotate-transit-key"

bootstrapVaultPkiStatusUrl :: PeerEndpoint -> String
bootstrapVaultPkiStatusUrl endpoint = peerRestUrl endpoint ++ "/v1/bootstrap/vault/pki/status"

bootstrapVaultPkiIssueTestCertUrl :: PeerEndpoint -> String
bootstrapVaultPkiIssueTestCertUrl endpoint =
  peerRestUrl endpoint ++ "/v1/bootstrap/vault/pki/issue-test-cert"

pulumiObjectGetUrl :: PeerEndpoint -> String
pulumiObjectGetUrl endpoint = peerRestUrl endpoint ++ pulumiObjectGetPath

pulumiObjectPutUrl :: PeerEndpoint -> String
pulumiObjectPutUrl endpoint = peerRestUrl endpoint ++ pulumiObjectPutPath

pulumiObjectDeleteUrl :: PeerEndpoint -> String
pulumiObjectDeleteUrl endpoint = peerRestUrl endpoint ++ pulumiObjectDeletePath

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

ensureVaultBootstrap :: PeerEndpoint -> Text -> IO (Either GatewayError Value)
ensureVaultBootstrap endpoint unlockPassword = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
      payload =
        object
          [ "unlock_password" .= unlockPassword
          , "loopback_nodeport_verified" .= True
          ]
  result <- httpPostJsonResponseJson config (bootstrapVaultUrl endpoint) payload
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right value -> Right value

queryVaultStatus :: PeerEndpoint -> IO (Either GatewayError SealStatus)
queryVaultStatus endpoint = do
  let config = defaultHttpConfig {httpRequestTimeoutMicros = 5 * 1000 * 1000}
  result <- httpGetJson config (bootstrapVaultStatusUrl endpoint)
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right value -> Right value

sealVault :: PeerEndpoint -> Text -> IO (Either GatewayError Value)
sealVault endpoint unlockPassword =
  postBootstrapPasswordAction (bootstrapVaultSealUrl endpoint) unlockPassword

rotateVaultUnlockBundle :: PeerEndpoint -> Text -> Text -> IO (Either GatewayError Value)
rotateVaultUnlockBundle endpoint unlockPassword newUnlockPassword = do
  let payload =
        object
          [ "unlock_password" .= unlockPassword
          , "new_unlock_password" .= newUnlockPassword
          , "loopback_nodeport_verified" .= True
          ]
  postBootstrapJsonAction (bootstrapVaultRotateUnlockBundleUrl endpoint) payload

rotateVaultTransitKey :: PeerEndpoint -> Text -> Text -> IO (Either GatewayError Value)
rotateVaultTransitKey endpoint unlockPassword keyName = do
  let payload =
        object
          [ "unlock_password" .= unlockPassword
          , "key_name" .= keyName
          , "loopback_nodeport_verified" .= True
          ]
  postBootstrapJsonAction (bootstrapVaultRotateTransitKeyUrl endpoint) payload

queryVaultPkiStatus :: PeerEndpoint -> Text -> IO (Either GatewayError Value)
queryVaultPkiStatus endpoint unlockPassword =
  postBootstrapPasswordAction (bootstrapVaultPkiStatusUrl endpoint) unlockPassword

issueVaultPkiTestCert :: PeerEndpoint -> Text -> IO (Either GatewayError Value)
issueVaultPkiTestCert endpoint unlockPassword =
  postBootstrapPasswordAction (bootstrapVaultPkiIssueTestCertUrl endpoint) unlockPassword

getPulumiObject :: PeerEndpoint -> Text -> IO (Either GatewayError (Maybe ByteString))
getPulumiObject endpoint stackName = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
      payload = PulumiObjectRequest stackName True
  result <- httpPostJsonResponseJson config (pulumiObjectGetUrl endpoint) payload
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right PulumiObjectAbsent -> Right Nothing
    Right (PulumiObjectPresent checkpoint) -> Right (Just checkpoint)

putPulumiObject :: PeerEndpoint -> Text -> ByteString -> IO (Either GatewayError ())
putPulumiObject endpoint stackName checkpoint = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
      payload = PulumiObjectPutRequest stackName checkpoint True
  result <- httpPostJsonNoResponse config [] (pulumiObjectPutUrl endpoint) payload
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right () -> Right ()

deletePulumiObject :: PeerEndpoint -> Text -> IO (Either GatewayError ())
deletePulumiObject endpoint stackName = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
      payload = PulumiObjectRequest stackName True
  result <- httpPostJsonNoResponse config [] (pulumiObjectDeleteUrl endpoint) payload
  pure $ case result of
    Left httpErr -> Left (GatewayTransport httpErr)
    Right () -> Right ()

postBootstrapPasswordAction :: String -> Text -> IO (Either GatewayError Value)
postBootstrapPasswordAction url unlockPassword =
  postBootstrapJsonAction
    url
    ( object
        [ "unlock_password" .= unlockPassword
        , "loopback_nodeport_verified" .= True
        ]
    )

postBootstrapJsonAction :: String -> Value -> IO (Either GatewayError Value)
postBootstrapJsonAction url payload = do
  let config =
        defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
  result <- httpPostJsonResponseJson config url payload
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
