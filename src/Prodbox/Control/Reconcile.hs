{-# LANGUAGE ScopedTypeVariables #-}

-- | Early slice of public @control reconcile@ for a new identity: load the
-- retained node archive (which records the kind intent), then create the kind
-- network and node var volume through held, recorded Docker sessions. It stops
-- there; node create/start, kubeadm and kubeconfig are not part of this slice, and no
-- cluster readiness is claimed. Admission here is local and narrow: the
-- daemon observed for the attempt must equal the daemon recorded in the
-- proposal (checked by the attempt boundary), and a pre-existing intent,
-- attempt marker or receipt is never replaced.
module Prodbox.Control.Reconcile
  ( ReconcileOutcome (..)
  , NetworkAttempt
  , reconcileNewPrerequisites
  , reconcileFamilyPrerequisites
  , prepareNewOwnerFamilyOperation
  , kindUlaSubnet
  , imageSubmissionAccepted
  , randomOperationId
  , ImageAttemptFailure (..)
  ) where

import Control.Exception (IOException, try)
import Crypto.Hash.SHA1 qualified as SHA1
import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)
import Numeric (showHex)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapKindTool
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  , decodeOptionalBootstrapSource
  , renderBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( FreshScopeResult (..)
  , prepareFreshScope
  , scopeKindName
  )
import Prodbox.Config.KindPlan (KindNodeCreateInput (..), kindNodeRunArgumentsFor)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfoResult (..)
  , DockerImageLoadResult (..)
  , DockerImageLoadStream (..)
  , DockerImageReadback (..)
  , DockerImageSubmissionObservation (..)
  , DockerNetworkCreateResult (..)
  , DockerNodeVarCreateResult (..)
  , DockerNodeVarVolumeObservation (..)
  , createDockerSessionKindNetwork
  , createDockerSessionNodeVarVolume
  , loadAndObserveDockerSessionImage
  , observeDockerKindNodeRuntime
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), observeDockerDaemon)
import Prodbox.Control.DockerPeer (DockerPeerResult (..))
import Prodbox.Control.ImageIdObservation (ImageIdObservation (..))
import Prodbox.Control.KindDockerWorkerPrepare
  ( KindDockerWorkerPreparation (..)
  , prepareKindDockerWorkerPaths
  )
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches)
  , observeKindOwnerFamilyIntent
  )
import Prodbox.Control.KindLease
  ( KindOperationOutcome (..)
  , retryBusyKindOperationUntil
  , withNewKindOwnerFamilyOperation
  , withRecoveredKindOperation
  , withRecoveredKindOperationUntil
  )
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkIntentWrite (..)
  , mkKindNetworkIntent
  , recordKindNetworkIntent
  )
import Prodbox.Control.KindNetworkReceipt (NetworkTransport (..))
import Prodbox.Control.KindNetworkRecovery
  ( KindNetworkAttemptAction (..)
  , KindNetworkRecordedTransport (..)
  , withNewConnectedKindNetworkRecordedAttemptGuarded
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateIntentWrite (..)
  , mkKindNodeCreateIntent
  , recordKindNodeCreateIntent
  )
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeIntentWrite (..)
  , mkKindNodeVolumeIntent
  , recordKindNodeVolumeIntent
  )
import Prodbox.Control.KindNodeVolumeOperation
  ( KindNodeVolumeAction (..)
  , withNewConnectedKindNodeVolumeAttemptGuarded
  )
import Prodbox.Control.NodeArchive (InspectedArchiveResult (..), VerifiedNodeArchive (..))
import Prodbox.Control.NodeArchiveStage (StagedNodeResult (..))
import Prodbox.Control.NodeImageIntent (NodeImageResultWrite (..))
import Prodbox.Control.NodeImageOperation
  ( NodeImageAttemptAction (..)
  , NodeImageConnectedObservation (..)
  , NodeImageConnectionResult (..)
  , NodeImagePreparation (..)
  , NodeImageRecordedSubmission (..)
  , withNewConnectedNodeImageRecordedAttempt
  , withRecoveredConnectedNodeImageRecordedFamilyAttempt
  )
import Prodbox.Control.Recreate (ArchiveOutcome (..), archiveCompletedOperation)
import Prodbox.Control.Status (observeImageId)
import System.IO (IOMode (ReadMode), withBinaryFile)

type NetworkAttempt =
  KindOperationOutcome
    (DockerPeerResult (DockerConnectedInfoResult (KindNetworkAttemptAction KindNetworkRecordedTransport)))

data ReconcileOutcome
  = ReconcileRootRefused !FreshScopeResult
  | ReconcileCapacityRefused !String
  | ReconcileFamilyAdmissionRefused
  | ReconcileFamilyConfigurationRefused
  | ReconcileFamilyOperationReady !String
  | ReconcileFamilyIntentRefused !String
  | ReconcileDaemonUnobserved !String
  | ReconcileNetworkProposalInvalid
  | ReconcileNetworkProposalRefused !String
  | ReconcileNetworkAttempt !String !NetworkAttempt
  | ReconcileVolumeProposalRefused !String !String
  | ReconcileVolumeProposalInvalid !String
  | ReconcileVolumeAttempt !String !String !String
  | ReconcileNodeProposal !String !String
  | ReconcileNodeReady !String
  | ReconcileNodeProposalInvalid !String
  | ReconcileEntropyUnavailable
  | ReconcileArchiveRefused !String
  | ReconcileRecreated !String ![String]
  | ReconcileImageAttempt !String !String !ImageAttemptFailure
  | ReconcileImageNotObserved !String !String
  deriving (Eq, Show)

-- Closed diagnostic only: no daemon response text or artifact content is
-- retained by the family result.
data ImageAttemptFailure
  = ImageAttemptResultUnconfirmed
  | ImageAttemptReadbackUnconfirmed
  | ImageAttemptTransportUnconfirmed
  | ImageAttemptClosingUnconfirmed
  | ImageAttemptOther
  deriving (Eq, Show)

-- | Subnet kind itself proposes for a network name on its first attempt: a
-- fc00::/8 address whose bytes 2..7 come from SHA-1 of the name followed by
-- the little-endian 32-bit attempt number, as a /64.
kindUlaSubnet :: String -> Int -> String
kindUlaSubnet name attempt =
  let attemptBytes = [fromIntegral ((attempt `div` (256 ^ index)) `mod` 256) | index <- [0 .. 3 :: Int]] :: [Word8]
      digest = ByteString.unpack (SHA1.hash (ByteString8.pack name <> ByteString.pack attemptBytes))
      byte index = fromIntegral (digest !! index) :: Int
      group high low = showHex ((byte high `shiftL` 8) .|. byte low) ""
   in intercalate ":" ["fc00", group 2 3, group 4 5, group 6 7, "", ""] <> "/64"

randomOperationId :: IO (Maybe String)
randomOperationId = do
  bytes <- try (withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 16))
  pure $ case bytes of
    Right value | ByteString.length value == 16 -> Just (concatMap hex2 (ByteString.unpack value))
    Left (_ :: IOException) -> Nothing
    _ -> Nothing
 where
  hex2 byte = let text = showHex byte "" in if length text == 1 then '0' : text else text

-- A pre-existing image cannot turn a failed or uncertain load into success.
-- Even this accepted transport is not a proof of daemon worker settlement.
imageSubmissionAccepted :: NodeImageRecordedSubmission -> Bool
imageSubmissionAccepted
  ( NodeImageRecordedSubmission
      ( DockerImageSubmissionObservation
          (DockerImageLoadReply 200 (DockerImageLoadMessages count))
          (DockerImageReadbackStable (Right ImageIdObserved {}))
        )
      NodeImageResultRecorded
    ) = count > 0
imageSubmissionAccepted _ = False

-- Establish only the owner-first operation before publishing its controller.
-- Image, network and volume effects are performed later by the family worker.
prepareNewOwnerFamilyOperation :: IO (Maybe String) -> BootstrapProjection -> IO ReconcileOutcome
prepareNewOwnerFamilyOperation admit bootstrap = case renderBootstrapProjection bootstrap of
  Nothing -> pure ReconcileFamilyConfigurationRefused
  Just source -> do
    decoded <- decodeOptionalBootstrapSource "kind-family-settings.dhall" source
    if decoded /= Right (Just bootstrap)
      then pure ReconcileFamilyConfigurationRefused
      else do
        prepared <-
          prepareFreshScope (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
        case prepared of
          FreshScopePrepared -> start
          FreshScopeAlreadyExists -> start
          other -> pure (ReconcileRootRefused other)
 where
  start = do
    refusal <- admit
    case refusal of
      Just reason -> pure (ReconcileCapacityRefused reason)
      Nothing -> do
        archived <- archiveCompletedOperation bootstrap
        case archived of
          ArchiveNothingRecorded -> begin
          ArchiveMoved _ _ -> begin
          other -> pure (ReconcileArchiveRefused (show other))
  begin = do
    generated <- randomOperationId
    case generated of
      Nothing -> pure ReconcileEntropyUnavailable
      Just operation -> do
        written <- withNewKindOwnerFamilyOperation bootstrap operation id
        pure $ case written of
          KindOperationCallbackReturned True -> ReconcileFamilyOperationReady operation
          other -> ReconcileFamilyIntentRefused (show other)

-- | Image, network, then node var volume for one new operation. Each later
-- step runs only after an independent observation of the earlier one; any
-- other outcome is returned and every durable record is retained.
-- | The capacity admission runs after the root exists (its probe reads the
-- retained root's device) and before any archive, image, network, volume or
-- node effect; a refusal leaves only the root and its generation record.
reconcileNewPrerequisites :: IO (Maybe String) -> BootstrapProjection -> IO ReconcileOutcome
reconcileNewPrerequisites admit bootstrap = reconcilePrerequisitesUsing Nothing admit bootstrap

-- The managed family already owns the operation and its admission. No new
-- operation or host-side controller is created by this worker path.
reconcileFamilyPrerequisites
  :: Word64 -> BootstrapProjection -> String -> (IO Bool -> IO Bool) -> IO ReconcileOutcome
reconcileFamilyPrerequisites ending bootstrap operation admission =
  do
    admitted <- withRecoveredKindOperationUntil ending bootstrap operation $ \stable -> do
      before <- admission stable
      protocol <- observeKindOwnerFamilyIntent bootstrap
      after <- admission stable
      pure (before && protocol == KindIntentMatches operation && after)
    if admitted == KindOperationCallbackReturned True
      then reconcilePrerequisitesUsing (Just (ending, operation, admission)) (pure Nothing) bootstrap
      else pure ReconcileFamilyAdmissionRefused

reconcilePrerequisitesUsing
  :: Maybe (Word64, String, IO Bool -> IO Bool)
  -> IO (Maybe String)
  -> BootstrapProjection
  -> IO ReconcileOutcome
reconcilePrerequisitesUsing selected admit bootstrap = case selected of
  Just (_, operation, _) -> image operation
  Nothing -> do
    prepared <-
      prepareFreshScope (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
    case prepared of
      FreshScopePrepared -> start
      FreshScopeAlreadyExists -> start
      other -> pure (ReconcileRootRefused other)
 where
  socket = bootstrapRuntimeSocket bootstrap
  admitted stable = case selected of
    Nothing -> stable
    Just (_, operation, admission) -> do
      before <- admission stable
      protocol <- observeKindOwnerFamilyIntent bootstrap
      after <- admission stable
      pure (before && protocol == KindIntentMatches operation && after)
  acquire :: IO (KindOperationOutcome value) -> IO (KindOperationOutcome value)
  acquire action = case selected of
    Nothing -> action
    Just (ending, _, _) -> retryBusyKindOperationUntil ending action
  start = do
    refusal <- admit
    case refusal of
      Just reason -> pure (ReconcileCapacityRefused reason)
      Nothing -> archive
  archive = do
    archived <- archiveCompletedOperation bootstrap
    case archived of
      ArchiveNothingRecorded -> begin
      ArchiveMoved _ _ -> begin
      other -> pure (ReconcileArchiveRefused (show other))
  begin = do
    generated <- randomOperationId
    case generated of
      Nothing -> pure ReconcileEntropyUnavailable
      Just operation -> image operation
  image operation = do
    captured <- newIORef ""
    let submit = case selected of
          Nothing -> withNewConnectedNodeImageRecordedAttempt bootstrap operation
          Just _ -> withRecoveredConnectedNodeImageRecordedFamilyAttempt bootstrap operation admitted
    loaded <- acquire $ submit $ \verified _ size descriptor session stable -> do
      writeIORef captured (nodeConfigDigest verified)
      loadAndObserveDockerSessionImage session descriptor size (nodeConfigDigest verified) stable
    configDigest <- readIORef captured
    case loaded of
      KindOperationCallbackReturned
        ( InspectedArchiveCompleted
            ( StagedNodeCompleted
                ( NodeImagePreparationCompleted
                    ( NodeImageConnectedObserved
                        ( DockerPeerCompleted
                            ( DockerConnectedInfoCompleted
                                (NodeImageConnectionReady (NodeImageAttemptActionReturned submission))
                              )
                          )
                      )
                  )
              )
          )
          | imageSubmissionAccepted submission -> do
              observed <-
                if null configDigest then pure ImageIdUnobservable else observeImageId socket configDigest
              case observed of
                ImageIdObserved {} -> network operation configDigest
                _ -> pure (ReconcileImageNotObserved operation (show observed))
      _ -> pure (ReconcileImageAttempt operation (show loaded) (failureStage loaded))
  failureStage loaded = case loaded of
    KindOperationRootChanged {} -> ImageAttemptClosingUnconfirmed
    KindOperationUnlockFailed {} -> ImageAttemptClosingUnconfirmed
    KindOperationScopeCleanupFailed {} -> ImageAttemptClosingUnconfirmed
    KindOperationCallbackReturned (InspectedArchiveChanged _) -> ImageAttemptClosingUnconfirmed
    KindOperationCallbackReturned (InspectedArchiveUnconfirmedAfter _ _) -> ImageAttemptClosingUnconfirmed
    KindOperationCallbackReturned (InspectedArchiveCompleted (StagedNodeChanged _)) -> ImageAttemptClosingUnconfirmed
    KindOperationCallbackReturned
      (InspectedArchiveCompleted (StagedNodeCompleted (NodeImagePreparationChangedAfter _))) -> ImageAttemptClosingUnconfirmed
    KindOperationCallbackReturned
      ( InspectedArchiveCompleted
          ( StagedNodeCompleted
              (NodeImagePreparationCompleted (NodeImageConnectedObserved (DockerPeerChanged _)))
            )
        ) -> ImageAttemptClosingUnconfirmed
    KindOperationCallbackReturned
      ( InspectedArchiveCompleted
          ( StagedNodeCompleted
              ( NodeImagePreparationCompleted
                  ( NodeImageConnectedObserved
                      ( DockerPeerCompleted
                          (DockerConnectedInfoCompleted (NodeImageConnectionChangedAfter _))
                        )
                    )
                )
            )
        ) -> ImageAttemptClosingUnconfirmed
    KindOperationCallbackReturned
      ( InspectedArchiveCompleted
          ( StagedNodeCompleted
              ( NodeImagePreparationCompleted
                  ( NodeImageConnectedObserved
                      ( DockerPeerCompleted
                          (DockerConnectedInfoCompleted (NodeImageConnectionReady (NodeImageAttemptActionChangedAfter _)))
                        )
                    )
                )
            )
        ) -> ImageAttemptClosingUnconfirmed
    KindOperationCallbackReturned
      ( InspectedArchiveCompleted
          ( StagedNodeCompleted
              ( NodeImagePreparationCompleted
                  ( NodeImageConnectedObserved
                      ( DockerPeerCompleted
                          ( DockerConnectedInfoCompleted
                              ( NodeImageConnectionReady
                                  ( NodeImageAttemptActionReturned
                                      (NodeImageRecordedSubmission (DockerImageSubmissionObservation transport readback) recorded)
                                    )
                                )
                            )
                        )
                    )
                )
            )
        ) ->
        if recorded /= NodeImageResultRecorded
          then ImageAttemptResultUnconfirmed
          else case transport of
            DockerImageLoadReply 200 (DockerImageLoadMessages count) | count > 0 -> case readback of
              DockerImageReadbackStable (Right ImageIdObserved {}) -> ImageAttemptOther
              _ -> ImageAttemptReadbackUnconfirmed
            _ -> ImageAttemptTransportUnconfirmed
    _ -> ImageAttemptOther
  network operation configDigest = do
    daemon <- observeDockerDaemon socket
    case daemon of
      DockerDaemonObserved _ _ ->
        case mkKindNetworkIntent
          operation
          (kindUlaSubnet (scopeKindName (bootstrapScope bootstrap)) 0)
          Nothing
          daemon of
          Nothing -> pure ReconcileNetworkProposalInvalid
          Just intent -> do
            recorded <- acquire $ withRecoveredKindOperation bootstrap operation $ \stable ->
              recordKindNetworkIntent bootstrap intent (admitted stable)
            case recorded of
              KindOperationCallbackReturned NetworkIntentRecorded -> do
                created <- acquire $ withNewConnectedKindNetworkRecordedAttemptGuarded bootstrap operation admitted $ \_ session stable ->
                  createDockerSessionKindNetwork session bootstrap intent stable
                case createdNetworkId created of
                  Just networkId -> volume operation configDigest networkId
                  Nothing -> pure (ReconcileNetworkAttempt operation created)
              other -> pure (ReconcileNetworkProposalRefused (show other))
      other -> pure (ReconcileDaemonUnobserved (show other))
  volume operation configDigest networkId = do
    daemon <- observeDockerDaemon socket
    case mkKindNodeVolumeIntent operation daemon of
      Nothing -> pure (ReconcileVolumeProposalInvalid operation)
      Just intent -> do
        recorded <- acquire $ withRecoveredKindOperation bootstrap operation $ \stable ->
          recordKindNodeVolumeIntent bootstrap intent (admitted stable)
        case recorded of
          KindOperationCallbackReturned NodeVolumeIntentRecorded -> do
            created <- acquire $ withNewConnectedKindNodeVolumeAttemptGuarded bootstrap operation admitted $ \session stable ->
              createDockerSessionNodeVarVolume session bootstrap operation stable
            case created of
              KindOperationCallbackReturned
                ( DockerPeerCompleted
                    ( DockerConnectedInfoCompleted
                        (NodeVolumeActionReturned (DockerNodeVarCreateReply 201 (Just DockerNodeVarVolumeMatching)) _)
                      )
                  ) -> nodeProposal operation configDigest networkId
              _ -> pure (ReconcileVolumeAttempt operation networkId (show created))
          other -> pure (ReconcileVolumeProposalRefused operation (show other))
  nodeProposal operation configDigest networkId = do
    runtime <- observeDockerKindNodeRuntime socket
    let propose (daemon, mode) =
          mkKindNodeCreateIntent
            bootstrap
            ( KindNodeCreateInput
                (maybe "" artifactDigest (bootstrapKindTool bootstrap))
                configDigest
                networkId
                (Text.unpack (bootstrapRootGeneration bootstrap))
                operation
                (kindNodeRunArgumentsFor mode (bootstrapKindPlan bootstrap) configDigest)
            )
            daemon
    case runtime >>= propose of
      Nothing -> pure (ReconcileNodeProposalInvalid operation)
      Just intent -> do
        recorded <- acquire $ withRecoveredKindOperation bootstrap operation $ \stable ->
          recordKindNodeCreateIntent bootstrap intent (admitted stable)
        case recorded of
          KindOperationCallbackReturned NodeCreateIntentRecorded -> do
            prepared <-
              acquire $
                withRecoveredKindOperation
                  bootstrap
                  operation
                  (prepareKindDockerWorkerPaths bootstrap operation . admitted)
            case prepared of
              KindOperationCallbackReturned KindDockerWorkerPrepared -> pure (ReconcileNodeReady operation)
              other -> pure (ReconcileNodeProposal operation ("worker paths: " <> show other))
          other -> pure (ReconcileNodeProposal operation (show other))
  createdNetworkId attempt = case attempt of
    KindOperationCallbackReturned
      ( DockerPeerCompleted
          ( DockerConnectedInfoCompleted
              ( KindNetworkAttemptReturned
                  ( KindNetworkRecordedTransport
                      (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just networkId)))
                      _
                    )
                )
            )
        ) -> Just networkId
    _ -> Nothing
