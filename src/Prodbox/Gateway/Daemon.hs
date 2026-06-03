{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Daemon
  ( runGatewayDaemon
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently, race, withAsync)
import Control.Concurrent.STM
  ( TChan
  , TQueue
  , TVar
  , atomically
  , modifyTVar'
  , newTChanIO
  , newTQueueIO
  , newTVarIO
  , readTQueue
  , readTVar
  , readTVarIO
  , writeTChan
  , writeTQueue
  , writeTVar
  )
import Control.Exception
  ( AsyncException
  , IOException
  , SomeException
  , bracketOnError
  , displayException
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forever, void, when)
import Crypto.Hash.SHA256 (hash, hmac)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , toJSON
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (intToDigit, toLower)
import Data.List (intercalate, isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (formatShow, iso8601Format)
import Data.Word (Word8)
import GHC.Conc (threadWaitRead)
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (AI_PASSIVE)
  , Family (AF_INET)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , accept
  , addrAddress
  , addrFamily
  , addrFlags
  , addrProtocol
  , addrSocketType
  , bind
  , close
  , connect
  , defaultHints
  , defaultProtocol
  , getAddrInfo
  , listen
  , setSocketOption
  , socket
  , withFdSocket
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.Error
  ( AppError (..)
  , ErrorKind (..)
  , appError
  )
import Prodbox.Gateway.Logging
  ( Severity (..)
  , field
  , logStructuredAt
  , severityFromLogLevel
  )
import Prodbox.Gateway.Peer
  ( PeerEventBatch (..)
  , PeerTransportRequest (..)
  , PeerTransportResponse (..)
  , encodePeerEventBatch
  , handlePeerRequest
  , parsePeerHttpRequest
  , renderPeerHttpResponse
  )
import Prodbox.Gateway.Settings qualified as GatewaySettings
import Prodbox.Gateway.Types
  ( CommitLog (..)
  , DaemonConfig (..)
  , Disposition (..)
  , DnsWriteGate (..)
  , GatewayAwsCreds (..)
  , GatewayMinioCreds (..)
  , GatewayRule (..)
  , Orders (..)
  , PeerEndpoint (..)
  , PeerHealth (..)
  , SignedEvent (..)
  , appendIfNew
  , canWriteDns
  , defaultDrainDeadlineSeconds
  , emptyCommitLog
  , eventTimestampUtc
  , eventTypeClaim
  , eventTypeHeartbeat
  , eventTypeYield
  , extractOrdersVersionFromEvent
  , nodeDisposition
  , peerDialSocketHost
  , validateDaemonTimingAgainstOrders
  )
import Prodbox.Http.Client
  ( defaultHttpConfig
  , httpGetText
  , renderHttpError
  )
import Prodbox.K8s.InCluster qualified as InCluster
import Prodbox.Result (Result (..))
import Prodbox.Retry
  ( RetryPolicy (..)
  , retryDelayMicros
  )
import Prodbox.Secret.Derive qualified
import Prodbox.Secret.EnsureNamespace qualified as EnsureNamespace
import Prodbox.Secret.Inventory qualified as Inventory
import Prodbox.Secret.MasterSeed qualified as MasterSeed
import Prodbox.Secret.Wire qualified as SecretWire
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FSNotify
  ( Event (..)
  , defaultConfig
  , watchDir
  , withManagerConf
  )
import System.FilePath (takeDirectory, takeFileName)
import System.Posix.Signals
  ( Handler (Catch)
  , installHandler
  , sigINT
  , sigTERM
  )
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

-- | In-memory daemon state.  Updated through STM by the loops and HTTP
-- listeners, and rendered onto @/v1/state@ for operator inspection.
data DaemonState = DaemonState
  { stateCommitLog :: CommitLog
  , stateLastHeartbeatTimes :: Map String UTCTime
  , stateGatewayOwner :: Maybe String
  , statePreviousOwner :: Maybe String
  , stateLastPublicIp :: Maybe String
  , stateLastDnsWriteIp :: Maybe String
  , stateLastDnsWriteTime :: Maybe UTCTime
  , stateMeshPeers :: [String]
  , statePeerHealth :: Map String PeerHealth
  , stateMaxObservedSkewSeconds :: Maybe Double
  , stateOrdersVersionUtc :: Int
  , stateLatestObservedOrdersVersion :: Int
  }

data ReadinessState
  = Starting
  | Ready
  | Draining
  deriving (Eq, Show)

data LiveConfig = LiveConfig
  { liveLogLevel :: String
  , liveHeartbeatInterval :: Double
  , liveReconnectInterval :: Double
  , liveSyncInterval :: Double
  , liveMaxClockSkewSeconds :: Double
  , liveDrainDeadlineSeconds :: Int
  }
  deriving (Eq, Show)

data MetricsRegistry = MetricsRegistry
  { metricsDaemonName :: String
  }
  deriving (Eq, Show)

data DaemonHooks = DaemonHooks
  { envAfterPeerEventCommit :: Int -> IO ()
  , envBeforeOrdersAdoption :: Int -> IO ()
  , envOnPeerConnectionEstablished :: String -> IO ()
  }

data DaemonEnv = DaemonEnv
  { envConfigPath :: Maybe FilePath
  , envBootConfig :: DaemonConfig
  , envOrders :: Orders
  , envState :: TVar DaemonState
  , envReadiness :: TVar ReadinessState
  , envLiveConfig :: TVar LiveConfig
  , envLiveConfigReloads :: TChan LiveConfig
  , envMetrics :: MetricsRegistry
  , envDrainSignals :: TQueue DrainSignal
  , envReloadSignals :: TQueue ()
  , envHooks :: DaemonHooks
  , envMasterSeed :: Maybe Prodbox.Secret.Derive.MasterSeed
  -- ^ Sprint 2.19: the master seed retrieved from MinIO at startup. When
  -- the daemon has 'daemonMinioCreds' bound and the seed is readable, the
  -- @/v1/secret/derive@ endpoint composes 'Prodbox.Secret.Derive.derive'
  -- against this value. When MinIO is unavailable (no credentials bound,
  -- or the read fails at startup) the field stays 'Nothing' and the
  -- endpoint returns 503 with the structured reason in the legacy stub.
  }

data DrainSignal
  = BeginDrain
  | ForceDrain
  deriving (Eq, Show)

noopDaemonHooks :: DaemonHooks
noopDaemonHooks =
  DaemonHooks
    { envAfterPeerEventCommit = \_ -> pure ()
    , envBeforeOrdersAdoption = \_ -> pure ()
    , envOnPeerConnectionEstablished = \_ -> pure ()
    }

initialState :: Int -> DaemonState
initialState ordersVersion =
  DaemonState
    { stateCommitLog = emptyCommitLog
    , stateLastHeartbeatTimes = Map.empty
    , stateGatewayOwner = Nothing
    , statePreviousOwner = Nothing
    , stateLastPublicIp = Nothing
    , stateLastDnsWriteIp = Nothing
    , stateLastDnsWriteTime = Nothing
    , stateMeshPeers = []
    , statePeerHealth = Map.empty
    , stateMaxObservedSkewSeconds = Nothing
    , stateOrdersVersionUtc = ordersVersion
    , stateLatestObservedOrdersVersion = ordersVersion
    }

runGatewayDaemon :: Maybe FilePath -> Maybe Int -> String -> DaemonConfig -> IO ExitCode
runGatewayDaemon maybeConfigPath restPortOverride logLevel config = withSocketsDo $ do
  logAtLevel
    logLevel
    Info
    "gateway_starting"
    [ field "node_id" (daemonNodeId config)
    , field "log_level" logLevel
    ]
  -- Sprint 2.22: dispatch by file extension via GatewaySettings.loadOrders
  -- so the chart-rendered Dhall Orders content decodes through the native
  -- dhall library; legacy JSON Orders files continue to work during the
  -- chart transition.
  ordersResult <- GatewaySettings.loadOrders (daemonOrdersFile config)
  case ordersResult of
    Left err -> do
      logAtLevel logLevel Error "orders_parse_failed" [field "detail" err]
      pure (ExitFailure 1)
    Right orders ->
      case validateDaemonTimingAgainstOrders config orders of
        Left err -> do
          logAtLevel logLevel Error "gateway_timing_invalid" [field "detail" err]
          pure (ExitFailure 1)
        Right () ->
          case resolveLocalPeerEndpoint config orders of
            Left err -> do
              logAtLevel logLevel Error "local_gateway_node_invalid" [field "detail" err]
              pure (ExitFailure 1)
            Right localPeer -> do
              startupValidationResult <- validateDaemonStartupInputs config
              case startupValidationResult of
                Left err -> do
                  logAtLevel
                    logLevel
                    Error
                    "gateway_startup_inputs_invalid"
                    [ field "message" ("Failed to validate gateway startup inputs: " ++ err)
                    , field "detail" err
                    ]
                  pure (ExitFailure 1)
                Right () -> do
                  now <- getCurrentTime
                  let localNodeId = daemonNodeId config
                      meshPeers =
                        [ peerNodeId peer
                        | peer <- ordersNodes orders
                        , peerNodeId peer /= localNodeId
                        ]
                      initialDaemonState =
                        (initialState (ordersVersionUtc orders))
                          { stateLastHeartbeatTimes = Map.singleton localNodeId now
                          , stateMeshPeers = meshPeers
                          , statePeerHealth =
                              Map.fromList
                                [(p, PeerHealth Nothing False Nothing) | p <- meshPeers]
                          }
                  stateVar <- newTVarIO initialDaemonState
                  readinessVar <- newTVarIO Starting
                  liveConfigVar <- newTVarIO (liveConfigFromDaemonConfig logLevel config)
                  reloadBroadcast <- newTChanIO
                  drainSignals <- newTQueueIO
                  reloadSignals <- newTQueueIO
                  signalCount <- newTVarIO (0 :: Int)
                  -- Sprint 2.19: attempt to retrieve the master seed from MinIO if
                  -- credentials are bound in the Dhall config. Failures degrade
                  -- gracefully: the daemon stays up and @/v1/secret/derive@ returns
                  -- a structured 503 until the seed becomes available.
                  initialMasterSeed <- acquireInitialMasterSeed logLevel config
                  -- Sprint 3.13 chunk 16: self-bootstrap the gateway's own
                  -- @gateway-event-keys@ Secret. Solves the chicken-and-egg
                  -- where the other charts' pre-install Jobs POST to the
                  -- gateway daemon, but the gateway daemon doesn't exist
                  -- yet to satisfy its own pre-install Job. Failures degrade
                  -- gracefully (running outside k8s, RBAC missing, or
                  -- already-applied): the chart's Helm @lookup@ falls back
                  -- to placeholder values and the next reconcile retries.
                  selfBootstrapOwnSecrets logLevel initialMasterSeed
                  -- Sprint 3.13 chunk 24: derive the gateway's own event
                  -- keys in-memory from the master seed and inject them
                  -- into the BootConfig so the runtime peer/heartbeat
                  -- loops always have valid signing material. The chart's
                  -- @configmap-config.yaml@ renders BEFORE the daemon
                  -- writes its self-bootstrap Secret, so the ConfigMap's
                  -- @event_keys@ list is empty on first install; without
                  -- this in-memory injection the daemon would log
                  -- @event_key_missing@ forever and never sign a real
                  -- peer event. The derivation matches what the daemon's
                  -- own ensure-namespace handler writes for the
                  -- @gateway-event-keys@ Secret, so the in-memory and
                  -- on-cluster values agree by construction.
                  let derivedEventKeys = deriveOwnGatewayEventKeys initialMasterSeed
                      configWithDerivedEventKeys =
                        config {daemonEventKeys = derivedEventKeys}
                  let env =
                        DaemonEnv
                          { envConfigPath = maybeConfigPath
                          , envBootConfig = configWithDerivedEventKeys
                          , envOrders = orders
                          , envState = stateVar
                          , envReadiness = readinessVar
                          , envLiveConfig = liveConfigVar
                          , envLiveConfigReloads = reloadBroadcast
                          , envMetrics = MetricsRegistry "gateway"
                          , envDrainSignals = drainSignals
                          , envReloadSignals = reloadSignals
                          , envHooks = noopDaemonHooks
                          , envMasterSeed = initialMasterSeed
                          }
                  installDaemonSignalHandlers env signalCount

                  logForEnv
                    env
                    Info
                    "orders_loaded"
                    [ field "node_count" (length (ordersNodes orders))
                    , field "orders_version_utc" (ordersVersionUtc orders)
                    ]

                  result <- try (serveGatewayDaemon restPortOverride localPeer env) :: IO (Either SomeException ())
                  case result of
                    Left exc -> do
                      logForEnv env Error "gateway_daemon_error" [field "detail" (show exc)]
                      pure (ExitFailure 1)
                    Right () -> do
                      logForEnv env Info "gateway_stopped" []
                      pure ExitSuccess

liveConfigFromDaemonConfig :: String -> DaemonConfig -> LiveConfig
liveConfigFromDaemonConfig logLevel config =
  LiveConfig
    { liveLogLevel = fromMaybe logLevel (daemonConfigLogLevel config)
    , liveHeartbeatInterval = daemonHeartbeatInterval config
    , liveReconnectInterval = daemonReconnectInterval config
    , liveSyncInterval = daemonSyncInterval config
    , liveMaxClockSkewSeconds = daemonMaxClockSkewSeconds config
    , liveDrainDeadlineSeconds =
        fromMaybe defaultDrainDeadlineSeconds (daemonDrainDeadlineSeconds config)
    }

logAtLevel :: String -> Severity -> Text.Text -> [(Text.Text, Value)] -> IO ()
logAtLevel logLevel =
  logStructuredAt (severityFromLogLevel logLevel)

logForEnv :: DaemonEnv -> Severity -> Text.Text -> [(Text.Text, Value)] -> IO ()
logForEnv env severity eventName fields = do
  liveConfig <- readTVarIO (envLiveConfig env)
  logAtLevel (liveLogLevel liveConfig) severity eventName fields

installDaemonSignalHandlers
  :: DaemonEnv
  -> TVar Int
  -> IO ()
installDaemonSignalHandlers env signalCount = do
  let drainHandler =
        Catch $
          do
            previousCount <- updateSignalCount
            if previousCount == 0
              then do
                atomically (writeTVar (envReadiness env) Draining)
                pure ()
              else pure ()
  _ <- installHandler sigTERM drainHandler Nothing
  _ <- installHandler sigINT drainHandler Nothing
  pure ()
 where
  updateSignalCount =
    atomically $ do
      previousCount <- readTVar signalCount
      writeTVar signalCount (previousCount + 1)
      writeTQueue (envDrainSignals env) $
        if previousCount == 0
          then BeginDrain
          else ForceDrain
      pure previousCount

serveGatewayDaemon :: Maybe Int -> PeerEndpoint -> DaemonEnv -> IO ()
serveGatewayDaemon restPortOverride localPeer env = do
  atomically (writeTVar (envReadiness env) Ready)
  race (drainCoordinator env) (daemonWorkers restPortOverride localPeer env)
    >>= either pure pure

daemonWorkers :: Maybe Int -> PeerEndpoint -> DaemonEnv -> IO ()
daemonWorkers restPortOverride localPeer env =
  withAsync (worker "heartbeat" (heartbeatLoop env)) $ \_ ->
    withAsync (worker "gateway_ownership" (gatewayLoop env)) $ \_ ->
      withAsync (worker "dns_write" (dnsWriteLoop env)) $ \_ ->
        withAsync (worker "rest_server" (restServerLoop restPortOverride localPeer env)) $ \_ ->
          withAsync (worker "peer_listener" (peerListenerLoop localPeer env)) $ \_ ->
            withAsync (worker "config_watch" (configFileWatchLoop env)) $ \_ ->
              void $
                concurrently
                  (worker "peer_dialer" (peerDialerLoop env))
                  (worker "config_reload" (reloadLoop env))
 where
  worker = runWorkerWithRetry env

-- | File-watch worker: subscribes to events on the parent directory of the
-- daemon's `--config` Dhall path so kubelet `..data` symlink swaps trigger
-- reloads. Feeds the existing `envReloadSignals` `TQueue ()` that the
-- `config_reload` worker drains. See
-- [config_doctrine.md § 7](../../documents/engineering/config_doctrine.md#7-file-watch-reload-trigger).
configFileWatchLoop :: DaemonEnv -> IO ()
configFileWatchLoop env =
  case envConfigPath env of
    Nothing -> pure ()
    Just configPath -> do
      let parentDir = takeDirectory configPath
          configName = takeFileName configPath
      withManagerConf defaultConfig $ \manager -> do
        _ <- watchDir manager parentDir (const True) (handleEvent configName)
        forever (threadDelay 1000000)
 where
  handleEvent configName event =
    let eventPath = takeFileName (eventPathFromEvent event)
     in if eventPath == configName || eventPath == "..data"
          then atomically (writeTQueue (envReloadSignals env) ())
          else pure ()

  eventPathFromEvent :: Event -> FilePath
  eventPathFromEvent ev = case ev of
    Added p _ _ -> p
    Modified p _ _ -> p
    ModifiedAttributes p _ _ -> p
    Removed p _ _ -> p
    WatchedDirectoryRemoved p _ _ -> p
    CloseWrite p _ _ -> p
    Unknown p _ _ _ -> p

drainCoordinator :: DaemonEnv -> IO ()
drainCoordinator env = do
  firstSignal <- atomically (readTQueue (envDrainSignals env))
  case firstSignal of
    ForceDrain -> logForEnv env Warn "gateway_force_draining" []
    BeginDrain -> do
      liveConfig <- readTVarIO (envLiveConfig env)
      atomically (writeTVar (envReadiness env) Draining)
      logForEnv
        env
        Info
        "gateway_draining"
        [field "deadline_seconds" (liveDrainDeadlineSeconds liveConfig)]
      race
        (threadDelay (liveDrainDeadlineSeconds liveConfig * 1000000))
        waitForForceDrain
        >>= either pure pure
 where
  waitForForceDrain = do
    signal <- atomically (readTQueue (envDrainSignals env))
    case signal of
      ForceDrain -> logForEnv env Warn "gateway_force_draining" []
      BeginDrain -> waitForForceDrain

runWorkerWithRetry :: DaemonEnv -> String -> IO () -> IO ()
runWorkerWithRetry env workerName action = go 0
 where
  go attemptIndex = do
    result <- try action :: IO (Either SomeException ())
    case result of
      Right () -> do
        readiness <- readTVarIO (envReadiness env)
        if readiness == Draining
          then pure ()
          else do
            logForEnv env Warn "daemon_worker_returned" [field "worker" workerName]
            go 0
      Left exc ->
        do
          readiness <- readTVarIO (envReadiness env)
          if readiness == Draining
            then pure ()
            else case classifyWorkerFailure attemptIndex exc of
              AppError {errorKind = Recoverable} -> do
                logForEnv
                  env
                  Warn
                  "daemon_worker_restarting"
                  [ field "worker" workerName
                  , field "attempt" (attemptIndex + 1)
                  , field "detail" (displayException exc)
                  ]
                threadDelay (retryDelayMicros daemonWorkerRetryPolicy attemptIndex)
                go (attemptIndex + 1)
              AppError {errorKind = Fatal} -> do
                logForEnv
                  env
                  Error
                  "daemon_worker_failed"
                  [ field "worker" workerName
                  , field "detail" (displayException exc)
                  ]
                throwIO exc

classifyWorkerFailure :: Int -> SomeException -> AppError
classifyWorkerFailure attemptIndex exc =
  case fromException exc :: Maybe AsyncException of
    Just _ -> appError Fatal (Text.pack (displayException exc)) (Just exc)
    Nothing ->
      appError
        ( if attemptIndex + 1 < retryPolicyMaxAttempts daemonWorkerRetryPolicy
            then Recoverable
            else Fatal
        )
        (Text.pack (displayException exc))
        (Just exc)

daemonWorkerRetryPolicy :: RetryPolicy
daemonWorkerRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 5
    , retryPolicyBaseDelayMicros = 500000
    , retryPolicyMultiplier = 2
    , retryPolicyMaxDelayMicros = 5000000
    }

reloadLoop :: DaemonEnv -> IO ()
reloadLoop env = forever $ do
  atomically (readTQueue (envReloadSignals env))
  reloadResult <- reloadLiveConfig env
  case reloadResult of
    Left eventName ->
      logForEnv env Warn (Text.pack eventName) []
    Right liveConfig -> do
      atomically $ do
        writeTVar (envLiveConfig env) liveConfig
        writeTChan (envLiveConfigReloads env) liveConfig
      logForEnv
        env
        Info
        "config_reloaded"
        [ field "log_level" (liveLogLevel liveConfig)
        , field "heartbeat_interval_seconds" (liveHeartbeatInterval liveConfig)
        , field "reconnect_interval_seconds" (liveReconnectInterval liveConfig)
        , field "sync_interval_seconds" (liveSyncInterval liveConfig)
        , field "drain_deadline_seconds" (liveDrainDeadlineSeconds liveConfig)
        ]

reloadLiveConfig :: DaemonEnv -> IO (Either String LiveConfig)
reloadLiveConfig env =
  case envConfigPath env of
    Nothing -> pure (Left "config_reload_failed")
    Just path -> do
      loadResult <- GatewaySettings.loadDaemonConfig path
      case loadResult of
        Left err ->
          if "config_schema_mismatch" `isPrefixOf` err
            then pure (Left "config_schema_mismatch")
            else pure (Left "config_reload_failed")
        Right newConfig -> do
          currentLiveConfig <- readTVarIO (envLiveConfig env)
          -- Sprint 2.21 chunk: reapply the in-memory event-key derivation
          -- to the freshly-decoded config before comparing against
          -- 'envBootConfig'. Chunk 16's chart-side @lookup@ stores
          -- base64url values in the Secret; chunk 24's in-memory
          -- derivation uses hex (peer signature verification depends on
          -- the hex encoding). Without this overlay, every reload
          -- compares hex-vs-base64url, so 'daemonBootFieldsChanged'
          -- always returns True and routine 'log_level' edits spuriously
          -- drain the Pod.
          let derivedKeys = deriveOwnGatewayEventKeys (envMasterSeed env)
              newConfigWithDerivedKeys =
                newConfig {daemonEventKeys = derivedKeys}
              bootChanged =
                daemonBootFieldsChanged
                  (envBootConfig env)
                  newConfigWithDerivedKeys
              liveConfig =
                liveConfigFromDaemonConfig
                  (liveLogLevel currentLiveConfig)
                  newConfigWithDerivedKeys
          case validateDaemonTimingAgainstOrders newConfig (envOrders env) of
            Left _ -> pure (Left "config_schema_mismatch")
            Right () ->
              if bootChanged
                then do
                  -- Per [config_doctrine.md § 8](../../documents/engineering/config_doctrine.md#8-boot-vs-live-split-and-the-restart-contract):
                  -- a BootConfig change triggers drain-and-exit so the kubelet
                  -- restarts the Pod against the new Dhall.
                  logForEnv env Warn (Text.pack "config_reload_boot_change_detected") []
                  atomically (writeTQueue (envDrainSignals env) BeginDrain)
                  pure (Left "config_boot_change_drain")
                else pure (Right liveConfig)

daemonBootFieldsChanged :: DaemonConfig -> DaemonConfig -> Bool
daemonBootFieldsChanged old new =
  daemonNodeId old /= daemonNodeId new
    || daemonCertFile old /= daemonCertFile new
    || daemonKeyFile old /= daemonKeyFile new
    || daemonCaFile old /= daemonCaFile new
    || daemonOrdersFile old /= daemonOrdersFile new
    || daemonEventKeys old /= daemonEventKeys new
    || daemonDnsWriteGate old /= daemonDnsWriteGate new

validateDaemonStartupInputs :: DaemonConfig -> IO (Either String ())
validateDaemonStartupInputs config = do
  fileResults <-
    mapM
      (uncurry validateRequiredFile)
      [ ("cert_file", daemonCertFile config)
      , ("key_file", daemonKeyFile config)
      , ("ca_file", daemonCaFile config)
      ]
  pure $
    case [err | Left err <- fileResults] of
      [] -> Right ()
      errors -> Left (intercalate "; " errors)

validateRequiredFile :: String -> FilePath -> IO (Either String ())
validateRequiredFile fieldName path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (fieldName ++ " does not exist: " ++ path))
    else do
      fileResult <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
      pure $
        case fileResult of
          Left err ->
            Left
              ( fieldName
                  ++ " could not be read from "
                  ++ path
                  ++ ": "
                  ++ displayException err
              )
          Right contents ->
            if BS.null contents
              then Left (fieldName ++ " is empty: " ++ path)
              else Right ()

resolveLocalPeerEndpoint :: DaemonConfig -> Orders -> Either String PeerEndpoint
resolveLocalPeerEndpoint config orders =
  case filter (\peer -> peerNodeId peer == daemonNodeId config) (ordersNodes orders) of
    [peer] -> Right peer
    [] -> Left ("local node " ++ daemonNodeId config ++ " not found in orders")
    _ -> Left ("local node " ++ daemonNodeId config ++ " appeared multiple times in orders")

heartbeatLoop :: DaemonEnv -> IO ()
heartbeatLoop env = forever $ do
  let config = envBootConfig env
      stateVar = envState env
      eventKeys = Map.fromList (daemonEventKeys config)
  now <- getCurrentTime
  let nodeId = daemonNodeId config
      heartbeatPayload =
        object
          [ "node_id" .= nodeId
          , "timestamp" .= formatUtcIso now
          ]
  case Map.lookup nodeId eventKeys of
    Nothing -> logForEnv env Warn "event_key_missing" [field "node_id" nodeId]
    Just key -> do
      let event = createSignedEvent nodeId eventTypeHeartbeat heartbeatPayload key now
      atomically $ modifyTVar' stateVar $ \state ->
        state
          { stateCommitLog = appendIfNew (stateCommitLog state) event
          , stateLastHeartbeatTimes =
              Map.insert nodeId now (stateLastHeartbeatTimes state)
          }
  liveConfig <- readTVarIO (envLiveConfig env)
  threadDelay (round (liveHeartbeatInterval liveConfig * 1000000))

-- | Recompute the elected owner from heartbeat freshness, emit signed
-- @claim@/@yield@ events on transitions, and update the in-memory owner
-- view.  Closes the model's ownership-event lifecycle in the runtime.
gatewayLoop :: DaemonEnv -> IO ()
gatewayLoop env = forever $ do
  let config = envBootConfig env
      orders = envOrders env
      stateVar = envState env
      eventKeys = Map.fromList (daemonEventKeys config)
  now <- getCurrentTime
  state <- readTVarIO stateVar
  let nodeId = daemonNodeId config
      rule = ordersGatewayRule orders
      heartbeatTimeout = fromIntegral (heartbeatTimeoutSeconds rule)
      ordersOk = stateLatestObservedOrdersVersion state <= stateOrdersVersionUtc state
      activeNodes =
        [ rankedId
        | rankedId <- rankedNodes rule
        , case Map.lookup rankedId (stateLastHeartbeatTimes state) of
            Just lastHeartbeat -> diffUTCTime now lastHeartbeat < heartbeatTimeout
            Nothing -> rankedId == nodeId
        ]
      owner =
        if not ordersOk
          then Nothing
          else case activeNodes of
            (firstNode : _) -> Just firstNode
            [] -> Nothing
      previous = stateGatewayOwner state
      transitionedToOwner = previous /= Just nodeId && owner == Just nodeId
      transitionedFromOwner = previous == Just nodeId && owner /= Just nodeId
  when transitionedToOwner $
    appendOwnershipEvent
      env
      stateVar
      eventKeys
      nodeId
      eventTypeClaim
      now
      ( object
          [ "claiming_node_id" .= nodeId
          , "previous_owner" .= toMaybeString previous
          ]
      )
  when transitionedFromOwner $
    appendOwnershipEvent
      env
      stateVar
      eventKeys
      nodeId
      eventTypeYield
      now
      ( object
          [ "yielding_node_id" .= nodeId
          , "new_owner" .= toMaybeString owner
          ]
      )
  atomically $ modifyTVar' stateVar $ \s ->
    s
      { stateGatewayOwner = owner
      , statePreviousOwner = previous
      }
  liveConfig <- readTVarIO (envLiveConfig env)
  threadDelay (round (liveHeartbeatInterval liveConfig * 1000000))

toMaybeString :: Maybe String -> Value
toMaybeString Nothing = Null
toMaybeString (Just s) = String (Text.pack s)

appendOwnershipEvent
  :: DaemonEnv
  -> TVar DaemonState
  -> Map String String
  -> String
  -> String
  -> UTCTime
  -> Value
  -> IO ()
appendOwnershipEvent env stateVar eventKeys nodeId evType now payload =
  case Map.lookup nodeId eventKeys of
    Nothing -> logForEnv env Warn "event_key_missing" [field "node_id" nodeId]
    Just key -> do
      let ev = createSignedEvent nodeId evType payload key now
      atomically $ modifyTVar' stateVar $ \s ->
        s {stateCommitLog = appendIfNew (stateCommitLog s) ev}
      logForEnv
        env
        Info
        "gateway_ownership_event_emitted"
        [ field "event_type" evType
        , field "node_id" nodeId
        ]

-- | Write Route 53 only when the runtime CanWriteDns predicate holds: the
-- local node must be the elected owner AND the most recent claim/yield
-- event from the local node must be a claim.
dnsWriteLoop :: DaemonEnv -> IO ()
dnsWriteLoop env = forever $ do
  let config = envBootConfig env
      stateVar = envState env
  state <- readTVarIO stateVar
  let nodeId = daemonNodeId config
      eligible = canWriteDns nodeId (stateGatewayOwner state) (stateCommitLog state)
  when eligible $ do
    case daemonDnsWriteGate config of
      Nothing -> pure ()
      Just gate -> do
        publicIpResult <- fetchPublicIp
        case publicIpResult of
          Left err -> logForEnv env Warn "dns_write_skipped" [field "detail" err]
          Right currentIp -> do
            atomically $ modifyTVar' stateVar $ \s -> s {stateLastPublicIp = Just currentIp}
            let shouldWrite = case stateLastDnsWriteIp state of
                  Nothing -> True
                  Just lastIp -> lastIp /= currentIp
            when shouldWrite $ do
              writeResult <- writeDnsRecord (daemonAwsCreds config) gate currentIp
              case writeResult of
                Left err -> logForEnv env Error "dns_write_failed" [field "detail" err]
                Right () -> do
                  now <- getCurrentTime
                  atomically $ modifyTVar' stateVar $ \s ->
                    s
                      { stateLastPublicIp = Just currentIp
                      , stateLastDnsWriteIp = Just currentIp
                      , stateLastDnsWriteTime = Just now
                      }
                  logForEnv
                    env
                    Info
                    "dns_write_succeeded"
                    [ field "fqdn" (dnsWriteGateFqdn gate)
                    , field "ip" currentIp
                    ]
  liveConfig <- readTVarIO (envLiveConfig env)
  threadDelay (round (liveSyncInterval liveConfig * 1000000))

restServerLoop :: Maybe Int -> PeerEndpoint -> DaemonEnv -> IO ()
restServerLoop restPortOverride localPeer env = do
  let host = peerRestHost localPeer
      port = fromMaybe (peerRestPort localPeer) restPortOverride
  withListeningSocket "REST server" host port $ \sock -> do
    logForEnv env Info "rest_server_listening" [field "host" host, field "port" port]
    acceptWhileServing True sock env (`handleRestClient` env)

handleRestClient :: Socket -> DaemonEnv -> IO ()
handleRestClient sock env = do
  _ <- try handleRequest :: IO (Either SomeException ())
  close sock
 where
  handleRequest = do
    rawRequest <- receiveAll sock
    now <- getCurrentTime
    case requestPath rawRequest of
      "/healthz" ->
        sendHttpResponse sock 200 "text/plain" "ok\n"
      "/readyz" -> do
        readiness <- readTVarIO (envReadiness env)
        case readiness of
          Ready -> sendHttpResponse sock 200 "text/plain" "ready\n"
          Draining -> sendHttpResponse sock 503 "text/plain" "draining\n"
          Starting -> sendHttpResponse sock 503 "text/plain" "starting\n"
      "/metrics" -> do
        state <- readTVarIO (envState env)
        sendHttpResponse sock 200 "text/plain" (renderMetricsText now env state)
      "/v1/state" -> do
        state <- readTVarIO (envState env)
        sendLazyHttpResponse sock 200 "application/json" (renderStateJson now (envBootConfig env) state)
      path
        | "/v1/secret/derive" `isPrefixOf` path -> handleSecretDerive env sock path
        | path == "/v1/secret/ensure-namespace" ->
            handleSecretEnsureNamespace env sock rawRequest
      _ ->
        sendHttpResponse sock 404 "text/plain" "not found\n"

sendHttpResponse :: Socket -> Int -> String -> String -> IO ()
sendHttpResponse sock statusCode contentType responseBody =
  sendLazyHttpResponse sock statusCode contentType (BL8.pack responseBody)

sendLazyHttpResponse :: Socket -> Int -> String -> BL.ByteString -> IO ()
sendLazyHttpResponse sock statusCode contentType responseBody = do
  let responseHeaders =
        "HTTP/1.1 "
          ++ show statusCode
          ++ " "
          ++ statusReason statusCode
          ++ "\r\n"
          ++ "Content-Type: "
          ++ contentType
          ++ "\r\n"
          ++ "Content-Length: "
          ++ show (BL.length responseBody)
          ++ "\r\n"
          ++ "Connection: close\r\n"
          ++ "\r\n"
  sendAll sock (BS8.pack responseHeaders)
  sendAll sock (BL.toStrict responseBody)

statusReason :: Int -> String
statusReason statusCode =
  case statusCode of
    200 -> "OK"
    404 -> "Not Found"
    503 -> "Service Unavailable"
    _ -> "OK"

requestPath :: BS.ByteString -> String
requestPath rawRequest =
  case words (takeWhile (/= '\r') (takeWhile (/= '\n') (BS8.unpack rawRequest))) of
    _method : path : _ -> path
    _ -> "/v1/state"

-- | Sprint 2.19: try to retrieve the master seed from MinIO at daemon
-- startup. Returns 'Just' when 'daemonMinioCreds' is bound and the read or
-- create succeeds; returns 'Nothing' otherwise (no creds, MinIO unreachable,
-- I/O failure). The @/v1/secret/derive@ endpoint serves 503 while
-- 'envMasterSeed' stays 'Nothing'.
acquireInitialMasterSeed :: String -> DaemonConfig -> IO (Maybe Prodbox.Secret.Derive.MasterSeed)
acquireInitialMasterSeed logLevel config =
  case daemonMinioCreds config of
    Nothing -> do
      logAtLevel
        logLevel
        Info
        "master_seed_unavailable"
        [field "reason" ("no minio_creds bound in daemon config" :: String)]
      pure Nothing
    Just creds -> do
      -- Sprint 2.19: prefer the endpoint URL bound in the daemon Dhall
      -- config (`boot.minio_endpoint_url`) so in-cluster gateway pods
      -- reach the MinIO Service DNS (e.g.
      -- `http://minio.prodbox.svc.cluster.local:9000`) rather than the
      -- pod's own loopback. Fall back to `http://127.0.0.1:9000` only
      -- for host-side smoke runs that lack the field.
      let cfg = case daemonMinioEndpointUrl config of
            Just url ->
              MasterSeed.minioMasterSeedConfigFromUrl
                url
                (gatewayMinioAccessKey creds)
                (gatewayMinioSecretKey creds)
            Nothing ->
              MasterSeed.defaultMinioMasterSeedConfig
                defaultMinioLocalPort
                (gatewayMinioAccessKey creds)
                (gatewayMinioSecretKey creds)
      result <- MasterSeed.ensureMasterSeed cfg
      case result of
        Left err -> do
          logAtLevel
            logLevel
            Warn
            "master_seed_unavailable"
            [field "reason" (MasterSeed.renderMasterSeedError err)]
          pure Nothing
        Right seed -> do
          logAtLevel
            logLevel
            Info
            "master_seed_ready"
            [ field "source" ("minio:prodbox/master-seed" :: String)
            , field "endpoint" (MasterSeed.minioMasterSeedEndpoint cfg)
            ]
          pure (Just seed)
 where
  defaultMinioLocalPort :: Int
  defaultMinioLocalPort = 9000

-- | Sprint 3.13 chunk 16: at daemon startup, after the master seed has
-- been acquired, self-materialize the gateway's own derived-secret
-- inventory ('(\"gateway\", \"gateway\")' in 'Inventory.derivedSecretInventoryFor').
-- This is the daemon's response to the bootstrap chicken-and-egg: the
-- other charts (keycloak, keycloak-postgres) materialize their secrets
-- via a pre-install Job that POSTs to /this/ daemon, but the gateway
-- chart can't depend on itself the same way. Self-bootstrap puts the
-- daemon Pod in charge of writing its own k8s Secret as soon as it has
-- the master seed.
--
-- Failure modes are all benign-and-logged:
--
--   * No master seed yet — skipped silently; subsequent reload may
--     succeed once MinIO becomes reachable.
--   * Outside k8s (no projected ServiceAccount) — skipped with a
--     diagnostic; the standalone smoke-run path has no @gateway-event-keys@
--     Secret to write to.
--   * CA store load fails — skipped with diagnostic.
--   * RBAC missing or PUT fails — skipped with diagnostic; the operator
--     can repair RBAC and the next Pod restart retries.
--
-- The chart's @configmap-config.yaml@ reads the materialized Secret via
-- Helm @lookup@, so once the daemon writes the Secret a subsequent
-- @helm upgrade@ picks up the keys. The peer-event flow itself
-- tolerates an empty key list (it just won't accept signed events from
-- peers until both sides hold matching keys).
-- | Sprint 3.13 chunk 24: derive the gateway's own per-node event keys
-- in memory from the master seed. The list shape matches what the
-- daemon's ensure-namespace handler writes into the
-- @gateway-event-keys@ Secret for external observers, but here we want
-- the values directly in 'daemonEventKeys' so the runtime peer /
-- heartbeat loops have signing material from the very first event.
--
-- Returns @[]@ when the seed isn't bound yet; the runtime degrades to
-- the @event_key_missing@ log path until a future config reload re-runs
-- this with a valid seed.
--
-- Canonical node ids match 'Prodbox.Secret.Inventory.derivedSecretInventoryFor'
-- for @(gateway, gateway)@: @node-a@, @node-b@, @node-c@. The derivation
-- context follows 'Prodbox.Secret.Derive.gatewayEventKeyContext':
-- @gateway:gateway:<node-id>:event-key@. The hex encoding matches the
-- existing daemon @daemonEventKeys@ representation (`deriveHex` rather
-- than `deriveBase64Url`) so peer signature verification stays
-- compatible.
deriveOwnGatewayEventKeys
  :: Maybe Prodbox.Secret.Derive.MasterSeed -> [(String, String)]
deriveOwnGatewayEventKeys maybeSeed =
  case maybeSeed of
    Nothing -> []
    Just seed ->
      [ ( nodeId
        , Text.unpack
            ( Prodbox.Secret.Derive.deriveHex
                seed
                (Prodbox.Secret.Derive.gatewayEventKeyContext "gateway" (Text.pack nodeId))
            )
        )
      | nodeId <- ["node-a", "node-b", "node-c"]
      ]

selfBootstrapOwnSecrets :: String -> Maybe Prodbox.Secret.Derive.MasterSeed -> IO ()
selfBootstrapOwnSecrets logLevel maybeSeed =
  case maybeSeed of
    Nothing -> pure ()
    Just seed -> do
      credsResult <- InCluster.loadInClusterCredentials
      case credsResult of
        Left credsErr ->
          logAtLevel
            logLevel
            Info
            "self_bootstrap_skipped"
            [field "reason" credsErr]
        Right creds -> do
          opsResult <- InCluster.inClusterK8sSecretOps creds
          case opsResult of
            Left opsErr ->
              logAtLevel
                logLevel
                Warn
                "self_bootstrap_skipped"
                [field "reason" opsErr]
            Right ops -> do
              let inventory = Inventory.derivedSecretInventoryFor "gateway" "gateway"
              applyResult <- EnsureNamespace.applyDerivedSecrets ops seed "gateway" inventory
              case applyResult of
                Left applyErr ->
                  logAtLevel
                    logLevel
                    Warn
                    "self_bootstrap_failed"
                    [field "reason" applyErr]
                Right _ ->
                  logAtLevel
                    logLevel
                    Info
                    "self_bootstrap_ready"
                    [ field "secret" ("gateway-event-keys" :: String)
                    , field "fields" (length inventory)
                    ]

-- | Sprint 2.19: serve @/v1/secret/derive?context=<ctx>@. Returns 200 with
-- the URL-safe base64 derived value when the seed is bound; 400 when the
-- @context@ query parameter is missing; 503 when 'envMasterSeed' is
-- 'Nothing'.
handleSecretDerive :: DaemonEnv -> Socket -> String -> IO ()
handleSecretDerive env sock path =
  case envMasterSeed env of
    Nothing ->
      sendHttpResponse
        sock
        503
        "application/json"
        "{\"error\":\"master-seed unavailable\",\"reason\":\"daemon has not yet acquired the master seed from MinIO; see documents/engineering/secret_derivation_doctrine.md \\u00a78.\"}\n"
    Just seed ->
      case extractContextQuery path of
        Nothing ->
          sendHttpResponse
            sock
            400
            "application/json"
            "{\"error\":\"missing context query parameter\",\"reason\":\"GET /v1/secret/derive requires ?context=<context-string>\"}\n"
        Just contextText -> do
          let derived =
                Prodbox.Secret.Derive.deriveBase64Url
                  seed
                  (Text.pack contextText)
              response =
                SecretWire.DeriveResponse
                  { SecretWire.deriveResponseContext = Text.pack contextText
                  , SecretWire.deriveResponseDerived = derived
                  , SecretWire.deriveResponseEncoding = SecretWire.deriveEncodingBase64Url
                  }
          sendLazyHttpResponse sock 200 "application/json" (encode response)

-- | Sprint 3.13 fifth chunk: serve @POST /v1/secret/ensure-namespace@.
-- Idempotently materializes every derived @v1.Secret@ for a release per
-- the doctrine §6 inventory. Returns 200 with the SHA-256 inventory on
-- success; 400 on malformed body; 503 when the master seed is
-- unavailable or the in-pod K8s API client cannot be constructed.
handleSecretEnsureNamespace :: DaemonEnv -> Socket -> BS.ByteString -> IO ()
handleSecretEnsureNamespace env sock rawRequest =
  case envMasterSeed env of
    Nothing ->
      sendHttpResponse
        sock
        503
        "application/json"
        "{\"error\":\"master-seed unavailable\",\"reason\":\"daemon has not yet acquired the master seed from MinIO; see documents/engineering/secret_derivation_doctrine.md \\u00a78.\"}\n"
    Just seed -> do
      let body = extractRequestBody rawRequest
      case eitherDecode (BL.fromStrict body) of
        Left err ->
          sendLazyHttpResponse
            sock
            400
            "application/json"
            ( encode
                ( object
                    [ "error" .= ("malformed request body" :: Text.Text)
                    , "reason" .= Text.pack ("JSON decode failed: " ++ err)
                    ]
                )
            )
        Right (request :: SecretWire.EnsureNamespaceRequest) -> do
          credsResult <- InCluster.loadInClusterCredentials
          case credsResult of
            Left credsErr ->
              sendLazyHttpResponse
                sock
                503
                "application/json"
                ( encode
                    ( object
                        [ "error" .= ("in-pod ServiceAccount unavailable" :: Text.Text)
                        , "reason" .= Text.pack credsErr
                        ]
                    )
                )
            Right creds -> do
              opsResult <- InCluster.inClusterK8sSecretOps creds
              case opsResult of
                Left opsErr ->
                  sendLazyHttpResponse
                    sock
                    503
                    "application/json"
                    ( encode
                        ( object
                            [ "error" .= ("K8s API client construction failed" :: Text.Text)
                            , "reason" .= Text.pack opsErr
                            ]
                        )
                    )
                Right ops -> do
                  let namespace = SecretWire.ensureNamespaceRequestNamespace request
                      release = SecretWire.ensureNamespaceRequestRelease request
                      inventory = Inventory.derivedSecretInventoryFor namespace release
                  applyResult <- EnsureNamespace.applyDerivedSecrets ops seed namespace inventory
                  case applyResult of
                    Left applyErr ->
                      sendLazyHttpResponse
                        sock
                        500
                        "application/json"
                        ( encode
                            ( object
                                [ "error" .= ("ensure-namespace materialization failed" :: Text.Text)
                                , "reason" .= Text.pack applyErr
                                ]
                            )
                        )
                    Right secrets ->
                      sendLazyHttpResponse
                        sock
                        200
                        "application/json"
                        ( encode
                            SecretWire.EnsureNamespaceResponse
                              { SecretWire.ensureNamespaceResponseNamespace = namespace
                              , SecretWire.ensureNamespaceResponseRelease = release
                              , SecretWire.ensureNamespaceResponseSecrets = secrets
                              }
                        )

-- | Sprint 3.13 fifth chunk: extract the body of an HTTP request from
-- the raw bytes received off the socket. Looks for the @\\r\\n\\r\\n@
-- header/body separator and returns everything after it. Returns an
-- empty 'ByteString' when the separator is absent (the request had
-- only headers and the caller will surface a malformed-body error
-- during JSON decode). Exposed at module scope so the unit suite can
-- pin the byte-level contract without spinning up a socket.
extractRequestBody :: BS.ByteString -> BS.ByteString
extractRequestBody raw =
  let sep = BS8.pack "\r\n\r\n"
   in case BS.breakSubstring sep raw of
        (_, rest) | BS.null rest -> BS.empty
        (_, rest) -> BS.drop (BS.length sep) rest

-- | Parse the @context@ query parameter from a path of the form
-- @/v1/secret/derive?context=<value>@. Returns 'Nothing' when the parameter
-- is absent. Does not URL-decode; doctrine context strings are ASCII-only.
extractContextQuery :: String -> Maybe String
extractContextQuery path =
  case break (== '?') path of
    (_, '?' : queryString) -> lookup "context" (parsePairs queryString)
    _ -> Nothing
 where
  parsePairs s =
    [ (key, value)
    | pair <- splitOn '&' s
    , let (key, rest) = break (== '=') pair
    , value <- case rest of
        '=' : v -> [v]
        _ -> [""]
    ]

splitOn :: Char -> String -> [String]
splitOn c = foldr step []
 where
  step char [] = [[char]]
  step char (cur : rest)
    | char == c = "" : cur : rest
    | otherwise = (char : cur) : rest

renderMetricsText :: UTCTime -> DaemonEnv -> DaemonState -> String
renderMetricsText now env state =
  unlines
    [ "# TYPE prodbox_gateway_events_total counter"
    , "prodbox_gateway_events_total{daemon=\""
        ++ metricsDaemonName (envMetrics env)
        ++ "\"} "
        ++ show (length (commitLogEvents (stateCommitLog state)))
    , "# TYPE prodbox_gateway_peer_connected gauge"
    ]
    ++ unlines
      [ "prodbox_gateway_peer_connected{peer=\""
          ++ peer
          ++ "\"} "
          ++ if peerHealthConnected health then "1" else "0"
      | (peer, health) <- Map.toList (statePeerHealth state)
      ]
    ++ unlines
      [ "# TYPE prodbox_gateway_heartbeat_age_seconds gauge"
      ]
    ++ unlines
      [ "prodbox_gateway_heartbeat_age_seconds{node=\""
          ++ nodeId
          ++ "\"} "
          ++ show (realToFrac (diffUTCTime now timestamp) :: Double)
      | (nodeId, timestamp) <- Map.toList (stateLastHeartbeatTimes state)
      ]

-- | Bind the peer-events HTTP listener on the configured socket port.
peerListenerLoop
  :: PeerEndpoint
  -> DaemonEnv
  -> IO ()
peerListenerLoop localPeer env = do
  let host = peerSocketHost localPeer
      port = peerSocketPort localPeer
  withListeningSocket "Peer events listener" host port $ \sock -> do
    logForEnv env Info "peer_listener_listening" [field "host" host, field "port" port]
    acceptWhileServing False sock env (`handlePeerClient` env)

acceptWhileServing :: Bool -> Socket -> DaemonEnv -> (Socket -> IO ()) -> IO ()
acceptWhileServing allowDuringDrain sock env handleClient = go
 where
  go = do
    readiness <- readTVarIO (envReadiness env)
    case readiness of
      Draining
        | not allowDuringDrain -> pure ()
      _ -> do
        maybeReadable <- waitForSocketRead sock
        case maybeReadable of
          Nothing -> go
          Just () -> do
            (clientSock, _) <- accept sock
            handleClient clientSock
            go

waitForSocketRead :: Socket -> IO (Maybe ())
waitForSocketRead sock =
  withFdSocket sock $
    \socketFd -> timeout listenerPollMicros (threadWaitRead (Fd socketFd))

listenerPollMicros :: Int
listenerPollMicros = 100000

openListeningSocket :: String -> String -> Int -> IO Socket
openListeningSocket label host port = do
  socketResult <- bindListeningSocket host port
  case socketResult of
    Left err -> ioError (userError (label ++ " failed to bind on " ++ host ++ ":" ++ show port ++ ": " ++ err))
    Right sock -> pure sock

withListeningSocket :: String -> String -> Int -> (Socket -> IO value) -> IO value
withListeningSocket label host port =
  bracketOnError
    (openListeningSocket label host port)
    close

bindListeningSocket :: String -> Int -> IO (Either String Socket)
bindListeningSocket host port = do
  let hints =
        defaultHints
          { addrFlags = [AI_PASSIVE]
          , addrSocketType = Stream
          }
  addrResult <-
    try
      (getAddrInfo (Just hints) (Just host) (Just (show port)))
      :: IO (Either IOException [AddrInfo])
  case addrResult of
    Left err ->
      pure
        ( Left
            ( "failed to resolve listener address: "
                ++ displayException err
            )
        )
    Right [] -> pure (Left "no listener addresses resolved")
    Right addresses -> tryAddresses addresses []
 where
  tryAddresses :: [AddrInfo] -> [String] -> IO (Either String Socket)
  tryAddresses [] errors = pure (Left (intercalate "; " (reverse errors)))
  tryAddresses (addressInfo : rest) errors = do
    socketResult <-
      try
        (socket (addrFamily addressInfo) (addrSocketType addressInfo) (addrProtocol addressInfo))
        :: IO (Either IOException Socket)
    case socketResult of
      Left err ->
        tryAddresses rest (displayException err : errors)
      Right sock -> do
        setSocketOption sock ReuseAddr 1
        bindResult <-
          try
            (bind sock (addrAddress addressInfo) >> listen sock 16)
            :: IO (Either IOException ())
        case bindResult of
          Left err -> do
            close sock
            tryAddresses rest (displayException err : errors)
          Right () -> pure (Right sock)

handlePeerClient
  :: Socket
  -> DaemonEnv
  -> IO ()
handlePeerClient sock env = do
  _ <- try handleOne :: IO (Either SomeException ())
  close sock
 where
  handleOne = do
    envOnPeerConnectionEstablished (envHooks env) "inbound"
    raw <- receiveAll sock
    case parsePeerHttpRequest raw of
      Left err -> do
        let response = renderPeerHttpResponse (PeerResponseError err)
        sendAll sock (BL.toStrict response)
      Right (PeerPushEvents batch) -> do
        response <- ingestPeerBatch env batch
        sendAll sock (BL.toStrict response)
      Right PeerPullEvents -> do
        state <- readTVarIO (envState env)
        let batch =
              PeerEventBatch
                (commitLogEvents (stateCommitLog state))
                (stateOrdersVersionUtc state)
            response = renderPeerHttpResponse (PeerResponseEventBatch batch)
        sendAll sock (BL.toStrict response)

-- | Read the inbound request until the body matches the @Content-Length@
-- header.  GET requests with no body return after the header section.
receiveAll :: Socket -> IO BS.ByteString
receiveAll sock = loop BS.empty
 where
  loop acc = do
    chunk <- recv sock 16384
    if BS.null chunk
      then pure acc
      else
        let acc' = acc `BS.append` chunk
         in if hasFullBody acc'
              then pure acc'
              else loop acc'

  hasFullBody :: BS.ByteString -> Bool
  hasFullBody bs =
    let text = BS8.unpack bs
        (header, body) = splitOnDoubleCrlf text
     in case lookupContentLength header of
          Just expected -> length body >= expected
          Nothing -> not (null header) && doubleCrlfPresent text

  doubleCrlfPresent :: String -> Bool
  doubleCrlfPresent text = "\r\n\r\n" `isInfixOf'` text || "\n\n" `isInfixOf'` text

  splitOnDoubleCrlf :: String -> (String, String)
  splitOnDoubleCrlf = go []
   where
    go acc rest = case rest of
      '\r' : '\n' : '\r' : '\n' : remainder -> (reverse acc, remainder)
      '\n' : '\n' : remainder -> (reverse acc, remainder)
      (c : remainder) -> go (c : acc) remainder
      [] -> (reverse acc, "")

  lookupContentLength :: String -> Maybe Int
  lookupContentLength text =
    let headerLines = lines (replace '\r' ' ' text)
        findHeader [] = Nothing
        findHeader (h : rest) =
          let lc = map toLower h
           in if "content-length:" `isPrefixOf` lc
                then case reads (drop (length ("content-length:" :: String)) lc) of
                  ((n, _) : _) -> Just n
                  _ -> findHeader rest
                else findHeader rest
     in findHeader headerLines

  replace c r = map (\x -> if x == c then r else x)

  isInfixOf' :: String -> String -> Bool
  isInfixOf' needle haystack = any (needle `isPrefixOf`) (tails haystack)

  tails :: [a] -> [[a]]
  tails [] = [[]]
  tails xs@(_ : rest) = xs : tails rest

ingestPeerBatch
  :: DaemonEnv
  -> PeerEventBatch
  -> IO BL.ByteString
ingestPeerBatch env batch = do
  now <- getCurrentTime
  liveConfig <- readTVarIO (envLiveConfig env)
  let config = envBootConfig env
      orders = envOrders env
      stateVar = envState env
      eventKeys = Map.fromList (daemonEventKeys config)
      senderOrdersVersion = peerEventBatchSenderOrdersVersionUtc batch
  state0 <- readTVarIO stateVar
  let receiverOrdersVersion = stateOrdersVersionUtc state0
  if senderOrdersVersion > 0 && senderOrdersVersion < receiverOrdersVersion
    then
      pure
        ( renderPeerHttpResponse
            (PeerResponseStaleOrders senderOrdersVersion receiverOrdersVersion)
        )
    else do
      let nowIso = formatUtcIso now
          knownEmitters = map peerNodeId (ordersNodes orders)
          lookupKey = (`Map.lookup` eventKeys)
          (accepted, rejected) =
            handlePeerRequest
              lookupKey
              knownEmitters
              (liveMaxClockSkewSeconds liveConfig)
              nowIso
              batch
      appliedCount <- atomically $ do
        s0 <- readTVar stateVar
        let preCount = length (commitLogEvents (stateCommitLog s0))
            updated =
              applyAcceptedEvents now accepted s0
                `noteSenderOrdersAdvert` senderOrdersVersion
            postCount = length (commitLogEvents (stateCommitLog updated))
        writeTVar stateVar updated
        pure (postCount - preCount)
      envAfterPeerEventCommit (envHooks env) appliedCount
      pure (renderPeerHttpResponse (PeerResponseEventsAccepted appliedCount rejected))

noteSenderOrdersAdvert :: DaemonState -> Int -> DaemonState
noteSenderOrdersAdvert s senderVersion
  | senderVersion > stateLatestObservedOrdersVersion s =
      s {stateLatestObservedOrdersVersion = senderVersion}
  | otherwise = s

-- | Apply a list of accepted peer events to the daemon state in one pass:
-- append to the commit log (idempotently), update last-heartbeat times,
-- record per-peer transport health, refresh max-observed clock skew, and
-- promote a newer Orders version when announced.
applyAcceptedEvents :: UTCTime -> [SignedEvent] -> DaemonState -> DaemonState
applyAcceptedEvents now events s0 =
  let log0 = stateCommitLog s0
      log' = foldl' appendIfNew log0 events
      heartbeats0 = stateLastHeartbeatTimes s0
      heartbeats' = foldl' updateHeartbeatFromEvent heartbeats0 events
      peerHealth0 = statePeerHealth s0
      peerHealth' = foldl' (updatePeerHealthFromEvent now) peerHealth0 events
      skew0 = stateMaxObservedSkewSeconds s0
      skew' = foldl' (updateSkewFromEvent now) skew0 events
      ordersAdvert = foldl' updateOrdersAdvert (stateLatestObservedOrdersVersion s0) events
   in s0
        { stateCommitLog = log'
        , stateLastHeartbeatTimes = heartbeats'
        , statePeerHealth = peerHealth'
        , stateMaxObservedSkewSeconds = skew'
        , stateLatestObservedOrdersVersion = ordersAdvert
        }

updateHeartbeatFromEvent :: Map String UTCTime -> SignedEvent -> Map String UTCTime
updateHeartbeatFromEvent acc ev =
  case eventTimestampUtc ev of
    Just ts ->
      Map.insertWith max (emitterNodeId ev) ts acc
    Nothing -> acc

updatePeerHealthFromEvent
  :: UTCTime -> Map String PeerHealth -> SignedEvent -> Map String PeerHealth
updatePeerHealthFromEvent now acc ev =
  let baseline = PeerHealth (Just now) True Nothing
      merge _new old =
        old
          { peerHealthLastInboundEvent = Just now
          , peerHealthConnected = True
          , peerHealthLastError = Nothing
          }
   in Map.insertWith merge (emitterNodeId ev) baseline acc

updateSkewFromEvent :: UTCTime -> Maybe Double -> SignedEvent -> Maybe Double
updateSkewFromEvent now acc ev =
  case eventTimestampUtc ev of
    Just ts ->
      let skew = abs (realToFrac (diffUTCTime now ts) :: Double)
       in Just (maybe skew (max skew) acc)
    Nothing -> acc

updateOrdersAdvert :: Int -> SignedEvent -> Int
updateOrdersAdvert acc ev =
  case extractOrdersVersionFromEvent ev of
    Just v | v > acc -> v
    _ -> acc

-- | Periodically push the local commit log to every other peer in the
-- mesh.  Each cycle marks unreachable peers as disconnected so
-- @/v1/state@ exposes per-peer transport health.
peerDialerLoop :: DaemonEnv -> IO ()
peerDialerLoop env = forever $ do
  let config = envBootConfig env
      orders = envOrders env
      stateVar = envState env
  state <- readTVarIO stateVar
  let nodeId = daemonNodeId config
      peers = [p | p <- ordersNodes orders, peerNodeId p /= nodeId]
      events = commitLogEvents (stateCommitLog state)
      batch = PeerEventBatch events (stateOrdersVersionUtc state)
  mapM_ (pushToPeer stateVar batch) peers
  liveConfig <- readTVarIO (envLiveConfig env)
  threadDelay (round (liveReconnectInterval liveConfig * 1000000))

pushToPeer :: TVar DaemonState -> PeerEventBatch -> PeerEndpoint -> IO ()
pushToPeer stateVar batch peer = do
  let host = peerDialSocketHost peer
      port = peerSocketPort peer
      body = encode (encodePeerEventBatch batch)
      request =
        BL.toStrict $
          BL.append
            ( BL.fromStrict
                ( BS8.pack
                    ( "POST /v1/peer/events HTTP/1.1\r\n"
                        ++ "Host: "
                        ++ host
                        ++ ":"
                        ++ show port
                        ++ "\r\n"
                        ++ "Content-Type: application/json\r\n"
                        ++ "Content-Length: "
                        ++ show (BL.length body)
                        ++ "\r\n"
                        ++ "Connection: close\r\n"
                        ++ "\r\n"
                    )
                )
            )
            body
  result <-
    try (dialAndSend host port request) :: IO (Either SomeException (Either String BS.ByteString))
  case result of
    Left exc -> markPeerError stateVar (peerNodeId peer) (show exc)
    Right (Left err) -> markPeerError stateVar (peerNodeId peer) err
    Right (Right _resp) -> markPeerOk stateVar (peerNodeId peer)

dialAndSend :: String -> Int -> BS.ByteString -> IO (Either String BS.ByteString)
dialAndSend host port request = do
  addrInfos <- getAddrInfo Nothing (Just host) (Just (show port))
  case addrInfos of
    [] -> pure (Left ("no address resolution for " ++ host))
    (info : _) -> do
      sock <- socket AF_INET Stream defaultProtocol
      connectResult <- try (connect sock (addrAddress info)) :: IO (Either SomeException ())
      case connectResult of
        Left exc -> do
          close sock
          pure (Left (show exc))
        Right () -> do
          sendAll sock request
          chunks <- readUntilClose sock []
          close sock
          pure (Right (BS.concat (reverse chunks)))

readUntilClose :: Socket -> [BS.ByteString] -> IO [BS.ByteString]
readUntilClose sock acc = do
  chunk <- recv sock 16384
  if BS.null chunk
    then pure acc
    else readUntilClose sock (chunk : acc)

markPeerError :: TVar DaemonState -> String -> String -> IO ()
markPeerError stateVar peerId reason =
  atomically $ modifyTVar' stateVar $ \s ->
    s
      { statePeerHealth =
          Map.alter
            (markPeerHealthError reason)
            peerId
            (statePeerHealth s)
      }

markPeerHealthError :: String -> Maybe PeerHealth -> Maybe PeerHealth
markPeerHealthError reason mh =
  case mh of
    Just h -> Just h {peerHealthConnected = False, peerHealthLastError = Just reason}
    Nothing -> Just (PeerHealth Nothing False (Just reason))

markPeerOk :: TVar DaemonState -> String -> IO ()
markPeerOk stateVar peerId = do
  now <- getCurrentTime
  atomically $ modifyTVar' stateVar $ \s ->
    s
      { statePeerHealth =
          Map.alter
            (markPeerHealthOk now)
            peerId
            (statePeerHealth s)
      }

markPeerHealthOk :: UTCTime -> Maybe PeerHealth -> Maybe PeerHealth
markPeerHealthOk now mh =
  case mh of
    Just h ->
      Just
        h
          { peerHealthConnected = True
          , peerHealthLastError = Nothing
          , peerHealthLastInboundEvent =
              Just (maybe now (max now) (peerHealthLastInboundEvent h))
          }
    Nothing -> Just (PeerHealth (Just now) True Nothing)

renderStateJson :: UTCTime -> DaemonConfig -> DaemonState -> BL.ByteString
renderStateJson now config state =
  encode $
    object
      [ "node_id" .= daemonNodeId config
      , "gateway_owner" .= stateGatewayOwner state
      , "previous_owner" .= statePreviousOwner state
      , "has_active_claim" .= (stateGatewayOwner state == Just (daemonNodeId config))
      , "can_write_dns"
          .= canWriteDns (daemonNodeId config) (stateGatewayOwner state) (stateCommitLog state)
      , "node_disposition"
          .= renderDisposition (nodeDisposition (daemonNodeId config) (stateCommitLog state))
      , "peer_dispositions" .= renderPeerDispositions state
      , "mesh_peers" .= stateMeshPeers state
      , "event_count" .= length (commitLogEvents (stateCommitLog state))
      , "event_hashes" .= renderRecentEventHashes (commitLogEvents (stateCommitLog state))
      , "last_public_ip_observed" .= stateLastPublicIp state
      , "last_dns_write_ip" .= stateLastDnsWriteIp state
      , "last_dns_write_at_utc" .= fmap formatUtcIso (stateLastDnsWriteTime state)
      , "dns_write_gate" .= fmap renderDnsWriteGate (daemonDnsWriteGate config)
      , "heartbeat_age_seconds" .= renderHeartbeatAges now state
      , "peer_transport" .= renderPeerTransport now state
      , "max_clock_skew_seconds_observed" .= stateMaxObservedSkewSeconds state
      , "max_clock_skew_seconds_bound" .= daemonMaxClockSkewSeconds config
      , "orders_version_utc" .= stateOrdersVersionUtc state
      , "latest_observed_orders_version_utc" .= stateLatestObservedOrdersVersion state
      ]

gatewayStatusEventHashLimit :: Int
gatewayStatusEventHashLimit = 64

renderRecentEventHashes :: [SignedEvent] -> [String]
renderRecentEventHashes events =
  reverse (take gatewayStatusEventHashLimit (reverse (map eventHash events)))

renderDisposition :: Disposition -> Value
renderDisposition d = case d of
  DispositionOwner -> String "owner"
  DispositionYielded -> String "yielded"
  DispositionUnknown -> String "unknown"

renderPeerDispositions :: DaemonState -> Value
renderPeerDispositions state =
  Object $
    KeyMap.fromList
      [ (Key.fromString peer, renderDisposition (nodeDisposition peer (stateCommitLog state)))
      | peer <- stateMeshPeers state
      ]

renderDnsWriteGate :: DnsWriteGate -> Value
renderDnsWriteGate gate =
  object
    [ "zone_id" .= dnsWriteGateZoneId gate
    , "fqdn" .= dnsWriteGateFqdn gate
    , "ttl" .= dnsWriteGateTtl gate
    , "aws_region" .= dnsWriteGateAwsRegion gate
    ]

renderHeartbeatAges :: UTCTime -> DaemonState -> Value
renderHeartbeatAges now state =
  Object $
    KeyMap.fromList
      [ (Key.fromString nodeId, toJSON (realToFrac (diffUTCTime now timestamp) :: Double))
      | (nodeId, timestamp) <- Map.toList (stateLastHeartbeatTimes state)
      ]

renderPeerTransport :: UTCTime -> DaemonState -> Value
renderPeerTransport now state =
  Object $
    KeyMap.fromList
      [ ( Key.fromString peer
        , object
            [ "connected" .= peerHealthConnected health
            , "last_inbound_event_age_seconds"
                .= fmap (\t -> realToFrac (diffUTCTime now t) :: Double) (peerHealthLastInboundEvent health)
            , "last_error" .= peerHealthLastError health
            ]
        )
      | (peer, health) <- Map.toList (statePeerHealth state)
      ]

fetchPublicIp :: IO (Either String String)
fetchPublicIp = do
  result <- httpGetText defaultHttpConfig "https://api.ipify.org"
  case result of
    Left err -> pure (Left ("failed to fetch public IP: " ++ renderHttpError err))
    Right body ->
      let ip = trim body
       in if length (filter (== '.') ip) == 3
            then pure (Right ip)
            else pure (Left ("unexpected public IP: " ++ ip))

-- | Sprint 2.22: write a Route 53 A record. AWS credentials are now sourced
-- from the daemon's mounted Dhall config ('Maybe GatewayAwsCreds') rather
-- than inherited from the Pod's process environment. When no credentials
-- are bound the subprocess inherits the parent environment as a transitional
-- fallback during the chart-side env-var removal.
writeDnsRecord :: Maybe GatewayAwsCreds -> DnsWriteGate -> String -> IO (Either String ())
writeDnsRecord maybeAwsCreds gate ip = do
  let changeBatch =
        BL8.unpack $
          encode $
            object
              [ "Changes"
                  .= [ object
                         [ "Action" .= ("UPSERT" :: String)
                         , "ResourceRecordSet"
                             .= object
                               [ "Name" .= dnsWriteGateFqdn gate
                               , "Type" .= ("A" :: String)
                               , "TTL" .= dnsWriteGateTtl gate
                               , "ResourceRecords" .= [object ["Value" .= ip]]
                               ]
                         ]
                     ]
              ]
      subprocessEnv = fmap awsCredsToSubprocessEnv maybeAwsCreds
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "route53"
            , "change-resource-record-sets"
            , "--hosted-zone-id"
            , dnsWriteGateZoneId gate
            , "--change-batch"
            , changeBatch
            , "--region"
            , dnsWriteGateAwsRegion gate
            ]
        , subprocessEnvironment = subprocessEnv
        , subprocessWorkingDirectory = Nothing
        }
  case result of
    Failure err -> pure (Left ("aws cli failed: " ++ err))
    Success output ->
      case processExitCode output of
        ExitSuccess -> pure (Right ())
        ExitFailure _ -> pure (Left ("route53 update failed: " ++ trim (processStderr output)))

awsCredsToSubprocessEnv :: GatewayAwsCreds -> [(String, String)]
awsCredsToSubprocessEnv creds =
  [ ("AWS_ACCESS_KEY_ID", gatewayAwsAccessKeyId creds)
  , ("AWS_SECRET_ACCESS_KEY", gatewayAwsSecretAccessKey creds)
  , ("AWS_DEFAULT_REGION", gatewayAwsRegion creds)
  ]
    ++ maybe [] (\t -> [("AWS_SESSION_TOKEN", t)]) (gatewayAwsSessionToken creds)

createSignedEvent :: String -> String -> Value -> String -> UTCTime -> SignedEvent
createSignedEvent nodeId evtType payload key now =
  let payloadJsonStr = BL8.unpack (encode payload)
      tsStr = formatUtcIso now
      unsignedPayload =
        object
          [ "emitter_node_id" .= nodeId
          , "event_type" .= evtType
          , "payload_json" .= payloadJsonStr
          , "timestamp_utc" .= tsStr
          ]
      unsignedStr = BL8.unpack (encode unsignedPayload)
      eventHashBytes = hash (BS8.pack unsignedStr)
      eventHashHex = bytesToHex eventHashBytes
      signatureBytes = hmac (BS8.pack key) (BS8.pack eventHashHex)
      signatureHexStr = bytesToHex signatureBytes
   in SignedEvent
        { eventHash = eventHashHex
        , emitterNodeId = nodeId
        , timestampUtc = tsStr
        , eventType = evtType
        , payloadJson = payloadJsonStr
        , signatureHex = signatureHexStr
        }

formatUtcIso :: UTCTime -> String
formatUtcIso = formatShow iso8601Format

bytesToHex :: BS.ByteString -> String
bytesToHex = concatMap byteToHex . BS.unpack
 where
  byteToHex :: Word8 -> String
  byteToHex b = [intToDigit (fromIntegral (b `div` 16)), intToDigit (fromIntegral (b `mod` 16))]

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
