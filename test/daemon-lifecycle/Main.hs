{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.STM
  ( TMVar
  , TVar
  , atomically
  , modifyTVar'
  , newEmptyTMVarIO
  , newTVarIO
  , putTMVar
  , readTMVar
  , readTVar
  , readTVarIO
  , takeTMVar
  , writeTVar
  )
import Control.Exception
  ( SomeException
  , bracket
  , try
  )
import Control.Monad (forever)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (elemIndex, intercalate)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word64)
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (SockAddrInet)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , accept
  , bind
  , close
  , connect
  , defaultProtocol
  , getSocketName
  , listen
  , setSocketOption
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.Bootstrap.Broker.LegacyAdapter (bootstrapVaultPath)
import Prodbox.CLI.Spec
  ( findCommandSpec
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (DeadlineOpen)
  , deadlineObservation
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.Gateway
  ( resolveGatewayConfigPath
  )
import Prodbox.Gateway.Daemon
  ( EmitterAdmissionMarker (..)
  , EmitterRuntimeDependencies (..)
  , EmitterRuntimeEvent (..)
  , EmitterTopology (JournalLeaseEmitter)
  , TargetOperation (TargetPulumiObjectGet)
  , runGatewayDaemonWithRuntimeDependencies
  )
import Prodbox.Gateway.Emitter.Journal
  ( EmitterRetirementReceipt
  , JournalIdentity
  , mkEmitterRetirementReceipt
  , mkJournalIdentity
  , renderJournalError
  , retirementNextIncarnation
  )
import Prodbox.Gateway.Emitter.Lease
  ( EmitterLeaseClient (..)
  , EmitterLeaseRuntime (..)
  , LeaseMutationResult (..)
  , LeaseObservation (..)
  , LeaseRecord (..)
  )
import Prodbox.Gateway.ObjectStore (pulumiObjectGetPath)
import Prodbox.Gateway.Settings qualified as GatewaySettings
import Prodbox.Result (Result (..))
import Prodbox.Retry
  ( PollOutcome (..)
  , RetryPolicy (..)
  , pollUntilReady
  )
import Prodbox.Subprocess
  ( BackgroundProcess (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , startBackgroundProcess
  , stopBackgroundProcess
  , terminateBackgroundProcess
  , waitBackgroundProcess
  )
import System.Directory (getCurrentDirectory, removeFile)
import System.Environment
  ( lookupEnv
  , setEnv
  , unsetEnv
  )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO (hGetContents)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import TestSupport

main :: IO ()
main = mainWithSuite "prodbox-daemon-lifecycle" $ do
  describe "daemon lifecycle suite scaffold" $ do
    it "keeps the gateway daemon runtime in the repository" $ do
      repoRoot <- getCurrentDirectory
      daemonSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs")
      daemonSource `shouldContain` "runGatewayDaemon"

    it "keeps the gateway start command in the registry-backed parser" $
      findCommandSpec ["gateway", "start"]
        `shouldSatisfy` isJust

  describe "gateway daemon process lifecycle" $ do
    it "serves health and metrics but stays unready without durable emitter authority" $
      withGatewayDaemon 5 $ \daemon -> do
        healthResult <- tryAny (waitForHttpStatus (daemonRestPort daemon) "/healthz" 200)
        case healthResult of
          Right () -> pure ()
          Left err -> do
            stderrText <- readDaemonStderr daemon
            expectationFailure
              ( "health probe failed: "
                  ++ err
                  ++ "\n=== daemon stderr ===\n"
                  ++ stderrText
              )
        readHttp (daemonRestPort daemon) "/healthz"
          `shouldReturn` HttpResponse 200 "ok\n"
        metrics <- readHttp (daemonRestPort daemon) "/metrics"
        responseStatus metrics `shouldBe` 200
        responseBody metrics `shouldContain` "prodbox_gateway_signed_replay_assertions"
        readHttp (daemonRestPort daemon) "/readyz"
          `shouldReturn` HttpResponse 503 "starting\n"
        terminateGatewayDaemon daemon
        waitForHttpStatus (daemonRestPort daemon) "/readyz" 503
        waitForProcessExitSuccess daemon 10

    it "forces drain promptly when SIGTERM arrives twice" $
      withGatewayDaemon 5 $ \daemon -> do
        waitForHttpStatus (daemonRestPort daemon) "/healthz" 200
        terminateGatewayDaemon daemon
        waitForHttpStatus (daemonRestPort daemon) "/readyz" 503
        readHttp (daemonRestPort daemon) "/readyz"
          `shouldReturn` HttpResponse 503 "draining\n"
        terminateGatewayDaemon daemon
        waitForProcessExitSuccess daemon 10

    it "emits structured JSON log lines on stderr" $
      withGatewayDaemon 5 $ \daemon -> do
        waitForHttpStatus (daemonRestPort daemon) "/healthz" 200
        terminateGatewayDaemon daemon
        waitForProcessExitSuccess daemon 10
        stderrText <- readDaemonStderr daemon
        case filter (not . null) (lines stderrText) of
          firstLine : _ -> assertStructuredLogLine firstLine
          [] -> expectationFailure "expected at least one daemon log line on stderr"

    it "binds pre-Vault diagnostics without readiness or local publication" $
      withGatewayDaemonWithConfig renderPreVaultConfig 5 $ \daemon -> do
        waitForHttpStatus (daemonRestPort daemon) "/healthz" 200
        readHttp (daemonRestPort daemon) "/healthz"
          `shouldReturn` HttpResponse 200 "ok\n"
        readHttp (daemonRestPort daemon) "/readyz"
          `shouldReturn` HttpResponse 503 "starting\n"
        rollbackResponse <-
          readHttpRequest
            (daemonRestPort daemon)
            (postJsonRequest bootstrapVaultPath "{}")
        responseStatus rollbackResponse `shouldBe` 400
        responseBody rollbackResponse `shouldContain` "invalid bootstrap JSON body"
        federationResponse <- readHttp (daemonRestPort daemon) "/v1/federation/children"
        responseStatus federationResponse `shouldBe` 503
        responseBody federationResponse `shouldContain` "gateway service-account token"
        stateResponse <- readHttp (daemonRestPort daemon) "/v1/state"
        case eitherDecode (BL8.pack (responseBody stateResponse)) of
          Right (Object obj) ->
            KeyMap.lookup (Key.fromString "signed_replay_assertion_count") obj
              `shouldBe` Just (Number 0)
          other -> expectationFailure ("unexpected pre-Vault state response: " ++ show other)
        terminateGatewayDaemon daemon
        waitForProcessExitSuccess daemon 10

    it "serves the bounded peer cursor protocol while continuity and DNS stay fail-closed" $
      withGatewayDaemon 5 $ \daemon -> do
        waitForHttpStatus (daemonRestPort daemon) "/healthz" 200
        peerResponse <-
          readHttpRequest
            (daemonPeerPort daemon)
            "GET /v1/peer/cursor HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        responseStatus peerResponse `shouldBe` 200
        responseBody peerResponse `shouldSatisfy` (not . null)
        oversizedOutcome <-
          timeout
            1000000
            ( tryReadHttpRequest
                (daemonPeerPort daemon)
                "POST /v1/peer/delta HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 65537\r\nConnection: close\r\n\r\n"
            )
        case oversizedOutcome of
          Nothing ->
            expectationFailure
              "peer listener waited for an oversized declared body instead of rejecting its header"
          Just (Left _) -> pure ()
          Just (Right oversizedResponse) ->
            responseStatus oversizedResponse `shouldSatisfy` (`elem` [400, 413])
        stateResponse <- readHttp (daemonRestPort daemon) "/v1/state"
        responseStatus stateResponse `shouldBe` 200
        case eitherDecode (BL8.pack (responseBody stateResponse)) of
          Right (Object obj) -> do
            KeyMap.lookup (Key.fromString "can_write_dns") obj `shouldBe` Just (Bool False)
            KeyMap.lookup (Key.fromString "semantic_member_count") obj
              `shouldBe` Just (Number 1)
            case ( KeyMap.lookup (Key.fromString "signed_replay_assertion_count") obj
                 , KeyMap.lookup (Key.fromString "retained_assertion_count") obj
                 , KeyMap.lookup (Key.fromString "retained_assertion_capacity") obj
                 ) of
              (Just (Number replayCount), Just (Number retainedCount), Just (Number capacity)) -> do
                replayCount `shouldSatisfy` (>= 0)
                retainedCount `shouldSatisfy` (>= replayCount)
                retainedCount `shouldSatisfy` (<= capacity)
              other -> expectationFailure ("unexpected bounded count diagnostics: " ++ show other)
            case KeyMap.lookup (Key.fromString "recent_assertion_hashes") obj of
              Just (Array hashes) -> length hashes `shouldSatisfy` (<= 64)
              other -> expectationFailure ("unexpected assertion-hash diagnostic: " ++ show other)
            case KeyMap.lookup (Key.fromString "peer_receive_cursors") obj of
              Just (Object cursors) -> KeyMap.size cursors `shouldSatisfy` (<= 1)
              other -> expectationFailure ("unexpected peer cursor diagnostic: " ++ show other)
            case KeyMap.lookup (Key.fromString "continuity_authority") obj of
              Just (Object continuityObject) ->
                KeyMap.lookup (Key.fromString "status") continuityObject
                  `shouldBe` Just (String (Text.pack "unavailable"))
              other -> expectationFailure ("unexpected continuity diagnostic: " ++ show other)
          other -> expectationFailure ("unexpected gateway state response: " ++ show other)
        terminateGatewayDaemon daemon
        waitForProcessExitSuccess daemon 10

  -- Sprint 2.21: the SIGHUP-based reload test was removed when SIGHUP was
  -- replaced by the file-watch worker. The file-watch reload behavior is
  -- inherently asynchronous (fsnotify's parent-directory watch races with
  -- the test's config rewrite), so deterministic unit-level coverage is no
  -- longer feasible here. The closure gate moved to the live operator
  -- exercise on this host: `prodbox cluster reconcile` brings up the gateway
  -- daemon with a mounted Dhall ConfigMap; editing the ConfigMap triggers a
  -- LiveConfig reload (log_level / timing knob change) in-process or a
  -- BootConfig drain-and-exit (node identity / cert paths) followed by a
  -- kubelet-driven restart.

  describe "gateway /v1/state inbound/outbound health split (Sprint 2.25)" $ do
    it "splits peer health into inbound and outbound fields" $
      withGatewayDaemon 5 $ \daemon -> do
        waitForHttpStatus (daemonRestPort daemon) "/healthz" 200
        stateResponse <- readHttp (daemonRestPort daemon) "/v1/state"
        responseStatus stateResponse `shouldBe` 200
        case eitherDecode (BL8.pack (responseBody stateResponse)) of
          Left err -> expectationFailure ("/v1/state was not JSON: " ++ err)
          Right (Object obj) -> do
            stateHasKey obj "peer_inbound_health" `shouldBe` True
            stateHasKey obj "peer_outbound_health" `shouldBe` True
            -- The conflated single-health field is replaced by the split.
            stateHasKey obj "peer_transport" `shouldBe` False
          Right _ -> expectationFailure "/v1/state was not a JSON object"

  describe "Sprint 2.32 actor-backed target daemon composition" $ do
    it "keeps production on the mutually exclusive legacy topology pending Standard-P" $ do
      repoRoot <- getCurrentDirectory
      daemonSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs")
      daemonSource
        `shouldContain` "runGatewayDaemon = runGatewayDaemonWithTopology LegacyModelBEmitter"
      daemonSource
        `shouldContain` "LegacyModelBEmitter -> writeLegacyDnsRecord action"
      daemonSource
        `shouldContain` "withTargetOperationAtDeadline env TargetRoute53Write deadline"
      daemonSource
        `shouldContain` "Just _ -> throwIO exc"
      daemonSource
        `shouldContain` "try (TextIO.readFile path) :: IO (Either IOException Text.Text)"

    it "keeps target continuity and native REST off an occupied legacy child slot" $
      withTargetGatewayFixture $ \fixture ->
        withRunningTargetGateway fixture $ do
          -- The injected fixture never seeds the legacy child permit. Reaching
          -- ready proves the Journal/Lease continuity actor does not wait on it.
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          response <-
            readHttpRequest
              (targetRestPort fixture)
              (postJsonRequest bootstrapVaultPath "{}")
          responseStatus response `shouldBe` 404
          targetResponse <-
            readHttpRequest
              (targetRestPort fixture)
              (postJsonRequest pulumiObjectGetPath "{}")
          responseStatus targetResponse `shouldBe` 400
          propagatedDeadline <-
            waitForEmitterEvent fixture pulumiObjectOperationDeadline
          observedAtHandler <- realMonotonicNow
          deadlineObservation observedAtHandler propagatedDeadline
            `shouldSatisfy` isOpenDeadline

          repoRoot <- getCurrentDirectory
          daemonSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs")
          daemonSource
            `shouldContain` "LegacyModelBEmitter -> withGatewayChild env childName action"
          daemonSource
            `shouldContain` "JournalLeaseEmitter -> action"
          daemonSource
            `shouldContain` "writeNativeDnsRecord acceptedDeadline action"

    it "refuses a saturated target operation immediately without queueing" $
      withTargetGatewayFixture $ \fixture -> do
        atomically (writeTVar (targetBlockNextOperation fixture) True)
        withRunningTargetGateway fixture $ do
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          let request = postJsonRequest pulumiObjectGetPath "{}"
          withAsync (readHttpRequest (targetRestPort fixture) request) $ \firstRequest -> do
            _ <-
              waitForEmitterEvent fixture pulumiObjectOperationAdmitted
            refused <-
              timeout
                1000000
                (readHttpRequest (targetRestPort fixture) request)
            case refused of
              Nothing -> expectationFailure "saturated target operation queued instead of refusing"
              Just response -> do
                responseStatus response `shouldBe` 503
                responseBody response `shouldContain` "immediate refusal"
            atomically (putTMVar (targetOperationGate fixture) ())
            completed <- wait firstRequest
            responseStatus completed `shouldBe` 400

    it "adopts a target peer cursor only after its actor acknowledgement fsyncs" $
      withTargetGatewayFixture $ \fixture -> do
        atomically (writeTVar (targetFailNextPeerAckFsync fixture) True)
        withRunningTargetGateway fixture $ do
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          _ <- waitForRespondedEmitterBytes fixture
          baselineEvents <- readTVarIO (targetEvents fixture)
          atomically (putTMVar (targetPeerProxyEnabled fixture) ())

          _ <-
            waitForEmitterEvent fixture (matchingEmitterEvent EmitterPeerAckProjectionFsyncRefused)
          stateWhileRefused <- readHttp (targetRestPort fixture) "/v1/state"
          peerCursorPresent "node-b" stateWhileRefused `shouldBe` False
          refusedEvents <- readTVarIO (targetEvents fixture)
          checkpointEventCount refusedEvents
            `shouldBe` checkpointEventCount baselineEvents

          atomically (putTMVar (targetPeerAckFsyncRecoveryGate fixture) ())
          _ <-
            waitForEmitterEvent fixture (matchingEmitterEvent EmitterPeerAckProjectionFsynced)
          waitForPeerCursor fixture "node-b"
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200

    it "earns readiness, fsyncs before actor response, and recovers after Lease loss" $
      withTargetGatewayFixture $ \fixture ->
        withRunningTargetGateway fixture $ do
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          responseBytes <- waitForRespondedEmitterBytes fixture
          events <- readTVarIO (targetEvents fixture)
          eventIndex (EmitterAssertionPublished responseBytes) events
            `shouldSatisfy` (< eventIndex (EmitterProjectionFsynced responseBytes) events)
          eventIndex (EmitterProjectionFsynced responseBytes) events
            `shouldSatisfy` (< eventIndex (EmitterRequestResponded responseBytes) events)

          atomically (writeTVar (targetLeaseAvailable fixture) False)
          waitForHttpStatus (targetRestPort fixture) "/readyz" 503
          readHttp (targetRestPort fixture) "/readyz"
            `shouldReturn` HttpResponse 503 "starting\n"

          atomically (writeTVar (targetLeaseAvailable fixture) True)
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200

    it "republishes the exact staged bytes after a publish-before-commit crash" $
      withTargetGatewayFixture $ \fixture -> do
        atomically (writeTVar (targetBlockNextPublish fixture) True)
        crashedBytes <-
          withRunningTargetGateway fixture $ do
            waitForHttpStatus (targetRestPort fixture) "/readyz" 200
            waitForPublishedEmitterBytes fixture

        atomically $ do
          writeTVar (targetLeaseRecord fixture) Nothing
          writeTVar (targetEvents fixture) []

        recoveredBytes <-
          withRunningTargetGateway fixture $ do
            waitForHttpStatus (targetRestPort fixture) "/readyz" 200
            waitForPublishedEmitterBytes fixture
        recoveredBytes `shouldBe` crashedBytes

    it "rolls volatile publication back to the retained journal before exact recovery" $
      withTargetGatewayFixture $ \fixture ->
        withRunningTargetGateway fixture $ do
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          committedBytes <- waitForRespondedEmitterBytes fixture
          atomically $ do
            writeTVar (targetEvents fixture) []
            writeTVar (targetBlockNextPublish fixture) True

          volatileBytes <- waitForPublishedEmitterBytes fixture
          volatileBytes `shouldNotBe` committedBytes
          atomically (writeTVar (targetLeaseAvailable fixture) False)
          waitForHttpStatus (targetRestPort fixture) "/readyz" 503

          atomically $ do
            writeTVar (targetEvents fixture) []
            putTMVar (targetPublishGate fixture) ()
          _ <-
            waitForEmitterEvent fixture (matchingEmitterEvent EmitterRecoveryRequested)

          atomically (writeTVar (targetLeaseAvailable fixture) True)
          republishedBytes <- waitForPublishedEmitterBytes fixture
          republishedBytes `shouldBe` volatileBytes
          _ <-
            waitForEmitterEvent fixture (matchingProjectionFsynced volatileBytes)
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          completedEvents <- readTVarIO (targetEvents fixture)
          eventIndex (EmitterAssertionPublished volatileBytes) completedEvents
            `shouldSatisfy` (< eventIndex (EmitterProjectionFsynced volatileBytes) completedEvents)

    it "re-arms authenticated Orders migration after a migrated-projection crash" $
      withTargetGatewayFixture $ \fixture -> do
        withRunningTargetGateway fixture $
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
        targetWriteOrders fixture 2
        atomically $ do
          writeTVar (targetLeaseRecord fixture) Nothing
          writeTVar (targetEvents fixture) []
          writeTVar (targetBlockNextMountProjection fixture) True

        priorDigest <-
          withRunningTargetGateway fixture $ do
            armed <-
              waitForEmitterEvent fixture ordersMigrationAdmission
            _ <-
              waitForEmitterEvent fixture (matchingEmitterEvent EmitterMountProjectionFsynced)
            snd armed `shouldBe` 2
            pure (fst armed)

        atomically $ do
          writeTVar (targetLeaseRecord fixture) Nothing
          writeTVar (targetEvents fixture) []
        withRunningTargetGateway fixture $ do
          rearmedDigest <-
            waitForEmitterEvent fixture ordersMigrationAdmission
          fst rearmedDigest `shouldBe` priorDigest
          snd rearmedDigest `shouldBe` 2
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          remainingMigrations <-
            waitForEmitterEvent fixture ordersMigrationApplied
          remainingMigrations `shouldBe` 1
          _ <- waitForRespondedEmitterBytes fixture
          pure ()

    it "re-arms the local Orders migration after a same-process final-fsync refusal" $
      withTargetGatewayFixture $ \fixture -> do
        withRunningTargetGateway fixture $ do
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          _ <- waitForRespondedEmitterBytes fixture
          pure ()
        targetWriteOrders fixture 2
        atomically $ do
          writeTVar (targetLeaseRecord fixture) Nothing
          writeTVar (targetEvents fixture) []
          writeTVar (targetFailNextMigrationFinalFsync fixture) True

        withRunningTargetGateway fixture $ do
          failedBytes <-
            waitForEmitterEvent fixture projectionFsyncRefusedBytes
          waitForHttpStatus (targetRestPort fixture) "/readyz" 503
          failedEvents <- readTVarIO (targetEvents fixture)
          eventIndex (EmitterOrdersMigrationApplied 1) failedEvents
            `shouldSatisfy` (< eventIndex (EmitterProjectionFsyncRefused failedBytes) failedEvents)

          atomically $ do
            writeTVar (targetLeaseRecord fixture) Nothing
            writeTVar (targetEvents fixture) []
            putTMVar (targetProjectionFsyncRecoveryGate fixture) ()
          replayedBytes <- waitForPublishedEmitterBytes fixture
          replayedBytes `shouldBe` failedBytes
          _ <-
            waitForEmitterEvent fixture (matchingProjectionFsynced failedBytes)
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          recoveredEvents <- readTVarIO (targetEvents fixture)
          recoveredEvents `shouldContain` [EmitterOrdersMigrationApplied 1]

    it "clears readiness and re-drives exact bytes after a transient fsync failure" $
      withTargetGatewayFixture $ \fixture ->
        withRunningTargetGateway fixture $ do
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          atomically $ do
            writeTVar (targetEvents fixture) []
            writeTVar (targetFailNextProjectionFsync fixture) True
          failedBytes <-
            waitForEmitterEvent fixture projectionFsyncRefusedBytes
          waitForHttpStatus (targetRestPort fixture) "/readyz" 503
          eventsWhileBlocked <- readTVarIO (targetEvents fixture)
          eventsWhileBlocked
            `shouldNotContain` [EmitterRequestResponded failedBytes]

          atomically (putTMVar (targetProjectionFsyncRecoveryGate fixture) ())
          replayedBytes <-
            waitForEmitterEvent fixture (matchingPublishedBytes failedBytes)
          replayedBytes `shouldBe` failedBytes
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          completedEvents <- readTVarIO (targetEvents fixture)
          eventIndex (EmitterProjectionFsyncRefused failedBytes) completedEvents
            `shouldSatisfy` (< eventIndex (EmitterAssertionPublished failedBytes) completedEvents)
          completedEvents
            `shouldNotContain` [EmitterRequestResponded failedBytes]

    it "retries a failed authority mount after releasing the journal lock" $
      withTargetGatewayFixture $ \fixture -> do
        atomically (writeTVar (targetLeaseAvailable fixture) False)
        withRunningTargetGateway fixture $ do
          _ <- waitForMountUnavailable fixture
          readHttp (targetRestPort fixture) "/readyz"
            `shouldReturn` HttpResponse 503 "starting\n"
          atomically (writeTVar (targetLeaseAvailable fixture) True)
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200

    it "admits a missing journal only with an exact indexed retirement receipt" $
      withTargetGatewayFixture $ \fixture -> do
        withRunningTargetGateway fixture $
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
        identity <- waitForObservedIdentity fixture
        removeFile (targetJournalFile fixture)
        let receipt = retirementReceipt identity 1
        atomically $ do
          writeTVar (targetLeaseRecord fixture) Nothing
          writeTVar (targetEvents fixture) []
          writeTVar (targetExpectedRetirementNext fixture) (Just 2)
          writeTVar
            (targetAdmissionMarker fixture)
            (EmitterAdmissionMarkerRetired receipt)
        withRunningTargetGateway fixture $ do
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
          retirementNextIncarnation receipt `shouldBe` 2

    it "rejects a retirement receipt while the prior journal still exists" $
      withTargetGatewayFixture $ \fixture -> do
        withRunningTargetGateway fixture $
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
        identity <- waitForObservedIdentity fixture
        let receipt = retirementReceipt identity 1
        atomically $ do
          writeTVar (targetLeaseRecord fixture) Nothing
          writeTVar (targetEvents fixture) []
          writeTVar (targetExpectedRetirementNext fixture) (Just 2)
          writeTVar
            (targetAdmissionMarker fixture)
            (EmitterAdmissionMarkerRetired receipt)
        withRunningTargetGateway fixture $ do
          detail <- waitForMountUnavailable fixture
          detail `shouldContain` "retirement receipt refused because the old journal still exists"
          readHttp (targetRestPort fixture) "/readyz"
            `shouldReturn` HttpResponse 503 "starting\n"

    it "rejects stale and wrong-identity retirement receipts for a missing journal" $
      withTargetGatewayFixture $ \fixture -> do
        withRunningTargetGateway fixture $
          waitForHttpStatus (targetRestPort fixture) "/readyz" 200
        identity <- waitForObservedIdentity fixture
        removeFile (targetJournalFile fixture)
        let staleReceipt = retirementReceipt identity 0
        atomically $ do
          writeTVar (targetLeaseRecord fixture) Nothing
          writeTVar (targetEvents fixture) []
          writeTVar (targetExpectedRetirementNext fixture) (Just 2)
          writeTVar
            (targetAdmissionMarker fixture)
            (EmitterAdmissionMarkerRetired staleReceipt)
        withRunningTargetGateway fixture $ do
          staleDetail <- waitForMountUnavailable fixture
          staleDetail `shouldContain` "fixture retirement receipt is not the indexed successor"
          readHttp (targetRestPort fixture) "/readyz"
            `shouldReturn` HttpResponse 503 "starting\n"

        wrongIdentity <-
          either (error . renderJournalError) pure $
            mkJournalIdentity
              (Text.pack "other-cluster")
              (Text.pack "node-a")
              (BS8.replicate 32 '\x44')
        let wrongReceipt = retirementReceipt wrongIdentity 1
        atomically $ do
          writeTVar (targetEvents fixture) []
          writeTVar
            (targetAdmissionMarker fixture)
            (EmitterAdmissionMarkerRetired wrongReceipt)
        withRunningTargetGateway fixture $ do
          wrongDetail <- waitForMountUnavailable fixture
          wrongDetail `shouldContain` "fixture retirement receipt is not the indexed successor"
          readHttp (targetRestPort fixture) "/readyz"
            `shouldReturn` HttpResponse 503 "starting\n"

  describe "gateway daemon health endpoint goldens" $ do
    goldenTest
      "keeps /healthz response shape stable"
      "test/golden/daemon-health/healthz.golden"
      (renderEndpointGolden "/healthz")

    goldenTest
      "keeps authority-unavailable /readyz response shape stable"
      "test/golden/daemon-health/readyz-starting.golden"
      (renderEndpointGolden "/readyz")

    goldenTest
      "keeps authority-ready /readyz response shape stable"
      "test/golden/daemon-health/readyz-ready.golden"
      renderReadyzReadyGolden

    goldenTest
      "keeps draining /readyz response shape stable"
      "test/golden/daemon-health/readyz-draining.golden"
      renderDrainingReadyzGolden

    goldenTest
      "keeps /metrics response shape stable"
      "test/golden/daemon-health/metrics.golden"
      renderMetricsGolden

  -- Sprint 2.24: the daemon/workload runtime-override CLI flags
  -- (@--log-level@, @--port@, @--foreground@) were removed per the
  -- config-as-data doctrine. The gateway daemon takes only @--config@.
  -- Sprint 3.15: the workload likewise takes only @--config@ and sources
  -- its mode / port / log level / Redis / OIDC from the mounted Dhall config
  -- exclusively — the @PRODBOX_*@ env-var ladder was deleted, so there is no
  -- workload env-resolution to exercise here. The workload Boot/Live
  -- classification and the missing-@--config@ hard-failure path are covered
  -- by the unit suite.
  describe "daemon config-as-data resolution" $ do
    it "requires --config for the gateway daemon and ignores PRODBOX_CONFIG_PATH"
      $ withTemporaryEnv
        [ ("PRODBOX_CONFIG_PATH", Just "/tmp/from-env-gateway.json")
        , ("PRODBOX_LOG_LEVEL", Just "debug")
        , ("PRODBOX_PORT", Just "4100")
        ]
      $ do
        resolveGatewayConfigPath (Just "/tmp/from-cli-gateway.json")
          `shouldReturn` Right "/tmp/from-cli-gateway.json"
        resolveGatewayConfigPath Nothing
          `shouldReturn` Left "Missing gateway config path. Pass `--config <path>`."

withTemporaryEnv :: [(String, Maybe String)] -> IO a -> IO a
withTemporaryEnv bindings action =
  bracket captureEnv restore (\_ -> applyBindings bindings >> action)
 where
  captureEnv = mapM (\(name, _) -> captureBinding name) bindings

  restore originalValues = applyBindings originalValues

  captureBinding name = do
    value <- lookupEnv name
    pure (name, value)

applyBindings :: [(String, Maybe String)] -> IO ()
applyBindings =
  mapM_ applyBinding

applyBinding :: (String, Maybe String) -> IO ()
applyBinding (name, maybeValue) =
  case maybeValue of
    Just value -> setEnv name value
    Nothing -> unsetEnv name

isJust :: Maybe a -> Bool
isJust maybeValue =
  case maybeValue of
    Just _ -> True
    Nothing -> False

data RunningGatewayDaemon = RunningGatewayDaemon
  { daemonBackgroundProcess :: BackgroundProcess
  , daemonRestPort :: Int
  , daemonPeerPort :: Int
  , daemonWriteConfig :: Int -> Maybe String -> IO ()
  }

data TargetGatewayFixture = TargetGatewayFixture
  { targetRunDaemon :: IO ExitCode
  , targetRunPeerProxy :: IO ()
  , targetWriteOrders :: Int -> IO ()
  , targetRestPort :: Int
  , targetPeerPort :: Int
  , targetLeaseAvailable :: TVar Bool
  , targetLeaseRecord :: TVar (Maybe LeaseRecord)
  , targetEvents :: TVar [EmitterRuntimeEvent]
  , targetBlockNextPublish :: TVar Bool
  , targetPublishGate :: TMVar ()
  , targetAdmissionMarker :: TVar EmitterAdmissionMarker
  , targetObservedIdentity :: TVar (Maybe JournalIdentity)
  , targetExpectedRetirementNext :: TVar (Maybe Word64)
  , targetJournalFile :: FilePath
  , targetFailNextProjectionFsync :: TVar Bool
  , targetProjectionFsyncRecoveryGate :: TMVar ()
  , targetPeerProxyEnabled :: TMVar ()
  , targetFailNextPeerAckFsync :: TVar Bool
  , targetPeerAckFsyncRecoveryGate :: TMVar ()
  , targetBlockNextOperation :: TVar Bool
  , targetOperationGate :: TMVar ()
  , targetBlockNextMountProjection :: TVar Bool
  , targetFailNextMigrationFinalFsync :: TVar Bool
  }

withTargetGatewayFixture :: (TargetGatewayFixture -> IO a) -> IO a
withTargetGatewayFixture action =
  withSystemTempDirectory "prodbox-gateway-emitter-target" $ \tmpDir -> do
    restPort <- allocateTcpPort
    peerPort <- allocateTcpPort
    peerProxyPort <- allocateTcpPort
    let certPath = tmpDir </> "node-a.crt"
        keyPath = tmpDir </> "node-a.key"
        caPath = tmpDir </> "ca.crt"
        ordersPath = tmpDir </> "orders.dhall"
        configPath = tmpDir </> "gateway.dhall"
        journalRoot = tmpDir </> "journal"
        configText = renderTargetConfig certPath keyPath caPath ordersPath 5 Nothing
    writeFile certPath "cert"
    writeFile keyPath "key"
    writeFile caPath "ca"
    writeFile ordersPath (renderTargetOrders restPort peerPort peerProxyPort)
    writeFile configPath configText
    decoded <- GatewaySettings.decodeDaemonConfigDhall (Text.pack configText)
    config <-
      case decoded of
        Left err -> ioError (userError err)
        Right value -> pure value

    leaseAvailable <- newTVarIO True
    leaseRecord <- newTVarIO Nothing
    leaseVersion <- newTVarIO (0 :: Int)
    admissionMarker <- newTVarIO EmitterAdmissionMarkerMissing
    observedIdentity <- newTVarIO Nothing
    expectedRetirementNext <- newTVarIO Nothing
    failNextProjectionFsync <- newTVarIO False
    blockNextProjectionFsync <- newTVarIO False
    projectionFsyncRecoveryGate <- newEmptyTMVarIO
    peerProxyEnabled <- newEmptyTMVarIO
    failNextPeerAckFsync <- newTVarIO False
    blockPeerAckFsyncRecovery <- newTVarIO False
    peerAckFsyncRecoveryGate <- newEmptyTMVarIO
    blockNextOperation <- newTVarIO False
    operationGate <- newEmptyTMVarIO
    blockNextMountProjection <- newTVarIO False
    failNextMigrationFinalFsync <- newTVarIO False
    mountProjectionGate <- newEmptyTMVarIO
    events <- newTVarIO []
    blockNextPublish <- newTVarIO False
    publishGate <- newEmptyTMVarIO
    let observeLease _deadline _name =
          atomically $ do
            available <- readTVar leaseAvailable
            if not available
              then
                pure
                  (LeaseUnobservable (Text.pack "fixture Lease authority unavailable"))
              else do
                present <- readTVar leaseRecord
                pure (maybe LeaseMissing LeaseObserved present)
        mutateLease _deadline desired =
          atomically $ do
            available <- readTVar leaseAvailable
            if not available
              then
                pure
                  ( LeaseMutationUnobservable
                      (Text.pack "fixture Lease authority unavailable")
                  )
              else do
                previousVersion <- readTVar leaseVersion
                let nextVersion = previousVersion + 1
                    applied =
                      desired
                        { leaseRecordResourceVersion = Text.pack (show nextVersion)
                        }
                writeTVar leaseVersion nextVersion
                writeTVar leaseRecord (Just applied)
                pure (LeaseMutationApplied applied)
        leaseRuntime =
          EmitterLeaseRuntime
            { leaseRuntimeClient =
                EmitterLeaseClient
                  { leaseClientObserve = observeLease
                  , leaseClientCreate = mutateLease
                  , leaseClientReplace = mutateLease
                  }
            , leaseRuntimeWallNow = getCurrentTime
            , leaseRuntimeMonotonicNow = realMonotonicNow
            }
        observeEvent event = do
          atomically (modifyTVar' events (++ [event]))
          case event of
            EmitterAssertionPublished _ -> do
              shouldBlock <- atomically $ do
                current <- readTVar blockNextPublish
                if current
                  then writeTVar blockNextPublish False >> pure True
                  else pure False
              if shouldBlock
                then atomically (takeTMVar publishGate)
                else pure ()
            EmitterTargetOperationAdmitted TargetPulumiObjectGet _ -> do
              shouldBlock <- atomically $ do
                current <- readTVar blockNextOperation
                if current
                  then writeTVar blockNextOperation False >> pure True
                  else pure False
              if shouldBlock
                then atomically (takeTMVar operationGate)
                else pure ()
            EmitterMountProjectionFsynced -> do
              shouldBlock <- atomically $ do
                current <- readTVar blockNextMountProjection
                if current
                  then writeTVar blockNextMountProjection False >> pure True
                  else pure False
              if shouldBlock
                then atomically (takeTMVar mountProjectionGate)
                else pure ()
            EmitterOrdersMigrationApplied _ ->
              atomically $ do
                shouldFail <- readTVar failNextMigrationFinalFsync
                if shouldFail
                  then do
                    writeTVar failNextMigrationFinalFsync False
                    writeTVar failNextProjectionFsync True
                  else pure ()
            _ -> pure ()
        projectionFsyncGate = do
          decision <- atomically $ do
            shouldFail <- readTVar failNextProjectionFsync
            shouldBlock <- readTVar blockNextProjectionFsync
            if shouldFail
              then do
                writeTVar failNextProjectionFsync False
                writeTVar blockNextProjectionFsync True
                pure (Left "fixture one-shot projection fsync failure")
              else
                if shouldBlock
                  then do
                    writeTVar blockNextProjectionFsync False
                    pure (Right True)
                  else pure (Right False)
          case decision of
            Left err -> pure (Left err)
            Right True ->
              atomically (takeTMVar projectionFsyncRecoveryGate) >> pure (Right ())
            Right False -> pure (Right ())
        peerAckProjectionFsyncGate _projection = do
          decision <- atomically $ do
            shouldFail <- readTVar failNextPeerAckFsync
            shouldBlock <- readTVar blockPeerAckFsyncRecovery
            if shouldFail
              then do
                writeTVar failNextPeerAckFsync False
                writeTVar blockPeerAckFsyncRecovery True
                pure (Left "fixture one-shot peer acknowledgement fsync failure")
              else pure (Right shouldBlock)
          case decision of
            Left err -> pure (Left err)
            Right True -> do
              atomically $ do
                takeTMVar peerAckFsyncRecoveryGate
                writeTVar blockPeerAckFsyncRecovery False
              pure (Right ())
            Right False -> pure (Right ())
        dependencies =
          EmitterRuntimeDependencies
            { emitterDependencyJournalRoot = journalRoot
            , emitterDependencyLoadLeaseRuntime = pure (Right leaseRuntime)
            , emitterDependencyObserveAdmission = \_config _node identity -> do
                atomically (writeTVar observedIdentity (Just identity))
                Right <$> readTVarIO admissionMarker
            , emitterDependencyPersistAdmission = \_config _node ->
                atomically
                  (writeTVar admissionMarker EmitterAdmissionMarkerPresent)
                  >> pure (Right ())
            , emitterDependencyValidateRetirement = \_config _node identity receipt -> do
                expectedNext <- readTVarIO expectedRetirementNext
                pure $ case expectedNext of
                  Nothing -> Left "fixture retirement authority has no indexed successor"
                  Just nextIncarnation
                    | nextIncarnation == 0 ->
                        Left "fixture retirement authority indexed an invalid zero incarnation"
                    | otherwise ->
                        case mkEmitterRetirementReceipt identity (nextIncarnation - 1) of
                          Right expectedReceipt
                            | expectedReceipt == receipt -> Right ()
                          _ ->
                            Left "fixture retirement receipt is not the indexed successor"
            , emitterDependencyProjectionFsyncGate = projectionFsyncGate
            , emitterDependencyPeerAckProjectionFsyncGate = peerAckProjectionFsyncGate
            , emitterDependencyRenewalDelayMicros = const 100000
            , emitterDependencyObserveEvent = observeEvent
            , emitterDependencyLegacyChildSlotInitiallyOccupied = True
            }
        runDaemon =
          runGatewayDaemonWithRuntimeDependencies
            JournalLeaseEmitter
            dependencies
            (Just configPath)
            config
        peerProxyAction =
          runPeerProxy
            peerProxyPort
            peerPort
            peerProxyEnabled
    action
      TargetGatewayFixture
        { targetRunDaemon = runDaemon
        , targetRunPeerProxy = peerProxyAction
        , targetWriteOrders = \version ->
            writeFile
              ordersPath
              (renderTargetOrdersVersion version restPort peerPort peerProxyPort)
        , targetRestPort = restPort
        , targetPeerPort = peerPort
        , targetLeaseAvailable = leaseAvailable
        , targetLeaseRecord = leaseRecord
        , targetEvents = events
        , targetBlockNextPublish = blockNextPublish
        , targetPublishGate = publishGate
        , targetAdmissionMarker = admissionMarker
        , targetObservedIdentity = observedIdentity
        , targetExpectedRetirementNext = expectedRetirementNext
        , targetJournalFile = journalRoot </> "emitter.journal.enc"
        , targetFailNextProjectionFsync = failNextProjectionFsync
        , targetProjectionFsyncRecoveryGate = projectionFsyncRecoveryGate
        , targetPeerProxyEnabled = peerProxyEnabled
        , targetFailNextPeerAckFsync = failNextPeerAckFsync
        , targetPeerAckFsyncRecoveryGate = peerAckFsyncRecoveryGate
        , targetBlockNextOperation = blockNextOperation
        , targetOperationGate = operationGate
        , targetBlockNextMountProjection = blockNextMountProjection
        , targetFailNextMigrationFinalFsync = failNextMigrationFinalFsync
        }

withRunningTargetGateway :: TargetGatewayFixture -> IO a -> IO a
withRunningTargetGateway fixture action =
  withAsync (targetRunPeerProxy fixture) $ \_peerProxy ->
    withAsync (targetRunDaemon fixture) $ \_daemon -> do
      waitForHttpStatus (targetRestPort fixture) "/healthz" 200
      action

waitForPublishedEmitterBytes :: TargetGatewayFixture -> IO BS8.ByteString
waitForPublishedEmitterBytes fixture =
  waitForEmitterEvent fixture publishedBytes

waitForRespondedEmitterBytes :: TargetGatewayFixture -> IO BS8.ByteString
waitForRespondedEmitterBytes fixture =
  waitForEmitterEvent fixture respondedBytes

waitForMountUnavailable :: TargetGatewayFixture -> IO String
waitForMountUnavailable fixture =
  waitForEmitterEvent fixture mountUnavailableDetail

pulumiObjectOperationDeadline :: EmitterRuntimeEvent -> Maybe Deadline
pulumiObjectOperationDeadline event = case event of
  EmitterTargetOperationAdmitted TargetPulumiObjectGet deadline -> Just deadline
  _ -> Nothing

pulumiObjectOperationAdmitted :: EmitterRuntimeEvent -> Maybe ()
pulumiObjectOperationAdmitted event = case event of
  EmitterTargetOperationAdmitted TargetPulumiObjectGet _ -> Just ()
  _ -> Nothing

matchingEmitterEvent :: EmitterRuntimeEvent -> EmitterRuntimeEvent -> Maybe ()
matchingEmitterEvent expected observed
  | observed == expected = Just ()
  | otherwise = Nothing

ordersMigrationAdmission :: EmitterRuntimeEvent -> Maybe (BS8.ByteString, Int)
ordersMigrationAdmission event = case event of
  EmitterOrdersMigrationAdmissionArmed digest pending -> Just (digest, pending)
  _ -> Nothing

ordersMigrationApplied :: EmitterRuntimeEvent -> Maybe Int
ordersMigrationApplied event = case event of
  EmitterOrdersMigrationApplied pending -> Just pending
  _ -> Nothing

projectionFsyncRefusedBytes :: EmitterRuntimeEvent -> Maybe BS8.ByteString
projectionFsyncRefusedBytes event = case event of
  EmitterProjectionFsyncRefused bytes -> Just bytes
  _ -> Nothing

matchingProjectionFsynced :: BS8.ByteString -> EmitterRuntimeEvent -> Maybe ()
matchingProjectionFsynced expected event = case event of
  EmitterProjectionFsynced bytes
    | bytes == expected -> Just ()
  _ -> Nothing

publishedBytes :: EmitterRuntimeEvent -> Maybe BS8.ByteString
publishedBytes event = case event of
  EmitterAssertionPublished bytes -> Just bytes
  _ -> Nothing

matchingPublishedBytes :: BS8.ByteString -> EmitterRuntimeEvent -> Maybe BS8.ByteString
matchingPublishedBytes expected event = case publishedBytes event of
  Just bytes
    | bytes == expected -> Just bytes
  _ -> Nothing

respondedBytes :: EmitterRuntimeEvent -> Maybe BS8.ByteString
respondedBytes event = case event of
  EmitterRequestResponded bytes -> Just bytes
  _ -> Nothing

mountUnavailableDetail :: EmitterRuntimeEvent -> Maybe String
mountUnavailableDetail event = case event of
  EmitterMountUnavailable detail -> Just detail
  _ -> Nothing

waitForObservedIdentity :: TargetGatewayFixture -> IO JournalIdentity
waitForObservedIdentity fixture = do
  result <- pollUntilReady httpStatusRetryPolicy probe
  case result of
    Right identity -> pure identity
    Left detail -> expectationFailure (Text.unpack detail) >> error "unreachable"
 where
  probe = do
    observed <- readTVarIO (targetObservedIdentity fixture)
    pure $ case observed of
      Just identity -> PollReady identity
      Nothing -> PollPending (Text.pack "timed out waiting for observed journal identity")

retirementReceipt :: JournalIdentity -> Word64 -> EmitterRetirementReceipt
retirementReceipt identity priorIncarnation =
  either (error . renderJournalError) id $
    mkEmitterRetirementReceipt identity priorIncarnation

waitForEmitterEvent
  :: TargetGatewayFixture
  -> (EmitterRuntimeEvent -> Maybe selected)
  -> IO selected
waitForEmitterEvent fixture selectEvent = do
  result <- pollUntilReady httpStatusRetryPolicy probe
  case result of
    Right bytes -> pure bytes
    Left detail -> expectationFailure (Text.unpack detail) >> error "unreachable"
 where
  probe = do
    events <- readTVarIO (targetEvents fixture)
    pure $ case firstSelected selectEvent events of
      Just bytes -> PollReady bytes
      Nothing -> PollPending (Text.pack "timed out waiting for emitter runtime event")

firstSelected :: (value -> Maybe selected) -> [value] -> Maybe selected
firstSelected _ [] = Nothing
firstSelected selectValue (value : rest) =
  case selectValue value of
    Just selected -> Just selected
    Nothing -> firstSelected selectValue rest

eventIndex :: EmitterRuntimeEvent -> [EmitterRuntimeEvent] -> Int
eventIndex expected events =
  case elemIndex expected events of
    Just index -> index
    Nothing -> error ("missing target emitter event: " ++ show expected)

checkpointEventCount :: [EmitterRuntimeEvent] -> Int
checkpointEventCount = length . filter isCheckpoint
 where
  isCheckpoint event = case event of
    EmitterCheckpointInstalled _ -> True
    _ -> False

peerCursorPresent :: String -> HttpResponse -> Bool
peerCursorPresent peerName response =
  case eitherDecode (BL8.pack (responseBody response)) of
    Right (Object stateObject) ->
      case KeyMap.lookup (Key.fromString "peer_receive_cursors") stateObject of
        Just (Object cursors) -> KeyMap.member (Key.fromString peerName) cursors
        _ -> False
    _ -> False

waitForPeerCursor :: TargetGatewayFixture -> String -> IO ()
waitForPeerCursor fixture peerName = do
  result <- pollUntilReady httpStatusRetryPolicy probe
  case result of
    Right () -> pure ()
    Left detail -> expectationFailure (Text.unpack detail)
 where
  probe = do
    response <- readHttp (targetRestPort fixture) "/v1/state"
    pure $
      if peerCursorPresent peerName response
        then PollReady ()
        else PollPending (Text.pack ("timed out waiting for peer cursor " ++ peerName))

data HttpResponse = HttpResponse
  { responseStatus :: Int
  , responseBody :: String
  }
  deriving (Eq, Show)

withGatewayDaemon :: Int -> (RunningGatewayDaemon -> IO a) -> IO a
withGatewayDaemon drainDeadlineSeconds action =
  withGatewayDaemonWithConfig renderConfig drainDeadlineSeconds action

withGatewayDaemonWithConfig
  :: (FilePath -> FilePath -> FilePath -> FilePath -> Int -> Maybe String -> String)
  -> Int
  -> (RunningGatewayDaemon -> IO a)
  -> IO a
withGatewayDaemonWithConfig renderConfigFn drainDeadlineSeconds action =
  withSystemTempDirectory "prodbox-gateway-daemon" $ \tmpDir -> do
    repoRoot <- getCurrentDirectory
    binary <- resolveProdboxBinary repoRoot
    restPort <- allocateTcpPort
    peerPort <- allocateTcpPort
    let certPath = tmpDir </> "node-a.crt"
        keyPath = tmpDir </> "node-a.key"
        caPath = tmpDir </> "ca.crt"
        ordersPath = tmpDir </> "orders.dhall"
        configPath = tmpDir </> "gateway.dhall"
    writeFile certPath "cert"
    writeFile keyPath "key"
    writeFile caPath "ca"
    writeFile ordersPath (renderOrders restPort peerPort)
    let writeConfig deadlineSeconds maybeLogLevel =
          writeFile
            configPath
            (renderConfigFn certPath keyPath caPath ordersPath deadlineSeconds maybeLogLevel)
    writeConfig drainDeadlineSeconds Nothing
    bracket
      (startGatewayProcess binary tmpDir configPath restPort peerPort writeConfig)
      stopGatewayProcess
      action

resolveProdboxBinary :: FilePath -> IO FilePath
resolveProdboxBinary repoRoot = do
  let syncedBinary = repoRoot </> ".build" </> "prodbox"
  _ <-
    runCommandSuccess
      (Subprocess "cabal" ["build", "--builddir=.build", "exe:prodbox"] Nothing Nothing)
  listBin <-
    runCommandSuccess
      (Subprocess "cabal" ["list-bin", "--builddir=.build", "exe:prodbox"] Nothing Nothing)
  let compiledBinary = trim (processStdout listBin)
  pure $
    if null compiledBinary
      then syncedBinary
      else compiledBinary

runCommandSuccess :: Subprocess -> IO ProcessOutput
runCommandSuccess command = do
  result <- captureSubprocessResult command
  case result of
    Failure err -> ioError (userError err)
    Success output ->
      if processExitCode output == ExitSuccess
        then pure output
        else
          ioError
            ( userError
                ( "command failed: "
                    ++ subprocessPath command
                    ++ " "
                    ++ unwords (subprocessArguments command)
                    ++ "\n"
                    ++ processStderr output
                )
            )

startGatewayProcess
  :: FilePath
  -> FilePath
  -> FilePath
  -> Int
  -> Int
  -> (Int -> Maybe String -> IO ())
  -> IO RunningGatewayDaemon
startGatewayProcess binary workingDir configPath restPort peerPort writeConfig = do
  startResult <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = binary
        , subprocessArguments = ["gateway", "start", "--config", configPath]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just workingDir
        }
  case startResult of
    Left err -> ioError (userError (show err))
    Right process ->
      pure
        RunningGatewayDaemon
          { daemonBackgroundProcess = process
          , daemonRestPort = restPort
          , daemonPeerPort = peerPort
          , daemonWriteConfig = writeConfig
          }

stopGatewayProcess :: RunningGatewayDaemon -> IO ()
stopGatewayProcess daemon =
  stopBackgroundProcess (daemonBackgroundProcess daemon)

terminateGatewayDaemon :: RunningGatewayDaemon -> IO ()
terminateGatewayDaemon daemon =
  terminateBackgroundProcess (daemonBackgroundProcess daemon)

waitForProcessExitSuccess :: RunningGatewayDaemon -> Int -> IO ()
waitForProcessExitSuccess daemon timeoutSeconds = do
  result <-
    timeout
      (timeoutSeconds * 1000000)
      (waitBackgroundProcess (daemonBackgroundProcess daemon))
  case result of
    Nothing -> expectationFailure "gateway daemon did not exit before the test timeout"
    Just (Left err) -> expectationFailure (show err)
    Just (Right exitCode) -> exitCode `shouldBe` ExitSuccess

readDaemonStderr :: RunningGatewayDaemon -> IO String
readDaemonStderr daemon =
  case backgroundStderrHandle (daemonBackgroundProcess daemon) of
    Nothing -> pure ""
    Just handle -> do
      contents <- hGetContents handle
      length contents `seq` pure contents

assertStructuredLogLine :: String -> IO ()
assertStructuredLogLine rawLine =
  case eitherDecode (BL8.pack rawLine) of
    Left err -> expectationFailure ("daemon stderr log line was not JSON: " ++ err)
    Right (Object obj) -> do
      assertStringField obj "timestamp_utc"
      assertStringField obj "severity"
      assertStringField obj "event"
    Right _ -> expectationFailure "daemon stderr log line was not a JSON object"

stateHasKey :: KeyMap.KeyMap Value -> String -> Bool
stateHasKey obj fieldName =
  KeyMap.member (Key.fromString fieldName) obj

assertStringField :: KeyMap.KeyMap Value -> String -> IO ()
assertStringField obj fieldName =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (String value)
      | not (Text.null value) -> pure ()
    _ -> expectationFailure ("daemon structured log line is missing string field `" ++ fieldName ++ "`")

renderEndpointGolden :: String -> IO BL8.ByteString
renderEndpointGolden path =
  withGatewayDaemon 5 $ \daemon -> do
    waitForHttpStatus (daemonRestPort daemon) "/healthz" 200
    BL8.pack . renderHttpResponseForGolden <$> readHttp (daemonRestPort daemon) path

renderDrainingReadyzGolden :: IO BL8.ByteString
renderDrainingReadyzGolden =
  withGatewayDaemon 5 $ \daemon -> do
    waitForHttpStatus (daemonRestPort daemon) "/healthz" 200
    terminateGatewayDaemon daemon
    waitForHttpStatus (daemonRestPort daemon) "/readyz" 503
    BL8.pack . renderHttpResponseForGolden <$> readHttp (daemonRestPort daemon) "/readyz"

renderReadyzReadyGolden :: IO BL8.ByteString
renderReadyzReadyGolden =
  withTargetGatewayFixture $ \fixture ->
    withRunningTargetGateway fixture $ do
      waitForHttpStatus (targetRestPort fixture) "/readyz" 200
      BL8.pack . renderHttpResponseForGolden
        <$> readHttp (targetRestPort fixture) "/readyz"

renderMetricsGolden :: IO BL8.ByteString
renderMetricsGolden =
  withGatewayDaemon 5 $ \daemon -> do
    waitForHttpStatus (daemonRestPort daemon) "/healthz" 200
    metrics <- readHttp (daemonRestPort daemon) "/metrics"
    pure
      ( BL8.pack
          (renderHttpResponseForGolden metrics {responseBody = normalizeMetricsBody (responseBody metrics)})
      )

renderHttpResponseForGolden :: HttpResponse -> String
renderHttpResponseForGolden response =
  unlines
    [ "status: " ++ show (responseStatus response)
    , "body:"
    , responseBody response
    ]

normalizeMetricsBody :: String -> String
normalizeMetricsBody =
  intercalate "\n" . map normalizeMetricLine . lines
 where
  normalizeMetricLine line
    | "#" `prefixOf` line = line
    | null (words line) = line
    | otherwise =
        case words line of
          [metric, _value] -> metric ++ " <number>"
          _ -> line

allocateTcpPort :: IO Int
allocateTcpPort =
  withSocketsDo $
    bracket
      (socket AF_INET Stream defaultProtocol)
      close
      ( \sock -> do
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 1
          sockAddr <- getSocketName sock
          case sockAddr of
            SockAddrInet port _ -> pure (fromIntegral port)
            _ -> ioError (userError "expected IPv4 socket address while allocating a test port")
      )

-- | Readiness poll for an HTTP endpoint reaching the expected status. A
-- not-yet-ready reading is a steady-state observation, not an error, so
-- this routes through 'pollUntilReady' rather than the error retrier.
waitForHttpStatus :: Int -> String -> Int -> IO ()
waitForHttpStatus port path expectedStatus = do
  result <- pollUntilReady httpStatusRetryPolicy probe
  case result of
    Right () -> pure ()
    Left detail -> expectationFailure (Text.unpack detail)
 where
  probe = do
    result <- tryReadHttp port path
    pure $
      case result of
        Right response
          | responseStatus response == expectedStatus -> PollReady ()
        _ ->
          PollPending
            ( Text.pack
                ( "timed out waiting for "
                    ++ path
                    ++ " status "
                    ++ show expectedStatus
                    ++ "; last result: "
                    ++ show result
                )
            )

httpStatusRetryPolicy :: RetryPolicy
httpStatusRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 50
    , retryPolicyBaseDelayMicros = 100000
    , retryPolicyMultiplier = 1
    , retryPolicyMaxDelayMicros = 100000
    }

readHttp :: Int -> String -> IO HttpResponse
readHttp port path = do
  result <- tryReadHttp port path
  case result of
    Right response -> pure response
    Left err -> ioError (userError err)

tryReadHttp :: Int -> String -> IO (Either String HttpResponse)
tryReadHttp port path = tryReadHttpRequest port (httpRequest path)

readHttpRequest :: Int -> String -> IO HttpResponse
readHttpRequest port request = do
  result <- tryReadHttpRequest port request
  case result of
    Right response -> pure response
    Left err -> ioError (userError err)

tryReadHttpRequest :: Int -> String -> IO (Either String HttpResponse)
tryReadHttpRequest port request =
  withSocketsDo $
    bracket
      (socket AF_INET Stream defaultProtocol)
      close
      ( \sock -> do
          connectResult <- tryConnect sock port
          case connectResult of
            Left err -> pure (Left err)
            Right () -> do
              sendAll sock (BS8.pack request)
              raw <- receiveUntilClose sock []
              pure (parseHttpResponse (BS8.unpack (BS8.concat (reverse raw))))
      )

tryConnect :: Socket -> Int -> IO (Either String ())
tryConnect sock port = do
  result <-
    tryAny (connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1))))
  pure $
    case result of
      Left err -> Left err
      Right () -> Right ()

receiveUntilClose :: Socket -> [BS8.ByteString] -> IO [BS8.ByteString]
receiveUntilClose sock chunks = do
  chunk <- recv sock 4096
  if BS8.null chunk
    then pure chunks
    else receiveUntilClose sock (chunk : chunks)

runPeerProxy :: Int -> Int -> TMVar () -> IO ()
runPeerProxy listenPort upstreamPort enabled =
  withSocketsDo $
    bracket openListener close $ \listener ->
      forever $
        bracket (fst <$> accept listener) close $ \client -> do
          request <- receiveOneHttpMessage client BS8.empty
          atomically (readTMVar enabled)
          bracket
            (socket AF_INET Stream defaultProtocol)
            close
            ( \upstream -> do
                connect
                  upstream
                  (SockAddrInet (fromIntegral upstreamPort) (tupleToHostAddress (127, 0, 0, 1)))
                sendAll upstream request
                responseChunks <- receiveUntilClose upstream []
                sendAll client (BS8.concat (reverse responseChunks))
            )
 where
  openListener = do
    listener <- socket AF_INET Stream defaultProtocol
    setSocketOption listener ReuseAddr 1
    bind
      listener
      (SockAddrInet (fromIntegral listenPort) (tupleToHostAddress (127, 0, 0, 1)))
    listen listener 16
    pure listener

receiveOneHttpMessage :: Socket -> BS8.ByteString -> IO BS8.ByteString
receiveOneHttpMessage sock accumulated =
  case completeHttpMessageLength accumulated of
    Just totalLength
      | BS8.length accumulated >= totalLength ->
          pure (BS8.take totalLength accumulated)
    _ -> do
      chunk <- recv sock 4096
      if BS8.null chunk
        then pure accumulated
        else receiveOneHttpMessage sock (accumulated <> chunk)

completeHttpMessageLength :: BS8.ByteString -> Maybe Int
completeHttpMessageLength bytes = do
  let marker = BS8.pack "\r\n\r\n"
      (header, suffix) = BS8.breakSubstring marker bytes
  if BS8.null suffix
    then Nothing
    else do
      contentLength <- parseContentLength (BS8.unpack header)
      pure (BS8.length header + BS8.length marker + contentLength)

parseContentLength :: String -> Maybe Int
parseContentLength rawHeader =
  case [ parsed
       | line <- lines rawHeader
       , ["Content-Length:", rawLength] <- [words line]
       , Just parsed <- [readMaybeInt rawLength]
       ] of
    parsed : _ -> Just parsed
    [] -> Just 0

parseHttpResponse :: String -> Either String HttpResponse
parseHttpResponse raw =
  case lines raw of
    statusLine : _ ->
      let statusCode = parseStatusCode statusLine
          body = dropHeader raw
       in case statusCode of
            Just code -> Right (HttpResponse code body)
            Nothing -> Left ("could not parse status line: " ++ statusLine)
    [] -> Left "empty HTTP response"

parseStatusCode :: String -> Maybe Int
parseStatusCode statusLine =
  case words statusLine of
    _httpVersion : codeText : _ -> readMaybeInt codeText
    _ -> Nothing

dropHeader :: String -> String
dropHeader raw =
  case breakOn "\r\n\r\n" raw of
    Just (_, body) -> body
    Nothing ->
      case breakOn "\n\n" raw of
        Just (_, body) -> body
        Nothing -> ""

breakOn :: String -> String -> Maybe (String, String)
breakOn needle haystack = go "" haystack
 where
  go _ [] = Nothing
  go prefix rest
    | needle `prefixOf` rest = Just (reverse prefix, drop (length needle) rest)
    | otherwise =
        case rest of
          c : remaining -> go (c : prefix) remaining

prefixOf :: String -> String -> Bool
prefixOf prefix value =
  take (length prefix) value == prefix

httpRequest :: String -> String
httpRequest path =
  "GET " ++ path ++ " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"

postJsonRequest :: String -> String -> String
postJsonRequest path body =
  "POST "
    ++ path
    ++ " HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: "
    ++ show (length body)
    ++ "\r\nConnection: close\r\n\r\n"
    ++ body

isOpenDeadline :: DeadlineObservation -> Bool
isOpenDeadline observation = case observation of
  DeadlineOpen _ -> True
  _ -> False

-- | Render a current-schema gateway daemon config (Sprint 3.18 SecretRef
-- shape, decoded by 'Prodbox.Gateway.Settings.loadDaemonConfig').
--
-- The daemon's production config loader resolves @event_keys@,
-- @aws_creds@, and @minio_creds@ through Vault Kubernetes auth
-- ('resolveGatewaySecretRef' with @ProductionMode@). The lifecycle suite
-- launches a real daemon without a live Vault and exercises only the
-- health / readiness / metrics / @/v1/state@ / SIGTERM-drain surface — it
-- never signs an event for @node-a@, so the fixture carries no resolvable
-- secret material:
--
--   * @event_keys = []@ — no SecretRef is resolved, so the loader never
--     reaches a Vault read. A daemon with no key for its own node logs a
--     tolerated @event_key_missing@ warning and keeps serving (see
--     'heartbeatLoop' / 'appendOwnershipEvent' in @Gateway/Daemon.hs@), so
--     this does not weaken any lifecycle assertion. The
--     @prodbox_gateway_events_total@ metric is emitted unconditionally.
--   * @aws_creds = None@ / @minio_creds = None@ — both are @Optional@ on the
--     current @boot@ schema; the lifecycle suite drives no DNS-write or
--     object-store path.
--   * @vault = None@ — no Vault Kubernetes auth is attempted.
--
-- Vault-pointer placeholders (@SecretRef.Vault { mount, path, field }@,
-- matching @charts/gateway/templates/configmap-config.yaml@) are not used
-- here precisely because they would force a Vault read at load time that the
-- test context cannot satisfy.
renderConfig :: FilePath -> FilePath -> FilePath -> FilePath -> Int -> Maybe String -> String
renderConfig certPath keyPath caPath ordersPath drainDeadlineSeconds maybeLogLevel =
  unlines
    [ "{ schemaVersion = 1"
    , ", vault ="
    , "    None"
    , "      { address : Text"
    , "      , auth_path : Text"
    , "      , role : Text"
    , "      , service_account_token_file : Optional Text"
    , "      }"
    , ", boot ="
    , "  { node_id = \"node-a\""
    , "  , cert_file = " ++ show certPath
    , "  , key_file = " ++ show keyPath
    , "  , ca_file = " ++ show caPath
    , "  , orders_file = " ++ show ordersPath
    , "  , event_keys ="
    , "    [] : List { name : Text, value : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text > }"
    , "  , dns_write_gate ="
    , "      None { zone_id : Text, fqdn : Text, ttl : Natural, aws_region : Text }"
    , "  , aws_creds ="
    , "      None"
    , "        { access_key_id : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        , secret_access_key : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        , session_token : Optional < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        , region : Text"
    , "        }"
    , "  , minio_creds ="
    , "      None"
    , "        { minio_access_key : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        , minio_secret_key : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        }"
    , "  , minio_endpoint_url = None Text"
    , "  }"
    , ", live ="
    , "  { heartbeat_interval_seconds = 0.2"
    , "  , reconnect_interval_seconds = 0.2"
    , "  , sync_interval_seconds = 0.2"
    , "  , max_clock_skew_seconds = 10.0"
    , "  , drain_deadline_seconds = Some " ++ show drainDeadlineSeconds
    , "  , log_level = " ++ maybe "None Text" (\l -> "Some " ++ show l) maybeLogLevel
    , "  }"
    , "}"
    ]

renderTargetConfig
  :: FilePath -> FilePath -> FilePath -> FilePath -> Int -> Maybe String -> String
renderTargetConfig certPath keyPath caPath ordersPath drainDeadlineSeconds maybeLogLevel =
  Text.unpack $
    Text.replace
      ( Text.pack
          "    [] : List { name : Text, value : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text > }"
      )
      ( Text.pack
          "    [ { name = \"node-a\", value = < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >.TestPlaintext \"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\" }\n    , { name = \"node-b\", value = < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >.TestPlaintext \"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\" }\n    ]"
      )
      ( Text.pack
          (renderConfig certPath keyPath caPath ordersPath drainDeadlineSeconds maybeLogLevel)
      )

renderPreVaultConfig
  :: FilePath -> FilePath -> FilePath -> FilePath -> Int -> Maybe String -> String
renderPreVaultConfig certPath keyPath caPath ordersPath drainDeadlineSeconds maybeLogLevel =
  unlines
    [ "{ schemaVersion = 1"
    , ", vault ="
    , "    Some"
    , "      { address = \"http://127.0.0.1:1\""
    , "      , auth_path = \"kubernetes\""
    , "      , role = \"gateway-gateway\""
    , "      , service_account_token_file = Some \"/definitely/missing/prodbox-token\""
    , "      }"
    , ", boot ="
    , "  { node_id = \"node-a\""
    , "  , cert_file = " ++ show certPath
    , "  , key_file = " ++ show keyPath
    , "  , ca_file = " ++ show caPath
    , "  , orders_file = " ++ show ordersPath
    , "  , event_keys ="
    , "    [ { name = \"node-a\""
    , "      , value ="
    , "          < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >.Vault"
    , "            { mount = \"secret\", path = \"gateway/gateway/node-a/event-key\", field = \"key\" }"
    , "      }"
    , "    ]"
    , "  , dns_write_gate ="
    , "      None { zone_id : Text, fqdn : Text, ttl : Natural, aws_region : Text }"
    , "  , aws_creds ="
    , "      None"
    , "        { access_key_id : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        , secret_access_key : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        , session_token : Optional < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        , region : Text"
    , "        }"
    , "  , minio_creds ="
    , "      None"
    , "        { minio_access_key : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        , minio_secret_key : < Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"
    , "        }"
    , "  , minio_endpoint_url = Some \"http://minio.prodbox.svc.cluster.local:9000\""
    , "  }"
    , ", live ="
    , "  { heartbeat_interval_seconds = 0.2"
    , "  , reconnect_interval_seconds = 0.2"
    , "  , sync_interval_seconds = 0.2"
    , "  , max_clock_skew_seconds = 10.0"
    , "  , drain_deadline_seconds = Some " ++ show drainDeadlineSeconds
    , "  , log_level = " ++ maybe "None Text" (\l -> "Some " ++ show l) maybeLogLevel
    , "  }"
    , "}"
    ]

renderOrders :: Int -> Int -> String
renderOrders restPort peerPort =
  unlines
    [ "{ version_utc = 1"
    , ", nodes ="
    , "  [ { node_id = \"node-a\""
    , "    , stable_dns_name = \"127.0.0.1\""
    , "    , rest_host = \"127.0.0.1\""
    , "    , rest_port = " ++ show restPort
    , "    , socket_host = \"127.0.0.1\""
    , "    , socket_port = " ++ show peerPort
    , "    }"
    , "  ]"
    , ", gateway_rule ="
    , "    { ranked_nodes = [ \"node-a\" ]"
    , "    , heartbeat_timeout_seconds = 3"
    , "    }"
    , "}"
    ]

renderTargetOrders :: Int -> Int -> Int -> String
renderTargetOrders restPort peerPort peerProxyPort =
  renderTargetOrdersVersion 1 restPort peerPort peerProxyPort

renderTargetOrdersVersion :: Int -> Int -> Int -> Int -> String
renderTargetOrdersVersion version restPort peerPort peerProxyPort =
  unlines
    [ "{ version_utc = " ++ show version
    , ", nodes ="
    , "  [ { node_id = \"node-a\""
    , "    , stable_dns_name = \"127.0.0.1\""
    , "    , rest_host = \"127.0.0.1\""
    , "    , rest_port = " ++ show restPort
    , "    , socket_host = \"127.0.0.1\""
    , "    , socket_port = " ++ show peerPort
    , "    }"
    , "  , { node_id = \"node-b\""
    , "    , stable_dns_name = \"127.0.0.1\""
    , "    , rest_host = \"127.0.0.1\""
    , "    , rest_port = " ++ show peerProxyPort
    , "    , socket_host = \"127.0.0.1\""
    , "    , socket_port = " ++ show peerProxyPort
    , "    }"
    , "  ]"
    , ", gateway_rule ="
    , "    { ranked_nodes = [ \"node-a\", \"node-b\" ]"
    , "    , heartbeat_timeout_seconds = 3"
    , "    }"
    , "}"
    ]

tryAny :: IO a -> IO (Either String a)
tryAny action = do
  result <- try action
  pure $
    case result of
      Left (err :: SomeException) -> Left (show err)
      Right value -> Right value

readMaybeInt :: String -> Maybe Int
readMaybeInt value =
  case reads value of
    [(parsed, "")] -> Just parsed
    _ -> Nothing

trim :: String -> String
trim = reverse . dropWhile (`elem` ['\n', '\r', ' ', '\t']) . reverse
