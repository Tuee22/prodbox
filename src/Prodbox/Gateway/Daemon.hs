{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Daemon
  ( runGatewayDaemon
  , daemonBootFieldsChanged

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

    -- * Sprint 4.47: bounded target-secret Vault route
  , decodeTargetSecretCasRequest
  , decodeTargetSecretReadRequest
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently, race, replicateConcurrently, withAsync)
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , TChan
  , TMVar
  , TQueue
  , TVar
  , atomically
  , modifyTVar'
  , newTBQueueIO
  , newTChanIO
  , newTMVarIO
  , newTQueueIO
  , newTVarIO
  , orElse
  , putTMVar
  , readTBQueue
  , readTQueue
  , readTVar
  , readTVarIO
  , retry
  , takeTMVar
  , tryReadTQueue
  , writeTBQueue
  , writeTChan
  , writeTQueue
  , writeTVar
  )
import Control.Exception
  ( IOException
  , SomeAsyncException
  , SomeException
  , bracketOnError
  , bracket_
  , displayException
  , finally
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forever, replicateM_, unless, void, when)
import Crypto.Hash.SHA256 qualified as SHA256
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
import Data.ByteString.Builder qualified as ByteStringBuilder
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isSpace, toLower)
import Data.Foldable (for_)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, sortOn, stripPrefix)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Time.Format.ISO8601 (formatShow, iso8601Format)
import Data.Word (Word64)
import GHC.Conc (threadWaitRead)
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (AI_PASSIVE)
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
  , getAddrInfo
  , listen
  , setSocketOption
  , socket
  , withFdSocket
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config qualified as Capacity
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
  , ProdboxParameters (..)
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
import Prodbox.Gateway.Bounds
  ( GatewayBounds
  , defaultRawGatewayBounds
  , gatewayChildDeadlineMicros
  , gatewayChildPeakBytes
  , gatewayMaxEncodedAssertionBytes
  , gatewayMaxFrameBytes
  , gatewayMaxInFlightFrames
  , gatewayMaxInFlightFramesPerPeer
  , gatewayMaxNodeIdBytes
  , gatewayReplayPerEmitter
  , validateGatewayBounds
  )
import Prodbox.Gateway.ChildSchedule
  ( CapacityOneChildScheduler
  , RawChildRequest (..)
  , completeChild
  , newCapacityOneChildSchedulerFromBounds
  , scheduleChild
  , scheduledChildTimeoutMicros
  )
import Prodbox.Gateway.Continuity qualified as Continuity
import Prodbox.Gateway.ContinuityStore
  ( ContinuityStoreMaterial (..)
  , modelBContinuityAuthority
  )
import Prodbox.Gateway.DnsAuthority qualified as DnsAuthority
import Prodbox.Gateway.Logging
  ( Severity (..)
  , field
  , logStructuredAt
  , severityFromLogLevel
  )
import Prodbox.Gateway.ObjectStore
  ( AuthorityClockRequest (..)
  , AuthorityClockResponse (..)
  , AuthorityObjectCasRequest (..)
  , AuthorityObjectCasResponse (..)
  , AuthorityObjectLeaseGuard (..)
  , AuthorityObjectObservation (..)
  , AuthorityObjectPayloadError (..)
  , AuthorityObjectRequest (..)
  , PulumiObjectGetResponse (..)
  , PulumiObjectPutRequest (..)
  , PulumiObjectRequest (..)
  , authorityObjectRequestMaxBytes
  , pulumiObjectRequestMaxBytes
  , validateAuthorityObjectLogicalName
  , validateAuthorityObjectPayloadSize
  , validatePulumiObjectStackName
  )
import Prodbox.Gateway.Peer
  ( EventKey
  , PeerError (..)
  , PeerTransportResponse
  , SignedAssertion
  , boundedSignedAssertionsToList
  , decodeSignedAssertion
  , handlePeerRequest
  , mkEventKey
  , parsePeerHttpRequest
  , parsePeerHttpResponse
  , peerErrorResponse
  , peerRequestOrdersVersion
  , peerRequestReplayAssertions
  , peerRequestSemanticSnapshot
  , peerRequestSnapshotEvidence
  , peerResponseAccepted
  , peerResponseCursorVector
  , renderPeerCursorRequest
  , renderPeerDeltaRequest
  , renderPeerHttpResponse
  , renderPeerRepairRequest
  , selectSignedDelta
  , selectSignedRepairFromCheckpoint
  , signAndConvertAssertion
  , signedAssertionBytes
  , signedAssertionEmitter
  , signedAssertionEpoch
  , signedAssertionKind
  , signedAssertionResultDigest
  , signedAssertionSequence
  , signedSemanticSnapshotEmitter
  , validatePeerRequestHeartbeatSkew
  , verifySignedAssertion
  )
import Prodbox.Gateway.Readiness
  ( DrainPhase (..)
  , ObjectStoreProof (..)
  , ReadinessInputs (..)
  , ReadinessState (..)
  , WorkersStatus (..)
  , computeReadiness
  )
import Prodbox.Gateway.Routes
  ( GatewayRoute (..)
  , federationChildBootstrapSuffix
  , federationChildPathPrefix
  , operatorSecretPathPrefix
  , routeForPath
  , routePattern
  )
import Prodbox.Gateway.Settings qualified as GatewaySettings
import Prodbox.Gateway.State qualified as BoundedState
import Prodbox.Gateway.TargetSecret qualified as TargetSecret
import Prodbox.Gateway.Types
  ( DaemonConfig (..)
  , Disposition (..)
  , DnsWriteGate (..)
  , GatewayAwsCreds (..)
  , GatewayMinioCreds (..)
  , GatewayRule (..)
  , GatewayVaultAuth (..)
  , Orders (..)
  , PeerEndpoint (..)
  , PeerHealth (..)
  , defaultDrainDeadlineSeconds
  , peerDialSocketHost
  , validateDaemonTimingAgainstOrders
  )
import Prodbox.Http.Client
  ( HttpError (..)
  , defaultHttpConfig
  , httpGetText
  , renderHttpError
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  , decodeLeaseProjection
  , defaultSesLeasePolicy
  , fencingTokenValue
  , leaseGrantFencingToken
  , leaseGrantKey
  , leaseGrantOwnerNonce
  , leaseGrantSafeUseDeadline
  , leaseLogicalName
  , leaseProjectionActiveGrant
  , ownerNonceText
  )
import Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError (..)
  , LogicalConditionalPutResult (..)
  , LogicalObject (LogicalLongLivedState, LogicalPulumiStack)
  , VersionedLogicalObject (..)
  , getLogical
  , getLogicalVersioned
  , objectKeyForOpaqueId
  , opaqueObjectId
  , putLogical
  , putLogicalIfAbsent
  , putLogicalIfVersion
  , renderEncryptedObjectError
  )
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , ObjectVersion (..)
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
  , KvV2Cas (..)
  , KvV2VersionedSecret (..)
  , SealStatus (..)
  , VaultAddress (..)
  , VaultKubernetesLoginResult (..)
  , VaultToken (..)
  , bootstrapAction
  , defaultInitRequest
  , initResponseToUnlockBundle
  , vaultInit
  , vaultKubernetesLogin
  , vaultKubernetesLoginWithLease
  , vaultKvCasWriteV2
  , vaultKvReadV2
  , vaultKvReadVersionedV2
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
import Prodbox.Vault.Session
  ( GatewaySessionKey (..)
  , LoginLease (..)
  , VaultSession
  , VaultSessionError (..)
  , httpErrorToSessionError
  , newVaultSession
  , realSessionClock
  , renderVaultSessionError
  , resolveSharedSession
  , sessionAddress
  , sessionToken
  , withSessionToken
  )
import Prodbox.Vault.TransitCipher (vaultTransitDekCipher)
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , decryptUnlockBundle
  , encryptUnlockBundle
  , renderUnlockBundleError
  )
import System.Directory (doesFileExist, findExecutable)
import System.Environment (lookupEnv)
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
  { stateBoundedGateway :: BoundedState.GatewayState
  , stateSignedReplay :: Map String [SignedAssertion]
  , stateSignedCheckpointHeartbeat :: Map String SignedAssertion
  , stateSignedCheckpointOwnership :: Map String SignedAssertion
  , statePeerCursors :: Map String BoundedState.CursorVector
  , stateLastHeartbeatTimes :: Map String UTCTime
  , stateGatewayOwner :: Maybe String
  , statePreviousOwner :: Maybe String
  , stateLastPublicIp :: Maybe String
  , stateLastDnsWriteIp :: Maybe String
  , stateLastDnsWriteTime :: Maybe UTCTime
  , stateDnsClaimAuthority :: Maybe DnsAuthority.CurrentDnsClaim
  , stateMeshPeers :: [String]
  , statePeerHealth :: Map String PeerHealth
  , stateMaxObservedSkewSeconds :: Maybe Double
  , stateOrdersVersionUtc :: Int
  , stateLatestObservedOrdersVersion :: Int
  }

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
  , envValidatedOrders :: BoundedState.ValidatedOrders
  , envGatewayBounds :: GatewayBounds
  , envChildScheduler :: TVar CapacityOneChildScheduler
  , envChildPermit :: TMVar ()
  , envFramePermits :: TBQueue ()
  , envContinuity :: TVar (Maybe ContinuityRuntime)
  , envState :: TVar DaemonState
  , -- Sprint 2.34: readiness is no longer one cached three-state TVar written
    -- unconditionally at serve-start. It is a pure projection
    -- ('computeReadiness') over three orthogonal monotone boundary facts, so a
    -- flapping backend signal can never be folded into @/readyz@.
    envDrainPhase :: TVar DrainPhase
  , envObjectStoreProof :: TVar ObjectStoreProof
  , envWorkersStatus :: TVar WorkersStatus
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

data ContinuityRuntime = ContinuityRuntime
  { continuityRuntimeAuthority :: Continuity.GatewayContinuityAuthority IO
  , continuityRuntimeCurrent :: TVar Continuity.CurrentContinuity
  }

data ContinuityDiagnostic
  = ContinuityDiagnosticUnavailable
  | ContinuityDiagnosticReady Continuity.ContinuityAnchor

noopDaemonHooks :: DaemonHooks
noopDaemonHooks =
  DaemonHooks
    { envAfterPeerEventCommit = \_ -> pure ()
    , envBeforeOrdersAdoption = \_ -> pure ()
    , envOnPeerConnectionEstablished = \_ -> pure ()
    }

initialState :: Int -> BoundedState.GatewayState -> DaemonState
initialState ordersVersion boundedGateway =
  DaemonState
    { stateBoundedGateway = boundedGateway
    , stateSignedReplay = Map.empty
    , stateSignedCheckpointHeartbeat = Map.empty
    , stateSignedCheckpointOwnership = Map.empty
    , statePeerCursors = Map.empty
    , stateLastHeartbeatTimes = Map.empty
    , stateGatewayOwner = Nothing
    , statePreviousOwner = Nothing
    , stateLastPublicIp = Nothing
    , stateLastDnsWriteIp = Nothing
    , stateLastDnsWriteTime = Nothing
    , stateDnsClaimAuthority = Nothing
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
  startupModelResult <- loadGatewayStartupModel maybeConfigPath config
  case startupModelResult of
    Left err -> do
      logAtLevel logLevel Error "gateway_bounded_startup_failed" [field "detail" err]
      pure (ExitFailure 1)
    Right (gatewayBounds, childScheduler, orders, validatedOrders) ->
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
                  case initializeBoundedGateway gatewayBounds validatedOrders of
                    Left err -> do
                      logAtLevel logLevel Error "gateway_state_initialization_failed" [field "detail" err]
                      pure (ExitFailure 1)
                    Right boundedGateway -> do
                      let localNodeId = daemonNodeId config
                          meshPeers =
                            [ peerNodeId peer
                            | peer <- ordersNodes orders
                            , peerNodeId peer /= localNodeId
                            ]
                          initialDaemonState =
                            (initialState (ordersVersionUtc orders) boundedGateway)
                              { stateLastHeartbeatTimes = Map.singleton localNodeId now
                              , stateMeshPeers = meshPeers
                              , statePeerHealth =
                                  Map.fromList
                                    [(p, PeerHealth Nothing False Nothing) | p <- meshPeers]
                              }
                      stateVar <- newTVarIO initialDaemonState
                      drainPhaseVar <- newTVarIO PhaseServing
                      -- Sprint 2.34: 'PRODBOX_TEST_OBJECT_STORE_PROOF_LATCH' is a
                      -- sanctioned, in-memory, read-once, test-only seed for the
                      -- object-store proof latch. It does NOT participate in
                      -- config resolution (config still comes from the mounted
                      -- @--config@ Dhall) and is never set by any production
                      -- path, so production defaults to 'ObjectStoreUnproven'
                      -- and the readiness gate stays fail-closed. It lets the
                      -- 'prodbox-daemon-lifecycle' suite — which runs with no
                      -- Vault and no MinIO — exercise the real projection and
                      -- @/readyz@ handler without a live round trip.
                      objectStoreProofSeed <-
                        maybe
                          ObjectStoreUnproven
                          (\value -> if value == "1" then ObjectStoreProven else ObjectStoreUnproven)
                          <$> lookupEnv "PRODBOX_TEST_OBJECT_STORE_PROOF_LATCH"
                      objectStoreProofVar <- newTVarIO objectStoreProofSeed
                      workersStatusVar <- newTVarIO WorkersPending
                      liveConfigVar <- newTVarIO (liveConfigFromDaemonConfig logLevel config)
                      reloadBroadcast <- newTChanIO
                      drainSignals <- newTQueueIO
                      reloadSignals <- newTQueueIO
                      childSchedulerVar <- newTVarIO childScheduler
                      childPermit <- newTMVarIO ()
                      framePermits <-
                        newTBQueueIO
                          (fromIntegral (gatewayMaxInFlightFrames gatewayBounds))
                      atomically $
                        replicateM_
                          (gatewayMaxInFlightFrames gatewayBounds)
                          (writeTBQueue framePermits ())
                      continuityVar <- newTVarIO Nothing
                      signalCount <- newTVarIO (0 :: Int)
                      let env =
                            DaemonEnv
                              { envConfigPath = maybeConfigPath
                              , envBootConfig = config
                              , envOrders = orders
                              , envValidatedOrders = validatedOrders
                              , envGatewayBounds = gatewayBounds
                              , envChildScheduler = childSchedulerVar
                              , envChildPermit = childPermit
                              , envFramePermits = framePermits
                              , envContinuity = continuityVar
                              , envState = stateVar
                              , envDrainPhase = drainPhaseVar
                              , envObjectStoreProof = objectStoreProofVar
                              , envWorkersStatus = workersStatusVar
                              , envLiveConfig = liveConfigVar
                              , envLiveConfigReloads = reloadBroadcast
                              , envMetrics = MetricsRegistry "gateway"
                              , envDrainSignals = drainSignals
                              , envReloadSignals = reloadSignals
                              , envHooks = noopDaemonHooks
                              }
                      installDaemonSignalHandlers env signalCount

                      continuityResult <- bootstrapContinuity env
                      case continuityResult of
                        Left err ->
                          logForEnv env Warn "gateway_continuity_unavailable" [field "detail" err]
                        Right () ->
                          logForEnv env Info "gateway_continuity_ready" []

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

loadGatewayStartupModel
  :: Maybe FilePath
  -> DaemonConfig
  -> IO
       ( Either
           String
           ( GatewayBounds
           , CapacityOneChildScheduler
           , Orders
           , BoundedState.ValidatedOrders
           )
       )
loadGatewayStartupModel maybeConfigPath config = do
  let configMapDir = maybe "/etc/gateway/config" takeDirectory maybeConfigPath
  containerDefaultPath <- resolveTier0ConfigPath "/"
  contextResult <- loadDaemonBinaryContext configMapDir containerDefaultPath
  case contextResult of
    Left err -> pure (Left ("gateway runtime-memory context unavailable: " ++ err))
    Right (_, projectConfig) ->
      case Capacity.runtimeMemoryPlanForProfile
        (capacity (parameters projectConfig))
        "gateway" of
        Left err -> pure (Left ("gateway runtime-memory plan invalid: " ++ err))
        Right memoryPlan ->
          case validateGatewayBounds memoryPlan defaultRawGatewayBounds of
            Left err -> pure (Left ("gateway finite bounds invalid: " ++ show err))
            Right bounds -> do
              case newCapacityOneChildSchedulerFromBounds bounds of
                Left err -> pure (Left ("gateway child schedule invalid: " ++ show err))
                Right childScheduler -> do
                  ordersResult <-
                    GatewaySettings.loadOrdersBounded
                      bounds
                      (daemonEventKeys config)
                      (daemonOrdersFile config)
                  pure $ case ordersResult of
                    Left err -> Left err
                    Right (orders, validatedOrders) ->
                      Right (bounds, childScheduler, orders, validatedOrders)

initializeBoundedGateway
  :: GatewayBounds
  -> BoundedState.ValidatedOrders
  -> Either String BoundedState.GatewayState
initializeBoundedGateway bounds orders = do
  seeds <-
    traverse
      ( \nodeId -> do
          eventHash <-
            case BoundedState.mkEventHash (gatewayGenesisDigest orders nodeId) of
              Left err -> Left (show err)
              Right value -> Right value
          Right (nodeId, BoundedState.initialEmitterCursor 1 eventHash)
      )
      (BoundedState.validatedOrdersMemberIds orders)
  case BoundedState.initializeGatewayState bounds orders (Map.fromList seeds) of
    Left err -> Left (show err)
    Right state -> Right state

gatewayGenesisDigest
  :: BoundedState.ValidatedOrders
  -> BoundedState.NodeId
  -> ByteString
gatewayGenesisDigest orders nodeId =
  SHA256.hash
    ( BS.concat
        [ "prodbox.gateway.genesis.v1\NUL"
        , BoundedState.ordersAnchorHashBytes (BoundedState.validatedOrdersAnchor orders)
        , TextEncoding.encodeUtf8 (BoundedState.nodeIdText nodeId)
        ]
    )

continuityScopeFor
  :: DaemonEnv
  -> BoundedState.NodeId
  -> Either String (Continuity.ContinuityBounds, Continuity.ContinuityScope)
continuityScopeFor env nodeId = do
  let bounds = envGatewayBounds env
      anchor = BoundedState.validatedOrdersAnchor (envValidatedOrders env)
      anchorBytes =
        BL.toStrict
          ( ByteStringBuilder.toLazyByteString
              ( ByteStringBuilder.word64BE
                  ( BoundedState.ordersVersionValue
                      (BoundedState.ordersAnchorVersion anchor)
                  )
                  <> ByteStringBuilder.byteString
                    (BoundedState.ordersAnchorHashBytes anchor)
              )
          )
  continuityBounds <-
    case Continuity.mkContinuityBounds
      (gatewayMaxNodeIdBytes bounds)
      (fromIntegral (BS.length anchorBytes))
      (gatewayMaxEncodedAssertionBytes bounds) of
      Left err -> Left (show err)
      Right value -> Right value
  scope <-
    case Continuity.mkContinuityScope
      continuityBounds
      (BoundedState.nodeIdText nodeId)
      anchorBytes of
      Left err -> Left (show err)
      Right value -> Right value
  Right (continuityBounds, scope)

bootstrapContinuity :: DaemonEnv -> IO (Either String ())
bootstrapContinuity env = do
  let config = envBootConfig env
  case (daemonVaultAuth config, daemonMinioCreds config) of
    (Nothing, _) -> pure (Left "Vault authority is not configured")
    (_, Nothing) -> pure (Left "MinIO authority is not configured")
    (Just _, Just _) ->
      case localBoundedNode env of
        Left err -> pure (Left err)
        Right localNode ->
          case continuityScopeFor env localNode of
            Left err -> pure (Left err)
            Right (continuityBounds, scope) -> do
              materialResult <- resolveDaemonPulumiObjectMaterial env
              case materialResult of
                Left err -> pure (Left err)
                Right material -> do
                  genesis <-
                    pure
                      ( Continuity.mkContinuityDigest
                          (gatewayGenesisDigest (envValidatedOrders env) localNode)
                      )
                  case genesis of
                    Left err -> pure (Left (show err))
                    Right genesisDigest -> do
                      let authority =
                            modelBContinuityAuthority
                              ContinuityStoreMaterial
                                { continuityStoreObjectStore = daemonPulumiObjectStore material
                                , continuityStoreCipher = daemonPulumiCipher material
                                , continuityStoreHmacKey = daemonPulumiHmacKey material
                                , continuityStoreClusterId = daemonPulumiClusterId material
                                }
                              scope
                          admission =
                            Continuity.mkFirstContinuityAdmission scope genesisDigest
                      admissionStateResult <- observeContinuityAdmission config localNode
                      case admissionStateResult of
                        Left err -> pure (Left err)
                        Right admissionState -> do
                          recoveryResult <-
                            withGatewayChild env "gateway-continuity" $ do
                              result <-
                                case admissionState of
                                  ContinuityFirstAdmission ->
                                    Continuity.initializeContinuityAtFirstAdmission
                                      authority
                                      admission
                                  ContinuityPreviouslyAdmitted ->
                                    Continuity.recoverContinuityAtStartup authority
                              pure (either (Left . show) Right result)
                          case recoveryResult of
                            Left err -> pure (Left err)
                            Right recovery -> do
                              markerResult <-
                                case admissionState of
                                  ContinuityPreviouslyAdmitted -> pure (Right ())
                                  ContinuityFirstAdmission ->
                                    persistContinuityAdmission config localNode
                              case markerResult of
                                Left err -> pure (Left err)
                                Right () ->
                                  installContinuityRecovery
                                    env
                                    localNode
                                    continuityBounds
                                    authority
                                    recovery

data ContinuityAdmission
  = ContinuityFirstAdmission
  | ContinuityPreviouslyAdmitted
  deriving (Eq, Show)

continuityAdmissionPath :: BoundedState.NodeId -> Text.Text
continuityAdmissionPath nodeId =
  "prodbox/gateway/continuity-admission/"
    <> BoundedState.nodeIdText nodeId

-- | Vault carries the durable one-time admission witness independently from
-- the Model-B continuity object.  Once this marker exists, a missing object
-- is recovery failure—not permission to recreate a genesis anchor.
observeContinuityAdmission
  :: DaemonConfig
  -> BoundedState.NodeId
  -> IO (Either String ContinuityAdmission)
observeContinuityAdmission config nodeId = do
  tokenResult <- resolveGatewayVaultToken config
  case tokenResult of
    Left err -> pure (Left ("continuity admission marker is unobservable: " ++ err))
    Right (address, token) -> do
      observed <-
        vaultKvReadV2
          address
          token
          "secret"
          (continuityAdmissionPath nodeId)
      pure $ case observed of
        Left (HttpStatus 404 _) -> Right ContinuityFirstAdmission
        Left err ->
          Left
            ( "continuity admission marker is unobservable: "
                ++ renderHttpError err
            )
        Right fields
          | Map.lookup "admitted" fields == Just "true"
              && Map.lookup "node_id" fields
                == Just (BoundedState.nodeIdText nodeId) ->
              Right ContinuityPreviouslyAdmitted
          | otherwise -> Left "continuity admission marker is malformed"

persistContinuityAdmission
  :: DaemonConfig
  -> BoundedState.NodeId
  -> IO (Either String ())
persistContinuityAdmission config nodeId = do
  tokenResult <- resolveGatewayVaultToken config
  case tokenResult of
    Left err -> pure (Left ("continuity admission marker cannot be persisted: " ++ err))
    Right (address, token) -> do
      written <-
        vaultKvWriteV2
          address
          token
          "secret"
          (continuityAdmissionPath nodeId)
          ( Map.fromList
              [ ("admitted", "true")
              , ("node_id", BoundedState.nodeIdText nodeId)
              ]
          )
      pure $
        case written of
          Left err ->
            Left
              ( "continuity admission marker cannot be persisted: "
                  ++ renderHttpError err
              )
          Right () -> Right ()

installContinuityRecovery
  :: DaemonEnv
  -> BoundedState.NodeId
  -> Continuity.ContinuityBounds
  -> Continuity.GatewayContinuityAuthority IO
  -> Continuity.StartupRecovery
  -> IO (Either String ())
installContinuityRecovery env localNode continuityBounds authority recovery =
  case recovery of
    Continuity.StartupCurrent current -> do
      restored <- restoreCommittedAnchor current
      case restored of
        Left err -> pure (Left err)
        Right () -> installRuntime current
    Continuity.StartupRepublish witness -> do
      recovered <- recoverStagedAssertion witness
      case recovered of
        Left err -> pure (Left err)
        Right current -> installRuntime current
 where
  installRuntime current = do
    currentVar <- newTVarIO current
    -- Sprint 2.34: latch the object-store proof in the SAME STM transaction
    -- that publishes the continuity runtime. Reaching here means a validated
    -- 'StartupRecovery' (a real read-back or CAS write — never a bare
    -- absent-object GET) has been decoded, restored, and is being installed as
    -- the live authority, so kubelet readiness can never be reported before a
    -- proven durable-authority round trip. Written 'ObjectStoreProven' only,
    -- never cleared: a later transient object-store blip that resets
    -- 'envContinuity' does not un-ready the Pod (monotone latch).
    atomically $ do
      writeTVar (envContinuity env) (Just (ContinuityRuntime authority currentVar))
      writeTVar (envObjectStoreProof env) ObjectStoreProven
    pure (Right ())

  restoreCommittedAnchor current = do
    let anchor = Continuity.currentContinuityAnchor current
    case BoundedState.mkEventHash
      ( Continuity.continuityDigestBytes
          (Continuity.continuityAnchorPreviousDigest anchor)
      ) of
      Left err -> pure (Left (show err))
      Right eventHash ->
        atomically $ do
          daemonState <- readTVar (envState env)
          let cursor =
                BoundedState.restoredEmitterCursor
                  (Continuity.continuityAnchorEpoch anchor)
                  (Continuity.continuityAnchorSequence anchor)
                  eventHash
          case BoundedState.restoreEmitterFromContinuity
            localNode
            cursor
            (stateBoundedGateway daemonState) of
            Left err -> pure (Left (show err))
            Right restored -> do
              writeTVar
                (envState env)
                daemonState {stateBoundedGateway = restored}
              pure (Right ())

  recoverStagedAssertion witness =
    case validateRecoveredWitness witness of
      Left err -> pure (Left err)
      Right (signed, semantic, previousCursor) -> do
        published <- atomically $ do
          original <- readTVar (envState env)
          case BoundedState.restoreEmitterFromContinuity
            localNode
            previousCursor
            (stateBoundedGateway original) of
            Left err -> pure (Left (show err))
            Right restored -> do
              writeTVar
                (envState env)
                original {stateBoundedGateway = restored}
              result <- publishSignedAssertion env semantic signed
              case result of
                Left err -> do
                  writeTVar (envState env) original
                  pure (Left err)
                Right () -> pure (Right ())
        case published of
          Left err -> pure (Left err)
          Right () ->
            withGatewayChild env "gateway-continuity-recovery-commit" $ do
              committed <-
                Continuity.commitPublishedAssertion
                  authority
                  (Continuity.acknowledgePublication witness)
              pure (either (Left . show) Right committed)

  validateRecoveredWitness witness = do
    signed <-
      either
        (Left . show)
        Right
        ( decodeSignedAssertion
            (envGatewayBounds env)
            (Continuity.publicationSignedBytes witness)
        )
    semantic <-
      either
        (Left . show)
        Right
        ( verifySignedAssertion
            (envGatewayBounds env)
            (envValidatedOrders env)
            (gatewayEventKeyLookup env)
            signed
        )
    unless
      (BoundedState.assertionEmitter semantic == localNode)
      (Left "retained staged assertion belongs to a different emitter")
    let kind = signedAssertionKind signed
        transitionMatches =
          case (Continuity.publicationTransition witness, kind) of
            (Continuity.EpochInvalidation, BoundedState.EpochRotationAssertion) -> True
            (Continuity.SemanticAdvance, BoundedState.EpochRotationAssertion) -> False
            (Continuity.SemanticAdvance, _) -> True
            (Continuity.EpochInvalidation, _) -> False
        previousDigest =
          Continuity.continuityDigestBytes
            (Continuity.publicationPreviousDigest witness)
        nextAnchor = Continuity.publicationNextAnchor witness
    unless transitionMatches (Left "retained staged transition does not match signed assertion")
    unless
      ( previousDigest
          == BoundedState.eventHashBytes
            (BoundedState.assertionPreviousHash semantic)
      )
      (Left "retained staged previous digest does not match signed assertion")
    unless
      (Continuity.continuityAnchorEpoch nextAnchor == signedAssertionEpoch signed)
      (Left "retained staged epoch does not match signed assertion")
    unless
      (Continuity.continuityAnchorSequence nextAnchor == signedAssertionSequence signed)
      (Left "retained staged sequence does not match signed assertion")
    unless
      ( Continuity.continuityDigestBytes
          (Continuity.continuityAnchorPreviousDigest nextAnchor)
          == signedAssertionResultDigest signed
      )
      (Left "retained staged result digest does not match signed assertion")
    previousHash <- either (Left . show) Right (BoundedState.mkEventHash previousDigest)
    previousCursor <-
      case kind of
        BoundedState.EpochRotationAssertion
          | signedAssertionEpoch signed == 0 ->
              Left "retained epoch invalidation has no predecessor epoch"
          | otherwise ->
              Right
                ( BoundedState.restoredEmitterCursor
                    (signedAssertionEpoch signed - 1)
                    maxBound
                    previousHash
                )
        _
          | signedAssertionSequence signed == 0 ->
              Left "retained semantic assertion has no predecessor sequence"
          | otherwise ->
              Right
                ( BoundedState.restoredEmitterCursor
                    (signedAssertionEpoch signed)
                    (signedAssertionSequence signed - 1)
                    previousHash
                )
    -- Re-enter the continuity bound constructor during recovery so retained
    -- bytes cannot bypass a newly tightened runtime-memory plan.
    case kind of
      BoundedState.EpochRotationAssertion -> do
        _ <-
          either
            (Left . show)
            Right
            ( Continuity.mkSignedEpochInvalidation
                continuityBounds
                (signedAssertionBytes signed)
            )
        Right ()
      _ -> do
        _ <-
          either
            (Left . show)
            Right
            ( Continuity.mkSignedSemanticAssertion
                continuityBounds
                (signedAssertionBytes signed)
            )
        Right ()
    Right (signed, semantic, previousCursor)

continuityLoop :: DaemonEnv -> IO ()
continuityLoop env = forever $ do
  runtime <- readTVarIO (envContinuity env)
  case runtime of
    Nothing -> do
      result <- bootstrapContinuity env
      case result of
        Left err ->
          logForEnv env Warn "gateway_continuity_retry" [field "detail" err]
        Right () ->
          logForEnv env Info "gateway_continuity_recovered" []
    Just active -> do
      observed <-
        withGatewayChild env "gateway-continuity-observe" $ do
          result <-
            Continuity.recoverContinuityAtStartup
              (continuityRuntimeAuthority active)
          pure (either (Left . show) Right result)
      case observed of
        Left err -> do
          atomically (writeTVar (envContinuity env) Nothing)
          logForEnv env Warn "gateway_continuity_lost" [field "detail" err]
        Right (Continuity.StartupCurrent current) ->
          atomically (writeTVar (continuityRuntimeCurrent active) current)
        Right recovery@(Continuity.StartupRepublish _) ->
          case localBoundedNode env of
            Left err -> do
              atomically (writeTVar (envContinuity env) Nothing)
              logForEnv env Warn "gateway_continuity_recovery_failed" [field "detail" err]
            Right localNode ->
              case continuityScopeFor env localNode of
                Left err -> do
                  atomically (writeTVar (envContinuity env) Nothing)
                  logForEnv env Warn "gateway_continuity_recovery_failed" [field "detail" err]
                Right (continuityBounds, _) -> do
                  installed <-
                    installContinuityRecovery
                      env
                      localNode
                      continuityBounds
                      (continuityRuntimeAuthority active)
                      recovery
                  case installed of
                    Left err -> do
                      atomically (writeTVar (envContinuity env) Nothing)
                      logForEnv env Warn "gateway_continuity_recovery_failed" [field "detail" err]
                    Right () ->
                      logForEnv env Info "gateway_continuity_republished" []
  liveConfig <- readTVarIO (envLiveConfig env)
  threadDelay (round (liveReconnectInterval liveConfig * 1000000))

localBoundedNode :: DaemonEnv -> Either String BoundedState.NodeId
localBoundedNode env =
  case filter
    ( (== Text.pack (daemonNodeId (envBootConfig env)))
        . BoundedState.nodeIdText
    )
    (BoundedState.validatedOrdersMemberIds (envValidatedOrders env)) of
    [nodeId] -> Right nodeId
    _ -> Left "local node is absent from bounded Orders membership"

gatewayEventKeyLookup :: DaemonEnv -> BoundedState.NodeId -> Maybe EventKey
gatewayEventKeyLookup env nodeId = do
  raw <-
    Map.lookup
      (Text.unpack (BoundedState.nodeIdText nodeId))
      (Map.fromList (daemonEventKeys (envBootConfig env)))
  either
    (const Nothing)
    Just
    (mkEventKey (envGatewayBounds env) (TextEncoding.encodeUtf8 (Text.pack raw)))

emitLocalAssertion
  :: DaemonEnv
  -> BoundedState.AssertionKind
  -> IO (Either String SignedAssertion)
emitLocalAssertion env kind = do
  continuityRuntime <- readTVarIO (envContinuity env)
  case continuityRuntime of
    Nothing -> pure (Left "retained continuity authority is unavailable")
    Just runtime ->
      case localBoundedNode env of
        Left err -> pure (Left err)
        Right localNode ->
          case gatewayEventKeyLookup env localNode of
            Nothing -> pure (Left "local event-key authority is unavailable")
            Just eventKey -> do
              state <- readTVarIO (envState env)
              let cursorVector =
                    BoundedState.gatewayStateCursorVector
                      (stateBoundedGateway state)
              case BoundedState.cursorVectorLookup localNode cursorVector of
                Nothing -> pure (Left "local continuity cursor is unavailable")
                Just previousCursor ->
                  case signAndConvertAssertion
                    (envGatewayBounds env)
                    (envValidatedOrders env)
                    localNode
                    previousCursor
                    kind
                    eventKey of
                    Left err -> pure (Left (show err))
                    Right (signed, semantic) -> do
                      current <- readTVarIO (continuityRuntimeCurrent runtime)
                      staged <-
                        stageSignedForContinuity
                          env
                          runtime
                          current
                          kind
                          signed
                      case staged of
                        Left err -> pure (Left err)
                        Right acknowledgement -> do
                          witnessResult <-
                            withGatewayChild env "gateway-continuity-reobserve" $ do
                              result <-
                                Continuity.reobserveDurableStage
                                  (continuityRuntimeAuthority runtime)
                                  acknowledgement
                              pure (either (Left . show) Right result)
                          case witnessResult of
                            Left err -> pure (Left err)
                            Right witness
                              | Continuity.publicationSignedBytes witness
                                  /= signedAssertionBytes signed ->
                                  pure (Left "continuity publication witness bytes changed")
                              | otherwise -> do
                                  publishResult <-
                                    atomically
                                      (publishSignedAssertion env semantic signed)
                                  case publishResult of
                                    Left err -> pure (Left err)
                                    Right () -> do
                                      committed <-
                                        withGatewayChild env "gateway-continuity-commit" $ do
                                          result <-
                                            Continuity.commitPublishedAssertion
                                              (continuityRuntimeAuthority runtime)
                                              (Continuity.acknowledgePublication witness)
                                          pure (either (Left . show) Right result)
                                      case committed of
                                        Left err -> do
                                          atomically (writeTVar (envContinuity env) Nothing)
                                          pure (Left err)
                                        Right current' -> do
                                          atomically
                                            (writeTVar (continuityRuntimeCurrent runtime) current')
                                          refreshDnsClaimAuthority env kind current'
                                          pure (Right signed)

-- | Semantic emissions rotate only after the fixed sequence has been fully
-- consumed.  The invalidating checkpoint crosses the same retained
-- stage/re-observe/publish/commit boundary before the requested assertion is
-- signed in the fresh epoch.
emitLocalSemanticAssertion
  :: DaemonEnv
  -> BoundedState.AssertionKind
  -> IO (Either String SignedAssertion)
emitLocalSemanticAssertion env kind =
  case kind of
    BoundedState.EpochRotationAssertion -> emitLocalAssertion env kind
    _ ->
      case localBoundedNode env of
        Left err -> pure (Left err)
        Right localNode -> do
          state <- readTVarIO (envState env)
          case BoundedState.cursorVectorLookup
            localNode
            ( BoundedState.gatewayStateCursorVector
                (stateBoundedGateway state)
            ) of
            Nothing -> pure (Left "local continuity cursor is unavailable")
            Just cursor
              | BoundedState.emitterSequenceValue
                  (BoundedState.emitterCursorSequence cursor)
                  == maxBound -> do
                  rotated <-
                    emitLocalAssertion env BoundedState.EpochRotationAssertion
                  case rotated of
                    Left err -> pure (Left err)
                    Right _ -> emitLocalAssertion env kind
              | otherwise -> emitLocalAssertion env kind

refreshDnsClaimAuthority
  :: DaemonEnv
  -> BoundedState.AssertionKind
  -> Continuity.CurrentContinuity
  -> IO ()
refreshDnsClaimAuthority env kind current =
  case kind of
    BoundedState.OwnershipAssertion BoundedState.OwnershipYield ->
      atomically $ modifyTVar' (envState env) $ \state ->
        state {stateDnsClaimAuthority = Nothing}
    _ -> do
      state <- readTVarIO (envState env)
      let localNode = daemonNodeId (envBootConfig env)
          hasCurrentClaim =
            boundedNodeDisposition env state localNode == DispositionOwner
      if not hasCurrentClaim
        then atomically $ modifyTVar' (envState env) $ \currentState ->
          currentState {stateDnsClaimAuthority = Nothing}
        else case daemonAwsCreds (envBootConfig env) of
          Nothing ->
            atomically $ modifyTVar' (envState env) $ \currentState ->
              currentState {stateDnsClaimAuthority = Nothing}
          Just awsCreds ->
            case do
              generation <- credentialGenerationFor awsCreds
              fence <- continuityFenceFromCurrent current
              DnsAuthority.mkCurrentDnsClaim
                (Text.pack localNode)
                generation
                fence of
              Left _ ->
                atomically $ modifyTVar' (envState env) $ \currentState ->
                  currentState {stateDnsClaimAuthority = Nothing}
              Right claim ->
                atomically $ modifyTVar' (envState env) $ \currentState ->
                  currentState {stateDnsClaimAuthority = Just claim}

continuityFenceFromCurrent
  :: Continuity.CurrentContinuity
  -> Either DnsAuthority.DnsAuthorityError DnsAuthority.ContinuityFence
continuityFenceFromCurrent current =
  let anchor = Continuity.currentContinuityAnchor current
   in DnsAuthority.mkContinuityFence
        (fromIntegral (Continuity.continuityAnchorEpoch anchor))
        (fromIntegral (Continuity.continuityAnchorSequence anchor))
        ( hexText
            ( Continuity.continuityDigestBytes
                (Continuity.continuityAnchorPreviousDigest anchor)
            )
        )

stageSignedForContinuity
  :: DaemonEnv
  -> ContinuityRuntime
  -> Continuity.CurrentContinuity
  -> BoundedState.AssertionKind
  -> SignedAssertion
  -> IO (Either String Continuity.DurableStageAcknowledgement)
stageSignedForContinuity env runtime current kind signed =
  case localBoundedNode env >>= fmap fst . continuityScopeFor env of
    Left err -> pure (Left err)
    Right continuityBounds ->
      withGatewayChild env "gateway-continuity-stage" $ do
        result <-
          case kind of
            BoundedState.EpochRotationAssertion ->
              case Continuity.mkSignedEpochInvalidation
                continuityBounds
                (signedAssertionBytes signed) of
                Left err -> pure (Left err)
                Right assertion ->
                  Continuity.stageEpochInvalidation authority current assertion
            _ ->
              case Continuity.mkSignedSemanticAssertion
                continuityBounds
                (signedAssertionBytes signed) of
                Left err -> pure (Left err)
                Right assertion ->
                  Continuity.stageSemanticAssertion authority current assertion
        pure (either (Left . show) Right result)
 where
  authority = continuityRuntimeAuthority runtime

publishSignedAssertion
  :: DaemonEnv
  -> BoundedState.GatewayAssertion
  -> SignedAssertion
  -> STM (Either String ())
publishSignedAssertion env semantic signed = do
  daemonState <- readTVar (envState env)
  case BoundedState.applyGatewayAssertion
    semantic
    (stateBoundedGateway daemonState) of
    BoundedState.AssertionRejected _ err -> pure (Left (show err))
    BoundedState.AssertionDuplicate unchanged -> do
      writeTVar
        (envState env)
        (retainSignedAssertion env signed daemonState {stateBoundedGateway = unchanged})
      pure (Right ())
    BoundedState.AssertionApplied advanced -> do
      let withSemantic =
            retainSignedAssertion
              env
              signed
              daemonState {stateBoundedGateway = advanced}
          withHeartbeat =
            case signedAssertionKind signed of
              BoundedState.HeartbeatAssertion timestamp ->
                withSemantic
                  { stateLastHeartbeatTimes =
                      Map.insert
                        (Text.unpack (signedAssertionEmitter signed))
                        (posixSecondsToUTCTime (fromIntegral timestamp))
                        (stateLastHeartbeatTimes withSemantic)
                  }
              _ -> withSemantic
      writeTVar (envState env) withHeartbeat
      pure (Right ())

retainSignedAssertion
  :: DaemonEnv
  -> SignedAssertion
  -> DaemonState
  -> DaemonState
retainSignedAssertion env signed state =
  let emitter = Text.unpack (signedAssertionEmitter signed)
      capacity = gatewayReplayPerEmitter (envGatewayBounds env)
      prunedState = pruneSignedReplayAtCheckpoint env emitter state
      existing = Map.findWithDefault [] emitter (stateSignedReplay prunedState)
      position = signedAssertionPosition signed
   in if any ((== position) . signedAssertionPosition) existing
        then prunedState
        else
          let ordered = sortOn signedAssertionPosition (signed : existing)
              evictedCount = max 0 (length ordered - capacity)
              (evicted, retained) = splitAt evictedCount ordered
              withCheckpoint =
                Prelude.foldl
                  (flip advanceSignedCheckpointEvidence)
                  prunedState
                  evicted
           in withCheckpoint
                { stateSignedReplay =
                    Map.insert emitter retained (stateSignedReplay withCheckpoint)
                }

retainSignedAssertions
  :: DaemonEnv
  -> [SignedAssertion]
  -> DaemonState
  -> DaemonState
retainSignedAssertions env assertions initial =
  Prelude.foldl (flip (retainSignedAssertion env)) initial assertions

pruneSignedReplayAtCheckpoint
  :: DaemonEnv
  -> String
  -> DaemonState
  -> DaemonState
pruneSignedReplayAtCheckpoint env emitter state =
  case boundedNodeByName env emitter of
    Nothing -> state
    Just nodeId ->
      case BoundedState.gatewayStateEmitterCheckpoint
        nodeId
        (stateBoundedGateway state) of
        Nothing -> state
        Just checkpoint ->
          let checkpointPosition =
                emitterCursorPosition
                  (BoundedState.emitterCheckpointCursor checkpoint)
              existing = Map.findWithDefault [] emitter (stateSignedReplay state)
              (compacted, retained) =
                span
                  ((<= checkpointPosition) . signedAssertionPosition)
                  (sortOn signedAssertionPosition existing)
              withEvidence =
                Prelude.foldl
                  (flip advanceSignedCheckpointEvidence)
                  state
                  compacted
           in withEvidence
                { stateSignedReplay =
                    Map.insert emitter retained (stateSignedReplay withEvidence)
                }

advanceSignedCheckpointEvidence
  :: SignedAssertion
  -> DaemonState
  -> DaemonState
advanceSignedCheckpointEvidence signed state =
  let emitter = Text.unpack (signedAssertionEmitter signed)
      insertLatest evidence =
        Map.insertWith
          newerSignedAssertion
          emitter
          signed
          evidence
   in case signedAssertionKind signed of
        BoundedState.HeartbeatAssertion _ ->
          state
            { stateSignedCheckpointHeartbeat =
                insertLatest (stateSignedCheckpointHeartbeat state)
            }
        BoundedState.OwnershipAssertion _ ->
          state
            { stateSignedCheckpointOwnership =
                insertLatest (stateSignedCheckpointOwnership state)
            }
        BoundedState.EpochRotationAssertion -> state

newerSignedAssertion :: SignedAssertion -> SignedAssertion -> SignedAssertion
newerSignedAssertion candidate existing =
  if signedAssertionPosition candidate >= signedAssertionPosition existing
    then candidate
    else existing

signedAssertionPosition :: SignedAssertion -> (Word64, Word64)
signedAssertionPosition signed =
  (signedAssertionEpoch signed, signedAssertionSequence signed)

emitterCursorPosition :: BoundedState.EmitterCursor -> (Word64, Word64)
emitterCursorPosition cursor =
  ( BoundedState.emitterEpochValue (BoundedState.emitterCursorEpoch cursor)
  , BoundedState.emitterSequenceValue (BoundedState.emitterCursorSequence cursor)
  )

boundedNodeByName :: DaemonEnv -> String -> Maybe BoundedState.NodeId
boundedNodeByName env nodeName =
  case filter
    ((== Text.pack nodeName) . BoundedState.nodeIdText)
    (BoundedState.validatedOrdersMemberIds (envValidatedOrders env)) of
    [nodeId] -> Just nodeId
    _ -> Nothing

boundedNodeDisposition :: DaemonEnv -> DaemonState -> String -> Disposition
boundedNodeDisposition env state nodeName =
  case filter
    ((== Text.pack nodeName) . BoundedState.nodeIdText)
    (BoundedState.validatedOrdersMemberIds (envValidatedOrders env)) of
    [nodeId] ->
      case BoundedState.assertionKind
        <$> BoundedState.gatewayStateLatestOwnership
          nodeId
          (stateBoundedGateway state) of
        Just (BoundedState.OwnershipAssertion BoundedState.OwnershipClaim) ->
          DispositionOwner
        Just (BoundedState.OwnershipAssertion BoundedState.OwnershipYield) ->
          DispositionYielded
        _ -> DispositionUnknown
    _ -> DispositionUnknown

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
                atomically (writeTVar (envDrainPhase env) PhaseDraining)
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

-- | Sprint 2.34: the unconditional serve-start @Ready@ write is gone. Kubelet
-- readiness is now a pure projection of the drain phase, the object-store
-- proof latch (set once by the continuity worker on the first validated
-- @StartupRecovery@ install), and the workers-started fact — so @/readyz@
-- cannot report ready before a proven durable-authority round trip.
serveGatewayDaemon :: PeerEndpoint -> DaemonEnv -> IO ()
serveGatewayDaemon localPeer env =
  race (drainCoordinator env) (daemonWorkers localPeer env)
    >>= either pure pure

daemonWorkers :: PeerEndpoint -> DaemonEnv -> IO ()
daemonWorkers localPeer env = do
  -- Monotone worker-started latch: recorded before the REST listener that
  -- serves @/readyz@ is spawned, so an observable ready projection structurally
  -- implies the workers are up.
  atomically (writeTVar (envWorkersStatus env) WorkersStarted)
  withAsync (worker "continuity" (continuityLoop env)) $ \_ ->
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
      atomically (writeTVar (envDrainPhase env) PhaseDraining)
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
        drainPhase <- readTVarIO (envDrainPhase env)
        if drainPhase == PhaseDraining
          then pure ()
          else do
            logForEnv env Warn "daemon_worker_returned" [field "worker" workerName]
            go 0
      Left exc ->
        do
          drainPhase <- readTVarIO (envDrainPhase env)
          if drainPhase == PhaseDraining
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
  case fromException exc :: Maybe SomeAsyncException of
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
    -- Vault-resolved boot secrets: a daemon that booted pre-Vault carries these
    -- as Nothing; once a reload can resolve them (Vault ready) that is a boot
    -- change and must drain-restart into full mode, not be discarded.
    || daemonMinioCreds old /= daemonMinioCreds new
    || dnsCredentialReloadRequired (daemonAwsCreds old) (daemonAwsCreds new)

dnsCredentialReloadRequired
  :: Maybe GatewayAwsCreds
  -> Maybe GatewayAwsCreds
  -> Bool
dnsCredentialReloadRequired current observed =
  case (current, observed) of
    (Nothing, Nothing) -> False
    (Just old, Just new) ->
      case (credentialGenerationFor old, credentialGenerationFor new) of
        (Right oldGeneration, Right newGeneration) ->
          case DnsAuthority.decideCredentialReload oldGeneration newGeneration of
            DnsAuthority.CredentialGenerationUnchanged -> False
            DnsAuthority.CredentialGenerationRestartRequired _ _ -> True
        _ -> old /= new
    _ -> True

credentialGenerationFor
  :: GatewayAwsCreds
  -> Either DnsAuthority.DnsAuthorityError DnsAuthority.CredentialGeneration
credentialGenerationFor credentials =
  DnsAuthority.mkCredentialGeneration (fromIntegral nonZeroWord)
 where
  digest =
    SHA256.hash
      ( BL.toStrict
          ( ByteStringBuilder.toLazyByteString
              ( foldMap
                  encodeCredentialField
                  [ gatewayAwsAccessKeyId credentials
                  , gatewayAwsSecretAccessKey credentials
                  , fromMaybe "" (gatewayAwsSessionToken credentials)
                  , gatewayAwsRegion credentials
                  ]
              )
          )
      )
  rawWord =
    BS.foldl'
      (\acc byte -> acc * 256 + fromIntegral byte)
      0
      (BS.take 8 digest)
  nonZeroWord :: Word64
  nonZeroWord = max 1 rawWord

  encodeCredentialField value =
    let bytes = BS8.pack value
     in ByteStringBuilder.word64BE (fromIntegral (BS.length bytes))
          <> ByteStringBuilder.byteString bytes

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
  now <- getCurrentTime
  let timestamp =
        fromIntegral
          (max 0 (floor (utcTimeToPOSIXSeconds now) :: Integer))
          :: Word64
  result <-
    emitLocalSemanticAssertion
      env
      (BoundedState.HeartbeatAssertion timestamp)
  case result of
    Left err -> logForEnv env Warn "heartbeat_emission_refused" [field "detail" err]
    Right _ -> pure ()
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
  claimFailure <-
    if transitionedToOwner
      then do
        result <-
          emitLocalSemanticAssertion
            env
            (BoundedState.OwnershipAssertion BoundedState.OwnershipClaim)
        pure (either Just (const Nothing) result)
      else pure Nothing
  for_ claimFailure $ \err ->
    logForEnv env Warn "gateway_claim_refused" [field "detail" err]
  yieldFailure <-
    if transitionedFromOwner
      then do
        result <-
          emitLocalSemanticAssertion
            env
            (BoundedState.OwnershipAssertion BoundedState.OwnershipYield)
        pure (either Just (const Nothing) result)
      else pure Nothing
  for_ yieldFailure $ \err ->
    logForEnv env Warn "gateway_yield_refused" [field "detail" err]
  let effectiveOwner =
        if transitionedToOwner && maybe False (const True) claimFailure
          then Nothing
          else owner
  atomically $ modifyTVar' stateVar $ \s ->
    s
      { stateGatewayOwner = effectiveOwner
      , statePreviousOwner = previous
      }
  liveConfig <- readTVarIO (envLiveConfig env)
  threadDelay (round (liveHeartbeatInterval liveConfig * 1000000))

-- | Write Route 53 only when the runtime CanWriteDns predicate holds: the
-- local node must be the elected owner AND the most recent claim/yield
-- event from the local node must be a claim.
dnsWriteLoop :: DaemonEnv -> IO ()
dnsWriteLoop env = forever $ do
  let config = envBootConfig env
      stateVar = envState env
  state <- readTVarIO stateVar
  let nodeId = daemonNodeId config
      eligible =
        stateGatewayOwner state == Just nodeId
          && boundedNodeDisposition env state nodeId == DispositionOwner
  when eligible $ do
    case (daemonDnsWriteGate config, daemonAwsCreds config) of
      (Nothing, _) -> pure ()
      (_, Nothing) ->
        logForEnv
          env
          Warn
          "dns_write_unavailable"
          [field "detail" ("credential generation is not ready" :: String)]
      (Just gate, Just awsCreds) -> do
        authorityResult <- dnsWriteAuthority env state awsCreds
        case authorityResult of
          Left err ->
            logForEnv env Warn "dns_write_unavailable" [field "detail" err]
          Right _ -> do
            publicIpResult <- fetchPublicIp
            case publicIpResult of
              Left err -> logForEnv env Warn "dns_write_skipped" [field "detail" err]
              Right currentIp -> do
                atomically $ modifyTVar' stateVar $ \s -> s {stateLastPublicIp = Just currentIp}
                let shouldWrite = case stateLastDnsWriteIp state of
                      Nothing -> True
                      Just lastIp -> lastIp /= currentIp
                when shouldWrite $ do
                  writeResult <-
                    withGatewayChild
                      env
                      "route53-dns-write"
                      (reobserveAndWriteDns env awsCreds gate currentIp)
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

dnsWriteAuthority
  :: DaemonEnv
  -> DaemonState
  -> GatewayAwsCreds
  -> IO (Either String DnsAuthority.DnsWriteAuthorized)
dnsWriteAuthority env state awsCreds = do
  runtime <- readTVarIO (envContinuity env)
  case runtime of
    Nothing -> pure (Left "retained continuity authority is unavailable")
    Just active -> do
      current <- readTVarIO (continuityRuntimeCurrent active)
      pure $ do
        generation <- mapDnsError (credentialGenerationFor awsCreds)
        credentials <-
          mapDnsError
            ( DnsAuthority.mkDnsAwsCredentials
                DnsAuthority.DnsCredentialInput
                  { DnsAuthority.dnsCredentialAccessKeyId =
                      Text.pack (gatewayAwsAccessKeyId awsCreds)
                  , DnsAuthority.dnsCredentialSecretAccessKey =
                      Text.pack (gatewayAwsSecretAccessKey awsCreds)
                  , DnsAuthority.dnsCredentialSessionToken =
                      Text.pack <$> gatewayAwsSessionToken awsCreds
                  , DnsAuthority.dnsCredentialRegion =
                      Text.pack (gatewayAwsRegion awsCreds)
                  }
            )
        fence <- mapDnsError (continuityFenceFromCurrent current)
        mapDnsError
          ( DnsAuthority.authorizeDnsWrite
              (Text.pack (daemonNodeId (envBootConfig env)))
              (DnsAuthority.CredentialsReady generation credentials)
              (DnsAuthority.ContinuityReady fence)
              ( if boundedNodeDisposition env state (daemonNodeId (envBootConfig env))
                  == DispositionOwner
                  then
                    maybe
                      DnsAuthority.DnsClaimAbsent
                      DnsAuthority.DnsClaimCurrent
                      (stateDnsClaimAuthority state)
                  else DnsAuthority.DnsClaimAbsent
              )
          )
 where
  mapDnsError = either (Left . show) Right

-- | Re-observe the retained continuity object and consume the resulting
-- credential/claim witness within the same capacity-one child lease as the
-- Route 53 subprocess.  A staged, missing, corrupt, or unobservable record
-- cannot cross the effect boundary.
reobserveAndWriteDns
  :: DaemonEnv
  -> GatewayAwsCreds
  -> DnsWriteGate
  -> String
  -> IO (Either String ())
reobserveAndWriteDns env awsCreds gate currentIp = do
  runtime <- readTVarIO (envContinuity env)
  case runtime of
    Nothing -> pure (Left "retained continuity authority is unavailable")
    Just active -> do
      observed <-
        Continuity.recoverContinuityAtStartup
          (continuityRuntimeAuthority active)
      case observed of
        Left err -> pure (Left (show err))
        Right (Continuity.StartupRepublish _) ->
          pure (Left "retained continuity has an uncommitted staged assertion")
        Right (Continuity.StartupCurrent current) -> do
          atomically (writeTVar (continuityRuntimeCurrent active) current)
          freshState <- readTVarIO (envState env)
          authority <- dnsWriteAuthority env freshState awsCreds
          case authority of
            Left err -> pure (Left err)
            Right ready ->
              case do
                if dnsWriteGateTtl gate > 0
                  then Right ()
                  else Left (DnsAuthority.DnsWriteTtlInvalid 0)
                request <-
                  DnsAuthority.mkDnsWriteRequest
                    (Text.pack (dnsWriteGateZoneId gate))
                    (Text.pack (dnsWriteGateFqdn gate))
                    (fromIntegral (dnsWriteGateTtl gate))
                    (Text.pack (dnsWriteGateAwsRegion gate))
                    (Text.pack currentIp)
                DnsAuthority.authorizeDnsWriteRequest ready request of
                Left err -> pure (Left (show err))
                Right action -> writeDnsRecord action

hexText :: ByteString -> Text.Text
hexText bytes =
  TextEncoding.decodeUtf8
    ( BL.toStrict
        ( ByteStringBuilder.toLazyByteString
            (foldMap ByteStringBuilder.word8HexFixed (BS.unpack bytes))
        )
    )

withGatewayChild
  :: DaemonEnv
  -> Text.Text
  -> IO (Either String value)
  -> IO (Either String value)
withGatewayChild env childName action = do
  let bounds = envGatewayBounds env
      deadline = gatewayChildDeadlineMicros bounds
      request =
        RawChildRequest
          { rawChildRequestName = childName
          , rawChildRequestTimeoutMicros = Just deadline
          , rawChildRequestPeakBytes = Just (gatewayChildPeakBytes bounds)
          }
      deadlineInt = fromIntegral deadline
  permit <- timeout deadlineInt (atomically (takeTMVar (envChildPermit env)))
  case permit of
    Nothing -> pure (Left "gateway child permit deadline elapsed")
    Just () -> do
      scheduledResult <- atomically $ do
        scheduler <- readTVar (envChildScheduler env)
        case scheduleChild scheduler request of
          Left err -> pure (Left err)
          Right (scheduled, acquired) -> do
            writeTVar (envChildScheduler env) acquired
            pure (Right scheduled)
      case scheduledResult of
        Left err -> do
          atomically (putTMVar (envChildPermit env) ())
          pure (Left ("gateway child schedule refused: " ++ show err))
        Right scheduled ->
          ( do
              result <- timeout (scheduledChildTimeoutMicros scheduled) action
              pure $ case result of
                Nothing -> Left "gateway child process deadline elapsed"
                Just completed -> completed
          )
            `finally` atomically
              ( do
                  scheduler <- readTVar (envChildScheduler env)
                  case completeChild scheduler scheduled of
                    Left _ -> pure ()
                    Right available -> writeTVar (envChildScheduler env) available
                  putTMVar (envChildPermit env) ()
              )

restServerLoop :: PeerEndpoint -> DaemonEnv -> IO ()
restServerLoop localPeer env = do
  let host = peerRestHost localPeer
      port = peerRestPort localPeer
  withListeningSocket "REST server" host port $ \sock -> do
    logForEnv env Info "rest_server_listening" [field "host" host, field "port" port]
    acceptWhileServing
      (gatewayMaxInFlightFrames (envGatewayBounds env))
      True
      sock
      env
      (`handleRestClient` env)

-- | Preserve the listeners' benign handling of connection-local failures,
-- while allowing structured-concurrency cancellation to leave a fixed worker
-- immediately instead of being swallowed by a broad request boundary.
ignoreSynchronousConnectionFailure :: IO () -> IO ()
ignoreSynchronousConnectionFailure action = do
  outcome <- try action :: IO (Either SomeException ())
  case outcome of
    Right () -> pure ()
    Left exc ->
      case fromException exc :: Maybe SomeAsyncException of
        Just _ -> throwIO exc
        Nothing -> pure ()

handleRestClient :: Socket -> DaemonEnv -> IO ()
handleRestClient sock env =
  ignoreSynchronousConnectionFailure handleRequest
 where
  handleRequest = do
    maybeRaw <- receiveAllWithin env pulumiObjectRequestMaxBytes sock
    for_ maybeRaw handleParsedRequest

  handleParsedRequest rawRequest = do
    now <- getCurrentTime
    let path = requestPath rawRequest
    case routeForPath path of
      Just route -> dispatchGatewayRoute sock env now rawRequest route
      Nothing -> dispatchPatternRoute sock env rawRequest path

-- | Sprint 2.34: the daemon request dispatcher as one total @case@ over the
-- compiled 'GatewayRoute' registry ("Prodbox.Gateway.Routes"). Every path string
-- is a projection of @routePattern@; a registered route with no arm here is a
-- @-Werror@ compile error, so the daemon, the client, and the chart probe
-- rendering cannot drift.
--
-- LEGACY-ESCAPE[gateway-hosted-authority-routes]: the gateway daemon hosts the
-- bootstrap-Vault, Pulumi/authority object-store, lifecycle authority CAS/clock,
-- and target-secret authority routes below (plus the operator-secret route in
-- 'dispatchPatternRoute'). Registered in Prodbox.Legacy.EscapeRegistry; these
-- routes leave the gateway for the Bootstrap Broker / Lifecycle Authority /
-- Target Secret Agent under Sprints 2.33/4.50.
dispatchGatewayRoute :: Socket -> DaemonEnv -> UTCTime -> BS.ByteString -> GatewayRoute -> IO ()
dispatchGatewayRoute sock env now rawRequest route = case route of
  RouteHealthz ->
    sendHttpResponse sock 200 "text/plain" "ok\n"
  RouteReadyz -> do
    -- Constant-time projection: a consistent single-transaction snapshot of the
    -- three cached monotone facts, folded by the pure 'computeReadiness'. No
    -- backend I/O (bootstrap_readiness_doctrine §0.7 / §2.1).
    inputs <-
      atomically $
        ReadinessInputs
          <$> readTVar (envDrainPhase env)
          <*> readTVar (envObjectStoreProof env)
          <*> readTVar (envWorkersStatus env)
    case computeReadiness inputs of
      Ready -> sendHttpResponse sock 200 "text/plain" "ready\n"
      Draining -> sendHttpResponse sock 503 "text/plain" "draining\n"
      Starting -> sendHttpResponse sock 503 "text/plain" "starting\n"
  RouteMetrics -> do
    state <- readTVarIO (envState env)
    sendHttpResponse sock 200 "text/plain" (renderMetricsText now env state)
  RouteState -> do
    state <- readTVarIO (envState env)
    dnsReady <- gatewayDnsWriteReady env state
    continuityDiagnostic <- readContinuityDiagnostic env
    sendLazyHttpResponse
      sock
      200
      "application/json"
      (renderStateJson now env dnsReady continuityDiagnostic state)
  RouteFederationChildren -> do
    childrenResult <- readFederationChildren (envBootConfig env)
    case childrenResult of
      Left err -> sendHttpResponse sock 503 "text/plain" (err ++ "\n")
      Right children ->
        sendLazyHttpResponse
          sock
          200
          "application/json"
          (encode (object ["children" .= children]))
  RouteBootstrapVaultEnsure -> handleBootstrapVaultEnsure sock env rawRequest
  RouteBootstrapVaultStatus -> handleBootstrapVaultStatus sock env rawRequest
  RouteBootstrapVaultSeal -> handleBootstrapVaultSeal sock env rawRequest
  RouteBootstrapVaultRotateUnlockBundle -> handleBootstrapVaultRotateUnlockBundle sock env rawRequest
  RouteBootstrapVaultRotateTransitKey -> handleBootstrapVaultRotateTransitKey sock env rawRequest
  RouteBootstrapVaultPkiStatus -> handleBootstrapVaultPkiStatus sock env rawRequest
  RouteBootstrapVaultPkiIssueTestCert -> handleBootstrapVaultPkiIssueTestCert sock env rawRequest
  RoutePulumiObjectGet -> handlePulumiObjectGet sock env rawRequest
  RoutePulumiObjectPut -> handlePulumiObjectPut sock env rawRequest
  RoutePulumiObjectDelete -> handlePulumiObjectDelete sock env rawRequest
  RouteAuthorityObjectGet -> handleAuthorityObjectGet sock env rawRequest
  RouteAuthorityObjectCas -> handleAuthorityObjectCas sock env rawRequest
  RouteAuthorityClock -> handleAuthorityClock sock rawRequest
  RouteTargetSecretRead -> handleTargetSecretRead sock env rawRequest
  RouteTargetSecretCas -> handleTargetSecretCas sock env rawRequest

-- | The two variable-suffix pattern routes (operator-secret write, federation
-- child bootstrap) and the 404 fallthrough — the paths that are prefixes, not
-- fixed 'GatewayRoute' strings. Reached only when 'routeForPath' finds no fixed
-- route, preserving the pre-Sprint-2.34 precedence (fixed routes first).
dispatchPatternRoute :: Socket -> DaemonEnv -> BS.ByteString -> String -> IO ()
dispatchPatternRoute sock env rawRequest path =
  case operatorSecretLogicalPath path of
    Just logical
      | operatorSecretRequestMethod rawRequest == "POST" ->
          handleOperatorSecretWrite sock env rawRequest logical
      | otherwise ->
          -- The write endpoint exists only for POST; a GET/PUT/etc. against
          -- it is a client error, never a Vault read (the secrets it owns are
          -- read in-cluster via Vault Kubernetes auth, never echoed back).
          sendHttpResponse sock 405 "text/plain" "method not allowed\n"
    Nothing ->
      case federationBootstrapChildId path of
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
  logical <- stripPrefix operatorSecretPathPrefix path
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
-- Sprint 2.34: these are projections of the compiled route registry
-- ("Prodbox.Gateway.Routes"), not independent literals, so the daemon's own
-- diagnostics cannot drift from the dispatcher and client.
bootstrapVaultPath :: String
bootstrapVaultPath = routePattern RouteBootstrapVaultEnsure

bootstrapVaultStatusPath :: String
bootstrapVaultStatusPath = routePattern RouteBootstrapVaultStatus

bootstrapVaultSealPath :: String
bootstrapVaultSealPath = routePattern RouteBootstrapVaultSeal

bootstrapVaultRotateUnlockBundlePath :: String
bootstrapVaultRotateUnlockBundlePath = routePattern RouteBootstrapVaultRotateUnlockBundle

bootstrapVaultRotateTransitKeyPath :: String
bootstrapVaultRotateTransitKeyPath = routePattern RouteBootstrapVaultRotateTransitKey

bootstrapVaultPkiStatusPath :: String
bootstrapVaultPkiStatusPath = routePattern RouteBootstrapVaultPkiStatus

bootstrapVaultPkiIssueTestCertPath :: String
bootstrapVaultPkiIssueTestCertPath = routePattern RouteBootstrapVaultPkiIssueTestCert

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
      result <- ensureBootstrapVault env request
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
    result <- sealBootstrapVault env request
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
      result <- rotateBootstrapUnlockBundle env request
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
      result <- rotateBootstrapTransitKey env request
      sendBootstrapActionResult sock result

handleBootstrapVaultPkiStatus :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultPkiStatus sock env rawRequest =
  handleBootstrapVaultPasswordAction sock rawRequest $ \request -> do
    result <- bootstrapVaultPkiStatus env request
    pure $ encodeBootstrapActionResult result

handleBootstrapVaultPkiIssueTestCert :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleBootstrapVaultPkiIssueTestCert sock env rawRequest =
  handleBootstrapVaultPasswordAction sock rawRequest $ \request -> do
    result <- bootstrapVaultPkiIssueTestCert env request
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
  :: DaemonEnv
  -> BootstrapVaultRequest
  -> IO (Either BootstrapVaultEnsureError BootstrapVaultResponse)
ensureBootstrapVault env request = do
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
  config = envBootConfig env
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
            writeResult <-
              withGatewayChild
                env
                "vault-bootstrap-bundle-write"
                (putAndVerifyBootstrapBundle minioConfig password envelopeBytes)
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
    bundleResult <-
      withGatewayChild
        env
        "vault-bootstrap-bundle-read"
        (readBootstrapBundle minioConfig password)
    case bundleResult of
      Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
      Right bundle -> do
        unsealResult <- submitBootstrapUnsealSteps address status bundle
        case unsealResult of
          Left err -> pure (Left (BootstrapVaultEnsureUnsealFailed err))
          Right () ->
            reconcileWithRootToken "unsealed-reconciled" (VaultToken (unlockBundleInitialRootToken bundle))

  reconcileReadyVault = do
    bundleResult <-
      withGatewayChild
        env
        "vault-bootstrap-bundle-read"
        (readBootstrapBundle minioConfig password)
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
  :: DaemonEnv -> BootstrapVaultRequest -> IO (Either BootstrapVaultEnsureError Value)
sealBootstrapVault env request = do
  tokenResult <- bootstrapRootToken env (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <- vaultSeal (bootstrapVaultAddress (envBootConfig env)) token
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
  :: DaemonEnv
  -> BootstrapVaultRotateUnlockBundleRequest
  -> IO (Either BootstrapVaultEnsureError BL.ByteString)
rotateBootstrapUnlockBundle env request = do
  bundleResult <-
    withGatewayChild
      env
      "vault-bootstrap-bundle-read"
      (readBootstrapBundle minioConfig (bootstrapVaultRotateCurrentPassword request))
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
            withGatewayChild env "vault-bootstrap-bundle-write" $
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
  config = envBootConfig env
  minioConfig = bootstrapVaultObjectStoreConfig config

rotateBootstrapTransitKey
  :: DaemonEnv
  -> BootstrapVaultRotateTransitKeyRequest
  -> IO (Either BootstrapVaultEnsureError BL.ByteString)
rotateBootstrapTransitKey env request = do
  tokenResult <- bootstrapRootToken env (bootstrapVaultRotateTransitPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <-
        vaultRotateTransitKey
          (bootstrapVaultAddress (envBootConfig env))
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
  :: DaemonEnv -> BootstrapVaultRequest -> IO (Either BootstrapVaultEnsureError Value)
bootstrapVaultPkiStatus env request = do
  tokenResult <- bootstrapRootToken env (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      mountsResult <- vaultListMounts (bootstrapVaultAddress (envBootConfig env)) token
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
  :: DaemonEnv -> BootstrapVaultRequest -> IO (Either BootstrapVaultEnsureError Value)
bootstrapVaultPkiIssueTestCert env request = do
  tokenResult <- bootstrapRootToken env (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <-
        vaultPkiIssueTestCertificate
          (bootstrapVaultAddress (envBootConfig env))
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

bootstrapRootToken :: DaemonEnv -> Text.Text -> IO (Either BootstrapVaultEnsureError VaultToken)
bootstrapRootToken env password = do
  bundleResult <-
    withGatewayChild
      env
      "vault-bootstrap-bundle-read"
      ( readBootstrapBundle
          (bootstrapVaultObjectStoreConfig (envBootConfig env))
          password
      )
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
  | AuthorityObjectRequestTooLarge Int
  | PulumiObjectRequestEmpty
  | PulumiObjectRequestMalformed String
  | PulumiObjectStackInvalid String
  | AuthorityObjectLogicalNameInvalid String
  | AuthorityObjectExpectedVersionInvalid String
  | AuthorityObjectLeaseGuardInvalid String
  | AuthorityObjectPayloadInvalid AuthorityObjectPayloadError
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

decodeAuthorityObjectRequest
  :: BS.ByteString -> Either PulumiObjectRequestError AuthorityObjectRequest
decodeAuthorityObjectRequest rawRequest = do
  request <- decodeAuthorityObjectJson rawRequest
  logicalName <-
    case validateAuthorityObjectLogicalName (authorityObjectLogicalName request) of
      Left err -> Left (AuthorityObjectLogicalNameInvalid err)
      Right validated -> Right validated
  if authorityObjectLoopbackNodePortVerified request
    then Right request {authorityObjectLogicalName = logicalName}
    else Left PulumiObjectLoopbackUnverified

decodeAuthorityObjectCasRequest
  :: BS.ByteString -> Either PulumiObjectRequestError AuthorityObjectCasRequest
decodeAuthorityObjectCasRequest rawRequest = do
  request <- decodeAuthorityObjectJson rawRequest
  logicalName <-
    case validateAuthorityObjectLogicalName (authorityObjectCasLogicalName request) of
      Left err -> Left (AuthorityObjectLogicalNameInvalid err)
      Right validated -> Right validated
  expectedVersion <- traverse validateExpectedVersion (authorityObjectCasExpectedVersion request)
  leaseGuard <- traverse validateAuthorityLeaseGuard (authorityObjectCasLeaseGuard request)
  case ("leases/" `Text.isPrefixOf` logicalName, leaseGuard) of
    (True, Nothing) -> Right ()
    (True, Just _) ->
      Left
        ( AuthorityObjectLeaseGuardInvalid
            "lease projection acquire/release CAS must not carry a second lease guard"
        )
    (False, Nothing) ->
      Left
        ( AuthorityObjectLeaseGuardInvalid
            "checkpoint, SMTP, and global-intent CAS requires a current lease guard"
        )
    (False, Just _) -> Right ()
  case validateAuthorityObjectPayloadSize
    logicalName
    (authorityObjectCasPayload request) of
    Left err -> Left (AuthorityObjectPayloadInvalid err)
    Right () -> Right ()
  if authorityObjectCasLoopbackNodePortVerified request
    then
      Right
        request
          { authorityObjectCasLogicalName = logicalName
          , authorityObjectCasExpectedVersion = expectedVersion
          , authorityObjectCasLeaseGuard = leaseGuard
          }
    else Left PulumiObjectLoopbackUnverified

validateExpectedVersion
  :: Text.Text -> Either PulumiObjectRequestError Text.Text
validateExpectedVersion version
  | Text.null stripped =
      Left (AuthorityObjectExpectedVersionInvalid "expected_version must not be empty")
  | Text.length stripped > 512 =
      Left (AuthorityObjectExpectedVersionInvalid "expected_version must be 512 characters or fewer")
  | otherwise = Right stripped
 where
  stripped = Text.strip version

validateAuthorityLeaseGuard
  :: AuthorityObjectLeaseGuard
  -> Either PulumiObjectRequestError AuthorityObjectLeaseGuard
validateAuthorityLeaseGuard guard = do
  logicalName <-
    case validateAuthorityObjectLogicalName (authorityLeaseGuardLogicalName guard) of
      Left err -> Left (AuthorityObjectLogicalNameInvalid err)
      Right validated
        | "leases/" `Text.isPrefixOf` validated -> Right validated
        | otherwise ->
            Left
              ( AuthorityObjectLogicalNameInvalid
                  "lease_guard.logical_name must use the leases/ namespace"
              )
  expectedVersion <- validateExpectedVersion (authorityLeaseGuardExpectedVersion guard)
  if Text.null (Text.strip (authorityLeaseGuardOwnerNonce guard))
    then
      Left
        ( AuthorityObjectLeaseGuardInvalid
            "lease_guard.owner_nonce must not be empty"
        )
    else
      if authorityLeaseGuardFencingToken guard == 0
        then
          Left
            ( AuthorityObjectLeaseGuardInvalid
                "lease_guard.fencing_token must be positive"
            )
        else
          Right
            guard
              { authorityLeaseGuardLogicalName = logicalName
              , authorityLeaseGuardExpectedVersion = expectedVersion
              , authorityLeaseGuardOwnerNonce =
                  Text.strip (authorityLeaseGuardOwnerNonce guard)
              }

decodeAuthorityClockRequest
  :: BS.ByteString -> Either PulumiObjectRequestError AuthorityClockRequest
decodeAuthorityClockRequest rawRequest = do
  request <- decodeAuthorityObjectJson rawRequest
  if authorityClockLoopbackNodePortVerified request
    then Right request
    else Left PulumiObjectLoopbackUnverified

decodeTargetSecretReadRequest
  :: BS.ByteString
  -> Either TargetSecret.TargetSecretRequestError TargetSecret.TargetSecretReadRequest
decodeTargetSecretReadRequest rawRequest = do
  request <- decodeTargetSecretJson rawRequest
  TargetSecret.validateTargetSecretReadRequest request

decodeTargetSecretCasRequest
  :: BS.ByteString
  -> Either TargetSecret.TargetSecretRequestError TargetSecret.TargetSecretCasRequest
decodeTargetSecretCasRequest rawRequest = do
  request <- decodeTargetSecretJson rawRequest
  TargetSecret.validateTargetSecretCasRequest request

decodeTargetSecretJson
  :: (FromJSON value)
  => BS.ByteString
  -> Either TargetSecret.TargetSecretRequestError value
decodeTargetSecretJson rawRequest
  | method /= "POST" = Left (TargetSecret.TargetSecretMethodNotAllowed method)
  | BS.length body > TargetSecret.targetSecretRequestMaxBytes =
      Left
        ( TargetSecret.TargetSecretRequestTooLarge
            (BS.length body)
            TargetSecret.targetSecretRequestMaxBytes
        )
  | BS.null (BS8.dropWhile isSpace body) = Left TargetSecret.TargetSecretRequestEmpty
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left (TargetSecret.TargetSecretRequestMalformed err)
        Right request -> Right request
 where
  method = operatorSecretRequestMethod rawRequest
  body = requestBodyBytes rawRequest

decodeAuthorityObjectJson
  :: (FromJSON a) => BS.ByteString -> Either PulumiObjectRequestError a
decodeAuthorityObjectJson rawRequest
  | method /= "POST" = Left (PulumiObjectMethodNotAllowed method)
  | BS.length body > authorityObjectRequestMaxBytes =
      Left (AuthorityObjectRequestTooLarge (BS.length body))
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
  AuthorityObjectRequestTooLarge size ->
    "authority object-store request body is too large: "
      ++ show size
      ++ " bytes; maximum is "
      ++ show authorityObjectRequestMaxBytes
  PulumiObjectRequestEmpty ->
    "empty request body; expected JSON object with stack and loopback_nodeport_verified"
  PulumiObjectRequestMalformed detail ->
    "invalid Pulumi object-store JSON body: " ++ detail
  PulumiObjectStackInvalid detail ->
    "invalid Pulumi stack name: " ++ detail
  AuthorityObjectLogicalNameInvalid detail ->
    "invalid authority logical name: " ++ detail
  AuthorityObjectExpectedVersionInvalid detail ->
    "invalid authority expected version: " ++ detail
  AuthorityObjectLeaseGuardInvalid detail ->
    "invalid authority lease guard: " ++ detail
  AuthorityObjectPayloadInvalid payloadError ->
    "authority object payload for `"
      ++ Text.unpack (authorityPayloadLogicalName payloadError)
      ++ "` is too large: "
      ++ show (authorityPayloadObservedBytes payloadError)
      ++ " bytes; maximum is "
      ++ show (authorityPayloadMaximumBytes payloadError)
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

handleAuthorityObjectGet :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleAuthorityObjectGet sock env rawRequest =
  case decodeAuthorityObjectRequest rawRequest of
    Left (PulumiObjectMethodNotAllowed _) ->
      sendPulumiObjectRequestError
        sock
        405
        (PulumiObjectMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendPulumiObjectRequestError sock 400 err
    Right request -> do
      result <- readDaemonAuthorityObject env (authorityObjectLogicalName request)
      case result of
        Left err -> sendAuthorityObjectActionError sock err
        Right observation ->
          sendLazyHttpResponse sock 200 "application/json" (encode observation)

handleAuthorityObjectCas :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleAuthorityObjectCas sock env rawRequest =
  case decodeAuthorityObjectCasRequest rawRequest of
    Left (PulumiObjectMethodNotAllowed _) ->
      sendPulumiObjectRequestError
        sock
        405
        (PulumiObjectMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendPulumiObjectRequestError sock 400 err
    Right request -> do
      result <- compareAndSwapDaemonAuthorityObject env request
      case result of
        Left err -> sendAuthorityObjectActionError sock err
        Right response ->
          sendLazyHttpResponse sock 200 "application/json" (encode response)

handleAuthorityClock :: Socket -> BS.ByteString -> IO ()
handleAuthorityClock sock rawRequest =
  case decodeAuthorityClockRequest rawRequest of
    Left (PulumiObjectMethodNotAllowed _) ->
      sendPulumiObjectRequestError
        sock
        405
        (PulumiObjectMethodNotAllowed (operatorSecretRequestMethod rawRequest))
    Left err -> sendPulumiObjectRequestError sock 400 err
    Right _ -> do
      now <- getCurrentTime
      sendLazyHttpResponse
        sock
        200
        "application/json"
        (encode (AuthorityClockResponse (authorityMicrosFromUtc now)))

authorityMicrosFromUtc :: UTCTime -> Natural
authorityMicrosFromUtc now =
  fromInteger
    ( max
        0
        (floor (utcTimeToPOSIXSeconds now * 1000000) :: Integer)
    )

handleTargetSecretRead :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleTargetSecretRead sock env rawRequest =
  case decodeTargetSecretReadRequest rawRequest of
    Left (TargetSecret.TargetSecretMethodNotAllowed _) ->
      sendTargetSecretRequestError sock 405 (TargetSecret.TargetSecretMethodNotAllowed method)
    Left err -> sendTargetSecretRequestError sock 400 err
    Right request -> do
      result <-
        readTargetSecret
          env
          (TargetSecret.targetSecretReadCoordinate request)
      case result of
        Left err -> sendTargetSecretActionError sock err
        Right observation ->
          sendLazyHttpResponse sock 200 "application/json" (encode observation)
 where
  method = operatorSecretRequestMethod rawRequest

handleTargetSecretCas :: Socket -> DaemonEnv -> BS.ByteString -> IO ()
handleTargetSecretCas sock env rawRequest =
  case decodeTargetSecretCasRequest rawRequest of
    Left (TargetSecret.TargetSecretMethodNotAllowed _) ->
      sendTargetSecretRequestError sock 405 (TargetSecret.TargetSecretMethodNotAllowed method)
    Left err -> sendTargetSecretRequestError sock 400 err
    Right request -> do
      result <- compareAndSwapTargetSecretVault env request
      case result of
        Left err -> sendTargetSecretActionError sock err
        Right response ->
          sendLazyHttpResponse sock 200 "application/json" (encode response)
 where
  method = operatorSecretRequestMethod rawRequest

data TargetSecretActionError
  = TargetSecretAuthUnavailable !String
  | TargetSecretIdentityRefused !TargetSecret.TargetSecretRequestError
  | TargetSecretVaultUnavailable !String
  | TargetSecretStoredPayloadInvalid !TargetSecret.TargetSecretRequestError
  deriving (Eq, Show)

sendTargetSecretRequestError
  :: Socket -> Int -> TargetSecret.TargetSecretRequestError -> IO ()
sendTargetSecretRequestError sock status err =
  sendHttpResponse sock status "text/plain" (show err ++ "\n")

sendTargetSecretActionError :: Socket -> TargetSecretActionError -> IO ()
sendTargetSecretActionError sock err = case err of
  TargetSecretAuthUnavailable detail ->
    sendHttpResponse sock 503 "text/plain" (detail ++ "\n")
  TargetSecretIdentityRefused detail ->
    sendHttpResponse sock 409 "text/plain" (show detail ++ "\n")
  TargetSecretVaultUnavailable detail ->
    sendHttpResponse sock 502 "text/plain" (detail ++ "\n")
  TargetSecretStoredPayloadInvalid detail ->
    sendHttpResponse
      sock
      502
      "text/plain"
      ("target-secret Vault payload is invalid: " ++ show detail ++ "\n")

readTargetSecret
  :: DaemonEnv
  -> TargetSecret.TargetSecretCoordinate
  -> IO (Either TargetSecretActionError TargetSecret.TargetSecretObservation)
readTargetSecret env coordinate = do
  identityResult <- attestTargetSecretCoordinate env coordinate
  case identityResult of
    Left err -> pure (Left err)
    Right () -> do
      sessionResult <- resolveTargetSecretVaultSession (envBootConfig env)
      case sessionResult of
        Left err -> pure (Left (TargetSecretAuthUnavailable err))
        Right session -> do
          -- Sprint 1.64: route the read through the cached session so a stale
          -- cached token that draws a 403 triggers exactly one
          -- invalidate-and-relogin before the read is reinterpreted.
          result <-
            withSessionToken session $ \token ->
              rawTargetSecretVersionedRead (sessionAddress session) token coordinate
          pure (interpretTargetSecretRead result)

-- | The raw versioned read, surfacing the 'HttpError' so a caller (via
-- 'withSessionToken') can react to a 403.
rawTargetSecretVersionedRead
  :: VaultAddress
  -> VaultToken
  -> TargetSecret.TargetSecretCoordinate
  -> IO (Either HttpError KvV2VersionedSecret)
rawTargetSecretVersionedRead address token coordinate =
  vaultKvReadVersionedV2
    address
    token
    (TargetSecret.targetSecretCoordinateVaultMount coordinate)
    (TargetSecret.targetSecretCoordinateKvPath coordinate)

-- | Pure interpretation of a versioned target-secret read.
interpretTargetSecretRead
  :: Either HttpError KvV2VersionedSecret
  -> Either TargetSecretActionError TargetSecret.TargetSecretObservation
interpretTargetSecretRead result = case result of
  Left (HttpStatus 404 _) -> Right TargetSecret.TargetSecretMissing
  Left err ->
    Left
      ( TargetSecretVaultUnavailable
          ("target-secret Vault read failed: " ++ renderHttpError err)
      )
  Right versioned ->
    case TargetSecret.targetSecretRecordFromVaultFields
      (kvV2VersionedSecretData versioned) of
      Left err -> Left (TargetSecretStoredPayloadInvalid err)
      Right record ->
        Right
          ( TargetSecret.TargetSecretObserved
              (kvV2VersionedSecretVersion versioned)
              record
          )

-- | Post-write re-read used by 'compareAndSwapTargetSecretVault', which already
-- holds the token from its guarded write.
readTargetSecretWithToken
  :: VaultAddress
  -> VaultToken
  -> TargetSecret.TargetSecretCoordinate
  -> IO (Either TargetSecretActionError TargetSecret.TargetSecretObservation)
readTargetSecretWithToken address token coordinate =
  interpretTargetSecretRead <$> rawTargetSecretVersionedRead address token coordinate

compareAndSwapTargetSecretVault
  :: DaemonEnv
  -> TargetSecret.TargetSecretCasRequest
  -> IO (Either TargetSecretActionError TargetSecret.TargetSecretCasResponse)
compareAndSwapTargetSecretVault env request = do
  let coordinate = TargetSecret.targetSecretCasCoordinate request
  identityResult <- attestTargetSecretCoordinate env coordinate
  case identityResult of
    Left err -> pure (Left err)
    Right () -> do
      tokenResult <- resolveTargetSecretVaultToken (envBootConfig env)
      case tokenResult of
        Left err -> pure (Left (TargetSecretAuthUnavailable err))
        Right (address, token) ->
          case TargetSecret.targetSecretRecordToVaultFields (TargetSecret.targetSecretCasRecord request) of
            Left err -> pure (Left (TargetSecretStoredPayloadInvalid err))
            Right fields -> do
              result <-
                vaultKvCasWriteV2
                  address
                  token
                  (TargetSecret.targetSecretCoordinateVaultMount coordinate)
                  (TargetSecret.targetSecretCoordinateKvPath coordinate)
                  (KvV2Cas (TargetSecret.targetSecretCasExpectedVersion request))
                  fields
              case result of
                Right version ->
                  pure (Right (TargetSecret.TargetSecretCasApplied version))
                Left err
                  | vaultKvCasMismatch err -> do
                      observed <- readTargetSecretWithToken address token coordinate
                      pure (TargetSecret.TargetSecretCasConflict <$> observed)
                  | otherwise ->
                      pure
                        ( Left
                            ( TargetSecretVaultUnavailable
                                ("target-secret Vault CAS failed: " ++ renderHttpError err)
                            )
                        )

attestTargetSecretCoordinate
  :: DaemonEnv
  -> TargetSecret.TargetSecretCoordinate
  -> IO (Either TargetSecretActionError ())
attestTargetSecretCoordinate env coordinate = do
  clusterResult <- loadDaemonClusterId (envConfigPath env)
  pure $ case clusterResult of
    Left err -> Left (TargetSecretAuthUnavailable err)
    Right clusterId ->
      case TargetSecret.validateTargetSecretIdentity clusterId coordinate of
        Left refusal -> Left (TargetSecretIdentityRefused refusal)
        Right () -> Right ()

vaultKvCasMismatch :: HttpError -> Bool
vaultKvCasMismatch err = case err of
  HttpStatus 400 body ->
    let normalized = map toLower body
     in "check-and-set parameter did not match" `isInfixOf` normalized
  _ -> False

sendPulumiObjectRequestError :: Socket -> Int -> PulumiObjectRequestError -> IO ()
sendPulumiObjectRequestError sock status err =
  sendHttpResponse sock status "text/plain" (renderPulumiObjectRequestError err ++ "\n")

sendPulumiObjectActionError :: Socket -> String -> IO ()
sendPulumiObjectActionError sock detail =
  sendHttpResponse sock 503 "text/plain" ("Pulumi object-store unavailable: " ++ detail ++ "\n")

sendAuthorityObjectActionError :: Socket -> String -> IO ()
sendAuthorityObjectActionError sock detail =
  sendHttpResponse sock 503 "text/plain" ("authority object-store unavailable: " ++ detail ++ "\n")

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
    Right material ->
      withGatewayChild env "pulumi-object-get" $ do
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
    Right material ->
      withGatewayChild env "pulumi-object-put" $ do
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

readDaemonAuthorityObject
  :: DaemonEnv -> Text.Text -> IO (Either String AuthorityObjectObservation)
readDaemonAuthorityObject env logicalName = do
  materialResult <- resolveDaemonPulumiObjectMaterial env
  case materialResult of
    Left err -> pure (Left err)
    Right material ->
      withGatewayChild env "authority-object-get" $ do
        result <-
          getLogicalVersioned
            (daemonPulumiObjectStore material)
            (daemonPulumiCipher material)
            (daemonPulumiHmacKey material)
            (daemonPulumiClusterId material)
            (authorityLogicalObject logicalName)
        pure $ case result of
          Left err -> Left (renderEncryptedObjectError err)
          Right Nothing -> Right AuthorityObjectMissing
          Right (Just versioned) ->
            Right
              ( AuthorityObjectObserved
                  (objectVersionEtag (versionedLogicalStoreVersion versioned))
                  (versionedLogicalBytes versioned)
              )

compareAndSwapDaemonAuthorityObject
  :: DaemonEnv
  -> AuthorityObjectCasRequest
  -> IO (Either String AuthorityObjectCasResponse)
compareAndSwapDaemonAuthorityObject env request = do
  materialResult <- resolveDaemonPulumiObjectMaterial env
  case materialResult of
    Left err -> pure (Left err)
    Right material ->
      withGatewayChild env "authority-object-cas" $ do
        let logicalObject = authorityLogicalObject (authorityObjectCasLogicalName request)
            store = daemonPulumiObjectStore material
            cipher = daemonPulumiCipher material
            hmacKey = daemonPulumiHmacKey material
            clusterId = daemonPulumiClusterId material
            payload = authorityObjectCasPayload request
        guardResult <-
          case authorityObjectCasLeaseGuard request of
            Nothing -> pure (Right ())
            Just guard -> validateDaemonAuthorityLeaseGuard material guard
        case guardResult of
          Left err -> pure (Left err)
          Right () -> do
            casResult <-
              case authorityObjectCasExpectedVersion request of
                Nothing -> putLogicalIfAbsent store cipher hmacKey clusterId logicalObject payload
                Just version ->
                  putLogicalIfVersion
                    store
                    cipher
                    hmacKey
                    clusterId
                    logicalObject
                    (ObjectVersion version)
                    payload
            case casResult of
              Left err -> pure (Left (renderEncryptedObjectError err))
              Right disposition -> do
                observed <-
                  getLogicalVersioned store cipher hmacKey clusterId logicalObject
                pure $ case observed of
                  Left err -> Left (renderEncryptedObjectError err)
                  Right maybeVersioned -> do
                    observation <- authorityObservationFromVersioned maybeVersioned
                    case disposition of
                      LogicalConditionalPutApplied ->
                        case observation of
                          AuthorityObjectMissing ->
                            Left "authority CAS applied but mandatory re-observation was missing"
                          AuthorityObjectObserved version _ ->
                            Right (AuthorityObjectCasApplied version)
                      LogicalConditionalPutConflict ->
                        Right (AuthorityObjectCasConflict observation)

validateDaemonAuthorityLeaseGuard
  :: DaemonPulumiObjectMaterial
  -> AuthorityObjectLeaseGuard
  -> IO (Either String ())
validateDaemonAuthorityLeaseGuard material guard = do
  observed <-
    getLogicalVersioned
      (daemonPulumiObjectStore material)
      (daemonPulumiCipher material)
      (daemonPulumiHmacKey material)
      (daemonPulumiClusterId material)
      (authorityLogicalObject (authorityLeaseGuardLogicalName guard))
  now <- getCurrentTime
  pure $ case observed of
    Left err -> Left ("lease guard observation failed: " ++ renderEncryptedObjectError err)
    Right Nothing -> Left "lease guard rejected: lease projection is missing"
    Right (Just versioned)
      | objectVersionEtag (versionedLogicalStoreVersion versioned)
          /= authorityLeaseGuardExpectedVersion guard ->
          Left "lease guard rejected: lease object version changed"
      | otherwise -> do
          projection <-
            case decodeLeaseProjection
              defaultSesLeasePolicy
              (versionedLogicalBytes versioned) of
              Left err -> Left ("lease guard rejected: invalid lease projection: " ++ show err)
              Right value -> Right value
          grant <-
            case leaseProjectionActiveGrant projection of
              Nothing -> Left "lease guard rejected: lease has no active grant"
              Just value -> Right value
          if leaseLogicalName (leaseGrantKey grant) /= authorityLeaseGuardLogicalName guard
            then Left "lease guard rejected: lease key does not match its object coordinate"
            else
              if ownerNonceText (leaseGrantOwnerNonce grant)
                /= authorityLeaseGuardOwnerNonce guard
                then Left "lease guard rejected: owner nonce changed"
                else
                  if fencingTokenValue (leaseGrantFencingToken grant)
                    /= authorityLeaseGuardFencingToken guard
                    then Left "lease guard rejected: fencing token changed"
                    else
                      if authorityTimeFromMicros (authorityMicrosFromUtc now)
                        >= leaseGrantSafeUseDeadline grant
                        then Left "lease guard rejected: lease safe-use deadline has expired"
                        else Right ()

authorityObservationFromVersioned
  :: Maybe VersionedLogicalObject -> Either String AuthorityObjectObservation
authorityObservationFromVersioned maybeVersioned =
  case maybeVersioned of
    Nothing -> Right AuthorityObjectMissing
    Just versioned ->
      Right
        ( AuthorityObjectObserved
            (objectVersionEtag (versionedLogicalStoreVersion versioned))
            (versionedLogicalBytes versioned)
        )

authorityLogicalObject :: Text.Text -> LogicalObject
authorityLogicalObject logicalName =
  case Text.stripPrefix "pulumi-stack/" logicalName of
    Just stackName -> LogicalPulumiStack stackName
    Nothing -> LogicalLongLivedState logicalName

deleteDaemonPulumiObject :: DaemonEnv -> Text.Text -> IO (Either String ())
deleteDaemonPulumiObject env stackName = do
  materialResult <- resolveDaemonPulumiObjectMaterial env
  case materialResult of
    Left err -> pure (Left err)
    Right material ->
      withGatewayChild env "pulumi-object-delete" $ do
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
--
-- LEGACY-ESCAPE[per-request-operator-secret-vault-login]: a second gateway
-- fresh Vault Kubernetes-auth login, distinct from resolveGatewayVaultTokenFor,
-- performed on every operator-secret write. Registered in
-- Prodbox.Legacy.EscapeRegistry; folded onto the cached session in Sprint 1.64.
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
  rest <- stripPrefix federationChildPathPrefix path
  let suffix = federationChildBootstrapSuffix
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
resolveGatewayVaultToken =
  resolveGatewayVaultTokenFor "federation inventory unavailable"

resolveTargetSecretVaultToken
  :: DaemonConfig -> IO (Either String (VaultAddress, VaultToken))
resolveTargetSecretVaultToken =
  resolveGatewayVaultTokenFor "target-secret unavailable"

resolveTargetSecretVaultSession :: DaemonConfig -> IO (Either String VaultSession)
resolveTargetSecretVaultSession =
  resolveGatewayVaultSessionFor "target-secret unavailable"

-- | Sprint 1.64: the gateway daemon's own service-account Vault token is now
-- served from the shared cached renewable session in "Prodbox.Vault.Session"
-- rather than a fresh Kubernetes login on every request (counterexample
-- @LCPC-2026-07-11@'s gateway hot-path CPU driver). The session caches the
-- token, renews it single-flight at two-thirds of the lease, and — through
-- 'withSessionToken' — reacts to a @403@ with one invalidate-and-relogin.
resolveGatewayVaultTokenFor
  :: String
  -> DaemonConfig
  -> IO (Either String (VaultAddress, VaultToken))
resolveGatewayVaultTokenFor label config = do
  sessionResult <- resolveGatewayVaultSessionFor label config
  case sessionResult of
    Left err -> pure (Left err)
    Right session -> do
      tokenResult <- sessionToken session
      pure $ case tokenResult of
        Left sessionErr ->
          Left (label ++ ": Vault Kubernetes auth failed: " ++ renderVaultSessionError sessionErr)
        Right token -> Right (sessionAddress session, token)

-- | Look up (or lazily create) the shared cached session for the gateway
-- daemon's own service-account role. The login effect re-reads the current
-- service-account JWT on every refresh, so token rotation is honored.
resolveGatewayVaultSessionFor
  :: String -> DaemonConfig -> IO (Either String VaultSession)
resolveGatewayVaultSessionFor label config =
  case daemonVaultAuth config of
    Nothing ->
      pure (Left (label ++ ": gateway Vault auth is not configured"))
    Just auth -> do
      let address = VaultAddress (Text.pack (gatewayVaultAddress auth))
          key =
            GatewaySessionKey
              { gatewaySessionAddress = gatewayVaultAddress auth
              , gatewaySessionAuthPath = gatewayVaultAuthPath auth
              , gatewaySessionRole = gatewayVaultRole auth
              }
          login = do
            jwtResult <-
              readGatewayServiceAccountTokenFor
                label
                (gatewayVaultServiceAccountTokenFile auth)
            case jwtResult of
              Left err -> pure (Left (VaultSessionUnavailable err))
              Right jwt -> do
                loginResult <-
                  vaultKubernetesLoginWithLease
                    address
                    (Text.pack (gatewayVaultAuthPath auth))
                    (Text.pack (gatewayVaultRole auth))
                    jwt
                pure $ case loginResult of
                  Left httpErr -> Left (httpErrorToSessionError httpErr)
                  Right result ->
                    Right
                      LoginLease
                        { loginLeaseToken = vaultLoginToken result
                        , loginLeaseSeconds = vaultLoginLeaseSeconds result
                        , loginLeaseRenewable = vaultLoginRenewable result
                        }
      session <-
        resolveSharedSession key (\_ -> newVaultSession address realSessionClock login)
      pure (Right session)

readGatewayServiceAccountTokenFor
  :: String -> FilePath -> IO (Either String Text.Text)
readGatewayServiceAccountTokenFor label path = do
  result <- try (TextIO.readFile path) :: IO (Either SomeException Text.Text)
  pure $ case result of
    Left exc ->
      Left
        ( label
            ++ ": failed to read gateway service-account token: "
            ++ displayException exc
        )
    Right rawToken ->
      let token = Text.strip rawToken
       in if Text.null token
            then Left (label ++ ": gateway service-account token is empty")
            else Right token

renderMetricsText :: UTCTime -> DaemonEnv -> DaemonState -> String
renderMetricsText now env state =
  unlines
    [ "# TYPE prodbox_gateway_signed_replay_assertions gauge"
    , "prodbox_gateway_signed_replay_assertions{daemon=\""
        ++ metricsDaemonName (envMetrics env)
        ++ "\"} "
        ++ show (sum (map length (Map.elems (stateSignedReplay state))))
    , "# TYPE prodbox_gateway_semantic_members gauge"
    , "prodbox_gateway_semantic_members{daemon=\""
        ++ metricsDaemonName (envMetrics env)
        ++ "\"} "
        ++ show (BoundedState.gatewayStateEmitterCount (stateBoundedGateway state))
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
    acceptWhileServing
      (gatewayMaxInFlightFramesPerPeer (envGatewayBounds env))
      False
      sock
      env
      (`handlePeerClient` env)

-- | Accept loop shared by both listeners (REST and peer-events). Sprint
-- 2.25: one accept producer feeds a fixed-size 'replicateConcurrently' worker
-- pool. A separate slot queue bounds accepted plus active connections exactly
-- at @maxConnections@; it also lets a peer listener waiting at capacity wake
-- immediately when drain begins. 'race' gives the producer and pool one
-- structured lifetime: when the producer returns for drain, every active
-- handler is cancelled and awaited before the listener scope returns.
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
acceptWhileServing :: Int -> Bool -> Socket -> DaemonEnv -> (Socket -> IO ()) -> IO ()
acceptWhileServing maxConnections allowDuringDrain sock env handleClient = do
  let workerCount = max 1 maxConnections
  connectionQueue <- newTQueueIO
  connectionSlots <- newTBQueueIO (fromIntegral workerCount)
  atomically $
    replicateM_ workerCount (writeTBQueue connectionSlots ())
  void
    ( race
        (acceptConnections connectionQueue connectionSlots)
        (void (replicateConcurrently workerCount (connectionWorker connectionQueue connectionSlots)))
    )
    `finally` closeQueuedConnections connectionQueue
 where
  acceptConnections connectionQueue connectionSlots = do
    drainPhase <- readTVarIO (envDrainPhase env)
    case drainPhase of
      PhaseDraining
        | not allowDuringDrain -> pure ()
      _ -> do
        maybeReadable <- waitForSocketRead sock
        case maybeReadable of
          Nothing -> acceptConnections connectionQueue connectionSlots
          Just () -> do
            slotAcquired <- acquireConnectionSlot connectionSlots
            if slotAcquired
              then do
                enqueueAcceptedConnection connectionQueue connectionSlots
                acceptConnections connectionQueue connectionSlots
              else pure ()

  acquireConnectionSlot connectionSlots
    | allowDuringDrain =
        atomically (readTBQueue connectionSlots >> pure True)
    | otherwise =
        atomically (stopForDrain `orElse` acquireSlot)
   where
    stopForDrain = do
      drainPhase <- readTVar (envDrainPhase env)
      if drainPhase == PhaseDraining then pure False else retry
    acquireSlot = readTBQueue connectionSlots >> pure True

  enqueueAcceptedConnection connectionQueue connectionSlots =
    bracketOnError
      (pure ())
      (const (releaseConnectionSlot connectionSlots))
      (const acceptAndEnqueue)
   where
    acceptAndEnqueue =
      bracketOnError
        (fst <$> accept sock)
        close
        (atomically . writeTQueue connectionQueue)

  connectionWorker connectionQueue connectionSlots = forever $ do
    clientSock <- atomically (readTQueue connectionQueue)
    serveConnection clientSock
      `finally` releaseConnectionSlot connectionSlots

  serveConnection clientSock = do
    outcome <-
      try
        ( withFramePermit env (handleClient clientSock)
            `finally` close clientSock
        )
        :: IO (Either SomeException ())
    case outcome of
      Right () -> pure ()
      Left exc ->
        case fromException exc :: Maybe SomeAsyncException of
          Just _ -> throwIO exc
          Nothing ->
            logForEnv env Warn "connection_handler_error" [field "detail" (displayException exc)]

  releaseConnectionSlot connectionSlots =
    atomically (writeTBQueue connectionSlots ())

  closeQueuedConnections connectionQueue = do
    queued <- atomically (drainQueue connectionQueue)
    mapM_ closeQuietly queued

  drainQueue connectionQueue = do
    maybeSocket <- tryReadTQueue connectionQueue
    case maybeSocket of
      Nothing -> pure []
      Just queuedSocket -> (queuedSocket :) <$> drainQueue connectionQueue

  closeQuietly queuedSocket = do
    _ <- try (close queuedSocket) :: IO (Either IOException ())
    pure ()

withFramePermit :: DaemonEnv -> IO value -> IO value
withFramePermit env =
  bracket_
    (atomically (readTBQueue (envFramePermits env)))
    (atomically (writeTBQueue (envFramePermits env) ()))

-- | Read an inbound request bounded by the configured per-connection read
-- timeout. Returns the bytes read on success; returns 'Nothing' (a benign
-- sentinel the caller treats as a dropped connection) when the read does not
-- complete within 'liveConnectionReadTimeoutSeconds'. This is where the
-- Sprint 2.25 bounded read timeout is actually enforced — at the socket read
-- that a stalled peer would otherwise block forever.
receiveAllWithin :: DaemonEnv -> Int -> Socket -> IO (Maybe BS.ByteString)
receiveAllWithin env maxBodyBytes sock = do
  liveConfig <- readTVarIO (envLiveConfig env)
  let timeoutMicros = readTimeoutMicros (liveConnectionReadTimeoutSeconds liveConfig)
  outcome <- timeout timeoutMicros (receiveAllBounded maxBodyBytes sock)
  case outcome of
    Just (Right raw) -> pure (Just raw)
    Just (Left err) -> do
      logForEnv env Warn "connection_request_rejected" [field "detail" err]
      pure Nothing
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
handlePeerClient sock env =
  ignoreSynchronousConnectionFailure handleOne
 where
  handleOne = do
    envOnPeerConnectionEstablished (envHooks env) "inbound"
    maybeRaw <-
      receiveAllWithin
        env
        (fromIntegral (gatewayMaxFrameBytes (envGatewayBounds env)))
        sock
    for_ maybeRaw handleParsedPeerRequest

  handleParsedPeerRequest raw =
    case parsePeerHttpRequest (envGatewayBounds env) raw of
      Left err -> do
        sendPeerTransportResponse sock env (peerErrorResponse err)
      Right request -> do
        now <- getCurrentTime
        for_ (peerRequestOrdersVersion request) $ \observedVersion ->
          atomically $ modifyTVar' (envState env) $ \state ->
            state
              { stateLatestObservedOrdersVersion =
                  max
                    (stateLatestObservedOrdersVersion state)
                    ( if observedVersion > fromIntegral (maxBound :: Int)
                        then maxBound
                        else fromIntegral observedVersion
                    )
              }
        liveConfig <- readTVarIO (envLiveConfig env)
        let nowSeconds =
              fromIntegral
                (max 0 (floor (utcTimeToPOSIXSeconds now) :: Integer))
                :: Word64
            maximumSkew =
              fromIntegral
                (max 0 (floor (liveMaxClockSkewSeconds liveConfig) :: Integer))
                :: Word64
        case validatePeerRequestHeartbeatSkew nowSeconds maximumSkew request of
          Left err ->
            sendPeerTransportResponse sock env (peerErrorResponse err)
          Right () -> do
            (appliedCount, response) <- atomically $ do
              before <- readTVar (envState env)
              case handlePeerRequest
                (envGatewayBounds env)
                (gatewayEventKeyLookup env)
                request
                (stateBoundedGateway before) of
                Left err -> pure (0, peerErrorResponse err)
                Right (boundedAfter, acceptedResponse) -> do
                  let applied =
                        changedEmitterCount
                          (envValidatedOrders env)
                          (stateBoundedGateway before)
                          boundedAfter
                      withProjection =
                        refreshBoundedPeerObservations
                          env
                          now
                          (stateBoundedGateway before)
                          boundedAfter
                          before {stateBoundedGateway = boundedAfter}
                      retainedAssertions =
                        boundedSignedAssertionsToList
                          (peerRequestSnapshotEvidence request)
                          ++ boundedSignedAssertionsToList
                            (peerRequestReplayAssertions request)
                      withSnapshotPruned =
                        case peerRequestSemanticSnapshot request of
                          Nothing -> withProjection
                          Just snapshot ->
                            pruneSignedReplayAtCheckpoint
                              env
                              (Text.unpack (signedSemanticSnapshotEmitter snapshot))
                              withProjection
                      after
                        | peerResponseAccepted acceptedResponse =
                            retainSignedAssertions env retainedAssertions withSnapshotPruned
                        | otherwise = withProjection
                  writeTVar (envState env) after
                  pure (applied, acceptedResponse)
            envAfterPeerEventCommit (envHooks env) appliedCount
            sendPeerTransportResponse sock env response

sendPeerTransportResponse
  :: Socket
  -> DaemonEnv
  -> PeerTransportResponse
  -> IO ()
sendPeerTransportResponse sock env response =
  case renderPeerHttpResponse (envGatewayBounds env) response of
    Right bytes -> sendAll sock bytes
    Left err ->
      case renderPeerHttpResponse
        (envGatewayBounds env)
        (peerErrorResponse err) of
        Right bytes -> sendAll sock bytes
        Left _ ->
          sendAll
            sock
            "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

-- | Read one HTTP request with fixed header and body ceilings.  The
-- Content-Length value is checked as soon as the bounded header is complete,
-- before any further body read or accumulation occurs.
receiveAllBounded :: Int -> Socket -> IO (Either String BS.ByteString)
receiveAllBounded maxBodyBytes sock = readHeaders BS.empty
 where
  maxHeaderBytes = 16 * 1024

  readHeaders accumulated = do
    chunk <- recv sock 4096
    if BS.null chunk
      then pure (Left "connection closed before HTTP headers completed")
      else do
        let candidate = accumulated <> chunk
        case splitHttpHeaders candidate of
          Nothing
            | BS.length candidate > maxHeaderBytes ->
                pure (Left "HTTP request headers exceed 16384 bytes")
            | otherwise -> readHeaders candidate
          Just (headersWithDelimiter, initialBody) ->
            case contentLengthFromHeaders headersWithDelimiter of
              Left err -> pure (Left err)
              Right Nothing
                | BS.null initialBody -> pure (Right headersWithDelimiter)
                | otherwise -> pure (Left "HTTP request without Content-Length carried a body")
              Right (Just expected)
                | expected > maxBodyBytes ->
                    pure
                      ( Left
                          ( "HTTP Content-Length exceeds bound: "
                              ++ show expected
                              ++ " > "
                              ++ show maxBodyBytes
                          )
                      )
                | BS.length initialBody > expected ->
                    pure (Left "HTTP request body exceeds declared Content-Length")
                | otherwise ->
                    readBody headersWithDelimiter expected [initialBody] (BS.length initialBody)

  readBody headers expected reversedChunks received
    | received == expected =
        pure (Right (headers <> BS.concat (reverse reversedChunks)))
    | otherwise = do
        chunk <- recv sock (min 16384 (expected - received))
        if BS.null chunk
          then pure (Left "connection closed before declared HTTP body completed")
          else readBody headers expected (chunk : reversedChunks) (received + BS.length chunk)

splitHttpHeaders :: BS.ByteString -> Maybe (BS.ByteString, BS.ByteString)
splitHttpHeaders input =
  firstMatch "\r\n\r\n" `firstJust` firstMatch "\n\n"
 where
  firstMatch delimiter =
    let marker = BS8.pack delimiter
        (headers, rest) = BS.breakSubstring marker input
     in if marker `BS.isPrefixOf` rest
          then
            Just
              ( headers <> marker
              , BS.drop (BS.length marker) rest
              )
          else Nothing
  firstJust (Just value) _ = Just value
  firstJust Nothing fallback = fallback

contentLengthFromHeaders :: BS.ByteString -> Either String (Maybe Int)
contentLengthFromHeaders raw =
  case values of
    [] -> Right Nothing
    [value] ->
      case reads value of
        [(parsed, trailing)]
          | all isSpace trailing && parsed >= 0 -> Right (Just parsed)
        _ -> Left "invalid HTTP Content-Length"
    _ -> Left "duplicate HTTP Content-Length headers"
 where
  values =
    [ dropWhile isSpace (drop (length prefix) lowerLine)
    | line <- lines (map replaceCr (BS8.unpack raw))
    , let lowerLine = map toLower line
    , prefix `isPrefixOf` lowerLine
    ]
  prefix = "content-length:"
  replaceCr character = if character == '\r' then ' ' else character

changedEmitterCount
  :: BoundedState.ValidatedOrders
  -> BoundedState.GatewayState
  -> BoundedState.GatewayState
  -> Int
changedEmitterCount orders before after =
  length
    [ ()
    | emitter <- BoundedState.validatedOrdersMemberIds orders
    , BoundedState.cursorVectorLookup emitter beforeCursor
        /= BoundedState.cursorVectorLookup emitter afterCursor
    ]
 where
  beforeCursor = BoundedState.gatewayStateCursorVector before
  afterCursor = BoundedState.gatewayStateCursorVector after

-- | Project the bounded semantic fold onto the daemon's operator-facing
-- heartbeat/skew/link fields.  The traversal is exactly the validated Orders
-- membership bound and never touches replay history.
refreshBoundedPeerObservations
  :: DaemonEnv
  -> UTCTime
  -> BoundedState.GatewayState
  -> BoundedState.GatewayState
  -> DaemonState
  -> DaemonState
refreshBoundedPeerObservations env now before after initial =
  Prelude.foldr refreshEmitter initial memberIds
 where
  refreshEmitter emitter state =
    let emitterName = Text.unpack (BoundedState.nodeIdText emitter)
        beforeCursor =
          BoundedState.cursorVectorLookup
            emitter
            (BoundedState.gatewayStateCursorVector before)
        afterCursor =
          BoundedState.cursorVectorLookup
            emitter
            (BoundedState.gatewayStateCursorVector after)
        changed = beforeCursor /= afterCursor
        beforeHeartbeat = BoundedState.gatewayStateLatestHeartbeat emitter before
        afterHeartbeat = BoundedState.gatewayStateLatestHeartbeat emitter after
        withInbound
          | changed && emitterName /= daemonNodeId (envBootConfig env) =
              state
                { statePeerHealth =
                    Map.alter
                      (markPeerHealthInbound now)
                      emitterName
                      (statePeerHealth state)
                }
          | otherwise = state
     in case afterHeartbeat >>= heartbeatTimestamp of
          Nothing -> withInbound
          Just timestamp ->
            let withHeartbeat =
                  withInbound
                    { stateLastHeartbeatTimes =
                        Map.insertWith
                          max
                          emitterName
                          timestamp
                          (stateLastHeartbeatTimes withInbound)
                    }
             in if afterHeartbeat == beforeHeartbeat
                  then withHeartbeat
                  else
                    let skew = abs (realToFrac (diffUTCTime now timestamp) :: Double)
                     in withHeartbeat
                          { stateMaxObservedSkewSeconds =
                              Just
                                ( maybe
                                    skew
                                    (max skew)
                                    (stateMaxObservedSkewSeconds withHeartbeat)
                                )
                          }

  heartbeatTimestamp assertion =
    case BoundedState.assertionKind assertion of
      BoundedState.HeartbeatAssertion timestamp ->
        Just (posixSecondsToUTCTime (fromIntegral timestamp))
      _ -> Nothing

  memberIds = BoundedState.validatedOrdersMemberIds (envValidatedOrders env)

markPeerHealthInbound :: UTCTime -> Maybe PeerHealth -> Maybe PeerHealth
markPeerHealthInbound now maybeHealth =
  case maybeHealth of
    Nothing -> Just (PeerHealth (Just now) False Nothing)
    Just health -> Just health {peerHealthLastInboundEvent = Just now}

-- | Periodically exchange a bounded cursor and at most one bounded delta
-- frame with every peer.  A complete append-only event log is never built or
-- retransmitted.
peerDialerLoop :: DaemonEnv -> IO ()
peerDialerLoop env = forever $ do
  let config = envBootConfig env
      orders = envOrders env
      nodeId = daemonNodeId config
      peers = [p | p <- ordersNodes orders, peerNodeId p /= nodeId]
  mapM_ (pushToPeer env) peers
  liveConfig <- readTVarIO (envLiveConfig env)
  threadDelay (round (liveReconnectInterval liveConfig * 1000000))

pushToPeer :: DaemonEnv -> PeerEndpoint -> IO ()
pushToPeer env peer = do
  let host = peerDialSocketHost peer
      port = peerSocketPort peer
      peerHost = Text.pack (host ++ ":" ++ show port)
      stateVar = envState env
      bounds = envGatewayBounds env
  cursorRequest <- pure (either (Left . show) Right (renderPeerCursorRequest peerHost))
  cursorResult <-
    case cursorRequest of
      Left err -> pure (Left err)
      Right request -> exchangePeerRequest env host port request
  case cursorResult of
    Left err -> markPeerError stateVar (peerNodeId peer) err
    Right cursorResponse ->
      case peerResponseCursorVector
        bounds
        (envValidatedOrders env)
        cursorResponse of
        Left err -> markPeerError stateVar (peerNodeId peer) (show err)
        Right Nothing ->
          markPeerError stateVar (peerNodeId peer) "peer cursor response omitted its cursor"
        Right (Just peerCursor) -> do
          atomically $ modifyTVar' stateVar $ \state ->
            state
              { statePeerCursors =
                  Map.insert
                    (peerNodeId peer)
                    peerCursor
                    (statePeerCursors state)
              }
          dispatchPeerCursor env peer peerHost peerCursor True

dispatchPeerCursor
  :: DaemonEnv
  -> PeerEndpoint
  -> Text.Text
  -> BoundedState.CursorVector
  -> Bool
  -> IO ()
dispatchPeerCursor env peer peerHost peerCursor allowRepair = do
  state <- readTVarIO (envState env)
  let bounds = envGatewayBounds env
      orders = envValidatedOrders env
      retained = concat (Map.elems (stateSignedReplay state))
      stateVar = envState env
  case selectSignedDelta bounds orders peerCursor retained of
    Left (PeerSignedReplayUnavailable emitter _ _)
      | allowRepair ->
          sendPeerRepair
            env
            peer
            peerHost
            peerCursor
            emitter
            retained
            state
    Left err -> markPeerError stateVar (peerNodeId peer) (show err)
    Right frame ->
      case renderPeerDeltaRequest bounds peerHost frame of
        Left err -> markPeerError stateVar (peerNodeId peer) (show err)
        Right request -> do
          result <-
            exchangePeerRequest
              env
              (peerDialSocketHost peer)
              (peerSocketPort peer)
              request
          recordPeerExchange env peer "bounded delta" result

sendPeerRepair
  :: DaemonEnv
  -> PeerEndpoint
  -> Text.Text
  -> BoundedState.CursorVector
  -> BoundedState.NodeId
  -> [SignedAssertion]
  -> DaemonState
  -> IO ()
sendPeerRepair env peer peerHost peerCursor emitter retained state =
  case ( BoundedState.gatewayStateEmitterCheckpoint
           emitter
           (stateBoundedGateway state)
       , gatewayEventKeyLookup env emitter
       ) of
    (Nothing, _) ->
      markPeerError stateVar peerName "bounded emitter checkpoint is unavailable"
    (_, Nothing) ->
      markPeerError stateVar peerName "event-key authority is unavailable for checkpoint repair"
    (Just checkpoint, Just eventKey) ->
      let emitterName = Text.unpack (BoundedState.nodeIdText emitter)
          heartbeat = Map.lookup emitterName (stateSignedCheckpointHeartbeat state)
          ownership = Map.lookup emitterName (stateSignedCheckpointOwnership state)
       in case selectSignedRepairFromCheckpoint
            bounds
            (envValidatedOrders env)
            peerCursor
            checkpoint
            heartbeat
            ownership
            eventKey
            retained of
            Left err -> markPeerError stateVar peerName (show err)
            Right repair ->
              case renderPeerRepairRequest bounds peerHost repair of
                Left err -> markPeerError stateVar peerName (show err)
                Right request -> do
                  result <-
                    exchangePeerRequest
                      env
                      (peerDialSocketHost peer)
                      (peerSocketPort peer)
                      request
                  case result of
                    Left err -> markPeerError stateVar peerName err
                    Right response -> do
                      updatePeerCursorFromResponse env peer response
                      if peerResponseAccepted response
                        then case peerResponseCursorVector
                          bounds
                          (envValidatedOrders env)
                          response of
                          Right (Just repairedCursor) ->
                            dispatchPeerCursor env peer peerHost repairedCursor False
                          _ ->
                            markPeerError
                              stateVar
                              peerName
                              "peer repair response omitted its cursor"
                        else markPeerError stateVar peerName "peer rejected bounded repair"
 where
  bounds = envGatewayBounds env
  stateVar = envState env
  peerName = peerNodeId peer

recordPeerExchange
  :: DaemonEnv
  -> PeerEndpoint
  -> String
  -> Either String PeerTransportResponse
  -> IO ()
recordPeerExchange env peer frameLabel result =
  case result of
    Left err -> markPeerError stateVar peerName err
    Right response -> do
      updatePeerCursorFromResponse env peer response
      if peerResponseAccepted response
        then markPeerOk stateVar peerName
        else markPeerError stateVar peerName ("peer rejected " ++ frameLabel)
 where
  stateVar = envState env
  peerName = peerNodeId peer

updatePeerCursorFromResponse
  :: DaemonEnv
  -> PeerEndpoint
  -> PeerTransportResponse
  -> IO ()
updatePeerCursorFromResponse env peer response =
  case peerResponseCursorVector
    (envGatewayBounds env)
    (envValidatedOrders env)
    response of
    Right (Just cursor) ->
      atomically $ modifyTVar' (envState env) $ \state ->
        state
          { statePeerCursors =
              Map.insert
                (peerNodeId peer)
                cursor
                (statePeerCursors state)
          }
    _ -> pure ()

exchangePeerRequest
  :: DaemonEnv
  -> String
  -> Int
  -> ByteString
  -> IO (Either String PeerTransportResponse)
exchangePeerRequest env host port request = do
  rawResult <-
    try (dialAndReceiveBounded env host port request)
      :: IO (Either SomeException (Either String ByteString))
  pure $ do
    raw <- either (Left . displayException) id rawResult
    either (Left . show) Right (parsePeerHttpResponse (envGatewayBounds env) raw)

dialAndReceiveBounded
  :: DaemonEnv
  -> String
  -> Int
  -> ByteString
  -> IO (Either String ByteString)
dialAndReceiveBounded env host port request = do
  liveConfig <- readTVarIO (envLiveConfig env)
  outcome <-
    timeout
      (readTimeoutMicros (liveConnectionReadTimeoutSeconds liveConfig))
      dial
  pure (fromMaybe (Left "peer exchange timed out") outcome)
 where
  dial = do
    addresses <- getAddrInfo Nothing (Just host) (Just (show port))
    case addresses of
      [] -> pure (Left ("no address resolution for " ++ host))
      info : _ -> do
        sock <- socket (addrFamily info) (addrSocketType info) (addrProtocol info)
        ( do
            connect sock (addrAddress info)
            sendAll sock request
            receiveAllBounded
              (fromIntegral (gatewayMaxFrameBytes (envGatewayBounds env)))
              sock
          )
          `finally` close sock

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

gatewayDnsWriteReady :: DaemonEnv -> DaemonState -> IO Bool
gatewayDnsWriteReady env state =
  case (daemonDnsWriteGate config, daemonAwsCreds config) of
    (Just _, Just credentials) -> do
      result <- dnsWriteAuthority env state credentials
      pure (either (const False) (const True) result)
    _ -> pure False
 where
  config = envBootConfig env

readContinuityDiagnostic :: DaemonEnv -> IO ContinuityDiagnostic
readContinuityDiagnostic env = do
  runtime <- readTVarIO (envContinuity env)
  case runtime of
    Nothing -> pure ContinuityDiagnosticUnavailable
    Just active -> do
      current <- readTVarIO (continuityRuntimeCurrent active)
      pure (ContinuityDiagnosticReady (Continuity.currentContinuityAnchor current))

renderStateJson
  :: UTCTime
  -> DaemonEnv
  -> Bool
  -> ContinuityDiagnostic
  -> DaemonState
  -> BL.ByteString
renderStateJson now env dnsReady continuityDiagnostic state =
  encode $
    object
      [ "node_id" .= daemonNodeId config
      , "gateway_owner" .= stateGatewayOwner state
      , "previous_owner" .= statePreviousOwner state
      , "has_active_claim"
          .= ( stateGatewayOwner state == Just (daemonNodeId config)
                 && boundedNodeDisposition env state (daemonNodeId config) == DispositionOwner
             )
      , "can_write_dns" .= dnsReady
      , "node_disposition"
          .= renderDisposition (boundedNodeDisposition env state (daemonNodeId config))
      , "peer_dispositions" .= renderPeerDispositions env state
      , "mesh_peers" .= stateMeshPeers state
      , "semantic_member_count"
          .= BoundedState.gatewayStateEmitterCount (stateBoundedGateway state)
      , "signed_replay_assertion_count"
          .= sum (map length (Map.elems (stateSignedReplay state)))
      , "retained_assertion_count" .= retainedAssertionCount state
      , "retained_assertion_capacity"
          .= ( BoundedState.validatedOrdersMemberCount (envValidatedOrders env)
                 * (gatewayReplayPerEmitter (envGatewayBounds env) + 2)
             )
      , "recent_assertion_hashes"
          .= map
            (hexText . BoundedState.eventHashBytes)
            (BoundedState.gatewayStateDiagnosticHashes (stateBoundedGateway state))
      , "peer_receive_cursors" .= renderPeerReceiveCursors env state
      , "continuity_authority" .= renderContinuityDiagnostic continuityDiagnostic
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
 where
  config = envBootConfig env

retainedAssertionCount :: DaemonState -> Int
retainedAssertionCount state =
  sum (map length (Map.elems (stateSignedReplay state)))
    + Map.size (stateSignedCheckpointHeartbeat state)
    + Map.size (stateSignedCheckpointOwnership state)

renderPeerReceiveCursors :: DaemonEnv -> DaemonState -> Value
renderPeerReceiveCursors env state =
  Object $
    KeyMap.fromList
      [ (Key.fromString peerName, renderCursorVector cursor)
      | (peerName, cursor) <- Map.toAscList (statePeerCursors state)
      ]
 where
  renderCursorVector cursor =
    Object $
      KeyMap.fromList
        [ ( Key.fromText (BoundedState.nodeIdText emitter)
          , maybe Null renderEmitterCursor (BoundedState.cursorVectorLookup emitter cursor)
          )
        | emitter <- BoundedState.validatedOrdersMemberIds (envValidatedOrders env)
        ]

  renderEmitterCursor cursor =
    object
      [ "epoch"
          .= BoundedState.emitterEpochValue
            (BoundedState.emitterCursorEpoch cursor)
      , "sequence"
          .= BoundedState.emitterSequenceValue
            (BoundedState.emitterCursorSequence cursor)
      , "digest"
          .= hexText
            ( BoundedState.eventHashBytes
                (BoundedState.emitterCursorHash cursor)
            )
      ]

renderContinuityDiagnostic :: ContinuityDiagnostic -> Value
renderContinuityDiagnostic diagnostic =
  case diagnostic of
    ContinuityDiagnosticUnavailable ->
      object ["status" .= ("unavailable" :: Text.Text)]
    ContinuityDiagnosticReady anchor ->
      object
        [ "status" .= ("ready" :: Text.Text)
        , "epoch" .= Continuity.continuityAnchorEpoch anchor
        , "sequence" .= Continuity.continuityAnchorSequence anchor
        , "digest"
            .= hexText
              ( Continuity.continuityDigestBytes
                  (Continuity.continuityAnchorPreviousDigest anchor)
              )
        ]

renderDisposition :: Disposition -> Value
renderDisposition d = case d of
  DispositionOwner -> String "owner"
  DispositionYielded -> String "yielded"
  DispositionUnknown -> String "unknown"

renderPeerDispositions :: DaemonEnv -> DaemonState -> Value
renderPeerDispositions env state =
  Object $
    KeyMap.fromList
      [ (Key.fromString peer, renderDisposition (boundedNodeDisposition env state peer))
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

-- | Interpret a Route 53 write only from the opaque credential/continuity/
-- claim authority witness.  The child receives a sealed environment built
-- from an empty base; ambient AWS profiles and metadata are unreachable.
writeDnsRecord
  :: DnsAuthority.DnsWriteAction
  -> IO (Either String ())
writeDnsRecord action = do
  let changeBatch =
        BL8.unpack $
          encode $
            object
              [ "Changes"
                  .= [ object
                         [ "Action" .= ("UPSERT" :: String)
                         , "ResourceRecordSet"
                             .= object
                               [ "Name" .= DnsAuthority.dnsWriteActionFqdn action
                               , "Type" .= ("A" :: String)
                               , "TTL" .= DnsAuthority.dnsWriteActionTtl action
                               , "ResourceRecords"
                                   .= [object ["Value" .= DnsAuthority.dnsWriteActionIpv4 action]]
                               ]
                         ]
                     ]
              ]
      subprocessEnv = DnsAuthority.dnsWriteActionAwsEnvironment action
  executable <- findExecutable "aws"
  case executable of
    Nothing -> pure (Left "aws cli executable is unavailable")
    Just awsPath -> do
      result <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = awsPath
            , subprocessArguments =
                [ "route53"
                , "change-resource-record-sets"
                , "--hosted-zone-id"
                , Text.unpack (DnsAuthority.dnsWriteActionZoneId action)
                , "--change-batch"
                , changeBatch
                , "--region"
                , Text.unpack (DnsAuthority.dnsWriteActionRegion action)
                ]
            , subprocessEnvironment = Just subprocessEnv
            , subprocessWorkingDirectory = Nothing
            }
      case result of
        Failure err -> pure (Left ("aws cli failed: " ++ err))
        Success output ->
          case processExitCode output of
            ExitSuccess -> pure (Right ())
            ExitFailure _ -> pure (Left ("route53 update failed: " ++ trim (processStderr output)))

formatUtcIso :: UTCTime -> String
formatUtcIso = formatShow iso8601Format

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
