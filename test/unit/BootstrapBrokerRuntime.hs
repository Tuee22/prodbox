{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic real-loopback conformance for the bounded Bootstrap Broker
-- HTTP server and its production-shaped fake interpreter.
module BootstrapBrokerRuntime
  ( bootstrapBrokerRuntimeSuite
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, waitCatch, withAsync)
import Control.Concurrent.STM
  ( TMVar
  , TVar
  , atomically
  , modifyTVar'
  , newEmptyTMVarIO
  , newTVarIO
  , putTMVar
  , readTMVar
  , readTVarIO
  , tryPutTMVar
  , writeTVar
  )
import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Char (toLower)
import Data.Text.Encoding qualified as TextEncoding
import Network.Socket
  ( Family (AF_INET)
  , HostAddress
  , PortNumber
  , ShutdownCmd (ShutdownSend)
  , SockAddr (SockAddrInet)
  , Socket
  , SocketType (Stream)
  , bind
  , close
  , connect
  , defaultProtocol
  , getSocketName
  , shutdown
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Fake qualified as Fake
import Prodbox.Bootstrap.Broker.Request qualified as Request
import Prodbox.Bootstrap.Broker.Routes qualified as Routes
import Prodbox.Bootstrap.Broker.Server qualified as Server
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import System.Timeout (timeout)
import TestSupport
import Text.Read (readMaybe)

bootstrapBrokerRuntimeSuite :: SuiteBuilder ()
bootstrapBrokerRuntimeSuite = do
  routeConformanceSuite
  authenticationSuite
  fakeMetadataSuite
  idempotencySuite
  wireBoundsSuite
  drainSuite

-- Runtime fixture ---------------------------------------------------------

data RuntimeLimits = RuntimeLimits
  { runtimeQueueCapacity :: !Natural
  , runtimeMaximumBodyBytes :: !Natural
  , runtimeRequestDeadlineMilliseconds :: !Natural
  , runtimeDrainDeadlineMilliseconds :: !Natural
  }

defaultRuntimeLimits :: RuntimeLimits
defaultRuntimeLimits =
  RuntimeLimits
    { runtimeQueueCapacity = 32
    , runtimeMaximumBodyBytes = 4096
    , runtimeRequestDeadlineMilliseconds = 5000
    , runtimeDrainDeadlineMilliseconds = 1000
    }

data TestRuntime = TestRuntime
  { testRuntimePort :: !PortNumber
  , testRuntimeHandle :: !Server.BrokerServerHandle
  }

data RuntimeCapture = RuntimeCapture
  { captureInvocations :: !(TVar [CapturedInvocation])
  , captureAuthentications :: !(TVar [CapturedAuthentication])
  }

data CapturedInvocation = CapturedInvocation
  { capturedRoute :: !Routes.BrokerRoute
  , capturedCallerAddress :: !Settings.LoopbackAddress
  , capturedAuthentication :: !Server.BrokerRequestAuthentication
  , capturedBody :: !(Maybe ByteString)
  }
  deriving (Eq, Show)

data CapturedAuthentication = CapturedAuthentication
  { capturedClaimedIdentity :: !Request.BrokerServiceIdentity
  , capturedAuthenticationCaller :: !Settings.LoopbackAddress
  , capturedCredential :: !ByteString
  }
  deriving (Eq, Show)

withFakeRuntime
  :: Fake.FakeBrokerState
  -> RuntimeLimits
  -> (TestRuntime -> Fake.FakeBroker -> RuntimeCapture -> Expectation)
  -> Expectation
withFakeRuntime initialState limits assertion = do
  fake <- Fake.newFakeBrokerInState initialState
  invocations <- newTVarIO []
  authentications <- newTVarIO []
  let capture = RuntimeCapture invocations authentications
      authenticator = recordingAuthenticator authentications
      interpreter = recordingFakeInterpreter invocations fake
  withTestRuntime limits authenticator interpreter $ \runtime ->
    assertion runtime fake capture

recordingAuthenticator
  :: TVar [CapturedAuthentication]
  -> Server.BrokerAuthenticator
recordingAuthenticator captured =
  Server.BrokerAuthenticator $ \request -> do
    let observation =
          CapturedAuthentication
            { capturedClaimedIdentity =
                Server.authenticationClaimedIdentity request
            , capturedAuthenticationCaller =
                Server.authenticationCallerAddress request
            , capturedCredential =
                Server.withBrokerTransportCredential
                  (Server.authenticationCredential request)
                  id
            }
    atomically (modifyTVar' captured (observation :))
    Server.authenticateBrokerCaller Fake.fakeBrokerAuthenticator request

recordingFakeInterpreter
  :: TVar [CapturedInvocation]
  -> Fake.FakeBroker
  -> Server.BrokerInterpreter
recordingFakeInterpreter captured fake =
  Server.BrokerInterpreter $ \context route body -> do
    let observation =
          CapturedInvocation
            { capturedRoute = route
            , capturedCallerAddress = Server.brokerRequestCallerAddress context
            , capturedAuthentication =
                Server.brokerRequestAuthentication context
            , capturedBody =
                fmap (\value -> Server.withBrokerRequestBody value id) body
            }
    atomically (modifyTVar' captured (observation :))
    Server.interpretBrokerRequest
      (Fake.fakeBrokerInterpreter fake)
      context
      route
      body

clearRuntimeCapture :: RuntimeCapture -> IO ()
clearRuntimeCapture capture =
  atomically $ do
    writeTVar (captureInvocations capture) []
    writeTVar (captureAuthentications capture) []

readRuntimeInvocations :: RuntimeCapture -> IO [CapturedInvocation]
readRuntimeInvocations capture =
  reverse <$> readTVarIO (captureInvocations capture)

readRuntimeAuthentications :: RuntimeCapture -> IO [CapturedAuthentication]
readRuntimeAuthentications capture =
  reverse <$> readTVarIO (captureAuthentications capture)

withTestRuntime
  :: RuntimeLimits
  -> Server.BrokerAuthenticator
  -> Server.BrokerInterpreter
  -> (TestRuntime -> Expectation)
  -> Expectation
withTestRuntime limits authenticator interpreter assertion =
  withSocketsDo
    ( bracket
        (startTestRuntime 8 limits authenticator interpreter)
        stopTestRuntime
        assertion
    )

startTestRuntime
  :: Int
  -> RuntimeLimits
  -> Server.BrokerAuthenticator
  -> Server.BrokerInterpreter
  -> IO TestRuntime
startTestRuntime remainingAttempts limits authenticator interpreter
  | remainingAttempts <= 0 =
      testFailure "could not reserve an ephemeral Bootstrap Broker loopback port"
  | otherwise = do
      port <- reserveEphemeralLoopbackPort
      settings <- validatedRuntimeSettings port limits
      started <- Server.startBrokerServer settings authenticator interpreter
      case started of
        Right handle ->
          pure
            TestRuntime
              { testRuntimePort = port
              , testRuntimeHandle = handle
              }
        Left Server.BrokerListenerUnavailable ->
          startTestRuntime
            (remainingAttempts - 1)
            limits
            authenticator
            interpreter
        Left err -> testFailure (Server.renderBrokerServerError err)

stopTestRuntime :: TestRuntime -> IO ()
stopTestRuntime runtime = do
  Server.beginBrokerDrain (testRuntimeHandle runtime)
  stopped <- timeout 2_000_000 (Server.waitBrokerServer (testRuntimeHandle runtime))
  case stopped of
    Just _ -> pure ()
    Nothing -> do
      Server.forceBrokerDrain (testRuntimeHandle runtime)
      void (timeout 2_000_000 (Server.waitBrokerServer (testRuntimeHandle runtime)))

reserveEphemeralLoopbackPort :: IO PortNumber
reserveEphemeralLoopbackPort =
  bracket
    (socket AF_INET Stream defaultProtocol)
    close
    ( \listenerSocket -> do
        bind listenerSocket (SockAddrInet 0 literalIpv4Loopback)
        boundAddress <- getSocketName listenerSocket
        case boundAddress of
          SockAddrInet port _
            | port /= 0 -> pure port
          _ -> testFailure "ephemeral port reservation was not IPv4 loopback"
    )

validatedRuntimeSettings
  :: PortNumber
  -> RuntimeLimits
  -> IO Settings.BootstrapBrokerSettings
validatedRuntimeSettings port limits =
  case Settings.validateBootstrapBrokerConfig (runtimeConfig port limits) of
    Left err -> testFailure (Settings.renderBootstrapBrokerSettingsError err)
    Right settings -> do
      unless
        ( Settings.brokerListenAddress (Settings.brokerListener settings)
            == Settings.LoopbackIpv4
            && Settings.brokerListenPort (Settings.brokerListener settings)
              == fromIntegral port
        )
        (testFailure "validated runtime settings changed the literal loopback listener")
      pure settings

runtimeConfig :: PortNumber -> RuntimeLimits -> Settings.BootstrapBrokerConfigDhall
runtimeConfig port limits =
  Settings.BootstrapBrokerConfigDhall
    { Settings.schemaVersion = 1
    , Settings.cluster_id = "runtime-test-cluster"
    , Settings.vault_address = "http://127.0.0.1:8200"
    , Settings.service_identity = TextEncoding.decodeUtf8 testServiceIdentity
    , Settings.listener =
        Settings.BrokerListenerDhall
          { Settings.listen_host = "127.0.0.1"
          , Settings.listen_port = fromIntegral port
          }
    , Settings.bootstrap_store =
        Settings.BootstrapStoreDhall
          { Settings.store_endpoint = "http://127.0.0.1:9000"
          , Settings.store_bucket = "runtime-bootstrap-state"
          , Settings.vault_storage_generation_key = "vault-storage-generation"
          , Settings.bootstrap_session_fence_key = "bootstrap-session-fence"
          , Settings.prepared_init_envelope_key = "prepared-init-envelope"
          , Settings.encrypted_init_response_key = "encrypted-init-response"
          , Settings.final_unlock_bundle_key = "final-unlock-bundle"
          , Settings.child_custody_receipt_key = "child-custody-receipt"
          , Settings.child_recovery_delivery_key = "child-recovery-delivery"
          , Settings.root_init_journal_key = "root-init-journal"
          , Settings.root_session_journal_key = "root-session-journal"
          , Settings.child_custody_journal_key = "child-custody-journal"
          , Settings.child_recovery_journal_key = "child-recovery-journal"
          , Settings.post_unseal_handoff_key = "post-unseal-handoff"
          , Settings.secret_worker_checkpoint_key = "secret-worker-checkpoint"
          }
    , Settings.limits =
        Settings.BrokerLimitsDhall
          { Settings.queue_capacity = runtimeQueueCapacity limits
          , Settings.max_request_body_bytes = runtimeMaximumBodyBytes limits
          , Settings.request_deadline_milliseconds =
              runtimeRequestDeadlineMilliseconds limits
          , Settings.drain_deadline_milliseconds =
              runtimeDrainDeadlineMilliseconds limits
          }
    }

testServiceIdentity :: ByteString
testServiceIdentity = "runtime-test-service"

literalIpv4Loopback :: HostAddress
literalIpv4Loopback = tupleToHostAddress (127, 0, 0, 1)

testFailure :: String -> IO value
testFailure = throwIO . userError

-- Raw HTTP boundary -------------------------------------------------------

data RawHttpRequest = RawHttpRequest
  { rawRequestMethod :: !ByteString
  , rawRequestPath :: !String
  , rawRequestHeaders :: ![(ByteString, ByteString)]
  , rawRequestBody :: !ByteString
  , rawDeclaredContentLength :: !(Maybe Int)
  }
  deriving (Eq, Show)

data HttpResponse = HttpResponse
  { responseStatus :: !Int
  , responseBody :: !ByteString
  }
  deriving (Eq, Show)

canonicalRouteRequest
  :: ByteString
  -> Routes.BrokerRoute
  -> ByteString
  -> RawHttpRequest
canonicalRouteRequest key route body =
  RawHttpRequest
    { rawRequestMethod = renderMethod (Routes.brokerRouteMethod route)
    , rawRequestPath = Routes.brokerRoutePath route
    , rawRequestHeaders =
        if isProbeRoute route
          then []
          else canonicalRpcHeaders key body
    , rawRequestBody = body
    , rawDeclaredContentLength = Nothing
    }

canonicalRpcHeaders :: ByteString -> ByteString -> [(ByteString, ByteString)]
canonicalRpcHeaders key body =
  [ ("X-Prodbox-Service-Identity", testServiceIdentity)
  ,
    ( "X-Prodbox-Transport-Credential"
    , Fake.fakeBrokerTransportCredentialHeaderValue
    )
  , ("Idempotency-Key", key)
  , ("X-Prodbox-Request-Sha256", digestBytes body)
  ]

digestBytes :: ByteString -> ByteString
digestBytes =
  TextEncoding.encodeUtf8
    . Request.renderRequestDigest
    . Request.requestDigestForBytes

renderMethod :: Routes.BrokerHttpMethod -> ByteString
renderMethod method = case method of
  Routes.BrokerGet -> "GET"
  Routes.BrokerPost -> "POST"

otherMethodBytes :: Routes.BrokerHttpMethod -> ByteString
otherMethodBytes method = case method of
  Routes.BrokerGet -> "POST"
  Routes.BrokerPost -> "GET"

requestWithBody :: ByteString -> RawHttpRequest -> RawHttpRequest
requestWithBody body request =
  setOptionalHeader
    "x-prodbox-request-sha256"
    (digestBytes body)
    request
      { rawRequestBody = body
      , rawDeclaredContentLength = Nothing
      }

removeHeader :: ByteString -> RawHttpRequest -> RawHttpRequest
removeHeader name request =
  request
    { rawRequestHeaders =
        filter
          ((/= normalizeHeaderName name) . normalizeHeaderName . fst)
          (rawRequestHeaders request)
    }

setHeader :: ByteString -> ByteString -> RawHttpRequest -> RawHttpRequest
setHeader name value request =
  request
    { rawRequestHeaders =
        (name, value) : rawRequestHeaders (removeHeader name request)
    }

setOptionalHeader :: ByteString -> ByteString -> RawHttpRequest -> RawHttpRequest
setOptionalHeader name value request =
  if any
    ((== normalizeHeaderName name) . normalizeHeaderName . fst)
    (rawRequestHeaders request)
    then setHeader name value request
    else request

normalizeHeaderName :: ByteString -> ByteString
normalizeHeaderName = ByteString8.map toLower

renderRawHttpRequest :: RawHttpRequest -> ByteString
renderRawHttpRequest request =
  ByteString.concat
    [ rawRequestMethod request
    , " "
    , ByteString8.pack (rawRequestPath request)
    , " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    , ByteString.concat (map renderHeader (rawRequestHeaders request))
    , "Content-Length: "
    , ByteString8.pack (show declaredLength)
    , "\r\nConnection: close\r\n\r\n"
    , rawRequestBody request
    ]
 where
  declaredLength =
    case rawDeclaredContentLength request of
      Just value -> value
      Nothing -> ByteString.length (rawRequestBody request)
  renderHeader (name, value) = name <> ": " <> value <> "\r\n"

exchangeRequest :: TestRuntime -> RawHttpRequest -> IO HttpResponse
exchangeRequest runtime request =
  exchangeWire runtime (renderRawHttpRequest request)

exchangeWire :: TestRuntime -> ByteString -> IO HttpResponse
exchangeWire runtime wire =
  bracket
    (openLoopbackClient (testRuntimePort runtime))
    close
    (\clientSocket -> exchangeWireConnected clientSocket wire)

openLoopbackClient :: PortNumber -> IO Socket
openLoopbackClient port = do
  clientSocket <- socket AF_INET Stream defaultProtocol
  connect clientSocket (SockAddrInet port literalIpv4Loopback)
  pure clientSocket

exchangeConnected :: Socket -> RawHttpRequest -> IO HttpResponse
exchangeConnected clientSocket request =
  exchangeWireConnected clientSocket (renderRawHttpRequest request)

exchangeWireConnected :: Socket -> ByteString -> IO HttpResponse
exchangeWireConnected clientSocket wire = do
  sendAll clientSocket wire
  shutdown clientSocket ShutdownSend
  received <- timeout 2_000_000 (receiveAll clientSocket)
  case received of
    Nothing -> testFailure "timed out reading Bootstrap Broker response"
    Just bytes ->
      case parseHttpResponse bytes of
        Left err -> testFailure err
        Right response -> pure response

receiveAll :: Socket -> IO ByteString
receiveAll clientSocket = collect []
 where
  collect chunks = do
    bytes <- recv clientSocket 4096
    if ByteString.null bytes
      then pure (ByteString.concat (reverse chunks))
      else collect (bytes : chunks)

parseHttpResponse :: ByteString -> Either String HttpResponse
parseHttpResponse wire = do
  let (headerBlock, delimiterAndBody) = ByteString.breakSubstring "\r\n\r\n" wire
  if ByteString.null delimiterAndBody
    then Left "Bootstrap Broker response omitted the HTTP header delimiter"
    else do
      status <- parseStatusLine headerBlock
      Right
        HttpResponse
          { responseStatus = status
          , responseBody = ByteString.drop 4 delimiterAndBody
          }

parseStatusLine :: ByteString -> Either String Int
parseStatusLine headerBlock =
  case ByteString8.lines headerBlock of
    statusLine : _ ->
      case ByteString8.words statusLine of
        _version : rawStatus : _ ->
          maybe
            (Left "Bootstrap Broker returned a non-numeric HTTP status")
            Right
            (readMaybe (ByteString8.unpack rawStatus))
        _ -> Left "Bootstrap Broker returned a malformed HTTP status line"
    [] -> Left "Bootstrap Broker returned an empty HTTP response"

-- All-route conformance ---------------------------------------------------

routeConformanceSuite :: SuiteBuilder ()
routeConformanceSuite =
  describe "Sprint 2.33 Bootstrap Broker real-loopback route conformance" $ do
    it "covers the closed fifteen-route registry" $
      length Routes.allBrokerRoutes `shouldBe` 15
    forM_ Routes.allBrokerRoutes $ \route ->
      it ("projects exact method, path, body, and authentication for " ++ show route) $
        exerciseRouteConformance route

exerciseRouteConformance :: Routes.BrokerRoute -> Expectation
exerciseRouteConformance route =
  withFakeRuntime (routeInitialState route) defaultRuntimeLimits $
    \runtime fake capture -> do
      prepareRoutePrerequisites runtime fake route
      Fake.clearFakeBrokerActions fake
      clearRuntimeCapture capture
      body <- Fake.fakeBrokerRequestBodyFor fake route
      let canonical = canonicalRouteRequest (routeKey route) route body
          wrongMethod =
            canonical
              { rawRequestMethod =
                  otherMethodBytes (Routes.brokerRouteMethod route)
              }
          wrongPath = canonical {rawRequestPath = rawRequestPath canonical ++ "/wrong"}
          wrongBody = case Routes.brokerRouteBodyRequirement route of
            Routes.BrokerBodyForbidden -> requestWithBody "unexpected-body" canonical
            Routes.BrokerBodyRequired -> requestWithBody "" canonical
      methodResponse <- exchangeRequest runtime wrongMethod
      pathResponse <- exchangeRequest runtime wrongPath
      bodyResponse <- exchangeRequest runtime wrongBody
      response <- exchangeRequest runtime canonical
      responseStatus methodResponse `shouldBe` 405
      responseStatus pathResponse `shouldBe` 404
      responseStatus bodyResponse `shouldBe` 400
      responseStatus response `shouldBe` routeExpectedStatus route
      invocations <- readRuntimeInvocations capture
      authentications <- readRuntimeAuthentications capture
      assertCanonicalInvocation route body invocations authentications
      actions <- Fake.readFakeBrokerActions fake
      actions `shouldSatisfy` isSuccessfulRouteTrace route

prepareRoutePrerequisites
  :: TestRuntime
  -> Fake.FakeBroker
  -> Routes.BrokerRoute
  -> IO ()
prepareRoutePrerequisites runtime fake route =
  case route of
    Routes.BrokerChildRecoveryDeliver ->
      sendSuccessfulSetup runtime fake "setup-child-custody" Routes.BrokerChildCustodyCommit
    Routes.BrokerChildRecoveryObserve -> do
      sendSuccessfulSetup runtime fake "setup-child-custody" Routes.BrokerChildCustodyCommit
      sendSuccessfulSetup runtime fake "setup-child-delivery" Routes.BrokerChildRecoveryDeliver
    _ -> pure ()

sendSuccessfulSetup
  :: TestRuntime
  -> Fake.FakeBroker
  -> ByteString
  -> Routes.BrokerRoute
  -> IO ()
sendSuccessfulSetup runtime fake key route = do
  body <- Fake.fakeBrokerRequestBodyFor fake route
  response <- exchangeRequest runtime (canonicalRouteRequest key route body)
  unless
    (responseStatus response == 200 || responseStatus response == 202)
    (testFailure ("fake route prerequisite failed for " ++ show route))

routeInitialState :: Routes.BrokerRoute -> Fake.FakeBrokerState
routeInitialState route = case route of
  Routes.BrokerHealth -> Fake.FakeEmpty
  Routes.BrokerReadiness -> Fake.FakeEmpty
  Routes.BrokerVaultStatus -> Fake.FakeEmpty
  Routes.BrokerVaultInitialize -> Fake.FakeEmpty
  Routes.BrokerVaultUnseal -> Fake.FakeInitializedSealed
  Routes.BrokerVaultSeal -> Fake.FakeUnsealed
  Routes.BrokerVaultRotateUnlockBundle -> Fake.FakeInitializedSealed
  Routes.BrokerVaultRotateTransitKey -> Fake.FakeUnsealed
  Routes.BrokerVaultBaselineReconcile -> Fake.FakeUnsealed
  Routes.BrokerVaultPkiStatus -> Fake.FakeUnsealed
  Routes.BrokerVaultPkiIssueTestCertificate -> Fake.FakeUnsealed
  Routes.BrokerVaultResetAmbiguousInitialization -> Fake.FakeAmbiguousInitialization
  Routes.BrokerChildCustodyCommit -> Fake.FakeInitializedSealed
  Routes.BrokerChildRecoveryDeliver -> Fake.FakeInitializedSealed
  Routes.BrokerChildRecoveryObserve -> Fake.FakeInitializedSealed

routeExpectedStatus :: Routes.BrokerRoute -> Int
routeExpectedStatus route = case route of
  Routes.BrokerHealth -> 200
  Routes.BrokerReadiness -> 200
  Routes.BrokerVaultStatus -> 200
  Routes.BrokerVaultInitialize -> 202
  Routes.BrokerVaultUnseal -> 202
  Routes.BrokerVaultSeal -> 202
  Routes.BrokerVaultRotateUnlockBundle -> 200
  Routes.BrokerVaultRotateTransitKey -> 200
  Routes.BrokerVaultBaselineReconcile -> 202
  Routes.BrokerVaultPkiStatus -> 200
  Routes.BrokerVaultPkiIssueTestCertificate -> 200
  Routes.BrokerVaultResetAmbiguousInitialization -> 202
  Routes.BrokerChildCustodyCommit -> 202
  Routes.BrokerChildRecoveryDeliver -> 202
  Routes.BrokerChildRecoveryObserve -> 200

routeKey :: Routes.BrokerRoute -> ByteString
routeKey route = "route-" <> ByteString8.pack (map toLower (show route))

isProbeRoute :: Routes.BrokerRoute -> Bool
isProbeRoute route = case route of
  Routes.BrokerHealth -> True
  Routes.BrokerReadiness -> True
  _ -> False

assertCanonicalInvocation
  :: Routes.BrokerRoute
  -> ByteString
  -> [CapturedInvocation]
  -> [CapturedAuthentication]
  -> Expectation
assertCanonicalInvocation route body invocations authentications = do
  case invocations of
    [invocation] -> do
      capturedRoute invocation `shouldBe` route
      capturedCallerAddress invocation `shouldBe` Settings.LoopbackIpv4
      capturedBody invocation
        `shouldBe` case Routes.brokerRouteBodyRequirement route of
          Routes.BrokerBodyForbidden -> Nothing
          Routes.BrokerBodyRequired -> Just body
      case (isProbeRoute route, capturedAuthentication invocation) of
        (True, Server.BrokerProbeRequest) -> pure ()
        (False, Server.BrokerAuthenticatedRequest identity) ->
          Request.renderBrokerServiceIdentity identity
            `shouldBe` TextEncoding.decodeUtf8 testServiceIdentity
        _ -> expectationFailure "route received the wrong authentication context"
    _ -> expectationFailure ("expected one interpreter invocation, got " ++ show invocations)
  case (isProbeRoute route, authentications) of
    (True, []) -> pure ()
    (False, [authentication]) -> do
      Request.renderBrokerServiceIdentity (capturedClaimedIdentity authentication)
        `shouldBe` TextEncoding.decodeUtf8 testServiceIdentity
      capturedAuthenticationCaller authentication `shouldBe` Settings.LoopbackIpv4
      capturedCredential authentication
        `shouldBe` Fake.fakeBrokerTransportCredentialHeaderValue
    _ ->
      expectationFailure
        ("unexpected authenticator calls for " ++ show route ++ ": " ++ show authentications)

isSuccessfulRouteTrace :: Routes.BrokerRoute -> [Fake.FakeBrokerAction] -> Bool
isSuccessfulRouteTrace route actions = case actions of
  [ Fake.FakeActionStarted startedRoute before
    , Fake.FakeActionTransitionCommitted committedRoute committedBefore after
    , Fake.FakeActionCompleted completedRoute completedAfter
    ] ->
      startedRoute == route
        && committedRoute == route
        && completedRoute == route
        && before == committedBefore
        && after == completedAfter
  _ -> False

-- Authentication and fake metadata --------------------------------------

authenticationSuite :: SuiteBuilder ()
authenticationSuite =
  describe "Sprint 2.33 Bootstrap Broker loopback authentication envelope" $ do
    it "accepts the exact injected identity, credential, and entity SHA" $
      withFakeRuntime Fake.FakeUnsealed defaultRuntimeLimits $
        \runtime fake capture -> do
          body <- Fake.fakeBrokerRequestBodyFor fake Routes.BrokerVaultStatus
          let request = canonicalRouteRequest "valid-auth-envelope" Routes.BrokerVaultStatus body
          response <- exchangeRequest runtime request
          responseStatus response `shouldBe` 200
          authentications <- readRuntimeAuthentications capture
          invocations <- readRuntimeInvocations capture
          assertCanonicalInvocation Routes.BrokerVaultStatus body invocations authentications

    it "refuses every missing or wrong credential, identity, and digest before interpretation" $
      withFakeRuntime Fake.FakeUnsealed defaultRuntimeLimits $
        \runtime fake capture -> do
          body <- Fake.fakeBrokerRequestBodyFor fake Routes.BrokerVaultStatus
          let valid = canonicalRouteRequest "invalid-auth-envelope" Routes.BrokerVaultStatus body
              cases :: [(String, Int, RawHttpRequest)]
              cases =
                [ ("missing identity", 400, removeHeader "x-prodbox-service-identity" valid)
                , ("wrong identity", 401, setHeader "x-prodbox-service-identity" "other-service" valid)
                , ("missing credential", 400, removeHeader "x-prodbox-transport-credential" valid)
                , ("wrong credential", 401, setHeader "x-prodbox-transport-credential" "wrong" valid)
                , ("missing digest", 400, removeHeader "x-prodbox-request-sha256" valid)
                , ("wrong digest", 400, setHeader "x-prodbox-request-sha256" (ByteString.replicate 64 98) valid)
                ]
          forM_ cases $ \(label, expectedStatus, request) -> do
            response <- exchangeRequest runtime request
            (label, responseStatus response) `shouldBe` (label, expectedStatus)
          readRuntimeInvocations capture `shouldReturn` []
          Fake.readFakeBrokerActions fake `shouldReturn` []

fakeMetadataSuite :: SuiteBuilder ()
fakeMetadataSuite =
  describe "Sprint 2.33 production-shaped fake request metadata" $ do
    it "refuses malformed metadata without a state transition" $
      withFakeRuntime Fake.FakeUnsealed defaultRuntimeLimits $
        \runtime fake _capture -> do
          let route = Routes.BrokerVaultSeal
              request =
                canonicalRouteRequest "malformed-fake-metadata" route "{"
          response <- exchangeRequest runtime request
          responseStatus response `shouldBe` 400
          responseBody response `shouldBe` "{\"error\":\"malformed_request_metadata\"}"
          Fake.readFakeBrokerActions fake
            `shouldReturn` [ Fake.FakeActionStarted route Fake.FakeUnsealed
                           , Fake.FakeActionRefused
                               route
                               Fake.FakeUnsealed
                               Fake.FakeMalformedRequestMetadata
                           ]

    it "refuses metadata bound to a different fixed route" $
      withFakeRuntime Fake.FakeUnsealed defaultRuntimeLimits $
        \runtime fake _capture -> do
          let route = Routes.BrokerVaultSeal
          wrongBody <- Fake.fakeBrokerRequestBodyFor fake Routes.BrokerVaultUnseal
          response <-
            exchangeRequest
              runtime
              (canonicalRouteRequest "wrong-route-fake-metadata" route wrongBody)
          responseStatus response `shouldBe` 400
          responseBody response `shouldBe` "{\"error\":\"wrong_route_metadata\"}"
          Fake.readFakeBrokerActions fake
            `shouldReturn` [ Fake.FakeActionStarted route Fake.FakeUnsealed
                           , Fake.FakeActionRefused
                               route
                               Fake.FakeUnsealed
                               Fake.FakeWrongRouteMetadata
                           ]

-- Runtime idempotency -----------------------------------------------------

idempotencySuite :: SuiteBuilder ()
idempotencySuite =
  describe "Sprint 2.33 Bootstrap Broker runtime idempotency" $
    it "coalesces in-flight replay, caches completion, and conflicts on rebinding with one fake action" $ do
      fake <- Fake.newFakeBrokerInState Fake.FakeEmpty
      entered <- newEmptyTMVarIO
      release <- newEmptyTMVarIO
      interpreterCalls <- newTVarIO (0 :: Natural)
      let interpreter = gatedFakeInterpreter fake entered release interpreterCalls
      withTestRuntime defaultRuntimeLimits Fake.fakeBrokerAuthenticator interpreter $
        \runtime -> do
          body <- Fake.fakeBrokerRequestBodyFor fake Routes.BrokerVaultInitialize
          let key = "idempotency-exactly-once"
              request = canonicalRouteRequest key Routes.BrokerVaultInitialize body
          withAsync (exchangeRequest runtime request) $ \firstRequest -> do
            awaitSignal "first idempotent request did not enter the interpreter" entered
            withAsync (exchangeRequest runtime request) $ \replayRequest -> do
              awaitSnapshot
                runtime
                ( \snapshot ->
                    Server.snapshotActiveConnections snapshot >= 2
                      && Server.snapshotIdempotencyEntries snapshot == 1
                )
              atomically (putTMVar release ())
              firstResponse <- wait firstRequest
              replayResponse <- wait replayRequest
              responseStatus firstResponse `shouldBe` 202
              replayResponse `shouldBe` firstResponse
          cachedResponse <- exchangeRequest runtime request
          responseStatus cachedResponse `shouldBe` 202
          changedBodyResponse <-
            exchangeRequest runtime (requestWithBody (body <> " ") request)
          responseStatus changedBodyResponse `shouldBe` 409
          let changedOperation =
                canonicalRouteRequest key Routes.BrokerVaultUnseal body
          changedOperationResponse <- exchangeRequest runtime changedOperation
          responseStatus changedOperationResponse `shouldBe` 409
          readTVarIO interpreterCalls `shouldReturn` 1
          actions <- Fake.readFakeBrokerActions fake
          actions
            `shouldSatisfy` isSuccessfulRouteTrace Routes.BrokerVaultInitialize
          snapshot <- Server.brokerServerSnapshot (testRuntimeHandle runtime)
          Server.snapshotIdempotencyEntries snapshot `shouldBe` 1

gatedFakeInterpreter
  :: Fake.FakeBroker
  -> TMVar ()
  -> TMVar ()
  -> TVar Natural
  -> Server.BrokerInterpreter
gatedFakeInterpreter fake entered release calls =
  Server.BrokerInterpreter $ \context route body -> do
    atomically $ do
      modifyTVar' calls (+ 1)
      void (tryPutTMVar entered ())
    atomically (readTMVar release)
    Server.interpretBrokerRequest (Fake.fakeBrokerInterpreter fake) context route body

awaitSignal :: String -> TMVar () -> IO ()
awaitSignal failureMessage signal = do
  observed <- timeout 2_000_000 (atomically (readTMVar signal))
  case observed of
    Just () -> pure ()
    Nothing -> testFailure failureMessage

awaitSnapshot
  :: TestRuntime
  -> (Server.BrokerServerSnapshot -> Bool)
  -> IO ()
awaitSnapshot runtime predicate = go (2000 :: Int)
 where
  go attempts
    | attempts <= 0 = testFailure "Bootstrap Broker runtime did not reach the expected snapshot"
    | otherwise = do
        snapshot <- Server.brokerServerSnapshot (testRuntimeHandle runtime)
        if predicate snapshot
          then pure ()
          else do
            threadDelay 1000
            go (attempts - 1)

-- Wire bounds -------------------------------------------------------------

wireBoundsSuite :: SuiteBuilder ()
wireBoundsSuite =
  describe "Sprint 2.33 Bootstrap Broker HTTP bounds" $ do
    it "accepts the configured body maximum and rejects max plus one at header preflight" $ do
      invocations <- newTVarIO []
      let limits = defaultRuntimeLimits {runtimeMaximumBodyBytes = 256}
          interpreter = recordingAcceptingInterpreter invocations
      withTestRuntime limits Fake.fakeBrokerAuthenticator interpreter $ \runtime -> do
        let exactBody = ByteString.replicate 256 120
            exactRequest =
              canonicalRouteRequest
                "body-bound-exact"
                Routes.BrokerVaultInitialize
                exactBody
            oversizedRequest =
              ( canonicalRouteRequest
                  "body-bound-over"
                  Routes.BrokerVaultInitialize
                  (ByteString.replicate 257 120)
              )
                { rawDeclaredContentLength = Just 257
                }
        exactResponse <- exchangeRequest runtime exactRequest
        responseStatus exactResponse `shouldBe` 202
        oversizedResponse <- exchangeRequest runtime oversizedRequest
        responseStatus oversizedResponse `shouldBe` 413
        captured <- reverse <$> readTVarIO invocations
        captured
          `shouldBe` [ CapturedInvocation
                         Routes.BrokerVaultInitialize
                         Settings.LoopbackIpv4
                         (Server.BrokerAuthenticatedRequest (validatedServiceIdentity testServiceIdentity))
                         (Just exactBody)
                     ]

    it "rejects a header block beyond the compiled 16-KiB bound" $
      withFakeRuntime Fake.FakeEmpty defaultRuntimeLimits $
        \runtime fake capture -> do
          let headerPrefix = "GET /healthz HTTP/1.1\r\nX-Oversized: "
              headerWithoutDelimiter =
                ByteString.take
                  (16 * 1024)
                  (headerPrefix <> ByteString.replicate (16 * 1024) 120)
          response <- exchangeWire runtime headerWithoutDelimiter
          responseStatus response `shouldBe` 400
          readRuntimeInvocations capture `shouldReturn` []
          Fake.readFakeBrokerActions fake `shouldReturn` []

    it "rejects transport credentials beyond the compiled 4096-byte header bound" $
      withFakeRuntime Fake.FakeUnsealed defaultRuntimeLimits $
        \runtime fake capture -> do
          body <- Fake.fakeBrokerRequestBodyFor fake Routes.BrokerVaultStatus
          let request =
                setHeader
                  "x-prodbox-transport-credential"
                  (ByteString.replicate 4097 120)
                  (canonicalRouteRequest "credential-bound" Routes.BrokerVaultStatus body)
          response <- exchangeRequest runtime request
          responseStatus response `shouldBe` 401
          readRuntimeInvocations capture `shouldReturn` []
          Fake.readFakeBrokerActions fake `shouldReturn` []

recordingAcceptingInterpreter
  :: TVar [CapturedInvocation]
  -> Server.BrokerInterpreter
recordingAcceptingInterpreter captured =
  Server.BrokerInterpreter $ \context route body -> do
    let observation =
          CapturedInvocation
            { capturedRoute = route
            , capturedCallerAddress = Server.brokerRequestCallerAddress context
            , capturedAuthentication = Server.brokerRequestAuthentication context
            , capturedBody = fmap (\value -> Server.withBrokerRequestBody value id) body
            }
    atomically (modifyTVar' captured (observation :))
    pure (boundedReply Server.BrokerReplyAccepted "{\"accepted\":true}")

boundedReply :: Server.BrokerReplyStatus -> ByteString -> Server.BrokerReply
boundedReply status body =
  case Server.mkBrokerReply status body of
    Left err -> error err
    Right reply -> reply

validatedServiceIdentity :: ByteString -> Request.BrokerServiceIdentity
validatedServiceIdentity raw =
  case Request.mkBrokerServiceIdentity (TextEncoding.decodeUtf8 raw) of
    Left err -> error err
    Right identity -> identity

-- Graceful and forced drain ----------------------------------------------

drainSuite :: SuiteBuilder ()
drainSuite =
  describe "Sprint 2.33 Bootstrap Broker graceful and forced drain" $ do
    it "keeps liveness, closes readiness, refuses fresh RPCs, and settles admitted sockets" $
      withFakeRuntime Fake.FakeUnsealed defaultRuntimeLimits $
        \runtime fake _capture -> do
          statusBody <- Fake.fakeBrokerRequestBodyFor fake Routes.BrokerVaultStatus
          bracket (openLoopbackClient (testRuntimePort runtime)) close $ \healthSocket ->
            bracket (openLoopbackClient (testRuntimePort runtime)) close $ \readinessSocket ->
              bracket (openLoopbackClient (testRuntimePort runtime)) close $ \rpcSocket -> do
                awaitSnapshot
                  runtime
                  ((>= 3) . Server.snapshotActiveConnections)
                Server.beginBrokerDrain (testRuntimeHandle runtime)
                draining <- Server.brokerServerSnapshot (testRuntimeHandle runtime)
                Server.snapshotPhase draining `shouldBe` Server.BrokerDraining
                healthResponse <-
                  exchangeConnected
                    healthSocket
                    (canonicalRouteRequest "drain-health" Routes.BrokerHealth "")
                readinessResponse <-
                  exchangeConnected
                    readinessSocket
                    (canonicalRouteRequest "drain-readiness" Routes.BrokerReadiness "")
                rpcResponse <-
                  exchangeConnected
                    rpcSocket
                    (canonicalRouteRequest "drain-rpc" Routes.BrokerVaultStatus statusBody)
                responseStatus healthResponse `shouldBe` 200
                responseStatus readinessResponse `shouldBe` 503
                responseStatus rpcResponse `shouldBe` 503
          waitServerWithin runtime `shouldReturn` Right ()
          stopped <- Server.brokerServerSnapshot (testRuntimeHandle runtime)
          stopped
            `shouldBe` Server.BrokerServerSnapshot
              { Server.snapshotPhase = Server.BrokerStopped
              , Server.snapshotQueuedConnections = 0
              , Server.snapshotActiveConnections = 0
              , Server.snapshotIdempotencyEntries = 0
              }

    it "force-drains an admitted blocked interpreter on demand" $
      assertBlockedDrainOutcome
        defaultRuntimeLimits
        Server.forceBrokerDrain
        (Left Server.BrokerForcedShutdown)

    it "force-drains blocked work when the graceful drain deadline elapses" $
      assertBlockedDrainOutcome
        defaultRuntimeLimits {runtimeDrainDeadlineMilliseconds = 25}
        Server.beginBrokerDrain
        (Left Server.BrokerDrainDeadlineExceeded)

assertBlockedDrainOutcome
  :: RuntimeLimits
  -> (Server.BrokerServerHandle -> IO ())
  -> Either Server.BrokerServerError ()
  -> Expectation
assertBlockedDrainOutcome limits trigger expectedOutcome = do
  fake <- Fake.newFakeBrokerInState Fake.FakeEmpty
  entered <- newEmptyTMVarIO
  neverRelease <- newEmptyTMVarIO
  calls <- newTVarIO (0 :: Natural)
  let blockedInterpreter = gatedFakeInterpreter fake entered neverRelease calls
  withTestRuntime limits Fake.fakeBrokerAuthenticator blockedInterpreter $ \runtime ->
    withAsync
      (exchangeRequest runtime (canonicalRouteRequest "blocked-drain" Routes.BrokerHealth ""))
      $ \client -> do
        awaitSignal "blocked drain request did not enter the interpreter" entered
        trigger (testRuntimeHandle runtime)
        waitServerWithin runtime `shouldReturn` expectedOutcome
        void (waitCatch client)
        snapshot <- Server.brokerServerSnapshot (testRuntimeHandle runtime)
        Server.snapshotPhase snapshot `shouldBe` Server.BrokerStopped
        readTVarIO calls `shouldReturn` 1

waitServerWithin :: TestRuntime -> IO (Either Server.BrokerServerError ())
waitServerWithin runtime = do
  outcome <- timeout 2_000_000 (Server.waitBrokerServer (testRuntimeHandle runtime))
  case outcome of
    Nothing -> testFailure "Bootstrap Broker did not settle its drain"
    Just result -> pure result
