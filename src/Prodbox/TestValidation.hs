{-# LANGUAGE OverloadedStrings #-}

module Prodbox.TestValidation
  ( runNativeValidation
  , cascadeQualificationCycleVariable
  , NativeValidationKubeconfigMode (..)
  , nativeValidationKubeconfigMode
  , overlayKubeconfig
  , namespaceResourceQuotaHardFields
  , namespaceLimitRangeContainerFields
  , gatewayRuntimeExpectedReplicas
  , gatewayRuntimeKubeconfigRetryDelayMicroseconds
  , runNativeValidationWithGatewayStability
  , GatewayRuntimeStabilityRecorder
  , GatewayRuntimeStabilityMonitor
  , newGatewayRuntimeStabilityRecorder
  , withGatewayRuntimeStabilityMonitor
  , pauseGatewayRuntimeStabilityMonitor
  , refreshGatewayRuntimeStabilityMonitor
  , resumeGatewayRuntimeStabilityMonitor
  , recordGatewayRuntimeStabilitySample
  , GatewayRuntimeSampleOutcome (..)
  , gatewayRuntimeSampleOutcome
  , gatewayRuntimeSampleOutcomeExit
  , resetGatewayRuntimeStabilityHealthyWindow
  , runGatewayRuntimeStabilityGate
  , recordGatewayMeasuredProfile
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
  , quantitiesEquivalent
  , volumeRebindReport
  , verifyAwsTestSshReachability
  , assertInviteOidcClaims
  , gatewayPartitionValidationReport
  , gatewayPartitionLegacyReport
  , gatewayPartitionLegacyReportFor
  , gatewayPartitionCanonicalMembers
  , DaemonBootstrapAuditProvenance (..)
  , daemonBootstrapBrokerBaseUrl
  , daemonBootstrapRequiredRoutes
  , daemonBootstrapHostRootTokenPatterns
  , renderGatewayValidationConfigDhall
  , demoOidcSessionValidationAgentManifest
  , gatewayEmitterStatefulSets
  , sealStateFromVaultStatusOutput
  , observedBrokerRouteLine
  , keycloakInviteRecipient
  , retryWhileGatewayDnsPending
  , InviteMailObservation (..)
  , parseInviteMailEvidence
  , parseValidationZoneEvidence
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
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (isAsciiUpper, isSpace)
import Data.Either (lefts, rights)
import Data.Foldable (asum)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Data.Vector qualified as Vector
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
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
import Prodbox.Bootstrap.Broker.Client (BrokerEndpoint, brokerRouteUrl)
import Prodbox.Bootstrap.Broker.PortForward
  ( renderBrokerHostConnectionError
  , withBrokerHostConnection
  )
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerRoute (..)
  , brokerRoutePath
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
  , resolveRetainedManualPvRoot
  , retainedStorageInventoryEntries
  )
import Prodbox.CLI.Vault (brokerHostConnection, freshVaultIdempotencyKey)
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.MeasuredProfile qualified as MeasuredProfile
import Prodbox.Capacity.Placement qualified as Placement
import Prodbox.Capacity.Render qualified as CapacityRender
import Prodbox.Cbor
  ( CborPayload (..)
  )
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.ControlPlane.Capacity qualified as EmitterCapacity
import Prodbox.ControlPlane.Deadline qualified as Deadline
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityTestHarness)
  )
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchHostProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( OidcIdentity (..)
  )
import Prodbox.Dns
  ( configuredPublicHostFqdns
  , fetchPublicIp
  , queryRoute53Record
  )
import Prodbox.Error (AppError, errorMsg, fatalError)
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
import Prodbox.Lib.Storage (testManualPvHostRootEnv)
import Prodbox.Lifecycle.LiveResidue
  ( awsEksTestStackName
  , awsTestStackName
  , fetchPerRunStackOutputs
  )
import Prodbox.Lifecycle.OwnedResourceTags (dnsValidationHostedZoneNamePrefix)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent
      ( EnsureValidationHostedZone
      , ObserveProviderReadiness
      , ObservePublicARecord
      , ObserveSesInviteMail
      , ReapSesInviteMail
      , ReapValidationHostedZones
      , ReconcilePublicARecord
      )
  , ProviderReadinessProbe (ProviderReadinessRoute53Zone)
  , mkPublicARecordRef
  )
import Prodbox.Lifecycle.ResourceClass
  ( LifecycleClass (..)
  )
import Prodbox.Lifecycle.Teardown.CascadeCandidate
  ( CascadeCandidatePlanSummary (..)
  , fixedCascadeCandidatePlanSummary
  )
import Prodbox.Lifecycle.ValidationHostedZone qualified as Route53ValidationZone
import Prodbox.Minio.ObjectStoreTypes (defaultObjectStoreBucket)
import Prodbox.PublicEdge
  ( PublicEdgeReadinessObservation (..)
  , PublicEdgeRoute (..)
  , classifyPublicEdgeReadinessObservation
  , gatewayDnsWriteAuthorityNotReadyDiagnostic
  , publicEdgeReadyClassification
  , publicFqdn
  , publicRoutePathPrefix
  , requireSubstratePublicFqdn
  , requireSubstrateServedHost
  , servedHostString
  , substrateIdentityIssuerUrl
  , substratePublicRouteUrl
  , substrateServedHostMissing
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
import Prodbox.Settings
  ( ValidatedCoordinates (..)
  , ValidatedServedHost (..)
  , ValidatedSettings (..)
  , homeZoneIdTextForRendering
  , requireHomeZoneId
  , validateAndLoadSettings
  , validatedCoordinates
  )
import Prodbox.Settings qualified
import Prodbox.Settings.Coordinate
  ( awsRegionText
  , dnsTtlSeconds
  , route53ZoneIdText
  , s3BucketNameText
  )
import Prodbox.Subprocess
  ( BackgroundProcess
  , BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  , captureSubprocessResult
  , captureSubprocessWithInputBounded
  , commandDisplay
  , runSubprocessStreaming
  , startBackgroundProcess
  , stopBackgroundProcess
  )
import Prodbox.Substrate (Substrate (..), gatewayNodeIdsForSubstrate, substrateId)
import Prodbox.Test.CascadeQualification
  ( cascadeQualificationAttempt
  , cascadeQualificationCycleOutcome
  , cascadeQualificationCyclePassed
  , cascadeQualificationEvidenceDigest
  , cascadeQualificationEvidencePath
  , cascadeQualificationIdentityKey
  , cascadeQualificationLedgerEntries
  , cascadeQualificationLedgerTip
  , cascadeQualificationLifecycleResult
  , cascadeQualificationRunId
  , runCascadeQualificationCandidate
  )
import Prodbox.Test.CascadeQualificationReceipt
  ( ReceiptReport (..)
  , ledgerScanMode
  , ledgerSummaryLines
  , runCascadeQualificationReceipt
  )
import Prodbox.Test.CertificateScopeServing
  ( renderCertificateServingDefect
  , validatePresentedDnsSans
  )
import Prodbox.Test.CleanRoomHandoff qualified as CleanRoom
import Prodbox.Test.CleanRoomScan (productionSources)
import Prodbox.Test.CounterexampleValidation
  ( runControlPlaneCounterexampleValidation
  , runCreateInterruptedValidation
  , runTeardownRecoveryValidation
  )
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
import Prodbox.Tls.CertScope (certScopeSetDnsNames, fqdnText)
import Prodbox.UsersAdmin qualified
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , removeFile
  , renameFile
  )
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

-- | Sprint 5.33: where a daemon-bootstrap audit's trace came from.
--
-- The audit block previously said nothing about its own provenance, which is
-- how its unset arm — the one CI and a bare
-- @prodbox test integration daemon-bootstrap@ take — could be byte-identical to
-- its @"pass"@ fixture arm without that being visible in the output.
data DaemonBootstrapAuditProvenance
  = -- | The Bootstrap Broker daemon was probed live and answered; the transport
    -- lines below are the observation.
    DaemonBootstrapObservedDaemon
  | -- | A named repository fixture supplied the trace. Carries the fixture
    -- name so the emitted evidence says which.
    DaemonBootstrapFixtureTrace !String
  deriving (Eq, Show)

renderDaemonBootstrapProvenance :: DaemonBootstrapAuditProvenance -> String
renderDaemonBootstrapProvenance provenance = case provenance of
  DaemonBootstrapObservedDaemon -> "observed-daemon"
  DaemonBootstrapFixtureTrace name -> "fixture:" ++ name

data DaemonBootstrapAuditInput = DaemonBootstrapAuditInput
  { daemonBootstrapProvenance :: DaemonBootstrapAuditProvenance
  , daemonBootstrapDaemonAvailable :: Bool
  , daemonBootstrapObservedTransports :: [String]
  , daemonBootstrapObservedOutput :: [String]
  , daemonBootstrapRequiredDaemonPaths :: [String]
  }
  deriving (Eq, Show)

-- | Sprint 5.33: the one place the Bootstrap Broker's host-local base URL is
-- written. It was restated inline on every transport line below.
daemonBootstrapBrokerBaseUrl :: String
daemonBootstrapBrokerBaseUrl = "http://127.0.0.1:" ++ show controlPlaneListenPort

-- | The broker routes a daemon-bootstrap run must have travelled. This is a
-- *requirement*, not an observation: it is the compiled set the audit checks
-- the trace against.
daemonBootstrapRequiredRoutes :: [BrokerRoute]
daemonBootstrapRequiredRoutes =
  [ BrokerVaultInitialize
  , BrokerVaultStatus
  , BrokerVaultSeal
  , BrokerVaultRotateUnlockBundle
  , BrokerVaultRotateTransitKey
  , BrokerVaultPkiStatus
  , BrokerVaultPkiIssueTestCertificate
  ]

defaultDaemonBootstrapAuditInput :: DaemonBootstrapAuditInput
defaultDaemonBootstrapAuditInput =
  DaemonBootstrapAuditInput
    { daemonBootstrapProvenance = DaemonBootstrapFixtureTrace "pass"
    , daemonBootstrapDaemonAvailable = True
    , daemonBootstrapObservedTransports =
        [ "TOKENREQUEST audience=prodbox-bootstrap-broker duration=10m"
        , "POST " ++ daemonBootstrapBrokerBaseUrl ++ brokerRoutePath BrokerVaultInitialize
        , "GET " ++ daemonBootstrapBrokerBaseUrl ++ brokerRoutePath BrokerVaultStatus
        , "POST " ++ daemonBootstrapBrokerBaseUrl ++ brokerRoutePath BrokerVaultSeal
        , "POST " ++ daemonBootstrapBrokerBaseUrl ++ brokerRoutePath BrokerVaultRotateUnlockBundle
        , "POST " ++ daemonBootstrapBrokerBaseUrl ++ brokerRoutePath BrokerVaultRotateTransitKey
        , "GET " ++ daemonBootstrapBrokerBaseUrl ++ brokerRoutePath BrokerVaultPkiStatus
        , "POST "
            ++ daemonBootstrapBrokerBaseUrl
            ++ brokerRoutePath BrokerVaultPkiIssueTestCertificate
        , "ATTACH pod/bootstrap-secret-worker framed-stdin"
        ]
    , daemonBootstrapObservedOutput =
        [ "daemon-bootstrap result=ok"
        , "unlock_bundle_source=minio-service"
        , "request_password=redacted"
        , "response_root_token=redacted"
        ]
    , daemonBootstrapRequiredDaemonPaths = map brokerRoutePath daemonBootstrapRequiredRoutes
    }

daemonBootstrapForbiddenPatterns :: [String]
daemonBootstrapForbiddenPatterns =
  [ "port-forward service/minio"
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
      , -- Sprint 5.33: the block declares where its trace came from, so an
        -- `observed-daemon` claim and a `fixture:` claim are distinguishable in
        -- the evidence rather than only in the source.
        "AUDIT_PROVENANCE=" ++ renderDaemonBootstrapProvenance (daemonBootstrapProvenance input)
      , "DAEMON_AVAILABLE=" ++ (if daemonBootstrapDaemonAvailable input then "true" else "false")
      , "DAEMON_PATHS=" ++ intercalate "," (daemonBootstrapRequiredDaemonPaths input)
      , "LEGACY_TRANSPORTS=" ++ show (length forbiddenLegacy)
      , "HOST_ROOT_TOKEN_FALLBACKS=" ++ show (length hostRootTokenFallbacks)
      , "REDACTION=" ++ (if null leakedSecrets then "ok" else "leaked")
      ]
 where
  hostRootTokenFallbacks =
    filter
      (`isInfixOf` unlines (daemonBootstrapObservedTransports input ++ daemonBootstrapObservedOutput input))
      daemonBootstrapHostRootTokenPatterns

-- | The subset of 'daemonBootstrapForbiddenPatterns' the audit reports
-- separately as host-root-token fallbacks. Derived from that list rather than
-- restated, so a pattern cannot be counted in one line and missed by the other.
daemonBootstrapHostRootTokenPatterns :: [String]
daemonBootstrapHostRootTokenPatterns =
  filter
    (\forbidden -> any (`isInfixOf` forbidden) ["root-token", "host Vault", "HOST_VAULT_TOKEN"])
    daemonBootstrapForbiddenPatterns

defaultSealedVaultAuditInput :: SealedVaultAuditInput
defaultSealedVaultAuditInput =
  SealedVaultAuditInput
    { sealedVaultBucketNames = [defaultObjectStoreBucket]
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
  case filter (/= defaultObjectStoreBucket) buckets of
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
  :: Substrate -> FilePath -> IO (Either String GatewayRuntimeStabilityRecorder)
newGatewayRuntimeStabilityRecorder substrate repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> pure (Left ("load settings for gateway runtime stability: " ++ err))
    Right settings ->
      case gatewayRuntimeStabilityPolicy substrate settings of
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
      Right <$> runWithWorker (gatewayRuntimeAwsMonitorLoop repoRoot)
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
  -> GatewayRuntimeStabilityMonitor
  -> MVar ()
  -> IO ()
gatewayRuntimeAwsMonitorLoop repoRoot monitor firstObservationComplete =
  go Nothing 0
 where
  recorder = gatewayRuntimeMonitorRecorder monitor

  go maybeRefreshAcknowledgement refusedAttempts = do
    scoped <-
      AwsEks.withEksKubeconfigResult repoRoot $ \kubeconfigPath -> do
        baseEnvironment <- getEnvironment
        let monitorEnvironment =
              ("KUBECONFIG", kubeconfigPath)
                : filter ((/= "KUBECONFIG") . fst) baseEnvironment
        mapM_ (`putMVar` ()) maybeRefreshAcknowledgement
        gatewayRuntimeMonitorLoop
          (GatewayRuntimeKubectlContext repoRoot (Just monitorEnvironment))
          monitor
          firstObservationComplete
    case scoped of
      Right nextRefreshAcknowledgement -> go nextRefreshAcknowledgement 0
      Left refusal -> do
        -- The worker used to raise an untyped error here, which `link` carried
        -- into the suite and aborted it mid-flight. Record the refusal in the
        -- fold, whose absorbing outcome fails the final gate with this reason,
        -- release whoever waits on the first observation, a refresh the worker
        -- already took, and a refresh requested while no bracket can be opened
        -- (the request is read only inside a bracket, so without this it would
        -- wait for one that may never open), and keep the worker alive so those
        -- handshakes still complete.
        --
        -- The refusal is recorded only while the monitor is enabled and under the
        -- observation lock, the way a sample is: a planned pause means "do not
        -- judge the gateway now", and the absorbing outcome cannot be cleared by a
        -- later healthy sample. A refusal that outlasts the pause is recorded by
        -- the next attempt. Each attempt opens a bracket, which mints credentials,
        -- so the retry backs off rather than repeating at the sample rate for the
        -- length of the suite.
        recordRefusalWhileObserving refusal
        mapM_ (`putMVar` ()) maybeRefreshAcknowledgement
        pendingRefresh <-
          modifyMVar
            (gatewayRuntimeMonitorRefreshRequest monitor)
            (\request -> pure (Nothing, request))
        mapM_ (`putMVar` ()) pendingRefresh
        void (tryPutMVar firstObservationComplete ())
        interruptibleRetryDelay (gatewayRuntimeKubeconfigRetryDelayMicroseconds refusedAttempts)
        go Nothing (refusedAttempts + 1)

  -- The backoff sleeps in sample-interval slices and ends early when a refresh is
  -- requested, so a refresh does not wait out a thirty-second delay for its turn.
  interruptibleRetryDelay remaining
    | remaining <= 0 = pure ()
    | otherwise = do
        pending <- readMVar (gatewayRuntimeMonitorRefreshRequest monitor)
        case pending of
          Just _ -> pure ()
          Nothing -> do
            threadDelay (min remaining gatewayRuntimeSampleDelayMicroseconds)
            interruptibleRetryDelay (remaining - gatewayRuntimeSampleDelayMicroseconds)

  recordRefusalWhileObserving refusal =
    withMVar (gatewayRuntimeObservationLock recorder) $ \() -> do
      enabled <- readMVar (gatewayRuntimeMonitorEnabled monitor)
      when enabled $
        void
          ( recordGatewayRuntimeFailure
              recorder
              GatewayPodsPayload
              (AwsEks.renderEksKubeconfigError refusal)
          )

-- | The delay before the AWS monitor next tries to open a kubeconfig bracket
-- after it was refused one: the sample interval, doubling per consecutive
-- refusal, capped. A persistent refusal (the stack gone, the Authority sealed)
-- costs a credential mint per attempt, and the first refusal already carries
-- everything a thousand more would.
gatewayRuntimeKubeconfigRetryDelayMicroseconds :: Int -> Int
gatewayRuntimeKubeconfigRetryDelayMicroseconds refusedAttempts =
  min
    gatewayRuntimeKubeconfigRetryCeilingMicroseconds
    (gatewayRuntimeSampleDelayMicroseconds * 2 ^ min 5 (max 0 refusedAttempts))

gatewayRuntimeKubeconfigRetryCeilingMicroseconds :: Int
gatewayRuntimeKubeconfigRetryCeilingMicroseconds = 30000000

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
  :: Substrate
  -> ValidatedSettings
  -> Either String GatewayStabilityPolicy
gatewayRuntimeStabilityPolicy substrate settings = do
  let capacitySection =
        Prodbox.Settings.capacity
          (Prodbox.Settings.validatedConfig settings)
  runtimePlan <- Capacity.runtimeMemoryPlanForProfile capacitySection "gateway"
  Bifunctor.first
    (("gateway runtime stability policy: " ++) . show)
    ( mkGatewayStabilityPolicy
        (gatewayRuntimeExpectedReplicas substrate)
        gatewayRuntimeRequiredStableSamples
        runtimePlan
    )

-- | The gateway pods a substrate runs, which is what the stable-observation
-- fold must see in full before it counts a sample. It is the number of
-- StatefulSets the gateway chart renders, not the capacity plan's gateway
-- replica count: the plan models the two home emitters, and EKS renders
-- three, so a fold that waited for the plan's count could never complete
-- there.
gatewayRuntimeExpectedReplicas :: Substrate -> Natural
gatewayRuntimeExpectedReplicas = fromIntegral . length . gatewayNodeIdsForSubstrate

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

-- | Sprint 5.21 live recorder. The gateway-pods validation has already
-- established the workload; this observer then keeps the absorbing runtime
-- health fold active for the whole steady window while collecting cumulative
-- cgroup counters plus daemon-owned heap/object-store telemetry.
recordGatewayMeasuredProfile :: Substrate -> FilePath -> IO ExitCode
recordGatewayMeasuredProfile substrate repoRoot = do
  recorderResult <- newGatewayRuntimeStabilityRecorder substrate repoRoot
  case recorderResult of
    Left err -> failWith err
    Right recorder -> do
      scoped <-
        withSubstrateKubeconfigResult repoRoot substrate $
          withGatewayRuntimeStabilityMonitor substrate repoRoot recorder $ \_monitor -> do
            podResult <- gatewayCalibrationPod repoRoot
            case podResult of
              Left err -> failWith err
              Right podName -> do
                writeOutputLine
                  ( "Recording gateway measured profile from Pod `"
                      ++ podName
                      ++ "` for at least "
                      ++ show MeasuredProfile.recorderMinimumWindowSeconds
                      ++ " seconds."
                  )
                samplesResult <- collectGatewayCalibrationSamples repoRoot podName
                case samplesResult of
                  Left err -> failWith err
                  Right samples -> do
                    healthExit <-
                      runGatewayRuntimeStabilityGateInCurrentContext
                        (GatewayRuntimeKubectlContext repoRoot Nothing)
                        recorder
                    case healthExit of
                      ExitFailure code -> pure (ExitFailure code)
                      ExitSuccess -> commitGatewayMeasuredProfile repoRoot samples
      case scoped of
        Left err -> failWith err
        Right (Left err) -> failWith err
        Right (Right exitCode) -> pure exitCode

gatewayCalibrationPod :: FilePath -> IO (Either String String)
gatewayCalibrationPod repoRoot = do
  output <-
    captureCalibrationKubectl
      repoRoot
      [ "get"
      , "pods"
      , "--namespace"
      , gatewayValidationNamespace
      , "--selector"
      , "app.kubernetes.io/name=prodbox-gateway"
      , "--field-selector"
      , "status.phase=Running"
      , "--output"
      , "jsonpath={.items[0].metadata.name}"
      ]
  pure $ do
    textOutput <- output
    let podName = Text.unpack (Text.strip (Text.pack textOutput))
    if null podName
      then Left "measured-profile recorder found no Running gateway Pod"
      else Right podName

gatewayCalibrationSampleCount :: Int
gatewayCalibrationSampleCount = fromIntegral MeasuredProfile.recorderMinimumSampleCount

gatewayCalibrationDelayMicroseconds :: Int
gatewayCalibrationDelayMicroseconds = 6100000

collectGatewayCalibrationSamples
  :: FilePath -> String -> IO (Either String [MeasuredProfile.MeasuredProfileSample])
collectGatewayCalibrationSamples repoRoot podName = go gatewayCalibrationSampleCount []
 where
  go remaining collected
    | remaining <= 0 = pure (Right (reverse collected))
    | otherwise = do
        sample <- collectGatewayCalibrationSample repoRoot podName
        case sample of
          Left err -> pure (Left err)
          Right observed
            | remaining == 1 -> pure (Right (reverse (observed : collected)))
            | otherwise -> do
                threadDelay gatewayCalibrationDelayMicroseconds
                go (remaining - 1) (observed : collected)

collectGatewayCalibrationSample
  :: FilePath -> String -> IO (Either String MeasuredProfile.MeasuredProfileSample)
collectGatewayCalibrationSample repoRoot podName = do
  observedAt <- fromIntegral <$> getMonotonicTimeNSec
  output <- captureCalibrationKubectl repoRoot (calibrationExecArguments podName)
  pure $ do
    raw <- output
    values <- traverse readNatural (words raw)
    case values of
      [usageMicros, periods, throttled, rssBytes, heapBytes, objectMillis]
        | heapBytes == 0 ->
            Left "gateway /metrics reported zero heap bytes; the daemon must run with RTS stats enabled"
        | otherwise ->
            Right
              MeasuredProfile.MeasuredProfileSample
                { MeasuredProfile.sampleObservedAtNanoseconds = observedAt
                , MeasuredProfile.sampleCpuUsageNanoseconds = usageMicros * 1000
                , MeasuredProfile.sampleCfsPeriods = periods
                , MeasuredProfile.sampleCfsThrottledPeriods = throttled
                , MeasuredProfile.sampleRssBytes = rssBytes
                , MeasuredProfile.sampleHeapBytes = heapBytes
                , MeasuredProfile.sampleObjectStoreOpMillis = objectMillis
                }
      _ -> Left "gateway calibration sample did not contain exactly six Natural values"
 where
  readNatural token =
    case reads token of
      [(value, "")] -> Right value
      _ -> Left ("gateway calibration sample contains a non-Natural value: " ++ token)

calibrationExecArguments :: String -> [String]
calibrationExecArguments podName =
  [ "exec"
  , "--namespace"
  , gatewayValidationNamespace
  , podName
  , "--container"
  , "gateway"
  , "--"
  , "sh"
  , "-ceu"
  , unlines
      [ "usage=$(awk '$1 == \"usage_usec\" { printf \"%s\\n\", $2 }' /sys/fs/cgroup/cpu.stat)"
      , "periods=$(awk '$1 == \"nr_periods\" { printf \"%s\\n\", $2 }' /sys/fs/cgroup/cpu.stat)"
      , "throttled=$(awk '$1 == \"nr_throttled\" { printf \"%s\\n\", $2 }' /sys/fs/cgroup/cpu.stat)"
      , "rss=$(cat /sys/fs/cgroup/memory.current)"
      , "metrics=$(curl --fail --silent --show-error http://127.0.0.1:8443/metrics)"
      , "heap=$(printf '%s\n' \"$metrics\" | awk '$1 == \"prodbox_gateway_heap_live_bytes\" { printf \"%s\\n\", $2; exit }')"
      , "object=$(printf '%s\n' \"$metrics\" | awk '$1 == \"prodbox_gateway_object_store_op_p99_millis\" { printf \"%s\\n\", $2; exit }')"
      , "test -n \"$usage\" -a -n \"$periods\" -a -n \"$throttled\" -a -n \"$rss\" -a -n \"$heap\" -a -n \"$object\""
      , "printf '%s %s %s %s %s %s\n' \"$usage\" \"$periods\" \"$throttled\" \"$rss\" \"$heap\" \"$object\""
      ]
  ]

captureCalibrationKubectl :: FilePath -> [String] -> IO (Either String String)
captureCalibrationKubectl repoRoot arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "timeout"
        , subprocessArguments = ["--kill-after=2s", "12s", "kubectl"] ++ arguments
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case result of
    Failure err -> Left err
    Success output -> case processExitCode output of
      ExitSuccess -> Right (processStdout output)
      ExitFailure code ->
        Left
          ( "kubectl calibration observation failed (exit "
              ++ show code
              ++ "): "
              ++ outputDetail output
          )

commitGatewayMeasuredProfile
  :: FilePath -> [MeasuredProfile.MeasuredProfileSample] -> IO ExitCode
commitGatewayMeasuredProfile repoRoot samples = do
  digest <- MeasuredProfile.computeHotPathDigest repoRoot "gateway"
  recordedAt <- fromIntegral . (floor :: POSIXTime -> Integer) <$> getPOSIXTime
  case MeasuredProfile.aggregateMeasuredProfileSamples "gateway" recordedAt digest True samples of
    Left refusal -> failWith (MeasuredProfile.renderMeasuredProfileRecorderRefusal refusal)
    Right profile -> do
      let directory = repoRoot </> MeasuredProfile.measuredProfilesDir
          destination = directory </> "gateway.dhall"
      createDirectoryIfMissing True directory
      (temporary, handle) <- openTempFile directory ".gateway.dhall.tmp"
      BS8.hPutStr
        handle
        (TextEncoding.encodeUtf8 (MeasuredProfile.renderMeasuredResourceProfileDhall profile))
      hClose handle
      renameFile temporary destination
      writeOutputLine ("Recorded measured gateway profile: " ++ destination)
      pure ExitSuccess

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

-- | The exit of one stability __sample__, as distinct from the stability
-- __gate__ ('runGatewayRuntimeStabilityGateInCurrentContext').
--
-- Sprint 2.44: the two folds disagreed about 'NotStableYet' and only one of them
-- was wrong to. The gate retries and then fails, which is right — it is asked
-- for a verdict. The sampler is interleaved between suite phases roughly ten
-- times per run to feed the recorder, and a run that aborted the first time the
-- runtime had not yet converged would never reach the gate at all. So the
-- sampler continues, and that is deliberate.
--
-- What was wrong is that it continued __silently__: 'StableObserved' and
-- 'NotStableYet' both returned 'ExitSuccess' with no output, so a sample that
-- observed non-stability was indistinguishable from one that observed
-- stability, in the exit code and in the transcript alike. The ADT's third value
-- was discarded rather than recorded. Each arm now says what it saw, so the four
-- constructors produce four distinguishable outcomes.
--
-- The bound, stated rather than implied: this still exits 0 on 'NotStableYet'.
-- The row that scheduled this read the defect as "returns success when stability
-- was not observed", which is an accurate description and the wrong remedy for a
-- sampler — the fix is that it no longer claims to have observed stability, not
-- that it fails.
-- | Sprint 2.44 (pure): what one sample decided, total over the report's four
-- constructors. Split out from the interpreter below so the distinction the old
-- fold collapsed is testable without capturing a stream.
data GatewayRuntimeSampleOutcome
  = SampleObservedStable !Natural
  | -- | Observed, and stability was __not__ present. Continues; see
    -- 'gatewayRuntimeSampleExit'.
    SampleObservedNotYetStable !Natural !Natural
  | SampleObservedUnhealthy
  | SampleUnobservable
  deriving (Eq, Show)

-- | Sprint 2.44 (pure). Exposed for unit tests.
gatewayRuntimeSampleOutcome :: GatewayRuntimeStabilityReport -> GatewayRuntimeSampleOutcome
gatewayRuntimeSampleOutcome report = case report of
  StableObserved samples -> SampleObservedStable samples
  NotStableYet samples required -> SampleObservedNotYetStable samples required
  RuntimeUnhealthy _ -> SampleObservedUnhealthy
  StabilityUnreachable _ -> SampleUnobservable

-- | Sprint 2.44 (pure). Whether a sample's outcome fails the step. Exposed so
-- the sampler/gate disagreement is asserted rather than described.
gatewayRuntimeSampleOutcomeExit :: GatewayRuntimeSampleOutcome -> ExitCode
gatewayRuntimeSampleOutcomeExit outcome = case outcome of
  SampleObservedStable _ -> ExitSuccess
  SampleObservedNotYetStable _ _ -> ExitSuccess
  SampleObservedUnhealthy -> ExitFailure 1
  SampleUnobservable -> ExitFailure 1

gatewayRuntimeSampleExit :: GatewayRuntimeStabilityReport -> IO ExitCode
gatewayRuntimeSampleExit report =
  case gatewayRuntimeSampleOutcome report of
    SampleObservedUnhealthy ->
      failWith ("Gateway runtime is unhealthy: " ++ renderGatewayRuntimeStabilityReport report)
    SampleUnobservable ->
      failWith
        ("Gateway runtime stability is unobservable: " ++ renderGatewayRuntimeStabilityReport report)
    SampleObservedStable samples -> do
      writeDiagnosticLine
        ( "Gateway runtime stability sample: stable ("
            ++ show samples
            ++ " samples). "
            ++ renderGatewayRuntimeStabilityReport report
        )
      pure ExitSuccess
    SampleObservedNotYetStable samples required -> do
      writeDiagnosticLine
        ( "Gateway runtime stability sample: NOT yet stable ("
            ++ show samples
            ++ " of "
            ++ show required
            ++ " required samples) — recorded, and the run continues because this "
            ++ "is a sampler and the stability gate owns the verdict. This is not "
            ++ "an observation of stability. "
            ++ renderGatewayRuntimeStabilityReport report
        )
      pure ExitSuccess

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
  result <-
    case nativeValidationKubeconfigMode validation of
      ValidationUsesSelectedSubstrateKubeconfig ->
        withSubstrateKubeconfigEnv repoRoot substrate runSubstrateValidation
      ValidationUsesHomeCluster -> do
        when (substrate /= SubstrateHomeLocal) $
          writeDiagnosticLine
            ( "[validation="
                ++ nativeValidationId validation
                ++ "] addresses the retained home cluster, whichever substrate is selected"
            )
        runSubstrateValidation
      ValidationOwnsKubeconfigScopes -> runSubstrateValidation
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
          ["PROVIDER_ROLE=", "IAM_PRINCIPAL=assumed-role", "CONFIG_PATH="]
      ValidationAwsEks ->
        runSequentially
          [ assertNativeCommandOutputContainsAll
              repoRoot
              environment
              ["aws", "stack", "eks", "reconcile"]
              [AwsEks.awsEksProviderReceiptLabel ++ "sha256:"]
          , verifyAwsEksSnapshot repoRoot
          ]
      ValidationPulumi ->
        runSequentially
          [ assertNativeCommandOutputContainsAll
              repoRoot
              environment
              ["aws", "stack", "test", "reconcile"]
              [AwsTest.awsTestProviderReceiptLabel ++ "sha256:"]
          , verifyAwsTestSnapshot repoRoot
          ]
      ValidationHaRke2Aws ->
        runHaRke2AwsValidation repoRoot environment
      ValidationGatewayDaemon -> runGatewayDaemonValidation repoRoot environment
      ValidationGatewayPods ->
        runGatewayPodsValidation
          repoRoot
          substrate
          environment
          maybeGatewayStability
      ValidationControlPlaneCounterexample -> runControlPlaneCounterexampleValidation repoRoot
      ValidationTeardownRecovery -> runTeardownRecoveryValidation repoRoot
      ValidationCreateInterrupted -> runCreateInterruptedValidation repoRoot
      ValidationCertificateScope -> runCertificateScopeServingValidation repoRoot substrate
      ValidationCleanRoomHandoff -> runCleanRoomHandoffValidation repoRoot
      ValidationCascadeQualification ->
        runCascadeQualificationValidation repoRoot environment substrate
      ValidationCascadeQualificationReceipt ->
        runCascadeQualificationReceiptValidation repoRoot environment
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
        runResourceGuardrailsValidation repoRoot substrate
      ValidationDaemonBootstrap ->
        runDaemonBootstrapValidation repoRoot
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

-- | Most AWS validations run wholly against the selected EKS target and may
-- therefore use one suite-scoped kubeconfig.  Cascade qualification crosses
-- both control planes: its evidence inventory is observed on retained local
-- RKE2, while its cloud nodes acquire operation-bound ephemeral EKS clients
-- through the Provider.  An outer EKS kubeconfig is both redundant and an
-- invalid prerequisite when recovery starts from a retired checkpoint.
--
-- The @aws-eks@ validation is the one that creates the EKS checkpoint a
-- suite-scoped kubeconfig is projected from, and it runs no kubectl against
-- the cluster: it reconciles through the Authority and reads the retained
-- outputs back.  Wrapping it would ask for the checkpoint it is about to
-- create.
--
-- Three validations address the retained home cluster whichever substrate is
-- selected: their body is a chain of @prodbox@ children and probes that have no
-- substrate argument and are spawned with the environment captured before the
-- run, so wrapping them in the EKS kubeconfig changed nothing they touched while
-- making the declaration lie. @charts-platform@ and @charts-storage@ list,
-- inspect and delete the home vscode release, and @gateway-daemon@ reads the home
-- orders, forwards to a home daemon and expects the home DNS write gate. Naming
-- the home as their target says what they prove on an AWS run; it does not
-- extend them to EKS.
data NativeValidationKubeconfigMode
  = ValidationUsesSelectedSubstrateKubeconfig
  | ValidationUsesHomeCluster
  | ValidationOwnsKubeconfigScopes
  deriving (Eq, Show)

nativeValidationKubeconfigMode
  :: NativeValidation -> NativeValidationKubeconfigMode
nativeValidationKubeconfigMode validation =
  case validation of
    ValidationCascadeQualification -> ValidationOwnsKubeconfigScopes
    ValidationAwsEks -> ValidationOwnsKubeconfigScopes
    ValidationChartsPlatform -> ValidationUsesHomeCluster
    ValidationChartsStorage -> ValidationUsesHomeCluster
    ValidationGatewayDaemon -> ValidationUsesHomeCluster
    -- Every other validation is listed, with no wildcard, so a validation added
    -- to the closed set cannot compile until someone decides which cluster it
    -- addresses; a default would take the selected substrate without anyone
    -- having asked.
    ValidationChartsVscode -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationChartsApi -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationChartsWebsocket -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationAdminRoutes -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationPublicDns -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationDnsAws -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationAwsIam -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationPulumi -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationHaRke2Aws -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationGatewayPods -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationControlPlaneCounterexample -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationTeardownRecovery -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationCreateInterrupted -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationCertificateScope -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationCleanRoomHandoff -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationCascadeQualificationReceipt -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationResourceGuardrails -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationDaemonBootstrap -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationPulsarBroker -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationEksVolumeRebind -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationLifecycle -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationKeycloakInvite -> ValidationUsesSelectedSubstrateKubeconfig
    ValidationSealedVault -> ValidationUsesSelectedSubstrateKubeconfig

-- | The environment a child process needs to address the substrate a validation
-- runs against.
--
-- The scope wrapper selects the EKS cluster by setting the process's
-- @KUBECONFIG@, which only reaches subprocesses spawned without an explicit
-- environment. A child spawned with the list captured before the run carries
-- no such entry and addressed the home cluster. For the AWS substrate this
-- overlays the process's current value; the home substrate keeps the captured
-- list, which is what selects the home cluster.
selectedSubstrateEnvironment :: Substrate -> [(String, String)] -> IO [(String, String)]
selectedSubstrateEnvironment substrate environment =
  case substrate of
    SubstrateHomeLocal -> pure environment
    SubstrateAws -> (`overlayKubeconfig` environment) <$> lookupEnv "KUBECONFIG"

overlayKubeconfig :: Maybe FilePath -> [(String, String)] -> [(String, String)]
overlayKubeconfig scoped environment =
  case scoped of
    Nothing -> environment
    Just path -> ("KUBECONFIG", path) : filter ((/= "KUBECONFIG") . fst) environment

-- | Wrap a validation action with substrate-aware `KUBECONFIG` plus AWS_*
-- credentials for the AWS substrate.
--
-- For `SubstrateHomeLocal` the operator's default kubeconfig is in scope
-- already (no-op). For `SubstrateAws` (Sprint 4.18 fifth chunk
-- re-migration) the EKS kubeconfig is materialized into a scoped temp
-- file via 'AwsEks.withEksKubeconfig'. The file carries endpoint/CA and a
-- FIFO token path; no AWS credential or bearer enters the environment or
-- generated configuration.
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
      -- A refused kubeconfig is a typed result the callers already handle, where
      -- it used to be an `error` that bypassed their `Left` arms.
      scoped <-
        AwsEks.withEksKubeconfigResult repoRoot $ \kubeconfigPath -> do
          previousValue <- lookupEnv "KUBECONFIG"
          bracket_
            (setEnv "KUBECONFIG" kubeconfigPath)
            (restoreOne (("KUBECONFIG", kubeconfigPath), previousValue))
            action
      pure (Bifunctor.first AwsEks.renderEksKubeconfigError scoped)
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
              sealState = sealStateFromVaultStatusOutput statusText
              startedUnsealed = sealState == Just False
              startedSealed = sealState == Just True
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

-- | Sprint 5.33: the unset arm observes or refuses.
--
-- It used to be **byte-identical** to the @"pass"@ fixture arm below — the same
-- expression, one line apart — so the path CI and a bare
-- @prodbox test integration daemon-bootstrap@ take emitted a canned audit with
-- @DAEMON_AVAILABLE=true@ as a literal in
-- 'defaultDaemonBootstrapAuditInput' and no observation anywhere in the
-- function. Sprint `5.14`'s @Validation@ section rests entirely on this node.
--
-- The unset arm now probes the Bootstrap Broker's own route surface and builds
-- the audit from what answered. When no daemon answers it is a typed refusal
-- naming what was absent, per
-- @documents/engineering/bootstrap_readiness_doctrine.md § 0.5@ — never a
-- canned pass. The fixture arms keep their fixture provenance, which the
-- emitted block now states.
runDaemonBootstrapValidation :: FilePath -> IO ExitCode
runDaemonBootstrapValidation repoRoot = do
  fixture <- lookupEnv "PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT"
  case fixture of
    Nothing -> runObservedDaemonBootstrapAudit repoRoot
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

-- | Sprint 5.33: observe the live Bootstrap Broker daemon, or refuse naming
-- what was absent.
--
-- The observation is deliberately read-only: every probe is a @GET@, including
-- against the mutating routes. A daemon that serves a route answers a @GET@ on
-- it with *something other than 404* (405 for a POST-only route, 401/403 for an
-- unauthenticated one); a route the daemon does not serve answers 404. That
-- distinction is enough to observe the required-route surface without issuing a
-- single mutation, which is the whole point — a validation may not initialise
-- Vault to prove it could.
runObservedDaemonBootstrapAudit :: FilePath -> IO ExitCode
runObservedDaemonBootstrapAudit repoRoot = do
  keyResult <- freshVaultIdempotencyKey
  case keyResult of
    Left err -> failWith ("daemon-bootstrap validation could not mint a probe key: " ++ err)
    Right key -> do
      -- The Broker listens on its pod's loopback behind a ClusterIP Service, so
      -- the only host path to it is the Service port-forward every Broker command
      -- uses. The probe used to curl a fixed host address that nothing binds,
      -- which made the unset-fixture arm refuse on every cluster.
      connected <-
        withBrokerHostConnection
          (brokerHostConnection repoRoot)
          key
          (\endpoint _context -> observeBrokerRouteSurface endpoint)
      case connected of
        Left err ->
          failWith
            ( "daemon-bootstrap validation measured nothing and refuses: no "
                ++ "PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT fixture was selected and no Bootstrap "
                ++ "Broker daemon answered through its Service port-forward ("
                ++ renderBrokerHostConnectionError err
                ++ "). Run it against a cluster whose broker is serving, or select a "
                ++ "repository fixture explicitly."
            )
        Right outcome -> pure outcome

-- | Observe the broker's route surface through an established endpoint.
observeBrokerRouteSurface :: BrokerEndpoint -> IO ExitCode
observeBrokerRouteSurface endpoint = do
  healthProbe <- probeBrokerRouteStatus endpoint BrokerHealth
  case healthProbe of
    Left err ->
      failWith
        ( "daemon-bootstrap validation could not observe "
            ++ brokerRouteUrl endpoint BrokerHealth
            ++ ": "
            ++ err
        )
    Right healthStatus -> do
      routeProbes <- traverse probeRequiredRoute daemonBootstrapRequiredRoutes
      let served = rights routeProbes
          unobservable = lefts routeProbes
      case unobservable of
        (firstError : _) ->
          failWith
            ( "daemon-bootstrap validation could not observe the broker's route surface: "
                ++ firstError
            )
        [] ->
          emitDaemonBootstrapAudit
            defaultDaemonBootstrapAuditInput
              { daemonBootstrapProvenance = DaemonBootstrapObservedDaemon
              , daemonBootstrapDaemonAvailable = True
              , daemonBootstrapObservedTransports = served
              , daemonBootstrapObservedOutput =
                  [ "daemon-bootstrap probe=route-surface"
                  , "broker_health_status=" ++ show healthStatus
                  ]
              }
 where
  probeRequiredRoute route = do
    probe <- probeBrokerRouteStatus endpoint route
    pure $ case probe of
      Left err -> Left (brokerRoutePath route ++ ": " ++ err)
      Right 404 ->
        Left
          ( "the daemon does not serve "
              ++ brokerRoutePath route
              ++ " (404); this broker cannot have carried a daemon-bootstrap run"
          )
      Right status -> Right (observedBrokerRouteLine status route)

-- | One observed broker route, as the audit corpus records it.
--
-- The forward's local port is not part of the line.  It is an ephemeral port
-- chosen at connection time, and the audit refuses any corpus containing the
-- legacy MinIO forward's literal port; a line that embedded the live port
-- would be refused on the run in which the kernel handed out that number.  The
-- route path is what the audit's required-route check reads.
observedBrokerRouteLine :: Int -> BrokerRoute -> String
observedBrokerRouteLine status route =
  "OBSERVED " ++ show status ++ " GET broker-service-forward" ++ brokerRoutePath route

-- | Read-only @GET@ probe of one broker route, reporting the HTTP status the
-- daemon answered with. A transport failure is a @Left@ and never a status,
-- so "nothing answered" cannot be read as "the route is absent".
probeBrokerRouteStatus :: BrokerEndpoint -> BrokerRoute -> IO (Either String Int)
probeBrokerRouteStatus endpoint route = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "curl"
        , subprocessArguments =
            [ "-sS"
            , "--max-time"
            , "5"
            , "-o"
            , "/dev/null"
            , "-w"
            , "%{http_code}"
            , brokerRouteUrl endpoint route
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case result of
    Failure err -> Left ("failed to start `curl`: " ++ err)
    Success output -> case processExitCode output of
      ExitFailure code ->
        Left
          ( "`curl` exited with code "
              ++ show code
              ++ ": "
              ++ unwords (words (processStderr output))
          )
      ExitSuccess -> case reads (filter (not . isSpace) (processStdout output)) of
        [(status, "")] -> Right status
        _ ->
          Left
            ( "`curl` reported an unreadable HTTP status: "
                ++ show (processStdout output)
            )

-- | The seal state a @prodbox vault status@ output reports, if it reports one.
--
-- The command prints the Bootstrap Broker's JSON status after a label
-- (@Vault status: {"sealed":false,...}@). The @sealed=True@ spelling this
-- validation once matched no longer occurs in that output (it survives only in
-- the one-line renderer the cluster status surfaces use), so a substring match
-- on it could never succeed and the validation refused before it sealed
-- anything.
sealStateFromVaultStatusOutput :: String -> Maybe Bool
sealStateFromVaultStatusOutput output =
  listToMaybe
    [ sealed
    | line <- lines output
    , let payload = dropWhile (/= '{') line
    , not (null payload)
    , Right (Object fields) <- [decodeJsonStringUtf8 payload]
    , Just (Bool sealed) <- [KeyMap.lookup (Key.fromString "sealed") fields]
    ]

-- | Assert that @prodbox vault status@ reports a sealed Vault.
assertVaultReportsSealed :: FilePath -> [(String, String)] -> IO ExitCode
assertVaultReportsSealed repoRoot environment = do
  statusResult <- captureNativeCliCommand repoRoot environment ["vault", "status"]
  case statusResult of
    Left err -> failWith err
    Right statusOutput ->
      let statusText = processStdout statusOutput ++ processStderr statusOutput
       in case sealStateFromVaultStatusOutput statusText of
            Just True -> pure ExitSuccess
            observed ->
              failWith
                ( "expected `prodbox vault status` to report a sealed Vault, observed "
                    ++ show observed
                    ++ ": "
                    ++ outputDetail statusOutput
                )

runSealedVaultAssertions :: FilePath -> [(String, String)] -> IO ExitCode
runSealedVaultAssertions repoRoot environment =
  runSequentially
    [ assertVaultReportsSealed repoRoot environment
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

-- | Where the MinIO volume the sealed-Vault audit scans lives on the host.
--
-- It is the root the retained storage is bound at, which is the configured
-- @storage.manual_pv_host_root@: the harness generates a config rooted at
-- @.test-data/legacy-aggregate@, so the audit that looked under the production
-- @.data@ either refused ("root missing") or, on a host that kept an unused
-- @.data@ tree, scanned a directory MinIO does not write to and passed without
-- examining anything. The topology runner's override, when set, wins; a host with
-- no readable config falls back to the production default.
sealedVaultHostDiskRoot :: FilePath -> IO FilePath
sealedVaultHostDiskRoot repoRoot = do
  maybeTestRoot <- lookupEnv testManualPvHostRootEnv
  manualPvRoot <-
    case maybeTestRoot of
      Just testRoot | not (null testRoot) -> pure testRoot
      _ -> resolveRetainedManualPvRoot repoRoot
  pure (manualPvRoot </> "prodbox" </> "minio" </> "0")

-- | The StatefulSets that run the gateway emitters, from the output of
-- @kubectl get statefulset -o name@.
--
-- The gateway namespace has held only StatefulSets since Sprint 3.26 (one per
-- emitter, beside the unrelated Pulsar broker), so the Deployment-availability
-- wait of @cluster wait@ matches nothing there and refuses with "no matching
-- resources". This selects the ones whose rollout the gateway validations are
-- about, and leaves the broker out so its health cannot fail a gateway check.
gatewayEmitterStatefulSets :: String -> [String]
gatewayEmitterStatefulSets listing =
  [ name
  | line <- lines listing
  , let name = trim line
  , "statefulset.apps/gateway-" `isPrefixOf` name
  ]

-- | Wait for every gateway emitter StatefulSet to finish rolling out.
waitForGatewayEmitters :: FilePath -> [(String, String)] -> IO ExitCode
waitForGatewayEmitters repoRoot environment = do
  listed <- runTextCommand (kubectlInGatewayNamespace ["get", "statefulset", "-o", "name"])
  case listed of
    Left err -> failWith err
    Right output ->
      case gatewayEmitterStatefulSets output of
        [] ->
          failWith
            ( "namespace `"
                ++ gatewayValidationNamespace
                ++ "` holds no gateway emitter StatefulSet, so there is nothing to wait for"
            )
        refs ->
          runSequentially
            [ runCommandForExitCode
                (kubectlInGatewayNamespace ["rollout", "status", ref, "--timeout=300s"])
            | ref <- refs
            ]
 where
  kubectlInGatewayNamespace arguments =
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments = ["--namespace", gatewayValidationNamespace] ++ arguments
      , subprocessEnvironment = Just environment
      , subprocessWorkingDirectory = Just repoRoot
      }

runGatewayPodsValidation
  :: FilePath
  -> Substrate
  -> [(String, String)]
  -> Maybe GatewayRuntimeStabilityRecorder
  -> IO ExitCode
runGatewayPodsValidation repoRoot substrate capturedEnvironment maybeRecorder = do
  environment <- selectedSubstrateEnvironment substrate capturedEnvironment
  readyExit <- waitForGatewayEmitters repoRoot environment
  case readyExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      recorderResult <-
        case maybeRecorder of
          Just recorder -> pure (Right recorder)
          Nothing -> newGatewayRuntimeStabilityRecorder substrate repoRoot
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

-- | The root namespaces whose guardrails the cluster must carry. The standalone
-- @keycloak@ namespace is capped only by the dormant guardrail the home
-- reconcile applies; the AWS platform has no such step, and Keycloak runs in
-- @vscode@ there, so requiring a @keycloak@ quota on EKS could never pass.
resourceGuardrailRootNamespaces :: Substrate -> [String]
resourceGuardrailRootNamespaces substrate =
  case substrate of
    SubstrateHomeLocal -> ["keycloak", "vscode", "api", "websocket", "gateway"]
    SubstrateAws -> ["vscode", "api", "websocket", "gateway"]

data ResourceGuardrailPodSummary = ResourceGuardrailPodSummary
  { resourceGuardrailPodsChecked :: Int
  , resourceGuardrailContainersChecked :: Int
  }
  deriving (Eq, Show)

runResourceGuardrailsValidation :: FilePath -> Substrate -> IO ExitCode
runResourceGuardrailsValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith ("load settings for resource guardrail validation: " ++ err)
    Right settings -> do
      let plan = Prodbox.Settings.validatedResourcePlan settings
      podsResult <- kubectlJson ["get", "pods", "-A", "-o", "json"]
      quotasResult <- kubectlJson ["get", "resourcequota", "-A", "-o", "json"]
      limitRangesResult <- kubectlJson ["get", "limitrange", "-A", "-o", "json"]
      case (podsResult, quotasResult, limitRangesResult) of
        (Left err, _, _) -> failWith err
        (_, Left err, _) -> failWith err
        (_, _, Left err) -> failWith err
        (Right pods, Right quotas, Right limitRanges) ->
          emitResourceGuardrailReport substrate plan pods quotas limitRanges
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
  :: Substrate -> Capacity.ResourcePlan -> Value -> Value -> Value -> IO ExitCode
emitResourceGuardrailReport substrate plan pods quotas limitRanges =
  case resourceGuardrailReport substrate plan pods quotas limitRanges of
    Left err -> failWith err
    Right report -> do
      writeOutput report
      pure ExitSuccess

resourceGuardrailReport
  :: Substrate -> Capacity.ResourcePlan -> Value -> Value -> Value -> Either String String
resourceGuardrailReport substrate plan podPayload quotaPayload limitRangePayload = do
  podSummary <- resourceGuardrailPodSummary substrate plan podPayload
  quotaNamespaces <- resourceGuardrailQuotaNamespaces substrate plan quotaPayload
  limitRangeNamespaces <- resourceGuardrailLimitRangeNamespaces substrate plan limitRangePayload
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
  :: Substrate -> Capacity.ResourcePlan -> Value -> Either String ResourceGuardrailPodSummary
resourceGuardrailPodSummary substrate _plan payload = do
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
  expectedNamespaces = resourceGuardrailRootNamespaces substrate

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

resourceGuardrailQuotaNamespaces
  :: Substrate -> Capacity.ResourcePlan -> Value -> Either String [String]
resourceGuardrailQuotaNamespaces substrate plan payload = do
  items <- jsonArrayAt ["items"] payload
  traverse
    (requireResourceQuotaForNamespace substrate plan items)
    (resourceGuardrailRootNamespaces substrate)

requireResourceQuotaForNamespace
  :: Substrate -> Capacity.ResourcePlan -> [Value] -> String -> Either String String
requireResourceQuotaForNamespace substrate plan items namespace = do
  expected <- namespaceResourceQuotaHardFields substrate plan namespace
  quotaObject <- requireK8sObjectInNamespace "ResourceQuota" namespace items
  mapM_ (requireQuantityEquals ("ResourceQuota " ++ namespace) ["spec", "hard"] quotaObject) expected
  Right namespace

-- | Sprint 5.31: the @spec.hard@ a namespace's ResourceQuota must carry,
-- projected from the capacity plan.
--
-- Exported so the integration fixture's /observed/ cluster state is rendered
-- from the same projection this validator compares against, rather than being a
-- second hand-maintained copy of the numbers. A fake that restates a production
-- value is an encoder of it
-- ([chaos_hardening_doctrine.md § 23](../../documents/engineering/chaos_hardening_doctrine.md)),
-- and this one had already drifted: the fixture declared the gateway at
-- 250m × 3 replicas where the plan declares 750m × 2.
namespaceResourceQuotaHardFields
  :: Substrate -> Capacity.ResourcePlan -> String -> Either String [(String, String)]
namespaceResourceQuotaHardFields substrate plan namespace = do
  admission <- Placement.planNamespaceAdmission substrate (Text.pack namespace) plan
  let requested = Capacity.request admission
      limited = Capacity.limit admission
  Right
    [ ("requests.cpu", cpuQuantity (Capacity.milli_cpu requested))
    , ("limits.cpu", cpuQuantity (Capacity.milli_cpu limited))
    , ("requests.memory", memoryQuantity (Capacity.memory_mib requested))
    , ("limits.memory", memoryQuantity (Capacity.memory_mib limited))
    , ("requests.ephemeral-storage", memoryQuantity (Capacity.ephemeral_storage_mib requested))
    , ("limits.ephemeral-storage", memoryQuantity (Capacity.ephemeral_storage_mib limited))
    , ("requests.storage", memoryQuantity (Capacity.durable_storage_mib requested))
    ]

resourceGuardrailLimitRangeNamespaces
  :: Substrate -> Capacity.ResourcePlan -> Value -> Either String [String]
resourceGuardrailLimitRangeNamespaces substrate plan payload = do
  items <- jsonArrayAt ["items"] payload
  traverse
    (requireLimitRangeForNamespace substrate plan items)
    (resourceGuardrailRootNamespaces substrate)

requireLimitRangeForNamespace
  :: Substrate -> Capacity.ResourcePlan -> [Value] -> String -> Either String String
requireLimitRangeForNamespace substrate plan items namespace = do
  limitRangeObject <- requireK8sObjectInNamespace "LimitRange" namespace items
  limits <- jsonArrayAt ["spec", "limits"] limitRangeObject
  containerLimit <- requireContainerLimitRange namespace limits
  expected <- namespaceLimitRangeContainerFields substrate plan namespace
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

-- | Sprint 5.31: the Container @LimitRange@ fields a namespace must carry,
-- projected from the capacity plan. Exported for the same reason as
-- 'namespaceResourceQuotaHardFields': the fixture's observed cluster state is
-- rendered from this projection rather than restating its numbers.
namespaceLimitRangeContainerFields
  :: Substrate -> Capacity.ResourcePlan -> String -> Either String [([String], String, String)]
namespaceLimitRangeContainerFields substrate plan namespace = do
  envelope <- Placement.planNamespaceLimits substrate (Text.pack namespace) plan
  let requestVector = Capacity.request envelope
      limitVector = Capacity.limit envelope
  Right
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

-- | Whether two printed Kubernetes quantities are the same amount.
--
-- CPU is compared in milli-cores (@m@ and bare integers), memory and storage in
-- bytes (binary-SI @Ki@ to @Ti@ and bare integers), so zero is zero in any of
-- those units and @60Gi@ is @61440Mi@. It is closed over the forms the API server
-- prints for the values this suite compares and refuses everything else: a form
-- it cannot read (@Pi@, @k@, decimal-SI such as @1G@, a fraction, an exponent) is
-- never judged equivalent to a different spelling, so an unrecognised spelling is
-- reported as a mismatch naming both strings and is never equated silently (the
-- caller accepts two identical spellings before it asks).
quantitiesEquivalent :: String -> String -> Bool
quantitiesEquivalent expected actual =
  case (parseCpuMilliQuantity expected, parseCpuMilliQuantity actual) of
    (Just expectedMilli, Just actualMilli) | expectedMilli == actualMilli -> True
    _ ->
      case (parseByteQuantity expected, parseByteQuantity actual) of
        (Just expectedBytes, Just actualBytes) -> expectedBytes == actualBytes
        _ -> False

parseCpuMilliQuantity :: String -> Maybe Integer
parseCpuMilliQuantity raw =
  case stripQuantitySuffix "m" raw of
    Just milliText -> parseIntegerQuantity milliText
    Nothing -> (* 1000) <$> parseIntegerQuantity raw

-- | A binary-SI or bare-integer quantity in bytes, the way Kubernetes prints one:
-- @20Gi@, @61440Mi@, and — for a quantity of zero in any unit — the bare @0@. A
-- ResourceQuota the chart applies as @0Mi@ is read back as @0@, so a comparison
-- that knew only the suffixed forms refused every namespace with no durable
-- storage.
parseByteQuantity :: String -> Maybe Integer
parseByteQuantity raw =
  asum
    [ parseWithUnit "Ki" 1024
    , parseWithUnit "Mi" 1048576
    , parseWithUnit "Gi" 1073741824
    , parseWithUnit "Ti" 1099511627776
    , parseIntegerQuantity raw
    ]
 where
  parseWithUnit suffix scale = do
    quantityText <- stripQuantitySuffix suffix raw
    (* scale) <$> parseIntegerQuantity quantityText

stripQuantitySuffix :: String -> String -> Maybe String
stripQuantitySuffix suffix raw
  | suffix `isSuffixOf` raw = Just (take (length raw - length suffix) raw)
  | otherwise = Nothing

parseIntegerQuantity :: String -> Maybe Integer
parseIntegerQuantity raw =
  case reads raw of
    [(value, "")] | value >= 0 -> Just value
    _ -> Nothing

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

cpuQuantity :: Natural -> String
cpuQuantity = CapacityRender.cpuQuantity

memoryQuantity :: Natural -> String
memoryQuantity = CapacityRender.memoryQuantity

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
        [AwsTest.awsTestProviderReceiptLabel ++ "sha256:"]
    , verifyAwsTestSnapshot repoRoot
    ]
gatewayPartitionValidationReport :: IO (Either String String)
gatewayPartitionValidationReport =
  case gatewayPartitionLegacyReport of
    Left err -> pure (Left err)
    Right legacyReport -> do
      composed <- gatewayPartitionEmitterReport
      pure ((legacyReport ++) <$> composed)

-- | Sprint 5.33: the canonical member set the shipped @gateway-partition@
-- report composes over. Exposed as a named value so a unit case can vary the
-- composition and observe the rendered output change — which is the property
-- that was untestable while every emitted line was a literal.
gatewayPartitionCanonicalMembers :: [(String, Word64)]
gatewayPartitionCanonicalMembers = [("node-a", 0), ("node-b", 1), ("node-c", 2)]

gatewayPartitionLegacyReport :: Either String String
gatewayPartitionLegacyReport =
  gatewayPartitionLegacyReportFor gatewayPartitionCanonicalMembers

-- | Sprint 5.33: the pure partition composition, parameterized on its member
-- set and rendering every emitted value from what it computed.
--
-- The report block used to be eight string literals — @INITIAL_OWNER_ACTIVE=true@,
-- @PARTITION_TAKEOVER_ACCEPTED=1@, @SINGLE_WRITER_AFTER_TAKEOVER=true@ and the
-- rest — emitted after the invariants were asserted. The underlying property
-- test is sound and the invariant assertions are real; what was unsound is that
-- the *evidence* said the same thing for every input, and eight `Done` Phase-`2`
-- sprints cite this node's numbered output for commit-before-peer-response,
-- restart, and partition-takeover properties that no peer, restart, or
-- partition was present to exercise. Those citations carry Standard-C
-- corrections; the code deliverables they cover are not withdrawn.
gatewayPartitionLegacyReportFor :: [(String, Word64)] -> Either String String
gatewayPartitionLegacyReportFor members = do
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
                [rawMember nodeName rank | (nodeName, rank) <- members]
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
      -- Sprint 5.33: counted from the frames the composition actually
      -- produced, not written as `1` and `0`. An ownership claim that the
      -- state machine admitted carries an assertion in its delta frame; one it
      -- refused does not.
      appliedTakeoverFrames = [claimBFrame]
      acceptedTakeovers =
        length [frame | frame <- appliedTakeoverFrames, GatewayState.deltaFrameAssertionCount frame > 0]
      rejectedTakeovers = length appliedTakeoverFrames - acceptedTakeovers
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
      , "PARTITION_MEMBERS=" ++ show (length (GatewayState.validatedOrdersMemberIds orders))
      , "INITIAL_OWNER_ACTIVE=" ++ renderPartitionFlag initialOwnerActive
      , "PARTITION_TAKEOVER_ACCEPTED=" ++ show acceptedTakeovers
      , "PARTITION_TAKEOVER_REJECTED=" ++ show rejectedTakeovers
      , "SINGLE_WRITER_AFTER_TAKEOVER=" ++ renderPartitionFlag singleWriterAfterTakeover
      , "REJOIN_YIELD_RECORDED=" ++ renderPartitionFlag yieldPersisted
      , "BOUNDED_DELTA_IDEMPOTENT=" ++ renderPartitionFlag idempotentMerge
      ]
 where
  renderPartitionFlag flag = if flag then "true" else "false"
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
          (EmitterKernel.projectionMaximumRetainedAssertions (partitionProjectionBounds model))
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
            (EmitterKernel.projectionMaximumRetainedAssertions (partitionProjectionBounds model))
            (partitionMailbox model)
            partitionDeadline
            beforeAckProjection
        )
    let retained = EmitterKernel.unackedSuffixList (EmitterKernel.emitterUnacked beforeAckState)
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
            (EmitterKernel.projectionMaximumRetainedAssertions (partitionProjectionBounds model))
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
          (EmitterKernel.unackedSuffixList (EmitterKernel.emitterUnacked afterAckState))
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
          (EmitterKernel.projectionMaximumRetainedAssertions projectionBounds)
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

-- | Sprint 1.87: resolve the substrate's served host at an IO boundary that has
-- an error channel, or refuse with the canonical wording from
-- 'Prodbox.PublicEdge.substrateServedHostMissing'.
--
-- Every public-edge URL renderer now consumes the resolved
-- 'ValidatedServedHost' rather than reaching for @ValidatedSettings@ and a
-- 'Substrate', so a substrate that declares no served host refuses here instead
-- of rendering @https:\/\/\/path@ into a curl argument twenty lines later.
withSubstrateServedHost
  :: ValidatedSettings
  -> Substrate
  -> (ValidatedServedHost -> IO ExitCode)
  -> IO ExitCode
withSubstrateServedHost settings substrate act =
  either failWith act (requireSubstrateServedHost settings substrate)

runChartsVscodeValidation :: FilePath -> Substrate -> IO ExitCode
runChartsVscodeValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> withSubstrateServedHost settings substrate $ \servedHost -> do
      let vscodeUrl = substratePublicRouteUrl servedHost PublicRouteVscode
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
                (oidcRedirectFragments servedHost (vscodeUrl ++ "/oauth2/callback"))
                chartsVscodeCurlAttempts
                chartsVscodeCurlDelayMicroseconds
            ]

runChartsApiValidation :: FilePath -> Substrate -> IO ExitCode
runChartsApiValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> withSubstrateServedHost settings substrate $ \servedHost -> do
      let apiUrl = substratePublicRouteUrl servedHost PublicRouteApi
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
    Right settings -> withSubstrateServedHost settings substrate $ \servedHost -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess ->
          -- The single-binary registry:2 has no web UI, so the former /harbor
          -- OIDC admin route is gone; the MinIO console is the only admin route.
          assertOidcProtectedRoute
            repoRoot
            servedHost
            (substratePublicRouteUrl servedHost PublicRouteMinio)
            (substratePublicRouteUrl servedHost PublicRouteMinio ++ "/oauth2/callback")
            "MinIO admin route did not preserve the shared-host auth contract"

runKeycloakPublicHostValidation :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
runKeycloakPublicHostValidation repoRoot settings substrate =
  withSubstrateServedHost settings substrate $ \servedHost -> do
    let websocketStartUrl = substratePublicRouteUrl servedHost PublicRouteWebsocket ++ "/oidc/start"
        websocketCallbackUrl = substratePublicRouteUrl servedHost PublicRouteWebsocket ++ "/oidc/callback"
        issuerUrl = substrateIdentityIssuerUrl servedHost
        authUrl = substratePublicRouteUrl servedHost PublicRouteAuth
    redirectExit <-
      assertOidcProtectedRoute
        repoRoot
        servedHost
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
reconcileKeycloakRealmSecrets repoRoot settings substrate =
  -- Sprint 1.84: a substrate with no declared served host is a refusal, not a
  -- reconcile against the empty hostname.
  case requireSubstratePublicFqdn settings substrate of
    Left err -> failWith err
    Right publicHost -> do
      reconcileResult <-
        Prodbox.UsersAdmin.reconcileRealmOidcSecretsAtPublicHost
          repoRoot
          (Text.pack publicHost)
      case reconcileResult of
        Left err -> failWith err
        Right () -> pure ExitSuccess

runDirectOidcSessionValidation :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
runDirectOidcSessionValidation repoRoot settings substrate =
  withSubstrateServedHost settings substrate $ \servedHost -> do
    sessionResult <- completeDirectOidcLogin repoRoot servedHost
    case sessionResult of
      Left err -> failWith err
      Right sessionPayload ->
        case directOidcSessionSummary sessionPayload of
          Left err -> failWith err
          Right (carrierValue, issuerValue, maybeUsername) ->
            if carrierValue == "cookie-session"
              && issuerValue == substrateIdentityIssuerUrl servedHost
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
runWebsocketUpgradeValidation repoRoot environment settings substrate apiToken websocketToken =
  -- Sprint 1.84: a substrate with no declared served host is a refusal, not a
  -- WebSocket dial against the empty hostname.
  case requireSubstratePublicFqdn settings substrate of
    Left err -> failWith err
    Right websocketHost ->
      runWebsocketUpgradeValidationAt
        repoRoot
        environment
        apiToken
        websocketToken
        websocketHost

runWebsocketUpgradeValidationAt
  :: FilePath
  -> [(String, String)]
  -> String
  -> String
  -> String
  -> IO ExitCode
runWebsocketUpgradeValidationAt repoRoot environment apiToken websocketToken websocketHost = do
  nonce <- validationNonce
  let sessionId = "ws-" ++ nonce
      messageBody = "message-" ++ nonce
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

completeDirectOidcLogin :: FilePath -> ValidatedServedHost -> IO (Either String Value)
completeDirectOidcLogin repoRoot servedHost =
  runDemoOidcSessionValidationAgent
    repoRoot
    (substratePublicRouteUrl servedHost PublicRouteWebsocket)

-- | Run the browser-style password login inside a one-shot, exact Vault
-- consumer. The host submits only a secret-free Job and receives the final
-- non-secret session projection; the demo password exists solely on the Pod's
-- memory-backed volume and is read by curl from a file rather than argv.
runDemoOidcSessionValidationAgent :: FilePath -> String -> IO (Either String Value)
runDemoOidcSessionValidationAgent repoRoot publicWebsocketBaseUrl = do
  preclean <- deleteDemoOidcSessionValidationAgent repoRoot
  case preclean of
    Left err -> pure (Left err)
    Right () -> do
      operationResult <- do
        applied <-
          runDemoOidcAgentWithInput
            repoRoot
            (BL.toStrict (encode (demoOidcSessionValidationAgentManifest publicWebsocketBaseUrl)))
            ["apply", "-f", "-"]
        case applied of
          Left err -> pure (Left err)
          Right () -> do
            completed <-
              runDemoOidcAgentCommand
                repoRoot
                [ "wait"
                , "--namespace"
                , demoOidcSessionValidationNamespace
                , "--for=condition=complete"
                , "job/" ++ demoOidcSessionValidationJobName
                , "--timeout=180s"
                ]
            case completed of
              Left err -> pure (Left err)
              Right () -> readDemoOidcSessionValidationAgentResult repoRoot
      cleanupResult <- deleteDemoOidcSessionValidationAgent repoRoot
      pure $ case (operationResult, cleanupResult) of
        (Right payload, Right ()) -> Right payload
        (Left err, Right ()) -> Left err
        (Right _, Left cleanupErr) -> Left cleanupErr
        (Left err, Left cleanupErr) -> Left (err ++ "; " ++ cleanupErr)

demoOidcSessionValidationNamespace :: String
demoOidcSessionValidationNamespace = "vscode"

demoOidcSessionValidationJobName :: String
demoOidcSessionValidationJobName = "oidc-session-validation-agent"

demoOidcSessionValidationAgentManifest :: String -> Value
demoOidcSessionValidationAgentManifest publicWebsocketBaseUrl =
  object
    [ "apiVersion" .= ("batch/v1" :: String)
    , "kind" .= ("Job" :: String)
    , "metadata"
        .= object
          [ "name" .= demoOidcSessionValidationJobName
          , "namespace" .= demoOidcSessionValidationNamespace
          ]
    , "spec"
        .= object
          [ "activeDeadlineSeconds" .= (180 :: Int)
          , "backoffLimit" .= (0 :: Int)
          , "template"
              .= object
                [ "metadata"
                    .= object
                      [ "labels"
                          .= object
                            [ "app.kubernetes.io/component"
                                .= ("oidc-session-validation-agent" :: String)
                            ]
                      ]
                , "spec"
                    .= object
                      [ "restartPolicy" .= ("Never" :: String)
                      , "automountServiceAccountToken" .= False
                      , "serviceAccountName"
                          .= ("oidc-session-validation-agent" :: String)
                      , "securityContext"
                          .= object
                            [ "fsGroup" .= (100 :: Int)
                            ]
                      , "initContainers"
                          .= [ object
                                 [ "name" .= ("vault-materializer" :: String)
                                 , "image" .= ("hashicorp/vault:1.18.3" :: String)
                                 , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                 , "env"
                                     .= [ object
                                            [ "name" .= ("VAULT_ADDR" :: String)
                                            , "value"
                                                .= ("http://vault.vault.svc.cluster.local:8200" :: String)
                                            ]
                                        ]
                                 , "command" .= (["/bin/sh", "-ec", demoOidcVaultMaterializerScript] :: [String])
                                 , "resources"
                                     .= object
                                       [ "requests"
                                           .= object
                                             [ "cpu" .= ("25m" :: String)
                                             , "memory" .= ("64Mi" :: String)
                                             , "ephemeral-storage" .= demoOidcAgentEphemeralStorageRequest
                                             ]
                                       , "limits"
                                           .= object
                                             [ "cpu" .= ("25m" :: String)
                                             , "memory" .= ("64Mi" :: String)
                                             , "ephemeral-storage" .= demoOidcAgentEphemeralStorageLimit
                                             ]
                                       ]
                                 , "volumeMounts"
                                     .= [ object
                                            [ "name" .= ("vault-materialized" :: String)
                                            , "mountPath" .= ("/vault-materialized" :: String)
                                            ]
                                        , object
                                            [ "name" .= ("service-account-token" :: String)
                                            , "mountPath"
                                                .= ("/var/run/secrets/kubernetes.io/serviceaccount" :: String)
                                            , "readOnly" .= True
                                            ]
                                        ]
                                 ]
                             ]
                      , "containers"
                          .= [ object
                                 [ "name" .= demoOidcSessionValidationJobName
                                 , "image"
                                     .= ContainerImage.renderImageRef ContainerImage.harborCurlImage
                                 , "imagePullPolicy" .= ("IfNotPresent" :: String)
                                 , "env"
                                     .= [ object
                                            [ "name" .= ("PUBLIC_WEBSOCKET_BASE_URL" :: String)
                                            , "value" .= publicWebsocketBaseUrl
                                            ]
                                        ]
                                 , "command" .= (["/bin/sh", "-ec", demoOidcSessionValidationScript] :: [String])
                                 , "resources"
                                     .= object
                                       [ "requests"
                                           .= object
                                             [ "cpu" .= ("10m" :: String)
                                             , "memory" .= ("32Mi" :: String)
                                             , "ephemeral-storage" .= demoOidcAgentEphemeralStorageRequest
                                             ]
                                       , "limits"
                                           .= object
                                             [ "cpu" .= ("10m" :: String)
                                             , "memory" .= ("32Mi" :: String)
                                             , "ephemeral-storage" .= demoOidcAgentEphemeralStorageLimit
                                             ]
                                       ]
                                 , "volumeMounts"
                                     .= [ object
                                            [ "name" .= ("vault-materialized" :: String)
                                            , "mountPath" .= ("/vault-materialized" :: String)
                                            , "readOnly" .= True
                                            ]
                                        , object
                                            [ "name" .= ("runtime" :: String)
                                            , "mountPath" .= ("/run/prodbox-oidc" :: String)
                                            ]
                                        ]
                                 ]
                             ]
                      , "volumes"
                          .= [ object
                                 [ "name" .= ("service-account-token" :: String)
                                 , "projected"
                                     .= object
                                       [ "sources"
                                           .= [ object
                                                  [ "serviceAccountToken"
                                                      .= object
                                                        [ -- No audience: the Vault role this Job logs in to
                                                          -- (a chart-secret consumer role) carries none, so Vault
                                                          -- reviews the token against the API server's own
                                                          -- audience, and a token minted for another audience
                                                          -- fails that review.
                                                          "expirationSeconds" .= (600 :: Int)
                                                        , "path" .= ("token" :: String)
                                                        ]
                                                  ]
                                              ]
                                       ]
                                 ]
                             , object
                                 [ "name" .= ("vault-materialized" :: String)
                                 , "emptyDir"
                                     .= object
                                       [ "medium" .= ("Memory" :: String)
                                       , "sizeLimit" .= ("64Ki" :: String)
                                       ]
                                 ]
                             , object
                                 [ "name" .= ("runtime" :: String)
                                 , "emptyDir"
                                     .= object
                                       [ "medium" .= ("Memory" :: String)
                                       , "sizeLimit" .= ("2Mi" :: String)
                                       ]
                                 ]
                             ]
                      ]
                ]
          ]
    ]

-- | The ephemeral storage the validation Job's containers declare. The Job writes
-- only into memory-backed volumes, so its writable layers and logs are a few
-- kilobytes; but a container that declares nothing is charged the namespace
-- LimitRange default (a 1Gi request and a 2Gi limit), and the @vscode@ quota has
-- about 1Gi of limit headroom beside the workloads it hosts, so the Job's Pod was
-- refused with @exceeded quota@ and the suite failed at "OIDC session validation
-- Agent command failed" without naming the quota.
demoOidcAgentEphemeralStorageRequest :: String
demoOidcAgentEphemeralStorageRequest = "32Mi"

demoOidcAgentEphemeralStorageLimit :: String
demoOidcAgentEphemeralStorageLimit = "64Mi"

demoOidcVaultMaterializerScript :: String
demoOidcVaultMaterializerScript =
  unlines
    [ "set -eu"
    , "jwt=\"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\""
    , "export VAULT_TOKEN=\"$(vault write -field=token auth/kubernetes/login role=oidc-session-validation jwt=\"${jwt}\")\""
    , "unset jwt"
    , "demo_password=\"$(vault kv get -field=password secret/vscode/oidc/demo-user)\""
    , "umask 077"
    , "printf '%s' \"${demo_password}\" > /vault-materialized/demo-password"
    , "unset demo_password VAULT_TOKEN"
    , "chmod 0444 /vault-materialized/demo-password"
    ]

demoOidcSessionValidationScript :: String
demoOidcSessionValidationScript =
  unlines
    [ "set -eu"
    , "umask 077"
    , "cookie_jar=/run/prodbox-oidc/cookies"
    , "login_body=/run/prodbox-oidc/login-body"
    , "login_response=/run/prodbox-oidc/login-response"
    , "curl -sS -L --fail-with-body -c \"${cookie_jar}\" -b \"${cookie_jar}\" -o \"${login_body}\" \"${PUBLIC_WEBSOCKET_BASE_URL}/oidc/start\""
    , "form_action=\"$(sed -n 's/.*action=\"\\([^\"]*\\)\".*/\\1/p' \"${login_body}\" | head -n 1 | sed 's/&amp;/\\&/g')\""
    , "test -n \"${form_action}\""
    , "curl -sS -L --fail-with-body -c \"${cookie_jar}\" -b \"${cookie_jar}\" --data-urlencode username=demo-user --data-urlencode password@/vault-materialized/demo-password -o \"${login_response}\" \"${form_action}\""
    , "curl -sS -L --fail-with-body -c \"${cookie_jar}\" -b \"${cookie_jar}\" \"${PUBLIC_WEBSOCKET_BASE_URL}/oidc/session\""
    ]

demoOidcAgentLimits :: BoundedSubprocessLimits
demoOidcAgentLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 128 * 1024
    , boundedSubprocessMaximumStdoutBytes = 256 * 1024
    , boundedSubprocessMaximumStderrBytes = 64 * 1024
    , boundedSubprocessTimeoutMicros = 240 * 1000 * 1000
    }

runDemoOidcAgentWithInput
  :: FilePath -> BS8.ByteString -> [String] -> IO (Either String ())
runDemoOidcAgentWithInput repoRoot input arguments = do
  result <-
    captureSubprocessWithInputBounded
      demoOidcAgentLimits
      input
      (demoOidcKubectlSubprocess repoRoot arguments)
  pure (boundedAgentCommandResult result)

runDemoOidcAgentCommand :: FilePath -> [String] -> IO (Either String ())
runDemoOidcAgentCommand repoRoot arguments = do
  result <-
    captureSubprocessBounded
      demoOidcAgentLimits
      (demoOidcKubectlSubprocess repoRoot arguments)
  pure (boundedAgentCommandResult result)

boundedAgentCommandResult
  :: Either AppError ProcessOutput -> Either String ()
boundedAgentCommandResult result = case result of
  Left err -> Left (Text.unpack (errorMsg err))
  Right output -> case processExitCode output of
    ExitSuccess -> Right ()
    ExitFailure _ -> Left "OIDC session validation Agent command failed"

readDemoOidcSessionValidationAgentResult :: FilePath -> IO (Either String Value)
readDemoOidcSessionValidationAgentResult repoRoot = do
  result <-
    captureSubprocessBounded
      demoOidcAgentLimits
      ( demoOidcKubectlSubprocess
          repoRoot
          [ "logs"
          , "--namespace"
          , demoOidcSessionValidationNamespace
          , "job/" ++ demoOidcSessionValidationJobName
          , "--container"
          , demoOidcSessionValidationJobName
          ]
      )
  pure $ case result of
    Left err -> Left (Text.unpack (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ -> Left "OIDC session validation Agent result was unavailable"
      ExitSuccess ->
        case eitherDecode (BL.fromStrict (BS8.pack (processStdout output))) of
          Left _ -> Left "OIDC session validation Agent returned invalid JSON"
          Right payload -> Right payload

deleteDemoOidcSessionValidationAgent :: FilePath -> IO (Either String ())
deleteDemoOidcSessionValidationAgent repoRoot = do
  deleted <-
    runDemoOidcAgentCommand
      repoRoot
      [ "delete"
      , "--namespace"
      , demoOidcSessionValidationNamespace
      , "job/" ++ demoOidcSessionValidationJobName
      , "--ignore-not-found=true"
      , "--cascade=foreground"
      , "--wait=true"
      ]
  case deleted of
    Left err -> pure (Left err)
    Right () -> observeDemoOidcSessionValidationAgentAbsent repoRoot

observeDemoOidcSessionValidationAgentAbsent :: FilePath -> IO (Either String ())
observeDemoOidcSessionValidationAgentAbsent repoRoot = do
  result <-
    captureSubprocessBounded
      demoOidcAgentLimits
      ( demoOidcKubectlSubprocess
          repoRoot
          [ "get"
          , "pods"
          , "--namespace"
          , demoOidcSessionValidationNamespace
          , "--selector=job-name=" ++ demoOidcSessionValidationJobName
          , "--output=name"
          ]
      )
  pure $ case result of
    Left err -> Left (Text.unpack (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ -> Left "OIDC session validation Agent absence was unobservable"
      ExitSuccess
        | null (Text.unpack (Text.strip (Text.pack (processStdout output)))) -> Right ()
        | otherwise -> Left "OIDC session validation Agent Pod remained after Job deletion"

demoOidcKubectlSubprocess :: FilePath -> [String] -> Subprocess
demoOidcKubectlSubprocess repoRoot arguments =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments = arguments
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
fetchAccessToken repoRoot _settings _substrate secretKey clientId =
  case oidcClientSecretIdentityFor secretKey of
    Left err -> pure (Left err)
    Right identity
      | oidcClientIdForIdentity identity /= clientId ->
          pure (Left "OIDC validation client identity/client-id mismatch")
      | otherwise ->
          Prodbox.UsersAdmin.issueDemoOidcAccessToken repoRoot identity

-- | Map the stable validation key onto the closed in-Pod consumer identity.
-- Unknown names are rejected instead of becoming caller-controlled paths.
oidcClientSecretIdentityFor :: String -> Either String OidcIdentity
oidcClientSecretIdentityFor "keycloak_vscode_client_secret" = Right OidcVscode
oidcClientSecretIdentityFor "keycloak_api_client_secret" = Right OidcProdboxApi
oidcClientSecretIdentityFor "keycloak_websocket_client_secret" = Right OidcProdboxWebsocket
oidcClientSecretIdentityFor "VSCODE_CLIENT_SECRET" = Right OidcVscode
oidcClientSecretIdentityFor "API_CLIENT_SECRET" = Right OidcProdboxApi
oidcClientSecretIdentityFor "WEBSOCKET_CLIENT_SECRET" = Right OidcProdboxWebsocket
oidcClientSecretIdentityFor other = Left ("unsupported registered OIDC material key: " ++ other)

oidcClientIdForIdentity :: OidcIdentity -> String
oidcClientIdForIdentity identity = case identity of
  OidcVscode -> "vscode"
  OidcProdboxApi -> "prodbox-api"
  OidcProdboxWebsocket -> "prodbox-websocket"
  OidcDemoUser -> "demo-user"

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
  -> ValidatedServedHost
  -> String
  -> String
  -> String
  -> IO ExitCode
assertOidcProtectedRoute repoRoot servedHost requestUrl callbackUrl failurePrefix = do
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
      if redirectHeadersContainOidcContract servedHost callbackUrl redirectHeaders
        then pure ExitSuccess
        else failWith (failurePrefix ++ ": " ++ redirectHeaders)

redirectHeadersContainOidcContract :: ValidatedServedHost -> String -> String -> Bool
redirectHeadersContainOidcContract servedHost callbackUrl redirectHeaders =
  let loweredRedirectHeaders = map toLowerAscii redirectHeaders
   in all (`isInfixOf` loweredRedirectHeaders) (oidcRedirectFragments servedHost callbackUrl)

oidcRedirectFragments :: ValidatedServedHost -> String -> [String]
oidcRedirectFragments servedHost callbackUrl =
  map
    (map toLowerAscii)
    [ "HTTP/"
    , "Location: " ++ substrateIdentityIssuerUrl servedHost ++ "/protocol/openid-connect/auth"
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
        case classifyPublicEdgeReadinessObservation (processExitCode output) combinedOutput of
          PublicEdgeReadinessTerminalFailure code ->
            failWith
              ( "`"
                  ++ commandDisplay spec
                  ++ "` exited with code "
                  ++ show code
              )
          PublicEdgeReadinessReady -> pure ExitSuccess
          observation
            | attemptsLeft <= 1 ->
                failWith
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` did not report required output `"
                      ++ publicEdgeReadyClassification
                      ++ "` before timeout."
                  )
            | otherwise -> do
                writeDiagnosticLine
                  ( case observation of
                      PublicEdgeReadinessGatewayDnsPending ->
                        "Waiting for Gateway-DNS write authority before external curl validation."
                      PublicEdgeReadinessPending ->
                        "Waiting for public edge readiness before external curl validation."
                  )
                threadDelay publicEdgeReadyDelayMicroseconds
                waitForClassification spec (attemptsLeft - 1)

runPublicDnsValidation :: FilePath -> Substrate -> IO ExitCode
runPublicDnsValidation repoRoot _substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    -- Sprint 1.89: refuse before dispatching rather than observe the zone `""`.
    Right settings -> case requireHomeZoneId settings of
      Left err -> failWith err
      Right homeZoneId -> do
        zoneEvidence <-
          dispatchHostProviderIntentFresh
            LifecycleAuthorityTestHarness
            repoRoot
            "validation-public-dns-zone"
            ( ObserveProviderReadiness
                (ProviderReadinessRoute53Zone (route53ZoneIdText homeZoneId))
            )
        let zonePayloadResult = case zoneEvidence of
              Left err -> Left (renderProviderCallerError err)
              Right evidence -> decodeRoute53ZoneEvidence evidence
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

runCertificateScopeServingValidation :: FilePath -> Substrate -> IO ExitCode
runCertificateScopeServingValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith ("load settings for certificate-scope validation: " ++ err)
    Right settings ->
      -- Sprint 1.83: the served host and its scope set are the pair config
      -- validation parsed, so this validation can no longer probe one host while
      -- asserting the scope set of another.
      case Prodbox.Settings.substrateServedHost settings substrate of
        Nothing -> failWith (substrateServedHostMissing substrate)
        Just served -> do
          let servedHost = fqdnText (Prodbox.Settings.servedHostFqdn served)
              scopeSet = Prodbox.Settings.servedHostCertScopes served
          probeResult <- curlTlsServingProbe repoRoot (Text.unpack servedHost)
          case probeResult of
            Left err -> failWith err
            Right () -> do
              sansResult <- presentedCertificateSans repoRoot (Text.unpack servedHost)
              case sansResult of
                Left err -> failWith err
                Right presented ->
                  case validatePresentedDnsSans (certScopeSetDnsNames scopeSet) (Text.pack presented) of
                    Left defect -> failWith (renderCertificateServingDefect defect)
                    Right () -> do
                      writeOutput
                        ( unlines
                            [ "CERTIFICATE_SCOPE_SERVING_VALIDATION"
                            , "SUBSTRATE=" ++ substrateId substrate
                            , "SERVED_HOST=" ++ Text.unpack servedHost
                            , "PRESENTED_SAN_SET=" ++ show (certScopeSetDnsNames scopeSet)
                            , "TLS_HANDSHAKE=verified"
                            ]
                        )
                      pure ExitSuccess

runCleanRoomHandoffValidation :: FilePath -> IO ExitCode
runCleanRoomHandoffValidation repoRoot = do
  (paths, sources) <- productionSources repoRoot
  -- The scan follows the cycle ledger's phase: the exact pre-activation inventory
  -- while the legacy source is in the tree, nothing at all once the deletion is
  -- recorded. With no ledger the phase is pre-activation, as it has always been;
  -- a ledger that cannot be read fails here rather than defaulting.
  scanModeResult <- ledgerScanMode repoRoot
  case scanModeResult of
    Left err -> failWith ("clean-room qualification ledger is refused: " ++ err)
    Right scanMode ->
      case CleanRoom.legacyResidueViolations paths sources of
        residue : _ -> failWith ("clean-room legacy residue remains: " ++ show residue)
        [] ->
          case CleanRoom.legacyCutoverResidueViolations scanMode sources of
            residue : _ ->
              failWith ("clean-room legacy cutover inventory drifted: " ++ show residue)
            [] -> do
              writeOutput (CleanRoom.renderCleanRoomPlan [])
              summaryLines <- ledgerSummaryLines repoRoot
              writeOutput (unlines summaryLines)
              case fixedCascadeCandidatePlanSummary of
                Left err -> failWith err
                Right summary ->
                  writeOutput
                    ( unlines
                        [ "QUALIFICATION_ONLY_CASCADE_CANDIDATE"
                        , "CLEANUP_RUN_ID="
                            ++ Text.unpack (cascadeCandidateSummaryRunId summary)
                        , "GRAPH_DIGEST="
                            ++ Text.unpack (cascadeCandidateSummaryGraphDigest summary)
                        , "DESCRIPTOR_DIGEST="
                            ++ Text.unpack (cascadeCandidateSummaryDescriptorDigest summary)
                        , "TERMINAL_OPERATION_ID="
                            ++ Text.unpack
                              (cascadeCandidateSummaryTerminalOperationId summary)
                        ]
                    )
                    >> mapM_
                      (writeOutput . CleanRoom.renderInstalledCascadeTrace)
                      CleanRoom.fixedInstalledCascadeTraces
                    >> pure ExitSuccess

runCascadeQualificationValidation
  :: FilePath -> [(String, String)] -> Substrate -> IO ExitCode
runCascadeQualificationValidation repoRoot environment substrate =
  case substrate of
    SubstrateHomeLocal ->
      failWith
        "cascade-qualification is destructive AWS-harness work; rerun with --substrate aws"
    SubstrateAws ->
      case lookup cascadeQualificationCycleVariable environment of
        Nothing ->
          failWith
            ( cascadeQualificationCycleVariable
                ++ " must name the stable qualification cycle (for example pre-1, pre-2, or post-1)"
            )
        Just cycleLabel
          | null cycleLabel || any isSpace cycleLabel ->
              failWith
                (cascadeQualificationCycleVariable ++ " must be non-empty and contain no whitespace")
          | otherwise -> do
              driven <-
                runCascadeQualificationCandidate
                  repoRoot
                  environment
                  (Text.pack cycleLabel)
              case driven of
                Left err -> failWith ("cascade qualification failed: " ++ err)
                Right outcome -> do
                  let result = cascadeQualificationLifecycleResult outcome
                  writeOutput
                    ( unlines
                        [ "CASCADE_QUALIFICATION_RESULT"
                        , "CYCLE=" ++ cycleLabel
                        , "ATTEMPT=" ++ show (cascadeQualificationAttempt outcome)
                        , "CLEANUP_RUN_ID="
                            ++ Text.unpack (cascadeQualificationRunId outcome)
                        , "IDENTITY_KEY="
                            ++ Text.unpack (cascadeQualificationIdentityKey outcome)
                        , "EVIDENCE_PATH=" ++ cascadeQualificationEvidencePath outcome
                        , "EVIDENCE_DIGEST="
                            ++ Text.unpack (cascadeQualificationEvidenceDigest outcome)
                        , "LIFECYCLE_RESULT=" ++ show result
                        , "CYCLE_OUTCOME="
                            ++ Text.unpack (cascadeQualificationCycleOutcome outcome)
                        , "LEDGER_ENTRIES="
                            ++ show (cascadeQualificationLedgerEntries outcome)
                        , "LEDGER_TIP="
                            ++ Text.unpack (cascadeQualificationLedgerTip outcome)
                        ]
                    )
                  if cascadeQualificationCyclePassed outcome
                    then pure ExitSuccess
                    else
                      failWith
                        ( "cascade qualification cycle did not qualify ("
                            ++ Text.unpack (cascadeQualificationCycleOutcome outcome)
                            ++ "); a failed, interrupted or drifted attempt is recorded in the cycle ledger and breaks the count"
                        )

cascadeQualificationCycleVariable :: String
cascadeQualificationCycleVariable = "PRODBOX_TEST_CASCADE_QUALIFICATION_CYCLE"

-- | Read-only: report whether the cycle ledger holds two consecutive qualifying
-- cascade cycles on one deployment that is still the current tree. It mutates
-- nothing and needs no cluster or AWS credential; it exits zero only for a
-- qualifying verdict, so it is deliberately outside @test all@, where the
-- campaign being pending is a normal state.
runCascadeQualificationReceiptValidation :: FilePath -> [(String, String)] -> IO ExitCode
runCascadeQualificationReceiptValidation repoRoot environment = do
  report <- runCascadeQualificationReceipt repoRoot environment
  writeOutput (unlines (map Text.unpack (receiptLines report)))
  if receiptQualified report
    then pure ExitSuccess
    else
      failWith
        "the cycle ledger does not hold two consecutive qualifying cascade cycles on the current tree"

curlTlsServingProbe :: FilePath -> String -> IO (Either String ())
curlTlsServingProbe repoRoot host = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "curl"
        , subprocessArguments =
            [ "--silent"
            , "--show-error"
            , "--output"
            , "/dev/null"
            , "--connect-timeout"
            , "15"
            , "--max-time"
            , "30"
            , "https://" ++ host ++ "/"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case result of
    Failure err -> Left err
    Success output -> case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure code ->
        Left
          ("TLS serving probe failed for " ++ host ++ " (exit " ++ show code ++ "): " ++ outputDetail output)

presentedCertificateSans :: FilePath -> String -> IO (Either String String)
presentedCertificateSans repoRoot host = do
  handshake <-
    captureSubprocessBounded
      certificateProbeLimits
      Subprocess
        { subprocessPath = "openssl"
        , subprocessArguments =
            [ "s_client"
            , "-connect"
            , host ++ ":443"
            , "-servername"
            , host
            , "-verify_hostname"
            , host
            , "-verify_return_error"
            , "-showcerts"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  case handshake of
    Left err -> pure (Left (Text.unpack (errorMsg err)))
    Right output -> case processExitCode output of
      ExitFailure code ->
        pure
          (Left ("TLS handshake failed for " ++ host ++ " (exit " ++ show code ++ "): " ++ outputDetail output))
      ExitSuccess ->
        case firstPemCertificate (processStdout output) of
          Left err -> pure (Left err)
          Right certificate -> inspectCertificateSans repoRoot certificate

certificateProbeLimits :: BoundedSubprocessLimits
certificateProbeLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 128 * 1024
    , boundedSubprocessMaximumStdoutBytes = 512 * 1024
    , boundedSubprocessMaximumStderrBytes = 128 * 1024
    , boundedSubprocessTimeoutMicros = 45 * 1000 * 1000
    }

firstPemCertificate :: String -> Either String String
firstPemCertificate output =
  case dropWhile (not . isPrefixOf "-----BEGIN CERTIFICATE-----") (lines output) of
    [] -> Left "TLS handshake returned no PEM certificate"
    certificateLines ->
      let throughEnd = takeThrough (== "-----END CERTIFICATE-----") certificateLines
       in if "-----END CERTIFICATE-----" `elem` throughEnd
            then Right (unlines throughEnd)
            else Left "TLS handshake returned a truncated PEM certificate"

takeThrough :: (a -> Bool) -> [a] -> [a]
takeThrough _ [] = []
takeThrough predicate (value : values)
  | predicate value = [value]
  | otherwise = value : takeThrough predicate values

inspectCertificateSans :: FilePath -> String -> IO (Either String String)
inspectCertificateSans repoRoot certificate = do
  result <-
    captureSubprocessWithInputBounded
      certificateProbeLimits
      (BS8.pack certificate)
      Subprocess
        { subprocessPath = "openssl"
        , subprocessArguments = ["x509", "-noout", "-ext", "subjectAltName"]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case result of
    Left err -> Left (Text.unpack (errorMsg err))
    Right output -> case processExitCode output of
      ExitSuccess -> Right (processStdout output)
      ExitFailure code ->
        Left ("certificate SAN inspection failed (exit " ++ show code ++ "): " ++ outputDetail output)

runDnsAwsValidation :: FilePath -> IO ExitCode
runDnsAwsValidation repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    -- Sprint 1.89: refuse before dispatching rather than observe the zone `""`.
    Right settings -> case requireHomeZoneId settings of
      Left err -> failWith err
      Right homeZoneId -> do
        baseZoneResult <- observeHomeZoneName repoRoot (route53ZoneIdText homeZoneId)
        case baseZoneResult of
          Left err -> failWith err
          Right baseZoneName -> do
            nonce <- validationNonce
            runDnsAwsLifecycle repoRoot (Text.pack nonce) baseZoneName

-- | The home zone's name, read through the Provider because the host holds no
-- AWS credential.
observeHomeZoneName :: FilePath -> Text.Text -> IO (Either String String)
observeHomeZoneName repoRoot homeZoneId = do
  zoneEvidence <-
    dispatchHostProviderIntentFresh
      LifecycleAuthorityTestHarness
      repoRoot
      "validation-dns-aws-base-zone"
      (ObserveProviderReadiness (ProviderReadinessRoute53Zone homeZoneId))
  pure $ do
    evidence <- Bifunctor.first renderProviderCallerError zoneEvidence
    payload <- decodeRoute53ZoneEvidence evidence
    (zoneName, _) <- hostedZoneDelegation payload
    Right (trimTrailingDot zoneName)

-- | Create a throwaway zone, write and read back one record in it, and remove
-- the zone, every step through the Provider.
--
-- The zone is created by the registered validation-zone owner from the nonce, so
-- the name this validation derives is only used to name the record. The family
-- sweep runs whether or not the flow reaches its own teardown, and its result
-- is part of the verdict: a zone the sweep could not remove is a failure.
runDnsAwsLifecycle :: FilePath -> Text.Text -> String -> IO ExitCode
runDnsAwsLifecycle repoRoot nonce baseZoneName = do
  ensured <-
    dispatchDnsAws repoRoot "validation-dns-aws-zone" $
      EnsureValidationHostedZone nonce (Text.pack baseZoneName)
  validationResult <- case ensured >>= parseValidationZoneEvidence of
    Left err -> pure (Left err)
    Right zoneId -> exerciseValidationRecord repoRoot nonce baseZoneName zoneId
  swept <-
    dispatchDnsAws repoRoot "validation-dns-aws-sweep" $
      ReapValidationHostedZones dnsValidationHostedZoneNamePrefix
  case (validationResult, swept) of
    (Right (), Right _) -> pure ExitSuccess
    (Left err, _) -> failWith err
    (Right (), Left err) -> failWith ("validation hosted-zone sweep failed: " ++ err)

exerciseValidationRecord :: FilePath -> Text.Text -> String -> Text.Text -> IO (Either String ())
exerciseValidationRecord repoRoot nonce baseZoneName zoneId =
  case mkPublicARecordRef zoneId (Text.pack recordName) 60 [Text.pack recordIp] of
    Left err -> pure (Left ("build the validation record: " ++ show err))
    Right ref -> do
      written <- dispatchDnsAws repoRoot "validation-dns-aws-record" (ReconcilePublicARecord ref)
      case written of
        Left err -> pure (Left ("Route 53 record write failed: " ++ err))
        Right _ -> do
          observed <- dispatchDnsAws repoRoot "validation-dns-aws-verify" (ObservePublicARecord ref)
          pure $ case observed of
            Left err -> Left ("Route 53 record read-back failed: " ++ err)
            Right evidence
              | evidence == expectedEvidence -> Right ()
              | otherwise ->
                  Left
                    ( "Route 53 record lifecycle validation failed: expected "
                        ++ Text.unpack expectedEvidence
                        ++ " but found "
                        ++ Text.unpack evidence
                    )
 where
  zoneName =
    Route53ValidationZone.validationHostedZoneName (Text.unpack nonce) baseZoneName
  recordName = "gateway." ++ zoneName
  recordIp = "203.0.113.10"
  expectedEvidence = "public-a-values:" <> Text.pack recordIp

dispatchDnsAws :: FilePath -> Text.Text -> ProviderIntent -> IO (Either String Text.Text)
dispatchDnsAws repoRoot prefix intent =
  Bifunctor.first renderProviderCallerError
    <$> dispatchHostProviderIntentFresh LifecycleAuthorityTestHarness repoRoot prefix intent

-- | The zone id a validation-zone ensure names.
parseValidationZoneEvidence :: Text.Text -> Either String Text.Text
parseValidationZoneEvidence evidence =
  case Text.stripPrefix "validation-zone:" evidence of
    Just zoneId | not (Text.null zoneId) -> Right zoneId
    _ -> Left ("the Provider named no validation hosted zone: " ++ Text.unpack evidence)

runGatewayDaemonValidation :: FilePath -> [(String, String)] -> IO ExitCode
runGatewayDaemonValidation repoRoot environment = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForGatewayEmitters repoRoot environment
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
    , "    , lifecycle_authority = None { authority_scope : Text, endpoint : Text }"
    , "    , dns_write_gate = Some"
    , "        { zone_id = " ++ dhallText (Text.unpack (homeZoneIdTextForRendering settings))
    , "        , fqdn = " ++ dhallText (publicFqdn settings)
    , "        , ttl = " ++ show (dnsTtlSeconds (coordinateDemoTtl (validatedCoordinates settings)))
    , "        , aws_region = "
        ++ dhallText
          ( maybe
              ""
              (Text.unpack . awsRegionText)
              (coordinateOperationalAwsRegion (validatedCoordinates settings))
          )
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
  environment <- getEnvironment
  testSshExecutable <- lookupEnv "PRODBOX_TEST_SSH_EXECUTABLE"
  let spec =
        Subprocess
          { subprocessPath = fromMaybe "ssh" testSshExecutable
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
          , subprocessEnvironment = Just environment
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
        recordResult <-
          retryWhileGatewayDnsPending
            publicDnsWriteAuthorityAttempts
            publicDnsWriteAuthorityDelayMicroseconds
            (queryRoute53Record repoRoot settings fqdn)
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

-- | How long the DNS validation waits for the Gateway-DNS write authority: the
-- gateway state is served by whichever node the loopback endpoint reaches and
-- only the node that holds the ownership claim reports that it can write, so a
-- run that follows a credential change or a gateway restart sees the refusal
-- until the claim settles. The public-edge wait already treats exactly this
-- refusal as retryable; the validation that reads the same observation did not.
publicDnsWriteAuthorityAttempts :: Int
publicDnsWriteAuthorityAttempts = 30

publicDnsWriteAuthorityDelayMicroseconds :: Int
publicDnsWriteAuthorityDelayMicroseconds = 10 * 1000 * 1000

-- | Repeat an observation while it answers the one transient Gateway-DNS
-- convergence refusal, up to the attempts given. Every other answer, success or
-- failure, ends the wait at once, and the last answer is returned unchanged when
-- the attempts run out.
retryWhileGatewayDnsPending
  :: Int -> Int -> IO (Either String value) -> IO (Either String value)
retryWhileGatewayDnsPending attemptsLeft delayMicros observe = do
  result <- observe
  case result of
    Left err
      | attemptsLeft > 1
      , gatewayDnsWriteAuthorityNotReadyDiagnostic `isInfixOf` err -> do
          threadDelay delayMicros
          retryWhileGatewayDnsPending (attemptsLeft - 1) delayMicros observe
    _ -> pure result

assertPublicHttpRedirect
  :: FilePath -> ValidatedSettings -> Substrate -> PublicEdgeRoute -> IO ExitCode
assertPublicHttpRedirect repoRoot settings substrate route =
  -- Sprint 1.84: resolve here, where there is an error channel, and hand the
  -- pure renderer a host it can render.
  -- Sprint 1.87: carry the resolved 'ValidatedServedHost' rather than its string
  -- projection, so the HTTPS half of this comparison consumes the same
  -- resolution as the HTTP half instead of re-deriving it.
  case requireSubstrateServedHost settings substrate of
    Left err -> failWith err
    Right servedHost -> assertPublicHttpRedirectAt repoRoot servedHost route

assertPublicHttpRedirectAt
  :: FilePath -> ValidatedServedHost -> PublicEdgeRoute -> IO ExitCode
assertPublicHttpRedirectAt repoRoot servedHost route = do
  let publicHost = servedHostString servedHost
  result <-
    runTextCommand
      Subprocess
        { subprocessPath = "curl"
        , subprocessArguments =
            ["-sS", "-D", "-", "-o", "/dev/null", publicHttpRouteUrl publicHost route]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  case result of
    Left err -> failWith err
    Right headers ->
      if publicHttpRedirectMatches servedHost route headers
        then pure ExitSuccess
        else failWith ("public HTTP redirect did not target the canonical HTTPS route: " ++ headers)

-- | Sprint 1.84: takes the resolved served host rather than reaching for it.
-- The pure renderer has no error channel, so the resolution moves to its IO
-- caller, which does — that is the whole shape of this sprint.
publicHttpRouteUrl :: String -> PublicEdgeRoute -> String
publicHttpRouteUrl publicHost route =
  "http://" ++ publicHost ++ publicRoutePathPrefix route

publicHttpRedirectMatches :: ValidatedServedHost -> PublicEdgeRoute -> String -> Bool
publicHttpRedirectMatches servedHost route headers =
  let lowered = map toLowerAscii headers
      target = map toLowerAscii ("location: " ++ substratePublicRouteUrl servedHost route)
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

decodeRoute53ZoneEvidence :: Text.Text -> Either String Value
decodeRoute53ZoneEvidence evidence = do
  encoded <-
    maybe
      (Left "Provider Route 53 observation returned an unexpected evidence type")
      Right
      (Text.stripPrefix "provider-readiness-route53-json:" evidence)
  bytes <-
    Bifunctor.first
      (const "Provider Route 53 evidence is not valid base64")
      (Base64.decode (TextEncoding.encodeUtf8 encoded))
  eitherDecode (BL.fromStrict bytes)

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
-- 3. Poll the SES capture bucket through the Provider (`ObserveSesInviteMail`) for the
--    inbound message (60 s deadline).
-- 4. Extract the action-token URL via `Prodbox.Keycloak.Email.parseKeycloakInviteLink`.
-- 5. Follow the link with a cookie jar, parse and POST the Keycloak
--    credential-setup form with a generated password.
-- 6. Perform a fresh OIDC password-grant login for the invited user and assert the
--    token claims include the selected issuer, `email=<recipient>`, and
--    `email_verified=true`.
-- 7. Cleanup: `UsersAdmin.revokeUser ident --delete` and `ReapSesInviteMail`.
runKeycloakInviteValidation :: FilePath -> Substrate -> [(String, String)] -> IO ExitCode
runKeycloakInviteValidation repoRoot substrate _environment = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess -> do
          nonce <- generateInviteNonce
          let sesSection = Prodbox.Settings.ses (Prodbox.Settings.validatedConfig settings)
              recipientResult =
                keycloakInviteRecipient
                  nonce
                  (Prodbox.Settings.sender_domain sesSection)
                  (Prodbox.Settings.receive_subdomain sesSection)
              captureBucket =
                s3BucketNameText
                  <$> Prodbox.Settings.coordinateSesCaptureBucket
                    (Prodbox.Settings.validatedCoordinates settings)
          -- Sprint 1.84: the served host is resolved through the refusing
          -- accessor, beside the recipient guard that already refuses on the
          -- same shape of missing config.
          case (recipientResult, requireSubstratePublicFqdn settings substrate, captureBucket) of
            (Left err, _, _) -> failWith ("ValidationKeycloakInvite: " ++ err)
            (_, Left err, _) -> failWith err
            (_, _, Nothing) ->
              failWith "ValidationKeycloakInvite: ses.capture_bucket must be set in prodbox.dhall."
            (Right recipient, Right keycloakPublicHost, Just bucket) ->
              runInviteFlow repoRoot settings substrate keycloakPublicHost bucket recipient nonce

-- | Invite a throwaway user, read the invite message back through the Provider,
-- complete the credential setup, and remove the user and the message.
--
-- The captured message is read and deleted by the Provider because the host
-- holds no AWS credential. Cleanup runs whether or not the flow succeeded, and
-- a failure of the flow is never replaced by a failure of its cleanup.
runInviteFlow
  :: FilePath
  -> Prodbox.Settings.ValidatedSettings
  -> Substrate
  -> String
  -> Text.Text
  -> String
  -> String
  -> IO ExitCode
runInviteFlow repoRoot settings substrate keycloakPublicHost bucket recipient nonce = do
  let invitePassword = inviteCredentialPassword nonce
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
      mailResult <- awaitInviteMail repoRoot bucket (Text.pack recipient) inviteMailAttempts
      outcome <- case mailResult of
        Left err -> pure (Failure ("S3 capture poll failed: " ++ err))
        Right (key, inviteUrl) -> do
          writeOutputLine ("KEYCLOAK_INVITE_S3_KEY=" ++ key)
          writeOutputLine "KEYCLOAK_INVITE_LINK_PARSED=true"
          completeInviteFlow repoRoot settings substrate recipient invitePassword inviteUrl
      _ <-
        Prodbox.UsersAdmin.revokeUserAtPublicHost
          repoRoot
          (Text.pack keycloakPublicHost)
          userId
          True
      reaped <-
        dispatchDnsAws repoRoot "validation-invite-mail-reap" $
          ReapSesInviteMail bucket (Text.pack recipient)
      case (outcome, reaped) of
        (Failure err, _) -> failWith err
        (Success (), Left err) -> failWith ("captured invite message was not removed: " ++ err)
        (Success (), Right _) -> do
          writeOutputLine "KEYCLOAK_INVITE_CLEANUP=true"
          pure ExitSuccess

completeInviteFlow
  :: FilePath
  -> Prodbox.Settings.ValidatedSettings
  -> Substrate
  -> String
  -> String
  -> String
  -> IO (Result ())
completeInviteFlow repoRoot settings substrate recipient invitePassword inviteUrl = do
  credentialResult <- completeInviteCredentialSetup repoRoot inviteUrl invitePassword
  case credentialResult of
    Failure err -> pure (Failure ("credential setup failed: " ++ err))
    Success () -> do
      writeOutputLine "KEYCLOAK_INVITE_CREDENTIAL_SET=true"
      claimResult <-
        waitForInviteOidcClaims repoRoot settings substrate recipient invitePassword
      case claimResult of
        Left err -> pure (Failure ("OIDC claim assertion failed: " ++ err))
        Right () -> do
          writeOutputLine "KEYCLOAK_INVITE_OIDC_CLAIMS_VERIFIED=true"
          pure (Success ())

-- | What the invite-mail observation reported.
data InviteMailObservation
  = InviteMailPending
  | InviteMailArrived !String !String
  deriving (Eq, Show)

-- | Read the Provider's invite-mail evidence: @ses-invite:pending@, or
-- @ses-invite:\<object-key> \<invite-link>@.
parseInviteMailEvidence :: Text.Text -> Either String InviteMailObservation
parseInviteMailEvidence evidence =
  case Text.stripPrefix "ses-invite:" evidence of
    Nothing -> Left ("unexpected invite-mail evidence: " ++ Text.unpack evidence)
    Just "pending" -> Right InviteMailPending
    Just arrived -> case Text.words arrived of
      [key, inviteLink] ->
        Right (InviteMailArrived (Text.unpack key) (Text.unpack inviteLink))
      _ -> Left "invite-mail evidence is not an object key and a link"

-- | Poll the Provider for the invite message, one observation per attempt.
awaitInviteMail
  :: FilePath -> Text.Text -> Text.Text -> Int -> IO (Either String (String, String))
awaitInviteMail repoRoot bucket recipient attemptsLeft
  | attemptsLeft <= 0 =
      pure
        ( Left
            ( "no inbound message addressed to "
                ++ Text.unpack recipient
                ++ " arrived within the deadline"
            )
        )
  | otherwise = do
      observed <-
        dispatchDnsAws repoRoot "validation-invite-mail" (ObserveSesInviteMail bucket recipient)
      case observed >>= parseInviteMailEvidence of
        Left err -> pure (Left err)
        Right (InviteMailArrived key inviteLink) -> pure (Right (key, inviteLink))
        Right InviteMailPending -> do
          threadDelay inviteMailPollDelayMicroseconds
          awaitInviteMail repoRoot bucket recipient (attemptsLeft - 1)

inviteMailAttempts :: Int
inviteMailAttempts = 20

inviteMailPollDelayMicroseconds :: Int
inviteMailPollDelayMicroseconds = 3_000_000

-- | The address the invite validation sends to: a local part unique to the run
-- at the dotted receive domain the SES receipt rule is registered for.
--
-- @ses.receive_subdomain@ is a single DNS label, so the bare configured value
-- is not a mail domain and no captured message can carry it in its @To:@
-- header.  The domain is composed by the one rule the SES Provider references
-- use, and an unset label refuses by name rather than producing an address
-- nothing could receive.
keycloakInviteRecipient :: String -> Text.Text -> Text.Text -> Either String String
keycloakInviteRecipient nonce senderDomain receiveLabel =
  (\domain -> "test-" ++ nonce ++ "@" ++ Text.unpack domain)
    <$> Prodbox.Settings.sesReceiveDomain senderDomain receiveLabel

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
  tokenResult <-
    Prodbox.UsersAdmin.issueUserOidcAccessToken
      repoRoot
      OidcProdboxApi
      (Text.pack recipient)
      (Text.pack password)
  case tokenResult of
    Left err -> pure (Left err)
    Right token ->
      pure $ do
        servedHost <- requireSubstrateServedHost settings substrate
        claimsPayload <- decodeJwtPayload token
        assertInviteOidcClaims
          (substrateIdentityIssuerUrl servedHost)
          recipient
          claimsPayload

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
