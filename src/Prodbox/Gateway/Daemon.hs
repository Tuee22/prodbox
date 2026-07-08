{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Daemon
  ( runGatewayDaemon

    -- * Sprint 1.44: operator-write REST endpoint (pure routing helpers)
  , allowedOperatorSecretPaths
  , operatorWriteRoleName
  , operatorSecretLogicalPath
  , operatorSecretRequestMethod
  , operatorSecretJwtHeader
  , requestBodyBytes
  , decodeOperatorSecretFields

    -- * Sprint 2.29: pre-Vault bootstrap endpoint (pure routing helpers)
  , BootstrapVaultRequest (..)
  , BootstrapVaultRotateUnlockBundleRequest (..)
  , BootstrapVaultRotateTransitKeyRequest (..)
  , BootstrapVaultResponse (..)
  , BootstrapVaultRequestError (..)
  , bootstrapVaultPath
  , bootstrapVaultPkiIssueTestCertPath
  , bootstrapVaultPkiStatusPath
  , bootstrapVaultRotateTransitKeyPath
  , bootstrapVaultRotateUnlockBundlePath
  , bootstrapVaultSealPath
  , bootstrapVaultStatusPath
  , bootstrapVaultRequestMaxBytes
  , decodeBootstrapVaultAuthenticatedRequest
  , decodeBootstrapVaultRequest
  , decodeBootstrapVaultRotateTransitKeyRequest
  , decodeBootstrapVaultRotateUnlockBundleRequest
  , renderBootstrapVaultRequestError

    -- * Sprint 7.30: daemon object-store API for Pulumi backends
  , PulumiObjectRequestError (..)
  , decodePulumiObjectPutRequest
  , decodePulumiObjectRequest
  , renderPulumiObjectRequestError
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently, race, waitCatch, withAsync)
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
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value (..)
  , eitherDecodeStrict'
  , encode
  , object
  , toJSON
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isSpace, toLower)
import Data.Foldable (for_)
import Data.List (intercalate, isPrefixOf, isSuffixOf, stripPrefix)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (formatShow, iso8601Format)
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
import Prodbox.Cluster.Federation
  ( ChildBootstrapCredential
  , ChildIndex (..)
  , ChildMetadata
  , childBootstrapKvLogicalPath
  , childMetadataKvLogicalPath
  , decodeChildBootstrapCredential
  , decodeChildIndex
  , decodeChildMetadata
  , decodePayloadJsonField
  , federationChildrenIndexKvLogicalPath
  )
import Prodbox.Config.Tier0
  ( ContextKind (..)
  , ProdboxContext (..)
  , ProdboxProjectConfig (..)
  , Tier0Source (..)
  , loadDaemonBinaryContext
  )
import Prodbox.Crypto.Envelope (DekCipher)
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
import Prodbox.Gateway.ObjectStore
  ( PulumiObjectGetResponse (..)
  , PulumiObjectPutRequest (..)
  , PulumiObjectRequest (..)
  , pulumiObjectDeletePath
  , pulumiObjectGetPath
  , pulumiObjectPutPath
  , pulumiObjectRequestMaxBytes
  , validatePulumiObjectStackName
  )
import Prodbox.Gateway.Peer
  ( PeerEventBatch (..)
  , PeerTransportRequest (..)
  , PeerTransportResponse (..)
  , encodePeerEventBatch
  , handlePeerRequest
  , parsePeerHttpRequest
  , renderPeerHttpResponse
  , signEvent
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
  , GatewayVaultAuth (..)
  , Orders (..)
  , PeerEndpoint (..)
  , PeerHealth (..)
  , SignedEvent (..)
  , appendIfNew
  , canWriteDns
  , cborPayloadFromJsonValue
  , defaultDrainDeadlineSeconds
  , emptyCommitLog
  , eventTimestampUtc
  , eventTypeClaim
  , eventTypeHeartbeat
  , eventTypeYield
  , nodeDisposition
  , peerDialSocketHost
  , validateDaemonTimingAgainstOrders
  )
import Prodbox.Http.Client
  ( HttpError (..)
  , defaultHttpConfig
  , httpGetText
  , renderHttpError
  )
import Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError (..)
  , LogicalObject (LogicalPulumiStack)
  , getLogical
  , objectKeyForOpaqueId
  , opaqueObjectId
  , putLogical
  , renderEncryptedObjectError
  )
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , defaultObjectStoreBucket
  , deleteObject
  )
import Prodbox.Repo (resolveTier0ConfigPath)
import Prodbox.Result (Result (..))
import Prodbox.Retry
  ( RetryPolicy (..)
  , retryDelayMicros
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Vault.BootstrapBundle
  ( bootstrapObjectStoreConfigWithEndpoint
  , getBundleObject
  , putBundleObject
  )
import Prodbox.Vault.Client
  ( BootstrapAction (..)
  , SealStatus (..)
  , VaultAddress (..)
  , VaultToken (..)
  , bootstrapAction
  , defaultInitRequest
  , initResponseToUnlockBundle
  , vaultInit
  , vaultKubernetesLogin
  , vaultKvReadV2
  , vaultKvWriteV2
  , vaultListMounts
  , vaultMountType
  , vaultPkiIssueTestCertificate
  , vaultRotateTransitKey
  , vaultSeal
  , vaultSealStatus
  , vaultSubmitUnseal
  )
import Prodbox.Vault.Orchestration
  ( UnsealOutcome (..)
  , UnsealStep (..)
  , interpretUnsealProgress
  , planUnseal
  )
import Prodbox.Vault.Reconcile
  ( defaultVaultReconcilePlan
  , renderVaultReconcileError
  , runVaultReconcile
  )
import Prodbox.Vault.TransitCipher (vaultTransitDekCipher)
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , decryptUnlockBundle
  , encryptUnlockBundle
  , renderUnlockBundleError
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
  , liveConnectionReadTimeoutSeconds :: Double
  -- ^ Sprint 2.25: bounded per-connection read timeout applied to every
  -- accepted connection on BOTH the REST and peer-events listeners, so a
  -- slow or stuck peer cannot hold a handler thread (or wedge the accept
  -- loop) indefinitely. Sourced from 'LiveConfig' with a sane default
  -- ('defaultConnectionReadTimeoutSeconds') rather than from the Dhall
  -- surface, so it tracks live-reload without expanding the config schema.
  }
  deriving (Eq, Show)

-- | Sane default bounded read timeout for a single accepted connection.
-- Generous enough for an operator @kubectl port-forward@ round-trip and a
-- full peer event-batch push, short enough that a stalled peer is dropped
-- well before it could starve the mesh.
defaultConnectionReadTimeoutSeconds :: Double
defaultConnectionReadTimeoutSeconds = 30.0

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

-- | Sprint 2.24: the daemon no longer accepts a CLI log-level or REST
-- port override. The log level is sourced from the mounted Dhall config
-- (@live.log_level@, defaulting to @info@) and the REST port is sourced
-- from the Orders file the daemon loads below.
runGatewayDaemon :: Maybe FilePath -> DaemonConfig -> IO ExitCode
runGatewayDaemon maybeConfigPath config = withSocketsDo $ do
  let logLevel = fromMaybe "info" (daemonConfigLogLevel config)
  logAtLevel
    logLevel
    Info
    "gateway_starting"
    [ field "node_id" (daemonNodeId config)
    , field "log_level" logLevel
    ]
  -- Sprint 1.40: establish the Tier-0 binary context (config_doctrine.md §0).
  -- The container ships a baked-in default `prodbox.dhall`; the
  -- `gateway-config-<nodeId>` ConfigMap mount OVERWRITES it (a `prodbox.dhall`
  -- sibling next to the runtime `config.dhall` in the same directory mount).
  -- This is purely a non-secret binary-context observation logged at startup;
  -- it does NOT replace the daemon's existing `DaemonConfig` runtime (secrets
  -- stay `SecretRef.Vault` pointers resolved through Vault Kubernetes auth).
  logDaemonBinaryContext logLevel maybeConfigPath
  -- Sprint 2.22: dispatch by file extension via GatewaySettings.loadOrders
  -- so the chart-rendered Dhall Orders content decodes through the native
  -- dhall library. The legacy JSON Orders parser was removed with the
  -- Sprint 2.27 CBOR wire-codec closure.
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
                  let env =
                        DaemonEnv
                          { envConfigPath = maybeConfigPath
                          , envBootConfig = config
                          , envOrders = orders
                          , envState = stateVar
                          , envReadiness = readinessVar
                          , envLiveConfig = liveConfigVar
                          , envLiveConfigReloads = reloadBroadcast
                          , envMetrics = MetricsRegistry "gateway"
                          , envDrainSignals = drainSignals
                          , envReloadSignals = reloadSignals
                          , envHooks = noopDaemonHooks
                          }
                  installDaemonSignalHandlers env signalCount

                  logForEnv
                    env
                    Info
                    "orders_loaded"
                    [ field "node_count" (length (ordersNodes orders))
                    , field "orders_version_utc" (ordersVersionUtc orders)
                    ]

                  result <- try (serveGatewayDaemon localPeer env) :: IO (Either SomeException ())
                  case result of
                    Left exc -> do
                      logForEnv env Error "gateway_daemon_error" [field "detail" (show exc)]
                      pure (ExitFailure 1)
                    Right () -> do
                      logForEnv env Info "gateway_stopped" []
                      pure ExitSuccess

-- | Sprint 1.40: load and log the Tier-0 binary context using hostbootstrap's
-- per-frame context-init pattern — the `gateway-config-<nodeId>` ConfigMap
-- `prodbox.dhall` OVERWRITES the baked-in container default. The runtime
-- `--config` path's directory IS the ConfigMap directory mount, so the
-- ConfigMap-supplied `prodbox.dhall` (when present) sits beside the runtime
-- `config.dhall`. A decode failure is logged as a warning rather than fatal:
-- the binary context is a non-secret observation surface this sprint, and the
-- daemon's operational `DaemonConfig` runtime (already loaded) is unaffected.
logDaemonBinaryContext :: String -> Maybe FilePath -> IO ()
logDaemonBinaryContext logLevel maybeConfigPath = do
  let configMapDir = maybe "/etc/gateway/config" takeDirectory maybeConfigPath
  -- Sprint 1.49: the non-ConfigMap fallback default is the binary-sibling
  -- prodbox.dhall the image generates at build (`prodbox config generate`),
  -- resolved beside this executable. The "/" argument is the unused fallback
  -- anchor — the in-container executable directory always resolves.
  containerDefaultPath <- resolveTier0ConfigPath "/"
  result <- loadDaemonBinaryContext configMapDir containerDefaultPath
  case result of
    Left err ->
      logAtLevel logLevel Warn "tier0_binary_context_decode_failed" [field "detail" err]
    Right (source, projectConfig) -> do
      let ctx = context projectConfig
      logAtLevel
        logLevel
        Info
        "tier0_binary_context_loaded"
        [ field "source" (renderTier0Source source)
        , field "project" (project ctx)
        , field "binary" (binary ctx)
        , field "context_kind" (renderContextKind (context_kind ctx))
        , field "cluster_id" (cluster_id ctx)
        ]

renderTier0Source :: Tier0Source -> String
renderTier0Source source = case source of
  Tier0FromConfigMap path -> "configmap:" ++ path
  Tier0FromContainerDefault path -> "container-default:" ++ path
  Tier0FromCompiledDefault -> "compiled-default"

renderContextKind :: ContextKind -> String
renderContextKind kind = case kind of
  HostOrchestrator -> "HostOrchestrator"
  Daemon -> "Daemon"
  ClusterService -> "ClusterService"
  OtherContext -> "OtherContext"

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
    , liveConnectionReadTimeoutSeconds = defaultConnectionReadTimeoutSeconds
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

serveGatewayDaemon :: PeerEndpoint -> DaemonEnv -> IO ()
serveGatewayDaemon localPeer env = do
  atomically (writeTVar (envReadiness env) Ready)
  race (drainCoordinator env) (daemonWorkers localPeer env)
    >>= either pure pure

daemonWorkers :: PeerEndpoint -> DaemonEnv -> IO ()
daemonWorkers localPeer env =
  withAsync (worker "heartbeat" (heartbeatLoop env)) $ \_ ->
    withAsync (worker "gateway_ownership" (gatewayLoop env)) $ \_ ->
      withAsync (worker "dns_write" (dnsWriteLoop env)) $ \_ ->
        withAsync (worker "rest_server" (restServerLoop localPeer env)) $ \_ ->
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
          -- Sprint 2.25: the Sprint 2.21 chunk-48 reapply-derivation overlay
          -- is retired. With the single canonical event-key encoding
          -- (base64url-unpadded), the chart's ConfigMap @event_keys@ list
          -- (read via Helm @lookup@ from the base64url
          -- @gateway-event-keys@ Secret) and the in-memory derivation now
          -- agree byte-for-byte, so the boot-change classifier compares
          -- like-for-like. A routine @log_level@ edit no longer trips
          -- 'daemonBootFieldsChanged' through a hex-vs-base64url mismatch.
          let bootChanged =
                daemonBootFieldsChanged
                  (envBootConfig env)
                  newConfig
              liveConfig =
                liveConfigFromDaemonConfig
                  (liveLogLevel currentLiveConfig)
                  newConfig
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
    || daemonVaultAuth old /= daemonVaultAuth new
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

restServerLoop :: PeerEndpoint -> DaemonEnv -> IO ()
restServerLoop localPeer env = do
  let host = peerRestHost localPeer
      port = peerRestPort localPeer
  withListeningSocket "REST server" host port $ \sock -> do
    logForEnv env Info "rest_server_listening" [field "host" host, field "port" port]
    acceptWhileServing True sock env (`handleRestClient` env)

handleRestClient :: Socket -> DaemonEnv -> IO ()
handleRestClient sock env = do
  _ <- try handleRequest :: IO (Either SomeException ())
  close sock
 where
  handleRequest = do
    maybeRaw <- receiveAllWithin env sock
    for_ maybeRaw handleParsedRequest

  handleParsedRequest rawRequest = do
    now <- getCurrentTime
    case requestPath rawRequest of
      path
        | path == bootstrapVaultPath -> handleBootstrapVaultEnsure sock env rawRequest
        | path == bootstrapVaultStatusPath -> handleBootstrapVaultStatus sock env rawRequest
        | path == bootstrapVaultSealPath -> handleBootstrapVaultSeal sock env rawRequest
        | path == bootstrapVaultRotateUnlockBundlePath ->
            handleBootstrapVaultRotateUnlockBundle sock env rawRequest
        | path == bootstrapVaultRotateTransitKeyPath ->
            handleBootstrapVaultRotateTransitKey sock env rawRequest
        | path == bootstrapVaultPkiStatusPath -> handleBootstrapVaultPkiStatus sock env rawRequest
        | path == bootstrapVaultPkiIssueTestCertPath ->
            handleBootstrapVaultPkiIssueTestCert sock env rawRequest
        | path == pulumiObjectGetPath -> handlePulumiObjectGet sock env rawRequest
        | path == pulumiObjectPutPath -> handlePulumiObjectPut sock env rawRequest
        | path == pulumiObjectDeletePath -> handlePulumiObjectDelete sock env rawRequest
        | otherwise ->
            case operatorSecretLogicalPath path of
              Just logical
                | operatorSecretRequestMethod rawRequest == "POST" ->
                    handleOperatorSecretWrite sock env rawRequest logical
                | otherwise ->
                    -- The write endpoint exists only for POST; a GET/PUT/etc. against
                    -- it is a client error, never a Vault read (the secrets it owns are
                    -- read in-cluster via Vault Kubernetes auth, never echoed back).
                    sendHttpResponse sock 405 "text/plain" "method not allowed\n"
              Nothing -> handleReadRequest sock env now rawRequest

-- | The read-only REST dispatch (health, readiness, metrics, state, and the
-- federation inventory/bootstrap endpoints). Split out of 'handleRestClient'
-- (Sprint 1.44) so the operator-write @POST /v1/secret/<logical>@ route can be
-- handled ahead of it without re-indenting this block.
handleReadRequest :: Socket -> DaemonEnv -> UTCTime -> BS.ByteString -> IO ()
handleReadRequest sock env now rawRequest =
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
    "/v1/federation/children" -> do
      childrenResult <- readFederationChildren (envBootConfig env)
      case childrenResult of
        Left err -> sendHttpResponse sock 503 "text/plain" (err ++ "\n")
        Right children ->
          sendLazyHttpResponse
            sock
            200
            "application/json"
            (encode (object ["children" .= children]))
    _ ->
      case federationBootstrapChildId (requestPath rawRequest) of
        Just childId -> do
          bootstrapResult <- readFederationChildBootstrap (envBootConfig env) (Text.pack childId)
          case bootstrapResult of
            Left err ->
              case err of
                FederationChildBootstrapMissing ->
                  sendHttpResponse sock 404 "text/plain" "not found\n"
                FederationVaultUnavailable detail ->
                  sendHttpResponse sock 503 "text/plain" (detail ++ "\n")
            Right credential ->
              sendLazyHttpResponse sock 200 "application/json" (encode credential)
        Nothing ->
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
    400 -> "Bad Request"
    401 -> "Unauthorized"
    404 -> "Not Found"
    405 -> "Method Not Allowed"
    502 -> "Bad Gateway"
    503 -> "Service Unavailable"
    _ -> "OK"

requestPath :: BS.ByteString -> String
requestPath rawRequest =
  case words (takeWhile (/= '\r') (takeWhile (/= '\n') (BS8.unpack rawRequest))) of
    _method : path : _ -> path
    _ -> "/v1/state"

-- Sprint 1.44: the operator-write REST endpoint (@POST /v1/secret/<logical>@).
--
-- The host CLI (a real operator, or the test harness simulating one) routes the
-- two host-minted operator secrets through the in-cluster daemon over the
-- loopback NodePort instead of writing them to Vault with the host root token:
--
--   * @secret/acme/eab@ — the ZeroSSL external-account-binding material.
--   * @secret/gateway/gateway/aws@ — the minted operational @aws.*@ credential.
--
-- The request carries an operator-injected Kubernetes JWT (header
-- @X-Prodbox-Operator-Jwt@); the daemon exchanges it for a Vault token under the
-- narrow @prodbox-operator-write@ role and writes the KV object. The daemon's
-- own read-only @prodbox-gateway-daemon@ identity is never used for the write.

-- | The exact KV logical paths the operator-write endpoint accepts. Anything
-- else is a 404 — the endpoint is a deliberately tiny allowlist, not a generic
-- Vault proxy.
allowedOperatorSecretPaths :: [String]
allowedOperatorSecretPaths = ["acme/eab", "gateway/gateway/aws"]

-- | The Vault Kubernetes-auth role the daemon logs into for operator writes.
operatorWriteRoleName :: Text.Text
operatorWriteRoleName = "prodbox-operator-write"

-- | The request header carrying the operator-injected Kubernetes JWT.
operatorJwtHeaderName :: String
operatorJwtHeaderName = "x-prodbox-operator-jwt"

-- | Map a request path to an allowlisted operator-secret logical path. Returns
-- @Nothing@ for any non-@/v1/secret/@ path or any path outside the allowlist,
-- so the read dispatch handles everything else unchanged.
operatorSecretLogicalPath :: String -> Maybe String
operatorSecretLogicalPath path = do
  logical <- stripPrefix "/v1/secret/" path
  if logical `elem` allowedOperatorSecretPaths
    then Just logical
    else Nothing

-- | The HTTP method of a raw request: the first whitespace-delimited token of
-- the request line, verbatim (HTTP methods are case-sensitive and uppercase per
-- RFC 7231). Defaults to @GET@ for a malformed request line.
operatorSecretRequestMethod :: BS.ByteString -> String
operatorSecretRequestMethod rawRequest =
  case words (takeWhile (/= '\r') (takeWhile (/= '\n') (BS8.unpack rawRequest))) of
    method : _ -> method
    _ -> "GET"

-- | Extract the operator JWT header value (case-insensitive name match), if
-- present and non-empty.
operatorSecretJwtHeader :: BS.ByteString -> Maybe String
operatorSecretJwtHeader rawRequest =
  case [ trimHeader (drop 1 value)
       | line <- drop 1 (splitCrlfLines (BS8.unpack rawRequest))
       , let (name, value) = break (== ':') line
       , map toLower (trimHeader name) == operatorJwtHeaderName
       , not (null value)
       ] of
    (jwt : _) | not (null jwt) -> Just jwt
    _ -> Nothing

-- | The request body: everything after the first blank (CRLF CRLF) line.
requestBodyBytes :: BS.ByteString -> BS.ByteString
requestBodyBytes rawRequest =
  case BS.breakSubstring crlfCrlf rawRequest of
    (_, rest)
      | BS.null rest -> BS.empty
      | otherwise -> BS.drop (BS.length crlfCrlf) rest
 where
  crlfCrlf = BS8.pack "\r\n\r\n"

-- | Decode the operator-secret request body as a flat @{ field: value }@ JSON
-- object of string fields — exactly the Vault KV v2 field-map shape.
decodeOperatorSecretFields :: BS.ByteString -> Either String (Map Text.Text Text.Text)
decodeOperatorSecretFields body
  | BS.null (BS8.dropWhile isSpace body) =
      Left "empty request body; expected a JSON object of secret fields"
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left ("invalid secret JSON body: " ++ err)
        Right fields -> Right fields

-- Sprint 2.29: pre-Vault bootstrap route. The password-bearing request is
-- accepted only through the loopback-restricted daemon NodePort and is never
-- logged or echoed.
bootstrapVaultPath :: String
bootstrapVaultPath = "/v1/bootstrap/vault/ensure"

bootstrapVaultStatusPath :: String
bootstrapVaultStatusPath = "/v1/bootstrap/vault/status"

bootstrapVaultSealPath :: String
bootstrapVaultSealPath = "/v1/bootstrap/vault/seal"

bootstrapVaultRotateUnlockBundlePath :: String
bootstrapVaultRotateUnlockBundlePath = "/v1/bootstrap/vault/rotate-unlock-bundle"

bootstrapVaultRotateTransitKeyPath :: String
bootstrapVaultRotateTransitKeyPath = "/v1/bootstrap/vault/rotate-transit-key"

bootstrapVaultPkiStatusPath :: String
bootstrapVaultPkiStatusPath = "/v1/bootstrap/vault/pki/status"

bootstrapVaultPkiIssueTestCertPath :: String
bootstrapVaultPkiIssueTestCertPath = "/v1/bootstrap/vault/pki/issue-test-cert"

bootstrapVaultRequestMaxBytes :: Int
bootstrapVaultRequestMaxBytes = 64 * 1024

data BootstrapVaultRequest = BootstrapVaultRequest
  { bootstrapVaultUnlockPassword :: Text.Text
  , bootstrapVaultLoopbackNodePortVerified :: Bool
  }
  deriving (Eq)

instance Show BootstrapVaultRequest where
  show request =
    "BootstrapVaultRequest {bootstrapVaultUnlockPassword=<redacted>, bootstrapVaultLoopbackNodePortVerified="
      ++ show (bootstrapVaultLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON BootstrapVaultRequest where
  parseJSON =
    withObject "BootstrapVaultRequest" $ \o ->
      BootstrapVaultRequest
        <$> o .: "unlock_password"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON BootstrapVaultRequest where
  toJSON request =
    object
      [ "unlock_password" .= bootstrapVaultUnlockPassword request
      , "loopback_nodeport_verified" .= bootstrapVaultLoopbackNodePortVerified request
      ]

data BootstrapVaultRotateUnlockBundleRequest = BootstrapVaultRotateUnlockBundleRequest
  { bootstrapVaultRotateCurrentPassword :: Text.Text
  , bootstrapVaultRotateNewPassword :: Text.Text
  , bootstrapVaultRotateLoopbackNodePortVerified :: Bool
  }
  deriving (Eq)

instance Show BootstrapVaultRotateUnlockBundleRequest where
  show request =
    "BootstrapVaultRotateUnlockBundleRequest {bootstrapVaultRotateCurrentPassword=<redacted>, bootstrapVaultRotateNewPassword=<redacted>, bootstrapVaultRotateLoopbackNodePortVerified="
      ++ show (bootstrapVaultRotateLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON BootstrapVaultRotateUnlockBundleRequest where
  parseJSON =
    withObject "BootstrapVaultRotateUnlockBundleRequest" $ \o ->
      BootstrapVaultRotateUnlockBundleRequest
        <$> o .: "unlock_password"
        <*> o .: "new_unlock_password"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON BootstrapVaultRotateUnlockBundleRequest where
  toJSON request =
    object
      [ "unlock_password" .= bootstrapVaultRotateCurrentPassword request
      , "new_unlock_password" .= bootstrapVaultRotateNewPassword request
      , "loopback_nodeport_verified" .= bootstrapVaultRotateLoopbackNodePortVerified request
      ]

data BootstrapVaultRotateTransitKeyRequest = BootstrapVaultRotateTransitKeyRequest
  { bootstrapVaultRotateTransitPassword :: Text.Text
  , bootstrapVaultRotateTransitKeyName :: Text.Text
  , bootstrapVaultRotateTransitLoopbackNodePortVerified :: Bool
  }
  deriving (Eq)

instance Show BootstrapVaultRotateTransitKeyRequest where
  show request =
    "BootstrapVaultRotateTransitKeyRequest {bootstrapVaultRotateTransitPassword=<redacted>, bootstrapVaultRotateTransitKeyName="
      ++ show (bootstrapVaultRotateTransitKeyName request)
      ++ ", bootstrapVaultRotateTransitLoopbackNodePortVerified="
      ++ show (bootstrapVaultRotateTransitLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON BootstrapVaultRotateTransitKeyRequest where
  parseJSON =
    withObject "BootstrapVaultRotateTransitKeyRequest" $ \o ->
      BootstrapVaultRotateTransitKeyRequest
        <$> o .: "unlock_password"
        <*> o .: "key_name"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON BootstrapVaultRotateTransitKeyRequest where
  toJSON request =
    object
      [ "unlock_password" .= bootstrapVaultRotateTransitPassword request
      , "key_name" .= bootstrapVaultRotateTransitKeyName request
      , "loopback_nodeport_verified" .= bootstrapVaultRotateTransitLoopbackNodePortVerified request
      ]

data BootstrapVaultResponse = BootstrapVaultResponse
  { bootstrapVaultResponseStatus :: Text.Text
  , bootstrapVaultResponseAction :: Text.Text
  , bootstrapVaultResponseReconcileStepCount :: Int
  }
  deriving (Eq, Show)

instance FromJSON BootstrapVaultResponse where
  parseJSON =
    withObject "BootstrapVaultResponse" $ \o ->
      BootstrapVaultResponse
        <$> o .: "status"
        <*> o .: "action"
        <*> o .: "reconcile_step_count"

instance ToJSON BootstrapVaultResponse where
  toJSON response =
    object
      [ "status" .= bootstrapVaultResponseStatus response
      , "action" .= bootstrapVaultResponseAction response
      , "reconcile_step_count" .= bootstrapVaultResponseReconcileStepCount response
      ]

data BootstrapVaultRequestError
  = BootstrapVaultMethodNotAllowed String
  | BootstrapVaultRequestTooLarge Int
  | BootstrapVaultRequestEmpty
  | BootstrapVaultRequestMalformed String
  | BootstrapVaultPasswordEmpty
  | BootstrapVaultLoopbackUnverified
  deriving (Eq, Show)

decodeBootstrapVaultRequest
  :: BS.ByteString -> Either BootstrapVaultRequestError BootstrapVaultRequest
decodeBootstrapVaultRequest rawRequest
  | method /= "POST" = Left (BootstrapVaultMethodNotAllowed method)
  | BS.length body > bootstrapVaultRequestMaxBytes =
      Left (BootstrapVaultRequestTooLarge (BS.length body))
  | BS.null (BS8.dropWhile isSpace body) = Left BootstrapVaultRequestEmpty
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left (BootstrapVaultRequestMalformed err)
        Right request
          | Text.null (Text.strip (bootstrapVaultUnlockPassword request)) ->
              Left BootstrapVaultPasswordEmpty
          | not (bootstrapVaultLoopbackNodePortVerified request) ->
              Left BootstrapVaultLoopbackUnverified
          | otherwise -> Right request
 where
  method = operatorSecretRequestMethod rawRequest
  body = requestBodyBytes rawRequest

decodeBootstrapVaultAuthenticatedRequest
  :: BS.ByteString -> Either BootstrapVaultRequestError BootstrapVaultRequest
decodeBootstrapVaultAuthenticatedRequest = decodeBootstrapVaultRequest

decodeBootstrapVaultRotateUnlockBundleRequest
  :: BS.ByteString -> Either BootstrapVaultRequestError BootstrapVaultRotateUnlockBundleRequest
decodeBootstrapVaultRotateUnlockBundleRequest rawRequest
  | method /= "POST" = Left (BootstrapVaultMethodNotAllowed method)
  | BS.length body > bootstrapVaultRequestMaxBytes =
      Left (BootstrapVaultRequestTooLarge (BS.length body))
  | BS.null (BS8.dropWhile isSpace body) = Left BootstrapVaultRequestEmpty
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left (BootstrapVaultRequestMalformed err)
        Right request
          | Text.null (Text.strip (bootstrapVaultRotateCurrentPassword request)) ->
              Left BootstrapVaultPasswordEmpty
          | Text.null (Text.strip (bootstrapVaultRotateNewPassword request)) ->
              Left BootstrapVaultPasswordEmpty
          | not (bootstrapVaultRotateLoopbackNodePortVerified request) ->
              Left BootstrapVaultLoopbackUnverified
          | otherwise -> Right request
 where
  method = operatorSecretRequestMethod rawRequest
  body = requestBodyBytes rawRequest

decodeBootstrapVaultRotateTransitKeyRequest
  :: BS.ByteString -> Either BootstrapVaultRequestError BootstrapVaultRotateTransitKeyRequest
decodeBootstrapVaultRotateTransitKeyRequest rawRequest
  | method /= "POST" = Left (BootstrapVaultMethodNotAllowed method)
  | BS.length body > bootstrapVaultRequestMaxBytes =
      Left (BootstrapVaultRequestTooLarge (BS.length body))
  | BS.null (BS8.dropWhile isSpace body) = Left BootstrapVaultRequestEmpty
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left (BootstrapVaultRequestMalformed err)
        Right request
          | Text.null (Text.strip (bootstrapVaultRotateTransitPassword request)) ->
              Left BootstrapVaultPasswordEmpty
          | Text.null (Text.strip (bootstrapVaultRotateTransitKeyName request)) ->
              Left (BootstrapVaultRequestMalformed "key_name must not be empty")
          | not (bootstrapVaultRotateTransitLoopbackNodePortVerified request) ->
              Left BootstrapVaultLoopbackUnverified
          | otherwise -> Right request
 where
  method = operatorSecretRequestMethod rawRequest
  body = requestBodyBytes rawRequest

renderBootstrapVaultRequestError :: BootstrapVaultRequestError -> String
renderBootstrapVaultRequestError err = case err of
  BootstrapVaultMethodNotAllowed method ->
    "method " ++ method ++ " is not supported for " ++ bootstrapVaultPath
  BootstrapVaultRequestTooLarge size ->
    "bootstrap request body is too large: "
      ++ show size
      ++ " bytes; maximum is "
      ++ show bootstrapVaultRequestMaxBytes
  BootstrapVaultRequestEmpty ->
    "empty request body; expected JSON object with unlock_password and loopback_nodeport_verified"
  BootstrapVaultRequestMalformed detail ->
    "invalid bootstrap JSON body: " ++ detail
  BootstrapVaultPasswordEmpty ->
    "unlock_password must not be empty"
  BootstrapVaultLoopbackUnverified ->
    "loopback NodePort restriction is not verified; refusing password-bearing bootstrap route"

splitCrlfLines :: String -> [String]
splitCrlfLines = foldr step [""] . filter (/= '\r')
 where
  step '\n' acc = "" : acc
  step c (cur : rest) = (c : cur) : rest
  step c [] = [[c]]

trimHeader :: String -> String
trimHeader = f . f where f = reverse . dropWhile isSpace

data BootstrapVaultEnsureError
  = BootstrapVaultEnsureVaultUnavailable String
  | BootstrapVaultEnsureBundleUnavailable String
  | BootstrapVaultEnsureUnsealFailed String
  | BootstrapVaultEnsureReconcileFailed String
  deriving (Eq, Show)

handleBootstrapVaultEnsure :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultEnsure sock env rawRequest =
  case decodeBootstrapVaultRequest rawRequest of
    Left (BootstrapVaultMethodNotAllowed _) ->
      sendHttpResponse
        sock
        405
        "text/plain"
        ( renderBootstrapVaultRequestError
            (BootstrapVaultMethodNotAllowed (operatorSecretRequestMethod rawRequest))
            ++ "\n"
        )
    Left err ->
      sendHttpResponse sock 400 "text/plain" (renderBootstrapVaultRequestError err ++ "\n")
    Right request -> do
      result <- ensureBootstrapVault (envBootConfig env) request
      case result of
        Left err ->
          let (status, message) = renderBootstrapVaultEnsureError err
           in sendHttpResponse sock status "text/plain" (message ++ "\n")
        Right response ->
          sendLazyHttpResponse sock 200 "application/json" (encode response)

renderBootstrapVaultEnsureError :: BootstrapVaultEnsureError -> (Int, String)
renderBootstrapVaultEnsureError err = case err of
  BootstrapVaultEnsureVaultUnavailable detail ->
    (503, "Vault bootstrap unavailable: " ++ detail)
  BootstrapVaultEnsureBundleUnavailable detail ->
    (503, "Vault bootstrap bundle unavailable: " ++ detail)
  BootstrapVaultEnsureUnsealFailed detail ->
    (502, "Vault unseal failed: " ++ detail)
  BootstrapVaultEnsureReconcileFailed detail ->
    (502, "Vault reconcile failed: " ++ detail)

handleBootstrapVaultStatus :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultStatus sock env rawRequest =
  case operatorSecretRequestMethod rawRequest of
    "GET" -> do
      result <- vaultSealStatus (bootstrapVaultAddress (envBootConfig env))
      case result of
        Left err ->
          sendHttpResponse
            sock
            503
            "text/plain"
            ("Vault status unavailable: " ++ renderHttpError err ++ "\n")
        Right status ->
          sendLazyHttpResponse sock 200 "application/json" (encode status)
    method ->
      sendHttpResponse
        sock
        405
        "text/plain"
        ("method " ++ method ++ " is not supported for " ++ bootstrapVaultStatusPath ++ "\n")

handleBootstrapVaultSeal :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultSeal sock env rawRequest =
  handleBootstrapVaultPasswordAction sock rawRequest $ \request -> do
    result <- sealBootstrapVault (envBootConfig env) request
    pure $ encodeBootstrapActionResult result

handleBootstrapVaultRotateUnlockBundle :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultRotateUnlockBundle sock env rawRequest =
  case decodeBootstrapVaultRotateUnlockBundleRequest rawRequest of
    Left (BootstrapVaultMethodNotAllowed _) ->
      sendBootstrapRequestError
        sock
        405
        rawRequest
        (BootstrapVaultMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendBootstrapRequestError sock 400 rawRequest err
    Right request -> do
      result <- rotateBootstrapUnlockBundle (envBootConfig env) request
      sendBootstrapActionResult sock result

handleBootstrapVaultRotateTransitKey :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultRotateTransitKey sock env rawRequest =
  case decodeBootstrapVaultRotateTransitKeyRequest rawRequest of
    Left (BootstrapVaultMethodNotAllowed _) ->
      sendBootstrapRequestError
        sock
        405
        rawRequest
        (BootstrapVaultMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendBootstrapRequestError sock 400 rawRequest err
    Right request -> do
      result <- rotateBootstrapTransitKey (envBootConfig env) request
      sendBootstrapActionResult sock result

handleBootstrapVaultPkiStatus :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultPkiStatus sock env rawRequest =
  handleBootstrapVaultPasswordAction sock rawRequest $ \request -> do
    result <- bootstrapVaultPkiStatus (envBootConfig env) request
    pure $ encodeBootstrapActionResult result

handleBootstrapVaultPkiIssueTestCert :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultPkiIssueTestCert sock env rawRequest =
  handleBootstrapVaultPasswordAction sock rawRequest $ \request -> do
    result <- bootstrapVaultPkiIssueTestCert (envBootConfig env) request
    pure $ encodeBootstrapActionResult result

handleBootstrapVaultPasswordAction
  :: Socket
  -> BS.ByteString
  -> (BootstrapVaultRequest -> IO (Either BootstrapVaultEnsureError BL.ByteString))
  -> IO ()
handleBootstrapVaultPasswordAction sock rawRequest action =
  case decodeBootstrapVaultAuthenticatedRequest rawRequest of
    Left (BootstrapVaultMethodNotAllowed _) ->
      sendBootstrapRequestError
        sock
        405
        rawRequest
        (BootstrapVaultMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendBootstrapRequestError sock 400 rawRequest err
    Right request -> do
      result <- action request
      case result of
        Left err ->
          let (status, message) = renderBootstrapVaultEnsureError err
           in sendHttpResponse sock status "text/plain" (message ++ "\n")
        Right body ->
          sendLazyHttpResponse sock 200 "application/json" body

sendBootstrapRequestError :: Socket -> Int -> BS.ByteString -> BootstrapVaultRequestError -> IO ()
sendBootstrapRequestError sock status _rawRequest err =
  sendHttpResponse sock status "text/plain" (renderBootstrapVaultRequestError err ++ "\n")

sendBootstrapActionResult
  :: Socket -> Either BootstrapVaultEnsureError BL.ByteString -> IO ()
sendBootstrapActionResult sock result =
  case result of
    Left err ->
      let (status, message) = renderBootstrapVaultEnsureError err
       in sendHttpResponse sock status "text/plain" (message ++ "\n")
    Right body ->
      sendLazyHttpResponse sock 200 "application/json" body

encodeBootstrapActionResult
  :: Either BootstrapVaultEnsureError Value
  -> Either BootstrapVaultEnsureError BL.ByteString
encodeBootstrapActionResult = fmap encode

ensureBootstrapVault
  :: DaemonConfig
  -> BootstrapVaultRequest
  -> IO (Either BootstrapVaultEnsureError BootstrapVaultResponse)
ensureBootstrapVault config request = do
  statusResult <- vaultSealStatus address
  case statusResult of
    Left err ->
      pure (Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err)))
    Right status ->
      case bootstrapAction status of
        BootstrapInitialize -> initializeUnsealAndReconcile
        BootstrapUnseal -> unsealExistingAndReconcile status
        BootstrapReady -> reconcileReadyVault
 where
  address = bootstrapVaultAddress config
  minioConfig = bootstrapVaultObjectStoreConfig config
  password = bootstrapVaultUnlockPassword request

  initializeUnsealAndReconcile = do
    initResult <- vaultInit address defaultInitRequest
    case initResult of
      Left err ->
        pure (Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err)))
      Right initResponse -> do
        now <- getCurrentTime
        let bundle =
              initResponseToUnlockBundle
                (Text.pack (daemonNodeId config))
                address
                (Text.pack (formatShow iso8601Format now))
                initResponse
        encrypted <- encryptUnlockBundle password bundle
        case encrypted of
          Left err ->
            pure
              ( Left
                  ( BootstrapVaultEnsureBundleUnavailable
                      ("unlock bundle encryption failed: " ++ renderUnlockBundleError err)
                  )
              )
          Right envelopeBytes -> do
            writeResult <- putAndVerifyBootstrapBundle minioConfig password envelopeBytes
            case writeResult of
              Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
              Right () -> do
                currentStatus <- vaultSealStatus address
                case currentStatus of
                  Left err ->
                    pure (Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err)))
                  Right sealedStatus -> do
                    unsealResult <- submitBootstrapUnsealSteps address sealedStatus bundle
                    case unsealResult of
                      Left err -> pure (Left (BootstrapVaultEnsureUnsealFailed err))
                      Right () ->
                        reconcileWithRootToken
                          "initialized-unsealed-reconciled"
                          (VaultToken (unlockBundleInitialRootToken bundle))

  unsealExistingAndReconcile status = do
    bundleResult <- readBootstrapBundle minioConfig password
    case bundleResult of
      Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
      Right bundle -> do
        unsealResult <- submitBootstrapUnsealSteps address status bundle
        case unsealResult of
          Left err -> pure (Left (BootstrapVaultEnsureUnsealFailed err))
          Right () ->
            reconcileWithRootToken "unsealed-reconciled" (VaultToken (unlockBundleInitialRootToken bundle))

  reconcileReadyVault = do
    bundleResult <- readBootstrapBundle minioConfig password
    case bundleResult of
      Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
      Right bundle ->
        reconcileWithRootToken "reconciled" (VaultToken (unlockBundleInitialRootToken bundle))

  reconcileWithRootToken actionName token = do
    reconcileResult <- runVaultReconcile address token defaultVaultReconcilePlan
    pure $ case reconcileResult of
      Left err ->
        Left (BootstrapVaultEnsureReconcileFailed (renderVaultReconcileError err))
      Right steps ->
        Right
          BootstrapVaultResponse
            { bootstrapVaultResponseStatus = "ready"
            , bootstrapVaultResponseAction = actionName
            , bootstrapVaultResponseReconcileStepCount = length steps
            }

sealBootstrapVault
  :: DaemonConfig -> BootstrapVaultRequest -> IO (Either BootstrapVaultEnsureError Value)
sealBootstrapVault config request = do
  tokenResult <- bootstrapRootToken config (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <- vaultSeal (bootstrapVaultAddress config) token
      pure $ case result of
        Left err -> Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err))
        Right () ->
          Right
            ( object
                [ "status" .= ("sealed" :: Text.Text)
                , "action" .= ("sealed" :: Text.Text)
                ]
            )

rotateBootstrapUnlockBundle
  :: DaemonConfig
  -> BootstrapVaultRotateUnlockBundleRequest
  -> IO (Either BootstrapVaultEnsureError BL.ByteString)
rotateBootstrapUnlockBundle config request = do
  bundleResult <- readBootstrapBundle minioConfig (bootstrapVaultRotateCurrentPassword request)
  case bundleResult of
    Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
    Right bundle -> do
      encrypted <- encryptUnlockBundle (bootstrapVaultRotateNewPassword request) bundle
      case encrypted of
        Left err ->
          pure
            ( Left
                ( BootstrapVaultEnsureBundleUnavailable
                    ("unlock bundle encryption failed: " ++ renderUnlockBundleError err)
                )
            )
        Right envelopeBytes -> do
          writeResult <-
            putAndVerifyBootstrapBundle
              minioConfig
              (bootstrapVaultRotateNewPassword request)
              envelopeBytes
          pure $ case writeResult of
            Left err -> Left (BootstrapVaultEnsureBundleUnavailable err)
            Right () ->
              Right
                ( encode
                    ( object
                        [ "status" .= ("ready" :: Text.Text)
                        , "action" .= ("unlock-bundle-rotated" :: Text.Text)
                        ]
                    )
                )
 where
  minioConfig = bootstrapVaultObjectStoreConfig config

rotateBootstrapTransitKey
  :: DaemonConfig
  -> BootstrapVaultRotateTransitKeyRequest
  -> IO (Either BootstrapVaultEnsureError BL.ByteString)
rotateBootstrapTransitKey config request = do
  tokenResult <- bootstrapRootToken config (bootstrapVaultRotateTransitPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <-
        vaultRotateTransitKey
          (bootstrapVaultAddress config)
          token
          (bootstrapVaultRotateTransitKeyName request)
      pure $ case result of
        Left err -> Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err))
        Right () ->
          Right
            ( encode
                ( object
                    [ "status" .= ("ready" :: Text.Text)
                    , "action" .= ("transit-key-rotated" :: Text.Text)
                    , "key_name" .= bootstrapVaultRotateTransitKeyName request
                    ]
                )
            )

bootstrapVaultPkiStatus
  :: DaemonConfig -> BootstrapVaultRequest -> IO (Either BootstrapVaultEnsureError Value)
bootstrapVaultPkiStatus config request = do
  tokenResult <- bootstrapRootToken config (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      mountsResult <- vaultListMounts (bootstrapVaultAddress config) token
      pure $ case mountsResult of
        Left err -> Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err))
        Right mounts ->
          case Map.lookup "pki" mounts of
            Nothing ->
              Right
                ( object
                    [ "status" .= ("missing" :: Text.Text)
                    , "mount" .= ("pki" :: Text.Text)
                    ]
                )
            Just mount ->
              Right
                ( object
                    [ "status" .= ("present" :: Text.Text)
                    , "mount" .= ("pki" :: Text.Text)
                    , "type" .= vaultMountType mount
                    ]
                )

bootstrapVaultPkiIssueTestCert
  :: DaemonConfig -> BootstrapVaultRequest -> IO (Either BootstrapVaultEnsureError Value)
bootstrapVaultPkiIssueTestCert config request = do
  tokenResult <- bootstrapRootToken config (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <-
        vaultPkiIssueTestCertificate
          (bootstrapVaultAddress config)
          token
          "prodbox-test"
          "prodbox-vault-test.internal"
          "1m"
      pure $ case result of
        Left err -> Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err))
        Right certPem ->
          Right
            ( object
                [ "status" .= ("issued" :: Text.Text)
                , "certificate" .= certPem
                ]
            )

bootstrapRootToken :: DaemonConfig -> Text.Text -> IO (Either BootstrapVaultEnsureError VaultToken)
bootstrapRootToken config password = do
  bundleResult <- readBootstrapBundle (bootstrapVaultObjectStoreConfig config) password
  pure $ case bundleResult of
    Left err -> Left (BootstrapVaultEnsureBundleUnavailable err)
    Right bundle -> Right (VaultToken (unlockBundleInitialRootToken bundle))

bootstrapVaultAddress :: DaemonConfig -> VaultAddress
bootstrapVaultAddress config =
  case daemonVaultAuth config of
    Just auth -> VaultAddress (Text.pack (gatewayVaultAddress auth))
    Nothing -> VaultAddress "http://vault.vault.svc.cluster.local:8200"

bootstrapVaultObjectStoreConfig :: DaemonConfig -> ObjectStoreConfig
bootstrapVaultObjectStoreConfig config =
  bootstrapObjectStoreConfigWithEndpoint
    (fromMaybe "http://minio.prodbox.svc.cluster.local:9000" (daemonMinioEndpointUrl config))

data PulumiObjectRequestError
  = PulumiObjectMethodNotAllowed String
  | PulumiObjectRequestTooLarge Int
  | PulumiObjectRequestEmpty
  | PulumiObjectRequestMalformed String
  | PulumiObjectStackInvalid String
  | PulumiObjectLoopbackUnverified
  deriving (Eq, Show)

decodePulumiObjectRequest
  :: BS.ByteString -> Either PulumiObjectRequestError PulumiObjectRequest
decodePulumiObjectRequest rawRequest = do
  request <- decodePulumiObjectJson rawRequest
  case validatePulumiObjectStackName (pulumiObjectStackName request) of
    Left err -> Left (PulumiObjectStackInvalid err)
    Right stackName
      | not (pulumiObjectLoopbackNodePortVerified request) ->
          Left PulumiObjectLoopbackUnverified
      | otherwise ->
          Right request {pulumiObjectStackName = stackName}

decodePulumiObjectPutRequest
  :: BS.ByteString -> Either PulumiObjectRequestError PulumiObjectPutRequest
decodePulumiObjectPutRequest rawRequest = do
  request <- decodePulumiObjectJson rawRequest
  case validatePulumiObjectStackName (pulumiObjectPutStackName request) of
    Left err -> Left (PulumiObjectStackInvalid err)
    Right stackName
      | not (pulumiObjectPutLoopbackNodePortVerified request) ->
          Left PulumiObjectLoopbackUnverified
      | otherwise ->
          Right request {pulumiObjectPutStackName = stackName}

decodePulumiObjectJson
  :: (FromJSON a) => BS.ByteString -> Either PulumiObjectRequestError a
decodePulumiObjectJson rawRequest
  | method /= "POST" = Left (PulumiObjectMethodNotAllowed method)
  | BS.length body > pulumiObjectRequestMaxBytes =
      Left (PulumiObjectRequestTooLarge (BS.length body))
  | BS.null (BS8.dropWhile isSpace body) = Left PulumiObjectRequestEmpty
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left (PulumiObjectRequestMalformed err)
        Right request -> Right request
 where
  method = operatorSecretRequestMethod rawRequest
  body = requestBodyBytes rawRequest

renderPulumiObjectRequestError :: PulumiObjectRequestError -> String
renderPulumiObjectRequestError err = case err of
  PulumiObjectMethodNotAllowed method ->
    "method " ++ method ++ " is not supported for daemon Pulumi object-store routes"
  PulumiObjectRequestTooLarge size ->
    "Pulumi object-store request body is too large: "
      ++ show size
      ++ " bytes; maximum is "
      ++ show pulumiObjectRequestMaxBytes
  PulumiObjectRequestEmpty ->
    "empty request body; expected JSON object with stack and loopback_nodeport_verified"
  PulumiObjectRequestMalformed detail ->
    "invalid Pulumi object-store JSON body: " ++ detail
  PulumiObjectStackInvalid detail ->
    "invalid Pulumi stack name: " ++ detail
  PulumiObjectLoopbackUnverified ->
    "loopback NodePort restriction is not verified; refusing daemon Pulumi object-store route"

handlePulumiObjectGet :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handlePulumiObjectGet sock env rawRequest =
  case decodePulumiObjectRequest rawRequest of
    Left (PulumiObjectMethodNotAllowed _) ->
      sendPulumiObjectRequestError
        sock
        405
        (PulumiObjectMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendPulumiObjectRequestError sock 400 err
    Right request -> do
      result <- readDaemonPulumiObject env (pulumiObjectStackName request)
      case result of
        Left err -> sendPulumiObjectActionError sock err
        Right Nothing ->
          sendLazyHttpResponse sock 200 "application/json" (encode PulumiObjectAbsent)
        Right (Just checkpoint) ->
          sendLazyHttpResponse sock 200 "application/json" (encode (PulumiObjectPresent checkpoint))

handlePulumiObjectPut :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handlePulumiObjectPut sock env rawRequest =
  case decodePulumiObjectPutRequest rawRequest of
    Left (PulumiObjectMethodNotAllowed _) ->
      sendPulumiObjectRequestError
        sock
        405
        (PulumiObjectMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendPulumiObjectRequestError sock 400 err
    Right request -> do
      result <-
        writeDaemonPulumiObject
          env
          (pulumiObjectPutStackName request)
          (pulumiObjectPutCheckpoint request)
      case result of
        Left err -> sendPulumiObjectActionError sock err
        Right () ->
          sendLazyHttpResponse sock 200 "application/json" (encode (object ["stored" .= True]))

handlePulumiObjectDelete :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handlePulumiObjectDelete sock env rawRequest =
  case decodePulumiObjectRequest rawRequest of
    Left (PulumiObjectMethodNotAllowed _) ->
      sendPulumiObjectRequestError
        sock
        405
        (PulumiObjectMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendPulumiObjectRequestError sock 400 err
    Right request -> do
      result <- deleteDaemonPulumiObject env (pulumiObjectStackName request)
      case result of
        Left err -> sendPulumiObjectActionError sock err
        Right () ->
          sendLazyHttpResponse sock 200 "application/json" (encode (object ["deleted" .= True]))

sendPulumiObjectRequestError :: Socket -> Int -> PulumiObjectRequestError -> IO ()
sendPulumiObjectRequestError sock status err =
  sendHttpResponse sock status "text/plain" (renderPulumiObjectRequestError err ++ "\n")

sendPulumiObjectActionError :: Socket -> String -> IO ()
sendPulumiObjectActionError sock detail =
  sendHttpResponse sock 503 "text/plain" ("Pulumi object-store unavailable: " ++ detail ++ "\n")

data DaemonPulumiObjectMaterial = DaemonPulumiObjectMaterial
  { daemonPulumiObjectStore :: ObjectStoreConfig
  , daemonPulumiCipher :: DekCipher
  , daemonPulumiHmacKey :: ByteString
  , daemonPulumiClusterId :: Text.Text
  }

readDaemonPulumiObject :: DaemonEnv -> Text.Text -> IO (Either String (Maybe ByteString))
readDaemonPulumiObject env stackName = do
  materialResult <- resolveDaemonPulumiObjectMaterial env
  case materialResult of
    Left err -> pure (Left err)
    Right material -> do
      result <-
        getLogical
          (daemonPulumiObjectStore material)
          (daemonPulumiCipher material)
          (daemonPulumiHmacKey material)
          (daemonPulumiClusterId material)
          (LogicalPulumiStack stackName)
      pure $ case result of
        Left (EncryptedObjectMissing _) -> Right Nothing
        Left err -> Left (renderEncryptedObjectError err)
        Right checkpoint -> Right (Just checkpoint)

writeDaemonPulumiObject :: DaemonEnv -> Text.Text -> ByteString -> IO (Either String ())
writeDaemonPulumiObject env stackName checkpoint = do
  materialResult <- resolveDaemonPulumiObjectMaterial env
  case materialResult of
    Left err -> pure (Left err)
    Right material -> do
      result <-
        putLogical
          (daemonPulumiObjectStore material)
          (daemonPulumiCipher material)
          (daemonPulumiHmacKey material)
          (daemonPulumiClusterId material)
          (LogicalPulumiStack stackName)
          checkpoint
      pure $ case result of
        Left err -> Left (renderEncryptedObjectError err)
        Right () -> Right ()

deleteDaemonPulumiObject :: DaemonEnv -> Text.Text -> IO (Either String ())
deleteDaemonPulumiObject env stackName = do
  materialResult <- resolveDaemonPulumiObjectMaterial env
  case materialResult of
    Left err -> pure (Left err)
    Right material -> do
      let key =
            objectKeyForOpaqueId
              (opaqueObjectId (daemonPulumiHmacKey material) (LogicalPulumiStack stackName))
      deleteObject (daemonPulumiObjectStore material) key

resolveDaemonPulumiObjectMaterial :: DaemonEnv -> IO (Either String DaemonPulumiObjectMaterial)
resolveDaemonPulumiObjectMaterial env = go 0
 where
  -- Each call does a fresh Vault k8s-auth login + object-store HMAC read. Right
  -- after a fresh `vault reconcile` (the post-teardown AWS postflight) or a daemon
  -- restart, the login can succeed before the role's policy has fully propagated,
  -- yielding a transient 403. Retry with a fresh re-login (daemonWorkerRetryPolicy:
  -- 5 attempts, exp backoff) so a transient failure self-heals instead of failing
  -- the postflight object-store read (readiness hardening).
  go attemptIndex = do
    result <- resolveDaemonPulumiObjectMaterialOnce env
    case result of
      Right material -> pure (Right material)
      Left err
        | attemptIndex + 1 < retryPolicyMaxAttempts daemonWorkerRetryPolicy -> do
            logForEnv
              env
              Warn
              "daemon_object_store_material_retry"
              [field "attempt" (attemptIndex + 1), field "detail" err]
            threadDelay (retryDelayMicros daemonWorkerRetryPolicy attemptIndex)
            go (attemptIndex + 1)
        | otherwise -> pure (Left err)

resolveDaemonPulumiObjectMaterialOnce :: DaemonEnv -> IO (Either String DaemonPulumiObjectMaterial)
resolveDaemonPulumiObjectMaterialOnce env = do
  clusterResult <- loadDaemonClusterId (envConfigPath env)
  vaultResult <- resolveGatewayVaultToken (envBootConfig env)
  case (clusterResult, vaultResult) of
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    (Right clusterId, Right (address, token)) -> do
      hmacResult <- readDaemonObjectStoreHmac address token
      case hmacResult of
        Left err -> pure (Left err)
        Right hmacKey ->
          pure $ do
            objectStore <- daemonPulumiObjectStoreConfig (envBootConfig env)
            Right
              DaemonPulumiObjectMaterial
                { daemonPulumiObjectStore = objectStore
                , daemonPulumiCipher = vaultTransitDekCipher address token "prodbox-pulumi-state"
                , daemonPulumiHmacKey = hmacKey
                , daemonPulumiClusterId = clusterId
                }

loadDaemonClusterId :: Maybe FilePath -> IO (Either String Text.Text)
loadDaemonClusterId maybeConfigPath = do
  let configMapDir = maybe "/etc/gateway/config" takeDirectory maybeConfigPath
  containerDefaultPath <- resolveTier0ConfigPath "/"
  result <- loadDaemonBinaryContext configMapDir containerDefaultPath
  pure $ case result of
    Left err -> Left ("daemon Tier-0 cluster id unavailable: " ++ err)
    Right (_, projectConfig) -> Right (cluster_id (context projectConfig))

readDaemonObjectStoreHmac :: VaultAddress -> VaultToken -> IO (Either String ByteString)
readDaemonObjectStoreHmac address token = do
  result <- vaultKvReadV2 address token "secret" "object-store/hmac"
  pure $ case result of
    Left err -> Left ("daemon object-store HMAC unavailable: " ++ renderHttpError err)
    Right fields ->
      case Map.lookup "key" fields of
        Just value
          | not (Text.null (Text.strip value)) ->
              Right (TextEncoding.encodeUtf8 value)
        _ -> Left "daemon object-store HMAC unavailable: secret/object-store/hmac is missing field key"

daemonPulumiObjectStoreConfig :: DaemonConfig -> Either String ObjectStoreConfig
daemonPulumiObjectStoreConfig config =
  case daemonMinioCreds config of
    Nothing -> Left "daemon MinIO credentials are not configured"
    Just creds ->
      Right
        ObjectStoreConfig
          { objectStoreEndpoint =
              fromMaybe "http://minio.prodbox.svc.cluster.local:9000" (daemonMinioEndpointUrl config)
          , objectStoreBucket = defaultObjectStoreBucket
          , objectStoreAccessKey = gatewayMinioAccessKey creds
          , objectStoreSecretKey = gatewayMinioSecretKey creds
          }

putAndVerifyBootstrapBundle
  :: ObjectStoreConfig
  -> Text.Text
  -> BS.ByteString
  -> IO (Either String ())
putAndVerifyBootstrapBundle config password envelopeBytes = do
  putResult <- putBundleObject config envelopeBytes
  case putResult of
    Left err -> pure (Left ("write failed: " ++ err))
    Right () -> do
      readResult <- getBundleObject config
      pure $ case readResult of
        Left err -> Left ("read-back failed: " ++ err)
        Right Nothing -> Left "read-back returned no bootstrap unlock bundle"
        Right (Just bytes) ->
          case decryptUnlockBundle password bytes of
            Right _ -> Right ()
            Left err ->
              Left ("read-back did not decrypt: " ++ renderUnlockBundleError err)

readBootstrapBundle
  :: ObjectStoreConfig
  -> Text.Text
  -> IO (Either String UnlockBundle)
readBootstrapBundle config password = do
  result <- getBundleObject config
  pure $ case result of
    Left err -> Left ("read failed: " ++ err)
    Right Nothing -> Left "bootstrap unlock bundle is absent"
    Right (Just bytes) ->
      case decryptUnlockBundle password bytes of
        Left err -> Left ("unlock bundle did not decrypt: " ++ renderUnlockBundleError err)
        Right bundle -> Right bundle

submitBootstrapUnsealSteps
  :: VaultAddress
  -> SealStatus
  -> UnlockBundle
  -> IO (Either String ())
submitBootstrapUnsealSteps address status bundle =
  case planUnseal status (unlockBundleUnsealKeys bundle) of
    Left err -> pure (Left ("unseal plan failed: " ++ err))
    Right steps -> go steps
 where
  go [] =
    pure (Left "unseal consumed every key share but Vault is still sealed")
  go (step : rest) = do
    result <- vaultSubmitUnseal address (unsealStepKey step)
    case result of
      Left err -> pure (Left ("unseal submission failed: " ++ renderHttpError err))
      Right newStatus ->
        case interpretUnsealProgress newStatus step of
          UnsealCompleted -> pure (Right ())
          UnsealAdvanced _ -> go rest
          UnsealStalled ->
            pure (Left "unseal stalled; a key share did not advance progress")

-- | Errors from the operator-secret write path, mapped to HTTP status codes.
data OperatorWriteError
  = OperatorWriteAuthUnconfigured String
  | OperatorWriteAuthFailed String
  | OperatorWriteVaultFailed String
  deriving (Eq, Show)

-- | Handle @POST /v1/secret/<logical>@: require the operator JWT, decode the
-- body, exchange the JWT for a Vault token under the operator-write role, and
-- write the KV object. Never echoes the written secret back.
handleOperatorSecretWrite :: Socket -> DaemonEnv -> BS.ByteString -> String -> IO ()
handleOperatorSecretWrite sock env rawRequest logical =
  case operatorSecretJwtHeader rawRequest of
    Nothing ->
      sendHttpResponse sock 401 "text/plain" ("missing " ++ operatorJwtHeaderName ++ " header\n")
    Just jwt ->
      case decodeOperatorSecretFields (requestBodyBytes rawRequest) of
        Left err -> sendHttpResponse sock 400 "text/plain" (err ++ "\n")
        Right fields -> do
          writeResult <-
            writeOperatorSecret (envBootConfig env) (Text.pack jwt) (Text.pack logical) fields
          case writeResult of
            Left (OperatorWriteAuthUnconfigured detail) ->
              sendHttpResponse sock 503 "text/plain" (detail ++ "\n")
            Left (OperatorWriteAuthFailed detail) ->
              sendHttpResponse sock 403 "text/plain" (detail ++ "\n")
            Left (OperatorWriteVaultFailed detail) ->
              sendHttpResponse sock 502 "text/plain" (detail ++ "\n")
            Right () ->
              sendLazyHttpResponse sock 200 "application/json" (encode (object ["written" .= True]))

-- | Exchange the operator JWT for a Vault token under the operator-write role
-- and write the KV v2 object at @secret/<logical>@.
writeOperatorSecret
  :: DaemonConfig
  -> Text.Text
  -> Text.Text
  -> Map Text.Text Text.Text
  -> IO (Either OperatorWriteError ())
writeOperatorSecret config jwt logical fields =
  case daemonVaultAuth config of
    Nothing ->
      pure
        ( Left
            (OperatorWriteAuthUnconfigured "operator-write unavailable: gateway Vault auth is not configured")
        )
    Just auth -> do
      let address = VaultAddress (Text.pack (gatewayVaultAddress auth))
      loginResult <-
        vaultKubernetesLogin
          address
          (Text.pack (gatewayVaultAuthPath auth))
          operatorWriteRoleName
          jwt
      case loginResult of
        Left err ->
          pure
            ( Left
                (OperatorWriteAuthFailed ("operator-write Vault Kubernetes auth failed: " ++ renderHttpError err))
            )
        Right token -> do
          writeResult <- vaultKvWriteV2 address token "secret" logical fields
          pure $ case writeResult of
            Left err ->
              Left (OperatorWriteVaultFailed ("operator-write Vault KV write failed: " ++ renderHttpError err))
            Right () -> Right ()

data FederationChildBootstrapError
  = FederationVaultUnavailable String
  | FederationChildBootstrapMissing
  deriving (Eq, Show)

federationBootstrapChildId :: String -> Maybe String
federationBootstrapChildId path = do
  rest <- stripPrefix "/v1/federation/children/" path
  let suffix = "/bootstrap"
  if suffix `isSuffixOf` rest
    then
      let childId = take (length rest - length suffix) rest
       in if null childId then Nothing else Just childId
    else Nothing

readFederationChildren :: DaemonConfig -> IO (Either String [ChildMetadata])
readFederationChildren config = do
  vaultResult <- resolveGatewayVaultToken config
  case vaultResult of
    Left err -> pure (Left err)
    Right (address, token) -> do
      indexResult <- vaultKvReadV2 address token "secret" federationChildrenIndexKvLogicalPath
      case indexResult of
        Left (HttpStatus 404 _) -> pure (Right [])
        Left err -> pure (Left ("federation inventory unavailable: " ++ renderHttpError err))
        Right fields ->
          case decodePayloadJsonField decodeChildIndex fields of
            Left err -> pure (Left ("federation inventory index invalid: " ++ err))
            Right (ChildIndex childIds) -> readFederationChildMetadataList address token childIds

readFederationChildMetadata
  :: VaultAddress -> VaultToken -> Text.Text -> IO (Either String ChildMetadata)
readFederationChildMetadata address token childId = do
  readResult <- vaultKvReadV2 address token "secret" (childMetadataKvLogicalPath childId)
  pure $ case readResult of
    Left err -> Left ("federation child metadata unavailable: " ++ renderHttpError err)
    Right fields -> decodePayloadJsonField decodeChildMetadata fields

readFederationChildMetadataList
  :: VaultAddress -> VaultToken -> [Text.Text] -> IO (Either String [ChildMetadata])
readFederationChildMetadataList _ _ [] = pure (Right [])
readFederationChildMetadataList address token (childId : rest) = do
  current <- readFederationChildMetadata address token childId
  case current of
    Left err -> pure (Left err)
    Right metadata -> do
      remaining <- readFederationChildMetadataList address token rest
      pure ((metadata :) <$> remaining)

readFederationChildBootstrap
  :: DaemonConfig -> Text.Text -> IO (Either FederationChildBootstrapError ChildBootstrapCredential)
readFederationChildBootstrap config childId = do
  vaultResult <- resolveGatewayVaultToken config
  case vaultResult of
    Left err -> pure (Left (FederationVaultUnavailable err))
    Right (address, token) -> do
      readResult <- vaultKvReadV2 address token "secret" (childBootstrapKvLogicalPath childId)
      pure $ case readResult of
        Left (HttpStatus 404 _) -> Left FederationChildBootstrapMissing
        Left err -> Left (FederationVaultUnavailable ("federation bootstrap unavailable: " ++ renderHttpError err))
        Right fields ->
          case decodePayloadJsonField decodeChildBootstrapCredential fields of
            Left err -> Left (FederationVaultUnavailable ("federation bootstrap payload invalid: " ++ err))
            Right credential -> Right credential

resolveGatewayVaultToken :: DaemonConfig -> IO (Either String (VaultAddress, VaultToken))
resolveGatewayVaultToken config =
  case daemonVaultAuth config of
    Nothing ->
      pure (Left "federation inventory unavailable: gateway Vault auth is not configured")
    Just auth -> do
      jwtResult <- readGatewayServiceAccountToken (gatewayVaultServiceAccountTokenFile auth)
      case jwtResult of
        Left err -> pure (Left err)
        Right jwt -> do
          let address = VaultAddress (Text.pack (gatewayVaultAddress auth))
          loginResult <-
            vaultKubernetesLogin
              address
              (Text.pack (gatewayVaultAuthPath auth))
              (Text.pack (gatewayVaultRole auth))
              jwt
          pure $ case loginResult of
            Left err -> Left ("federation inventory unavailable: Vault Kubernetes auth failed: " ++ renderHttpError err)
            Right token -> Right (address, token)

readGatewayServiceAccountToken :: FilePath -> IO (Either String Text.Text)
readGatewayServiceAccountToken path = do
  result <- try (TextIO.readFile path) :: IO (Either SomeException Text.Text)
  pure $ case result of
    Left exc ->
      Left
        ( "federation inventory unavailable: failed to read gateway service-account token: "
            ++ displayException exc
        )
    Right rawToken ->
      let token = Text.strip rawToken
       in if Text.null token
            then Left "federation inventory unavailable: gateway service-account token is empty"
            else Right token

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
          ++ if peerHealthOutboundConnected health then "1" else "0"
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

-- | Accept loop shared by both listeners (REST and peer-events). Sprint
-- 2.25: each accepted connection is served under its OWN 'withAsync' child
-- (never a raw unmanaged thread spawn) so a handler that throws or is
-- cancelled can never leak a thread, wedge the accept loop, or block sibling
-- connections. The accept
-- loop recurses inside the 'withAsync' continuation, so it keeps accepting
-- while in-flight connections run concurrently; when the loop finally returns
-- (drain, with @allowDuringDrain@ False), 'withAsync' deterministically
-- cancels any still-running child.
--
-- The handler ('handleClient') is responsible for applying the bounded
-- per-connection read timeout to its socket read (see 'receiveAllWithin'),
-- sourced from 'LiveConfig' ('liveConnectionReadTimeoutSeconds'). A peer that
-- opens a socket and then stalls mid-request reads a timeout sentinel, is
-- rejected by the request parser, and dropped — rather than holding its
-- handler thread (or the accept loop) open indefinitely. A timed-out read is
-- an ordinary, benign connection drop confined to that connection's socket;
-- it never propagates into the accept loop and is never a 'Fatal' worker
-- error (including during 'Draining').
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
            -- Serve this connection in its own structured-concurrency child
            -- (via 'withAsync', not a raw unmanaged thread spawn), so a handler
            -- exception is confined to the child and the accept loop is never
            -- killed by it. The child is
            -- deterministically reaped via `waitCatch` (no leaked threads or
            -- `Async` handles); because each handler bounds its own socket
            -- read with the per-connection timeout, the join is itself bounded
            -- by `liveConnectionReadTimeoutSeconds`, so a stalled peer can
            -- delay the next accept by at most one timeout window rather than
            -- wedging the loop forever. The `Left` arm captures any escaped
            -- exception (handlers already self-`try`, so this is defensive)
            -- without propagating it into the accept loop.
            connOutcome <-
              withAsync (handleClient clientSock) waitCatch
            case connOutcome of
              Right () -> pure ()
              Left exc ->
                logForEnv env Warn "connection_handler_error" [field "detail" (displayException exc)]
            go

-- | Read an inbound request bounded by the configured per-connection read
-- timeout. Returns the bytes read on success; returns 'Nothing' (a benign
-- sentinel the caller treats as a dropped connection) when the read does not
-- complete within 'liveConnectionReadTimeoutSeconds'. This is where the
-- Sprint 2.25 bounded read timeout is actually enforced — at the socket read
-- that a stalled peer would otherwise block forever.
receiveAllWithin :: DaemonEnv -> Socket -> IO (Maybe BS.ByteString)
receiveAllWithin env sock = do
  liveConfig <- readTVarIO (envLiveConfig env)
  let timeoutMicros = readTimeoutMicros (liveConnectionReadTimeoutSeconds liveConfig)
  outcome <- timeout timeoutMicros (receiveAll sock)
  case outcome of
    Just raw -> pure (Just raw)
    Nothing -> do
      logForEnv env Warn "connection_read_timeout" []
      pure Nothing

-- | Convert a fractional-second read-timeout bound to whole microseconds for
-- 'System.Timeout.timeout', clamping to at least 1 microsecond so a
-- misconfigured non-positive value still yields a finite (immediate) timeout
-- rather than 'timeout's block-forever semantics for non-positive arguments.
readTimeoutMicros :: Double -> Int
readTimeoutMicros seconds = max 1 (round (seconds * 1000000))

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
    maybeRaw <- receiveAllWithin env sock
    for_ maybeRaw handleParsedPeerRequest

  handleParsedPeerRequest raw =
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
-- record per-peer inbound delivery health, and refresh max-observed clock
-- skew.
--
-- Sprint 2.25 (doctrine D4): this no longer advances
-- 'stateLatestObservedOrdersVersion' from any in-process promotion event. The
-- highest observed Orders version is learned solely from the sender's
-- advertised @orders_version_utc@ via 'noteSenderOrdersAdvert' on the ingest
-- path; there is no @orders_promoted@ event class to fold over.
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
   in s0
        { stateCommitLog = log'
        , stateLastHeartbeatTimes = heartbeats'
        , statePeerHealth = peerHealth'
        , stateMaxObservedSkewSeconds = skew'
        }

updateHeartbeatFromEvent :: Map String UTCTime -> SignedEvent -> Map String UTCTime
updateHeartbeatFromEvent acc ev =
  case eventTimestampUtc ev of
    Just ts ->
      Map.insertWith max (emitterNodeId ev) ts acc
    Nothing -> acc

-- | Record INBOUND delivery health: stamp the last-accepted-event time for
-- the emitting peer. This must touch only the inbound field — outbound dial
-- health is owned by the peer-dialer loop and reflects a different direction
-- of the link.
updatePeerHealthFromEvent
  :: UTCTime -> Map String PeerHealth -> SignedEvent -> Map String PeerHealth
updatePeerHealthFromEvent now acc ev =
  let baseline = PeerHealth (Just now) False Nothing
      merge _new old =
        old {peerHealthLastInboundEvent = Just now}
   in Map.insertWith merge (emitterNodeId ev) baseline acc

updateSkewFromEvent :: UTCTime -> Maybe Double -> SignedEvent -> Maybe Double
updateSkewFromEvent now acc ev =
  case eventTimestampUtc ev of
    Just ts ->
      let skew = abs (realToFrac (diffUTCTime now ts) :: Double)
       in Just (maybe skew (max skew) acc)
    Nothing -> acc

-- | Periodically push the local commit log to every other peer in the
-- mesh.  Each cycle marks unreachable peers as outbound-disconnected so
-- @/v1/state@ exposes per-peer OUTBOUND dial health (separate from the
-- inbound delivery health stamped by the peer-events listener).
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
      body = encodePeerEventBatch batch
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
                        ++ "Content-Type: application/cbor\r\n"
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

-- | Record OUTBOUND dial failure: mark the outbound link to the peer
-- disconnected and stamp the dial error. Must not touch inbound delivery
-- health — a failed push says nothing about whether the peer is emitting.
markPeerHealthError :: String -> Maybe PeerHealth -> Maybe PeerHealth
markPeerHealthError reason mh =
  case mh of
    Just h -> Just h {peerHealthOutboundConnected = False, peerHealthOutboundLastError = Just reason}
    Nothing -> Just (PeerHealth Nothing False (Just reason))

markPeerOk :: TVar DaemonState -> String -> IO ()
markPeerOk stateVar peerId =
  atomically $ modifyTVar' stateVar $ \s ->
    s
      { statePeerHealth =
          Map.alter
            markPeerHealthOk
            peerId
            (statePeerHealth s)
      }

-- | Record OUTBOUND dial success: mark the outbound link to the peer
-- connected and clear the dial error. Sprint 2.25 stops this writing the
-- inbound-event timestamp; reaching a peer's socket on a push is not evidence
-- the peer accepted an event from us, so it must not advance inbound freshness
-- (the prior conflation masked one-directional partitions).
markPeerHealthOk :: Maybe PeerHealth -> Maybe PeerHealth
markPeerHealthOk mh =
  case mh of
    Just h ->
      Just
        h
          { peerHealthOutboundConnected = True
          , peerHealthOutboundLastError = Nothing
          }
    Nothing -> Just (PeerHealth Nothing True Nothing)

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
      , "peer_inbound_health" .= renderPeerInboundHealth now state
      , "peer_outbound_health" .= renderPeerOutboundHealth state
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

-- | INBOUND delivery health per peer: the age of the last signed event this
-- daemon accepted from each peer. A stale (or absent) age while outbound
-- health is healthy is the observable signature of a one-directional
-- partition where we can reach the peer but it has stopped emitting to us.
renderPeerInboundHealth :: UTCTime -> DaemonState -> Value
renderPeerInboundHealth now state =
  Object $
    KeyMap.fromList
      [ ( Key.fromString peer
        , object
            [ "last_inbound_event_age_seconds"
                .= fmap (\t -> realToFrac (diffUTCTime now t) :: Double) (peerHealthLastInboundEvent health)
            ]
        )
      | (peer, health) <- Map.toList (statePeerHealth state)
      ]

-- | OUTBOUND dial health per peer: whether this daemon's last push to each
-- peer connected, plus the last dial error. Reflects our delivery attempts
-- only; it never advances when an inbound event arrives.
renderPeerOutboundHealth :: DaemonState -> Value
renderPeerOutboundHealth state =
  Object $
    KeyMap.fromList
      [ ( Key.fromString peer
        , object
            [ "connected" .= peerHealthOutboundConnected health
            , "last_error" .= peerHealthOutboundLastError health
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
  signEvent nodeId evtType (formatUtcIso now) (cborPayloadFromJsonValue payload) key

formatUtcIso :: UTCTime -> String
formatUtcIso = formatShow iso8601Format

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
