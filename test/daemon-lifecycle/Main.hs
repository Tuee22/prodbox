{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception
  ( SomeException
  , bracket
  , try
  )
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text qualified as Text
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (SockAddrInet)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
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
import Prodbox.CLI.Spec
  ( findCommandSpec
  )
import Prodbox.Gateway
  ( resolveGatewayConfigPath
  )
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
import System.Directory (getCurrentDirectory)
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
    it "serves health, readiness, metrics, and drains to exit success on SIGTERM" $
      withGatewayDaemon 5 $ \daemon -> do
        readinessResult <- tryAny (waitForHttpStatus (daemonRestPort daemon) "/readyz" 200)
        case readinessResult of
          Right () -> pure ()
          Left err -> do
            stderrText <- readDaemonStderr daemon
            expectationFailure
              ( "readiness probe failed: "
                  ++ err
                  ++ "\n=== daemon stderr ===\n"
                  ++ stderrText
              )
        readHttp (daemonRestPort daemon) "/healthz"
          `shouldReturn` HttpResponse 200 "ok\n"
        metrics <- readHttp (daemonRestPort daemon) "/metrics"
        responseStatus metrics `shouldBe` 200
        responseBody metrics `shouldContain` "prodbox_gateway_events_total"
        terminateGatewayDaemon daemon
        waitForHttpStatus (daemonRestPort daemon) "/readyz" 503
        waitForProcessExitSuccess daemon 10

    it "forces drain promptly when SIGTERM arrives twice" $
      withGatewayDaemon 5 $ \daemon -> do
        waitForHttpStatus (daemonRestPort daemon) "/readyz" 200
        terminateGatewayDaemon daemon
        waitForHttpStatus (daemonRestPort daemon) "/readyz" 503
        terminateGatewayDaemon daemon
        waitForProcessExitSuccess daemon 10

    it "emits structured JSON log lines on stderr" $
      withGatewayDaemon 5 $ \daemon -> do
        waitForHttpStatus (daemonRestPort daemon) "/readyz" 200
        terminateGatewayDaemon daemon
        waitForProcessExitSuccess daemon 10
        stderrText <- readDaemonStderr daemon
        case filter (not . null) (lines stderrText) of
          firstLine : _ -> assertStructuredLogLine firstLine
          [] -> expectationFailure "expected at least one daemon log line on stderr"

    it "binds diagnostics in pre-Vault mode before SecretRef resolution succeeds" $
      withGatewayDaemonWithConfig renderPreVaultConfig 5 $ \daemon -> do
        waitForHttpStatus (daemonRestPort daemon) "/readyz" 200
        readHttp (daemonRestPort daemon) "/healthz"
          `shouldReturn` HttpResponse 200 "ok\n"
        federationResponse <- readHttp (daemonRestPort daemon) "/v1/federation/children"
        responseStatus federationResponse `shouldBe` 503
        responseBody federationResponse `shouldContain` "gateway service-account token"
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
        waitForHttpStatus (daemonRestPort daemon) "/readyz" 200
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

  describe "gateway daemon health endpoint goldens" $ do
    goldenTest
      "keeps /healthz response shape stable"
      "test/golden/daemon-health/healthz.golden"
      (renderEndpointGolden "/healthz")

    goldenTest
      "keeps ready /readyz response shape stable"
      "test/golden/daemon-health/readyz-ready.golden"
      (renderEndpointGolden "/readyz")

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
  , daemonWriteConfig :: Int -> Maybe String -> IO ()
  }

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
      (startGatewayProcess binary tmpDir configPath restPort writeConfig)
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
  -> (Int -> Maybe String -> IO ())
  -> IO RunningGatewayDaemon
startGatewayProcess binary workingDir configPath restPort writeConfig = do
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
    waitForHttpStatus (daemonRestPort daemon) "/readyz" 200
    BL8.pack . renderHttpResponseForGolden <$> readHttp (daemonRestPort daemon) path

renderDrainingReadyzGolden :: IO BL8.ByteString
renderDrainingReadyzGolden =
  withGatewayDaemon 5 $ \daemon -> do
    waitForHttpStatus (daemonRestPort daemon) "/readyz" 200
    terminateGatewayDaemon daemon
    waitForHttpStatus (daemonRestPort daemon) "/readyz" 503
    BL8.pack . renderHttpResponseForGolden <$> readHttp (daemonRestPort daemon) "/readyz"

renderMetricsGolden :: IO BL8.ByteString
renderMetricsGolden =
  withGatewayDaemon 5 $ \daemon -> do
    waitForHttpStatus (daemonRestPort daemon) "/readyz" 200
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
  unlines . map normalizeMetricLine . lines
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
tryReadHttp port path =
  withSocketsDo $
    bracket
      (socket AF_INET Stream defaultProtocol)
      close
      ( \sock -> do
          connectResult <- tryConnect sock port
          case connectResult of
            Left err -> pure (Left err)
            Right () -> do
              sendAll sock (BS8.pack (httpRequest path))
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
