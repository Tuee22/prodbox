{-# LANGUAGE OverloadedStrings #-}

-- | Typed client for the dedicated Bootstrap Broker.
--
-- Target calls carry authenticated, secret-free controller metadata only.
-- Operator password/share bytes are delivered directly to an attested
-- one-shot worker by the Phase-3 physical adapter and cannot be represented by
-- this API. Production callers construct their context from the fixed
-- custom-audience projected ServiceAccount token path; the token is reread for
-- every call so kubelet rotation cannot leave a long-lived stale credential.
module Prodbox.Bootstrap.Broker.Client
  ( BrokerError (..)
  , renderBrokerError
  , brokerErrorIsTransient
  , BrokerEndpoint
  , brokerEndpointFromSettings
  , mkLoopbackBrokerEndpoint
  , brokerRouteUrl
  , BrokerClientCredential
  , mkBrokerClientCredential
  , brokerClientCredentialLength
  , BrokerClientContextError (..)
  , renderBrokerClientContextError
  , brokerProjectedTokenPath
  , BrokerCallContext
  , mkBrokerCallContext
  , loadProjectedBrokerCallContext
  , withProjectedBrokerCallContext
  , requestHostBrokerCallContext
  , requestHostBrokerCallContextWithEnvironment
  , BrokerActionRequest
  , mkBrokerActionRequest
  , brokerRequestDigestForAction
  , brokerRequestDigestForPkiAction
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
  , prepareChildCustody
  , finalizeChildCustody
  , brokerRequestDigestForChildCustodyFinalize
  , deliverChildRecovery
  , observeChildRecovery
  )
where

import Codec.Serialise (deserialiseOrFail)
import Control.Exception (IOException, try)
import Data.Aeson
  ( Value
  , encode
  , withObject
  , (.:)
  )
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isControl, isSpace)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types.Header (Header)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.ChartStatics qualified as ChartStatics
import Prodbox.Bootstrap.Broker.Program
  ( PkiIssueRequest
  )
import Prodbox.Bootstrap.Broker.Protocol
  ( BrokerActionRequest
  , brokerControllerRequestValue
  , encodeBrokerControllerRequest
  , mkBrokerActionRequest
  , mkBrokerChildCustodyFinalizeRequest
  , mkBrokerControllerRequest
  , mkBrokerPkiControllerRequest
  , renderBrokerProtocolError
  )
import Prodbox.Bootstrap.Broker.Request
  ( BrokerServiceIdentity
  , IdempotencyKey
  , RequestDigest
  , mkBrokerServiceIdentity
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
import Prodbox.Cluster.FederationRegistration
  ( ChildCustodyExport
  , FederationRegistrationCompletion
  , validateChildCustodyExport
  )
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError (..)
  , defaultHttpConfig
  , httpGetJsonWithHeaders
  , httpPostJsonWithHeaders
  , renderHttpError
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Exit (ExitCode (..))
import System.IO (IOMode (ReadMode), withBinaryFile)

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

-- | Host-side endpoint for a bounded @kubectl port-forward@. Only literal
-- IPv4 loopback is constructible; the caller cannot redirect the bearer token
-- to a hostname or remote address.
mkLoopbackBrokerEndpoint :: Natural -> Either String BrokerEndpoint
mkLoopbackBrokerEndpoint port
  | port == 0 || port > 65535 = Left "Bootstrap Broker loopback port must be in 1..65535"
  | otherwise = Right (BrokerEndpoint LoopbackIpv4 port)

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

maximumBrokerClientCredentialBytes :: Int
maximumBrokerClientCredentialBytes = 4096

mkBrokerClientCredential :: ByteString -> Either String BrokerClientCredential
mkBrokerClientCredential bytes
  | ByteString.null bytes = Left "broker transport credential must not be empty"
  | ByteString.length bytes > maximumBrokerClientCredentialBytes =
      Left "broker transport credential exceeds 4096 bytes"
  | otherwise = Right (BrokerClientCredential bytes)

brokerClientCredentialLength :: BrokerClientCredential -> Natural
brokerClientCredentialLength (BrokerClientCredential bytes) =
  fromIntegral (ByteString.length bytes)

data BrokerClientContextError
  = BrokerProjectedCredentialReadFailed
  | BrokerProjectedCredentialTooLarge
  | BrokerProjectedCredentialInvalid
  | BrokerProjectedCredentialRejected !String
  | BrokerTokenRequestNamespaceInvalid
  | BrokerTokenRequestProcessFailed
  | BrokerTokenRequestRefused
  deriving (Eq, Show)

renderBrokerClientContextError :: BrokerClientContextError -> String
renderBrokerClientContextError err = case err of
  BrokerProjectedCredentialReadFailed ->
    "failed to read the projected Bootstrap Broker ServiceAccount token"
  BrokerProjectedCredentialTooLarge ->
    "projected Bootstrap Broker ServiceAccount token exceeds 4096 bytes"
  BrokerProjectedCredentialInvalid ->
    "projected Bootstrap Broker ServiceAccount token is empty or contains invalid bytes"
  BrokerProjectedCredentialRejected detail -> detail
  BrokerTokenRequestNamespaceInvalid ->
    "Bootstrap Broker TokenRequest namespace is invalid"
  BrokerTokenRequestProcessFailed ->
    "failed to execute the Kubernetes Bootstrap Broker TokenRequest"
  BrokerTokenRequestRefused ->
    "Kubernetes refused the Bootstrap Broker TokenRequest"

-- | Fixed mount coordinate for a short-lived ServiceAccount token whose
-- audience is @prodbox-bootstrap-broker@. This is intentionally distinct from
-- Kubernetes' default API-audience token.
brokerProjectedTokenPath :: FilePath
brokerProjectedTokenPath =
  "/var/run/secrets/prodbox/bootstrap-broker/token"

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

-- | Read and validate the rotating projected token immediately before one
-- Broker call. Callers must not retain the returned context across operations;
-- use 'withProjectedBrokerCallContext' when possible to make that lifetime
-- explicit.
loadProjectedBrokerCallContext
  :: BrokerServiceIdentity
  -> IdempotencyKey
  -> IO (Either BrokerClientContextError BrokerCallContext)
loadProjectedBrokerCallContext identity idempotencyKey = do
  readResult <-
    try
      ( withBinaryFile brokerProjectedTokenPath ReadMode $ \handle ->
          ByteString.hGet handle (maximumBrokerClientCredentialBytes + 1)
      )
      :: IO (Either IOException ByteString)
  pure $ do
    bytes <- either (const (Left BrokerProjectedCredentialReadFailed)) Right readResult
    if ByteString.length bytes > maximumBrokerClientCredentialBytes
      then Left BrokerProjectedCredentialTooLarge
      else Right ()
    decoded <-
      either
        (const (Left BrokerProjectedCredentialInvalid))
        Right
        (TextEncoding.decodeUtf8' bytes)
    if Text.null decoded
      || Text.any
        (\character -> not (isAscii character) || isSpace character || isControl character)
        decoded
      then Left BrokerProjectedCredentialInvalid
      else Right ()
    credential <-
      either
        (Left . BrokerProjectedCredentialRejected)
        Right
        (mkBrokerClientCredential bytes)
    Right (mkBrokerCallContext identity idempotencyKey credential)

withProjectedBrokerCallContext
  :: BrokerServiceIdentity
  -> IdempotencyKey
  -> (BrokerCallContext -> IO value)
  -> IO (Either BrokerClientContextError value)
withProjectedBrokerCallContext identity idempotencyKey use = do
  loaded <- loadProjectedBrokerCallContext identity idempotencyKey
  case loaded of
    Left err -> pure (Left err)
    Right context -> Right <$> use context

-- | Mint one short-lived custom-audience credential from the host through the
-- Kubernetes TokenRequest API. The token is retained only in the opaque call
-- context and is bounded/validated by the same constructor as projected-token
-- callers. This is the host counterpart of
-- 'loadProjectedBrokerCallContext'; it is not a shared-profile or persisted
-- credential source.
requestHostBrokerCallContext
  :: FilePath
  -> Text.Text
  -> IdempotencyKey
  -> IO (Either BrokerClientContextError BrokerCallContext)
requestHostBrokerCallContext repoRoot namespace idempotencyKey =
  requestHostBrokerCallContextWithEnvironment
    Nothing
    repoRoot
    namespace
    idempotencyKey

-- | Environment-explicit TokenRequest variant used by substrate-selecting
-- host brackets. In particular, the caller can pin @KUBECONFIG@ rather than
-- allowing an ambient context to redirect the custom-audience credential.
requestHostBrokerCallContextWithEnvironment
  :: Maybe [(String, String)]
  -> FilePath
  -> Text.Text
  -> IdempotencyKey
  -> IO (Either BrokerClientContextError BrokerCallContext)
requestHostBrokerCallContextWithEnvironment environment repoRoot namespace idempotencyKey =
  case validateKubernetesNamespace namespace of
    Left err -> pure (Left err)
    Right () -> do
      captured <-
        captureSubprocessBounded
          hostTokenRequestLimits
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments =
                [ "create"
                , "token"
                , Text.unpack
                    ( ChartStatics.brokerStaticClientServiceAccount
                        ChartStatics.brokerChartStatics
                    )
                , "--namespace"
                , Text.unpack namespace
                , "--audience"
                , Text.unpack
                    ( ChartStatics.brokerStaticTokenAudience
                        ChartStatics.brokerChartStatics
                    )
                , "--duration=10m"
                ]
            , subprocessEnvironment = environment
            , subprocessWorkingDirectory = Just repoRoot
            }
      pure $ do
        output <- case captured of
          Left _ -> Left BrokerTokenRequestProcessFailed
          Right value -> Right value
        case processExitCode output of
          ExitFailure _ -> Left BrokerTokenRequestRefused
          ExitSuccess -> Right ()
        let tokenText = Text.strip (Text.pack (processStdout output))
            tokenBytes = TextEncoding.encodeUtf8 tokenText
        if Text.null tokenText
          || Text.any
            (\character -> not (isAscii character) || isSpace character || isControl character)
            tokenText
          then Left BrokerProjectedCredentialInvalid
          else Right ()
        credential <-
          either
            (Left . BrokerProjectedCredentialRejected)
            Right
            (mkBrokerClientCredential tokenBytes)
        identity <-
          either
            (Left . BrokerProjectedCredentialRejected . show)
            Right
            ( mkBrokerServiceIdentity
                ( ChartStatics.brokerStaticClientServiceAccount
                    ChartStatics.brokerChartStatics
                )
            )
        Right (mkBrokerCallContext identity idempotencyKey credential)

hostTokenRequestLimits :: BoundedSubprocessLimits
hostTokenRequestLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = maximumBrokerClientCredentialBytes + 1
    , boundedSubprocessMaximumStderrBytes = 4096
    , boundedSubprocessTimeoutMicros = 10 * 1000 * 1000
    }

validateKubernetesNamespace :: Text.Text -> Either BrokerClientContextError ()
validateKubernetesNamespace namespace
  | Text.null namespace = Left BrokerTokenRequestNamespaceInvalid
  | Text.length namespace > 63 = Left BrokerTokenRequestNamespaceInvalid
  | not (asciiAlphaNumeric (Text.head namespace)) = Left BrokerTokenRequestNamespaceInvalid
  | not (asciiAlphaNumeric (Text.last namespace)) = Left BrokerTokenRequestNamespaceInvalid
  | Text.any (\character -> not (asciiAlphaNumeric character || character == '-')) namespace =
      Left BrokerTokenRequestNamespaceInvalid
  | otherwise = Right ()
 where
  asciiAlphaNumeric character =
    (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')

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

prepareChildCustody
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError ChildCustodyExport)
prepareChildCustody endpoint context action = do
  response <-
    postBrokerAction endpoint context BrokerChildCustodyPrepare action
  pure (response >>= decodeChildCustodyExport)

finalizeChildCustody
  :: BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> FederationRegistrationCompletion
  -> IO (Either BrokerError Value)
finalizeChildCustody endpoint context action completion =
  postBrokerControllerRequest
    endpoint
    context
    BrokerChildCustodyFinalize
    ( brokerControllerRequestValue
        (mkBrokerChildCustodyFinalizeRequest action completion)
    )

decodeChildCustodyExport :: Value -> Either BrokerError ChildCustodyExport
decodeChildCustodyExport value = do
  encoded <-
    either
      (Left . BrokerPayload)
      Right
      ( parseEither
          (withObject "child custody prepare response" (.: "custody_export_cbor_base64"))
          value
      )
  bytes <-
    either
      (Left . BrokerPayload)
      Right
      (Base64.decode (TextEncoding.encodeUtf8 encoded))
  exported <-
    either
      (Left . BrokerPayload . show)
      Right
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  either
    (Left . BrokerPayload . show)
    Right
    (validateChildCustodyExport exported)

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

-- | Digest the exact JSON entity bytes the ordinary route client will send.
-- Host secret-ingress attestation uses this value to bind the one-shot Pod to
-- the controller request without exposing or duplicating the entity encoder.
brokerRequestDigestForAction
  :: BrokerRoute
  -> BrokerActionRequest
  -> Either BrokerError RequestDigest
brokerRequestDigestForAction route action = do
  request <-
    either
      (Left . BrokerPayload . renderBrokerProtocolError)
      Right
      (mkBrokerControllerRequest route action)
  Right (requestDigestForBytes (encodeBrokerControllerRequest request))

brokerRequestDigestForPkiAction
  :: BrokerActionRequest
  -> PkiIssueRequest
  -> RequestDigest
brokerRequestDigestForPkiAction action request =
  requestDigestForBytes
    (encodeBrokerControllerRequest (mkBrokerPkiControllerRequest action request))

brokerRequestDigestForChildCustodyFinalize
  :: BrokerActionRequest
  -> FederationRegistrationCompletion
  -> RequestDigest
brokerRequestDigestForChildCustodyFinalize action completion =
  requestDigestForBytes
    ( encodeBrokerControllerRequest
        (mkBrokerChildCustodyFinalizeRequest action completion)
    )

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
targetWriteConfig = defaultHttpConfig {httpRequestTimeoutMicros = 5 * 60 * 1000 * 1000}
