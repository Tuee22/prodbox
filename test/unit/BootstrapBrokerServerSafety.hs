{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Real-loopback proofs for the server's async-exception terminal
-- transitions.  These intentionally exercise the public server boundary:
-- killing an owner must wake coalesced replays and must not leave a running
-- idempotency binding behind.
module BootstrapBrokerServerSafety
  ( bootstrapBrokerServerSafetySuite
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, waitCatch, withAsync)
import Control.Concurrent.STM
  ( STM
  , TMVar
  , TVar
  , atomically
  , modifyTVar'
  , newEmptyTMVarIO
  , newTVarIO
  , putTMVar
  , readTMVar
  , readTVar
  , readTVarIO
  , retry
  , tryPutTMVar
  )
import Control.Exception (bracket, throwIO)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
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
import Prodbox.Bootstrap.Broker.Request qualified as Request
import Prodbox.Bootstrap.Broker.Routes qualified as Routes
import Prodbox.Bootstrap.Broker.Server qualified as Server
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import System.Timeout (timeout)
import TestSupport

bootstrapBrokerServerSafetySuite :: SuiteBuilder ()
bootstrapBrokerServerSafetySuite =
  describe "Sprint 2.33 Bootstrap Broker server terminal-transition safety" $ do
    it
      "authenticates the decoded route and secret-free request binding"
      authenticationProjectionProof
    it
      "times out one owner, wakes every replay, and permits a fresh retry"
      timeoutReplayProof
    it
      "force-drains an admitted owner and replay without a running residue"
      forceDrainReplayProof
    it
      "keeps a paused worker claim visible until dequeue and accounting commit together"
      atomicWorkerClaimProof
    it
      "bounds deadline-forced worker joins and clears runtime residue"
      drainDeadlineJoinProof

data TestLimits = TestLimits
  { testRequestDeadlineMilliseconds :: !Natural
  , testDrainDeadlineMilliseconds :: !Natural
  }

defaultTestLimits :: TestLimits
defaultTestLimits =
  TestLimits
    { testRequestDeadlineMilliseconds = 5_000
    , testDrainDeadlineMilliseconds = 1_000
    }

data TestServer = TestServer
  { testServerPort :: !PortNumber
  , testServerHandle :: !Server.BrokerServerHandle
  }

authenticationProjectionProof :: Expectation
authenticationProjectionProof = do
  captured <- newEmptyTMVarIO
  let authenticator =
        Server.BrokerAuthenticator $ \request -> do
          atomically (putTMVar captured request)
          pure (Right (Server.authenticationClaimedIdentity request))
  withTestServer defaultTestLimits authenticator acceptingInterpreter $ \server -> do
    let route = Routes.BrokerVaultInitialize
        key = "authentication-projection"
        body = "{\"action\":\"initialize\"}"
    status <- exchange server (rpcWire route key body)
    status `shouldBe` 202
    request <- awaitSignal "authenticator did not receive the request" captured
    Server.authenticationRoute request `shouldBe` route
    Server.authenticationOperation request `shouldBe` Request.EnsureVaultInitialized
    Server.authenticationClaimedIdentity request `shouldBe` testServiceIdentity
    Server.authenticationExpectedServiceIdentity request `shouldBe` testServiceIdentity
    Server.authenticationIdempotencyKey request `shouldBe` validatedKey key
    Server.authenticationRequestBodyDigest request
      `shouldBe` Request.requestDigestForBytes body
    Server.authenticationCallerAddress request `shouldBe` Settings.LoopbackIpv4
    Server.withBrokerTransportCredential
      (Server.authenticationCredential request)
      id
      `shouldBe` testTransportCredential

timeoutReplayProof :: Expectation
timeoutReplayProof = do
  entered <- newEmptyTMVarIO
  calls <- newTVarIO (0 :: Natural)
  let limits =
        defaultTestLimits
          { testRequestDeadlineMilliseconds = 1_500
          }
      interpreter = firstInvocationBlocks entered calls
      route = Routes.BrokerVaultInitialize
      wire = rpcWire route "timeout-owner-with-replays" "{\"action\":\"initialize\"}"
  withTestServer limits permissiveAuthenticator interpreter $ \server ->
    withAsync (exchange server wire) $ \owner -> do
      _ <- awaitSignal "owner did not enter the interpreter" entered
      -- Give the owner a materially earlier deadline than its coalesced
      -- replays.  Otherwise all three per-request timers can expire in the
      -- same scheduler turn, obscuring the terminal-transition proof.
      threadDelay 750_000
      withAsync (exchange server wire) $ \firstReplay ->
        withAsync (exchange server wire) $ \secondReplay -> do
          awaitSnapshot server $ \snapshot ->
            Server.snapshotActiveConnections snapshot >= 3
              && Server.snapshotIdempotencyEntries snapshot == 1
          ownerStatus <- wait owner
          firstReplayStatus <- wait firstReplay
          secondReplayStatus <- wait secondReplay
          ownerStatus `shouldBe` 504
          firstReplayStatus `shouldBe` 500
          secondReplayStatus `shouldBe` 500
          awaitSnapshot server $ \snapshot ->
            Server.snapshotActiveConnections snapshot == 0
              && Server.snapshotIdempotencyEntries snapshot == 0
          retryStatus <- exchange server wire
          retryStatus `shouldBe` 202
          readTVarIO calls `shouldReturn` 2

forceDrainReplayProof :: Expectation
forceDrainReplayProof = do
  entered <- newEmptyTMVarIO
  calls <- newTVarIO (0 :: Natural)
  let interpreter = firstInvocationBlocks entered calls
      wire =
        rpcWire
          Routes.BrokerVaultInitialize
          "force-drain-owner-with-replay"
          "{\"action\":\"initialize\"}"
  withTestServer defaultTestLimits permissiveAuthenticator interpreter $ \server ->
    withAsync (exchange server wire) $ \owner -> do
      _ <- awaitSignal "force-drain owner did not enter the interpreter" entered
      withAsync (exchange server wire) $ \replay -> do
        awaitSnapshot server $ \snapshot ->
          Server.snapshotActiveConnections snapshot >= 2
            && Server.snapshotIdempotencyEntries snapshot == 1
        Server.forceBrokerDrain (testServerHandle server)
        waitServerWithin server `shouldReturn` Left Server.BrokerForcedShutdown
        ownerSettled <- timeout 2_000_000 (waitCatch owner)
        replaySettled <- timeout 2_000_000 (waitCatch replay)
        ownerSettled `shouldSatisfy` maybe False (const True)
        replaySettled `shouldSatisfy` maybe False (const True)
        assertStoppedWithoutRuntimeResidue server
        readTVarIO calls `shouldReturn` 1

atomicWorkerClaimProof :: Expectation
atomicWorkerClaimProof = do
  claimGate <- newEmptyTMVarIO
  entered <- newEmptyTMVarIO
  calls <- newTVarIO (0 :: Natural)
  let hooks =
        Server.BrokerServerHooks
          { Server.brokerBeforeWorkerAccounting = readTMVar claimGate
          }
      interpreter = firstInvocationBlocks entered calls
      wire = probeWire Routes.BrokerHealth
  withTestServerWithHooks
    defaultTestLimits
    hooks
    permissiveAuthenticator
    interpreter
    $ \server ->
      withAsync (exchange server wire) $ \client -> do
        -- The gate runs after the queue read but inside the same STM
        -- transaction.  While it retries, the queue read is rolled back and
        -- the manager cannot observe the old queue-empty/active-zero gap.
        awaitSnapshot server $ \snapshot ->
          Server.snapshotQueuedConnections snapshot == 1
            && Server.snapshotActiveConnections snapshot == 0
        Server.beginBrokerDrain (testServerHandle server)
        premature <-
          timeout
            100_000
            (Server.waitBrokerServer (testServerHandle server))
        premature `shouldBe` Nothing
        draining <- Server.brokerServerSnapshot (testServerHandle server)
        draining
          `shouldBe` Server.BrokerServerSnapshot
            { Server.snapshotPhase = Server.BrokerDraining
            , Server.snapshotQueuedConnections = 1
            , Server.snapshotActiveConnections = 0
            , Server.snapshotIdempotencyEntries = 0
            }
        atomically (putTMVar claimGate ())
        _ <- awaitSignal "accounted worker did not enter the interpreter" entered
        Server.forceBrokerDrain (testServerHandle server)
        waitServerWithin server `shouldReturn` Left Server.BrokerForcedShutdown
        clientSettled <- timeout 2_000_000 (waitCatch client)
        clientSettled `shouldSatisfy` maybe False (const True)
        assertStoppedWithoutRuntimeResidue server
        readTVarIO calls `shouldReturn` 1

drainDeadlineJoinProof :: Expectation
drainDeadlineJoinProof = do
  entered <- newEmptyTMVarIO
  calls <- newTVarIO (0 :: Natural)
  let limits =
        defaultTestLimits
          { testDrainDeadlineMilliseconds = 50
          }
      interpreter = firstInvocationBlocks entered calls
      wire =
        rpcWire
          Routes.BrokerVaultInitialize
          "deadline-bounded-worker-join"
          "{\"action\":\"initialize\"}"
  withTestServer limits permissiveAuthenticator interpreter $ \server ->
    withAsync (exchange server wire) $ \client -> do
      _ <- awaitSignal "deadline-drain owner did not enter the interpreter" entered
      Server.beginBrokerDrain (testServerHandle server)
      settled <-
        timeout
          500_000
          (Server.waitBrokerServer (testServerHandle server))
      settled `shouldBe` Just (Left Server.BrokerDrainDeadlineExceeded)
      clientSettled <- timeout 2_000_000 (waitCatch client)
      clientSettled `shouldSatisfy` maybe False (const True)
      assertStoppedWithoutRuntimeResidue server
      readTVarIO calls `shouldReturn` 1

firstInvocationBlocks
  :: TMVar ()
  -> TVar Natural
  -> Server.BrokerInterpreter
firstInvocationBlocks entered calls =
  Server.BrokerInterpreter $ \_context _route _body -> do
    invocation <- atomically $ do
      modifyTVar' calls (+ 1)
      current <- readTVarIOInSTM calls
      if current == 1
        then void (tryPutTMVar entered ())
        else pure ()
      pure current
    if invocation == 1
      then atomically retry
      else pure acceptedReply

-- Keep the test interpreter's counter observation in the same STM transaction
-- as its increment without exposing any mutable state to the server.
readTVarIOInSTM :: TVar value -> STM value
readTVarIOInSTM = readTVar

acceptingInterpreter :: Server.BrokerInterpreter
acceptingInterpreter =
  Server.BrokerInterpreter (\_context _route _body -> pure acceptedReply)

acceptedReply :: Server.BrokerReply
acceptedReply = case Server.mkBrokerReply Server.BrokerReplyAccepted "{\"accepted\":true}" of
  Left err -> error err
  Right reply -> reply

permissiveAuthenticator :: Server.BrokerAuthenticator
permissiveAuthenticator =
  Server.BrokerAuthenticator $ \request ->
    pure (Right (Server.authenticationClaimedIdentity request))

withTestServer
  :: TestLimits
  -> Server.BrokerAuthenticator
  -> Server.BrokerInterpreter
  -> (TestServer -> Expectation)
  -> Expectation
withTestServer limits authenticator interpreter assertion =
  withTestServerWithHooks
    limits
    Server.noBrokerServerHooks
    authenticator
    interpreter
    assertion

withTestServerWithHooks
  :: TestLimits
  -> Server.BrokerServerHooks
  -> Server.BrokerAuthenticator
  -> Server.BrokerInterpreter
  -> (TestServer -> Expectation)
  -> Expectation
withTestServerWithHooks limits hooks authenticator interpreter assertion =
  withSocketsDo
    ( bracket
        (startTestServerWithHooks 8 limits hooks authenticator interpreter)
        stopTestServer
        assertion
    )

startTestServerWithHooks
  :: Int
  -> TestLimits
  -> Server.BrokerServerHooks
  -> Server.BrokerAuthenticator
  -> Server.BrokerInterpreter
  -> IO TestServer
startTestServerWithHooks remainingAttempts limits hooks authenticator interpreter
  | remainingAttempts <= 0 =
      testFailure "could not reserve a Bootstrap Broker safety-test port"
  | otherwise = do
      port <- reserveEphemeralPort
      settings <- validatedSettings port limits
      started <-
        Server.startBrokerServerWithHooks
          settings
          hooks
          authenticator
          interpreter
      case started of
        Right handle -> pure (TestServer port handle)
        Left Server.BrokerListenerUnavailable ->
          startTestServerWithHooks
            (remainingAttempts - 1)
            limits
            hooks
            authenticator
            interpreter
        Left err -> testFailure (Server.renderBrokerServerError err)

stopTestServer :: TestServer -> IO ()
stopTestServer server = do
  Server.beginBrokerDrain (testServerHandle server)
  settled <- timeout 2_000_000 (Server.waitBrokerServer (testServerHandle server))
  case settled of
    Just _ -> pure ()
    Nothing -> do
      Server.forceBrokerDrain (testServerHandle server)
      void (timeout 2_000_000 (Server.waitBrokerServer (testServerHandle server)))

waitServerWithin :: TestServer -> IO (Either Server.BrokerServerError ())
waitServerWithin server = do
  settled <- timeout 2_000_000 (Server.waitBrokerServer (testServerHandle server))
  case settled of
    Just result -> pure result
    Nothing -> testFailure "Bootstrap Broker server did not settle"

reserveEphemeralPort :: IO PortNumber
reserveEphemeralPort =
  bracket
    (socket AF_INET Stream defaultProtocol)
    close
    ( \listener -> do
        bind listener (SockAddrInet 0 literalLoopback)
        address <- getSocketName listener
        case address of
          SockAddrInet port _
            | port /= 0 -> pure port
          _ -> testFailure "reserved address was not IPv4 loopback"
    )

validatedSettings
  :: PortNumber
  -> TestLimits
  -> IO Settings.BootstrapBrokerSettings
validatedSettings port limits =
  case Settings.validateBootstrapBrokerConfig (settingsDhall port limits) of
    Left err -> testFailure (Settings.renderBootstrapBrokerSettingsError err)
    Right settings -> pure settings

settingsDhall
  :: PortNumber
  -> TestLimits
  -> Settings.BootstrapBrokerConfigDhall
settingsDhall port limits =
  Settings.BootstrapBrokerConfigDhall
    { Settings.schemaVersion = 1
    , Settings.cluster_id = "server-safety-cluster"
    , Settings.vault_address = "http://127.0.0.1:8200"
    , Settings.service_identity = Request.renderBrokerServiceIdentity testServiceIdentity
    , Settings.listener =
        Settings.BrokerListenerDhall
          { Settings.listen_host = "127.0.0.1"
          , Settings.listen_port = fromIntegral port
          }
    , Settings.bootstrap_store =
        Settings.BootstrapStoreDhall
          { Settings.store_endpoint = "http://127.0.0.1:9000"
          , Settings.store_bucket = "server-safety-bootstrap-state"
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
          , Settings.max_request_body_bytes = 4_096
          , Settings.request_deadline_milliseconds =
              testRequestDeadlineMilliseconds limits
          , Settings.drain_deadline_milliseconds =
              testDrainDeadlineMilliseconds limits
          }
    }

rpcWire :: Routes.BrokerRoute -> ByteString -> ByteString -> ByteString
rpcWire route rawKey body =
  ByteString.concat
    [ "POST "
    , ByteString8.pack (Routes.brokerRoutePath route)
    , " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    , "X-Prodbox-Service-Identity: "
    , TextEncoding.encodeUtf8 (Request.renderBrokerServiceIdentity testServiceIdentity)
    , "\r\nX-Prodbox-Transport-Credential: "
    , testTransportCredential
    , "\r\nIdempotency-Key: "
    , rawKey
    , "\r\nX-Prodbox-Request-Sha256: "
    , TextEncoding.encodeUtf8
        (Request.renderRequestDigest (Request.requestDigestForBytes body))
    , "\r\nContent-Length: "
    , ByteString8.pack (show (ByteString.length body))
    , "\r\nConnection: close\r\n\r\n"
    , body
    ]

probeWire :: Routes.BrokerRoute -> ByteString
probeWire route =
  ByteString.concat
    [ "GET "
    , ByteString8.pack (Routes.brokerRoutePath route)
    , " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    ]

exchange :: TestServer -> ByteString -> IO Int
exchange server wire =
  bracket
    (openClient (testServerPort server))
    close
    ( \client -> do
        sendAll client wire
        shutdown client ShutdownSend
        response <- timeout 2_000_000 (receiveAll client)
        case response of
          Nothing -> testFailure "timed out reading Bootstrap Broker response"
          Just bytes -> parseStatus bytes
    )

openClient :: PortNumber -> IO Socket
openClient port = do
  client <- socket AF_INET Stream defaultProtocol
  connect client (SockAddrInet port literalLoopback)
  pure client

receiveAll :: Socket -> IO ByteString
receiveAll client = collect []
 where
  collect chunks = do
    bytes <- recv client 4_096
    if ByteString.null bytes
      then pure (ByteString.concat (reverse chunks))
      else collect (bytes : chunks)

parseStatus :: ByteString -> IO Int
parseStatus response =
  case ByteString8.words response of
    _version : rawStatus : _ ->
      case reads (ByteString8.unpack rawStatus) of
        [(status, "")] -> pure status
        _ -> testFailure "Bootstrap Broker returned a non-numeric status"
    _ -> testFailure "Bootstrap Broker returned no HTTP status"

awaitSignal :: String -> TMVar value -> IO value
awaitSignal failureMessage signal = do
  observed <- timeout 2_000_000 (atomically (readTMVar signal))
  case observed of
    Just value -> pure value
    Nothing -> testFailure failureMessage

awaitSnapshot
  :: TestServer
  -> (Server.BrokerServerSnapshot -> Bool)
  -> IO ()
awaitSnapshot server predicate = go (2_000 :: Int)
 where
  go remaining
    | remaining <= 0 = testFailure "server did not reach the expected snapshot"
    | otherwise = do
        snapshot <- Server.brokerServerSnapshot (testServerHandle server)
        if predicate snapshot
          then pure ()
          else do
            threadDelay 1_000
            go (remaining - 1)

assertStoppedWithoutRuntimeResidue :: TestServer -> Expectation
assertStoppedWithoutRuntimeResidue server = do
  snapshot <- Server.brokerServerSnapshot (testServerHandle server)
  snapshot
    `shouldBe` Server.BrokerServerSnapshot
      { Server.snapshotPhase = Server.BrokerStopped
      , Server.snapshotQueuedConnections = 0
      , Server.snapshotActiveConnections = 0
      , Server.snapshotIdempotencyEntries = 0
      }

testServiceIdentity :: Request.BrokerServiceIdentity
testServiceIdentity = case Request.mkBrokerServiceIdentity "server-safety-service" of
  Left err -> error err
  Right identity -> identity

validatedKey :: ByteString -> Request.IdempotencyKey
validatedKey raw = case Request.mkIdempotencyKey (TextEncoding.decodeUtf8 raw) of
  Left err -> error err
  Right key -> key

testTransportCredential :: ByteString
testTransportCredential = "server-safety-transport-credential"

literalLoopback :: HostAddress
literalLoopback = tupleToHostAddress (127, 0, 0, 1)

testFailure :: String -> IO value
testFailure = throwIO . userError
