{-# LANGUAGE ScopedTypeVariables #-}

-- | Confined kind observations and worker composition. These do not grant
-- lifecycle admission or establish provider ownership or settlement.
module Prodbox.Control.KindTool
  ( KindToolAttempt (..)
  , KindToolObservation (..)
  , observeKindToolVersion
  , observeKindToolVersionOnHost
  , observeKindToolClusterOnHost
  , ConfinedKindInventory (..)
  , KindDockerMarkerObservation (..)
  , observeKindDockerMarker
  , ConfinedKindNodeAttempt (..)
  , runConfinedKindNodeOnHost
  , kindNodeWorkerEnvironment
  , runVerifiedConfinedKindNodeOnHost
  , ArchiveBoundConfinedKindNode (..)
  , ConnectedConfinedKindNode (..)
  , ConfinedNodeNetworkObservation (..)
  , observeConfinedNodeNetwork
  , ConfinedNodeImageObservation (..)
  , observeConfinedNodeImage
  , runArchiveBoundConfinedKindNodeOnHost
  , ConfinedKindInventoryConclusion (..)
  , ConfinedKindSnapshotsAttempt (..)
  , ConfinedKindSnapshotsObservation (..)
  , withConfinedKindSnapshots
  , observeConfinedKindInventoryOnHost
  , observeVerifiedConfinedKindInventoryOnHost
  , ConnectedConfinedKindInventory (..)
  , observeConnectedConfinedKindInventoryOnHost
  , interpretConnectedConfinedKindInventory
  , RecordedConfinedKindInventory (..)
  , observeRecordedConfinedKindInventoryOnHost
  , interpretRecordedConfinedKindInventory
  , ArchiveBoundConfinedKindInventory (..)
  , observeArchiveBoundConfinedKindInventoryOnHost
  , interpretArchiveBoundConfinedKindInventory
  , interpretConfinedKindInventory
  , interpretVerifiedConfinedKindInventory
  , parseKindClusterList
  )
where

import Control.Exception (IOException, bracket, try)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isAsciiLower, isDigit, isPrint)
import Data.List (isPrefixOf)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapKindTool
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( HeldArtifactResult (..)
  , ScopeArtifactObservation
  , ScopeGenerationObservation (..)
  , observeScopeGeneration
  , scopeKindName
  , scopeRoot
  , withVerifiedScopeArtifact
  )
import Prodbox.Config.KindPlan (KindNodeCreateInput (..), renderKindConfigWithLocalImageId)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoFailure
  , DockerConnectedInfoResult (..)
  , DockerImageLoadResult (..)
  , DockerImageLoadStream (..)
  , DockerNetworkCreateResult (..)
  , DockerSession
  , inspectDockerSessionImage
  , inspectDockerSessionKindNetwork
  , readDockerSessionKindNetworks
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..))
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..))
import Prodbox.Control.ImageIdObservation (ImageIdObservation (..))
import Prodbox.Control.KindDockerEndpoint
  ( KindDockerBrokerExit (..)
  , KindDockerEndpointResult (..)
  , KindDockerWorkerExit (..)
  , runBoundKindDockerReadWorker
  )
import Prodbox.Control.KindDockerReadGate (kindDockerInventoryObserved, newKindInventoryReadGate)
import Prodbox.Control.KindDockerWorkerPrepare
  ( KindDockerClientLinkPreparation (..)
  , KindDockerClientLinkRemoval (..)
  , prepareKindDockerClientLink
  , removeKindDockerClientLink
  )
import Prodbox.Control.KindDockerWorkerRoots
  ( withRecoveredKindDockerWorkerRoots
  , workerBridge
  , workerLock
  , workerReply
  , workerRequest
  , workerScratch
  )
import Prodbox.Control.KindLease (KindOperationOutcome (..))
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkAttemptObservation (..)
  , KindNetworkRecoveryObservation (..)
  , KindNetworkRemovalObservation (..)
  , kindNetworkDaemon
  , observeKindNetworkAttempt
  , observeKindNetworkRemoval
  , observeRecordedKindNetworkIntent
  )
import Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptKind (..)
  , NetworkReceiptObservation (..)
  , NetworkTransport (..)
  , observeNetworkReceipt
  )
import Prodbox.Control.KindNetworkRecovery
  ( KindNetworkConfigurationObservation (..)
  , compareKindNetworkConfiguration
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateIntent
  , KindNodeCreateRecoveryObservation (..)
  , kindNodeCreateDaemon
  , kindNodeCreateInput
  , observeRecordedKindNodeCreateIntent
  )
import Prodbox.Control.KindNodeCreateOperation
  ( KindNodeRunAction
  , newKindNodeBroker
  , observeKindNodeBrokerResult
  , runBoundKindNodeWorker
  )
import Prodbox.Control.NodeArchive
  ( InspectedArchiveResult (..)
  , VerifiedNodeArchive (..)
  , withInspectedNodeArchive
  )
import Prodbox.Control.NodeImageIntent
  ( NodeImageAttemptObservation (..)
  , NodeImageIdentityObservation (..)
  , NodeImageIntentObservation (..)
  , NodeImageResultObservation (..)
  , nodeImageIntentConfigDigest
  , nodeImageIntentManifestDigest
  , observeRecordedNodeImageAttempt
  , observeRecordedNodeImageIdentity
  , observeRecordedNodeImageResult
  )
import Prodbox.Control.SealedTool
  ( KindWorkerSnapshots
  , SealedToolBudget
  , SealedToolError
  , kindWorkerClientBudget
  , kindWorkerKindBudget
  , sealedToolRuntimePlan
  , withSealedTool
  )
import Prodbox.Subprocess
  ( HostSubprocessError
  , KindHostSubprocessPlacement
  , OwnedSubprocessError
  , OwnedSubprocessLimits
  , ProcessOutput (..)
  , Subprocess (..)
  , captureOwnedSubprocess
  , kindWorkerSandboxReady
  , mkKindWorkerSandbox
  , withPreparedConfinedKindHostSubprocess
  , withPreparedKindHostSubprocess
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (IOErrorType, ioeGetErrorType)
import System.Posix.Files (fileMode, fileSize, getFdStatus)
import System.Posix.IO qualified as Posix
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd (..))

data KindToolAttempt
  = KindToolNotExecutable
  | KindToolChangedBeforeRun
  | KindToolSealRefused !SealedToolError
  | KindToolProcessRefused !OwnedSubprocessError
  | KindToolExitFailure !Int
  | KindToolInvalidVersion
  | KindToolInvalidClusterList
  | KindToolVersion !String
  | KindToolClusterListed !Bool
  deriving (Eq, Show)

data KindToolObservation
  = KindToolNotDeclared
  | KindToolGenerationUnavailable
  | KindToolArtifactRefused !ScopeArtifactObservation
  | KindToolUnobservable
  | KindToolAttempted !KindToolAttempt !Bool
  deriving (Eq, Show)

data ConfinedKindInventory
  = ConfinedKindInventoryInvalidGate
  | ConfinedKindInventoryLink !KindDockerClientLinkPreparation
  | ConfinedKindInventoryInvalidSandbox
  | ConfinedKindInventoryInvalidDescriptors
  | ConfinedKindInventoryObserved
      !KindDockerBrokerExit
      !(KindDockerWorkerExit (Either HostSubprocessError ProcessOutput))
      !Bool
      !KindDockerMarkerObservation
      !(Maybe KindDockerClientLinkRemoval)
  deriving (Show)

data KindDockerMarkerObservation
  = KindDockerMarkerClear
  | KindDockerMarkerRetained
  | KindDockerMarkerUnobservable !IOErrorType
  deriving (Eq, Show)

data ConfinedKindNodeAttempt
  = ConfinedNodeProposalRefused !KindNodeCreateRecoveryObservation
  | ConfinedNodeToolMismatch
  | ConfinedNodeInvalidConfig
  | ConfinedNodeInvalidSandbox
  | ConfinedNodeInvalidDescriptors
  | ConfinedNodeBrokerRefused
  | ConfinedNodeLink !KindDockerClientLinkPreparation
  | ConfinedNodeObserved
      !KindDockerBrokerExit
      !(KindDockerWorkerExit (Either HostSubprocessError ProcessOutput))
      !(Maybe KindNodeRunAction)
      !KindDockerMarkerObservation
  deriving (Show)

data ConnectedConfinedKindNode
  = ConfinedNodeDaemonMismatch !DockerDaemonObservation
  | ConfinedNodeBindingUnavailable
  | ConfinedNodeImageRefused !ConfinedNodeImageObservation
  | ConfinedNodeNetworkRefused !ConfinedNodeNetworkObservation
  | ConfinedNodeBindingChanged
      !( ConfinedKindSnapshotsObservation
           (KindOperationOutcome (KindDockerEndpointResult ConfinedKindNodeAttempt))
       )
  | ConfinedNodeBindingObserved
      !( ConfinedKindSnapshotsObservation
           (KindOperationOutcome (KindDockerEndpointResult ConfinedKindNodeAttempt))
       )
  deriving (Show)

data ConfinedNodeImageObservation
  = ConfinedNodeImageAttemptRefused !NodeImageAttemptObservation
  | ConfinedNodeImageResultRefused !NodeImageResultObservation
  | ConfinedNodeImageMetadataRefused !(Either DockerConnectedInfoFailure ImageIdObservation)
  | ConfinedNodeImageChanged
  | ConfinedNodeImageReady
  deriving (Eq, Show)

data ConfinedNodeNetworkObservation
  = ConfinedNodeNetworkProposalRefused !KindNetworkRecoveryObservation
  | ConfinedNodeNetworkDaemonMismatch
  | ConfinedNodeNetworkAttemptRefused !KindNetworkAttemptObservation
  | ConfinedNodeNetworkReceiptRefused !NetworkReceiptObservation
  | ConfinedNodeNetworkRemovalRefused !KindNetworkRemovalObservation
  | ConfinedNodeNetworkInventoryRefused !(Either DockerConnectedInfoFailure [String])
  | ConfinedNodeNetworkDetailsRefused !(Maybe DockerConnectedInfoFailure)
  | ConfinedNodeNetworkChanged
  | ConfinedNodeNetworkReady
  deriving (Eq, Show)

data ArchiveBoundConfinedKindNode
  = ConfinedNodeImageRecordRefused !NodeImageIntentObservation
  | ConfinedNodeImageRecordMismatch
  | ConfinedNodeProposalUnavailable !KindNodeCreateRecoveryObservation
  | ConfinedNodeProposalMismatch
  | ConfinedNodeConnected !(DockerPeerResult (DockerConnectedInfoResult ConnectedConfinedKindNode))
  deriving (Show)

-- A failed read is not a clear marker and must not discard worker results.
observeKindDockerMarker :: Fd -> IO KindDockerMarkerObservation
observeKindDockerMarker descriptor = do
  result <- try (getFdStatus descriptor)
  pure $ case result of
    Left (failure :: IOException) -> KindDockerMarkerUnobservable (ioeGetErrorType failure)
    Right status -> if fileSize status == 0 then KindDockerMarkerClear else KindDockerMarkerRetained

data ConfinedKindInventoryConclusion
  = ConfinedKindInventoryUnconfirmed
  | ConfinedKindInventorySelected !Bool
  deriving (Eq, Show)

data ConfinedKindSnapshotsAttempt value
  = ConfinedKindNotExecutable
  | ConfinedKindChangedBeforeSnapshot
  | ConfinedKindSnapshotRefused !SealedToolError
  | ConfinedClientOpenRefused
  | ConfinedClientSnapshotRefused !SealedToolError
  | ConfinedSnapshotsReady !value
  deriving (Eq, Show)

data ConfinedKindSnapshotsObservation value
  = ConfinedKindNotDeclared
  | ConfinedKindGenerationUnavailable
  | ConfinedKindArtifactRefused !ScopeArtifactObservation
  | ConfinedKindArtifactUnobservable
  | ConfinedKindSnapshotsAttempted !(ConfinedKindSnapshotsAttempt value) !Bool
  deriving (Eq, Show)

data ConnectedConfinedKindInventory
  = ConfinedDockerIdentityMismatch !DockerDaemonObservation
  | ConfinedDockerBindingUnavailable
  | ConfinedDockerBindingChanged
      !( ConfinedKindSnapshotsObservation
           (KindOperationOutcome (KindDockerEndpointResult ConfinedKindInventory))
       )
  | ConfinedDockerBindingObserved
      !( ConfinedKindSnapshotsObservation
           (KindOperationOutcome (KindDockerEndpointResult ConfinedKindInventory))
       )
  deriving (Show)

data RecordedConfinedKindInventory
  = ConfinedImageRecordRefused !NodeImageIntentObservation
  | ConfinedImageRecordConfigMismatch
  | ConfinedImageRecordObserved
      !(DockerPeerResult (DockerConnectedInfoResult ConnectedConfinedKindInventory))
  deriving (Show)

data ArchiveBoundConfinedKindInventory
  = ConfinedArchiveRecordRefused !NodeImageIntentObservation
  | ConfinedArchiveRecordMismatch
  | ConfinedArchiveInventoryObserved !RecordedConfinedKindInventory
  deriving (Show)

-- | Hold the declared kind artifact and seal its verified bytes alongside a
-- digest-pinned snapshot of this running executable. The caller supplies the
-- trusted operator digest and funded limits, must inspect the final stability
-- flag, and must not let either descriptor escape the callback. The supplied
-- recheck detects change but does not exclude noncooperating writers.
withConfinedKindSnapshots
  :: KindWorkerSnapshots
  -> BootstrapProjection
  -> String
  -> Integer
  -> (Fd -> Fd -> IO Bool -> IO value)
  -> IO (ConfinedKindSnapshotsObservation value)
withConfinedKindSnapshots budgets bootstrap clientDigest clientMaximum action = case bootstrapKindTool bootstrap of
  Nothing -> pure ConfinedKindNotDeclared
  Just declaration -> do
    generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration bootstrap))
    if generation /= Right ScopeGenerationMatches
      then pure ConfinedKindGenerationUnavailable
      else do
        observed <-
          withVerifiedScopeArtifact
            scope
            (artifactPath declaration)
            (artifactDigest declaration)
            (artifactMaximumBytes declaration)
            $ \source stable -> do
              status <- getFdStatus source
              ready <- stable
              if fileMode status .&. 0o100 == 0
                then pure ConfinedKindNotExecutable
                else
                  if not ready
                    then pure ConfinedKindChangedBeforeSnapshot
                    else do
                      kindResult <- withSealedTool
                        (kindWorkerKindBudget budgets)
                        source
                        (artifactDigest declaration)
                        (artifactMaximumBytes declaration)
                        $ \kind -> do
                          stillReady <- stable
                          if not stillReady
                            then pure ConfinedKindChangedBeforeSnapshot
                            else do
                              let flags = Posix.defaultFileFlags {Posix.cloexec = True}
                              opened <- try (Posix.openFd "/proc/self/exe" Posix.ReadOnly flags)
                              case opened of
                                Left (_ :: IOException) -> pure ConfinedClientOpenRefused
                                Right descriptor -> bracket (pure descriptor) Posix.closeFd $ \clientSource -> do
                                  clientResult <- withSealedTool (kindWorkerClientBudget budgets) clientSource clientDigest clientMaximum $ \client ->
                                    ConfinedSnapshotsReady <$> action kind client stable
                                  pure (either ConfinedClientSnapshotRefused id clientResult)
                      pure (either ConfinedKindSnapshotRefused id kindResult)
        pure $ case observed of
          Left _ -> ConfinedKindArtifactUnobservable
          Right (HeldArtifactRefused failure) -> ConfinedKindArtifactRefused failure
          Right (HeldArtifactObserved value stable) -> ConfinedKindSnapshotsAttempted value stable
 where
  scope = bootstrapScope bootstrap

-- | A selected result is a scoped provider observation, not a proof of
-- ownership or absence. Every other combination retains its raw outcome for
-- recovery and is unconfirmed, including a worker that never used the broker.
interpretConfinedKindInventory
  :: String
  -> KindOperationOutcome (KindDockerEndpointResult ConfinedKindInventory)
  -> ConfinedKindInventoryConclusion
interpretConfinedKindInventory selected outcome = case outcome of
  KindOperationCallbackReturned
    ( KindDockerEndpointObserved
        ( ConfinedKindInventoryObserved
            KindDockerBrokerCancelled
            (KindDockerWorkerReturned (Right output))
            True
            KindDockerMarkerClear
            (Just KindDockerClientLinkRemoved)
          )
      )
      | processExitCode output == ExitSuccess ->
          case (parseKindClusterList selected (processStdout output), lines (processStdout output)) of
            (Just False, []) -> ConfinedKindInventorySelected False
            (Just True, [name]) | name == selected -> ConfinedKindInventorySelected True
            _ -> ConfinedKindInventoryUnconfirmed
  _ -> ConfinedKindInventoryUnconfirmed

-- | Require the retained kind artifact to remain stable across the entire
-- operation before accepting even the scoped inventory observation.
interpretVerifiedConfinedKindInventory
  :: String
  -> ConfinedKindSnapshotsObservation
       (KindOperationOutcome (KindDockerEndpointResult ConfinedKindInventory))
  -> ConfinedKindInventoryConclusion
interpretVerifiedConfinedKindInventory selected observation = case observation of
  ConfinedKindSnapshotsAttempted (ConfinedSnapshotsReady outcome) True ->
    interpretConfinedKindInventory selected outcome
  _ -> ConfinedKindInventoryUnconfirmed

-- | Only an unchanged held connection and expected record can contribute a
-- selected inventory observation. This does not authenticate the daemon.
interpretConnectedConfinedKindInventory
  :: String
  -> DockerPeerResult (DockerConnectedInfoResult ConnectedConfinedKindInventory)
  -> ConfinedKindInventoryConclusion
interpretConnectedConfinedKindInventory selected observation = case observation of
  DockerPeerCompleted (DockerConnectedInfoCompleted (ConfinedDockerBindingObserved value)) ->
    interpretVerifiedConfinedKindInventory selected value
  _ -> ConfinedKindInventoryUnconfirmed

interpretRecordedConfinedKindInventory
  :: String -> RecordedConfinedKindInventory -> ConfinedKindInventoryConclusion
interpretRecordedConfinedKindInventory selected observation = case observation of
  ConfinedImageRecordObserved result -> interpretConnectedConfinedKindInventory selected result
  ConfinedImageRecordRefused _ -> ConfinedKindInventoryUnconfirmed
  ConfinedImageRecordConfigMismatch -> ConfinedKindInventoryUnconfirmed

interpretArchiveBoundConfinedKindInventory
  :: String
  -> InspectedArchiveResult ArchiveBoundConfinedKindInventory
  -> ConfinedKindInventoryConclusion
interpretArchiveBoundConfinedKindInventory selected result = case result of
  InspectedArchiveCompleted (ConfinedArchiveInventoryObserved observed) ->
    interpretRecordedConfinedKindInventory selected observed
  _ -> ConfinedKindInventoryUnconfirmed

-- | Hold the independently inspected selected archive, compare its manifest
-- and configuration digests with the complete recorded image intent, and
-- recheck both throughout the read-only inventory. This does not prove that a
-- previous daemon-side load settled, authenticate Docker, or authorize effects.
observeArchiveBoundConfinedKindInventoryOnHost
  :: Int
  -> KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> String
  -> Integer
  -> [Fd]
  -> Fd
  -> IO (InspectedArchiveResult ArchiveBoundConfinedKindInventory)
observeArchiveBoundConfinedKindInventoryOnHost limit placement budgets limits bootstrap operation clientDigest clientMaximum readRoots nullDevice =
  withInspectedNodeArchive bootstrap $ \archive _ archiveStable -> do
    recorded <- observeRecordedNodeImageIdentity bootstrap operation
    case recorded of
      NodeImageIdentityObserved intent (DockerDaemonObserved _ _)
        | nodeImageIntentManifestDigest intent /= nodeManifestDigest archive
            || nodeImageIntentConfigDigest intent /= nodeConfigDigest archive ->
            pure ConfinedArchiveRecordMismatch
        | otherwise -> do
            let stable =
                  (&&) <$> archiveStable <*> ((== recorded) <$> observeRecordedNodeImageIdentity bootstrap operation)
            ConfinedArchiveInventoryObserved
              <$> observeRecordedConfinedKindInventoryWith
                limit
                placement
                budgets
                limits
                bootstrap
                operation
                clientDigest
                clientMaximum
                (nodeConfigDigest archive)
                readRoots
                nullDevice
                stable
      NodeImageIdentityObserved _ _ -> pure (ConfinedArchiveRecordRefused NodeImageIntentUnobservable)
      NodeImageIdentityRefused failure -> pure (ConfinedArchiveRecordRefused failure)

-- | Bind the selected Docker observation to the durable image intent for the
-- same operation and re-read that intent throughout the read. The record and
-- socket identity are observations, not authentication, effect admission or
-- proof of prior worker settlement. The caller still binds the image ID to
-- the inspected archive and supplies a funded, isolated host placement.
observeRecordedConfinedKindInventoryOnHost
  :: Int
  -> KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> String
  -> Integer
  -> String
  -> [Fd]
  -> Fd
  -> IO RecordedConfinedKindInventory
observeRecordedConfinedKindInventoryOnHost limit placement budgets limits bootstrap operation clientDigest clientMaximum imageId readRoots nullDevice =
  observeRecordedConfinedKindInventoryWith
    limit
    placement
    budgets
    limits
    bootstrap
    operation
    clientDigest
    clientMaximum
    imageId
    readRoots
    nullDevice
    (pure True)

observeRecordedConfinedKindInventoryWith
  :: Int
  -> KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> String
  -> Integer
  -> String
  -> [Fd]
  -> Fd
  -> IO Bool
  -> IO RecordedConfinedKindInventory
observeRecordedConfinedKindInventoryWith limit placement budgets limits bootstrap operation clientDigest clientMaximum imageId readRoots nullDevice externalStable = do
  recorded <- observeRecordedNodeImageIdentity bootstrap operation
  case recorded of
    NodeImageIdentityObserved intent expected@(DockerDaemonObserved _ _)
      | nodeImageIntentConfigDigest intent /= imageId -> pure ConfinedImageRecordConfigMismatch
      | otherwise -> do
          let stable =
                (&&) <$> externalStable <*> ((== recorded) <$> observeRecordedNodeImageIdentity bootstrap operation)
          result <-
            observeConnectedConfinedKindInventoryOnHost
              limit
              placement
              budgets
              limits
              bootstrap
              operation
              clientDigest
              clientMaximum
              imageId
              readRoots
              nullDevice
              expected
              stable
          pure (ConfinedImageRecordObserved result)
    NodeImageIdentityObserved _ _ -> pure (ConfinedImageRecordRefused NodeImageIntentUnobservable)
    NodeImageIdentityRefused failure -> pure (ConfinedImageRecordRefused failure)

-- | Bind the read-only inventory to one held connection and an independently
-- supplied expected daemon/socket observation. The record recheck must bind
-- that expectation to the operation; matching identities do not authenticate
-- a daemon, exclude a proxy, authorize effects or settle prior work.
observeConnectedConfinedKindInventoryOnHost
  :: Int
  -> KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> String
  -> Integer
  -> String
  -> [Fd]
  -> Fd
  -> DockerDaemonObservation
  -> IO Bool
  -> IO (DockerPeerResult (DockerConnectedInfoResult ConnectedConfinedKindInventory))
observeConnectedConfinedKindInventoryOnHost limit placement budgets limits bootstrap operation clientDigest clientMaximum imageId readRoots nullDevice expected expectedStable =
  withConnectedDockerInfo limit (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ socket)) peerStable -> do
    let actual = DockerDaemonObserved identifier socket
        stable = (&&) <$> expectedStable <*> peerStable
    if actual /= expected
      then pure (ConfinedDockerIdentityMismatch actual)
      else do
        ready <- stable
        if not ready
          then pure ConfinedDockerBindingUnavailable
          else do
            value <-
              observeVerifiedConfinedKindInventoryOnHost
                placement
                budgets
                limits
                bootstrap
                operation
                clientDigest
                clientMaximum
                imageId
                readRoots
                nullDevice
                session
                identifier
                stable
            after <- try stable
            pure $ case after of
              Right True -> ConfinedDockerBindingObserved value
              (_ :: Either IOException Bool) -> ConfinedDockerBindingChanged value

-- | Compose the authenticated snapshots with the read-only managed inventory.
-- The caller still authenticates the held Docker session and image, binds and
-- isolates all roots, and provides admission, budgets and recovery. An
-- unstable final artifact observation never authorizes an inventory result.
observeVerifiedConfinedKindInventoryOnHost
  :: KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> String
  -> Integer
  -> String
  -> [Fd]
  -> Fd
  -> DockerSession
  -> String
  -> IO Bool
  -> IO
       ( ConfinedKindSnapshotsObservation
           (KindOperationOutcome (KindDockerEndpointResult ConfinedKindInventory))
       )
observeVerifiedConfinedKindInventoryOnHost placement budgets limits bootstrap operation clientDigest clientMaximum imageId readRoots nullDevice session daemon peerStable =
  withConfinedKindSnapshots budgets bootstrap clientDigest clientMaximum $ \kind client artifactStable ->
    observeConfinedKindInventoryOnHost
      placement
      budgets
      limits
      bootstrap
      operation
      imageId
      readRoots
      nullDevice
      kind
      client
      session
      daemon
      ((&&) <$> artifactStable <*> peerStable)

-- | Observe only the selected cluster through the confined, managed kind
-- worker and the scoped read broker. The retained operation and its worker
-- roots are reacquired and rechecked for the duration. The caller must first
-- authenticate both sealed snapshots and the held Docker session, bind the
-- image ID to its archive, prove all supplied read roots disjoint from scratch,
-- fund and bound the worker, exclude other writers and settle prior workers.
-- Both returned outcomes must be inspected; neither is an absence proof. The
-- link is removed only after a confirmed managed worker result and broker
-- cancellation with a clear marker; all other retained state needs recovery.
observeConfinedKindInventoryOnHost
  :: KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> String
  -> [Fd]
  -> Fd
  -> Fd
  -> Fd
  -> DockerSession
  -> String
  -> IO Bool
  -> IO (KindOperationOutcome (KindDockerEndpointResult ConfinedKindInventory))
observeConfinedKindInventoryOnHost placement budgets limits bootstrap operation imageId readRoots nullDevice kind client session daemon peerStable =
  withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots rootsStable -> do
    let stable = (&&) <$> rootsStable <*> peerStable
        worker = scopeRoot (bootstrapScope bootstrap) </> ("kind-worker-" ++ operation)
        scratch = worker </> "scratch"
        bridge = worker </> "bridge"
        environment =
          [ ("PATH", bridge ++ ":/usr/bin:/bin")
          , ("HOME", scratch)
          , ("TMPDIR", scratch)
          , ("DOCKER_CONFIG", scratch)
          , ("KUBECONFIG", scratch </> "kubeconfig")
          , ("KIND_EXPERIMENTAL_PROVIDER", "docker")
          , ("PRODBOX_KIND_BRIDGE", bridge)
          ]
        command = Subprocess ("/proc/self/fd/" ++ show kind) ["get", "clusters"] (Just environment) (Just scratch)
    case mkKindWorkerSandbox
      (workerScratch roots)
      (workerBridge roots : readRoots)
      (workerLock roots)
      (workerRequest roots)
      (workerReply roots)
      nullDevice of
      Nothing -> pure ConfinedKindInventoryInvalidSandbox
      Just sandbox -> do
        created <- newKindInventoryReadGate (bootstrapScope bootstrap) imageId
        case created of
          Nothing -> pure ConfinedKindInventoryInvalidGate
          Just gate -> do
            ready <- kindWorkerSandboxReady sandbox kind client
            if not ready
              then pure ConfinedKindInventoryInvalidDescriptors
              else do
                link <- prepareKindDockerClientLink roots client stable
                if link /= KindDockerClientLinkPrepared
                  then pure (ConfinedKindInventoryLink link)
                  else do
                    (broker, child) <-
                      runBoundKindDockerReadWorker (workerBridge roots) stable gate session daemon $
                        withPreparedConfinedKindHostSubprocess placement budgets sandbox kind client limits $ \run ->
                          run ByteString.empty command
                    inventoryObserved <- kindDockerInventoryObserved gate
                    marker <- observeKindDockerMarker (workerLock roots)
                    removal <- case (broker, child, marker) of
                      (KindDockerBrokerCancelled, KindDockerWorkerReturned (Right _), KindDockerMarkerClear) ->
                        Just <$> removeKindDockerClientLink roots client stable
                      _ -> pure Nothing
                    pure (ConfinedKindInventoryObserved broker child inventoryObserved marker removal)

-- | Pair the retained node proposal and broker with one confined kind worker.
-- The caller must authenticate both sealed tools and the held daemon session,
-- bind the image and network to independent observations, establish admission,
-- exclude other writers, settle previous work and own exact recovery. A result
-- is not proof of resource ownership or readiness. The client link and worker
-- roots are intentionally retained for a separately proven recovery path.
runConfinedKindNodeOnHost
  :: KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> [Fd]
  -> Fd
  -> Fd
  -> Fd
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO (KindOperationOutcome (KindDockerEndpointResult ConfinedKindNodeAttempt))
runConfinedKindNodeOnHost placement budgets limits bootstrap operation readRoots nullDevice kind client session info peerStable admitCreate admitStart =
  withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots rootsStable -> do
    let stable = (&&) <$> rootsStable <*> peerStable
        worker = scopeRoot (bootstrapScope bootstrap) </> ("kind-worker-" ++ operation)
        scratch = worker </> "scratch"
        environment = kindNodeWorkerEnvironment bootstrap operation
        command =
          Subprocess
            ("/proc/self/fd/" ++ show kind)
            ["create", "cluster", "--config", "-", "--retain"]
            (Just environment)
            (Just scratch)
    proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
    case proposal of
      NodeCreateRecoveryRecorded intent -> case bootstrapKindTool bootstrap of
        Just declaration | artifactDigest declaration == nodeCreateToolDigest (kindNodeCreateInput intent) ->
          case renderKindConfigWithLocalImageId
            (bootstrapKindPlan bootstrap)
            (nodeCreateImageId (kindNodeCreateInput intent)) of
            Nothing -> pure ConfinedNodeInvalidConfig
            Just configuration -> case mkKindWorkerSandbox
              (workerScratch roots)
              (workerBridge roots : readRoots)
              (workerLock roots)
              (workerRequest roots)
              (workerReply roots)
              nullDevice of
              Nothing -> pure ConfinedNodeInvalidSandbox
              Just sandbox -> do
                ready <- kindWorkerSandboxReady sandbox kind client
                if not ready
                  then pure ConfinedNodeInvalidDescriptors
                  else do
                    broker <- newKindNodeBroker bootstrap operation session info stable admitCreate admitStart
                    case broker of
                      Nothing -> pure ConfinedNodeBrokerRefused
                      Just owner -> do
                        link <- prepareKindDockerClientLink roots client stable
                        if link /= KindDockerClientLinkPrepared
                          then pure (ConfinedNodeLink link)
                          else do
                            (brokerResult, childResult) <-
                              runBoundKindNodeWorker (workerBridge roots) stable owner $
                                withPreparedConfinedKindHostSubprocess placement budgets sandbox kind client limits $ \run ->
                                  run (LazyByteString.toStrict configuration) command
                            nodeResult <- observeKindNodeBrokerResult owner
                            marker <- observeKindDockerMarker (workerLock roots)
                            pure (ConfinedNodeObserved brokerResult childResult nodeResult marker)
        _ -> pure ConfinedNodeToolMismatch
      other -> pure (ConfinedNodeProposalRefused other)

-- | Project the explicit, scope-bound worker environment. This does not
-- validate the operation or authorize execution.
kindNodeWorkerEnvironment :: BootstrapProjection -> String -> [(String, String)]
kindNodeWorkerEnvironment bootstrap operation =
  [ ("PATH", bridge ++ ":/usr/bin:/bin")
  , ("HOME", scratch)
  , ("TMPDIR", scratch)
  , ("DOCKER_CONFIG", scratch)
  , ("KUBECONFIG", scratch </> "kubeconfig")
  , ("KIND_EXPERIMENTAL_PROVIDER", "docker")
  , ("KIND_EXPERIMENTAL_DOCKER_NETWORK", scopeKindName (bootstrapScope bootstrap))
  , ("PRODBOX_KIND_BRIDGE", bridge)
  ]
 where
  worker = scopeRoot (bootstrapScope bootstrap) </> ("kind-worker-" ++ operation)
  scratch = worker </> "scratch"
  bridge = worker </> "bridge"

-- | Hold both verified snapshots throughout the managed node attempt and
-- retain the artifact-stability observation with its result. The caller must
-- still authenticate the daemon, bind image and network ownership, provide
-- admission, settle workers, and recover every possible effect.
runVerifiedConfinedKindNodeOnHost
  :: KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> String
  -> Integer
  -> [Fd]
  -> Fd
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO
       ( ConfinedKindSnapshotsObservation
           (KindOperationOutcome (KindDockerEndpointResult ConfinedKindNodeAttempt))
       )
runVerifiedConfinedKindNodeOnHost placement budgets limits bootstrap operation clientDigest clientMaximum readRoots nullDevice session info peerStable admitCreate admitStart =
  withConfinedKindSnapshots budgets bootstrap clientDigest clientMaximum $ \kind client artifactStable ->
    runConfinedKindNodeOnHost
      placement
      budgets
      limits
      bootstrap
      operation
      readRoots
      nullDevice
      kind
      client
      session
      info
      ((&&) <$> artifactStable <*> peerStable)
      admitCreate
      admitStart

-- | Compare the retained load attempt and receipt with a fresh exact-image
-- read on the held session. A matching point observation does not authenticate
-- the daemon, establish ownership, or settle the load worker.
observeConfinedNodeImage
  :: BootstrapProjection
  -> String
  -> VerifiedNodeArchive
  -> DockerSession
  -> IO Bool
  -> IO ConfinedNodeImageObservation
observeConfinedNodeImage bootstrap operation archive session stable = do
  ready <- stable
  if not ready
    then pure ConfinedNodeImageChanged
    else do
      attempt <- observeRecordedNodeImageAttempt bootstrap operation
      if attempt /= NodeImageAttemptMatches
        then pure (ConfinedNodeImageAttemptRefused attempt)
        else do
          receipt <- observeRecordedNodeImageResult bootstrap operation
          case receipt of
            NodeImageResultObserved (DockerImageLoadReply 200 (DockerImageLoadMessages _)) -> do
              image <- inspectDockerSessionImage session (nodeConfigDigest archive)
              case image of
                Right (ImageIdObserved "linux" architecture _) | architecture == nodeArchitecture archive -> do
                  finalAttempt <- observeRecordedNodeImageAttempt bootstrap operation
                  finalReceipt <- observeRecordedNodeImageResult bootstrap operation
                  final <- stable
                  pure $
                    if final && finalAttempt == attempt && finalReceipt == receipt
                      then ConfinedNodeImageReady
                      else ConfinedNodeImageChanged
                _ -> pure (ConfinedNodeImageMetadataRefused image)
            _ -> pure (ConfinedNodeImageResultRefused receipt)

-- | Require the exact recorded create receipt, no removal attempt, and a
-- fresh held-session inventory and configuration read-back for the proposed
-- node network. These are point observations, not daemon authentication,
-- ownership, independent absence, or settlement of a prior worker.
observeConfinedNodeNetwork
  :: BootstrapProjection
  -> String
  -> String
  -> DockerDaemonObservation
  -> DockerSession
  -> IO Bool
  -> IO ConfinedNodeNetworkObservation
observeConfinedNodeNetwork bootstrap operation networkId expected session stable = do
  proposal <- observeRecordedKindNetworkIntent bootstrap operation stable
  case proposal of
    NetworkRecoveryRecorded intent
      | kindNetworkDaemon intent /= expected -> pure ConfinedNodeNetworkDaemonMismatch
      | otherwise -> do
          attempt <- observeKindNetworkAttempt bootstrap intent stable
          if attempt /= NetworkAttemptMatches
            then pure (ConfinedNodeNetworkAttemptRefused attempt)
            else do
              receipt <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
              if receipt
                /= NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just networkId)))
                then pure (ConfinedNodeNetworkReceiptRefused receipt)
                else do
                  removal <- observeKindNetworkRemoval bootstrap intent networkId stable
                  if removal /= NetworkRemovalMissing
                    then pure (ConfinedNodeNetworkRemovalRefused removal)
                    else do
                      inventory <- readDockerSessionKindNetworks session (bootstrapScope bootstrap)
                      if inventory /= Right [networkId]
                        then pure (ConfinedNodeNetworkInventoryRefused inventory)
                        else do
                          details <- inspectDockerSessionKindNetwork session (bootstrapScope bootstrap) networkId
                          case details of
                            Left failure -> pure (ConfinedNodeNetworkDetailsRefused (Just failure))
                            Right observed
                              | compareKindNetworkConfiguration bootstrap intent observed /= NetworkConfigurationMatches ->
                                  pure (ConfinedNodeNetworkDetailsRefused Nothing)
                              | otherwise -> do
                                  current <- observeRecordedKindNetworkIntent bootstrap operation stable
                                  finalAttempt <- observeKindNetworkAttempt bootstrap intent stable
                                  finalReceipt <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
                                  finalRemoval <- observeKindNetworkRemoval bootstrap intent networkId stable
                                  ready <- stable
                                  pure $
                                    if ready
                                      && current == proposal
                                      && finalAttempt == attempt
                                      && finalReceipt == receipt
                                      && finalRemoval == removal
                                      then ConfinedNodeNetworkReady
                                      else ConfinedNodeNetworkChanged
    other -> pure (ConfinedNodeNetworkProposalRefused other)

-- | Hold and inspect the selected node archive, bind its digests to the image
-- record and node proposal, and recheck those observations with the held
-- Docker session throughout the verified worker. These observations do not
-- authenticate a daemon, prove a prior load settled, admit an effect, or
-- establish resource ownership. The caller remains responsible for those
-- obligations and for recovery and cleanup.
runArchiveBoundConfinedKindNodeOnHost
  :: Int
  -> KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> OwnedSubprocessLimits
  -> BootstrapProjection
  -> String
  -> String
  -> Integer
  -> [Fd]
  -> Fd
  -> (KindNodeCreateIntent -> DockerSession -> IO Bool -> IO Bool)
  -> (KindNodeCreateIntent -> String -> DockerSession -> IO Bool -> IO Bool)
  -> IO (InspectedArchiveResult ArchiveBoundConfinedKindNode)
runArchiveBoundConfinedKindNodeOnHost limit placement budgets limits bootstrap operation clientDigest clientMaximum readRoots nullDevice admitCreate admitStart =
  withInspectedNodeArchive bootstrap $ \archive _ archiveStable -> do
    imageRecord <- observeRecordedNodeImageIdentity bootstrap operation
    case imageRecord of
      NodeImageIdentityRefused failure -> pure (ConfinedNodeImageRecordRefused failure)
      NodeImageIdentityObserved imageIntent expected@(DockerDaemonObserved _ _)
        | nodeImageIntentManifestDigest imageIntent /= nodeManifestDigest archive
            || nodeImageIntentConfigDigest imageIntent /= nodeConfigDigest archive ->
            pure ConfinedNodeImageRecordMismatch
        | otherwise -> do
            let imageStable =
                  (&&)
                    <$> archiveStable
                    <*> ((== imageRecord) <$> observeRecordedNodeImageIdentity bootstrap operation)
            proposal <- observeRecordedKindNodeCreateIntent bootstrap operation imageStable
            case proposal of
              NodeCreateRecoveryRecorded nodeIntent
                | kindNodeCreateDaemon nodeIntent /= expected
                    || nodeCreateImageId (kindNodeCreateInput nodeIntent) /= nodeConfigDigest archive ->
                    pure ConfinedNodeProposalMismatch
                | otherwise -> do
                    let recordStable =
                          (&&)
                            <$> imageStable
                            <*> ((== proposal) <$> observeRecordedKindNodeCreateIntent bootstrap operation imageStable)
                    ConfinedNodeConnected
                      <$> withConnectedDockerInfo
                        limit
                        (bootstrapRuntimeSocket bootstrap)
                        (connected archive expected nodeIntent recordStable)
              other -> pure (ConfinedNodeProposalUnavailable other)
      NodeImageIdentityObserved _ _ -> pure ConfinedNodeImageRecordMismatch
 where
  connected archive expected nodeIntent recordStable session info@(DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable = do
    let actual = DockerDaemonObserved identifier identity
        stable = (&&) <$> recordStable <*> peerStable
    if actual /= expected
      then pure (ConfinedNodeDaemonMismatch actual)
      else do
        ready <- stable
        if not ready
          then pure ConfinedNodeBindingUnavailable
          else do
            image <- observeConfinedNodeImage bootstrap operation archive session stable
            if image /= ConfinedNodeImageReady
              then pure (ConfinedNodeImageRefused image)
              else checkNetwork archive expected nodeIntent session info stable
  checkNetwork archive expected nodeIntent session info stable = do
    let networkId = nodeCreateNetworkId (kindNodeCreateInput nodeIntent)
    network <- observeConfinedNodeNetwork bootstrap operation networkId expected session stable
    if network /= ConfinedNodeNetworkReady
      then pure (ConfinedNodeNetworkRefused network)
      else do
        let networkStable = do
              image <- observeConfinedNodeImage bootstrap operation archive session stable
              if image /= ConfinedNodeImageReady
                then pure False
                else
                  (== ConfinedNodeNetworkReady)
                    <$> observeConfinedNodeNetwork bootstrap operation networkId expected session stable
        result <-
          runVerifiedConfinedKindNodeOnHost
            placement
            budgets
            limits
            bootstrap
            operation
            clientDigest
            clientMaximum
            readRoots
            nullDevice
            session
            info
            networkStable
            admitCreate
            admitStart
        after <- try networkStable
        pure $ case after of
          Right True -> ConfinedNodeBindingObserved result
          (_ :: Either IOException Bool) -> ConfinedNodeBindingChanged result

-- | Execute only `version`, using a digest-verified sealed snapshot and a
-- caller's bounded cgroup-owned subprocess budget. The final Boolean reports
-- whether the retained path and bytes remained stable during the attempt.
observeKindToolVersion
  :: OwnedSubprocessLimits -> SealedToolBudget -> BootstrapProjection -> IO KindToolObservation
observeKindToolVersion limits = observeKindToolVersionWith (captureOwnedSubprocess limits)

-- | Use the already observed parent placement and its single child slot for
-- the whole verified snapshot lifetime. This read-only observation still
-- does not authorize a cluster operation or establish measured headroom.
observeKindToolVersionOnHost
  :: KindHostSubprocessPlacement
  -> OwnedSubprocessLimits
  -> SealedToolBudget
  -> BootstrapProjection
  -> IO (Either HostSubprocessError KindToolObservation)
observeKindToolVersionOnHost placement limits budget bootstrap =
  withPreparedKindHostSubprocess placement (sealedToolRuntimePlan budget) limits $ \run -> do
    observed <- observeKindToolVersionWith run budget bootstrap
    pure $ case observed of
      KindToolAttempted (KindToolProcessRefused failure) _ -> Left failure
      other -> Right other

-- | Read kind's inventory using the explicitly selected Docker socket. A
-- negative result is one provider observation, not proof of cluster absence.
observeKindToolClusterOnHost
  :: KindHostSubprocessPlacement
  -> OwnedSubprocessLimits
  -> SealedToolBudget
  -> BootstrapProjection
  -> IO (Either HostSubprocessError KindToolObservation)
observeKindToolClusterOnHost placement limits budget bootstrap =
  withPreparedKindHostSubprocess placement (sealedToolRuntimePlan budget) limits $ \run -> do
    observed <- observeKindToolWith KindClusterInventory run budget bootstrap
    pure $ case observed of
      KindToolAttempted (KindToolProcessRefused failure) _ -> Left failure
      other -> Right other

observeKindToolVersionWith
  :: (Subprocess -> IO (Either OwnedSubprocessError ProcessOutput))
  -> SealedToolBudget
  -> BootstrapProjection
  -> IO KindToolObservation
observeKindToolVersionWith = observeKindToolWith KindVersion

data KindToolRequest = KindVersion | KindClusterInventory

observeKindToolWith
  :: KindToolRequest
  -> (Subprocess -> IO (Either OwnedSubprocessError ProcessOutput))
  -> SealedToolBudget
  -> BootstrapProjection
  -> IO KindToolObservation
observeKindToolWith request run budget bootstrap = case bootstrapKindTool bootstrap of
  Nothing -> pure KindToolNotDeclared
  Just declaration -> do
    generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration bootstrap))
    if generation /= Right ScopeGenerationMatches
      then pure KindToolGenerationUnavailable
      else do
        attempted <- try
          $ withVerifiedScopeArtifact
            scope
            (artifactPath declaration)
            (artifactDigest declaration)
            (artifactMaximumBytes declaration)
          $ \descriptor stable -> do
            status <- getFdStatus descriptor
            if fileMode status .&. 0o100 == 0
              then pure KindToolNotExecutable
              else do
                ready <- stable
                if not ready
                  then pure KindToolChangedBeforeRun
                  else do
                    sealed <- withSealedTool budget descriptor (artifactDigest declaration) (artifactMaximumBytes declaration) $ \snapshot -> do
                      stillReady <- stable
                      if not stillReady
                        then pure KindToolChangedBeforeRun
                        else do
                          parent <- getProcessID
                          let Fd number = snapshot
                              executable = "/proc/" ++ show parent ++ "/fd/" ++ show number
                              command =
                                Subprocess
                                  executable
                                  (arguments request)
                                  (Just (environment request))
                                  Nothing
                          result <- run command
                          pure $ case result of
                            Left failure -> KindToolProcessRefused failure
                            Right output -> case processExitCode output of
                              ExitFailure code -> KindToolExitFailure code
                              ExitSuccess -> interpret request (processStdout output)
                    pure (either KindToolSealRefused id sealed)
        pure $ case attempted of
          Left (_ :: IOException) -> KindToolUnobservable
          Right (Left _) -> KindToolUnobservable
          Right (Right (HeldArtifactRefused failure)) -> KindToolArtifactRefused failure
          Right (Right (HeldArtifactObserved attempt stable)) -> KindToolAttempted attempt stable
 where
  scope = bootstrapScope bootstrap
  arguments KindVersion = ["version"]
  arguments KindClusterInventory = ["get", "clusters"]
  environment KindVersion = [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
  environment KindClusterInventory =
    environment KindVersion
      ++ [ ("DOCKER_HOST", "unix://" ++ bootstrapRuntimeSocket bootstrap)
         , ("KIND_EXPERIMENTAL_PROVIDER", "docker")
         ]
  interpret KindVersion output = case lines output of
    [line] | validVersion line -> KindToolVersion line
    _ -> KindToolInvalidVersion
  interpret KindClusterInventory output =
    maybe
      KindToolInvalidClusterList
      KindToolClusterListed
      (parseKindClusterList (scopeKindName scope) output)
  validVersion line =
    "kind v" `isPrefixOf` line
      && length line <= 128
      && all (\character -> isAscii character && isPrint character) line

-- | Decode bounded `kind get clusters` output without publishing other names.
-- Even a valid negative result is not an independent absence proof.
parseKindClusterList :: String -> String -> Maybe Bool
parseKindClusterList selected output =
  let names = lines output
   in if validName selected && all validName names && length names == Set.size (Set.fromList names)
        then Just (selected `elem` names)
        else Nothing
 where
  validName name = case name of
    [] -> False
    first : rest ->
      length name <= 63
        && edge first
        && edge (foldl (\_ character -> character) first rest)
        && all (\character -> edge character || character == '-') name
  edge character = isAsciiLower character || (isDigit character && character >= '0' && character <= '9')
