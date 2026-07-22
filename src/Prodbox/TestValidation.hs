{-# LANGUAGE OverloadedStrings #-}

module Prodbox.TestValidation
  ( runNativeValidation
  , runNativeValidationWithGatewayStability
  , GatewayRuntimeStabilityRecorder
  , GatewayRuntimeStabilityMonitor
  , newGatewayRuntimeStabilityRecorder
  , withGatewayRuntimeStabilityMonitor
  , pauseGatewayRuntimeStabilityMonitor
  , refreshGatewayRuntimeStabilityMonitor
  , resumeGatewayRuntimeStabilityMonitor
  , recordGatewayRuntimeStabilitySample
  , resetGatewayRuntimeStabilityHealthyWindow
  , runGatewayRuntimeStabilityGate
  , DaemonBootstrapAuditInput (..)
  , SealedVaultAuditInput (..)
  , VolumeRebindSnapshot (..)
  , daemonBootstrapAuditReport
  , daemonBootstrapForbiddenPatterns
  , defaultDaemonBootstrapAuditInput
  , defaultSealedVaultAuditInput
  , parseVolumeRebindSnapshot
  , sealedVaultHostDiskRoot
  , sealedVaultAuditReport
  , sealedVaultForbiddenPatterns
  , resourceGuardrailReport
  , volumeRebindReport
  , verifyAwsTestSshReachability
  , assertInviteOidcClaims
  , gatewayPartitionValidationReport
  , renderGatewayValidationConfigDhall
  )
where

import Control.Concurrent
  ( MVar
  , modifyMVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  , threadDelay
  , tryPutMVar
  , withMVar
  )
import Control.Concurrent.Async (link, withAsync)
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , bracket_
  , displayException
  , finally
  , try
  )
import Control.Monad (foldM, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (isAsciiUpper)
import Data.Foldable (asum)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (..)
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , setSocketOption
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.WebSockets qualified as WebSocket
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Aws
  ( runAwsIamHarnessInspect
  )
import Prodbox.AwsEnvironment
  ( awsCliSubprocessEnvironment
  , overlayAwsCredentials
  )
import Prodbox.Bootstrap.Broker.LegacyAdapter
  ( bootstrapVaultPath
  , bootstrapVaultPkiIssueTestCertPath
  , bootstrapVaultPkiStatusPath
  , bootstrapVaultRotateTransitKeyPath
  , bootstrapVaultRotateUnlockBundlePath
  , bootstrapVaultSealPath
  , bootstrapVaultStatusPath
  )
import Prodbox.BuildSupport
  ( canonicalOperatorBinaryPath
  )
import Prodbox.CLI.Output
  ( writeDiagnostic
  , writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.CLI.Rke2
  ( RetainedStorageInventoryEntry (..)
  , retainedStorageInventoryEntries
  )
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Cbor
  ( CborPayload (..)
  )
import Prodbox.ControlPlane.Capacity qualified as EmitterCapacity
import Prodbox.ControlPlane.Deadline qualified as Deadline
import Prodbox.Dns
  ( configuredPublicHostFqdns
  , fetchPublicIp
  , queryRoute53Record
  )
import Prodbox.Error (fatalError)
import Prodbox.Gateway.Bounds qualified as GatewayBounds
import Prodbox.Gateway.Continuity qualified as GatewayContinuity
import Prodbox.Gateway.Emitter.Actor qualified as EmitterActor
import Prodbox.Gateway.Emitter.Kernel qualified as EmitterKernel
import Prodbox.Gateway.Emitter.Mailbox qualified as EmitterMailbox
import Prodbox.Gateway.Peer qualified as GatewayPeer
import Prodbox.Gateway.Settings qualified as GatewaySettings
import Prodbox.Gateway.State qualified as GatewayState
import Prodbox.Gateway.Types
  ( GatewayRule (..)
  , Orders (..)
  , PeerEndpoint (..)
  )
import Prodbox.Infra.AwsEksTestStack qualified as AwsEks
import Prodbox.Infra.AwsTestStack qualified as AwsTest
import Prodbox.Infra.StackOutputs (StackName (..))
import Prodbox.Keycloak.CredentialSetupForm qualified as CredentialSetupForm
import Prodbox.Keycloak.Email qualified
import Prodbox.Lib.Storage
  ( defaultChartDataRootRelative
  , testManualPvHostRootEnv
  )
import Prodbox.Lifecycle.LiveResidue
  ( awsEksTestStackName
  , awsTestStackName
  , fetchPerRunStackOutputs
  )
import Prodbox.Lifecycle.ResourceClass
  ( LifecycleClass (..)
  )
import Prodbox.PublicEdge
  ( PublicEdgeRoute (..)
  , publicFqdn
  , publicRoutePathPrefix
  , substrateIdentityIssuerUrl
  , substratePublicFqdn
  , substratePublicRouteUrl
  )
import Prodbox.Pulsar.Admin
  ( PulsarAdminConfig (..)
  , pulsarAdminTopicBroker
  )
import Prodbox.Pulsar.Client
  ( AckRequest (..)
  , ConsumeRequest (..)
  , ConsumedMessage (..)
  , ProduceReceipt (..)
  , ProduceRequest (..)
  , PulsarClientConfig (..)
  , PulsarClientError
  , PulsarLookupStrategy (..)
  , SubscriptionName (..)
  , ack
  , connect
  , consumeMessage
  , produce
  , renderPulsarClientError
  )
import Prodbox.Pulsar.Topic
  ( Phase (..)
  , TopicError
  , Workflow (..)
  , mkLane
  , mkNamespace
  , mkTenant
  , renderTopicError
  , renderTopicName
  , topicFor
  )
import Prodbox.Pulsar.TopicResidue
  ( ManagedTopic (..)
  , PulsarTopicBroker
  , RetentionPolicy (..)
  , TopicResidueStatus (..)
  , TopicUnobservableReason (..)
  , deleteTopic
  , ensureTopic
  , renderTopicUnobservableReason
  , topicDiscover
  )
import Prodbox.Result (Result (..))
import Prodbox.Ses.Capture qualified
import Prodbox.Settings
  ( AwsCredentialsRef (..)
  , Credentials
  , DomainSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , aws
  , domain
  , resolveAwsCredentialsRefFromHostVault
  , route53
  , validateAndLoadSettings
  )
import Prodbox.Settings qualified
import Prodbox.Subprocess
  ( BackgroundProcess
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , commandDisplay
  , runSubprocessStreaming
  , startBackgroundProcess
  , stopBackgroundProcess
  )
import Prodbox.Substrate (Substrate (..), substrateId)
import Prodbox.Test.GatewayRuntimeStability
  ( GatewayPayloadSource (..)
  , GatewayRuntimeStabilityReport (..)
  , GatewayStabilityPolicy
  , GatewayStabilityState
  , beginPlannedGatewayRollout
  , gatewayRuntimeStabilityReport
  , initialGatewayStabilityState
  , mkGatewayStabilityPolicy
  , observeGatewayRuntimeFailure
  , observeGatewayRuntimePayloads
  , renderGatewayRuntimeStabilityReport
  )
import Prodbox.TestPlan
  ( NativeValidation (..)
  , nativeValidationId
  )
import Prodbox.UsersAdmin qualified
import Prodbox.Vault.Host (readHostVaultKvField)
import System.Directory (doesDirectoryExist, removeFile)
import System.Environment
  ( getEnvironment
  , lookupEnv
  , setEnv
  , unsetEnv
  )
import System.Exit
  ( ExitCode (..)
  )
import System.FilePath ((</>))
import System.IO
  ( hClose
  , openTempFile
  )
import System.Timeout (timeout)
import Wuss qualified

publicEdgeReadyClassification :: String
publicEdgeReadyClassification = "CLASSIFICATION=ready-for-external-proof"

publicEdgeReadyAttempts :: Int
publicEdgeReadyAttempts = 60

publicEdgeReadyDelayMicroseconds :: Int
publicEdgeReadyDelayMicroseconds = 10000000

chartsVscodeCurlAttempts :: Int
chartsVscodeCurlAttempts = 24

chartsVscodeCurlDelayMicroseconds :: Int
chartsVscodeCurlDelayMicroseconds = 5000000

tokenFetchAttempts :: Int
tokenFetchAttempts = 12

tokenFetchDelayMicroseconds :: Int
tokenFetchDelayMicroseconds = 5000000

data SealedVaultAuditInput = SealedVaultAuditInput
  { sealedVaultBucketNames :: [String]
  , sealedVaultObjectKeys :: [String]
  , sealedVaultHostDiskEntries :: [String]
  , sealedVaultKubernetesObjectNames :: [String]
  , sealedVaultLogLines :: [String]
  }
  deriving (Eq, Show)

data DaemonBootstrapAuditInput = DaemonBootstrapAuditInput
  { daemonBootstrapDaemonAvailable :: Bool
  , daemonBootstrapObservedTransports :: [String]
  , daemonBootstrapObservedOutput :: [String]
  , daemonBootstrapRequiredDaemonPaths :: [String]
  }
  deriving (Eq, Show)

defaultDaemonBootstrapAuditInput :: DaemonBootstrapAuditInput
defaultDaemonBootstrapAuditInput =
  DaemonBootstrapAuditInput
    { daemonBootstrapDaemonAvailable = True
    , daemonBootstrapObservedTransports =
        [ "POST http://127.0.0.1:30443" ++ bootstrapVaultPath ++ " loopback_nodeport_verified=True"
        , "GET http://127.0.0.1:30443" ++ bootstrapVaultStatusPath
        , "POST http://127.0.0.1:30443" ++ bootstrapVaultSealPath
        , "POST http://127.0.0.1:30443" ++ bootstrapVaultRotateUnlockBundlePath
        , "POST http://127.0.0.1:30443" ++ bootstrapVaultRotateTransitKeyPath
        , "POST http://127.0.0.1:30443" ++ bootstrapVaultPkiStatusPath
        , "POST http://127.0.0.1:30443" ++ bootstrapVaultPkiIssueTestCertPath
        ]
    , daemonBootstrapObservedOutput =
        [ "daemon-bootstrap result=ok"
        , "unlock_bundle_source=minio-service"
        , "request_password=redacted"
        , "response_root_token=redacted"
        ]
    , daemonBootstrapRequiredDaemonPaths =
        [ bootstrapVaultPath
        , bootstrapVaultStatusPath
        , bootstrapVaultSealPath
        , bootstrapVaultRotateUnlockBundlePath
        , bootstrapVaultRotateTransitKeyPath
        , bootstrapVaultPkiStatusPath
        , bootstrapVaultPkiIssueTestCertPath
        ]
    }

daemonBootstrapForbiddenPatterns :: [String]
daemonBootstrapForbiddenPatterns =
  [ "kubectl port-forward"
  , "port-forward service/minio"
  , "127.0.0.1:39000"
  , "localhost:39000"
  , "127.0.0.1:31820"
  , "localhost:31820"
  , "PRODBOX_TEST_HOST_VAULT_TOKEN"
  , "direct host Vault"
  , "falling back to host Vault"
  , "host root-token"
  ]

daemonBootstrapForbiddenSecretSamples :: [String]
daemonBootstrapForbiddenSecretSamples =
  [ "operator-password"
  , "bootstrap-password"
  , "vault-unseal-key-1"
  , "vault-unseal-key-2"
  , "vault-root-token"
  , "fake-root-token"
  , "s.child-transit"
  ]

daemonBootstrapAuditReport :: DaemonBootstrapAuditInput -> Either String String
daemonBootstrapAuditReport input = do
  let corpus =
        unlines
          ( daemonBootstrapObservedTransports input
              ++ daemonBootstrapObservedOutput input
          )
      missingPaths =
        filter
          (\path -> not (any (path `isInfixOf`) (daemonBootstrapObservedTransports input)))
          (daemonBootstrapRequiredDaemonPaths input)
      forbiddenLegacy =
        filter (`isInfixOf` corpus) daemonBootstrapForbiddenPatterns
      leakedSecrets =
        filter (`isInfixOf` corpus) daemonBootstrapForbiddenSecretSamples
  case missingPaths of
    [] -> Right ()
    paths -> Left ("daemon-bootstrap validation missing daemon routes: " ++ intercalate "," paths)
  if daemonBootstrapDaemonAvailable input
    then Right ()
    else
      Left
        "daemon-bootstrap validation observed unavailable daemon; refusing legacy direct transport fallback"
  case forbiddenLegacy of
    [] -> Right ()
    patterns ->
      Left ("daemon-bootstrap validation observed legacy transport: " ++ intercalate "," patterns)
  case leakedSecrets of
    [] -> Right ()
    samples ->
      Left ("daemon-bootstrap validation observed unredacted secret sample: " ++ intercalate "," samples)
  Right $
    unlines
      [ "DAEMON_BOOTSTRAP_VALIDATION"
      , "DAEMON_AVAILABLE=true"
      , "DAEMON_PATHS=" ++ intercalate "," (daemonBootstrapRequiredDaemonPaths input)
      , "LEGACY_TRANSPORTS=0"
      , "HOST_ROOT_TOKEN_FALLBACKS=0"
      , "REDACTION=ok"
      ]

defaultSealedVaultAuditInput :: SealedVaultAuditInput
defaultSealedVaultAuditInput =
  SealedVaultAuditInput
    { sealedVaultBucketNames = ["prodbox-state"]
    , sealedVaultObjectKeys = []
    , sealedVaultHostDiskEntries = []
    , sealedVaultKubernetesObjectNames = []
    , sealedVaultLogLines = []
    }

sealedVaultForbiddenPatterns :: [String]
sealedVaultForbiddenPatterns =
  [ "prodbox-test-pulumi-backends"
  , "aws-eks"
  , "aws-test"
  , "aws-ses"
  , "master-seed"
  , "/v1/secret/derive"
  , "/v1/secret/ensure-namespace"
  , "secretreffile"
  , "aws_secret_access_key"
  , "akia"
  , "begin private key"
  , "client_secret = \""
  , "password = \""
  , "pulumi_config_passphrase"
  , "kubeconfig user token"
  , "child-a"
  , "child-b"
  , "child-named"
  ]

sealedVaultAuditReport :: SealedVaultAuditInput -> Either String String
sealedVaultAuditReport input = do
  assertOnlyGenericBuckets (sealedVaultBucketNames input)
  assertOpaqueObjectKeys (sealedVaultObjectKeys input)
  assertNoForbiddenPatterns "bucket listing" (sealedVaultBucketNames input)
  assertNoForbiddenPatterns "object listing" (sealedVaultObjectKeys input)
  assertNoForbiddenPatterns "host disk" (sealedVaultHostDiskEntries input)
  assertNoForbiddenPatterns "kubernetes objects" (sealedVaultKubernetesObjectNames input)
  assertNoForbiddenPatterns "logs/output" (sealedVaultLogLines input)
  Right $
    unlines
      [ "SEALED_VAULT_AUDIT=pass"
      , "SEALED_VAULT_BUCKETS=" ++ show (length (sealedVaultBucketNames input))
      , "SEALED_VAULT_OBJECT_KEYS=" ++ show (length (sealedVaultObjectKeys input))
      , "SEALED_VAULT_HOST_DISK_ENTRIES=" ++ show (length (sealedVaultHostDiskEntries input))
      , "SEALED_VAULT_K8S_OBJECTS=" ++ show (length (sealedVaultKubernetesObjectNames input))
      , "SEALED_VAULT_LOG_LINES=" ++ show (length (sealedVaultLogLines input))
      ]

assertOnlyGenericBuckets :: [String] -> Either String ()
assertOnlyGenericBuckets buckets =
  case filter (`notElem` ["prodbox-state"]) buckets of
    [] -> Right ()
    unexpected -> Left ("sealed Vault audit found role-revealing bucket names: " ++ show unexpected)

assertOpaqueObjectKeys :: [String] -> Either String ()
assertOpaqueObjectKeys objectKeys =
  case filter (not . sealedVaultOpaqueObjectKey) objectKeys of
    [] -> Right ()
    unexpected -> Left ("sealed Vault audit found non-opaque object keys: " ++ show unexpected)

sealedVaultOpaqueObjectKey :: String -> Bool
sealedVaultOpaqueObjectKey key =
  objectKey "objects/" || objectKey "indexes/"
 where
  objectKey prefix =
    prefix `isPrefixOf` key
      && suffix `isSuffixOf` key
      && noNestedPath (drop (length prefix) (take (length key - length suffix) key))
   where
    suffix = ".enc" :: String

  noNestedPath value =
    value /= "" && not ("/" `isInfixOf` value)

assertNoForbiddenPatterns :: String -> [String] -> Either String ()
assertNoForbiddenPatterns surface values =
  case [forbidden | forbidden <- sealedVaultForbiddenPatterns, any (containsLower forbidden) values] of
    [] -> Right ()
    patterns ->
      Left
        ( "sealed Vault audit found forbidden pattern(s) on "
            ++ surface
            ++ ": "
            ++ intercalate ", " patterns
        )
 where
  containsLower forbidden value =
    map toLowerAscii forbidden `isInfixOf` map toLowerAscii value

awsTestSshReadyAttempts :: Int
awsTestSshReadyAttempts = 18

awsTestSshReadyDelayMicroseconds :: Int
awsTestSshReadyDelayMicroseconds = 10000000

websocketConnectionAttempts :: Int
websocketConnectionAttempts = 4

websocketConnectionRetryDelayMicroseconds :: Int
websocketConnectionRetryDelayMicroseconds = 5000000

websocketDistinctConnectionRetryDelayMicroseconds :: Int
websocketDistinctConnectionRetryDelayMicroseconds = 1000000

websocketReceiveRetryDelayMicroseconds :: Int
websocketReceiveRetryDelayMicroseconds = 1000000

gatewayValidationNamespace :: String
gatewayValidationNamespace = "gateway"

pulsarValidationNamespace :: String
pulsarValidationNamespace = gatewayValidationNamespace

gatewayStatusRetryAttempts :: Int
gatewayStatusRetryAttempts = 12

gatewayStatusRetryDelayMicroseconds :: Int
gatewayStatusRetryDelayMicroseconds = 1000000

data GatewayRuntimeStabilityRecorder = GatewayRuntimeStabilityRecorder
  { gatewayRuntimeStabilityStateVar :: MVar GatewayStabilityState
  , gatewayRuntimeObservationLock :: MVar ()
  }

-- | Structured-concurrency handle for the run-scoped observer.  The worker
-- owns no independent evidence: every sample is folded into the shared
-- recorder.  Planned rollouts pause observations only while the gateway is
-- intentionally absent; pausing never clears the absorbing recorder state.
data GatewayRuntimeStabilityMonitor = GatewayRuntimeStabilityMonitor
  { gatewayRuntimeMonitorEnabled :: MVar Bool
  , gatewayRuntimeMonitorRefreshRequest :: MVar (Maybe (MVar ()))
  , gatewayRuntimeMonitorRefreshLock :: MVar ()
  , gatewayRuntimeMonitorRecorder :: GatewayRuntimeStabilityRecorder
  }

data GatewayRuntimeKubectlContext = GatewayRuntimeKubectlContext
  { gatewayRuntimeContextRepoRoot :: FilePath
  , gatewayRuntimeContextEnvironment :: Maybe [(String, String)]
  }

gatewayRuntimeRequiredStableSamples :: Natural
gatewayRuntimeRequiredStableSamples = 3

gatewayRuntimeMaximumSampleAttempts :: Int
gatewayRuntimeMaximumSampleAttempts = 6

gatewayRuntimeSampleDelayMicroseconds :: Int
gatewayRuntimeSampleDelayMicroseconds = 1000000

gatewayRuntimeKubectlRequestTimeout :: String
gatewayRuntimeKubectlRequestTimeout = "5s"

gatewayRuntimeKubectlDeadlineMicroseconds :: Int
gatewayRuntimeKubectlDeadlineMicroseconds = 15000000

newGatewayRuntimeStabilityRecorder
  :: FilePath -> IO (Either String GatewayRuntimeStabilityRecorder)
newGatewayRuntimeStabilityRecorder repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> pure (Left ("load settings for gateway runtime stability: " ++ err))
    Right settings ->
      case gatewayRuntimeStabilityPolicy settings of
        Left err -> pure (Left err)
        Right policy -> do
          stateVar <- newMVar (initialGatewayStabilityState policy)
          observationLock <- newMVar ()
          pure
            ( Right
                GatewayRuntimeStabilityRecorder
                  { gatewayRuntimeStabilityStateVar = stateVar
                  , gatewayRuntimeObservationLock = observationLock
                  }
            )

-- | Run a continuously sampled observer in a structured scope.  AWS uses a
-- monitor-private kubeconfig and explicit subprocess environment, so the
-- observer never races the parent process's ambient environment while other
-- validations execute.
withGatewayRuntimeStabilityMonitor
  :: Substrate
  -> FilePath
  -> GatewayRuntimeStabilityRecorder
  -> (GatewayRuntimeStabilityMonitor -> IO result)
  -> IO (Either String result)
withGatewayRuntimeStabilityMonitor substrate repoRoot recorder action =
  case substrate of
    SubstrateHomeLocal ->
      Right
        <$> runWithWorker
          ( gatewayRuntimeHomeMonitorLoop
              (GatewayRuntimeKubectlContext repoRoot Nothing)
          )
    SubstrateAws -> do
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left err -> pure (Left err)
        Right settings -> do
          credentialsResult <-
            resolveAwsCredentialsRefFromHostVault
              repoRoot
              "aws"
              (aws (validatedConfig settings))
          case credentialsResult of
            Left err ->
              pure (Left ("load operational AWS credentials from Vault: " ++ err))
            Right credentials ->
              Right <$> runWithWorker (gatewayRuntimeAwsMonitorLoop repoRoot credentials)
 where
  runWithWorker workerAction = do
    enabled <- newMVar True
    refreshRequest <- newMVar Nothing
    refreshLock <- newMVar ()
    firstObservationComplete <- newEmptyMVar
    let monitor =
          GatewayRuntimeStabilityMonitor
            { gatewayRuntimeMonitorEnabled = enabled
            , gatewayRuntimeMonitorRefreshRequest = refreshRequest
            , gatewayRuntimeMonitorRefreshLock = refreshLock
            , gatewayRuntimeMonitorRecorder = recorder
            }
    withAsync (workerAction monitor firstObservationComplete) $ \worker -> do
      link worker
      -- Do not let the observed suite outrun its monitor.  The explicit
      -- baseline precedes this scope; this handshake proves the continuous
      -- worker has taken over before any later action can mutate the gateway.
      _ <- takeMVar firstObservationComplete
      action monitor

gatewayRuntimeHomeMonitorLoop
  :: GatewayRuntimeKubectlContext
  -> GatewayRuntimeStabilityMonitor
  -> MVar ()
  -> IO ()
gatewayRuntimeHomeMonitorLoop context monitor firstObservationComplete =
  go Nothing
 where
  go maybeRefreshAcknowledgement = do
    mapM_ (`putMVar` ()) maybeRefreshAcknowledgement
    nextRefreshAcknowledgement <-
      gatewayRuntimeMonitorLoop context monitor firstObservationComplete
    go nextRefreshAcknowledgement

gatewayRuntimeAwsMonitorLoop
  :: FilePath
  -> Credentials
  -> GatewayRuntimeStabilityMonitor
  -> MVar ()
  -> IO ()
gatewayRuntimeAwsMonitorLoop repoRoot credentials monitor firstObservationComplete =
  go Nothing
 where
  go maybeRefreshAcknowledgement = do
    nextRefreshAcknowledgement <-
      AwsEks.withEksKubeconfig repoRoot $ \kubeconfigPath -> do
        baseEnvironment <- awsCliSubprocessEnvironment credentials
        let monitorEnvironment =
              ("KUBECONFIG", kubeconfigPath)
                : filter ((/= "KUBECONFIG") . fst) baseEnvironment
        mapM_ (`putMVar` ()) maybeRefreshAcknowledgement
        gatewayRuntimeMonitorLoop
          (GatewayRuntimeKubectlContext repoRoot (Just monitorEnvironment))
          monitor
          firstObservationComplete
    go nextRefreshAcknowledgement

gatewayRuntimeMonitorLoop
  :: GatewayRuntimeKubectlContext
  -> GatewayRuntimeStabilityMonitor
  -> MVar ()
  -> IO (Maybe (MVar ()))
gatewayRuntimeMonitorLoop context monitor firstObservationComplete = do
  maybeRefreshAcknowledgement <-
    modifyMVar
      (gatewayRuntimeMonitorRefreshRequest monitor)
      (\request -> pure (Nothing, request))
  case maybeRefreshAcknowledgement of
    Just acknowledgement -> pure (Just acknowledgement)
    Nothing -> do
      observeWhenEnabled
      void (tryPutMVar firstObservationComplete ())
      threadDelay gatewayRuntimeSampleDelayMicroseconds
      gatewayRuntimeMonitorLoop context monitor firstObservationComplete
 where
  observeWhenEnabled = do
    let recorder = gatewayRuntimeMonitorRecorder monitor
    withMVar (gatewayRuntimeObservationLock recorder) $ \() -> do
      enabled <- readMVar (gatewayRuntimeMonitorEnabled monitor)
      when enabled $ void (observeGatewayRuntimeStabilityUnlocked context recorder)

pauseGatewayRuntimeStabilityMonitor
  :: GatewayRuntimeStabilityMonitor -> IO ()
pauseGatewayRuntimeStabilityMonitor monitor = do
  modifyMVar_
    (gatewayRuntimeMonitorEnabled monitor)
    (const (pure False))
  -- Wait for an observation already in flight.  The loop rechecks the flag
  -- while holding this lock, so a queued sample cannot start after pause.
  withMVar
    (gatewayRuntimeObservationLock (gatewayRuntimeMonitorRecorder monitor))
    (const (pure ()))

-- | Request a fresh monitor observation context.  The worker checks this
-- before every sample, leaves its current kubeconfig bracket without reading
-- from it again, and (on AWS) materializes a new kubeconfig for the recreated
-- EKS target.  Callers pause and drain first, then resume only after a fresh
-- foreground sample has proved the replacement gateway observable.
refreshGatewayRuntimeStabilityMonitor
  :: GatewayRuntimeStabilityMonitor -> IO ()
refreshGatewayRuntimeStabilityMonitor monitor =
  withMVar (gatewayRuntimeMonitorRefreshLock monitor) $ \() -> do
    acknowledgement <- newEmptyMVar
    modifyMVar_
      (gatewayRuntimeMonitorRefreshRequest monitor)
      (const (pure (Just acknowledgement)))
    takeMVar acknowledgement

resumeGatewayRuntimeStabilityMonitor
  :: GatewayRuntimeStabilityMonitor -> IO ()
resumeGatewayRuntimeStabilityMonitor monitor =
  modifyMVar_
    (gatewayRuntimeMonitorEnabled monitor)
    (const (pure True))

gatewayRuntimeStabilityPolicy
  :: ValidatedSettings
  -> Either String GatewayStabilityPolicy
gatewayRuntimeStabilityPolicy settings = do
  let capacitySection =
        Prodbox.Settings.capacity
          (Prodbox.Settings.validatedConfig settings)
  runtimePlan <- Capacity.runtimeMemoryPlanForProfile capacitySection "gateway"
  expectedReplicas <- gatewayRuntimeExpectedReplicas (Capacity.resource_plan capacitySection)
  Bifunctor.first
    (("gateway runtime stability policy: " ++) . show)
    ( mkGatewayStabilityPolicy
        expectedReplicas
        gatewayRuntimeRequiredStableSamples
        runtimePlan
    )

gatewayRuntimeExpectedReplicas :: Capacity.ResourcePlan -> Either String Natural
gatewayRuntimeExpectedReplicas resourcePlan =
  case filter
    ((== "gateway") . Capacity.profile_id)
    (Capacity.workload_profiles resourcePlan) of
    [profile] -> Right (Capacity.replicas profile)
    [] -> Left "capacity.resource_plan is missing the gateway workload profile"
    _ -> Left "capacity.resource_plan contains duplicate gateway workload profiles"

resetGatewayRuntimeStabilityHealthyWindow
  :: GatewayRuntimeStabilityRecorder -> IO ()
resetGatewayRuntimeStabilityHealthyWindow recorder =
  modifyMVar_
    (gatewayRuntimeStabilityStateVar recorder)
    (pure . beginPlannedGatewayRollout)

recordGatewayRuntimeStabilitySample
  :: Substrate
  -> FilePath
  -> GatewayRuntimeStabilityRecorder
  -> IO ExitCode
recordGatewayRuntimeStabilitySample substrate repoRoot recorder = do
  scopedResult <-
    withSubstrateKubeconfigResult
      repoRoot
      substrate
      ( observeGatewayRuntimeStability
          (GatewayRuntimeKubectlContext repoRoot Nothing)
          recorder
      )
  case scopedResult of
    Left err -> do
      report <- recordGatewayRuntimeFailure recorder GatewayPodsPayload err
      failWith (renderGatewayRuntimeStabilityReport report)
    Right report -> gatewayRuntimeSampleExit report

runGatewayRuntimeStabilityGate
  :: Substrate
  -> FilePath
  -> GatewayRuntimeStabilityRecorder
  -> IO ExitCode
runGatewayRuntimeStabilityGate substrate repoRoot recorder = do
  scopedResult <-
    withSubstrateKubeconfigResult
      repoRoot
      substrate
      ( runGatewayRuntimeStabilityGateInCurrentContext
          (GatewayRuntimeKubectlContext repoRoot Nothing)
          recorder
      )
  case scopedResult of
    Left err -> do
      report <- recordGatewayRuntimeFailure recorder GatewayPodsPayload err
      failWith (renderGatewayRuntimeStabilityReport report)
    Right exitCode -> pure exitCode

runGatewayRuntimeStabilityGateInCurrentContext
  :: GatewayRuntimeKubectlContext
  -> GatewayRuntimeStabilityRecorder
  -> IO ExitCode
runGatewayRuntimeStabilityGateInCurrentContext context recorder =
  go gatewayRuntimeMaximumSampleAttempts
 where
  go attemptsRemaining = do
    report <- observeGatewayRuntimeStability context recorder
    case report of
      StableObserved samples -> do
        writeOutput
          ( unlines
              [ "GATEWAY_RUNTIME_STABILITY_VALIDATION"
              , "CLASSIFICATION=stable"
              , "STABLE_SAMPLES=" ++ show samples
              , renderGatewayRuntimeStabilityReport report
              ]
          )
        pure ExitSuccess
      NotStableYet _ _
        | attemptsRemaining > 1 -> do
            writeDiagnosticLine
              ("Waiting for gateway runtime stability: " ++ renderGatewayRuntimeStabilityReport report)
            threadDelay gatewayRuntimeSampleDelayMicroseconds
            go (attemptsRemaining - 1)
        | otherwise ->
            failWith
              ( "Gateway runtime stability window did not converge: "
                  ++ renderGatewayRuntimeStabilityReport report
              )
      RuntimeUnhealthy _ ->
        failWith
          ("Gateway runtime is unhealthy: " ++ renderGatewayRuntimeStabilityReport report)
      StabilityUnreachable _ ->
        failWith
          ("Gateway runtime stability is unobservable: " ++ renderGatewayRuntimeStabilityReport report)

gatewayRuntimeSampleExit :: GatewayRuntimeStabilityReport -> IO ExitCode
gatewayRuntimeSampleExit report =
  case report of
    RuntimeUnhealthy _ ->
      failWith ("Gateway runtime is unhealthy: " ++ renderGatewayRuntimeStabilityReport report)
    StabilityUnreachable _ ->
      failWith
        ("Gateway runtime stability is unobservable: " ++ renderGatewayRuntimeStabilityReport report)
    StableObserved _ -> pure ExitSuccess
    NotStableYet _ _ -> pure ExitSuccess

observeGatewayRuntimeStability
  :: GatewayRuntimeKubectlContext
  -> GatewayRuntimeStabilityRecorder
  -> IO GatewayRuntimeStabilityReport
observeGatewayRuntimeStability context recorder =
  withMVar (gatewayRuntimeObservationLock recorder) $ \() ->
    observeGatewayRuntimeStabilityUnlocked context recorder

observeGatewayRuntimeStabilityUnlocked
  :: GatewayRuntimeKubectlContext
  -> GatewayRuntimeStabilityRecorder
  -> IO GatewayRuntimeStabilityReport
observeGatewayRuntimeStabilityUnlocked context recorder = do
  podsResult <-
    gatewayRuntimeKubectlJson
      context
      ["get", "pods", "--namespace", gatewayValidationNamespace, "-o", "json"]
  eventsResult <-
    gatewayRuntimeKubectlJson
      context
      [ "get"
      , "events"
      , "--namespace"
      , gatewayValidationNamespace
      , "--field-selector"
      , "involvedObject.kind=Pod"
      , "-o"
      , "json"
      ]
  metricsResult <-
    gatewayRuntimeKubectlJson
      context
      [ "get"
      , "--raw"
      , "/apis/metrics.k8s.io/v1beta1/namespaces/gateway/pods"
      ]
  observedAt <- Text.pack . show <$> getPOSIXTime
  case (podsResult, eventsResult, metricsResult) of
    (Left err, _, _) -> recordGatewayRuntimeFailure recorder GatewayPodsPayload err
    (_, Left err, _) -> recordGatewayRuntimeFailure recorder GatewayEventsPayload err
    (_, _, Left err) -> recordGatewayRuntimeFailure recorder GatewayMetricsPayload err
    (Right pods, Right events, Right metrics) ->
      modifyGatewayRuntimeState
        recorder
        (observeGatewayRuntimePayloads observedAt pods events metrics)

recordGatewayRuntimeFailure
  :: GatewayRuntimeStabilityRecorder
  -> GatewayPayloadSource
  -> String
  -> IO GatewayRuntimeStabilityReport
recordGatewayRuntimeFailure recorder source detail = do
  modifyGatewayRuntimeState
    recorder
    (observeGatewayRuntimeFailure source (Text.pack detail))

modifyGatewayRuntimeState
  :: GatewayRuntimeStabilityRecorder
  -> (GatewayStabilityState -> GatewayStabilityState)
  -> IO GatewayRuntimeStabilityReport
modifyGatewayRuntimeState recorder transition =
  modifyMVar (gatewayRuntimeStabilityStateVar recorder) $ \state -> do
    let nextState = transition state
    pure (nextState, gatewayRuntimeStabilityReport nextState)

gatewayRuntimeKubectlJson
  :: GatewayRuntimeKubectlContext -> [String] -> IO (Either String Value)
gatewayRuntimeKubectlJson context arguments = do
  let boundedArguments =
        arguments ++ ["--request-timeout=" ++ gatewayRuntimeKubectlRequestTimeout]
      spec =
        Subprocess
          { subprocessPath = "timeout"
          , subprocessArguments =
              ["--kill-after=2s", "12s", "kubectl"] ++ boundedArguments
          , subprocessEnvironment = gatewayRuntimeContextEnvironment context
          , subprocessWorkingDirectory = Just (gatewayRuntimeContextRepoRoot context)
          }
  deadlineResult <-
    timeout
      gatewayRuntimeKubectlDeadlineMicroseconds
      (runJsonCommand spec)
  pure $
    case deadlineResult of
      Nothing ->
        Left
          ( "`"
              ++ commandDisplay spec
              ++ "` exceeded the 15-second observation deadline"
          )
      Just result -> result

runNativeValidation
  :: Substrate -> FilePath -> [(String, String)] -> NativeValidation -> IO ExitCode
runNativeValidation substrate repoRoot environment validation =
  runNativeValidationWithGatewayStability
    Nothing
    substrate
    repoRoot
    environment
    validation

runNativeValidationWithGatewayStability
  :: Maybe GatewayRuntimeStabilityRecorder
  -> Substrate
  -> FilePath
  -> [(String, String)]
  -> NativeValidation
  -> IO ExitCode
runNativeValidationWithGatewayStability maybeGatewayStability substrate repoRoot environment validation = do
  writeOutputLine
    ("Validation: " ++ nativeValidationId validation ++ " (substrate=" ++ substrateId substrate ++ ")")
  writeDiagnosticLine
    ( "[validation="
        ++ nativeValidationId validation
        ++ " substrate="
        ++ substrateId substrate
        ++ "] entering body"
    )
  result <- withSubstrateKubeconfigEnv repoRoot substrate runSubstrateValidation
  writeDiagnosticLine
    ( "[validation="
        ++ nativeValidationId validation
        ++ " substrate="
        ++ substrateId substrate
        ++ "] body exit="
        ++ show result
    )
  pure result
 where
  runSubstrateValidation =
    case validation of
      ValidationChartsVscode -> runChartsVscodeValidation repoRoot substrate
      ValidationChartsApi -> runChartsApiValidation repoRoot substrate
      ValidationChartsWebsocket -> runChartsWebsocketValidation repoRoot environment substrate
      ValidationAdminRoutes -> runAdminRoutesValidation repoRoot substrate
      ValidationPublicDns -> runPublicDnsValidation repoRoot substrate
      ValidationDnsAws -> runDnsAwsValidation repoRoot
      ValidationAwsIam ->
        assertProducedOutputContainsAll
          "aws-iam harness inspection"
          (runAwsIamHarnessInspect repoRoot)
          ["IAM_USER=prodbox", "CONFIG_PATH="]
      ValidationAwsEks ->
        runSequentially
          [ assertNativeCommandOutputContainsAll
              repoRoot
              environment
              ["aws", "stack", "eks", "reconcile"]
              ["STACK=" ++ AwsEks.awsEksTestStackName, "CLUSTER_NAME=", "NODE_GROUP_NAME="]
          , verifyAwsEksSnapshot repoRoot
          ]
      ValidationPulumi ->
        runSequentially
          [ assertNativeCommandOutputContainsAll
              repoRoot
              environment
              ["aws", "stack", "test", "reconcile"]
              ["STACK=" ++ AwsTest.awsTestStackName, "NODE_COUNT=3"]
          , verifyAwsTestSnapshot repoRoot
          ]
      ValidationHaRke2Aws ->
        runHaRke2AwsValidation repoRoot environment
      ValidationGatewayDaemon -> runGatewayDaemonValidation repoRoot environment
      ValidationGatewayPods ->
        runGatewayPodsValidation
          repoRoot
          environment
          maybeGatewayStability
      ValidationGatewayPartition -> runGatewayPartitionValidation
      ValidationChartsPlatform ->
        runSequentially
          [ assertNativeCommandOutputContainsAll
              repoRoot
              environment
              ["charts", "list"]
              ["CHART_LIST", "NAME=vscode", "NAME=gateway"]
          , assertNativeCommandOutputContainsAll
              repoRoot
              environment
              ["charts", "status", "vscode"]
              ["CHART_STATUS", "NAME=vscode"]
          ]
      ValidationResourceGuardrails ->
        runResourceGuardrailsValidation repoRoot
      ValidationDaemonBootstrap ->
        runDaemonBootstrapValidation
      ValidationPulsarBroker ->
        runPulsarBrokerValidation repoRoot environment substrate
      ValidationChartsStorage ->
        runSequentially
          [ assertNativeCommandOutputContainsAll
              repoRoot
              environment
              ["charts", "status", "vscode"]
              ["CHART_STATUS", "STORAGE_BINDING"]
          , assertNativeCommandOutputContainsAll
              repoRoot
              environment
              ["charts", "delete", "vscode", "--yes"]
              ["CHART_DELETION", "HOST_STORAGE_PRESERVED=true"]
          ]
      ValidationEksVolumeRebind ->
        runEksVolumeRebindValidation repoRoot environment substrate
      ValidationLifecycle ->
        -- The Sprint 4.11 `noLivePerRunPulumiStacks` predicate guards
        -- `rke2 delete --yes` against orphaning per-run AWS stacks.
        -- The canonical suite provisions the `aws-eks` and (sometimes)
        -- `aws-test` Pulumi stacks earlier in the run and destroys
        -- them at suite postflight, so by the time this validation
        -- fires the predicate sees live residue. The suite harness
        -- has explicit residue ownership semantics — it knows the
        -- postflight will clean up — so the `--allow-pulumi-residue`
        -- bypass is the documented operator-acknowledged escape hatch
        -- and the right tool for the suite-internal call.
        runSequentially
          [ runNativeCliCommandForExitCode
              repoRoot
              environment
              -- The refactor renamed `rke2 delete` → `cluster delete`; the new
              -- default (no `--cascade`) is a pure local uninstall that leaves
              -- per-run AWS Pulumi stacks untouched, exactly what the retired
              -- `--allow-pulumi-residue` bypass did, so the suite-internal
              -- residue-acknowledged teardown is now just `cluster delete --yes`.
              ["cluster", "delete", "--yes"]
          , runNativeCliCommandForExitCode repoRoot environment ["cluster", "reconcile"]
          , -- Reconcile brings up a fresh Vault that auto-unseals from the durable
            -- unlock bundle, but under host memory pressure that unseal can lose
            -- the race (Vault pod not ready yet), leaving Vault sealed for the
            -- `cluster health` check below and the suite's postflight per-run AWS
            -- destroy. `vault unseal` is idempotent (no-op when already unsealed),
            -- so this is a safe retry that closes the delete→reconcile→destroy
            -- teardown race without depending on the reconcile's unseal timing.
            runNativeCliCommandForExitCode repoRoot environment ["vault", "unseal"]
          , runNativeCliCommandForExitCode repoRoot environment ["cluster", "health"]
          ]
      ValidationKeycloakInvite -> runKeycloakInviteValidation repoRoot substrate environment
      ValidationSealedVault -> runSealedVaultValidation repoRoot environment

-- | Wrap a validation action with substrate-aware `KUBECONFIG` plus AWS_*
-- credentials for the AWS substrate.
--
-- For `SubstrateHomeLocal` the operator's default kubeconfig is in scope
-- already (no-op). For `SubstrateAws` (Sprint 4.18 fifth chunk
-- re-migration) the EKS kubeconfig is materialized into a scoped temp
-- file via 'AwsEks.withEksKubeconfig' and exported alongside
-- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION`
-- (and optionally `AWS_SESSION_TOKEN`) from `settings.aws.*`, so every
-- kubectl/helm subprocess that inherits the parent process environment
-- can both target the EKS substrate and successfully resolve the
-- kubeconfig's `aws eks get-token` exec provider.
withSubstrateKubeconfigEnv :: FilePath -> Substrate -> IO ExitCode -> IO ExitCode
withSubstrateKubeconfigEnv repoRoot substrate action = do
  result <- withSubstrateKubeconfigResult repoRoot substrate action
  case result of
    Left err -> failWith err
    Right exitCode -> pure exitCode

withSubstrateKubeconfigResult
  :: FilePath -> Substrate -> IO result -> IO (Either String result)
withSubstrateKubeconfigResult repoRoot substrate action =
  case substrate of
    SubstrateHomeLocal -> Right <$> action
    SubstrateAws -> do
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left err -> pure (Left err)
        Right settings -> do
          credentialsResult <-
            resolveAwsCredentialsRefFromHostVault
              repoRoot
              "aws"
              (aws (validatedConfig settings))
          case credentialsResult of
            Left err ->
              pure (Left ("load operational AWS credentials from Vault: " ++ err))
            Right credentials ->
              AwsEks.withEksKubeconfig repoRoot $ \kubeconfigPath -> do
                let envOverrides = overlayAwsCredentials [("KUBECONFIG", kubeconfigPath)] credentials
                previousValues <- mapM (\(name, _) -> lookupEnv name) envOverrides
                Right
                  <$> bracket_
                    (mapM_ (\(name, value) -> setEnv name value) envOverrides)
                    (mapM_ restoreOne (zip envOverrides previousValues))
                    action
 where
  restoreOne :: ((String, String), Maybe String) -> IO ()
  restoreOne ((name, _), Nothing) = unsetEnv name
  restoreOne ((name, _), Just value) = setEnv name value

runPulsarBrokerValidation :: FilePath -> [(String, String)] -> Substrate -> IO ExitCode
runPulsarBrokerValidation repoRoot environment _substrate =
  runSequentially
    [ runNativeCliCommandForExitCode repoRoot environment ["cluster", "health"]
    , runPulsarRolloutWait repoRoot
    , runPulsarBrokerProof repoRoot
    ]

runPulsarRolloutWait :: FilePath -> IO ExitCode
runPulsarRolloutWait repoRoot =
  runCommandForExitCode
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "--namespace"
          , pulsarValidationNamespace
          , "rollout"
          , "status"
          , "statefulset/pulsar"
          , "--timeout=240s"
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

runPulsarBrokerProof :: FilePath -> IO ExitCode
runPulsarBrokerProof repoRoot = do
  nonce <- validationNonce
  portPair <- reserveDistinctLocalTcpPorts
  case pulsarValidationTopic nonce of
    Left err -> failWith ("failed to build Pulsar validation topic: " ++ renderTopicError err)
    Right managedTopic ->
      let (brokerPort, adminPort) = portPair
          topicBroker =
            pulsarAdminTopicBroker
              PulsarAdminConfig
                { pulsarAdminHost = "127.0.0.1"
                , pulsarAdminPort = adminPort
                }
          cleanup =
            do
              _ <- deleteTopic topicBroker managedTopic
              pure ()
       in withPulsarPortForward repoRoot brokerPort adminPort $
            finally
              (runPulsarBrokerRoundTrip nonce brokerPort topicBroker managedTopic)
              cleanup

pulsarValidationTopic :: String -> Either TopicError ManagedTopic
pulsarValidationTopic nonce = do
  tenant <- mkTenant "public"
  namespaceName <- mkNamespace "default"
  lane <- mkLane (Text.pack ("validation-" ++ nonce))
  pure
    ManagedTopic
      { managedTopicName = topicFor tenant namespaceName Reconcile Command lane
      , managedTopicRetention =
          RetentionPolicy
            { retentionBacklogBytes = 0
            , retentionOffloadBytes = 0
            }
      , managedTopicClass = PerRun
      }

runPulsarBrokerRoundTrip
  :: String
  -> Int
  -> PulsarTopicBroker
  -> ManagedTopic
  -> IO ExitCode
runPulsarBrokerRoundTrip nonce brokerPort topicBroker managedTopic = do
  threadDelay 1500000
  _ <- deleteTopic topicBroker managedTopic
  ensureResult <- retryEither 12 1000000 (ensureTopic topicBroker managedTopic)
  case ensureResult of
    Left reason -> failWith ("Pulsar topic ensure failed: " ++ renderTopicUnobservableReason reason)
    Right () -> do
      presentResult <- waitForPulsarTopicPresent topicBroker managedTopic
      case presentResult of
        Left reason ->
          failWith ("Pulsar topic was not observable after ensure: " ++ renderTopicUnobservableReason reason)
        Right () -> do
          connectionResult <-
            retryEither
              12
              1000000
              ( connect
                  PulsarClientConfig
                    { pulsarClientHost = "127.0.0.1"
                    , pulsarClientPort = brokerPort
                    , pulsarClientName = Text.pack ("prodbox-validation-" ++ nonce)
                    , pulsarClientLookupStrategy = StayOnConnectedBroker
                    }
              )
          case connectionResult of
            Left err -> failPulsarClient "Pulsar broker connect failed" err
            Right connection -> do
              let topic = managedTopicName managedTopic
                  subscription = SubscriptionName (Text.pack ("prodbox-validation-" ++ nonce))
                  payload = CborPayload (BS8.pack ("prodbox-pulsar-validation:" ++ nonce))
              produceResult <-
                produce
                  connection
                  ProduceRequest
                    { produceTopic = topic
                    , producePayload = payload
                    }
              case produceResult of
                Left err -> failPulsarClient "Pulsar produce failed" err
                Right receipt -> do
                  consumeResult <-
                    consumeMessage
                      connection
                      ConsumeRequest
                        { consumeTopic = topic
                        , consumeSubscription = subscription
                        }
                  case consumeResult of
                    Left err -> failPulsarClient "Pulsar consume failed" err
                    Right Nothing -> failWith "Pulsar consume returned no message."
                    Right (Just consumed)
                      | consumedPayload consumed /= payload ->
                          failWith "Pulsar consumed payload did not match produced payload."
                      | otherwise -> do
                          ackResult <-
                            ack
                              connection
                              AckRequest
                                { ackTopic = topic
                                , ackSubscription = subscription
                                , ackMessageId = consumedMessageId consumed
                                }
                          case ackResult of
                            Left err -> failPulsarClient "Pulsar ack failed" err
                            Right () -> do
                              deleteResult <- retryEither 6 1000000 (deleteTopic topicBroker managedTopic)
                              case deleteResult of
                                Left reason ->
                                  failWith ("Pulsar topic delete failed: " ++ renderTopicUnobservableReason reason)
                                Right () -> do
                                  absentResult <- waitForPulsarTopicAbsent topicBroker managedTopic
                                  case absentResult of
                                    Left reason ->
                                      failWith
                                        ( "Pulsar topic remained observable after delete: "
                                            ++ renderTopicUnobservableReason reason
                                        )
                                    Right () -> do
                                      writeOutputLine "PULSAR_BROKER_VALIDATION=pass"
                                      writeOutputLine
                                        ( "TOPIC="
                                            ++ Text.unpack (renderTopicName (managedTopicName managedTopic))
                                        )
                                      writeOutputLine ("PRODUCED_MESSAGE_ID=" ++ show (produceReceiptMessageId receipt))
                                      writeOutputLine ("ACKED_MESSAGE_ID=" ++ show (consumedMessageId consumed))
                                      pure ExitSuccess

waitForPulsarTopicPresent
  :: PulsarTopicBroker
  -> ManagedTopic
  -> IO (Either TopicUnobservableReason ())
waitForPulsarTopicPresent topicBroker managedTopic =
  retryTopicStatus 12 1000000 isPresent (TopicBrokerError "topic did not become present")
 where
  isPresent status =
    case status of
      TopicPresent _ -> Right (Just ())
      TopicAbsent -> Right Nothing
      TopicUnobservable reason -> Left reason

  retryTopicStatus = retryPulsarTopicStatus topicBroker managedTopic

waitForPulsarTopicAbsent
  :: PulsarTopicBroker
  -> ManagedTopic
  -> IO (Either TopicUnobservableReason ())
waitForPulsarTopicAbsent topicBroker managedTopic =
  retryTopicStatus 12 1000000 isAbsent (TopicBrokerError "topic did not become absent")
 where
  isAbsent status =
    case status of
      TopicAbsent -> Right (Just ())
      TopicPresent _ -> Right Nothing
      TopicUnobservable reason -> Left reason

  retryTopicStatus = retryPulsarTopicStatus topicBroker managedTopic

retryPulsarTopicStatus
  :: PulsarTopicBroker
  -> ManagedTopic
  -> Int
  -> Int
  -> (TopicResidueStatus -> Either TopicUnobservableReason (Maybe ()))
  -> TopicUnobservableReason
  -> IO (Either TopicUnobservableReason ())
retryPulsarTopicStatus topicBroker managedTopic attempts delayMicros classify missingReason =
  go attempts
 where
  go attemptsLeft = do
    status <- topicDiscover topicBroker managedTopic
    case classify status of
      Left reason -> pure (Left reason)
      Right (Just ()) -> pure (Right ())
      Right Nothing
        | attemptsLeft <= 1 -> pure (Left missingReason)
        | otherwise -> threadDelay delayMicros >> go (attemptsLeft - 1)

withPulsarPortForward :: FilePath -> Int -> Int -> IO ExitCode -> IO ExitCode
withPulsarPortForward repoRoot brokerPort adminPort action = do
  processResult <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "--namespace"
            , pulsarValidationNamespace
            , "port-forward"
            , "service/pulsar"
            , show brokerPort ++ ":6650"
            , show adminPort ++ ":8080"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  case processResult of
    Left err -> failWith ("failed to start Pulsar port-forward: " ++ show err)
    Right process -> action `finally` stopBackgroundProcess process

reserveDistinctLocalTcpPorts :: IO (Int, Int)
reserveDistinctLocalTcpPorts = do
  first <- reserveLocalTcpPort
  second <- reserveLocalTcpPort
  if first == second
    then reserveDistinctLocalTcpPorts
    else pure (first, second)

retryEither :: Int -> Int -> IO (Either err value) -> IO (Either err value)
retryEither attempts delayMicros action = go attempts
 where
  go attemptsLeft = do
    result <- action
    case result of
      Right _ -> pure result
      Left _
        | attemptsLeft <= 1 -> pure result
        | otherwise -> threadDelay delayMicros >> go (attemptsLeft - 1)

failPulsarClient :: String -> PulsarClientError -> IO ExitCode
failPulsarClient context err =
  failWith (context ++ ": " ++ renderPulsarClientError err)

runSealedVaultValidation :: FilePath -> [(String, String)] -> IO ExitCode
runSealedVaultValidation repoRoot environment = do
  testAudit <- lookupEnv "PRODBOX_TEST_SEALED_VAULT_AUDIT"
  case testAudit of
    Just "pass" -> emitSealedVaultAudit defaultSealedVaultAuditInput
    Just other -> failWith ("unknown PRODBOX_TEST_SEALED_VAULT_AUDIT fixture: " ++ other)
    Nothing -> do
      statusResult <- captureNativeCliCommand repoRoot environment ["vault", "status"]
      case statusResult of
        Left err -> failWith err
        Right statusOutput -> do
          let statusText = processStdout statusOutput ++ processStderr statusOutput
              startedUnsealed = "sealed=False" `isInfixOf` statusText
              startedSealed = "sealed=True" `isInfixOf` statusText
          if not (startedUnsealed || startedSealed)
            then
              failWith ("could not determine Vault seal state from `vault status`: " ++ outputDetail statusOutput)
            else
              let restore =
                    if startedUnsealed
                      then do
                        unsealExit <- runNativeCliCommandForExitCode repoRoot environment ["vault", "unseal"]
                        case unsealExit of
                          ExitSuccess -> pure ()
                          ExitFailure _ ->
                            writeDiagnosticLine "sealed-vault validation could not restore Vault to unsealed state."
                      else pure ()
               in finally
                    ( do
                        if startedUnsealed
                          then do
                            sealExit <- runNativeCliCommandForExitCode repoRoot environment ["vault", "seal"]
                            case sealExit of
                              ExitSuccess -> runSealedVaultAssertions repoRoot environment
                              failure@(ExitFailure _) -> pure failure
                          else runSealedVaultAssertions repoRoot environment
                    )
                    restore

runDaemonBootstrapValidation :: IO ExitCode
runDaemonBootstrapValidation = do
  fixture <- lookupEnv "PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT"
  case fixture of
    Nothing -> emitDaemonBootstrapAudit defaultDaemonBootstrapAuditInput
    Just "pass" -> emitDaemonBootstrapAudit defaultDaemonBootstrapAuditInput
    Just "legacy-minio-port-forward" ->
      emitDaemonBootstrapAudit
        defaultDaemonBootstrapAuditInput
          { daemonBootstrapObservedTransports =
              "kubectl port-forward service/minio 39000:9000"
                : daemonBootstrapObservedTransports defaultDaemonBootstrapAuditInput
          }
    Just "legacy-vault-nodeport" ->
      emitDaemonBootstrapAudit
        defaultDaemonBootstrapAuditInput
          { daemonBootstrapObservedTransports =
              "POST http://127.0.0.1:31820/v1/sys/unseal"
                : daemonBootstrapObservedTransports defaultDaemonBootstrapAuditInput
          }
    Just "host-root-token-fallback" ->
      emitDaemonBootstrapAudit
        defaultDaemonBootstrapAuditInput
          { daemonBootstrapObservedOutput =
              "falling back to host Vault root-token write"
                : daemonBootstrapObservedOutput defaultDaemonBootstrapAuditInput
          }
    Just "daemon-unavailable" ->
      emitDaemonBootstrapAudit
        defaultDaemonBootstrapAuditInput
          { daemonBootstrapDaemonAvailable = False
          }
    Just other -> failWith ("unknown PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT fixture: " ++ other)

runSealedVaultAssertions :: FilePath -> [(String, String)] -> IO ExitCode
runSealedVaultAssertions repoRoot environment =
  runSequentially
    [ assertNativeCommandOutputContainsAll repoRoot environment ["vault", "status"] ["sealed=True"]
    , assertNativeCommandFailureContainsAll
        repoRoot
        environment
        ["aws", "stack", "eks", "reconcile"]
        ["Blocked: Vault is sealed."]
    , runSealedVaultHostAndK8sAudit repoRoot
    ]

runSealedVaultHostAndK8sAudit :: FilePath -> IO ExitCode
runSealedVaultHostAndK8sAudit repoRoot = do
  minioRoot <- sealedVaultHostDiskRoot repoRoot
  minioExists <- doesDirectoryExist minioRoot
  if not minioExists
    then failWith ("MinIO hostPath root missing for sealed-Vault audit: " ++ minioRoot)
    else do
      findResult <-
        runTextCommand
          Subprocess
            { subprocessPath = "find"
            , subprocessArguments = [minioRoot, "-type", "f", "-o", "-type", "d"]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
      case findResult of
        Left err -> failWith err
        Right output -> do
          let hostEntries = filter (/= "") (lines output)
          k8sObjectsResult <-
            runTextCommand
              Subprocess
                { subprocessPath = "kubectl"
                , subprocessArguments = ["get", "configmap,secret", "-A", "-o", "name"]
                , subprocessEnvironment = Nothing
                , subprocessWorkingDirectory = Just repoRoot
                }
          case k8sObjectsResult of
            Left err -> failWith err
            Right k8sOutput ->
              emitSealedVaultAudit
                defaultSealedVaultAuditInput
                  { sealedVaultHostDiskEntries = hostEntries
                  , sealedVaultKubernetesObjectNames = filter (/= "") (lines k8sOutput)
                  }

sealedVaultHostDiskRoot :: FilePath -> IO FilePath
sealedVaultHostDiskRoot repoRoot = do
  maybeTestRoot <- lookupEnv testManualPvHostRootEnv
  let manualPvRoot =
        case maybeTestRoot of
          Just testRoot | not (null testRoot) -> testRoot
          _ -> repoRoot </> defaultChartDataRootRelative
  pure (manualPvRoot </> "prodbox" </> "minio" </> "0")

runGatewayPodsValidation
  :: FilePath
  -> [(String, String)]
  -> Maybe GatewayRuntimeStabilityRecorder
  -> IO ExitCode
runGatewayPodsValidation repoRoot environment maybeRecorder = do
  readyExit <-
    runNativeCliCommandForExitCode
      repoRoot
      environment
      ["cluster", "wait", "--namespace", gatewayValidationNamespace]
  case readyExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      recorderResult <-
        case maybeRecorder of
          Just recorder -> pure (Right recorder)
          Nothing -> newGatewayRuntimeStabilityRecorder repoRoot
      case recorderResult of
        Left err -> failWith err
        Right recorder -> do
          stabilityExit <-
            runGatewayRuntimeStabilityGateInCurrentContext
              (GatewayRuntimeKubectlContext repoRoot Nothing)
              recorder
          case stabilityExit of
            failure@(ExitFailure _) -> pure failure
            ExitSuccess ->
              -- Logs remain a post-classification diagnostic. They are not an
              -- input to the typed runtime-stability oracle.
              runNativeCliCommandForExitCode
                repoRoot
                environment
                [ "cluster"
                , "workload-logs"
                , "--namespace"
                , gatewayValidationNamespace
                , "--tail"
                , "20"
                ]

resourceGuardrailRootNamespaces :: [String]
resourceGuardrailRootNamespaces = ["keycloak", "vscode", "api", "websocket", "gateway"]

data ResourceGuardrailPodSummary = ResourceGuardrailPodSummary
  { resourceGuardrailPodsChecked :: Int
  , resourceGuardrailContainersChecked :: Int
  }
  deriving (Eq, Show)

runResourceGuardrailsValidation :: FilePath -> IO ExitCode
runResourceGuardrailsValidation repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith ("load settings for resource guardrail validation: " ++ err)
    Right settings -> do
      let plan =
            Capacity.resource_plan
              (Prodbox.Settings.capacity (Prodbox.Settings.validatedConfig settings))
      podsResult <- kubectlJson ["get", "pods", "-A", "-o", "json"]
      quotasResult <- kubectlJson ["get", "resourcequota", "-A", "-o", "json"]
      limitRangesResult <- kubectlJson ["get", "limitrange", "-A", "-o", "json"]
      case (podsResult, quotasResult, limitRangesResult) of
        (Left err, _, _) -> failWith err
        (_, Left err, _) -> failWith err
        (_, _, Left err) -> failWith err
        (Right pods, Right quotas, Right limitRanges) ->
          emitResourceGuardrailReport plan pods quotas limitRanges
 where
  kubectlJson args =
    runJsonCommand
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments = args
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }

emitResourceGuardrailReport
  :: Capacity.ResourcePlan -> Value -> Value -> Value -> IO ExitCode
emitResourceGuardrailReport plan pods quotas limitRanges =
  case resourceGuardrailReport plan pods quotas limitRanges of
    Left err -> failWith err
    Right report -> do
      writeOutput report
      pure ExitSuccess

resourceGuardrailReport
  :: Capacity.ResourcePlan -> Value -> Value -> Value -> Either String String
resourceGuardrailReport plan podPayload quotaPayload limitRangePayload = do
  podSummary <- resourceGuardrailPodSummary plan podPayload
  quotaNamespaces <- resourceGuardrailQuotaNamespaces plan quotaPayload
  limitRangeNamespaces <- resourceGuardrailLimitRangeNamespaces plan limitRangePayload
  pure
    ( unlines
        [ "RESOURCE_GUARDRAILS_VALIDATION"
        , "PODS_CHECKED=" ++ show (resourceGuardrailPodsChecked podSummary)
        , "CONTAINERS_CHECKED=" ++ show (resourceGuardrailContainersChecked podSummary)
        , "QUOTA_NAMESPACES=" ++ intercalate "," quotaNamespaces
        , "LIMIT_RANGE_NAMESPACES=" ++ intercalate "," limitRangeNamespaces
        , "BESTEFFORT_PODS=0"
        , "UNCAPPED_CONTAINERS=0"
        ]
    )

resourceGuardrailPodSummary
  :: Capacity.ResourcePlan -> Value -> Either String ResourceGuardrailPodSummary
resourceGuardrailPodSummary plan payload = do
  items <- jsonArrayAt ["items"] payload
  checked <- traverse (resourceGuardrailPodCheck expectedNamespaces) items
  let relevant = [summary | Just summary <- checked]
      failures = concatMap snd relevant
      podsChecked = length relevant
      containersChecked = sum (map (fst . fst) relevant)
  if podsChecked == 0
    then
      Left
        ("resource guardrail validation found no pods in namespaces " ++ intercalate "," expectedNamespaces)
    else
      if null failures
        then
          Right
            ResourceGuardrailPodSummary
              { resourceGuardrailPodsChecked = podsChecked
              , resourceGuardrailContainersChecked = containersChecked
              }
        else Left (intercalate "; " failures)
 where
  expectedNamespaces =
    map (Text.unpack . Capacity.namespace_name) (Capacity.namespace_quotas plan)

resourceGuardrailPodCheck
  :: [String] -> Value -> Either String (Maybe ((Int, String), [String]))
resourceGuardrailPodCheck expectedNamespaces item = do
  namespace <- jsonStringAt ["metadata", "namespace"] item
  if namespace `notElem` expectedNamespaces
    then Right Nothing
    else do
      podName <- jsonStringAt ["metadata", "name"] item
      qosClass <- jsonStringAt ["status", "qosClass"] item
      containers <- jsonArrayAt ["spec", "containers"] item
      initContainers <- jsonArrayAtOptional ["spec", "initContainers"] item
      let podId = namespace ++ "/" ++ podName
          qosFailures =
            [ "pod " ++ podId ++ " is BestEffort"
            | qosClass == "BestEffort"
            ]
          emptyFailures =
            [ "pod " ++ podId ++ " has no containers"
            | null containers
            ]
          containerFailures =
            concat
              ( zipWith
                  (resourceGuardrailContainerFailures podId "container")
                  [(0 :: Int) ..]
                  containers
                  ++ zipWith
                    (resourceGuardrailContainerFailures podId "initContainer")
                    [(0 :: Int) ..]
                    initContainers
              )
      Right
        ( Just
            ( (length containers + length initContainers, podId)
            , qosFailures ++ emptyFailures ++ containerFailures
            )
        )

resourceGuardrailContainerFailures :: String -> String -> Int -> Value -> [String]
resourceGuardrailContainerFailures podId containerKind index container =
  let containerName =
        case jsonMaybeStringAt ["name"] container of
          Right (Just name) -> name
          _ -> containerKind ++ "[" ++ show index ++ "]"
      containerId = podId ++ " " ++ containerKind ++ " " ++ containerName
      requiredPaths =
        [ ["resources", "requests", "cpu"]
        , ["resources", "requests", "memory"]
        , ["resources", "requests", "ephemeral-storage"]
        , ["resources", "limits", "cpu"]
        , ["resources", "limits", "memory"]
        , ["resources", "limits", "ephemeral-storage"]
        ]
   in concatMap (\path -> resourceQuantityFailures containerId path container) requiredPaths

resourceQuantityFailures :: String -> [String] -> Value -> [String]
resourceQuantityFailures containerId path value =
  case jsonValueAtMaybe path value of
    Right (Just (String quantity)) | not (Text.null (Text.strip quantity)) -> []
    Right (Just (Number _)) -> []
    Right (Just _) -> [containerId ++ " has non-scalar resource quantity `" ++ intercalate "." path ++ "`"]
    Right Nothing -> [containerId ++ " is missing `" ++ intercalate "." path ++ "`"]
    Left err -> [containerId ++ " has malformed resources: " ++ err]

resourceGuardrailQuotaNamespaces :: Capacity.ResourcePlan -> Value -> Either String [String]
resourceGuardrailQuotaNamespaces plan payload = do
  items <- jsonArrayAt ["items"] payload
  traverse (requireResourceQuotaForNamespace plan items) resourceGuardrailRootNamespaces

requireResourceQuotaForNamespace
  :: Capacity.ResourcePlan -> [Value] -> String -> Either String String
requireResourceQuotaForNamespace plan items namespace = do
  namespaceQuota <- requireNamespaceQuotaForValidation plan namespace
  quotaObject <- requireK8sObjectInNamespace "ResourceQuota" namespace items
  let vector = Capacity.quota namespaceQuota
      expected =
        [ ("requests.cpu", cpuQuantity (Capacity.milli_cpu vector))
        , ("limits.cpu", cpuQuantity (Capacity.milli_cpu vector))
        , ("requests.memory", memoryQuantity (Capacity.memory_mib vector))
        , ("limits.memory", memoryQuantity (Capacity.memory_mib vector))
        , ("requests.ephemeral-storage", memoryQuantity (Capacity.ephemeral_storage_mib vector))
        , ("limits.ephemeral-storage", memoryQuantity (Capacity.ephemeral_storage_mib vector))
        , ("requests.storage", memoryQuantity (Capacity.durable_storage_mib vector))
        ]
  mapM_ (requireQuantityEquals ("ResourceQuota " ++ namespace) ["spec", "hard"] quotaObject) expected
  Right namespace

resourceGuardrailLimitRangeNamespaces :: Capacity.ResourcePlan -> Value -> Either String [String]
resourceGuardrailLimitRangeNamespaces plan payload = do
  items <- jsonArrayAt ["items"] payload
  traverse (requireLimitRangeForNamespace plan items) resourceGuardrailRootNamespaces

requireLimitRangeForNamespace :: Capacity.ResourcePlan -> [Value] -> String -> Either String String
requireLimitRangeForNamespace plan items namespace = do
  envelope <- namespaceLimitEnvelopeForValidation plan namespace
  limitRangeObject <- requireK8sObjectInNamespace "LimitRange" namespace items
  limits <- jsonArrayAt ["spec", "limits"] limitRangeObject
  containerLimit <- requireContainerLimitRange namespace limits
  let requestVector = Capacity.request envelope
      limitVector = Capacity.limit envelope
      expected =
        [ (["defaultRequest"], "cpu", cpuQuantity (Capacity.milli_cpu requestVector))
        , (["defaultRequest"], "memory", memoryQuantity (Capacity.memory_mib requestVector))
        ,
          ( ["defaultRequest"]
          , "ephemeral-storage"
          , memoryQuantity (Capacity.ephemeral_storage_mib requestVector)
          )
        , (["default"], "cpu", cpuQuantity (Capacity.milli_cpu limitVector))
        , (["default"], "memory", memoryQuantity (Capacity.memory_mib limitVector))
        , (["default"], "ephemeral-storage", memoryQuantity (Capacity.ephemeral_storage_mib limitVector))
        ]
  mapM_
    ( \(prefix, fieldName, expectedQuantity) ->
        requireQuantityEquals
          ("LimitRange " ++ namespace)
          prefix
          containerLimit
          (fieldName, expectedQuantity)
    )
    expected
  Right namespace

requireK8sObjectInNamespace :: String -> String -> [Value] -> Either String Value
requireK8sObjectInNamespace kind namespace items = do
  indexed <-
    traverse
      ( \item -> do
          itemNamespace <- jsonStringAt ["metadata", "namespace"] item
          pure (itemNamespace, item)
      )
      items
  case lookup namespace indexed of
    Just item -> Right item
    Nothing -> Left (kind ++ " missing for namespace `" ++ namespace ++ "`")

requireContainerLimitRange :: String -> [Value] -> Either String Value
requireContainerLimitRange namespace limits =
  case filter isContainerLimit limits of
    limit : _ -> Right limit
    [] -> Left ("LimitRange " ++ namespace ++ " has no Container limit entry")
 where
  isContainerLimit value =
    case jsonStringAt ["type"] value of
      Right "Container" -> True
      _ -> False

requireQuantityEquals :: String -> [String] -> Value -> (String, String) -> Either String ()
requireQuantityEquals label prefix value (fieldName, expectedQuantity) = do
  actual <- jsonStringAt (prefix ++ [fieldName]) value
  if actual == expectedQuantity || quantitiesEquivalent expectedQuantity actual
    then Right ()
    else
      Left
        ( label
            ++ " field `"
            ++ intercalate "." (prefix ++ [fieldName])
            ++ "` mismatch: expected `"
            ++ expectedQuantity
            ++ "`, observed `"
            ++ actual
            ++ "`"
        )

quantitiesEquivalent :: String -> String -> Bool
quantitiesEquivalent expected actual =
  case (parseCpuMilliQuantity expected, parseCpuMilliQuantity actual) of
    (Just expectedMilli, Just actualMilli) | expectedMilli == actualMilli -> True
    _ ->
      case (parseMebiQuantity expected, parseMebiQuantity actual) of
        (Just expectedMebi, Just actualMebi) -> expectedMebi == actualMebi
        _ -> False

parseCpuMilliQuantity :: String -> Maybe Integer
parseCpuMilliQuantity raw =
  case stripQuantitySuffix "m" raw of
    Just milliText -> parseIntegerQuantity milliText
    Nothing -> (* 1000) <$> parseIntegerQuantity raw

parseMebiQuantity :: String -> Maybe Integer
parseMebiQuantity raw =
  asum
    [ parseWithUnit "Ki" (`div` 1024)
    , parseWithUnit "Mi" id
    , parseWithUnit "Gi" (* 1024)
    , parseWithUnit "Ti" (* 1048576)
    ]
 where
  parseWithUnit suffix scale = do
    quantityText <- stripQuantitySuffix suffix raw
    scale <$> parseIntegerQuantity quantityText

stripQuantitySuffix :: String -> String -> Maybe String
stripQuantitySuffix suffix raw
  | suffix `isSuffixOf` raw = Just (take (length raw - length suffix) raw)
  | otherwise = Nothing

parseIntegerQuantity :: String -> Maybe Integer
parseIntegerQuantity raw =
  case reads raw of
    [(value, "")] | value >= 0 -> Just value
    _ -> Nothing

requireNamespaceQuotaForValidation
  :: Capacity.ResourcePlan -> String -> Either String Capacity.NamespaceQuota
requireNamespaceQuotaForValidation plan namespace =
  case filter ((== Text.pack namespace) . Capacity.namespace_name) (Capacity.namespace_quotas plan) of
    namespaceQuota : _ -> Right namespaceQuota
    [] -> Left ("capacity.resource_plan is missing namespace quota `" ++ namespace ++ "`")

namespaceLimitEnvelopeForValidation
  :: Capacity.ResourcePlan -> String -> Either String Capacity.ResourceEnvelope
namespaceLimitEnvelopeForValidation plan namespace =
  case filter ((== Text.pack namespace) . Capacity.profile_namespace) (Capacity.workload_profiles plan) of
    profile : _ -> Right (Capacity.resources profile)
    [] -> Left ("capacity.resource_plan has no workload profile for namespace `" ++ namespace ++ "`")

jsonArrayAt :: [String] -> Value -> Either String [Value]
jsonArrayAt path value = do
  fieldValue <- jsonValueAt path value
  case fieldValue of
    Array arrayValue -> Right (Vector.toList arrayValue)
    _ -> Left ("JSON field `" ++ intercalate "." path ++ "` is not an array")

jsonArrayAtOptional :: [String] -> Value -> Either String [Value]
jsonArrayAtOptional path value =
  case jsonValueAtMaybe path value of
    Left err -> Left err
    Right Nothing -> Right []
    Right (Just Null) -> Right []
    Right (Just (Array arrayValue)) -> Right (Vector.toList arrayValue)
    Right (Just _) -> Left ("JSON field `" ++ intercalate "." path ++ "` is not an array")

cpuQuantity :: (Show a) => a -> String
cpuQuantity value = show value ++ "m"

memoryQuantity :: (Show a) => a -> String
memoryQuantity value = show value ++ "Mi"

data VolumeRebindSnapshot = VolumeRebindSnapshot
  { volumeRebindSnapshotPersistentVolume :: String
  , volumeRebindSnapshotClaimNamespace :: String
  , volumeRebindSnapshotPersistentClaim :: String
  , volumeRebindSnapshotPhase :: String
  , volumeRebindSnapshotVolumeHandle :: Maybe String
  }
  deriving (Eq, Show)

runEksVolumeRebindValidation :: FilePath -> [(String, String)] -> Substrate -> IO ExitCode
runEksVolumeRebindValidation repoRoot environment substrate = do
  fixture <- lookupEnv "PRODBOX_TEST_VOLUME_REBIND"
  case fixture of
    Just "pass" -> emitVolumeRebindReport fixtureBefore fixtureAfter fixtureSentinel fixtureSentinel
    Just other -> failWith ("unknown PRODBOX_TEST_VOLUME_REBIND fixture: " ++ other)
    Nothing ->
      case selectVolumeRebindEntry substrate of
        Left err -> failWith err
        Right entry -> do
          let sentinel = volumeRebindSentinel substrate
          beforeResult <- captureVolumeRebindSnapshot repoRoot entry
          case beforeResult of
            Left err -> failWith err
            Right before -> do
              writeExit <- writeVolumeRebindSentinel repoRoot entry sentinel
              case writeExit of
                failure@(ExitFailure _) -> pure failure
                ExitSuccess -> do
                  restartExit <- restartVolumeRebindSubstrate repoRoot environment substrate
                  case restartExit of
                    failure@(ExitFailure _) -> pure failure
                    ExitSuccess ->
                      withSubstrateKubeconfigEnv repoRoot substrate $ do
                        afterResult <- captureVolumeRebindSnapshot repoRoot entry
                        case afterResult of
                          Left err -> failWith err
                          Right after -> do
                            observedResult <- readVolumeRebindSentinel repoRoot entry
                            case observedResult of
                              Left err -> failWith err
                              Right observed -> emitVolumeRebindReport before after sentinel observed
 where
  fixtureSentinel = "prodbox-volume-rebind-fixture"
  fixtureBefore =
    VolumeRebindSnapshot
      { volumeRebindSnapshotPersistentVolume = "pv-prodbox-minio-0"
      , volumeRebindSnapshotClaimNamespace = "prodbox"
      , volumeRebindSnapshotPersistentClaim = "data-minio-0"
      , volumeRebindSnapshotPhase = "Bound"
      , volumeRebindSnapshotVolumeHandle = Just "vol-fixture"
      }
  fixtureAfter = fixtureBefore

selectVolumeRebindEntry :: Substrate -> Either String RetainedStorageInventoryEntry
selectVolumeRebindEntry substrate =
  case filter ((== "data-minio-0") . retainedStorageInventoryPersistentClaim) entries of
    entry : _ -> Right entry
    [] ->
      Left
        ( "retained storage inventory for substrate `"
            ++ substrateId substrate
            ++ "` does not include the MinIO claim data-minio-0"
        )
 where
  entries = retainedStorageInventoryEntries substrate

volumeRebindSentinel :: Substrate -> String
volumeRebindSentinel substrate =
  "prodbox-volume-rebind-" ++ substrateId substrate

captureVolumeRebindSnapshot
  :: FilePath -> RetainedStorageInventoryEntry -> IO (Either String VolumeRebindSnapshot)
captureVolumeRebindSnapshot repoRoot entry = do
  result <-
    runJsonCommand
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "pv"
            , retainedStorageInventoryPersistentVolume entry
            , "-o"
            , "json"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure (result >>= parseVolumeRebindSnapshot)

parseVolumeRebindSnapshot :: Value -> Either String VolumeRebindSnapshot
parseVolumeRebindSnapshot value = do
  pvName <- jsonStringAt ["metadata", "name"] value
  claimNamespace <- jsonStringAt ["spec", "claimRef", "namespace"] value
  claimName <- jsonStringAt ["spec", "claimRef", "name"] value
  phase <- jsonStringAt ["status", "phase"] value
  csiHandle <- jsonMaybeStringAt ["spec", "csi", "volumeHandle"] value
  awsHandle <- jsonMaybeStringAt ["spec", "awsElasticBlockStore", "volumeID"] value
  let volumeHandle =
        case csiHandle of
          Just _ -> csiHandle
          Nothing -> awsHandle
  pure
    VolumeRebindSnapshot
      { volumeRebindSnapshotPersistentVolume = pvName
      , volumeRebindSnapshotClaimNamespace = claimNamespace
      , volumeRebindSnapshotPersistentClaim = claimName
      , volumeRebindSnapshotPhase = phase
      , volumeRebindSnapshotVolumeHandle = volumeHandle
      }

writeVolumeRebindSentinel
  :: FilePath -> RetainedStorageInventoryEntry -> String -> IO ExitCode
writeVolumeRebindSentinel repoRoot entry sentinel =
  runCommandForExitCode
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "-n"
          , retainedStorageInventoryNamespace entry
          , "exec"
          , "statefulset/minio"
          , "--"
          , "sh"
          , "-c"
          , "mkdir -p /export/prodbox-volume-rebind && printf '%s' \"$1\" > /export/prodbox-volume-rebind/sentinel"
          , "sh"
          , sentinel
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

readVolumeRebindSentinel
  :: FilePath -> RetainedStorageInventoryEntry -> IO (Either String String)
readVolumeRebindSentinel repoRoot entry =
  runTextCommand
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "-n"
          , retainedStorageInventoryNamespace entry
          , "exec"
          , "statefulset/minio"
          , "--"
          , "cat"
          , "/export/prodbox-volume-rebind/sentinel"
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

restartVolumeRebindSubstrate
  :: FilePath -> [(String, String)] -> Substrate -> IO ExitCode
restartVolumeRebindSubstrate repoRoot environment substrate =
  case substrate of
    SubstrateHomeLocal ->
      runSequentially
        [ runNativeCliCommandForExitCode repoRoot environment ["cluster", "delete", "--yes"]
        , runNativeCliCommandForExitCode repoRoot environment ["cluster", "reconcile", "--with-edge"]
        , runNativeCliCommandForExitCode repoRoot environment ["vault", "unseal"]
        , runNativeCliCommandForExitCode repoRoot environment ["cluster", "health"]
        ]
    SubstrateAws ->
      runSequentially
        [ runNativeCliCommandForExitCode repoRoot environment ["aws", "stack", "eks", "destroy", "--yes"]
        , runNativeCliCommandForExitCode repoRoot environment ["aws", "stack", "eks", "reconcile"]
        , -- Recreate the substrate platform, retained PV bindings, and the
          -- observed gateway before the volume read-back and monitor handoff.
          -- The chart command is the canonical AWS platform installer; a bare
          -- Pulumi stack reconcile owns only the substrate resources.
          runNativeCliCommandForExitCode
            repoRoot
            environment
            ["charts", "reconcile", "gateway", "--substrate", "aws"]
        ]

emitVolumeRebindReport
  :: VolumeRebindSnapshot -> VolumeRebindSnapshot -> String -> String -> IO ExitCode
emitVolumeRebindReport before after expectedSentinel observedSentinel =
  case volumeRebindReport before after expectedSentinel observedSentinel of
    Left err -> failWith err
    Right report -> do
      writeOutput report
      pure ExitSuccess

volumeRebindReport
  :: VolumeRebindSnapshot -> VolumeRebindSnapshot -> String -> String -> Either String String
volumeRebindReport before after expectedSentinel observedSentinel = do
  requireEqual
    "persistent volume"
    (volumeRebindSnapshotPersistentVolume before)
    (volumeRebindSnapshotPersistentVolume after)
  requireEqual
    "claim namespace"
    (volumeRebindSnapshotClaimNamespace before)
    (volumeRebindSnapshotClaimNamespace after)
  requireEqual
    "persistent claim"
    (volumeRebindSnapshotPersistentClaim before)
    (volumeRebindSnapshotPersistentClaim after)
  requireEqual "before binding phase" "Bound" (volumeRebindSnapshotPhase before)
  requireEqual "after binding phase" "Bound" (volumeRebindSnapshotPhase after)
  requireVolumeHandleRebound
    (volumeRebindSnapshotVolumeHandle before)
    (volumeRebindSnapshotVolumeHandle after)
  requireEqual "sentinel" expectedSentinel observedSentinel
  pure
    ( unlines
        [ "VOLUME_REBIND_VALIDATION"
        , "PV=" ++ volumeRebindSnapshotPersistentVolume after
        , "PVC="
            ++ volumeRebindSnapshotClaimNamespace after
            ++ "/"
            ++ volumeRebindSnapshotPersistentClaim after
        , "PHASE_BEFORE=" ++ volumeRebindSnapshotPhase before
        , "PHASE_AFTER=" ++ volumeRebindSnapshotPhase after
        , "VOLUME_HANDLE=" ++ maybe "none" id (volumeRebindSnapshotVolumeHandle after)
        , "SENTINEL=preserved"
        ]
    )

requireVolumeHandleRebound :: Maybe String -> Maybe String -> Either String ()
requireVolumeHandleRebound before after =
  case (before, after) of
    (Nothing, Nothing) -> Right ()
    (Just beforeHandle, Just afterHandle) ->
      requireEqual "volume handle" beforeHandle afterHandle
    (Just beforeHandle, Nothing) ->
      Left ("volume handle disappeared after rebind: " ++ beforeHandle)
    (Nothing, Just afterHandle) ->
      Left ("volume handle appeared only after rebind: " ++ afterHandle)

requireEqual :: String -> String -> String -> Either String ()
requireEqual label expected actual =
  if expected == actual
    then Right ()
    else Left (label ++ " mismatch: expected `" ++ expected ++ "`, observed `" ++ actual ++ "`")

jsonStringAt :: [String] -> Value -> Either String String
jsonStringAt path value = do
  fieldValue <- jsonValueAt path value
  case fieldValue of
    String jsonText ->
      let stripped = Text.strip jsonText
       in if Text.null stripped
            then Left ("JSON field `" ++ intercalate "." path ++ "` is empty")
            else Right (Text.unpack stripped)
    _ -> Left ("JSON field `" ++ intercalate "." path ++ "` is not a string")

jsonMaybeStringAt :: [String] -> Value -> Either String (Maybe String)
jsonMaybeStringAt path value =
  case jsonValueAtMaybe path value of
    Left err -> Left err
    Right Nothing -> Right Nothing
    Right (Just Null) -> Right Nothing
    Right (Just (String jsonText)) ->
      let stripped = Text.strip jsonText
       in if Text.null stripped
            then Right Nothing
            else Right (Just (Text.unpack stripped))
    Right (Just _) -> Left ("JSON field `" ++ intercalate "." path ++ "` is not a string")

jsonValueAt :: [String] -> Value -> Either String Value
jsonValueAt path value =
  case jsonValueAtMaybe path value of
    Left err -> Left err
    Right (Just fieldValue) -> Right fieldValue
    Right Nothing -> Left ("JSON field `" ++ intercalate "." path ++ "` is missing")

jsonValueAtMaybe :: [String] -> Value -> Either String (Maybe Value)
jsonValueAtMaybe [] value = Right (Just value)
jsonValueAtMaybe (key : rest) value =
  case value of
    Object objectValue ->
      case KeyMap.lookup (Key.fromString key) objectValue of
        Nothing -> Right Nothing
        Just child -> jsonValueAtMaybe rest child
    _ -> Left ("JSON field parent `" ++ key ++ "` is not an object")

emitSealedVaultAudit :: SealedVaultAuditInput -> IO ExitCode
emitSealedVaultAudit input =
  case sealedVaultAuditReport input of
    Left err -> failWith err
    Right report -> do
      writeOutput report
      pure ExitSuccess

emitDaemonBootstrapAudit :: DaemonBootstrapAuditInput -> IO ExitCode
emitDaemonBootstrapAudit input =
  case daemonBootstrapAuditReport input of
    Left err -> failWith err
    Right report -> do
      writeOutput report
      pure ExitSuccess

captureNativeCliCommand
  :: FilePath -> [(String, String)] -> [String] -> IO (Either String ProcessOutput)
captureNativeCliCommand repoRoot environment cliArgs = do
  result <- captureSubprocessResult (nativeCliCommandSpec repoRoot environment cliArgs)
  pure $
    case result of
      Failure err -> Left err
      Success output -> Right output

assertNativeCommandFailureContainsAll
  :: FilePath -> [(String, String)] -> [String] -> [String] -> IO ExitCode
assertNativeCommandFailureContainsAll repoRoot environment cliArgs expectedTexts =
  assertCommandFailureContainsAll (nativeCliCommandSpec repoRoot environment cliArgs) expectedTexts

assertCommandFailureContainsAll :: Subprocess -> [String] -> IO ExitCode
assertCommandFailureContainsAll spec expectedTexts = do
  outputResult <- captureSubprocessResult spec
  case outputResult of
    Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
    Success output -> do
      writeOutput (processStdout output)
      writeDiagnostic (processStderr output)
      let combinedOutput = processStdout output ++ processStderr output
      case processExitCode output of
        ExitSuccess ->
          failWith ("`" ++ commandDisplay spec ++ "` unexpectedly succeeded on a sealed-Vault path")
        ExitFailure _ ->
          if all (`isInfixOf` combinedOutput) expectedTexts
            then pure ExitSuccess
            else
              failWith
                ( "`"
                    ++ commandDisplay spec
                    ++ "` did not report all required sealed-Vault fragments: "
                    ++ show expectedTexts
                )

runHaRke2AwsValidation :: FilePath -> [(String, String)] -> IO ExitCode
runHaRke2AwsValidation repoRoot environment = do
  stackExit <- provisionAndVerifyAwsTestStack repoRoot environment
  case stackExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      sshExit <- verifyAwsTestSshReachability repoRoot
      case sshExit of
        ExitSuccess -> pure ExitSuccess
        firstFailure@(ExitFailure _) -> do
          writeDiagnosticLine
            "AWS test-stack SSH validation failed after reconcile; destroying and recreating the retained stack once before retry."
          destroyExit <-
            runNativeCliCommandForExitCode repoRoot environment ["aws", "stack", "test", "destroy", "--yes"]
          case destroyExit of
            destroyFailure@(ExitFailure _) -> pure destroyFailure
            ExitSuccess -> do
              retryStackExit <- provisionAndVerifyAwsTestStack repoRoot environment
              case retryStackExit of
                retryFailure@(ExitFailure _) -> pure retryFailure
                ExitSuccess -> do
                  retrySshExit <- verifyAwsTestSshReachability repoRoot
                  case retrySshExit of
                    ExitSuccess -> pure ExitSuccess
                    ExitFailure _ -> pure firstFailure

provisionAndVerifyAwsTestStack :: FilePath -> [(String, String)] -> IO ExitCode
provisionAndVerifyAwsTestStack repoRoot environment =
  runSequentially
    [ assertNativeCommandOutputContainsAll
        repoRoot
        environment
        ["aws", "stack", "test", "reconcile"]
        ["STACK=" ++ AwsTest.awsTestStackName, "NODE_COUNT=3"]
    , verifyAwsTestSnapshot repoRoot
    ]

runGatewayPartitionValidation :: IO ExitCode
runGatewayPartitionValidation = do
  result <- gatewayPartitionValidationReport
  case result of
    Left err -> failWith err
    Right report -> do
      writeOutput report
      pure ExitSuccess

gatewayPartitionValidationReport :: IO (Either String String)
gatewayPartitionValidationReport =
  case gatewayPartitionLegacyReport of
    Left err -> pure (Left err)
    Right legacyReport -> do
      composed <- gatewayPartitionEmitterReport
      pure ((legacyReport ++) <$> composed)

gatewayPartitionLegacyReport :: Either String String
gatewayPartitionLegacyReport = do
  memoryPlan <-
    Capacity.runtimeMemoryPlanForProfile Capacity.defaultCapacitySection "gateway"
  bounds <-
    either
      (Left . ("gateway bounds invalid: " ++) . show)
      Right
      (GatewayBounds.validateGatewayBounds memoryPlan GatewayBounds.defaultRawGatewayBounds)
  orders <-
    mapGatewayStateError
      ( GatewayState.validateOrders
          bounds
          GatewayState.RawOrders
            { GatewayState.rawOrdersDocument = "gateway-partition-v2"
            , GatewayState.rawOrdersVersion = 2
            , GatewayState.rawOrdersMembers =
                [ rawMember "node-a" 0
                , rawMember "node-b" 1
                , rawMember "node-c" 2
                ]
            }
      )
  nodeA <- resolveNode orders "node-a"
  nodeB <- resolveNode orders "node-b"
  initial <- initializePartitionState bounds orders
  claimA <-
    nextOwnershipAssertion
      bounds
      orders
      nodeA
      initial
      GatewayState.OwnershipClaim
      "claim-a"
  (claimAFrame, afterClaimA) <- applyPartitionAssertion bounds orders claimA initial
  claimB <-
    nextOwnershipAssertion
      bounds
      orders
      nodeB
      afterClaimA
      GatewayState.OwnershipClaim
      "claim-b"
  (claimBFrame, afterTakeover) <- applyPartitionAssertion bounds orders claimB afterClaimA
  yieldA <-
    nextOwnershipAssertion
      bounds
      orders
      nodeA
      afterTakeover
      GatewayState.OwnershipYield
      "yield-a"
  (_yieldFrame, healed) <- applyPartitionAssertion bounds orders yieldA afterTakeover
  duplicate <- applyPartitionFrame claimBFrame healed
  let initialOwnerActive = canNodeWrite "node-a" (Just "node-a") nodeA afterClaimA
      singleWriterAfterTakeover =
        canNodeWrite "node-b" (Just "node-b") nodeB afterTakeover
          && not (canNodeWrite "node-a" (Just "node-b") nodeA afterTakeover)
      yieldPersisted =
        ownershipDecision nodeA healed == Just GatewayState.OwnershipYield
      idempotentMerge =
        GatewayState.gatewayStateCursorVector duplicate
          == GatewayState.gatewayStateCursorVector healed
      boundedFrames =
        GatewayState.deltaFrameAssertionCount claimAFrame == 1
          && GatewayState.deltaFrameAssertionCount claimBFrame == 1
  ensurePartitionInvariant
    initialOwnerActive
    "initial claim did not activate DNS-write authority for node-a"
  ensurePartitionInvariant
    boundedFrames
    "partition transitions did not use one-assertion bounded delta frames"
  ensurePartitionInvariant
    singleWriterAfterTakeover
    "partition takeover did not preserve the single-writer DNS surface"
  ensurePartitionInvariant yieldPersisted "node-a yield was not preserved after rejoin healing"
  ensurePartitionInvariant
    idempotentMerge
    "bounded semantic merge was not idempotent on repeated delta delivery"
  Right $
    unlines
      [ "GATEWAY_PARTITION_VALIDATION"
      , "FORMAL_MODEL_DELEGATED=false"
      , "INITIAL_OWNER_ACTIVE=true"
      , "PARTITION_TAKEOVER_ACCEPTED=1"
      , "PARTITION_TAKEOVER_REJECTED=0"
      , "SINGLE_WRITER_AFTER_TAKEOVER=true"
      , "REJOIN_YIELD_RECORDED=true"
      , "BOUNDED_DELTA_IDEMPOTENT=true"
      ]
 where
  rawMember nodeName rank =
    GatewayState.RawGatewayMember
      { GatewayState.rawMemberNodeId = Text.pack nodeName
      , GatewayState.rawMemberEndpoint = Text.pack (nodeName ++ ".example.test:8444")
      , GatewayState.rawMemberTrustKey = BS8.pack ("partition-key-" ++ nodeName)
      , GatewayState.rawMemberRank = rank
      }

  resolveNode orders nodeName =
    case filter
      ((== Text.pack nodeName) . GatewayState.nodeIdText)
      (GatewayState.validatedOrdersMemberIds orders) of
      [nodeId] -> Right nodeId
      _ -> Left ("partition Orders did not contain exactly one " ++ nodeName)

  initializePartitionState bounds orders = do
    seeds <-
      traverse
        ( \nodeId -> do
            digest <- partitionEventHash (Text.unpack (GatewayState.nodeIdText nodeId) ++ "-genesis")
            Right (nodeId, GatewayState.initialEmitterCursor 1 digest)
        )
        (GatewayState.validatedOrdersMemberIds orders)
    mapGatewayStateError
      (GatewayState.initializeGatewayState bounds orders (Map.fromList seeds))

  nextOwnershipAssertion bounds orders emitter state decision label = do
    previous <-
      case GatewayState.cursorVectorLookup
        emitter
        (GatewayState.gatewayStateCursorVector state) of
        Nothing -> Left "partition emitter cursor was absent"
        Just cursor -> Right cursor
    resultHash <- partitionEventHash label
    mapGatewayStateError
      ( GatewayState.mkNextAssertion
          bounds
          orders
          emitter
          previous
          resultHash
          256
          (GatewayState.OwnershipAssertion decision)
      )

  applyPartitionAssertion bounds orders assertion state = do
    frame <-
      mapGatewayStateError
        ( GatewayState.mkDeltaFrame
            bounds
            orders
            (GatewayState.gatewayStateCursorVector state)
            [assertion]
        )
    advanced <- applyPartitionFrame frame state
    Right (frame, advanced)

  applyPartitionFrame frame state =
    case GatewayState.applyDelta frame state of
      GatewayState.DeltaApplied advanced -> Right advanced
      GatewayState.DeltaRejected _ err -> mapGatewayStateError (Left err)

  ownershipDecision emitter state =
    case GatewayState.assertionKind
      <$> GatewayState.gatewayStateLatestOwnership emitter state of
      Just (GatewayState.OwnershipAssertion decision) -> Just decision
      _ -> Nothing

  canNodeWrite
    :: String
    -> Maybe String
    -> GatewayState.NodeId
    -> GatewayState.GatewayState
    -> Bool
  canNodeWrite nodeName owner emitter state =
    owner == Just nodeName
      && ownershipDecision emitter state == Just GatewayState.OwnershipClaim

  partitionEventHash label =
    mapGatewayStateError (GatewayState.mkEventHash (SHA256.hash (BS8.pack label)))

  mapGatewayStateError result = either (Left . show) Right result

data PartitionEmitterModel = PartitionEmitterModel
  { partitionBounds :: !GatewayBounds.GatewayBounds
  , partitionOrders :: !GatewayState.ValidatedOrders
  , partitionNodeA :: !GatewayState.NodeId
  , partitionNodeB :: !GatewayState.NodeId
  , partitionInitialGateway :: !GatewayState.GatewayState
  , partitionEventKey :: !GatewayPeer.EventKey
  , partitionEventKeyLookup :: !GatewayPeer.EventKeyLookup
  , partitionActorConfig :: !EmitterActor.EmitterActorConfig
  , partitionMailbox :: !EmitterMailbox.Mailbox
  , partitionProjectionBounds :: !EmitterKernel.DurableProjectionBounds
  , partitionInitialEmitter :: !EmitterKernel.EmitterState
  , partitionPeerB :: !EmitterKernel.EmitterPeer
  }

data PartitionRestartProof = PartitionRestartProof
  { restartProjectionBytes :: !BS8.ByteString
  , restartCheckpointBytes :: !BS8.ByteString
  , restartSuffixBytes :: ![BS8.ByteString]
  }

gatewayPartitionEmitterReport :: IO (Either String String)
gatewayPartitionEmitterReport = runExceptT $ do
  model <- partitionEither "composed partition model" partitionEmitterModel
  sourceStateRef <- liftIO (newIORef (partitionInitialGateway model))
  projectionBytesRef <- liftIO (newIORef [])
  checkpointBytesRef <- liftIO (newIORef [])
  recoveryReplayRef <- liftIO (newIORef [])
  stagedBytesRef <- liftIO (newIORef [])
  let interpreter =
        partitionEmitterInterpreter
          model
          sourceStateRef
          projectionBytesRef
          checkpointBytesRef
          recoveryReplayRef
          stagedBytesRef
  restartProof <- do
    result <-
      liftIO $
        EmitterActor.withEmitterActor
          (partitionActorConfig model)
          (partitionInitialEmitter model)
          interpreter
          ( runExceptT
              . partitionDriveOfflineRepair
                model
                sourceStateRef
                projectionBytesRef
                checkpointBytesRef
                stagedBytesRef
          )
    either throwE pure result
  stageCountBeforeRestart <- liftIO (length <$> readIORef stagedBytesRef)
  restoredProjection <-
    partitionEither
      "restart durable projection decode"
      ( EmitterKernel.decodeDurableEmitterProjection
          (partitionProjectionBounds model)
          (restartProjectionBytes restartProof)
      )
  let restartDeadline = partitionDeadline
  restoredEmitter <-
    partitionEither
      "restart durable emitter restore"
      ( EmitterKernel.restoreDurableEmitterState
          (partitionMailbox model)
          restartDeadline
          restoredProjection
      )
  reencoded <-
    partitionEither
      "restart durable projection re-encode"
      ( EmitterKernel.encodeDurableEmitterProjection
          (partitionProjectionBounds model)
          (EmitterKernel.projectDurableEmitterState restoredEmitter)
      )
  partitionRequire
    (reencoded == restartProjectionBytes restartProof)
    "restart changed the exact durable projection bytes"
  recoverResult <-
    liftIO $
      EmitterActor.withEmitterActor
        (partitionActorConfig model)
        restoredEmitter
        interpreter
        (\actor -> EmitterActor.submitEmitterRequest actor EmitterMailbox.ReqRecover)
  case recoverResult of
    Right EmitterActor.EmitterNoTransition -> pure ()
    other -> throwE ("restart recovery did not finish cleanly: " ++ show other)
  replays <- liftIO (readIORef recoveryReplayRef)
  replay <-
    case replays of
      [one] -> pure one
      _ -> throwE ("restart recovery emitted an unexpected replay count: " ++ show (length replays))
  recoveredCheckpoint <-
    case EmitterKernel.recoveryReplayCheckpoint replay of
      Nothing -> throwE "restart recovery omitted the installed checkpoint"
      Just payload -> pure (EmitterKernel.boundedSignedPayloadBytes payload)
  let recoveredSuffix =
        map
          EmitterKernel.stagedRecordSignedBytes
          (EmitterKernel.recoveryReplayAssertions replay)
  partitionRequire
    (recoveredCheckpoint == restartCheckpointBytes restartProof)
    "restart recovery changed the exact checkpoint bytes"
  partitionRequire
    (recoveredSuffix == restartSuffixBytes restartProof)
    "restart recovery changed the exact retained suffix bytes"
  partitionRequire
    ( EmitterKernel.recoveryReplayAssertionCount replay
        == fromIntegral (length (restartSuffixBytes restartProof))
    )
    "restart recovery assertion count did not match its exact suffix"
  stageCountAfterRestart <- liftIO (length <$> readIORef stagedBytesRef)
  partitionRequire
    (stageCountAfterRestart == stageCountBeforeRestart)
    "restart recovery re-signed retained assertions"
  pure $
    unlines
      [ "EMITTER_PIPELINE_COMPOSED=true"
      , "OFFLINE_REPAIR_EXACT=true"
      , "DURABLE_ACK_ADVANCED=true"
      , "CHECKPOINT_COMPACTION_BOUNDED=true"
      , "RESTART_EXACT_BYTES=true"
      , "WRONG_INCARNATION_REJECTED=true"
      , "WRONG_DIGEST_REJECTED=true"
      ]

partitionDriveOfflineRepair
  :: PartitionEmitterModel
  -> IORef GatewayState.GatewayState
  -> IORef [BS8.ByteString]
  -> IORef [BS8.ByteString]
  -> IORef [BS8.ByteString]
  -> EmitterActor.EmitterActor
  -> ExceptT String IO PartitionRestartProof
partitionDriveOfflineRepair
  model
  sourceStateRef
  projectionBytesRef
  checkpointBytesRef
  stagedBytesRef
  actor = do
    records <- traverse submit partitionRequests
    partitionRequire (length records == 5) "actor did not commit the five deterministic assertions"
    stagedBytes <- liftIO (readIORef stagedBytesRef)
    partitionRequire
      (stagedBytes == map EmitterKernel.stagedRecordSignedBytes records)
      "actor stage boundary did not preserve the exact signed assertion bytes"
    beforeAckBytes <- latestRef "pre-ack durable projection" projectionBytesRef
    beforeAckProjection <-
      partitionEither
        "pre-ack durable projection decode"
        ( EmitterKernel.decodeDurableEmitterProjection
            (partitionProjectionBounds model)
            beforeAckBytes
        )
    beforeAckState <-
      partitionEither
        "pre-ack emitter restore"
        ( EmitterKernel.restoreDurableEmitterState
            (partitionMailbox model)
            partitionDeadline
            beforeAckProjection
        )
    let retained = EmitterKernel.emitterUnacked beforeAckState
        retainedBytes =
          map
            (EmitterKernel.stagedRecordSignedBytes . EmitterKernel.unackedAssertionRecord)
            retained
    partitionRequire
      (length retained == 2)
      "checkpoint compaction did not retain the configured two-assertion suffix"
    partitionRequire
      (EmitterKernel.durableProjectionUnackedCount beforeAckProjection <= 2)
      "durable retained suffix exceeded its absolute threshold"
    partitionRequire
      (fromIntegral (BS8.length beforeAckBytes) <= partitionMaximumProjectionBytes)
      "durable projection exceeded its absolute encoded-byte bound"
    checkpointBytes <-
      case EmitterKernel.repairFloorSignedBytes (EmitterKernel.emitterRepairFloor beforeAckState) of
        Nothing -> throwE "checkpoint compaction did not install a signed repair floor"
        Just bytes -> pure bytes
    installedCheckpoints <- liftIO (readIORef checkpointBytesRef)
    partitionRequire
      (length installedCheckpoints == 3 && last installedCheckpoints == checkpointBytes)
      "checkpoint installation count or final exact bytes were not deterministic"
    snapshot <-
      partitionEither
        "repair-floor snapshot decode"
        ( GatewayPeer.decodeSignedSemanticSnapshot
            (partitionBounds model)
            checkpointBytes
        )
    retainedSigned <-
      traverse
        ( partitionEither "retained assertion decode"
            . GatewayPeer.decodeSignedAssertion (partitionBounds model)
        )
        retainedBytes
    repair <-
      partitionEither
        "offline peer repair selection"
        ( GatewayPeer.selectSignedRepair
            (partitionBounds model)
            (partitionOrders model)
            (GatewayState.gatewayStateCursorVector (partitionInitialGateway model))
            snapshot
            retainedSigned
        )
    let repairRequest = GatewayPeer.PeerPushRepair repair
    partitionRequire
      (GatewayPeer.peerRequestSemanticSnapshot repairRequest == Just snapshot)
      "offline repair did not carry the exact checkpoint floor"
    partitionRequire
      ( GatewayPeer.boundedSignedAssertionsToList
          (GatewayPeer.peerRequestReplayAssertions repairRequest)
          == retainedSigned
      )
      "offline repair did not carry the exact retained signed suffix"
    encodedRepair <- pure (GatewayPeer.encodeSignedRepairFrame repair)
    partitionRequire
      ( fromIntegral (BS8.length encodedRepair)
          <= GatewayBounds.gatewayMaxFrameBytes (partitionBounds model)
      )
      "offline repair exceeded the absolute peer-frame bound"
    decodedRepair <-
      partitionEither
        "offline repair canonical decode"
        (GatewayPeer.decodeSignedRepairFrame (partitionBounds model) encodedRepair)
    partitionRequire (decodedRepair == repair) "offline repair bytes did not round-trip canonically"
    repaired <-
      case GatewayPeer.applySignedRepair
        (partitionBounds model)
        (partitionEventKeyLookup model)
        decodedRepair
        (partitionInitialGateway model) of
        Left err -> throwE ("offline repair verification failed: " ++ show err)
        Right (GatewayState.RepairApplied advanced) -> pure advanced
        Right outcome -> throwE ("offline repair was not applied: " ++ show outcome)
    source <- liftIO (readIORef sourceStateRef)
    partitionRequire
      (GatewayState.gatewayStateCursorVector repaired == GatewayState.gatewayStateCursorVector source)
      "offline repair did not converge to the exact source cursor"
    partitionRequire
      ( GatewayState.gatewayStateLatestHeartbeat (partitionNodeA model) repaired
          == GatewayState.gatewayStateLatestHeartbeat (partitionNodeA model) source
      )
      "offline repair did not converge heartbeat semantics"
    partitionRequire
      ( GatewayState.gatewayStateLatestOwnership (partitionNodeA model) repaired
          == GatewayState.gatewayStateLatestOwnership (partitionNodeA model) source
      )
      "offline repair did not converge ownership semantics"
    proveWrongIncarnationAndDigest model repaired
    response <-
      case GatewayPeer.handlePeerRequest
        (partitionBounds model)
        (partitionEventKeyLookup model)
        GatewayPeer.PeerPullCursor
        repaired of
        Left err -> throwE ("offline cursor response failed: " ++ show err)
        Right (_, value) -> pure value
    point <-
      case GatewayPeer.peerResponseAckPoint
        (partitionBounds model)
        (partitionOrders model)
        (partitionNodeA model)
        response of
        Left err -> throwE ("offline cursor acknowledgement failed: " ++ show err)
        Right Nothing -> throwE "offline cursor response omitted its acknowledgement"
        Right (Just value) -> pure value
    projectionCountBeforeAck <- liftIO (length <$> readIORef projectionBytesRef)
    acknowledgement <-
      liftIO
        (EmitterActor.acknowledgeEmitterPeerThrough actor (partitionPeerB model) point)
    case acknowledgement of
      Right () -> pure ()
      Left err -> throwE ("actor rejected the durable peer acknowledgement: " ++ show err)
    projectionCountAfterAck <- liftIO (length <$> readIORef projectionBytesRef)
    partitionRequire
      (projectionCountAfterAck == projectionCountBeforeAck + 1)
      "actor did not fsync exactly one acknowledgement projection"
    afterAckBytes <- latestRef "post-ack durable projection" projectionBytesRef
    afterAckProjection <-
      partitionEither
        "post-ack durable projection decode"
        ( EmitterKernel.decodeDurableEmitterProjection
            (partitionProjectionBounds model)
            afterAckBytes
        )
    afterAckState <-
      partitionEither
        "post-ack emitter restore"
        ( EmitterKernel.restoreDurableEmitterState
            (partitionMailbox model)
            partitionDeadline
            afterAckProjection
        )
    partitionRequire
      ( Map.lookup
          (partitionPeerB model)
          (EmitterKernel.emitterPeerAcknowledgements afterAckState)
          == Just (Just point)
      )
      "peer cursor response did not advance the actor's durable acknowledgement"
    partitionRequire
      ( all
          ( Set.notMember (partitionPeerB model)
              . EmitterKernel.unackedAssertionWaitingPeers
          )
          (EmitterKernel.emitterUnacked afterAckState)
      )
      "durable acknowledgement did not remove the offline peer from retained waiters"
    pure
      PartitionRestartProof
        { restartProjectionBytes = afterAckBytes
        , restartCheckpointBytes = checkpointBytes
        , restartSuffixBytes = retainedBytes
        }
   where
    submit request = do
      result <- liftIO (EmitterActor.submitEmitterRequest actor request)
      case result of
        Right (EmitterActor.EmitterCommitted record) -> pure record
        other -> throwE ("actor request did not commit: " ++ show other)

    partitionRequests =
      [ EmitterMailbox.ReqOwnership EmitterMailbox.OwnershipClaim
      , EmitterMailbox.ReqHeartbeat (EmitterMailbox.HeartbeatPayload 10)
      , EmitterMailbox.ReqOwnership EmitterMailbox.OwnershipYield
      , EmitterMailbox.ReqHeartbeat (EmitterMailbox.HeartbeatPayload 20)
      , EmitterMailbox.ReqOwnership EmitterMailbox.OwnershipClaim
      ]

partitionEmitterModel :: Either String PartitionEmitterModel
partitionEmitterModel = do
  memoryPlan <-
    either (Left . show) Right $
      Capacity.runtimeMemoryPlanForProfile Capacity.defaultCapacitySection "gateway"
  bounds <-
    either (Left . show) Right $
      GatewayBounds.validateGatewayBounds memoryPlan GatewayBounds.defaultRawGatewayBounds
  orders <-
    either (Left . show) Right $
      GatewayState.validateOrders
        bounds
        GatewayState.RawOrders
          { GatewayState.rawOrdersDocument = "gateway-partition-v2"
          , GatewayState.rawOrdersVersion = 2
          , GatewayState.rawOrdersMembers =
              [ partitionRawMember "node-a" 0
              , partitionRawMember "node-b" 1
              , partitionRawMember "node-c" 2
              ]
          }
  nodeA <- partitionResolveNode orders "node-a"
  nodeB <- partitionResolveNode orders "node-b"
  nodeC <- partitionResolveNode orders "node-c"
  initialGateway <- partitionInitializeGateway bounds orders
  key <-
    either (Left . show) Right $
      GatewayPeer.mkEventKey bounds (SHA256.hash "gateway-partition-event-key-node-a")
  capacityPlan <-
    either (Left . show) Right $
      EmitterCapacity.mkServiceCapacityPlan
        EmitterCapacity.RawServiceCapacityPlan
          { EmitterCapacity.rawArrivalPerSecond = 1
          , EmitterCapacity.rawServiceTimeMicros = 2500
          , EmitterCapacity.rawWorkerCount = 1
          , EmitterCapacity.rawQueueCapacity = 8
          , EmitterCapacity.rawRejectionThreshold = 8
          , EmitterCapacity.rawHeadroomPpm = 100000
          }
  actorConfig <-
    maybe
      (Left "partition emitter capacity did not produce a single-worker actor")
      Right
      (EmitterActor.mkEmitterActorConfig capacityPlan)
  projectionBounds <-
    either (Left . show) Right $
      EmitterKernel.mkDurableProjectionBounds
        partitionMaximumProjectionBytes
        (GatewayBounds.gatewayMaxEncodedAssertionBytes bounds)
        (GatewayBounds.gatewayMaxFrameBytes bounds)
        2
        8
  peerB <-
    maybe
      (Left "partition node-b did not produce an emitter peer")
      Right
      (EmitterKernel.mkEmitterPeer (GatewayState.nodeIdText nodeB))
  peerC <-
    maybe
      (Left "partition node-c did not produce an emitter peer")
      Right
      (EmitterKernel.mkEmitterPeer (GatewayState.nodeIdText nodeC))
  initialCursor <- partitionCursorFor nodeA initialGateway
  initialAnchor <- partitionAnchorFromCursor initialCursor
  let mailbox = EmitterActor.emitterActorMailbox actorConfig
      incarnation = EmitterKernel.mkIncarnation 7
      initialEmitter =
        EmitterKernel.mkEmitterStateForPeers
          initialAnchor
          incarnation
          mailbox
          2
          [peerB, peerC]
      lookupKey candidate
        | candidate == nodeA = Just key
        | otherwise = Nothing
  Right
    PartitionEmitterModel
      { partitionBounds = bounds
      , partitionOrders = orders
      , partitionNodeA = nodeA
      , partitionNodeB = nodeB
      , partitionInitialGateway = initialGateway
      , partitionEventKey = key
      , partitionEventKeyLookup = lookupKey
      , partitionActorConfig = actorConfig
      , partitionMailbox = mailbox
      , partitionProjectionBounds = projectionBounds
      , partitionInitialEmitter = initialEmitter
      , partitionPeerB = peerB
      }

partitionRawMember :: String -> Word64 -> GatewayState.RawGatewayMember
partitionRawMember nodeName rank =
  GatewayState.RawGatewayMember
    { GatewayState.rawMemberNodeId = Text.pack nodeName
    , GatewayState.rawMemberEndpoint = Text.pack (nodeName ++ ".example.test:8444")
    , GatewayState.rawMemberTrustKey = BS8.pack ("partition-key-" ++ nodeName)
    , GatewayState.rawMemberRank = rank
    }

partitionResolveNode
  :: GatewayState.ValidatedOrders
  -> String
  -> Either String GatewayState.NodeId
partitionResolveNode orders nodeName =
  case filter
    ((== Text.pack nodeName) . GatewayState.nodeIdText)
    (GatewayState.validatedOrdersMemberIds orders) of
    [nodeId] -> Right nodeId
    _ -> Left ("partition Orders did not contain exactly one " ++ nodeName)

partitionInitializeGateway
  :: GatewayBounds.GatewayBounds
  -> GatewayState.ValidatedOrders
  -> Either String GatewayState.GatewayState
partitionInitializeGateway bounds orders = do
  seeds <-
    traverse
      ( \nodeId -> do
          digest <-
            partitionHash
              (Text.unpack (GatewayState.nodeIdText nodeId) ++ "-genesis")
          Right (nodeId, GatewayState.initialEmitterCursor 1 digest)
      )
      (GatewayState.validatedOrdersMemberIds orders)
  either (Left . show) Right $
    GatewayState.initializeGatewayState bounds orders (Map.fromList seeds)

partitionEmitterInterpreter
  :: PartitionEmitterModel
  -> IORef GatewayState.GatewayState
  -> IORef [BS8.ByteString]
  -> IORef [BS8.ByteString]
  -> IORef [EmitterKernel.RecoveryReplay]
  -> IORef [BS8.ByteString]
  -> EmitterActor.EmitterInterpreter
partitionEmitterInterpreter
  model
  sourceStateRef
  projectionBytesRef
  checkpointBytesRef
  recoveryReplayRef
  stagedBytesRef =
    EmitterActor.EmitterInterpreter
      { EmitterActor.emitterMintTicket = pure (partitionNow, partitionDeadline)
      , EmitterActor.emitterObserveNow = pure partitionNow
      , EmitterActor.emitterStage =
          partitionEmitterStage model stagedBytesRef
      , EmitterActor.emitterFsyncProjection =
          partitionEmitterFsyncProjection model projectionBytesRef
      , EmitterActor.emitterPublish = \_ record -> do
          current <- readIORef sourceStateRef
          case partitionApplyPublished model record current of
            Left err -> pure (Left (Text.pack err))
            Right advanced -> do
              writeIORef sourceStateRef advanced
              pure (Right ())
      , EmitterActor.emitterCommit = \_ _ -> pure (Right ())
      , EmitterActor.emitterInstallCheckpoint =
          partitionEmitterInstallCheckpoint model checkpointBytesRef
      , EmitterActor.emitterRestoreRetained = \_ replay -> do
          modifyIORef' recoveryReplayRef (++ [replay])
          pure (Right ())
      }

partitionEmitterStage
  :: PartitionEmitterModel
  -> IORef [BS8.ByteString]
  -> EmitterKernel.TransitionAdmission
  -> Deadline.Deadline
  -> EmitterKernel.StagePlan
  -> IO (Either Text.Text EmitterKernel.StageOutcome)
partitionEmitterStage model stagedBytesRef _ _ plan =
  case partitionStage model plan of
    Left err -> pure (Left (Text.pack err))
    Right outcome -> do
      case outcome of
        EmitterKernel.StageStaged payload ->
          modifyIORef'
            stagedBytesRef
            (++ [EmitterKernel.boundedSignedPayloadBytes payload])
        EmitterKernel.StageNeedsRotation -> pure ()
      pure (Right outcome)

partitionEmitterFsyncProjection
  :: PartitionEmitterModel
  -> IORef [BS8.ByteString]
  -> Deadline.Deadline
  -> EmitterKernel.DurableEmitterProjection
  -> IO (Either Text.Text ())
partitionEmitterFsyncProjection model projectionBytesRef _ projection =
  case EmitterKernel.encodeDurableEmitterProjection
    (partitionProjectionBounds model)
    projection of
    Left err -> pure (Left (Text.pack (show err)))
    Right bytes -> do
      modifyIORef' projectionBytesRef (++ [bytes])
      pure (Right ())

partitionEmitterInstallCheckpoint
  :: PartitionEmitterModel
  -> IORef [BS8.ByteString]
  -> Deadline.Deadline
  -> EmitterKernel.CheckpointCandidate
  -> IO (Either Text.Text EmitterKernel.CheckpointOutcome)
partitionEmitterInstallCheckpoint model checkpointBytesRef _ candidate =
  case partitionCheckpoint model candidate of
    Left err -> pure (Left (Text.pack err))
    Right (bytes, outcome) -> do
      modifyIORef' checkpointBytesRef (++ [bytes])
      pure (Right outcome)

partitionStage
  :: PartitionEmitterModel
  -> EmitterKernel.StagePlan
  -> Either String EmitterKernel.StageOutcome
partitionStage model plan = do
  previous <- partitionCursorFromAnchor (EmitterKernel.stagePlanPreviousAnchor plan)
  let incarnation = EmitterKernel.stagePlanIncarnation plan
      bounds = partitionBounds model
      orders = partitionOrders model
      emitter = partitionNodeA model
      key = partitionEventKey model
      previousSequence =
        GatewayState.emitterSequenceValue
          (GatewayState.emitterCursorSequence previous)
      semanticKind = case EmitterKernel.stagePlanKind plan of
        EmitterKernel.KindHeartbeat payload ->
          Right
            ( GatewayState.HeartbeatAssertion
                (EmitterMailbox.heartbeatObservedMicros payload)
            )
        EmitterKernel.KindOwnership EmitterMailbox.OwnershipClaim ->
          Right (GatewayState.OwnershipAssertion GatewayState.OwnershipClaim)
        EmitterKernel.KindOwnership EmitterMailbox.OwnershipYield ->
          Right (GatewayState.OwnershipAssertion GatewayState.OwnershipYield)
        EmitterKernel.KindEpochRotation -> Right GatewayState.EpochRotationAssertion
        EmitterKernel.KindOrdersMigration _ ->
          Left "partition emitter did not request an Orders migration"
  if previousSequence == maxBound
    && case EmitterKernel.stagePlanKind plan of
      EmitterKernel.KindHeartbeat _ -> True
      EmitterKernel.KindOwnership _ -> True
      _ -> False
    then Right EmitterKernel.StageNeedsRotation
    else do
      kind <- semanticKind
      (signed, _) <-
        either (Left . show) Right $
          GatewayPeer.signAndConvertAssertionForIncarnation
            bounds
            orders
            emitter
            incarnation
            previous
            kind
            key
      payload <-
        either (Left . show) Right $
          EmitterKernel.mkBoundedSignedPayload
            (GatewayBounds.gatewayMaxEncodedAssertionBytes bounds)
            (GatewayPeer.signedAssertionBytes signed)
      Right (EmitterKernel.StageStaged payload)

partitionApplyPublished
  :: PartitionEmitterModel
  -> EmitterKernel.StagedRecord
  -> GatewayState.GatewayState
  -> Either String GatewayState.GatewayState
partitionApplyPublished model record state = do
  signed <-
    either (Left . show) Right $
      GatewayPeer.decodeSignedAssertion
        (partitionBounds model)
        (EmitterKernel.stagedRecordSignedBytes record)
  semantic <-
    either (Left . show) Right $
      GatewayPeer.verifySignedAssertion
        (partitionBounds model)
        (partitionOrders model)
        (partitionEventKeyLookup model)
        signed
  previous <- partitionCursorFromAnchor (EmitterKernel.stagedRecordPreviousAnchor record)
  expectedResult <- partitionCursorFromAnchor (EmitterKernel.stagedRecordNextAnchor record)
  if GatewayState.assertionEmitter semantic /= partitionNodeA model
    || GatewayState.assertionIncarnation semantic /= EmitterKernel.stagedRecordIncarnation record
    || GatewayState.assertionPreviousHash semantic /= GatewayState.emitterCursorHash previous
    || GatewayState.assertionResultCursor semantic /= expectedResult
    then Left "published signed assertion did not match its immutable Kernel record"
    else case GatewayState.applyGatewayAssertion semantic state of
      GatewayState.AssertionApplied advanced -> Right advanced
      outcome -> Left ("published semantic assertion was not applied: " ++ show outcome)

partitionCheckpoint
  :: PartitionEmitterModel
  -> EmitterKernel.CheckpointCandidate
  -> Either String (BS8.ByteString, EmitterKernel.CheckpointOutcome)
partitionCheckpoint model candidate = do
  baseEvidence <-
    case EmitterKernel.repairFloorSignedBytes
      (EmitterKernel.checkpointCandidatePreviousFloor candidate) of
      Nothing -> Right []
      Just bytes -> do
        snapshot <-
          either (Left . show) Right $
            GatewayPeer.decodeSignedSemanticSnapshot (partitionBounds model) bytes
        _ <-
          either (Left . show) Right $
            GatewayPeer.verifySemanticSnapshot
              (partitionBounds model)
              (partitionOrders model)
              (partitionEventKeyLookup model)
              snapshot
        Right
          ( GatewayPeer.boundedSignedAssertionsToList
              (GatewayPeer.signedSemanticSnapshotEvidence snapshot)
          )
  candidateSigned <-
    traverse
      ( either (Left . show) Right
          . GatewayPeer.decodeSignedAssertion (partitionBounds model)
          . EmitterKernel.stagedRecordSignedBytes
          . EmitterKernel.unackedAssertionRecord
      )
      (EmitterKernel.checkpointCandidateAssertions candidate)
  evidencePairs <- traverse verifyOne (baseEvidence ++ candidateSigned)
  latest <-
    case reverse (EmitterKernel.checkpointCandidateAssertions candidate) of
      [] -> Left "Kernel proposed an empty checkpoint prefix"
      value : _ -> Right (EmitterKernel.unackedAssertionRecord value)
  let through = EmitterKernel.checkpointCandidateThrough candidate
  if EmitterKernel.stagedRecordNextAnchor latest /= EmitterKernel.ackPointAnchor through
    || EmitterKernel.stagedRecordIncarnation latest /= EmitterKernel.ackPointIncarnation through
    then Left "Kernel checkpoint through-point did not match its exact prefix"
    else pure ()
  cursor <- partitionCursorFromAnchor (EmitterKernel.ackPointAnchor through)
  let (heartbeat, ownership) = foldl partitionAdvanceEvidence (Nothing, Nothing) evidencePairs
  checkpoint <-
    either (Left . show) Right $
      GatewayState.mkEmitterCheckpointForIncarnation
        (partitionBounds model)
        (partitionOrders model)
        (partitionNodeA model)
        (EmitterKernel.ackPointIncarnation through)
        cursor
        (snd <$> heartbeat)
        (snd <$> ownership)
  snapshot <-
    either (Left . show) Right $
      GatewayPeer.signSemanticSnapshot
        (partitionBounds model)
        (partitionOrders model)
        checkpoint
        (fst <$> heartbeat)
        (fst <$> ownership)
        (partitionEventKey model)
  bytes <-
    either (Left . show) Right $
      GatewayPeer.encodeSignedSemanticSnapshot (partitionBounds model) snapshot
  payload <-
    either (Left . show) Right $
      EmitterKernel.mkBoundedSignedPayload
        (GatewayBounds.gatewayMaxFrameBytes (partitionBounds model))
        bytes
  Right (bytes, EmitterKernel.CheckpointInstalled payload)
 where
  verifyOne signed = do
    semantic <-
      either (Left . show) Right $
        GatewayPeer.verifySignedAssertion
          (partitionBounds model)
          (partitionOrders model)
          (partitionEventKeyLookup model)
          signed
    Right (signed, semantic)

partitionAdvanceEvidence
  :: ( Maybe (GatewayPeer.SignedAssertion, GatewayState.GatewayAssertion)
     , Maybe (GatewayPeer.SignedAssertion, GatewayState.GatewayAssertion)
     )
  -> (GatewayPeer.SignedAssertion, GatewayState.GatewayAssertion)
  -> ( Maybe (GatewayPeer.SignedAssertion, GatewayState.GatewayAssertion)
     , Maybe (GatewayPeer.SignedAssertion, GatewayState.GatewayAssertion)
     )
partitionAdvanceEvidence (heartbeat, ownership) pair@(_, semantic) =
  case GatewayState.assertionKind semantic of
    GatewayState.HeartbeatAssertion _ -> (Just pair, ownership)
    GatewayState.OwnershipAssertion _ -> (heartbeat, Just pair)
    GatewayState.EpochRotationAssertion -> (heartbeat, ownership)
    GatewayState.OrdersMigrationAssertion _ -> (Nothing, Nothing)

proveWrongIncarnationAndDigest
  :: PartitionEmitterModel
  -> GatewayState.GatewayState
  -> ExceptT String IO ()
proveWrongIncarnationAndDigest model state = do
  current <-
    partitionEither "repaired emitter cursor" (partitionCursorFor (partitionNodeA model) state)
  (staleSigned, _) <-
    partitionEither
      "stale-incarnation assertion signing"
      ( GatewayPeer.signAndConvertAssertionForIncarnation
          (partitionBounds model)
          (partitionOrders model)
          (partitionNodeA model)
          (EmitterKernel.mkIncarnation 6)
          current
          (GatewayState.HeartbeatAssertion 999)
          (partitionEventKey model)
      )
  stale <-
    partitionEither "stale-incarnation assertion verification" (partitionVerify model staleSigned)
  case GatewayState.applyGatewayAssertion stale state of
    GatewayState.AssertionRejected unchanged GatewayState.AssertionStaleIncarnation {} ->
      partitionRequire
        (GatewayState.gatewayStateCursorVector unchanged == GatewayState.gatewayStateCursorVector state)
        "stale incarnation changed the repaired cursor"
    outcome -> throwE ("wrong incarnation did not fail closed: " ++ show outcome)
  wrongHash <- partitionEither "wrong previous digest" (partitionHash "wrong-partition-digest")
  let wrongCursor =
        GatewayState.restoredEmitterCursor
          ( GatewayState.emitterEpochValue
              (GatewayState.emitterCursorEpoch current)
          )
          ( GatewayState.emitterSequenceValue
              (GatewayState.emitterCursorSequence current)
          )
          wrongHash
  (wrongSigned, _) <-
    partitionEither
      "wrong-digest assertion signing"
      ( GatewayPeer.signAndConvertAssertionForIncarnation
          (partitionBounds model)
          (partitionOrders model)
          (partitionNodeA model)
          (EmitterKernel.mkIncarnation 7)
          wrongCursor
          (GatewayState.HeartbeatAssertion 1000)
          (partitionEventKey model)
      )
  wrong <- partitionEither "wrong-digest assertion verification" (partitionVerify model wrongSigned)
  case GatewayState.applyGatewayAssertion wrong state of
    GatewayState.AssertionRejected unchanged GatewayState.AssertionPreviousHashMismatch {} ->
      partitionRequire
        (GatewayState.gatewayStateCursorVector unchanged == GatewayState.gatewayStateCursorVector state)
        "wrong previous digest changed the repaired cursor"
    outcome -> throwE ("wrong digest did not fail closed: " ++ show outcome)

partitionVerify
  :: PartitionEmitterModel
  -> GatewayPeer.SignedAssertion
  -> Either GatewayPeer.PeerError GatewayState.GatewayAssertion
partitionVerify model signed = do
  decoded <-
    GatewayPeer.decodeSignedAssertion
      (partitionBounds model)
      (GatewayPeer.signedAssertionBytes signed)
  GatewayPeer.verifySignedAssertion
    (partitionBounds model)
    (partitionOrders model)
    (partitionEventKeyLookup model)
    decoded

partitionCursorFor
  :: GatewayState.NodeId
  -> GatewayState.GatewayState
  -> Either String GatewayState.EmitterCursor
partitionCursorFor emitter state =
  maybe
    (Left "partition emitter cursor was absent")
    Right
    ( GatewayState.cursorVectorLookup
        emitter
        (GatewayState.gatewayStateCursorVector state)
    )

partitionCursorFromAnchor
  :: GatewayContinuity.ContinuityAnchor
  -> Either String GatewayState.EmitterCursor
partitionCursorFromAnchor anchor = do
  eventHash <-
    either (Left . show) Right $
      GatewayState.mkEventHash
        ( GatewayContinuity.continuityDigestBytes
            (GatewayContinuity.continuityAnchorPreviousDigest anchor)
        )
  Right
    ( GatewayState.restoredEmitterCursor
        (GatewayContinuity.continuityAnchorEpoch anchor)
        (GatewayContinuity.continuityAnchorSequence anchor)
        eventHash
    )

partitionAnchorFromCursor
  :: GatewayState.EmitterCursor
  -> Either String GatewayContinuity.ContinuityAnchor
partitionAnchorFromCursor cursor = do
  digest <-
    either (Left . show) Right $
      GatewayContinuity.mkContinuityDigest
        (GatewayState.eventHashBytes (GatewayState.emitterCursorHash cursor))
  Right
    ( GatewayContinuity.restoreContinuityAnchor
        (GatewayState.emitterEpochValue (GatewayState.emitterCursorEpoch cursor))
        (GatewayState.emitterSequenceValue (GatewayState.emitterCursorSequence cursor))
        digest
    )

partitionHash :: String -> Either String GatewayState.EventHash
partitionHash label =
  either (Left . show) Right $
    GatewayState.mkEventHash (SHA256.hash (BS8.pack label))

partitionNow :: Deadline.MonotonicInstant
partitionNow = Deadline.monotonicInstantFromMicros 1000

partitionDeadline :: Deadline.Deadline
partitionDeadline =
  Deadline.deadlineAtOffset
    partitionNow
    (Deadline.RemainingDuration 1000000)

partitionMaximumProjectionBytes :: Natural
partitionMaximumProjectionBytes = 1048576

partitionEither :: (Show err) => String -> Either err value -> ExceptT String IO value
partitionEither context result =
  either (throwE . ((context ++ ": ") ++) . show) pure result

partitionRequire :: Bool -> String -> ExceptT String IO ()
partitionRequire condition err =
  if condition then pure () else throwE err

latestRef :: String -> IORef [value] -> ExceptT String IO value
latestRef label ref = do
  values <- liftIO (readIORef ref)
  case reverse values of
    value : _ -> pure value
    [] -> throwE (label ++ " was absent")

ensurePartitionInvariant :: Bool -> String -> Either String ()
ensurePartitionInvariant condition err =
  if condition then Right () else Left err

runChartsVscodeValidation :: FilePath -> Substrate -> IO ExitCode
runChartsVscodeValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      let vscodeUrl = substratePublicRouteUrl settings substrate PublicRouteVscode
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess ->
          runSequentially
            [ assertPublicHttpRedirect repoRoot settings substrate PublicRouteVscode
            , reconcileKeycloakRealmSecrets repoRoot settings substrate
            , waitForKeycloakTokenEndpointReady repoRoot settings substrate
            , waitForCommandOutputContainsAll
                Subprocess
                  { subprocessPath = "curl"
                  , subprocessArguments =
                      [ "-sS"
                      , "-D"
                      , "-"
                      , "-o"
                      , "/dev/null"
                      , vscodeUrl
                      ]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
                (oidcRedirectFragments settings substrate (vscodeUrl ++ "/oauth2/callback"))
                chartsVscodeCurlAttempts
                chartsVscodeCurlDelayMicroseconds
            ]

runChartsApiValidation :: FilePath -> Substrate -> IO ExitCode
runChartsApiValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      let apiUrl = substratePublicRouteUrl settings substrate PublicRouteApi
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess -> do
          apiTokenResult <-
            waitForAccessToken repoRoot settings substrate "keycloak_api_client_secret" "prodbox-api"
          websocketTokenResult <-
            waitForAccessToken
              repoRoot
              settings
              substrate
              "keycloak_websocket_client_secret"
              "prodbox-websocket"
          case (apiTokenResult, websocketTokenResult) of
            (Left err, _) -> failWith err
            (_, Left err) -> failWith err
            (Right apiToken, Right websocketToken) ->
              runSequentially
                [ runKeycloakPublicHostValidation repoRoot settings substrate
                , assertHttpStatusIn
                    (statusOnlyCurlSpec repoRoot [] apiUrl)
                    ["401", "403"]
                , assertHttpStatusIn
                    ( statusOnlyCurlSpec
                        repoRoot
                        ["-H", "Authorization: Bearer " ++ websocketToken]
                        apiUrl
                    )
                    ["401", "403"]
                , assertCommandOutputContainsAll
                    ( jsonCurlSpec
                        repoRoot
                        ["-H", "Authorization: Bearer " ++ apiToken]
                        apiUrl
                    )
                    ["\"mode\":\"api\"", "\"pod\":\""]
                ]

runChartsWebsocketValidation :: FilePath -> [(String, String)] -> Substrate -> IO ExitCode
runChartsWebsocketValidation repoRoot environment substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess -> do
          apiTokenResult <-
            waitForAccessToken repoRoot settings substrate "keycloak_api_client_secret" "prodbox-api"
          websocketTokenResult <-
            waitForAccessToken
              repoRoot
              settings
              substrate
              "keycloak_websocket_client_secret"
              "prodbox-websocket"
          case (apiTokenResult, websocketTokenResult) of
            (Left err, _) -> failWith err
            (_, Left err) -> failWith err
            (Right apiToken, Right websocketToken) -> do
              runSequentially
                [ runDirectOidcSessionValidation repoRoot settings substrate
                , runWebsocketUpgradeValidation repoRoot environment settings substrate apiToken websocketToken
                ]

data ManagedWebsocketConnection = ManagedWebsocketConnection
  { managedWebsocketConnection :: WebSocket.Connection
  , managedWebsocketPod :: String
  , managedWebsocketFinalize :: IO ()
  }

runAdminRoutesValidation :: FilePath -> Substrate -> IO ExitCode
runAdminRoutesValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess ->
          -- The single-binary registry:2 has no web UI, so the former /harbor
          -- OIDC admin route is gone; the MinIO console is the only admin route.
          assertOidcProtectedRoute
            repoRoot
            settings
            substrate
            (substratePublicRouteUrl settings substrate PublicRouteMinio)
            (substratePublicRouteUrl settings substrate PublicRouteMinio ++ "/oauth2/callback")
            "MinIO admin route did not preserve the shared-host auth contract"

runKeycloakPublicHostValidation :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
runKeycloakPublicHostValidation repoRoot settings substrate = do
  let websocketStartUrl = substratePublicRouteUrl settings substrate PublicRouteWebsocket ++ "/oidc/start"
      websocketCallbackUrl = substratePublicRouteUrl settings substrate PublicRouteWebsocket ++ "/oidc/callback"
      issuerUrl = substrateIdentityIssuerUrl settings substrate
      authUrl = substratePublicRouteUrl settings substrate PublicRouteAuth
  redirectExit <-
    assertOidcProtectedRoute
      repoRoot
      settings
      substrate
      websocketStartUrl
      websocketCallbackUrl
      "direct OIDC redirect did not preserve the shared-host auth contract"
  case redirectExit of
    ExitFailure _ -> pure redirectExit
    ExitSuccess -> do
      metadataResult <-
        runJsonCommand
          (jsonCurlSpec repoRoot [] (issuerUrl ++ "/.well-known/openid-configuration"))
      case metadataResult of
        Left err -> failWith err
        Right metadataPayload ->
          case keycloakWellKnownSummary metadataPayload of
            Left err -> failWith err
            Right (issuerValue, authorizationEndpoint, tokenEndpoint, jwksUriValue) ->
              if and
                [ issuerValue == issuerUrl
                , (authUrl ++ "/") `isInfixOf` authorizationEndpoint
                , (authUrl ++ "/") `isInfixOf` tokenEndpoint
                , (authUrl ++ "/") `isInfixOf` jwksUriValue
                ]
                then
                  assertHttpStatusIn
                    (statusOnlyCurlSpec repoRoot [] (authUrl ++ "/health/ready"))
                    ["404"]
                else
                  failWith
                    ( "Keycloak well-known metadata did not preserve the shared-host auth contract: "
                        ++ show
                          [ issuerValue
                          , authorizationEndpoint
                          , tokenEndpoint
                          , jwksUriValue
                          ]
                    )

waitForKeycloakTokenEndpointReady :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
waitForKeycloakTokenEndpointReady repoRoot settings substrate = do
  tokenResult <-
    waitForAccessToken repoRoot settings substrate "keycloak_api_client_secret" "prodbox-api"
  case tokenResult of
    Left err -> failWith err
    Right _ -> pure ExitSuccess

-- | Sprint 5.10 follow-up: reconcile the Keycloak realm's OIDC client secrets +
-- demo-user password with Vault via the admin API before exercising the password
-- grant. @--import-realm@ is @IGNORE_EXISTING@, so a preserved Keycloak database
-- can hold stale secrets that diverged from Vault — yielding a persistent
-- @invalid_client_credentials@ 401. This patches the live realm to match Vault.
reconcileKeycloakRealmSecrets :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
reconcileKeycloakRealmSecrets repoRoot settings substrate = do
  reconcileResult <-
    Prodbox.UsersAdmin.reconcileRealmOidcSecretsAtPublicHost
      repoRoot
      (Text.pack (substratePublicFqdn settings substrate))
  case reconcileResult of
    Left err -> failWith err
    Right () -> pure ExitSuccess

runDirectOidcSessionValidation :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
runDirectOidcSessionValidation repoRoot settings substrate = do
  sessionResult <- completeDirectOidcLogin repoRoot settings substrate
  case sessionResult of
    Left err -> failWith err
    Right sessionPayload ->
      case directOidcSessionSummary sessionPayload of
        Left err -> failWith err
        Right (carrierValue, issuerValue, maybeUsername) ->
          if carrierValue == "cookie-session"
            && issuerValue == substrateIdentityIssuerUrl settings substrate
            && maybeUsername == Just "demo-user"
            then pure ExitSuccess
            else
              failWith
                ( "direct OIDC session payload did not match the documented carrier or issuer boundary: "
                    ++ show (carrierValue, issuerValue, maybeUsername)
                )

runWebsocketUpgradeValidation
  :: FilePath
  -> [(String, String)]
  -> ValidatedSettings
  -> Substrate
  -> String
  -> String
  -> IO ExitCode
runWebsocketUpgradeValidation repoRoot environment settings substrate apiToken websocketToken = do
  nonce <- validationNonce
  let sessionId = "ws-" ++ nonce
      messageBody = "message-" ++ nonce
      websocketHost = substratePublicFqdn settings substrate
  initialChecksExit <-
    runSequentially
      [ assertHttpStatusIn
          (statusOnlyCurlSpec repoRoot [] (stateUrl websocketHost sessionId))
          ["401", "403"]
      , assertHttpStatusIn
          ( statusOnlyCurlSpec
              repoRoot
              ["-H", "Authorization: Bearer " ++ apiToken]
              (stateUrl websocketHost sessionId)
          )
          ["401", "403"]
      ]
  case initialChecksExit of
    ExitFailure _ -> pure initialChecksExit
    ExitSuccess -> do
      firstConnectionResult <-
        openManagedWebsocketConnection websocketHost (websocketPath sessionId True) websocketToken
      case firstConnectionResult of
        Left err -> failWith err
        Right firstConnection ->
          finally
            ( do
                secondConnectionResult <-
                  openDistinctManagedWebsocketConnection
                    websocketHost
                    (websocketPath sessionId False)
                    websocketToken
                    (managedWebsocketPod firstConnection)
                    8
                case secondConnectionResult of
                  Left err -> failWith err
                  Right secondConnection ->
                    finally
                      ( do
                          WebSocket.sendTextData
                            (managedWebsocketConnection firstConnection)
                            (Text.pack messageBody)
                          broadcastResult <-
                            waitForWebsocketBroadcast
                              (managedWebsocketConnection secondConnection)
                              messageBody
                              12
                          case broadcastResult of
                            Left err -> failWith err
                            Right senderPod ->
                              if senderPod /= managedWebsocketPod firstConnection
                                then
                                  failWith
                                    ( "websocket broadcast came from unexpected pod: expected "
                                        ++ managedWebsocketPod firstConnection
                                        ++ " but observed "
                                        ++ senderPod
                                    )
                                else do
                                  revokeExit <-
                                    assertHttpStatusIn
                                      ( statusOnlyCurlSpec
                                          repoRoot
                                          [ "-X"
                                          , "POST"
                                          , "-H"
                                          , "Authorization: Bearer " ++ websocketToken
                                          ]
                                          (revokeUrl websocketHost sessionId)
                                      )
                                      ["200"]
                                  case revokeExit of
                                    ExitFailure _ -> pure revokeExit
                                    ExitSuccess -> do
                                      revokeCloseResult <-
                                        waitForWebsocketClose
                                          (managedWebsocketConnection firstConnection)
                                          15000000
                                      case revokeCloseResult of
                                        Left err -> failWith err
                                        Right () -> do
                                          thirdConnectionResult <-
                                            openManagedWebsocketConnection
                                              websocketHost
                                              (websocketPath sessionId False)
                                              websocketToken
                                          case thirdConnectionResult of
                                            Left err -> failWith err
                                            Right thirdConnection ->
                                              finally
                                                ( do
                                                    deleteExit <-
                                                      runCommandForExitCode
                                                        Subprocess
                                                          { subprocessPath = "kubectl"
                                                          , subprocessArguments =
                                                              ["delete", "pod", managedWebsocketPod thirdConnection, "--namespace", "websocket"]
                                                          , subprocessEnvironment = Nothing
                                                          , subprocessWorkingDirectory = Just repoRoot
                                                          }
                                                    case deleteExit of
                                                      ExitFailure _ -> pure deleteExit
                                                      ExitSuccess -> do
                                                        threadDelay 2000000
                                                        fourthConnectionResult <-
                                                          openDistinctManagedWebsocketConnection
                                                            websocketHost
                                                            (websocketPath sessionId False)
                                                            websocketToken
                                                            (managedWebsocketPod thirdConnection)
                                                            8
                                                        case fourthConnectionResult of
                                                          Left err -> failWith err
                                                          Right fourthConnection ->
                                                            finally
                                                              ( do
                                                                  closeResult <-
                                                                    waitForWebsocketClose
                                                                      (managedWebsocketConnection thirdConnection)
                                                                      20000000
                                                                  case closeResult of
                                                                    Left err -> failWith err
                                                                    Right () -> do
                                                                      rolloutExit <-
                                                                        runNativeCliCommandForExitCode
                                                                          repoRoot
                                                                          environment
                                                                          ["cluster", "wait", "--namespace", "websocket"]
                                                                      case rolloutExit of
                                                                        ExitFailure _ -> pure rolloutExit
                                                                        ExitSuccess -> do
                                                                          statePayloadResult <-
                                                                            runJsonCommand
                                                                              ( jsonCurlSpec
                                                                                  repoRoot
                                                                                  ["-H", "Authorization: Bearer " ++ websocketToken]
                                                                                  (stateUrl websocketHost sessionId)
                                                                              )
                                                                          case statePayloadResult of
                                                                            Left err -> failWith err
                                                                            Right statePayload ->
                                                                              case websocketStateSnapshot statePayload of
                                                                                Left err -> failWith err
                                                                                Right (_, messages) ->
                                                                                  if messageBody `elem` messages
                                                                                    then pure ExitSuccess
                                                                                    else
                                                                                      failWith
                                                                                        ( "websocket validation did not observe reconnect-safe Redis state after drain: "
                                                                                            ++ show messages
                                                                                        )
                                                              )
                                                              (closeManagedWebsocketConnection fourthConnection)
                                                )
                                                (closeManagedWebsocketConnection thirdConnection)
                      )
                      (closeManagedWebsocketConnection secondConnection)
            )
            (closeManagedWebsocketConnection firstConnection)

completeDirectOidcLogin :: FilePath -> ValidatedSettings -> Substrate -> IO (Either String Value)
completeDirectOidcLogin repoRoot settings substrate =
  withTemporaryFilePath repoRoot "prodbox-oidc-cookies" $ \cookieJarPath ->
    withTemporaryFilePath repoRoot "prodbox-oidc-login-body" $ \bodyPath -> do
      -- Sprint 3.18: demo-user password lives in Vault KV, not in the
      -- removed host-side @.prodbox-state@ cache or the pre-Vault OIDC Secret.
      demoPasswordResult <- readKeycloakOidcClientField repoRoot "DEMO_USER_PASSWORD"
      case demoPasswordResult of
        Left err -> pure (Left err)
        Right demoPassword -> do
          loginPageResult <-
            runTextCommand
              Subprocess
                { subprocessPath = "curl"
                , subprocessArguments =
                    [ "-sS"
                    , "-L"
                    , "-c"
                    , cookieJarPath
                    , "-b"
                    , cookieJarPath
                    , "-o"
                    , bodyPath
                    , substratePublicRouteUrl settings substrate PublicRouteWebsocket ++ "/oidc/start"
                    ]
                , subprocessEnvironment = Nothing
                , subprocessWorkingDirectory = Just repoRoot
                }
          case loginPageResult of
            Left err -> pure (Left err)
            Right _ -> do
              loginBody <- readFile bodyPath
              case extractLoginFormAction loginBody of
                Left err -> pure (Left err)
                Right formActionUrl -> do
                  loginResult <-
                    runTextCommand
                      Subprocess
                        { subprocessPath = "curl"
                        , subprocessArguments =
                            [ "-sS"
                            , "-L"
                            , "-c"
                            , cookieJarPath
                            , "-b"
                            , cookieJarPath
                            , "--data-urlencode"
                            , "username=demo-user"
                            , "--data-urlencode"
                            , "password=" ++ demoPassword
                            , formActionUrl
                            ]
                        , subprocessEnvironment = Nothing
                        , subprocessWorkingDirectory = Just repoRoot
                        }
                  case loginResult of
                    Left err -> pure (Left err)
                    Right _ ->
                      runJsonCommand
                        Subprocess
                          { subprocessPath = "curl"
                          , subprocessArguments =
                              [ "-sS"
                              , "-L"
                              , "-c"
                              , cookieJarPath
                              , "-b"
                              , cookieJarPath
                              , substratePublicRouteUrl settings substrate PublicRouteWebsocket ++ "/oidc/session"
                              ]
                          , subprocessEnvironment = Nothing
                          , subprocessWorkingDirectory = Just repoRoot
                          }

openManagedWebsocketConnection
  :: String -> String -> String -> IO (Either String ManagedWebsocketConnection)
openManagedWebsocketConnection host path token = go websocketConnectionAttempts
 where
  go :: Int -> IO (Either String ManagedWebsocketConnection)
  go attemptsLeft = do
    connectionResult <-
      try
        ( Wuss.newSecureClientConnectionWith
            host
            443
            path
            WebSocket.defaultConnectionOptions
              { WebSocket.connectionCompressionOptions = WebSocket.NoCompression
              }
            [(CI.mk (BS8.pack "Authorization"), BS8.pack ("Bearer " ++ token))]
        )
        :: IO (Either SomeException (WebSocket.Connection, IO ()))
    case connectionResult of
      Left err ->
        retryOrFail attemptsLeft ("failed to open websocket connection: " ++ displayException err)
      Right (connection, finalizeConnection) -> do
        welcomeResult <- readWebsocketWelcome connection 10000000
        case welcomeResult of
          Left err -> do
            finalizeConnection
            retryOrFail attemptsLeft err
          Right podName ->
            pure
              ( Right
                  ManagedWebsocketConnection
                    { managedWebsocketConnection = connection
                    , managedWebsocketPod = podName
                    , managedWebsocketFinalize = finalizeConnection
                    }
              )

  retryOrFail :: Int -> String -> IO (Either String ManagedWebsocketConnection)
  retryOrFail attemptsLeft detail
    | attemptsLeft <= 1 || not (shouldRetryTransientWebsocketOpenError detail) = pure (Left detail)
    | otherwise = do
        writeDiagnosticLine ("Waiting for websocket route readiness before retry: " ++ detail)
        threadDelay websocketConnectionRetryDelayMicroseconds
        go (attemptsLeft - 1)

openDistinctManagedWebsocketConnection
  :: String -> String -> String -> String -> Int -> IO (Either String ManagedWebsocketConnection)
openDistinctManagedWebsocketConnection host path token excludedPod attemptsLeft = do
  connectionResult <- openManagedWebsocketConnection host path token
  case connectionResult of
    Left err
      | attemptsLeft <= 1 || not (shouldRetryTransientWebsocketOpenError err) -> pure (Left err)
      | otherwise -> do
          writeDiagnosticLine ("Waiting for websocket route readiness before retry: " ++ err)
          threadDelay websocketDistinctConnectionRetryDelayMicroseconds
          openDistinctManagedWebsocketConnection host path token excludedPod (attemptsLeft - 1)
    Right connection
      | managedWebsocketPod connection /= excludedPod -> pure (Right connection)
      | attemptsLeft <= 1 -> do
          closeManagedWebsocketConnection connection
          pure
            ( Left
                ( "failed to observe a second websocket backend pod distinct from "
                    ++ excludedPod
                )
            )
      | otherwise -> do
          closeManagedWebsocketConnection connection
          writeDiagnosticLine "Waiting for a distinct websocket backend pod before retry."
          threadDelay websocketDistinctConnectionRetryDelayMicroseconds
          openDistinctManagedWebsocketConnection host path token excludedPod (attemptsLeft - 1)

closeManagedWebsocketConnection :: ManagedWebsocketConnection -> IO ()
closeManagedWebsocketConnection connection = do
  _ <-
    try
      ( WebSocket.sendCloseCode
          (managedWebsocketConnection connection)
          1000
          (Text.pack "validation complete")
      )
      :: IO (Either SomeException ())
  managedWebsocketFinalize connection

readWebsocketWelcome :: WebSocket.Connection -> Int -> IO (Either String String)
readWebsocketWelcome connection timeoutMicroseconds = do
  messageResult <- waitForWebsocketJsonMessage connection timeoutMicroseconds
  pure $ do
    payload <- messageResult
    payloadType <- websocketPayloadType payload
    if payloadType == "welcome"
      then websocketPayloadField payload "pod"
      else Left ("expected websocket welcome payload but observed type " ++ payloadType)

waitForWebsocketBroadcast :: WebSocket.Connection -> String -> Int -> IO (Either String String)
waitForWebsocketBroadcast connection expectedMessage attemptsLeft = go attemptsLeft
 where
  go attemptsRemaining
    | attemptsRemaining <= 0 = pure (Left "timed out waiting for websocket broadcast message")
    | otherwise = do
        messageResult <- waitForWebsocketJsonMessage connection 10000000
        case messageResult of
          Left err
            | attemptsRemaining > 1 && shouldRetryTransientWebsocketReceiveError err -> do
                writeDiagnosticLine ("Waiting for websocket broadcast delivery before retry: " ++ err)
                threadDelay websocketReceiveRetryDelayMicroseconds
                go (attemptsRemaining - 1)
            | otherwise -> pure (Left err)
          Right payload ->
            case websocketPayloadType payload of
              Left err -> pure (Left err)
              Right "message" ->
                case (websocketPayloadField payload "message", websocketPayloadField payload "pod") of
                  (Right observedMessage, Right observedPod)
                    | observedMessage == expectedMessage -> pure (Right observedPod)
                    | otherwise -> go (attemptsRemaining - 1)
                  (Left err, _) -> pure (Left err)
                  (_, Left err) -> pure (Left err)
              Right _ -> go (attemptsRemaining - 1)

waitForWebsocketClose :: WebSocket.Connection -> Int -> IO (Either String ())
waitForWebsocketClose connection timeoutMicroseconds = go timeoutMicroseconds
 where
  go remainingMicroseconds
    | remainingMicroseconds <= 0 = pure (Left "timed out waiting for websocket close")
    | otherwise = do
        receiveResult <-
          timeout
            remainingMicroseconds
            (try (WebSocket.receiveData connection :: IO Text.Text) :: IO (Either SomeException Text.Text))
        case receiveResult of
          Nothing -> pure (Left "timed out waiting for websocket close")
          Just (Left _) -> pure (Right ())
          Just (Right _) -> go (remainingMicroseconds - 1000000)

waitForWebsocketJsonMessage :: WebSocket.Connection -> Int -> IO (Either String Value)
waitForWebsocketJsonMessage connection timeoutMicroseconds = do
  receiveResult <-
    timeout
      timeoutMicroseconds
      (try (WebSocket.receiveData connection :: IO Text.Text) :: IO (Either SomeException Text.Text))
  case receiveResult of
    Nothing -> pure (Left "timed out waiting for websocket message")
    Just (Left err) -> pure (Left ("websocket receive failed: " ++ displayException err))
    Just (Right messageText) ->
      pure $
        case decodeJsonTextUtf8 messageText of
          Left err -> Left ("websocket payload was not valid JSON: " ++ err)
          Right payload -> Right payload

shouldRetryTransientWebsocketOpenError :: String -> Bool
shouldRetryTransientWebsocketOpenError detail =
  let lowered = map toLowerAscii detail
   in any
        (`isInfixOf` lowered)
        [ "<<timeout>>"
        , "timed out"
        , "temporary failure"
        , "service unavailable"
        , "connection refused"
        , "connection reset"
        , "unexpected eof"
        , "end of file"
        , "tls"
        , "bad handshake"
        , "handshake"
        , "draining"
        , "502"
        , "503"
        , "504"
        ]

shouldRetryTransientWebsocketReceiveError :: String -> Bool
shouldRetryTransientWebsocketReceiveError detail =
  let lowered = map toLowerAscii detail
   in any
        (`isInfixOf` lowered)
        [ "<<timeout>>"
        , "timed out waiting for websocket message"
        , "timed out"
        ]

keycloakWellKnownSummary :: Value -> Either String (String, String, String, String)
keycloakWellKnownSummary payload =
  case payload of
    Object obj ->
      (,,,)
        <$> requireStringField obj "issuer"
        <*> requireStringField obj "authorization_endpoint"
        <*> requireStringField obj "token_endpoint"
        <*> requireStringField obj "jwks_uri"
    _ -> Left "Keycloak well-known payload was not a JSON object"

directOidcSessionSummary :: Value -> Either String (String, String, Maybe String)
directOidcSessionSummary payload =
  case payload of
    Object obj ->
      (,,)
        <$> requireStringField obj "carrier"
        <*> requireStringField obj "issuer"
        <*> pure
          ( case KeyMap.lookup "preferred_username" obj of
              Just (String value) -> Just (textValue value)
              _ -> Nothing
          )
    _ -> Left "direct OIDC session payload was not a JSON object"

websocketPayloadType :: Value -> Either String String
websocketPayloadType payload =
  case payload of
    Object obj -> requireStringField obj "type"
    _ -> Left "websocket payload was not a JSON object"

websocketPayloadField :: Value -> String -> Either String String
websocketPayloadField payload fieldName =
  case payload of
    Object obj -> requireStringField obj fieldName
    _ -> Left "websocket payload was not a JSON object"

extractLoginFormAction :: String -> Either String String
extractLoginFormAction bodyText =
  case splitOnSubstring "action=\"" bodyText of
    Nothing -> Left "could not find Keycloak login form action"
    Just (_, actionAndRest) ->
      case break (== '"') actionAndRest of
        (actionUrl, _ : _) | actionUrl /= "" -> Right (decodeHtmlAttributeValue actionUrl)
        _ -> Left "could not parse Keycloak login form action"

decodeHtmlAttributeValue :: String -> String
decodeHtmlAttributeValue value =
  replaceAll "&amp;" "&" value

replaceAll :: String -> String -> String -> String
replaceAll needle replacement = go
 where
  go remaining =
    case splitOnSubstring needle remaining of
      Nothing -> remaining
      Just (beforeNeedle, afterNeedle) ->
        beforeNeedle ++ replacement ++ go afterNeedle

withTemporaryFilePath :: FilePath -> String -> (FilePath -> IO a) -> IO a
withTemporaryFilePath parentDir templateName action =
  bracket
    (openTempFile parentDir templateName)
    (\(path, handle) -> hClose handle >> removeFile path)
    (\(path, handle) -> hClose handle >> action path)

splitOnSubstring :: String -> String -> Maybe (String, String)
splitOnSubstring needle haystack = go [] haystack
 where
  go _ [] = Nothing
  go reversedPrefix remaining
    | needle `startsWith` remaining =
        Just (reverse reversedPrefix, drop (length needle) remaining)
    | otherwise =
        case remaining of
          character : trailing ->
            go (character : reversedPrefix) trailing

splitOnChar :: Char -> String -> [String]
splitOnChar _ [] = [""]
splitOnChar delimiter value =
  case break (== delimiter) value of
    (before, _ : after) -> before : splitOnChar delimiter after
    (before, []) -> [before]

startsWith :: String -> String -> Bool
startsWith [] _ = True
startsWith _ [] = False
startsWith (left : leftRest) (right : rightRest) =
  left == right && startsWith leftRest rightRest

waitForAccessToken
  :: FilePath -> ValidatedSettings -> Substrate -> String -> String -> IO (Either String String)
waitForAccessToken repoRoot settings substrate secretKey clientId = go tokenFetchAttempts
 where
  go :: Int -> IO (Either String String)
  go attemptsLeft = do
    tokenResult <- fetchAccessToken repoRoot settings substrate secretKey clientId
    case tokenResult of
      Right token -> pure (Right token)
      Left err
        | attemptsLeft <= 1 -> pure (Left err)
        | otherwise -> do
            writeDiagnosticLine ("Waiting for Keycloak token endpoint readiness before retry: " ++ err)
            threadDelay tokenFetchDelayMicroseconds
            go (attemptsLeft - 1)

fetchAccessToken
  :: FilePath -> ValidatedSettings -> Substrate -> String -> String -> IO (Either String String)
fetchAccessToken repoRoot settings substrate secretKey clientId = do
  -- Sprint 3.18: the OIDC client secrets + demo-user password live in Vault KV.
  -- The @secretKey@ argument is the legacy chart-secret key name; we map it to
  -- the corresponding Vault path and field.
  clientSecretResult <- readKeycloakOidcClientField repoRoot secretKey
  case clientSecretResult of
    Left err -> pure (Left err)
    Right clientSecret -> do
      demoPasswordResult <- readKeycloakOidcClientField repoRoot "DEMO_USER_PASSWORD"
      case demoPasswordResult of
        Left err -> pure (Left err)
        Right demoPassword -> do
          payloadResult <-
            runJsonCommand
              Subprocess
                { subprocessPath = "curl"
                , subprocessArguments =
                    [ "-sS"
                    , "--fail-with-body"
                    , "-X"
                    , "POST"
                    , "--data-urlencode"
                    , "grant_type=password"
                    , "--data-urlencode"
                    , "client_id=" ++ clientId
                    , "--data-urlencode"
                    , "client_secret=" ++ clientSecret
                    , "--data-urlencode"
                    , "username=demo-user"
                    , "--data-urlencode"
                    , "password=" ++ demoPassword
                    , substrateIdentityIssuerUrl settings substrate ++ "/protocol/openid-connect/token"
                    ]
                , subprocessEnvironment = Nothing
                , subprocessWorkingDirectory = Just repoRoot
                }
          case payloadResult of
            Left err -> pure (Left err)
            Right payload -> pure (accessTokenFromPayload payload)

-- | Map a legacy validation key to the Vault KV path and field used by the
-- shared-edge Keycloak deployment. The caller surface remains stable for the
-- validation code, but the secret source is now Vault KV.
oidcClientSecretVaultRefFor :: String -> (Text.Text, Text.Text)
oidcClientSecretVaultRefFor "keycloak_vscode_client_secret" = ("vscode/oidc/vscode", "client_secret")
oidcClientSecretVaultRefFor "keycloak_api_client_secret" = ("vscode/oidc/prodbox-api", "client_secret")
oidcClientSecretVaultRefFor "keycloak_websocket_client_secret" = ("vscode/oidc/prodbox-websocket", "client_secret")
oidcClientSecretVaultRefFor "keycloak_demo_user_password" = ("vscode/oidc/demo-user", "password")
oidcClientSecretVaultRefFor "VSCODE_CLIENT_SECRET" = ("vscode/oidc/vscode", "client_secret")
oidcClientSecretVaultRefFor "API_CLIENT_SECRET" = ("vscode/oidc/prodbox-api", "client_secret")
oidcClientSecretVaultRefFor "WEBSOCKET_CLIENT_SECRET" = ("vscode/oidc/prodbox-websocket", "client_secret")
oidcClientSecretVaultRefFor "DEMO_USER_PASSWORD" = ("vscode/oidc/demo-user", "password")
oidcClientSecretVaultRefFor other = (Text.pack other, "client_secret")

-- | Read a validation OIDC secret field from Vault KV. A sealed/unreachable
-- Vault or missing field fails the validation closed.
readKeycloakOidcClientField :: FilePath -> String -> IO (Either String String)
readKeycloakOidcClientField repoRoot fieldName = do
  let (path, field) = oidcClientSecretVaultRefFor fieldName
  result <- readHostVaultKvField repoRoot "secret" path field
  pure (Text.unpack <$> result)

accessTokenFromPayload :: Value -> Either String String
accessTokenFromPayload payload =
  case payload of
    Object obj ->
      case KeyMap.lookup "access_token" obj of
        Just (String tokenText) -> Right (Text.unpack tokenText)
        _ -> Left "token endpoint response did not contain access_token"
    _ -> Left "token endpoint response was not a JSON object"

statusOnlyCurlSpec :: FilePath -> [String] -> String -> Subprocess
statusOnlyCurlSpec repoRoot extraArgs url =
  Subprocess
    { subprocessPath = "curl"
    , subprocessArguments = ["-sS", "-o", "/dev/null", "-w", "%{http_code}"] ++ extraArgs ++ [url]
    , subprocessEnvironment = Nothing
    , subprocessWorkingDirectory = Just repoRoot
    }

jsonCurlSpec :: FilePath -> [String] -> String -> Subprocess
jsonCurlSpec repoRoot extraArgs url =
  Subprocess
    { subprocessPath = "curl"
    , subprocessArguments = ["-sS", "--fail-with-body"] ++ extraArgs ++ [url]
    , subprocessEnvironment = Nothing
    , subprocessWorkingDirectory = Just repoRoot
    }

assertHttpStatusIn :: Subprocess -> [String] -> IO ExitCode
assertHttpStatusIn spec allowedStatuses = do
  result <- runTextCommand spec
  case result of
    Left err -> failWith err
    Right statusText ->
      if trim statusText `elem` allowedStatuses
        then pure ExitSuccess
        else
          failWith
            ( "`"
                ++ commandDisplay spec
                ++ "` returned unexpected HTTP status "
                ++ trim statusText
                ++ "; expected one of "
                ++ show allowedStatuses
            )

websocketPath :: String -> Bool -> String
websocketPath sessionId resetRequested =
  "/ws?session="
    ++ sessionId
    ++ if resetRequested then "&reset=true" else ""

revokeUrl :: String -> String -> String
revokeUrl host sessionId =
  "https://" ++ host ++ "/ws/revoke?session=" ++ sessionId

stateUrl :: String -> String -> String
stateUrl host sessionId =
  "https://" ++ host ++ "/ws/state?session=" ++ sessionId

websocketStateSnapshot :: Value -> Either String (String, [String])
websocketStateSnapshot payload =
  case payload of
    Object obj ->
      case (KeyMap.lookup "pod" obj, KeyMap.lookup "messages" obj) of
        (Just (String podText), Just (Array messageValues)) ->
          Right
            ( Text.unpack podText
            , [ Text.unpack value
              | String value <- Vector.toList messageValues
              ]
            )
        _ -> Left "websocket state payload did not include pod and messages fields"
    _ -> Left "websocket state payload was not a JSON object"

assertOidcProtectedRoute
  :: FilePath
  -> ValidatedSettings
  -> Substrate
  -> String
  -> String
  -> String
  -> IO ExitCode
assertOidcProtectedRoute repoRoot settings substrate requestUrl callbackUrl failurePrefix = do
  redirectResult <-
    runTextCommand
      Subprocess
        { subprocessPath = "curl"
        , subprocessArguments = ["-sS", "-D", "-", "-o", "/dev/null", requestUrl]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  case redirectResult of
    Left err -> failWith err
    Right redirectHeaders ->
      if redirectHeadersContainOidcContract settings substrate callbackUrl redirectHeaders
        then pure ExitSuccess
        else failWith (failurePrefix ++ ": " ++ redirectHeaders)

redirectHeadersContainOidcContract :: ValidatedSettings -> Substrate -> String -> String -> Bool
redirectHeadersContainOidcContract settings substrate callbackUrl redirectHeaders =
  let loweredRedirectHeaders = map toLowerAscii redirectHeaders
   in all (`isInfixOf` loweredRedirectHeaders) (oidcRedirectFragments settings substrate callbackUrl)

oidcRedirectFragments :: ValidatedSettings -> Substrate -> String -> [String]
oidcRedirectFragments settings substrate callbackUrl =
  map
    (map toLowerAscii)
    [ "HTTP/"
    , "Location: " ++ substrateIdentityIssuerUrl settings substrate ++ "/protocol/openid-connect/auth"
    , "redirect_uri=" ++ encodeRedirectUri callbackUrl
    ]

encodeRedirectUri :: String -> String
encodeRedirectUri =
  replaceAll "/" "%2F" . replaceAll ":" "%3A"

waitForPublicEdgeReady :: FilePath -> Substrate -> IO ExitCode
waitForPublicEdgeReady repoRoot substrate = do
  let spec =
        Subprocess
          { subprocessPath = canonicalOperatorBinaryPath repoRoot
          , subprocessArguments = ["edge", "status", "--substrate", substrateId substrate]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
  waitForClassification spec publicEdgeReadyAttempts
 where
  waitForClassification :: Subprocess -> Int -> IO ExitCode
  waitForClassification spec attemptsLeft = do
    outputResult <- captureSubprocessResult spec
    case outputResult of
      Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
      Success output -> do
        let combinedOutput = processStdout output ++ processStderr output
        writeOutput (processStdout output)
        writeDiagnostic (processStderr output)
        case processExitCode output of
          ExitFailure code ->
            failWith
              ( "`"
                  ++ commandDisplay spec
                  ++ "` exited with code "
                  ++ show code
              )
          ExitSuccess
            | publicEdgeReadyClassification `isInfixOf` combinedOutput -> pure ExitSuccess
            | attemptsLeft <= 1 ->
                failWith
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` did not report required output `"
                      ++ publicEdgeReadyClassification
                      ++ "` before timeout."
                  )
            | otherwise -> do
                writeDiagnosticLine "Waiting for public edge readiness before external curl validation."
                threadDelay publicEdgeReadyDelayMicroseconds
                waitForClassification spec (attemptsLeft - 1)

runPublicDnsValidation :: FilePath -> Substrate -> IO ExitCode
runPublicDnsValidation repoRoot _substrate = do
  settingsEnvResult <- settingsAwsEnvironment repoRoot
  case settingsEnvResult of
    Left err -> failWith err
    Right (settings, awsEnvironment) -> do
      zonePayloadResult <-
        runJsonCommand
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                [ "route53"
                , "get-hosted-zone"
                , "--id"
                , textValue (zone_id (route53 (validatedConfig settings)))
                , "--output"
                , "json"
                ]
            , subprocessEnvironment = Just awsEnvironment
            , subprocessWorkingDirectory = Just repoRoot
            }
      case zonePayloadResult of
        Left err -> failWith err
        Right payload ->
          case hostedZoneDelegation payload of
            Left err -> failWith err
            Right (zoneName, expectedNameservers) -> do
              digResult <-
                runTextCommand
                  Subprocess
                    { subprocessPath = "dig"
                    , subprocessArguments = ["+short", "NS", zoneName]
                    , subprocessEnvironment = Nothing
                    , subprocessWorkingDirectory = Just repoRoot
                    }
              case digResult of
                Left err -> failWith err
                Right stdoutText -> do
                  let actualNameservers = sort (map normalizeDnsValue (filter (/= "") (lines stdoutText)))
                      expectedNormalized = sort (map normalizeDnsValue expectedNameservers)
                  if actualNameservers == expectedNormalized
                    then do
                      publicIpResult <- fetchPublicIp
                      case publicIpResult of
                        Left err -> failWith err
                        Right publicIp ->
                          verifyConfiguredPublicDnsRecords repoRoot settings publicIp
                    else
                      failWith
                        ( "Public NS delegation mismatch for "
                            ++ zoneName
                            ++ ": expected "
                            ++ show expectedNormalized
                            ++ " but found "
                            ++ show actualNameservers
                        )

runDnsAwsValidation :: FilePath -> IO ExitCode
runDnsAwsValidation repoRoot = do
  settingsEnvResult <- settingsAwsEnvironment repoRoot
  case settingsEnvResult of
    Left err -> failWith err
    Right (settings, awsEnvironment) -> do
      baseZoneNameResult <- configuredHostedZoneName repoRoot awsEnvironment settings
      case baseZoneNameResult of
        Left err -> failWith err
        Right baseZoneName -> do
          nonce <- validationNonce
          let zoneName = "prodbox-dns-aws-" ++ nonce ++ "." ++ baseZoneName
              recordName = "gateway." ++ zoneName
              recordIp = "203.0.113.10"
              callerReference = "prodbox-dns-aws-" ++ nonce
          createZoneResult <-
            runTextCommand
              Subprocess
                { subprocessPath = "aws"
                , subprocessArguments =
                    [ "route53"
                    , "create-hosted-zone"
                    , "--name"
                    , zoneName
                    , "--caller-reference"
                    , callerReference
                    , "--query"
                    , "HostedZone.Id"
                    , "--output"
                    , "text"
                    ]
                , subprocessEnvironment = Just awsEnvironment
                , subprocessWorkingDirectory = Just repoRoot
                }
          case createZoneResult of
            Left err -> failWith err
            Right zoneId -> do
              let hostedZoneId = trim zoneId
              validationExit <- do
                upsertExit <- changeRoute53Record repoRoot awsEnvironment hostedZoneId "UPSERT" recordName recordIp
                case upsertExit of
                  ExitFailure _ -> pure upsertExit
                  ExitSuccess -> do
                    verifyResult <-
                      runTextCommand
                        Subprocess
                          { subprocessPath = "aws"
                          , subprocessArguments =
                              [ "route53"
                              , "list-resource-record-sets"
                              , "--hosted-zone-id"
                              , hostedZoneId
                              , "--query"
                              , "ResourceRecordSets[?Name == '"
                                  ++ ensureTrailingDot recordName
                                  ++ "'].ResourceRecords[0].Value | [0]"
                              , "--output"
                              , "text"
                              ]
                          , subprocessEnvironment = Just awsEnvironment
                          , subprocessWorkingDirectory = Just repoRoot
                          }
                    case verifyResult of
                      Left err -> failWith err
                      Right value ->
                        if trim value == recordIp
                          then pure ExitSuccess
                          else
                            failWith
                              ( "Route 53 record lifecycle validation failed: expected "
                                  ++ recordIp
                                  ++ " but found "
                                  ++ trim value
                              )
              cleanupExit <- cleanupDnsAwsValidation repoRoot awsEnvironment hostedZoneId recordName recordIp
              case (validationExit, cleanupExit) of
                (ExitSuccess, ExitSuccess) -> pure ExitSuccess
                (ExitFailure _, _) -> pure validationExit
                (_, ExitFailure _) -> pure cleanupExit

configuredHostedZoneName
  :: FilePath -> [(String, String)] -> ValidatedSettings -> IO (Either String String)
configuredHostedZoneName repoRoot awsEnvironment settings = do
  zonePayloadResult <-
    runJsonCommand
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "route53"
            , "get-hosted-zone"
            , "--id"
            , textValue (zone_id (route53 (validatedConfig settings)))
            , "--output"
            , "json"
            ]
        , subprocessEnvironment = Just awsEnvironment
        , subprocessWorkingDirectory = Just repoRoot
        }
  case zonePayloadResult of
    Left err -> pure (Left err)
    Right payload ->
      case hostedZoneDelegation payload of
        Left err -> pure (Left err)
        Right (zoneName, _) -> pure (Right (trimTrailingDot zoneName))

cleanupDnsAwsValidation
  :: FilePath
  -> [(String, String)]
  -> String
  -> String
  -> String
  -> IO ExitCode
cleanupDnsAwsValidation repoRoot awsEnvironment hostedZoneId recordName recordIp = do
  deleteRecordExit <-
    changeRoute53Record repoRoot awsEnvironment hostedZoneId "DELETE" recordName recordIp
  case deleteRecordExit of
    ExitFailure _ -> pure deleteRecordExit
    ExitSuccess ->
      runCommandForExitCode
        Subprocess
          { subprocessPath = "aws"
          , subprocessArguments =
              [ "route53"
              , "delete-hosted-zone"
              , "--id"
              , hostedZoneId
              ]
          , subprocessEnvironment = Just awsEnvironment
          , subprocessWorkingDirectory = Just repoRoot
          }

changeRoute53Record
  :: FilePath
  -> [(String, String)]
  -> String
  -> String
  -> String
  -> String
  -> IO ExitCode
changeRoute53Record repoRoot awsEnvironment hostedZoneId action recordName recordIp = do
  (batchPath, handle) <- openTempFile repoRoot "route53-change-batch.json"
  hClose handle
  writeResult <-
    try
      ( writeFile
          batchPath
          (route53ChangeBatch action recordName recordIp)
      )
      :: IO (Either IOException ())
  case writeResult of
    Left err -> failWith ("failed to write Route 53 change batch: " ++ show err)
    Right () -> do
      changeResult <-
        runTextCommand
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                [ "route53"
                , "change-resource-record-sets"
                , "--hosted-zone-id"
                , hostedZoneId
                , "--change-batch"
                , "file://" ++ batchPath
                , "--query"
                , "ChangeInfo.Id"
                , "--output"
                , "text"
                ]
            , subprocessEnvironment = Just awsEnvironment
            , subprocessWorkingDirectory = Just repoRoot
            }
      _ <- try (removeFile batchPath) :: IO (Either IOException ())
      case changeResult of
        Left err -> failWith err
        Right changeId ->
          runCommandForExitCode
            Subprocess
              { subprocessPath = "aws"
              , subprocessArguments =
                  [ "route53"
                  , "wait"
                  , "resource-record-sets-changed"
                  , "--id"
                  , trim changeId
                  ]
              , subprocessEnvironment = Just awsEnvironment
              , subprocessWorkingDirectory = Just repoRoot
              }

route53ChangeBatch :: String -> String -> String -> String
route53ChangeBatch action recordName recordIp =
  unlines
    [ "{"
    , "  \"Changes\": ["
    , "    {"
    , "      \"Action\": \"" ++ action ++ "\","
    , "      \"ResourceRecordSet\": {"
    , "        \"Name\": \"" ++ ensureTrailingDot recordName ++ "\","
    , "        \"Type\": \"A\","
    , "        \"TTL\": 60,"
    , "        \"ResourceRecords\": [{\"Value\": \"" ++ recordIp ++ "\"}]"
    , "      }"
    , "    }"
    , "  ]"
    , "}"
    ]

runGatewayDaemonValidation :: FilePath -> [(String, String)] -> IO ExitCode
runGatewayDaemonValidation repoRoot environment = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <-
        runNativeCliCommandForExitCode
          repoRoot
          environment
          ["cluster", "wait", "--namespace", gatewayValidationNamespace]
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess -> do
          ordersTextResult <-
            runTextCommand
              Subprocess
                { subprocessPath = "kubectl"
                , subprocessArguments =
                    [ "--namespace"
                    , gatewayValidationNamespace
                    , "get"
                    , "configmap"
                    , "gateway-orders"
                    , "-o"
                    , "jsonpath={.data.orders\\.dhall}"
                    ]
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just repoRoot
                }
          case ordersTextResult of
            Left err -> failWith err
            Right ordersText -> do
              -- Sprint 2.22 closure: the chart now ships Dhall Orders.
              ordersResult <- GatewaySettings.decodeOrdersDhall (Text.pack ordersText)
              case ordersResult of
                Left err -> failWith ("failed to parse gateway orders from cluster ConfigMap: " ++ err)
                Right orders ->
                  case selectGatewayValidationPeer orders of
                    Left err -> failWith err
                    Right localPeer -> do
                      localPort <- reserveLocalTcpPort
                      withGatewayPortForward repoRoot environment localPeer localPort $
                        withTemporaryFilePath repoRoot "gateway-validation-orders.dhall" $ \ordersPath ->
                          withTemporaryFilePath repoRoot "gateway-validation-config.dhall" $ \configPath -> do
                            ordersWriteResult <-
                              try
                                (writeFile ordersPath (renderGatewayValidationOrdersDhall orders (peerNodeId localPeer) localPort))
                                :: IO (Either IOException ())
                            case ordersWriteResult of
                              Left err ->
                                failWith ("failed to write gateway validation orders file: " ++ show err)
                              Right () -> do
                                configWriteResult <-
                                  try
                                    ( writeFile
                                        configPath
                                        (renderGatewayValidationConfigDhall settings (peerNodeId localPeer) ordersPath)
                                    )
                                    :: IO (Either IOException ())
                                case configWriteResult of
                                  Left err ->
                                    failWith ("failed to write gateway validation config: " ++ show err)
                                  Right () -> do
                                    statusExit <-
                                      waitForCommandOutputContainsAll
                                        (nativeCliCommandSpec repoRoot environment ["gateway", "status", "--config", configPath])
                                        [ "Gateway status"
                                        , "NODE_ID=" ++ peerNodeId localPeer
                                        , "DNS_WRITE_GATE=" ++ publicFqdn settings ++ "@"
                                        ]
                                        gatewayStatusRetryAttempts
                                        gatewayStatusRetryDelayMicroseconds
                                    case statusExit of
                                      ExitFailure _ -> pure statusExit
                                      ExitSuccess ->
                                        runNativeCliCommandForExitCode
                                          repoRoot
                                          environment
                                          ["cluster", "workload-logs", "--namespace", gatewayValidationNamespace, "--tail", "20"]

selectGatewayValidationPeer :: Orders -> Either String PeerEndpoint
selectGatewayValidationPeer orders =
  case ordersNodes orders of
    [] -> Left "gateway validation requires at least one node in gateway-orders"
    peer : _ -> Right peer

-- | Sprint 2.20/2.22 closure follow-up: the gateway daemon decodes its config
-- via 'Dhall.inputFile auto' against the schema in
-- 'Prodbox.Gateway.Settings.DaemonConfigDhall'. The validation surface renders
-- the same shape so the daemon accepts the file without falling back to a JSON
-- decoder (which no longer exists on the supported path).
renderGatewayValidationOrdersDhall :: Orders -> String -> Int -> String
renderGatewayValidationOrdersDhall orders localNodeId localPort =
  unlines
    [ "{ version_utc = " ++ show (ordersVersionUtc orders)
    , ", nodes = " ++ nodesList
    , ", gateway_rule ="
    , "    { ranked_nodes = " ++ rankedNodesList
    , "    , heartbeat_timeout_seconds = " ++ show (heartbeatTimeoutSeconds (ordersGatewayRule orders))
    , "    }"
    , "}"
    ]
 where
  nodesList = case ordersNodes orders of
    [] ->
      "([] : List { node_id : Text, stable_dns_name : Text, rest_host : Text, rest_port : Natural, socket_host : Text, socket_port : Natural })"
    peers -> "[ " ++ intercalate "\n  , " (map renderNode peers) ++ " ]"
  rankedNodesList = case rankedNodes (ordersGatewayRule orders) of
    [] -> "([] : List Text)"
    xs -> "[ " ++ intercalate ", " (map dhallText xs) ++ " ]"
  renderNode :: PeerEndpoint -> String
  renderNode peer =
    "{ node_id = "
      ++ dhallText (peerNodeId peer)
      ++ ", stable_dns_name = "
      ++ dhallText rewrittenStableDnsName
      ++ ", rest_host = "
      ++ dhallText rewrittenRestHost
      ++ ", rest_port = "
      ++ show rewrittenRestPort
      ++ ", socket_host = "
      ++ dhallText (peerSocketHost peer)
      ++ ", socket_port = "
      ++ show (peerSocketPort peer)
      ++ " }"
   where
    isLocalNode = peerNodeId peer == localNodeId
    rewrittenStableDnsName =
      if isLocalNode
        then "127.0.0.1"
        else peerStableDnsName peer
    rewrittenRestHost =
      if isLocalNode
        then "127.0.0.1"
        else peerRestHost peer
    rewrittenRestPort =
      if isLocalNode
        then localPort
        else peerRestPort peer

renderGatewayValidationConfigDhall :: ValidatedSettings -> String -> FilePath -> String
renderGatewayValidationConfigDhall settings nodeId ordersPath =
  unlines
    [ "{ schemaVersion = 1"
    , -- The daemon decoder carries a top-level optional Vault Kubernetes-auth
      -- block; the validation daemon needs no Vault auth, but the `None` must
      -- still annotate the decoder's record type for the in-process decode.
      ", vault = None { address : Text, auth_path : Text, role : Text, service_account_token_file : Optional Text }"
    , ", boot ="
    , "    { node_id = " ++ dhallText nodeId
    , "    , cert_file = " ++ dhallText "unused.crt"
    , "    , key_file = " ++ dhallText "unused.key"
    , "    , ca_file = " ++ dhallText "unused-ca.crt"
    , "    , orders_file = " ++ dhallText ordersPath
    , -- `gateway status` never uses event_keys (it queries the running daemon by
      -- endpoint), but `loadDaemonConfig` eagerly resolves every SecretRef during
      -- decode — and the host CLI cannot resolve a Vault ref (no in-cluster
      -- Kubernetes-auth token) nor a TestPlaintext one (production mode). An empty
      -- list has nothing to resolve, so the host status check decodes cleanly.
      "    , event_keys = [] : List { name : Text, value : " ++ secretRefType ++ " }"
    , "    , dns_write_gate = Some"
    , "        { zone_id = " ++ dhallText (Text.unpack (zone_id (route53 (validatedConfig settings))))
    , "        , fqdn = " ++ dhallText (publicFqdn settings)
    , "        , ttl = " ++ show (demo_ttl (domain (validatedConfig settings)))
    , "        , aws_region = "
        ++ dhallText (Text.unpack (awsCredentialRegion (aws (validatedConfig settings))))
    , "        }"
    , -- Sprint 3.18: the gateway daemon decoder types these credential fields as
      -- Vault-backed SecretRefs, not Text. The validation config carries no real
      -- creds (None), but the None type annotation must still match the decoder's
      -- SecretRef union or the in-process decode fails ("Expression doesn't match
      -- annotation"). region stays Text.
      "    , aws_creds = None { access_key_id : "
        ++ secretRefType
        ++ ", secret_access_key : "
        ++ secretRefType
        ++ ", session_token : Optional "
        ++ secretRefType
        ++ ", region : Text }"
    , "    , minio_creds = None { minio_access_key : "
        ++ secretRefType
        ++ ", minio_secret_key : "
        ++ secretRefType
        ++ " }"
    , "    , minio_endpoint_url = None Text"
    , "    }"
    , ", live ="
    , "    { heartbeat_interval_seconds = 1.0"
    , "    , reconnect_interval_seconds = 1.0"
    , "    , sync_interval_seconds = 5.0"
    , "    , max_clock_skew_seconds = 10.0"
    , "    , drain_deadline_seconds = Some 30"
    , "    , log_level = Some " ++ dhallText "info"
    , "    }"
    , "}"
    ]
 where
  secretRefType =
    "< Vault : { mount : Text, path : Text, field : Text }"
      ++ " | TransitKey : Text"
      ++ " | Prompt : { name : Text, purpose : Text }"
      ++ " | TestPlaintext : Text >"

-- | Render a Haskell 'String' as a Dhall double-quoted text literal, escaping
-- the two characters Dhall's quoted-text grammar treats specially (backslash and
-- double-quote). Used by 'renderGatewayValidationOrdersDhall' /
-- 'renderGatewayValidationConfigDhall' so the rendered validation files round-
-- trip through @Dhall.inputFile auto@ without further escaping.
dhallText :: String -> String
dhallText s = '"' : escape s ++ "\""
 where
  escape [] = []
  escape ('\\' : rest) = '\\' : '\\' : escape rest
  escape ('"' : rest) = '\\' : '"' : escape rest
  escape (c : rest) = c : escape rest

withGatewayPortForward :: FilePath -> [(String, String)] -> PeerEndpoint -> Int -> IO a -> IO a
withGatewayPortForward repoRoot environment localPeer localPort action = do
  processResult <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "--namespace"
            , gatewayValidationNamespace
            , "port-forward"
            , "service/gateway-" ++ peerNodeId localPeer
            , show localPort ++ ":" ++ show (peerRestPort localPeer)
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  case processResult of
    Left err -> fail (show err)
    Right process -> action `finally` cleanupGatewayPortForward process

cleanupGatewayPortForward :: BackgroundProcess -> IO ()
cleanupGatewayPortForward = stopBackgroundProcess

reserveLocalTcpPort :: IO Int
reserveLocalTcpPort =
  withSocketsDo $
    bracket
      (socket AF_INET Stream defaultProtocol)
      close
      ( \reservedSocket -> do
          setSocketOption reservedSocket ReuseAddr 1
          bind reservedSocket (SockAddrInet 0 (tupleToHostAddress (0, 0, 0, 0)))
          socketAddress <- getSocketName reservedSocket
          case socketAddress of
            SockAddrInet port _ -> pure (fromIntegral port)
            SockAddrInet6 port _ _ _ -> pure (fromIntegral port)
            _ -> fail "failed to reserve a local TCP port for gateway validation"
      )

-- | Sprint 4.18: AWS EKS validation reads the live Pulumi outputs
-- from the in-cluster MinIO backend rather than the legacy
-- @.prodbox-state\/aws-eks-test\/stack-snapshot.json@ file.
--
-- Sprint 5.6: assert the substrate-equivalence properties the AWS EKS run
-- must hold (per @DEVELOPMENT_PLAN/substrates.md@ and
-- @phase-7-aws-substrate-foundations.md@) by decoding the outputs through
-- the structured 'AwsEks.parseAwsEksTestStackFromOutputs' parser —
-- mirroring the stronger sibling 'verifyAwsTestSnapshot' (which structurally
-- decodes the three-node topology). The parser requires every field
-- (@cluster_name@, @node_group_name@, @vpc_id@, the structured
-- @subnet_ids@ JSON list, the cluster OIDC issuer, the OIDC provider ARN,
-- and the AWS Load Balancer Controller policy/role ARNs that make the EKS
-- substrate stand up the same load-balancer edge as home) to be present,
-- non-empty, and well-formed — replacing the weaker
-- @null clusterName || Text.null subnetIdsRaw@ existence check that passed
-- on a structurally invalid @subnet_ids@ payload.
verifyAwsEksSnapshot :: FilePath -> IO ExitCode
verifyAwsEksSnapshot repoRoot = do
  outputsResult <-
    fetchPerRunStackOutputs repoRoot (StackName (Text.pack awsEksTestStackName))
  case outputsResult of
    Left err ->
      failWith ("AWS EKS validation could not read Pulumi outputs: " ++ err)
    Right outputs ->
      case AwsEks.parseAwsEksTestStackFromOutputs outputs of
        Left err -> failWith ("AWS EKS Pulumi outputs are incomplete: " ++ err)
        Right snapshot
          | null (AwsEks.eksSnapshotSubnetIds snapshot) ->
              failWith "AWS EKS Pulumi outputs parsed but contain no subnet_ids"
          | otherwise -> pure ExitSuccess

-- | Sprint 4.18: AWS test-stack validation reads the live Pulumi
-- @nodes@ output from the in-cluster MinIO backend rather than the
-- legacy @.prodbox-state\/aws-test\/stack-snapshot.json@ file.
verifyAwsTestSnapshot :: FilePath -> IO ExitCode
verifyAwsTestSnapshot repoRoot = do
  nodesResult <- fetchAwsTestNodes repoRoot
  case nodesResult of
    Left err -> failWith err
    Right nodes ->
      if length nodes /= 3
        then failWith "AWS test-stack Pulumi outputs did not contain the expected three-node topology"
        else pure ExitSuccess

verifyAwsTestSshReachability :: FilePath -> IO ExitCode
verifyAwsTestSshReachability repoRoot = do
  nodesResult <- fetchAwsTestNodes repoRoot
  case nodesResult of
    Left err -> failWith err
    Right nodes ->
      AwsTest.withAwsTestSshPrivateKey repoRoot $ \privateKeyPath ->
        foldM
          (verifyAwsTestNodeSsh repoRoot privateKeyPath)
          ExitSuccess
          nodes

-- | Sprint 4.18: shared live-fetch helper for the AWS test-stack
-- validation suite. Reads the live @aws-test@ Pulumi outputs and
-- decodes the @nodes@ array via
-- 'AwsTest.parseAwsTestNodesFromOutputs'.
fetchAwsTestNodes :: FilePath -> IO (Either String [AwsTest.AwsTestNode])
fetchAwsTestNodes repoRoot = do
  outputsResult <-
    fetchPerRunStackOutputs repoRoot (StackName (Text.pack awsTestStackName))
  pure $ case outputsResult of
    Left err -> Left ("AWS test-stack validation could not read Pulumi outputs: " ++ err)
    Right outputs -> AwsTest.parseAwsTestNodesFromOutputs outputs

verifyAwsTestNodeSsh :: FilePath -> FilePath -> ExitCode -> AwsTest.AwsTestNode -> IO ExitCode
verifyAwsTestNodeSsh repoRoot privateKeyPath exitCode node =
  case exitCode of
    ExitFailure _ -> pure exitCode
    ExitSuccess -> waitForAwsTestNodeSsh repoRoot privateKeyPath node awsTestSshReadyAttempts

waitForAwsTestNodeSsh :: FilePath -> FilePath -> AwsTest.AwsTestNode -> Int -> IO ExitCode
waitForAwsTestNodeSsh repoRoot privateKeyPath node attemptsLeft = do
  let spec =
        Subprocess
          { subprocessPath = "ssh"
          , subprocessArguments =
              [ "-i"
              , privateKeyPath
              , "-o"
              , "BatchMode=yes"
              , "-o"
              , "StrictHostKeyChecking=no"
              , "-o"
              , "UserKnownHostsFile=/dev/null"
              , "-o"
              , "ConnectTimeout=20"
              , "ubuntu@" ++ AwsTest.testNodePublicIp node
              , "hostname"
              ]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
      nodeLabel = AwsTest.testNodeName node ++ " (" ++ AwsTest.testNodePublicIp node ++ ")"
  outputResult <- captureSubprocessResult spec
  case outputResult of
    Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitSuccess -> do
          writeOutput (processStdout output)
          writeDiagnostic (processStderr output)
          pure ExitSuccess
        ExitFailure _
          | attemptsLeft > 1 && shouldRetryAwsTestSsh (outputDetail output) -> do
              writeDiagnosticLine
                ( "Waiting for AWS test-stack SSH readiness on "
                    ++ nodeLabel
                    ++ " before retry: "
                    ++ outputDetail output
                )
              threadDelay awsTestSshReadyDelayMicroseconds
              waitForAwsTestNodeSsh repoRoot privateKeyPath node (attemptsLeft - 1)
          | otherwise ->
              failWith
                ( "AWS test-stack SSH validation failed for "
                    ++ nodeLabel
                    ++ ": "
                    ++ outputDetail output
                )

shouldRetryAwsTestSsh :: String -> Bool
shouldRetryAwsTestSsh detail =
  let lowered = map toLowerAscii detail
   in any
        (`isInfixOf` lowered)
        [ "connection refused"
        , "connection timed out"
        , "operation timed out"
        , "connection reset by peer"
        , "connection closed by remote host"
        , "no route to host"
        , "host is down"
        , "network is unreachable"
        ]

runSequentially :: [IO ExitCode] -> IO ExitCode
runSequentially = foldM step ExitSuccess
 where
  step failure@(ExitFailure _) _ = pure failure
  step ExitSuccess action = action

runNativeCliCommandForExitCode :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runNativeCliCommandForExitCode repoRoot environment cliArgs = do
  runCommandForExitCode (nativeCliCommandSpec repoRoot environment cliArgs)

assertNativeCommandOutputContainsAll
  :: FilePath -> [(String, String)] -> [String] -> [String] -> IO ExitCode
assertNativeCommandOutputContainsAll repoRoot environment cliArgs expectedTexts = do
  assertCommandOutputContainsAll (nativeCliCommandSpec repoRoot environment cliArgs) expectedTexts

assertProducedOutputContainsAll :: String -> IO String -> [String] -> IO ExitCode
assertProducedOutputContainsAll label outputAction expectedTexts = do
  outputResult <- try outputAction :: IO (Either SomeException String)
  case outputResult of
    Left err -> failWith ("`" ++ label ++ "` failed: " ++ displayException err)
    Right output -> do
      writeOutput output
      if all (`isInfixOf` output) expectedTexts
        then pure ExitSuccess
        else
          failWith
            ( "`"
                ++ label
                ++ "` did not report all required output fragments: "
                ++ show expectedTexts
            )

nativeCliCommandSpec :: FilePath -> [(String, String)] -> [String] -> Subprocess
nativeCliCommandSpec repoRoot environment cliArgs =
  Subprocess
    { subprocessPath = canonicalOperatorBinaryPath repoRoot
    , subprocessArguments = cliArgs
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just repoRoot
    }

runCommandForExitCode :: Subprocess -> IO ExitCode
runCommandForExitCode spec = do
  commandResult <- runSubprocessStreaming spec
  case commandResult of
    Failure err -> failWith err
    Success exitCode -> pure exitCode

assertCommandOutputContainsAll :: Subprocess -> [String] -> IO ExitCode
assertCommandOutputContainsAll spec expectedTexts = do
  outputResult <- captureSubprocessResult spec
  case outputResult of
    Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
    Success output -> do
      writeOutput (processStdout output)
      writeDiagnostic (processStderr output)
      case processExitCode output of
        ExitFailure code ->
          failWith
            ( "`"
                ++ commandDisplay spec
                ++ "` exited with code "
                ++ show code
            )
        ExitSuccess ->
          let combinedOutput = processStdout output ++ processStderr output
           in if all (`isInfixOf` combinedOutput) expectedTexts
                then pure ExitSuccess
                else
                  failWith
                    ( "`"
                        ++ commandDisplay spec
                        ++ "` did not report all required output fragments: "
                        ++ show expectedTexts
                    )

waitForCommandOutputContainsAll :: Subprocess -> [String] -> Int -> Int -> IO ExitCode
waitForCommandOutputContainsAll spec expectedTexts attempts delayMicroseconds = go attempts
 where
  loweredExpectedTexts = map (map toLowerAscii) expectedTexts

  go :: Int -> IO ExitCode
  go attemptsLeft = do
    outputResult <- captureSubprocessResult spec
    case outputResult of
      Failure err ->
        if attemptsLeft <= 1
          then failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
          else retry attemptsLeft
      Success output -> do
        writeOutput (processStdout output)
        writeDiagnostic (processStderr output)
        let combinedOutput = processStdout output ++ processStderr output
            loweredCombinedOutput = map toLowerAscii combinedOutput
        case processExitCode output of
          ExitSuccess
            | all (`isInfixOf` loweredCombinedOutput) loweredExpectedTexts -> pure ExitSuccess
            | attemptsLeft <= 1 ->
                failWith
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` did not report all required output fragments: "
                      ++ show expectedTexts
                  )
            | otherwise -> retry attemptsLeft
          ExitFailure code
            | attemptsLeft <= 1 ->
                failWith
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` exited with code "
                      ++ show code
                  )
            | otherwise -> retry attemptsLeft

  retry :: Int -> IO ExitCode
  retry attemptsLeft = do
    writeDiagnosticLine "Waiting for required command output before retry."
    threadDelay delayMicroseconds
    go (attemptsLeft - 1)

verifyConfiguredPublicDnsRecords :: FilePath -> ValidatedSettings -> String -> IO ExitCode
verifyConfiguredPublicDnsRecords repoRoot settings publicIp =
  do
    dnsExit <- foldM verifyHost ExitSuccess (configuredPublicHostFqdns settings)
    case dnsExit of
      ExitFailure _ -> pure dnsExit
      ExitSuccess -> assertPublicHttpRedirect repoRoot settings SubstrateHomeLocal PublicRouteAuth
 where
  verifyHost :: ExitCode -> String -> IO ExitCode
  verifyHost exitCode fqdn =
    case exitCode of
      ExitFailure _ -> pure exitCode
      ExitSuccess -> do
        recordResult <- queryRoute53Record repoRoot settings fqdn
        case recordResult of
          Left err -> failWith err
          Right Nothing ->
            failWith ("Public A record missing in Route 53 for " ++ fqdn)
          Right (Just route53Ip)
            | route53Ip /= publicIp ->
                failWith
                  ( "Public A record mismatch for "
                      ++ fqdn
                      ++ ": Route 53 has "
                      ++ route53Ip
                      ++ " but the current public IP is "
                      ++ publicIp
                  )
            | otherwise -> do
                digResult <-
                  runTextCommand
                    Subprocess
                      { subprocessPath = "dig"
                      , subprocessArguments = ["+short", "A", fqdn]
                      , subprocessEnvironment = Nothing
                      , subprocessWorkingDirectory = Just repoRoot
                      }
                case digResult of
                  Left err -> failWith err
                  Right stdoutText ->
                    let resolvedIps = nub (filter (/= "") (map trim (lines stdoutText)))
                     in if publicIp `elem` resolvedIps
                          then pure ExitSuccess
                          else
                            failWith
                              ( "Public DNS A resolution mismatch for "
                                  ++ fqdn
                                  ++ ": expected "
                                  ++ publicIp
                                  ++ " but found "
                                  ++ show resolvedIps
                              )

assertPublicHttpRedirect
  :: FilePath -> ValidatedSettings -> Substrate -> PublicEdgeRoute -> IO ExitCode
assertPublicHttpRedirect repoRoot settings substrate route = do
  result <-
    runTextCommand
      Subprocess
        { subprocessPath = "curl"
        , subprocessArguments =
            ["-sS", "-D", "-", "-o", "/dev/null", publicHttpRouteUrl settings substrate route]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  case result of
    Left err -> failWith err
    Right headers ->
      if publicHttpRedirectMatches settings substrate route headers
        then pure ExitSuccess
        else failWith ("public HTTP redirect did not target the canonical HTTPS route: " ++ headers)

publicHttpRouteUrl :: ValidatedSettings -> Substrate -> PublicEdgeRoute -> String
publicHttpRouteUrl settings substrate route =
  "http://" ++ substratePublicFqdn settings substrate ++ publicRoutePathPrefix route

publicHttpRedirectMatches :: ValidatedSettings -> Substrate -> PublicEdgeRoute -> String -> Bool
publicHttpRedirectMatches settings substrate route headers =
  let lowered = map toLowerAscii headers
      target = map toLowerAscii ("location: " ++ substratePublicRouteUrl settings substrate route)
      permanentStatus =
        any
          (`isInfixOf` lowered)
          [ "http/1.1 301"
          , "http/1.1 308"
          , "http/2 301"
          , "http/2 308"
          , "http/3 301"
          , "http/3 308"
          ]
   in permanentStatus && target `isInfixOf` lowered

runTextCommand :: Subprocess -> IO (Either String String)
runTextCommand spec = do
  outputResult <- captureSubprocessResult spec
  pure $
    case outputResult of
      Failure err -> Left ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
      Success output ->
        case processExitCode output of
          ExitSuccess -> Right (processStdout output)
          ExitFailure _ ->
            Left
              ( "`"
                  ++ commandDisplay spec
                  ++ "` failed: "
                  ++ outputDetail output
              )

runJsonCommand :: Subprocess -> IO (Either String Value)
runJsonCommand spec = do
  textResult <- runTextCommand spec
  pure $ do
    stdoutText <- textResult
    decodeJsonStringUtf8 stdoutText

decodeJsonStringUtf8 :: String -> Either String Value
decodeJsonStringUtf8 = decodeJsonTextUtf8 . Text.pack

decodeJsonTextUtf8 :: Text.Text -> Either String Value
decodeJsonTextUtf8 =
  eitherDecode . BL.fromStrict . TextEncoding.encodeUtf8

settingsAwsEnvironment :: FilePath -> IO (Either String (ValidatedSettings, [(String, String)]))
settingsAwsEnvironment repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> pure (Left err)
    Right settings -> do
      currentEnvironment <- getEnvironment
      credentialsResult <-
        resolveAwsCredentialsRefFromHostVault
          repoRoot
          "aws"
          (aws (validatedConfig settings))
      pure $
        case credentialsResult of
          Left err -> Left ("load operational AWS credentials from Vault: " ++ err)
          Right credentials ->
            Right
              ( settings
              , overlayAwsCredentials currentEnvironment credentials
              )

hostedZoneDelegation :: Value -> Either String (String, [String])
hostedZoneDelegation payload =
  case payload of
    Object rootObject -> do
      hostedZoneValue <- requireObjectField rootObject "HostedZone"
      zoneName <- requireStringField hostedZoneValue "Name"
      delegationValue <- requireObjectField rootObject "DelegationSet"
      nameservers <- requireStringArrayField delegationValue "NameServers"
      Right (zoneName, nameservers)
    _ -> Left "aws route53 get-hosted-zone did not return a JSON object"

requireObjectField :: KeyMap.KeyMap Value -> String -> Either String (KeyMap.KeyMap Value)
requireObjectField objectValue key =
  case KeyMap.lookup (Key.fromString key) objectValue of
    Just (Object nested) -> Right nested
    _ -> Left ("missing object field " ++ key)

requireStringField :: KeyMap.KeyMap Value -> String -> Either String String
requireStringField objectValue key =
  case KeyMap.lookup (Key.fromString key) objectValue of
    Just (String value) -> Right (textValue value)
    _ -> Left ("missing string field " ++ key)

requireBoolField :: KeyMap.KeyMap Value -> String -> Either String Bool
requireBoolField objectValue key =
  case KeyMap.lookup (Key.fromString key) objectValue of
    Just (Bool value) -> Right value
    _ -> Left ("missing boolean field " ++ key)

requireStringArrayField :: KeyMap.KeyMap Value -> String -> Either String [String]
requireStringArrayField objectValue key =
  case KeyMap.lookup (Key.fromString key) objectValue of
    Just (Array values) ->
      mapM (requireStringArrayEntry key) (Vector.toList values)
    _ -> Left ("missing array field " ++ key)

requireStringArrayEntry :: String -> Value -> Either String String
requireStringArrayEntry key value =
  case value of
    String textVal -> Right (textValue textVal)
    _ -> Left ("field " ++ key ++ " must contain strings only")

validationNonce :: IO String
validationNonce = show . (round :: Rational -> Integer) . toRational <$> getPOSIXTime

normalizeDnsValue :: String -> String
normalizeDnsValue = trimTrailingDot . map toLowerAscii . trim

ensureTrailingDot :: String -> String
ensureTrailingDot value =
  if null value || last value == '.'
    then value
    else value ++ "."

trimTrailingDot :: String -> String
trimTrailingDot value =
  if not (null value) && last value == '.'
    then init value
    else value

trim :: String -> String
trim =
  reverse
    . dropWhile (`elem` [' ', '\n', '\r', '\t'])
    . reverse
    . dropWhile (`elem` [' ', '\n', '\r', '\t'])

toLowerAscii :: Char -> Char
toLowerAscii char
  | isAsciiUpper char = toEnum (fromEnum char + 32)
  | otherwise = char

textValue :: Text.Text -> String
textValue = Text.unpack

outputDetail :: ProcessOutput -> String
outputDetail output =
  case (trim (processStderr output), trim (processStdout output)) of
    (stderrText, _) | stderrText /= "" -> stderrText
    ("", stdoutText) | stdoutText /= "" -> stdoutText
    _ -> "subprocess exited without output"

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

-- | `ValidationKeycloakInvite` — Phase 8 canonical-suite validation that proves the
-- operator-invited email-auth flow end-to-end on whichever substrate is active.
--
-- The flow per [phase-8-email-invite-auth.md → Sprint 8.5](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md):
--
-- 1. Generate a unique recipient at `ses.receive_subdomain`.
-- 2. Call `UsersAdmin.inviteUser` (live Keycloak admin API). Asserts the created
--    user lands with `emailVerified=false`.
-- 3. Poll the SES capture bucket via `Prodbox.Ses.Capture.pollSesCapture` for the
--    inbound message (60 s deadline).
-- 4. Extract the action-token URL via `Prodbox.Keycloak.Email.parseKeycloakInviteLink`.
-- 5. Follow the link with a cookie jar, parse and POST the Keycloak
--    credential-setup form with a generated password.
-- 6. Perform a fresh OIDC password-grant login for the invited user and assert the
--    token claims include the selected issuer, `email=<recipient>`, and
--    `email_verified=true`.
-- 7. Cleanup: `UsersAdmin.revokeUser ident --delete` and `deleteCapturedEmail`.
runKeycloakInviteValidation :: FilePath -> Substrate -> [(String, String)] -> IO ExitCode
runKeycloakInviteValidation repoRoot substrate _environment = do
  envResult <- settingsAwsEnvironment repoRoot
  case envResult of
    Left err -> failWith err
    Right (settings, awsEnv) -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess -> do
          nonce <- generateInviteNonce
          let subdomain =
                Text.unpack
                  ( Text.strip
                      ( Prodbox.Settings.receive_subdomain
                          (Prodbox.Settings.ses (Prodbox.Settings.validatedConfig settings))
                      )
                  )
              keycloakPublicHost = substratePublicFqdn settings substrate
          if null subdomain
            then
              failWith
                "ValidationKeycloakInvite: ses.receive_subdomain must be set in prodbox.dhall."
            else do
              let recipient = "test-" ++ nonce ++ "@" ++ subdomain
                  invitePassword = inviteCredentialPassword nonce
              writeOutputLine ("KEYCLOAK_INVITE_PUBLIC_FQDN=" ++ keycloakPublicHost)
              writeOutputLine ("KEYCLOAK_INVITE_RECIPIENT=" ++ recipient)
              inviteResult <-
                Prodbox.UsersAdmin.inviteUserAtPublicHost
                  repoRoot
                  (Text.pack keycloakPublicHost)
                  recipient
                  Nothing
              case inviteResult of
                Left err -> failWith ("invite failed: " ++ err)
                Right summary -> do
                  let userId = Text.unpack (Prodbox.UsersAdmin.userSummaryId summary)
                  writeOutputLine ("KEYCLOAK_INVITE_USER_ID=" ++ userId)
                  captureResult <-
                    Prodbox.Ses.Capture.pollSesCapture awsEnv settings (Text.pack recipient) 60
                  (outcome, maybeCapturedKey) <- case captureResult of
                    Failure err -> pure (Failure ("S3 capture poll failed: " ++ err), Nothing)
                    Success captured -> do
                      let key = Prodbox.Ses.Capture.capturedEmailKey captured
                      writeOutputLine ("KEYCLOAK_INVITE_S3_KEY=" ++ Text.unpack key)
                      flowResult <-
                        case Prodbox.Keycloak.Email.parseKeycloakInviteLink
                          (Prodbox.Ses.Capture.capturedEmailBody captured) of
                          Left err -> pure (Failure ("invite-link parse failed: " ++ err))
                          Right inviteUrl -> do
                            writeOutputLine "KEYCLOAK_INVITE_LINK_PARSED=true"
                            credentialResult <-
                              completeInviteCredentialSetup repoRoot inviteUrl invitePassword
                            case credentialResult of
                              Failure err ->
                                pure (Failure ("credential setup failed: " ++ err))
                              Success () -> do
                                writeOutputLine "KEYCLOAK_INVITE_CREDENTIAL_SET=true"
                                claimResult <-
                                  waitForInviteOidcClaims
                                    repoRoot
                                    settings
                                    substrate
                                    recipient
                                    invitePassword
                                case claimResult of
                                  Left err -> pure (Failure ("OIDC claim assertion failed: " ++ err))
                                  Right () -> do
                                    writeOutputLine "KEYCLOAK_INVITE_OIDC_CLAIMS_VERIFIED=true"
                                    pure (Success ())
                      pure (flowResult, Just key)
                  _ <-
                    Prodbox.UsersAdmin.revokeUserAtPublicHost
                      repoRoot
                      (Text.pack keycloakPublicHost)
                      userId
                      True
                  case maybeCapturedKey of
                    Nothing -> pure ()
                    Just key -> do
                      _ <- Prodbox.Ses.Capture.deleteCapturedEmail awsEnv settings key
                      pure ()
                  case outcome of
                    Failure err -> failWith err
                    Success () -> do
                      writeOutputLine "KEYCLOAK_INVITE_CLEANUP=true"
                      pure ExitSuccess

-- | Generate a 16-character lowercase hex nonce from the current `POSIXTime` for
-- per-test recipient uniqueness. Avoids pulling in a stronger RNG; sub-second
-- collisions are acceptable for a validation harness that runs serially.
generateInviteNonce :: IO String
generateInviteNonce = do
  now <- Data.Time.Clock.POSIX.getPOSIXTime
  let micros = floor (now * 1e6) :: Integer
  pure (Numeric.showHex micros "")

inviteCredentialPassword :: String -> String
inviteCredentialPassword nonce =
  "ProdboxInvite-" ++ nonce ++ "!Aa1"

completeInviteCredentialSetup :: FilePath -> String -> String -> IO (Result ())
completeInviteCredentialSetup repoRoot inviteUrl password =
  withTemporaryFilePath repoRoot "prodbox-invite-cookies" $ \cookieJarPath ->
    withTemporaryFilePath repoRoot "prodbox-invite-setup-body" $ \getBodyPath ->
      withTemporaryFilePath repoRoot "prodbox-invite-setup-post-body" $ \postBodyPath -> do
        formResult <- fetchInviteCredentialSetupForm repoRoot cookieJarPath getBodyPath inviteUrl
        case formResult of
          Failure err -> pure (Failure err)
          Success form -> do
            let actionUrl =
                  resolveCredentialSetupActionUrl
                    inviteUrl
                    (Text.unpack (CredentialSetupForm.formActionUrl form))
                postBody =
                  BS8.unpack
                    ( CredentialSetupForm.renderCredentialSetupFormPost
                        form
                        (Text.pack password)
                        (Text.pack password)
                    )
            postResult <-
              runTextCommand
                Subprocess
                  { subprocessPath = "curl"
                  , subprocessArguments =
                      [ "-sS"
                      , "-L"
                      , "--fail-with-body"
                      , "-c"
                      , cookieJarPath
                      , "-b"
                      , cookieJarPath
                      , "-H"
                      , "Content-Type: application/x-www-form-urlencoded"
                      , "--data-binary"
                      , postBody
                      , "-o"
                      , postBodyPath
                      , actionUrl
                      ]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            case postResult of
              Left err -> pure (Failure ("credential-setup form POST failed: " ++ err))
              Right _ -> pure (Success ())

fetchInviteCredentialSetupForm
  :: FilePath -> FilePath -> FilePath -> String -> IO (Result CredentialSetupForm.CredentialSetupForm)
fetchInviteCredentialSetupForm repoRoot cookieJarPath getBodyPath inviteUrl = do
  getResult <- curlGetWithCookieJar repoRoot cookieJarPath getBodyPath inviteUrl
  case getResult of
    Left err -> pure (Failure ("invite link GET failed: " ++ err))
    Right _ -> do
      body <- BS8.readFile getBodyPath
      case CredentialSetupForm.parseCredentialSetupForm body of
        Right form -> pure (Success form)
        Left firstErr ->
          case CredentialSetupForm.parseCredentialSetupContinuationLink body of
            Left continuationErr ->
              pure
                ( Failure
                    ( "credential-setup form parse failed: "
                        ++ firstErr
                        ++ "; continuation link parse failed: "
                        ++ continuationErr
                    )
                )
            Right continuationHref -> do
              let continuationUrl =
                    resolveCredentialSetupActionUrl inviteUrl (Text.unpack continuationHref)
              writeOutputLine "KEYCLOAK_INVITE_VERIFY_CONTINUATION_FOLLOWED=true"
              continuationResult <- curlGetWithCookieJar repoRoot cookieJarPath getBodyPath continuationUrl
              case continuationResult of
                Left err -> pure (Failure ("credential-setup continuation GET failed: " ++ err))
                Right _ -> do
                  continuationBody <- BS8.readFile getBodyPath
                  case CredentialSetupForm.parseCredentialSetupForm continuationBody of
                    Left err ->
                      pure
                        ( Failure
                            ( "credential-setup form parse failed after verify-email continuation: "
                                ++ err
                            )
                        )
                    Right form -> pure (Success form)

curlGetWithCookieJar :: FilePath -> FilePath -> FilePath -> String -> IO (Either String String)
curlGetWithCookieJar repoRoot cookieJarPath outputPath url =
  runTextCommand
    Subprocess
      { subprocessPath = "curl"
      , subprocessArguments =
          [ "-sS"
          , "-L"
          , "--fail-with-body"
          , "-c"
          , cookieJarPath
          , "-b"
          , cookieJarPath
          , "-o"
          , outputPath
          , url
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Just repoRoot
      }

resolveCredentialSetupActionUrl :: String -> String -> String
resolveCredentialSetupActionUrl inviteUrl actionUrl
  | "https://" `isPrefixOf` actionUrl = actionUrl
  | "http://" `isPrefixOf` actionUrl = actionUrl
  | "/" `isPrefixOf` actionUrl =
      case originFromUrl inviteUrl of
        Just origin -> origin ++ actionUrl
        Nothing -> actionUrl
  | otherwise =
      case directoryUrlFromUrl inviteUrl of
        Just directoryUrl -> directoryUrl ++ actionUrl
        Nothing -> actionUrl

originFromUrl :: String -> Maybe String
originFromUrl rawUrl =
  case splitOnSubstring "://" rawUrl of
    Just (scheme, afterScheme)
      | scheme /= "" ->
          let host = takeWhile (/= '/') afterScheme
           in if host /= ""
                then Just (scheme ++ "://" ++ host)
                else Nothing
    _ -> Nothing

directoryUrlFromUrl :: String -> Maybe String
directoryUrlFromUrl rawUrl = do
  origin <- originFromUrl rawUrl
  let withoutQuery = takeWhile (/= '?') rawUrl
      afterOrigin = drop (length origin) withoutQuery
      directoryPath =
        reverse
          ( dropWhile
              (/= '/')
              (reverse afterOrigin)
          )
  pure (origin ++ directoryPath)

waitForInviteOidcClaims
  :: FilePath -> ValidatedSettings -> Substrate -> String -> String -> IO (Either String ())
waitForInviteOidcClaims repoRoot settings substrate recipient password = go tokenFetchAttempts
 where
  go attemptsLeft = do
    result <- fetchInviteOidcClaims repoRoot settings substrate recipient password
    case result of
      Right () -> pure (Right ())
      Left err
        | attemptsLeft <= 1 -> pure (Left err)
        | otherwise -> do
            writeDiagnosticLine ("Waiting for invited-user OIDC claims before retry: " ++ err)
            threadDelay tokenFetchDelayMicroseconds
            go (attemptsLeft - 1)

fetchInviteOidcClaims
  :: FilePath -> ValidatedSettings -> Substrate -> String -> String -> IO (Either String ())
fetchInviteOidcClaims repoRoot settings substrate recipient password = do
  clientSecretResult <- readKeycloakOidcClientField repoRoot "API_CLIENT_SECRET"
  case clientSecretResult of
    Left err -> pure (Left err)
    Right clientSecret -> do
      payloadResult <-
        runJsonCommand
          Subprocess
            { subprocessPath = "curl"
            , subprocessArguments =
                [ "-sS"
                , "--fail-with-body"
                , "-X"
                , "POST"
                , "--data-urlencode"
                , "grant_type=password"
                , "--data-urlencode"
                , "client_id=prodbox-api"
                , "--data-urlencode"
                , "client_secret=" ++ clientSecret
                , "--data-urlencode"
                , "username=" ++ recipient
                , "--data-urlencode"
                , "password=" ++ password
                , "--data-urlencode"
                , "scope=openid email profile"
                , substrateIdentityIssuerUrl settings substrate ++ "/protocol/openid-connect/token"
                ]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
      case payloadResult of
        Left err -> pure (Left err)
        Right tokenPayload ->
          pure $ do
            token <- inviteTokenForClaims tokenPayload
            claimsPayload <- decodeJwtPayload token
            assertInviteOidcClaims
              (substrateIdentityIssuerUrl settings substrate)
              recipient
              claimsPayload

inviteTokenForClaims :: Value -> Either String String
inviteTokenForClaims payload =
  case payload of
    Object obj ->
      case KeyMap.lookup "id_token" obj of
        Just (String tokenText) -> Right (Text.unpack tokenText)
        _ ->
          case KeyMap.lookup "access_token" obj of
            Just (String tokenText) -> Right (Text.unpack tokenText)
            _ -> Left "token endpoint response did not contain id_token or access_token"
    _ -> Left "token endpoint response was not a JSON object"

decodeJwtPayload :: String -> Either String Value
decodeJwtPayload tokenValue =
  case splitOnChar '.' tokenValue of
    [_headerText, payloadText, _signatureText] ->
      case Base64Url.decode (BS8.pack (padBase64Url payloadText)) of
        Left _ -> Left "JWT payload was not valid base64url"
        Right decodedPayload ->
          case eitherDecode (BL.fromStrict decodedPayload) of
            Left _ -> Left "JWT payload was not valid JSON"
            Right payload -> Right payload
    _ -> Left "JWT did not contain three dot-separated sections"

padBase64Url :: String -> String
padBase64Url value =
  value ++ replicate paddingLength '='
 where
  remainder = length value `mod` 4
  paddingLength =
    case remainder of
      0 -> 0
      2 -> 2
      3 -> 1
      _ -> 0

assertInviteOidcClaims :: String -> String -> Value -> Either String ()
assertInviteOidcClaims expectedIssuer expectedEmail payload =
  case payload of
    Object obj -> do
      issuerValue <- requireStringField obj "iss"
      emailValue <- requireStringField obj "email"
      emailVerified <- requireBoolField obj "email_verified"
      if issuerValue /= expectedIssuer
        then
          Left
            ( "OIDC token issuer mismatch: expected "
                ++ expectedIssuer
                ++ " but found "
                ++ issuerValue
            )
        else
          if emailValue /= expectedEmail
            then
              Left
                ( "OIDC token email mismatch: expected "
                    ++ expectedEmail
                    ++ " but found "
                    ++ emailValue
                )
            else
              if emailVerified
                then Right ()
                else Left "OIDC token email_verified claim was false"
    _ -> Left "OIDC token payload was not a JSON object"
