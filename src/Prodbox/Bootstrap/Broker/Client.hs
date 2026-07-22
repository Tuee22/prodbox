{-# LANGUAGE OverloadedStrings #-}

-- | Typed loopback client for the dedicated Bootstrap Broker.
--
-- Target calls carry authenticated, secret-free controller metadata only.
-- Operator password/share bytes are delivered directly to an attested
-- one-shot worker by the Phase-3 physical adapter and cannot be represented by
-- this API.  The Standard-P rollback helpers at the bottom remain explicitly
-- typed against a Gateway 'PeerEndpoint' until deployment qualification.
module Prodbox.Bootstrap.Broker.Client
  ( BrokerError (..)
  , renderBrokerError
  , brokerErrorIsTransient
  , BrokerEndpoint
  , brokerEndpointFromSettings
  , brokerRouteUrl
  , BrokerClientCredential
  , mkBrokerClientCredential
  , brokerClientCredentialLength
  , BrokerCallContext
  , mkBrokerCallContext
  , BrokerActionRequest
  , mkBrokerActionRequest
  , queryBrokerHealth
  , queryBrokerReadiness
  , initializeVault
  , unsealVault
  , queryVaultStatus
  , sealVault
  , rotateVaultUnlockBundle
  , rotateVaultTransitKey
  , reconcileVaultBaseline
  , queryVaultPkiStatus
  , issueVaultPkiTestCert
  , resetAmbiguousVaultInitialization
  , commitChildCustody
  , deliverChildRecovery
  , observeChildRecovery
  , legacyBootstrapVaultUrl
  , ensureVaultBootstrapLegacy
  , queryVaultStatusLegacy
  , sealVaultLegacy
  , rotateVaultUnlockBundleLegacy
  , rotateVaultTransitKeyLegacy
  , queryVaultPkiStatusLegacy
  , issueVaultPkiTestCertLegacy
  )
where

import Data.Aeson
  ( Value
  , encode
  , object
  , (.=)
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types.Header (Header)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.LegacyAdapter
  ( LegacyGatewayBootstrapRoute (..)
  , legacyGatewayBootstrapPath
  )
import Prodbox.Bootstrap.Broker.Program
  ( PkiIssueRequest
  )
import Prodbox.Bootstrap.Broker.Protocol
  ( BrokerActionRequest
  , brokerControllerRequestValue
  , mkBrokerActionRequest
  , mkBrokerControllerRequest
  , mkBrokerPkiControllerRequest
  , renderBrokerProtocolError
  )
import Prodbox.Bootstrap.Broker.Request
  ( BrokerServiceIdentity
  , IdempotencyKey
  , renderBrokerServiceIdentity
  , renderIdempotencyKey
  , renderRequestDigest
  , requestDigestForBytes
  )
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerRoute (..)
  , brokerRoutePath
  )
import Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerSettings
  , LoopbackAddress (..)
  , brokerListenAddress
  , brokerListenPort
  , brokerListener
  )
import Prodbox.Gateway.Types (PeerEndpoint, peerRestUrl)
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError (..)
  , defaultHttpConfig
  , httpGetJson
  , httpGetJsonWithHeaders
  , httpPostJsonResponseJson
  , httpPostJsonWithHeaders
  , renderHttpError
  )
import Prodbox.Vault.Client (SealStatus)

data BrokerError
  = BrokerTransport HttpError
  | BrokerPayload String
  deriving (Eq, Show)

renderBrokerError :: BrokerError -> String
renderBrokerError err = case err of
  BrokerTransport httpErr -> renderHttpError httpErr
  BrokerPayload message -> "bootstrap-broker response payload error: " ++ message

brokerErrorIsTransient :: BrokerError -> Bool
brokerErrorIsTransient err = case err of
  BrokerTransport (HttpConnectionFailure _) -> True
  BrokerTransport (HttpTimeout _) -> True
  BrokerTransport (HttpStatus _ _) -> False
  BrokerTransport (HttpDecode _) -> False
  BrokerPayload _ -> False

-- | Exact literal-loopback target.  There is no hostname/string constructor,
-- so a target client cannot accidentally address a Gateway or remote service.
data BrokerEndpoint = BrokerEndpoint !LoopbackAddress !Natural
  deriving (Eq, Show)

brokerEndpointFromSettings :: BootstrapBrokerSettings -> BrokerEndpoint
brokerEndpointFromSettings settings =
  BrokerEndpoint
    (brokerListenAddress listener)
    (fromIntegral (brokerListenPort listener))
 where
  listener = brokerListener settings

brokerRouteUrl :: BrokerEndpoint -> BrokerRoute -> String
brokerRouteUrl endpoint route = brokerEndpointBaseUrl endpoint ++ brokerRoutePath route

brokerEndpointBaseUrl :: BrokerEndpoint -> String
brokerEndpointBaseUrl (BrokerEndpoint address port) = case address of
  LoopbackIpv4 -> "http://127.0.0.1:" ++ show port
  LoopbackIpv6 -> "http://[::1]:" ++ show port

-- | Opaque transport attestation (for example a projected ServiceAccount
-- token).  Its constructor/bytes and ordinary rendering are unavailable.
newtype BrokerClientCredential = BrokerClientCredential ByteString
  deriving (Eq)

instance Show BrokerClientCredential where
  show credential =
    "BrokerClientCredential <redacted:"
      ++ show (brokerClientCredentialLength credential)
      ++ " bytes>"

mkBrokerClientCredential :: ByteString -> Either String BrokerClientCredential
mkBrokerClientCredential bytes
  | ByteString.null bytes = Left "broker transport credential must not be empty"
  | ByteString.length bytes > 4096 =
      Left "broker transport credential exceeds 4096 bytes"
  | otherwise = Right (BrokerClientCredential bytes)

brokerClientCredentialLength :: BrokerClientCredential -> Natural
brokerClientCredentialLength (BrokerClientCredential bytes) =
  fromIntegral (ByteString.length bytes)

data BrokerCallContext = BrokerCallContext
  { callServiceIdentity :: !BrokerServiceIdentity
  , callIdempotencyKey :: !IdempotencyKey
  , callCredential :: !BrokerClientCredential
  }
  deriving (Eq)

instance Show BrokerCallContext where
  show context =
    "BrokerCallContext {serviceIdentity = "
      ++ show (renderBrokerServiceIdentity (callServiceIdentity context))
      ++ ", idempotencyKey = "
      ++ show (renderIdempotencyKey (callIdempotencyKey context))
      ++ ", credential = <redacted>}"

mkBrokerCallContext
  :: BrokerServiceIdentity
  -> IdempotencyKey
  -> BrokerClientCredential
  -> BrokerCallContext
mkBrokerCallContext = BrokerCallContext

queryBrokerHealth
  :: BrokerEndpoint -> BrokerCallContext -> IO (Either BrokerError Value)
queryBrokerHealth endpoint context =
  getBrokerAction endpoint context BrokerHealth

queryBrokerReadiness
  :: BrokerEndpoint -> BrokerCallContext -> IO (Either BrokerError Value)
queryBrokerReadiness endpoint context =
  getBrokerAction endpoint context BrokerReadiness

initializeVault
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
initializeVault endpoint context =
  postBrokerAction endpoint context BrokerVaultInitialize

unsealVault
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
unsealVault endpoint context =
  postBrokerAction endpoint context BrokerVaultUnseal

queryVaultStatus
  :: BrokerEndpoint -> BrokerCallContext -> IO (Either BrokerError Value)
queryVaultStatus endpoint context =
  getBrokerAction endpoint context BrokerVaultStatus

sealVault
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
sealVault endpoint context =
  postBrokerAction endpoint context BrokerVaultSeal

rotateVaultUnlockBundle
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
rotateVaultUnlockBundle endpoint context =
  postBrokerAction endpoint context BrokerVaultRotateUnlockBundle

rotateVaultTransitKey
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
rotateVaultTransitKey endpoint context =
  postBrokerAction endpoint context BrokerVaultRotateTransitKey

reconcileVaultBaseline
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
reconcileVaultBaseline endpoint context =
  postBrokerAction endpoint context BrokerVaultBaselineReconcile

queryVaultPkiStatus
  :: BrokerEndpoint -> BrokerCallContext -> IO (Either BrokerError Value)
queryVaultPkiStatus endpoint context =
  getBrokerAction endpoint context BrokerVaultPkiStatus

issueVaultPkiTestCert
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> PkiIssueRequest
  -> IO (Either BrokerError Value)
issueVaultPkiTestCert endpoint context action request =
  postBrokerControllerRequest
    endpoint
    context
    BrokerVaultPkiIssueTestCertificate
    (brokerControllerRequestValue (mkBrokerPkiControllerRequest action request))

resetAmbiguousVaultInitialization
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
resetAmbiguousVaultInitialization endpoint context =
  postBrokerAction endpoint context BrokerVaultResetAmbiguousInitialization

commitChildCustody
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
commitChildCustody endpoint context =
  postBrokerAction endpoint context BrokerChildCustodyCommit

deliverChildRecovery
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
deliverChildRecovery endpoint context =
  postBrokerAction endpoint context BrokerChildRecoveryDeliver

observeChildRecovery
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
observeChildRecovery endpoint context =
  postBrokerAction endpoint context BrokerChildRecoveryObserve

getBrokerAction
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerRoute
  -> IO (Either BrokerError Value)
getBrokerAction endpoint context route = do
  result <-
    httpGetJsonWithHeaders
      targetReadConfig
      (brokerHeaders context ByteString.empty)
      (brokerRouteUrl endpoint route)
  pure (either (Left . BrokerTransport) Right result)

postBrokerAction
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerRoute
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)
postBrokerAction endpoint context route action =
  case mkBrokerControllerRequest route action of
    Left protocolError ->
      pure (Left (BrokerPayload (renderBrokerProtocolError protocolError)))
    Right request ->
      postBrokerControllerRequest
        endpoint
        context
        route
        (brokerControllerRequestValue request)

postBrokerControllerRequest
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerRoute
  -> Value
  -> IO (Either BrokerError Value)
postBrokerControllerRequest endpoint context route payload = do
  let exactBody = LazyByteString.toStrict (encode payload)
  result <-
    httpPostJsonWithHeaders
      targetWriteConfig
      (brokerHeaders context exactBody)
      (brokerRouteUrl endpoint route)
      payload
  pure (either (Left . BrokerTransport) Right result)

brokerHeaders :: BrokerCallContext -> ByteString -> [Header]
brokerHeaders context body =
  [
    ( "x-prodbox-service-identity"
    , TextEncoding.encodeUtf8 (renderBrokerServiceIdentity (callServiceIdentity context))
    )
  , ("x-prodbox-transport-credential", credentialBytes (callCredential context))
  ,
    ( "idempotency-key"
    , TextEncoding.encodeUtf8 (renderIdempotencyKey (callIdempotencyKey context))
    )
  ,
    ( "x-prodbox-request-sha256"
    , TextEncoding.encodeUtf8 (renderRequestDigest (requestDigestForBytes body))
    )
  ]

credentialBytes :: BrokerClientCredential -> ByteString
credentialBytes (BrokerClientCredential bytes) = bytes

targetReadConfig :: HttpConfig
targetReadConfig = defaultHttpConfig {httpRequestTimeoutMicros = 5 * 1000 * 1000}

targetWriteConfig :: HttpConfig
targetWriteConfig = defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}

-- Standard-P rollback adapter ---------------------------------------------

legacyBootstrapVaultUrl :: PeerEndpoint -> String
legacyBootstrapVaultUrl endpoint =
  legacyGatewayRouteUrl endpoint LegacyGatewayVaultEnsure

legacyGatewayRouteUrl :: PeerEndpoint -> LegacyGatewayBootstrapRoute -> String
legacyGatewayRouteUrl endpoint route =
  peerRestUrl endpoint ++ legacyGatewayBootstrapPath route

ensureVaultBootstrapLegacy :: PeerEndpoint -> Text -> IO (Either BrokerError Value)
ensureVaultBootstrapLegacy endpoint unlockPassword =
  postLegacyJsonAction
    (legacyGatewayRouteUrl endpoint LegacyGatewayVaultEnsure)
    ( object
        [ "unlock_password" .= unlockPassword
        , "loopback_nodeport_verified" .= True
        ]
    )

queryVaultStatusLegacy :: PeerEndpoint -> IO (Either BrokerError SealStatus)
queryVaultStatusLegacy endpoint = do
  result <-
    httpGetJson
      targetReadConfig
      (legacyGatewayRouteUrl endpoint LegacyGatewayVaultStatus)
  pure (either (Left . BrokerTransport) Right result)

sealVaultLegacy :: PeerEndpoint -> Text -> IO (Either BrokerError Value)
sealVaultLegacy endpoint =
  postLegacyPasswordAction (legacyGatewayRouteUrl endpoint LegacyGatewayVaultSeal)

rotateVaultUnlockBundleLegacy
  :: PeerEndpoint -> Text -> Text -> IO (Either BrokerError Value)
rotateVaultUnlockBundleLegacy endpoint unlockPassword newUnlockPassword =
  postLegacyJsonAction
    (legacyGatewayRouteUrl endpoint LegacyGatewayVaultRotateUnlockBundle)
    ( object
        [ "unlock_password" .= unlockPassword
        , "new_unlock_password" .= newUnlockPassword
        , "loopback_nodeport_verified" .= True
        ]
    )

rotateVaultTransitKeyLegacy
  :: PeerEndpoint -> Text -> Text -> IO (Either BrokerError Value)
rotateVaultTransitKeyLegacy endpoint unlockPassword keyName =
  postLegacyJsonAction
    (legacyGatewayRouteUrl endpoint LegacyGatewayVaultRotateTransitKey)
    ( object
        [ "unlock_password" .= unlockPassword
        , "key_name" .= keyName
        , "loopback_nodeport_verified" .= True
        ]
    )

queryVaultPkiStatusLegacy :: PeerEndpoint -> Text -> IO (Either BrokerError Value)
queryVaultPkiStatusLegacy endpoint =
  postLegacyPasswordAction (legacyGatewayRouteUrl endpoint LegacyGatewayVaultPkiStatus)

issueVaultPkiTestCertLegacy :: PeerEndpoint -> Text -> IO (Either BrokerError Value)
issueVaultPkiTestCertLegacy endpoint =
  postLegacyPasswordAction
    (legacyGatewayRouteUrl endpoint LegacyGatewayVaultPkiIssueTestCertificate)

postLegacyPasswordAction :: String -> Text -> IO (Either BrokerError Value)
postLegacyPasswordAction url unlockPassword =
  postLegacyJsonAction
    url
    ( object
        [ "unlock_password" .= unlockPassword
        , "loopback_nodeport_verified" .= True
        ]
    )

postLegacyJsonAction :: String -> Value -> IO (Either BrokerError Value)
postLegacyJsonAction url payload = do
  result <- httpPostJsonResponseJson targetWriteConfig url payload
  pure (either (Left . BrokerTransport) Right result)
