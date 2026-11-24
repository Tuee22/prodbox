{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Read-only, partial observations of the local kind control candidate.
-- None of these observations is lifecycle admission or cloud absence proof.
module Prodbox.Control.Status
  ( ControlObservation (..)
  , ControlStatusError (..)
  , RuntimeObservation (..)
  , RuntimeInventoryDecision (..)
  , ImageObservation (..)
  , ImageIdObservation (..)
  , ImageArchiveComparison (..)
  , HostCapacityObservation (..)
  , HostHeadroomObservation (..)
  , KubernetesVolumeObservation (..)
  , chooseRuntimeCandidate
  , observeRuntimeInventory
  , observeControl
  , matchesRunningWorkerNode
  , observeNodeCreateUnderLease
  , observeNodeCaBindingUnderLease
  , matchesScopedWorkerNode
  , NodeCreateStatus (..)
  , matchesNodeCreateStatus
  , observeImage
  , observeImageId
  , compareImageArchive
  , parseNodeObservation
  , parseImageObservation
  , parseImageIdObservation
  , renderControlObservation
  , renderControlStatusError
  )
where

import Control.Exception (IOException, try)
import Control.Monad (void)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.ByteString.Char8 qualified as ByteString
import Data.Char (isAsciiLower, isDigit)
import Data.List (nub, sort)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Capacity.Config (ResourceVector (..))
import Prodbox.Capacity.NativeHostProbe
  ( NativeHostHeadroom (..)
  , observeNativeHostCapacityBefore
  , observeNativeHostHeadroomBefore
  )
import Prodbox.Capacity.ObservedHost (observedHostVector, observedStorageDevicesCoincide)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapKindTool
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentScope
  , ScopeArtifactObservation (..)
  , ScopeGenerationObservation (..)
  , ScopeRootObservation (..)
  , observeScopeArtifact
  , observeScopeGeneration
  , observeScopeRoot
  , scopeKindName
  , scopeRoot
  , withObservedScopeRoot
  )
import Prodbox.Config.KindPlan (kindPlanNodeImage)
import Prodbox.Config.KindVolume
  ( KindVolumeObservation (..)
  , kindVolumeName
  , observeKindVolumeDirectory
  )
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoFailure (..)
  , DockerConnectedInfoResult (..)
  , DockerNetworkCreateResult (..)
  , DockerNetworkRemoveResult (..)
  , DockerNodeConfigWriteResult (..)
  , DockerNodeConfigReadback (..)
  , DockerNodeContainerCreateResult (..)
  , DockerNodeContainerObservation (..)
  , DockerNodeContainerRemoveResult (..)
  , DockerNodeContainerStartResult (..)
  , DockerNodeVarCreateResult (..)
  , DockerNodeVarRemoveResult (..)
  , DockerNodeVarVolumeObservation (..)
  , inspectDockerSessionKindNode
  , inspectDockerSessionNodeVarVolume
  , readDockerSessionKindNodeCa
  , observeConnectedDockerInfo
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , observeDockerDaemon
  , readDocker
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..), observeDockerPeer)
import Prodbox.Control.ImageIdObservation
  ( ImageIdObservation (..)
  , parseImageIdObservation
  , validImageId
  )
import Prodbox.Control.KindIntent (KindIntentObservation (..), observeKindIntent)
import Prodbox.Control.KindKubeconfig
  ( KindKubeconfig
  , kindKubeconfigContext
  , kindKubeconfigScope
  , kindKubeconfigServer
  , withKindKubeconfigMaterial
  )
import Prodbox.Control.KindKubeconfigFile (KindKubeconfigFileError, readKindKubeconfig)
import Prodbox.Control.KindKubernetesRead
  ( KindKubernetesReaderError
  , observeKindKubernetesVolumeBinding
  )
import Prodbox.Control.KindLease (KindOperationOutcome (..), withRecoveredKindOperation)
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkAttemptObservation (..)
  , KindNetworkRecoveryObservation (..)
  , KindNetworkRemovalRecovery (..)
  )
import Prodbox.Control.KindNetworkReceipt (NetworkReceiptObservation (..), NetworkTransport (..))
import Prodbox.Control.KindNetworkRecovery
  ( KindNetworkConfigurationObservation (..)
  , KindNetworkIndependentIdObservation (..)
  , KindNetworkIndependentObservation (..)
  , KindNetworkRecoveryResult (..)
  , KindNetworkRecoverySample (..)
  , observeRecoveredKindNetwork
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCandidateObservation (..)
  , KindNodeConfigAttemptObservation (..)
  , KindNodeConfigResultObservation (..)
  , KindNodeCreateAttemptObservation (..)
  , KindNodeCreateRecoveryObservation (..)
  , KindNodeCreateResultObservation (..)
  , KindNodeRemoveAttemptObservation (..)
  , KindNodeRemoveControlObservation (..)
  , KindNodeRemoveResultObservation (..)
  , KindNodeStartAttemptObservation (..)
  , KindNodeStartResultObservation (..)
  , kindNodeCreateDaemon
  , kindNodeCreateInput
  , observeKindNodeConfigAttempt
  , observeKindNodeConfigResult
  , observeKindNodeCreateAttempt
  , observeKindNodeCreateResult
  , observeKindNodeRemoveAttempt
  , observeKindNodeRemoveControl
  , observeKindNodeRemoveResult
  , observeKindNodeStartAttempt
  , observeKindNodeStartResult
  , observeRecordedKindNodeCandidate
  , observeRecordedKindNodeCreateIntent
  )
import Prodbox.Control.KindNodeCreateReadback
  ( NodeCreateCandidate (..)
  , NodeCreateReadback (..)
  , observeIndependentNodeCreateCandidate
  )
import Prodbox.Control.KindNodeRemovalReadback
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , observeIndependentNodeRemoval
  )
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeAttemptObservation (..)
  , KindNodeVolumeIntentObservation (..)
  , KindNodeVolumeReceiptObservation (..)
  , KindNodeVolumeRemovalObservation (..)
  , KindNodeVolumeRemovalReceiptObservation (..)
  , mkKindNodeVolumeIntent
  , observeKindNodeVolumeAttempt
  , observeKindNodeVolumeIntent
  , observeKindNodeVolumeReceipt
  , observeKindNodeVolumeRemoval
  , observeKindNodeVolumeRemovalReceipt
  )
import Prodbox.Control.KindNodeVolumeReadback
  ( NodeVolumeInventory (..)
  , NodeVolumeReadback (..)
  , observeIndependentNodeVolume
  )
import Prodbox.Control.KindVolumeReadback
  ( KindVolumeBindingObservation (..)
  , KindVolumeBracketObservation (..)
  )
import Prodbox.Control.NodeImageIntent
  ( NodeImageAttemptObservation (..)
  , NodeImageIntentObservation (..)
  , observeRecordedNodeImageAttempt
  , observeRecordedNodeImageIntent
  )
import System.Info qualified as SystemInfo
import System.Posix.Files (getSymbolicLinkStatus, isSocket)

data RuntimeObservation
  = RuntimeUnobservable !ControlStatusError
  | RuntimeNoMatchesObserved
  | RuntimeInventoryChanged
  | RuntimeForeignOrMultiple
  | RuntimeNodeObserved !Bool !Bool
  deriving (Eq, Show)

data RuntimeInventoryDecision
  = InventoryNoMatches
  | InventoryChanged
  | InventoryForeignOrMultiple
  | InventoryCandidate !String
  deriving (Eq, Show)

data ImageObservation
  = ImageUnobservable
  | ImageObserved !Bool !String !String !String
  deriving (Eq, Show)

data ImageArchiveComparison
  = ImageArchiveUnobservable
  | ImageArchiveConfigMatches
  | ImageArchiveDescriptorMatches
  | ImageArchiveMetadataDiffers
  deriving (Eq, Show)

-- This compares independent, non-atomic metadata observations. It does not
-- authenticate the daemon, prove loadability or grant lifecycle admission.
compareImageArchive
  :: String -> String -> String -> String -> ImageObservation -> ImageArchiveComparison
compareImageArchive selectedDigest manifestDigest configDigest architecture observation = case observation of
  ImageUnobservable -> ImageArchiveUnobservable
  ImageObserved repoMatches imageId os imageArchitecture ->
    if not repoMatches || os /= "linux" || imageArchitecture /= architecture
      then ImageArchiveMetadataDiffers
      else
        if imageId == configDigest
          then ImageArchiveConfigMatches
          else
            if imageId == selectedDigest || imageId == manifestDigest
              then ImageArchiveDescriptorMatches
              else ImageArchiveMetadataDiffers

data HostCapacityObservation
  = HostCapacityUnobservable
  | HostCapacityObserved !ResourceVector !Bool
  deriving (Eq, Show)

data HostHeadroomObservation = HostHeadroomUnobservable | HostHeadroomObserved !NativeHostHeadroom
  deriving (Eq, Show)

data KubernetesVolumeObservation
  = KubernetesVolumeNotObserved
  | KubernetesVolumeInputsChanged
  | KubernetesVolumeObserved !(Either KindKubernetesReaderError KindVolumeBracketObservation)
  deriving (Eq, Show)

data ControlStatusError
  = ControlRootUnobservable
  | ControlRuntimeSocketUnobservable
  | ControlRuntimeCommandFailed
  | ControlRuntimeResponseInvalid
  deriving (Eq, Show)

data NodeCreateStatus
  = NodeCreateStatus
      !KindNodeCreateRecoveryObservation
      !Bool
      !(Maybe KindNodeCreateAttemptObservation)
      !(Maybe KindNodeCreateResultObservation)
      !(Maybe KindNodeStartAttemptObservation)
      !(Maybe KindNodeStartResultObservation)
      !(Maybe KindNodeRemoveControlObservation)
      !(Maybe KindNodeRemoveAttemptObservation)
      !(Maybe KindNodeRemoveResultObservation)
      !(Maybe (Either DockerConnectedInfoFailure DockerNodeContainerObservation))
  deriving (Eq, Show)

data NodeConfigRecordStatus
  = NodeConfigRecordUnavailable
  | NodeConfigRecordObserved !KindNodeConfigAttemptObservation !(Maybe KindNodeConfigResultObservation)
  deriving (Eq, Show)

data ControlObservation = ControlObservation
  { controlScopeName :: !String
  , controlRoot :: !FilePath
  , controlRootPresent :: !Bool
  , controlGeneration :: !(Maybe ScopeGenerationObservation)
  , controlArtifact :: !(Maybe ScopeArtifactObservation)
  , controlKindTool :: !(Maybe ScopeArtifactObservation)
  , controlIntent :: !(Maybe KindIntentObservation)
  , controlImageIntent :: !(Maybe NodeImageIntentObservation)
  , controlImageAttempt :: !(Maybe NodeImageAttemptObservation)
  , controlNetworkRecovery
      :: !( Maybe
              (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNetworkRecoveryResult)))
          )
  , controlNodeVarVolume
      :: !( Maybe
              ( KindOperationOutcome
                  ( DockerPeerResult
                      ( DockerConnectedInfoResult
                          ( Either
                              DockerConnectedInfoFailure
                              ( DockerNodeVarVolumeObservation
                              , KindNodeVolumeIntentObservation
                              , Maybe KindNodeVolumeAttemptObservation
                              , Maybe KindNodeVolumeReceiptObservation
                              , Maybe KindNodeVolumeRemovalObservation
                              , Maybe KindNodeVolumeRemovalReceiptObservation
                              )
                          )
                      )
                  )
              )
          )
  , controlNodeCreate
      :: !( Maybe
              ( KindOperationOutcome
                  (DockerPeerResult (DockerConnectedInfoResult NodeCreateStatus))
              )
          )
  , controlNodeCandidateRecord :: !(Maybe (KindOperationOutcome KindNodeCandidateObservation))
  , controlNodeConfigRecord :: !(Maybe (KindOperationOutcome NodeConfigRecordStatus))
  , controlNodeCreateReadback
      :: !(Maybe (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult NodeCreateReadback))))
  , controlNodeVarReadback :: !(Maybe (KindOperationOutcome NodeVolumeReadback))
  , controlNodeRemovalReadback :: !(Maybe (KindOperationOutcome NodeRemovalReadback))
  , controlVolume :: !(Maybe KindVolumeObservation)
  , controlKubernetesVolume :: !KubernetesVolumeObservation
  , controlKubeconfig :: !(Maybe (Either KindKubeconfigFileError ()))
  , controlHostCapacity :: !(Maybe HostCapacityObservation)
  , controlHostHeadroom :: !(Maybe HostHeadroomObservation)
  , controlDaemon :: !DockerDaemonObservation
  , controlDockerPeer :: !(DockerPeerResult DockerPeer)
  , controlConnectedInfo :: !(DockerPeerResult (DockerConnectedInfoResult DockerConnectedInfo))
  , controlRuntime :: !RuntimeObservation
  , controlImage :: !ImageObservation
  }
  deriving (Eq, Show)

-- A single observation of the exact recorded node and daemon. It is not a
-- substitute for worker settlement or a durable readiness guarantee.
matchesRunningWorkerNode :: String -> ControlObservation -> Bool
matchesRunningWorkerNode identifier observed = case controlNodeCreate observed of
  Just
    ( KindOperationCallbackReturned
        ( DockerPeerCompleted
            (DockerConnectedInfoCompleted status)
          )
      ) -> matchesNodeCreateStatus identifier status
  _ -> False

matchesScopedWorkerNode :: String -> DockerPeerResult (DockerConnectedInfoResult NodeCreateStatus) -> Bool
matchesScopedWorkerNode identifier observed = case observed of
  DockerPeerCompleted (DockerConnectedInfoCompleted status) -> matchesNodeCreateStatus identifier status
  _ -> False

matchesNodeCreateStatus :: String -> NodeCreateStatus -> Bool
matchesNodeCreateStatus identifier status = case status of
  NodeCreateStatus
    (NodeCreateRecoveryRecorded _)
    True
    (Just NodeCreateAttemptMatches)
    (Just (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just recorded))))
    (Just NodeStartAttemptMatches)
    (Just (NodeStartResultObserved (DockerNodeContainerStartReply 204)))
    (Just NodeRemoveControlMissing)
    (Just NodeRemoveAttemptMissing)
    Nothing
    (Just (Right (DockerNodeContainerMatching True))) -> identifier == recorded
  _ -> False

-- | Read a scope and the exact named/labelled Docker inventory at the selected
-- socket. A name/label mismatch is reported as foreign, never as absent.
observeControl :: BootstrapProjection -> IO (Either ControlStatusError ControlObservation)
observeControl bootstrap = do
  root <- observeScopeRoot scope
  case root of
    Left _ -> pure (Left ControlRootUnobservable)
    Right rootState -> do
      generation <- case rootState of
        ScopeRootAbsent -> pure (Right Nothing)
        ScopeRootPresent -> fmap Just <$> observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration bootstrap))
      artifact <- case (rootState, bootstrapNodeArtifact bootstrap) of
        (ScopeRootPresent, Just declaration) ->
          fmap Just
            <$> observeScopeArtifact
              scope
              (artifactPath declaration)
              (artifactDigest declaration)
              (artifactMaximumBytes declaration)
        _ -> pure (Right Nothing)
      tool <- case (rootState, bootstrapKindTool bootstrap) of
        (ScopeRootPresent, Just declaration) ->
          fmap Just
            <$> observeScopeArtifact
              scope
              (artifactPath declaration)
              (artifactDigest declaration)
              (artifactMaximumBytes declaration)
        _ -> pure (Right Nothing)
      case (generation, artifact, tool) of
        (Left _, _, _) -> pure (Left ControlRootUnobservable)
        (_, Left _, _) -> pure (Left ControlRootUnobservable)
        (_, _, Left _) -> pure (Left ControlRootUnobservable)
        (Right observedGeneration, Right observedArtifact, Right observedTool) -> do
          intent <- case rootState of
            ScopeRootAbsent -> pure Nothing
            ScopeRootPresent -> Just <$> observeKindIntent bootstrap
          imageIntent <- case intent of
            Just (KindIntentMatches operation) -> Just <$> observeRecordedNodeImageIntent bootstrap operation
            _ -> pure Nothing
          imageAttempt <- case intent of
            Just (KindIntentMatches operation) -> Just <$> observeRecordedNodeImageAttempt bootstrap operation
            _ -> pure Nothing
          networkRecovery <- case intent of
            Just (KindIntentMatches operation) -> Just <$> observeRecoveredKindNetwork bootstrap operation
            _ -> pure Nothing
          nodeVarVolume <- case intent of
            Just (KindIntentMatches operation) -> Just <$> observeNodeVarVolume bootstrap operation
            _ -> pure Nothing
          nodeCreate <- case intent of
            Just (KindIntentMatches operation) -> Just <$> observeNodeCreate bootstrap operation
            _ -> pure Nothing
          nodeConfigRecord <- case intent of
            Just (KindIntentMatches operation) -> Just <$> observeNodeConfigRecord bootstrap operation
            _ -> pure Nothing
          nodeCreateReadback <- case (intent, nodeCreate) of
            ( Just (KindIntentMatches operation)
              , Just
                  ( KindOperationCallbackReturned
                      ( DockerPeerCompleted
                          (DockerConnectedInfoCompleted (NodeCreateStatus _ True _ (Just candidateResult) _ _ _ _ _ _))
                        )
                    )
              )
                | candidateResult == NodeCreateResultMissing
                    || candidateResult == NodeCreateResultObserved DockerNodeContainerCreateUnconfirmed ->
                    Just <$> observeIndependentNodeCreateCandidate bootstrap operation
            _ -> pure Nothing
          nodeCandidateRecord <- case (intent, nodeCreate) of
            ( Just (KindIntentMatches operation)
              , Just
                  ( KindOperationCallbackReturned
                      ( DockerPeerCompleted
                          (DockerConnectedInfoCompleted (NodeCreateStatus _ True _ (Just candidateResult) _ _ _ _ _ _))
                        )
                    )
              )
                | candidateResult == NodeCreateResultMissing
                    || candidateResult == NodeCreateResultObserved DockerNodeContainerCreateUnconfirmed ->
                    Just <$> withRecoveredKindOperation bootstrap operation (observeCandidateRecord bootstrap operation)
            _ -> pure Nothing
          nodeVarReadback <- case (intent, nodeVarVolume) of
            ( Just (KindIntentMatches operation)
              , Just
                  ( KindOperationCallbackReturned
                      ( DockerPeerCompleted
                          (DockerConnectedInfoCompleted (Right (_, _, _, _, Just NodeVolumeRemovalMatches, _)))
                        )
                    )
              ) ->
                Just <$> observeIndependentNodeVolume bootstrap operation
            _ -> pure Nothing
          nodeRemovalReadback <- case (intent, nodeCreate) of
            ( Just (KindIntentMatches operation)
              , Just
                  ( KindOperationCallbackReturned
                      ( DockerPeerCompleted
                          ( DockerConnectedInfoCompleted
                              (NodeCreateStatus _ True _ _ _ _ _ (Just NodeRemoveAttemptMatches) _ _)
                            )
                        )
                    )
              ) -> Just <$> observeIndependentNodeRemoval bootstrap operation
            _ -> pure Nothing
          volume <- case intent of
            Just expected@(KindIntentVolumeMatches _ recorded) -> do
              observed <- observeKindVolumeDirectory recorded
              current <- observeKindIntent bootstrap
              pure $ Just (if current == expected then observed else KindVolumeDirectoryChanged)
            _ -> pure Nothing
          kubeconfig <- case rootState of
            ScopeRootAbsent -> pure Nothing
            ScopeRootPresent -> Just <$> readKindKubeconfig bootstrap
          kubernetesVolume <- case (intent, kubeconfig) of
            (Just expected@(KindIntentVolumeMatches _ recorded), Just (Right config)) -> do
              observed <- observeKindKubernetesVolumeBinding config recorded
              current <- observeKindIntent bootstrap
              reread <- readKindKubeconfig bootstrap
              same <- case reread of
                Left _ -> pure False
                Right later -> sameKindKubeconfig config later
              pure $
                if current == expected && same
                  then KubernetesVolumeObserved observed
                  else KubernetesVolumeInputsChanged
            _ -> pure KubernetesVolumeNotObserved
          capacity <- case rootState of
            ScopeRootAbsent -> pure Nothing
            ScopeRootPresent -> Just <$> observeHostCapacity scope
          headroom <- case rootState of
            ScopeRootAbsent -> pure Nothing
            ScopeRootPresent -> Just <$> observeHostHeadroom scope
          daemon <- observeDockerDaemon (bootstrapRuntimeSocket bootstrap)
          peer <- observeDockerPeer (bootstrapRuntimeSocket bootstrap)
          connectedInfo <- observeConnectedDockerInfo (bootstrapRuntimeSocket bootstrap)
          runtime <- observeRuntime (bootstrapRuntimeSocket bootstrap) (scopeKindName scope) (scopeRoot scope)
          image <- case runtime of
            Left _ -> pure ImageUnobservable
            Right _ ->
              observeImage (bootstrapRuntimeSocket bootstrap) (kindPlanNodeImage (bootstrapKindPlan bootstrap))
          pure $
            Right
              ( ControlObservation
                  (scopeKindName scope)
                  (scopeRoot scope)
                  (rootState == ScopeRootPresent)
                  observedGeneration
                  observedArtifact
                  observedTool
                  intent
                  imageIntent
                  imageAttempt
                  networkRecovery
                  nodeVarVolume
                  nodeCreate
                  nodeCandidateRecord
                  nodeConfigRecord
                  nodeCreateReadback
                  nodeVarReadback
                  nodeRemovalReadback
                  volume
                  kubernetesVolume
                  (fmap void kubeconfig)
                  capacity
                  headroom
                  daemon
                  peer
                  connectedInfo
                  (either RuntimeUnobservable id runtime)
                  image
              )
 where
  scope = bootstrapScope bootstrap

-- A matching local proposal and daemon identity do not establish admission,
-- provenance, a submitted request or worker settlement.
observeNodeCreate
  :: BootstrapProjection
  -> String
  -> IO
       ( KindOperationOutcome
           (DockerPeerResult (DockerConnectedInfoResult NodeCreateStatus))
       )
observeNodeCreate bootstrap operation =
  withRecoveredKindOperation bootstrap operation (observeNodeCreateUnderLease bootstrap operation)

-- The caller holds the matching recovered operation lease throughout.
observeNodeCreateUnderLease
  :: BootstrapProjection -> String -> IO Bool
  -> IO (DockerPeerResult (DockerConnectedInfoResult NodeCreateStatus))
observeNodeCreateUnderLease bootstrap operation operationStable =
    withConnectedDockerInfo 60000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      let stable = (&&) <$> operationStable <*> peerStable
      before <- stable
      -- The caller's held lease and Docker peer bracket this read-only
      -- snapshot. Individual journal readers still verify their own records
      -- and roots, without recursively repeating the full family proof.
      observed <- if before then observeRecordedKindNodeCreateIntent bootstrap operation (pure True)
        else pure NodeCreateRecoveryUnobservable
      let matches = case observed of
            NodeCreateRecoveryRecorded candidate -> kindNodeCreateDaemon candidate == DockerDaemonObserved identifier identity
            _ -> False
      ( attempt
        , result
        , startAttempt
        , startResult
        , removeControl
        , removeAttempt
        , removeResult
        , nodeInspection
        ) <- case observed of
        NodeCreateRecoveryRecorded candidate | matches -> do
          marker <- observeKindNodeCreateAttempt bootstrap candidate (pure True)
          transport <- case marker of
            NodeCreateAttemptMatches -> Just <$> observeKindNodeCreateResult bootstrap candidate (pure True)
            _ -> pure Nothing
          start <- case transport of
            Just (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId))) ->
              Just <$> observeKindNodeStartAttempt bootstrap candidate containerId (pure True)
            _ -> pure Nothing
          startOutcome <- case (transport, start) of
            ( Just (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId)))
              , Just NodeStartAttemptMatches
              ) ->
                Just <$> observeKindNodeStartResult bootstrap candidate containerId (pure True)
            _ -> pure Nothing
          control <- case transport of
            Just (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId))) ->
              Just <$> observeKindNodeRemoveControl bootstrap candidate containerId (pure True)
            _ -> pure Nothing
          removal <- case transport of
            Just (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId))) ->
              Just <$> observeKindNodeRemoveAttempt bootstrap candidate containerId (pure True)
            _ -> pure Nothing
          removalOutcome <- case (transport, removal) of
            ( Just (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId)))
              , Just NodeRemoveAttemptMatches
              ) ->
                Just <$> observeKindNodeRemoveResult bootstrap candidate containerId (pure True)
            _ -> pure Nothing
          inspected <- case transport of
            Just (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId))) ->
              Just <$> inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput candidate) containerId
            _ -> pure Nothing
          pure
            ( Just marker
            , transport
            , start
            , startOutcome
            , control
            , removal
            , removalOutcome
            , inspected
            )
        _ -> pure (Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing)
      after <- stable
      pure $
        if before && after
          then
            NodeCreateStatus
              observed
              matches
              attempt
              result
              startAttempt
              startResult
              removeControl
              removeAttempt
              removeResult
              nodeInspection
          else
            NodeCreateStatus
              NodeCreateRecoveryUnobservable
              False
              Nothing
              Nothing
              Nothing
              Nothing
              Nothing
              Nothing
              Nothing
              Nothing

-- The caller holds the recovered operation lease. This brackets the CA read
-- with exact running-node and daemon observations and compares the full
-- selected kubeconfig in memory. TLS peer authentication remains separate.
observeNodeCaBindingUnderLease
  :: BootstrapProjection -> String -> String -> KindKubeconfig -> IO Bool -> IO Bool
observeNodeCaBindingUnderLease bootstrap operation node config operationStable = do
  before <- matchesScopedWorkerNode node <$> observeNodeCreateUnderLease bootstrap operation operationStable
  current <- readKindKubeconfig bootstrap
  configBefore <- either (const (pure False)) (sameKindKubeconfig config) current
  if not (before && configBefore) then pure False else do
    observed <- withKindKubeconfigMaterial config $ \ca _ _ ->
      withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
        let stable = (&&) <$> operationStable <*> peerStable
        proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
        case proposal of
          NodeCreateRecoveryRecorded candidate
            | kindNodeCreateDaemon candidate == DockerDaemonObserved identifier identity -> do
                initial <- inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput candidate) node
                caRead <- readDockerSessionKindNodeCa session node ca
                final <- inspectDockerSessionKindNode session bootstrap (kindNodeCreateInput candidate) node
                unchanged <- stable
                pure (initial == Right (DockerNodeContainerMatching True)
                  && caRead == Right DockerNodeConfigMatches
                  && final == initial && unchanged)
          _ -> pure False
    after <- matchesScopedWorkerNode node <$> observeNodeCreateUnderLease bootstrap operation operationStable
    latest <- readKindKubeconfig bootstrap
    configAfter <- either (const (pure False)) (sameKindKubeconfig config) latest
    stable <- operationStable
    pure (observed == DockerPeerCompleted (DockerConnectedInfoCompleted True) && after && configAfter && stable)
-- Local checkpoint readability is separate from daemon presence and from
-- resource ownership or worker settlement.
observeNodeConfigRecord
  :: BootstrapProjection -> String -> IO (KindOperationOutcome NodeConfigRecordStatus)
observeNodeConfigRecord bootstrap operation =
  withRecoveredKindOperation bootstrap operation $ \stable -> do
    proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
    case proposal of
      NodeCreateRecoveryRecorded intent -> do
        created <- observeKindNodeCreateResult bootstrap intent stable
        case created of
          NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just identifier)) -> do
            attempt <- observeKindNodeConfigAttempt bootstrap intent identifier stable
            result <- case attempt of
              NodeConfigAttemptMatches -> Just <$> observeKindNodeConfigResult bootstrap intent identifier stable
              _ -> pure Nothing
            pure (NodeConfigRecordObserved attempt result)
          _ -> pure NodeConfigRecordUnavailable
      _ -> pure NodeConfigRecordUnavailable

observeCandidateRecord
  :: BootstrapProjection -> String -> IO Bool -> IO KindNodeCandidateObservation
observeCandidateRecord bootstrap operation stable = do
  proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
  case proposal of
    NodeCreateRecoveryRecorded intent -> observeRecordedKindNodeCandidate bootstrap intent stable
    _ -> pure NodeCandidateRecordUnobservable

-- This is a candidate-name observation under the recovered operation lease.
-- It does not imply that a volume create was admitted or that any worker has
-- settled, and a matching label is not provenance.
observeNodeVarVolume
  :: BootstrapProjection
  -> String
  -> IO
       ( KindOperationOutcome
           ( DockerPeerResult
               ( DockerConnectedInfoResult
                   ( Either
                       DockerConnectedInfoFailure
                       ( DockerNodeVarVolumeObservation
                       , KindNodeVolumeIntentObservation
                       , Maybe KindNodeVolumeAttemptObservation
                       , Maybe KindNodeVolumeReceiptObservation
                       , Maybe KindNodeVolumeRemovalObservation
                       , Maybe KindNodeVolumeRemovalReceiptObservation
                       )
                   )
               )
           )
       )
observeNodeVarVolume bootstrap operation =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 5000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      before <- (&&) <$> operationStable <*> peerStable
      if not before
        then pure (Left DockerConnectedInfoChanged)
        else do
          observed <- inspectDockerSessionNodeVarVolume session bootstrap operation
          let stable = (&&) <$> operationStable <*> peerStable
          (recorded, attempt, receipt, removal, removalReceipt) <- case mkKindNodeVolumeIntent operation (DockerDaemonObserved identifier identity) of
            Nothing -> pure (NodeVolumeIntentUnobservable, Nothing, Nothing, Nothing, Nothing)
            Just expected -> do
              proposal <- observeKindNodeVolumeIntent bootstrap expected stable
              marker <- case proposal of
                NodeVolumeIntentMatches -> Just <$> observeKindNodeVolumeAttempt bootstrap expected stable
                _ -> pure Nothing
              result <- case marker of
                Just NodeVolumeAttemptMatches -> Just <$> observeKindNodeVolumeReceipt bootstrap expected stable
                _ -> pure Nothing
              removalMarker <- case marker of
                Just NodeVolumeAttemptMatches -> Just <$> observeKindNodeVolumeRemoval bootstrap expected stable
                _ -> pure Nothing
              removalResult <- case removalMarker of
                Just NodeVolumeRemovalMatches -> Just <$> observeKindNodeVolumeRemovalReceipt bootstrap expected stable
                _ -> pure Nothing
              pure (proposal, marker, result, removalMarker, removalResult)
          after <- stable
          pure
            ( if after
                then (,recorded,attempt,receipt,removal,removalReceipt) <$> observed
                else Left DockerConnectedInfoChanged
            )

-- Compare only in memory; no credential bytes or secret digests enter output.
sameKindKubeconfig :: KindKubeconfig -> KindKubeconfig -> IO Bool
sameKindKubeconfig left right =
  withKindKubeconfigMaterial left $ \leftCa leftCert leftKey ->
    withKindKubeconfigMaterial right $ \rightCa rightCert rightKey ->
      pure $
        kindKubeconfigScope left == kindKubeconfigScope right
          && kindKubeconfigServer left == kindKubeconfigServer right
          && kindKubeconfigContext left == kindKubeconfigContext right
          && leftCa == rightCa
          && leftCert == rightCert
          && leftKey == rightKey

observeHostCapacity :: DeploymentScope -> IO HostCapacityObservation
observeHostCapacity scope = do
  result <- withObservedScopeRoot scope $ \sameRoot -> do
    attempt <- try $ do
      stableBefore <- sameRoot
      now <- getMonotonicTimeNSec
      observed <- observeNativeHostCapacityBefore (now + 2000000000) (scopeRoot scope)
      stableAfter <- sameRoot
      pure $ case observed of
        Right capacity
          | stableBefore && stableAfter ->
              HostCapacityObserved (observedHostVector capacity) (observedStorageDevicesCoincide capacity)
        _ -> HostCapacityUnobservable
    pure $
      either (const HostCapacityUnobservable) id (attempt :: Either IOException HostCapacityObservation)
  pure $ either (const HostCapacityUnobservable) id result

observeHostHeadroom :: DeploymentScope -> IO HostHeadroomObservation
observeHostHeadroom scope = do
  result <- withObservedScopeRoot scope $ \sameRoot -> do
    attempt <- try $ do
      stableBefore <- sameRoot
      now <- getMonotonicTimeNSec
      observed <- observeNativeHostHeadroomBefore (now + 2000000000) (scopeRoot scope)
      stableAfter <- sameRoot
      pure $ case observed of
        Right headroom | stableBefore && stableAfter -> HostHeadroomObserved headroom
        _ -> HostHeadroomUnobservable
    pure $
      either (const HostHeadroomUnobservable) id (attempt :: Either IOException HostHeadroomObservation)
  pure $ either (const HostHeadroomUnobservable) id result

-- A failed inspect is unobservable, not evidence that an image is absent.
-- RepoDigests describe daemon metadata, not the retained archive's origin.
observeImage :: FilePath -> String -> IO ImageObservation
observeImage socket reference = do
  socketStatus <- try (getSymbolicLinkStatus socket)
  case socketStatus of
    Right status | isSocket status -> do
      output <- docker socket ["image", "inspect", reference]
      pure $ case output of
        Left _ -> ImageUnobservable
        Right content -> case Aeson.eitherDecodeStrict' (ByteString.pack content) of
          Right [value] -> either (const ImageUnobservable) id (parseImageObservation reference value)
          _ -> ImageUnobservable
    Left (_ :: IOException) -> pure ImageUnobservable
    Right _ -> pure ImageUnobservable

-- | A successful exact-ID inspection is a point observation, not ownership,
-- provenance, absence, or permission to remove an image.
observeImageId :: FilePath -> String -> IO ImageIdObservation
observeImageId socket identifier
  | not (validImageId identifier) = pure ImageIdUnobservable
  | otherwise = do
      socketStatus <- try (getSymbolicLinkStatus socket)
      case socketStatus of
        Right status | isSocket status -> do
          output <- docker socket ["image", "inspect", identifier]
          pure $ case output of
            Left _ -> ImageIdUnobservable
            Right content -> case Aeson.eitherDecodeStrict' (ByteString.pack content) of
              Right [value] -> either (const ImageIdUnobservable) id (parseImageIdObservation identifier value)
              _ -> ImageIdUnobservable
        Left (_ :: IOException) -> pure ImageIdUnobservable
        Right _ -> pure ImageIdUnobservable

parseImageObservation :: String -> Aeson.Value -> Either String ImageObservation
parseImageObservation reference = parseEither $ Aeson.withObject "image" $ \value -> do
  imageId <- value .: "Id"
  repoDigests <- value .: "RepoDigests" :: Parser [String]
  operatingSystem <- value .: "Os"
  architecture <- value .: "Architecture"
  let expectedDigest = drop 1 (dropWhile (/= '@') reference)
      matches = any ((== expectedDigest) . drop 1 . dropWhile (/= '@')) repoDigests
      validId = case stripPrefixSha imageId of
        Just digest -> validContainerId digest
        Nothing -> False
  if null expectedDigest || not validId || not (safeWord operatingSystem) || not (safeWord architecture)
    then fail "invalid image metadata"
    else pure (ImageObserved matches imageId operatingSystem architecture)
 where
  stripPrefixSha ('s' : 'h' : 'a' : '2' : '5' : '6' : ':' : rest) = Just rest
  stripPrefixSha _ = Nothing
  safeWord word =
    not (null word)
      && length word <= 32
      && all (\c -> isAsciiLower c || (c >= '0' && c <= '9') || c `elem` ("_-" :: String)) word

observeRuntime
  :: FilePath -> String -> FilePath -> IO (Either ControlStatusError RuntimeObservation)
observeRuntime socket name root = do
  socketStatus <- try (getSymbolicLinkStatus socket)
  case socketStatus of
    Left (_ :: IOException) -> pure (Left ControlRuntimeSocketUnobservable)
    Right status | not (isSocket status) -> pure (Left ControlRuntimeSocketUnobservable)
    Right _ -> observeRuntimeInventory (inventory socket) (inspectNode socket name root) labelFilter nameFilter
 where
  labelFilter = "label=io.x-k8s.kind.cluster=" ++ name
  nameFilter = "name=^/" ++ name ++ "-control-plane$"

-- | Bracket an inspect with independent inventories. A changed inventory is
-- reported as such even when the inspected container was an exact match.
observeRuntimeInventory
  :: (String -> IO (Either ControlStatusError [String]))
  -> (String -> IO (Either ControlStatusError RuntimeObservation))
  -> String
  -> String
  -> IO (Either ControlStatusError RuntimeObservation)
observeRuntimeInventory readInventory inspect labelFilter nameFilter = runExceptT $ do
  firstLabels <- ExceptT (readInventory labelFilter)
  firstNames <- ExceptT (readInventory nameFilter)
  secondLabels <- ExceptT (readInventory labelFilter)
  secondNames <- ExceptT (readInventory nameFilter)
  case chooseRuntimeCandidate firstLabels firstNames secondLabels secondNames of
    InventoryNoMatches -> pure RuntimeNoMatchesObserved
    InventoryChanged -> pure RuntimeInventoryChanged
    InventoryForeignOrMultiple -> pure RuntimeForeignOrMultiple
    InventoryCandidate identifier -> do
      observed <- ExceptT (inspect identifier)
      finalLabels <- ExceptT (readInventory labelFilter)
      finalNames <- ExceptT (readInventory nameFilter)
      pure $ case chooseRuntimeCandidate secondLabels secondNames finalLabels finalNames of
        InventoryCandidate finalIdentifier | finalIdentifier == identifier -> observed
        _ -> RuntimeInventoryChanged

-- Separate provider reads are observations at different instants. A changed
-- inventory never becomes a candidate or evidence of resource absence.
chooseRuntimeCandidate :: [String] -> [String] -> [String] -> [String] -> RuntimeInventoryDecision
chooseRuntimeCandidate firstLabels firstNames secondLabels secondNames
  | firstLabels /= secondLabels || firstNames /= secondNames = InventoryChanged
  | otherwise = case (firstLabels, firstNames) of
      ([], []) -> InventoryNoMatches
      ([labelId], [nameId]) | labelId == nameId -> InventoryCandidate labelId
      _ -> InventoryForeignOrMultiple

inventory :: FilePath -> String -> IO (Either ControlStatusError [String])
inventory socket filterValue = do
  output <-
    docker socket ["ps", "--all", "--no-trunc", "--filter", filterValue, "--format", "{{.ID}}"]
  pure $ do
    content <- output
    let identifiers = lines content
    if all validContainerId identifiers && length identifiers == length (nub identifiers)
      then Right (sort identifiers)
      else Left ControlRuntimeResponseInvalid

validContainerId :: String -> Bool
validContainerId identifier = length identifier == 64 && all hexadecimal identifier
 where
  hexadecimal character = (isDigit character && character <= '9') || (character >= 'a' && character <= 'f')

inspectNode
  :: FilePath -> String -> FilePath -> String -> IO (Either ControlStatusError RuntimeObservation)
inspectNode socket name root identifier = do
  output <- docker socket ["inspect", "--type", "container", identifier]
  pure $ do
    content <- output
    values <-
      either
        (const (Left ControlRuntimeResponseInvalid))
        Right
        (Aeson.eitherDecodeStrict' (ByteString.pack content))
    case values of
      [value] ->
        either
          (const (Left ControlRuntimeResponseInvalid))
          Right
          (parseNodeObservation name root identifier value)
      _ -> Left ControlRuntimeResponseInvalid

parseNodeObservation
  :: String -> FilePath -> String -> Aeson.Value -> Either String RuntimeObservation
parseNodeObservation name root identifier = parseEither (nodeObservation name root identifier)

nodeObservation :: String -> FilePath -> String -> Aeson.Value -> Parser RuntimeObservation
nodeObservation name root identifier = Aeson.withObject "container" $ \value -> do
  observedId <- value .: "Id"
  observedName <- value .: "Name"
  config <- value .: "Config"
  labels <- config .: "Labels"
  cluster <- labels .: "io.x-k8s.kind.cluster"
  role <- labels .: "io.x-k8s.kind.role"
  state <- value .: "State"
  running <- state .: "Running"
  mounts <- value .: "Mounts"
  bound <- traverse mountObservation mounts
  let exact =
        observedId == identifier
          && observedName == '/' : name ++ "-control-plane"
          && cluster == name
          && role == ("control-plane" :: String)
      matches =
        [(source, kind, writable) | (source, target, kind, writable) <- bound, target == "/var/lib/prodbox"]
  pure $
    if exact
      then RuntimeNodeObserved running (matches == [(root, "bind", True)])
      else RuntimeForeignOrMultiple

mountObservation :: Aeson.Value -> Parser (FilePath, FilePath, String, Bool)
mountObservation = Aeson.withObject "mount" $ \value -> (,,,) <$> value .: "Source" <*> value .: "Destination" <*> value .: "Type" <*> value .: "RW"

docker :: FilePath -> [String] -> IO (Either ControlStatusError String)
docker socket arguments = do
  result <- readDocker socket arguments
  pure (maybe (Left ControlRuntimeCommandFailed) Right result)

renderControlObservation :: ControlObservation -> String
renderControlObservation observed =
  unlines
    [ "Control candidate: " ++ controlScopeName observed
    , "Root: "
        ++ controlRoot observed
        ++ if controlRootPresent observed then " (present)" else " (not present locally)"
    , "Generation record: " ++ maybe "not observed" generationText (controlGeneration observed)
    , "Retained node artifact: " ++ maybe "not observed" artifactText (controlArtifact observed)
    , "Retained kind tool: " ++ maybe "not observed" toolArtifactText (controlKindTool observed)
    , "Kind operation record: " ++ maybe "not observed" intentText (controlIntent observed)
    , "Node image intent: "
        ++ maybe "not observed" (imageIntentText (controlDaemon observed)) (controlImageIntent observed)
    , "Node image attempt: " ++ maybe "not observed" imageAttemptText (controlImageAttempt observed)
    , "Kind network recovery: "
        ++ maybe "not observed" networkRecoveryText (controlNetworkRecovery observed)
    , "Candidate node /var volume: "
        ++ maybe "not observed" nodeVarVolumeText (controlNodeVarVolume observed)
    , "Node create proposal: " ++ maybe "not observed" nodeCreateText (controlNodeCreate observed)
    , "Node configuration records: "
        ++ maybe "not observed" nodeConfigRecordText (controlNodeConfigRecord observed)
    , "Recorded unconfirmed node candidate: "
        ++ maybe "not observed" nodeCandidateRecordText (controlNodeCandidateRecord observed)
    , "Unconfirmed node candidate: "
        ++ maybe "not observed" nodeCreateReadbackText (controlNodeCreateReadback observed)
    , "Independent volume inventory: "
        ++ maybe "not observed" nodeVarReadbackText (controlNodeVarReadback observed)
    , "Independent node removal inventory: "
        ++ maybe "not observed" nodeRemovalReadbackText (controlNodeRemovalReadback observed)
    , "Recorded volume directory: " ++ maybe "not observed" volumeText (controlVolume observed)
    , "Recorded Kubernetes volume: " ++ kubernetesVolumeText (controlKubernetesVolume observed)
    , "Selected kubeconfig: " ++ maybe "not observed" kubeconfigText (controlKubeconfig observed)
    , "Host capacity: " ++ maybe "not observed" capacityText (controlHostCapacity observed)
    , "Host headroom: " ++ maybe "not observed" headroomText (controlHostHeadroom observed)
    , "Docker daemon: " ++ daemonText (controlDaemon observed)
    , "Docker socket peer: " ++ peerText (controlDockerPeer observed)
    , "Docker connected info: " ++ connectedInfoText (controlConnectedInfo observed)
    , "Docker inventory: " ++ runtimeText (controlRuntime observed)
    , "Node image: " ++ imageText (controlImage observed)
    , "Docker executable identity, image provenance and archive binding, cluster certificates and identity, network policy enforcement (observed only during `control reconcile`), and cloud resources were not checked."
    ]
 where
  daemonText DockerDaemonUnobservable = "unobservable"
  daemonText DockerDaemonChanged = "identity or socket changed during observation"
  daemonText (DockerDaemonObserved identifier _) =
    "repeated ID "
      ++ identifier
      ++ "; socket identity stable during observations; daemon not authenticated"
  peerText (DockerPeerCompleted (DockerPeer pid uid gid _)) =
    "kernel reported pid "
      ++ show pid
      ++ ", uid "
      ++ show uid
      ++ ", gid "
      ++ show gid
      ++ " on a separate connection; daemon not authenticated"
  peerText (DockerPeerChanged _) = "socket or peer changed during observation"
  peerText (DockerPeerRefused _) = "unobservable"
  peerText (DockerPeerUnconfirmed _) = "observation interrupted"
  peerText (DockerPeerUnconfirmedAfter _ _) = "observation interrupted after peer read"
  connectedInfoText
    ( DockerPeerCompleted
        (DockerConnectedInfoCompleted (DockerConnectedInfo identifier (DockerPeer pid uid gid _)))
      ) =
      "ID "
        ++ identifier
        ++ ", kernel peer pid "
        ++ show pid
        ++ ", uid "
        ++ show uid
        ++ ", gid "
        ++ show gid
        ++ " on the same connection; daemon not authenticated"
  connectedInfoText (DockerPeerCompleted (DockerConnectedInfoRefused _)) = "unobservable"
  connectedInfoText (DockerPeerChanged _) = "socket or peer changed during observation"
  connectedInfoText (DockerPeerRefused _) = "unobservable"
  connectedInfoText (DockerPeerUnconfirmed _) = "observation interrupted"
  connectedInfoText (DockerPeerUnconfirmedAfter _ _) = "observation interrupted after info read"
  kubeconfigText (Left failure) = "not safely readable: " ++ show failure
  kubeconfigText (Right ()) = "selected local file is structurally valid; cluster identity and certificates unverified"
  toolArtifactText (ScopeArtifactDigestMatches size) =
    "declared file digest matches ("
      ++ show size
      ++ " bytes); executable version and provenance unverified"
  toolArtifactText observation = artifactText observation
  capacityText HostCapacityUnobservable = "unobservable"
  capacityText (HostCapacityObserved vector shared) =
    "CPU affinity "
      ++ show (milli_cpu vector)
      ++ " millicores, host memory total "
      ++ show (memory_mib vector)
      ++ " MiB, root filesystem total "
      ++ show (ephemeral_storage_mib vector)
      ++ " MiB, retained filesystem total "
      ++ show (durable_storage_mib vector)
      ++ " MiB; filesystems "
      ++ (if shared then "share" else "use different")
      ++ " devices; reservations and workload fit unverified"
  headroomText HostHeadroomUnobservable = "unobservable"
  headroomText (HostHeadroomObserved available) =
    "host memory available "
      ++ show (hostAvailableMemoryMib available)
      ++ " MiB, root filesystem available "
      ++ show (hostAvailableRootStorageMib available)
      ++ " MiB, retained filesystem available "
      ++ show (hostAvailableRetainedStorageMib available)
      ++ " MiB; volatile observations, cgroup limits, quotas, reservations and workload fit unverified"
  intentText KindIntentMissing = "not found locally; operation absence is unverified"
  intentText (KindIntentMatches operationId) =
    "record " ++ operationId ++ " matches selected configuration; completion and admission unverified"
  intentText (KindIntentVolumeMatches operationId volume) =
    "record "
      ++ operationId
      ++ " matches selected volume "
      ++ kindVolumeName volume
      ++ "; completion and admission unverified"
  intentText KindIntentConflict = "record conflicts with selected configuration"
  intentText KindIntentInvalid = "record is invalid or incomplete"
  intentText KindIntentGenerationUnavailable = "selected root generation is unavailable or different"
  intentText KindIntentObservationUnobservable = "record could not be safely observed"
  imageIntentText _ NodeImageIntentMissing = "not found locally; image effect remains unverified"
  imageIntentText _ NodeImageIntentMatches = "matching local record; daemon effect and worker settlement unverified"
  imageIntentText current (NodeImageIntentBound expected@(DockerDaemonObserved _ _)) = case current of
    DockerDaemonObserved {}
      | current == expected ->
          "bound local record matches sampled daemon; daemon authentication and worker settlement unverified"
    DockerDaemonObserved {} -> "bound local record differs from sampled daemon; worker settlement unverified"
    _ -> "bound local record; current daemon unobservable or changed; worker settlement unverified"
  imageIntentText _ (NodeImageIntentBound _) = "recorded daemon binding is unobservable"
  imageIntentText _ NodeImageIntentConflict = "record conflicts with selected operation or configuration"
  imageIntentText _ NodeImageIntentInvalid = "record is invalid or incomplete"
  imageIntentText _ NodeImageIntentUnobservable = "record could not be safely observed"
  imageAttemptText NodeImageAttemptMissing = "not found locally; daemon effect and worker settlement unverified"
  imageAttemptText NodeImageAttemptMatches = "matching local marker; daemon effect and worker settlement unverified"
  imageAttemptText NodeImageAttemptConflict = "marker conflicts with the recorded image intent"
  imageAttemptText NodeImageAttemptInvalid = "marker is invalid or incomplete"
  imageAttemptText NodeImageAttemptUnobservable = "marker or parent intent could not be safely observed"
  nodeVarVolumeText outcome = case outcome of
    KindOperationRefused _ -> "operation lease or record unavailable; volume state unverified"
    KindOperationUnconfirmed _ -> "operation interrupted; volume state unverified"
    KindOperationRootChanged _ -> "scope changed during observation; volume state unverified"
    KindOperationUnlockFailed _ _ -> "lease unlock failed; volume state unverified"
    KindOperationScopeCleanupFailed _ _ -> "scope cleanup failed; volume state unverified"
    KindOperationCallbackReturned
      ( DockerPeerCompleted
          ( DockerConnectedInfoCompleted
              (Right (observation, intent, attempt, receipt, removal, removalReceipt))
            )
        ) ->
        nodeVarResultText observation
          ++ "; "
          ++ nodeVarIntentText intent
          ++ "; "
          ++ maybe "volume attempt not observed" nodeVarAttemptText attempt
          ++ "; "
          ++ maybe "volume result not observed" nodeVarReceiptText receipt
          ++ "; "
          ++ maybe "volume removal not observed" nodeVarRemovalText removal
          ++ "; "
          ++ maybe "volume removal result not observed" nodeVarRemovalReceiptText removalReceipt
    KindOperationCallbackReturned _ -> "unobservable or changed; volume state and worker settlement unverified"
  nodeVarResultText DockerNodeVarVolumeNotFound = "daemon returned 404; absence, ownership and worker settlement unverified"
  nodeVarResultText DockerNodeVarVolumeMatching = "configuration and labels match; provenance, admission and worker settlement unverified"
  nodeVarResultText DockerNodeVarVolumeConflict = "configuration or labels conflict; ownership and worker settlement unverified"
  nodeVarIntentText NodeVolumeIntentMissing = "volume proposal not found locally"
  nodeVarIntentText NodeVolumeIntentMatches = "volume proposal matches current operation and daemon; effect and settlement unverified"
  nodeVarIntentText NodeVolumeIntentConflict = "volume proposal conflicts with current operation or daemon"
  nodeVarIntentText NodeVolumeIntentInvalid = "volume proposal is invalid or incomplete"
  nodeVarIntentText NodeVolumeIntentUnobservable = "volume proposal could not be safely observed"
  nodeVarAttemptText NodeVolumeAttemptMissing = "volume attempt not found locally; effect and settlement unverified"
  nodeVarAttemptText NodeVolumeAttemptMatches = "volume attempt recorded; effect and settlement unverified"
  nodeVarAttemptText NodeVolumeAttemptConflict = "volume attempt conflicts with proposal"
  nodeVarAttemptText NodeVolumeAttemptInvalid = "volume attempt invalid or incomplete"
  nodeVarAttemptText NodeVolumeAttemptUnobservable = "volume attempt could not be safely observed"
  nodeVarReceiptText NodeVolumeReceiptMissing = "volume result not found locally; effect and settlement unverified"
  nodeVarReceiptText (NodeVolumeReceiptObserved DockerNodeVarCreateNotStarted) = "volume request not started; settlement unverified"
  nodeVarReceiptText (NodeVolumeReceiptObserved DockerNodeVarCreateUnconfirmed) = "volume request outcome unconfirmed; settlement unverified"
  nodeVarReceiptText (NodeVolumeReceiptObserved (DockerNodeVarCreateReply status _)) = "volume daemon replied " ++ show status ++ "; ownership and settlement unverified"
  nodeVarReceiptText NodeVolumeReceiptConflict = "volume result conflicts with attempt"
  nodeVarReceiptText NodeVolumeReceiptInvalid = "volume result is invalid or incomplete"
  nodeVarReceiptText NodeVolumeReceiptUnobservable = "volume result could not be safely observed"
  nodeVarRemovalText NodeVolumeRemovalMissing = "volume removal not found locally; absence and settlement unverified"
  nodeVarRemovalText NodeVolumeRemovalMatches = "volume removal recorded; absence and settlement unverified"
  nodeVarRemovalText NodeVolumeRemovalConflict = "volume removal conflicts with attempt"
  nodeVarRemovalText NodeVolumeRemovalInvalid = "volume removal is invalid or incomplete"
  nodeVarRemovalText NodeVolumeRemovalUnobservable = "volume removal could not be safely observed"
  nodeVarRemovalReceiptText NodeVolumeRemovalReceiptMissing = "volume removal result not found locally; absence and settlement unverified"
  nodeVarRemovalReceiptText (NodeVolumeRemovalReceiptObserved DockerNodeVarRemoveNotStarted) = "volume removal not started; settlement unverified"
  nodeVarRemovalReceiptText (NodeVolumeRemovalReceiptObserved DockerNodeVarRemoveUnconfirmed) = "volume removal outcome unconfirmed; absence and settlement unverified"
  nodeVarRemovalReceiptText (NodeVolumeRemovalReceiptObserved (DockerNodeVarRemoveReply status)) = "volume removal daemon replied " ++ show status ++ "; absence and settlement unverified"
  nodeVarRemovalReceiptText NodeVolumeRemovalReceiptConflict = "volume removal result conflicts with marker"
  nodeVarRemovalReceiptText NodeVolumeRemovalReceiptInvalid = "volume removal result invalid or incomplete"
  nodeVarRemovalReceiptText NodeVolumeRemovalReceiptUnobservable = "volume removal result could not be safely observed"
  nodeVarReadbackText outcome = case outcome of
    KindOperationRefused _ -> "operation unavailable; absence and settlement unverified"
    KindOperationUnconfirmed _ -> "operation interrupted; absence and settlement unverified"
    KindOperationRootChanged _ -> "scope changed during observation; absence and settlement unverified"
    KindOperationUnlockFailed _ _ -> "lease unlock failed; absence and settlement unverified"
    KindOperationScopeCleanupFailed _ _ -> "scope cleanup failed; absence and settlement unverified"
    KindOperationCallbackReturned NodeVolumeReadbackRecordUnavailable -> "matching removal record unavailable; absence and settlement unverified"
    KindOperationCallbackReturned NodeVolumeReadbackUnobservable -> "unobservable; absence and settlement unverified"
    KindOperationCallbackReturned NodeVolumeReadbackChanged -> "inventory or scope changed during observation; absence and settlement unverified"
    KindOperationCallbackReturned (NodeVolumeReadbackSampled sample) ->
      (if nodeVolumeListed sample then "volume listed" else "volume not listed")
        ++ ", "
        ++ show (length (nodeVolumeContainerIds sample))
        ++ " referencing containers in repeated reads; absence and settlement unverified"
  nodeRemovalReadbackText outcome = case outcome of
    KindOperationRefused _ -> "operation could not be safely acquired"
    KindOperationUnconfirmed _ -> "operation interrupted; absence and settlement unverified"
    KindOperationRootChanged _ -> "operation root or intent changed during observation"
    KindOperationUnlockFailed _ _ -> "lease unlock failed; absence and settlement unverified"
    KindOperationScopeCleanupFailed _ _ -> "scope cleanup failed; absence and settlement unverified"
    KindOperationCallbackReturned NodeRemovalReadbackRecordUnavailable -> "required removal record unavailable"
    KindOperationCallbackReturned NodeRemovalReadbackUnobservable -> "unobservable; absence and settlement unverified"
    KindOperationCallbackReturned NodeRemovalReadbackChanged -> "daemon or inventory changed; absence and settlement unverified"
    KindOperationCallbackReturned (NodeRemovalReadbackSampled sample) ->
      (if nodeRemovalTargetListed sample then "target listed" else "target not listed")
        ++ ", "
        ++ show (length (nodeRemovalNameIds sample))
        ++ " name matches, "
        ++ show (length (nodeRemovalClusterIds sample))
        ++ " cluster-label matches in repeated reads; absence and settlement unverified"
  nodeCandidateRecordText outcome = case outcome of
    KindOperationRefused _ -> "operation could not be safely acquired"
    KindOperationUnconfirmed _ -> "operation interrupted; ownership and settlement unverified"
    KindOperationRootChanged _ -> "operation root or intent changed"
    KindOperationUnlockFailed _ _ -> "lease unlock failed; ownership and settlement unverified"
    KindOperationScopeCleanupFailed _ _ -> "scope cleanup failed; ownership and settlement unverified"
    KindOperationCallbackReturned NodeCandidateRecordMissing -> "not found locally; ownership and settlement unverified"
    KindOperationCallbackReturned (NodeCandidateRecordObserved identifier) -> "candidate " ++ identifier ++ " recorded; ownership and settlement unverified"
    KindOperationCallbackReturned NodeCandidateRecordConflict -> "record conflicts with selected operation"
    KindOperationCallbackReturned NodeCandidateRecordInvalid -> "record invalid or incomplete"
    KindOperationCallbackReturned NodeCandidateRecordUnobservable -> "unobservable; ownership and settlement unverified"
  nodeCreateReadbackText outcome = case outcome of
    KindOperationRefused _ -> "operation could not be safely acquired"
    KindOperationUnconfirmed _ -> "operation interrupted; ownership and settlement unverified"
    KindOperationRootChanged _ -> "operation root or intent changed"
    KindOperationUnlockFailed _ _ -> "lease unlock failed; ownership and settlement unverified"
    KindOperationScopeCleanupFailed _ _ -> "scope cleanup failed; ownership and settlement unverified"
    KindOperationCallbackReturned (DockerPeerCompleted (DockerConnectedInfoCompleted value)) -> case value of
      NodeCreateReadbackRecordUnavailable -> "required attempt or uncertain result unavailable"
      NodeCreateReadbackDaemonMismatch -> "recorded daemon differs; settlement unverified"
      NodeCreateReadbackUnobservable -> "unobservable; ownership and settlement unverified"
      NodeCreateReadbackChanged -> "inventory, result or daemon changed; ownership and settlement unverified"
      NodeCreateReadbackSampled NodeCandidateNone _ -> "no candidate sampled; absence and settlement unverified"
      NodeCreateReadbackSampled NodeCandidateConflict _ -> "candidate inventory conflicts; ownership and settlement unverified"
      NodeCreateReadbackSampled (NodeCandidateUnique identifier) inspection ->
        "candidate " ++ identifier ++ "; " ++ maybe "inspection unavailable" nodeInspectionText inspection
    _ -> "unobservable; ownership and settlement unverified"
  nodeCreateText outcome = case outcome of
    KindOperationCallbackReturned
      ( DockerPeerCompleted
          (DockerConnectedInfoCompleted (NodeCreateStatus NodeCreateRecoveryMissing _ _ _ _ _ _ _ _ _))
        ) -> "not found locally; effect and settlement unverified"
    KindOperationCallbackReturned
      ( DockerPeerCompleted
          ( DockerConnectedInfoCompleted
              ( NodeCreateStatus
                  (NodeCreateRecoveryRecorded _)
                  True
                  attempt
                  result
                  startAttempt
                  startResult
                  removeControl
                  removeAttempt
                  removeResult
                  nodeInspection
                )
            )
        ) ->
        "matches the selected operation and daemon; admission and settlement unverified; "
          ++ maybe "node attempt not observed" nodeCreateAttemptText attempt
          ++ "; "
          ++ maybe "node result not observed" nodeCreateResultText result
          ++ "; "
          ++ maybe "node start attempt not observed" nodeStartAttemptText startAttempt
          ++ "; "
          ++ maybe "node start result not observed" nodeStartResultText startResult
          ++ "; "
          ++ maybe "node removal control not observed" nodeRemoveControlText removeControl
          ++ "; "
          ++ maybe "node removal attempt not observed" nodeRemoveAttemptText removeAttempt
          ++ "; "
          ++ maybe "node removal result not observed" nodeRemoveResultText removeResult
          ++ "; "
          ++ maybe "node inspection not observed" nodeInspectionText nodeInspection
    KindOperationCallbackReturned
      ( DockerPeerCompleted
          ( DockerConnectedInfoCompleted
              (NodeCreateStatus (NodeCreateRecoveryRecorded _) False _ _ _ _ _ _ _ _)
            )
        ) -> "recorded daemon differs; admission and settlement unverified"
    KindOperationCallbackReturned
      ( DockerPeerCompleted
          (DockerConnectedInfoCompleted (NodeCreateStatus NodeCreateRecoveryConflict _ _ _ _ _ _ _ _ _))
        ) -> "conflicts with selected scope"
    KindOperationCallbackReturned
      ( DockerPeerCompleted
          (DockerConnectedInfoCompleted (NodeCreateStatus NodeCreateRecoveryInvalid _ _ _ _ _ _ _ _ _))
        ) -> "invalid or incomplete"
    _ -> "unobservable; effect and settlement unverified"
  nodeCreateAttemptText NodeCreateAttemptMissing = "node attempt not found locally; effect and settlement unverified"
  nodeCreateAttemptText NodeCreateAttemptMatches = "node attempt recorded; effect and settlement unverified"
  nodeCreateAttemptText NodeCreateAttemptConflict = "node attempt conflicts with proposal"
  nodeCreateAttemptText NodeCreateAttemptInvalid = "node attempt invalid or incomplete"
  nodeCreateAttemptText NodeCreateAttemptUnobservable = "node attempt could not be safely observed"
  nodeCreateResultText NodeCreateResultMissing = "node result not found locally; effect and settlement unverified"
  nodeCreateResultText (NodeCreateResultObserved DockerNodeContainerCreateNotStarted) = "node request not started; settlement unverified"
  nodeCreateResultText (NodeCreateResultObserved DockerNodeContainerCreateUnconfirmed) = "node request outcome unconfirmed; settlement unverified"
  nodeCreateResultText (NodeCreateResultObserved (DockerNodeContainerCreateReply status _)) = "node daemon replied " ++ show status ++ "; ownership and settlement unverified"
  nodeCreateResultText NodeCreateResultConflict = "node result conflicts with attempt"
  nodeCreateResultText NodeCreateResultInvalid = "node result invalid or incomplete"
  nodeCreateResultText NodeCreateResultUnobservable = "node result could not be safely observed"
  nodeStartAttemptText NodeStartAttemptMissing = "node start attempt not found locally; effect and settlement unverified"
  nodeStartAttemptText NodeStartAttemptMatches = "node start attempt recorded; effect and settlement unverified"
  nodeStartAttemptText NodeStartAttemptConflict = "node start attempt conflicts with create result"
  nodeStartAttemptText NodeStartAttemptInvalid = "node start attempt invalid or incomplete"
  nodeStartAttemptText NodeStartAttemptUnobservable = "node start attempt could not be safely observed"
  nodeStartResultText NodeStartResultMissing = "node start result not found locally; readiness and settlement unverified"
  nodeStartResultText (NodeStartResultObserved DockerNodeContainerStartNotStarted) = "node start not sent; settlement unverified"
  nodeStartResultText (NodeStartResultObserved DockerNodeContainerStartUnconfirmed) = "node start outcome unconfirmed; readiness and settlement unverified"
  nodeStartResultText (NodeStartResultObserved (DockerNodeContainerStartReply status)) = "node start daemon replied " ++ show status ++ "; readiness and settlement unverified"
  nodeStartResultText NodeStartResultConflict = "node start result conflicts with attempt"
  nodeStartResultText NodeStartResultInvalid = "node start result invalid or incomplete"
  nodeStartResultText NodeStartResultUnobservable = "node start result could not be safely observed"
  nodeConfigRecordText (KindOperationCallbackReturned (NodeConfigRecordObserved attempt result)) =
    nodeConfigAttemptText attempt
      ++ "; "
      ++ maybe "node configuration result not observed" nodeConfigResultText result
  nodeConfigRecordText (KindOperationCallbackReturned NodeConfigRecordUnavailable) =
    "matching local node record unavailable; effect and settlement unverified"
  nodeConfigRecordText _ = "local records unobservable; effect and settlement unverified"
  nodeConfigAttemptText NodeConfigAttemptMissing = "node configuration attempt not found locally; effect and settlement unverified"
  nodeConfigAttemptText NodeConfigAttemptMatches = "node configuration attempt recorded; effect and settlement unverified"
  nodeConfigAttemptText NodeConfigAttemptConflict = "node configuration attempt conflicts with the recorded node"
  nodeConfigAttemptText NodeConfigAttemptInvalid = "node configuration attempt invalid or incomplete"
  nodeConfigAttemptText NodeConfigAttemptUnobservable = "node configuration attempt could not be safely observed"
  nodeConfigResultText NodeConfigResultMissing = "node configuration result not found locally; effect and settlement unverified"
  nodeConfigResultText (NodeConfigResultObserved DockerNodeConfigWriteNotStarted) = "node configuration write not sent; settlement unverified"
  nodeConfigResultText (NodeConfigResultObserved DockerNodeConfigWriteUnconfirmed) = "node configuration write outcome unconfirmed; settlement unverified"
  nodeConfigResultText (NodeConfigResultObserved (DockerNodeConfigWriteReply status)) = "node configuration daemon replied " ++ show status ++ "; contents and settlement unverified"
  nodeConfigResultText NodeConfigResultConflict = "node configuration result conflicts with attempt"
  nodeConfigResultText NodeConfigResultInvalid = "node configuration result invalid or incomplete"
  nodeConfigResultText NodeConfigResultUnobservable = "node configuration result could not be safely observed"
  nodeRemoveControlText NodeRemoveControlMissing = "node removal positive control record not found; absence and settlement unverified"
  nodeRemoveControlText NodeRemoveControlMatches = "node removal positive control recorded; authenticity and settlement unverified"
  nodeRemoveControlText NodeRemoveControlConflict = "node removal positive control conflicts with create result"
  nodeRemoveControlText NodeRemoveControlInvalid = "node removal positive control invalid or incomplete"
  nodeRemoveControlText NodeRemoveControlUnobservable = "node removal positive control could not be safely observed"
  nodeRemoveAttemptText NodeRemoveAttemptMissing = "node removal attempt not found locally; absence and settlement unverified"
  nodeRemoveAttemptText NodeRemoveAttemptMatches = "node removal attempt recorded; absence and settlement unverified"
  nodeRemoveAttemptText NodeRemoveAttemptConflict = "node removal attempt conflicts with create result"
  nodeRemoveAttemptText NodeRemoveAttemptInvalid = "node removal attempt invalid or incomplete"
  nodeRemoveAttemptText NodeRemoveAttemptUnobservable = "node removal attempt could not be safely observed"
  nodeRemoveResultText NodeRemoveResultMissing = "node removal result not found locally; absence and settlement unverified"
  nodeRemoveResultText (NodeRemoveResultObserved DockerNodeContainerRemoveNotStarted) = "node removal not sent; absence and settlement unverified"
  nodeRemoveResultText (NodeRemoveResultObserved DockerNodeContainerRemoveUnconfirmed) = "node removal outcome unconfirmed; absence and settlement unverified"
  nodeRemoveResultText (NodeRemoveResultObserved (DockerNodeContainerRemoveReply status)) = "node removal daemon replied " ++ show status ++ "; absence and settlement unverified"
  nodeRemoveResultText NodeRemoveResultConflict = "node removal result conflicts with attempt"
  nodeRemoveResultText NodeRemoveResultInvalid = "node removal result invalid or incomplete"
  nodeRemoveResultText NodeRemoveResultUnobservable = "node removal result could not be safely observed"
  nodeInspectionText (Left _) = "node inspection unobservable; ownership and readiness unverified"
  nodeInspectionText (Right DockerNodeContainerConflict) = "node identity, image, network, ports or mounts conflict; ownership and readiness unverified"
  nodeInspectionText (Right (DockerNodeContainerMatching running)) =
    "node identity, image, network, ports and mounts match; "
      ++ (if running then "running" else "not running")
      ++ "; ownership and readiness unverified"
  networkRecoveryText outcome = case outcome of
    KindOperationRefused _ -> "operation could not be safely acquired"
    KindOperationUnconfirmed _ -> "operation interrupted; network state unverified"
    KindOperationRootChanged _ -> "operation root or intent changed during observation"
    KindOperationUnlockFailed _ _ -> "lease unlock failed; network state unverified"
    KindOperationScopeCleanupFailed _ _ -> "scope cleanup failed; network state unverified"
    KindOperationCallbackReturned peer -> case peer of
      DockerPeerCompleted (DockerConnectedInfoCompleted result) -> networkResultText result
      DockerPeerChanged _ -> "Docker socket or peer changed during observation"
      DockerPeerRefused _ -> "Docker peer could not be observed"
      DockerPeerUnconfirmed _ -> "observation interrupted"
      DockerPeerUnconfirmedAfter _ _ -> "observation interrupted after a read"
      DockerPeerCompleted (DockerConnectedInfoRefused _) -> "Docker connection could not be observed"
  networkResultText result = case result of
    KindNetworkRecoveryRecordRefused NetworkRecoveryMissing -> "proposal not found locally; network absence and worker settlement unverified"
    KindNetworkRecoveryRecordRefused NetworkRecoveryConflict -> "proposal conflicts with selected scope"
    KindNetworkRecoveryRecordRefused NetworkRecoveryInvalid -> "proposal is invalid or incomplete"
    KindNetworkRecoveryRecordRefused NetworkRecoveryUnobservable -> "proposal could not be safely observed"
    KindNetworkRecoveryRecordRefused (NetworkRecoveryRecorded _) -> "proposal observation inconsistent"
    KindNetworkRecoveryDaemonMismatch -> "recorded daemon differs from connected daemon; worker settlement unverified"
    KindNetworkRecoveryChangedAfter _ -> "scope or proposal changed during observation; worker settlement unverified"
    KindNetworkRecoverySampled sample ->
      "attempt "
        ++ networkAttemptText (networkAttemptBefore sample)
        ++ ", inventory "
        ++ networkInventoryText (networkInventory sample)
        ++ ", detail "
        ++ networkDetailText (networkDetails sample)
        ++ ", configuration "
        ++ networkConfigurationText (networkConfiguration sample)
        ++ ", separate client "
        ++ networkIndependentText (networkDetails sample) (networkIndependent sample)
        ++ ", daemon recheck "
        ++ either (const "failed") (const "matched") (networkDaemonAfter sample)
        ++ ", attempt after "
        ++ networkAttemptText (networkAttemptAfter sample)
        ++ ", removal "
        ++ networkRemovalText (networkRemovalBefore sample)
        ++ ", removal after "
        ++ networkRemovalText (networkRemovalAfter sample)
        ++ ", removal ID "
        ++ networkRemovalIdText (networkRemovalIdObservation sample)
        ++ ", separate removal ID "
        ++ networkIndependentIdText (networkRemovalIndependentId sample)
        ++ ", create receipt "
        ++ networkReceiptText (networkCreateReceipt sample)
        ++ ", removal receipt "
        ++ networkReceiptText (networkRemovalReceipt sample)
        ++ "; daemon authentication, network ownership, absence and worker settlement unverified"
  networkAttemptText value = case value of
    NetworkAttemptMissing -> "missing locally"
    NetworkAttemptMatches -> "recorded"
    NetworkAttemptConflict -> "conflicting"
    NetworkAttemptInvalid -> "invalid"
    NetworkAttemptUnobservable -> "unobservable"
  networkRemovalText value = case value of
    NetworkRemovalRecoveryMissing -> "missing locally"
    NetworkRemovalRecoveryRecorded identifier -> "recorded for " ++ identifier
    NetworkRemovalRecoveryConflict -> "conflicting"
    NetworkRemovalRecoveryInvalid -> "invalid"
    NetworkRemovalRecoveryUnobservable -> "unobservable"
  networkRemovalIdText value = case value of
    Nothing -> "not observed"
    Just (Left _) -> "unobservable"
    Just (Right Nothing) -> "ID query control was blind"
    Just (Right (Just False)) -> "not returned by ID query"
    Just (Right (Just True)) -> "returned by ID query"
  networkReceiptText value = case value of
    NetworkReceiptMissing -> "missing locally"
    NetworkReceiptConflict -> "conflicting"
    NetworkReceiptInvalid -> "invalid"
    NetworkReceiptUnobservable -> "unobservable"
    NetworkReceiptObserved transport -> case transport of
      NetworkCreateTransport DockerNetworkCreateNotStarted -> "create not started"
      NetworkCreateTransport DockerNetworkCreateUnconfirmed -> "create unconfirmed"
      NetworkCreateTransport (DockerNetworkCreateReply status _) -> "create reply " ++ show status
      NetworkRemovalTransport DockerNetworkRemoveNotStarted -> "removal not started"
      NetworkRemovalTransport DockerNetworkRemoveUnconfirmed -> "removal unconfirmed"
      NetworkRemovalTransport (DockerNetworkRemoveReply status) -> "removal reply " ++ show status
  networkIndependentIdText value = case value of
    NetworkIndependentIdUnobservable -> "unobservable"
    NetworkIndependentIdBlind -> "ID query control was blind"
    NetworkIndependentIdObserved False -> "not returned by ID query"
    NetworkIndependentIdObserved True -> "returned by ID query"
    NetworkIndependentIdChanged _ -> "scope or daemon changed"
  networkInventoryText result = case result of
    Left _ -> "unobservable"
    Right [] -> "no matches observed"
    Right [_] -> "one match observed"
    Right _ -> "ambiguous"
  networkDetailText result = case result of
    Nothing -> "not observed"
    Just (Left _) -> "unobservable"
    Just (Right _) -> "observed"
  networkConfigurationText value = case value of
    NetworkConfigurationUnobserved -> "unobserved"
    NetworkConfigurationMatches -> "matches proposal"
    NetworkConfigurationDiffers -> "differs from proposal"
  networkIndependentText held independent = case independent of
    NetworkIndependentUnobservable -> "unobservable"
    NetworkIndependentChanged _ -> "scope or daemon changed"
    NetworkIndependentObserved details -> case held of
      Just (Right previous) | previous == details -> "matching detail observed"
      _ -> "detail differs from held session"
  volumeText KindVolumeDirectoryPresent = "present in selected root; node and Pod mounts unverified"
  volumeText KindVolumeDirectoryMissing = "not found in selected root; resource absence unverified"
  volumeText KindVolumeDirectoryUnsafe = "directory ownership or permissions unsafe"
  volumeText KindVolumeDirectoryChanged = "record or directory changed during observation"
  volumeText KindVolumeGenerationUnavailable = "selected generation unavailable"
  volumeText KindVolumeDirectoryUnobservable = "directory could not be safely observed"
  kubernetesVolumeText KubernetesVolumeNotObserved = "not observed"
  kubernetesVolumeText KubernetesVolumeInputsChanged = "record or kubeconfig changed during observation"
  kubernetesVolumeText (KubernetesVolumeObserved result) =
    bindingText result ++ "; configured CA ownership and node/Pod mounts unverified"
  bindingText (Left failure) = "reader failed: " ++ show failure
  bindingText (Right (KindVolumeStableBinding KindVolumeBindingObserved {})) =
    "configured loopback endpoint reports a stable PV/PVC binding"
  bindingText (Right (KindVolumeStableBinding _)) = "invalid stable binding observation"
  bindingText (Right (KindVolumeBindingUnconfirmed observation)) = "binding unconfirmed: " ++ show observation
  bindingText (Right (KindVolumeBindingChanged _)) = "binding changed during observation"
  bindingText (Right (KindVolumeReadFailed stage failure)) = "read failed at " ++ show stage ++ ": " ++ show failure
  bindingText (Right (KindVolumeReadbackInvalid stage)) = "invalid response at " ++ show stage
  imageText ImageUnobservable = "unobservable; image absence is unverified"
  imageText (ImageObserved digestMatches imageId operatingSystem architecture) =
    "daemon image ID "
      ++ imageId
      ++ ", OS "
      ++ operatingSystem
      ++ ", architecture "
      ++ architecture
      ++ ( if digestMatches
             then "; selected digest appears in RepoDigests"
             else "; selected digest not reported in RepoDigests"
         )
      ++ "; host architecture "
      ++ SystemInfo.arch
  artifactText (ScopeArtifactDigestMatches size) =
    "declared file digest matches (" ++ show size ++ " bytes); image contents and provenance unverified"
  artifactText ScopeArtifactDigestMismatch = "declared file digest differs"
  artifactText ScopeArtifactMissing = "declared file missing"
  artifactText ScopeArtifactUnsafe = "declared file or parent is unsafe"
  artifactText ScopeArtifactTooLarge = "declared file exceeds size limit"
  artifactText ScopeArtifactChanged = "file or root changed during observation"
  artifactText ScopeArtifactUnobservable = "declared file could not be safely observed"
  artifactText ScopeArtifactTimedOut = "file hashing timed out"
  artifactText ScopeArtifactInvalidDeclaration = "invalid artifact declaration"
  runtimeText (RuntimeUnobservable failure) = renderControlStatusError failure ++ "; resource absence is unverified"
  runtimeText RuntimeNoMatchesObserved = "no matches in repeated name and label queries; resource absence is unverified"
  runtimeText RuntimeInventoryChanged = "inventory changed during observation; retry status"
  runtimeText RuntimeForeignOrMultiple = "foreign or multiple matching containers"
  runtimeText (RuntimeNodeObserved running mountMatches) =
    (if running then "control-plane container running" else "control-plane container stopped")
      ++ if mountMatches
        then "; retained bind source, target, and configured write flag match"
        else "; retained bind source, target, or configured write flag differs"
  generationText ScopeGenerationMissing = "missing"
  generationText ScopeGenerationMatches = "matches selected generation"
  generationText ScopeGenerationForeign = "foreign or different root generation"
  generationText ScopeGenerationInvalid = "invalid"
  generationText ScopeGenerationUnobservable = "unobservable"
  generationText ScopeGenerationPathChanged = "root path changed during observation"
  generationText ScopeGenerationInvalidExpected = "invalid selected generation"

renderControlStatusError :: ControlStatusError -> String
renderControlStatusError failure = case failure of
  ControlRootUnobservable -> "the selected root could not be safely observed"
  ControlRuntimeSocketUnobservable -> "the selected Docker socket is unavailable or is not a socket"
  ControlRuntimeCommandFailed -> "the selected Docker daemon could not be queried"
  ControlRuntimeResponseInvalid -> "the selected Docker daemon returned an invalid response"
