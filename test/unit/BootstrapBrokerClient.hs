{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | End-to-end composition proof for the target Bootstrap Broker client,
-- bounded loopback server, and deterministic typed interpreter.
module BootstrapBrokerClient
  ( bootstrapBrokerClientSuite
  )
where

import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, void)
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.Socket
  ( Family (AF_INET)
  , HostAddress
  , PortNumber
  , SockAddr (SockAddrInet)
  , SocketType (Stream)
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Prodbox.Bootstrap.Broker.Client qualified as Client
import Prodbox.Bootstrap.Broker.Fake qualified as Fake
import Prodbox.Bootstrap.Broker.Program qualified as Program
import Prodbox.Bootstrap.Broker.Request qualified as Request
import Prodbox.Bootstrap.Broker.Routes qualified as Routes
import Prodbox.Bootstrap.Broker.Server qualified as Server
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import Prodbox.Http.Client qualified as Http
import System.Timeout (timeout)
import TestSupport

bootstrapBrokerClientSuite :: SuiteBuilder ()
bootstrapBrokerClientSuite =
  describe "Sprint 2.33 target Client-Server-Fake composition" $ do
    it "sends exact auth/digest and replays initialization from cache" $
      withClientRuntime Fake.FakeEmpty $ \runtime fake -> do
        action <-
          Fake.fakeBrokerActionRequestFor fake Routes.BrokerVaultInitialize
        let context = validCallContext "target-client-initialize"
            endpoint = Client.brokerEndpointFromSettings (clientRuntimeSettings runtime)
        first <- Client.initializeVault endpoint context action
        second <- Client.initializeVault endpoint context action
        assertClientSuccess first
        second `shouldBe` first
        snapshot <- Fake.readFakeBrokerSnapshot fake
        Fake.fakeSnapshotState snapshot `shouldBe` Fake.FakeInitializedSealed
        Fake.fakeSnapshotActions snapshot
          `shouldSatisfy` successfulTraceFor Routes.BrokerVaultInitialize

    it "refuses an invalid target-client credential before invoking the fake" $
      withClientRuntime Fake.FakeEmpty $ \runtime fake -> do
        action <-
          Fake.fakeBrokerActionRequestFor fake Routes.BrokerVaultInitialize
        let endpoint = Client.brokerEndpointFromSettings (clientRuntimeSettings runtime)
            context =
              Client.mkBrokerCallContext
                validServiceIdentity
                (validIdempotencyKey "target-client-bad-auth")
                (validCredential "wrong-attestation")
        response <- Client.initializeVault endpoint context action
        response `shouldSatisfy` isHttpStatus 401
        Fake.readFakeBrokerActions fake `shouldReturn` []

    it "refuses idempotency-key rebinding on the target client path without a second interpreter action" $
      withClientRuntime Fake.FakeInitializedSealed $ \runtime fake -> do
        initializeAction <-
          Fake.fakeBrokerActionRequestFor fake Routes.BrokerVaultInitialize
        unsealAction <-
          Fake.fakeBrokerActionRequestFor fake Routes.BrokerVaultUnseal
        let endpoint = Client.brokerEndpointFromSettings (clientRuntimeSettings runtime)
            context = validCallContext "target-client-rebind"
        first <- Client.initializeVault endpoint context initializeAction
        rebound <- Client.unsealVault endpoint context unsealAction
        assertClientSuccess first
        rebound `shouldSatisfy` isHttpStatus 409
        actions <- Fake.readFakeBrokerActions fake
        actions `shouldSatisfy` successfulTraceFor Routes.BrokerVaultInitialize

    it "invokes every non-reset route through the exported target client" $
      withClientRuntime Fake.FakeEmpty $ \runtime fake ->
        forM_
          [ Routes.BrokerHealth
          , Routes.BrokerReadiness
          , Routes.BrokerVaultStatus
          , Routes.BrokerVaultInitialize
          , Routes.BrokerVaultUnseal
          , Routes.BrokerVaultRotateUnlockBundle
          , Routes.BrokerVaultRotateTransitKey
          , Routes.BrokerVaultBaselineReconcile
          , Routes.BrokerVaultPkiStatus
          , Routes.BrokerVaultPkiIssueTestCertificate
          , Routes.BrokerChildCustodyCommit
          , Routes.BrokerChildRecoveryDeliver
          , Routes.BrokerChildRecoveryObserve
          , Routes.BrokerVaultSeal
          ]
          $ \route -> do
            response <- invokeClientRoute runtime fake route
            case response of
              Right _ -> pure ()
              Left err ->
                expectationFailure
                  ("target client route " ++ show route ++ " failed: " ++ Client.renderBrokerError err)

    it "invokes ambiguous-init reset through the exported target client" $
      withClientRuntime Fake.FakeAmbiguousInitialization $ \runtime fake -> do
        response <-
          invokeClientRoute
            runtime
            fake
            Routes.BrokerVaultResetAmbiguousInitialization
        assertClientSuccess response
        snapshot <- Fake.readFakeBrokerSnapshot fake
        Fake.fakeSnapshotState snapshot `shouldBe` Fake.FakeEmpty

data ClientRuntime = ClientRuntime
  { clientRuntimeSettings :: !Settings.BootstrapBrokerSettings
  , clientRuntimeHandle :: !Server.BrokerServerHandle
  }

withClientRuntime
  :: Fake.FakeBrokerState
  -> (ClientRuntime -> Fake.FakeBroker -> Expectation)
  -> Expectation
withClientRuntime initialState assertion =
  withSocketsDo $ do
    fake <- Fake.newFakeBrokerInState initialState
    bracket
      (startClientRuntime 8 fake)
      stopClientRuntime
      (\runtime -> assertion runtime fake)

startClientRuntime :: Int -> Fake.FakeBroker -> IO ClientRuntime
startClientRuntime remainingAttempts fake
  | remainingAttempts <= 0 =
      testFailure "could not reserve an ephemeral target-client loopback port"
  | otherwise = do
      port <- reserveEphemeralLoopbackPort
      settings <- validatedClientSettings port
      started <-
        Server.startBrokerServer
          settings
          Fake.fakeBrokerAuthenticator
          (Fake.fakeBrokerInterpreter fake)
      case started of
        Right handle ->
          pure
            ClientRuntime
              { clientRuntimeSettings = settings
              , clientRuntimeHandle = handle
              }
        Left Server.BrokerListenerUnavailable ->
          startClientRuntime (remainingAttempts - 1) fake
        Left err -> testFailure (Server.renderBrokerServerError err)

stopClientRuntime :: ClientRuntime -> IO ()
stopClientRuntime runtime = do
  Server.beginBrokerDrain (clientRuntimeHandle runtime)
  stopped <- timeout 2_000_000 (Server.waitBrokerServer (clientRuntimeHandle runtime))
  case stopped of
    Just _ -> pure ()
    Nothing -> do
      Server.forceBrokerDrain (clientRuntimeHandle runtime)
      void (timeout 2_000_000 (Server.waitBrokerServer (clientRuntimeHandle runtime)))

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
          _ -> testFailure "ephemeral target-client port was not IPv4 loopback"
    )

validatedClientSettings :: PortNumber -> IO Settings.BootstrapBrokerSettings
validatedClientSettings port =
  case Settings.validateBootstrapBrokerConfig (clientConfig port) of
    Left err -> testFailure (Settings.renderBootstrapBrokerSettingsError err)
    Right settings -> pure settings

clientConfig :: PortNumber -> Settings.BootstrapBrokerConfigDhall
clientConfig port =
  Settings.BootstrapBrokerConfigDhall
    { Settings.schemaVersion = 1
    , Settings.cluster_id = "target-client-test-cluster"
    , Settings.vault_address = "http://127.0.0.1:8200"
    , Settings.service_identity =
        Request.renderBrokerServiceIdentity validServiceIdentity
    , Settings.listener =
        Settings.BrokerListenerDhall
          { Settings.listen_host = "127.0.0.1"
          , Settings.listen_port = fromIntegral port
          }
    , Settings.bootstrap_store =
        Settings.BootstrapStoreDhall
          { Settings.store_endpoint = "http://127.0.0.1:9000"
          , Settings.store_bucket = "target-client-bootstrap-state"
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
          { Settings.queue_capacity = 16
          , Settings.max_request_body_bytes = 4096
          , Settings.request_deadline_milliseconds = 5000
          , Settings.drain_deadline_milliseconds = 1000
          }
    }

validCallContext :: Text -> Client.BrokerCallContext
validCallContext rawKey =
  Client.mkBrokerCallContext
    validServiceIdentity
    (validIdempotencyKey rawKey)
    validTransportCredential

validServiceIdentity :: Request.BrokerServiceIdentity
validServiceIdentity =
  case Request.mkBrokerServiceIdentity "runtime-test-service" of
    Right identity -> identity
    Left err -> error ("invalid compiled target-client service identity: " ++ err)

validIdempotencyKey :: Text -> Request.IdempotencyKey
validIdempotencyKey rawKey =
  case Request.mkIdempotencyKey rawKey of
    Right key -> key
    Left err -> error ("invalid target-client idempotency key: " ++ err)

validTransportCredential :: Client.BrokerClientCredential
validTransportCredential =
  validCredential Fake.fakeBrokerTransportCredentialHeaderValue

validCredential :: ByteString -> Client.BrokerClientCredential
validCredential bytes =
  case Client.mkBrokerClientCredential bytes of
    Right credential -> credential
    Left err -> error ("invalid compiled target-client credential: " ++ err)

successfulTraceFor :: Routes.BrokerRoute -> [Fake.FakeBrokerAction] -> Bool
successfulTraceFor route actions = case actions of
  [ Fake.FakeActionStarted startedRoute _
    , Fake.FakeActionTransitionCommitted committedRoute _ _
    , Fake.FakeActionCompleted completedRoute _
    ] ->
      startedRoute == route
        && committedRoute == route
        && completedRoute == route
  _ -> False

isHttpStatus :: Int -> Either Client.BrokerError value -> Bool
isHttpStatus expected response = case response of
  Left (Client.BrokerTransport (Http.HttpStatus actual _)) -> actual == expected
  _ -> False

assertClientSuccess :: Either Client.BrokerError value -> Expectation
assertClientSuccess response = case response of
  Right _ -> pure ()
  Left err -> expectationFailure (Client.renderBrokerError err)

invokeClientRoute
  :: ClientRuntime
  -> Fake.FakeBroker
  -> Routes.BrokerRoute
  -> IO (Either Client.BrokerError Value)
invokeClientRoute runtime fake route = do
  action <- Fake.fakeBrokerActionRequestFor fake route
  let endpoint = Client.brokerEndpointFromSettings (clientRuntimeSettings runtime)
      context = validCallContext ("target-client-" <> Text.pack (show route))
  case route of
    Routes.BrokerHealth -> Client.queryBrokerHealth endpoint context
    Routes.BrokerReadiness -> Client.queryBrokerReadiness endpoint context
    Routes.BrokerVaultStatus -> Client.queryVaultStatus endpoint context
    Routes.BrokerVaultInitialize -> Client.initializeVault endpoint context action
    Routes.BrokerVaultUnseal -> Client.unsealVault endpoint context action
    Routes.BrokerVaultSeal -> Client.sealVault endpoint context action
    Routes.BrokerVaultRotateUnlockBundle ->
      Client.rotateVaultUnlockBundle endpoint context action
    Routes.BrokerVaultRotateTransitKey ->
      Client.rotateVaultTransitKey endpoint context action
    Routes.BrokerVaultBaselineReconcile ->
      Client.reconcileVaultBaseline endpoint context action
    Routes.BrokerVaultPkiStatus -> Client.queryVaultPkiStatus endpoint context
    Routes.BrokerVaultPkiIssueTestCertificate ->
      Client.issueVaultPkiTestCert
        endpoint
        context
        action
        (mustRight (Program.mkPkiIssueRequest "client.test.invalid" 60))
    Routes.BrokerVaultResetAmbiguousInitialization ->
      Client.resetAmbiguousVaultInitialization endpoint context action
    Routes.BrokerChildCustodyCommit ->
      Client.commitChildCustody endpoint context action
    Routes.BrokerChildRecoveryDeliver ->
      Client.deliverChildRecovery endpoint context action
    Routes.BrokerChildRecoveryObserve ->
      Client.observeChildRecovery endpoint context action

literalIpv4Loopback :: HostAddress
literalIpv4Loopback = tupleToHostAddress (127, 0, 0, 1)

testFailure :: String -> IO value
testFailure = throwIO . userError

mustRight :: (Show error) => Either error value -> value
mustRight = either (error . show) id
